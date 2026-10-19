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
    return true
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

/// `-U`: searches that resume in the middle of the text.
struct Multiline {
  /// Successive matches across the whole text, as `-U` finds them.
  func multilineMatches(_ pattern: String, _ text: String, dotAll: Bool = false) throws -> [String] {
    var options = MatcherOptions()
    options.multiline = true
    options.multilineDotAll = dotAll
    let matcher = try Matcher(patterns: [pattern], options: options)
    var lineMatcher = matcher.makeLineMatcher()
    let bytes = Array(text.utf8)
    var result: [String] = []
    var pos = 0
    while pos <= bytes.count, let m = lineMatcher.findMultiline(in: bytes.span, from: pos, end: bytes.count) {
      result.append(String(decoding: bytes[m], as: UTF8.self))
      pos = m.isEmpty ? m.upperBound + 1 : m.upperBound
    }
    return result
  }

  @Test func `spans lines only when a match can`() throws {
    #expect(try Matcher(patterns: ["a\\nb"], options: { var o = MatcherOptions(); o.multiline = true; return o }())
      .isMultiline)
    // `^` and `\A` count as matching `\n`, as in ripgrep.
    #expect(try Matcher(patterns: ["^a"], options: { var o = MatcherOptions(); o.multiline = true; return o }())
      .isMultiline)
    #expect(try !Matcher(patterns: ["a.b"], options: { var o = MatcherOptions(); o.multiline = true; return o }())
      .isMultiline)
  }

  /// The DFA's start state depends on the byte before the resume position.
  @Test func `assertions see the text before the search position`() throws {
    #expect(try multilineMatches(#"\Aab"#, "abab\n") == ["ab"])
    #expect(try multilineMatches(#"b\z"#, "ab\nab") == ["b"])
    #expect(try multilineMatches(#"\Bx\n?"#, "axx x\n") == ["x", "x"])
    #expect(try multilineMatches(#"\bx\n?"#, "axx x\n") == ["x\n"])
    #expect(try multilineMatches(#"^x\n"#, "x\nx\nyx\n") == ["x\n", "x\n"])
    #expect(try multilineMatches(#"a.b"#, "a\nb", dotAll: true) == ["a\nb"])
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

  func message(_ patterns: [String]) -> String? {
    do {
      _ = try Matcher(patterns: patterns)
      return nil
    } catch {
      return error.description
    }
  }

  /// As in ripgrep, the patterns are parsed joined, and errors underline the
  /// whole part of the joined pattern in error.
  @Test func `errors show the joined pattern`() {
    #expect(message(["x{2,1}"]) == "regex parse error:\n    (?:x{2,1})\n        ^^^^^\n"
      + "error: invalid repetition count range, the start must be <= the end")
    #expect(message(["a(", "b"]) == "regex parse error:\n    (?:a()|(?:b)\n    ^\nerror: unclosed group")
    #expect(message(["(?<a>x)(?<a>y)"]) == "regex parse error:\n    (?:(?<a>x)(?<a>y))\n          ^      ^\n"
      + "error: duplicate capture group name")
    #expect(message(["\\p{Script=Nope}"]) == "regex parse error:\n    (?:\\p{Script=Nope})\n       ^^^^^^^^^^^^^^^\n"
      + "error: Unicode property value not found")
    // A pattern may close another's group.
    #expect(message(["a)|(b"]) == nil)
  }

  @Test(arguments: ["(?ii)", "(?i-i)", "(?i-)", "(?--i)", "(?<1a>x)", "(?)", "[\\b]", "[\\d-z]"])
  func `rejects like regex-syntax`(_ pattern: String) {
    #expect(throws: RegexError.self) { _ = try Matcher(patterns: [pattern]) }
  }

  /// Counted repetitions are limited by the compiled size, not the count.
  @Test func `size limit`() {
    #expect(message(["a{1001}"]) == nil)
    #expect(message(["a{4294967295}"]) == "compiled regex exceeds size limit of 104857600")
  }
}

/// The Unicode data is regex-syntax's (Unicode 16.0), as ripgrep uses.
struct UnicodeProperties {
  @Test func `scripts categories and properties`() throws {
    #expect(try matchingLines(#"\p{Greek}"#, "α\na\n") == ["α"])
    #expect(try matchingLines(#"\p{sc=Grek}"#, "α\na\n") == ["α"])
    #expect(try matchingLines(#"\p{scx:Greek}"#, "α\na\n") == ["α"])
    #expect(try matchingLines(#"\P{Greek}"#, "α\na\n") == ["a"])
    #expect(try matchingLines(#"\p{gc!=L}"#, "a\n1\n") == ["1"])
    #expect(try matchingLines(#"\p{isLetter}"#, "a\n1\n") == ["a"])
    #expect(try matchingLines(#"\p{Emoji_Presentation}"#, "😀\na\n") == ["😀"])
    // Unicode 1.1 has no euro sign (2.1).
    #expect(try matchingLines(#"\p{age=1.1}"#, "€\na\n") == ["a"])
  }

  @Test func `word characters come from Unicode 16`() throws {
    // U+088F is new in Unicode 17, so not a word character for ripgrep.
    #expect(try matchingLines(#"^\w$"#, "\u{88F}\nb\n") == ["b"])
  }

  /// Smart case looks at the syntax: only literals count.
  @Test func `smart case`() throws {
    var options = MatcherOptions()
    options.caseMode = .smart
    #expect(try matchingLines(#"\p{Lu}"#, "a\nA\n", options: options) == ["A"])
    #expect(try matchingLines(#"\x41b"#, "ab\nAb\n", options: options) == ["Ab"])
    #expect(try matchingLines(#"ab"#, "ab\nAB\n", options: options) == ["ab", "AB"])
    #expect(try matchingLines(#"[A]b"#, "ab\nAb\n", options: options) == ["Ab"])
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
        let expected = naive(needles, fold, haystack, from: from, to: haystack.count)
        let text = String(decoding: haystack, as: UTF8.self)
        #expect(finder.find(haystack.span, from: from, to: haystack.count) == expected,
                "needles \(needles.map { String(decoding: $0, as: UTF8.self) }) fold \(fold) in \(text)")
      }
    }
  }
}
