import Darwin

/// The outcome of matching a path against ignore rules.
enum IgnoreMatch: Sendable, Equatable {
  case none
  case ignore
  /// Explicitly re-included by a `!pattern` rule (or a positive `--glob`).
  case whitelist
}

/// One line of a gitignore-style file.
struct IgnoreRule: Sendable, Hashable {
  let glob: Glob
  let negated: Bool
  let directoryOnly: Bool
}

/// The rules from one ignore file (or from `--glob` flags), in file order.
///
/// Large ignore files (the Linux kernel's has over a hundred rules) would be
/// slow to scan for every entry, so like ripgrep's globset the rules are
/// indexed: rules that can only match one name, one extension or one path
/// are found by hashing, and only the rest are tried one by one.
final class IgnoreRules: Sendable {
  let rules: [IgnoreRule]
  /// Whether any rule is anchored and so needs the entry's relative path
  /// rather than just its name.
  let needsRelativePath: Bool

  /// Rule indices, ascending within each group; the tables map keys to
  /// ranges of this array.
  private let candidates: [Int32]
  /// Unanchored literal names (`Module.symvers`).
  private let byName: LiteralTable
  /// Unanchored suffixes with a dot (`*.o`, `*.so.dbg`), keyed by the final
  /// extension (`.o`, `.dbg`), which a matching name must share.
  private let byExtension: LiteralTable
  /// Anchored literal paths (`/vmlinux`).
  private let byPath: LiteralTable
  /// Every other rule.
  private let others: Range<Int>

  init(rules: [IgnoreRule]) {
    self.rules = rules
    needsRelativePath = rules.contains { $0.glob.anchored }
    var names: [[UInt8]: [Int32]] = [:]
    var extensions: [[UInt8]: [Int32]] = [:]
    var paths: [[UInt8]: [Int32]] = [:]
    var rest: [Int32] = []
    for (index, rule) in rules.enumerated() {
      let glob = rule.glob
      let i = Int32(index)
      switch glob.strategy {
      case .exact where !glob.caseInsensitive:
        if glob.anchored {
          paths[glob.bytes, default: []].append(i)
        } else {
          names[glob.bytes, default: []].append(i)
        }
      case .suffix where !glob.caseInsensitive && !glob.anchored && glob.bytes.contains(UInt8(ascii: ".")):
        let dot = glob.bytes.lastIndex(of: UInt8(ascii: "."))!
        extensions[Array(glob.bytes[dot...]), default: []].append(i)
      default:
        rest.append(i)
      }
    }
    var candidates: [Int32] = []
    func table(_ groups: [[UInt8]: [Int32]]) -> LiteralTable {
      LiteralTable(groups.map { key, indices in
        let start = candidates.count
        candidates.append(contentsOf: indices)
        return (key, start..<candidates.count)
      })
    }
    byName = table(names)
    byExtension = table(extensions)
    byPath = table(paths)
    others = candidates.count..<(candidates.count + rest.count)
    candidates.append(contentsOf: rest)
    self.candidates = candidates
  }

  /// Parses an ignore file. Lines that can't be parsed are skipped and
  /// described in `errors` (`line N: ...`), as ripgrep reports them; like
  /// ripgrep, reading stops at a line that isn't valid UTF-8.
  convenience init(gitignore contents: [UInt8], caseInsensitive: Bool = false, errors: inout [String]) {
    var rules: [IgnoreRule] = []
    var lineNumber = 0
    var start = 0
    // Most files are valid UTF-8 throughout; only otherwise is each line checked.
    let valid = (try? UTF8Span(validating: contents.span)) != nil
    while start < contents.count {
      lineNumber += 1
      let newline = contents[start...].firstIndex(of: 10) ?? contents.count
      var line = contents[start..<newline]
      start = newline + 1
      if line.last == 13 {
        line = line.dropLast()
      }
      if lineNumber == 1, line.starts(with: [0xEF, 0xBB, 0xBF]) {
        line = line.dropFirst(3)
      }
      guard valid || (try? UTF8Span(validating: Array(line).span)) != nil else {
        errors.append("line \(lineNumber): stream did not contain valid UTF-8")
        break
      }
      do {
        if let rule = try Self.parse(Array(line), caseInsensitive: caseInsensitive) {
          rules.append(rule)
        }
      } catch {
        errors.append("line \(lineNumber): \(error.message)")
      }
    }
    self.init(rules: rules)
  }

  convenience init(gitignore contents: [UInt8], caseInsensitive: Bool = false) {
    var errors: [String] = []
    self.init(gitignore: contents, caseInsensitive: caseInsensitive, errors: &errors)
  }

