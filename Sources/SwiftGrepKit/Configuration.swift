import GrepRegex

/// What to print for each file. ripgrep calls these search modes; `-q` and
/// `-o` are separate flags that modify them.
public enum OutputMode: Sendable, Hashable {
  /// Matching lines (the default).
  case lines
  /// Number of matching lines per file (`-c`).
  case count
  /// Number of matches per file (`--count-matches`).
  case countMatches
  /// Paths of files with a match (`-l`).
  case filesWithMatches
  /// Paths of files without a match (`--files-without-match`).
  case filesWithoutMatch
  /// JSON Lines (`--json`).
  case json
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

/// `--sort` and `--sortr`.
public struct SortOrder: Sendable, Hashable {
  public enum Key: Sendable, Hashable {
    case path, modified, accessed, created
  }

  public var key: Key
  public var reverse: Bool
}

/// `-A`, `-B` and `-C`, which ripgrep resolves only at the end: `-A`/`-B`
/// win over `-C` regardless of order. `--passthru` prints every line.
public enum ContextLines: Sendable, Hashable {
  case passthru
  case limited(before: Int?, after: Int?, both: Int?)

  var before: Int {
    guard case let .limited(before, _, both) = self else { return 0 }
    return before ?? both ?? 0
  }

  var after: Int {
    guard case let .limited(_, after, both) = self else { return 0 }
    return after ?? both ?? 0
  }
}

/// Output buffering (`--line-buffered`, `--block-buffered`).
public enum Buffering: Sendable, Hashable {
  /// Line buffered on a terminal, block buffered otherwise.
  case auto
  case line
  case block
}

/// `--engine`. Only the default engine exists; PCRE2 is not available.
public enum RegexEngine: Sendable, Hashable {
  case `default`, auto, pcre2
}

/// One `--type-add`, `--type-clear`, `-t` or `-T`, applied in order.
public enum TypeChange: Sendable, Hashable {
  case add(String)
  case clear(String)
  case select(String)
  case negate(String)
}

/// What `--generate` writes.
public enum GenerateKind: Sendable, Hashable {
  case man, bash, zsh, fish, powershell
}

/// Everything parsed from the command line.
public struct Configuration: Sendable {
  public var patterns: [String] = []
  public var matcher = MatcherOptions()
  public var invertMatch = false
  public var engine = RegexEngine.default

  public var mode: OutputMode = .lines
  public var quiet = false
  public var onlyMatching = false
  public var lineNumbers: Bool?
  public var column: Bool?
  public var byteOffset = false
  public var withFilename: Bool?
  public var heading: Bool?
  public var color: ColorChoice = .auto
  /// `--colors` specifications, applied in order over the defaults.
  public var colors: [ColorSpecification] = []
  public var hyperlinkFormat = HyperlinkFormat.none
  public var hostnameBinary: String?
  public var nullAfterPath = false
  public var vimgrep = false
  public var context = ContextLines.limited(before: nil, after: nil, both: nil)
  public var maxCount: Int?
  public var maxColumns: Int?
  public var maxColumnsPreview = false
  public var trim = false
  public var replacement: [UInt8]?
  public var includeZero = false
  public var stats = false
  public var contextSeparator: [UInt8]? = Array("--".utf8)
  public var fieldContextSeparator: [UInt8] = Array("-".utf8)
  public var fieldMatchSeparator: [UInt8] = Array(":".utf8)
  public var pathSeparator: UInt8?
  public var buffering = Buffering.auto
  public var stopOnNonmatch = false
  /// Report errors such as unreadable files (`--no-messages` turns it off).
  public var messages = true
  /// Report problems with ignore files (`--no-ignore-messages`).
  public var ignoreMessages = true

  public var paths: [String] = []
  /// `-f -` read the patterns from standard input, so it can't be searched.
  public var standardInputConsumed = false
  public var hidden = false
  public var followLinks = false
  public var noIgnoreVCS = false
  public var noIgnoreDot = false
  public var noIgnoreParent = false
  public var noIgnoreGlobal = false
  public var noIgnoreExclude = false
  public var noIgnoreFiles = false
  public var noRequireGit = false
  /// `--ignore-file` paths, in order.
  public var ignoreFiles: [String] = []
  public var ignoreFileCaseInsensitive = false
  public var oneFileSystem = false
  public var globs: [(pattern: String, caseInsensitive: Bool)] = []
  public var globCaseInsensitive = false
  public var typeChanges: [TypeChange] = []
  public var maxDepth: Int?
  public var maxFilesize: Int64?
  public var binary: BinaryMode = .auto
  /// Skip a leading UTF-8 byte order mark, like ripgrep's default encoding
  /// detection (`-E none` turns it off).
  public var stripByteOrderMark = true
  public var sort: SortOrder?
  /// `--pre` and `--pre-glob`: search a command's output instead.
  public var preprocessor: String?
  public var preprocessorGlobs: [String] = []
  /// `-z`: search the output of decompression commands.
  public var searchCompressed = false

