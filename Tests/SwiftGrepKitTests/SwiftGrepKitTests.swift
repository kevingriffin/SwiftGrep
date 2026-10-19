import Darwin
@testable import SwiftGrepKit
import System
import Testing

struct Globs {
  func matches(_ pattern: String, _ path: String, anchored: Bool? = nil) -> Bool {
    let bytes = Array(pattern.utf8)
    let glob = Glob(bytes, anchored: anchored ?? bytes.contains(UInt8(ascii: "/")))
    return glob.matches(Array(path.utf8))
  }

  @Test func basenames() {
    #expect(matches("*.nix", "pkgs/foo/default.nix"))
    #expect(!matches("*.nix", "pkgs/foo/default.nixx"))
    #expect(matches("result-*", "result-bin"))
    #expect(matches("tags", "a/b/tags"))
    #expect(!matches("tags", "a/b/tags2"))
    #expect(matches(".*.sw[po]", ".file.swp"))
    #expect(matches("\\#*\\#", "#scratch#"))
  }

  @Test func anchored() {
    #expect(matches("doc/NEWS.html", "doc/NEWS.html"))
    #expect(!matches("doc/NEWS.html", "x/doc/NEWS.html"))
    #expect(matches("pkgs/*/tmp", "pkgs/qt/tmp"))
    #expect(!matches("pkgs/*/tmp", "pkgs/qt/x/tmp"))
  }

  @Test func `double star`() {
    #expect(matches("a/**/b", "a/b"))
    #expect(matches("a/**/b", "a/x/y/b"))
    #expect(!matches("a/**/b", "a/x/y/c"))
    #expect(matches("a/**", "a/x/y"))
    #expect(matches("**/foo", "x/y/foo"))
    #expect(matches("**", "anything/at/all"))
  }

  @Test func classes() {
    #expect(matches("[Mm]akefile", "Makefile"))
    #expect(matches("[!a]x", "bx"))
    #expect(!matches("[!a]x", "ax"))
    #expect(matches("*.[ch]", "x.h"))
    // As in ripgrep's globs, `?` and classes match bytes, not characters.
    #expect(!matches("f?o", "fäo"))
    #expect(matches("f??o", "fäo"))
    #expect(!matches("f[ä]o", "fäo"))
  }

  @Test func `case insensitive`() {
    let glob = Glob(Array("*.MD".utf8), anchored: false, caseInsensitive: true)
    #expect(glob.matches(Array("README.md".utf8)))
  }

  @Test func alternatives() {
    #expect(matches("*.{c,h}", "a/x.h"))
    #expect(!matches("*.{c,h}", "x.cc"))
    #expect(matches("{a,{b,c}}x", "cx"))
    // As in globset, empty alternatives are dropped.
    #expect(!matches("x{,y}", "x"))
    #expect(matches("x{,y}", "xy"))
    #expect(throws: Glob.ParseError.self) {
      try Glob(parsing: Array("*.{c".utf8), anchored: false, caseInsensitive: false)
    }
  }
}

struct GitignoreRules {
  func match(_ rules: String, _ path: String, directory: Bool = false) -> IgnoreMatch {
    let parsed = IgnoreRules(gitignore: Array(rules.utf8))
    let bytes = Array(path.utf8)
    let nameStart = (bytes.lastIndex(of: UInt8(ascii: "/")) ?? -1) + 1
    return parsed.match(bytes.span, nameStart: nameStart, isDirectory: directory)
  }

  @Test func `last match wins`() {
    let rules = "*.log\n!keep.log\n"
    #expect(match(rules, "a/debug.log") == .ignore)
    #expect(match(rules, "a/keep.log") == .whitelist)
    #expect(match(rules, "a/readme") == .none)
  }

  @Test func `directory only`() {
    #expect(match("build/\n", "x/build", directory: true) == .ignore)
    #expect(match("build/\n", "x/build", directory: false) == .none)
  }

  @Test func `comments and escapes`() {
    #expect(match("# comment\n\\#notes\n", "#notes") == .ignore)
    #expect(match("trailing   \n", "trailing") == .ignore)
    #expect(match("\\!bang\n", "!bang") == .ignore)
  }

  @Test func `leading slash anchors`() {
    #expect(match("/AGENTS.md\n", "AGENTS.md") == .ignore)
    #expect(match("/AGENTS.md\n", "sub/AGENTS.md") == .none)
    #expect(match("**/node_modules\n", "a/b/node_modules", directory: true) == .ignore)
  }

