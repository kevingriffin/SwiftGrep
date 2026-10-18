import BinaryParsing
import Darwin
import System

/// The kind of a directory entry, as reported by `getattrlistbulk`.
enum EntryKind: UInt8, Sendable {
  case file
  case directory
  case symlink
  case other

  init(vnodeType: UInt32) {
    switch vnodeType {
    case 1: self = .file // VREG
    case 2: self = .directory // VDIR
    case 5: self = .symlink // VLNK
    default: self = .other
    }
  }

  init(_ type: FileType) {
    switch type {
    case .regular: self = .file
    case .directory: self = .directory
    case .symbolicLink: self = .symlink
    default: self = .other
    }
  }
}

/// One entry of a directory listing. The name lives in the listing's
/// `names` storage, followed by a NUL terminator.
struct DirectoryEntry {
  var nameOffset: Int
  var nameLength: Int
  var kind: EntryKind
  /// Data length in bytes for files, or -1 if unknown.
  var size: Int64
  /// Whether the file was large when its listing was cached. Only a
  /// scheduling hint: the file may have changed since.
  var largeHint = false

  /// Files from this size up are searched as jobs of their own.
  static let largeSize: Int64 = 1 << 20

  /// Whether the file is (probably) large enough to search on its own.
  var isLarge: Bool {
    size >= Self.largeSize || (size < 0 && largeHint)
  }

  /// The name's bytes in `DirectoryListing.names`.
  var nameRange: Range<Int> {
    nameOffset..<(nameOffset + nameLength)
  }

  /// The name with its NUL terminator, for system calls.
  var cNameRange: Range<Int> {
    nameOffset..<(nameOffset + nameLength + 1)
  }
}

/// Reads whole directories with `getattrlistbulk`, which returns names, types
/// and sizes for many entries per system call. This replaces the
/// `readdir` + `stat` + "probe for .gitignore" pattern of portable walkers:
/// on APFS every `open` is expensive and contended, so knowing up front which
/// ignore files exist (and which files are empty) avoids needless opens.
///
/// The listing owns its buffers and is reused for every directory a worker
/// reads, so it is non-copyable.
struct DirectoryListing: ~Copyable {
  /// The buffer `getattrlistbulk` fills.
  private var bulk = UniqueArray<UInt8>(repeating: 0, count: 128 * 1024)
  /// Every entry's name followed by a NUL, so names can be passed to
  /// `openat` without copying.
  private(set) var names = UniqueArray<UInt8>(capacity: 64 * 1024)
  private(set) var entries: [DirectoryEntry] = []

  init() {
    entries.reserveCapacity(256)
  }

  mutating func reset() {
    entries.removeAll(keepingCapacity: true)
    names.removeLast(names.count)
  }

  /// Reads all entries of the open directory `fd`.
  ///
  /// Everything the kernel returns is validated before use: entry lengths
  /// and name references must stay inside the buffer, and names that could
  /// change the meaning of a path (empty, `.`, `..`, or containing `/` or
  /// NUL), which a misbehaving network or user-space file system could
  /// return, are skipped.
  mutating func read(directory fd: FileDescriptor) throws(Errno) {
    reset()
    var request = attrlist()
    request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME)
      | attrgroup_t(ATTR_CMN_ERROR) | attrgroup_t(ATTR_CMN_OBJTYPE)
    request.fileattr = attrgroup_t(ATTR_FILE_DATALENGTH)
    while true {
      let count = try OS.getattrlistbulk(fd, &request, into: &bulk)
      if count == 0 {
        return
      }
      do {
        var input = ParserSpan(bulk.span.bytes)
        for _ in 0..<count {
          try Self.parseEntry(&input, names: &names, entries: &entries)
        }
      } catch {
        throw .ioError
      }
    }
  }

  /// Parses one entry: its length (u32, including itself), the returned
  /// attribute groups (5 × u32), then the requested attributes in order.
  private static func parseEntry(
    _ input: inout ParserSpan, names: inout UniqueArray<UInt8>, entries: inout [DirectoryEntry],
  ) throws(ParsingError) {
    let length = try Int(parsing: &input, storedAsLittleEndian: UInt32.self)
    var entry = try input.sliceSpan(byteCount: length - 4)
    let common = try UInt32(parsingLittleEndian: &entry)
    try entry.seek(toRelativeOffset: 8) // volume and directory attributes
    let fileAttributes = try UInt32(parsingLittleEndian: &entry)
    try entry.seek(toRelativeOffset: 4) // fork attributes
    var failed = false
    if common & UInt32(ATTR_CMN_ERROR) != 0 {
      failed = try UInt32(parsingLittleEndian: &entry) != 0
    }
    var name: ParserSpan? = nil
    if common & UInt32(ATTR_CMN_NAME) != 0 {
      // An attrreference_t: the name's offset from the reference itself,
      // and its length including the NUL. The name must lie in this entry.
      let offset = try Int(parsing: &entry, storedAsLittleEndian: Int32.self)
      let length = try Int(parsing: &entry, storedAsLittleEndian: UInt32.self)
      var data = try entry.seeking(toRelativeOffset: offset - 8)
      name = try data.sliceSpan(byteCount: length - 1)
    }
    var kind = EntryKind.other
    if common & UInt32(ATTR_CMN_OBJTYPE) != 0 {
      kind = try EntryKind(vnodeType: UInt32(parsingLittleEndian: &entry))
    }
    var size: Int64 = -1
    if fileAttributes & UInt32(ATTR_FILE_DATALENGTH) != 0 {
      size = try Int64(parsingLittleEndian: &entry)
    }
    if !failed, let name {
      let bytes = Span<UInt8>(viewing: name.bytes)
      if isPlainName(bytes) {
        entries.append(DirectoryEntry(nameOffset: names.count, nameLength: bytes.count, kind: kind, size: size))
        names.append(copying: bytes)
        names.append(0)
      }
    }
  }

  /// Whether `name` is a single, ordinary path component.
  static func isPlainName(_ name: Span<UInt8>) -> Bool {
    switch name.count {
    case 0: return false
    case 1: if name[0] == UInt8(ascii: ".") {
        return false
      }
    case 2: if name[0] == UInt8(ascii: ".") && name[1] == UInt8(ascii: ".") {
        return false
      }
    default: break
    }
    var i = 0
    while i < name.count {
      if name[i] == UInt8(ascii: "/") || name[i] == 0 {
        return false
      }
      i += 1
    }
    return true
  }

  /// Adds an entry (used when loading a cached listing).
  mutating func appendEntry(name: Span<UInt8>, kind: EntryKind, size: Int64, largeHint: Bool = false) {
    guard Self.isPlainName(name) else { return }
    entries.append(DirectoryEntry(nameOffset: names.count, nameLength: name.count, kind: kind, size: size,
                                  largeHint: largeHint))
    names.append(copying: name)
    names.append(0)
  }

  mutating func updateEntry(at index: Int, _ body: (inout DirectoryEntry) -> Void) {
    body(&entries[index])
  }

  /// The entry's name, copied.
  func nameBytes(of entry: DirectoryEntry) -> [UInt8] {
    Array(copying: names.span.extracting(entry.nameRange))
  }
}

