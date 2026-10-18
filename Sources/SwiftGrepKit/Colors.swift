/// A terminal color, as in ripgrep's `--colors` values.
public enum TerminalColor: Sendable, Hashable {
  case black, blue, green, red, cyan, magenta, yellow, white
  case ansi256(UInt8)
  case rgb(UInt8, UInt8, UInt8)

  /// Parses a color name, an ANSI 256 number or an `r,g,b` triple (decimal
  /// or `0x` hex), with termcolor's error messages.
  init(parsing text: String) throws(UsageError) {
    switch text.lowercased() {
    case "black": self = .black
    case "blue": self = .blue
    case "green": self = .green
    case "red": self = .red
    case "cyan": self = .cyan
    case "magenta": self = .magenta
    case "yellow": self = .yellow
    case "white": self = .white
    default:
      func number(_ s: Substring) -> UInt8? {
        s.hasPrefix("0x") ? UInt8(s.dropFirst(2), radix: 16) : UInt8(s)
      }
      let codes = text.split(separator: ",", omittingEmptySubsequences: false)
      if codes.count > 1 {
        guard codes.count == 3, let r = number(codes[0]), let g = number(codes[1]), let b = number(codes[2]) else {
          throw UsageError("unrecognized RGB color triple, should be '[0-255],[0-255],[0-255]' (or a hex triple), but is '\(text)'")
        }
        self = .rgb(r, g, b)
      } else if let n = number(codes[0]) {
        self = .ansi256(n)
      } else if text.allSatisfy(\.isHexDigit) {
        throw UsageError("unrecognized ansi256 color number, should be '[0-255]' (or a hex number), but is '\(text)'")
      } else {
        throw UsageError("unrecognized color name '\(text)'. Choose from: black, blue, green, red, cyan, magenta, yellow, white")
      }
    }
  }

  /// The ANSI number of a basic color (0 for black ... 7 for white).
  var basicIndex: Int {
    switch self {
    case .black: 0
    case .red: 1
    case .green: 2
    case .yellow: 3
    case .blue: 4
    case .magenta: 5
    case .cyan: 6
    case .white: 7
    case .ansi256, .rgb: 0
    }
  }
}

/// A color and style, as termcolor writes it.
struct TerminalStyle: Sendable, Hashable {
  var foreground: TerminalColor?
  var background: TerminalColor?
  var bold = false
  var intense = false
  var underline = false
  var italic = false

  var isNone: Bool {
    foreground == nil && background == nil && !bold && !intense && !underline && !italic
  }

  /// The escape sequence that switches to this style: a reset, then the
  /// attributes, then the colors.
  var escape: [UInt8] {
    var text = "\u{1B}[0m"
    if bold {
      text += "\u{1B}[1m"
    }
    if italic {
      text += "\u{1B}[3m"
    }
    if underline {
      text += "\u{1B}[4m"
    }
    if let foreground {
      text += code(foreground, layer: 3)
    }
    if let background {
      text += code(background, layer: 4)
    }
    return Array(text.utf8)
  }

  /// `layer` is 3 for the foreground and 4 for the background. Intense
  /// basic colors are the upper half of the 256-color palette.
  private func code(_ color: TerminalColor, layer: Int) -> String {
    switch color {
    case let .ansi256(n): "\u{1B}[\(layer)8;5;\(n)m"
    case let .rgb(r, g, b): "\u{1B}[\(layer)8;2;\(r);\(g);\(b)m"
    default:
      intense ? "\u{1B}[\(layer)8;5;\(color.basicIndex + 8)m" : "\u{1B}[\(layer)\(color.basicIndex)m"
    }
  }
}

/// One `--colors` value: `TYPE:fg:COLOR`, `TYPE:bg:COLOR`, `TYPE:style:STYLE`
/// or `TYPE:none`.
public struct ColorSpecification: Sendable, Hashable {
  enum Target: Sendable, Hashable {
    case path, line, column, match, highlight
  }