  /// Rules are indexed by name, extension and path, but file order still
  /// decides across the groups.
  @Test func `indexed rules keep file order`() {
    let rules = "*.o\n!keep.o\n*.so.dbg\n!/top/x.so.dbg\nvmlinux\n!*\n*.o.*\nTAGS\n/top/TAGS\n*~\n"
    #expect(match(rules, "a/main.o") == .whitelist) // `!*` comes after `*.o`
    #expect(match(rules, "a/main.o.cmd") == .ignore) // `*.o.*`
    #expect(match(rules, "TAGS") == .ignore)
    #expect(match(rules, "top/TAGS") == .ignore)
    #expect(match(rules, "a/file.c~") == .ignore)
    #expect(match(rules, "a/lib.so.dbg") == .whitelist)
    #expect(match("*.so.dbg\n", "a/lib.so.dbg") == .ignore)
    #expect(match("*.so.dbg\n", "a/lib.dbg") == .none)
    #expect(match("*.o\n!keep.o\n", "a/keep.o") == .whitelist)
    #expect(match("!keep.o\n*.o\n", "a/keep.o") == .ignore)
    #expect(match("*.o\n!/top/x.o\n", "top/x.o") == .whitelist)
    #expect(match("*.o\n!/top/x.o\n", "other/top/x.o") == .ignore)
    #expect(match("*.asn1.[ch]\n", "x.asn1.c") == .ignore)
    #expect(match("*.long-type-*.txt\n", "a.long-type-7.txt") == .ignore)
    #expect(match("*.long-type-*.txt\n", "a.long-type-7.txtx") == .none)
    #expect(match("\\#*#\n", "#draft#") == .ignore)
    #expect(match("\\#*#\n", "#") == .none)
  }
}

struct Arguments {
  func parse(_ args: [String]) throws -> Configuration {
    guard case let .search(config) = try ArgumentParser.parse(args) else {
      Issue.record("expected a search")
      return Configuration()
    }
    return config
  }

  @Test func `clustered short flags`() throws {
    let c = try parse(["-inC2", "foo", "dir"])
    #expect(c.matcher.caseMode == .insensitive)
    #expect(c.lineNumbers == true)
    #expect(c.context.before == 2 && c.context.after == 2)
    #expect(c.patterns == ["foo"])
    #expect(c.paths == ["dir"])
  }

  @Test func `long flags with values`() throws {
    let c = try parse(["--max-count=3", "--glob", "*.nix", "-e", "a", "-e", "b", "--", "-path"])
    #expect(c.maxCount == 3)
    #expect(c.globs.map(\.pattern) == ["*.nix"])
    #expect(c.patterns == ["a", "b"])
    #expect(c.paths == ["-path"])
  }

  @Test func unrestricted() throws {
    let c = try parse(["-uuu", "x"])
    #expect(c.noIgnore && c.hidden && c.binary == .search)
  }

  @Test func errors() {
    #expect(throws: UsageError.self) { _ = try ArgumentParser.parse(["--nope", "x"]) }
    #expect(throws: UsageError.self) { _ = try ArgumentParser.parse([]) }
    #expect(throws: UsageError.self) { _ = try ArgumentParser.parse(["-A"]) }
  }
}

struct Encoding {
  func decode(_ bytes: [UInt8], _ encoding: TextEncoding) -> String {
    var output: [UInt8] = []
    #expect(Encodings.decode(bytes.span, from: encoding, into: &output))
    return String(decoding: output, as: UTF8.self)
  }

  func plan(_ bytes: [UInt8], _ mode: EncodingMode) -> (Int, TextEncoding?) {
    Encodings.plan(bytes.span, mode)
  }

  @Test func `utf-16 surrogates and odd bytes`() {
    #expect(decode([0x3D, 0xD8, 0x00, 0xDE, 0x41, 0x00], .utf16LE) == "😀A")
    // An unpaired lead surrogate, a lone trail surrogate and a final odd byte.
    #expect(decode([0x3D, 0xD8, 0x41, 0x00, 0x00, 0xDE, 0x42], .utf16LE) == "\u{FFFD}A\u{FFFD}\u{FFFD}")
    #expect(decode([0x00, 0x41], .utf16BE) == "A")
  }

