import Darwin

/// A glob with gitignore semantics, matched against byte paths.
///
/// `*` and `?` never match `/`; `**` matches across directories when it forms
/// a whole path segment (`**/x`, `x/**/y`, `x/**`). Patterns without a slash
/// match the final path component at any depth.
struct Glob: Sendable, Hashable {
  enum Kind: UInt8, Sendable, Hashable {
    /// Literal bytes: `bytes[start..<end]`.
    case literal
    /// `?`: one character other than `/`.
    case one
    /// `*`: any run of characters other than `/`.
    case star
    /// `**/` (or `/**/` after a literal slash): zero or more whole directories.
    case anyDirectories
    /// Trailing `/**` or a lone `**`: anything at all.
    case anything
    /// A `[...]` class: `ranges[start..<end]`.
    case set
    /// A `[!...]` class.
    case negatedSet
  }

  /// One element of the pattern. Literals and classes refer to `bytes` and
  /// `ranges` by position, so tokens are plain values and matching does no
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

  let tokens: [Token]
  /// The bytes of every literal token, concatenated.
  let bytes: [UInt8]
  /// The ranges of every class token, concatenated.
  let ranges: [ClosedRange<UInt32>]
  let strategy: Strategy
  /// For `general` globs: the length of a literal that the glob starts or
  /// ends with (the first or last bytes of `bytes`), checked before trying
  /// a full match.
  let prefixLength: Int
  let suffixLength: Int
  /// Whether the glob is matched against the whole relative path (it
  /// contained a slash) rather than just the file name.
  let anchored: Bool
  let caseInsensitive: Bool

  /// Parses a glob. `anchored` is decided by the caller (gitignore rules
  /// decide it from the presence of a slash).
  init(_ pattern: [UInt8], anchored: Bool, caseInsensitive: Bool = false) {
    self.anchored = anchored
    self.caseInsensitive = caseInsensitive
    let source = caseInsensitive ? pattern.map(Self.lower) : pattern
    var tokens: [Token] = []
    var bytes: [UInt8] = []
    var ranges: [ClosedRange<UInt32>] = []
    var literalStart = 0
    func add(_ kind: Kind) {
      tokens.append(Token(kind: kind, start: 0, end: 0))
    }
    func flush() {
      if bytes.count > literalStart {
        tokens.append(Token(kind: .literal, start: Int32(literalStart), end: Int32(bytes.count)))
        literalStart = bytes.count
      }
    }
    var i = 0
    let n = source.count
    while i < n {
      let c = source[i]
      switch c {
      case UInt8(ascii: "\\") where i + 1 < n:
        bytes.append(source[i + 1])
        i += 2
      case UInt8(ascii: "*"):
        var j = i
        while j < n && source[j] == UInt8(ascii: "*") { j += 1 }
        let count = j - i
        let atSegmentStart = i == 0 || source[i - 1] == UInt8(ascii: "/")
        let atSegmentEnd = j == n || source[j] == UInt8(ascii: "/")
        flush()
        if count >= 2 && atSegmentStart && atSegmentEnd {
          if j == n {
            add(.anything)
            i = j
          } else {
            add(.anyDirectories)
            i = j + 1 // also consume the slash
          }
        } else {
          if tokens.last?.kind != .star { add(.star) }
          i = j
        }
      case UInt8(ascii: "?"):
        flush()
        add(.one)
        i += 1
      case UInt8(ascii: "["):
        if let (set, negated, next) = Self.parseClass(source, from: i) {
          flush()
          tokens.append(Token(kind: negated ? .negatedSet : .set, start: Int32(ranges.count),
                              end: Int32(ranges.count + set.count)))
          ranges.append(contentsOf: set)
          i = next
        } else {
          bytes.append(c)
          i += 1
        }
      default:
        bytes.append(c)
        i += 1
      }
    }
    flush()
    self.tokens = tokens
    self.bytes = bytes
    self.ranges = ranges
    let first = tokens.first, last = tokens.last
    prefixLength = first?.kind == .literal ? Int(first!.end - first!.start) : 0
    suffixLength = tokens.count > 1 && last?.kind == .literal ? Int(last!.end - last!.start) : 0
    let kinds = tokens.map(\.kind)
    switch kinds {
    case []: strategy = .exact
    case [.literal]: strategy = .exact
    case [.anything]: strategy = .always
    case [.star, .literal] where !anchored || !bytes.contains(UInt8(ascii: "/")): strategy = .suffix
    case [.literal, .star]: strategy = .prefix
    case [.literal, .anything]: strategy = .prefixAnything
    default: strategy = .general
    }
  }

  @inline(__always)
  static func lower(_ b: UInt8) -> UInt8 {
    b >= 0x41 && b <= 0x5A ? b | 0x20 : b
  }

