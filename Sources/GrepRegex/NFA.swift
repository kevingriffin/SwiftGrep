/// A set of bytes as a 256-bit bitmap.
struct ByteSet: Hashable, Sendable {
  var bits: InlineArray<4, UInt64> = .init(repeating: 0)

  init() {}

  init(_ range: ClosedRange<UInt8>) {
    insert(range)
  }

  static let all: ByteSet = {
    var s = ByteSet()
    s.insert(0...255)
    return s
  }()

  @inline(__always)
  func contains(_ byte: UInt8) -> Bool {
    bits[Int(byte &>> 6)] & (1 &<< UInt64(byte & 63)) != 0
  }

  mutating func insert(_ byte: UInt8) {
    bits[Int(byte &>> 6)] |= 1 &<< UInt64(byte & 63)
  }

  mutating func insert(_ range: ClosedRange<UInt8>) {
    for b in range {
      insert(b)
    }
  }

  mutating func remove(_ byte: UInt8) {
    bits[Int(byte &>> 6)] &= ~(1 &<< UInt64(byte & 63))
  }

  var isEmpty: Bool {
    bits[0] | bits[1] | bits[2] | bits[3] == 0
  }

  var count: Int {
    bits[0].nonzeroBitCount + bits[1].nonzeroBitCount + bits[2].nonzeroBitCount + bits[3].nonzeroBitCount
  }

  static func == (a: ByteSet, b: ByteSet) -> Bool {
    a.bits[0] == b.bits[0] && a.bits[1] == b.bits[1] && a.bits[2] == b.bits[2] && a.bits[3] == b.bits[3]
  }

  func hash(into hasher: inout Hasher) {
    for i in 0..<4 {
      hasher.combine(bits[i])
    }
  }

  /// Members as maximal ranges.
  var ranges: [ClosedRange<UInt8>] {
    var result: [ClosedRange<UInt8>] = []
    var start: Int? = nil
    for b in 0...256 {
      let inSet = b < 256 && contains(UInt8(b))
      if inSet, start == nil {
        start = b
      }
      if !inSet, let s = start {
        result.append(UInt8(s)...UInt8(b - 1))
        start = nil
      }
    }
    return result
  }
}

/// A set of `Look` assertions as a bitmask.
struct LookSet: Hashable, Sendable {
  var bits: UInt32 = 0

  @inline(__always) func contains(_ look: Look) -> Bool {
    bits & (1 << look.rawValue) != 0
  }

  @inline(__always) mutating func insert(_ look: Look) {
    bits |= 1 << look.rawValue
  }

  var isEmpty: Bool {
    bits == 0
  }

  var containsWordLook: Bool {
    Look.allCases.contains { $0.isWordLook && contains($0) }
  }

  var containsCRLFLook: Bool {
    contains(.startLineCRLF) || contains(.endLineCRLF)
  }

  var containsUnicodeWordLook: Bool {
    Look.allCases.contains { $0.isUnicodeWordLook && contains($0) }
  }
}

/// A Thompson NFA over bytes. Unicode is handled by compiling scalar classes
/// into UTF-8 byte sequences.
struct NFA: Sendable {
  typealias StateID = Int32

  struct Transition: Sendable, Hashable {
    var low: UInt8
    var high: UInt8
    var next: StateID
  }

  enum State: Sendable, Hashable {
    /// Consumes one byte in the set.
    case bytes(ByteSet, next: StateID)
    /// Consumes one byte, choosing the next state by range (sorted, disjoint).
    case sparse([Transition])
    /// Epsilon transitions in priority order.
    case union([StateID])
    case look(Look, next: StateID)
    /// Records the position in a capture slot (an epsilon transition).
    case capture(slot: Int32, next: StateID)
    case match
    case fail
  }

  var states: [State] = []
  /// Start of the pattern (anchored).
  var start: StateID = 0
  /// Start state that also allows a match to begin at any later position.
  var unanchoredStart: StateID = 0
  var looks = LookSet()
  /// Whether the pattern can only ever match the empty string at line positions.
  var matchState: StateID = 0
}

/// Compiles a `RegexNode` into an `NFA`.
struct NFACompiler {
  private var nfa = NFA()
  private let stateLimit: Int
  private let pattern: String
  /// Whether capture groups get states of their own (only `--replace`
  /// needs them).
  private let captures: Bool
  /// Caches compiled UTF-8 automata for large classes that appear many times.
  private var classCache: [ScalarSet: [UTF8Sequence]] = [:]

  init(pattern: String, captures: Bool, stateLimit: Int = 2_000_000) {
    self.pattern = pattern
    self.captures = captures
    self.stateLimit = stateLimit
  }