  @Test func `invalid utf-8 becomes replacement characters`() {
    #expect(decode([0x61, 0xFF, 0x62], .utf8) == "a\u{FFFD}b")
    // Each maximal invalid subsequence is one error: E0 must be followed by
    // A0...BF, and a truncated sequence ends at the byte that breaks it.
    #expect(decode([0xE0, 0x80, 0x7A], .utf8) == "\u{FFFD}\u{FFFD}z")
    #expect(decode([0xF0, 0x9F, 0x98, 0x68], .utf8) == "\u{FFFD}h")
    #expect(decode([0xED, 0xA0, 0x80], .utf8) == "\u{FFFD}\u{FFFD}\u{FFFD}")
  }

  @Test func `labels and single-byte encodings`() throws {
    let latin1 = try #require(Encodings.encoding(forLabel: " Latin1 "))
    // WHATWG maps latin1 to windows-1252.
    #expect(decode([0x80, 0x41], latin1) == "€A")
    #expect(Encodings.encoding(forLabel: "csunicode") == .utf16LE)
    #expect(Encodings.encoding(forLabel: "replacement") == nil)
    let iso88593 = try #require(Encodings.encoding(forLabel: "iso-8859-3"))
    #expect(decode([0xA5], iso88593) == "\u{FFFD}")
  }

  @Test func `cjk encodings through iconv`() {
    #expect(decode([0x93, 0xFA, 0x96, 0x7B], .shiftJIS) == "日本")
    #expect(decode([0x93, 0xFA, 0x96], .shiftJIS) == "日\u{FFFD}")
  }

  @Test func `byte order marks`() {
    #expect(plan([0xFF, 0xFE, 0x41, 0], .auto) == (2, .utf16LE))
    #expect(plan([0xEF, 0xBB, 0xBF, 0x41], .auto) == (3, nil))
    #expect(plan([0xFF, 0xFE, 0x41, 0], .disabled) == (0, nil))
    // A UTF-16 byte order mark overrides -E; a UTF-8 one is only dropped.
    #expect(plan([0xFE, 0xFF, 0, 0x41], .some(.utf8)) == (2, .utf16BE))
    #expect(plan([0xEF, 0xBB, 0xBF, 0x41], .some(.utf16LE)) == (3, .utf16LE))
    // The decoder drops a second byte order mark of its own encoding.
    #expect(plan([0xFF, 0xFE, 0xFF, 0xFE, 0x41, 0], .auto) == (4, .utf16LE))
    #expect(plan([0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF], .auto) == (3, nil))
  }
}

struct Generated {
  @Test func `every flag is in the man page and completions`() {
    for kind in [GenerateKind.man, .bash, .zsh, .fish, .powershell] {
      let text = Generator.output(kind)
      for flag in Flag.declared where !flag.isHidden {
        let long = kind == .man ? "\\-\\-" + flag.long.split(separator: "-").joined(separator: "\\-") : flag.long
        #expect(text.contains(long), "\(kind) lacks --\(flag.long)")
      }
    }
  }
}

struct Binary {
  /// The same 64 KiB buffer refill logic, step by step over a byte array.
  @Test func `searchable length matches ripgrep buffering`() {
    let line = Array(repeating: UInt8(ascii: "y"), count: 79) + [10]
    var data: [UInt8] = Array("foo\n".utf8)
    for _ in 0..<1000 {
      data += line
    }
    let nul = data.count
    data += [0, 10] + Array("foo\n".utf8)
    let limit = LineBufferModel.searchableLength(data.span, nulOffset: nul)
    // The first 64 KiB chunk is searched up to its last complete line.
    #expect(limit > 0 && limit < nul)
    #expect(data[limit - 1] == 10)
    #expect(limit <= LineBufferModel.capacity)
  }

  @Test func `nul in first chunk skips everything`() {
    let data: [UInt8] = Array("foo\0bar\n".utf8)
    let limit = LineBufferModel.searchableLength(data.span, nulOffset: 3)
    #expect(limit == 0)
  }
}

