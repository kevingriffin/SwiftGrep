/// An encoding that ripgrep (encoding_rs) decodes to UTF-8 before searching.
public enum TextEncoding: Sendable, Hashable {
  case utf8, utf16LE, utf16BE
  /// x-user-defined: bytes 0x80 to 0xFF are U+F780 to U+F7FF.
  case userDefined
  /// A single-byte encoding, by its index in `Encodings.singleByteTables`.
  case singleByte(Int)
  case gbk, gb18030, big5, eucJP, iso2022JP, shiftJIS, eucKR
}

/// `-E`: how file contents are decoded before searching.
public enum EncodingMode: Sendable, Hashable {
  /// The default: a UTF-16 byte order mark selects UTF-16, and a UTF-8 one
  /// is skipped.
  case auto
  /// A UTF-16 byte order mark still takes precedence.
  case some(TextEncoding)
  /// `-E none`: the bytes are searched as they are.
  case disabled
}

/// Character encodings, decoded like ripgrep's `DecodeReaderBytes` with the
/// WHATWG decoders of encoding_rs: malformed input becomes U+FFFD. The
/// labels and single-byte tables are in `EncodingTables.swift`.
enum Encodings {
  /// The encoding a WHATWG label names (surrounding ASCII whitespace is
  /// ignored and letters are compared without case).
  static func encoding(forLabel label: String) -> TextEncoding? {
    byLabel[label.trimmingCharacters(in: " \t\n\u{0C}\r").lowercased()]
  }

  /// What ripgrep does with a file's bytes: skips `skip` bytes of byte
  /// order marks, and decodes the rest from `encoding`, or searches it as it
  /// is when that's nil.
  static func plan(_ data: Span<UInt8>, _ mode: EncodingMode) -> (skip: Int, encoding: TextEncoding?) {
    var encoding: TextEncoding?
    switch mode {
    case .disabled: return (0, nil)
    case .auto: encoding = nil
    case let .some(explicit): encoding = explicit
    }
    var skip = 0
    switch byteOrderMark(data, at: 0) {
    case let (.utf8, length)?:
      // A UTF-8 byte order mark is dropped, but doesn't override `-E`.
      skip = length
    case let (marked, length)?:
      (skip, encoding) = (length, marked)
    case nil:
      break
    }
    // Decoders also drop a byte order mark of their own encoding.
    if let encoding, let (own, length) = byteOrderMark(data, at: skip), own == encoding {
      skip += length
    }
    return (skip, encoding)
  }

  /// The byte order mark at `offset`, if any: its encoding and length.
  private static func byteOrderMark(_ data: Span<UInt8>, at offset: Int) -> (TextEncoding, Int)? {
    let left = data.count - offset
    guard left >= 2 else { return nil }
    switch (data[offset], data[offset + 1]) {
    case (0xEF, 0xBB) where left >= 3 && data[offset + 2] == 0xBF: return (.utf8, 3)
    case (0xFF, 0xFE): return (.utf16LE, 2)
    case (0xFE, 0xFF): return (.utf16BE, 2)
    default: return nil
    }
  }

  /// Decodes `data` to UTF-8, appending to `output`. Returns false if the
  /// encoding isn't available (the CJK encodings come from the system's
  /// iconv).
  static func decode(_ data: Span<UInt8>, from encoding: TextEncoding, into output: inout [UInt8]) -> Bool {
    output.reserveCapacity(output.count + data.count + data.count / 2)
    switch encoding {
    case .utf8: decodeUTF8(data, into: &output)
    case .utf16LE: decodeUTF16(data, bigEndian: false, into: &output)
    case .utf16BE: decodeUTF16(data, bigEndian: true, into: &output)
    case .userDefined:
      for i in data.indices {
        let byte = data[i]
        if byte < 0x80 {
          output.append(byte)
        } else {
          appendUTF8(0xF780 + UInt32(byte - 0x80), to: &output)
        }
      }
    case let .singleByte(table):
      let base = table * 128
      for i in data.indices {
        let byte = data[i]
        if byte < 0x80 {
          output.append(byte)
        } else {
          let scalar = singleByteTables[base + Int(byte - 0x80)]
          appendUTF8(scalar == 0 ? 0xFFFD : UInt32(scalar), to: &output)
        }
      }
    // iconv's closest matches to the WHATWG definitions.
    case .gbk, .gb18030: return OS.convert(data, from: "GB18030", appendingTo: &output)
    case .big5: return OS.convert(data, from: "BIG5-HKSCS", appendingTo: &output)
    case .eucJP: return OS.convert(data, from: "EUC-JP", appendingTo: &output)
    case .iso2022JP: return OS.convert(data, from: "ISO-2022-JP", appendingTo: &output)
    case .shiftJIS: return OS.convert(data, from: "CP932", appendingTo: &output)
    case .eucKR: return OS.convert(data, from: "CP949", appendingTo: &output)
    }
    return true
  }

