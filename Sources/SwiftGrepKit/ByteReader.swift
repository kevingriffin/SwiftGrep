/// A cursor for parsing untrusted bytes: `getattrlistbulk` results and the
/// listing cache file. Every read is checked against the cursor's range and
/// throws instead of going past it, so damaged input is an error, not a trap.
///
/// The cursor holds offsets rather than the bytes, because a type that
/// stores a span needs lifetime annotations, which are still experimental.
/// So each read takes the `Span` it parses, which bounds-checks too.
struct ByteReader {
  struct Malformed: Error {}

  private(set) var position: Int
  let end: Int

  /// A reader for all of `bytes`.
  init(_ bytes: Span<UInt8>) {
    position = 0
    end = bytes.count
  }

  /// A reader for `bytes` from `offset` on.
  init(_ bytes: Span<UInt8>, from offset: Int) throws(Malformed) {
    guard offset >= 0, offset <= bytes.count else { throw Malformed() }
    position = offset
    end = bytes.count
  }

  /// A reader for `range`, which must lie within `bytes`.
  init(_ range: Range<Int>, in bytes: Span<UInt8>) throws(Malformed) {
    guard range.lowerBound >= 0, range.upperBound <= bytes.count else { throw Malformed() }
    position = range.lowerBound
    end = range.upperBound
  }

  private init(position: Int, end: Int) {
    self.position = position
    self.end = end
  }

  /// The bytes left to read.
  var range: Range<Int> {
    position..<end
  }

  /// A reader for the next `count` bytes, which this one skips.
  mutating func take(_ count: Int) throws(Malformed) -> ByteReader {
    guard count >= 0, count <= end - position else { throw Malformed() }
    defer { position += count }
    return ByteReader(position: position, end: position + count)
  }

  mutating func skip(_ count: Int) throws(Malformed) {
    _ = try take(count)
  }

  /// Reads a little-endian integer.
  mutating func read<T: FixedWidthInteger>(_: T.Type, from bytes: Span<UInt8>) throws(Malformed) -> T {
    let field = try take(MemoryLayout<T>.size).range
    var value: T = 0
    for (shift, i) in zip(stride(from: 0, to: T.bitWidth, by: 8), field) {
      value |= T(truncatingIfNeeded: bytes[i]) << shift
    }
    return value
  }
}
