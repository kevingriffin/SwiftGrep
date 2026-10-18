@testable import GrepRegex
import Testing

/// Lines of `text` that match `pattern`, found through the DFA/prefilter path.
func matchingLines(_ pattern: String, _ text: String, options: MatcherOptions = MatcherOptions()) throws -> [String] {
  let matcher = try Matcher(patterns: [pattern], options: options)
  var lineMatcher = matcher.makeLineMatcher()
  let bytes = Array(text.utf8)
  guard !bytes.isEmpty else { return [] }
  let end = bytes.last == 10 ? bytes.count - 1 : bytes.count
  var result: [String] = []
  var pos = 0
  while pos <= end, let line = lineMatcher.nextMatchingLine(in: bytes.span, from: pos, end: end) {
    result.append(String(decoding: bytes[line], as: UTF8.self))
    pos = line.upperBound + 1
  }
  return result
}

/// All match spans in a single line, as substrings.
func matches(_ pattern: String, _ line: String, options: MatcherOptions = MatcherOptions()) throws -> [String] {
  let matcher = try Matcher(patterns: [pattern], options: options)
  var lineMatcher = matcher.makeLineMatcher()
  let bytes = Array(line.utf8)
  var result: [String] = []
  lineMatcher.forEachMatch(in: bytes.span, lineStart: 0, lineEnd: bytes.count) { m in
    result.append(String(decoding: bytes[m], as: UTF8.self))
  }
  return result
}

struct LineMatching {
  let text = "alpha foo\nbeta\ngamma foo foo\ndelta\nFOO bar\n"

  @Test func literal() throws {
    #expect(try matchingLines("foo", text) == ["alpha foo", "gamma foo foo"])
    #expect(try matchingLines("zzz", text) == [])
  }

  @Test func `case insensitive`() throws {
    var options = MatcherOptions()
    options.caseMode = .insensitive
    #expect(try matchingLines("foo", text, options: options) == ["alpha foo", "gamma foo foo", "FOO bar"])
    options.caseMode = .smart
    #expect(try matchingLines("foo", text, options: options).count == 3)
    #expect(try matchingLines("FOO", text, options: options) == ["FOO bar"])
  }

  @Test func `kelvin sign folds with K`() throws {
    var options = MatcherOptions()
    options.caseMode = .insensitive
    #expect(try matchingLines("kelvin", "\u{212A}elvin\nother\n", options: options) == ["\u{212A}elvin"])
    // Dotless i is not a case variant of i under simple case folding.
    #expect(try matchingLines("fix", "f\u{131}x\n", options: options) == [])
  }

  @Test func anchors() throws {
    #expect(try matchingLines("^foo", "foo\n foo\nfoo bar\n") == ["foo", "foo bar"])
    #expect(try matchingLines("foo$", "foo\nfoo \nbar foo\n") == ["foo", "bar foo"])
    #expect(try matchingLines("^$", "a\n\nb\n\n") == ["", ""])
    #expect(try matchingLines("^", "a\nb\n") == ["a", "b"])
    #expect(try matchingLines("^", "a\nb") == ["a", "b"])
    #expect(try matchingLines("^", "\n") == [""])
  }

  @Test func `crlf is not stripped`() throws {
    #expect(try matchingLines("foo$", "foo\r\nfoo\n") == ["foo"])
  }

  @Test func `word boundaries`() throws {
    let input = "foo-bar\n-foo\nfoobar\nfoo_x\nxfoo\n"
    #expect(try matchingLines(#"\bfoo\b"#, input) == ["foo-bar", "-foo"])
    var options = MatcherOptions()
    options.wordRegexp = true
    #expect(try matchingLines("foo", input, options: options) == ["foo-bar", "-foo"])
    #expect(try matchingLines("-foo", input, options: options) == ["-foo"])
    #expect(try matchingLines(#"\Bfoo"#, input) == ["xfoo"])
    #expect(try matchingLines(#"\<foo"#, input) == ["foo-bar", "-foo", "foobar", "foo_x"])
  }

  @Test func `unicode word boundary`() throws {
    // é is a word character, so there is no boundary between it and "foo".
    #expect(try matchingLines(#"\bfoo"#, "éfoo\n foo\n") == [" foo"])
    #expect(try matchingLines(#"(?-u:\b)foo"#, "éfoo\n") == ["éfoo"])
  }

