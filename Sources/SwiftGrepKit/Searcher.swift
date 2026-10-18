import GrepRegex

/// What one file's search found. Also feeds `--stats`.
struct FileResult {
  /// Lines reported as matches. This decides whether the file matched, and
  /// is what `-c` prints.
  var matchCount = 0
  /// Individual matches, for `--count-matches` and `--stats`.
  var matches = 0
  var matchedLines = 0
  var bytesPrinted = 0
}

/// Totals over every file a worker searched, for `--stats`.
struct SearchTotals {
  /// Files that passed every filter, whether or not they could be read.
  var filesConsidered = 0
  var filesSearched = 0
  var filesMatched = 0
  var matches = 0
  var matchedLines = 0
  var bytesSearched = 0
  var bytesPrinted = 0
  var nanoseconds = 0
}

/// Where ripgrep's reads end. It reads files through a line buffer: the
/// first read takes at most 3 bytes (its byte order mark check, unless a
/// UTF-8 byte order mark was skipped), later ones fill the free space of a
/// 64 KiB buffer, which triples when one line doesn't fit. A fill ends at the
/// last line terminator read, or at the end of the file, and each is
/// searched before the next is read.
///
/// The boundaries are visible in a few places: binary data is noticed per
/// read, and the lines after the `-m` limit behave differently at the start
/// of a new fill. Reproducing them keeps results identical.
struct LineBufferModel {
  static let capacity = 64 * 1024

  private let terminator: UInt8
  private var capacity = Self.capacity
  /// Start of the unsearched data: the lines before it were searched.
  private(set) var consumed = 0
  private var filled = 0
  private var peek: Bool

  init(terminator: UInt8, peek: Bool) {
    self.terminator = terminator
    self.peek = peek
  }

  enum Fill {
    /// A buffer of lines to search ends here.
    case lines(end: Int)
    /// A read contained the NUL byte; the data before `consumed` was searched.
    case binary
    case end
  }

  /// Reads the next buffer of complete lines from `data`, noticing a NUL
  /// byte at `nulOffset`.
  mutating func fill(_ data: Span<UInt8>, nulOffset: Int = .max) -> Fill {
    var lastTerminator: Int? = nil
    while lastTerminator == nil {
      var free = capacity - (filled - consumed)
      if free <= 0 {
        capacity *= 3
        free = capacity - (filled - consumed)
      }
      let size = min(peek ? 3 : free, data.count - filled)
      peek = false
      guard size > 0 else {
        // The end of the file: a last line without a terminator.
        guard filled > consumed else { return .end }
        consumed = filled
        return .lines(end: filled)
      }
      if nulOffset < filled + size {
        return .binary
      }
      lastTerminator = data.lastIndex(of: terminator, in: filled..<(filled + size))
      filled += size
    }
    consumed = lastTerminator! + 1
    return .lines(end: consumed)
  }

  /// The number of leading bytes that ripgrep searches before noticing the
  /// NUL byte at `nulOffset`. Always 0 or just past a line terminator.
  static func searchableLength(_ data: Span<UInt8>, nulOffset: Int, terminator: UInt8 = 10, peek: Bool = true) -> Int {
    var model = LineBufferModel(terminator: terminator, peek: peek)
    while true {
      switch model.fill(data, nulOffset: nulOffset) {
      case .lines: continue
      case .binary: return model.consumed
      case .end: return data.count
      }
    }
  }

  /// The end of the fill that holds `position`.
  mutating func end(containing position: Int, _ data: Span<UInt8>) -> Int {
    while true {
      switch fill(data) {
      case let .lines(end) where end > position: return end
      case .lines: continue
      case .binary, .end: return data.count
      }
    }
  }
}

/// How a line was reported, which decides its separator and coloring.
enum LineKind {
  case match
  case before
  case after
  /// A line printed by `--passthru`.
  case other
}

