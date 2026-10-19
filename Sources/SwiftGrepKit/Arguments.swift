import Darwin
import GrepRegex
import System

/// Generates a flag table from `@Spelling` annotations (see `SwiftGrepMacros`).
@attached(
  member,
  names: named(short), named(long), named(negation), named(takesValue), named(valueName), named(help), named(aliases),
  named(section), named(isHidden), named(declared), named(byShort), named(byLong), named(byNegation), named(optionsHelp)
)
macro CommandLineFlags() = #externalMacro(module: "SwiftGrepMacros", type: "CommandLineFlagsMacro")

/// A flag's short and long spellings, the spelling that turns it off, its
/// value name and help.
@attached(peer)
macro Spelling(
  _ spellings: String..., value: String? = nil, negation: String? = nil, help: String = "", aliases: [String] = [],
  hidden: Bool = false,
) = #externalMacro(module: "SwiftGrepMacros", type: "MarkerMacro")

/// Starts a section of `--help`.
@attached(peer)
macro Section(_ title: String) = #externalMacro(module: "SwiftGrepMacros", type: "MarkerMacro")

/// Command line flags, in ripgrep's spelling. Each flag is declared once;
/// `@CommandLineFlags` derives the lookup tables and the help text.
@CommandLineFlags
enum Flag {
  @Section("INPUT")
  @Spelling("-e", "--regexp", value: "PATTERN", help: "A pattern to search for (repeatable)")
  case regexp
  @Spelling("-f", "--file", value: "PATTERNFILE", help: "Read patterns from a file, one per line (- for stdin)")
  case file
  @Spelling("--pre", value: "COMMAND", negation: "--no-pre", help: "Search the output of COMMAND FILE for each file")
  case pre
  @Spelling("--pre-glob", value: "GLOB", help: "Only run --pre on files matching GLOB (repeatable)")
  case preGlob
  @Spelling("-z", "--search-zip", negation: "--no-search-zip", help: "Search in compressed files (gzip, bzip2, xz, ...)")
  case searchZip

  @Section("SEARCH")
  @Spelling("-s", "--case-sensitive", help: "Case sensitive search (default)")
  case caseSensitive
  @Spelling("-i", "--ignore-case", help: "Case insensitive search")
  case ignoreCase
  @Spelling("-S", "--smart-case", help: "Insensitive unless the pattern has uppercase")
  case smartCase
  @Spelling("-F", "--fixed-strings", negation: "--no-fixed-strings", help: "Treat patterns as literal strings")
  case fixedStrings
  @Spelling("-w", "--word-regexp", help: "Only match whole words")
  case wordRegexp
  @Spelling("-x", "--line-regexp", help: "Only match whole lines")
  case lineRegexp
  @Spelling("-v", "--invert-match", negation: "--no-invert-match", help: "Select non-matching lines")
  case invertMatch
  @Spelling("-m", "--max-count", value: "NUM", help: "Stop after NUM matching lines per file")
  case maxCount
  @Spelling("--stop-on-nonmatch", help: "Stop a file at the first non-matching line after a match")
  case stopOnNonmatch
  @Spelling("-U", "--multiline", negation: "--no-multiline", help: "Let matches span lines")
  case multiline
  @Spelling("--multiline-dotall", negation: "--no-multiline-dotall", help: "Let . match line terminators with -U")
  case multilineDotall
  @Spelling("--crlf", negation: "--no-crlf", help: "Treat CRLF as a line terminator")
  case crlf
  @Spelling("--null-data", help: "Use NUL as the line terminator")
  case nullData
  @Spelling("--no-unicode", negation: "--unicode", help: "Disable Unicode mode in patterns")
  case noUnicode
  @Spelling("-a", "--text", negation: "--no-text", help: "Search binary files as text")
  case text
  @Spelling("-E", "--encoding", value: "ENCODING", negation: "--no-encoding",
            help: "auto or utf-8 (skip a UTF-8 byte order mark, the default), or none")
  case encoding
  @Spelling("--engine", value: "ENGINE", help: "default or auto (PCRE2 is not available)")
  case engine
  @Spelling("-P", "--pcre2", negation: "--no-pcre2", help: "Use PCRE2 (not available)")
  case pcre2
  @Spelling("--auto-hybrid-regex", negation: "--no-auto-hybrid-regex", help: "Same as --engine auto", hidden: true)
  case autoHybridRegex
  @Spelling("--no-pcre2-unicode", negation: "--pcre2-unicode", help: "Same as --no-unicode", hidden: true)
  case noPCRE2Unicode
  @Spelling("--dfa-size-limit", value: "NUM+SUFFIX?", help: "The lazy DFA's cache size per worker")
  case dfaSizeLimit
  @Spelling("--regex-size-limit", value: "NUM+SUFFIX?", help: "The size limit of a compiled pattern")
  case regexSizeLimit

