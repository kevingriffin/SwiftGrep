import Darwin
import GrepRegex
import System

public enum SwiftGrep {
  public static let version = "0.1.0"

  /// Runs `sg` with the given arguments (without the program name) and
  /// returns the exit status: 0 if something matched, 1 if nothing did, 2 on
  /// errors.
  public static func main(arguments: [String], output: Int32 = STDOUT_FILENO) async -> Int32 {
    OS.ignoreBrokenPipes()
    let config: Configuration
    do {
      switch try ArgumentParser.parse(arguments) {
      case .help:
        writeStdout(ArgumentParser.helpText + "\n")
        return 0
      case .version:
        writeStdout("sg \(version)\n")
        return 0
      case .pcre2Version:
        writeStdout("PCRE2 is not available in this build of SwiftGrep.\n")
        return 1
      case let .typeList(changes):
        let listing = try TypeMatcher.listing(changes)
        writeStdout(listing)
        return listing.isEmpty ? 1 : 0
      case let .generate(kind):
        writeStdout(Generator.output(kind))
        return 0
      case .clearCache:
        return ListingCache.clearAll()
      case let .search(c):
        config = c
      }
    } catch {
      Diagnostics.error(error.description)
      return 2
    }
    do {
      return try await search(config, output: output)
    } catch let error as UsageError {
      Diagnostics.error(error.description)
      return 2
    } catch let error as RegexError {
      Diagnostics.error(error.description)
      return 2
    } catch {
      Diagnostics.error("\(error)")
      return 2
    }
  }

  static func writeStdout(_ text: String) {
    try? OS.writeAll(.standardOutput, Array(text.utf8).span)
  }

  static func search(_ config: Configuration, output: Int32) async throws -> Int32 {
    let start = Clock.now
    let isTerminal = isatty(output) != 0
    let types = try TypeMatcher(config.typeChanges)
    let overrides = try makeOverrides(config)
    let commands = try FileCommands(config)

    // Like ripgrep, a search that can't match isn't run at all.
    let searching = config.mode != .listFiles
    if searching && (config.patterns.isEmpty && !config.invertMatch || config.maxCount == 0) {
      return 1
    }
    let matcher = try makeMatcher(config)

    // Roots.
    var jobs: [Job] = []
    var failedRoots = false
    var rootIsDirectory = false
    let walk = makeWalkOptions(config)
    let implicitPath = config.paths.isEmpty
    let readStandardInput = implicitPath && searching && !config.standardInputConsumed && isReadableStandardInput()
    if implicitPath {
      if readStandardInput {
        jobs.append(.standardInput)
      } else {
        jobs.append(.directory(rootJob(display: [], walk: walk, config: config)))
      }
    } else {
      for path in config.paths {
        if path == "-" {
          jobs.append(.standardInput)
          continue
        }
        let info: Stat
        do {
          info = try Stat(FilePath(path))
        } catch {
          if config.messages {
            Diagnostics.error("\(path): IO error for operation on \(path): \(error.message)")
          }
          failedRoots = true
          continue
        }
        if info.type == .directory {
          rootIsDirectory = true
          jobs.append(.directory(rootJob(display: Array(path.utf8), walk: walk, config: config)))
        } else {
          jobs.append(.file(displayPath: Array(path.utf8)))
        }
      }
    }

    // ripgrep's defaults depend on whether exactly one file is searched.
    let isOneFile = implicitPath ? readStandardInput : config.paths.count == 1 && !rootIsDirectory
    let onlyStandardInput = implicitPath ? readStandardInput : config.paths == ["-"]
    let settings = resolveSettings(config, isTerminal: isTerminal, isOneFile: isOneFile,
                                   onlyStandardInput: onlyStandardInput)

    // Files are separated by a blank line under --heading, and by the
    // context separator when context is shown.
    var fileSeparator: [UInt8]?
    if config.mode == .lines {
      if settings.heading {
        fileSeparator = []
      } else if config.context != .passthru && settings.hasContext {
        fileSeparator = config.contextSeparator
      }
    }
    // A single-threaded ripgrep (sorting) ends the separator with the line
    // terminator; its parallel output writer always uses `\n`.
    let separatorEnd = config.sort != nil ? settings.lineTerminatorBytes : [10]
    let sink = OutputSink(fd: FileDescriptor(rawValue: output), fileSeparator: fileSeparator.map { $0 + separatorEnd },
                          collectForSorting: config.sort != nil)

    // On APFS every open() goes through a kernel lock that is shared by all
    // processes. Measured on an M4 Max (16 cores) over nixpkgs, open
    // throughput peaks at 4-5 concurrent callers (~175k opens/s) and collapses
    // beyond 6 (16 threads are ~6x slower than 4, burning 30+ s of kernel time
    // spinning). Searching is cheap next to opening, so five workers is the
    // sweet spot; ripgrep's default of one thread per core lands on the cliff.
    let cores = max(1, Int(sysconf(Int32(_SC_NPROCESSORS_ONLN))))
    let workerCount = config.threads ?? min(cores, 5)

    let lineBuffered = switch config.buffering {
    case .auto: isTerminal
    case .line: true
    case .block: false
    }
    let run = SearchRun(
      settings: settings, matcher: matcher, walk: walk, overrides: overrides, types: types, sink: sink,
      queue: WorkQueue(jobs), flushEachFile: lineBuffered, separateFiles: fileSeparator != nil,
      sortOutput: config.sort != nil, quitAfterMatch: config.quiet && !config.stats, messages: config.messages,
      ignoreMessages: config.messages && config.ignoreMessages, implicitPath: implicitPath, commands: commands,
    )

    if config.debug {
      Diagnostics.error("debug: \(matcher.strategyDescription)")
      Diagnostics.error("debug: workers: \(workerCount), listing cache: \(config.useCache), case insensitive: \(matcher.isCaseInsensitive)")
    }

    await withDiscardingTaskGroup { group in
      for _ in 0..<workerCount {
        group.addTask {
          var worker = Worker(shared: run)
          await worker.run()
        }
      }
    }
    if let sort = config.sort {
      sink.finishSorted(by: sort)
    }
    for case let .directory(job) in jobs {
      job.root.cache?.save()
    }

    let totals = run.totals.withLock { $0 }
    if settings.stats && searching {
      let text = statistics(totals, json: config.mode == .json, total: Clock.now - start)
      // Like ripgrep's parallel output, the statistics follow the file
      // separator; sorted (single-threaded in ripgrep) output has none.
      if config.sort == nil {
        sink.writeFile(text.storage.span)
      } else {
        sink.write(text.storage.span)
      }
    }

    let matched = run.matched.load(ordering: .relaxed)
    let failed = run.failed.load(ordering: .relaxed) || failedRoots
    // Like ripgrep, an implicit search of the current directory that
    // filtered out every file is an error.
    if implicitPath, !readStandardInput, searching, totals.filesConsidered == 0 {
      if config.messages {
        Diagnostics.error("No files were searched, which means SwiftGrep probably applied a filter you didn't expect.")
      }
      return 2
    }
    if matched && (config.quiet || !failed) {
      return 0
    }
    return failed ? 2 : 1
  }

