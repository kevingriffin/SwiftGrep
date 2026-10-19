/// The immutable part of a lazy DFA, shared by all threads.
@usableFromInline
struct DFAProgram: Sendable {
  let nfa: FlatNFA
  /// Byte to equivalence class.
  let classes: InlineArray<256, UInt8>
  /// Number of byte classes. Class `classCount` is the end-of-input class.
  let classCount: Int
  let stride: Int
  /// One representative byte for each class.
  let representatives: [UInt8]
  let usesWordLooks: Bool
  /// When the pattern has Unicode word boundaries, bytes >= 0x80 make the DFA give up.
  let quitOnNonASCII: Bool
  /// The byte that ends lines (records), or nil when the whole text is
  /// searched at once (`-U`).
  let terminator: UInt8?
  /// Whether states remember that the previous byte was `\r`, for CRLF
  /// anchors.
  let tracksCR: Bool
  /// `\z` in CRLF mode would need two bytes of look-ahead at a `\r`, so the
  /// DFA gives up there and the Pike VM decides.
  let quitOnCR: Bool

  init(nfa: FlatNFA, terminator: UInt8?) {
    self.nfa = nfa
    self.terminator = terminator
    usesWordLooks = nfa.looks.containsWordLook
    quitOnNonASCII = nfa.looks.containsUnicodeWordLook
    tracksCR = nfa.looks.containsCRLFLook
    quitOnCR = tracksCR && terminator != nil && nfa.looks.contains(.endText)

    var boundary = [Bool](repeating: false, count: 257)
    func mark(_ low: UInt8, _ high: UInt8) {
      boundary[Int(low)] = true
      boundary[Int(high) + 1] = true
    }
    for set in nfa.byteSets {
      for r in set.ranges {
        mark(r.lowerBound, r.upperBound)
      }
    }
    for e in nfa.edges {
      mark(e.low, e.high)
    }
    mark(10, 10)
    mark(13, 13)
    if let terminator {
      mark(terminator, terminator)
    }
    if usesWordLooks {
      mark(UInt8(ascii: "0"), UInt8(ascii: "9"))
      mark(UInt8(ascii: "A"), UInt8(ascii: "Z"))
      mark(UInt8(ascii: "_"), UInt8(ascii: "_"))
      mark(UInt8(ascii: "a"), UInt8(ascii: "z"))
    }
    if quitOnNonASCII {
      mark(0x80, 0xFF)
    }

    var classes = InlineArray<256, UInt8>(repeating: 0)
    var representatives: [UInt8] = [0]
    var cls = 0
    for b in 0..<256 {
      if b > 0 && boundary[b] {
        cls += 1
        representatives.append(UInt8(b))
      }
      classes[b] = UInt8(cls)
    }
    self.classes = classes
    classCount = cls + 1
    self.stride = cls + 2
    self.representatives = representatives
  }
}

/// Result of a DFA search.
enum DFAResult: Equatable {
  /// A match ends at this position (the earliest such position).
  case match(at: Int)
  case noMatch
  /// The DFA cannot decide; the caller must fall back to the Pike VM. The
  /// position is where it gave up.
  case quit(at: Int)
}

/// A lazily built DFA. States are computed from NFA state sets on demand and
/// cached; the cache is cleared if it grows too large.
///
/// Matches are reported with "earliest" semantics, which is all a line-oriented
/// search needs to know whether a line matches. Match detection is delayed by
/// one byte so that look-ahead assertions (`$`, `\b`) see the next byte.
@usableFromInline
struct LazyDFA: ~Copyable {
  private static let unknown: Int32 = -1
  private static let dead: Int32 = -2
  private static let quit: Int32 = -3
  private static let match: Int32 = -4

  private struct StateKey: Hashable {
    var states: [Int32]
    var looks: UInt32
    var fromWord: Bool
    var fromCR: Bool
  }

  private struct StateInfo {
    var setStart: Int
    var setCount: Int
    var looks: LookSet
    var fromWord: Bool
    var fromCR: Bool
    var hasLookStates: Bool
  }