/// A growable byte buffer that a worker reads files into. Reused for every
/// file, so it is non-copyable and frees its memory when the worker ends.
struct FileBuffer: ~Copyable {
  /// The file's contents after `readAll`.
  private(set) var storage = UniqueArray<UInt8>(capacity: 256 * 1024)

  enum ReadOutcome {
    case complete
    case failed(Errno)
    /// The file is larger than `mapThreshold`; map it instead.
    case tooLarge(Int64)
  }

  /// Reads the whole file. With a known size this is a single `read` call:
  /// asking for one byte more than expected detects both EOF and growth.
  /// Without one (listings from the cache carry no sizes), the first read
  /// usually gets everything; only if it fills the buffer is the size looked up.
  mutating func readAll(_ fd: FileDescriptor, sizeHint: Int64, regularFile: Bool, mapThreshold: Int64) -> ReadOutcome {
    storage.removeLast(storage.count)
    var knownSize = sizeHint
    if knownSize >= 0 {
      if knownSize > mapThreshold {
        return .tooLarge(knownSize)
      }
      if Int(knownSize) + 1 > storage.capacity {
        storage.setCapacity(Int(knownSize) + 1)
      }
    }
    while true {
      if storage.freeCapacity == 0 {
        if knownSize < 0 && regularFile, let info = try? fd.stat() {
          knownSize = info.size
          if knownSize > mapThreshold {
            return .tooLarge(knownSize)
          }
        }
        if knownSize >= Int64(storage.count) {
          storage.setCapacity(Int(knownSize) + 1)
        } else {
          storage.setCapacity(storage.capacity * 2)
        }
      }
      // read(2) rejects requests above INT_MAX.
      let requested = min(storage.freeCapacity, 1 << 30)
      let n: Int
      do {
        n = try OS.read(fd, appendingTo: &storage, limit: requested)
      } catch {
        return .failed(error)
      }
      // A short read of a regular file means EOF; no second call needed.
      if n == 0 || (regularFile && n < requested) {
        return .complete
      }
    }
  }

  /// Releases memory after reading an unusually large file.
  mutating func shrinkIfLarge(limit: Int = 1 << 20) {
    guard storage.capacity > limit else { return }
    storage = UniqueArray(capacity: 256 * 1024)
  }
}

enum FileIO {
  /// Reads a small file completely (configuration and ignore files).
  static func readWholeFile(path: String) throws(Errno) -> [UInt8] {
    let file = try OS.open(path, .readOnly, .closeOnExec)
    return try readWholeFile(file.descriptor)
  }

  /// Reads `name` (NUL-terminated) in the open directory `directory`.
  static func readWholeFile(_ name: Span<UInt8>, in directory: FileDescriptor) throws(Errno) -> [UInt8] {
    let file = try OS.open(name, in: directory, .closeOnExec)
    return try readWholeFile(file.descriptor)
  }

  static func readWholeFile(_ fd: FileDescriptor) throws(Errno) -> [UInt8] {
    var buffer = UniqueArray<UInt8>(capacity: 64 * 1024)
    while true {
      if buffer.freeCapacity == 0 {
        buffer.setCapacity(buffer.capacity * 2)
      }
      if try OS.read(fd, appendingTo: &buffer, limit: buffer.freeCapacity) == 0 {
        return Array(copying: buffer.span)
      }
    }
  }

  static func environment(_ name: String) -> String? {
    OS.environment(name)
  }
}

extension Array where Element: BitwiseCopyable {
  /// A copy of a span's elements.
  init(copying span: Span<Element>) {
    self.init()
    reserveCapacity(span.count)
    for i in span.indices {
      append(span[i])
    }
  }
}
