/// Flags that change how a pattern is interpreted. They can be set globally
/// and toggled inline with `(?flags)` / `(?flags:...)`.
struct ParseFlags: Hashable, Sendable {
  var caseInsensitive = false
  var dotMatchesNewline = false
  var swapGreed = false
  var ignoreWhitespace = false
  var unicode = true
  /// CRLF mode: `^` and `$` treat `\r` as a line terminator too, and `.`
  /// doesn't match it.
  var crlf = false
}

/// The capturing groups seen so far. Like ripgrep, which joins its patterns
/// into one regex, groups are numbered across all patterns.
struct CaptureGroups: Sendable {
  /// The number of groups, not counting group 0 (the whole match).
  var count = 0
  var names: [String: Int] = [:]
}

/// A recursive descent parser for Rust `regex` crate syntax (the dialect ripgrep uses).
struct Parser {
  private let pattern: String
  private let chars: [Unicode.Scalar]
  private var pos = 0
  private var flags: ParseFlags
  private var groups: CaptureGroups
  /// The first error found when translating (regex-syntax's second pass).
  private var deferred: RegexError?
  /// Where each capture group name was given, for duplicate name errors.
  private var nameSpans: [String: Range<Int>] = [:]
  private var literals = LiteralAnalysis()

  /// ripgrep's smart case analysis: whether the syntax has any literal
  /// character (outside of classes like `\w` or `\pL`), and any uppercase one.
  struct LiteralAnalysis {
    var any = false
    var uppercase = false

    mutating func note(_ value: UInt32) {
      any = true
      uppercase = uppercase || UnicodeClasses.isUppercase(value)
    }
  }

  init(_ pattern: String, flags: ParseFlags, groups: CaptureGroups) {
    self.pattern = pattern
    chars = Array(pattern.unicodeScalars)
    self.flags = flags
    self.groups = groups
  }

  static func parse(_ pattern: String, flags: ParseFlags) throws(RegexError) -> RegexNode {
    var groups = CaptureGroups()
    return try parse(pattern, flags: flags, groups: &groups)
  }

  static func parse(_ pattern: String, flags: ParseFlags, groups: inout CaptureGroups) throws(RegexError) -> RegexNode {
    var literals = LiteralAnalysis()
    return try parse(pattern, flags: flags, groups: &groups, literals: &literals)
  }

  static func parse(
    _ pattern: String, flags: ParseFlags, groups: inout CaptureGroups, literals: inout LiteralAnalysis,
  ) throws(RegexError) -> RegexNode {
    var parser = Parser(pattern, flags: flags, groups: groups)
    let node = try parser.parseAlternation(depth: 0)
    guard parser.pos == parser.chars.count else {
      throw parser.error("unopened group", parser.pos..<(parser.pos + 1))
    }
    if let deferred = parser.deferred {
      throw deferred
    }
    groups = parser.groups
    literals = parser.literals
    return node
  }

  // MARK: - Helpers

  /// An error at `offset` (the current position by default).
  private func error(_ message: String, at offset: Int? = nil) -> RegexError {
    let start = offset ?? pos
    return RegexError(message: message, pattern: pattern, span: start..<start)
  }

  private func error(_ message: String, _ span: Range<Int>, auxiliary: Range<Int>? = nil) -> RegexError {
    RegexError(message: message, pattern: pattern, span: span, auxiliarySpan: auxiliary)
  }

  private var atEnd: Bool {
    pos >= chars.count
  }

  /// regex-syntax's `bump`: moves past the current character and says
  /// whether there's another.
  private mutating func bump() -> Bool {
    guard pos < chars.count else { return false }
    pos += 1
    return pos < chars.count
  }

  /// `bump`, then skips whitespace and comments in extended mode.
  private mutating func bumpAndBumpSpace() -> Bool {
    guard bump() else { return false }
    skipWhitespaceIfExtended()
    return pos < chars.count
  }

  private var current: Unicode.Scalar? {
    pos < chars.count ? chars[pos] : nil
  }

  private func peek(_ offset: Int = 1) -> Unicode.Scalar? {
    pos + offset < chars.count ? chars[pos + offset] : nil
  }

  private mutating func skipWhitespaceIfExtended() {
    guard flags.ignoreWhitespace else { return }
    while let c = current {
      if c.properties.isWhitespace {
        pos += 1
      } else if c == "#" {
        while let d = current, d != "\n" {
          pos += 1
        }
      } else {
        break
      }
    }
  }

  // MARK: - Structure