/// Searches files and formats their output. Owned by one worker, which
/// reuses its buffers and matcher state for every file; the file's bytes are
/// passed to each call as a `Span`, so they can never outlive the worker's
/// read buffer.
///
/// The line loop follows ripgrep's searcher core, so context, `-m` and
/// `--passthru` interact exactly as they do there.
struct FileSearcher: ~Copyable {
  let shared: SearchRun
  let settings: OutputSettings
  var matcher: LineMatcher
  var out = OutputBuffer()
  var totals = SearchTotals()
  var file = FileState()
  /// Matches in the line being printed (absolute positions).
  var ranges: [Range<Int>] = []
  /// A binary file's contents with NUL bytes turned into line terminators.
  private var converted = UniqueArray<UInt8>()

  static let flushThreshold = 64 * 1024

  init(shared: SearchRun) {
    self.shared = shared
    settings = shared.settings
    matcher = shared.matcher.makeLineMatcher()
  }

  /// State for the file being searched.
  struct FileState {
    var path: [UInt8] = []
    /// The percent-encoded absolute path for hyperlinks, once resolved.
    var linkPath: [UInt8]?
    var linkResolved = false
    var outputStart = 0
    /// End of the searched data, so a line ending there has no terminator.
    var limit = 0
    /// Start of the line after the last one reported.
    var lastLineVisited = 0
    var afterContextLeft = 0
    var hasSunk = false
    var hasMatched = false
    /// Matching lines so far, for `-m`.
    var count = 0
    var lineNumberPosition = 0
    var lineNumber = 1
    /// After binary data is detected (converting it), ripgrep's line printer
    /// stops at the first line it would print from here on.
    var binaryStart = Int.max
    var result = FileResult()
    /// Whether the file had a match, even if a skipped binary file's
    /// summary then reports none (ripgrep's statistics still count it).
    var searchedWithMatch = false
    var bytesSearched = 0
    /// ripgrep's search position, which ends the bytes searched when the
    /// search stops early (`-m`).
    var position = 0
    var stopped = false
    /// A UTF-8 byte order mark was skipped (so ripgrep's first read was a
    /// full one).
    var skippedByteOrderMark = false
    /// When the search started (only timed for `--stats` and `--json`).
    var start: ContinuousClock.Instant?
    var jsonBegun = false
    /// Escape sequences written for colors and hyperlinks.
    var escapeBytes = 0
  }

  // MARK: - Files

  /// Searches one file's contents. `path` is the path as displayed;
  /// `explicit` files (named on the command line) get ripgrep's "convert"
  /// binary handling rather than being skipped.
  mutating func search(_ data: Span<UInt8>, path: [UInt8], explicit: Bool) {
    begin(path: path)
    if settings.stats {
      file.start = ContinuousClock.now
    }
    // ripgrep decodes files after dropping a UTF-8 byte order mark, so
    // offsets and columns count from the byte after it.
    if settings.stripByteOrderMark, data.count >= 3, data[0] == 0xEF, data[1] == 0xBB, data[2] == 0xBF {
      file.skippedByteOrderMark = true
      run(data.extracting(3...), explicit: explicit)
    } else {
      run(data, explicit: explicit)
    }
    finishFile()
  }

