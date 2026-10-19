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

/// An error produced while parsing or compiling a pattern, shown the way
/// regex-syntax shows its errors.
public struct RegexError: Error, Sendable, CustomStringConvertible {
  public let message: String
  public let pattern: String
  /// The part of the pattern in error, in Unicode scalars (Rust's `char`s,
  /// in which regex-syntax counts columns). An empty span gets one caret.
  public let span: Range<Int>?
  /// A second part, for errors such as a duplicate group name that point at
  /// the first occurrence too.
  public let auxiliarySpan: Range<Int>?
  /// The message stands alone, without the pattern (compilation limits).
  public var standalone = false

  init(message: String, pattern: String, span: Range<Int>?, auxiliarySpan: Range<Int>? = nil, standalone: Bool = false) {
    self.message = message
    self.pattern = pattern
    self.span = span
    self.auxiliarySpan = auxiliarySpan
    self.standalone = standalone
  }

  public var description: String {
    if standalone {
      return message
    }
    guard let span else { return "regex parse error:\n    \(pattern)\nerror: \(message)" }
    return ErrorNotation(pattern: pattern, spans: [span] + (auxiliarySpan.map { [$0] } ?? [])).text(message: message)
  }
}

/// regex-syntax's error formatter: the pattern with carets under the spans,
/// and line numbers when the pattern has several lines.
private struct ErrorNotation {
  let lines: [[Unicode.Scalar]]
  let multiLine: Bool
  /// Width of the line numbers (0 for a single line).
  let numberWidth: Int
  /// One-line spans by line, as (first column, columns) from 0.
  var byLine: [[(column: Int, width: Int)]]
  /// Spans over several lines, as (line, column) pairs from 1.
  var spread: [((Int, Int), (Int, Int))] = []

  init(pattern: String, spans: [Range<Int>]) {
    let scalars = Array(pattern.unicodeScalars)
    // Lines as Rust's `str::lines` gives them: split at `\n`, without a
    // trailing `\r`, and no empty line after a final `\n`.
    var split = scalars.split(separator: "\n", omittingEmptySubsequences: false).map { line in
      line.last == "\r" ? Array(line.dropLast()) : Array(line)
    }
    if scalars.last == "\n" {
      split.removeLast()
    }
    lines = split
    multiLine = scalars.contains("\n")
    // A span can start just after a final `\n`, on one more line.
    let count = split.count + (scalars.last == "\n" ? 1 : 0)
    numberWidth = count <= 1 ? 0 : String(count).count
    byLine = Array(repeating: [], count: max(count, 1))
    func position(_ offset: Int) -> (line: Int, column: Int) {
      var line = 1
      var column = 1
      for scalar in scalars.prefix(offset) {
        if scalar == "\n" {
          line += 1
          column = 1
        } else {
          column += 1
        }
      }
      return (line, column)
    }
    for span in spans.sorted(by: { ($0.lowerBound, $0.upperBound) < ($1.lowerBound, $1.upperBound) }) {
      let (start, end) = (position(span.lowerBound), position(span.upperBound))
      if start.line == end.line {
        byLine[start.line - 1].append((start.column - 1, max(1, end.column - start.column)))
      } else {
        spread.append(((start.line, start.column), (end.line, end.column)))
      }
    }
  }

  func text(message: String) -> String {
    var notated = ""
    for (i, line) in lines.enumerated() {
      if numberWidth > 0 {
        let number = String(i + 1)
        notated += String(repeating: " ", count: numberWidth - number.count) + number + ": "
      } else {
        notated += "    "
      }
      notated += String(String.UnicodeScalarView(line)) + "\n"
      if i < byLine.count, !byLine[i].isEmpty {
        var notes = String(repeating: " ", count: numberWidth == 0 ? 4 : 2 + numberWidth)
        var column = 0
        for (start, width) in byLine[i] {
          notes += String(repeating: " ", count: max(0, start - column)) + String(repeating: "^", count: width)
          column = max(column, start) + width
        }
        notated += notes + "\n"
      }
    }
    guard multiLine else { return "regex parse error:\n\(notated)error: \(message)" }
    let divider = String(repeating: "~", count: 79)
    var text = "regex parse error:\n\(divider)\n\(notated)\(divider)\n"
    if !spread.isEmpty {
      text += spread.map { start, end in
        "on line \(start.0) (column \(start.1)) through line \(end.0) (column \(end.1 - 1))"
      }.joined(separator: "\n") + "\n"
    }
    return text + "error: \(message)"
  }
}