  private mutating func parseAlternation(depth: Int) throws(RegexError) -> RegexNode {
    guard depth < 250 else { throw error("exceeds the nesting limit") }
    let savedFlags = flags
    var branches: [RegexNode] = try [parseConcat(depth: depth)]
    while current == "|" {
      pos += 1
      try branches.append(parseConcat(depth: depth))
    }
    // Inline flags like `(?i)` only last until the end of the enclosing group.
    flags = savedFlags
    return branches.count == 1 ? branches[0] : .alternate(branches)
  }

  private mutating func parseConcat(depth: Int) throws(RegexError) -> RegexNode {
    var items: [RegexNode] = []
    while true {
      skipWhitespaceIfExtended()
      guard let c = current, c != "|", c != ")" else { break }
      let atom: RegexNode
      switch c {
      case "(":
        guard let group = try parseGroup(depth: depth) else { continue } // a bare flag group
        atom = group
      case "*", "+", "?":
        throw error("repetition operator missing expression")
      case "{":
        throw error("repetition operator missing expression")
      default:
        atom = try parseAtom()
      }
      try items.append(parseRepetitions(atom))
    }
    switch items.count {
    case 0: return .empty
    case 1: return items[0]
    default: return .concat(items)
    }
  }

  private mutating func parseRepetitions(_ atom: RegexNode) throws(RegexError) -> RegexNode {
    var node = atom
    while true {
      skipWhitespaceIfExtended()
      guard let c = current else { return node }
      let opStart = pos
      var min = 0
      var max: Int?
      switch c {
      case "*": pos += 1
      case "+": min = 1; pos += 1
      case "?": max = 1; pos += 1
      case "{":
        let (lo, hi) = try parseCounted()
        min = lo
        max = hi
      default:
        return node
      }
      var greedy = true
      if current == "?" {
        greedy = false
        pos += 1
      }
      if flags.swapGreed {
        greedy.toggle()
      }
      if let max, max < min {
        throw error("invalid repetition count range, the start must be <= the end", opStart..<pos)
      }
      node = .repeat(node, min: min, max: max, greedy: greedy)
    }
  }

  /// regex-syntax's `parse_decimal`: digits, with whitespace around them
  /// skipped even outside extended mode. `empty` is the error for no digits.
  private mutating func parseDecimal(empty: String) -> Result<Int, RegexError> {
    while let c = current, c.properties.isWhitespace {
      pos += 1
    }
    let start = pos
    var digits = ""
    while let c = current, c.value >= 0x30, c.value <= 0x39 {
      digits.unicodeScalars.append(c)
      _ = bumpAndBumpSpace()
    }
    let span = start..<pos
    while let c = current, c.properties.isWhitespace {
      _ = bumpAndBumpSpace()
    }
    guard !digits.isEmpty else { return .failure(error(empty, span)) }
    guard let value = UInt32(digits) else { return .failure(error("decimal literal invalid", span)) }
    return .success(Int(value))
  }

  /// Parses `{n}`, `{n,}` or `{n,m}` at `{`, up to the closing brace, with
  /// regex-syntax's errors in its order.
  private mutating func parseCounted() throws(RegexError) -> (Int, Int?) {
    let open = pos
    let empty = "repetition quantifier expects a valid decimal"
    guard bumpAndBumpSpace() else { throw error("unclosed counted repetition", open..<pos) }
    let low = parseDecimal(empty: empty)
    guard !atEnd else { throw error("unclosed counted repetition", open..<pos) }
    let range: (Int, Int?)
    if current == "," {
      guard bumpAndBumpSpace() else { throw error("unclosed counted repetition", open..<pos) }
      if current != "}" {
        let start = try low.get()
        range = try (start, parseDecimal(empty: empty).get())
      } else {
        range = try (low.get(), nil)
      }
    } else {
      let count = try low.get()
      range = (count, count)
    }
    guard current == "}" else { throw error("unclosed counted repetition", open..<pos) }
    pos += 1
    return range
  }

  /// regex-syntax's `parse_group`: `(` ... `)`. Returns nil for a flag-only
  /// group like `(?i)`, which changes the flags for the rest of the
  /// enclosing group.
  private mutating func parseGroup(depth: Int) throws(RegexError) -> RegexNode? {
    let open = pos
    let openSpan = open..<(open + 1)
    pos += 1
    skipWhitespaceIfExtended()
    for prefix in ["?=", "?!", "?<=", "?<!"] where starts(with: prefix) {
      throw error("look-around, including look-ahead and look-behind, is not supported",
                  open..<(pos + prefix.unicodeScalars.count))
    }
    let inner = pos
    var capture: Int?
    var newFlags: ParseFlags?
    if starts(with: "?P<") || starts(with: "?<") {
      pos += starts(with: "?P<") ? 3 : 2
      groups.count += 1
      capture = groups.count
      try parseCaptureName(index: groups.count)
    } else if current == "?" {
      pos += 1
      guard !atEnd else { throw error("unclosed group", openSpan) }
      let (parsed, empty) = try parseFlags()
      let end = chars[pos]
      pos += 1
      if end == ")" {
        // `(?)` reads as a repetition operator without an expression.
        if empty {
          throw error("repetition operator missing expression", inner..<inner)
        }
        flags = parsed
        return nil
      }
      newFlags = parsed
    } else {
      groups.count += 1
      capture = groups.count
    }
    let saved = flags
    if let newFlags {
      flags = newFlags
    }
    let body = try parseAlternation(depth: depth + 1)
    flags = saved
    guard current == ")" else { throw error("unclosed group", openSpan) }
    pos += 1
    return capture.map { .capture($0, body) } ?? .group(body)
  }

