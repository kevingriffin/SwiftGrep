import Darwin
import GrepRegex
import Synchronization
import System

/// Identity of a directory, for symlink loop detection with `--follow`.
struct FileID: Hashable, Sendable {
  var device: Int32
  var inode: UInt64

  init(_ info: Stat) {
    device = info.deviceID.rawValue
    inode = info.inode.rawValue
  }
}

struct DirectoryJob: Sendable {
  /// The path as printed, e.g. `pkgs/foo` (empty for an implicit `.`).
  var displayPath: [UInt8]
  /// Absolute path, used to match anchored ignore rules.
  var absolutePath: [UInt8]
  /// Depth of this directory below the search root (the root is 0).
  var depth: Int
  var ignore: IgnoreLevel?
  /// Directories above this one (only tracked with `--follow`).
  var ancestors: [FileID]
  var root: SearchRoot
}

/// What every directory under a search root shares. It's one reference so
/// that `DirectoryJob` stays small: with a seventh stored property, the
/// optimizer stopped passing jobs by their fields, and listing nixpkgs got
/// 7% slower.
final class SearchRoot: Sendable {
  /// The listing cache, if enabled.
  let cache: ListingCache?
  /// The device, for `--one-file-system`.
  let device: Int32

  init(cache: ListingCache?, device: Int32) {
    self.cache = cache
    self.device = device
  }
}

/// How a directory's entries are reached: through an open descriptor when its
/// listing was read from the file system, or by path when it came from the
/// listing cache (the directory itself is then never opened).
enum DirectoryAccess {
  case descriptor(FileDescriptor)
  case path
}

enum Job: Sendable {
  case directory(DirectoryJob)
  /// A file named on the command line.
  case file(displayPath: [UInt8])
  /// A large file found while walking, searched by whichever worker is free
  /// (`size` is -1 if unknown).
  case largeFile(displayPath: [UInt8], size: Int64)
  case standardInput
}

struct WalkOptions: Sendable {
  var hidden = false
  var followLinks = false
  var maxDepth: Int?
  var maxFilesize: Int64?
  /// Don't descend into directories on other devices than their root.
  var oneFileSystem = false
  var useIgnoreFiles = true
  var ignore = IgnoreContext()
  /// `--ignore-file` rules, in order; later files take precedence. They are
  /// matched against paths relative to the current directory, below every
  /// other kind of ignore file.
  var explicitIgnores: [IgnoreRules] = []
}

/// State shared by all workers of one search.
final class SearchRun: Sendable {
  let settings: OutputSettings
  let matcher: Matcher
  let walk: WalkOptions
  let overrides: IgnoreRules?
  let overridesWhitelist: Bool
  let types: TypeMatcher?
  let sink: OutputSink
  let queue: WorkQueue<Job>
  /// Write output after every file (line buffering).
  let flushEachFile: Bool
  /// Each file's output goes to the sink separately (headings, context, sorting).
  let separateFiles: Bool
  let sortOutput: Bool
  /// `-q` without `--stats`: the first match ends the whole search.
  let quitAfterMatch: Bool
  /// Report errors (`--no-messages` turns this off; they still count).
  let messages: Bool
  /// Report ignore files that can't be parsed (`--no-ignore-messages`).
  let ignoreMessages: Bool
  /// The search root is the current directory, which wasn't named.
  let implicitPath: Bool
  /// `--pre` and `-z`.
  let commands: FileCommands?

  let matched = Atomic<Bool>(false)
  let failed = Atomic<Bool>(false)
  let stopped = Atomic<Bool>(false)
  let totals = Mutex(SearchTotals())

  init(settings: OutputSettings, matcher: Matcher, walk: WalkOptions, overrides: IgnoreRules?,
       types: TypeMatcher?, sink: OutputSink, queue: WorkQueue<Job>, flushEachFile: Bool, separateFiles: Bool,
       sortOutput: Bool, quitAfterMatch: Bool, messages: Bool, ignoreMessages: Bool, implicitPath: Bool,
       commands: FileCommands? = nil)
  {
    self.settings = settings
    self.matcher = matcher
    self.walk = walk
    self.overrides = overrides
    overridesWhitelist = overrides?.rules.contains { $0.negated } ?? false
    self.types = types
    self.sink = sink
    self.queue = queue
    self.flushEachFile = flushEachFile
    self.separateFiles = separateFiles
    self.sortOutput = sortOutput
    self.quitAfterMatch = quitAfterMatch
    self.messages = messages
    self.ignoreMessages = ignoreMessages
    self.implicitPath = implicitPath
    self.commands = commands
  }

