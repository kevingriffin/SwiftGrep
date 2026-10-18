import BinaryParsing
import Darwin
import System
import Synchronization

/// A persistent cache of directory listings, validated with `lstat`.
///
/// On APFS, opening a directory to enumerate it costs as much as opening a
/// file and contends on the same kernel lock, while `lstat` is several times
/// cheaper and scales across cores. A directory whose device, inode,
/// modification time and status change time are unchanged has the same
/// entries (creating, removing or renaming an entry always updates the
/// directory's mtime and ctime, at nanosecond resolution, and ctime cannot be
/// set by user space). So an unchanged directory's names and types are read
/// from the cache instead of the file system. File contents and ignore files
/// are always read fresh.
///
/// The cache file is one per search root, read whole at startup, with a
/// sorted index so lookups need no parsing up front. All fields are little
/// endian, and every offset is checked against the file before use, so a
/// damaged or hostile cache file can only cause cache misses:
///
///     header   magic "SGLC", version, record count
///     index    count × (inode u64, device i32, offset u32, length u32, pad u32), sorted
///     records  stamp (4 × i64), entry count u32, entries (kind u8, length u16, name)
///
/// The high bit of an entry's kind marks a file that was large when it was
/// recorded (see `DirectoryEntry.largeHint`).
final class ListingCache: Sendable {
  struct Key: Hashable, Sendable, Comparable {
    var device: Int32
    var inode: UInt64

    init(device: Int32, inode: UInt64) {
      self.device = device
      self.inode = inode
    }

    init(_ info: Stat) {
      device = info.deviceID.rawValue
      inode = info.inode.rawValue
    }

    static func < (a: Key, b: Key) -> Bool {
      a.device != b.device ? a.device < b.device : a.inode < b.inode
    }
  }

  /// The parts of `stat` that change whenever a directory's entries change.
  struct Stamp: Equatable, Sendable {
    var modifiedSeconds: Int
    var modifiedNanoseconds: Int
    var changedSeconds: Int
    var changedNanoseconds: Int

    init(_ info: Stat) {
      modifiedSeconds = info.st_mtim.tv_sec
      modifiedNanoseconds = info.st_mtim.tv_nsec
      changedSeconds = info.st_ctim.tv_sec
      changedNanoseconds = info.st_ctim.tv_nsec
    }

    init(parsing input: inout ParserSpan) throws(ParsingError) {
      modifiedSeconds = try Int(parsing: &input, storedAsLittleEndian: Int64.self)
      modifiedNanoseconds = try Int(parsing: &input, storedAsLittleEndian: Int64.self)
      changedSeconds = try Int(parsing: &input, storedAsLittleEndian: Int64.self)
      changedNanoseconds = try Int(parsing: &input, storedAsLittleEndian: Int64.self)
    }
  }

  /// A fresh listing to be written back: entries as (kind, name) pairs.
  struct Record: Sendable {
    var stamp: Stamp
    var entries: [UInt8]
    var entryCount: Int
  }

  private static let magic: UInt32 = 0x434C_4753 // "SGLC"
  private static let version: UInt32 = 2
  private static let headerSize = 16
  private static let indexEntrySize = 24
  /// Records beyond this are not added; a cache that grows past it (from
  /// orphaned directories) starts over with the current run's listings.
  private static let maxRecords = 2_000_000
  /// The cache is not read or written if it is larger than this.
  private static let maxFileSize = 256 << 20

  let path: String
  /// Listings of directories changed this recently (in seconds) are not cached.
  private let quietPeriod: Int
  /// The previous cache file (empty if there was none or it was invalid).
  private let contents: [UInt8]
  private let recordCount: Int
  private let fresh = Mutex<[Key: Record]>([:])

  /// Opens the cache for a search root, or returns nil if caching does not
  /// apply (not APFS, or no usable cache directory).
  init?(root absolutePath: [UInt8], directory: String? = cacheDirectory(), quietPeriod: Int = 2) {
    guard OS.fileSystemType(String(decoding: absolutePath, as: UTF8.self)) == "apfs", let directory else { return nil }
    self.quietPeriod = quietPeriod
    let name = directory + "/listings-" + Self.hash(absolutePath)
    path = name + ".v\(Self.version)"
    // Drop the cache written by an older format.
    for old in 1..<Self.version { OS.unlink(name + ".v\(old)") }
    let contents = Self.read(path) ?? []
    let count = Self.validRecordCount(contents.span.bytes)
    self.contents = count == nil ? [] : contents
    recordCount = count ?? 0
  }

