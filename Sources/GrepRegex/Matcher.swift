/// How letter case is treated.
public enum CaseMode: Sendable, Hashable {
  case sensitive
  case insensitive
  /// Insensitive unless the pattern contains an uppercase letter.
  case smart
}

/// How a pattern is interpreted.
public struct MatcherOptions: Sendable, Hashable {
  public var caseMode: CaseMode = .sensitive
  /// Treat patterns as literal strings rather than regular expressions.
  public var fixedStrings = false
  /// Only match whole words (`-w`).
  public var wordRegexp = false
  /// Only match whole lines (`-x`).
  public var lineRegexp = false

  public init() {}
}

/// A compiled set of patterns. Immutable and shared between threads; each
/// thread searches with its own `LineMatcher`.
public final class Matcher: Sendable {
  let nfa: FlatNFA
  let dfaProgram: DFAProgram
  let prefilter: Prefilter?
  /// When true, every prefilter hit is a match and no verification is needed.
  let prefilterIsExact: Bool
  /// Whether case-insensitive matching ended up enabled.
  public let isCaseInsensitive: Bool

  public init(patterns: [String], options: MatcherOptions = MatcherOptions()) throws(RegexError) {
    let insensitive: Bool = switch options.caseMode {
    case .sensitive: false
    case .insensitive: true
    case .smart: !patterns.contains(where: Self.hasUppercaseLiteral)
    }
    isCaseInsensitive = insensitive

    var flags = ParseFlags()
    flags.caseInsensitive = insensitive
    var nodes: [RegexNode] = []
    for pattern in patterns {
      if options.fixedStrings {
        nodes.append(Self.literalNode(pattern, caseInsensitive: insensitive))
      } else {
        try nodes.append(Parser.parse(pattern, flags: flags))
      }
    }
    var node = nodes.count == 1 ? nodes[0] : .alternate(nodes)
    if options.lineRegexp {
      node = .concat([.look(.startLine), .group(node), .look(.endLine)])
    } else if options.wordRegexp {
      node = .concat([.look(.wordStartHalf), .group(node), .look(.wordEndHalf)])
    }

    let compiled = try NFACompiler.compile(node, pattern: patterns.joined(separator: "|"))
    nfa = FlatNFA(compiled)
    dfaProgram = DFAProgram(nfa: nfa)

    let info = LiteralExtractor(foldASCII: insensitive).extract(node)
    if let exact = info.exact, info.precise,
       let filter = Prefilter(literals: exact, fold: insensitive, maxCost: 0.05)
    {
      prefilter = filter
      prefilterIsExact = true
    } else if let required = info.required,
              let filter = Prefilter(literals: required, fold: insensitive, maxCost: 0.004)
    {
      prefilter = filter
      prefilterIsExact = false
    } else {
      prefilter = nil
      prefilterIsExact = false
    }
  }

  /// A description of the search strategy, for `--debug` output.
  public var strategyDescription: String {
    let filter = switch prefilter {
    case let .byte(f): "memchr(\(f.byte))"
    case let .pair(f): "packed pair (\(f.needle.count) bytes)"
    case let .teddy(f): "teddy (\(f.count) literals, window \(f.offset)..<\(f.offset + f.width))"
    case let .multi(f): "multi-literal (\(f.needles.count) literals)"
    case nil: "none"
    }
    return "prefilter: \(filter)\(prefilterIsExact ? " (exact)" : ""), nfa states: \(nfa.count), byte classes: \(dfaProgram.classCount)"
  }

  /// Makes the per-thread search state.
  public func makeLineMatcher() -> LineMatcher {
    LineMatcher(matcher: self)
  }

  static func literalNode(_ string: String, caseInsensitive: Bool) -> RegexNode {
    let chars = string.unicodeScalars.map { scalar -> RegexNode in
      if caseInsensitive && CaseFolding.hasCase(scalar.value) {
        return .set(ScalarSet(scalar: scalar.value).caseFolded())
      }
      return .char(scalar.value)
    }
    return chars.count == 1 ? chars[0] : .concat(chars)
  }

  /// Smart case: does the pattern contain an uppercase literal character?
  /// Escape sequences such as `\S` or `\W` are not literals and don't count.
  static func hasUppercaseLiteral(_ pattern: String) -> Bool {
    let chars = Array(pattern.unicodeScalars)
    var i = 0
    while i < chars.count {
      let c = chars[i]
      if c == "\\" {
        i += 2
        // Skip braced arguments like \p{Greek} or \x{41}.
        if i < chars.count, chars[i] == "{" {
          while i < chars.count, chars[i] != "}" {
            i += 1
          }
        }
        continue
      }
      if c.properties.isUppercase {
        return true
      }
      i += 1
    }
    return false
  }
}