  @Section("FILTER")
  @Spelling("-g", "--glob", value: "GLOB", help: "Include (or with !, exclude) matching paths")
  case glob
  @Spelling("--iglob", value: "GLOB", help: "Case insensitive --glob")
  case iglob
  @Spelling("--glob-case-insensitive", negation: "--no-glob-case-insensitive", help: "Treat all globs as case insensitive")
  case globCaseInsensitive
  @Spelling("-t", "--type", value: "TYPE", help: "Only search files of TYPE")
  case type
  @Spelling("-T", "--type-not", value: "TYPE", help: "Don't search files of TYPE")
  case typeNot
  @Spelling("--type-add", value: "TYPESPEC", help: "Define a file type (TYPE:GLOB or TYPE:include:TYPE,...)")
  case typeAdd
  @Spelling("--type-clear", value: "TYPE", help: "Remove a file type's globs")
  case typeClear
  @Spelling("-.", "--hidden", negation: "--no-hidden", help: "Search hidden files and directories")
  case hidden
  @Spelling("-L", "--follow", negation: "--no-follow", help: "Follow symbolic links")
  case follow
  @Spelling("-d", "--max-depth", value: "NUM", help: "Descend at most NUM directories", aliases: ["maxdepth"])
  case maxDepth
  @Spelling("--max-filesize", value: "NUM+SUFFIX?", help: "Skip files larger than NUM bytes (K, M or G)")
  case maxFilesize
  @Spelling("--binary", negation: "--no-binary", help: "Search binary files found while walking")
  case binary
  @Spelling("--ignore-file", value: "PATH", help: "Use another ignore file, at the lowest precedence (repeatable)")
  case ignoreFile
  @Spelling("--ignore-file-case-insensitive", negation: "--no-ignore-file-case-insensitive",
            help: "Match ignore file globs case insensitively")
  case ignoreFileCaseInsensitive
  @Spelling("--no-ignore", negation: "--ignore", help: "Don't use ignore files")
  case noIgnore
  @Spelling("--no-ignore-dot", negation: "--ignore-dot", help: "Don't use .ignore and .rgignore")
  case noIgnoreDot
  @Spelling("--no-ignore-exclude", negation: "--ignore-exclude", help: "Don't use .git/info/exclude")
  case noIgnoreExclude
  @Spelling("--no-ignore-files", negation: "--ignore-files", help: "Don't use --ignore-file files")
  case noIgnoreFiles
  @Spelling("--no-ignore-global", negation: "--ignore-global", help: "Don't use the global git excludes file")
  case noIgnoreGlobal
  @Spelling("--no-ignore-parent", negation: "--ignore-parent", help: "Don't use ignore files in parent directories")
  case noIgnoreParent
  @Spelling("--no-ignore-vcs", negation: "--ignore-vcs", help: "Don't use .gitignore and git excludes")
  case noIgnoreVCS
  @Spelling("--no-require-git", negation: "--require-git", help: "Use .gitignore outside git repositories too")
  case noRequireGit
  @Spelling("--one-file-system", negation: "--no-one-file-system", help: "Don't descend into other file systems")
  case oneFileSystem
  @Spelling("-u", "--unrestricted", help: "-u: --no-ignore, -uu: +--hidden, -uuu: +--binary")
  case unrestricted

