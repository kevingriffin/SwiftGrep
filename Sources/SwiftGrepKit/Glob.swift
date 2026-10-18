import Darwin
import GrepRegex

/// A glob with the syntax and semantics of ripgrep's globset (as configured
/// for ignore files, `--glob` and file types), matched against byte paths.
///
/// Globs are matched byte by byte, as globset's regexes are: `?` is one byte
/// other than `/`, `*` any run of them, and a class is a set of bytes (a
/// non-ASCII character in a class stands for its separate UTF-8 bytes). `**`
/// matches across directories when it forms a whole path component, and
/// `{a,b}` matches either alternative. Unanchored globs (patterns without a
/// slash) match the final path component at any depth.
struct Glob: Sendable, Hashable {
  enum Kind: UInt8, Sendable, Hashable {
    /// Literal bytes: `bytes[start..<end]`.
    case literal
    /// `?`: one byte other than `/`.
    case one
    /// `*`: any run of bytes other than `/`.
    case star
    /// A leading `**/`: nothing, or anything ending in `/`.
    case anyPrefix
    /// A trailing `/**`: `/` and then anything.
    case anySuffix
    /// `/**/` in the middle: `/`, or `/` anything `/`.
    case anyDirectories
    /// A glob that is just `**`: everything.
    case anything
    /// A class: one byte in `classes[start]`.
    case set
    /// `{`: the start of alternatives, each ended by `branch` or `join`.
    case fork
    /// `,`: the next alternative.
    case branch
    /// `}`: the end of alternatives.
    case join
  }

  /// One element of the pattern. Literals and classes refer to `bytes` and
  /// `classes` by position, so tokens are plain values and matching does no
  /// reference counting.
  struct Token: Sendable, Hashable {
    let kind: Kind
    let start: Int32
    let end: Int32
  }

  /// The fast path chosen for the token sequence. `exact`, `suffix` and
  /// `prefix` globs consist of one literal, which is all of `bytes`.
  enum Strategy: Sendable, Hashable {
    case exact
    /// `*literal`
    case suffix
    /// `literal*`
    case prefix
    /// `literal/**`
    case prefixAnything
    case always
    case general
  }

  /// A glob that can't be parsed, with globset's description.
  struct ParseError: Error, Sendable {
    let message: String
  }

  let tokens: [Token]
  /// The bytes of every literal token, concatenated.
  let bytes: [UInt8]
  let classes: [ByteClass]
  let strategy: Strategy
  /// For `general` globs: the length of a literal that the glob starts or
  /// ends with (the first or last bytes of `bytes`), checked before trying
  /// a full match.
  let prefixLength: Int
  let suffixLength: Int
  /// Whether the glob is matched against the whole relative path rather than
  /// just the file name.
  let anchored: Bool
  let caseInsensitive: Bool
  /// Whether the pattern has alternatives (`fork` tokens).
  let hasAlternatives: Bool

  /// Parses a glob, falling back to matching the pattern literally if it is
  /// invalid (for callers that validated it already).
  init(_ pattern: [UInt8], anchored: Bool, caseInsensitive: Bool = false) {
    if let glob = try? Glob(parsing: pattern, anchored: anchored, caseInsensitive: caseInsensitive) {
      self = glob
    } else {
      self.init(compiling: [.literal(Array(pattern))], anchored: anchored, caseInsensitive: caseInsensitive)
    }
  }

  /// Parses a glob. `anchored` is decided by the caller (gitignore rules
  /// decide it from the presence of a slash). An unclosed `[` is a literal
  /// if `allowUnclosedClass` (in ignore files), and an error otherwise.
  init(parsing pattern: [UInt8], anchored: Bool, caseInsensitive: Bool, allowUnclosedClass: Bool = false) throws(ParseError) {
    var parser = GlobParser(pattern, allowUnclosedClass: allowUnclosedClass)
    let items = try parser.parse()
    self.init(compiling: items, anchored: anchored, caseInsensitive: caseInsensitive)
  }