  /// The WHATWG UTF-8 decoder: each maximal invalid subsequence becomes one
  /// U+FFFD. Valid sequences are copied as they are.
  private static func decodeUTF8(_ data: Span<UInt8>, into output: inout [UInt8]) {
    var i = 0
    let n = data.count
    while i < n {
      let byte = data[i]
      if byte < 0x80 {
        output.append(byte)
        i += 1
        continue
      }
      var needed = 0
      var lower: UInt8 = 0x80
      var upper: UInt8 = 0xBF
      switch byte {
      case 0xC2...0xDF: needed = 1
      case 0xE0...0xEF:
        needed = 2
        if byte == 0xE0 {
          lower = 0xA0
        }
        if byte == 0xED {
          upper = 0x9F
        }
      case 0xF0...0xF4:
        needed = 3
        if byte == 0xF0 {
          lower = 0x90
        }
        if byte == 0xF4 {
          upper = 0x8F
        }
      default:
        appendUTF8(0xFFFD, to: &output)
        i += 1
        continue
      }
      var j = i + 1
      var seen = 0
      while seen < needed, j < n, data[j] >= lower, data[j] <= upper {
        (lower, upper) = (0x80, 0xBF)
        seen += 1
        j += 1
      }
      if seen == needed {
        for k in i..<j {
          output.append(data[k])
        }
      } else {
        // The byte that broke the sequence starts the next one.
        appendUTF8(0xFFFD, to: &output)
      }
      i = j
    }
  }

  /// The WHATWG UTF-16 decoder: unpaired surrogates and a final odd byte
  /// become U+FFFD.
  private static func decodeUTF16(_ data: Span<UInt8>, bigEndian: Bool, into output: inout [UInt8]) {
    var lead: UInt32?
    var i = 0
    while i + 1 < data.count {
      let (a, b) = (UInt32(data[i]), UInt32(data[i + 1]))
      let unit = bigEndian ? a << 8 | b : b << 8 | a
      i += 2
      if let high = lead {
        lead = nil
        if (0xDC00...0xDFFF).contains(unit) {
          appendUTF8(0x10000 + (high - 0xD800) << 10 + (unit - 0xDC00), to: &output)
          continue
        }
        appendUTF8(0xFFFD, to: &output)
      }
      switch unit {
      case 0xD800...0xDBFF: lead = unit
      case 0xDC00...0xDFFF: appendUTF8(0xFFFD, to: &output)
      default: appendUTF8(unit, to: &output)
      }
    }
    if lead != nil || i < data.count {
      appendUTF8(0xFFFD, to: &output)
    }
  }

  private static func appendUTF8(_ scalar: UInt32, to output: inout [UInt8]) {
    switch scalar {
    case 0..<0x80:
      output.append(UInt8(scalar))
    case 0x80..<0x800:
      output.append(UInt8(0xC0 | scalar >> 6))
      output.append(UInt8(0x80 | scalar & 0x3F))
    case 0x800..<0x10000:
      output.append(UInt8(0xE0 | scalar >> 12))
      output.append(UInt8(0x80 | scalar >> 6 & 0x3F))
      output.append(UInt8(0x80 | scalar & 0x3F))
    default:
      output.append(UInt8(0xF0 | scalar >> 18))
      output.append(UInt8(0x80 | scalar >> 12 & 0x3F))
      output.append(UInt8(0x80 | scalar >> 6 & 0x3F))
      output.append(UInt8(0x80 | scalar & 0x3F))
    }
  }
}