  func stop() {
    stopped.store(true, ordering: .relaxed)
    queue.cancel()
  }

  func report(_ path: [UInt8], _ error: Errno) {
    report(path, error.message)
  }

  func report(_ path: [UInt8], _ message: String) {
    failed.store(true, ordering: .relaxed)
    guard messages else { return }
    Diagnostics.error("\(String(decoding: path.isEmpty ? Array(".".utf8) : path, as: UTF8.self)): \(message)")
  }

  /// Reports the lines of an ignore file that couldn't be parsed, one per
  /// line of the message, as ripgrep does.
  func reportIgnoreErrors(_ errors: [String], path: String) {
    guard ignoreMessages, !errors.isEmpty else { return }
    Diagnostics.error(errors.map { "\(path): \($0)" }.joined(separator: "\n"))
  }

  /// Adds one worker's totals.
  func add(_ worker: SearchTotals) {
    totals.withLock { t in
      t.filesConsidered += worker.filesConsidered
      t.filesSearched += worker.filesSearched
      t.filesMatched += worker.filesMatched
      t.matches += worker.matches
      t.matchedLines += worker.matchedLines
      t.bytesSearched += worker.bytesSearched
      t.bytesPrinted += worker.bytesPrinted
      t.nanoseconds += worker.nanoseconds
    }
  }
}

/// One search worker. Owns its reusable buffers and matcher state, so it is
/// non-copyable; it lives for the duration of its task.
struct Worker: ~Copyable {
  let shared: SearchRun
  private var searcher: FileSearcher
  private var listing = DirectoryListing()
  private var buffer = FileBuffer()
  private var displayScratch: [UInt8] = []
  private var scratch = PathScratch()
  private var subdirectories: [Job] = []
  private var largeFiles: [Job] = []
  private var fileIndices: [Int] = []

  /// Larger files are memory mapped rather than read, which keeps the
  /// per-worker buffers small.
  static let mmapThreshold: Int64 = 4 << 20

  private static let gitName = Array(".git".utf8)
  private static let ignoreName = Array(".ignore".utf8)
  private static let rgignoreName = Array(".rgignore".utf8)
  private static let gitignoreName = Array(".gitignore".utf8)
  private static let gitExcludePath = Array(".git/info/exclude".utf8)

  init(shared: SearchRun) {
    self.shared = shared
    searcher = FileSearcher(shared: shared)
    displayScratch.reserveCapacity(1024)
  }

  mutating func run() async {
    var finishedOne = false
    while let job = await shared.queue.next(finishedOne: finishedOne) {
      finishedOne = true
      if shared.stopped.load(ordering: .relaxed) {
        continue
      }
      switch job {
      case let .directory(directory):
        process(directory)
      case let .file(path):
        searchExplicitFile(path)
      case let .largeFile(path, size):
        searchLargeFile(path, size: size)
      case .standardInput:
        searchStandardInput()
      }
    }
    searcher.flush()
    shared.add(searcher.totals)
  }

  // MARK: - Directories

  private mutating func process(_ job: DirectoryJob) {
    var openPath = job.displayPath.isEmpty ? Array(".".utf8) : job.displayPath
    openPath.append(0)
    var info: Stat?
    if job.root.cache != nil || shared.walk.oneFileSystem {
      // A cheap stat decides whether the cached listing is still valid.
      let current: Stat
      do {
        current = try OS.stat(openPath.span)
      } catch {
        shared.report(job.displayPath, error)
        return
      }
      info = current
      if shared.walk.oneFileSystem && current.deviceID.rawValue != job.root.device {
        return
      }
    }
    if let cache = job.root.cache, let current = info {
      if cache.load(ListingCache.Key(current), stamp: ListingCache.Stamp(current), into: &listing) {
        processEntries(of: job, access: .path, info: current)
        return
      }
    }
    // The directory stays open while its entries are processed.
    let directory: OpenFile
    do {
      directory = try OS.open(openPath.span, [.directory, .closeOnExec])
    } catch {
      shared.report(job.displayPath, error)
      return
    }
    if info == nil {
      info = try? directory.descriptor.stat()
    }
    do {
      try listing.read(directory: directory.descriptor)
    } catch {
      shared.report(job.displayPath, error)
      return
    }
    if let cache = job.root.cache, let info {
      cache.record(ListingCache.Key(info), stamp: ListingCache.Stamp(info), listing: listing)
    }
    processEntries(of: job, access: .descriptor(directory.descriptor), info: info)
  }

