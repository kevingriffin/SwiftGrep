import GrepRegex

/// Per-file results.
struct FileResult {
  var matchedLines = 0
  var matches = 0
  var hadMatch: Bool { matchedLines > 0 }
}

/// Emulates where ripgrep stops when it finds binary data.
///
/// ripgrep reads files through a 64 KiB line buffer and checks each newly
/// read chunk for NUL bytes. When one is found, that whole chunk is discarded:
/// only complete lines from earlier chunks are searched. Reproducing the chunk
/// boundaries keeps results identical for binary files.
enum BinaryDetection {
  static let bufferCapacity = 64 * 1024

  /// The number of leading bytes that ripgrep would search before noticing
  /// the NUL byte at `nulOffset`. Always 0 or just past a line terminator.
  static func searchableLength(_ data: Span<UInt8>, nulOffset: Int) -> Int {
    var capacity = bufferCapacity
    var consumed = 0  // start of unsearched data (lines before it were searched)
    var filled = 0    // end of data read so far
    while true {
      var free = capacity - (filled - consumed)
      if free <= 0 {
        capacity *= 2
        free = capacity - (filled - consumed)
      }
      let newFilled = min(filled + free, data.count)
      if nulOffset < newFilled { return consumed }
      filled = newFilled
      if filled == data.count { return data.count }
      if let lastNewline = data.lastIndex(of: 10, in: consumed..<filled) {
        consumed = lastNewline + 1
      }
    }
  }
}

/// Searches one file's contents and formats the output.
///
/// Holds only per-file position state; the file's bytes are passed to each
/// call as a `Span`, so they can never outlive the worker's reusable buffer.
struct FileSearch: ~Copyable {
  let settings: OutputSettings
  let path: [UInt8]

  private var printedUpTo = 0
  private var afterRemaining = 0
  private var printedAnything = false
  private var lineNumberPosition = 0
  private var lineNumber = 1
  private var matchRanges: [Range<Int>] = []
  private(set) var result = FileResult()

  init(settings: OutputSettings, path: [UInt8]) {
    self.settings = settings
    self.path = path
  }

  private enum Flow { case proceed, stop }

  /// Runs the search. `explicit` files (named on the command line) get
  /// ripgrep's "convert" binary handling rather than being skipped.
  mutating func run(_ data: Span<UInt8>, explicit: Bool, matcher: inout LineMatcher, out: inout OutputBuffer) {
    // ripgrep decodes files after dropping a UTF-8 byte order mark, so
    // offsets and columns count from the byte after it.
    if settings.stripByteOrderMark, data.count >= 3, data[0] == 0xEF, data[1] == 0xBB, data[2] == 0xBF {
      search(data.extracting(3...), explicit: explicit, matcher: &matcher, out: &out)
    } else {
      search(data, explicit: explicit, matcher: &matcher, out: &out)
    }
  }

  private mutating func search(_ data: Span<UInt8>, explicit: Bool, matcher: inout LineMatcher, out: inout OutputBuffer) {
    let n = data.count
    guard n > 0 else {
      finish(out: &out, binaryOffset: nil, binaryQuit: false)
      return
    }
    var limit = n
    var binaryOffset: Int? = nil
    var convert = false
    if settings.binary != .text, let nul = data.firstIndex(of: 0, in: 0..<n) {
      binaryOffset = nul
      limit = BinaryDetection.searchableLength(data, nulOffset: nul)
      convert = explicit || settings.binary == .search
      guard convert || limit > 0 else { return } // a binary file is skipped silently
    }
    searchLines(data, upTo: limit, matcher: &matcher, out: &out)
    if binaryOffset != nil && !convert && settings.mode != .lines && settings.mode != .onlyMatching {
      // Like ripgrep, summaries (-c, -l, ...) never report a binary file
      // that was skipped, even if it matched before the binary data.
      result = FileResult()
      return
    }
    if convert, binaryOffset != nil, limit < n, !result.hadMatch || settings.mode == .count {
      // After binary data is detected ripgrep only checks whether there is
      // another match, without printing it.
      let restEnd = data[n - 1] == 10 ? n - 1 : n
      if limit <= restEnd, matcher.nextMatchingLine(in: data, from: limit, end: restEnd) != nil {
        result.matchedLines += 1
        result.matches += 1
      }
    }
    finish(out: &out, binaryOffset: binaryOffset, binaryQuit: binaryOffset != nil && !convert)
  }

