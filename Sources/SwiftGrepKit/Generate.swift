/// `--generate`: a man page and shell completions, built from the flag table
/// that `--help` comes from.
enum Generator {
  static func output(_ kind: GenerateKind) -> String {
    switch kind {
    case .man: manPage()
    case .bash: bash()
    case .zsh: zsh()
    case .fish: fish()
    case .powershell: powershell()
    }
  }

  private static var flags: [Flag] {
    Flag.declared.filter { !$0.isHidden }
  }

  /// How a flag's value is completed.
  private enum ValueKind {
    case file, command, type, other
    case choices([String])
  }

  private static func valueKind(_ flag: Flag) -> ValueKind? {
    switch flag.valueName {
    case nil: nil
    case "PATH", "PATTERNFILE": .file
    case "COMMAND": .command
    case "TYPE": .type
    case "WHEN": .choices(["never", "auto", "always", "ansi"])
    case "ENGINE": .choices(["default", "auto"])
    case "SORTBY": .choices(["none", "path", "modified", "accessed", "created"])
    case "KIND": .choices(["man", "complete-bash", "complete-zsh", "complete-fish", "complete-powershell"])
    case "FORMAT": .choices(HyperlinkFormat.aliases.map(\.name))
    case "ENCODING": .choices(Encodings.byLabel.keys.sorted())
    default: .other
    }
  }

  /// Every spelling of the flag, with dashes.
  private static func spellings(_ flag: Flag, negation: Bool = true) -> [String] {
    var result = flag.short.map { ["-\($0)"] } ?? []
    result.append("--" + flag.long)
    result += flag.aliases.map { "--" + $0 }
    if negation, let negated = flag.negation {
      result.append("--" + negated)
    }
    return result
  }

  // MARK: - Man page

  private static func manPage() -> String {
    var page = """
    .TH SG 1 "" "sg \(SwiftGrep.version)" "User Commands"
    .SH NAME
    sg \\- recursively search the current directory for lines matching a pattern
    .SH SYNOPSIS
    .B sg
    [\\fIOPTIONS\\fP] \\fIPATTERN\\fP [\\fIPATH\\fP...]
    .br
    .B sg
    [\\fIOPTIONS\\fP] \\fB\\-e\\fP \\fIPATTERN\\fP... [\\fIPATH\\fP...]
    .br
    .B sg
    [\\fIOPTIONS\\fP] \\fB\\-f\\fP \\fIPATTERNFILE\\fP... [\\fIPATH\\fP...]
    .br
    .B sg
    [\\fIOPTIONS\\fP] \\fB\\-\\-files\\fP [\\fIPATH\\fP...]
    .br
    .B sg
    [\\fIOPTIONS\\fP] \\fB\\-\\-type\\-list\\fP
    .SH DESCRIPTION
    SwiftGrep (sg) is a ripgrep-compatible recursive search tool, tuned for
    APFS. It searches the current directory for lines matching a regex
    pattern, respecting gitignore rules and skipping hidden files, hidden
    directories and binary files by default. Its output, exit status and
    flags are those of ripgrep.
    .PP
    With no \\fIPATH\\fP, sg searches the current directory, or standard
    input when it is a pipe or a file.
    .PP
    Switches are turned off again by their negation, as in ripgrep: for
    example, \\fB\\-\\-no\\-heading\\fP undoes \\fB\\-\\-heading\\fP.
    .SH OPTIONS

    """
    for flag in flags {
      if let section = flag.section {
        page += ".SS \(roff(section)) OPTIONS\n"
      }
      var names = spellings(flag, negation: false).map { "\\fB\(roff($0))\\fP" }.joined(separator: ", ")
      if let value = flag.valueName {
        names += "=\\fI\(roff(value))\\fP"
      }
      page += ".TP\n\(names)\n\(roff(flag.help)).\n"
      if let negated = flag.negation {
        page += ".IP\nTurned off by \\fB\(roff("--" + negated))\\fP.\n"
      }
    }
    page += """
    .SH EXIT STATUS
    0 if a line matched, 1 if none did, and 2 if an error occurred (unless
    \\fB\\-q\\fP was given and a line matched).
    .SH CONFIGURATION FILE
    Like ripgrep, sg reads flags from the file named by
    \\fBRIPGREP_CONFIG_PATH\\fP before those on the command line: one flag
    or value per line, ignoring blank lines and lines starting with
    \\fB#\\fP. \\fB\\-\\-no\\-config\\fP turns this off.
    .SH CACHE
    sg caches directory listings, validated by one \\fBstat\\fP per
    directory. \\fB\\-\\-no\\-cache\\fP skips the cache for one search, and
    \\fB\\-\\-clear\\-cache\\fP deletes it.
    .SH SEE ALSO
    .BR rg (1)

    """
    return page
  }