  /// Filters the entries of the listing just read and searches or queues them.
  private mutating func processEntries(of job: DirectoryJob, access: DirectoryAccess, info: Stat?) {
    var ancestors = job.ancestors
    if shared.walk.followLinks, let info {
      let id = FileID(info)
      if ancestors.contains(id) {
        shared.failed.store(true, ordering: .relaxed)
        if shared.messages {
          Diagnostics.error("File system loop found: \(String(decoding: job.displayPath, as: UTF8.self)) points to an ancestor")
        }
        return
      }
      ancestors.append(id)
    }

    let level = shared.walk.useIgnoreFiles ? loadIgnoreFiles(access, job: job) : job.ignore
    let entryDepth = job.depth + 1
    let descend = shared.walk.maxDepth.map { entryDepth < $0 } ?? true
    let searchFiles = shared.walk.maxDepth.map { entryDepth <= $0 } ?? true

    subdirectories.removeAll(keepingCapacity: true)
    largeFiles.removeAll(keepingCapacity: true)
    fileIndices.removeAll(keepingCapacity: true)
    for index in listing.entries.indices {
      var entry = listing.entries[index]
      if entry.kind == .symlink {
        guard shared.walk.followLinks, let target = statEntry(entry, access, job: job) else { continue }
        entry.kind = EntryKind(target.type)
        entry.size = target.size
      }
      let isDirectory = entry.kind == .directory
      guard isDirectory ? descend : (entry.kind == .file && searchFiles) else { continue }
      guard Self.accept(entry, isDirectory: isDirectory, in: job, level: level, listing: listing,
                        scratch: &scratch, shared: shared) else { continue }
      if isDirectory {
        let name = listing.nameBytes(of: entry)
        let child = DirectoryJob(
          displayPath: Self.join(job.displayPath, name.span),
          absolutePath: Self.join(job.absolutePath, name.span),
          depth: entryDepth, ignore: level, ancestors: ancestors, root: job.root,
        )
        subdirectories.append(.directory(child))
      } else {
        if let max = shared.walk.maxFilesize {
          // Cached listings carry no sizes; look this one up.
          if entry.size < 0, let info = statEntry(entry, access, job: job) {
            entry.size = info.size
          }
          if entry.size > max {
            continue
          }
        }
        listing.setKindAndSize(at: index, kind: entry.kind, size: entry.size)
        if entry.isLarge && shared.settings.mode != .listFiles {
          let path = Self.join(job.displayPath, listing.names.span.extracting(entry.nameRange))
          largeFiles.append(.largeFile(displayPath: path, size: entry.size))
        } else {
          fileIndices.append(index)
        }
      }
    }
    // Publish subdirectories first so idle workers can start on them, and
    // large files last so they are taken first: a directory full of large
    // files (Linux has 188 MB of headers in one) would otherwise keep one
    // worker busy long after the others ran out of work.
    shared.queue.push(subdirectories)
    shared.queue.push(largeFiles)
    for index in fileIndices {
      if shared.stopped.load(ordering: .relaxed) {
        return
      }
      searchEntry(listing.entries[index], access, parent: job)
    }
  }

  /// `directory/name` (relative to the working directory) as a C string.
  private func entryPath(_ entry: DirectoryEntry, in job: DirectoryJob) -> [UInt8] {
    var path = Self.join(job.displayPath.isEmpty ? Array(".".utf8) : job.displayPath,
                         listing.names.span.extracting(entry.nameRange))
    path.append(0)
    return path
  }

  private func statEntry(_ entry: DirectoryEntry, _ access: DirectoryAccess, job: DirectoryJob) -> Stat? {
    switch access {
    case let .descriptor(fd):
      try? OS.stat(listing.names.span.extracting(entry.cNameRange), in: fd)
    case .path:
      try? OS.stat(entryPath(entry, in: job).span)
    }
  }

  /// Reads a small file in the directory, such as an ignore file.
  private func readSmallFile(_ entry: DirectoryEntry, _ access: DirectoryAccess, job: DirectoryJob) -> [UInt8]? {
    switch access {
    case let .descriptor(fd):
      return try? FileIO.readWholeFile(listing.names.span.extracting(entry.cNameRange), in: fd)
    case .path:
      guard let file = try? OS.open(entryPath(entry, in: job).span, .closeOnExec) else { return nil }
      return try? FileIO.readWholeFile(file.descriptor)
    }
  }

