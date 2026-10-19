import GrepRegex

/// ripgrep's standard printer (lines with their prefixes) and summary
/// printer (`-c`, `-l` and friends), byte for byte.
extension FileSearcher {
  // MARK: - Lines

  /// Prints a reported line. `ranges` holds its matches (or, for context
  /// lines, the matches to highlight under `-v`).
  mutating func printLine(_ data: Span<UInt8>, _ line: Range<Int>, _ kind: LineKind) {
    writeHeadingIfNeeded()
    // The line as ripgrep holds it: with its terminator, if it has one.
    let full = line.lowerBound..<(line.upperBound < file.limit ? line.upperBound + 1 : line.upperBound)
    var matches = ranges
    ranges = []
    defer { ranges = matches }
    if let replacement = settings.replacement, !matches.isEmpty || (kind != .match && settings.invert) {
      printReplaced(data, line, kind, replacement: replacement, matches: &matches)
      return
    }
    if matches.isEmpty {
      writePrelude(data, line, offset: line.lowerBound, column: nil, kind)
      writeLine(data, full, matches: matches, kind)
    } else if settings.onlyMatching {
      for match in matches {
        writePrelude(data, line, offset: match.lowerBound, column: match.lowerBound - line.lowerBound + 1, kind)
        writeColoredLine(data, match, matches: [match], kind)
      }
    } else if settings.vimgrep {
      for match in matches {
        writePrelude(data, line, offset: match.lowerBound, column: match.lowerBound - line.lowerBound + 1, kind)
        writeColoredLine(data, full, matches: [match], kind)
      }
    } else {
      writePrelude(data, line, offset: line.lowerBound, column: matches[0].lowerBound - line.lowerBound + 1, kind)
      writeColoredLine(data, full, matches: matches, kind)
    }
  }

  /// Prints a line with `--replace` applied: the replaced bytes take the
  /// place of the line, and the replacements those of the matches.
  private mutating func printReplaced(
    _ data: Span<UInt8>, _ line: Range<Int>, _ kind: LineKind, replacement: [UInt8], matches: inout [Range<Int>],
  ) {
    var replaced: [UInt8] = []
    var spans: [Range<Int>] = []
    var last = line.lowerBound
    let hay = data
    for match in matches {
      replaced.append(contentsOf: Array(copying: hay.extracting(last..<match.lowerBound)))
      let start = replaced.count
      interpolate(replacement, data, line: line, match, into: &replaced)
      spans.append(start..<replaced.count)
      last = match.upperBound
    }
    let end = contentEnd(data, line)
    if last < end {
      replaced.append(contentsOf: Array(copying: hay.extracting(last..<end)))
    }
    // The line's terminator (with `--crlf`, including its `\r`).
    if end < file.limit {
      replaced.append(contentsOf: Array(copying: hay.extracting(end..<min(line.upperBound + 1, file.limit))))
    }
    let original = matches
    let bytes = replaced.span
    if spans.isEmpty {
      writePrelude(data, line, offset: line.lowerBound, column: nil, kind)
      writeLine(bytes, 0..<bytes.count, matches: spans, kind, original: original.count)
    } else if settings.onlyMatching {
      for (i, span) in spans.enumerated() {
        writePrelude(data, line, offset: original[i].lowerBound, column: span.lowerBound + 1, kind)
        writeColoredLine(bytes, span, matches: [span], kind, original: 1)
      }
    } else if settings.vimgrep {
      for (i, span) in spans.enumerated() {
        writePrelude(data, line, offset: original[i].lowerBound, column: span.lowerBound + 1, kind)
        writeColoredLine(bytes, 0..<bytes.count, matches: [span], kind, original: original.count)
      }
    } else {
      writePrelude(data, line, offset: line.lowerBound, column: spans[0].lowerBound + 1, kind)
      writeColoredLine(bytes, 0..<bytes.count, matches: spans, kind, original: original.count)
    }
  }

  /// The heading (path line) before a file's first line, with `--heading`.
  mutating func writeHeadingIfNeeded() {
    guard out.count == file.outputStart, settings.heading, settings.withFilename else { return }
    let linked = openLink(line: nil, column: nil)
    appendColoredPath()
    closeLink(linked)
    if let terminator = settings.pathTerminator {
      out.append(terminator)
    } else {
      out.append(settings.lineTerminatorBytes)
    }
  }

