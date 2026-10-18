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

  var isWordLook: Bool { self != .startLine && self != .endLine }

  var isUnicodeWordLook: Bool {
    switch self {
    case .wordBoundary, .notWordBoundary, .wordStart, .wordEnd, .wordStartHalf, .wordEndHalf: true
    default: false
    }
  }

  /// Evaluates the assertion given the word-ness of the surrounding characters
  /// and whether the position is at a line boundary.
  @inline(__always)
  func holds(atLineStart: Bool, atLineEnd: Bool, previousIsWord: Bool, nextIsWord: Bool) -> Bool {
    switch self {
    case .startLine: atLineStart
    case .endLine: atLineEnd
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

  /// Whether the expression contains any character with uppercase letters, used by smart case.
  var containsUppercaseLiteral: Bool {
    switch self {
    case .char(let c):
      guard let s = Unicode.Scalar(c) else { return false }
      return s.properties.isUppercase
    case .concat(let nodes), .alternate(let nodes):
      return nodes.contains { $0.containsUppercaseLiteral }
    case .repeat(let node, _, _, _), .group(let node):
      return node.containsUppercaseLiteral
    default:
      return false
    }
  }

  var containsLook: Bool {
    switch self {
    case .look: true
    case .concat(let nodes), .alternate(let nodes): nodes.contains { $0.containsLook }
    case .repeat(let node, _, _, _), .group(let node): node.containsLook
    default: false
    }
  }

  /// Whether the expression can only match the empty string (and so every line).
  var minLength: Int {
    switch self {
    case .empty, .look: 0
    case .char(let c): UTF8Encoding.length(of: c)
    case .byte, .byteSet: 1
    case .set(let s): s.ranges.first.map { UTF8Encoding.length(of: $0.lowerBound) } ?? 0
    case .concat(let nodes): nodes.reduce(0) { $0 + $1.minLength }
    case .alternate(let nodes): nodes.map(\.minLength).min() ?? 0
    case .repeat(let node, let min, _, _): node.minLength * min
    case .group(let node): node.minLength
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
      return [UInt8(scalar)]
    case 0x80..<0x800:
      return [UInt8(0xC0 | (scalar >> 6)), UInt8(0x80 | (scalar & 0x3F))]
    case 0x800..<0x10000:
      return [UInt8(0xE0 | (scalar >> 12)), UInt8(0x80 | ((scalar >> 6) & 0x3F)), UInt8(0x80 | (scalar & 0x3F))]
    default:
      return [
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

  public var description: String {
    guard let offset else { return "regex parse error:\n    \(pattern)\nerror: \(message)" }
    let scalars = Array(pattern.unicodeScalars)
    let caretColumn = String(String.UnicodeScalarView(scalars.prefix(offset))).count
    return "regex parse error:\n    \(pattern)\n    \(String(repeating: " ", count: caretColumn))^\nerror: \(message)"
  }
}