  private mutating func searchLines(_ data: Span<UInt8>, upTo limit: Int, matcher: inout LineMatcher, out: inout OutputBuffer) {
    guard limit > 0 else { return }
    // Lines end at a terminator or at `end`; a final terminator does not
    // start another (empty) line.
    let end = data[limit - 1] == 10 ? limit - 1 : limit
    var pos = 0
    if !settings.invert {
      while pos <= end, let line = matcher.nextMatchingLine(in: data, from: pos, end: end) {
        if select(line, data, matcher: &matcher, out: &out) == .stop { break }
        pos = line.upperBound + 1
      }
    } else {
      outer: while pos <= end {
        let next = matcher.nextMatchingLine(in: data, from: pos, end: end)
        var p = pos
        while next.map({ p < $0.lowerBound }) ?? (p <= end) {
          let lineEnd = data.firstIndex(of: 10, in: p..<end) ?? end
          if select(p..<lineEnd, data, matcher: &matcher, out: &out) == .stop { break outer }
          p = lineEnd + 1
        }
        guard let next else { break }
        pos = next.upperBound + 1
      }
    }
    if settings.hasContext && (settings.mode == .lines || settings.mode == .onlyMatching) {
      flushAfterContext(data, before: end + 1, end: end, matcher: &matcher, out: &out)
    }
  }

  /// Handles one selected line (a matching line, or a non-matching one with -v).
  private mutating func select(_ line: Range<Int>, _ data: Span<UInt8>, matcher: inout LineMatcher, out: inout OutputBuffer) -> Flow {
    switch settings.mode {
    case .quiet, .filesWithMatches, .filesWithoutMatch, .listFiles:
      result.matchedLines = 1
      return .stop
    case .count:
      result.matchedLines += 1
    case .countMatches:
      result.matchedLines += 1
      if settings.invert {
        result.matches += 1
      } else {
        var count = 0
        matcher.forEachMatch(in: data, lineStart: line.lowerBound, lineEnd: line.upperBound) { _ in count += 1 }
        result.matches += count
      }
    case .lines, .onlyMatching:
      result.matchedLines += 1
      printSelected(line, data, matcher: &matcher, out: &out)
    }
    if let max = settings.maxCount, result.matchedLines >= max { return .stop }
    return .proceed
  }

  // MARK: - Line output

  /// Line numbers are counted incrementally, since lines are visited in order.
  private mutating func lineNumber(at position: Int, _ data: Span<UInt8>) -> Int {
    if position > lineNumberPosition {
      lineNumber += data.count(of: 10, in: lineNumberPosition..<position)
      lineNumberPosition = position
    }
    return lineNumber
  }

  private mutating func flushAfterContext(_ data: Span<UInt8>, before limit: Int, end: Int, matcher: inout LineMatcher, out: inout OutputBuffer) {
    while afterRemaining > 0 && printedUpTo < limit && printedUpTo <= end {
      let lineEnd = data.firstIndex(of: 10, in: printedUpTo..<end) ?? end
      emitLine(printedUpTo..<lineEnd, data, selected: false, matcher: &matcher, out: &out)
      printedUpTo = lineEnd + 1
      afterRemaining -= 1
    }
  }

  private mutating func printSelected(_ line: Range<Int>, _ data: Span<UInt8>, matcher: inout LineMatcher, out: inout OutputBuffer) {
    if settings.hasContext {
      flushAfterContext(data, before: line.lowerBound, end: data.count, matcher: &matcher, out: &out)
      // Walk back over up to `before` lines that have not been printed yet.
      var start = line.lowerBound
      var count = 0
      while count < settings.before && start > printedUpTo {
        start = data.lastIndex(of: 10, in: printedUpTo..<(start - 1)).map { $0 + 1 } ?? printedUpTo
        count += 1
      }
      if printedAnything && start > printedUpTo, let separator = settings.contextSeparator {
        out.append(separator)
        out.append(10)
      }
      var p = start
      while p < line.lowerBound {
        let lineEnd = data.firstIndex(of: 10, in: p..<line.lowerBound) ?? line.lowerBound
        emitLine(p..<lineEnd, data, selected: false, matcher: &matcher, out: &out)
        p = lineEnd + 1
      }
    }
    emitLine(line, data, selected: true, matcher: &matcher, out: &out)
    printedUpTo = line.upperBound + 1
    afterRemaining = settings.after
  }

  private mutating func writeHeadingIfNeeded(out: inout OutputBuffer) {
    guard settings.heading, !printedAnything else { return }
    appendPath(out: &out)
    out.append(10)
  }

  private func appendPath(out: inout OutputBuffer) {
    if let color = settings.color {
      out.append(color.path)
      out.append(path)
      out.append(color.reset)
    } else {
      out.append(path)
    }
  }