  private enum PendingSeparator { case none, field, pathTerminator }

  /// Writes the path, line number, column and byte offset fields that are
  /// enabled, each followed by its separator.
  private mutating func writePrelude(
    _ data: Span<UInt8>, _ line: Range<Int>, offset: Int, column: Int?, _ kind: LineKind,
  ) {
    writePrelude(number: settings.lineNumbers ? lineNumber(at: line.lowerBound, data) : nil, offset: offset,
                 column: column, kind)
  }

  /// The prelude with the line number given (nil when line numbers are off).
  mutating func writePrelude(number lineNumber: Int?, offset: Int, column: Int?, _ kind: LineKind) {
    var pending = PendingSeparator.none
    var linked = false
    if settings.withFilename, settings.hyperlinks.isLineDependent || !settings.heading {
      linked = openLink(line: lineNumber, column: column)
    }
    if settings.withFilename && !settings.heading {
      appendColoredPath()
      pending = settings.pathTerminator != nil ? .pathTerminator : .field
    }
    if let lineNumber {
      writeSeparator(&pending, kind)
      appendNumber(lineNumber, color: settings.colors?.lineNumber)
      pending = .field
    }
    if settings.column, let column {
      writeSeparator(&pending, kind)
      appendNumber(column, color: settings.colors?.column)
      pending = .field
    }
    if settings.byteOffset {
      writeSeparator(&pending, kind)
      appendNumber(offset, color: settings.colors?.column)
      pending = .field
    }
    closeLink(linked)
    writeSeparator(&pending, kind)
  }

  private mutating func writeSeparator(_ pending: inout PendingSeparator, _ kind: LineKind) {
    switch pending {
    case .none: break
    case .field: out.append(kind == .match ? settings.fieldMatchSeparator : settings.fieldContextSeparator)
    case .pathTerminator: out.append(settings.pathTerminator ?? 0)
    }
    pending = .none
  }

  private mutating func appendNumber(_ value: Int, color: [UInt8]?) {
    if let color {
      appendEscape(color)
      out.appendDecimal(value)
      appendEscape(Palette.reset)
    } else {
      out.appendDecimal(value)
    }
  }

  /// Writes a line (`bytes` includes its terminator, if any) uncolored.
  mutating func writeLine(
    _ data: Span<UInt8>, _ bytes: Range<Int>, matches: [Range<Int>], _ kind: LineKind, original: Int? = nil,
  ) {
    let line = settings.trim ? trimmedPrefix(data, bytes) : bytes
    if exceedsMaxColumns(line.count) {
      var index = 0
      writeExceeded(data, line, matches: matches, kind, original: original ?? matches.count, index: &index)
    } else {
      out.append(data.extracting(line))
      if line.isEmpty || data[line.upperBound - 1] != settings.lineTerminator {
        out.append(settings.lineTerminatorBytes)
      }
    }
  }

  private mutating func writeColoredLine(
    _ data: Span<UInt8>, _ bytes: Range<Int>, matches: [Range<Int>], _ kind: LineKind, original: Int? = nil,
  ) {
    guard settings.colors?.matchIsColored == true else {
      writeLine(data, bytes, matches: matches, kind, original: original)
      return
    }
    let line = settings.trim ? trimmedPrefix(data, bytes) : bytes
    var index = 0
    if exceedsMaxColumns(bytes.count) {
      writeExceeded(data, line, matches: matches, kind, original: original ?? matches.count, index: &index)
    } else {
      writeColoredMatches(data, line, matches: matches, kind, index: &index)
      out.append(settings.lineTerminatorBytes)
    }
  }