  private func starts(with prefix: String) -> Bool {
    var i = pos
    for scalar in prefix.unicodeScalars {
      guard i < chars.count, chars[i] == scalar else { return false }
      i += 1
    }
    return true
  }

  /// regex-syntax's `parse_capture_name`, after `<`.
  private mutating func parseCaptureName(index: Int) throws(RegexError) {
    guard !atEnd else { throw error("unclosed capture group name", pos..<pos) }
    let start = pos
    while let c = current, c != ">" {
      guard Self.isCaptureCharacter(c, first: pos == start) else {
        throw error("invalid capture group character", pos..<(pos + 1))
      }
      guard bump() else { break }
    }
    let end = pos
    guard !atEnd else { throw error("unclosed capture group name", pos..<pos) }
    pos += 1
    guard end > start else { throw error("empty capture group name", start..<start) }
    let name = String(String.UnicodeScalarView(chars[start..<end]))
    if let original = nameSpans[name] {
      throw error("duplicate capture group name", start..<end, auxiliary: original)
    }
    nameSpans[name] = start..<end
    groups.names[name] = index
  }

  private static func isCaptureCharacter(_ c: Unicode.Scalar, first: Bool) -> Bool {
    if c == "_" || c.properties.isAlphabetic {
      return true
    }
    let numeric = switch c.properties.generalCategory {
    case .decimalNumber, .letterNumber, .otherNumber: true
    default: false
    }
    return !first && (c == "." || c == "[" || c == "]" || numeric)
  }

  /// regex-syntax's `parse_flags`: the flags up to `:` or `)`, applied to
  /// the current ones, and whether there were none.
  private mutating func parseFlags() throws(RegexError) -> (ParseFlags, empty: Bool) {
    var result = flags
    var seen: [(flag: Unicode.Scalar, span: Range<Int>)] = []
    var negation: Range<Int>?
    var lastWasNegation: Range<Int>?
    while let c = current, c != ":", c != ")" {
      let span = pos..<(pos + 1)
      if c == "-" {
        lastWasNegation = span
        if let original = negation {
          throw error("flag negation operator repeated", span, auxiliary: original)
        }
        negation = span
      } else {
        lastWasNegation = nil
        let on = negation == nil
        switch c {
        case "i": result.caseInsensitive = on
        case "m": break // multi-line: ^ and $ always match at line boundaries here.
        case "s": result.dotMatchesNewline = on
        case "U": result.swapGreed = on
        case "u": result.unicode = on
        case "R": result.crlf = on
        case "x": result.ignoreWhitespace = on
        default: throw error("unrecognized flag", span)
        }
        if let original = seen.first(where: { $0.flag == c }) {
          throw error("duplicate flag", span, auxiliary: original.span)
        }
        seen.append((c, span))
      }
      guard bump() else { throw error("expected flag but got end of regex", pos..<pos) }
    }
    if let lastWasNegation {
      throw error("dangling flag negation operator", lastWasNegation)
    }
    return (result, seen.isEmpty && negation == nil)
  }

  // MARK: - Atoms

  private mutating func parseAtom() throws(RegexError) -> RegexNode {
    guard let c = current else { throw error("unexpected end of pattern") }
    switch c {
    case ".":
      pos += 1
      var dot = flags.unicode ? ScalarSet.all : ScalarSet([0...0xFF])
      if !flags.dotMatchesNewline {
        dot = dot.removing(10)
        if flags.crlf {
          dot = dot.removing(13)
        }
      }
      return flags.unicode ? .set(dot) : .byteSet(dot)
    case "^":
      pos += 1
      return .look(flags.crlf ? .startLineCRLF : .startLine)
    case "$":
      pos += 1
      return .look(flags.crlf ? .endLineCRLF : .endLine)
    case "[":
      return try parseClass()
    case "\\":
      return try parseEscape()
    default:
      pos += 1
      return literal(c.value)
    }
  }

