/// Flags that change how a pattern is interpreted. They can be set globally
/// and toggled inline with `(?flags)` / `(?flags:...)`.
struct ParseFlags: Hashable, Sendable {
  var caseInsensitive = false
  var dotMatchesNewline = false
  var swapGreed = false
  var ignoreWhitespace = false
  var unicode = true
}

/// A recursive descent parser for Rust `regex` crate syntax (the dialect ripgrep uses).
struct Parser {
  private let pattern: String
  private let chars: [Unicode.Scalar]
  private var pos = 0
  private var flags: ParseFlags

  init(_ pattern: String, flags: ParseFlags) {
    self.pattern = pattern
    self.chars = Array(pattern.unicodeScalars)
    self.flags = flags
  }

  static func parse(_ pattern: String, flags: ParseFlags) throws(RegexError) -> RegexNode {
    var parser = Parser(pattern, flags: flags)
    let node = try parser.parseAlternation(depth: 0)
    guard parser.pos == parser.chars.count else {
      throw parser.error("unopened group", at: parser.pos)
    }
    return node
  }

  // MARK: - Helpers

  private func error(_ message: String, at offset: Int? = nil) -> RegexError {
    RegexError(message: message, pattern: pattern, offset: offset ?? pos)
  }

  private var atEnd: Bool { pos >= chars.count }
  private var current: Unicode.Scalar? { pos < chars.count ? chars[pos] : nil }
  private func peek(_ offset: Int = 1) -> Unicode.Scalar? {
    pos + offset < chars.count ? chars[pos + offset] : nil
  }

  private mutating func skipWhitespaceIfExtended() {
    guard flags.ignoreWhitespace else { return }
    while let c = current {
      if c.properties.isWhitespace {
        pos += 1
      } else if c == "#" {
        while let d = current, d != "\n" { pos += 1 }
      } else {
        break
      }
    }
  }

  // MARK: - Structure

  private mutating func parseAlternation(depth: Int) throws(RegexError) -> RegexNode {
    guard depth < 250 else { throw error("exceeds the nesting limit") }
    let savedFlags = flags
    var branches: [RegexNode] = [try parseConcat(depth: depth)]
    while current == "|" {
      pos += 1
      branches.append(try parseConcat(depth: depth))
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
      items.append(try parseRepetitions(atom))
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
      var max: Int? = nil
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
      if flags.swapGreed { greedy.toggle() }
      if let max, max < min {
        throw error("invalid repetition count range, the start must be <= the end", at: opStart)
      }
      node = .repeat(node, min: min, max: max, greedy: greedy)
    }
  }

  private mutating func parseDecimal() -> Int? {
    var value = 0
    var digits = 0
    while let c = current, c.value >= 0x30, c.value <= 0x39, value <= 100_000 {
      value = value * 10 + Int(c.value - 0x30)
      digits += 1
      pos += 1
    }
    return digits > 0 ? value : nil
  }

  /// Parses `{n}`, `{n,}`, `{n,m}` or `{,m}`.
  private mutating func parseCounted() throws(RegexError) -> (Int, Int?) {
    let open = pos
    pos += 1 // {
    skipWhitespaceIfExtended()
    let lo = parseDecimal()
    skipWhitespaceIfExtended()
    var hi = lo
    if current == "," {
      pos += 1
      skipWhitespaceIfExtended()
      hi = parseDecimal()
      skipWhitespaceIfExtended()
      if lo == nil && hi == nil { throw error("repetition quantifier expects a valid decimal", at: open) }
    } else if lo == nil {
      throw error("repetition quantifier expects a valid decimal", at: open)
    }
    guard current == "}" else { throw error("unclosed counted repetition", at: open) }
    pos += 1
    if (lo ?? 0) > 1000 || (hi ?? 0) > 1000 {
      throw error("repetition count exceeds the size limit", at: open)
    }
    return (lo ?? 0, hi)
  }

