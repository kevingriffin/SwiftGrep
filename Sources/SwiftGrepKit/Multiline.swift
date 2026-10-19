import GrepRegex

/// `-U`: ripgrep's multi-line search. The whole file is one text; each match
/// is widened to whole lines, overlapping or adjacent blocks of lines are
/// merged, and each block is reported once.
extension FileSearcher {
  /// Searches `data` across lines and reports the file.
  mutating func runMultiline(_ data: Span<UInt8>, explicit: Bool) {
    let n = data.count
    file.limit = n
    file.multiline = true
    file.binaryQuit = !(explicit || settings.binary == .search)
    // ripgrep checks the first 64 KiB for binary data, and then each range
    // it reports.
    if settings.binary != .text, let nul = data.firstIndex(of: 0, in: 0..<min(n, LineBufferModel.capacity)) {
      file.binaryOffset = nul
      if file.binaryQuit {
        file.bytesSearched = 0
        report(binaryOffset: nul, quit: true)
        return
      }
      file.binaryStart = 0
    }
    let stopped = searchBlocks(data)
    let position = stopped ? file.position : n
    file.bytesSearched = file.binaryOffset.map { min($0, position) } ?? position
    report(binaryOffset: file.binaryOffset, quit: file.binaryQuit && file.binaryOffset != nil)
  }

  /// ripgrep's `MultiLine::run`. Returns whether it stopped early.
  private mutating func searchBlocks(_ data: Span<UInt8>) -> Bool {
    let n = data.count
    let end = n > 0 && data[n - 1] == settings.lineTerminator ? n - 1 : n
    var pos = 0
    var pending: Range<Int>?
    var keepGoing = true
    while pos < n && keepGoing {
      if settings.invert {
        // The lines between matches are the matches.
        var region = pos..<n
        if !exceededLimit, let found = matcher.findMultiline(in: data, from: pos, end: n) {
          file.count += 1
          let block = locate(data, found)
          region = pos..<block.lowerBound
          pos = block.upperBound + (block.isEmpty && block.upperBound < n ? 1 : 0)
        } else {
          pos = n
        }
        file.position = pos
        guard !region.isEmpty else { continue }
        keepGoing = blockContext(data, upTo: region.lowerBound, end: end) && sinkLines(data, region, end: end)
      } else {
        guard !exceededLimit, let found = matcher.findMultiline(in: data, from: pos, end: n) else {
          pos = n
          file.position = pos
          break
        }
        file.count += 1
        pos = found.upperBound + (found.isEmpty && found.upperBound < n ? 1 : 0)
        file.position = pos
        let block = locate(data, found)
        if let last = pending {
          if last.upperBound >= block.lowerBound {
            pending = last.lowerBound..<block.upperBound
            continue
          }
          pending = block
          keepGoing = blockContext(data, upTo: last.lowerBound, end: end) && sinkBlock(data, last)
        } else {
          pending = block
        }
      }
    }
    if keepGoing, let last = pending, blockContext(data, upTo: last.lowerBound, end: end) {
      _ = sinkBlock(data, last)
    }
    if keepGoing {
      _ = settings.passthru ? otherContext(data, upTo: n, end: end) : afterContext(data, upTo: end + 1, end: end)
    }
    return !keepGoing
  }

  /// The lines around `range` (from the start of its first line to the end
  /// of its last, including the terminator).
  private func locate(_ data: Span<UInt8>, _ range: Range<Int>) -> Range<Int> {
    let terminator = settings.lineTerminator
    let start = data.lastIndex(of: terminator, in: 0..<range.lowerBound).map { $0 + 1 } ?? 0
    if range.upperBound > start, data[range.upperBound - 1] == terminator {
      return start..<range.upperBound
    }
    let end = data.firstIndex(of: terminator, in: range.upperBound..<data.count).map { $0 + 1 } ?? data.count
    return start..<end
  }

  private mutating func blockContext(_ data: Span<UInt8>, upTo upto: Int, end: Int) -> Bool {
    if settings.passthru {
      return otherContext(data, upTo: upto, end: end)
    }
    return afterContext(data, upTo: upto, end: end) && beforeContext(data, upTo: upto)
  }

  /// `--passthru`: every line not reported yet, up to `upto`.
  private mutating func otherContext(_ data: Span<UInt8>, upTo upto: Int, end: Int) -> Bool {
    var p = file.lastLineVisited
    while p < upto && p <= end {
      let lineEnd = data.firstIndex(of: settings.lineTerminator, in: p..<end) ?? end
      guard sinkContext(data, p..<lineEnd, .other) else { return false }
      p = lineEnd + 1
    }
    return true
  }

  /// Reports each line of an inverted region as a match.
  private mutating func sinkLines(_ data: Span<UInt8>, _ region: Range<Int>, end: Int) -> Bool {
    var p = region.lowerBound
    while p < region.upperBound && p <= end {
      let lineEnd = data.firstIndex(of: settings.lineTerminator, in: p..<end) ?? end
      guard sinkMatched(data, p..<lineEnd) else { return false }
      p = lineEnd + 1
    }
    return true
  }

