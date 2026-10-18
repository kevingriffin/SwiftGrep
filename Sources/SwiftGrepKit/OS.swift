import Darwin
import System

/// The system calls SwiftGrep makes, with safe signatures.
///
/// Built on the System framework (swift-system, which macOS 27 ships with
/// `Stat`): descriptors are `FileDescriptor`s, metadata is `Stat`, and
/// failures are thrown as typed `Errno`s, so an error can't be lost or
/// overwritten between a failing call and the code that reports it.
///
/// This is the only file in SwiftGrepKit that passes pointers to C. Every
/// function takes and returns safe types (spans, arrays, strings and values),
/// and each `unsafe` expression is preceded by the checks that make it sound,
/// so the rest of the module compiles under strict memory safety without any
/// `unsafe` code. Paths given as byte spans must be NUL-terminated.
enum OS {
  // MARK: - Opening and inspecting files

  static func open(_ path: Span<UInt8>, _ options: FileDescriptor.OpenOptions = []) throws(Errno) -> OpenFile {
    precondition(path.count > 0 && path[path.count - 1] == 0, "path must be NUL-terminated")
    let fd = path.withUnsafeBufferPointer { p in
      unsafe p.withMemoryRebound(to: CChar.self) { unsafe Darwin.open($0.baseAddress!, options.rawValue) }
    }
    guard fd >= 0 else { throw Errno(rawValue: errno) }
    return OpenFile(FileDescriptor(rawValue: fd))
  }

  /// Opens `name` (NUL-terminated) in the open directory `directory`.
  static func open(_ name: Span<UInt8>, in directory: FileDescriptor, _ options: FileDescriptor.OpenOptions = []) throws(Errno) -> OpenFile {
    precondition(name.count > 0 && name[name.count - 1] == 0, "name must be NUL-terminated")
    let fd = name.withUnsafeBufferPointer { p in
      unsafe p.withMemoryRebound(to: CChar.self) { unsafe openat(directory.rawValue, $0.baseAddress!, options.rawValue) }
    }
    guard fd >= 0 else { throw Errno(rawValue: errno) }
    return OpenFile(FileDescriptor(rawValue: fd))
  }

  static func open(
    _ path: String, _ mode: FileDescriptor.AccessMode = .readOnly,
    _ options: FileDescriptor.OpenOptions = [], permissions: FilePermissions = .ownerReadWrite,
  ) throws(Errno) -> OpenFile {
    let fd = unsafe Darwin.open(path, mode.rawValue | options.rawValue, permissions.rawValue)
    guard fd >= 0 else { throw Errno(rawValue: errno) }
    return OpenFile(FileDescriptor(rawValue: fd))
  }

  /// `stat` (following symlinks) of a NUL-terminated path.
  static func stat(_ path: Span<UInt8>) throws(Errno) -> Stat {
    precondition(path.count > 0 && path[path.count - 1] == 0, "path must be NUL-terminated")
    return try path.withUnsafeBufferPointer { p throws(Errno) -> Stat in
      try unsafe p.withMemoryRebound(to: CChar.self) { c throws(Errno) -> Stat in
        try unsafe Stat(c.baseAddress!)
      }
    }
  }

  /// `stat` (following symlinks) of a NUL-terminated name in `directory`.
  static func stat(_ name: Span<UInt8>, in directory: FileDescriptor) throws(Errno) -> Stat {
    precondition(name.count > 0 && name[name.count - 1] == 0, "name must be NUL-terminated")
    return try name.withUnsafeBufferPointer { p throws(Errno) -> Stat in
      try unsafe p.withMemoryRebound(to: CChar.self) { c throws(Errno) -> Stat in
        try unsafe Stat(c.baseAddress!, relativeTo: directory, flags: [])
      }
    }
  }