  /// Parses `(` ... `)`. Returns nil for a flag-only group like `(?i)`, which
  /// changes the flags for the rest of the enclosing group.
  private mutating func parseGroup(depth: Int) throws(RegexError) -> RegexNode? {
    let open = pos
    pos += 1 // (
    if current == "?" {
      pos += 1
      switch current {
      case "P" where peek() == "<", "<" where peek() != "=" && peek() != "!":
        if current == "P" { pos += 1 }
        pos += 1 // <
        let nameStart = pos
        while let c = current, c != ">" {
          guard c == "_" || c.properties.isAlphabetic || c.properties.numericType != nil || c == "." || c == "[" || c == "]" else {
            throw error("invalid capture group character", at: pos)
          }
          pos += 1
        }
        guard current == ">" else { throw error("unclosed capture group name", at: nameStart) }
        guard pos > nameStart else { throw error("empty capture group name", at: nameStart) }
        pos += 1
      case "=", "!":
        throw error("look-around, including look-ahead and look-behind, is not supported", at: open)
      case "<" where peek() == "=" || peek() == "!":
        throw error("look-around, including look-ahead and look-behind, is not supported", at: open)
      default:
        // Flags: (?flags) or (?flags:...)
        var newFlags = flags
        var negate = false
        var sawFlag = false
        while let c = current, c != ":", c != ")" {
          switch c {
          case "-":
            guard !negate else { throw error("repeated negation in flags", at: pos) }
            negate = true
          case "i": newFlags.caseInsensitive = !negate
          case "m": break // multi-line: ^ and $ always match at line boundaries here.
          case "s": newFlags.dotMatchesNewline = !negate
          case "U": newFlags.swapGreed = !negate
          case "x": newFlags.ignoreWhitespace = !negate
          case "u": newFlags.unicode = !negate
          case "R": break // CRLF mode: accepted, treated as LF.
          default:
            throw error("unrecognized flag", at: pos)
          }
          if c != "-" { sawFlag = true }
          pos += 1
        }
        guard let terminator = current else { throw error("unclosed group", at: open) }
        if negate && !sawFlag { throw error("expected flag but got end of flags", at: pos) }
        pos += 1
        if terminator == ")" {
          flags = newFlags
          return nil
        }
        let saved = flags
        flags = newFlags
        let inner = try parseAlternation(depth: depth + 1)
        flags = saved
        guard current == ")" else { throw error("unclosed group", at: open) }
        pos += 1
        return .group(inner)
      }
    }
    let saved = flags
    let inner = try parseAlternation(depth: depth + 1)
    flags = saved
    guard current == ")" else { throw error("unclosed group", at: open) }
    pos += 1
    return .group(inner)
  }

  // MARK: - Atoms

  private mutating func parseAtom() throws(RegexError) -> RegexNode {
    guard let c = current else { throw error("unexpected end of pattern") }
    switch c {
    case ".":
      pos += 1
      if flags.unicode {
        return .set(flags.dotMatchesNewline ? .all : ScalarSet.all.removing(10))
      }
      return .byteSet(ScalarSet([0...0xFF]).removing(flags.dotMatchesNewline ? 0x100 : 10))
    case "^":
      pos += 1
      return .look(.startLine)
    case "$":
      pos += 1
      return .look(.endLine)
    case "[":
      return try parseClass()
    case "\\":
      return try parseEscape()
    default:
      pos += 1
      return literal(c.value)
    }
  }

  private func literal(_ value: UInt32) -> RegexNode {
    if flags.caseInsensitive && CaseFolding.hasCase(value) {
      return .set(ScalarSet(scalar: value).caseFolded())
    }
    return .char(value)
  }

  private mutating func parseEscape() throws(RegexError) -> RegexNode {
    let start = pos
    pos += 1 // backslash
    guard let c = current else { throw error("incomplete escape sequence, reached end of pattern prematurely", at: start) }
    pos += 1
    switch c {
    case "d", "D", "s", "S", "w", "W":
      return classNode(perlClass(c), negated: c.properties.isUppercase)
    case "p", "P":
      let set = try parseUnicodeClass(negated: c == "P", start: start)
      return classNode(set, negated: false)
    case "b":
      // `\b{name}` is a special word boundary only if the braces hold a name;
      // otherwise `{` starts a repetition, as in `\b{2}`.
      if current == "{", let first = peek(), first.properties.isAlphabetic {
        let open = pos
        pos += 1
        var name = ""
        while let d = current, d != "}" {
          name.unicodeScalars.append(d)
          pos += 1
        }
        guard current == "}" else { throw error("unclosed word boundary", at: open) }
        pos += 1
        switch name {
        case "start": return .look(flags.unicode ? .wordStart : .wordStartASCII)
        case "end": return .look(flags.unicode ? .wordEnd : .wordEndASCII)
        case "start-half": return .look(flags.unicode ? .wordStartHalf : .wordStartHalfASCII)
        case "end-half": return .look(flags.unicode ? .wordEndHalf : .wordEndHalfASCII)
        default: throw error("unrecognized word boundary assertion", at: open)
        }
      }
      return .look(flags.unicode ? .wordBoundary : .wordBoundaryASCII)
    case "B":
      return .look(flags.unicode ? .notWordBoundary : .notWordBoundaryASCII)
    case "<":
      return .look(flags.unicode ? .wordStart : .wordStartASCII)
    case ">":
      return .look(flags.unicode ? .wordEnd : .wordEndASCII)
    case "A":
      return .look(.startLine)
    case "z":
      return .look(.endLine)
    case "Z":
      throw error("unrecognized escape sequence", at: start)
    case "1"..."9":
      throw error("backreferences are not supported", at: start)
    default:
      pos = start
      let value = try parseEscapedScalar()
      if !flags.unicode, value >= 0x80, value <= 0xFF {
        return .byte(UInt8(value))
      }
      return literal(value)
    }
  }