struct Hardening {
  /// Backtracking glob matchers take exponential time on patterns like
  /// this; the position-set matcher must finish instantly.
  @Test func `globs cannot blow up`() {
    let pattern = Array(String(repeating: "*a", count: 20).utf8) + Array("*b".utf8)
    let glob = Glob(pattern, anchored: false)
    let name = Array(String(repeating: "a", count: 200).utf8)
    let start = ContinuousClock.now
    #expect(!glob.matches(name))
    #expect(glob.matches(name + Array("b".utf8)))
    #expect(ContinuousClock.now - start < .seconds(1))
    // Very long patterns and paths work without recursion.
    let long = Glob(Array(String(repeating: "*x", count: 2000).utf8), anchored: true)
    #expect(long.matches(Array(String(repeating: "x", count: 3000).utf8)))
    #expect(!long.matches(Array(String(repeating: "x", count: 1999).utf8)))
  }

  /// Alternate groups nest with an explicit stack and a limit, so a hostile
  /// ignore file can't exhaust the stack.
  @Test func `glob nesting is limited`() throws {
    let deep = String(repeating: "{a,", count: 10000) + "b" + String(repeating: "}", count: 10000)
    #expect(throws: Glob.ParseError.self) {
      try Glob(parsing: Array(deep.utf8), anchored: false, caseInsensitive: false)
    }
    let shallow = String(repeating: "{a,", count: 60) + "b" + String(repeating: "}", count: 60)
    let glob = try Glob(parsing: Array(shallow.utf8), anchored: false, caseInsensitive: false)
    #expect(glob.matches(Array("b".utf8)))
    // In an ignore file, the bad line is reported and the others still apply.
    var errors: [String] = []
    let rules = IgnoreRules(gitignore: Array(("x\n" + deep + "\ny\n").utf8), errors: &errors)
    #expect(errors.count == 1)
    #expect(rules.match(Array("y".utf8).span, nameStart: 0, isDirectory: false) == .ignore)
  }

  /// Lengths and offsets read from a cache file or `getattrlistbulk` are
  /// untrusted: going past the reader's range must throw, not trap.
  @Test func `byte reader stays in bounds`() throws {
    let bytes: [UInt8] = [0xFE, 0xFF, 0xFF, 0xFF, 1, 2, 3]
    let span = bytes.span
    var input = ByteReader(span)
    #expect(try input.read(Int32.self, from: span) == -2)
    var field = try input.take(2)
    #expect(try field.read(UInt16.self, from: span) == 0x0201)
    #expect(throws: ByteReader.Malformed.self) { try field.read(UInt8.self, from: span) }
    #expect(throws: ByteReader.Malformed.self) { try input.read(UInt16.self, from: span) }
    #expect(throws: ByteReader.Malformed.self) { try input.skip(-1) }
    #expect(throws: ByteReader.Malformed.self) { try ByteReader(span, from: 8) }
    #expect(throws: ByteReader.Malformed.self) { try ByteReader(span, from: -1) }
    #expect(throws: ByteReader.Malformed.self) { try ByteReader(5..<8, in: span) }
    #expect(try input.read(UInt8.self, from: span) == 3)
  }

  @Test func `directory names must be plain`() {
    func plain(_ name: String) -> Bool {
      DirectoryListing.isPlainName(Array(name.utf8).span)
    }
    for bad in ["", ".", "..", "a/b", "../x", "a\u{0}b"] {
      #expect(!plain(bad), "\(bad)")
    }
    for good in ["a", "...", ".hidden", "a b", "é"] {
      #expect(plain(good), "\(good)")
    }
  }
}

struct Ordering {
  @Test func `component wise`() {
    #expect(PathOrder.less(Array("a/x".utf8), Array("a-b/x".utf8)))
    #expect(PathOrder.less(Array("a/b".utf8), Array("a/c".utf8)))
    #expect(!PathOrder.less(Array("b".utf8), Array("a/z".utf8)))
  }
}

/// Runs `sg` in-process against a temporary directory tree.
@Suite(.serialized) struct EndToEnd {
  let root: String

  init() throws {
    var template = Array("/tmp/sg-tests-XXXXXX".utf8CString)
    let made = template.withUnsafeMutableBufferPointer { mkdtemp($0.baseAddress!) }
    root = String(cString: made!)
    try write("repo/.gitignore", "ignored.txt\nbuild/\n")
    try write("repo/.git/HEAD", "ref: refs/heads/main\n")
    try write("repo/a.txt", "alpha foo\nbeta\ngamma foo\n")
    try write("repo/ignored.txt", "foo\n")
    try write("repo/build/out.txt", "foo\n")
    try write("repo/.hidden", "foo\n")
    try write("repo/sub/b.nix", "{ foo = 1; }\n")
    try write("repo/bin.dat", "foo\0bar\n")
  }

