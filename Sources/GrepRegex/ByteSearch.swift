/// SIMD helpers over byte spans. Loads are bounds checked by the span (one
/// compare per 16 bytes). NEON has no `movemask`, so a 16 lane comparison
/// result is narrowed to a 64-bit mask with 4 bits per lane.
enum SIMDBytes {
  @inline(__always)
  static func load(_ bytes: RawSpan, _ offset: Int) -> SIMD16<UInt8> {
    bytes.load(fromByteOffset: offset, as: SIMD16<UInt8>.self)
  }

  @inline(__always)
  static func nibbleMask(_ m: SIMDMask<SIMD16<Int8>>) -> UInt64 {
    let lanes = SIMD16<UInt8>(repeating: 0).replacing(with: 0xFF, where: m)
    let wide = bitCast(lanes, to: SIMD8<UInt16>.self)
    return bitCast(SIMD8<UInt8>(truncatingIfNeeded: wide &>> 4), to: UInt64.self)
  }

  /// Index of the first set lane in a nibble mask.
  @inline(__always)
  static func firstLane(_ mask: UInt64) -> Int { mask.trailingZeroBitCount &>> 2 }

  /// Index of the last set lane in a nibble mask.
  @inline(__always)
  static func lastLane(_ mask: UInt64) -> Int { 15 &- (mask.leadingZeroBitCount &>> 2) }

  @inline(__always)
  static func clearLane(_ mask: UInt64, _ lane: Int) -> UInt64 {
    mask & ~(0xF &<< UInt64(lane &<< 2))
  }
}

/// Byte searches over a span. Every access is checked against the span.
extension Span where Element == UInt8 {
  /// The first index of `byte` in `range`.
  public func firstIndex(of byte: UInt8, in range: Range<Int>) -> Int? {
    precondition(range.lowerBound >= 0 && range.upperBound <= count)
    let bytes = self.bytes
    let needle = SIMD16<UInt8>(repeating: byte)
    var i = range.lowerBound
    let end = range.upperBound
    while end &- i >= 64 {
      let m0 = SIMDBytes.load(bytes, i) .== needle
      let m1 = SIMDBytes.load(bytes, i &+ 16) .== needle
      let m2 = SIMDBytes.load(bytes, i &+ 32) .== needle
      let m3 = SIMDBytes.load(bytes, i &+ 48) .== needle
      if any((m0 .| m1) .| (m2 .| m3)) {
        for (k, m) in [m0, m1, m2, m3].enumerated() {
          let mask = SIMDBytes.nibbleMask(m)
          if mask != 0 { return i &+ k &* 16 &+ SIMDBytes.firstLane(mask) }
        }
      }
      i &+= 64
    }
    while end &- i >= 16 {
      let mask = SIMDBytes.nibbleMask(SIMDBytes.load(bytes, i) .== needle)
      if mask != 0 { return i &+ SIMDBytes.firstLane(mask) }
      i &+= 16
    }
    while i < end {
      if self[i] == byte { return i }
      i &+= 1
    }
    return nil
  }

  /// The last index of `byte` in `range`.
  public func lastIndex(of byte: UInt8, in range: Range<Int>) -> Int? {
    precondition(range.lowerBound >= 0 && range.upperBound <= count)
    let bytes = self.bytes
    let needle = SIMD16<UInt8>(repeating: byte)
    var end = range.upperBound
    while end - 16 >= range.lowerBound {
      let mask = SIMDBytes.nibbleMask(SIMDBytes.load(bytes, end &- 16) .== needle)
      if mask != 0 { return end &- 16 &+ SIMDBytes.lastLane(mask) }
      end &-= 16
    }
    while end > range.lowerBound {
      end &-= 1
      if self[end] == byte { return end }
    }
    return nil
  }

  /// The number of occurrences of `byte` in `range`.
  public func count(of byte: UInt8, in range: Range<Int>) -> Int {
    precondition(range.lowerBound >= 0 && range.upperBound <= count)
    let bytes = self.bytes
    var i = range.lowerBound
    let end = range.upperBound
    var total = 0
    let needle = SIMD16<UInt8>(repeating: byte)
    @inline(__always)
    func hits(_ offset: Int) -> SIMD16<UInt8> {
      // 0xFF in each matching lane; subtracting it adds one.
      SIMD16<UInt8>(repeating: 0).replacing(with: 0xFF, where: SIMDBytes.load(bytes, offset) .== needle)
    }
    while end &- i >= 64 {
      // Per-lane byte counters (up to 4 per round), flushed before they can
      // overflow.
      var lanes = SIMD16<UInt8>(repeating: 0)
      var rounds = 0
      while rounds < 63 && end &- i >= 64 {
        lanes &-= hits(i)
        lanes &-= hits(i &+ 16)
        lanes &-= hits(i &+ 32)
        lanes &-= hits(i &+ 48)
        i &+= 64
        rounds &+= 1
      }
      total &+= Int(SIMD16<UInt16>(truncatingIfNeeded: lanes).wrappedSum())
    }
    while i < end {
      if self[i] == byte { total &+= 1 }
      i &+= 1
    }
    return total
  }
}