  /// Searches the data and reports the file.
  private mutating func run(_ data: Span<UInt8>, explicit: Bool) {
    let n = data.count
    var limit = n
    var binaryOffset: Int? = nil
    var convert = false
    if settings.binary != .text, n > 0, let nul = data.firstIndex(of: 0, in: 0..<n) {
      binaryOffset = nul
      limit = LineBufferModel.searchableLength(data, nulOffset: nul, terminator: settings.lineTerminator,
                                               peek: !file.skippedByteOrderMark)
      convert = explicit || settings.binary == .search
    }
    if convert {
      // ripgrep keeps searching, with every NUL turned into a line
      // terminator. The bytes before `limit` hold no NUL, so converting the
      // whole file changes nothing that was searched before the detection.
      var copy = UniqueArray<UInt8>()
      swap(&copy, &converted)
      copy.removeLast(copy.count)
      if copy.capacity < n {
        copy.setCapacity(n)
      }
      copy.append(copying: data)
      copy.replaceAll(0, with: settings.lineTerminator)
      file.binaryStart = limit
      searchLines(copy.span, upTo: n)
      file.bytesSearched = file.stopped ? file.position : n
      swap(&copy, &converted)
      if converted.capacity > 1 << 20 {
        converted = UniqueArray()
      }
    } else {
      searchLines(data, upTo: limit)
      file.bytesSearched = file.stopped ? file.position : limit
    }
    report(binaryOffset: binaryOffset, quit: binaryOffset != nil && !convert)
  }

  private mutating func begin(path: [UInt8]) {
    file = FileState()
    // JSON paths are printed as they are.
    if let separator = settings.pathSeparator, settings.kind != .json {
      file.path = path.map { $0 == UInt8(ascii: "/") ? separator : $0 }
    } else {
      file.path = path
    }
    file.outputStart = out.count
  }

  /// Updates the totals and hands the file's output to the sink.
  private mutating func finishFile() {
    let result = file.result
    totals.filesSearched += 1
    totals.bytesSearched += file.bytesSearched
    if settings.stats {
      totals.nanoseconds += file.elapsedNanoseconds()
      totals.matches += result.matches
      totals.matchedLines += result.matchedLines
      totals.bytesPrinted += result.bytesPrinted
    }
    if file.searchedWithMatch {
      totals.filesMatched += 1
    }
    let matched = settings.kind.matchesWithout ? result.matchCount == 0 : result.matchCount > 0
    if matched {
      shared.matched.store(true, ordering: .relaxed)
      if shared.quitAfterMatch {
        shared.stop()
      }
    }
    let start = file.outputStart
    guard out.count > start else { return }
    if shared.sortOutput {
      shared.sink.collect(path: file.path, data: out.copyBytes(from: start))
      out.truncate(to: start)
    } else if shared.separateFiles {
      shared.sink.writeFile(out.storage.span)
      out.removeAll()
      if shared.sink.isBroken {
        shared.stop()
      }
    } else if shared.flushEachFile || out.count >= Self.flushThreshold {
      flush()
    }
  }

  /// Prints a path for `--files`.
  mutating func list(_ path: [UInt8]) {
    shared.matched.store(true, ordering: .relaxed)
    if shared.quitAfterMatch {
      shared.stop()
      return
    }
    let start = out.count
    file.path = settings.pathSeparator.map { separator in path.map { $0 == UInt8(ascii: "/") ? separator : $0 } } ?? path
    file.linkResolved = false
    let linked = openLink(line: nil, column: nil)
    appendColoredPath()
    closeLink(linked)
    out.append(settings.pathTerminator ?? 10)
    if shared.sortOutput {
      shared.sink.collect(path: path, data: out.copyBytes(from: start))
      out.truncate(to: start)
    } else if shared.flushEachFile || out.count >= Self.flushThreshold {
      flush()
    }
  }

  mutating func flush() {
    guard !out.isEmpty else { return }
    shared.sink.write(out.storage.span)
    out.removeAll()
    if shared.sink.isBroken {
      shared.stop()
    }
  }

  // MARK: - The line loop

  private var exceededLimit: Bool {
    settings.maxCount.map { file.count >= $0 } ?? false
  }

  /// Searches the lines in `data[0..<limit]`.
  private mutating func searchLines(_ data: Span<UInt8>, upTo limit: Int) {
    guard limit > 0 else { return }
    file.limit = limit
    // Lines end at a terminator or at `end`; a final terminator does not
    // start another (empty) line.
    let end = data[limit - 1] == settings.lineTerminator ? limit - 1 : limit
    var pos = 0
    if !settings.passthru {
      switch searchFast(data, from: &pos, end: end) {
      case .stop: file.stopped = true
      case .finished: break
      case .switchToSlow: file.stopped = searchSlow(data, from: pos, end: end)
      }
    } else {
      file.stopped = searchSlow(data, from: pos, end: end)
    }
    file.position = min(file.position, limit)
  }