  @Section("OUTPUT")
  @Spelling("-A", "--after-context", value: "NUM", help: "Show NUM lines after each match")
  case afterContext
  @Spelling("-B", "--before-context", value: "NUM", help: "Show NUM lines before each match")
  case beforeContext
  @Spelling("-C", "--context", value: "NUM", help: "Show NUM lines around each match")
  case context
  @Spelling("--context-separator", value: "SEPARATOR", negation: "--no-context-separator",
            help: "Print SEPARATOR between context blocks")
  case contextSeparator
  @Spelling("--passthru", help: "Print matching and non-matching lines", aliases: ["passthrough"])
  case passthru
  @Spelling("--color", value: "WHEN", help: "never, auto, always or ansi")
  case color
  @Spelling("--colors", value: "COLOR_SPEC", help: "Set a color, e.g. match:fg:magenta (repeatable)")
  case colors
  @Spelling("-p", "--pretty", help: "Alias for --color always --heading -n")
  case pretty
  @Spelling("-n", "--line-number", help: "Show line numbers")
  case lineNumber
  @Spelling("-N", "--no-line-number", help: "Don't show line numbers")
  case noLineNumber
  @Spelling("--column", negation: "--no-column", help: "Show the column of the first match (implies -n)")
  case column
  @Spelling("-b", "--byte-offset", negation: "--no-byte-offset", help: "Show the byte offset of each line")
  case byteOffset
  @Spelling("-H", "--with-filename", help: "Show the path with each match")
  case withFilename
  @Spelling("-I", "--no-filename", help: "Don't show paths")
  case noFilename
  @Spelling("--heading", negation: "--no-heading", help: "Group matches under each file's path")
  case heading
  @Spelling("-0", "--null", help: "Print NUL after file paths")
  case null
  @Spelling("--path-separator", value: "SEPARATOR", help: "Print SEPARATOR instead of / in paths")
  case pathSeparator
  @Spelling("--field-context-separator", value: "SEPARATOR", help: "Separate fields of context lines (default -)")
  case fieldContextSeparator
  @Spelling("--field-match-separator", value: "SEPARATOR", help: "Separate fields of matching lines (default :)")
  case fieldMatchSeparator
  @Spelling("-o", "--only-matching", help: "Print only the matched parts")
  case onlyMatching
  @Spelling("-r", "--replace", value: "REPLACEMENT", help: "Print matches replaced (with $1, ${name}, $$)")
  case replace
  @Spelling("--vimgrep", help: "path:line:column:text for every match")
  case vimgrep
  @Spelling("-M", "--max-columns", value: "NUM", help: "Omit lines longer than NUM bytes")
  case maxColumns
  @Spelling("--max-columns-preview", negation: "--no-max-columns-preview", help: "Show the start of omitted lines")
  case maxColumnsPreview
  @Spelling("--trim", negation: "--no-trim", help: "Remove leading whitespace from lines")
  case trim
  @Spelling("--include-zero", negation: "--no-include-zero", help: "Print zero counts with -c")
  case includeZero
  @Spelling("-q", "--quiet", help: "Print nothing; exit 0 on the first match")
  case quiet
  @Spelling("--hyperlink-format", value: "FORMAT", help: "Link paths, e.g. default, vscode or file://{host}{path}")
  case hyperlinkFormat
  @Spelling("--hostname-bin", value: "COMMAND", help: "Run COMMAND for the {host} of hyperlinks")
  case hostnameBin
  @Spelling("--line-buffered", negation: "--no-line-buffered", help: "Write each file's output at once")
  case lineBuffered
  @Spelling("--block-buffered", negation: "--no-block-buffered", help: "Write output in large blocks")
  case blockBuffered
  @Spelling("--sort", value: "SORTBY", help: "path, modified, accessed, created or none")
  case sort
  @Spelling("--sortr", value: "SORTBY", help: "Like --sort, descending")
  case sortReverse
  @Spelling("--sort-files", negation: "--no-sort-files", help: "Same as --sort path", hidden: true)
  case sortFiles

  @Section("OUTPUT MODES")
  @Spelling("-c", "--count", help: "Count matching lines per file")
  case count
  @Spelling("--count-matches", help: "Count matches per file")
  case countMatches
  @Spelling("-l", "--files-with-matches", help: "Print paths of files with a match")
  case filesWithMatches
  @Spelling("--files-without-match", help: "Print paths of files without a match")
  case filesWithoutMatch
  @Spelling("--json", negation: "--no-json", help: "Print results as JSON Lines")
  case json

  @Section("LOGGING")
  @Spelling("--debug", help: "Print the search strategy to stderr")
  case debug
  @Spelling("--trace", help: "Same as --debug")
  case trace
  @Spelling("--no-messages", negation: "--messages", help: "Don't print error messages")
  case noMessages
  @Spelling("--no-ignore-messages", negation: "--ignore-messages", help: "Don't report problems with ignore files")
  case noIgnoreMessages
  @Spelling("--stats", negation: "--no-stats", help: "Print statistics at the end")
  case stats

  @Section("OTHER")
  @Spelling("--files", help: "List files that would be searched")
  case files
  @Spelling("--type-list", help: "Show all file types")
  case typeList
  @Spelling("--generate", value: "KIND", help: "man, complete-bash, complete-zsh, complete-fish or complete-powershell")
  case generate
  @Spelling("--no-config", help: "Don't read the file named by RIPGREP_CONFIG_PATH")
  case noConfig
  @Spelling("--pcre2-version", help: "Print the PCRE2 version (not available)")
  case pcre2Version
  @Spelling("-h", "--help", help: "Show this help")
  case help
  @Spelling("-V", "--version", help: "Show the version")
  case version

  @Section("PERFORMANCE")
  @Spelling("-j", "--threads", value: "NUM", help: "Number of search workers (default: 5, the APFS open() sweet spot)")
  case threads
  @Spelling("--no-cache", help: "Don't use the directory listing cache (also: SG_NO_CACHE=1 in the environment)")
  case noCache
  @Spelling("--clear-cache", help: "Delete all cached directory listings")
  case clearCache
  @Spelling("--mmap", negation: "--no-mmap", help: "Accepted; files over 4 MB are always mapped", hidden: true)
  case mmap
}