  private init(compiling parsed: [GlobItem], anchored: Bool, caseInsensitive: Bool) {
    var items = parsed
    var anchored = anchored
    // `**/rest` matches like an unanchored `rest` when `rest` can't match a
    // slash; and an unanchored glob that can (a negated class matches `/`)
    // must be matched as `**/glob` against the whole path. A glob that is
    // just `**` matches everything either way.
    if items == [.anyPrefix] {
      anchored = true
    } else if anchored, items.count > 1, items.first == .anyPrefix, !GlobItem.canMatchSlash(items.dropFirst()) {
      items.removeFirst()
      anchored = false
    } else if !anchored, GlobItem.canMatchSlash(items[...]) {
      items.insert(.anyPrefix, at: 0)
      anchored = true
    }
    self.anchored = anchored
    self.caseInsensitive = caseInsensitive
    var tokens: [Token] = []
    var bytes: [UInt8] = []
    var classes: [ByteClass] = []
    var forks = false
    func emit(_ items: some Collection<GlobItem>) {
      for item in items {
        switch item {
        case let .literal(literal):
          let start = bytes.count
          bytes.append(contentsOf: caseInsensitive ? literal.map(ByteClass.lower) : literal)
          if let last = tokens.last, last.kind == .literal, Int(last.end) == start {
            tokens[tokens.count - 1] = Token(kind: .literal, start: last.start, end: Int32(bytes.count))
          } else {
            tokens.append(Token(kind: .literal, start: Int32(start), end: Int32(bytes.count)))
          }
        case .one: tokens.append(Token(kind: .one, start: 0, end: 0))
        case .star: tokens.append(Token(kind: .star, start: 0, end: 0))
        case .anyPrefix: tokens.append(Token(kind: .anyPrefix, start: 0, end: 0))
        case .anySuffix: tokens.append(Token(kind: .anySuffix, start: 0, end: 0))
        case .anyDirectories: tokens.append(Token(kind: .anyDirectories, start: 0, end: 0))
        case let .set(set, negated):
          // Like `(?i)`, case folding applies before negation.
          let folded = caseInsensitive ? set.caseFolded : set
          tokens.append(Token(kind: .set, start: Int32(classes.count), end: 0))
          classes.append(negated ? folded.inverted : folded)
        case let .alternatives(branches) where branches.isEmpty:
          continue
        case let .alternatives(branches):
          forks = true
          tokens.append(Token(kind: .fork, start: 0, end: 0))
          for (i, branch) in branches.enumerated() {
            if i > 0 {
              tokens.append(Token(kind: .branch, start: 0, end: 0))
            }
            emit(branch)
          }
          tokens.append(Token(kind: .join, start: 0, end: 0))
        }
      }
    }
    // A glob that is just `**` matches everything.
    if items == [.anyPrefix] {
      tokens = [Token(kind: .anything, start: 0, end: 0)]
    } else {
      emit(items)
    }
    hasAlternatives = forks
    let kinds = tokens.map(\.kind)
    let first = tokens.first, last = tokens.last
    var prefixLength = !forks && first?.kind == .literal ? Int(first!.end - first!.start) : 0
    let suffixLength = !forks && tokens.count > 1 && last?.kind == .literal ? Int(last!.end - last!.start) : 0
    let strategy: Strategy
    switch kinds {
    case [], [.literal]: strategy = .exact
    case [.anything]: strategy = .always
    case [.star, .literal] where !anchored || !bytes.contains(UInt8(ascii: "/")): strategy = .suffix
    case [.literal, .star] where !anchored || !bytes.contains(UInt8(ascii: "/")): strategy = .prefix
    case [.literal, .anySuffix], [.literal, .anyDirectories, .star]:
      // `dir/**` and `dir/**/*`: everything below `dir/`.
      bytes.append(UInt8(ascii: "/"))
      tokens = [Token(kind: .literal, start: 0, end: Int32(bytes.count)), Token(kind: .anything, start: 0, end: 0)]
      prefixLength = bytes.count
      strategy = .prefixAnything
    default: strategy = .general
    }
    self.tokens = tokens
    self.bytes = bytes
    self.classes = classes
    self.prefixLength = prefixLength
    self.suffixLength = suffixLength
    self.strategy = strategy
  }