  /// Reads `relative` (a path inside the directory, without a terminator).
  private func readSmallFile(_ relative: [UInt8], _ access: DirectoryAccess, job: DirectoryJob) -> [UInt8]? {
    switch access {
    case let .descriptor(fd):
      return try? FileIO.readWholeFile((relative + [0]).span, in: fd)
    case .path:
      var path = Self.join(job.displayPath.isEmpty ? Array(".".utf8) : job.displayPath, relative.span)
      path.append(0)
      guard let file = try? OS.open(path.span, .closeOnExec) else { return nil }
      return try? FileIO.readWholeFile(file.descriptor)
    }
  }

  static func join(_ parent: [UInt8], _ name: Span<UInt8>) -> [UInt8] {
    var result: [UInt8] = []
    result.reserveCapacity(parent.count + name.count + 1)
    result.append(contentsOf: parent)
    if !parent.isEmpty && parent.last != UInt8(ascii: "/") {
      result.append(UInt8(ascii: "/"))
    }
    for i in name.indices {
      result.append(name[i])
    }
    return result
  }

  /// Applies `--glob` overrides, ignore files, `--type` and hidden-file rules.
  private static func accept(
    _ entry: DirectoryEntry, isDirectory: Bool, in job: DirectoryJob, level: IgnoreLevel?,
    listing: borrowing DirectoryListing, scratch: inout PathScratch, shared: SearchRun,
  ) -> Bool {
    let names = listing.names.span
    let name = names.extracting(entry.nameRange)
    // The path relative to the current directory, for `--glob` and
    // `--ignore-file`.
    var relativeNameStart = 0
    if shared.overrides != nil || !shared.walk.explicitIgnores.isEmpty {
      scratch.override.removeAll(keepingCapacity: true)
      var parent = job.displayPath[...]
      if parent.starts(with: [UInt8(ascii: "."), UInt8(ascii: "/")]) {
        parent = parent.dropFirst(2)
      }
      if parent == [UInt8(ascii: ".")] {
        parent = []
      }
      scratch.override.append(contentsOf: parent)
      if !parent.isEmpty && parent.last != UInt8(ascii: "/") {
        scratch.override.append(UInt8(ascii: "/"))
      }
      relativeNameStart = scratch.override.count
      for i in entry.nameRange {
        scratch.override.append(names[i])
      }
    }
    if let overrides = shared.overrides {
      // Overrides beat every other rule, including hidden files.
      switch overrides.match(scratch.override.span, nameStart: relativeNameStart, isDirectory: isDirectory) {
      case .ignore: return false
      case .whitelist: return true
      case .none: if shared.overridesWhitelist && !isDirectory {
          return false
        }
      }
    }
    var m = IgnoreMatch.none
    if let level, level.hasRules {
      if level.needsRelativePath {
        scratch.absolute.removeAll(keepingCapacity: true)
        scratch.absolute.append(contentsOf: job.absolutePath)
        scratch.absolute.append(UInt8(ascii: "/"))
        let nameStart = scratch.absolute.count
        for i in entry.nameRange {
          scratch.absolute.append(names[i])
        }
        m = shared.walk.ignore.match(level: level, path: scratch.absolute.span, nameStart: nameStart, isDirectory: isDirectory)
      } else {
        m = shared.walk.ignore.match(level: level, path: name, nameStart: 0, isDirectory: isDirectory)
      }
    }
    if m == .none {
      for rules in shared.walk.explicitIgnores.reversed() where m == .none {
        m = rules.match(scratch.override.span, nameStart: relativeNameStart, isDirectory: isDirectory)
      }
    }
    if m == .ignore {
      return false
    }
    var whitelisted = m == .whitelist
    if !isDirectory, let types = shared.types {
      switch types.match(name: name) {
      case .ignore: return false
      case .whitelist: whitelisted = true
      case .none: break
      }
    }
    if !whitelisted && !shared.walk.hidden && name[0] == UInt8(ascii: ".") {
      return false
    }
    return true
  }

