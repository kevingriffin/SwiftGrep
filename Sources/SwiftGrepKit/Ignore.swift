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
        if glob.anchored { paths[glob.bytes, default: []].append(i) } else { names[glob.bytes, default: []].append(i) }
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

  /// Parses gitignore syntax.
  convenience init(gitignore contents: some Collection<UInt8>, caseInsensitive: Bool = false) {
    var rules: [IgnoreRule] = []
    var line: [UInt8] = []
    for byte in contents {
      if byte == 10 {
        if let rule = Self.parse(line, caseInsensitive: caseInsensitive) { rules.append(rule) }
        line.removeAll(keepingCapacity: true)
      } else {
        line.append(byte)
      }
    }
    if let rule = Self.parse(line, caseInsensitive: caseInsensitive) { rules.append(rule) }
    self.init(rules: rules)
  }

  static func parse(_ raw: [UInt8], caseInsensitive: Bool) -> IgnoreRule? {
    var line = raw
    if line.last == 13 { line.removeLast() } // CRLF files
    // Trailing spaces are ignored unless escaped.
    while let last = line.last, last == UInt8(ascii: " ") {
      if line.count >= 2 && line[line.count - 2] == UInt8(ascii: "\\") { break }
      line.removeLast()
    }
    guard let first = line.first, first != UInt8(ascii: "#") else { return nil }
    var negated = false
    if first == UInt8(ascii: "!") {
      negated = true
      line.removeFirst()
    } else if first == UInt8(ascii: "\\"), line.count > 1,
              line[1] == UInt8(ascii: "!") || line[1] == UInt8(ascii: "#") {
      line.removeFirst()
    }
    var directoryOnly = false
    if line.last == UInt8(ascii: "/") {
      directoryOnly = true
      line.removeLast()
    }
    guard !line.isEmpty else { return nil }
    // A slash anywhere but the end anchors the pattern to the file's directory.
    var anchored = line.contains(UInt8(ascii: "/"))
    if line.first == UInt8(ascii: "/") { line.removeFirst() }
    // `**/name` matches at any depth, just like an unanchored name.
    if line.starts(with: Array("**/".utf8)), !line.dropFirst(3).contains(UInt8(ascii: "/")) {
      line.removeFirst(3)
      anchored = false
    }
    return IgnoreRule(glob: Glob(line, anchored: anchored, caseInsensitive: caseInsensitive),
                      negated: negated, directoryOnly: directoryOnly)
  }

  /// The last matching rule decides.
  func match(_ path: Span<UInt8>, nameStart: Int, isDirectory: Bool) -> IgnoreMatch {
    let candidateArray = self.candidates
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
    _ path: Span<UInt8>, _ nameStart: Int, _ isDirectory: Bool
  ) -> Int {
    var i = range.upperBound - 1
    while i >= range.lowerBound {
      let index = Int(candidates[i])
      guard index > best else { break }
      i -= 1
      if rules[index].directoryOnly && !isDirectory { continue }
      if rules[index].glob.matches(path, nameStart: nameStart) { return index }
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

  var isEmpty: Bool { entries.isEmpty }

  init(_ pairs: [([UInt8], Range<Int>)]) {
    var capacity = 1
    while capacity < pairs.count * 2 { capacity <<= 1 }
    var slots = [Int32](repeating: 0, count: pairs.isEmpty ? 0 : capacity)
    var entries: [Entry] = []
    var keys: [UInt8] = []
    for (key, values) in pairs {
      entries.append(Entry(keyStart: Int32(keys.count), keyEnd: Int32(keys.count + key.count), values: values))
      keys.append(contentsOf: key)
      var slot = Self.hash(key.span) & (capacity - 1)
      while slots[slot] != 0 { slot = (slot + 1) & (capacity - 1) }
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
    let keys = self.keys.span
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
      if keys[start + i] != key[i] { return false }
      i += 1
    }
    return true
  }

  /// FNV-1a.
  private static func hash(_ bytes: Span<UInt8>) -> Int {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    var i = 0
    while i < bytes.count {
      h = (h ^ UInt64(bytes[i])) &* 0x0000_0100_0000_01b3
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
       gitignore: IgnoreRules?, gitExclude: IgnoreRules?, hasGit: Bool) {
    self.parent = parent
    self.directory = directory
    self.rgignore = rgignore
    self.dotIgnore = dotIgnore
    self.gitignore = gitignore
    self.gitExclude = gitExclude
    self.hasGit = hasGit
    insideGit = hasGit || (parent?.insideGit ?? false)
    let own = [rgignore, dotIgnore, gitignore, gitExclude].compactMap { $0 }
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
      if l.hasGit && !sawGit { repoRootLength = base }
      sawGit = sawGit || l.hasGit
      current = l.parent
    }
    if custom != .none { return custom }
    if dot != .none { return dot }
    if git != .none { return git }
    if exclude != .none { return exclude }
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
    var result: String? = nil
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
    while let f = view.first, scalars.contains(f) { view = view.dropFirst() }
    while let l = view.last, scalars.contains(l) { view = view.dropLast() }
    return String(String.UnicodeScalarView(view))
  }
}