  /// Matches the glob against `path` (relative to the glob's base). For
  /// unanchored globs only the final component (starting at `nameStart`) is used.
  func matches(_ path: Span<UInt8>, nameStart: Int) -> Bool {
    let start = anchored ? 0 : nameStart
    let count = path.count - start
    let slash = UInt8(ascii: "/")
    let literal = bytes.span
    switch strategy {
    case .always:
      return true
    case .exact:
      return literal.count == count && equal(path, at: start, literal)
    case .suffix:
      guard literal.count <= count else { return false }
      // The star must not cross a slash.
      if anchored, path.firstIndex(of: slash, in: start..<(path.count - literal.count)) != nil {
        return false
      }
      return equal(path, at: path.count - literal.count, literal)
    case .prefix:
      guard literal.count <= count, equal(path, at: start, literal) else { return false }
      return path.firstIndex(of: slash, in: (start + literal.count)..<path.count) == nil
    case .prefixAnything:
      return literal.count <= count && equal(path, at: start, literal)
    case .general:
      guard prefixLength + suffixLength <= count,
            equal(path, at: start, literal.extracting(..<prefixLength)),
            equal(path, at: path.count - suffixLength, literal.extracting((literal.count - suffixLength)...))
      else { return false }
      return matchGeneral(path, from: start)
    }
  }

  func matches(_ path: [UInt8]) -> Bool {
    let nameStart = (path.lastIndex(of: UInt8(ascii: "/")) ?? -1) + 1
    return matches(path.span, nameStart: nameStart)
  }

  @inline(__always)
  private func equal(_ path: Span<UInt8>, at offset: Int, _ literal: Span<UInt8>) -> Bool {
    Self.equal(path, at: offset, literal, caseInsensitive: caseInsensitive)
  }

  @inline(__always)
  fileprivate static func equal(_ path: Span<UInt8>, at offset: Int, _ literal: Span<UInt8>, caseInsensitive: Bool) -> Bool {
    var k = 0
    if caseInsensitive {
      while k < literal.count {
        if ByteClass.lower(path[offset + k]) != literal[k] {
          return false
        }
        k += 1
      }
    } else {
      while k < literal.count {
        if path[offset + k] != literal[k] {
          return false
        }
        k += 1
      }
    }
    return true
  }

  // MARK: - General matching

  /// Matches the token sequence by tracking the set of path positions that
  /// each prefix of the pattern can reach, as a bitset. This takes
  /// O(tokens × path length) time and no recursion whatever the pattern, so
  /// a hostile ignore file (say `*a*a*a*a*a*a*b`, which makes backtracking
  /// matchers take exponential time) cannot stall the search. Alternatives
  /// are tracked with a stack of sets, not by recursion either.
  private func matchGeneral(_ path: Span<UInt8>, from start: Int) -> Bool {
    let positions = path.count - start + 1
    let words = (positions + 63) / 64
    if words <= 8 && !hasAlternatives {
      // Paths up to 511 bytes, the common case, use stack storage.
      var a = InlineArray<8, UInt64>(repeating: 0)
      var b = InlineArray<8, UInt64>(repeating: 0)
      var reached = a.mutableSpan
      var next = b.mutableSpan
      var none = InlineArray<0, UInt64>(repeating: 0)
      var frames = none.mutableSpan
      return simulate(path, from: start, words: words, &reached, &next, &frames)
    }
    var a = [UInt64](repeating: 0, count: words)
    var b = [UInt64](repeating: 0, count: words)
    var reached = a.mutableSpan
    var next = b.mutableSpan
    // Two sets (the input and the union so far) per level of alternatives.
    var depth = 0
    var maximum = 0
    for token in tokens {
      if token.kind == .fork {
        depth += 1
        maximum = max(maximum, depth)
      } else if token.kind == .join {
        depth -= 1
      }
    }
    var stack = [UInt64](repeating: 0, count: 2 * maximum * words)
    var frames = stack.mutableSpan
    return simulate(path, from: start, words: words, &reached, &next, &frames)
  }