  private enum FastResult { case finished, stop, switchToSlow }

  /// Skips from match to match with the prefilter and DFA.
  private mutating func searchFast(_ data: Span<UInt8>, from pos: inout Int, end: Int) -> FastResult {
    while pos <= end {
      if settings.stopOnNonmatch && file.hasMatched {
        return .switchToSlow
      }
      if settings.invert {
        let next = exceededLimit ? nil : matcher.nextMatchingLine(in: data, from: pos, end: end)
        // The lines before the next match are the (inverted) matches.
        let region = pos..<(next?.lowerBound ?? end + 1)
        pos = next.map { $0.upperBound + 1 } ?? end + 1
        file.position = pos
        guard !region.isEmpty else { continue }
        file.hasMatched = true
        guard afterContext(data, upTo: region.lowerBound, end: end),
              beforeContext(data, upTo: region.lowerBound)
        else { return .stop }
        var p = region.lowerBound
        while p < region.upperBound {
          let lineEnd = data.firstIndex(of: settings.lineTerminator, in: p..<end) ?? end
          file.count += 1
          guard sinkMatched(data, p..<lineEnd) else { return .stop }
          if exceededLimit {
            return afterLimit(data, line: p, end: end)
          }
          p = lineEnd + 1
        }
      } else {
        guard !exceededLimit, let line = matcher.nextMatchingLine(in: data, from: pos, end: end) else { break }
        file.hasMatched = true
        file.count += 1
        if settings.hasContext {
          guard afterContext(data, upTo: line.lowerBound, end: end),
                beforeContext(data, upTo: line.lowerBound)
          else { return .stop }
        }
        pos = line.upperBound + 1
        file.position = pos
        guard sinkMatched(data, line) else { return .stop }
      }
    }
    guard afterContext(data, upTo: end + 1, end: end) else { return .stop }
    return exceededLimit && file.afterContextLeft == 0 ? .stop : .finished
  }

  /// The rest of an inverted search once `-m` is reached at `line`.
  /// ripgrep finishes the current fill (see `LineBufferModel`) with after
  /// context. In each later fill its search starts out past the limit, which
  /// in the fast path makes the fill's first line a match, and with
  /// `--stop-on-nonmatch` switches to the slow path.
  private mutating func afterLimit(_ data: Span<UInt8>, line: Int, end: Int) -> FastResult {
    var model = LineBufferModel(terminator: settings.lineTerminator, peek: !file.skippedByteOrderMark)
    let searched = data.extracting(..<file.limit)
    var fillEnd = model.end(containing: line, searched)
    while true {
      guard afterContext(data, upTo: fillEnd, end: end), file.afterContextLeft > 0 else { return .stop }
      guard fillEnd < file.limit else { return .finished }
      if settings.stopOnNonmatch {
        return searchSlow(data, from: fillEnd, end: end) ? .stop : .finished
      }
      let lineEnd = data.firstIndex(of: settings.lineTerminator, in: fillEnd..<end) ?? end
      file.count += 1
      guard sinkMatched(data, fillEnd..<lineEnd) else { return .stop }
      fillEnd = model.end(containing: fillEnd, searched)
    }
  }