  private let program: DFAProgram
  /// Each byte's class, times 4: the byte offset of its transition within a
  /// state's row.
  private let classTable: InlineArray<256, UInt16>
  /// Transitions, one row of `stride` entries per state. State IDs are byte
  /// offsets of their rows, so following a transition is one add and one
  /// (bounds checked) load.
  private var table: UniqueArray<Int32>
  private var stateCount = 0
  private var infos: [StateInfo] = []
  private var setPool: [Int32] = []
  private var map: [StateKey: Int32] = [:]
  private var startState: Int32 = 0
  /// `-U` start states in the middle of the text, after `\n`, after `\r`,
  /// after a word byte and after any other byte.
  private var contextStartStates = InlineArray<4, Int32>(repeating: unknown)
  private var visited: SparseSet
  private var stack: [Int32] = []
  private var scratchSet: [Int32] = []
  private let maxStates: Int
  /// Number of times the cache was cleared during the current search.
  private var clearsThisSearch = 0

  init(program: DFAProgram, cacheBytes: Int = 4 << 20) {
    self.program = program
    classTable = InlineArray { b in UInt16(program.classes[b]) << 2 }
    maxStates = max(16, cacheBytes / (program.stride * MemoryLayout<Int32>.stride))
    table = UniqueArray(capacity: 64 * program.stride)
    visited = SparseSet(capacity: program.nfa.count)
    resetCache()
  }

  private mutating func resetCache() {
    stateCount = 0
    table.removeLast(table.count)
    infos.removeAll(keepingCapacity: true)
    setPool.removeAll(keepingCapacity: true)
    map.removeAll(keepingCapacity: true)
    // A search starts at the start of a line (and of the text).
    var looks = LookSet()
    looks.insert(.startLine)
    looks.insert(.startLineCRLF)
    looks.insert(.startText)
    looks.bits &= program.nfa.looks.bits
    let set = closure(seeds: [program.nfa.unanchoredStart], looks: looks)
    startState = intern(set, looks: looks, fromWord: false, fromCR: false)
    for k in contextStartStates.indices {
      contextStartStates[k] = Self.unknown
    }
  }

  /// Searches `[from, end)` for the earliest match. `from` must be at the
  /// start of a line, and `end` at the end of a line or of the haystack.
  mutating func findEarliest(_ hay: Span<UInt8>, from: Int, end: Int) -> DFAResult {
    search(hay, from: from, end: end, start: startState)
  }

  /// `-U`: searches `[from, end)` of a text that starts at 0, so the
  /// assertions at `from` depend on the byte before it.
  mutating func findEarliest(inText hay: Span<UInt8>, from: Int, end: Int) -> DFAResult {
    guard from > 0 else { return search(hay, from: from, end: end, start: startState) }
    guard let start = startState(after: hay[from - 1]) else { return .quit(at: from) }
    return search(hay, from: from, end: end, start: start)
  }

  /// The start state after `byte`, as `computeTransition` would step to it
  /// in a DFA without a line terminator; nil if the DFA can't tell (a
  /// Unicode word boundary after non-ASCII).
  private mutating func startState(after byte: UInt8) -> Int32? {
    precondition(program.terminator == nil)
    if byte >= 0x80 && program.quitOnNonASCII {
      return nil
    }
    let fromWord = program.usesWordLooks && WordChars.isASCIIWord(byte)
    let fromCR = program.tracksCR && byte == 13
    let kind = byte == 10 ? 0 : fromCR ? 1 : fromWord ? 2 : 3
    if contextStartStates[kind] == Self.unknown {
      var looks = LookSet()
      if byte == 10 {
        looks.insert(.startLine)
        looks.insert(.startLineCRLF)
      }
      looks.bits &= program.nfa.looks.bits
      let set = closure(seeds: [program.nfa.unanchoredStart], looks: looks)
      contextStartStates[kind] = intern(set, looks: looks, fromWord: fromWord, fromCR: fromCR)
    }
    return contextStartStates[kind]
  }