  public var threads: Int?
  /// Use the persistent directory listing cache (see `ListingCache`).
  public var useCache = FileIO.environment("SG_NO_CACHE") == nil
  public var debug = false

  public init() {}

  /// `--no-ignore`: disables every kind of ignore file, except those given
  /// with `--ignore-file` (as in ripgrep).
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

/// How each file's results are reported, after `-q` and `-o` are folded in
/// (ripgrep's printer kinds).
enum ReportKind: Sendable, Hashable {
  /// Lines, with context, colors and so on.
  case standard
  case json
  case count
  case countMatches
  case pathWithMatch
  case pathWithoutMatch
  /// `-q`: nothing is printed.
  case quietWithMatch
  case quietWithoutMatch

  /// Whether the file's search can stop at the first match.
  var quitsEarly: Bool {
    self == .pathWithMatch || self == .quietWithMatch
  }

  /// Whether a file "matches" when it has no matching line.
  var matchesWithout: Bool {
    self == .pathWithoutMatch || self == .quietWithoutMatch
  }
}

/// Output settings with every default resolved (TTY detection done).
/// Immutable and shared by all workers, so it's a class: each file's search
/// holds one reference rather than copying every array.
final class OutputSettings: Sendable {
  let mode: OutputMode
  let kind: ReportKind
  let invert: Bool
  let lineNumbers: Bool
  let column: Bool
  let byteOffset: Bool
  let withFilename: Bool
  let heading: Bool
  /// Escape sequences when colors are on.
  let colors: Palette?
  let hyperlinks: HyperlinkFormat
  let onlyMatching: Bool
  let vimgrep: Bool
  let before: Int
  let after: Int
  let passthru: Bool
  let maxCount: Int?
  let maxColumns: Int?
  let maxColumnsPreview: Bool
  let trim: Bool
  let replacement: [UInt8]?
  let includeZero: Bool
  let binary: BinaryMode
  let stripByteOrderMark: Bool
  let contextSeparator: [UInt8]?
  let fieldContextSeparator: [UInt8]
  let fieldMatchSeparator: [UInt8]
  /// Written after a path instead of a field separator (`-0`).
  let pathTerminator: UInt8?
  /// Replaces `/` in printed paths.
  let pathSeparator: UInt8?
  /// The byte lines end with: `\n`, or NUL with `--null-data`.
  let lineTerminator: UInt8
  /// `--crlf`: lines end with `\r\n` when printed, and a `\r` before the
  /// terminator is not part of the line's contents.
  let crlf: Bool
  let stopOnNonmatch: Bool
  let stats: Bool

  init(_ config: Configuration, kind: ReportKind, lineNumbers: Bool, withFilename: Bool, heading: Bool,
       colors: Palette?, hyperlinks: HyperlinkFormat)
  {
    mode = config.mode
    self.kind = kind
    invert = config.invertMatch
    self.lineNumbers = lineNumbers
    column = config.column ?? config.vimgrep
    byteOffset = config.byteOffset
    self.withFilename = withFilename
    self.heading = heading
    self.colors = colors
    self.hyperlinks = hyperlinks
    onlyMatching = config.onlyMatching
    vimgrep = config.vimgrep
    before = config.context.before
    after = config.context.after
    passthru = config.context == .passthru
    maxCount = config.maxCount
    maxColumns = config.maxColumns
    maxColumnsPreview = config.maxColumnsPreview
    trim = config.trim
    replacement = config.replacement
    includeZero = config.includeZero
    binary = config.matcher.lineTerminator == 0 ? .text : config.binary
    stripByteOrderMark = config.stripByteOrderMark
    contextSeparator = config.contextSeparator
    fieldContextSeparator = config.fieldContextSeparator
    fieldMatchSeparator = config.fieldMatchSeparator
    pathTerminator = config.nullAfterPath ? 0 : nil
    pathSeparator = config.pathSeparator
    lineTerminator = config.matcher.lineTerminator
    crlf = config.matcher.crlf
    stopOnNonmatch = config.stopOnNonmatch
    stats = config.stats || config.mode == .json
  }

  var hasContext: Bool {
    before > 0 || after > 0
  }

  /// Whether printing a matching line needs the exact match positions
  /// (ripgrep's "match granularity").
  var needsSpans: Bool {
    colors?.matchIsColored == true || column || replacement != nil || vimgrep || onlyMatching || stats
  }

  /// The bytes that end a printed line.
  var lineTerminatorBytes: [UInt8] {
    crlf ? [13, 10] : [lineTerminator]
  }
}