  /// A rule that can't be parsed.
  struct LineError: Error {
    /// `error parsing glob 'LINE': REASON`
    let message: String
  }

  /// One line of an ignore file or one `--glob`, as ripgrep's gitignore
  /// builder reads it. Returns nil for blank lines and comments. An unclosed
  /// `[` is literal in ignore files but an error in `--glob`.
  static func parse(_ raw: [UInt8], caseInsensitive: Bool, allowUnclosedClass: Bool = true) throws(LineError) -> IgnoreRule? {
    var line = raw[...]
    guard line.first != UInt8(ascii: "#") else { return nil }
    // Trailing whitespace is ignored unless the line ends with "\ ".
    if !line.suffix(2).elementsEqual([UInt8(ascii: "\\"), UInt8(ascii: " ")]) {
      line = Self.trimmingTrailingWhitespace(line)
    }
    guard !line.isEmpty else { return nil }
    let original = line
    var negated = false
    var absolute = false
    if line.starts(with: [UInt8(ascii: "\\"), UInt8(ascii: "!")]) || line.starts(with: [UInt8(ascii: "\\"), UInt8(ascii: "#")]) {
      line = line.dropFirst()
      absolute = line.first == UInt8(ascii: "/")
    } else {
      if line.first == UInt8(ascii: "!") {
        negated = true
        line = line.dropFirst()
      }
      if line.first == UInt8(ascii: "/") {
        line = line.dropFirst()
        absolute = true
      }
    }
    var directoryOnly = false
    if line.last == UInt8(ascii: "/") {
      directoryOnly = true
      line = line.dropLast()
      if line.last == UInt8(ascii: "\\") {
        line = line.dropLast()
      }
    }
    // A pattern without a slash matches at any depth.
    var glob = Array(line)
    if !absolute && !line.contains(UInt8(ascii: "/")) && !glob.starts(with: Array("**/".utf8)) && glob != Array("**".utf8) {
      glob = Array("**/".utf8) + glob
    }
    if glob.count >= 3 && glob.suffix(3).elementsEqual("/**".utf8) {
      glob += Array("/*".utf8)
    }
    do {
      let parsed = try Glob(parsing: glob, anchored: true, caseInsensitive: caseInsensitive,
                            allowUnclosedClass: allowUnclosedClass)
      return IgnoreRule(glob: parsed, negated: negated, directoryOnly: directoryOnly)
    } catch {
      throw LineError(message: "error parsing glob '\(String(decoding: original, as: UTF8.self))': \(error.message)")
    }
  }

  /// Rust's `trim_end`: drops trailing Unicode whitespace.
  private static func trimmingTrailingWhitespace(_ line: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
    var end = line.endIndex
    while end > line.startIndex, [9, 10, 11, 12, 13, 32].contains(line[end - 1]) {
      end -= 1
    }
    guard end > line.startIndex, line[end - 1] >= 0x80 else { return line[..<end] }
    var scalars = String(decoding: line[..<end], as: UTF8.self).unicodeScalars[...]
    while let last = scalars.last, last.properties.isWhitespace {
      scalars = scalars.dropLast()
    }
    return ArraySlice(String(String.UnicodeScalarView(scalars)).utf8)
  }

  /// The last matching rule decides.
  func match(_ path: Span<UInt8>, nameStart: Int, isDirectory: Bool) -> IgnoreMatch {
    let candidateArray = candidates
    let candidates = candidateArray.span
    let name = path.extracting(nameStart...)
    var best = -1
    if !byName.isEmpty {
      best = lastMatch(among: candidates, byName.lookup(name), above: best, path, nameStart, isDirectory)
    }
    if !byExtension.isEmpty, let dot = name.lastIndex(of: UInt8(ascii: "."), in: 0..<name.count) {
      best = lastMatch(among: candidates, byExtension.lookup(name.extracting(dot...)), above: best, path, nameStart, isDirectory)
    }
    if !byPath.isEmpty {
      best = lastMatch(among: candidates, byPath.lookup(path), above: best, path, nameStart, isDirectory)
    }
    best = lastMatch(among: candidates, others, above: best, path, nameStart, isDirectory)
    guard best >= 0 else { return .none }
    return rules[best].negated ? .whitelist : .ignore
  }