  private mutating func literal(_ value: UInt32) -> RegexNode {
    literals.note(value)
    if flags.caseInsensitive && CaseFolding.hasCase(value) {
      return .set(ScalarSet(scalar: value).caseFolded())
    }
    return .char(value)
  }

  /// What an escape stands for (regex-syntax's `Primitive`).
  private enum Escape {
    case literal(UInt32)
    case look(Look)
    case set(ScalarSet)
  }

  private static let eofMessage = "incomplete escape sequence, reached end of pattern prematurely"

  private mutating func parseEscape() throws(RegexError) -> RegexNode {
    switch try parseEscapeSequence().escape {
    case let .literal(value):
      if !flags.unicode, value >= 0x80, value <= 0xFF {
        literals.note(value)
        return .byte(UInt8(value))
      }
      return literal(value)
    case let .look(look):
      return .look(look)
    case let .set(set):
      return .set(set)
    }
  }

  /// regex-syntax's `parse_escape`, at a backslash.
  private mutating func parseEscapeSequence() throws(RegexError) -> (escape: Escape, span: Range<Int>) {
    let start = pos
    guard bump() else { throw error(Self.eofMessage, start..<pos) }
    let c = chars[pos]
    switch c {
    case "0"..."9":
      throw error("backreferences are not supported", start..<(pos + 1))
    case "x", "u", "U":
      let value = try parseHex()
      return (.literal(value), start..<pos)
    case "p", "P":
      let set = try parseUnicodeClass(start: start)
      return (.set(set), start..<pos)
    case "d", "s", "w", "D", "S", "W":
      pos += 1
      // Perl classes are closed under case folding.
      let set = perlClass(c)
      return (.set(c.properties.isUppercase ? set.inverted() : set), start..<pos)
    default:
      break
    }
    pos += 1
    let span = start..<pos
    // Meta characters and other ASCII punctuation stand for themselves.
    if c.isASCII, !c.properties.isAlphabetic, !("0"..."9").contains(c), c != "<", c != ">" {
      return (.literal(c.value), span)
    }
    let escape: Escape
    switch c {
    case "a": escape = .literal(7)
    case "f": escape = .literal(12)
    case "t": escape = .literal(9)
    case "n": escape = .literal(10)
    case "r": escape = .literal(13)
    case "v": escape = .literal(11)
    case "A": escape = .look(.startText)
    case "z": escape = .look(.endText)
    case "b":
      var look: Look = flags.unicode ? .wordBoundary : .wordBoundaryASCII
      if current == "{", let special = try parseSpecialWordBoundary(start: start) {
        look = special
      }
      return (.look(look), start..<pos)
    case "B": escape = .look(flags.unicode ? .notWordBoundary : .notWordBoundaryASCII)
    case "<": escape = .look(flags.unicode ? .wordStart : .wordStartASCII)
    case ">": escape = .look(flags.unicode ? .wordEnd : .wordEndASCII)
    default: throw error("unrecognized escape sequence", span)
    }
    return (escape, span)
  }

  /// `\b{start}` and friends, at `{`; nil (consuming nothing) if the braces
  /// start a repetition instead, as in `\b{2}`.
  private mutating func parseSpecialWordBoundary(start escapeStart: Int) throws(RegexError) -> Look? {
    func isNameCharacter(_ c: Unicode.Scalar?) -> Bool {
      guard let c else { return false }
      return ("a"..."z").contains(c) || ("A"..."Z").contains(c) || c == "-"
    }
    let open = pos
    guard bumpAndBumpSpace() else {
      throw error("found either the beginning of a special word boundary or a bounded repetition on a \\b with "
        + "an opening brace, but no closing brace", escapeStart..<pos)
    }
    let contents = pos
    guard isNameCharacter(current) else {
      pos = open
      return nil
    }
    var name = ""
    while isNameCharacter(current), let c = current {
      name.unicodeScalars.append(c)
      _ = bumpAndBumpSpace()
    }
    guard current == "}" else {
      throw error("special word boundary assertion is either unclosed or contains an invalid character", open..<pos)
    }
    let end = pos
    pos += 1
    switch name {
    case "start": return flags.unicode ? .wordStart : .wordStartASCII
    case "end": return flags.unicode ? .wordEnd : .wordEndASCII
    case "start-half": return flags.unicode ? .wordStartHalf : .wordStartHalfASCII
    case "end-half": return flags.unicode ? .wordEndHalf : .wordEndHalfASCII
    default:
      throw error("unrecognized special word boundary assertion, valid choices are: start, end, start-half or end-half",
                  contents..<end)
    }
  }

  private static func isHexDigit(_ c: Unicode.Scalar?) -> Bool {
    guard let c else { return false }
    return ("0"..."9").contains(c) || ("a"..."f").contains(c) || ("A"..."F").contains(c)
  }

