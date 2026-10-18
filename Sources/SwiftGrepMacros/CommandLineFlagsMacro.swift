import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// Generates a command line flag table from an enum whose cases carry
/// `@Spelling` attributes (and optional `@Section` headings):
///
///     @CommandLineFlags
///     enum Flag {
///       @Section("PATTERNS")
///       @Spelling("-e", "--regexp", value: "PATTERN", help: "A pattern to search for")
///       case regexp
///     }
///
/// It adds `short`, `long`, `negation`, `takesValue`, `valueName`, `help`,
/// `aliases`, `section` and `isHidden` properties, `byShort`, `byLong`
/// (including hidden `aliases`) and `byNegation` lookup tables, `declared`
/// (every flag in declaration order) and `optionsHelp`, the options section of
/// `--help`. A `negation` such as `--no-heading` turns the flag off again, as
/// in ripgrep; it is not listed in `--help`. Everything is computed at compile
/// time: unlike a reflection-based parser there is no work at startup, and
/// conflicting spellings are compile errors rather than runtime traps.
public struct CommandLineFlagsMacro: MemberMacro {
  struct Spec {
    var name: String
    var short: Character?
    var long: String
    var negation: String?
    var value: String?
    var help: String
    var aliases: [String]
    var hidden: Bool
    var section: String?
  }

