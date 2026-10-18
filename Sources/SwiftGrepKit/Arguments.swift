import Darwin
import GrepRegex
import System

/// Generates a flag table from `@Spelling` annotations (see `SwiftGrepMacros`).
@attached(member, names: named(short), named(long), named(takesValue), named(byShort), named(byLong), named(optionsHelp))
macro CommandLineFlags() = #externalMacro(module: "SwiftGrepMacros", type: "CommandLineFlagsMacro")

/// A flag's short and long spellings, its value name and help.
@attached(peer)
macro Spelling(
  _ spellings: String..., value: String? = nil, help: String = "", aliases: [String] = [], hidden: Bool = false,
) = #externalMacro(module: "SwiftGrepMacros", type: "MarkerMacro")

/// Starts a section of `--help`.
@attached(peer)
macro Section(_ title: String) = #externalMacro(module: "SwiftGrepMacros", type: "MarkerMacro")

/// Command line flags, in ripgrep's spelling. Each flag is declared once;
/// `@CommandLineFlags` derives the lookup tables and the help text.
@CommandLineFlags
enum Flag {
  @Section("PATTERNS")
  @Spelling("-e", "--regexp", value: "PATTERN", help: "A pattern to search for (repeatable)")
  case regexp
  @Spelling("-f", "--file", value: "FILE", help: "Read patterns from FILE, one per line")
  case file
  @Spelling("-F", "--fixed-strings", help: "Treat patterns as literal strings")
  case fixedStrings
  @Spelling("-i", "--ignore-case", help: "Case insensitive search")
  case ignoreCase
  @Spelling("-S", "--smart-case", help: "Insensitive unless the pattern has uppercase")
  case smartCase
  @Spelling("-s", "--case-sensitive", help: "Case sensitive search (default)")
  case caseSensitive
  @Spelling("-w", "--word-regexp", help: "Only match whole words")
  case wordRegexp
  @Spelling("-x", "--line-regexp", help: "Only match whole lines")
  case lineRegexp
  @Spelling("-v", "--invert-match", help: "Select non-matching lines")
  case invertMatch

  @Section("OUTPUT")
  @Spelling("-c", "--count", help: "Count matching lines per file")
  case count
  @Spelling("--count-matches", help: "Count matches per file")
  case countMatches
  @Spelling("-l", "--files-with-matches", help: "Print paths of files with a match")
  case filesWithMatches
  @Spelling("--files-without-match", help: "Print paths of files without a match", aliases: ["files-without-matches"])
  case filesWithoutMatch
  @Spelling("-q", "--quiet", help: "Print nothing; exit 0 on the first match")
  case quiet
  @Spelling("-o", "--only-matching", help: "Print only the matched parts")
  case onlyMatching
  @Spelling("-n", "--line-number", help: "Show line numbers")
  case lineNumber
  @Spelling("-N", "--no-line-number", help: "Don't show line numbers")
  case noLineNumber
  @Spelling("--column", help: "Show the column of the first match")
  case column
  @Spelling("--no-column", help: "Don't show columns")
  case noColumn
  @Spelling("-H", "--with-filename", help: "Show the path with each match")
  case withFilename
  @Spelling("-I", "--no-filename", help: "Don't show paths")
  case noFilename
  @Spelling("--heading", help: "Group matches under each file's path")
  case heading
  @Spelling("--no-heading", help: "Show the path on every line")
  case noHeading
  @Spelling("--color", value: "WHEN", help: "never, auto, always, ansi", aliases: ["colour"])
  case color
  @Spelling("-p", "--pretty", help: "Alias for --color always --heading -n")
  case pretty
  @Spelling("-0", "--null", help: "Print NUL after file paths")
  case null
  @Spelling("--vimgrep", help: "path:line:column:text for every match")
  case vimgrep
  @Spelling("-A", "--after-context", value: "NUM", help: "Show NUM lines after each match")
  case afterContext
  @Spelling("-B", "--before-context", value: "NUM", help: "Show NUM lines before each match")
  case beforeContext
  @Spelling("-C", "--context", value: "NUM", help: "Show NUM lines around each match")
  case context
  @Spelling("--context-separator", value: "SEP", help: "Print SEP between context blocks")
  case contextSeparator
  @Spelling("--no-context-separator", help: "Don't separate context blocks")
  case noContextSeparator
  @Spelling("-m", "--max-count", value: "NUM", help: "Stop after NUM matching lines per file")
  case maxCount
  @Spelling("--include-zero", help: "Print zero counts with -c")
  case includeZero
  @Spelling("--stats", help: "Print statistics at the end")
  case stats
  @Spelling("--sort", value: "path", help: "Sort output by path (the search stays parallel)")
  case sort
  @Spelling("--sortr", value: "path", help: "Sort output by path, descending")
  case sortReverse