/// Per-thread search state for a `Matcher`: the lazy DFA cache and the Pike
/// VM's scratch memory. Not copyable, since it owns that memory.
public struct LineMatcher: ~Copyable {
  public let matcher: Matcher
  private var dfa: LazyDFA
  private var pike: PikeVM

  init(matcher: Matcher) {
    self.matcher = matcher
    dfa = LazyDFA(program: matcher.dfaProgram)
    pike = PikeVM(nfa: matcher.nfa)
  }

  /// Finds the next line containing a match.
  ///
  /// `from` must be the start of a line. `end` is the end of the searchable
  /// region: the haystack length, minus one if it ends with a line terminator.
  /// Returns the line's range without its terminator.
  public mutating func nextMatchingLine(in hay: Span<UInt8>, from: Int, end: Int) -> Range<Int>? {
    precondition(from >= 0 && end <= hay.count)
    guard from <= end else { return nil }
    if let prefilter = matcher.prefilter {
      var pos = from
      while pos < end {
        guard let hit = prefilter.find(hay, from: pos, to: end) else { return nil }
        let line = Self.line(around: hit, in: hay, from: pos, end: end)
        if matcher.prefilterIsExact || isMatch(hay, lineStart: line.lowerBound, lineEnd: line.upperBound) {
          return line
        }
        pos = line.upperBound + 1
      }
      return nil
    }
    var pos = from
    while pos <= end {
      switch dfa.findEarliest(hay, from: pos, end: end) {
      case .noMatch:
        return nil
      case let .match(at):
        return Self.line(around: at, in: hay, from: pos, end: end)
      case let .quit(at):
        let line = Self.line(around: at, in: hay, from: pos, end: end)
        if pike.isMatch(in: hay, lineStart: line.lowerBound, lineEnd: line.upperBound) {
          return line
        }
        pos = line.upperBound + 1
      }
    }
    return nil
  }

  /// The line (without its terminator) containing `position`, which lies in
  /// `[from, end]` with `from` at a line start.
  private static func line(around position: Int, in hay: Span<UInt8>, from: Int, end: Int) -> Range<Int> {
    let lineStart = hay.lastIndex(of: 10, in: from..<position).map { $0 + 1 } ?? from
    let lineEnd = hay.firstIndex(of: 10, in: position..<end) ?? end
    return lineStart..<lineEnd
  }

  /// Whether the line `[lineStart, lineEnd)` contains a match.
  public mutating func isMatch(_ hay: Span<UInt8>, lineStart: Int, lineEnd: Int) -> Bool {
    switch dfa.findEarliest(hay, from: lineStart, end: lineEnd) {
    case .match: true
    case .noMatch: false
    case .quit: pike.isMatch(in: hay, lineStart: lineStart, lineEnd: lineEnd)
    }
  }

  /// The leftmost-first match in the line `[lineStart, lineEnd)` that starts
  /// at or after `from`.
  public mutating func findMatch(in hay: Span<UInt8>, lineStart: Int, lineEnd: Int, from: Int) -> Range<Int>? {
    precondition(lineStart >= 0 && lineStart <= from && from <= lineEnd && lineEnd <= hay.count)
    return pike.find(in: hay, lineStart: lineStart, lineEnd: lineEnd, from: from)
  }

  /// Calls `body` with each successive non-overlapping match in the line.
  public mutating func forEachMatch(
    in hay: Span<UInt8>, lineStart: Int, lineEnd: Int, _ body: (Range<Int>) -> Void,
  ) {
    precondition(lineStart >= 0 && lineStart <= lineEnd && lineEnd <= hay.count)
    var at = lineStart
    var lastEnd = -1
    while at <= lineEnd {
      guard let m = pike.find(in: hay, lineStart: lineStart, lineEnd: lineEnd, from: at) else { return }
      if m.isEmpty {
        // An empty match right after the previous match is not reported.
        if m.lowerBound != lastEnd {
          body(m)
        }
        at = m.upperBound + (m.upperBound < lineEnd ? UTF8Decoding.characterLength(hay, at: m.upperBound, end: lineEnd) : 1)
      } else {
        body(m)
        at = m.upperBound
      }
      lastEnd = m.upperBound
    }
  }
}
