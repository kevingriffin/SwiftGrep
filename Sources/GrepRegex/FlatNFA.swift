/// The NFA flattened into plain arrays. The engines walk this representation
/// in their hot loops, which avoids reference counting on enum payloads.
@usableFromInline
struct FlatNFA: Sendable {
  enum Kind: UInt8, Sendable {
    case bytes, sparse, union, look, match, fail
  }

  /// Per state: kind, and two arguments whose meaning depends on the kind:
  /// - bytes:  a = index into `byteSets`, b = next state
  /// - sparse: a = first index into `edges`, b = edge count
  /// - union:  a = first index into `alternatives`, b = count
  /// - look:   a = `Look.rawValue`, b = next state
  let kinds: [Kind]
  let argA: [Int32]
  let argB: [Int32]
  let byteSets: [ByteSet]
  let edges: [NFA.Transition]
  let alternatives: [Int32]
  let start: Int32
  let unanchoredStart: Int32
  let matchState: Int32
  let looks: LookSet

  var count: Int {
    kinds.count
  }

  init(_ nfa: NFA) {
    var kinds: [Kind] = []
    var a: [Int32] = []
    var b: [Int32] = []
    var byteSets: [ByteSet] = []
    var setIndex: [ByteSet: Int32] = [:]
    var edges: [NFA.Transition] = []
    var alternatives: [Int32] = []
    kinds.reserveCapacity(nfa.states.count)
    for state in nfa.states {
      switch state {
      case let .bytes(set, next):
        let index: Int32
        if let existing = setIndex[set] {
          index = existing
        } else {
          index = Int32(byteSets.count)
          byteSets.append(set)
          setIndex[set] = index
        }
        kinds.append(.bytes); a.append(index); b.append(next)
      case let .sparse(transitions):
        kinds.append(.sparse); a.append(Int32(edges.count)); b.append(Int32(transitions.count))
        edges.append(contentsOf: transitions)
      case let .union(alts):
        kinds.append(.union); a.append(Int32(alternatives.count)); b.append(Int32(alts.count))
        alternatives.append(contentsOf: alts)
      case let .look(look, next):
        kinds.append(.look); a.append(Int32(look.rawValue)); b.append(next)
      case .match:
        kinds.append(.match); a.append(0); b.append(0)
      case .fail:
        kinds.append(.fail); a.append(0); b.append(0)
      }
    }
    self.kinds = kinds
    argA = a
    argB = b
    self.byteSets = byteSets
    self.edges = edges
    self.alternatives = alternatives
    start = nfa.start
    unanchoredStart = nfa.unanchoredStart
    matchState = nfa.matchState
    looks = nfa.looks
  }

  /// The state reached from `state` by consuming `byte`, or -1.
  @inline(__always)
  func step(_ state: Int, _ byte: UInt8) -> Int32 {
    switch kinds[state] {
    case .bytes:
      return byteSets[Int(argA[state])].contains(byte) ? argB[state] : -1
    case .sparse:
      let first = Int(argA[state])
      let end = first + Int(argB[state])
      for i in first..<end {
        let e = edges[i]
        if byte < e.low {
          return -1
        }
        if byte <= e.high {
          return e.next
        }
      }
      return -1
    default:
      return -1
    }
  }
}

/// A set of small integers with O(1) insert, membership and clear, that
/// remembers insertion order.
@usableFromInline
struct SparseSet: ~Copyable {
  private var dense: UniqueArray<Int32>
  private var sparse: UniqueArray<Int32>
  private(set) var count = 0
  let capacity: Int

  init(capacity: Int) {
    self.capacity = max(capacity, 1)
    dense = UniqueArray(repeating: 0, count: self.capacity)
    sparse = UniqueArray(repeating: 0, count: self.capacity)
  }

  @inline(__always)
  func contains(_ value: Int32) -> Bool {
    let i = Int(sparse[Int(value)])
    return i < count && dense[i] == value
  }

  /// Inserts the value, returning false if it was already present.
  @inline(__always) @discardableResult
  mutating func insert(_ value: Int32) -> Bool {
    if contains(value) {
      return false
    }
    dense[count] = value
    sparse[Int(value)] = Int32(count)
    count += 1
    return true
  }