  @inline(__always)
  private mutating func search(_ hay: Span<UInt8>, from: Int, end: Int, start: Int32) -> DFAResult {
    precondition(from >= 0 && end <= hay.count)
    clearsThisSearch = 0
    var sid = start
    var i = from
    let eoiClass = program.classCount
    while true {
      do {
        // Spans, not copies: indexing a local copy of the InlineArray would
        // copy all 512 bytes on every access.
        let classes = classTable.span
        let t = table.span.bytes
        // Hot loop: follow cached transitions until something special happens.
        while i &+ 4 <= end {
          let n0 = t.load(fromByteOffset: Int(sid) &+ Int(classes[Int(hay[i])]), as: Int32.self)
          if n0 < 0 {
            break
          }
          let n1 = t.load(fromByteOffset: Int(n0) &+ Int(classes[Int(hay[i &+ 1])]), as: Int32.self)
          if n1 < 0 {
            sid = n0; i &+= 1; break
          }
          let n2 = t.load(fromByteOffset: Int(n1) &+ Int(classes[Int(hay[i &+ 2])]), as: Int32.self)
          if n2 < 0 {
            sid = n1; i &+= 2; break
          }
          let n3 = t.load(fromByteOffset: Int(n2) &+ Int(classes[Int(hay[i &+ 3])]), as: Int32.self)
          if n3 < 0 {
            sid = n2; i &+= 3; break
          }
          sid = n3
          i &+= 4
        }
        while i < end {
          let n = t.load(fromByteOffset: Int(sid) &+ Int(classes[Int(hay[i])]), as: Int32.self)
          if n < 0 {
            break
          }
          sid = n
          i &+= 1
        }
      }
      if i >= end {
        break
      }
      let cls = Int(classTable[Int(hay[i])] >> 2)
      var next = entry(sid, cls)
      if next == Self.unknown {
        guard let computed = computeTransition(from: &sid, class: cls) else { return .quit(at: i) }
        next = computed
      }
      switch next {
      case Self.match: return .match(at: i)
      case Self.quit: return .quit(at: i)
      case Self.dead: return .noMatch
      default:
        sid = next
        i += 1
      }
    }
    var eoi = entry(sid, eoiClass)
    if eoi == Self.unknown {
      guard let computed = computeTransition(from: &sid, class: eoiClass) else { return .quit(at: end) }
      eoi = computed
    }
    return eoi == Self.match ? .match(at: end) : .noMatch
  }

  /// The row index of a state.
  @inline(__always)
  private func index(of sid: Int32) -> Int {
    Int(sid) / (program.stride * MemoryLayout<Int32>.stride)
  }

  /// The cached transition from `sid` on class `cls`.
  @inline(__always)
  private func entry(_ sid: Int32, _ cls: Int) -> Int32 {
    table[index(of: sid) * program.stride + cls]
  }