  /// The type name of the file system holding `path` (e.g. "apfs").
  static func fileSystemType(_ path: String) -> String? {
    var info = statfs()
    guard unsafe statfs(path, &info) == 0 else { return nil }
    return withUnsafeBytes(of: info.f_fstypename) { bytes in
      unsafe String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
  }

  static func realpath(_ path: String) -> String? {
    guard let resolved = unsafe Darwin.realpath(path, nil) else { return nil }
    defer { unsafe free(resolved) }
    return unsafe String(cString: resolved)
  }

  // MARK: - Reading and writing

  /// Reads up to `limit` bytes from `fd` into `buffer`'s spare capacity (at
  /// least one byte must be free), retrying after interruptions. Returns the
  /// number of bytes read; 0 means end of file.
  static func read(_ fd: FileDescriptor, appendingTo buffer: inout UniqueArray<UInt8>, limit: Int) throws(Errno) -> Int {
    precondition(buffer.freeCapacity > 0 && limit > 0)
    while true {
      let n = buffer.edit { output in
        unsafe output.withUnsafeMutableBufferPointer { storage, initialized in
          let request = min(storage.count - initialized, limit)
          let n = unsafe Darwin.read(fd.rawValue, storage.baseAddress! + initialized, request)
          if n > 0 {
            initialized += n
          }
          return n
        }
      }
      if n >= 0 {
        return n
      }
      if errno != EINTR {
        throw Errno(rawValue: errno)
      }
    }
  }

  /// Writes all of `bytes`, retrying after interruptions.
  static func writeAll(_ fd: FileDescriptor, _ bytes: Span<UInt8>) throws(Errno) {
    var offset = 0
    while offset < bytes.count {
      let n = bytes.withUnsafeBufferPointer { p in
        unsafe Darwin.write(fd.rawValue, p.baseAddress! + offset, p.count - offset)
      }
      if n > 0 {
        offset += n
      } else if n < 0 && errno == EINTR {
        continue
      } else {
        throw n < 0 ? Errno(rawValue: errno) : .ioError
      }
    }
  }

  /// Fills `buffer` (its whole initialized contents) with directory entries
  /// in `getattrlistbulk` format. Returns the entry count, 0 at the end of
  /// the directory.
  static func getattrlistbulk(_ fd: FileDescriptor, _ request: inout attrlist, into buffer: inout UniqueArray<UInt8>) throws(Errno) -> Int {
    var storage = buffer.mutableSpan
    while true {
      let count = storage.withUnsafeMutableBytes { bytes in
        unsafe Darwin.getattrlistbulk(fd.rawValue, &request, bytes.baseAddress, bytes.count, 0)
      }
      if count >= 0 {
        return Int(count)
      }
      if errno != EINTR {
        throw Errno(rawValue: errno)
      }
    }
  }

  // MARK: - Directories and files by path

  /// Creates a directory, succeeding if it already exists.
  static func makeDirectory(_ path: String, permissions: FilePermissions) -> Bool {
    unsafe mkdir(path, permissions.rawValue) == 0 || errno == EEXIST
  }

  static func rename(_ from: String, _ to: String) -> Bool {
    unsafe Darwin.rename(from, to) == 0
  }

  @discardableResult
  static func unlink(_ path: String) -> Bool {
    unsafe Darwin.unlink(path) == 0
  }

  /// Names in a directory (without `.` and `..`), or nil if it can't be read.
  static func directoryNames(_ path: String) -> [String]? {
    guard let dir = unsafe opendir(path) else { return nil }
    defer { unsafe closedir(dir) }
    var names: [String] = []
    while let entry = unsafe readdir(dir) {
      let name = unsafe withUnsafeBytes(of: entry.pointee.d_name) { bytes in
        unsafe String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
      }
      if name != "." && name != ".." {
        names.append(name)
      }
    }
    return names
  }

  // MARK: - Processes

  /// The output of a command run to completion.
  struct ProcessResult {
    var status: Int32
    var output: [UInt8]
    var error: [UInt8]
  }

  /// Runs `arguments` (the command is looked up in `PATH`) with standard
  /// input from `input`, or `/dev/null`, collecting its output and errors.
  /// Throws if the command can't be started.
  static func spawn(_ arguments: [String], input: FileDescriptor? = nil) throws(Errno) -> ProcessResult {
    precondition(!arguments.isEmpty)
    var outputPipe = try makePipe()
    var errorPipe = try makePipe()
    defer {
      for fd in [outputPipe[0], outputPipe[1], errorPipe[0], errorPipe[1]] where fd >= 0 {
        close(fd)
      }
    }
    var actions: posix_spawn_file_actions_t? = nil
    unsafe posix_spawn_file_actions_init(&actions)
    defer { unsafe posix_spawn_file_actions_destroy(&actions) }
    if let input {
      unsafe posix_spawn_file_actions_adddup2(&actions, input.rawValue, 0)
    } else {
      unsafe posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    }
    unsafe posix_spawn_file_actions_adddup2(&actions, outputPipe[1], 1)
    unsafe posix_spawn_file_actions_adddup2(&actions, errorPipe[1], 2)
    // The child gets only these three descriptors, so children spawned by
    // other workers at the same time never hold each other's pipes open.
    var attributes: posix_spawnattr_t? = nil
    unsafe posix_spawnattr_init(&attributes)
    defer { unsafe posix_spawnattr_destroy(&attributes) }
    unsafe posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
    var argv: [UnsafeMutablePointer<CChar>?] = unsafe arguments.map { unsafe strdup($0) } + [nil]
    defer {
      for unsafe pointer in unsafe argv {
        unsafe free(pointer)
      }
    }
    var pid: pid_t = 0
    let spawned = unsafe posix_spawnp(&pid, argv[0], &actions, &attributes, &argv, environ)
    guard spawned == 0 else { throw Errno(rawValue: spawned) }
    close(outputPipe[1])
    outputPipe[1] = -1
    close(errorPipe[1])
    errorPipe[1] = -1
    var result = ProcessResult(status: 0, output: [], error: [])
    drain(output: OpenFileView(outputPipe[0]), error: OpenFileView(errorPipe[0]), into: &result)
    var status: Int32 = 0
    while unsafe waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    // WIFEXITED / WEXITSTATUS; a signal counts as a failure.
    result.status = status & 0x7F == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F)
    return result
  }