/// The result of parsing the command line.
public enum Command: Sendable {
  case search(Configuration)
  case help
  case version
  case pcre2Version
  case typeList([TypeChange])
  case generate(GenerateKind)
  case clearCache
}

public enum ArgumentParser {
  /// Parses the arguments, preceded by those in the file named by
  /// `RIPGREP_CONFIG_PATH` (unless `--no-config` is given), as ripgrep does.
  public static func parse(_ arguments: [String]) throws(UsageError) -> Command {
    try parse(arguments, environment: FileIO.environment)
  }

  static func parse(_ arguments: [String], environment: (String) -> String?) throws(UsageError) -> Command {
    var first = ArgumentState()
    try first.parse(arguments)
    if let special = first.special {
      return special
    }
    guard !first.noConfig, let path = environment("RIPGREP_CONFIG_PATH"), !path.isEmpty else {
      return try first.finish()
    }
    let configArguments = ConfigFile.arguments(path: path, messages: first.config.messages)
    guard !configArguments.isEmpty else { return try first.finish() }
    var state = ArgumentState()
    try state.parse(configArguments + arguments)
    if let special = state.special {
      return special
    }
    return try state.finish()
  }

  /// ripgrep's parser for human readable sizes: digits and an optional K, M
  /// or G suffix.
  static func parseSize(_ text: String) throws(UsageError) -> Int64 {
    var digits = Substring(text)
    var shift: Int64 = 0
    switch digits.last {
    case "K": shift = 10
    case "M": shift = 20
    case "G": shift = 30
    default: break
    }
    if shift > 0 {
      digits.removeLast()
    }
    guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else {
      throw UsageError("invalid size: invalid format for size '\(text)', which should be a non-empty sequence of "
        + "digits followed by an optional 'K', 'M' or 'G' suffix")
    }
    guard let value = UInt64(digits), value <= UInt64(Int64.max) else {
      throw UsageError("invalid size: invalid integer found in size '\(text)': number too large to fit in target type")
    }
    let (bytes, overflow) = Int64(value).multipliedReportingOverflow(by: 1 << shift)
    guard !overflow else { throw UsageError("invalid size: size '\(text)' is too big") }
    return bytes
  }

  /// Rust's integer parsing messages, which ripgrep reports for bad numbers.
  static func parseNumber(_ text: String) throws(UsageError) -> Int {
    guard !text.isEmpty else {
      throw UsageError("value is not a valid number: cannot parse integer from empty string")
    }
    let digits = text.hasPrefix("+") ? text.dropFirst() : Substring(text)
    guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else {
      throw UsageError("value is not a valid number: invalid digit found in string")
    }
    guard let n = Int(digits) else {
      throw UsageError("value is not a valid number: number too large to fit in target type")
    }
    return n
  }

  /// ripgrep's escapes for separators: `\t`, `\n`, `\r`, `\0`, `\\` and
  /// `\xNN`; anything else is kept as it is.
  static func unescape(_ text: String) -> [UInt8] {
    let bytes = Array(text.utf8)
    var result: [UInt8] = []
    var i = 0
    func hexValue(_ byte: UInt8) -> UInt8? {
      switch byte {
      case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
      case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
      case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
      default: nil
      }
    }
    while i < bytes.count {
      guard bytes[i] == UInt8(ascii: "\\"), i + 1 < bytes.count else {
        result.append(bytes[i])
        i += 1
        continue
      }
      switch bytes[i + 1] {
      case UInt8(ascii: "\\"): result.append(UInt8(ascii: "\\"))
      case UInt8(ascii: "n"): result.append(10)
      case UInt8(ascii: "r"): result.append(13)
      case UInt8(ascii: "t"): result.append(9)
      case UInt8(ascii: "0"): result.append(0)
      case UInt8(ascii: "x") where i + 3 < bytes.count:
        if let high = hexValue(bytes[i + 2]), let low = hexValue(bytes[i + 3]) {
          result.append(high << 4 | low)
          i += 4
          continue
        }
        result.append(contentsOf: bytes[i...(i + 1)])
      default:
        result.append(contentsOf: bytes[i...(i + 1)])
      }
      i += 2
    }
    return result
  }

  public static let helpText = """
  SwiftGrep (sg) — a ripgrep-compatible recursive search tool, tuned for APFS.

  USAGE:
      sg [OPTIONS] PATTERN [PATH ...]
      sg [OPTIONS] -e PATTERN ... [PATH ...]
      sg [OPTIONS] --files [PATH ...]

  Switches are turned off again by their negation, as in ripgrep
  (--no-heading, --no-fixed-strings, --ignore-vcs, ...).

  """ + "\n" + Flag.optionsHelp + "\n"
}

/// Where patterns come from, in command line order.
private enum PatternSource {
  case pattern(String)
  case file(String)
}