  /// `\x`, `\u` and `\U` escapes, at the letter.
  private mutating func parseHex() throws(RegexError) -> UInt32 {
    let count = current == "x" ? 2 : current == "u" ? 4 : 8
    guard bumpAndBumpSpace() else { throw error(Self.eofMessage, pos..<pos) }
    if current == "{" {
      return try parseHexBrace()
    }
    let start = pos
    var digits = ""
    for i in 0..<count {
      if i > 0, !bumpAndBumpSpace() {
        throw error(Self.eofMessage, pos..<pos)
      }
      guard let c = current, Self.isHexDigit(c) else { throw error("invalid hexadecimal digit", pos..<(pos + 1)) }
      digits.unicodeScalars.append(c)
    }
    _ = bumpAndBumpSpace()
    guard let value = UInt32(digits, radix: 16), Unicode.Scalar(value) != nil else {
      throw error("hexadecimal literal is not a Unicode scalar value", start..<pos)
    }
    return value
  }

  private mutating func parseHexBrace() throws(RegexError) -> UInt32 {
    let brace = pos
    var digits = ""
    while bumpAndBumpSpace(), current != "}" {
      guard let c = current, Self.isHexDigit(c) else { throw error("invalid hexadecimal digit", pos..<(pos + 1)) }
      digits.unicodeScalars.append(c)
    }
    guard !atEnd else { throw error(Self.eofMessage, brace..<pos) }
    let end = pos
    _ = bumpAndBumpSpace()
    guard !digits.isEmpty else { throw error("hexadecimal literal empty", brace..<pos) }
    guard let value = UInt32(digits, radix: 16), Unicode.Scalar(value) != nil else {
      throw error("hexadecimal literal is not a Unicode scalar value", (brace + 1)..<end)
    }
    return value
  }

  private func perlClass(_ c: Unicode.Scalar) -> ScalarSet {
    let lower = Unicode.Scalar(UInt8(ascii: "a") + (UInt8(c.value) | 0x20) - UInt8(ascii: "a"))
    if !flags.unicode {
      switch lower {
      case "d": return ScalarSet([0x30...0x39])
      case "s": return ScalarSet([9...13, 32...32])
      default: return ScalarSet([0x30...0x39, 0x41...0x5A, 0x5F...0x5F, 0x61...0x7A])
      }
    }
    switch lower {
    case "d": return ScalarSet(table: UnicodeTables.perlDigit)
    case "s": return ScalarSet(table: UnicodeTables.perlSpace)
    default: return ScalarSet(table: UnicodeTables.perlWord)
    }
  }

  /// `\p` and `\P` classes, at the letter; `start` is the backslash. Unknown
  /// properties are reported once the whole pattern has parsed, as
  /// regex-syntax finds them when translating its syntax tree.
  private mutating func parseUnicodeClass(start: Int) throws(RegexError) -> ScalarSet {
    var negated = current == "P"
    guard bumpAndBumpSpace() else { throw error(Self.eofMessage, pos..<pos) }
    let query: UnicodeClasses.Query
    if current == "{" {
      var name: [Unicode.Scalar] = []
      while bumpAndBumpSpace(), let c = current, c != "}" {
        name.append(c)
      }
      guard !atEnd else { throw error(Self.eofMessage, pos..<pos) }
      pos += 1
      func text(_ part: ArraySlice<Unicode.Scalar>) -> String {
        String(String.UnicodeScalarView(part))
      }
      if let i = name.indices.first(where: { name[$0] == "!" && $0 + 1 < name.count && name[$0 + 1] == "=" }) {
        negated.toggle()
        query = .byValue(name: text(name[..<i]), value: text(name[(i + 2)...]))
      } else if let i = name.firstIndex(of: ":") ?? name.firstIndex(of: "=") {
        query = .byValue(name: text(name[..<i]), value: text(name[(i + 1)...]))
      } else {
        query = .binary(text(name[...]))
      }
    } else {
      let c = chars[pos]
      guard c != "\\" else { throw error("invalid Unicode character class", pos..<(pos + 1)) }
      _ = bumpAndBumpSpace()
      query = .oneLetter(c)
    }
    let span = start..<pos
    guard flags.unicode else {
      deferError(error("Unicode not allowed here", span))
      return ScalarSet()
    }
    switch UnicodeClasses.lookup(query) {
    case var .success(set):
      if flags.caseInsensitive {
        set = set.caseFolded()
      }
      return negated ? set.inverted() : set
    case .failure(.propertyNotFound):
      deferError(error("Unicode property not found", span))
    case .failure(.valueNotFound):
      deferError(error("Unicode property value not found", span))
    }
    return ScalarSet()
  }