  @Section("FILES")
  @Spelling("--files", help: "List files that would be searched")
  case files
  @Spelling("-g", "--glob", value: "GLOB", help: "Include (or with !, exclude) matching paths")
  case glob
  @Spelling("--iglob", value: "GLOB", help: "Case insensitive --glob")
  case iglob
  @Spelling("--glob-case-insensitive", help: "Treat all globs as case insensitive")
  case globCaseInsensitive
  @Spelling("-t", "--type", value: "TYPE", help: "Only search files of TYPE")
  case type
  @Spelling("-T", "--type-not", value: "TYPE", help: "Don't search files of TYPE")
  case typeNot
  @Spelling("--type-add", value: "TYPE:GLOB", help: "Define a file type")
  case typeAdd
  @Spelling("--type-list", help: "Show all file types")
  case typeList
  @Spelling("-.", "--hidden", help: "Search hidden files and directories")
  case hidden
  @Spelling("--no-hidden", help: "Skip hidden files (default)")
  case noHidden
  @Spelling("--no-ignore", help: "Don't use ignore files")
  case noIgnore
  @Spelling("--no-ignore-vcs", help: "Don't use .gitignore and git excludes")
  case noIgnoreVCS
  @Spelling("--no-ignore-dot", help: "Don't use .ignore and .rgignore")
  case noIgnoreDot
  @Spelling("--no-ignore-parent", help: "Don't use ignore files in parent directories")
  case noIgnoreParent
  @Spelling("--no-ignore-global", help: "Don't use the global git excludes file")
  case noIgnoreGlobal
  @Spelling("--no-ignore-exclude", help: "Don't use .git/info/exclude")
  case noIgnoreExclude
  @Spelling("--no-require-git", help: "Use .gitignore outside git repositories too")
  case noRequireGit
  @Spelling("-u", "--unrestricted", help: "-u: --no-ignore, -uu: +--hidden, -uuu: +--binary")
  case unrestricted
  @Spelling("-L", "--follow", help: "Follow symbolic links")
  case follow
  @Spelling("-d", "--max-depth", value: "NUM", help: "Descend at most NUM directories", aliases: ["maxdepth"])
  case maxDepth
  @Spelling("--max-filesize", value: "NUM[KMG]", help: "Skip larger files")
  case maxFilesize
  @Spelling("-a", "--text", help: "Search binary files as text")
  case text
  @Spelling("--binary", help: "Search binary files found while walking")
  case binary
  @Spelling("-E", "--encoding", value: "ENC", help: "auto or utf-8 (skip a UTF-8 byte order mark, the default), or none")
  case encoding
  @Spelling("--no-encoding", help: "Same as --encoding auto")
  case noEncoding

  @Section("PERFORMANCE")
  @Spelling("-j", "--threads", value: "NUM", help: "Number of search workers (default: 5, the APFS open() sweet spot)")
  case threads
  @Spelling("--no-cache", help: "Don't use the directory listing cache (also: SG_NO_CACHE=1 in the environment)")
  case noCache
  @Spelling("--clear-cache", help: "Delete all cached directory listings")
  case clearCache
  @Spelling("--debug", help: "Print the search strategy to stderr")
  case debug
  @Spelling("--mmap", hidden: true)
  case mmap
  @Spelling("--no-mmap", hidden: true)
  case noMmap

  @Section("OTHER")
  @Spelling("-h", "--help", help: "Show this help")
  case help
  @Spelling("-V", "--version", help: "Show the version")
  case version
}

/// The result of parsing the command line.
public enum Command: Sendable {
  case search(Configuration)
  case help
  case version
  case typeList([String])
  case clearCache
}