  /// Parses an escape that denotes a single character (used both outside and inside classes).
  private mutating func parseEscapedScalar() throws(RegexError) -> UInt32 {
    let start = pos
    pos += 1 // backslash
    guard let c = current else { throw error("incomplete escape sequence, reached end of pattern prematurely", at: start) }
    pos += 1
    switch c {
    case "a": return 7
    case "f": return 12
    case "t": return 9
    case "n": return 10
    case "r": return 13
    case "v": return 11
    case "x": return try parseHex(digits: 2, start: start)
    case "u": return try parseHex(digits: 4, start: start)
    case "U": return try parseHex(digits: 8, start: start)
    case "0"..."7" where c == "0":
      throw error("backreferences are not supported", at: start)
    default:
      // Any ASCII punctuation (and space) may be escaped to stand for itself.
      if c.isASCII, !c.properties.isAlphabetic, c.properties.numericType == nil {
        return c.value
      }
      throw error("unrecognized escape sequence", at: start)
    }
  }

  private mutating func parseHex(digits: Int, start: Int) throws(RegexError) -> UInt32 {
    var text = ""
    if current == "{" {
      pos += 1
      while let c = current, c != "}" {
        text.unicodeScalars.append(c)
        pos += 1
      }
      guard current == "}" else { throw error("unclosed hexadecimal literal", at: start) }
      pos += 1
    } else {
      for _ in 0..<digits {
        guard let c = current else { throw error("incomplete escape sequence, reached end of pattern prematurely", at: start) }
        text.unicodeScalars.append(c)
        pos += 1
      }
    }
    guard !text.isEmpty, text.count <= 8, let value = UInt32(text, radix: 16) else {
      throw error("invalid hexadecimal digit", at: start)
    }
    guard Unicode.Scalar(value) != nil else {
      throw error("hexadecimal literal is not a Unicode scalar value", at: start)
    }
    return value
  }