  private mutating func appendPrefix(_ line: Range<Int>, _ data: Span<UInt8>, separator: UInt8, column: Int?, out: inout OutputBuffer) {
    if settings.withFilename && !settings.heading {
      appendPath(out: &out)
      out.append(settings.nullAfterPath ? 0 : separator)
    }
    if settings.lineNumbers {
      let number = lineNumber(at: line.lowerBound, data)
      if let color = settings.color {
        out.append(color.lineNumber)
        out.appendDecimal(number)
        out.append(color.reset)
      } else {
        out.appendDecimal(number)
      }
      out.append(separator)
    }
    if let column {
      if let color = settings.color {
        out.append(color.column)
        out.appendDecimal(column)
        out.append(color.reset)
      } else {
        out.appendDecimal(column)
      }
      out.append(separator)
    }
  }

  private mutating func findMatchRanges(_ line: Range<Int>, _ data: Span<UInt8>, matcher: inout LineMatcher) {
    var ranges = matchRanges
    matchRanges = []
    ranges.removeAll(keepingCapacity: true)
    matcher.forEachMatch(in: data, lineStart: line.lowerBound, lineEnd: line.upperBound) { ranges.append($0) }
    matchRanges = ranges
  }

  private mutating func emitLine(_ line: Range<Int>, _ data: Span<UInt8>, selected: Bool, matcher: inout LineMatcher, out: inout OutputBuffer) {
    writeHeadingIfNeeded(out: &out)
    printedAnything = true
    let separator = selected ? UInt8(ascii: ":") : UInt8(ascii: "-")
    let highlight = selected && !settings.invert
    if highlight && settings.needsSpans {
      findMatchRanges(line, data, matcher: &matcher)
    } else {
      matchRanges.removeAll(keepingCapacity: true)
    }

    if settings.mode == .onlyMatching && highlight {
      for match in matchRanges {
        let column = settings.column ? match.lowerBound - line.lowerBound + 1 : nil
        appendPrefix(line, data, separator: separator, column: column, out: &out)
        appendHighlighted(match, data, matches: [match], out: &out)
        out.append(10)
      }
      return
    }
    if settings.vimgrep && highlight {
      for match in matchRanges {
        appendPrefix(line, data, separator: separator, column: match.lowerBound - line.lowerBound + 1, out: &out)
        appendHighlighted(line, data, matches: matchRanges, out: &out)
        out.append(10)
      }
      return
    }
    let column = settings.column && selected ? (matchRanges.first.map { $0.lowerBound - line.lowerBound + 1 } ?? 1) : nil
    appendPrefix(line, data, separator: separator, column: column, out: &out)
    if highlight && settings.color != nil {
      appendHighlighted(line, data, matches: matchRanges, out: &out)
    } else {
      out.append(data.extracting(line))
    }
    out.append(10)
  }

  private func appendHighlighted(_ range: Range<Int>, _ data: Span<UInt8>, matches: [Range<Int>], out: inout OutputBuffer) {
    guard let color = settings.color else {
      out.append(data.extracting(range))
      return
    }
    var p = range.lowerBound
    for match in matches where match.lowerBound >= p && match.upperBound <= range.upperBound {
      out.append(data.extracting(p..<match.lowerBound))
      if !match.isEmpty {
        out.append(color.match)
        out.append(data.extracting(match))
        out.append(color.reset)
      }
      p = match.upperBound
    }
    out.append(data.extracting(p..<range.upperBound))
  }

  // MARK: - Per-file summary output

  private mutating func finish(out: inout OutputBuffer, binaryOffset: Int?, binaryQuit: Bool) {
    let terminator: UInt8 = settings.nullAfterPath ? 0 : 10
    switch settings.mode {
    case .count, .countMatches:
      let value = settings.mode == .count ? result.matchedLines : result.matches
      guard value > 0 || settings.includeZero else { return }
      if settings.withFilename {
        appendPath(out: &out)
        out.append(settings.nullAfterPath ? 0 : UInt8(ascii: ":"))
      }
      out.appendDecimal(value)
      out.append(10)
    case .filesWithMatches:
      guard result.hadMatch else { return }
      appendPath(out: &out)
      out.append(terminator)
    case .filesWithoutMatch:
      guard !result.hadMatch else { return }
      appendPath(out: &out)
      out.append(terminator)
    case .lines, .onlyMatching:
      guard let offset = binaryOffset, result.hadMatch else { return }
      if settings.withFilename {
        appendPath(out: &out)
        out.append(": ")
      }
      out.append(binaryQuit ? "WARNING: stopped searching binary file after match" : "binary file matches")
      out.append(" (found \"\\0\" byte around offset ")
      out.appendDecimal(offset)
      out.append(")\n")
    case .quiet, .listFiles:
      break
    }
  }
}
