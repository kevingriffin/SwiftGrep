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
  /// Unicode mode: `\w`, `.` and classes are Unicode aware (`--no-unicode`
  /// turns it off, like `(?-u)`).
  public var unicode = true
  /// Matches may span lines (`-U`).
  public var multiline = false
  /// With `multiline`, `.` matches line terminators too (`--multiline-dotall`).
  public var multilineDotAll = false
  /// `$` matches before `\r\n` and `.` doesn't match `\r` (`--crlf`).
  public var crlf = false
  /// The byte that ends lines: `\n`, or NUL with `--null-data`.
  public var lineTerminator: UInt8 = 10
  /// The largest compiled pattern, in bytes (`--regex-size-limit`).
  public var sizeLimit = 100 << 20
  /// The lazy DFA's cache per search thread, in bytes (`--dfa-size-limit`).
  public var dfaSizeLimit = 4 << 20
  /// Reject patterns that need a NUL byte, which binary detection makes
  /// impossible to match (as ripgrep does unless `--text` is given).
  public var banNUL = false
  /// Track capture groups, for `--replace`.
  public var captures = false

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
  let dfaCacheBytes: Int
  /// The byte that ends lines, or nil with `-U`.
  let terminator: UInt8?
  let crlf: Bool
  let groups: CaptureGroups

  public init(patterns: [String], options: MatcherOptions = MatcherOptions()) throws(RegexError) {
    var flags = ParseFlags()
    flags.caseInsensitive = options.caseMode == .insensitive
    flags.unicode = options.unicode
    flags.crlf = options.crlf
    flags.dotMatchesNewline = options.multiline && options.multilineDotAll
    var groups = CaptureGroups()
    var node: RegexNode
    var insensitive = flags.caseInsensitive
    if options.fixedStrings {
      // Smart case: every character is a literal.
      if options.caseMode == .smart {
        let scalars = patterns.lazy.flatMap(\.unicodeScalars)
        insensitive = !scalars.isEmpty && !scalars.contains { UnicodeClasses.isUppercase($0.value) }
      }
      let nodes = patterns.map { Self.literalNode($0, caseInsensitive: insensitive) }
      node = nodes.count == 1 ? nodes[0] : .alternate(nodes)
    } else {
      // Like ripgrep, parse the patterns as one regex, `(?:p1)|(?:p2)`: a
      // pattern may close another's group, capture groups are numbered
      // across all of them, and errors show the joined pattern.
      let joined = patterns.map { "(?:" + $0 + ")" }.joined(separator: "|")
      var literals = Parser.LiteralAnalysis()
      node = try Parser.parse(joined, flags: flags, groups: &groups, literals: &literals)
      // Smart case, as ripgrep decides it from the syntax tree: insensitive
      // if there's a literal and none is uppercase.
      if options.caseMode == .smart, literals.any, !literals.uppercase {
        insensitive = true
        flags.caseInsensitive = true
        groups = CaptureGroups()
        node = try Parser.parse(joined, flags: flags, groups: &groups, literals: &literals)
      }
    }
    isCaseInsensitive = insensitive
    if options.banNUL && !options.fixedStrings {
      try PatternRestrictions.checkNoNUL(node)
    }
    if options.lineRegexp {
      node = .concat([.look(options.crlf ? .startLineCRLF : .startLine), .group(node),
                      .look(options.crlf ? .endLineCRLF : .endLine)])
    } else if options.wordRegexp {
      node = .concat([.look(.wordStartHalf), .group(node), .look(.wordEndHalf)])
    }
    // A line-by-line search can't match the line terminator.
    if !options.multiline {
      if options.crlf {
        node = try PatternRestrictions.strip(node, 13)
      }
      node = try PatternRestrictions.strip(node, options.lineTerminator)
    }
    crlf = options.crlf
    self.groups = groups

    let compiled = try NFACompiler.compile(node, pattern: patterns.joined(separator: "|"),
                                           captures: options.captures && groups.count > 0, sizeLimit: options.sizeLimit)
    nfa = FlatNFA(compiled)
    // Like ripgrep, `-U` only searches across lines if a match can contain
    // the line terminator; otherwise lines are searched one by one. Line
    // anchors count as containing `\n`, as they do in ripgrep.
    let acrossLines = nfa.canMatch(options.lineTerminator) || options.lineTerminator == 10 && nfa.looks.containsLineLook
    terminator = options.multiline && acrossLines ? nil : options.lineTerminator
    dfaProgram = DFAProgram(nfa: nfa, terminator: terminator)
    dfaCacheBytes = options.dfaSizeLimit

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
    // Like ripgrep, patterns that are just literals are searched without a
    // regex, so the size limit doesn't apply to them.
    if !prefilterIsExact, nfa.memoryUsage > options.sizeLimit {
      throw RegexError(message: "compiled regex exceeds size limit of \(options.sizeLimit)", pattern: "", span: nil,
                       standalone: true)
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

  /// The index of the capture group with this name, if any.
  public func captureIndex(named name: String) -> Int? {
    groups.names[name]
  }

  /// The number of capture groups, not counting the whole match.
  public var captureCount: Int {
    groups.count
  }

  /// Whether matches can span lines (`-U` with a pattern that can match the
  /// line terminator).
  public var isMultiline: Bool {
    terminator == nil
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
}

/// Per-thread search state for a `Matcher`: the lazy DFA cache and the Pike
/// VM's scratch memory. Not copyable, since it owns that memory.
public struct LineMatcher: ~Copyable {
  public let matcher: Matcher
  private var dfa: LazyDFA
  private var pike: PikeVM
  /// Made when first needed (`--replace`).
  private var captureVM: CaptureVM?

  init(matcher: Matcher) {
    self.matcher = matcher
    dfa = LazyDFA(program: matcher.dfaProgram, cacheBytes: matcher.dfaCacheBytes)
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
        let line = line(around: hit, in: hay, from: pos, end: end)
        if matcher.prefilterIsExact || isMatch(hay, lineStart: line.lowerBound, lineEnd: contentEnd(hay, line)) {
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
        return line(around: at, in: hay, from: pos, end: end)
      case let .quit(at):
        let line = line(around: at, in: hay, from: pos, end: end)
        if pike.isMatch(in: hay, lineStart: line.lowerBound, lineEnd: contentEnd(hay, line)) {
          return line
        }
        pos = line.upperBound + 1
      }
    }
    return nil
  }

  /// The line (without its terminator) containing `position`, which lies in
  /// `[from, end]` with `from` at a line start.
  private func line(around position: Int, in hay: Span<UInt8>, from: Int, end: Int) -> Range<Int> {
    let terminator = matcher.terminator ?? 10
    let lineStart = hay.lastIndex(of: terminator, in: from..<position).map { $0 + 1 } ?? from
    let lineEnd = hay.firstIndex(of: terminator, in: position..<end) ?? end
    return lineStart..<lineEnd
  }

  /// The end of the line's contents: in CRLF mode a `\r` before the
  /// terminator isn't part of them.
  private func contentEnd(_ hay: Span<UInt8>, _ line: Range<Int>) -> Int {
    if matcher.crlf, line.upperBound > line.lowerBound, hay[line.upperBound - 1] == 13 {
      return line.upperBound - 1
    }
    return line.upperBound
  }

  /// Whether the line `[lineStart, lineEnd)` contains a match.
  public mutating func isMatch(_ hay: Span<UInt8>, lineStart: Int, lineEnd: Int) -> Bool {
    switch dfa.findEarliest(hay, from: lineStart, end: lineEnd) {
    case .match: true
    case .noMatch: false
    case .quit: pike.isMatch(in: hay, lineStart: lineStart, lineEnd: lineEnd)
    }
  }

  /// The leftmost-first match in `hay[from..<end]`, which is searched as a
  /// text of its own (as ripgrep does with `-U`, so `\A` and `^` match at
  /// `from`). The lazy DFA first checks that a match exists.
  public mutating func findMultiline(in hay: Span<UInt8>, from: Int, end: Int) -> Range<Int>? {
    precondition(matcher.isMultiline && from >= 0 && from <= end && end <= hay.count)
    // Every match contains one of the prefilter's literals.
    if let prefilter = matcher.prefilter, prefilter.find(hay, from: from, to: end) == nil {
      return nil
    }
    if case .noMatch = dfa.findEarliest(inText: hay, from: from, end: end) {
      return nil
    }
    return pike.find(in: hay, lineStart: 0, lineEnd: end, from: from)
  }

  /// The leftmost-first match in the line `[lineStart, lineEnd)` that starts
  /// at or after `from`.
  public mutating func findMatch(in hay: Span<UInt8>, lineStart: Int, lineEnd: Int, from: Int) -> Range<Int>? {
    precondition(lineStart >= 0 && lineStart <= from && from <= lineEnd && lineEnd <= hay.count)
    return pike.find(in: hay, lineStart: lineStart, lineEnd: lineEnd, from: from)
  }

  /// The capture groups of `match` in the line `[lineStart, lineEnd)`
  /// (group 0 is the match itself); nil for groups that didn't take part.
  public mutating func captures(in hay: Span<UInt8>, lineStart: Int, lineEnd: Int, match: Range<Int>) -> [Range<Int>?] {
    guard matcher.groups.count > 0 else { return [match] }
    if captureVM == nil {
      captureVM = CaptureVM(nfa: matcher.nfa, groups: matcher.groups.count)
    }
    return captureVM!.captures(in: hay, lineStart: lineStart, lineEnd: lineEnd, start: match.lowerBound) ?? [match]
  }

  /// Calls `body` with each successive non-overlapping match in the line.
  public mutating func forEachMatch(
    in hay: Span<UInt8>, lineStart: Int, lineEnd: Int, from: Int? = nil, _ body: (Range<Int>) -> Bool,
  ) {
    precondition(lineStart >= 0 && lineStart <= lineEnd && lineEnd <= hay.count)
    var at = from ?? lineStart
    var lastEnd = -1
    while at <= lineEnd {
      guard let m = pike.find(in: hay, lineStart: lineStart, lineEnd: lineEnd, from: at) else { return }
      if m.isEmpty {
        // An empty match right after the previous match is not reported.
        if m.lowerBound != lastEnd, !body(m) {
          return
        }
        // Like ripgrep's regex (with `utf8_empty` off), the next search
        // starts one byte later, even inside a UTF-8 sequence.
        at = m.upperBound + 1
      } else {
        guard body(m) else { return }
        at = m.upperBound
      }
      lastEnd = m.upperBound
    }
  }
}