  /// A pipe's read and write ends.
  private static func makePipe() throws(Errno) -> [Int32] {
    var ends: [Int32] = [-1, -1]
    guard unsafe pipe(&ends) == 0 else { throw Errno(rawValue: errno) }
    return ends
  }

  /// A borrowed descriptor (owned by the caller).
  struct OpenFileView {
    let fd: Int32
    init(_ fd: Int32) {
      self.fd = fd
    }
  }

  /// Reads both pipes until they close, so a child that fills one of them
  /// can't block forever.
  private static func drain(output: OpenFileView, error: OpenFileView, into result: inout ProcessResult) {
    var open = [output.fd, error.fd]
    var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    while !open.isEmpty {
      var fds = open.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
      let ready = unsafe poll(&fds, nfds_t(fds.count), -1)
      if ready < 0 {
        if errno == EINTR {
          continue
        }
        return
      }
      for entry in fds where entry.revents != 0 {
        let n = chunk.withUnsafeMutableBytes { unsafe Darwin.read(entry.fd, $0.baseAddress, $0.count) }
        if n > 0 {
          if entry.fd == output.fd {
            result.output.append(contentsOf: chunk[0..<n])
          } else {
            result.error.append(contentsOf: chunk[0..<n])
          }
        } else if n == 0 || errno != EINTR {
          open.removeAll { $0 == entry.fd }
        }
      }
    }
  }

  /// The standard output of a command that succeeded, or nil.
  static func run(_ arguments: [String]) -> [UInt8]? {
    guard let result = try? spawn(arguments), result.status == 0 else { return nil }
    return result.output
  }

  static func hostname() -> String? {
    var buffer = [CChar](repeating: 0, count: 256)
    guard unsafe gethostname(&buffer, buffer.count) == 0 else { return nil }
    let name = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: name, as: UTF8.self)
  }

  // MARK: - Process environment

  static func environment(_ name: String) -> String? {
    guard let value = unsafe getenv(name) else { return nil }
    return unsafe String(cString: value)
  }

  /// Seconds since the epoch.
  static func now() -> Int {
    var time = timespec()
    _ = unsafe clock_gettime(CLOCK_REALTIME, &time)
    return time.tv_sec
  }

  static func ignoreBrokenPipes() {
    _ = signal(SIGPIPE, SIG_IGN)
  }
}

extension Errno {
  /// ripgrep's error style: "No such file or directory (os error 2)".
  var message: String {
    "\(description) (os error \(rawValue))"
  }
}

/// An open file descriptor that is closed when it goes out of scope, so
/// descriptors can be neither leaked nor closed twice.
struct OpenFile: ~Copyable {
  let descriptor: FileDescriptor

  init(_ descriptor: FileDescriptor) {
    self.descriptor = descriptor
  }

  /// Closes the file now rather than at the end of the scope.
  consuming func close() {}

  deinit { _ = try? descriptor.close() }
}

/// A read-only memory map of a file, unmapped when it goes out of scope.
/// Its bytes are only lent out as a span for the duration of a call, so
/// using it is safe even though it holds a pointer.
@safe struct MappedFile: ~Copyable {
  private let address: UnsafeRawPointer
  let length: Int

  init(_ fd: FileDescriptor, length: Int) throws(Errno) {
    precondition(length > 0)
    let p = unsafe mmap(nil, length, PROT_READ, MAP_PRIVATE, fd.rawValue, 0)
    guard let p = unsafe p, unsafe p != MAP_FAILED else { throw Errno(rawValue: errno) }
    _ = unsafe madvise(p, length, MADV_SEQUENTIAL)
    unsafe address = UnsafeRawPointer(p)
    self.length = length
  }

  deinit { _ = unsafe munmap(UnsafeMutableRawPointer(mutating: address), length) }

  /// Calls `body` with the mapped bytes. The span cannot escape the call, so
  /// it never outlives the mapping.
  func withBytes<R>(_ body: (Span<UInt8>) -> R) -> R {
    let span = unsafe Span(_unsafeStart: address.assumingMemoryBound(to: UInt8.self), count: length)
    return body(span)
  }
}
