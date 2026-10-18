/// A set of Unicode scalar values (or raw bytes, in byte mode), stored as
/// sorted, non-overlapping, non-adjacent inclusive ranges.
struct ScalarSet: Hashable, Sendable {
  private(set) var ranges: [ClosedRange<UInt32>]

  init() {
    ranges = []
  }

  init(_ ranges: some Sequence<ClosedRange<UInt32>>) {
    self.ranges = Array(ranges)
    canonicalize()
  }

  init(scalar: UInt32) {
    ranges = [scalar...scalar]
  }

  /// Builds a set from a generated flat table of (low, high) pairs.
  init(table: [UInt32]) {
    var result: [ClosedRange<UInt32>] = []
    result.reserveCapacity(table.count / 2)
    var i = 0
    while i + 1 < table.count {
      result.append(table[i]...table[i + 1])
      i += 2
    }
    ranges = result
    canonicalize()
  }

  static let maxScalar: UInt32 = 0x10FFFF
  static let all = ScalarSet([0...maxScalar])

  var isEmpty: Bool {
    ranges.isEmpty
  }

  /// The single scalar in this set, if it contains exactly one.
  var singleScalar: UInt32? {
    guard ranges.count == 1, let r = ranges.first, r.lowerBound == r.upperBound else { return nil }
    return r.lowerBound
  }

  /// Number of scalars in the set.
  var count: Int {
    ranges.reduce(0) { $0 + Int($1.upperBound - $1.lowerBound) + 1 }
  }

  var isASCII: Bool {
    ranges.last.map { $0.upperBound < 0x80 } ?? true
  }

  func contains(_ value: UInt32) -> Bool {
    var lo = 0
    var hi = ranges.count
    while lo < hi {
      let mid = (lo + hi) / 2
      let r = ranges[mid]
      if value < r.lowerBound {
        hi = mid
      } else if value > r.upperBound {
        lo = mid + 1
      } else {
        return true
      }
    }
    return false
  }

  mutating func insert(_ range: ClosedRange<UInt32>) {
    ranges.append(range)
    canonicalize()
  }

  mutating func formUnion(_ other: ScalarSet) {
    guard !other.isEmpty else { return }
    ranges.append(contentsOf: other.ranges)
    canonicalize()
  }

  func union(_ other: ScalarSet) -> ScalarSet {
    var copy = self
    copy.formUnion(other)
    return copy
  }

  /// Complement within `0...upperBound` (0x10FFFF for scalars, 0xFF for bytes).
  func inverted(upperBound: UInt32 = maxScalar) -> ScalarSet {
    var result: [ClosedRange<UInt32>] = []
    var next: UInt32 = 0
    for r in ranges {
      if r.lowerBound > upperBound {
        break
      }
      if r.lowerBound > next {
        result.append(next...(r.lowerBound - 1))
      }
      if r.upperBound >= upperBound {
        next = upperBound + 1
        break
      }
      next = r.upperBound + 1
    }
    if next <= upperBound {
      result.append(next...upperBound)
    }
    var set = ScalarSet()
    set.ranges = result
    return set
  }

  func intersection(_ other: ScalarSet) -> ScalarSet {
    var result: [ClosedRange<UInt32>] = []
    var i = 0
    var j = 0
    while i < ranges.count && j < other.ranges.count {
      let a = ranges[i]
      let b = other.ranges[j]
      let lo = max(a.lowerBound, b.lowerBound)
      let hi = min(a.upperBound, b.upperBound)
      if lo <= hi {
        result.append(lo...hi)
      }
      if a.upperBound < b.upperBound {
        i += 1
      } else {
        j += 1
      }
    }
    var set = ScalarSet()
    set.ranges = result
    return set
  }

  func subtracting(_ other: ScalarSet) -> ScalarSet {
    intersection(other.inverted())
  }

  func symmetricDifference(_ other: ScalarSet) -> ScalarSet {
    union(other).subtracting(intersection(other))
  }

  /// Adds every simple case folding equivalent of every member.
  func caseFolded() -> ScalarSet {
    var extra: [ClosedRange<UInt32>] = []
    for r in ranges {
      // ASCII letters are by far the most common; handle them without the table.
      CaseFolding.forEachEquivalent(in: r) { extra.append($0...$0) }
    }
    guard !extra.isEmpty else { return self }
    var copy = self
    copy.ranges.append(contentsOf: extra)
    copy.canonicalize()
    return copy
  }

  /// Removes the given scalar, e.g. the line terminator.
  func removing(_ value: UInt32) -> ScalarSet {
    subtracting(ScalarSet(scalar: value))
  }

  private mutating func canonicalize() {
    guard ranges.count > 1 else { return }
    ranges.sort { $0.lowerBound < $1.lowerBound }
    var merged: [ClosedRange<UInt32>] = []
    merged.reserveCapacity(ranges.count)
    for r in ranges {
      if let last = merged.last, r.lowerBound <= last.upperBound &+ 1 {
        if r.upperBound > last.upperBound {
          merged[merged.count - 1] = last.lowerBound...r.upperBound
        }
      } else {
        merged.append(r)
      }
    }
    ranges = merged
  }
}

/// Simple Unicode case folding, backed by the generated pair table.
enum CaseFolding {
  /// Calls `body` with every scalar that is case-equivalent to some scalar in
  /// `range` (excluding the scalar itself).
  static func forEachEquivalent(in range: ClosedRange<UInt32>, _ body: (UInt32) -> Void) {
    let table = UnicodeTables.caseFoldPairs
    let pairCount = table.count / 2
    // Binary search the first pair whose source is >= range.lowerBound.
    var lo = 0
    var hi = pairCount
    while lo < hi {
      let mid = (lo + hi) / 2
      if table[mid * 2] < range.lowerBound {
        lo = mid + 1
      } else {
        hi = mid
      }
    }
    var i = lo
    while i < pairCount, table[i * 2] <= range.upperBound {
      body(table[i * 2 + 1])
      i += 1
    }
  }

  /// All scalars equivalent to `value` under simple case folding, including itself.
  static func equivalents(of value: UInt32) -> [UInt32] {
    var result = [value]
    forEachEquivalent(in: value...value) { result.append($0) }
    return result
  }

  static func hasCase(_ value: UInt32) -> Bool {
    var found = false
    forEachEquivalent(in: value...value) { _ in found = true }
    return found
  }
}