  /// Visits every line in turn, for `--passthru` and `--stop-on-nonmatch`.
  /// Once `-m` is reached, lines no longer match here (unlike in after
  /// context of the fast path), as in ripgrep.
  /// Returns whether the search stopped before the end.
  private mutating func searchSlow(_ data: Span<UInt8>, from start: Int, end: Int) -> Bool {
    var pos = start
    while pos <= end {
      if exceededLimit && !settings.passthru && file.afterContextLeft == 0 {
        return true
      }
      let lineEnd = data.firstIndex(of: settings.lineTerminator, in: pos..<end) ?? end
      let line = pos..<lineEnd
      let matched = !exceededLimit && isMatch(data, line)
      pos = lineEnd + 1
      file.position = pos
      let success = matched != settings.invert
      if success {
        file.hasMatched = true
        file.count += 1
        guard beforeContext(data, upTo: line.lowerBound), sinkMatched(data, line) else { return true }
      } else if file.afterContextLeft >= 1 {
        guard sinkContext(data, line, .after) else { return true }
      } else if settings.passthru {
        guard sinkContext(data, line, .other) else { return true }
      }
      if settings.stopOnNonmatch && !success && file.hasMatched {
        return true
      }
    }
    return false
  }

  /// Whether the line (without its terminator) contains a match.
  mutating func isMatch(_ data: Span<UInt8>, _ line: Range<Int>) -> Bool {
    matcher.isMatch(data, lineStart: line.lowerBound, lineEnd: contentEnd(data, line))
  }

  /// The end of the line's contents: with `--crlf`, a `\r` before the
  /// terminator belongs to the terminator.
  func contentEnd(_ data: Span<UInt8>, _ line: Range<Int>) -> Int {
    if settings.crlf, line.upperBound > line.lowerBound, data[line.upperBound - 1] == 13 {
      return line.upperBound - 1
    }
    return line.upperBound
  }

  /// Reports pending after-context lines before `upto` (a line start).
  /// Past the `-m` limit, lines that match are reported as matches without
  /// counting toward it.
  private mutating func afterContext(_ data: Span<UInt8>, upTo upto: Int, end: Int) -> Bool {
    guard file.afterContextLeft > 0 else { return true }
    let exceeded = exceededLimit
    var p = file.lastLineVisited
    while p < upto && p <= end {
      let lineEnd = data.firstIndex(of: settings.lineTerminator, in: p..<end) ?? end
      let line = p..<lineEnd
      if exceeded && isMatch(data, line) != settings.invert {
        let left = file.afterContextLeft
        file.position = lineEnd + 1
        guard sinkMatched(data, line) else { return false }
        file.afterContextLeft = left - 1
      } else {
        guard sinkContext(data, line, .after) else { return false }
      }
      if file.afterContextLeft == 0 {
        break
      }
      p = lineEnd + 1
    }
    return true
  }

  /// Reports up to `-B` lines before `upto` that weren't reported yet.
  private mutating func beforeContext(_ data: Span<UInt8>, upTo upto: Int) -> Bool {
    guard settings.before > 0, file.lastLineVisited < upto else { return true }
    var start = upto
    var lines = 0
    while lines < settings.before && start > file.lastLineVisited {
      start = data.lastIndex(of: settings.lineTerminator, in: file.lastLineVisited..<(start - 1)).map { $0 + 1 }
        ?? file.lastLineVisited
      lines += 1
    }
    var p = start
    while p < upto {
      let lineEnd = data.firstIndex(of: settings.lineTerminator, in: p..<(upto - 1)) ?? (upto - 1)
      guard breakContext(at: p), sinkContext(data, p..<lineEnd, .before) else { return false }
      p = lineEnd + 1
    }
    return true
  }

  /// Prints the context separator if lines were skipped since the last
  /// reported line.
  private mutating func breakContext(at lineStart: Int) -> Bool {
    guard settings.hasContext, file.hasSunk, file.lastLineVisited < lineStart else { return true }
    if settings.kind == .standard, let separator = settings.contextSeparator {
      out.append(separator)
      out.append(settings.lineTerminatorBytes)
    }
    return true
  }