/// A flag's value: a switch turned on or off (by its negation), or a value.
private enum FlagValue {
  case on
  case off
  case value(String)
}

/// ripgrep's "low-level arguments": the flags as given, before defaults are
/// resolved.
private struct ArgumentState {
  var config = Configuration()
  var positional: [String] = []
  var patterns: [PatternSource] = []
  var special: Command?
  var mode = Mode.search(.lines)
  var unrestricted = 0
  var noConfig = false

  enum Mode {
    case search(OutputMode)
    case files
    case typeList
    case generate(GenerateKind)
  }

  /// Parses arguments like lexopt: `--name=value`, short clusters such as
  /// `-niC1` (the rest of a cluster is a value, after an optional `=`), and
  /// `--` before positional arguments.
  mutating func parse(_ arguments: [String]) throws(UsageError) {
    var i = 0
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
        var inline: String?
        if let eq = name.firstIndex(of: "=") {
          inline = String(name[name.index(after: eq)...])
          name = String(name[..<eq])
        }
        let spelling = "--" + name
        let flag: Flag
        let negated: Bool
        if let found = Flag.byLong[name] {
          (flag, negated) = (found, false)
        } else if let found = Flag.byNegation[name] {
          (flag, negated) = (found, true)
        } else {
          throw UsageError(Suggestions.unrecognized(name))
        }
        let value: FlagValue
        if negated || !flag.takesValue {
          if let inline {
            throw UsageError("invalid CLI arguments: unexpected argument for option '\(spelling)': \"\(inline)\"")
          }
          value = negated ? .off : .on
        } else if let inline {
          value = .value(inline)
        } else {
          guard i < arguments.count else {
            throw UsageError("missing value for flag \(spelling): missing argument for option '\(spelling)'")
          }
          value = .value(arguments[i])
          i += 1
        }
        try apply(flag, value, spelling: spelling)
        continue
      }
      let characters = Array(argument.dropFirst())
      var j = 0
      while j < characters.count {
        let c = characters[j]
        j += 1
        let spelling = "-\(c)"
        guard let flag = Flag.byShort[c] else { throw UsageError("unrecognized flag \(spelling)") }
        guard flag.takesValue else {
          if j < characters.count, characters[j] == "=" {
            throw UsageError("invalid CLI arguments: unexpected argument for option '\(spelling)': "
              + "\"\(String(characters[(j + 1)...]))\"")
          }
          try apply(flag, .on, spelling: spelling)
          continue
        }
        var value: String
        if j < characters.count {
          value = String(characters[j...])
          if value.hasPrefix("=") {
            value.removeFirst()
          }
          j = characters.count
        } else {
          guard i < arguments.count else {
            throw UsageError("missing value for flag \(spelling): missing argument for option '\(spelling)'")
          }
          value = arguments[i]
          i += 1
        }
        try apply(flag, .value(value), spelling: spelling)
      }
    }
  }

  mutating func apply(_ flag: Flag, _ value: FlagValue, spelling: String) throws(UsageError) {
    do {
      try update(flag, value)
    } catch {
      throw UsageError("error parsing flag \(spelling): \(error.description)")
    }
  }

  /// One flag's effect, as in ripgrep's `Flag::update`.
  private mutating func update(_ flag: Flag, _ value: FlagValue) throws(UsageError) {
    var on = true
    var text = ""
    switch value {
    case .on: break
    case .off: on = false
    case let .value(v): text = v
    }
    func number() throws(UsageError) -> Int {
      try ArgumentParser.parseNumber(text)
    }
    func choice(_ choices: [String]) throws(UsageError) -> String {
      guard choices.contains(text) else { throw UsageError("choice '\(text)' is unrecognized") }
      return text
    }
    switch flag {
    // Input
    case .regexp: patterns.append(.pattern(text))
    case .file: patterns.append(.file(text))
    case .pre:
      config.preprocessor = on && !text.isEmpty ? text : nil
      if config.preprocessor != nil {
        config.searchCompressed = false
      }
    case .preGlob: config.preprocessorGlobs.append(text)
    case .searchZip:
      config.searchCompressed = on
      if on {
        config.preprocessor = nil
      }
    // Search
    case .caseSensitive: config.matcher.caseMode = .sensitive
    case .ignoreCase: config.matcher.caseMode = .insensitive
    case .smartCase: config.matcher.caseMode = .smart
    case .fixedStrings: config.matcher.fixedStrings = on
    case .wordRegexp:
      config.matcher.wordRegexp = true
      config.matcher.lineRegexp = false
    case .lineRegexp:
      config.matcher.lineRegexp = true
      config.matcher.wordRegexp = false
    case .invertMatch: config.invertMatch = on
    case .maxCount: config.maxCount = try number()
    case .stopOnNonmatch:
      config.stopOnNonmatch = true
      config.matcher.multiline = false
    case .multiline:
      config.matcher.multiline = on
      if on {
        config.stopOnNonmatch = false
      }
    case .multilineDotall: config.matcher.multilineDotAll = on
    case .crlf:
      config.matcher.crlf = on
      if on {
        config.matcher.lineTerminator = 10
      }
    case .nullData:
      config.matcher.crlf = false
      config.matcher.lineTerminator = 0
    case .noUnicode, .noPCRE2Unicode: config.matcher.unicode = !on
    case .text: config.binary = on ? .text : .auto
    case .encoding:
      guard case .value = value else {
        config.encoding = .auto
        return
      }
      switch text {
      case "auto": config.encoding = .auto
      case "none": config.encoding = .disabled
      default:
        guard let encoding = Encodings.encoding(forLabel: text) else {
          throw UsageError("grep config error: unknown encoding: \(text)")
        }
        config.encoding = .some(encoding)
      }
    case .engine:
      switch text {
      case "default": config.engine = .default
      case "auto": config.engine = .auto
      case "pcre2": config.engine = .pcre2
      default: throw UsageError("unrecognized regex engine '\(text)'")
      }
    case .pcre2: config.engine = on ? .pcre2 : .default
    case .autoHybridRegex: config.engine = on ? .auto : .default
    case .dfaSizeLimit: config.matcher.dfaSizeLimit = try Int(ArgumentParser.parseSize(text))
    case .regexSizeLimit: config.matcher.sizeLimit = try Int(ArgumentParser.parseSize(text))
    // Filter
    case .glob: config.globs.append((text, false))
    case .iglob: config.globs.append((text, true))
    case .globCaseInsensitive: config.globCaseInsensitive = on
    case .type: config.typeChanges.append(.select(text))
    case .typeNot: config.typeChanges.append(.negate(text))
    case .typeAdd: config.typeChanges.append(.add(text))
    case .typeClear: config.typeChanges.append(.clear(text))
    case .hidden: config.hidden = on
    case .follow: config.followLinks = on
    case .maxDepth: config.maxDepth = try number()
    case .maxFilesize: config.maxFilesize = try ArgumentParser.parseSize(text)
    case .binary: config.binary = on ? .search : .auto
    case .ignoreFile: config.ignoreFiles.append(text)
    case .ignoreFileCaseInsensitive: config.ignoreFileCaseInsensitive = on
    case .noIgnore: config.noIgnore = on
    case .noIgnoreDot: config.noIgnoreDot = on
    case .noIgnoreExclude: config.noIgnoreExclude = on
    case .noIgnoreFiles: config.noIgnoreFiles = on
    case .noIgnoreGlobal: config.noIgnoreGlobal = on
    case .noIgnoreParent: config.noIgnoreParent = on
    case .noIgnoreVCS: config.noIgnoreVCS = on
    case .noRequireGit: config.noRequireGit = on
    case .oneFileSystem: config.oneFileSystem = on
    case .unrestricted:
      unrestricted += 1
      guard unrestricted <= 3 else { throw UsageError("flag can only be repeated up to 3 times") }
      switch unrestricted {
      case 1: config.noIgnore = true
      case 2: config.hidden = true
      default: config.binary = .search
      }
    // Output
    case .afterContext: config.context = try config.context.setting(after: number())
    case .beforeContext: config.context = try config.context.setting(before: number())
    case .context: config.context = try config.context.setting(both: number())
    case .contextSeparator:
      config.contextSeparator = on ? ArgumentParser.unescape(text) : nil
    case .passthru: config.context = .passthru
    case .color:
      switch try choice(["never", "auto", "always", "ansi"]) {
      case "never": config.color = .never
      case "auto": config.color = .auto
      case "always": config.color = .always
      default: config.color = .ansi
      }
    case .colors: try config.colors.append(ColorSpecification(parsing: text))
    case .pretty:
      config.color = .always
      config.heading = true
      config.lineNumbers = true
    case .lineNumber: config.lineNumbers = true
    case .noLineNumber: config.lineNumbers = false
    case .column: config.column = on
    case .byteOffset: config.byteOffset = on
    case .withFilename: config.withFilename = true
    case .noFilename: config.withFilename = false
    case .heading: config.heading = on
    case .null: config.nullAfterPath = true
    case .pathSeparator:
      let separator = ArgumentParser.unescape(text)
      guard separator.count <= 1 else {
        throw UsageError("A path separator must be exactly one byte, but the given separator is "
          + "\(separator.count) bytes: \(text)\nIn some shells on Windows '/' is automatically expanded. Use '//' instead.")
      }
      config.pathSeparator = separator.first
    case .fieldContextSeparator: config.fieldContextSeparator = ArgumentParser.unescape(text)
    case .fieldMatchSeparator: config.fieldMatchSeparator = ArgumentParser.unescape(text)
    case .onlyMatching: config.onlyMatching = true
    case .replace: config.replacement = Array(text.utf8)
    case .vimgrep: config.vimgrep = true
    case .maxColumns:
      let n = try number()
      config.maxColumns = n == 0 ? nil : n
    case .maxColumnsPreview: config.maxColumnsPreview = on
    case .trim: config.trim = on
    case .includeZero: config.includeZero = on
    case .quiet: config.quiet = true
    case .hyperlinkFormat: config.hyperlinkFormat = try HyperlinkFormat(parsing: text)
    case .hostnameBin: config.hostnameBinary = text.isEmpty ? nil : text
    case .lineBuffered: config.buffering = on ? .line : .auto
    case .blockBuffered: config.buffering = on ? .block : .auto
    case .sort, .sortReverse:
      let key: SortOrder.Key
      switch try choice(["none", "path", "modified", "accessed", "created"]) {
      case "none":
        config.sort = nil
        return
      case "path": key = .path
      case "modified": key = .modified
      case "accessed": key = .accessed
      default: key = .created
      }
      config.sort = SortOrder(key: key, reverse: flag == .sortReverse)
    case .sortFiles: config.sort = on ? SortOrder(key: .path, reverse: false) : nil
    // Output modes. ripgrep lets the last one win.
    case .count: mode = .search(.count)
    case .countMatches: mode = .search(.countMatches)
    case .filesWithMatches: mode = .search(.filesWithMatches)
    case .filesWithoutMatch: mode = .search(.filesWithoutMatch)
    case .json:
      if on {
        mode = .search(.json)
      } else if case .search(.json) = mode {
        mode = .search(.lines)
      }
    // Logging
    case .debug, .trace: config.debug = true
    case .noMessages: config.messages = !on
    case .noIgnoreMessages: config.ignoreMessages = !on
    case .stats: config.stats = on
    // Other
    case .files: mode = .files
    case .typeList: mode = .typeList
    case .generate:
      switch try choice(["man", "complete-bash", "complete-zsh", "complete-fish", "complete-powershell"]) {
      case "man": mode = .generate(.man)
      case "complete-bash": mode = .generate(.bash)
      case "complete-zsh": mode = .generate(.zsh)
      case "complete-fish": mode = .generate(.fish)
      default: mode = .generate(.powershell)
      }
    case .noConfig: noConfig = true
    case .pcre2Version: special = .pcre2Version
    case .help: special = .help
    case .version: special = .version
    // Performance
    case .threads:
      let n = try number()
      config.threads = n == 0 ? nil : n
    case .noCache: config.useCache = false
    case .clearCache: special = .clearCache
    case .mmap: break
    }
  }

  /// Resolves patterns and paths (ripgrep's `Patterns` and `Paths`).
  consuming func finish() throws(UsageError) -> Command {
    switch mode {
    case .typeList: return .typeList(config.typeChanges)
    case let .generate(kind): return .generate(kind)
    case .files:
      config.mode = .listFiles
      config.paths = positional
      return .search(config)
    case let .search(outputMode):
      config.mode = outputMode
    }
    // -v counts lines, and -o -c counts matches.
    if config.mode == .countMatches && config.invertMatch {
      config.mode = .count
    } else if config.mode == .count && config.onlyMatching {
      config.mode = .countMatches
    }
    if patterns.isEmpty {
      guard !positional.isEmpty else {
        throw UsageError("SwiftGrep requires at least one pattern to execute a search")
      }
      config.patterns = [positional.removeFirst()]
    } else {
      // Duplicates are dropped, keeping the first occurrence.
      var seen = Set<String>()
      for source in patterns {
        let found: [String] = switch source {
        case let .pattern(pattern): [pattern]
        case let .file(path): try Self.readPatterns(path, standardInputConsumed: &config.standardInputConsumed)
        }
        for pattern in found where seen.insert(pattern).inserted {
          config.patterns.append(pattern)
        }
      }
    }
    if config.standardInputConsumed, positional.contains("-") {
      throw UsageError("error: attempted to read patterns from stdin while also searching stdin")
    }
    config.paths = positional
    return .search(config)
  }

  /// Patterns from a file, one per line (a trailing `\r` is dropped).
  private static func readPatterns(_ path: String, standardInputConsumed: inout Bool) throws(UsageError) -> [String] {
    if path == "-" {
      guard !standardInputConsumed else {
        throw UsageError("error reading -f/--file from stdin: stdin has already been consumed")
      }
      standardInputConsumed = true
    }
    let data: [UInt8]
    do {
      data = path == "-" ? try FileIO.readWholeFile(.standardInput) : try FileIO.readWholeFile(path: path)
    } catch {
      throw UsageError("\(path): \(error.message)")
    }
    var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map {
      $0.hasSuffix("\r") ? String($0.dropLast()) : String($0)
    }
    if lines.last == "" {
      lines.removeLast()
    }
    return lines
  }
}