  private typealias Clock = ContinuousClock

  static func makeMatcher(_ config: Configuration) throws -> Matcher {
    if config.engine == .pcre2 {
      throw UsageError("PCRE2 is not available in this build of SwiftGrep")
    }
    var options = config.matcher
    options.captures = config.replacement != nil
    // Binary detection makes a NUL byte impossible to match.
    options.banNUL = config.binary != .text && options.lineTerminator != 0
    var patterns = config.mode == .listFiles ? [""] : config.patterns
    if patterns.isEmpty {
      // `-v -f /dev/null`: nothing matches, so every line is printed.
      options.fixedStrings = false
      patterns = ["[^\\x{0}-\\x{10FFFF}]"]
    }
    do {
      return try Matcher(patterns: patterns, options: options)
    } catch where config.engine == .auto {
      let divider = String(repeating: "~", count: 79)
      throw UsageError("regex could not be compiled with either the default regex engine or with PCRE2.\n\n"
        + "default regex engine error:\n\(divider)\n\(error.description)\n\(divider)\n\n"
        + "PCRE2 regex engine error:\nPCRE2 is not available in this build of SwiftGrep")
    }
  }

  /// The `--stats` summary, after a blank line (or a JSON `summary`).
  static func statistics(_ totals: SearchTotals, json: Bool, total: Duration) -> OutputBuffer {
    var out = OutputBuffer(capacity: 1024)
    if json {
      out.append("{\"data\":{\"elapsed_total\":")
      out.appendJSONDuration(nanoseconds: total.nanoseconds, sortedKeys: true)
      out.append(",\"stats\":{\"bytes_printed\":")
      out.appendDecimal(totals.bytesPrinted)
      out.append(",\"bytes_searched\":")
      out.appendDecimal(totals.bytesSearched)
      out.append(",\"elapsed\":")
      out.appendJSONDuration(nanoseconds: totals.nanoseconds, sortedKeys: true)
      out.append(",\"matched_lines\":")
      out.appendDecimal(totals.matchedLines)
      out.append(",\"matches\":")
      out.appendDecimal(totals.matches)
      out.append(",\"searches\":")
      out.appendDecimal(totals.filesSearched)
      out.append(",\"searches_with_match\":")
      out.appendDecimal(totals.filesMatched)
      out.append("}},\"type\":\"summary\"}\n")
    } else {
      out.append("\n")
      out.append("\(totals.matches) matches\n")
      out.append("\(totals.matchedLines) matched lines\n")
      out.append("\(totals.filesMatched) files contained matches\n")
      out.append("\(totals.filesSearched) files searched\n")
      out.append("\(totals.bytesPrinted) bytes printed\n")
      out.append("\(totals.bytesSearched) bytes searched\n")
      out.append(SecondsFormat.sixDecimals(nanoseconds: totals.nanoseconds) + " seconds spent searching\n")
      out.append(SecondsFormat.sixDecimals(nanoseconds: total.nanoseconds) + " seconds total\n")
    }
    return out
  }