  /// Keeps the first error found when translating, reported only if the
  /// whole pattern parses.
  private mutating func deferError(_ error: RegexError) {
    if deferred == nil {
      deferred = error
    }
  }

  // MARK: - Bracketed classes

  private mutating func parseClass() throws(RegexError) -> RegexNode {
    let set = try parseClassBody()
    return .set(set)
  }

  /// regex-syntax's `parse_set_class`: `[...]` at the opening bracket, as
  /// its final set (case folded and negated as needed).
  private mutating func parseClassBody() throws(RegexError) -> ScalarSet {
    let unclosed = "unclosed character class"
    let open = pos
    guard bumpAndBumpSpace() else { throw error(unclosed, open..<pos) }
    var negated = false
    if current == "^" {
      negated = true
      guard bumpAndBumpSpace() else { throw error(unclosed, open..<pos) }
    }
    // Leading `-`s, and then a `]` if nothing came before it, are literal.
    var union = ScalarSet()
    var empty = true
    while current == "-" {
      union.insert(0x2D...0x2D)
      literals.note(0x2D)
      empty = false
      guard bumpAndBumpSpace() else { throw error(unclosed, open..<open) }
    }
    if empty, current == "]" {
      union.insert(0x5D...0x5D)
      literals.note(0x5D)
      guard bumpAndBumpSpace() else { throw error(unclosed, open..<pos) }
    }
    let openSpan = open..<pos
    // Set operations apply left to right.
    var left: ScalarSet?
    var operation: ((ScalarSet, ScalarSet) -> ScalarSet)?
    func pending() -> ScalarSet {
      operation.map { $0(left ?? ScalarSet(), union) } ?? union
    }
    while true {
      skipWhitespaceIfExtended()
      guard let c = current else { throw error(unclosed, openSpan) }
      switch c {
      case "[":
        if let ascii = parseASCIIClass() {
          union.formUnion(ascii)
        } else {
          try union.formUnion(parseClassBody())
        }
      case "]":
        pos += 1
        var result = pending()
        if flags.caseInsensitive {
          result = result.caseFolded()
        }
        return negated ? result.inverted() : result
      case "&" where peek() == "&", "-" where peek() == "-", "~" where peek() == "~":
        pos += 2
        left = pending()
        operation = switch c {
        case "&": { $0.intersection($1) }
        case "-": { $0.subtracting($1) }
        default: { $0.symmetricDifference($1) }
        }
        union = ScalarSet()
      default:
        try parseClassRange(into: &union, openSpan: openSpan)
      }
    }
  }

  /// regex-syntax's `parse_set_class_range`: one item or a range of two.
  private mutating func parseClassRange(into union: inout ScalarSet, openSpan: Range<Int>) throws(RegexError) {
    let unclosed = "unclosed character class"
    let (first, firstSpan) = try parseClassItem()
    skipWhitespaceIfExtended()
    guard !atEnd else { throw error(unclosed, openSpan) }
    if current != "-" || peekSpace() == "]" || peekSpace() == "-" {
      switch first {
      case .look: throw error("invalid escape sequence found in character class", firstSpan)
      case let .literal(value):
        literals.note(value)
        union.insert(value...value)
      case let .set(set): union.formUnion(set)
      }
      return
    }
    guard bumpAndBumpSpace() else { throw error(unclosed, openSpan) }
    let (second, secondSpan) = try parseClassItem()
    guard case let .literal(low) = first else { throw error("invalid range boundary, must be a literal", firstSpan) }
    guard case let .literal(high) = second else { throw error("invalid range boundary, must be a literal", secondSpan) }
    literals.note(low)
    literals.note(high)
    guard low <= high else {
      throw error("invalid character class range, the start must be <= the end", firstSpan.lowerBound..<secondSpan.upperBound)
    }
    union.insert(low...high)
  }

  private mutating func parseClassItem() throws(RegexError) -> (escape: Escape, span: Range<Int>) {
    if current == "\\" {
      return try parseEscapeSequence()
    }
    let c = chars[pos]
    pos += 1
    return (.literal(c.value), (pos - 1)..<pos)
  }

  /// The next character after the current one, past whitespace and comments
  /// in extended mode.
  private func peekSpace() -> Unicode.Scalar? {
    guard flags.ignoreWhitespace else { return peek() }
    var i = pos + 1
    var inComment = false
    while i < chars.count {
      let c = chars[i]
      if c.properties.isWhitespace {
        i += 1
      } else if !inComment, c == "#" {
        inComment = true
        i += 1
      } else if inComment, c == "\n" {
        inComment = false
        i += 1
      } else if inComment {
        i += 1
      } else {
        break
      }
    }
    return i < chars.count ? chars[i] : nil
  }