  /// Escapes text for roff: backslashes and dashes, and a leading dot or
  /// quote that would start a request.
  private static func roff(_ text: String) -> String {
    var result = ""
    for character in text {
      switch character {
      case "\\": result += "\\e"
      case "-": result += "\\-"
      default: result.append(character)
      }
    }
    if result.hasPrefix(".") || result.hasPrefix("'") {
      result = "\\&" + result
    }
    return result
  }

  // MARK: - bash

  private static func bash() -> String {
    var cases = ""
    for flag in flags {
      guard let kind = valueKind(flag) else { continue }
      let reply = switch kind {
      case .file: #"COMPREPLY=($(compgen -f -- "${cur}"))"#
      case .command: #"COMPREPLY=($(compgen -c -- "${cur}"))"#
      case .type: #"COMPREPLY=($(compgen -W "$(sg --type-list 2>/dev/null | cut -d: -f1)" -- "${cur}"))"#
      case let .choices(choices): #"COMPREPLY=($(compgen -W ""# + choices.joined(separator: " ") + #"" -- "${cur}"))"#
      case .other: "COMPREPLY=()"
      }
      cases += """
          \(spellings(flag, negation: false).joined(separator: "|")))
            \(reply)
            return 0
            ;;

      """
    }
    let options = flags.flatMap { spellings($0) }.joined(separator: " ")
    return """
    _sg() {
      local cur prev
      COMPREPLY=()
      cur="${COMP_WORDS[COMP_CWORD]}"
      prev="${COMP_WORDS[COMP_CWORD-1]}"
      case "${prev}" in
    \(cases)  esac
      if [[ ${cur} == -* ]]; then
        COMPREPLY=($(compgen -W "\(options)" -- "${cur}"))
      fi
      return 0
    }

    complete -F _sg -o bashdefault -o default sg

    """
  }

  // MARK: - zsh