  enum Change: Sendable, Hashable {
    case clear
    case foreground(TerminalColor)
    case background(TerminalColor)
    case bold(Bool)
    case intense(Bool)
    case underline(Bool)
    case italic(Bool)
  }

  let target: Target
  let change: Change

  init(target: Target, change: Change) {
    self.target = target
    self.change = change
  }

  public init(parsing text: String) throws(UsageError) {
    let pieces = text.split(separator: ":", omittingEmptySubsequences: false)
    let invalid = UsageError("invalid color spec format: '\(text)'. Valid format is "
      + "'(path|line|column|match|highlight):(fg|bg|style):(value)'.")
    guard pieces.count == 2 || pieces.count == 3 else { throw invalid }
    switch pieces[0].lowercased() {
    case "path": target = .path
    case "line": target = .line
    case "column": target = .column
    case "match": target = .match
    case "highlight": target = .highlight
    default:
      throw UsageError("unrecognized output type '\(pieces[0])'. Choose from: path, line, column, match, highlight.")
    }
    let kind = pieces[1].lowercased()
    guard ["fg", "bg", "style", "none"].contains(kind) else {
      throw UsageError("unrecognized spec type '\(pieces[1])'. Choose from: fg, bg, style, none.")
    }
    if kind == "none" {
      change = .clear
      return
    }
    guard pieces.count == 3 else { throw invalid }
    let value = String(pieces[2])
    switch kind {
    case "fg": change = try .foreground(TerminalColor(parsing: value))
    case "bg": change = try .background(TerminalColor(parsing: value))
    default:
      switch value.lowercased() {
      case "bold": change = .bold(true)
      case "nobold": change = .bold(false)
      case "intense": change = .intense(true)
      case "nointense": change = .intense(false)
      case "underline": change = .underline(true)
      case "nounderline": change = .underline(false)
      case "italic": change = .italic(true)
      case "noitalic": change = .italic(false)
      default:
        throw UsageError("unrecognized style attribute '\(value)'. Choose from: nobold, bold, nointense, "
          + "intense, nounderline, underline, noitalic, italic.")
      }
    }
  }

  func apply(to style: inout TerminalStyle) {
    switch change {
    case .clear: style = TerminalStyle()
    case let .foreground(color): style.foreground = color
    case let .background(color): style.background = color
    case let .bold(on): style.bold = on
    case let .intense(on): style.intense = on
    case let .underline(on): style.underline = on
    case let .italic(on): style.italic = on
    }
  }

  /// ripgrep's defaults, which `--colors` values are applied on top of.
  static let defaults: [ColorSpecification] = [
    ColorSpecification(target: .path, change: .foreground(.magenta)),
    ColorSpecification(target: .line, change: .foreground(.green)),
    ColorSpecification(target: .match, change: .foreground(.red)),
    ColorSpecification(target: .match, change: .bold(true)),
  ]
}

/// The escape sequences for colored output, computed once per run.
struct Palette: Sendable {
  let path: [UInt8]
  let lineNumber: [UInt8]
  let column: [UInt8]
  let match: [UInt8]
  /// The style of the rest of a matching line, if any (`highlight`).
  let highlight: [UInt8]?
  /// Whether matches are colored at all. If not, lines are printed plain
  /// (even with a highlight style), as in ripgrep.
  let matchIsColored: Bool
  static let reset: [UInt8] = Array("\u{1B}[0m".utf8)

  init(_ specifications: [ColorSpecification]) {
    var path = TerminalStyle()
    var line = TerminalStyle()
    var column = TerminalStyle()
    var match = TerminalStyle()
    var highlight = TerminalStyle()
    for spec in ColorSpecification.defaults + specifications {
      switch spec.target {
      case .path: spec.apply(to: &path)
      case .line: spec.apply(to: &line)
      case .column: spec.apply(to: &column)
      case .match: spec.apply(to: &match)
      case .highlight: spec.apply(to: &highlight)
      }
    }
    self.path = path.escape
    lineNumber = line.escape
    self.column = column.escape
    self.match = match.escape
    self.highlight = highlight.isNone ? nil : highlight.escape
    matchIsColored = !match.isNone
  }
}