  /// `[:name:]` or `[:^name:]` inside a class. Returns nil, consuming
  /// nothing, if this isn't one, and the `[` starts a nested class.
  private mutating func parseASCIIClass() -> ScalarSet? {
    let start = pos
    guard bump(), current == ":", bump() else {
      pos = start
      return nil
    }
    var negated = false
    if current == "^" {
      negated = true
      guard bump() else {
        pos = start
        return nil
      }
    }
    let nameStart = pos
    while current != ":", bump() {}
    let name = String(String.UnicodeScalarView(chars[nameStart..<pos]))
    guard current == ":", peek() == "]", var set = Self.asciiClass(name) else {
      pos = start
      return nil
    }
    pos += 2
    if flags.caseInsensitive {
      set = set.caseFolded()
    }
    return negated ? set.inverted() : set
  }

  private static func asciiClass(_ name: String) -> ScalarSet? {
    switch name {
    case "alnum": ScalarSet([0x30...0x39, 0x41...0x5A, 0x61...0x7A])
    case "alpha": ScalarSet([0x41...0x5A, 0x61...0x7A])
    case "ascii": ScalarSet([0...0x7F])
    case "blank": ScalarSet([9...9, 32...32])
    case "cntrl": ScalarSet([0...0x1F, 0x7F...0x7F])
    case "digit": ScalarSet([0x30...0x39])
    case "graph": ScalarSet([0x21...0x7E])
    case "lower": ScalarSet([0x61...0x7A])
    case "print": ScalarSet([0x20...0x7E])
    case "punct": ScalarSet([0x21...0x2F, 0x3A...0x40, 0x5B...0x60, 0x7B...0x7E])
    case "space": ScalarSet([9...13, 32...32])
    case "upper": ScalarSet([0x41...0x5A])
    case "word": ScalarSet([0x30...0x39, 0x41...0x5A, 0x5F...0x5F, 0x61...0x7A])
    case "xdigit": ScalarSet([0x30...0x39, 0x41...0x46, 0x61...0x66])
    default: nil
    }
  }
}

/// `\p{...}`: regex-syntax's lookup of Unicode properties (its `ClassQuery`),
/// over its tables in `UnicodeTables`.
enum UnicodeClasses {
  enum Query {
    /// `\pL`
    case oneLetter(Unicode.Scalar)
    /// `\p{Greek}`: a binary property, general category or script.
    case binary(String)
    /// `\p{sc=Greek}`, `\p{sc:Greek}` or `\p{sc!=Greek}`.
    case byValue(name: String, value: String)
  }

  enum LookupError: Error {
    case propertyNotFound
    case valueNotFound
  }

  static func lookup(_ query: Query) -> Result<ScalarSet, LookupError> {
    switch query {
    case let .oneLetter(c): binary(String(c))
    case let .binary(name): binary(name)
    case let .byValue(name, value): byValue(name, value)
    }
  }

  private static func binary(_ name: String) -> Result<ScalarSet, LookupError> {
    let normalized = normalize(name)
    if normalized != "cf", normalized != "sc", normalized != "lc", let canonical = canonicalProperty(normalized) {
      return booleanProperty(canonical)
    }
    if let canonical = canonicalCategory(normalized) {
      return category(canonical)
    }
    if let canonical = canonicalValue(of: "Script", normalized) {
      return set(in: UnicodeTables.scripts, canonical).map(Result.success) ?? .failure(.valueNotFound)
    }
    return .failure(.propertyNotFound)
  }

  private static func byValue(_ name: String, _ value: String) -> Result<ScalarSet, LookupError> {
    let normalizedValue = normalize(value)
    guard let property = canonicalProperty(normalize(name)) else { return .failure(.propertyNotFound) }
    switch property {
    case "General_Category":
      guard let canonical = canonicalCategory(normalizedValue) else { return .failure(.valueNotFound) }
      return category(canonical)
    default:
      guard let canonical = canonicalValue(of: property, normalizedValue) else { return .failure(.valueNotFound) }
      let tables: [UnicodeTables.NamedSet]
      switch property {
      case "Script": tables = UnicodeTables.scripts
      case "Script_Extensions": tables = UnicodeTables.scriptExtensions
      case "Grapheme_Cluster_Break": tables = UnicodeTables.graphemeClusterBreaks
      case "Word_Break": tables = UnicodeTables.wordBreaks
      case "Sentence_Break": tables = UnicodeTables.sentenceBreaks
      case "Age": return age(canonical)
      default: return .failure(.propertyNotFound)
      }
      return set(in: tables, canonical).map(Result.success) ?? .failure(.valueNotFound)
    }
  }