  /// The highest rule index in `candidates[range]` that matches the entry,
  /// if it is above `best`; otherwise `best`.
  private func lastMatch(
    among candidates: Span<Int32>, _ range: Range<Int>, above best: Int,
    _ path: Span<UInt8>, _ nameStart: Int, _ isDirectory: Bool,
  ) -> Int {
    var i = range.upperBound - 1
    while i >= range.lowerBound {
      let index = Int(candidates[i])
      guard index > best else { break }
      i -= 1
      if rules[index].directoryOnly && !isDirectory {
        continue
      }
      if rules[index].glob.matches(path, nameStart: nameStart) {
        return index
      }
    }
    return best
  }
}

/// An immutable hash table from byte strings to ranges, probed with a
/// borrowed key so lookups never allocate.
struct LiteralTable: Sendable {
  private struct Entry: Sendable {
    var keyStart: Int32
    var keyEnd: Int32
    var values: Range<Int>
  }

  /// Entry index + 1 for each slot; 0 marks an empty slot.
  private let slots: [Int32]
  private let entries: [Entry]
  private let keys: [UInt8]

  var isEmpty: Bool {
    entries.isEmpty
  }

  init(_ pairs: [([UInt8], Range<Int>)]) {
    var capacity = 1
    while capacity < pairs.count * 2 {
      capacity <<= 1
    }
    var slots = [Int32](repeating: 0, count: pairs.isEmpty ? 0 : capacity)
    var entries: [Entry] = []
    var keys: [UInt8] = []
    for (key, values) in pairs {
      entries.append(Entry(keyStart: Int32(keys.count), keyEnd: Int32(keys.count + key.count), values: values))
      keys.append(contentsOf: key)
      var slot = Self.hash(key.span) & (capacity - 1)
      while slots[slot] != 0 {
        slot = (slot + 1) & (capacity - 1)
      }
      slots[slot] = Int32(entries.count)
    }
    self.slots = slots
    self.entries = entries
    self.keys = keys
  }

  /// The range stored for `key`, or an empty range.
  func lookup(_ key: Span<UInt8>) -> Range<Int> {
    guard !slots.isEmpty else { return 0..<0 }
    let mask = slots.count - 1
    var slot = Self.hash(key) & mask
    let keys = keys.span
    while true {
      let index = Int(slots[slot])
      guard index > 0 else { return 0..<0 }
      let entry = entries[index - 1]
      if Int(entry.keyEnd - entry.keyStart) == key.count, Self.equal(keys, from: Int(entry.keyStart), key) {
        return entry.values
      }
      slot = (slot + 1) & mask
    }
  }

  private static func equal(_ keys: Span<UInt8>, from start: Int, _ key: Span<UInt8>) -> Bool {
    var i = 0
    while i < key.count {
      if keys[start + i] != key[i] {
        return false
      }
      i += 1
    }
    return true
  }

  /// FNV-1a.
  private static func hash(_ bytes: Span<UInt8>) -> Int {
    var h: UInt64 = 0xCBF2_9CE4_8422_2325
    var i = 0
    while i < bytes.count {
      h = (h ^ UInt64(bytes[i])) &* 0x0000_0100_0000_01B3
      i += 1
    }
    return Int(truncatingIfNeeded: h ^ (h >> 32))
  }
}

/// The ignore files found in one directory, linked to the parent directory's
/// level. Levels are immutable and shared by every job below the directory.
final class IgnoreLevel: Sendable {
  let parent: IgnoreLevel?
  /// Absolute path of the directory, with a trailing slash.
  let directory: [UInt8]
  let rgignore: IgnoreRules?
  let dotIgnore: IgnoreRules?
  let gitignore: IgnoreRules?
  let gitExclude: IgnoreRules?
  /// Whether the directory contains `.git`, i.e. is the root of a repository.
  let hasGit: Bool
  /// Whether this level or any ancestor has `.git`.
  let insideGit: Bool
  /// Whether any rule in this level or above needs relative paths.
  let needsRelativePath: Bool
  /// Whether there are any rules at all in this chain.
  let hasRules: Bool

  init(parent: IgnoreLevel?, directory: [UInt8], rgignore: IgnoreRules?, dotIgnore: IgnoreRules?,
       gitignore: IgnoreRules?, gitExclude: IgnoreRules?, hasGit: Bool)
  {
    self.parent = parent
    self.directory = directory
    self.rgignore = rgignore
    self.dotIgnore = dotIgnore
    self.gitignore = gitignore
    self.gitExclude = gitExclude
    self.hasGit = hasGit
    insideGit = hasGit || (parent?.insideGit ?? false)
    let own = [rgignore, dotIgnore, gitignore, gitExclude].compactMap(\.self)
    needsRelativePath = own.contains { $0.needsRelativePath } || (parent?.needsRelativePath ?? false)
    hasRules = !own.isEmpty || (parent?.hasRules ?? false)
  }
}