  static func isReadableStandardInput() -> Bool {
    guard let info = try? FileDescriptor.standardInput.stat() else { return false }
    let type = info.type
    return type == .regular || type == .fifo || type == .socket
  }

  static func makeWalkOptions(_ config: Configuration) -> WalkOptions {
    var walk = WalkOptions()
    walk.hidden = config.hidden
    walk.followLinks = config.followLinks
    walk.maxDepth = config.maxDepth
    walk.maxFilesize = config.maxFilesize
    walk.oneFileSystem = config.oneFileSystem
    walk.ignore.useGitignore = !config.noIgnoreVCS
    walk.ignore.useGitExclude = !config.noIgnoreVCS && !config.noIgnoreExclude
    walk.ignore.useGlobalGitignore = !config.noIgnoreVCS && !config.noIgnoreGlobal
    walk.ignore.useDotIgnore = !config.noIgnoreDot
    walk.ignore.useRgignore = !config.noIgnoreDot
    walk.ignore.requireGit = !config.noRequireGit
    walk.ignore.caseInsensitive = config.ignoreFileCaseInsensitive
    walk.useIgnoreFiles = walk.ignore.useGitignore || walk.ignore.useDotIgnore
    if walk.ignore.useGlobalGitignore, let path = GitConfig.globalExcludesFile(),
       let data = try? FileIO.readWholeFile(path: path)
    {
      let rules = IgnoreRules(gitignore: data, caseInsensitive: config.ignoreFileCaseInsensitive)
      walk.ignore.global = rules.rules.isEmpty ? nil : rules
    }
    if !config.noIgnoreFiles {
      let messages = config.messages && config.ignoreMessages
      for path in config.ignoreFiles {
        do {
          let data = try FileIO.readWholeFile(path: path)
          var errors: [String] = []
          walk.explicitIgnores.append(IgnoreRules(gitignore: data, errors: &errors))
          if messages && !errors.isEmpty {
            Diagnostics.error(errors.map { "\(path): \($0)" }.joined(separator: "\n"))
          }
        } catch {
          if messages {
            Diagnostics.error("\(path): \(error.message)")
          }
        }
      }
    }
    return walk
  }

  /// A root directory job, with ignore rules from its parent directories.
  static func rootJob(display: [UInt8], walk: WalkOptions, config: Configuration) -> DirectoryJob {
    let openPath = display.isEmpty ? "." : String(decoding: display, as: UTF8.self)
    var absolute = Array(openPath.utf8)
    if let resolved = OS.realpath(openPath) {
      absolute = Array(resolved.utf8)
    }
    var level: IgnoreLevel?
    if walk.useIgnoreFiles && !config.noIgnoreParent {
      level = parentLevels(of: absolute, context: walk.ignore)
    }
    let cache = config.useCache ? ListingCache(root: absolute) : nil
    let device = config.oneFileSystem ? (try? Stat(FilePath(openPath)))?.deviceID.rawValue ?? 0 : 0
    return DirectoryJob(displayPath: display, absolutePath: absolute, depth: 0, ignore: level, ancestors: [],
                        root: SearchRoot(cache: cache, device: device))
  }

