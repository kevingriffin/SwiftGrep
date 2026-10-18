/// A `--hyperlink-format`: paths in colored output become OSC 8 terminal
/// hyperlinks, filled in from a template such as `file://{host}{path}`.
public struct HyperlinkFormat: Sendable, Hashable {
  enum Part: Sendable, Hashable {
    case text([UInt8])
    case host
    case wslPrefix
    case path
    case line
    case column
  }

  let parts: [Part]
  /// The host name for `{host}` (filled in once per run).
  var host: [UInt8] = []

  /// No hyperlinks (the default, and the `none` alias).
  public static let none = HyperlinkFormat(parts: [])

  private init(parts: [Part]) {
    self.parts = parts
  }

  var isEmpty: Bool {
    parts.isEmpty
  }

  /// Whether links differ per line (`{line}` is used), so they are written
  /// for every line even under `--heading`.
  var isLineDependent: Bool {
    parts.contains(.line)
  }

  /// ripgrep's aliases, sorted by name.
  static let aliases: [(name: String, format: String)] = [
    ("cursor", "cursor://file{path}:{line}:{column}"),
    ("default", "file://{host}{path}"),
    ("file", "file://{host}{path}"),
    ("grep+", "grep+://{path}:{line}"),
    ("kitty", "file://{host}{path}#{line}"),
    ("macvim", "mvim://open?url=file://{path}&line={line}&column={column}"),
    ("none", ""),
    ("textmate", "txmt://open?url=file://{path}&line={line}&column={column}"),
    ("vscode", "vscode://file{path}:{line}:{column}"),
    ("vscode-insiders", "vscode-insiders://file{path}:{line}:{column}"),
    ("vscodium", "vscodium://file{path}:{line}:{column}"),
  ]

  /// Parses a format or an alias, with ripgrep's validation and messages.
  public init(parsing text: String) throws(UsageError) {
    let input = Self.aliases.first { $0.name == text }?.format ?? text
    func failure(_ message: String) -> UsageError {
      UsageError("invalid hyperlink format: " + message)
    }
    var parts: [Part] = []
    func appendText(_ bytes: some Sequence<UInt8>) {
      if case var .text(existing) = parts.last {
        existing.append(contentsOf: bytes)
        parts[parts.count - 1] = .text(existing)
      } else {
        parts.append(.text(Array(bytes)))
      }
    }
    enum State { case verbatim, closing, opening, inVariable }
    var state = State.verbatim
    var name = ""
    for character in input {
      switch state {
      case .verbatim:
        if character == "{" {
          state = .opening
        } else if character == "}" {
          state = .closing
        } else {
          appendText(character.utf8)
        }
      case .closing:
        guard character == "}" else {
          throw failure("unopened variable: found '}' without a corresponding '{' preceding it")
        }
        appendText("}".utf8)
        state = .verbatim
      case .opening, .inVariable:
        if state == .opening && character == "{" {
          appendText("{".utf8)
          state = .verbatim
        } else if character == "}" {
          switch name {
          case "host": parts.append(.host)
          case "wslprefix": parts.append(.wslPrefix)
          case "path": parts.append(.path)
          case "line": parts.append(.line)
          case "column": parts.append(.column)
          default:
            throw failure("invalid hyperlink format variable: '\(name)', choose from: path, line, column, host, wslprefix")
          }
          name = ""
          state = .verbatim
        } else {
          name.append(character)
          state = .inVariable
        }
      }
    }
    switch state {
    case .verbatim: break
    case .closing: throw failure("unopened variable: found '}' without a corresponding '{' preceding it")
    case .opening, .inVariable: throw failure("unclosed variable: found '{' without a corresponding '}' following it")
    }
    if !parts.isEmpty {
      guard parts.contains(where: {
        if case .text = $0 {
          false
        } else {
          true
        }
      }) else {
        throw failure("at least a {path} variable is required in a hyperlink format, or otherwise use a valid alias: "
          + "default, none, cursor, file, grep+, kitty, macvim, textmate, vscode, vscode-insiders, vscodium")
      }
      guard parts.contains(.path) else { throw failure("the {path} variable is required in a hyperlink format") }
      if parts.contains(.column) && !parts.contains(.line) {
        throw failure("the hyperlink format contains a {column} variable, but no {line} variable is present")
      }
      guard case let .text(first) = parts.first, let colon = first.firstIndex(of: UInt8(ascii: ":")), colon > 0,
            first[..<colon].allSatisfy(Self.isSchemeByte)
      else {
        throw failure("the hyperlink format must start with a valid URL scheme, i.e., [0-9A-Za-z+-.]+:")
      }
    }
    self.parts = parts
  }

  private static func isSchemeByte(_ byte: UInt8) -> Bool {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
         UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "+"), UInt8(ascii: "-"), UInt8(ascii: "."):
      true
    default:
      false
    }
  }

  /// Appends the escape sequence that opens a link to `path` (an encoded
  /// absolute path, see `encode`).
  func appendOpening(path: [UInt8], line: Int?, column: Int?, to out: inout OutputBuffer) {
    out.append("\u{1B}]8;;")
    for part in parts {
      switch part {
      case let .text(bytes): out.append(bytes)
      case .host: out.append(host)
      case .wslPrefix: break
      case .path: out.append(path)
      case .line: out.appendDecimal(line ?? 1)
      case .column: out.appendDecimal(column ?? 1)
      }
    }
    out.append("\u{1B}\\")
  }

  static let closing = Array("\u{1B}]8;;\u{1B}\\".utf8)

  /// The canonical absolute path, percent-encoded for a `file://` URL, or
  /// nil if it can't be resolved (then no link is written).
  static func encode(path: [UInt8]) -> [UInt8]? {
    guard let resolved = OS.realpath(String(decoding: path.isEmpty ? Array(".".utf8) : path, as: UTF8.self)),
          resolved.hasPrefix("/")
    else { return nil }
    let hex = Array("0123456789ABCDEF".utf8)
    var result: [UInt8] = []
    for byte in resolved.utf8 {
      switch byte {
      case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
           UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "/"), UInt8(ascii: ":"), UInt8(ascii: "-"),
           UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"), 128...:
        result.append(byte)
      default:
        result += [UInt8(ascii: "%"), hex[Int(byte >> 4)], hex[Int(byte & 0xF)]]
      }
    }
    return result
  }
}

/// The host name for hyperlinks: the output of `--hostname-bin`, or the
/// system's host name.
enum Hostname {
  static func lookup(command: String?) -> String {
    if let command, let output = OS.run([command]) {
      let name = String(decoding: output, as: UTF8.self).trimmingCharacters(in: " \t\r\n")
      if !name.isEmpty {
        return name
      }
    }
    return OS.hostname() ?? ""
  }
}