extension ContextLines {
  func setting(before lines: Int) -> ContextLines {
    guard case let .limited(_, after, both) = self else { return .limited(before: lines, after: nil, both: nil) }
    return .limited(before: lines, after: after, both: both)
  }

  func setting(after lines: Int) -> ContextLines {
    guard case let .limited(before, _, both) = self else { return .limited(before: nil, after: lines, both: nil) }
    return .limited(before: before, after: lines, both: both)
  }

  func setting(both lines: Int) -> ContextLines {
    guard case let .limited(before, after, _) = self else { return .limited(before: nil, after: nil, both: lines) }
    return .limited(before: before, after: after, both: lines)
  }
}

/// ripgrep's suggestions for misspelled flags: names sharing at least 40%
/// of their character trigrams.
enum Suggestions {
  static func unrecognized(_ name: String) -> String {
    let given = trigrams(name)
    var similar: [String] = []
    let flags = Flag.declared.sorted { (order[$0.long] ?? Int.max) < (order[$1.long] ?? Int.max) }
    for flag in flags {
      for candidate in [flag.long] + (flag.negation.map { [$0] } ?? []) + flag.aliases {
        let other = trigrams(candidate)
        let shared = given.intersection(other).count
        if Double(shared) / Double(given.union(other).count) >= 0.4 {
          similar.append("--" + candidate)
        }
      }
    }
    var message = "unrecognized flag --\(name)"
    if !similar.isEmpty {
      message += "\n\nsimilar flags that are available: " + similar.joined(separator: ", ")
    }
    return message
  }

