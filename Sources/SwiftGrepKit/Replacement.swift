import GrepRegex

/// `--replace`: expands `$1`, `${name}` and `$$` in the replacement for one
/// match, with the rules of ripgrep's grep-matcher.
extension FileSearcher {
  mutating func interpolate(
    _ replacement: [UInt8], _ data: Span<UInt8>, line: Range<Int>, _ match: Range<Int>, into result: inout [UInt8],
  ) {
    let groups = matcher.captures(in: data, lineStart: line.lowerBound, lineEnd: contentEnd(data, line), match: match)
    let names = shared.matcher
    Replacement.expand(replacement, into: &result) { reference, result in
      let index: Int? = switch reference {
      case let .number(n): n
      case let .name(name): names.captureIndex(named: name)
      }
      guard let index, index < groups.count, let group = groups[index] else { return }
      result.append(contentsOf: Array(copying: data.extracting(group)))
    }
  }
}

enum Replacement {
  enum Reference {
    case number(Int)
    case name(String)
  }

  /// Copies `template` into `result`, calling `append` for each group
  /// reference. `$$` is a literal `$`; a `$` that doesn't start a valid
  /// reference is kept as it is.
  static func expand(_ template: [UInt8], into result: inout [UInt8], _ append: (Reference, inout [UInt8]) -> Void) {
    var i = 0
    while i < template.count {
      guard template[i] == UInt8(ascii: "$") else {
        result.append(template[i])
        i += 1
        continue
      }
      if i + 1 < template.count, template[i + 1] == UInt8(ascii: "$") {
        result.append(UInt8(ascii: "$"))
        i += 2
        continue
      }
      guard let (reference, end) = parseReference(template, at: i) else {
        result.append(UInt8(ascii: "$"))
        i += 1
        continue
      }
      append(reference, &result)
      i = end
    }
  }

  /// Parses `$name` or `${name}` at `start`, returning where it ends. Names
  /// are runs of ASCII letters, digits and underscores, so `$1a` refers to a
  /// group named `1a`.
  private static func parseReference(_ template: [UInt8], at start: Int) -> (Reference, Int)? {
    var i = start + 1
    guard i < template.count else { return nil }
    let brace = template[i] == UInt8(ascii: "{")
    if brace {
      i += 1
    }
    let nameStart = i
    while i < template.count, isNameByte(template[i]) {
      i += 1
    }
    guard i > nameStart else { return nil }
    let name = String(decoding: template[nameStart..<i], as: UTF8.self)
    if brace {
      guard i < template.count, template[i] == UInt8(ascii: "}") else { return nil }
      i += 1
    }
    if let number = UInt32(name) {
      return (.number(Int(number)), i)
    }
    return (.name(name), i)
  }

  private static func isNameByte(_ byte: UInt8) -> Bool {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "a")...UInt8(ascii: "z"),
         UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "_"):
      true
    default:
      false
    }
  }
}