  /// Computes, caches and returns the transition from `sid` on `cls`. May
  /// clear the cache, in which case `sid` is updated to the re-added state.
  /// Returns nil if the cache is being cleared too often to make progress.
  private mutating func computeTransition(from sid: inout Int32, class cls: Int) -> Int32? {
    var stateIndex = index(of: sid)
    if stateCount >= maxStates {
      clearsThisSearch += 1
      if clearsThisSearch > 8 {
        return nil
      }
      // Re-add the current state after clearing.
      let info = infos[stateIndex]
      let set = Array(setPool[info.setStart..<(info.setStart + info.setCount)])
      resetCache()
      sid = intern(set, looks: info.looks, fromWord: info.fromWord, fromCR: info.fromCR)
      stateIndex = index(of: sid)
    }
    let info = infos[stateIndex]
    let nfa = program.nfa
    let byte: UInt8? = cls == program.classCount ? nil : program.representatives[cls]
    let result: Int32
    if let byte, byte >= 0x80, program.quitOnNonASCII {
      result = Self.quit
    } else if byte == 13 && program.quitOnCR {
      result = Self.quit
    } else {
      // Resolve look-ahead assertions at the current position: the end of
      // a line is before the terminator, before `\n` (multi-line), and in
      // CRLF mode before `\r` but not between `\r` and `\n`.
      var lookNow = info.looks
      let atEnd = byte == nil || (byte != nil && byte == program.terminator)
      if atEnd {
        lookNow.insert(.endText)
      }
      if atEnd || byte == 10 {
        lookNow.insert(.endLine)
      }
      if byte == nil || byte == 13 || (byte == 10 && !info.fromCR) || (atEnd && byte != 10) {
        lookNow.insert(.endLineCRLF)
      }
      // A `\r` starts a line in CRLF mode unless a `\n` follows.
      if info.fromCR && byte != 10 {
        lookNow.insert(.startLineCRLF)
      }
      if program.usesWordLooks {
        let nextIsWord = byte.map(WordChars.isASCIIWord) ?? false
        for look in Look.allCases where look.isWordLook && nfa.looks.contains(look) {
          if look.holds(previousIsWord: info.fromWord, nextIsWord: nextIsWord) {
            lookNow.insert(look)
          }
        }
      }
      lookNow.bits &= nfa.looks.bits
      var working = Array(setPool[info.setStart..<(info.setStart + info.setCount)])
      if lookNow != info.looks && info.hasLookStates {
        working = closure(seeds: working, looks: lookNow)
      }
      let isMatch = working.contains(nfa.matchState)
      if isMatch {
        result = Self.match
      } else if let byte {
        scratchSet.removeAll(keepingCapacity: true)
        for s in working {
          let target = nfa.step(Int(s), byte)
          if target >= 0 {
            scratchSet.append(target)
          }
        }
        var lookNext = LookSet()
        let afterTerminator = byte == program.terminator
        if afterTerminator {
          lookNext.insert(.startText)
        }
        if afterTerminator || byte == 10 {
          lookNext.insert(.startLine)
          lookNext.insert(.startLineCRLF)
        }
        lookNext.bits &= nfa.looks.bits
        let fromWord = program.usesWordLooks && WordChars.isASCIIWord(byte)
        let fromCR = program.tracksCR && byte == 13
        let nextSet = closure(seeds: scratchSet, looks: lookNext)
        result = nextSet.isEmpty ? Self.dead : intern(nextSet, looks: lookNext, fromWord: fromWord, fromCR: fromCR)
      } else {
        result = Self.dead
      }
    }
    // `intern` may have grown the table; index it afresh.
    table[index(of: sid) * program.stride + cls] = result
    return result
  }

  /// The epsilon closure of `seeds`, following look states that hold under
  /// `looks`. Returns the sorted set of states that matter for stepping and
  /// matching (byte states, the match state and unresolved look states).
  private mutating func closure(seeds: [Int32], looks: LookSet) -> [Int32] {
    let nfa = program.nfa
    visited.clear()
    var result: [Int32] = []
    stack.removeAll(keepingCapacity: true)
    for seed in seeds.reversed() {
      stack.append(seed)
    }
    while let s = stack.popLast() {
      guard visited.insert(s) else { continue }
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
        result.append(s)
        let look = Look(rawValue: UInt8(nfa.argA[index]))!
        if looks.contains(look) {
          stack.append(nfa.argB[index])
        }
      case .capture:
        stack.append(nfa.argB[index])
      case .fail:
        break
      default:
        result.append(s)
      }
    }
    result.sort()
    return result
  }

  private mutating func intern(_ set: [Int32], looks: LookSet, fromWord: Bool, fromCR: Bool) -> Int32 {
    let key = StateKey(states: set, looks: looks.bits, fromWord: fromWord, fromCR: fromCR)
    if let existing = map[key] {
      return existing
    }
    let stride = program.stride
    let row = stateCount * stride
    let id = Int32(row * MemoryLayout<Int32>.stride)
    stateCount += 1
    table.append(copying: repeatElement(Self.unknown, count: stride))
    let nfa = program.nfa
    infos.append(StateInfo(
      setStart: setPool.count, setCount: set.count, looks: looks, fromWord: fromWord, fromCR: fromCR,
      hasLookStates: set.contains { nfa.kinds[Int($0)] == .look },
    ))
    setPool.append(contentsOf: set)
    map[key] = id
    return id
  }
}