/// Finds a single byte, optionally ASCII case-insensitively.
struct ByteFinder: Sendable {
  let byte: UInt8
  let fold: Bool

  init(byte: UInt8, fold: Bool) {
    let isLetter = (byte | 0x20) >= 0x61 && (byte | 0x20) <= 0x7A
    self.fold = fold && isLetter
    self.byte = self.fold ? byte | 0x20 : byte
  }

  func find(_ hay: Span<UInt8>, from: Int, to: Int) -> Int? {
    guard fold else { return hay.firstIndex(of: byte, in: from..<to) }
    let bytes = hay.bytes
    let needle = SIMD16<UInt8>(repeating: byte)
    let lowerBit = SIMD16<UInt8>(repeating: 0x20)
    var i = from
    while i + 16 <= to {
      let mask = SIMDBytes.nibbleMask((SIMDBytes.load(bytes, i) | lowerBit) .== needle)
      if mask != 0 { return i &+ SIMDBytes.firstLane(mask) }
      i &+= 16
    }
    while i < to {
      if hay[i] | 0x20 == byte { return i }
      i &+= 1
    }
    return nil
  }
}

/// Substring search that scans for two rare bytes of the needle at their
/// relative offsets with SIMD, then verifies candidates. ASCII case folding is
/// supported by OR-ing 0x20 into letter positions.
struct PairFinder: Sendable {
  let needle: [UInt8]
  /// Per needle position: 0x20 where the needle has a letter and folding is on.
  let foldMask: [UInt8]
  let index1: Int
  let index2: Int

  init(needle raw: [UInt8], fold: Bool) {
    precondition(raw.count >= 2)
    var needle = raw
    var foldMask = [UInt8](repeating: 0, count: raw.count)
    if fold {
      for (k, b) in raw.enumerated() where (b | 0x20) >= 0x61 && (b | 0x20) <= 0x7A {
        foldMask[k] = 0x20
        needle[k] = b | 0x20
      }
    }
    self.needle = needle
    self.foldMask = foldMask
    // Choose the two rarest positions.
    func frequency(_ k: Int) -> Float {
      let b = needle[k]
      var f = ByteFrequencies.table[Int(b)]
      if foldMask[k] != 0 { f += ByteFrequencies.table[Int(b & ~0x20)] }
      return f
    }
    let order = needle.indices.sorted { frequency($0) < frequency($1) || (frequency($0) == frequency($1) && $0 < $1) }
    var first = order[0]
    var second = order.first { needle[$0] != needle[first] } ?? order[1]
    if first > second { swap(&first, &second) }
    index1 = first
    index2 = second
  }

  @inline(__always)
  private func verify(_ hay: Span<UInt8>, _ start: Int) -> Bool {
    let needle = self.needle.span
    let mask = foldMask.span
    var k = 0
    while k < needle.count {
      if hay[start &+ k] | mask[k] != needle[k] { return false }
      k &+= 1
    }
    return true
  }

  func find(_ hay: Span<UInt8>, from: Int, to: Int) -> Int? {
    let n = needle.count
    guard to - from >= n else { return nil }
    let bytes = hay.bytes
    let last = to - n
    let i1 = index1
    let i2 = index2
    let b1 = SIMD16<UInt8>(repeating: needle[i1])
    let b2 = SIMD16<UInt8>(repeating: needle[i2])
    let o1 = SIMD16<UInt8>(repeating: foldMask[i1])
    let o2 = SIMD16<UInt8>(repeating: foldMask[i2])
    var i = from
    // Every load stays below `to`: i + 15 + i2 < to.
    while i + 32 + i2 <= to {
      let m1 = (SIMDBytes.load(bytes, i &+ i1) | o1 .== b1) .& (SIMDBytes.load(bytes, i &+ i2) | o2 .== b2)
      let m2 = (SIMDBytes.load(bytes, i &+ 16 &+ i1) | o1 .== b1) .& (SIMDBytes.load(bytes, i &+ 16 &+ i2) | o2 .== b2)
      if any(m1 .| m2) {
        var mask = SIMDBytes.nibbleMask(m1)
        while mask != 0 {
          let lane = SIMDBytes.firstLane(mask)
          if i &+ lane <= last, verify(hay, i &+ lane) { return i &+ lane }
          mask = SIMDBytes.clearLane(mask, lane)
        }
        mask = SIMDBytes.nibbleMask(m2)
        while mask != 0 {
          let lane = SIMDBytes.firstLane(mask)
          if i &+ 16 &+ lane <= last, verify(hay, i &+ 16 &+ lane) { return i &+ 16 &+ lane }
          mask = SIMDBytes.clearLane(mask, lane)
        }
      }
      i &+= 32
    }
    let f1 = foldMask[i1]
    let f2 = foldMask[i2]
    let n1 = needle[i1]
    let n2 = needle[i2]
    while i <= last {
      if hay[i &+ i1] | f1 == n1 && hay[i &+ i2] | f2 == n2 && verify(hay, i) { return i }
      i &+= 1
    }
    return nil
  }
}