  /// Notices binary data in a range about to be reported. Returns true if
  /// the search stops (a file found while walking is skipped from here on).
  mutating func checkBinary(_ data: Span<UInt8>, _ range: Range<Int>) -> Bool {
    guard file.multiline, settings.binary != .text else { return false }
    if file.binaryOffset != nil {
      return file.binaryQuit
    }
    guard let nul = data.firstIndex(of: 0, in: range) else { return false }
    file.binaryOffset = nul
    if file.binaryQuit {
      return true
    }
    // Converted: the line printer reports the file as binary from here on.
    file.binaryStart = 0
    return false
  }

  /// Reports a block of lines holding one or more matches.
  private mutating func sinkBlock(_ data: Span<UInt8>, _ block: Range<Int>) -> Bool {
    guard !block.isEmpty, !checkBinary(data, block), breakContext(at: block.lowerBound) else { return false }
    guard reportBlock(data, block) else { return false }
    file.lastLineVisited = block.upperBound
    file.afterContextLeft = settings.after
    file.hasSunk = true
    return true
  }

  private mutating func reportBlock(_ data: Span<UInt8>, _ block: Range<Int>) -> Bool {
    let terminated = data[block.upperBound - 1] == settings.lineTerminator
    let lines = data.count(of: settings.lineTerminator, in: block) + (terminated ? 0 : 1)
    switch settings.kind {
    case .standard:
      file.result.matchCount += 1
      if settings.needsSpans {
        findBlockMatches(data, block)
      } else {
        ranges.removeAll(keepingCapacity: true)
      }
      if settings.stats {
        file.result.matches += ranges.count
        file.result.matchedLines += lines
      }
      if block.lowerBound >= file.binaryStart {
        return false
      }
      printBlock(data, block)
    case .json:
      file.result.matchCount += 1
      findBlockMatches(data, block)
      file.result.matches += ranges.count
      file.result.matchedLines += lines
      printJSONBlock(data, block)
    case .count, .countMatches, .pathWithMatch, .pathWithoutMatch, .quietWithMatch, .quietWithoutMatch:
      findBlockMatches(data, block)
      let count = max(ranges.count, 1)
      file.result.matchCount += count
      if settings.stats || settings.kind == .countMatches {
        file.result.matches += count
        file.result.matchedLines += lines
      } else if settings.kind.quitsEarly {
        return false
      }
    }
    return true
  }

  /// The matches in a block: searched from the start of the file, with a
  /// little look-ahead past the block, as ripgrep's printer does.
  private mutating func findBlockMatches(_ data: Span<UInt8>, _ block: Range<Int>) {
    var found = ranges
    ranges = []
    found.removeAll(keepingCapacity: true)
    let lookAhead = min(data.count, block.upperBound + 128)
    matcher.forEachMatch(in: data, lineStart: 0, lineEnd: lookAhead, from: block.lowerBound) { match in
      guard match.lowerBound < block.upperBound else { return false }
      found.append(match)
      return true
    }
    ranges = found
  }

  // MARK: - Printing blocks

  private mutating func printBlock(_ data: Span<UInt8>, _ block: Range<Int>) {
    writeHeadingIfNeeded()
    let firstLine = settings.lineNumbers ? lineNumber(at: block.lowerBound, data) : nil
    let matches = ranges
    ranges = []
    defer { ranges = matches }
    guard let replacement = settings.replacement, !matches.isEmpty else {
      printBlockLines(data, block, matches: matches, original: matches.count, offset: 0, firstLine: firstLine)
      return
    }
    // `--replace`: the block with its matches replaced takes its place.
    var replaced: [UInt8] = []
    var spans: [Range<Int>] = []
    var last = block.lowerBound
    for match in matches {
      replaced.append(contentsOf: Array(copying: data.extracting(last..<match.lowerBound)))
      let start = replaced.count
      Replacement.expand(replacement, into: &replaced) { reference, result in
        appendGroup(reference, data, block, match, into: &result)
      }
      spans.append(start..<replaced.count)
      last = match.upperBound
    }
    let lookAheadEnd = min(data.count, block.upperBound + 128)
    let tailEnd = last > block.upperBound ? lookAheadEnd : block.upperBound
    if last < tailEnd {
      replaced.append(contentsOf: Array(copying: data.extracting(last..<tailEnd)))
    }
    let count = matches.count
    printBlockLines(replaced.span, 0..<replaced.count, matches: spans, original: count, offset: block.lowerBound,
                    firstLine: firstLine)
  }

  private mutating func appendGroup(
    _ reference: Replacement.Reference, _ data: Span<UInt8>, _ block: Range<Int>, _ match: Range<Int>,
    into result: inout [UInt8],
  ) {
    let index: Int? = switch reference {
    case let .number(n): n
    case let .name(name): shared.matcher.captureIndex(named: name)
    }
    let lookAhead = min(data.count, block.upperBound + 128)
    let groups = matcher.captures(in: data, lineStart: 0, lineEnd: lookAhead, match: match)
    guard let index, index < groups.count, let group = groups[index] else { return }
    result.append(contentsOf: Array(copying: data.extracting(group)))
  }