  func write(_ relative: String, _ contents: String) throws {
    try write(relative, bytes: Array(contents.utf8))
  }

  func write(_ relative: String, bytes contents: [UInt8]) throws {
    let path = root + "/" + relative
    // Create parent directories one component at a time.
    _ = path.split(separator: "/").dropLast().reduce("") { partial, component in
      let next = partial + "/" + component
      mkdir(next, 0o755)
      return next
    }
    let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    guard fd >= 0 else { throw UsageError("cannot create \(path)") }
    defer { close(fd) }
    contents.withUnsafeBufferPointer { _ = Darwin.write(fd, $0.baseAddress, $0.count) }
  }

  func run(_ args: [String]) async -> (status: Int32, lines: [String]) {
    let outputPath = root + "/output-\(UInt32.random(in: 0...UInt32.max))"
    let fd = open(outputPath, O_RDWR | O_CREAT | O_TRUNC, 0o644)
    let status = await SwiftGrep.main(arguments: args, output: fd)
    close(fd)
    let data = (try? FileIO.readWholeFile(path: outputPath)) ?? []
    unlink(outputPath)
    let text = String(decoding: data, as: UTF8.self).replacing(root + "/repo/", with: "")
    return (status, text.split(separator: "\n").map(String.init).sorted())
  }

  @Test func `respects gitignore hidden and binary`() async {
    let result = await run(["foo", root + "/repo"])
    #expect(result.status == 0)
    #expect(result.lines == ["a.txt:alpha foo", "a.txt:gamma foo", "sub/b.nix:{ foo = 1; }"])
  }

  @Test func `unrestricted searches everything`() async {
    let result = await run(["-uuu", "-l", "foo", root + "/repo"])
    #expect(result.lines.contains("ignored.txt"))
    #expect(result.lines.contains("build/out.txt"))
    #expect(result.lines.contains(".hidden"))
    #expect(result.lines.contains("bin.dat"))
  }

  @Test func `counts and types`() async {
    #expect(await run(["-c", "foo", root + "/repo"]).lines == ["a.txt:2", "sub/b.nix:1"])
    #expect(await run(["-c", "-t", "nix", "foo", root + "/repo"]).lines == ["sub/b.nix:1"])
    #expect(await run(["-c", "-g", "!*.nix", "foo", root + "/repo"]).lines == ["a.txt:2"])
  }

  @Test func `explicit binary file`() async {
    let result = await run(["foo", root + "/repo/bin.dat"])
    #expect(result.lines == ["binary file matches (found \"\\0\" byte around offset 3)"])
  }

  @Test func `no match exit status`() async {
    #expect(await run(["zzz", root + "/repo"]).status == 1)
    #expect(await run(["foo", root + "/missing"]).status == 2)
  }

  @Test func `skips byte order mark`() async throws {
    try write("bom/a.txt", "\u{FEFF}foo first\nfoo\n")
    let path = root + "/bom/a.txt"
    #expect(await run(["-n", "--column", "^foo", path]).lines == ["1:1:foo first", "2:1:foo"])
    #expect(await run(["-E", "none", "-c", "^foo", path]).lines == ["1"])
  }

  @Test func `large files are searched as separate jobs`() async throws {
    let line = String(repeating: "x", count: 99) + "\n"
    try write("big/large.txt", String(repeating: line, count: 11000) + "needle\n" + line)
    try write("big/small.txt", "needle\n")
    let result = await run(["-c", "needle", root + "/big"])
    #expect(result.lines == [root + "/big/large.txt:1", root + "/big/small.txt:1"])
    #expect(await run(["-n", "needle", root + "/big/large.txt"]).lines == ["11001:needle"])
  }

  @Test func `sorted output`() async {
    let result = await run(["--sort", "path", "-n", "foo", root + "/repo"])
    #expect(result.lines.count == 3)
  }

  @Test func `utf-16 files are decoded`() async throws {
    let text = "foo bar\nbaz foo\n".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
    try write("enc/u16.txt", bytes: [0xFF, 0xFE] + text)
    let path = root + "/enc/u16.txt"
    #expect(await run(["-n", "-b", "foo", path]).lines == ["1:0:foo bar", "2:8:baz foo"])
    #expect(await run(["-E", "none", "-c", "foo", path]).status == 1)
  }