  /// ripgrep's flag order, which suggestions follow.
  private static let order: [String: Int] = Dictionary(uniqueKeysWithValues: [
    "regexp", "file", "after-context", "before-context", "binary", "block-buffered", "byte-offset", "case-sensitive",
    "color", "colors", "column", "context", "context-separator", "count", "count-matches", "crlf", "debug",
    "dfa-size-limit", "encoding", "engine", "field-context-separator", "field-match-separator", "files",
    "files-with-matches", "files-without-match", "fixed-strings", "follow", "generate", "glob", "glob-case-insensitive",
    "heading", "help", "hidden", "hostname-bin", "hyperlink-format", "iglob", "ignore-case", "ignore-file",
    "ignore-file-case-insensitive", "include-zero", "invert-match", "json", "line-buffered", "line-number",
    "no-line-number", "line-regexp", "max-columns", "max-columns-preview", "max-count", "max-depth", "max-filesize",
    "mmap", "multiline", "multiline-dotall", "no-config", "no-ignore", "no-ignore-dot", "no-ignore-exclude",
    "no-ignore-files", "no-ignore-global", "no-ignore-messages", "no-ignore-parent", "no-ignore-vcs", "no-messages",
    "no-require-git", "no-unicode", "null", "null-data", "one-file-system", "only-matching", "path-separator",
    "passthru", "pcre2", "pcre2-version", "pre", "pre-glob", "pretty", "quiet", "regex-size-limit", "replace",
    "search-zip", "smart-case", "sort", "sortr", "stats", "stop-on-nonmatch", "text", "threads", "trace", "trim", "type",
    "type-not", "type-add", "type-clear", "type-list", "unrestricted", "version", "vimgrep", "with-filename",
    "no-filename", "word-regexp", "auto-hybrid-regex", "no-pcre2-unicode", "sort-files",
  ].enumerated().map { ($1, $0) })

  private static func trigrams(_ name: String) -> Set<[UInt8]> {
    let bytes = Array(name.utf8)
    switch bytes.count {
    case 0: return [Array("!!!".utf8)]
    case 1: return [[bytes[0], 33, 33]]
    case 2: return [[bytes[0], bytes[1], 33]]
    default: return Set((0...(bytes.count - 3)).map { Array(bytes[$0..<($0 + 3)]) })
    }
  }
}

/// ripgrep's configuration file: one argument per line, ignoring blank lines
/// and lines starting with `#`.
enum ConfigFile {
  static func arguments(path: String, messages: Bool) -> [String] {
    let data: [UInt8]
    do {
      data = try FileIO.readWholeFile(path: path)
    } catch {
      if messages {
        Diagnostics.error("failed to read the file specified in RIPGREP_CONFIG_PATH: \(path): \(error.message)")
      }
      return []
    }
    var arguments: [String] = []
    for line in data.split(separator: 10, omittingEmptySubsequences: false) {
      let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: " \t\r\n\u{0B}\u{0C}")
      if text.isEmpty || text.hasPrefix("#") {
        continue
      }
      arguments.append(text)
    }
    return arguments
  }
}