  /// Writes the line's contents with its matches colored. As in ripgrep,
  /// adjacent matches share one colored run, and with a highlight style the
  /// rest of a matching line is drawn in it.
  /// `index` is the first match to consider; a match spanning lines (`-U`)
  /// continues on the next one.
  mutating func writeColoredMatches(
    _ data: Span<UInt8>, _ bytes: Range<Int>, matches: [Range<Int>], _ kind: LineKind, index: inout Int,
  ) {
    var line = trimmedTerminator(data, bytes)
    guard !matches.isEmpty else {
      out.append(data.extracting(line))
      return
    }
    let highlight = kind == .match ? settings.colors?.highlight : nil
    if let highlight {
      appendEscape(highlight)
    }
    var inMatch = false
    while !line.isEmpty {
      let match = matches[index]
      if match.upperBound <= line.lowerBound {
        if index + 1 < matches.count {
          index += 1
          continue
        }
        endColorMatch(&inMatch, highlight: highlight)
        out.append(data.extracting(line))
        break
      }
      if line.lowerBound < match.lowerBound {
        let upto = min(line.upperBound, match.lowerBound)
        endColorMatch(&inMatch, highlight: highlight)
        out.append(data.extracting(line.lowerBound..<upto))
        line = upto..<line.upperBound
      } else {
        let upto = min(line.upperBound, match.upperBound)
        if !inMatch, let colors = settings.colors {
          appendEscape(colors.match)
          inMatch = true
        }
        out.append(data.extracting(line.lowerBound..<upto))
        line = upto..<line.upperBound
      }
    }
    endColorMatch(&inMatch, highlight: highlight)
    if highlight != nil {
      appendEscape(Palette.reset)
    }
  }

  private mutating func endColorMatch(_ inMatch: inout Bool, highlight: [UInt8]?) {
    guard inMatch else { return }
    appendEscape(highlight ?? Palette.reset)
    inMatch = false
  }

  func exceedsMaxColumns(_ length: Int) -> Bool {
    settings.maxColumns.map { length > $0 } ?? false
  }

  /// A line longer than `--max-columns`: a placeholder, or with
  /// `--max-columns-preview` its first graphemes.
  mutating func writeExceeded(
    _ data: Span<UInt8>, _ line: Range<Int>, matches: [Range<Int>], _ kind: LineKind, original: Int, index: inout Int,
  ) {
    if settings.maxColumnsPreview {
      let end = Graphemes.end(of: data, line, count: settings.maxColumns ?? 0)
      let shown = line.lowerBound..<end
      writeColoredMatches(data, shown, matches: matches, kind, index: &index)
      if matches.isEmpty {
        out.append(" [... omitted end of long line]")
      } else {
        let remaining = matches.count { $0.lowerBound >= shown.upperBound && $0.lowerBound < line.upperBound }
        out.append(" [... ")
        out.appendDecimal(remaining)
        out.append(remaining == 1 ? " more match]" : " more matches]")
      }
    } else if original == 0 || settings.onlyMatching {
      out.append(kind == .match ? "[Omitted long matching line]" : "[Omitted long context line]")
    } else {
      out.append("[Omitted long line with ")
      out.appendDecimal(original)
      out.append(" matches]")
    }
    out.append(settings.lineTerminatorBytes)
  }

  /// `--trim`: drops leading ASCII whitespace that isn't the terminator.
  func trimmedPrefix(_ data: Span<UInt8>, _ bytes: Range<Int>) -> Range<Int> {
    var start = bytes.lowerBound
    while start < bytes.upperBound {
      let byte = data[start]
      let space = byte == 9 || byte == 10 || byte == 11 || byte == 12 || byte == 13 || byte == 32
      guard space, byte != settings.lineTerminator, !(settings.crlf && byte == 13) else { break }
      start += 1
    }
    return start..<bytes.upperBound
  }

  func trimmedTerminator(_ data: Span<UInt8>, _ bytes: Range<Int>) -> Range<Int> {
    guard !bytes.isEmpty, data[bytes.upperBound - 1] == settings.lineTerminator else { return bytes }
    var end = bytes.upperBound - 1
    if settings.crlf, end > bytes.lowerBound, data[end - 1] == 13 {
      end -= 1
    }
    return bytes.lowerBound..<end
  }

  // MARK: - Paths and hyperlinks

  /// Appends a color or hyperlink escape sequence. ripgrep writes these
  /// past its byte counter, so `--stats` doesn't count them as printed.
  mutating func appendEscape(_ bytes: [UInt8]) {
    out.append(bytes)
    file.escapeBytes += bytes.count
  }