  public static func expansion(
    of node: AttributeSyntax,
    providingMembersOf declaration: some DeclGroupSyntax,
    conformingTo protocols: [TypeSyntax],
    in context: some MacroExpansionContext,
  ) throws -> [DeclSyntax] {
    guard let enumDecl = declaration.as(EnumDeclSyntax.self) else {
      context.diagnose(Diagnostic(node: node, message: Message.error("@CommandLineFlags only applies to enums")))
      return []
    }
    var specs: [Spec] = []
    var shorts: [Character: String] = [:]
    var longs: [String: String] = [:]
    var negations: [String: String] = [:]
    var failed = false
    func fail(_ node: some SyntaxProtocol, _ text: String) {
      context.diagnose(Diagnostic(node: node, message: Message.error(text)))
      failed = true
    }

    for member in enumDecl.memberBlock.members {
      guard let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
      guard caseDecl.elements.count == 1, let element = caseDecl.elements.first else {
        fail(caseDecl, "declare one flag per case")
        continue
      }
      let name = element.name.text
      var section: String? = nil
      var spelling: AttributeSyntax? = nil
      for case let .attribute(attribute) in caseDecl.attributes {
        switch attribute.attributeName.trimmedDescription {
        case "Section": section = stringArguments(attribute).first
        case "Spelling": spelling = attribute
        default: break
        }
      }
      guard let spelling else {
        fail(element, "flag '\(name)' needs a @Spelling")
        continue
      }
      var spec = Spec(name: name, short: nil, long: "", negation: nil, value: nil, help: "", aliases: [], hidden: false,
                      section: section)
      for argument in spelling.arguments?.as(LabeledExprListSyntax.self) ?? [] {
        let label = argument.label?.text
        switch label {
        case nil:
          guard let text = stringLiteral(argument.expression) else {
            fail(argument, "spellings must be string literals")
            continue
          }
          if text.hasPrefix("--"), text.count > 2 {
            spec.long = String(text.dropFirst(2))
          } else if text.hasPrefix("-"), text.count == 2 {
            spec.short = text.last
          } else {
            fail(argument, "'\(text)' is neither a short (-x) nor a long (--name) flag")
          }
        case "value": spec.value = stringLiteral(argument.expression)
        case "negation":
          guard let text = stringLiteral(argument.expression), text.hasPrefix("--"), text.count > 2 else {
            fail(argument, "a negation must be a long flag (--name)")
            continue
          }
          spec.negation = String(text.dropFirst(2))
        case "help": spec.help = stringLiteral(argument.expression) ?? ""
        case "hidden": spec.hidden = argument.expression.trimmedDescription == "true"
        case "aliases":
          let elements = argument.expression.as(ArrayExprSyntax.self)?.elements ?? []
          spec.aliases = elements.compactMap { stringLiteral($0.expression) }
        default:
          fail(argument, "unknown @Spelling argument '\(label ?? "")'")
        }
      }
      guard !spec.long.isEmpty else {
        fail(spelling, "flag '\(name)' needs a long spelling")
        continue
      }
      // Conflicts are reported, and the later spelling is dropped so the
      // generated members still compile and only the real error shows.
      if let short = spec.short {
        if let other = shorts[short] {
          fail(spelling, "-\(short) is already used by '\(other)'")
          spec.short = nil
        } else {
          shorts[short] = name
        }
      }
      if let other = longs[spec.long] {
        fail(spelling, "--\(spec.long) is already used by '\(other)'")
      }
      longs[spec.long] = longs[spec.long] ?? name
      spec.aliases = spec.aliases.filter { alias in
        if let other = longs[alias] {
          fail(spelling, "--\(alias) is already used by '\(other)'")
          return false
        }
        longs[alias] = name
        return true
      }
      if let negation = spec.negation {
        if let other = longs[negation] {
          fail(spelling, "--\(negation) is already used by '\(other)'")
          spec.negation = nil
        } else {
          longs[negation] = name
          negations[negation] = name
        }
      }
      specs.append(spec)
    }
    _ = failed

    let shortCases = specs.compactMap { s in s.short.map { "case .\(s.name): \(literal(String($0)))" } }
    let longCases = specs.map { "case .\($0.name): \(literal($0.long))" }
    let valueCases = specs.filter { $0.value != nil }.map { ".\($0.name)" }
    let byShort = specs.compactMap { s in s.short.map { "\(literal(String($0))): .\(s.name)" } }
    let byLong = longs.filter { negations[$0.key] == nil }.sorted { $0.key < $1.key }
      .map { "\(literal($0.key)): .\($0.value)" }
    let byNegation = negations.sorted { $0.key < $1.key }.map { "\(literal($0.key)): .\($0.value)" }
    func cases(_ value: (Spec) -> String?) -> String {
      specs.compactMap { spec in value(spec).map { "case .\(spec.name): \($0)" } }.joined(separator: "\n")
    }

    return [
      """
      /// The flag's short spelling, if any.
      var short: Character? {
        switch self {
        \(raw: shortCases.joined(separator: "\n"))
        default: nil
        }
      }
      """,
      """
      /// The flag's long spelling.
      var long: String {
        switch self {
        \(raw: longCases.joined(separator: "\n"))
        }
      }
      """,
      """
      /// Whether the flag takes a value.
      var takesValue: Bool {
        switch self {
        \(raw: valueCases.isEmpty ? "" : "case \(valueCases.joined(separator: ", ")): true")
        default: false
        }
      }
      """,
      """
      /// The spelling that turns the flag off again, if any.
      var negation: String? {
        switch self {
        \(raw: cases { $0.negation.map(literal) })
        default: nil
        }
      }
      """,
      """
      /// The name of the flag's value in the help, if it takes one.
      var valueName: String? {
        switch self {
        \(raw: cases { $0.value.map(literal) })
        default: nil
        }
      }
      """,
      """
      /// The flag's one-line description.
      var help: String {
        switch self {
        \(raw: cases { literal($0.help) })
        }
      }
      """,
      """
      /// Other long spellings of the flag.
      var aliases: [String] {
        switch self {
        \(raw: cases { $0.aliases.isEmpty ? nil : "[" + $0.aliases.map(literal).joined(separator: ", ") + "]" })
        default: []
        }
      }
      """,
      """
      /// The help section that starts at this flag, if any.
      var section: String? {
        switch self {
        \(raw: cases { $0.section.map(literal) })
        default: nil
        }
      }
      """,
      """
      /// Whether the flag is left out of `--help`.
      var isHidden: Bool {
        switch self {
        \(raw: cases { $0.hidden ? "true" : nil })
        default: false
        }
      }
      """,
      "static let declared: [Self] = [\(raw: specs.map { ".\($0.name)" }.joined(separator: ", "))]",
      "static let byShort: [Character: Self] = [\(raw: byShort.joined(separator: ", "))]",
      "static let byLong: [String: Self] = [\(raw: byLong.joined(separator: ", "))]",
      "static let byNegation: [String: Self] = [\(raw: byNegation.isEmpty ? ":" : byNegation.joined(separator: ", "))]",
      "static let optionsHelp: String = \(raw: literal(helpText(specs)))",
    ]
  }

