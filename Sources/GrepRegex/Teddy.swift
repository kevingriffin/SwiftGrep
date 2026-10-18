import _Builtin_intrinsics.arm.neon

/// Teddy, the SIMD multi-literal search from Hyperscan (ripgrep uses it too).
///
/// The needles are put in up to eight buckets, one bit each. A window of up
/// to three bytes is taken at the same offset in every needle, and for each
/// window position two 16-byte tables map a byte's low and high nibble to the
/// buckets whose needles can have that byte there. Two `tbl` lookups per
/// window byte then test 16 start positions at once; only positions that
/// survive every window byte are verified against the needles in their
/// buckets.
struct TeddyFinder: Sendable {
  /// The needles, lowercased where folding applies, concatenated.
  private let bytes: [UInt8]
  /// 0x20 at each folded letter, parallel to `bytes`.
  private let foldMasks: [UInt8]
  /// Needle `i` is `bytes[starts[i]..<starts[i + 1]]`.
  private let starts: [Int]
  /// Needle indices of bucket `b`: `bucketItems[bucketStarts[b]..<bucketStarts[b + 1]]`.
  private let bucketStarts: [Int]
  private let bucketItems: [Int]
  private let low: InlineArray<3, SIMD16<UInt8>>
  private let high: InlineArray<3, SIMD16<UInt8>>
  /// Where the window starts in every needle, and its length (1...3).
  let offset: Int
  let width: Int
  let minLength: Int
  let count: Int

  init(needles raw: [[UInt8]], fold: Bool) {
    precondition(!raw.isEmpty && !raw.contains(where: \.isEmpty))
    count = raw.count
    var bytes: [UInt8] = []
    var masks: [UInt8] = []
    var starts: [Int] = []
    for needle in raw {
      starts.append(bytes.count)
      for b in needle {
        let letter = fold && (b | 0x20) >= 0x61 && (b | 0x20) <= 0x7A
        bytes.append(letter ? b | 0x20 : b)
        masks.append(letter ? 0x20 : 0)
      }
    }
    starts.append(bytes.count)
    let minLength = raw.map(\.count).min()!
    let width = min(3, minLength)
    self.minLength = minLength
    self.width = width

    /// The byte values a position accepts: one, or both cases of a letter.
    func variants(_ i: Int, _ k: Int) -> [UInt8] {
      let b = bytes[starts[i] + k]
      return masks[starts[i] + k] != 0 ? [b, b & ~0x20] : [b]
    }

    // Place the window where a random position is least likely to pass it.
    var bestOffset = 0
    var bestCost = Float.infinity
    for w in 0...(minLength - width) {
      var cost: Float = 0
      for i in raw.indices {
        var p: Float = 1
        for k in 0..<width {
          p *= variants(i, w + k).reduce(0) { $0 + ByteFrequencies.table[Int($1)] }
        }
        cost += p
      }
      if cost < bestCost {
        bestCost = cost
        bestOffset = w
      }
    }
    offset = bestOffset

    // Needles with the same window share a bucket; the groups are dealt out
    // over the eight buckets.
    var groups: [[UInt8]: [Int]] = [:]
    var order: [[UInt8]] = []
    for i in raw.indices {
      let key = Array(bytes[(starts[i] + bestOffset)..<(starts[i] + bestOffset + width)])
      if groups[key] == nil { order.append(key) }
      groups[key, default: []].append(i)
    }
    var buckets = [[Int]](repeating: [], count: 8)
    for (g, key) in order.enumerated() { buckets[g % 8].append(contentsOf: groups[key]!) }

    var low = InlineArray<3, SIMD16<UInt8>>(repeating: SIMD16(repeating: 0))
    var high = InlineArray<3, SIMD16<UInt8>>(repeating: SIMD16(repeating: 0))
    for (b, members) in buckets.enumerated() {
      let bit = UInt8(1) << UInt8(b)
      for i in members {
        for k in 0..<width {
          for v in variants(i, bestOffset + k) {
            low[k][Int(v & 0xF)] |= bit
            high[k][Int(v >> 4)] |= bit
          }
        }
      }
    }
    self.low = low
    self.high = high
    self.bytes = bytes
    self.foldMasks = masks
    self.starts = starts
    var bucketStarts = [0]
    var bucketItems: [Int] = []
    for members in buckets {
      bucketItems.append(contentsOf: members)
      bucketStarts.append(bucketItems.count)
    }
    self.bucketStarts = bucketStarts
    self.bucketItems = bucketItems
  }

