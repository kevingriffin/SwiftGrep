/// `--pre` and `-z`: files searched through the output of a command.
struct FileCommands: Sendable {
  let preprocessor: String?
  /// `--pre-glob` rules, with `--glob`'s semantics (`negated` means
  /// "preprocess").
  let preprocessorGlobs: IgnoreRules?
  let preprocessorGlobsWhitelist: Bool
  let decompress: Bool

  enum Command {
    case preprocess([String])
    case decompress([String])
  }

  /// ripgrep's decompression commands, by file name suffix.
  private static let decompressors: [(suffix: [UInt8], command: [String])] = [
    (".gz", ["gzip", "-d", "-c"]), (".tgz", ["gzip", "-d", "-c"]),
    (".bz2", ["bzip2", "-d", "-c"]), (".tbz2", ["bzip2", "-d", "-c"]),
    (".xz", ["xz", "-d", "-c"]), (".txz", ["xz", "-d", "-c"]),
    (".lz4", ["lz4", "-d", "-c"]), (".lzma", ["xz", "--format=lzma", "-d", "-c"]),
    (".br", ["brotli", "-d", "-c"]), (".zst", ["zstd", "-q", "-d", "-c"]), (".zstd", ["zstd", "-q", "-d", "-c"]),
    (".Z", ["uncompress", "-c"]),
  ].map { (Array($0.0.utf8), $0.1) }

  /// Returns nil unless `--pre` or `-z` is given.
  init?(_ config: Configuration) throws(UsageError) {
    guard config.preprocessor != nil || config.searchCompressed else { return nil }
    preprocessor = config.preprocessor
    decompress = config.searchCompressed
    var rules: [IgnoreRule] = []
    for pattern in config.preprocessorGlobs {
      let rule: IgnoreRule?
      do {
        rule = try IgnoreRules.parse(Array(pattern.utf8), caseInsensitive: false, allowUnclosedClass: false)
      } catch {
        throw UsageError(error.message)
      }
      if let rule {
        rules.append(IgnoreRule(glob: rule.glob, negated: !rule.negated, directoryOnly: rule.directoryOnly))
      }
    }
    preprocessorGlobs = rules.isEmpty ? nil : IgnoreRules(rules: rules)
    preprocessorGlobsWhitelist = rules.contains { $0.negated }
  }

  /// The command whose output is searched instead of `path` (relative to
  /// the current directory), if any.
  func command(for path: [UInt8]) -> Command? {
    let text = String(decoding: path, as: UTF8.self)
    if let preprocessor {
      if let rules = preprocessorGlobs {
        var relative = path[...]
        if relative.starts(with: Array("./".utf8)) {
          relative = relative.dropFirst(2)
        }
        let candidate = Array(relative)
        let nameStart = (candidate.lastIndex(of: UInt8(ascii: "/")) ?? -1) + 1
        switch rules.match(candidate.span, nameStart: nameStart, isDirectory: false) {
        case .ignore: return nil
        case .whitelist: break
        case .none: if preprocessorGlobsWhitelist {
            return nil
          }
        }
      }
      return .preprocess([preprocessor, text])
    }
    if decompress, let entry = Self.decompressors.first(where: { path.count > $0.suffix.count && path.ends(with: $0.suffix) }) {
      return .decompress(entry.command + [text])
    }
    return nil
  }

  /// A command as Rust's `Command` prints it: each argument quoted.
  static func describe(_ arguments: [String]) -> String {
    arguments.map(debugQuoted).joined(separator: " ")
  }

  private static func debugQuoted(_ text: String) -> String {
    var result = "\""
    for scalar in text.unicodeScalars {
      switch scalar {
      case "\"": result += "\\\""
      case "\\": result += "\\\\"
      case "\n": result += "\\n"
      case "\r": result += "\\r"
      case "\t": result += "\\t"
      case "\0": result += "\\0"
      default:
        if scalar.value < 0x20 || scalar.value == 0x7F {
          result += "\\u{" + String(scalar.value, radix: 16) + "}"
        } else {
          result.unicodeScalars.append(scalar)
        }
      }
    }
    return result + "\""
  }

  /// A failed command's error output, as ripgrep shows it.
  static func describe(errorOutput: [UInt8]) -> String {
    let message = String(decoding: errorOutput, as: UTF8.self).trimmingCharacters(in: " \t\r\n\u{0B}\u{0C}")
    guard !message.isEmpty else { return "<stderr is empty>" }
    let rule = String(repeating: "-", count: 79)
    return "\n\(rule)\n\(message)\n\(rule)"
  }
}

private extension [UInt8] {
  func ends(with suffix: [UInt8]) -> Bool {
    count >= suffix.count && self[(count - suffix.count)...].elementsEqual(suffix)
  }
}