  /// The options part of `--help`: sections in declaration order, one flag
  /// per line, descriptions aligned and wrapped.
  static func helpText(_ specs: [Spec]) -> String {
    let column = 30
    let width = 80
    var lines: [String] = []
    for spec in specs where !spec.hidden {
      if let section = spec.section {
        if !lines.isEmpty {
          lines.append("")
        }
        lines.append("\(section):")
      }
      var flag = spec.short.map { "    -\($0), " } ?? "        "
      flag += "--\(spec.long)"
      if let value = spec.value {
        flag += " \(value)"
      }
      var words = spec.help.split(separator: " ").map(String.init)
      var line = flag
      if line.count + 2 > column {
        lines.append(line)
        line = ""
      }
      while !words.isEmpty {
        line = line.padding(toLength: column)
        var text = ""
        while let word = words.first, column + text.count + word.count + (text.isEmpty ? 0 : 1) <= width || text.isEmpty {
          text += (text.isEmpty ? "" : " ") + word
          words.removeFirst()
        }
        lines.append(line + text)
        line = ""
      }
      if spec.help.isEmpty {
        lines.append(line)
      }
    }
    return lines.joined(separator: "\n")
  }

  private static func stringArguments(_ attribute: AttributeSyntax) -> [String] {
    (attribute.arguments?.as(LabeledExprListSyntax.self) ?? []).compactMap { stringLiteral($0.expression) }
  }

  private static func stringLiteral(_ expression: ExprSyntax) -> String? {
    guard let literal = expression.as(StringLiteralExprSyntax.self) else { return nil }
    var text = ""
    for segment in literal.segments {
      guard case let .stringSegment(part) = segment else { return nil }
      text += part.content.text
    }
    return text
  }

  /// A Swift string literal for `text`.
  private static func literal(_ text: String) -> String {
    var escaped = ""
    for scalar in text.unicodeScalars {
      switch scalar {
      case "\\": escaped += "\\\\"
      case "\"": escaped += "\\\""
      case "\n": escaped += "\\n"
      default: escaped.unicodeScalars.append(scalar)
      }
    }
    return "\"\(escaped)\""
  }

  enum Message: DiagnosticMessage {
    case error(String)
    var message: String {
      switch self {
      case let .error(text): text
      }
    }

    var diagnosticID: MessageID {
      MessageID(domain: "SwiftGrepMacros", id: "CommandLineFlags")
    }

    var severity: DiagnosticSeverity {
      .error
    }
  }
}

/// Marks a flag's spellings; read by `@CommandLineFlags`, expands to nothing.
public struct MarkerMacro: PeerMacro {
  public static func expansion(
    of node: AttributeSyntax,
    providingPeersOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext,
  ) throws -> [DeclSyntax] {
    []
  }
}

extension String {
  func padding(toLength length: Int) -> String {
    count >= length ? self : self + String(repeating: " ", count: length - count)
  }
}

@main
struct SwiftGrepMacrosPlugin: CompilerPlugin {
  let providingMacros: [any Macro.Type] = [CommandLineFlagsMacro.self, MarkerMacro.self]
}