/// Searches for any of several literals by scanning for the bytes they have at
/// a common offset, then verifying the literals that share the found byte.
/// Used for sets too large for Teddy.
struct MultiFinder: Sendable {
  let needles: [[UInt8]]
  let foldMasks: [[UInt8]]
  let offset: Int
  /// For each byte value, the needles whose byte at `offset` (after folding) matches.
  let buckets: [[Int]]
  let member: InlineArray<256, Bool>

  init(needles raw: [[UInt8]], fold: Bool) {
    var needles = raw
    var masks = raw.map { [UInt8](repeating: 0, count: $0.count) }
    if fold {
      for i in needles.indices {
        for k in needles[i].indices where (needles[i][k] | 0x20) >= 0x61 && (needles[i][k] | 0x20) <= 0x7A {
          masks[i][k] = 0x20
          needles[i][k] |= 0x20
        }
      }
    }
    self.needles = needles
    self.foldMasks = masks
    let minLength = needles.map(\.count).min() ?? 1
    // Pick the offset whose distinct bytes are rarest in total.
    var bestOffset = 0
    var bestCost = Float.infinity
    for k in 0..<minLength {
      var bytes = Set<UInt8>()
      for (i, n) in needles.enumerated() {
        bytes.insert(n[k])
        if masks[i][k] != 0 { bytes.insert(n[k] & ~0x20) }
      }
      let cost = bytes.reduce(Float(0)) { $0 + ByteFrequencies.table[Int($1)] }
      if cost < bestCost {
        bestCost = cost
        bestOffset = k
      }
    }
    offset = bestOffset
    var buckets = [[Int]](repeating: [], count: 256)
    var member = InlineArray<256, Bool>(repeating: false)
    for (i, n) in needles.enumerated() {
      let b = n[bestOffset]
      buckets[Int(b)].append(i)
      member[Int(b)] = true
      if masks[i][bestOffset] != 0 {
        buckets[Int(b & ~0x20)].append(i)
        member[Int(b & ~0x20)] = true
      }
    }
    self.buckets = buckets
    self.member = member
  }

  private func verify(_ hay: Span<UInt8>, at hit: Int, from: Int, to: Int) -> Int? {
    let start = hit - offset
    guard start >= from else { return nil }
    for index in buckets[Int(hay[hit])] {
      let n = needles[index]
      guard start + n.count <= to else { continue }
      let mask = foldMasks[index]
      var k = 0
      while k < n.count && hay[start &+ k] | mask[k] == n[k] { k &+= 1 }
      if k == n.count { return start }
    }
    return nil
  }

  func find(_ hay: Span<UInt8>, from: Int, to: Int) -> Int? {
    var i = from + offset
    while i < to {
      if member[Int(hay[i])], let start = verify(hay, at: i, from: from, to: to) { return start }
      i &+= 1
    }
    return nil
  }
}

/// A fast candidate search used before running the regex engines.
enum Prefilter: Sendable {
  case byte(ByteFinder)
  case pair(PairFinder)
  case teddy(TeddyFinder)
  case multi(MultiFinder)

  /// Builds a prefilter for the literal set, or nil if it would not pay off.
  init?(literals: [[UInt8]], fold: Bool, maxCost: Float) {
    guard !literals.isEmpty, !literals.contains(where: \.isEmpty) else { return nil }
    let cost = LiteralExtractor.cost(of: literals)
    guard cost <= maxCost else { return nil }
    if literals.count == 1 {
      let needle = literals[0]
      self = needle.count == 1 ? .byte(ByteFinder(byte: needle[0], fold: fold)) : .pair(PairFinder(needle: needle, fold: fold))
    } else if literals.count <= 64 {
      self = .teddy(TeddyFinder(needles: literals, fold: fold))
    } else {
      self = .multi(MultiFinder(needles: literals, fold: fold))
    }
  }

  /// Position of a candidate literal occurrence in `[from, to)`.
  @inline(__always)
  func find(_ hay: Span<UInt8>, from: Int, to: Int) -> Int? {
    precondition(from >= 0 && to <= hay.count)
    return switch self {
    case .byte(let f): f.find(hay, from: from, to: to)
    case .pair(let f): f.find(hay, from: from, to: to)
    case .teddy(let f): f.find(hay, from: from, to: to)
    case .multi(let f): f.find(hay, from: from, to: to)
    }
  }
}