public enum ArgumentParser {
  public static func parse(_ arguments: [String]) throws(UsageError) -> Command {
    var config = Configuration()
    var positional: [String] = []
    var explicitPatterns: [String]? = nil
    var unrestricted = 0
    var wantsTypeList = false
    var i = 0

    func number(_ value: String, _ flag: Flag) throws(UsageError) -> Int {
      guard let n = Int(value), n >= 0 else { throw UsageError("invalid value '\(value)' for --\(flag.long): expected a non-negative integer") }
      return n
    }

    func apply(_ flag: Flag, _ value: String?) throws(UsageError) -> Command? {
      let v = value ?? ""
      switch flag {
      case .regexp: explicitPatterns = (explicitPatterns ?? []) + [v]
      case .file:
        let data: [UInt8]
        do {
          data = v == "-" ? try FileIO.readWholeFile(.standardInput) : try FileIO.readWholeFile(path: v)
        } catch {
          throw UsageError("\(v): \(error.message)")
        }
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map {
          $0.hasSuffix("\r") ? String($0.dropLast()) : String($0)
        }
        if lines.last == "" {
          lines.removeLast()
        }
        explicitPatterns = (explicitPatterns ?? []) + lines
      case .fixedStrings: config.matcher.fixedStrings = true
      case .ignoreCase: config.matcher.caseMode = .insensitive
      case .smartCase: config.matcher.caseMode = .smart
      case .caseSensitive: config.matcher.caseMode = .sensitive
      case .wordRegexp: config.matcher.wordRegexp = true
      case .lineRegexp: config.matcher.lineRegexp = true
      case .invertMatch: config.invertMatch = true
      case .count: config.mode = .count
      case .countMatches: config.mode = .countMatches
      case .filesWithMatches: config.mode = .filesWithMatches
      case .filesWithoutMatch: config.mode = .filesWithoutMatch
      case .quiet: config.mode = .quiet
      case .onlyMatching: config.mode = .onlyMatching
      case .lineNumber: config.lineNumbers = true
      case .noLineNumber: config.lineNumbers = false
      case .column: config.column = true
      case .noColumn: config.column = false
      case .withFilename: config.withFilename = true
      case .noFilename: config.withFilename = false
      case .heading: config.heading = true
      case .noHeading: config.heading = false
      case .color:
        switch v {
        case "never": config.color = .never
        case "auto": config.color = .auto
        case "always": config.color = .always
        case "ansi": config.color = .ansi
        default: throw UsageError("invalid value '\(v)' for --color: expected never, auto, always or ansi")
        }
      case .null: config.nullAfterPath = true
      case .vimgrep: config.vimgrep = true
      case .pretty:
        config.color = .always
        config.heading = true
        config.lineNumbers = true
      case .afterContext: config.afterContext = try number(v, flag)
      case .beforeContext: config.beforeContext = try number(v, flag)
      case .context:
        let n = try number(v, flag)
        config.afterContext = n
        config.beforeContext = n
      case .maxCount: config.maxCount = try number(v, flag)
      case .includeZero: config.includeZero = true
      case .stats: config.stats = true
      case .contextSeparator: config.contextSeparator = Array(v.utf8)
      case .noContextSeparator: config.contextSeparator = nil
      case .files: config.mode = .listFiles
      case .glob: config.globs.append((v, false))
      case .iglob: config.globs.append((v, true))
      case .globCaseInsensitive: config.globCaseInsensitive = true
      case .type: config.types.append(v)
      case .typeNot: config.typesNot.append(v)
      case .typeAdd: config.typeAdditions.append(v)
      case .typeList: wantsTypeList = true
      case .hidden: config.hidden = true
      case .noHidden: config.hidden = false
      case .noIgnore: config.noIgnore = true
      case .noIgnoreVCS: config.noIgnoreVCS = true
      case .noIgnoreDot: config.noIgnoreDot = true
      case .noIgnoreParent: config.noIgnoreParent = true
      case .noIgnoreGlobal: config.noIgnoreGlobal = true
      case .noIgnoreExclude: config.noIgnoreExclude = true
      case .noRequireGit: config.noRequireGit = true
      case .unrestricted:
        unrestricted += 1
        if unrestricted >= 1 {
          config.noIgnore = true
        }
        if unrestricted >= 2 {
          config.hidden = true
        }
        if unrestricted >= 3 {
          config.binary = .search
        }
      case .follow: config.followLinks = true
      case .maxDepth: config.maxDepth = try number(v, flag)
      case .maxFilesize: config.maxFilesize = try parseSize(v)
      case .text: config.binary = .text
      case .binary: config.binary = .search
      case .encoding:
        // Only UTF-8 is supported, where ripgrep's encodings differ just in
        // whether a byte order mark is skipped.
        switch v.lowercased() {
        case "auto", "utf-8", "utf8": config.stripByteOrderMark = true
        case "none": config.stripByteOrderMark = false
        default: throw UsageError("unsupported --encoding value '\(v)' (supported: auto, none, utf-8)")
        }
      case .noEncoding: config.stripByteOrderMark = true
      case .sort, .sortReverse:
        switch v {
        case "path": config.sort = flag == .sort ? .path : .pathReverse
        case "none": config.sort = .none
        default: throw UsageError("unsupported --\(flag.long) value '\(v)' (supported: path, none)")
        }
      case .threads:
        let n = try number(v, flag)
        config.threads = n == 0 ? nil : n
      case .noCache: config.useCache = false
      case .clearCache: return .clearCache
      case .debug: config.debug = true
      case .mmap, .noMmap: break
      case .help: return .help
      case .version: return .version
      }
      return nil
    }

    var onlyPositional = false
    while i < arguments.count {
      let argument = arguments[i]
      i += 1
      if onlyPositional || argument == "-" || !argument.hasPrefix("-") {
        positional.append(argument)
        continue
      }
      if argument == "--" {
        onlyPositional = true
        continue
      }
      if argument.hasPrefix("--") {
        var name = String(argument.dropFirst(2))
        var value: String? = nil
        if let eq = name.firstIndex(of: "=") {
          value = String(name[name.index(after: eq)...])
          name = String(name[..<eq])
        }
        guard let flag = Flag.byLong[name] else { throw UsageError("unrecognized flag --\(name)") }
        if flag.takesValue {
          if value == nil {
            guard i < arguments.count else { throw UsageError("flag --\(name) requires a value") }
            value = arguments[i]
            i += 1
          }
        } else if value != nil {
          throw UsageError("flag --\(name) does not take a value")
        }
        if let command = try apply(flag, value) {
          return command
        }
        continue
      }
      // A cluster of short flags, e.g. -inC2.
      let chars = Array(argument.dropFirst())
      var j = 0
      while j < chars.count {
        let c = chars[j]
        j += 1
        guard let flag = Flag.byShort[c] else { throw UsageError("unrecognized flag -\(c)") }
        var value: String? = nil
        if flag.takesValue {
          if j < chars.count {
            var rest = String(chars[j...])
            if rest.hasPrefix("=") {
              rest.removeFirst()
            }
            value = rest
            j = chars.count
          } else {
            guard i < arguments.count else { throw UsageError("flag -\(c) requires a value") }
            value = arguments[i]
            i += 1
          }
        }
        if let command = try apply(flag, value) {
          return command
        }
      }
    }

    if wantsTypeList {
      return .typeList(config.typeAdditions)
    }
    if let explicitPatterns {
      config.patterns = explicitPatterns
    } else if config.mode != .listFiles {
      guard !positional.isEmpty else {
        throw UsageError("ripgrep-compatible usage: sg [OPTIONS] PATTERN [PATH ...]\n\nTry 'sg --help' for more information.")
      }
      config.patterns = [positional.removeFirst()]
    }
    config.paths = positional
    return .search(config)
  }

  static func parseSize(_ text: String) throws(UsageError) -> Int64 {
    var digits = text
    var multiplier: Int64 = 1
    switch text.last?.uppercased() {
    case "K": multiplier = 1 << 10
    case "M": multiplier = 1 << 20
    case "G": multiplier = 1 << 30
    default: break
    }
    if multiplier > 1 {
      digits.removeLast()
    }
    guard let n = Int64(digits), n >= 0 else { throw UsageError("invalid --max-filesize value '\(text)'") }
    return n * multiplier
  }

  public static let helpText = """
  SwiftGrep (sg) — a ripgrep-compatible recursive search tool, tuned for APFS.

  USAGE:
      sg [OPTIONS] PATTERN [PATH ...]
      sg [OPTIONS] -e PATTERN ... [PATH ...]
      sg [OPTIONS] --files [PATH ...]

  """ + "\n" + Flag.optionsHelp + "\n"
}