  @Test func `line regexp`() throws {
    var options = MatcherOptions()
    options.lineRegexp = true
    #expect(try matchingLines("foo|bar", "foo\nbar\nfoobar\n", options: options) == ["foo", "bar"])
  }

  @Test func `classes and repetition`() throws {
    let input = "abc123\nxyz\n42\nA-Z\n"
    #expect(try matchingLines(#"\d+"#, input) == ["abc123", "42"])
    #expect(try matchingLines(#"^\d{2}$"#, input) == ["42"])
    #expect(try matchingLines("[^a-z0-9]", input) == ["A-Z"])
    #expect(try matchingLines("[[:upper:]]", input) == ["A-Z"])
    #expect(try matchingLines(#"[a-c&&b]"#, "b\na\n") == ["b"])
    #expect(try matchingLines("x{2,3}", "x\nxx\nxxxx\n") == ["xx", "xxxx"])
    #expect(try matchingLines("colou?r", "color\ncolour\ncolr\n") == ["color", "colour"])
  }

  @Test func `unicode classes`() throws {
    #expect(try matchingLines(#"^\w+$"#, "héllo\nhi there\n") == ["héllo"])
    #expect(try matchingLines(#"\p{Lu}"#, "abc\naBc\n") == ["aBc"])
    #expect(try matchingLines("ü", "über\nuber\n") == ["über"])
    #expect(try matchingLines("^.{3}$", "日本語\nab\n") == ["日本語"])
  }

  @Test func `dot never matches newline`() throws {
    #expect(try matchingLines("a.b", "a\nb\naxb\n") == ["axb"])
  }

  @Test func `alternation of literals`() throws {
    #expect(try matchingLines("cat|dog|bird", "a cat\nfish\nhotdog\nbirds\n") == ["a cat", "hotdog", "birds"])
  }

  @Test func `fixed strings`() throws {
    var options = MatcherOptions()
    options.fixedStrings = true
    #expect(try matchingLines("a.b(", "a.b(c\naxb(\n", options: options) == ["a.b(c"])
  }

  @Test func `empty pattern matches every line`() throws {
    #expect(try matchingLines("", "a\n\nb\n") == ["a", "", "b"])
  }

  /// A needle whose sampled bytes match at the very end of the haystack
  /// must not be compared past the end.
  @Test func `literal at end of buffer`() throws {
    for tail in ["ab", "abcde", "a", "abcdef"] {
      let text = String(repeating: "x", count: 100) + tail
      #expect(try matchingLines("abcdef", text) == (tail == "abcdef" ? [text] : []))
      #expect(try matchingLines("abcdef", text, options: { var o = MatcherOptions(); o.caseMode = .insensitive; return o }())
        == (tail == "abcdef" ? [text] : []))
    }
  }

  @Test func `last line without newline`() throws {
    #expect(try matchingLines("end", "start\nthe end") == ["the end"])
  }
}

struct Spans {
  @Test func `leftmost first`() throws {
    #expect(try matches("a|ab", "ab") == ["a"])
    #expect(try matches("ab|a", "ab") == ["ab"])
    #expect(try matches("a+", "caaab aa") == ["aaa", "aa"])
    #expect(try matches("a+?", "aaa") == ["a", "a", "a"])
    #expect(try matches("foo", "foo foo foo") == ["foo", "foo", "foo"])
    #expect(try matches(#"\w+"#, "héllo wörld") == ["héllo", "wörld"])
  }

  @Test func `empty matches`() throws {
    #expect(try matches("x*", "axb") == ["", "x", ""])
  }
}

