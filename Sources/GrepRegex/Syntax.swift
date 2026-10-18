/// Zero-width assertions understood by the engines.
public enum Look: UInt8, Sendable, Hashable, CaseIterable {
  /// `^`: start of a line.
  case startLine
  /// `$`: end of a line.
  case endLine
  /// `\b` (Unicode).
  case wordBoundary
  /// `\B` (Unicode).
  case notWordBoundary
  /// `\b{start}` / `\<`.
  case wordStart
  /// `\b{end}` / `\>`.
  case wordEnd
  /// `\b{start-half}`: the previous character is not a word character.
  case wordStartHalf
  /// `\b{end-half}`: the next character is not a word character.
  case wordEndHalf
  /// ASCII-only variants, produced by `(?-u:\b)` and friends.
  case wordBoundaryASCII
  case notWordBoundaryASCII
  case wordStartASCII
  case wordEndASCII
  case wordStartHalfASCII
  case wordEndHalfASCII
  /// `^` and `$` in CRLF mode (`--crlf`, `(?R)`): `\r` ends lines too, but
  /// no line starts or ends between a `\r` and a `\n`.
  case startLineCRLF
  case endLineCRLF
  /// `\A` and `\z`: the start and end of the text, which is the line in
  /// line-by-line searches and the file with `-U`.
  case startText
  case endText

  var isLineLook: Bool {
    switch self {
    case .startLine, .endLine, .startLineCRLF, .endLineCRLF, .startText, .endText: true
    default: false
    }
  }

  var isWordLook: Bool {
    !isLineLook
  }

  var isUnicodeWordLook: Bool {
    switch self {
    case .wordBoundary, .notWordBoundary, .wordStart, .wordEnd, .wordStartHalf, .wordEndHalf: true
    default: false
    }
  }

  /// Evaluates a word assertion given the word-ness of the surrounding
  /// characters.
  @inline(__always)
  func holds(previousIsWord: Bool, nextIsWord: Bool) -> Bool {
    switch self {
    case .startLine, .endLine, .startLineCRLF, .endLineCRLF, .startText, .endText: false
    case .wordBoundary, .wordBoundaryASCII: previousIsWord != nextIsWord
    case .notWordBoundary, .notWordBoundaryASCII: previousIsWord == nextIsWord
    case .wordStart, .wordStartASCII: !previousIsWord && nextIsWord
    case .wordEnd, .wordEndASCII: previousIsWord && !nextIsWord
    case .wordStartHalf, .wordStartHalfASCII: !previousIsWord
    case .wordEndHalf, .wordEndHalfASCII: !nextIsWord
    }
  }
}

/// A parsed regular expression. Case-insensitivity has already been applied:
/// case-folded characters are represented as sets.
indirect enum RegexNode: Sendable, Hashable {
  case empty
  /// A single Unicode scalar, matched exactly.
  case char(UInt32)
  /// A single arbitrary byte (only produced in non-Unicode mode for `\xNN` >= 0x80).
  case byte(UInt8)
  /// A set of scalars. `ascii` sets that only contain bytes < 0x80 compile to a single byte test.
  case set(ScalarSet)
  /// A set of raw bytes, from non-Unicode classes such as `(?-u:[\x80-\xFF])`.
  case byteSet(ScalarSet)
  case look(Look)
  case concat([RegexNode])
  case alternate([RegexNode])
  case `repeat`(RegexNode, min: Int, max: Int?, greedy: Bool)
  case group(RegexNode)
  /// A capturing group; group 0 is the whole match, so indices start at 1.
  case capture(Int, RegexNode)

  /// Whether the expression contains any character with uppercase letters, used by smart case.
  var containsUppercaseLiteral: Bool {
    switch self {
    case let .char(c):
      guard let s = Unicode.Scalar(c) else { return false }
      return s.properties.isUppercase
    case let .concat(nodes), let .alternate(nodes):
      return nodes.contains { $0.containsUppercaseLiteral }
    case let .repeat(node, _, _, _), let .group(node), let .capture(_, node):
      return node.containsUppercaseLiteral
    default:
      return false
    }
  }

  var containsLook: Bool {
    switch self {
    case .look: true
    case let .concat(nodes), let .alternate(nodes): nodes.contains { $0.containsLook }
    case let .repeat(node, _, _, _), let .group(node), let .capture(_, node): node.containsLook
    default: false
    }
  }

  /// Whether the expression can only match the empty string (and so every line).
  var minLength: Int {
    switch self {
    case .empty, .look: 0
    case let .char(c): UTF8Encoding.length(of: c)
    case .byte, .byteSet: 1
    case let .set(s): s.ranges.first.map { UTF8Encoding.length(of: $0.lowerBound) } ?? 0
    case let .concat(nodes): nodes.reduce(0) { $0 + $1.minLength }
    case let .alternate(nodes): nodes.map(\.minLength).min() ?? 0
    case let .repeat(node, min, _, _): node.minLength * min
    case let .group(node), let .capture(_, node): node.minLength
    }
  }
}

enum UTF8Encoding {
  static func length(of scalar: UInt32) -> Int {
    switch scalar {
    case 0..<0x80: 1
    case 0x80..<0x800: 2
    case 0x800..<0x10000: 3
    default: 4
    }
  }

  static func encode(_ scalar: UInt32) -> [UInt8] {
    switch scalar {
    case 0..<0x80:
      [UInt8(scalar)]
    case 0x80..<0x800:
      [UInt8(0xC0 | (scalar >> 6)), UInt8(0x80 | (scalar & 0x3F))]
    case 0x800..<0x10000:
      [UInt8(0xE0 | (scalar >> 12)), UInt8(0x80 | ((scalar >> 6) & 0x3F)), UInt8(0x80 | (scalar & 0x3F))]
    default:
      [
        UInt8(0xF0 | (scalar >> 18)), UInt8(0x80 | ((scalar >> 12) & 0x3F)),
        UInt8(0x80 | ((scalar >> 6) & 0x3F)), UInt8(0x80 | (scalar & 0x3F)),
      ]
    }
  }
}

/// An error produced while parsing or compiling a pattern.
public struct RegexError: Error, Sendable, CustomStringConvertible {
  public let message: String
  public let pattern: String
  public let offset: Int?
  /// The message stands alone, without the pattern (compilation limits).
  public var standalone = false

  init(message: String, pattern: String, offset: Int?, standalone: Bool = false) {
    self.message = message
    self.pattern = pattern
    self.offset = offset
    self.standalone = standalone
  }

  public var description: String {
    if standalone {
      return message
    }
    guard let offset else { return "regex parse error:\n    \(pattern)\nerror: \(message)" }
    let scalars = Array(pattern.unicodeScalars)
    let caretColumn = String(String.UnicodeScalarView(scalars.prefix(offset))).count
    return "regex parse error:\n    \(pattern)\n    \(String(repeating: " ", count: caretColumn))^\nerror: \(message)"
  }
}