  private func classNode(_ set: ScalarSet, negated: Bool) -> RegexNode {
    var s = flags.caseInsensitive ? set.caseFolded() : set
    if negated { s = s.inverted() }
    return .set(s)
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

  private mutating func parseUnicodeClass(negated: Bool, start: Int) throws(RegexError) -> ScalarSet {
    var name = ""
    var negate = negated
    if current == "{" {
      pos += 1
      while let c = current, c != "}" {
        name.unicodeScalars.append(c)
        pos += 1
      }
      guard current == "}" else { throw error("unclosed Unicode class", at: start) }
      pos += 1
    } else if let c = current {
      name.unicodeScalars.append(c)
      pos += 1
    } else {
      throw error("incomplete escape sequence, reached end of pattern prematurely", at: start)
    }
    if name.hasPrefix("^") {
      negate.toggle()
      name.removeFirst()
    }
    guard let set = UnicodeClasses.lookup(name) else {
      throw error("Unicode property not found", at: start)
    }
    return negate ? set.inverted() : set
  }

  // MARK: - Bracketed classes

  private mutating func parseClass() throws(RegexError) -> RegexNode {
    let set = try parseClassBody()
    return .set(set)
  }

  /// Parses `[...]` starting at the opening bracket, returning the final set
  /// (already case folded and negated as needed).
  private mutating func parseClassBody() throws(RegexError) -> ScalarSet {
    let open = pos
    pos += 1 // [
    var negated = false
    if current == "^" {
      negated = true
      pos += 1
    }
    var result = ScalarSet()
    var pendingOp: ((ScalarSet, ScalarSet) -> ScalarSet)? = nil
    var lhs: ScalarSet? = nil
    var first = true
    while true {
      guard let c = current else { throw error("unclosed character class", at: open) }
      if c == "]" && !first { pos += 1; break }
      first = false
      // Set operators.
      if (c == "&" && peek() == "&") || (c == "-" && peek() == "-") || (c == "~" && peek() == "~") {
        let op: (ScalarSet, ScalarSet) -> ScalarSet
        switch c {
        case "&": op = { $0.intersection($1) }
        case "-": op = { $0.subtracting($1) }
        default: op = { $0.symmetricDifference($1) }
        }
        pos += 2
        let left = pendingOp.map { $0(lhs ?? ScalarSet(), result) } ?? result
        lhs = left
        pendingOp = op
        result = ScalarSet()
        continue
      }
      if flags.ignoreWhitespace, c.properties.isWhitespace { pos += 1; continue }
      if c == "[" {
        if peek() == ":" , let posix = try parsePosixClass() {
          result.formUnion(posix)
          continue
        }
        result.formUnion(try parseClassBody())
        continue
      }
      if c == "\\", let next = peek(), "dDsSwWpP".unicodeScalars.contains(next) {
        pos += 2
        if next == "p" || next == "P" {
          result.formUnion(try parseUnicodeClass(negated: next == "P", start: pos - 2))
        } else {
          let base = perlClass(next)
          result.formUnion(next.properties.isUppercase ? base.inverted() : base)
        }
        continue
      }
      let low = try parseClassChar()
      if current == "-", let after = peek(), after != "]" {
        pos += 1
        let high = try parseClassChar()
        guard low <= high else { throw error("invalid character class range, the start must be <= the end", at: open) }
        result.insert(low...high)
      } else {
        result.insert(low...low)
      }
    }
    if let pendingOp { result = pendingOp(lhs ?? ScalarSet(), result) }
    if flags.caseInsensitive { result = result.caseFolded() }
    if negated { result = result.inverted() }
    return result
  }

  private mutating func parseClassChar() throws(RegexError) -> UInt32 {
    guard let c = current else { throw error("unclosed character class") }
    if c == "\\" { return try parseEscapedScalar() }
    pos += 1
    return c.value
  }

  /// Parses `[:name:]` or `[:^name:]`. Returns nil (without consuming) if this
  /// is not a POSIX class, in which case `[` starts a nested class.
  private mutating func parsePosixClass() throws(RegexError) -> ScalarSet? {
    let start = pos
    pos += 2 // [:
    var negate = false
    if current == "^" {
      negate = true
      pos += 1
    }
    var name = ""
    while let c = current, c.properties.isAlphabetic, c.isASCII {
      name.unicodeScalars.append(c)
      pos += 1
    }
    guard current == ":", peek() == "]" else {
      pos = start
      return nil
    }
    pos += 2
    let set: ScalarSet
    switch name {
    case "alnum": set = ScalarSet([0x30...0x39, 0x41...0x5A, 0x61...0x7A])
    case "alpha": set = ScalarSet([0x41...0x5A, 0x61...0x7A])
    case "ascii": set = ScalarSet([0...0x7F])
    case "blank": set = ScalarSet([9...9, 32...32])
    case "cntrl": set = ScalarSet([0...0x1F, 0x7F...0x7F])
    case "digit": set = ScalarSet([0x30...0x39])
    case "graph": set = ScalarSet([0x21...0x7E])
    case "lower": set = ScalarSet([0x61...0x7A])
    case "print": set = ScalarSet([0x20...0x7E])
    case "punct": set = ScalarSet([0x21...0x2F, 0x3A...0x40, 0x5B...0x60, 0x7B...0x7E])
    case "space": set = ScalarSet([9...13, 32...32])
    case "upper": set = ScalarSet([0x41...0x5A])
    case "word": set = ScalarSet([0x30...0x39, 0x41...0x5A, 0x5F...0x5F, 0x61...0x7A])
    case "xdigit": set = ScalarSet([0x30...0x39, 0x41...0x46, 0x61...0x66])
    default: throw error("invalid ASCII class", at: start)
    }
    return negate ? set.inverted() : set
  }
}

/// Unicode property classes for `\p{...}`.
enum UnicodeClasses {
  static func lookup(_ rawName: String) -> ScalarSet? {
    // Loose matching as in UAX#44: ignore case, whitespace, underscores and hyphens.
    let name = String(rawName.lowercased().unicodeScalars.filter { $0 != "_" && $0 != "-" && $0 != " " })
    let categoryAliases: [String: [String]] = [
      "l": ["Lu", "Ll", "Lt", "Lm", "Lo"], "letter": ["Lu", "Ll", "Lt", "Lm", "Lo"],
      "lu": ["Lu"], "uppercaseletter": ["Lu"], "ll": ["Ll"], "lowercaseletter": ["Ll"],
      "lt": ["Lt"], "titlecaseletter": ["Lt"], "lm": ["Lm"], "modifierletter": ["Lm"],
      "lo": ["Lo"], "otherletter": ["Lo"], "lc": ["Lu", "Ll", "Lt"], "casedletter": ["Lu", "Ll", "Lt"],
      "m": ["Mn", "Mc", "Me"], "mark": ["Mn", "Mc", "Me"], "combiningmark": ["Mn", "Mc", "Me"],
      "mn": ["Mn"], "nonspacingmark": ["Mn"], "mc": ["Mc"], "spacingmark": ["Mc"],
      "me": ["Me"], "enclosingmark": ["Me"],
      "n": ["Nd", "Nl", "No"], "number": ["Nd", "Nl", "No"],
      "nd": ["Nd"], "decimalnumber": ["Nd"], "digit": ["Nd"], "nl": ["Nl"], "letternumber": ["Nl"],
      "no": ["No"], "othernumber": ["No"],
      "p": ["Pc", "Pd", "Ps", "Pe", "Pi", "Pf", "Po"], "punctuation": ["Pc", "Pd", "Ps", "Pe", "Pi", "Pf", "Po"],
      "pc": ["Pc"], "connectorpunctuation": ["Pc"], "pd": ["Pd"], "dashpunctuation": ["Pd"],
      "ps": ["Ps"], "openpunctuation": ["Ps"], "pe": ["Pe"], "closepunctuation": ["Pe"],
      "pi": ["Pi"], "initialpunctuation": ["Pi"], "pf": ["Pf"], "finalpunctuation": ["Pf"],
      "po": ["Po"], "otherpunctuation": ["Po"],
      "s": ["Sm", "Sc", "Sk", "So"], "symbol": ["Sm", "Sc", "Sk", "So"],
      "sm": ["Sm"], "mathsymbol": ["Sm"], "sc": ["Sc"], "currencysymbol": ["Sc"],
      "sk": ["Sk"], "modifiersymbol": ["Sk"], "so": ["So"], "othersymbol": ["So"],
      "z": ["Zs", "Zl", "Zp"], "separator": ["Zs", "Zl", "Zp"],
      "zs": ["Zs"], "spaceseparator": ["Zs"], "zl": ["Zl"], "lineseparator": ["Zl"],
      "zp": ["Zp"], "paragraphseparator": ["Zp"],
      "cc": ["Cc"], "control": ["Cc"], "cf": ["Cf"], "format": ["Cf"],
      "cs": ["Cs"], "surrogate": ["Cs"], "co": ["Co"], "privateuse": ["Co"],
    ]
    if let categories = categoryAliases[name] {
      var set = ScalarSet()
      for c in categories {
        if let table = UnicodeTables.generalCategory(c) { set.formUnion(ScalarSet(table: table)) }
      }
      return set
    }
    switch name {
    case "c", "other":
      return unassigned().union(lookup("Cc")!).union(lookup("Cf")!).union(lookup("Cs")!).union(lookup("Co")!)
    case "cn", "unassigned":
      return unassigned()
    case "any":
      return .all
    case "ascii":
      return ScalarSet([0...0x7F])
    case "alphabetic", "alpha":
      return ScalarSet(table: UnicodeTables.alphabetic)
    case "whitespace", "wspace", "space":
      return ScalarSet(table: UnicodeTables.perlSpace)
    case "uppercase", "upper":
      return ScalarSet(table: UnicodeTables.uppercase)
    case "lowercase", "lower":
      return ScalarSet(table: UnicodeTables.lowercase)
    default:
      return nil
    }
  }

  private static func unassigned() -> ScalarSet {
    var assigned = ScalarSet()
    for c in ["Lu", "Ll", "Lt", "Lm", "Lo", "Mn", "Mc", "Me", "Nd", "Nl", "No", "Pc", "Pd", "Ps", "Pe",
              "Pi", "Pf", "Po", "Sm", "Sc", "Sk", "So", "Zs", "Zl", "Zp", "Cc", "Cf", "Cs", "Co"] {
      if let table = UnicodeTables.generalCategory(c) { assigned.formUnion(ScalarSet(table: table)) }
    }
    return assigned.inverted()
  }
}