  static func compile(_ node: RegexNode, pattern: String, captures: Bool = false) throws(RegexError) -> NFA {
    var compiler = NFACompiler(pattern: pattern, captures: captures)
    return try compiler.build(node)
  }

  private mutating func build(_ node: RegexNode) throws(RegexError) -> NFA {
    let match = add(.match)
    nfa.matchState = match
    let start = try compile(node, next: match)
    nfa.start = start
    // Unanchored prefix: a lazy `(?s-u:.)*?`. The loop is listed last so the
    // pattern itself is always preferred.
    let loop = add(.fail)
    let anyByte = add(.bytes(.all, next: loop))
    nfa.states[Int(loop)] = .union([start, anyByte])
    nfa.unanchoredStart = loop
    return nfa
  }

  private mutating func add(_ state: NFA.State) -> NFA.StateID {
    nfa.states.append(state)
    return NFA.StateID(nfa.states.count - 1)
  }

  private func checkSize() throws(RegexError) {
    if nfa.states.count > stateLimit {
      throw RegexError(message: "compiled regex exceeds size limit", pattern: pattern, offset: nil)
    }
  }

  private mutating func compile(_ node: RegexNode, next: NFA.StateID) throws(RegexError) -> NFA.StateID {
    try checkSize()
    switch node {
    case .empty:
      return next
    case let .char(c):
      var s = next
      for b in UTF8Encoding.encode(c).reversed() {
        s = add(.bytes(ByteSet(b...b), next: s))
      }
      return s
    case let .byte(b):
      return add(.bytes(ByteSet(b...b), next: next))
    case let .byteSet(set):
      var bytes = ByteSet()
      for r in set.ranges where r.lowerBound <= 0xFF {
        bytes.insert(UInt8(r.lowerBound)...UInt8(min(r.upperBound, 0xFF)))
      }
      return bytes.isEmpty ? add(.fail) : add(.bytes(bytes, next: next))
    case let .set(set):
      if set.isEmpty {
        return add(.fail)
      }
      if set.isASCII {
        var bytes = ByteSet()
        for r in set.ranges {
          bytes.insert(UInt8(r.lowerBound)...UInt8(r.upperBound))
        }
        return add(.bytes(bytes, next: next))
      }
      return try compileUTF8(set, next: next)
    case let .look(look):
      nfa.looks.insert(look)
      return add(.look(look, next: next))
    case let .concat(nodes):
      var s = next
      for n in nodes.reversed() {
        s = try compile(n, next: s)
      }
      return s
    case let .alternate(nodes):
      var starts: [NFA.StateID] = []
      starts.reserveCapacity(nodes.count)
      for n in nodes {
        try starts.append(compile(n, next: next))
      }
      return add(.union(starts))
    case let .group(n):
      return try compile(n, next: next)
    case let .capture(index, n):
      guard captures else { return try compile(n, next: next) }
      let end = add(.capture(slot: Int32(2 * index + 1), next: next))
      let inner = try compile(n, next: end)
      return add(.capture(slot: Int32(2 * index), next: inner))
    case let .repeat(n, min, max, greedy):
      return try compileRepeat(n, min: min, max: max, greedy: greedy, next: next)
    }
  }

  private mutating func compileRepeat(
    _ node: RegexNode, min: Int, max: Int?, greedy: Bool, next: NFA.StateID,
  ) throws(RegexError) -> NFA.StateID {
    var result: NFA.StateID
    if let max {
      result = next
      for _ in 0..<(max - min) {
        let body = try compile(node, next: result)
        result = add(.union(greedy ? [body, next] : [next, body]))
      }
      for _ in 0..<min {
        result = try compile(node, next: result)
      }
      return result
    }
    // Unbounded: a loop around one copy, preceded by min-1 mandatory copies.
    let loop = add(.fail)
    let body = try compile(node, next: loop)
    nfa.states[Int(loop)] = .union(greedy ? [body, next] : [next, body])
    if min == 0 {
      return loop
    }
    result = body
    for _ in 0..<(min - 1) {
      result = try compile(node, next: result)
    }
    return result
  }

  /// Compiles a non-ASCII scalar set into a byte trie of its UTF-8 encodings.
  private mutating func compileUTF8(_ set: ScalarSet, next: NFA.StateID) throws(RegexError) -> NFA.StateID {
    let sequences: [UTF8Sequence]
    if let cached = classCache[set] {
      sequences = cached
    } else {
      var all: [UTF8Sequence] = []
      for r in set.ranges {
        all.append(contentsOf: UTF8Sequences.split(r))
      }
      classCache[set] = all
      sequences = all
    }
    var trie = ByteRangeTrie()
    for seq in sequences {
      guard trie.insert(seq) else {
        // Overlapping prefixes (never expected from the splitter); fall back to plain alternation.
        var starts: [NFA.StateID] = []
        for seq in sequences {
          var s = next
          for r in seq.ranges.reversed() {
            s = add(.bytes(ByteSet(r), next: s))
          }
          starts.append(s)
        }
        return add(.union(starts))
      }
    }
    return try emit(trieNode: 0, trie: trie, next: next)
  }