  /// Ignore levels for every ancestor of `path`, outermost first.
  static func parentLevels(of path: [UInt8], context: IgnoreContext) -> IgnoreLevel? {
    var ancestors: [[UInt8]] = []
    var current = path
    while let slash = current.lastIndex(of: UInt8(ascii: "/")) {
      current = Array(current[..<slash])
      ancestors.append(current.isEmpty ? [UInt8(ascii: "/")] : current)
      if current.isEmpty {
        break
      }
    }
    var level: IgnoreLevel?
    for directory in ancestors.reversed() {
      let base = directory == [UInt8(ascii: "/")] ? "" : String(decoding: directory, as: UTF8.self)
      func rules(_ name: String) -> IgnoreRules? {
        guard let data = try? FileIO.readWholeFile(path: base + "/" + name) else { return nil }
        let r = IgnoreRules(gitignore: data, caseInsensitive: context.caseInsensitive)
        return r.rules.isEmpty ? nil : r
      }
      let hasGit = (try? Stat(FilePath(base + "/.git"))) != nil
      let gitignore = context.useGitignore ? rules(".gitignore") : nil
      let dotIgnore = context.useDotIgnore ? rules(".ignore") : nil
      let rgignore = context.useRgignore ? rules(".rgignore") : nil
      let exclude = hasGit && context.useGitExclude ? rules(".git/info/exclude") : nil
      guard hasGit || gitignore != nil || dotIgnore != nil || rgignore != nil || exclude != nil else { continue }
      level = IgnoreLevel(parent: level, directory: Array((base + "/").utf8), rgignore: rgignore,
                          dotIgnore: dotIgnore, gitignore: gitignore, gitExclude: exclude, hasGit: hasGit)
    }
    return level
  }

  /// `--glob` rules. A plain glob whitelists and `!glob` excludes, the inverse
  /// of gitignore, so the rule's `negated` flag means "whitelist" here. Like
  /// ripgrep, every `--iglob` comes after every `--glob`.
  static func makeOverrides(_ config: Configuration) throws(UsageError) -> IgnoreRules? {
    guard !config.globs.isEmpty else { return nil }
    var rules: [IgnoreRule] = []
    for (pattern, insensitive) in config.globs.filter({ !$0.caseInsensitive }) + config.globs.filter(\.caseInsensitive) {
      let rule: IgnoreRule?
      do {
        rule = try IgnoreRules.parse(Array(pattern.utf8), caseInsensitive: insensitive || config.globCaseInsensitive,
                                     allowUnclosedClass: false)
      } catch {
        throw UsageError(error.message)
      }
      if let rule {
        rules.append(IgnoreRule(glob: rule.glob, negated: !rule.negated, directoryOnly: rule.directoryOnly))
      }
    }
    return IgnoreRules(rules: rules)
  }

  /// ripgrep's defaults for output, which depend on the terminal and on
  /// whether a single file is searched.
  static func resolveSettings(_ config: Configuration, isTerminal: Bool, isOneFile: Bool, onlyStandardInput: Bool)
    -> OutputSettings
  {
    let color: Bool = switch config.color {
    case .never: false
    case .always, .ansi: true
    case .auto:
      isTerminal && FileIO.environment("TERM").map { $0 != "dumb" } == true && FileIO.environment("NO_COLOR") == nil
    }
    let kind: ReportKind = if config.quiet {
      config.mode == .filesWithoutMatch ? .quietWithoutMatch : .quietWithMatch
    } else {
      switch config.mode {
      case .lines, .listFiles: .standard
      case .json: .json
      case .count: .count
      case .countMatches: .countMatches
      case .filesWithMatches: .pathWithMatch
      case .filesWithoutMatch: .pathWithoutMatch
      }
    }
    let column = config.column ?? config.vimgrep
    let lineNumbers = config.lineNumbers ?? {
      if config.quiet {
        return false
      }
      switch config.mode {
      case .lines: return isTerminal && !onlyStandardInput || column || config.vimgrep
      case .json: return true
      default: return false
      }
    }()
    let heading = switch config.heading {
    case nil: !config.vimgrep && isTerminal
    case true?: !config.vimgrep
    case false?: false
    }
    var hyperlinks = config.hyperlinkFormat
    if color, !hyperlinks.isEmpty {
      hyperlinks.host = Array(Hostname.lookup(command: config.hostnameBinary).utf8)
    }
    return OutputSettings(
      config, kind: kind, lineNumbers: lineNumbers, withFilename: config.withFilename ?? (config.vimgrep || !isOneFile),
      heading: heading, colors: color ? Palette(config.colors) : nil, hyperlinks: hyperlinks,
    )
  }
}