  private static func zsh() -> String {
    var arguments: [String] = []
    for flag in flags {
      let names = spellings(flag, negation: false)
      let help = zshQuoted("[" + flag.help.escaping(["[", "]"], with: "\\") + "]")
      guard let kind = valueKind(flag) else {
        let exclusive = "(" + names.joined(separator: " ") + ")"
        let form = names.count == 1 ? names[0] : "{" + names.joined(separator: ",") + "}"
        arguments.append("'\(exclusive)'\(form)\(help)")
        if let negated = flag.negation {
          arguments.append(zshQuoted("--\(negated)[Turn off --\(flag.long)]"))
        }
        continue
      }
      let action = switch kind {
      case .file: "_files"
      case .command: "_command_names -e"
      case .type: "_sg_types"
      case let .choices(choices): "(" + choices.joined(separator: " ") + ")"
      case .other: " "
      }
      let value = zshQuoted(":\(flag.valueName ?? "value"):\(action)")
      let forms = names.map { $0.hasPrefix("--") ? $0 + "=" : $0 + "+" }
      let form = forms.count == 1 ? forms[0] : "{" + forms.joined(separator: ",") + "}"
      arguments.append("'*'\(form)\(help)\(value)")
      if let negated = flag.negation {
        arguments.append(zshQuoted("--\(negated)[Turn off --\(flag.long)]"))
      }
    }
    arguments.append(zshQuoted(#"(-e --regexp -f --file --files --type-list)1: :_guard "^-*" "search pattern""#))
    arguments.append(zshQuoted("*:file or directory to search:_files"))
    return """
    #compdef sg

    _sg() {
      local -a args=(
        \(arguments.joined(separator: "\n    "))
      )
      _arguments -s -S : $args
    }

    (( $+functions[_sg_types] )) ||
    _sg_types() {
      local -a types=( ${(f)"$( _call_program types $words[1] --type-list )"} )
      types=( ${types%%:*} )
      _describe -t types 'file type' types "$@"
    }

    _sg "$@"

    """
  }

  /// Single-quotes text for zsh.
  private static func zshQuoted(_ text: String) -> String {
    "'" + text.replacingAll("'", with: #"'\''"#) + "'"
  }

  // MARK: - fish

  private static func fish() -> String {
    var script = """
    # Usage: __sg_contains_opt LONG [SHORT]
    function __sg_contains_opt --description 'Whether the command line has the option'
        if not set -q __sg_config
            set -g __sg_config
            if set -qx RIPGREP_CONFIG_PATH
                set __sg_config (
                    cat -- $RIPGREP_CONFIG_PATH 2>/dev/null \\
                    | string trim \\
                    | string match -rv '^$|^#'
                )
            end
        end

        set -l commandline (commandline -cpo) (commandline -ct) $__sg_config

        if contains -- "--$argv[1]" $commandline
            return 0
        end

        if set -q argv[2]
            if string match -qr -- "^-[^-]*$argv[2]" $commandline
                return 0
            end
        end

        return 1
    end


    """
    for flag in flags {
      let doc = flag.help.escaping(["'"], with: "\\")
      var line = "complete -c sg"
      if let short = flag.short {
        line += " -s \(short)"
      }
      line += " -l \(flag.long) -d '\(doc)'"
      switch valueKind(flag) {
      case nil: break
      case .file: line += " -r -F"
      case .command: line += " -r -f -a '(__fish_complete_command)'"
      case .type: line += #" -r -f -a '(sg --type-list | string replace : \t)'"#
      case let .choices(choices): line += " -r -f -a '\(choices.joined(separator: " "))'"
      case .other: line += " -r -f"
      }
      script += line + "\n"
      for alias in flag.aliases {
        script += "complete -c sg -l \(alias) -d '\(doc)'\n"
      }
      if let negated = flag.negation {
        let short = flag.short.map { " \($0)" } ?? ""
        script += "complete -c sg -l \(negated) -n '__sg_contains_opt \(flag.long)\(short)' -d '\(doc)'\n"
      }
    }
    return script
  }

  // MARK: - PowerShell

  private static func powershell() -> String {
    var results: [String] = []
    for flag in flags {
      let doc = flag.help.replacingAll("'", with: "''")
      for dashed in spellings(flag) {
        let name = dashed.drop { $0 == "-" }
        results.append(
          "[CompletionResult]::new('\(dashed)', '\(name)', [CompletionResultType]::ParameterName, '\(doc)')",
        )
      }
    }
    return """
    using namespace System.Management.Automation
    using namespace System.Management.Automation.Language

    Register-ArgumentCompleter -Native -CommandName 'sg' -ScriptBlock {
      param($wordToComplete, $commandAst, $cursorPosition)
      $completions = @(
        \(results.joined(separator: "\n    "))
      )
      $completions.Where{ $_.CompletionText -like "$wordToComplete*" } |
        Sort-Object -Property ListItemText
    }

    """
  }
}

private extension String {
  func replacingAll(_ character: Character, with replacement: String) -> String {
    var result = ""
    for c in self {
      if c == character {
        result += replacement
      } else {
        result.append(c)
      }
    }
    return result
  }

  /// Puts `escape` before each of `characters`.
  func escaping(_ characters: Set<Character>, with escape: String) -> String {
    var result = ""
    for c in self {
      if characters.contains(c) {
        result += escape
      }
      result.append(c)
    }
    return result
  }
}