  /// Reads the ignore files present in this directory (known from the
  /// listing, so nothing is opened speculatively).
  private func loadIgnoreFiles(_ access: DirectoryAccess, job: DirectoryJob) -> IgnoreLevel? {
    let context = shared.walk.ignore
    var rgignore: IgnoreRules?
    var dotIgnore: IgnoreRules?
    var gitignore: IgnoreRules?
    var gitExclude: IgnoreRules?
    var hasGit = false
    let names = listing.names.span
    for entry in listing.entries {
      let name = names.extracting(entry.nameRange)
      guard name.count >= 4, name[0] == UInt8(ascii: "."), entry.kind != .directory || name.count == 4 else { continue }
      if name.equals(Self.gitName) {
        hasGit = true
        if entry.kind == .directory && context.useGitExclude,
           let data = readSmallFile(Self.gitExcludePath, access, job: job)
        {
          var errors: [String] = []
          gitExclude = IgnoreRules(gitignore: data, caseInsensitive: context.caseInsensitive, errors: &errors)
          shared.reportIgnoreErrors(errors, path: ignoreFilePath(job, Self.gitExcludePath))
        }
      } else if name.equals(Self.ignoreName) && context.useDotIgnore {
        dotIgnore = readRules(entry, access, job: job)
      } else if name.equals(Self.rgignoreName) && context.useRgignore {
        rgignore = readRules(entry, access, job: job)
      } else if name.equals(Self.gitignoreName) && context.useGitignore {
        gitignore = readRules(entry, access, job: job)
      }
    }
    guard rgignore != nil || dotIgnore != nil || gitignore != nil || gitExclude != nil || hasGit else {
      return job.ignore
    }
    var directory = job.absolutePath
    if directory.last != UInt8(ascii: "/") {
      directory.append(UInt8(ascii: "/"))
    }
    return IgnoreLevel(parent: job.ignore, directory: directory, rgignore: rgignore, dotIgnore: dotIgnore,
                       gitignore: gitignore, gitExclude: gitExclude, hasGit: hasGit)
  }

  private func readRules(_ entry: DirectoryEntry, _ access: DirectoryAccess, job: DirectoryJob) -> IgnoreRules? {
    guard let data = readSmallFile(entry, access, job: job) else { return nil }
    var errors: [String] = []
    let rules = IgnoreRules(gitignore: data, caseInsensitive: shared.walk.ignore.caseInsensitive, errors: &errors)
    shared.reportIgnoreErrors(errors, path: ignoreFilePath(job, listing.nameBytes(of: entry)))
    return rules.rules.isEmpty ? nil : rules
  }

  /// An ignore file's path as ripgrep names it in messages: below the
  /// current directory, it starts with `./`.
  private func ignoreFilePath(_ job: DirectoryJob, _ name: [UInt8]) -> String {
    let directory = shared.implicitPath ? Array("./".utf8) + job.displayPath : job.displayPath
    return String(decoding: Self.join(directory, name.span), as: UTF8.self)
  }

  // MARK: - Files

  private mutating func searchEntry(_ entry: DirectoryEntry, _ access: DirectoryAccess, parent: DirectoryJob) {
    displayScratch.removeAll(keepingCapacity: true)
    displayScratch.append(contentsOf: parent.displayPath)
    if !parent.displayPath.isEmpty && parent.displayPath.last != UInt8(ascii: "/") {
      displayScratch.append(UInt8(ascii: "/"))
    }
    do {
      let names = listing.names.span
      for i in entry.nameRange {
        displayScratch.append(names[i])
      }
    }

    searcher.totals.filesConsidered += 1
    if shared.settings.mode == .listFiles {
      searcher.list(displayScratch)
      return
    }
    if searchThroughCommand(explicit: false) {
      return
    }
    if entry.size == 0 {
      // Nothing to read, but some modes still report the file.
      searcher.search([UInt8]().span, path: displayScratch, explicit: false)
      return
    }
    let file: OpenFile
    do {
      switch access {
      case let .descriptor(fd):
        file = try OS.open(listing.names.span.extracting(entry.cNameRange), in: fd, .closeOnExec)
      case .path:
        file = try OS.open((displayScratch + [0]).span, .closeOnExec)
      }
    } catch {
      shared.report(displayScratch, error)
      return
    }
    readAndSearch(file, size: entry.size, regularFile: true, explicit: false)
  }

