/// A Pike VM: simulates the NFA with one thread per state, giving
/// leftmost-first match spans in time linear in the haystack length.
///
/// The VM owns its scratch memory and is used by one thread at a time.
@usableFromInline
struct PikeVM: ~Copyable {
  private let nfa: FlatNFA
  private var current: SparseSet
  private var next: SparseSet
  /// Match start slot per state, indexed by the state's position in the set.
  private var currentSlots: UniqueArray<Int>
  private var nextSlots: UniqueArray<Int>
  private var stack: [Int32] = []

  init(nfa: FlatNFA) {
    self.nfa = nfa
    current = SparseSet(capacity: nfa.count)
    next = SparseSet(capacity: nfa.count)
    currentSlots = UniqueArray(repeating: 0, count: max(nfa.count, 1))
    nextSlots = UniqueArray(repeating: 0, count: max(nfa.count, 1))
    stack.reserveCapacity(64)
  }

  /// Finds the leftmost-first match within the line `[lineStart, lineEnd)`,
  /// starting the search at `from`.
  mutating func find(
    in hay: Span<UInt8>, lineStart: Int, lineEnd: Int, from: Int,
  ) -> Range<Int>? {
    current.clear()
    var matched: Range<Int>?
    var pos = from
    while true {
      if matched == nil {
        addThread(toCurrent: true, state: nfa.start, slot: pos, at: pos, hay: hay, lineStart: lineStart, lineEnd: lineEnd)
      }
      if current.count == 0 {
        break
      }
      next.clear()
      let byte: UInt8? = pos < lineEnd ? hay[pos] : nil
      var i = 0
      while i < current.count {
        let state = current[i]
        let slot = currentSlots[i]
        i += 1
        switch nfa.kinds[Int(state)] {
        case .match:
          matched = slot..<pos
          // Lower priority threads can never produce a preferred match.
          i = current.count
        case .bytes, .sparse:
          guard let byte else { continue }
          let target = nfa.step(Int(state), byte)
          if target >= 0 {
            addThread(toCurrent: false, state: target, slot: slot, at: pos + 1, hay: hay, lineStart: lineStart, lineEnd: lineEnd)
          }
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
    return matched
  }

  /// Whether the line contains any match.
  mutating func isMatch(in hay: Span<UInt8>, lineStart: Int, lineEnd: Int) -> Bool {
    find(in: hay, lineStart: lineStart, lineEnd: lineEnd, from: lineStart) != nil
  }

  /// Follows epsilon transitions from `state` in priority order, adding each
  /// reachable state to the current or next set.
  private mutating func addThread(
    toCurrent: Bool, state: Int32, slot: Int, at pos: Int,
    hay: Span<UInt8>, lineStart: Int, lineEnd: Int,
  ) {
    stack.removeAll(keepingCapacity: true)
    stack.append(state)
    while let s = stack.popLast() {
      let inserted = toCurrent ? current.insert(s) : next.insert(s)
      guard inserted else { continue }
      if toCurrent {
        currentSlots[current.index(of: s)] = slot
      } else {
        nextSlots[next.index(of: s)] = slot
      }
      let index = Int(s)
      switch nfa.kinds[index] {
      case .union:
        let first = Int(nfa.argA[index])
        var k = first + Int(nfa.argB[index]) - 1
        while k >= first {
          stack.append(nfa.alternatives[k])
          k -= 1
        }
      case .look:
        let look = Look(rawValue: UInt8(nfa.argA[index]))!
        if Self.holds(look, at: pos, hay: hay, lineStart: lineStart, lineEnd: lineEnd) {
          stack.append(nfa.argB[index])
        }
      case .capture:
        stack.append(nfa.argB[index])
      default:
        break
      }
    }
  }

  /// Whether `look` holds at `pos` in the text `[lineStart, lineEnd)` (a
  /// line, or the file with `-U`). Lines start and end at the text's bounds
  /// and at `\n`; in CRLF mode also at `\r`, but never between `\r` and `\n`.
  static func holds(_ look: Look, at pos: Int, hay: Span<UInt8>, lineStart: Int, lineEnd: Int) -> Bool {
    switch look {
    case .startText:
      return pos == lineStart
    case .endText:
      return pos == lineEnd
    case .startLine:
      return pos == lineStart || hay[pos - 1] == 10
    case .endLine:
      return pos == lineEnd || hay[pos] == 10
    case .startLineCRLF:
      guard pos > lineStart else { return true }
      return hay[pos - 1] == 10 || (hay[pos - 1] == 13 && (pos >= lineEnd || hay[pos] != 10))
    case .endLineCRLF:
      guard pos < lineEnd else { return true }
      return hay[pos] == 13 || (hay[pos] == 10 && (pos == lineStart || hay[pos - 1] != 13))
    default:
      let unicode = look.isUnicodeWordLook
      let before = WordChars.isWord(before: pos, in: hay, start: lineStart, unicode: unicode)
      let after = WordChars.isWord(after: pos, in: hay, end: lineEnd, unicode: unicode)
      return look.holds(previousIsWord: before, nextIsWord: after)
    }
  }
}