  private func simulate(
    _ path: Span<UInt8>, from start: Int, words: Int,
    _ reached: inout MutableSpan<UInt64>, _ next: inout MutableSpan<UInt64>, _ frames: inout MutableSpan<UInt64>,
  ) -> Bool {
    let length = path.count - start
    let slash = UInt8(ascii: "/")
    let literals = bytes.span
    let sets = classes.span
    @inline(__always) func isSet(_ set: borrowing MutableSpan<UInt64>, _ i: Int) -> Bool {
      set[i >> 6] & (1 << UInt64(i & 63)) != 0
    }
    @inline(__always) func insert(_ set: inout MutableSpan<UInt64>, _ i: Int) {
      set[i >> 6] |= 1 << UInt64(i & 63)
    }
    // The smallest reached position, or nil.
    func first(_ set: borrowing MutableSpan<UInt64>) -> Int? {
      for w in 0..<words where set[w] != 0 {
        return w << 6 | set[w].trailingZeroBitCount
      }
      return nil
    }
    for w in 0..<words {
      reached[w] = 0
    }
    reached[0] = 1
    var level = 0
    for token in tokens {
      switch token.kind {
      case .fork:
        // Save the input and start an empty union.
        let base = 2 * level * words
        for w in 0..<words {
          frames[base + w] = reached[w]
          frames[base + words + w] = 0
        }
        level += 1
        continue
      case .branch, .join:
        let base = 2 * (level - 1) * words
        for w in 0..<words {
          frames[base + words + w] |= reached[w]
          reached[w] = token.kind == .branch ? frames[base + w] : frames[base + words + w]
        }
        if token.kind == .join {
          level -= 1
        }
        continue
      default:
        break
      }
      for w in 0..<words {
        next[w] = 0
      }
      var any = false
      switch token.kind {
      case .literal:
        // Only the reachable positions are visited.
        let literal = literals.extracting(Int(token.start)..<Int(token.end))
        for w in 0..<words {
          var bits = reached[w]
          while bits != 0 {
            let p = w << 6 | bits.trailingZeroBitCount
            bits &= bits &- 1
            if length - p >= literal.count, Self.equal(path, at: start + p, literal, caseInsensitive: caseInsensitive) {
              insert(&next, p + literal.count)
              any = true
            }
          }
        }
      case .one, .set:
        for w in 0..<words {
          var bits = reached[w]
          while bits != 0 {
            let p = w << 6 | bits.trailingZeroBitCount
            bits &= bits &- 1
            guard p < length else { continue }
            let byte = path[start + p]
            if token.kind == .one ? byte != slash : sets[Int(token.start)].contains(byte) {
              insert(&next, p + 1)
              any = true
            }
          }
        }
      case .star:
        // Any run of bytes other than `/`.
        var active = false
        for q in 0...length {
          if isSet(reached, q) {
            active = true
          } else if active && path[start + q - 1] == slash {
            active = false
          }
          if active {
            insert(&next, q)
            any = true
          }
        }
      case .anyPrefix:
        // Nothing, or anything ending in `/`.
        guard let from = first(reached) else { break }
        for q in 0...length where isSet(reached, q) || (q > from && path[start + q - 1] == slash) {
          insert(&next, q)
          any = true
        }
      case .anySuffix:
        // `/`, then anything.
        var seen = false
        for q in 0...length {
          if seen {
            insert(&next, q)
            any = true
          } else if q < length, isSet(reached, q), path[start + q] == slash {
            seen = true
          }
        }
      case .anyDirectories:
        // `/`, or `/` anything `/`.
        var seen = false
        for q in 0..<length where path[start + q] == slash {
          if seen || isSet(reached, q) {
            insert(&next, q + 1)
            any = true
          }
          if isSet(reached, q) {
            seen = true
          }
        }
      case .anything:
        guard let from = first(reached) else { break }
        for q in from...length {
          insert(&next, q)
          any = true
        }
      case .fork, .branch, .join:
        break
      }
      // Inside alternatives, a branch that reaches nothing just contributes
      // nothing to the union.
      guard any || level > 0 else { return false }
      for w in 0..<words {
        reached[w] = next[w]
      }
    }
    return isSet(reached, length)
  }
}

/// A set of bytes, for glob classes.
struct ByteClass: Sendable, Hashable {
  var bits = InlineArray<4, UInt64>(repeating: 0)

  @inline(__always)
  func contains(_ byte: UInt8) -> Bool {
    bits[Int(byte >> 6)] & (1 << UInt64(byte & 63)) != 0
  }

  mutating func insert(_ range: ClosedRange<UInt8>) {
    for byte in range {
      bits[Int(byte >> 6)] |= 1 << UInt64(byte & 63)
    }
  }

  var inverted: ByteClass {
    var result = ByteClass()
    for i in 0..<4 {
      result.bits[i] = ~bits[i]
    }
    return result
  }

  /// With the other case of every ASCII letter, as `(?i)` adds it.
  var caseFolded: ByteClass {
    var result = self
    for byte in UInt8(ascii: "A")...UInt8(ascii: "Z") where contains(byte) || contains(byte | 0x20) {
      result.insert(byte...byte)
      result.insert((byte | 0x20)...(byte | 0x20))
    }
    return result
  }

  static func == (a: ByteClass, b: ByteClass) -> Bool {
    a.bits[0] == b.bits[0] && a.bits[1] == b.bits[1] && a.bits[2] == b.bits[2] && a.bits[3] == b.bits[3]
  }