  /// Reads the file (closing it) and searches its contents.
  private mutating func readAndSearch(_ file: consuming OpenFile, size: Int64, regularFile: Bool, explicit: Bool) {
    switch buffer.readAll(file.descriptor, sizeHint: size, regularFile: regularFile, mapThreshold: Self.mmapThreshold) {
    case .complete:
      file.close()
      searcher.search(buffer.storage.span, path: displayScratch, explicit: explicit)
      buffer.shrinkIfLarge()
    case let .failed(error):
      shared.report(displayScratch, error)
    case let .tooLarge(length):
      let mapped: MappedFile
      do {
        mapped = try MappedFile(file.descriptor, length: Int(length))
      } catch {
        shared.report(displayScratch, error)
        return
      }
      file.close()
      let path = displayScratch
      mapped.withBytes { searcher.search($0, path: path, explicit: explicit) }
    }
  }

  private mutating func searchExplicitFile(_ path: [UInt8]) {
    displayScratch = path
    searcher.totals.filesConsidered += 1
    if shared.settings.mode != .listFiles, searchThroughCommand(explicit: true) {
      return
    }
    let file: OpenFile
    do {
      file = try OS.open((path + [0]).span, .closeOnExec)
    } catch {
      shared.report(path, error)
      return
    }
    let size = (try? file.descriptor.stat()).flatMap { $0.type == .regular ? $0.size : nil } ?? -1
    if shared.settings.mode == .listFiles {
      file.close()
      searcher.list(path)
      return
    }
    readAndSearch(file, size: size, regularFile: size >= 0, explicit: true)
  }

  private mutating func searchLargeFile(_ path: [UInt8], size: Int64) {
    displayScratch = path
    searcher.totals.filesConsidered += 1
    if searchThroughCommand(explicit: false) {
      return
    }
    let file: OpenFile
    do {
      file = try OS.open((path + [0]).span, .closeOnExec)
    } catch {
      shared.report(displayScratch, error)
      return
    }
    readAndSearch(file, size: size, regularFile: true, explicit: false)
  }

  /// `--pre` and `-z`: searches a command's output instead of the file at
  /// `displayScratch`. Returns false if the file is to be searched as it is
  /// (no command applies, or a decompressor couldn't be started).
  private mutating func searchThroughCommand(explicit: Bool) -> Bool {
    guard let commands = shared.commands, let command = commands.command(for: displayScratch) else { return false }
    let result: OS.ProcessResult
    switch command {
    case let .preprocess(arguments):
      // The preprocessor reads the file on standard input too.
      let input: OpenFile
      do {
        input = try OS.open((displayScratch + [0]).span, .closeOnExec)
      } catch {
        shared.report(displayScratch, error)
        return true
      }
      do {
        result = try OS.spawn(arguments, input: input.descriptor)
      } catch {
        shared.report(displayScratch, "preprocessor command could not start: '\(FileCommands.describe(arguments))': "
          + error.message)
        return true
      }
      guard result.status == 0 else {
        shared.report(displayScratch, "preprocessor command failed: '\(FileCommands.describe(arguments))': "
          + FileCommands.describe(errorOutput: result.error))
        return true
      }
    case let .decompress(arguments):
      // Like ripgrep, a missing decompressor means the file is searched as is.
      guard let output = try? OS.spawn(arguments) else { return false }
      guard output.status == 0 else {
        shared.report(displayScratch, FileCommands.describe(errorOutput: output.error))
        return true
      }
      result = output
    }
    searchBytes(result.output, explicit: explicit)
    return true
  }

  private mutating func searchBytes(_ bytes: [UInt8], explicit: Bool) {
    searcher.search(bytes.span, path: displayScratch, explicit: explicit)
  }

  private mutating func searchStandardInput() {
    displayScratch = Array("<stdin>".utf8)
    searcher.totals.filesConsidered += 1
    guard let input = try? FileDescriptor.standardInput.duplicate() else { return }
    readAndSearch(OpenFile(input), size: -1, regularFile: false, explicit: true)
  }
}

/// Reusable buffers for building the paths that ignore rules are matched
/// against.
struct PathScratch {
  var absolute: [UInt8] = []
  var override: [UInt8] = []

  init() {
    absolute.reserveCapacity(1024)
  }
}

extension DirectoryListing {
  /// Records a resolved kind and size (after following a symlink).
  mutating func setKindAndSize(at index: Int, kind: EntryKind, size: Int64) {
    updateEntry(at: index) { entry in
      entry.kind = kind
      entry.size = size
    }
  }
}

extension Span where Element == UInt8 {
  /// Whether the span holds exactly `bytes`.
  func equals(_ bytes: [UInt8]) -> Bool {
    guard count == bytes.count else { return false }
    for i in indices where self[i] != bytes[i] {
      return false
    }
    return true
  }
}