  private static func read(_ path: String) -> [UInt8]? {
    guard let file = try? OS.open(path, .readOnly, [.closeOnExec, .noFollow]),
          let info = try? file.descriptor.stat(), info.type == .regular, info.size <= maxFileSize else { return nil }
    return try? FileIO.readWholeFile(file.descriptor)
  }

  /// The number of records if the header and index fit in the file.
  private static func validRecordCount(_ file: RawSpan) -> Int? {
    var input = ParserSpan(file)
    do {
      try #magicNumber("SGLC", parsing: &input)
      guard try UInt32(parsingLittleEndian: &input) == version else { return nil }
      let count = try Int(parsing: &input, storedAsLittleEndian: UInt32.self)
      try input.seek(toRelativeOffset: 4)
      _ = try input.sliceSpan(byteCount: count * indexEntrySize)
      return count
    } catch {
      return nil
    }
  }

  /// The cache directory, created if needed. It is only used if it is a
  /// real directory owned by this user and closed to everyone else, so other
  /// users can neither plant files in it nor redirect writes through it.
  static func cacheDirectory(environment: (String) -> String? = FileIO.environment) -> String? {
    let base: String
    if let xdg = environment("XDG_CACHE_HOME"), xdg.hasPrefix("/") {
      // The XDG spec says relative paths are invalid and must be ignored.
      base = xdg + "/swiftgrep"
    } else if let home = environment("HOME"), home.hasPrefix("/") {
      base = home + "/Library/Caches/SwiftGrep"
    } else {
      return nil
    }
    guard OS.makeDirectory(base, permissions: .ownerReadWriteExecute),
          let directory = try? OS.open(base, .readOnly, [.directory, .noFollow, .closeOnExec]),
          let info = try? directory.descriptor.stat(),
          info.userID.rawValue == getuid(),
          info.permissions.isDisjoint(with: [.groupReadWriteExecute, .otherReadWriteExecute])
    else { return nil }
    return base
  }

  /// FNV-1a, enough to name a cache file after its root path.
  static func hash(_ bytes: [UInt8]) -> String {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    for b in bytes {
      h ^= UInt64(b)
      h = h &* 0x0000_0100_0000_01B3
    }
    let hex = String(h, radix: 16)
    return String(repeating: "0", count: 16 - hex.count) + hex
  }

  // MARK: - Lookup

  /// One entry of the sorted index.
  private struct IndexEntry {
    var key: Key
    var record: ParserRange

    /// Parses entry `i`; the record range is checked against the file.
    init(_ i: Int, in file: borrowing ParserSpan) throws(ParsingError) {
      var input = try file.seeking(toAbsoluteOffset: ListingCache.headerSize + i * ListingCache.indexEntrySize)
      let inode = try UInt64(parsingLittleEndian: &input)
      let device = try Int32(parsingLittleEndian: &input)
      let offset = try Int(parsing: &input, storedAsLittleEndian: UInt32.self)
      let length = try Int(parsing: &input, storedAsLittleEndian: UInt32.self)
      key = Key(device: device, inode: inode)
      var whole = try file.seeking(toAbsoluteOffset: offset)
      record = try whole.sliceRange(byteCount: length)
    }
  }

  /// Fills `listing` from the cache if the directory is unchanged.
  func load(_ key: Key, stamp: Stamp, into listing: inout DirectoryListing) -> Bool {
    let contents = self.contents
    let file = ParserSpan(contents.span.bytes)
    do {
      var lo = 0
      var hi = recordCount
      while lo < hi {
        let mid = (lo + hi) / 2
        let entry = try IndexEntry(mid, in: file)
        if entry.key < key {
          lo = mid + 1
        } else if key < entry.key {
          hi = mid
        } else {
          var record = try file.seeking(toRange: entry.record)
          guard try Stamp(parsing: &record) == stamp else { return false }
          let count = try Int(parsing: &record, storedAsLittleEndian: UInt32.self)
          try listing.load(cachedEntries: &record, count: count)
          return true
        }
      }
    } catch {
      // A damaged cache file is just a miss.
    }
    return false
  }

  // MARK: - Recording

  /// Remembers a freshly read listing, unless the directory changed too
  /// recently to trust its timestamps.
  func record(_ key: Key, stamp: Stamp, listing: borrowing DirectoryListing) {
    let now = OS.now()
    guard now - stamp.changedSeconds >= quietPeriod, now - stamp.modifiedSeconds >= quietPeriod else { return }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(listing.entries.count * 16)
    let names = listing.names.span
    for entry in listing.entries {
      guard entry.nameLength <= Int(UInt16.max) else { return }
      bytes.append(entry.kind.rawValue | (entry.isLarge ? 0x80 : 0))
      bytes.append(UInt8(truncatingIfNeeded: entry.nameLength))
      bytes.append(UInt8(truncatingIfNeeded: entry.nameLength >> 8))
      for i in entry.nameRange { bytes.append(names[i]) }
    }
    let record = Record(stamp: stamp, entries: bytes, entryCount: listing.entries.count)
    fresh.withLock { records in
      if records.count < Self.maxRecords { records[key] = record }
    }
  }