  @inline(__always) mutating func clear() {
    count = 0
  }

  @inline(__always) subscript(index: Int) -> Int32 {
    dense[index]
  }

  /// Index of a member in insertion order.
  @inline(__always) func index(of value: Int32) -> Int {
    Int(sparse[Int(value)])
  }

  mutating func swapContents(with other: inout SparseSet) {
    swap(&dense, &other.dense)
    swap(&sparse, &other.sparse)
    swap(&count, &other.count)
  }
}

/// Character classification for look-around assertions.
enum WordChars {
  static let ascii: ByteSet = {
    var s = ByteSet()
    s.insert(UInt8(ascii: "0")...UInt8(ascii: "9"))
    s.insert(UInt8(ascii: "A")...UInt8(ascii: "Z"))
    s.insert(UInt8(ascii: "a")...UInt8(ascii: "z"))
    s.insert(UInt8(ascii: "_"))
    return s
  }()

  static let unicode = ScalarSet(table: UnicodeTables.perlWord)

  @inline(__always)
  static func isASCIIWord(_ byte: UInt8) -> Bool {
    ascii.contains(byte)
  }

  /// Whether the character starting at `position` is a word character.
  static func isWord(after position: Int, in hay: Span<UInt8>, end: Int, unicode: Bool) -> Bool {
    guard position < end else { return false }
    let b = hay[position]
    if b < 0x80 || !unicode {
      return isASCIIWord(b)
    }
    guard let scalar = UTF8Decoding.decode(hay, at: position, end: end) else { return false }
    return Self.unicode.contains(scalar.value)
  }

  /// Whether the character ending just before `position` is a word character.
  static func isWord(before position: Int, in hay: Span<UInt8>, start: Int, unicode: Bool) -> Bool {
    guard position > start else { return false }
    let b = hay[position - 1]
    if b < 0x80 || !unicode {
      return isASCIIWord(b)
    }
    guard let scalar = UTF8Decoding.decodeBackward(hay, before: position, start: start) else { return false }
    return Self.unicode.contains(scalar.value)
  }
}

enum UTF8Decoding {
  /// Decodes one scalar starting at `i`. Returns nil for invalid UTF-8.
  static func decodeScalar(_ p: Span<UInt8>, at i: Int, end: Int) -> (value: UInt32, length: Int)? {
    let b0 = UInt32(p[i])
    if b0 < 0x80 {
      return (b0, 1)
    }
    let length: Int
    var value: UInt32
    switch b0 {
    case 0xC2...0xDF: length = 2; value = b0 & 0x1F
    case 0xE0...0xEF: length = 3; value = b0 & 0x0F
    case 0xF0...0xF4: length = 4; value = b0 & 0x07
    default: return nil
    }
    guard i + length <= end else { return nil }
    for k in 1..<length {
      let b = UInt32(p[i + k])
      guard b & 0xC0 == 0x80 else { return nil }
      value = value << 6 | (b & 0x3F)
    }
    // Reject overlong encodings and surrogates.
    switch length {
    case 3 where value < 0x800 || (0xD800...0xDFFF).contains(value): return nil
    case 4 where value < 0x10000 || value > 0x10FFFF: return nil
    default: break
    }
    return (value, length)
  }

  static func decode(_ p: Span<UInt8>, at i: Int, end: Int) -> Unicode.Scalar? {
    guard let decoded = decodeScalar(p, at: i, end: end) else { return nil }
    return Unicode.Scalar(decoded.value)
  }

  /// Decodes the scalar that ends just before `i`.
  static func decodeBackward(_ p: Span<UInt8>, before i: Int, start: Int) -> Unicode.Scalar? {
    var j = i - 1
    let limit = max(start, i - 4)
    while j > limit && p[j] & 0xC0 == 0x80 {
      j -= 1
    }
    guard let decoded = decodeScalar(p, at: j, end: i), j + decoded.length == i else { return nil }
    return Unicode.Scalar(decoded.value)
  }

  /// Length of the (possibly invalid) character starting at `i`, at least 1.
  static func characterLength(_ p: Span<UInt8>, at i: Int, end: Int) -> Int {
    decodeScalar(p, at: i, end: end)?.length ?? 1
  }
}
