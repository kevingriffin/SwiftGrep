/// A Pike VM that also records capture groups, for `--replace`. It runs
/// anchored at the start of a match the regular Pike VM found, so it finds
/// the same leftmost-first match and only adds the groups.
///
/// Each thread carries its slots (the start and end of each group). They are
/// set while following epsilon transitions, with an explicit stack that
/// restores a slot once its branch has been explored, so there is no
/// recursion however deeply the pattern nests.
struct CaptureVM: ~Copyable {
  private let nfa: FlatNFA
  private let slotCount: Int
  private var current: SparseSet
  private var next: SparseSet
  /// `slotCount` slots per state in each set, by insertion index.
  private var currentSlots: UniqueArray<Int>
  private var nextSlots: UniqueArray<Int>
  /// The slots along the epsilon path being explored.
  private var scratch: UniqueArray<Int>
  private var stack: [Frame] = []

  private enum Frame {
    case explore(Int32)
    case restore(slot: Int, value: Int)
  }

  init(nfa: FlatNFA, groups: Int) {
    self.nfa = nfa
    slotCount = 2 * (groups + 1)
    current = SparseSet(capacity: nfa.count)
    next = SparseSet(capacity: nfa.count)
    currentSlots = UniqueArray(repeating: -1, count: max(nfa.count, 1) * slotCount)
    nextSlots = UniqueArray(repeating: -1, count: max(nfa.count, 1) * slotCount)
    scratch = UniqueArray(repeating: -1, count: slotCount)
  }

  /// The groups of the leftmost-first match starting at `start` in the text
  /// `[lineStart, lineEnd)`; group 0 is the whole match. Nil if no match
  /// starts there.
  mutating func captures(in hay: Span<UInt8>, lineStart: Int, lineEnd: Int, start: Int) -> [Range<Int>?]? {
    current.clear()
    for k in 0..<slotCount {
      scratch[k] = -1
    }
    explore(nfa.start, intoCurrent: true, at: start, hay: hay, lineStart: lineStart, lineEnd: lineEnd)
    var best: [Int]?
    var pos = start
    while current.count > 0 {
      next.clear()
      let byte: UInt8? = pos < lineEnd ? hay[pos] : nil
      var i = 0
      while i < current.count {
        let state = current[i]
        let row = i * slotCount
        i += 1
        switch nfa.kinds[Int(state)] {
        case .match:
          var slots = [Int](repeating: -1, count: slotCount)
          for k in 0..<slotCount {
            slots[k] = currentSlots[row + k]
          }
          slots[0] = start
          slots[1] = pos
          best = slots
          // Lower priority threads can never produce a preferred match.
          i = current.count
        case .bytes, .sparse:
          guard let byte else { continue }
          let target = nfa.step(Int(state), byte)
          guard target >= 0 else { continue }
          for k in 0..<slotCount {
            scratch[k] = currentSlots[row + k]
          }
          explore(target, intoCurrent: false, at: pos + 1, hay: hay, lineStart: lineStart, lineEnd: lineEnd)
        default:
          continue
        }
      }
      if pos >= lineEnd {
        break
      }
      current.swapContents(with: &next)
      swap(&currentSlots, &nextSlots)
      pos += 1
    }
    guard let best else { return nil }
    return (0..<(slotCount / 2)).map { group in
      let (low, high) = (best[2 * group], best[2 * group + 1])
      return low >= 0 && high >= low ? low..<high : nil
    }
  }

  /// Adds `state` and everything reachable from it by epsilon transitions,
  /// in priority order, with the slots in `scratch`.
  private mutating func explore(
    _ state: Int32, intoCurrent: Bool, at pos: Int, hay: Span<UInt8>, lineStart: Int, lineEnd: Int,
  ) {
    stack.removeAll(keepingCapacity: true)
    stack.append(.explore(state))
    while let frame = stack.popLast() {
      let s: Int32
      switch frame {
      case let .restore(slot, value):
        scratch[slot] = value
        continue
      case let .explore(id):
        s = id
      }
      let inserted = intoCurrent ? current.insert(s) : next.insert(s)
      guard inserted else { continue }
      let row = (intoCurrent ? current.index(of: s) : next.index(of: s)) * slotCount
      for k in 0..<slotCount {
        if intoCurrent {
          currentSlots[row + k] = scratch[k]
        } else {
          nextSlots[row + k] = scratch[k]
        }
      }
      let index = Int(s)
      switch nfa.kinds[index] {
      case .union:
        let first = Int(nfa.argA[index])
        var k = first + Int(nfa.argB[index]) - 1
        while k >= first {
          stack.append(.explore(nfa.alternatives[k]))
          k -= 1
        }
      case .look:
        let look = Look(rawValue: UInt8(nfa.argA[index]))!
        if PikeVM.holds(look, at: pos, hay: hay, lineStart: lineStart, lineEnd: lineEnd) {
          stack.append(.explore(nfa.argB[index]))
        }
      case .capture:
        let slot = Int(nfa.argA[index])
        if slot < slotCount {
          stack.append(.restore(slot: slot, value: scratch[slot]))
          scratch[slot] = pos
        }
        stack.append(.explore(nfa.argB[index]))
      default:
        break
      }
    }
  }
}