  /// Position of the first needle occurrence starting in `[from, to)` and
  /// ending by `to`.
  func find(_ hay: Span<UInt8>, from: Int, to: Int) -> Int? {
    switch width {
    case 1: scan(hay, from: from, to: to, width: 1)
    case 2: scan(hay, from: from, to: to, width: 2)
    default: scan(hay, from: from, to: to, width: 3)
    }
  }

  @inline(__always)
  private func scan(_ hay: Span<UInt8>, from: Int, to: Int, width: Int) -> Int? {
    guard to - from >= minLength else { return nil }
    let bytes = hay.bytes
    let nibble = SIMD16<UInt8>(repeating: 0x0F)
    let l0 = low[0], h0 = high[0]
    let l1 = width > 1 ? low[1] : l0, h1 = width > 1 ? high[1] : h0
    let l2 = width > 2 ? low[2] : l0, h2 = width > 2 ? high[2] : h0
    @inline(__always)
    func lookup(_ l: SIMD16<UInt8>, _ h: SIMD16<UInt8>, _ v: SIMD16<UInt8>) -> SIMD16<UInt8> {
      vqtbl1q_u8(l, v & nibble) & vqtbl1q_u8(h, v &>> 4)
    }
    @inline(__always)
    func candidates(at s: Int) -> SIMD16<UInt8> {
      let w = s &+ offset
      var r = lookup(l0, h0, SIMDBytes.load(bytes, w))
      if width > 1 { r &= lookup(l1, h1, SIMDBytes.load(bytes, w &+ 1)) }
      if width > 2 { r &= lookup(l2, h2, SIMDBytes.load(bytes, w &+ 2)) }
      return r
    }
    var s = from
    // Every load stays below `to`: s + offset + width - 1 + 15 < to.
    let vectorEnd = to - offset - width - 15
    while s + 16 <= vectorEnd {
      let r1 = candidates(at: s)
      let r2 = candidates(at: s &+ 16)
      if vmaxvq_u8(r1 | r2) != 0 {
        if let hit = verifyLanes(r1, hay, s, to) { return hit }
        if let hit = verifyLanes(r2, hay, s &+ 16, to) { return hit }
      }
      s &+= 32
    }
    while s <= vectorEnd {
      let r = candidates(at: s)
      if vmaxvq_u8(r) != 0, let hit = verifyLanes(r, hay, s, to) { return hit }
      s &+= 16
    }
    // The last few positions, one at a time.
    let last = to - minLength
    while s <= last {
      let w = s + offset
      var bits = low[0][Int(hay[w] & 0xF)] & high[0][Int(hay[w] >> 4)]
      if width > 1 { bits &= low[1][Int(hay[w + 1] & 0xF)] & high[1][Int(hay[w + 1] >> 4)] }
      if width > 2 { bits &= low[2][Int(hay[w + 2] & 0xF)] & high[2][Int(hay[w + 2] >> 4)] }
      if bits != 0, verify(bits, hay, s, to) { return s }
      s += 1
    }
    return nil
  }

  @inline(__always)
  private func verifyLanes(_ r: SIMD16<UInt8>, _ hay: Span<UInt8>, _ s: Int, _ to: Int) -> Int? {
    var mask = SIMDBytes.nibbleMask(r .!= SIMD16(repeating: 0))
    while mask != 0 {
      let lane = SIMDBytes.firstLane(mask)
      if verify(r[lane], hay, s &+ lane, to) { return s &+ lane }
      mask = SIMDBytes.clearLane(mask, lane)
    }
    return nil
  }

  /// Whether a needle in one of the `buckets` occurs at `start`.
  private func verify(_ buckets: UInt8, _ hay: Span<UInt8>, _ start: Int, _ to: Int) -> Bool {
    let bytes = self.bytes.span
    let masks = foldMasks.span
    var remaining = buckets
    while remaining != 0 {
      let b = remaining.trailingZeroBitCount
      remaining &= remaining &- 1
      for item in bucketStarts[b]..<bucketStarts[b + 1] {
        let i = bucketItems[item]
        let begin = starts[i]
        let length = starts[i + 1] - begin
        guard start + length <= to else { continue }
        var k = 0
        while k < length && hay[start &+ k] | masks[begin &+ k] == bytes[begin &+ k] { k &+= 1 }
        if k == length { return true }
      }
    }
    return false
  }
}
