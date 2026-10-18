import Darwin
import System
import GrepRegex

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
      case .typeList(let additions):
        writeStdout(try TypeMatcher.listing(additions: additions))
        return 0
      case .clearCache:
        return ListingCache.clearAll()
      case .search(let c):
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

    var matcherOptions = config.matcher
    let patterns = config.mode == .listFiles ? [""] : config.patterns
    if patterns.isEmpty {
      // `-f /dev/null`: nothing can match.
      matcherOptions.fixedStrings = false
    }
    let matcher = try Matcher(patterns: patterns.isEmpty ? ["[^\\x{0}-\\x{10FFFF}]"] : patterns, options: matcherOptions)

    // Roots.
    var jobs: [Job] = []
    var anyDirectory = false
    var failedRoots = false
    let walk = makeWalkOptions(config)
    if config.paths.isEmpty {
      if config.mode != .listFiles && isReadableStandardInput() {
        jobs.append(.standardInput)
      } else {
        anyDirectory = true
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
          Diagnostics.error("\(path): IO error for operation on \(path): \(error.message)")
          failedRoots = true
          continue
        }
        if info.type == .directory {
          anyDirectory = true
          jobs.append(.directory(rootJob(display: Array(path.utf8), walk: walk, config: config)))
        } else {
          jobs.append(.file(displayPath: Array(path.utf8)))
        }
      }
    }

    let settings = resolveSettings(config, isTerminal: isTerminal,
                                   multipleTargets: anyDirectory || jobs.count > 1)
    let overrides = makeOverrides(config)
    let types = config.types.isEmpty && config.typesNot.isEmpty ? nil
      : try TypeMatcher(select: config.types, negate: config.typesNot, additions: config.typeAdditions)

    let separateFiles = settings.heading || (settings.hasContext && settings.contextSeparator != nil
      && (settings.mode == .lines || settings.mode == .onlyMatching))
    let fileSeparator: [UInt8]? = settings.heading ? [10]
      : separateFiles ? (settings.contextSeparator ?? []) + [10] : nil
    let sink = OutputSink(fd: FileDescriptor(rawValue: output), fileSeparator: fileSeparator, collectForSorting: config.sort != .none)

    // On APFS every open() goes through a kernel lock that is shared by all
    // processes. Measured on an M4 Max (16 cores) over nixpkgs, open
    // throughput peaks at 4-5 concurrent callers (~175k opens/s) and collapses
    // beyond 6 (16 threads are ~6x slower than 4, burning 30+ s of kernel time
    // spinning). Searching is cheap next to opening, so five workers is the
    // sweet spot; ripgrep's default of one thread per core lands on the cliff.
    let cores = max(1, Int(sysconf(Int32(_SC_NPROCESSORS_ONLN))))
    let workerCount = config.threads ?? min(cores, 5)

    let run = SearchRun(
      settings: settings, matcher: matcher, walk: walk, overrides: overrides, types: types, sink: sink,
      queue: WorkQueue(jobs), flushEachFile: isTerminal, separateFiles: separateFiles,
      sortOutput: config.sort != .none)

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
    if config.sort != .none {
      sink.finishSorted(reverse: config.sort == .pathReverse)
    }
    for case .directory(let root) in jobs {
      root.cache?.save()
    }

    if config.stats {
      let elapsed = Clock.now - start
      let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
      var text = "\n"
      text += "\(run.linesMatched.load(ordering: .relaxed)) matched lines\n"
      text += "\(run.filesMatched.load(ordering: .relaxed)) files contained matches\n"
      text += "\(run.filesSearched.load(ordering: .relaxed)) files searched\n"
      text += "\(run.bytesSearched.load(ordering: .relaxed)) bytes searched\n"
      text += "\(String(format3(seconds))) seconds\n"
      try? OS.writeAll(FileDescriptor(rawValue: output), Array(text.utf8).span)
    }

    let matched = run.matched.load(ordering: .relaxed)
    let failed = run.failed.load(ordering: .relaxed) || failedRoots
    // Like ripgrep, an implicit search of the current directory that
    // filtered out every file is an error.
    if config.paths.isEmpty, anyDirectory, config.mode != .listFiles, !failed,
       run.filesSearched.load(ordering: .relaxed) == 0 {
      Diagnostics.error("No files were searched, which means SwiftGrep probably applied a filter you didn't expect.")
      return 2
    }
    if failed && !(config.mode == .quiet && matched) { return 2 }
    return matched ? 0 : 1
  }

  private typealias Clock = ContinuousClock


  private static func format3(_ value: Double) -> String {
    let millis = Int((value * 1000).rounded())
    let fraction = String(millis % 1000)
    return "\(millis / 1000)." + String(repeating: "0", count: 3 - fraction.count) + fraction
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
    walk.ignore.useGitignore = !config.noIgnoreVCS
    walk.ignore.useGitExclude = !config.noIgnoreVCS && !config.noIgnoreExclude
    walk.ignore.useGlobalGitignore = !config.noIgnoreVCS && !config.noIgnoreGlobal
    walk.ignore.useDotIgnore = !config.noIgnoreDot
    walk.ignore.useRgignore = !config.noIgnoreDot
    walk.ignore.requireGit = !config.noRequireGit
    walk.useIgnoreFiles = walk.ignore.useGitignore || walk.ignore.useDotIgnore
    if walk.ignore.useGlobalGitignore, let path = GitConfig.globalExcludesFile(),
       let data = try? FileIO.readWholeFile(path: path) {
      let rules = IgnoreRules(gitignore: data)
      walk.ignore.global = rules.rules.isEmpty ? nil : rules
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
    var level: IgnoreLevel? = nil
    if walk.useIgnoreFiles && !config.noIgnoreParent {
      level = parentLevels(of: absolute, context: walk.ignore)
    }
    let cache = config.useCache ? ListingCache(root: absolute) : nil
    return DirectoryJob(displayPath: display, absolutePath: absolute, depth: 0, ignore: level, ancestors: [], cache: cache)
  }

  /// Ignore levels for every ancestor of `path`, outermost first.
  static func parentLevels(of path: [UInt8], context: IgnoreContext) -> IgnoreLevel? {
    var ancestors: [[UInt8]] = []
    var current = path
    while let slash = current.lastIndex(of: UInt8(ascii: "/")) {
      current = Array(current[..<slash])
      ancestors.append(current.isEmpty ? [UInt8(ascii: "/")] : current)
      if current.isEmpty { break }
    }
    var level: IgnoreLevel? = nil
    for directory in ancestors.reversed() {
      let base = directory == [UInt8(ascii: "/")] ? "" : String(decoding: directory, as: UTF8.self)
      func rules(_ name: String) -> IgnoreRules? {
        guard let data = try? FileIO.readWholeFile(path: base + "/" + name) else { return nil }
        let r = IgnoreRules(gitignore: data)
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
  /// of gitignore, so the rule's `negated` flag means "whitelist" here.
  static func makeOverrides(_ config: Configuration) -> IgnoreRules? {
    guard !config.globs.isEmpty else { return nil }
    var rules: [IgnoreRule] = []
    for (pattern, insensitive) in config.globs {
      guard let rule = IgnoreRules.parse(Array(pattern.utf8), caseInsensitive: insensitive || config.globCaseInsensitive) else { continue }
      rules.append(IgnoreRule(glob: rule.glob, negated: !rule.negated, directoryOnly: rule.directoryOnly))
    }
    return IgnoreRules(rules: rules)
  }

  static func resolveSettings(_ config: Configuration, isTerminal: Bool, multipleTargets: Bool) -> OutputSettings {
    let color: Bool
    switch config.color {
    case .never: color = false
    case .always, .ansi: color = true
    case .auto: color = isTerminal && FileIO.environment("TERM") != "dumb"
    }
    let printsLines = config.mode == .lines || config.mode == .onlyMatching
    return OutputSettings(
      mode: config.mode,
      invert: config.invertMatch,
      lineNumbers: config.vimgrep || (config.lineNumbers ?? isTerminal),
      column: config.column || config.vimgrep,
      withFilename: config.vimgrep || (config.withFilename ?? multipleTargets),
      heading: printsLines && !config.vimgrep && (config.heading ?? isTerminal),
      color: color ? ColorSpec() : nil,
      nullAfterPath: config.nullAfterPath,
      vimgrep: config.vimgrep,
      before: config.beforeContext,
      after: config.afterContext,
      maxCount: config.maxCount,
      includeZero: config.includeZero,
      binary: config.binary,
      stripByteOrderMark: config.stripByteOrderMark,
      contextSeparator: config.contextSeparator)
  }
}
