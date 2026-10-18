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
  /// The listing cache for this job's search root, if enabled.
  var cache: ListingCache?
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
  var useIgnoreFiles = true
  var ignore = IgnoreContext()
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
  /// Write output after every file (interactive terminals).
  let flushEachFile: Bool
  /// Each file's output goes to the sink separately (headings, context, sorting).
  let separateFiles: Bool
  let sortOutput: Bool
  let showErrors = true

  let matched = Atomic<Bool>(false)
  let failed = Atomic<Bool>(false)
  let stopped = Atomic<Bool>(false)
  let filesSearched = Atomic<Int>(0)
  let filesMatched = Atomic<Int>(0)
  let bytesSearched = Atomic<Int>(0)
  let linesMatched = Atomic<Int>(0)

  init(settings: OutputSettings, matcher: Matcher, walk: WalkOptions, overrides: IgnoreRules?,
       types: TypeMatcher?, sink: OutputSink, queue: WorkQueue<Job>, flushEachFile: Bool, separateFiles: Bool, sortOutput: Bool)
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
  }

  func stop() {
    stopped.store(true, ordering: .relaxed)
    queue.cancel()
  }

  func report(_ path: [UInt8], _ error: Errno) {
    failed.store(true, ordering: .relaxed)
    Diagnostics.error("\(String(decoding: path.isEmpty ? Array(".".utf8) : path, as: UTF8.self)): \(error.message)")
  }
}

/// Searches file contents and formats their output. Owned by a worker; kept
/// apart from the worker's read buffer so a span of that buffer can be
/// searched while this state is mutated.
struct FileSearcher: ~Copyable {
  let shared: SearchRun
  private var lineMatcher: LineMatcher
  var out = OutputBuffer()
  var filesSearched = 0
  var bytesSearched = 0
  var filesMatched = 0
  var linesMatched = 0

  static let flushThreshold = 64 * 1024

  init(shared: SearchRun) {
    self.shared = shared
    lineMatcher = shared.matcher.makeLineMatcher()
  }

  /// Searches one file's contents. `path` is the path as displayed.
  mutating func search(_ data: Span<UInt8>, path: [UInt8], explicit: Bool) {
    let start = out.count
    filesSearched += 1
    bytesSearched += data.count
    var search = FileSearch(settings: shared.settings, path: path)
    search.run(data, explicit: explicit, matcher: &lineMatcher, out: &out)
    let result = search.result
    let mode = shared.settings.mode
    if result.hadMatch {
      filesMatched += 1
      linesMatched += result.matchedLines
    }
    if result.hadMatch != (mode == .filesWithoutMatch) {
      shared.matched.store(true, ordering: .relaxed)
      if mode == .quiet {
        shared.stop()
      }
    }
    guard out.count > start else { return }
    if shared.sortOutput {
      shared.sink.collect(path: path, data: out.copyBytes(from: start))
      out.truncate(to: start)
    } else if shared.separateFiles {
      shared.sink.writeFile(out.storage.span)
      out.removeAll()
      if shared.sink.isBroken {
        shared.stop()
      }
    } else if shared.flushEachFile || out.count >= Self.flushThreshold {
      flush()
    }
  }

  /// Prints a path for `--files`.
  mutating func list(_ path: [UInt8]) {
    out.append(path)
    out.append(shared.settings.nullAfterPath ? 0 : 10)
    shared.matched.store(true, ordering: .relaxed)
    if shared.flushEachFile || out.count >= Self.flushThreshold {
      flush()
    }
  }

  mutating func flush() {
    guard !out.isEmpty else { return }
    shared.sink.write(out.storage.span)
    out.removeAll()
    if shared.sink.isBroken {
      shared.stop()
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
    shared.filesSearched.add(searcher.filesSearched, ordering: .relaxed)
    shared.bytesSearched.add(searcher.bytesSearched, ordering: .relaxed)
    shared.filesMatched.add(searcher.filesMatched, ordering: .relaxed)
    shared.linesMatched.add(searcher.linesMatched, ordering: .relaxed)
  }

  // MARK: - Directories

  private mutating func process(_ job: DirectoryJob) {
    var openPath = job.displayPath.isEmpty ? Array(".".utf8) : job.displayPath
    openPath.append(0)
    var info: Stat? = nil
    if let cache = job.cache {
      // A cheap stat decides whether the cached listing is still valid.
      let current: Stat
      do {
        current = try OS.stat(openPath.span)
      } catch {
        shared.report(job.displayPath, error)
        return
      }
      info = current
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
    if let cache = job.cache, let info {
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
        Diagnostics.error("File system loop found: \(String(decoding: job.displayPath, as: UTF8.self)) points to an ancestor")
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
          depth: entryDepth, ignore: level, ancestors: ancestors, cache: job.cache,
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
    if let overrides = shared.overrides {
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
      let nameStart = scratch.override.count
      for i in entry.nameRange {
        scratch.override.append(names[i])
      }
      // Overrides beat every other rule, including hidden files.
      switch overrides.match(scratch.override.span, nameStart: nameStart, isDirectory: isDirectory) {
      case .ignore: return false
      case .whitelist: return true
      case .none: if shared.overridesWhitelist && !isDirectory {
          return false
        }
      }
    }
    var whitelisted = false
    if let level, level.hasRules {
      let m: IgnoreMatch
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
      if m == .ignore {
        return false
      }
      if m == .whitelist {
        whitelisted = true
      }
    }
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
    var rgignore: IgnoreRules? = nil
    var dotIgnore: IgnoreRules? = nil
    var gitignore: IgnoreRules? = nil
    var gitExclude: IgnoreRules? = nil
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
          gitExclude = IgnoreRules(gitignore: data)
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
    let rules = IgnoreRules(gitignore: data)
    return rules.rules.isEmpty ? nil : rules
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

    if shared.settings.mode == .listFiles {
      searcher.list(displayScratch)
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
    let file: OpenFile
    do {
      file = try OS.open((path + [0]).span, .closeOnExec)
    } catch {
      shared.report(displayScratch, error)
      return
    }
    readAndSearch(file, size: size, regularFile: true, explicit: false)
  }

  private mutating func searchStandardInput() {
    displayScratch = Array("<stdin>".utf8)
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