  mutating func appendColoredPath() {
    if let colors = settings.colors {
      appendEscape(colors.path)
      out.append(file.path)
      appendEscape(Palette.reset)
    } else {
      out.append(file.path)
    }
  }

  /// Opens a hyperlink for the file if links are on and its path resolves.
  mutating func openLink(line: Int?, column: Int?) -> Bool {
    guard !settings.hyperlinks.isEmpty, settings.colors != nil else { return false }
    if !file.linkResolved {
      file.linkPath = HyperlinkFormat.encode(path: file.path)
      file.linkResolved = true
    }
    guard let path = file.linkPath else { return false }
    let start = out.count
    settings.hyperlinks.appendOpening(path: path, line: line, column: column, to: &out)
    file.escapeBytes += out.count - start
    return true
  }

  mutating func closeLink(_ opened: Bool) {
    if opened {
      appendEscape(HyperlinkFormat.closing)
    }
  }

  // MARK: - Per-file reports

  /// Finishes the file's output: the binary file notice, counts and paths.
  mutating func report(binaryOffset: Int?, quit: Bool) {
    file.searchedWithMatch = file.result.matchCount > 0
    switch settings.kind {
    case .standard:
      if let offset = binaryOffset, file.result.matchCount > 0 {
        if settings.withFilename {
          let linked = openLink(line: nil, column: nil)
          appendColoredPath()
          closeLink(linked)
          out.append(": ")
        }
        out.append(quit ? "WARNING: stopped searching binary file after match" : "binary file matches")
        out.append(" (found \"\\0\" byte around offset ")
        out.appendDecimal(offset)
        out.append(")\n")
      }
      file.result.bytesPrinted = out.count - file.outputStart - file.escapeBytes
    case .json:
      file.result.bytesPrinted = out.count - file.outputStart
      printJSONEnd(binaryOffset: binaryOffset)
    case .count, .countMatches, .pathWithMatch, .pathWithoutMatch, .quietWithMatch, .quietWithoutMatch:
      // Like ripgrep, summaries never report a binary file that was
      // skipped, even if it matched before the binary data.
      if binaryOffset != nil && quit {
        file.result.matchCount = 0
        return
      }
      let count = settings.kind == .count ? file.result.matchCount : file.result.matches
      switch settings.kind {
      case .count, .countMatches:
        guard count > 0 || settings.includeZero else { return }
        if settings.withFilename {
          let linked = openLink(line: nil, column: nil)
          appendColoredPath()
          closeLink(linked)
          out.append(settings.pathTerminator ?? UInt8(ascii: ":"))
        }
        out.appendDecimal(count)
        out.append(settings.lineTerminatorBytes)
      case .pathWithMatch, .pathWithoutMatch:
        guard (file.result.matchCount > 0) == (settings.kind == .pathWithMatch) else { return }
        let linked = openLink(line: nil, column: nil)
        appendColoredPath()
        closeLink(linked)
        if let terminator = settings.pathTerminator {
          out.append(terminator)
        } else {
          out.append(settings.lineTerminatorBytes)
        }
      default:
        break
      }
    }
  }
}

/// Grapheme cluster boundaries in bytes that may not be valid UTF-8, for
/// `--max-columns-preview`.
enum Graphemes {
  /// The end of the first `count` grapheme clusters of `data[range]`. Each
  /// invalid byte counts as one cluster.
  static func end(of data: Span<UInt8>, _ range: Range<Int>, count: Int) -> Int {
    var position = range.lowerBound
    var remaining = count
    while remaining > 0 && position < range.upperBound {
      // Take the run of valid UTF-8 starting here.
      var runEnd = position
      while runEnd < range.upperBound, let scalar = GrepRegex.UTF8Decoding.decodeScalar(data, at: runEnd, end: range.upperBound) {
        runEnd += scalar.length
      }
      if runEnd == position {
        position += 1
        remaining -= 1
        continue
      }
      let text = String(decoding: Array(copying: data.extracting(position..<runEnd)), as: UTF8.self)
      for character in text {
        guard remaining > 0 else { break }
        position += character.utf8.count
        remaining -= 1
      }
    }
    return position
  }
}
