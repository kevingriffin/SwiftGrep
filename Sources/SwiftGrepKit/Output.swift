import Darwin
import Synchronization
import System

/// A growable output buffer owned by one worker. Non-copyable: it owns its
/// memory and is flushed to the shared sink in large chunks.
struct OutputBuffer: ~Copyable {
  private(set) var storage: UniqueArray<UInt8>

  init(capacity: Int = 128 * 1024) {
    storage = UniqueArray(capacity: capacity)
  }

  var count: Int {
    storage.count
  }

  var isEmpty: Bool {
    storage.isEmpty
  }

  @inline(__always)
  mutating func append(_ byte: UInt8) {
    storage.append(byte)
  }

  mutating func append(_ bytes: Span<UInt8>) {
    storage.append(copying: bytes)
  }

  mutating func append(_ bytes: [UInt8]) {
    storage.append(copying: bytes.span)
  }

  mutating func append(_ string: String) {
    storage.append(copying: string.utf8)
  }

  /// Appends a decimal number.
  mutating func appendDecimal(_ value: Int) {
    var v = value
    if v == 0 {
      storage.append(UInt8(ascii: "0"))
      return
    }
    var digits = InlineArray<20, UInt8>(repeating: 0)
    var n = 0
    while v > 0 {
      digits[n] = UInt8(truncatingIfNeeded: v % 10) &+ 48
      v /= 10
      n += 1
    }
    while n > 0 {
      n -= 1
      storage.append(digits[n])
    }
  }

  mutating func removeAll() {
    storage.removeLast(storage.count)
  }

  /// Drops bytes past `length`, used to discard a partially formatted file.
  mutating func truncate(to length: Int) {
    if length < storage.count {
      storage.removeLast(storage.count - length)
    }
  }

  /// Copies out bytes from `start` (used to detach one file's output).
  func copyBytes(from start: Int) -> [UInt8] {
    Array(copying: storage.span.extracting(start...))
  }
}

/// Serializes writes to standard output from all workers.
///
/// Each write is a whole number of files, so output from different files is
/// never interleaved. When files need a separator between them (headings or
/// context), the sink adds it before every file except the first.
final class OutputSink: Sendable {
  private struct State {
    var wroteAnyFile = false
    var broken = false
    var sorted: [(path: [UInt8], data: [UInt8])] = []
  }

  private let state = Mutex(State())
  let fileSeparator: [UInt8]?
  let collectForSorting: Bool
  private let fd: FileDescriptor

  init(fd: FileDescriptor = .standardOutput, fileSeparator: [UInt8]?, collectForSorting: Bool) {
    self.fd = fd
    self.fileSeparator = fileSeparator
    self.collectForSorting = collectForSorting
  }

  var isBroken: Bool {
    state.withLock { $0.broken }
  }

  /// Writes output for one or more complete files.
  func write(_ bytes: Span<UInt8>) {
    guard !bytes.isEmpty else { return }
    state.withLock { s in
      guard !s.broken else { return }
      do { try OS.writeAll(fd, bytes) } catch { s.broken = true }
    }
  }

  /// Writes the output of a single file, preceded by the file separator if
  /// any file was written before.
  func writeFile(_ bytes: Span<UInt8>) {
    guard !bytes.isEmpty else { return }
    state.withLock { s in
      guard !s.broken else { return }
      if s.wroteAnyFile, let separator = fileSeparator {
        do { try OS.writeAll(fd, separator.span) } catch { s.broken = true; return }
      }
      s.wroteAnyFile = true
      do { try OS.writeAll(fd, bytes) } catch { s.broken = true }
    }
  }

  /// Keeps one file's output for `--sort`, to be written by `finishSorted`.
  func collect(path: [UInt8], data: [UInt8]) {
    state.withLock { $0.sorted.append((path, data)) }
  }

  /// Writes collected output in `--sort` order. Paths sort component-wise,
  /// like a sorted walk; for timestamps, files are looked up now, and those
  /// without one sort last (first in reverse), as in ripgrep.
  func finishSorted(by order: SortOrder) {
    let items = state.withLock { s -> [(path: [UInt8], data: [UInt8])] in
      let items = s.sorted
      s.sorted = []
      return items
    }
    var ordered = items.sorted { PathOrder.less($0.path, $1.path) }
    if order.key != .path {
      let times = ordered.map { item in Self.timestamp(of: item.path, order.key) }
      let indices = ordered.indices.sorted { a, b in
        switch (times[a], times[b]) {
        case let (x?, y?): x != y ? x < y : a < b
        case (_?, nil): true
        case (nil, _?): false
        case (nil, nil): a < b
        }
      }
      ordered = indices.map { ordered[$0] }
    }
    if order.reverse {
      ordered.reverse()
    }
    for item in ordered {
      if fileSeparator == nil {
        write(item.data.span)
      } else {
        writeFile(item.data.span)
      }
    }
  }
}

extension OutputSink {
  /// A file's timestamp in nanoseconds, for `--sort`.
  static func timestamp(of path: [UInt8], _ key: SortOrder.Key) -> Int? {
    let cPath = (path.isEmpty ? Array(".".utf8) : path) + [0]
    guard let info = try? OS.stat(cPath.span) else { return nil }
    let time = switch key {
    case .modified: info.st_mtim
    case .accessed: info.st_atim
    case .created: info.st_birthtim
    case .path: info.st_mtim
    }
    return time.tv_sec * 1_000_000_000 + time.tv_nsec
  }
}

/// Orders paths component by component, which is the order a sorted
/// depth-first walk visits them (so `a/x` sorts before `a-b/x`).
enum PathOrder {
  static func less(_ a: [UInt8], _ b: [UInt8]) -> Bool {
    let n = min(a.count, b.count)
    var i = 0
    while i < n {
      let x = a[i]
      let y = b[i]
      if x != y {
        if x == UInt8(ascii: "/") {
          return true
        }
        if y == UInt8(ascii: "/") {
          return false
        }
        return x < y
      }
      i += 1
    }
    return a.count < b.count
  }
}

/// Error messages go straight to stderr, one line at a time.
enum Diagnostics {
  private static let lock = Mutex(())

  static func error(_ message: String) {
    let line = Array(("sg: " + message + "\n").utf8)
    lock.withLock { _ in try? OS.writeAll(.standardError, line.span) }
  }
}
