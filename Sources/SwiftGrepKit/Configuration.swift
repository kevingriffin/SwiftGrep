import GrepRegex

/// What to print for each file.
public enum OutputMode: Sendable, Hashable {
  /// Matching lines (the default).
  case lines
  /// Only the matched parts of lines (`-o`).
  case onlyMatching
  /// Number of matching lines per file (`-c`).
  case count
  /// Number of matches per file (`--count-matches`).
  case countMatches
  /// Paths of files with a match (`-l`).
  case filesWithMatches
  /// Paths of files without a match (`--files-without-match`).
  case filesWithoutMatch
  /// Nothing; exit status only (`-q`).
  case quiet
  /// The files that would be searched (`--files`).
  case listFiles
}

public enum ColorChoice: Sendable, Hashable {
  case never, auto, always, ansi
}

/// How files containing NUL bytes are handled.
public enum BinaryMode: Sendable, Hashable {
  /// ripgrep's default: binary files found while walking are skipped
  /// (searching stops at the first NUL), while files named explicitly are
  /// searched and reported as "binary file matches".
  case auto
  /// `--binary`: search binary files found while walking too.
  case search
  /// `-a`/`--text`: treat every file as text.
  case text
}

public enum SortMode: Sendable, Hashable {
  case none, path, pathReverse
}

/// Everything parsed from the command line.
public struct Configuration: Sendable {
  public var patterns: [String] = []
  public var matcher = MatcherOptions()
  public var invertMatch = false

  public var mode: OutputMode = .lines
  public var lineNumbers: Bool? = nil
  public var column = false
  public var withFilename: Bool? = nil
  public var heading: Bool? = nil
  public var color: ColorChoice = .auto
  public var nullAfterPath = false
  public var vimgrep = false
  public var beforeContext = 0
  public var afterContext = 0
  public var maxCount: Int? = nil
  public var includeZero = false
  public var stats = false
  public var contextSeparator: [UInt8]? = Array("--".utf8)

  public var paths: [String] = []
  public var hidden = false
  public var followLinks = false
  public var noIgnoreVCS = false
  public var noIgnoreDot = false
  public var noIgnoreParent = false
  public var noIgnoreGlobal = false
  public var noIgnoreExclude = false
  public var noRequireGit = false
  public var globs: [(pattern: String, caseInsensitive: Bool)] = []
  public var globCaseInsensitive = false
  public var types: [String] = []
  public var typesNot: [String] = []
  public var typeAdditions: [String] = []
  public var maxDepth: Int? = nil
  public var maxFilesize: Int64? = nil
  public var binary: BinaryMode = .auto
  /// Skip a leading UTF-8 byte order mark, like ripgrep's default encoding
  /// detection (`-E none` turns it off).
  public var stripByteOrderMark = true
  public var sort: SortMode = .none

  public var threads: Int? = nil
  /// Use the persistent directory listing cache (see `ListingCache`).
  public var useCache = FileIO.environment("SG_NO_CACHE") == nil
  public var debug = false

  public init() {}

  /// `--no-ignore`: disables every kind of ignore file.
  public var noIgnore: Bool {
    get { noIgnoreVCS && noIgnoreDot && noIgnoreParent && noIgnoreGlobal && noIgnoreExclude }
    set {
      noIgnoreVCS = newValue
      noIgnoreDot = newValue
      noIgnoreParent = newValue
      noIgnoreGlobal = newValue
      noIgnoreExclude = newValue
    }
  }
}

/// Escape sequences for colored output, matching ripgrep's defaults.
struct ColorSpec: Sendable {
  var path: [UInt8] = Array("\u{1B}[0m\u{1B}[35m".utf8)
  var lineNumber: [UInt8] = Array("\u{1B}[0m\u{1B}[32m".utf8)
  var column: [UInt8] = Array("\u{1B}[0m".utf8)
  var match: [UInt8] = Array("\u{1B}[0m\u{1B}[1m\u{1B}[31m".utf8)
  var reset: [UInt8] = Array("\u{1B}[0m".utf8)
}

/// Output settings with every default resolved (TTY detection done).
struct OutputSettings: Sendable {
  var mode: OutputMode
  var invert: Bool
  var lineNumbers: Bool
  var column: Bool
  var withFilename: Bool
  var heading: Bool
  var color: ColorSpec?
  var nullAfterPath: Bool
  var vimgrep: Bool
  var before: Int
  var after: Int
  var maxCount: Int?
  var includeZero: Bool
  var binary: BinaryMode
  var stripByteOrderMark: Bool
  var contextSeparator: [UInt8]?

  var hasContext: Bool { before > 0 || after > 0 }

  /// Whether printing needs exact match positions from the Pike VM.
  var needsSpans: Bool {
    color != nil || column || vimgrep || mode == .onlyMatching || mode == .countMatches
  }
}