  func hash(into hasher: inout Hasher) {
    for i in 0..<4 {
      hasher.combine(bits[i])
    }
  }

  @inline(__always)
  static func lower(_ b: UInt8) -> UInt8 {
    b >= 0x41 && b <= 0x5A ? b | 0x20 : b
  }
}

/// A parsed glob element (globset's tokens).
enum GlobItem: Sendable, Hashable {
  case literal([UInt8])
  case one
  case star
  case anyPrefix
  case anySuffix
  case anyDirectories
  /// A class; a negated one (`[!...]`) matches `/` too.
  case set(ByteClass, negated: Bool)
  /// Alternatives; empty ones are dropped, as in globset's regex.
  case alternatives([[GlobItem]])

  /// Whether the items can match a `/` (so a pattern without one could still
  /// match across directories).
  static func canMatchSlash(_ items: ArraySlice<GlobItem>) -> Bool {
    var pending: [ArraySlice<GlobItem>] = []
    var next: ArraySlice<GlobItem>? = items
    while let current = next ?? pending.popLast() {
      next = nil
      for item in current {
        switch item {
        case let .literal(bytes) where bytes.contains(UInt8(ascii: "/")): return true
        case .anyPrefix, .anySuffix, .anyDirectories: return true
        case let .set(set, negated) where set.contains(UInt8(ascii: "/")) != negated: return true
        case let .alternatives(branches): pending += branches.map { $0[...] }
        default: break
        }
      }
    }
    return false
  }
}

/// globset's parser, with the options ripgrep uses (`/` is never matched by
/// wildcards, and `\` escapes).
struct GlobParser {
  /// Braces nest at most this deep, which keeps compilation free of deep
  /// recursion for hostile patterns.
  static let maxNesting = 64

  private let pattern: [UInt8]
  private var index = 0
  private var previous: Unicode.Scalar?
  private var current: Unicode.Scalar?
  private let allowUnclosedClass: Bool
  private var foundUnclosedClass = false
  /// The alternatives being parsed: `branches` holds every open branch, and
  /// `stack` where each group of alternatives starts in it.
  private var branches: [[GlobItem]] = [[]]
  private var stack: [Int] = []

  init(_ pattern: [UInt8], allowUnclosedClass: Bool) {
    self.pattern = pattern
    self.allowUnclosedClass = allowUnclosedClass
  }

  private func error(_ message: String) -> Glob.ParseError {
    Glob.ParseError(message: message)
  }

  /// The character at `position` and its length (invalid UTF-8 reads as
  /// U+FFFD, one byte at a time).
  private func character(at position: Int) -> (Unicode.Scalar, Int)? {
    guard position < pattern.count else { return nil }
    let byte = pattern[position]
    if byte < 0x80 {
      return (Unicode.Scalar(byte), 1)
    }
    if let decoded = GrepRegex.UTF8Decoding.decodeScalar(pattern.span, at: position, end: pattern.count),
       let scalar = Unicode.Scalar(decoded.value)
    {
      return (scalar, decoded.length)
    }
    return ("\u{FFFD}", 1)
  }

  private mutating func bump() -> Unicode.Scalar? {
    previous = current
    current = nil
    if let (c, length) = character(at: index) {
      current = c
      index += length
    }
    return current
  }

  private func peek() -> Unicode.Scalar? {
    character(at: index)?.0
  }

  private mutating func push(_ item: GlobItem) {
    branches[branches.count - 1].append(item)
  }

  /// Appends a character, merging it into a literal that ends the branch.
  private mutating func pushLiteral(_ c: Unicode.Scalar) {
    let last = branches.count - 1
    if case var .literal(bytes)? = branches[last].last {
      branches[last].removeLast()
      bytes.append(contentsOf: String(c).utf8)
      branches[last].append(.literal(bytes))
    } else {
      branches[last].append(.literal(Array(String(c).utf8)))
    }
  }

  /// Removes the branch's last token, as globset's `pop_token` does; a
  /// merged literal gives up just its last character.
  private mutating func popToken() -> GlobItem? {
    let last = branches.count - 1
    guard case var .literal(bytes)? = branches[last].last, bytes.count > 1 else {
      return branches[last].popLast()
    }
    branches[last].removeLast()
    let removed = bytes.removeLast()
    branches[last].append(.literal(bytes))
    return .literal([removed])
  }

