/// `--json`: ripgrep's JSON Lines messages (`begin`, `match`, `context`,
/// `end` and a final `summary`), byte for byte as serde_json writes them.
extension FileSearcher {
  mutating func printJSON(_ data: Span<UInt8>, _ line: Range<Int>, _ kind: LineKind) {
    if !file.jsonBegun {
      out.append("{\"type\":\"begin\",\"data\":{\"path\":")
      out.appendJSONData(file.path.span)
      out.append("}}\n")
      file.jsonBegun = true
    }
    let full = line.lowerBound..<(line.upperBound < file.limit ? line.upperBound + 1 : line.upperBound)
    out.append(kind == .match ? "{\"type\":\"match\",\"data\":{\"path\":" : "{\"type\":\"context\",\"data\":{\"path\":")
    out.appendJSONData(file.path.span)
    out.append(",\"lines\":")
    out.appendJSONData(data.extracting(full))
    out.append(",\"line_number\":")
    if settings.lineNumbers {
      out.appendDecimal(lineNumber(at: line.lowerBound, data))
    } else {
      out.append("null")
    }
    out.append(",\"absolute_offset\":")
    out.appendDecimal(line.lowerBound)
    out.append(",\"submatches\":[")
    var replaced: [UInt8] = []
    for (i, match) in ranges.enumerated() {
      if i > 0 {
        out.append(UInt8(ascii: ","))
      }
      out.append("{\"match\":")
      out.appendJSONData(data.extracting(match))
      if let replacement = settings.replacement {
        replaced.removeAll(keepingCapacity: true)
        interpolate(replacement, data, line: line, match, into: &replaced)
        out.append(",\"replacement\":")
        out.appendJSONData(replaced.span)
      }
      out.append(",\"start\":")
      out.appendDecimal(match.lowerBound - line.lowerBound)
      out.append(",\"end\":")
      out.appendDecimal(match.upperBound - line.lowerBound)
      out.append(UInt8(ascii: "}"))
    }
    out.append("]}}\n")
  }

  /// The `end` message, written only if the file printed a `begin`.
  mutating func printJSONEnd(binaryOffset: Int?) {
    guard file.jsonBegun else { return }
    out.append("{\"type\":\"end\",\"data\":{\"path\":")
    out.appendJSONData(file.path.span)
    out.append(",\"binary_offset\":")
    if let binaryOffset {
      out.appendDecimal(binaryOffset)
    } else {
      out.append("null")
    }
    out.append(",\"stats\":{\"elapsed\":")
    out.appendJSONDuration(nanoseconds: file.elapsedNanoseconds(), sortedKeys: false)
    out.append(",\"searches\":1,\"searches_with_match\":")
    out.appendDecimal(file.result.matchCount > 0 ? 1 : 0)
    out.append(",\"bytes_searched\":")
    out.appendDecimal(file.bytesSearched)
    out.append(",\"bytes_printed\":")
    out.appendDecimal(file.result.bytesPrinted)
    out.append(",\"matched_lines\":")
    out.appendDecimal(file.result.matchedLines)
    out.append(",\"matches\":")
    out.appendDecimal(file.result.matches)
    out.append("}}}\n")
  }
}

extension FileSearcher.FileState {
  func elapsedNanoseconds() -> Int {
    guard let start else { return 0 }
    return (ContinuousClock.now - start).nanoseconds
  }
}

extension Duration {
  var nanoseconds: Int {
    Int(components.seconds) * 1_000_000_000 + Int(components.attoseconds / 1_000_000_000)
  }
}

extension OutputBuffer {
  /// `{"text":"..."}` for valid UTF-8, otherwise `{"bytes":"<base64>"}`.
  mutating func appendJSONData(_ bytes: Span<UInt8>) {
    if (try? UTF8Span(validating: bytes)) != nil {
      append("{\"text\":")
      appendJSONString(bytes)
      append(UInt8(ascii: "}"))
    } else {
      append("{\"bytes\":\"")
      appendBase64(bytes)
      append("\"}")
    }
  }

  /// A JSON string of valid UTF-8, escaped as serde_json does.
  mutating func appendJSONString(_ bytes: Span<UInt8>) {
    let hex = Array("0123456789abcdef".utf8)
    append(UInt8(ascii: "\""))
    var i = 0
    while i < bytes.count {
      let byte = bytes[i]
      switch byte {
      case UInt8(ascii: "\""): append("\\\"")
      case UInt8(ascii: "\\"): append("\\\\")
      case 8: append("\\b")
      case 9: append("\\t")
      case 10: append("\\n")
      case 12: append("\\f")
      case 13: append("\\r")
      case 0..<0x20:
        append("\\u00")
        append(hex[Int(byte >> 4)])
        append(hex[Int(byte & 0xF)])
      default:
        append(byte)
      }
      i += 1
    }
    append(UInt8(ascii: "\""))
  }

  mutating func appendBase64(_ bytes: Span<UInt8>) {
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
    var i = 0
    while i + 3 <= bytes.count {
      let group = Int(bytes[i]) << 16 | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2])
      append(alphabet[group >> 18 & 63])
      append(alphabet[group >> 12 & 63])
      append(alphabet[group >> 6 & 63])
      append(alphabet[group & 63])
      i += 3
    }
    switch bytes.count - i {
    case 1:
      let group = Int(bytes[i])
      append(alphabet[group >> 2 & 63])
      append(alphabet[group << 4 & 63])
      append("==")
    case 2:
      let group = Int(bytes[i]) << 8 | Int(bytes[i + 1])
      append(alphabet[group >> 10 & 63])
      append(alphabet[group >> 4 & 63])
      append(alphabet[group << 2 & 63])
      append(UInt8(ascii: "="))
    default:
      break
    }
  }

  /// `{"secs":..,"nanos":..,"human":"0.000123s"}`. serde_json's `json!`
  /// maps (the final summary) sort their keys.
  mutating func appendJSONDuration(nanoseconds: Int, sortedKeys: Bool) {
    let seconds = nanoseconds / 1_000_000_000
    let nanos = nanoseconds % 1_000_000_000
    if sortedKeys {
      append("{\"human\":\"")
      append(SecondsFormat.sixDecimals(nanoseconds: nanoseconds))
      append("s\",\"nanos\":")
      appendDecimal(nanos)
      append(",\"secs\":")
      appendDecimal(seconds)
      append(UInt8(ascii: "}"))
    } else {
      append("{\"secs\":")
      appendDecimal(seconds)
      append(",\"nanos\":")
      appendDecimal(nanos)
      append(",\"human\":\"")
      append(SecondsFormat.sixDecimals(nanoseconds: nanoseconds))
      append("s\"}")
    }
  }
}

enum SecondsFormat {
  /// Seconds with six decimals, as Rust's `{:0.6}` prints them.
  static func sixDecimals(nanoseconds: Int) -> String {
    let micros = (nanoseconds + 500) / 1000
    let fraction = String(micros % 1_000_000)
    return "\(micros / 1_000_000)." + String(repeating: "0", count: 6 - fraction.count) + fraction
  }
}