  @Test func `multi-line matches`() async throws {
    try write("ml/a.txt", "one\ntwo\nthree\nfour\n")
    let path = root + "/ml/a.txt"
    #expect(await run(["-U", "-n", "two\\nthree", path]).lines == ["2:two", "3:three"])
    // Counts are of matches, as in ripgrep, though adjacent lines are one block.
    #expect(await run(["-U", "-c", "o\\n|e\\n", path]).lines == ["3"])
    #expect(await run(["-U", "-c", "\\Atwo", path]).status == 1)
  }

  @Test func `preprocessors and replacements`() async throws {
    try write("pre/a.txt", "foo\n")
    let path = root + "/pre/a.txt"
    #expect(await run(["--pre", "cat", "foo", path]).lines == ["foo"])
    #expect(await run(["--pre", "false", "foo", path]).status == 2)
    #expect(await run(["-r", "[$0]", "-o", "fo+", path]).lines == ["[foo]"])
  }

  @Test func `ignore files given on the command line`() async throws {
    try write("ign/a.txt", "foo\n")
    try write("ign/b.txt", "foo\n")
    try write("rules", "a.txt\n")
    let args = ["-l", "--ignore-file", root + "/rules", "foo", root + "/ign"]
    #expect(await run(args).lines == [root + "/ign/b.txt"])
    // Ignore files in the tree take precedence.
    try write("ign/.ignore", "!a.txt\n")
    #expect(await run(args).lines == [root + "/ign/a.txt", root + "/ign/b.txt"])
  }

  @Test func `configuration file`() throws {
    try write("config/rc", "# flags before the command line\n\n--context=2\n-i\n")
    let path = root + "/config/rc"
    let command = try ArgumentParser.parse(["-s", "foo"]) { $0 == "RIPGREP_CONFIG_PATH" ? path : nil }
    guard case let .search(config) = command else {
      Issue.record("expected a search")
      return
    }
    #expect(config.matcher.caseMode == .sensitive)
    guard case let .limited(_, _, both) = config.context else {
      Issue.record("expected limited context")
      return
    }
    #expect(both == 2)
  }
}

struct ListingCacheTests {
  func makeTemporaryDirectory() -> String {
    var template = Array("/tmp/sg-cache-XXXXXX".utf8CString)
    let made = template.withUnsafeMutableBufferPointer { mkdtemp($0.baseAddress!) }
    return String(cString: made!)
  }

  func touch(_ path: String) {
    close(open(path, O_WRONLY | O_CREAT, 0o644))
  }

  /// Reads `directory` the way the walker does: from the cache if valid,
  /// otherwise from the file system (recording the fresh listing).
  func list(_ directory: String, cache: ListingCache) throws -> (names: [String], cached: Bool) {
    let info = try Stat(FilePath(directory))
    let key = ListingCache.Key(info)
    var listing = DirectoryListing()
    let cached = cache.load(key, stamp: ListingCache.Stamp(info), into: &listing)
    if !cached {
      let file = try OS.open(directory, .readOnly, .directory)
      try listing.read(directory: file.descriptor)
      cache.record(key, stamp: ListingCache.Stamp(info), listing: listing)
    }
    let names = listing.entries.map { String(decoding: listing.nameBytes(of: $0), as: UTF8.self) }.sorted()
    return (names, cached)
  }

  @Test func `reuses unchanged listings and notices changes`() throws {
    let cacheDirectory = makeTemporaryDirectory()
    let tree = makeTemporaryDirectory()
    touch(tree + "/a")
    touch(tree + "/b")
    let root = Array(tree.utf8)

    var cache = try #require(ListingCache(root: root, directory: cacheDirectory, quietPeriod: 0))
    #expect(try list(tree, cache: cache) == (["a", "b"], false))
    cache.save()

    // A new process sees the saved listing without reading the directory.
    cache = try #require(ListingCache(root: root, directory: cacheDirectory, quietPeriod: 0))
    #expect(try list(tree, cache: cache) == (["a", "b"], true))

    // Adding an entry changes the directory's mtime, so the cache is bypassed.
    touch(tree + "/c")
    #expect(try list(tree, cache: cache) == (["a", "b", "c"], false))
    cache.save()
    cache = try #require(ListingCache(root: root, directory: cacheDirectory, quietPeriod: 0))
    #expect(try list(tree, cache: cache) == (["a", "b", "c"], true))

    // So does removing one.
    unlink(tree + "/a")
    #expect(try list(tree, cache: cache) == (["b", "c"], false))
  }