  mutating func parse() throws(Glob.ParseError) -> [GlobItem] {
    while let c = bump() {
      switch c {
      case "?": push(.one)
      case "*": parseStar()
      case "[" where !foundUnclosedClass: try parseClass()
      case "{":
        guard stack.count < Self.maxNesting else { throw error("alternate groups are nested too deeply") }
        stack.append(branches.count)
        branches.append([])
      case "}":
        guard let start = stack.popLast() else {
          throw error("unopened alternate group; missing '{' (maybe escape '}' with '[}]'?)")
        }
        // Empty alternatives match nothing more (even `{}` stays a token, so
        // `**{}` is not the glob `**`).
        let alternatives = Array(branches[start...]).filter { !$0.isEmpty }
        branches.removeSubrange(start...)
        push(.alternatives(alternatives))
      case "," where !stack.isEmpty:
        branches.append([])
      case "\\":
        guard let escaped = bump() else { throw error("dangling '\\'") }
        pushLiteral(escaped)
      default:
        pushLiteral(c)
      }
    }
    guard stack.isEmpty else {
      throw error("unclosed alternate group; missing '}' (maybe escape '{' with '[{]'?)")
    }
    return branches[0]
  }

  /// `*`, or `**` when it forms a whole path component.
  private mutating func parseStar() {
    let before = previous
    guard peek() == "*" else {
      push(.star)
      return
    }
    _ = bump()
    if branches[branches.count - 1].isEmpty {
      if let next = peek(), next != "/" {
        push(.star)
        push(.star)
      } else {
        push(.anyPrefix)
        _ = bump()
      }
      return
    }
    if before != "/" && (branches.count <= 1 || (before != "," && before != "{")) {
      push(.star)
      push(.star)
      return
    }
    let isSuffix: Bool
    switch peek() {
    case nil:
      isSuffix = true
    case ","? where branches.count >= 2, "}"? where branches.count >= 2:
      isSuffix = true
    case "/"?:
      _ = bump()
      isSuffix = false
    default:
      push(.star)
      push(.star)
      return
    }
    switch popToken() {
    case .anyPrefix?: push(.anyPrefix)
    case .anySuffix?: push(.anySuffix)
    default: push(isSuffix ? .anySuffix : .anyDirectories)
    }
  }

  /// `[...]`: `!` or `^` negates, a leading `]` or `-` is literal, and there
  /// are no escapes inside. Characters become their UTF-8 bytes, as in
  /// globset's byte-oriented regexes.
  private mutating func parseClass() throws(Glob.ParseError) {
    let saved = (index, previous, current)
    var ranges: [(Unicode.Scalar, Unicode.Scalar)] = []
    var negated = false
    if peek() == "!" || peek() == "^" {
      _ = bump()
      negated = true
    }
    var first = true
    var inRange = false
    while true {
      guard let c = bump() else {
        guard allowUnclosedClass else { throw error("unclosed character class; missing ']'") }
        (index, previous, current) = saved
        foundUnclosedClass = true
        pushLiteral("[")
        return
      }
      switch c {
      case "]" where !first:
        if inRange {
          ranges.append(("-", "-"))
        }
        var set = ByteClass()
        for (low, high) in ranges {
          Self.addBytes(low, high, to: &set)
        }
        push(.set(set, negated: negated))
        return
      case "-" where !first && !inRange:
        inRange = true
      default:
        if inRange {
          let low = ranges[ranges.count - 1].0
          guard low <= c else { throw error("invalid range; '\(low)' > '\(c)'") }
          ranges[ranges.count - 1].1 = c
        } else {
          ranges.append((c, c))
        }
        inRange = false
      }
      first = false
    }
  }

  /// The bytes a class item stands for in globset's byte regex: each byte
  /// of a character, and for a range the bytes on either side with a range
  /// between the last byte of `low` and the first of `high`.
  private static func addBytes(_ low: Unicode.Scalar, _ high: Unicode.Scalar, to set: inout ByteClass) {
    let lowBytes = Array(String(low).utf8)
    let highBytes = Array(String(high).utf8)
    if low == high {
      for byte in lowBytes {
        set.insert(byte...byte)
      }
      return
    }
    for byte in lowBytes.dropLast() {
      set.insert(byte...byte)
    }
    if lowBytes[lowBytes.count - 1] <= highBytes[0] {
      set.insert(lowBytes[lowBytes.count - 1]...highBytes[0])
    }
    for byte in highBytes.dropFirst() {
      set.insert(byte...byte)
    }
  }
}