/// Global ignore settings shared by the whole walk.
struct IgnoreContext: Sendable {
  var useRgignore = true
  var useDotIgnore = true
  var useGitignore = true
  var useGitExclude = true
  var useGlobalGitignore = true
  var requireGit = true
  /// `--ignore-file-case-insensitive`.
  var caseInsensitive = false
  var global: IgnoreRules?

  /// Matches an entry against the chain of levels, mirroring the precedence of
  /// ripgrep's `ignore` crate: `.rgignore` > `.ignore` > `.gitignore` >
  /// `.git/info/exclude` > global excludes, with the deepest match winning
  /// within each kind, and gitignore rules stopping at a repository root.
  ///
  /// `path` is the entry's absolute path when `level.needsRelativePath`,
  /// otherwise just its name. `nameStart` is where the name begins in `path`.
  func match(level: IgnoreLevel, path: Span<UInt8>, nameStart: Int, isDirectory: Bool) -> IgnoreMatch {
    let anyGit = !requireGit || level.insideGit
    var custom = IgnoreMatch.none
    var dot = IgnoreMatch.none
    var git = IgnoreMatch.none
    var exclude = IgnoreMatch.none
    var sawGit = false
    var current: IgnoreLevel? = level
    let useFullPath = level.needsRelativePath
    var repoRootLength = 0
    while let l = current {
      let base = useFullPath ? l.directory.count : 0
      let relative = path.extracting(min(base, path.count)...)
      let relativeName = nameStart - base
      if custom == .none, let rules = l.rgignore {
        custom = rules.match(relative, nameStart: relativeName, isDirectory: isDirectory)
      }
      if dot == .none, let rules = l.dotIgnore {
        dot = rules.match(relative, nameStart: relativeName, isDirectory: isDirectory)
      }
      if anyGit && !sawGit {
        if git == .none, let rules = l.gitignore {
          git = rules.match(relative, nameStart: relativeName, isDirectory: isDirectory)
        }
        if exclude == .none, let rules = l.gitExclude {
          exclude = rules.match(relative, nameStart: relativeName, isDirectory: isDirectory)
        }
      }
      if l.hasGit && !sawGit {
        repoRootLength = base
      }
      sawGit = sawGit || l.hasGit
      current = l.parent
    }
    if custom != .none {
      return custom
    }
    if dot != .none {
      return dot
    }
    if git != .none {
      return git
    }
    if exclude != .none {
      return exclude
    }
    if anyGit, let global {
      let relative = path.extracting(min(repoRootLength, path.count)...)
      return global.match(relative, nameStart: nameStart - repoRootLength, isDirectory: isDirectory)
    }
    return .none
  }
}

/// Locating and reading git configuration for the global excludes file.
enum GitConfig {
  static func globalExcludesFile() -> String? {
    let home = FileIO.environment("HOME") ?? ""
    let xdg = FileIO.environment("XDG_CONFIG_HOME").flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.config"
    for config in [xdg + "/git/config", home + "/.gitconfig"] {
      if let value = excludesFile(inConfig: config) {
        return value.hasPrefix("~/") ? home + value.dropFirst(1) : value
      }
    }
    return xdg + "/git/ignore"
  }

  /// A minimal git config reader: finds `excludesfile` in a `[core]` section.
  private static func excludesFile(inConfig path: String) -> String? {
    guard let data = try? FileIO.readWholeFile(path: path) else { return nil }
    var inCore = false
    var result: String?
    for rawLine in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true) {
      let line = rawLine.trimmingCharacters(in: " \t\r")
      if line.hasPrefix("[") {
        let name = line.dropFirst().prefix { $0 != "]" && $0 != " " && $0 != "\"" }
        inCore = name.lowercased() == "core"
        continue
      }
      guard inCore, let eq = line.firstIndex(of: "=") else { continue }
      let key = line[..<eq].trimmingCharacters(in: " \t").lowercased()
      guard key == "excludesfile" else { continue }
      var value = line[line.index(after: eq)...].trimmingCharacters(in: " \t")
      if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
        value = String(value.dropFirst().dropLast())
      }
      result = value // the last assignment wins
    }
    return result
  }
}

extension StringProtocol {
  func trimmingCharacters(in set: String) -> String {
    let scalars = Set(set.unicodeScalars)
    var view = Substring(self).unicodeScalars[...]
    while let f = view.first, scalars.contains(f) {
      view = view.dropFirst()
    }
    while let l = view.last, scalars.contains(l) {
      view = view.dropLast()
    }
    return String(String.UnicodeScalarView(view))
  }
}