  /// Prints the lines of `bytes[block]`; `offset` is added to positions in
  /// `bytes` for byte offsets (it is nonzero for replaced text).
  private mutating func printBlockLines(
    _ bytes: Span<UInt8>, _ block: Range<Int>, matches: [Range<Int>], original: Int, offset: Int, firstLine: Int?,
  ) {
    let base = offset == 0 ? 0 : offset - block.lowerBound
    var lines: [Range<Int>] = []
    var p = block.lowerBound
    while p < block.upperBound {
      let terminator = bytes.firstIndex(of: settings.lineTerminator, in: p..<block.upperBound)
      let next = terminator.map { $0 + 1 } ?? block.upperBound
      lines.append(p..<next)
      p = next
    }
    func number(_ i: Int) -> Int? {
      firstLine.map { $0 + i }
    }
    if matches.isEmpty {
      for (i, line) in lines.enumerated() {
        writePrelude(number: number(i), offset: base + line.lowerBound, column: nil, .match)
        writeLine(bytes, line, matches: [], .match, original: original)
      }
    } else if settings.onlyMatching {
      var index = 0
      for (i, whole) in lines.enumerated() {
        var line = trimmedTerminator(bytes, whole)
        if settings.trim {
          line = trimmedPrefix(bytes, line)
        }
        while !line.isEmpty {
          if matches[index].upperBound <= line.lowerBound {
            guard index + 1 < matches.count else { break }
            index += 1
            continue
          }
          let match = matches[index]
          if line.lowerBound < match.lowerBound {
            line = min(line.upperBound, match.lowerBound)..<line.upperBound
            continue
          }
          let upto = min(line.upperBound, match.upperBound)
          writePrelude(number: number(i), offset: base + match.lowerBound,
                       column: match.lowerBound - block.lowerBound + 1, .match)
          let part = line.lowerBound..<upto
          line = upto..<line.upperBound
          if exceedsMaxColumns(part.count) {
            writeExceeded(bytes, part, matches: matches, .match, original: original, index: &index)
          } else {
            appendMatchColored(bytes, part)
            out.append(settings.lineTerminatorBytes)
          }
        }
      }
    } else if settings.vimgrep {
      // One line per match: the first line it is on.
      for match in matches {
        for (i, whole) in lines.enumerated() {
          if whole.lowerBound >= match.upperBound {
            break
          }
          if whole.upperBound <= match.lowerBound {
            continue
          }
          writePrelude(number: number(i), offset: base + whole.lowerBound,
                       column: max(match.lowerBound - whole.lowerBound, 0) + 1, .match)
          var line = trimmedTerminator(bytes, whole)
          if settings.trim {
            line = trimmedPrefix(bytes, line)
          }
          if exceedsMaxColumns(line.count) {
            var index = 0
            writeExceeded(bytes, line, matches: [match], .match, original: original, index: &index)
            continue
          }
          while !line.isEmpty {
            if match.upperBound <= line.lowerBound {
              out.append(bytes.extracting(line))
              line = line.upperBound..<line.upperBound
            } else if line.lowerBound < match.lowerBound {
              let upto = min(line.upperBound, match.lowerBound)
              out.append(bytes.extracting(line.lowerBound..<upto))
              line = upto..<line.upperBound
            } else {
              let upto = min(line.upperBound, match.upperBound)
              appendMatchColored(bytes, line.lowerBound..<upto)
              line = upto..<line.upperBound
            }
          }
          out.append(settings.lineTerminatorBytes)
          break
        }
      }
    } else {
      var index = 0
      let column = matches[0].lowerBound - block.lowerBound + 1
      for (i, whole) in lines.enumerated() {
        writePrelude(number: number(i), offset: base + whole.lowerBound, column: column, .match)
        let line = settings.trim ? trimmedPrefix(bytes, whole) : whole
        if exceedsMaxColumns(line.count) {
          writeExceeded(bytes, line, matches: matches, .match, original: original, index: &index)
        } else {
          writeColoredMatches(bytes, line, matches: matches, .match, index: &index)
          out.append(settings.lineTerminatorBytes)
        }
      }
    }
  }

  /// A part of a match, in the match color (ripgrep writes these with the
  /// match style even when it is empty).
  private mutating func appendMatchColored(_ bytes: Span<UInt8>, _ range: Range<Int>) {
    if let colors = settings.colors {
      appendEscape(colors.match)
      out.append(bytes.extracting(range))
      appendEscape(Palette.reset)
    } else {
      out.append(bytes.extracting(range))
    }
  }

  private mutating func printJSONBlock(_ data: Span<UInt8>, _ block: Range<Int>) {
    let terminated = data[block.upperBound - 1] == settings.lineTerminator
    printJSON(data, block.lowerBound..<(block.upperBound - (terminated ? 1 : 0)), .match)
  }
}