  /// Writes the merged cache if anything changed. The file is replaced
  /// atomically, so concurrent runs at worst lose each other's updates.
  func save() {
    let updates = fresh.withLock { $0 }
    guard !updates.isEmpty else { return }
    let contents = self.contents
    let file = ParserSpan(contents.span.bytes)
    var records: [(Key, Range<Int>?, Record?)] = []
    records.reserveCapacity(recordCount + updates.count)
    // Keep earlier listings unless the file has grown past its bound.
    if recordCount + updates.count <= Self.maxRecords {
      for i in 0..<recordCount {
        guard let entry = try? IndexEntry(i, in: file), updates[entry.key] == nil else { continue }
        records.append((entry.key, entry.record.lowerBound..<entry.record.upperBound, nil))
      }
    }
    for (key, record) in updates { records.append((key, nil, record)) }
    records.sort { $0.0 < $1.0 }

    var index: [UInt8] = []
    var data: [UInt8] = []
    index.reserveCapacity(records.count * Self.indexEntrySize)
    let dataStart = Self.headerSize + records.count * Self.indexEntrySize
    for (key, old, new) in records {
      let offset = dataStart + data.count
      if let old {
        data.append(contentsOf: contents[old])
      } else if let new {
        Self.append(new.stamp.modifiedSeconds, to: &data)
        Self.append(new.stamp.modifiedNanoseconds, to: &data)
        Self.append(new.stamp.changedSeconds, to: &data)
        Self.append(new.stamp.changedNanoseconds, to: &data)
        Self.append(UInt32(new.entryCount), to: &data)
        data.append(contentsOf: new.entries)
      }
      guard dataStart + data.count <= Self.maxFileSize else { return }
      Self.append(key.inode, to: &index)
      Self.append(key.device, to: &index)
      Self.append(UInt32(offset), to: &index)
      Self.append(UInt32(dataStart + data.count - offset), to: &index)
      Self.append(UInt32(0), to: &index)
    }
    var header: [UInt8] = []
    Self.append(Self.magic, to: &header)
    Self.append(Self.version, to: &header)
    Self.append(UInt32(records.count), to: &header)
    Self.append(UInt32(0), to: &header)

    // A fresh file that is never a symlink, so an existing name can't
    // redirect the write.
    let temporary = path + ".tmp.\(getpid())"
    OS.unlink(temporary)
    do {
      let file = try OS.open(temporary, .writeOnly, [.create, .exclusiveCreate, .noFollow, .closeOnExec],
                             permissions: .ownerReadWrite)
      try OS.writeAll(file.descriptor, header.span)
      try OS.writeAll(file.descriptor, index.span)
      try OS.writeAll(file.descriptor, data.span)
      file.close()
      if OS.rename(temporary, path) { return }
    } catch {}
    OS.unlink(temporary)
  }

  /// Appends `value` in little-endian byte order.
  private static func append<T: FixedWidthInteger>(_ value: T, to bytes: inout [UInt8]) {
    for shift in stride(from: 0, to: T.bitWidth, by: 8) {
      bytes.append(UInt8(truncatingIfNeeded: value >> shift))
    }
  }

  /// Removes every cache file.
  static func clearAll() -> Int32 {
    guard let directory = cacheDirectory(), let names = OS.directoryNames(directory) else { return 0 }
    for name in names where name.hasPrefix("listings-") { OS.unlink(directory + "/" + name) }
    return 0
  }
}

private struct InvalidEntryKind: Error {}

extension DirectoryListing {
  /// Replaces the listing with `count` entries decoded from a cache record:
  /// kind (u8, high bit: large file), name length (u16), name.
  mutating func load(cachedEntries input: inout ParserSpan, count: Int) throws(ParsingError) {
    reset()
    for _ in 0..<count {
      let tag = try UInt8(parsing: &input)
      guard let kind = EntryKind(rawValue: tag & 0x7F) else { throw ParsingError(userError: InvalidEntryKind()) }
      let length = try Int(parsing: &input, storedAsLittleEndian: UInt16.self)
      let name = try input.sliceSpan(byteCount: length)
      appendEntry(name: Span(viewing: name.bytes), kind: kind, size: -1, largeHint: tag & 0x80 != 0)
    }
  }
}