struct Errors {
  @Test(arguments: ["(", "a)", "a{2,1}", #"\1"#, "[a", "*a", #"\p{Nope}"#, "(?=a)", "a\nb"])
  func rejects(_ pattern: String) {
    #expect(throws: RegexError.self) { _ = try Matcher(patterns: [pattern]) }
  }

  @Test func `literal newline message`() {
    do {
      _ = try Matcher(patterns: [#"foo\nbar"#])
      Issue.record("expected an error")
    } catch {
      #expect(error.message.contains("not allowed"))
    }
  }
}

/// Cross-checks the DFA and prefilter path against the Pike VM on random
/// patterns and haystacks.
struct Consistency {
  struct RandomGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
      state ^= state << 13
      state ^= state >> 7
      state ^= state << 17
      return state
    }
  }

  static let atoms = ["a", "b", "c", "ab", "[ab]", "[^a]", ".", #"\w"#, #"\d"#, "é", #"\b"#, "^", "$", "(a|bc)", "x?", #"\s"#]
  static let suffixes = ["", "", "", "*", "+", "?", "{2}", "{1,3}", "*?"]

  func randomPattern(_ rng: inout RandomGenerator) -> String {
    var pattern = ""
    for _ in 0..<Int.random(in: 1...4, using: &rng) {
      pattern += Self.atoms.randomElement(using: &rng)! + Self.suffixes.randomElement(using: &rng)!
    }
    if Int.random(in: 0..<5, using: &rng) == 0 {
      pattern += "|" + Self.atoms.randomElement(using: &rng)!
    }
    return pattern
  }

  func randomText(_ rng: inout RandomGenerator) -> String {
    let pieces = ["a", "b", "c", "ab", " ", "\n", "1", "é", "x", "_", "-", "bc"]
    var text = ""
    for _ in 0..<Int.random(in: 0...40, using: &rng) {
      text += pieces.randomElement(using: &rng)!
    }
    return text
  }

  @Test func `dfa agrees with pike VM`() throws {
    var rng = RandomGenerator(state: 0x9E37_79B9_7F4A_7C15)
    for _ in 0..<3000 {
      let pattern = randomPattern(&rng)
      let text = randomText(&rng)
      for caseMode in [CaseMode.sensitive, .insensitive] {
        var options = MatcherOptions()
        options.caseMode = caseMode
        options.wordRegexp = Int.random(in: 0..<4, using: &rng) == 0
        let matcher = try Matcher(patterns: [pattern], options: options)
        var lm = matcher.makeLineMatcher()
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { continue }
        let end = bytes.last == 10 ? bytes.count - 1 : bytes.count
        do {
          let buffer = bytes.span
          // Expected: each line checked with the Pike VM alone.
          var expected: [Range<Int>] = []
          var start = 0
          while start <= end {
            let lineEnd = buffer.firstIndex(of: 10, in: start..<end) ?? end
            if lm.findMatch(in: buffer, lineStart: start, lineEnd: lineEnd, from: start) != nil {
              expected.append(start..<lineEnd)
            }
            start = lineEnd + 1
          }
          var actual: [Range<Int>] = []
          var pos = 0
          while pos <= end, let line = lm.nextMatchingLine(in: buffer, from: pos, end: end) {
            actual.append(line)
            pos = line.upperBound + 1
          }
          #expect(actual == expected, "pattern \(pattern) case \(caseMode) word \(options.wordRegexp) text \(text.debugDescription)")
        }
      }
    }
  }
}

/// Checks the Teddy multi-literal search against a naive scan, with haystack
/// lengths around the 16- and 32-byte block boundaries.
struct TeddyTests {
  func naive(_ needles: [[UInt8]], _ fold: Bool, _ h: [UInt8], from: Int, to: Int) -> Int? {
    func lower(_ b: UInt8) -> UInt8 {
      fold && b >= 0x41 && b <= 0x5A ? b | 0x20 : b
    }
    for s in from..<max(from, to) {
      for n in needles where s + n.count <= to {
        if n.indices.allSatisfy({ lower(h[s + $0]) == lower(n[$0]) }) {
          return s
        }
      }
    }
    return nil
  }

  @Test func `agrees with naive search`() {
    var rng = Consistency.RandomGenerator(state: 0x2545_F491_4F6C_DD1D)
    let alphabet = Array("abcAB_xyz".utf8)
    for _ in 0..<4000 {
      let fold = Bool.random(using: &rng)
      let needles = (0..<Int.random(in: 2...12, using: &rng)).map { _ in
        (0..<Int.random(in: 1...6, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! }
      }
      let haystack = (0..<Int.random(in: 0...80, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! }
      let finder = TeddyFinder(needles: needles, fold: fold)
      let from = haystack.isEmpty ? 0 : Int.random(in: 0...min(3, haystack.count), using: &rng)
      do {
        #expect(finder.find(haystack.span, from: from, to: haystack.count) == naive(needles, fold, haystack, from: from, to: haystack.count),
                "needles \(needles.map { String(decoding: $0, as: UTF8.self) }) fold \(fold) in \(String(decoding: haystack, as: UTF8.self))")
      }
    }
  }
}
