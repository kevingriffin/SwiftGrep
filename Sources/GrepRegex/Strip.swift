/// ripgrep's restrictions on patterns: a line-oriented search can't match a
/// line terminator, and with binary detection it can't match a NUL byte.
enum PatternRestrictions {
  /// Removes `byte` from every class, as ripgrep's `strip_from_match` does.
  /// A literal containing it, or a class that would become empty, is an error.
  /// Nesting is bounded by the parser.
  static func strip(_ node: RegexNode, _ byte: UInt8) throws(RegexError) -> RegexNode {
    let value = UInt32(byte)
    switch node {
    case .empty, .look:
      return node
    case let .char(c):
      guard c != value else { throw notAllowed(byte) }
      return node
    case let .byte(b):
      guard b != byte else { throw notAllowed(byte) }
      return node
    case let .set(set):
      guard !set.isEmpty else { return node }
      let stripped = set.removing(value)
      guard !stripped.isEmpty else { throw notAllowed(byte) }
      return .set(stripped)
    case let .byteSet(set):
      guard !set.isEmpty else { return node }
      let stripped = set.removing(value)
      guard !stripped.isEmpty else { throw notAllowed(byte) }
      return .byteSet(stripped)
    case let .concat(nodes):
      var result: [RegexNode] = []
      for n in nodes {
        try result.append(strip(n, byte))
      }
      return .concat(result)
    case let .alternate(nodes):
      var result: [RegexNode] = []
      for n in nodes {
        try result.append(strip(n, byte))
      }
      return .alternate(result)
    case let .repeat(n, min, max, greedy):
      return try .repeat(strip(n, byte), min: min, max: max, greedy: greedy)
    case let .group(n):
      return try .group(strip(n, byte))
    case let .capture(index, n):
      return try .capture(index, strip(n, byte))
    }
  }

  private static func notAllowed(_ byte: UInt8) -> RegexError {
    let name = switch byte {
    case 10: "\\n"
    case 13: "\\r"
    case 0: "\\0"
    default: String(UnicodeScalar(byte))
    }
    return RegexError(message: "the literal \"\(name)\" is not allowed in a regex\n\n"
      + "Consider enabling multiline mode with the --multiline flag (or -U for short).\n"
      + "When multiline mode is enabled, new line characters can be matched.", pattern: "", span: nil, standalone: true)
  }

  /// ripgrep's ban on patterns that need a NUL byte, which binary detection
  /// makes impossible to match: a literal containing it, or a class of just
  /// NUL. An alternation of single characters counts as one class, as
  /// ripgrep's regex syntax turns it into one.
  static func checkNoNUL(_ node: RegexNode) throws(RegexError) {
    var pending = [node]
    while let next = pending.popLast() {
      switch next {
      case .char(0), .byte(0):
        throw banned
      case let .set(set) where set.singleScalar == 0:
        throw banned
      case let .byteSet(set) where set.singleScalar == 0:
        throw banned
      case let .alternate(nodes):
        if let union = singleCharacters(nodes) {
          if union.singleScalar == 0 {
            throw banned
          }
        } else {
          pending += nodes
        }
      case let .concat(nodes):
        pending += nodes
      case let .repeat(n, _, _, _), let .group(n), let .capture(_, n):
        pending.append(n)
      default:
        break
      }
    }
  }

  private static let banned = RegexError(
    message: "pattern contains \"\\0\" but it is impossible to match\n\nConsider enabling text mode with the --text flag "
      + "(or -a for short). Otherwise,\nbinary detection is enabled and matching a NUL byte is impossible.",
    pattern: "", span: nil, standalone: true,
  )

  /// The union of the alternatives if each is a single character or class
  /// (non-capturing groups don't count, as ripgrep's syntax drops them).
  private static func singleCharacters(_ nodes: [RegexNode]) -> ScalarSet? {
    var union = ScalarSet()
    for var node in nodes {
      while case let .group(inner) = node {
        node = inner
      }
      switch node {
      case let .char(c): union.insert(c...c)
      case let .set(set): union.formUnion(set)
      default: return nil
      }
    }
    return union
  }
}