  private mutating func emit(trieNode: Int, trie: ByteRangeTrie, next: NFA.StateID) throws(RegexError) -> NFA.StateID {
    try checkSize()
    var transitions: [NFA.Transition] = []
    for edge in trie.nodes[trieNode] {
      let target = edge.child < 0 ? next : try emit(trieNode: edge.child, trie: trie, next: next)
      transitions.append(NFA.Transition(low: edge.low, high: edge.high, next: target))
    }
    transitions.sort { $0.low < $1.low }
    if transitions.count == 1 {
      return add(.bytes(ByteSet(transitions[0].low...transitions[0].high), next: transitions[0].next))
    }
    return add(.sparse(transitions))
  }
}

/// One UTF-8 encoding pattern: a sequence of byte ranges, e.g. [E1][80-BF][80-BF].
struct UTF8Sequence: Hashable, Sendable {
  var ranges: [ClosedRange<UInt8>]
}

enum UTF8Sequences {
  /// Splits a scalar range into UTF-8 byte range sequences, skipping surrogates.
  static func split(_ range: ClosedRange<UInt32>) -> [UTF8Sequence] {
    var result: [UTF8Sequence] = []
    var stack: [(UInt32, UInt32)] = [(range.lowerBound, range.upperBound)]
    outer: while var (start, end) = stack.popLast() {
      inner: while true {
        // Remove surrogates.
        if start <= 0xDFFF && end >= 0xD800 {
          if start < 0xD800 {
            if end > 0xDFFF {
              stack.append((0xE000, end))
            }
            end = 0xD7FF
          } else if end > 0xDFFF {
            start = 0xE000
          } else {
            continue outer
          }
        }
        // Split at encoded length boundaries.
        for max: UInt32 in [0x7F, 0x7FF, 0xFFFF] where start <= max && max < end {
          stack.append((max + 1, end))
          end = max
          continue inner
        }
        if end <= 0x7F {
          result.append(UTF8Sequence(ranges: [UInt8(start)...UInt8(end)]))
          continue outer
        }
        // Split so that every continuation byte range is complete.
        for i: UInt32 in 1..<4 {
          let mask: UInt32 = (1 << (6 * i)) - 1
          if start & ~mask != end & ~mask {
            if start & mask != 0 {
              stack.append(((start | mask) + 1, end))
              end = start | mask
              continue inner
            }
            if end & mask != mask {
              stack.append((end & ~mask, end))
              end = (end & ~mask) - 1
              continue inner
            }
          }
        }
        let s = UTF8Encoding.encode(start)
        let e = UTF8Encoding.encode(end)
        result.append(UTF8Sequence(ranges: zip(s, e).map { $0...$1 }))
        continue outer
      }
    }
    result.sort { a, b in
      for (x, y) in zip(a.ranges, b.ranges) where x != y {
        return x.lowerBound < y.lowerBound
      }
      return a.ranges.count < b.ranges.count
    }
    return result
  }
}

/// A trie keyed by byte ranges whose sibling edges are either identical or disjoint.
struct ByteRangeTrie {
  struct Edge {
    var low: UInt8
    var high: UInt8
    /// Child node index, or -1 if the sequence ends here.
    var child: Int
  }

  var nodes: [[Edge]] = [[]]

  /// Inserts a sequence. Returns false if it partially overlaps an existing edge.
  mutating func insert(_ seq: UTF8Sequence) -> Bool {
    var node = 0
    for (i, r) in seq.ranges.enumerated() {
      let isLast = i == seq.ranges.count - 1
      if let index = nodes[node].firstIndex(where: { $0.low == r.lowerBound && $0.high == r.upperBound }) {
        let edge = nodes[node][index]
        if isLast || edge.child < 0 {
          return isLast && edge.child < 0
        }
        node = edge.child
        continue
      }
      if nodes[node].contains(where: { $0.low <= r.upperBound && r.lowerBound <= $0.high }) {
        return false
      }
      if isLast {
        nodes[node].append(Edge(low: r.lowerBound, high: r.upperBound, child: -1))
      } else {
        nodes.append([])
        let child = nodes.count - 1
        nodes[node].append(Edge(low: r.lowerBound, high: r.upperBound, child: child))
        node = child
      }
    }
    return true
  }
}