  private static func booleanProperty(_ canonical: String) -> Result<ScalarSet, LookupError> {
    switch canonical {
    case "Decimal_Number": .success(ScalarSet(table: UnicodeTables.perlDigit))
    case "White_Space": .success(ScalarSet(table: UnicodeTables.perlSpace))
    default: set(in: UnicodeTables.binaryProperties, canonical).map(Result.success) ?? .failure(.propertyNotFound)
    }
  }

  private static func category(_ canonical: String) -> Result<ScalarSet, LookupError> {
    switch canonical {
    case "Decimal_Number": .success(ScalarSet(table: UnicodeTables.perlDigit))
    case "ASCII": .success(ScalarSet([0...0x7F]))
    case "Any": .success(.all)
    case "Assigned": category("Unassigned").map { $0.inverted() }
    default: set(in: UnicodeTables.generalCategories, canonical).map(Result.success) ?? .failure(.valueNotFound)
    }
  }

  /// `Age=V8_0` is everything assigned in Unicode 8.0 or earlier.
  private static func age(_ canonical: String) -> Result<ScalarSet, LookupError> {
    func version(_ name: String) -> [Int] {
      name.dropFirst().split(separator: "_").map { Int($0) ?? 0 }
    }
    let ages = UnicodeTables.ages.sorted { version($0.name).lexicographicallyPrecedes(version($1.name)) }
    guard let last = ages.firstIndex(where: { $0.name == canonical }) else { return .failure(.valueNotFound) }
    var result = ScalarSet()
    for entry in ages[...last] {
      result.formUnion(ranges(entry))
    }
    return .success(result)
  }

  private static func canonicalCategory(_ normalized: String) -> String? {
    switch normalized {
    case "any": "Any"
    case "assigned": "Assigned"
    case "ascii": "ASCII"
    default: canonicalValue(of: "General_Category", normalized)
    }
  }

  private static func canonicalProperty(_ normalized: String) -> String? {
    search(UnicodeTables.propertyNames, normalized)
  }

  private static func canonicalValue(of property: String, _ normalized: String) -> String? {
    guard let values = UnicodeTables.propertyValues.first(where: { $0.0 == property })?.1 else { return nil }
    return search(values, normalized)
  }

  private static func search(_ pairs: [(String, String)], _ key: String) -> String? {
    var low = 0
    var high = pairs.count
    while low < high {
      let mid = (low + high) / 2
      if pairs[mid].0 < key {
        low = mid + 1
      } else {
        high = mid
      }
    }
    return low < pairs.count && pairs[low].0 == key ? pairs[low].1 : nil
  }

  private static func set(in tables: [UnicodeTables.NamedSet], _ name: String) -> ScalarSet? {
    tables.first { $0.name == name }.map(ranges)
  }

  private static func ranges(_ entry: UnicodeTables.NamedSet) -> ScalarSet {
    let start = entry.start * 2
    return ScalarSet(table: Array(UnicodeTables.sets[start..<(start + entry.count * 2)]))
  }

  /// Rust's `char::is_uppercase`, from the same Unicode version as the rest.
  static func isUppercase(_ value: UInt32) -> Bool {
    if value < 0x80 {
      return value >= 0x41 && value <= 0x5A
    }
    return uppercase.contains(value)
  }

  private static let uppercase = set(in: UnicodeTables.binaryProperties, "Uppercase") ?? ScalarSet()

  /// UAX44-LM3 loose matching, as regex-syntax does it: no case, spaces,
  /// underscores, hyphens, non-ASCII or "is" prefix.
  static func normalize(_ name: String) -> String {
    var bytes = Array(name.utf8)
    let startsWithIs = bytes.count >= 2 && (bytes[0] | 0x20) == UInt8(ascii: "i") && (bytes[1] | 0x20) == UInt8(ascii: "s")
      && bytes[0].isASCIILetter && bytes[1].isASCIILetter
    if startsWithIs {
      bytes.removeFirst(2)
    }
    var result: [UInt8] = []
    for byte in bytes where byte != UInt8(ascii: " ") && byte != UInt8(ascii: "_") && byte != UInt8(ascii: "-") && byte < 0x80 {
      result.append(byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z") ? byte + 32 : byte)
    }
    // "isc" is ISO_Comment's alias, not "is" and the Other category.
    if startsWithIs && result == [UInt8(ascii: "c")] {
      result = Array("isc".utf8)
    }
    return String(decoding: result, as: UTF8.self)
  }
}

private extension UInt8 {
  var isASCIILetter: Bool {
    (self | 0x20) >= UInt8(ascii: "a") && (self | 0x20) <= UInt8(ascii: "z")
  }
}
