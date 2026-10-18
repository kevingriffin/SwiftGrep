/// Literal extraction: finds strings that every match must contain, so a fast
/// substring search can skip most of the haystack before the regex runs.
struct LiteralExtractor {
  /// What is known about the strings a sub-expression can match.
  struct Info {
    /// The complete (finite) set of strings the expression matches, if small.
    var exact: [[UInt8]]?
    /// Whether matching `exact` is equivalent to matching the expression.
    /// False when look-around or case folding make the set an over-approximation.
    var precise: Bool
    /// A set of strings of which every match contains at least one.
    var required: [[UInt8]]?

    static let unknown = Info(exact: nil, precise: false, required: nil)
    static let emptyString = Info(exact: [[]], precise: true, required: nil)
  }

  /// When true, literals are compared ASCII case-insensitively and stored lowercase.
  let foldASCII: Bool
  let maxStrings = 64
  let maxLength = 64

  func extract(_ node: RegexNode) -> Info {
    switch node {
    case .empty:
      return .emptyString
    case .look:
      return Info(exact: [[]], precise: false, required: nil)
    case let .char(c):
      var bytes = UTF8Encoding.encode(c)
      var precise = true
      if foldASCII, bytes.count == 1, isASCIILetter(bytes[0]) {
        bytes[0] |= 0x20
        precise = false // a case-sensitive letter, but searched case-insensitively
      }
      return Info(exact: [bytes], precise: precise, required: [bytes])
    case let .byte(b):
      return Info(exact: [[b]], precise: true, required: [[b]])
    case let .byteSet(set):
      guard set.count <= 16 else { return .unknown }
      let strings = set.ranges.flatMap { r in (r.lowerBound...r.upperBound).map { [UInt8($0)] } }
      return Info(exact: strings, precise: true, required: strings)
    case let .set(set):
      return extractSet(set.removing(10))
    case let .group(inner):
      return extract(inner)
    case let .concat(nodes):
      return extractConcat(nodes)
    case let .alternate(nodes):
      return extractAlternation(nodes)
    case let .repeat(inner, min, max, _):
      return extractRepeat(inner, min: min, max: max)
    }
  }

  private func isASCIILetter(_ b: UInt8) -> Bool {
    (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
  }

  private func extractSet(_ set: ScalarSet) -> Info {
    guard !set.isEmpty, set.count <= 32 else { return .unknown }
    var strings: [[UInt8]] = []
    var precise = true
    var seen = Set<[UInt8]>()
    for r in set.ranges {
      for c in r.lowerBound...r.upperBound {
        var bytes = UTF8Encoding.encode(c)
        if foldASCII, bytes.count == 1, isASCIILetter(bytes[0]) {
          // Folding is only exact if the other case is in the set too.
          if !set.contains(c ^ 0x20) {
            precise = false
          }
          bytes[0] |= 0x20
        }
        if seen.insert(bytes).inserted {
          strings.append(bytes)
        }
      }
    }
    return Info(exact: strings, precise: precise, required: strings)
  }

  private func cross(_ a: [[UInt8]], _ b: [[UInt8]]) -> [[UInt8]]? {
    guard a.count * b.count <= maxStrings else { return nil }
    var result: [[UInt8]] = []
    result.reserveCapacity(a.count * b.count)
    var seen = Set<[UInt8]>()
    for x in a {
      for y in b {
        let s = x + y
        if s.count > maxLength {
          return nil
        }
        if seen.insert(s).inserted {
          result.append(s)
        }
      }
    }
    return result
  }

  private func extractConcat(_ nodes: [RegexNode]) -> Info {
    var candidates: [[[UInt8]]] = []
    var run: [[UInt8]] = [[]]
    var runPrecise = true
    var allExact = true
    for node in nodes {
      let info = extract(node)
      if let exact = info.exact, let combined = cross(run, exact) {
        run = combined
        runPrecise = runPrecise && info.precise
        continue
      }
      // The run cannot be extended: keep it as a candidate and start over.
      allExact = false
      candidates.append(run)
      if let required = info.required {
        candidates.append(required)
      }
      if let exact = info.exact {
        run = exact
        runPrecise = info.precise
      } else {
        run = [[]]
        runPrecise = true
      }
    }
    candidates.append(run)
    let required = Self.best(of: candidates)
    if allExact {
      return Info(exact: run, precise: runPrecise, required: required)
    }
    return Info(exact: nil, precise: false, required: required)
  }

  private func extractAlternation(_ nodes: [RegexNode]) -> Info {
    let infos = nodes.map(extract)
    var exact: [[UInt8]]? = []
    var precise = true
    var seen = Set<[UInt8]>()
    for info in infos {
      guard let e = info.exact, var acc = exact else {
        exact = nil
        break
      }
      for s in e where seen.insert(s).inserted {
        acc.append(s)
      }
      precise = precise && info.precise
      exact = acc.count <= maxStrings ? acc : nil
    }
    var required: [[UInt8]]? = []
    var requiredSeen = Set<[UInt8]>()
    for info in infos {
      guard let best = Self.best(of: [info.exact, info.required].compactMap(\.self)), var acc = required else {
        required = nil
        break
      }
      for s in best where requiredSeen.insert(s).inserted {
        acc.append(s)
      }
      required = acc.count <= maxStrings ? acc : nil
    }
    return Info(exact: exact, precise: exact != nil && precise, required: required)
  }

  private func extractRepeat(_ inner: RegexNode, min: Int, max: Int?) -> Info {
    let info = extract(inner)
    if min == 0 {
      if max == 1, let e = info.exact, e.count < maxStrings {
        var strings = e
        if !strings.contains([]) {
          strings.append([])
        }
        return Info(exact: strings, precise: info.precise, required: nil)
      }
      return .unknown
    }
    let required = Self.best(of: [info.exact, info.required].compactMap(\.self))
    if let max, max == min, let e = info.exact {
      var result: [[UInt8]]? = [[]]
      for _ in 0..<min {
        guard let r = result else { break }
        result = cross(r, e)
      }
      if let result {
        return Info(exact: result, precise: info.precise, required: Self.best(of: [result, required].compactMap(\.self)))
      }
    }
    return Info(exact: nil, precise: false, required: required)
  }

  // MARK: - Scoring

  /// Estimated probability that a literal occurs at a given position.
  static func cost(of literal: [UInt8]) -> Float {
    guard !literal.isEmpty else { return .infinity }
    var probs = literal.map { ByteFrequencies.table[Int($0)] }
    probs.sort()
    var p = probs[0]
    if probs.count > 1 {
      p *= Swift.min(1, probs[1] * 8)
    }
    return p
  }

  /// Estimated candidate rate for a set: the sum of each literal's rate.
  static func cost(of set: [[UInt8]]) -> Float {
    guard !set.isEmpty else { return .infinity }
    var total: Float = 0
    for s in set {
      let c = cost(of: s)
      if c == .infinity {
        return .infinity
      }
      total += c
    }
    return total
  }

  static func best(of candidates: [[[UInt8]]]) -> [[UInt8]]? {
    var best: [[UInt8]]? = nil
    var bestCost = Float.infinity
    for c in candidates {
      let cost = cost(of: c)
      if cost < bestCost {
        best = c
        bestCost = cost
      }
    }
    return best
  }
}