  private mutating func sinkMatched(_ data: Span<UInt8>, _ line: Range<Int>) -> Bool {
    guard breakContext(at: line.lowerBound) else { return false }
    guard reportMatch(data, line) else { return false }
    file.lastLineVisited = line.upperBound + 1
    file.afterContextLeft = settings.after
    file.hasSunk = true
    return true
  }

  private mutating func sinkContext(_ data: Span<UInt8>, _ line: Range<Int>, _ kind: LineKind) -> Bool {
    guard reportContext(data, line, kind) else { return false }
    file.lastLineVisited = line.upperBound + 1
    if kind == .after {
      file.afterContextLeft -= 1
    }
    file.hasSunk = true
    return true
  }

  // MARK: - Reporting

  /// Reports a matching line. Returns false to stop searching the file.
  private mutating func reportMatch(_ data: Span<UInt8>, _ line: Range<Int>) -> Bool {
    file.result.matchCount += 1
    switch settings.kind {
    case .standard:
      if settings.needsSpans {
        findMatches(data, line)
      } else {
        ranges.removeAll(keepingCapacity: true)
      }
      if settings.stats {
        file.result.matches += ranges.count
        file.result.matchedLines += 1
      }
      if line.lowerBound >= file.binaryStart {
        return false
      }
      printLine(data, line, .match)
    case .json:
      findMatches(data, line)
      file.result.matches += ranges.count
      file.result.matchedLines += 1
      printJSON(data, line, .match)
    case .count, .countMatches, .pathWithMatch, .pathWithoutMatch, .quietWithMatch, .quietWithoutMatch:
      if settings.stats || settings.kind == .countMatches {
        var count = 0
        matcher.forEachMatch(in: data, lineStart: line.lowerBound, lineEnd: contentEnd(data, line)) { _ in count += 1 }
        file.result.matches += max(count, 1)
        file.result.matchedLines += 1
      } else if settings.kind.quitsEarly {
        return false
      }
    }
    return true
  }

  /// Reports a context line. Returns false to stop searching the file.
  private mutating func reportContext(_ data: Span<UInt8>, _ line: Range<Int>, _ kind: LineKind) -> Bool {
    switch settings.kind {
    case .standard:
      // Under -v the context lines are the ones that match, so their
      // matches are highlighted.
      if settings.invert && settings.needsSpans {
        findMatches(data, line)
      } else {
        ranges.removeAll(keepingCapacity: true)
      }
      if line.lowerBound >= file.binaryStart {
        return false
      }
      printLine(data, line, kind)
    case .json:
      if settings.invert {
        findMatches(data, line)
      } else {
        ranges.removeAll(keepingCapacity: true)
      }
      printJSON(data, line, kind)
    default:
      break
    }
    return true
  }

  /// Collects the matches in the line into `ranges`, dropping an empty
  /// match at its very end as ripgrep does.
  mutating func findMatches(_ data: Span<UInt8>, _ line: Range<Int>) {
    var found = ranges
    ranges = []
    found.removeAll(keepingCapacity: true)
    let end = contentEnd(data, line)
    matcher.forEachMatch(in: data, lineStart: line.lowerBound, lineEnd: end) { found.append($0) }
    if let last = found.last, last.isEmpty, last.lowerBound >= end {
      found.removeLast()
    }
    ranges = found
  }

  /// Line numbers are counted incrementally, since lines are visited in order.
  mutating func lineNumber(at position: Int, _ data: Span<UInt8>) -> Int {
    if position > file.lineNumberPosition {
      file.lineNumber += data.count(of: settings.lineTerminator, in: file.lineNumberPosition..<position)
      file.lineNumberPosition = position
    }
    return file.lineNumber
  }
}

extension UniqueArray where Element == UInt8 {
  /// Replaces every `byte` with `replacement`.
  mutating func replaceAll(_ byte: UInt8, with replacement: UInt8) {
    var span = mutableSpan
    var i = 0
    while i < span.count {
      if span[i] == byte {
        span[i] = replacement
      }
      i += 1
    }
  }
}