  @Test func `remembers large files`() throws {
    let cacheDirectory = makeTemporaryDirectory()
    let tree = makeTemporaryDirectory()
    touch(tree + "/small")
    let fd = open(tree + "/large", O_WRONLY | O_CREAT, 0o644)
    ftruncate(fd, DirectoryEntry.largeSize)
    close(fd)
    let root = Array(tree.utf8)
    let cache = try #require(ListingCache(root: root, directory: cacheDirectory, quietPeriod: 0))
    _ = try list(tree, cache: cache)
    cache.save()

    let reopened = try #require(ListingCache(root: root, directory: cacheDirectory, quietPeriod: 0))
    let info = try Stat(FilePath(tree))
    var listing = DirectoryListing()
    #expect(reopened.load(ListingCache.Key(info), stamp: ListingCache.Stamp(info), into: &listing))
    let large = listing.entries.map { (String(decoding: listing.nameBytes(of: $0), as: UTF8.self), $0.isLarge, $0.size) }
      .sorted { $0.0 < $1.0 }
    #expect(large.map(\.0) == ["large", "small"])
    #expect(large.map(\.1) == [true, false])
    #expect(large.allSatisfy { $0.2 == -1 }) // cached sizes are never trusted
  }

  @Test func `damaged cache files are misses`() throws {
    let cacheDirectory = makeTemporaryDirectory()
    let tree = makeTemporaryDirectory()
    touch(tree + "/a")
    let root = Array(tree.utf8)
    let cache = try #require(ListingCache(root: root, directory: cacheDirectory, quietPeriod: 0))
    _ = try list(tree, cache: cache)
    cache.save()
    let original = try FileIO.readWholeFile(path: cache.path)

    // Truncations, flipped bytes and absurd counts or offsets must never crash.
    var variants: [[UInt8]] = (0..<original.count).map { Array(original.prefix($0)) }
    for i in stride(from: 0, to: original.count, by: 3) {
      var damaged = original
      damaged[i] ^= 0xFF
      variants.append(damaged)
    }
    for damaged in variants {
      let fd = open(cache.path, O_WRONLY | O_TRUNC)
      _ = damaged.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
      close(fd)
      let reopened = try #require(ListingCache(root: root, directory: cacheDirectory, quietPeriod: 0))
      let names = try list(tree, cache: reopened).names
      #expect(names == ["a"] || names == [], "a damaged cache must give the real listing or none")
    }
  }

  @Test func `cache directory must be private`() {
    let home = makeTemporaryDirectory()
    mkdir(home + "/Library", 0o700)
    mkdir(home + "/Library/Caches", 0o700)
    let env: (String) -> String? = { ["HOME": home, "XDG_CACHE_HOME": "relative/dir"][$0] }
    // A relative XDG_CACHE_HOME is ignored.
    #expect(ListingCache.cacheDirectory(environment: env) == home + "/Library/Caches/SwiftGrep")
    // A directory others can write to is not used.
    chmod(home + "/Library/Caches/SwiftGrep", 0o777)
    #expect(ListingCache.cacheDirectory(environment: env) == nil)
    // Nor is a symlink.
    let elsewhere = makeTemporaryDirectory()
    let xdg = makeTemporaryDirectory()
    symlink(elsewhere, xdg + "/swiftgrep")
    #expect(ListingCache.cacheDirectory(environment: { $0 == "XDG_CACHE_HOME" ? xdg : nil }) == nil)
  }

  @Test func `recently changed directories are not recorded`() throws {
    let cacheDirectory = makeTemporaryDirectory()
    let tree = makeTemporaryDirectory()
    touch(tree + "/x")
    let cache = try #require(ListingCache(root: Array(tree.utf8), directory: cacheDirectory, quietPeriod: 60))
    _ = try list(tree, cache: cache)
    cache.save()
    let reopened = try #require(ListingCache(root: Array(tree.utf8), directory: cacheDirectory, quietPeriod: 60))
    #expect(try list(tree, cache: reopened).cached == false)
  }
}