  /// Parses a `[...]` class. Returns nil if it is not terminated.
  private static func parseClass(_ s: [UInt8], from start: Int) -> ([ClosedRange<UInt32>], Bool, Int)? {
    var i = start + 1
    var negated = false
    if i < s.count && (s[i] == UInt8(ascii: "!") || s[i] == UInt8(ascii: "^")) {
      negated = true
      i += 1
    }
    var ranges: [ClosedRange<UInt32>] = []
    var first = true
    func scalar(at index: inout Int) -> UInt32? {
      guard index < s.count else { return nil }
      if s[index] == UInt8(ascii: "\\"), index + 1 < s.count { index += 1 }
      // Decode one UTF-8 scalar.
      let b0 = s[index]
      var length = 1
      if b0 >= 0xF0 { length = 4 } else if b0 >= 0xE0 { length = 3 } else if b0 >= 0xC0 { length = 2 }
      guard index + length <= s.count else { return nil }
      let decoded = String(decoding: s[index..<(index + length)], as: UTF8.self).unicodeScalars.first?.value
      index += length
      return decoded
    }
    while i < s.count {
      if s[i] == UInt8(ascii: "]") && !first {
        return (ranges, negated, i + 1)
      }
      first = false
      guard let low = scalar(at: &i) else { return nil }
      if i + 1 < s.count, s[i] == UInt8(ascii: "-"), s[i + 1] != UInt8(ascii: "]") {
        i += 1
        guard let high = scalar(at: &i) else { return nil }
        if low <= high { ranges.append(low...high) }
      } else {
        ranges.append(low...low)
      }
    }
    return nil
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
      if anchored, path.firstIndex(of: slash, in: start..<(path.count - literal.count)) != nil { return false }
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
        if lower(path[offset + k]) != literal[k] { return false }
        k += 1
      }
    } else {
      while k < literal.count {
        if path[offset + k] != literal[k] { return false }
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
  /// matchers take exponential time) cannot stall the search.
  private func matchGeneral(_ path: Span<UInt8>, from start: Int) -> Bool {
    let positions = path.count - start + 1
    let words = (positions + 63) / 64
    if words <= 8 {
      // Paths up to 511 bytes, the common case, use stack storage.
      var a = InlineArray<8, UInt64>(repeating: 0)
      var b = InlineArray<8, UInt64>(repeating: 0)
      var reached = a.mutableSpan
      var next = b.mutableSpan
      return simulate(path, from: start, words: words, &reached, &next)
    }
    var a = [UInt64](repeating: 0, count: words)
    var b = [UInt64](repeating: 0, count: words)
    var reached = a.mutableSpan
    var next = b.mutableSpan
    return simulate(path, from: start, words: words, &reached, &next)
  }

  private func simulate(
    _ path: Span<UInt8>, from start: Int, words: Int,
    _ reached: inout MutableSpan<UInt64>, _ next: inout MutableSpan<UInt64>
  ) -> Bool {
    let length = path.count - start
    let slash = UInt8(ascii: "/")
    let literals = bytes.span
    let classes = ranges.span
    @inline(__always) func isSet(_ set: borrowing MutableSpan<UInt64>, _ i: Int) -> Bool {
      set[i >> 6] & (1 << UInt64(i & 63)) != 0
    }
    @inline(__always) func insert(_ set: inout MutableSpan<UInt64>, _ i: Int) {
      set[i >> 6] |= 1 << UInt64(i & 63)
    }
    reached[0] = 1
    for token in tokens {
      for w in 0..<words { next[w] = 0 }
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
      case .one, .set, .negatedSet:
        let set = classes.extracting(Int(token.start)..<Int(token.end))
        for w in 0..<words {
          var bits = reached[w]
          while bits != 0 {
            let p = w << 6 | bits.trailingZeroBitCount
            bits &= bits &- 1
            guard p < length, path[start + p] != slash else { continue }
            let step = Self.characterLength(path, at: start + p)
            if token.kind == .one || matchesClass(path, at: start + p, length: step, set, negated: token.kind == .negatedSet) {
              insert(&next, p + step)
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
      case .anyDirectories:
        // Nothing, or anything ending in `/`.
        var seen = false
        for q in 0...length {
          if (seen && q > 0 && path[start + q - 1] == slash) || isSet(reached, q) {
            insert(&next, q)
            any = true
          }
          if isSet(reached, q) { seen = true }
        }
      case .anything:
        var seen = false
        for q in 0...length {
          if isSet(reached, q) { seen = true }
          if seen {
            insert(&next, q)
            any = true
          }
        }
      }
      guard any else { return false }
      for w in 0..<words { reached[w] = next[w] }
    }
    return isSet(reached, length)
  }

  private func matchesClass(_ path: Span<UInt8>, at p: Int, length: Int, _ set: Span<ClosedRange<UInt32>>, negated: Bool) -> Bool {
    var value = UInt32(path[p])
    var upper = value
    if length > 1 {
      value = UTF8Decoding.scalarValue(path, at: p, length: length) ?? value
      upper = value
    } else if caseInsensitive {
      // The pattern was lowercased; match either case of an ASCII letter.
      value = UInt32(Self.lower(UInt8(value)))
      upper = value >= 0x61 && value <= 0x7A ? value - 0x20 : value
    }
    var inSet = false
    for i in set.indices where set[i].contains(value) || set[i].contains(upper) {
      inSet = true
      break
    }
    return inSet != negated
  }

  private static func characterLength(_ p: Span<UInt8>, at i: Int) -> Int {
    let b = p[i]
    let length = b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : b >= 0xC0 ? 2 : 1
    return min(length, p.count - i)
  }
}

enum UTF8Decoding {
  /// The scalar encoded by the `length` bytes at `p`, if they are valid UTF-8.
  static func scalarValue(_ bytes: Span<UInt8>, at p: Int, length: Int) -> UInt32? {
    var scalars = String(decoding: Array(copying: bytes.extracting(p..<(p + length))), as: UTF8.self).unicodeScalars.makeIterator()
    return scalars.next()?.value
  }
}
