/// File type definitions for `-t`/`-T`: ripgrep's built-in table (from its
/// `default_types.rs`), one entry per name.
enum FileTypes {
  static let defaults: [(name: String, globs: [String])] = [
    ("ada", ["*.adb", "*.ads"]),
    ("agda", ["*.agda", "*.lagda"]),
    ("aidl", ["*.aidl"]),
    ("alire", ["alire.toml"]),
    ("amake", ["*.mk", "*.bp"]),
    ("asciidoc", ["*.adoc", "*.asc", "*.asciidoc"]),
    ("asm", ["*.asm", "*.s", "*.S"]),
    ("asp", ["*.aspx", "*.aspx.cs", "*.aspx.vb", "*.ascx", "*.ascx.cs", "*.ascx.vb", "*.asp"]),
    ("ats", ["*.ats", "*.dats", "*.sats", "*.hats"]),
    ("avro", ["*.avdl", "*.avpr", "*.avsc"]),
    ("awk", ["*.awk"]),
    ("bat", ["*.bat"]),
    ("batch", ["*.bat"]),
    ("bazel", [
      "*.bazel", "*.bzl", "*.BUILD", "*.bazelrc", "BUILD", "MODULE.bazel", "WORKSPACE", "WORKSPACE.bazel",
      "WORKSPACE.bzlmod",
    ]),
    ("bitbake", ["*.bb", "*.bbappend", "*.bbclass", "*.conf", "*.inc"]),
    ("boxlang", ["*.bx", "*.bxm", "*.bxs"]),
    ("brotli", ["*.br"]),
    ("buildstream", ["*.bst"]),
    ("bzip2", ["*.bz2", "*.tbz2"]),
    ("c", ["*.[chH]", "*.[chH].in", "*.cats"]),
    ("cabal", ["*.cabal"]),
    ("candid", ["*.did"]),
    ("carp", ["*.carp"]),
    ("cbor", ["*.cbor"]),
    ("ceylon", ["*.ceylon"]),
    ("cfml", ["*.cfc", "*.cfm"]),
    ("clojure", ["*.clj", "*.cljc", "*.cljs", "*.cljx"]),
    ("cmake", ["*.cmake", "CMakeLists.txt"]),
    ("cmd", ["*.bat", "*.cmd"]),
    ("cml", ["*.cml"]),
    ("coffeescript", ["*.coffee"]),
    ("config", ["*.cfg", "*.conf", "*.config", "*.ini"]),
    ("container", ["*Containerfile*", "*Dockerfile*"]),
    ("coq", ["*.v"]),
    ("cpp", [
      "*.[ChH]", "*.cc", "*.[ch]pp", "*.[ch]xx", "*.hh", "*.inl", "*.[ChH].in", "*.cc.in", "*.[ch]pp.in",
      "*.[ch]xx.in", "*.hh.in",
    ]),
    ("creole", ["*.creole"]),
    ("crystal", ["Projectfile", "*.cr", "*.ecr", "shard.yml"]),
    ("cs", ["*.cs"]),
    ("csharp", ["*.cs"]),
    ("cshtml", ["*.cshtml"]),
    ("csproj", ["*.csproj"]),
    ("css", ["*.css", "*.scss"]),
    ("csv", ["*.csv"]),
    ("cuda", ["*.cu", "*.cuh"]),
    ("cython", ["*.pyx", "*.pxi", "*.pxd"]),
    ("d", ["*.d"]),
    ("dart", ["*.dart"]),
    ("devicetree", ["*.dts", "*.dtsi", "*.dtso"]),
    ("dhall", ["*.dhall"]),
    ("diff", ["*.patch", "*.diff"]),
    ("dita", ["*.dita", "*.ditamap", "*.ditaval"]),
    ("docker", ["*Dockerfile*"]),
    ("dockercompose", ["docker-compose.yml", "docker-compose.*.yml"]),
    ("dts", ["*.dts", "*.dtsi"]),
    ("dvc", ["Dvcfile", "*.dvc"]),
    ("ebuild", ["*.ebuild", "*.eclass"]),
    ("edn", ["*.edn"]),
    ("elisp", ["*.el"]),
    ("elixir", ["*.ex", "*.eex", "*.exs", "*.heex", "*.leex", "*.livemd"]),
    ("elm", ["*.elm"]),
    ("erb", ["*.erb"]),
    ("erlang", ["*.erl", "*.hrl"]),
    ("fennel", ["*.fnl"]),
    ("fidl", ["*.fidl"]),
    ("fish", ["*.fish"]),
    ("flatbuffers", ["*.fbs"]),
    ("fortran", ["*.f", "*.F", "*.f77", "*.F77", "*.pfo", "*.f90", "*.F90", "*.f95", "*.F95"]),
    ("fsharp", ["*.fs", "*.fsx", "*.fsi"]),
    ("fut", ["*.fut"]),
    ("gap", ["*.g", "*.gap", "*.gi", "*.gd", "*.tst"]),
    ("gdscript", ["*.gd"]),
    ("gleam", ["*.gleam"]),
    ("gn", ["*.gn", "*.gni"]),
    ("go", ["*.go"]),
    ("gprbuild", ["*.gpr"]),
    ("gradle", ["*.gradle", "*.gradle.kts", "gradle.properties", "gradle-wrapper.*", "gradlew", "gradlew.bat"]),
    ("graphql", ["*.graphql", "*.graphqls"]),
    ("groovy", ["*.groovy", "*.gradle"]),
    ("gzip", ["*.gz", "*.tgz"]),
    ("h", ["*.h", "*.hh", "*.hpp"]),
    ("haml", ["*.haml"]),
    ("hare", ["*.ha"]),
    ("haskell", ["*.hs", "*.lhs", "*.cpphs", "*.c2hs", "*.hsc"]),
    ("hbs", ["*.hbs"]),
    ("hs", ["*.hs", "*.lhs"]),
    ("html", ["*.htm", "*.html", "*.ejs"]),
    ("hurl", ["*.hurl"]),
    ("hy", ["*.hy"]),
    ("idris", ["*.idr", "*.lidr"]),
    ("janet", ["*.janet"]),
    ("java", ["*.java", "*.jsp", "*.jspx", "*.properties"]),
    ("jinja", ["*.j2", "*.jinja", "*.jinja2"]),
    ("jl", ["*.jl"]),
    ("js", ["*.js", "*.jsx", "*.vue", "*.cjs", "*.mjs"]),
    ("json", ["*.json", "composer.lock", "*.sarif"]),
    ("jsonl", ["*.jsonl"]),
    ("julia", ["*.jl"]),
    ("jupyter", ["*.ipynb", "*.jpynb"]),
    ("k", ["*.k"]),
    ("kconfig", ["Kconfig", "Kconfig.*"]),
    ("kotlin", ["*.kt", "*.kts"]),
    ("lean", ["*.lean"]),
    ("less", ["*.less"]),
    ("license", [
      "COPYING", "COPYING[.-]*", "COPYRIGHT", "COPYRIGHT[.-]*", "EULA", "EULA[.-]*", "licen[cs]e", "licen[cs]e.*",
      "LICEN[CS]E", "LICEN[CS]E[.-]*", "*[.-]LICEN[CS]E*", "NOTICE", "NOTICE[.-]*", "PATENTS", "PATENTS[.-]*",
      "UNLICEN[CS]E", "UNLICEN[CS]E[.-]*", "agpl[.-]*", "gpl[.-]*", "lgpl[.-]*", "AGPL-*[0-9]*", "APACHE-*[0-9]*",
      "BSD-*[0-9]*", "CC-BY-*", "GFDL-*[0-9]*", "GNU-*[0-9]*", "GPL-*[0-9]*", "LGPL-*[0-9]*", "MIT-*[0-9]*",
      "MPL-*[0-9]*", "OFL-*[0-9]*",
    ]),
    ("lilypond", ["*.ly", "*.ily"]),
    ("lisp", ["*.el", "*.jl", "*.lisp", "*.lsp", "*.sc", "*.scm"]),
    ("llvm", ["*.ll"]),
    ("lock", ["*.lock", "package-lock.json"]),
    ("log", ["*.log"]),
    ("lua", ["*.lua"]),
    ("lz4", ["*.lz4"]),
    ("lzma", ["*.lzma"]),
    ("m4", ["*.ac", "*.m4"]),
    ("make", [
      "[Gg][Nn][Uu]makefile", "[Mm]akefile", "[Gg][Nn][Uu]makefile.am", "[Mm]akefile.am", "[Gg][Nn][Uu]makefile.in",
      "[Mm]akefile.in", "Makefile.*", "*.mk", "*.mak",
    ]),
    ("mako", ["*.mako", "*.mao"]),
    ("man", ["*.[0-9lnpx]", "*.[0-9][cEFMmpSx]"]),
    ("markdown", ["*.markdown", "*.md", "*.mdown", "*.mdwn", "*.mkd", "*.mkdn", "*.mdx"]),
    ("md", ["*.markdown", "*.md", "*.mdown", "*.mdwn", "*.mkd", "*.mkdn", "*.mdx"]),
    ("matlab", ["*.m"]),
    ("meson", ["meson.build", "meson_options.txt", "meson.options"]),
    ("minified", ["*.min.html", "*.min.css", "*.min.js"]),
    ("mint", ["*.mint"]),
    ("mk", ["mkfile"]),
    ("ml", ["*.ml"]),
    ("mojo", ["*.mojo"]),
    ("motoko", ["*.mo"]),
    ("msbuild", ["*.csproj", "*.fsproj", "*.vcxproj", "*.proj", "*.props", "*.targets", "*.sln", "*.slnf"]),
    ("nim", ["*.nim", "*.nimf", "*.nimble", "*.nims"]),
    ("nix", ["*.nix"]),
    ("objc", ["*.h", "*.m"]),
    ("objcpp", ["*.h", "*.mm"]),
    ("ocaml", ["*.ml", "*.mli", "*.mll", "*.mly"]),
    ("org", ["*.org", "*.org_archive"]),
    ("pants", ["BUILD"]),
    ("pascal", ["*.pas", "*.dpr", "*.lpr", "*.pp", "*.inc"]),
    ("pdf", ["*.pdf"]),
    ("perl", ["*.perl", "*.pl", "*.PL", "*.plh", "*.plx", "*.pm", "*.t"]),
    ("php", ["*.php", "*.php3", "*.php4", "*.php5", "*.php7", "*.php8", "*.pht", "*.phtml"]),
    ("pkgbuild", ["PKGBUILD"]),
    ("po", ["*.po"]),
    ("pod", ["*.pod"]),
    ("postscript", ["*.eps", "*.ps"]),
    ("prolog", ["*.pl", "*.pro", "*.prolog", "*.P"]),
    ("proto", ["*.proto"]),
    ("protobuf", ["*.proto"]),
    ("ps", ["*.cdxml", "*.ps1", "*.ps1xml", "*.psd1", "*.psm1"]),
    ("puppet", ["*.epp", "*.erb", "*.pp", "*.rb"]),
    ("purs", ["*.purs"]),
    ("py", ["*.py", "*.pyi"]),
    ("python", ["*.py", "*.pyi"]),
    ("qmake", ["*.pro", "*.pri", "*.prf"]),
    ("qml", ["*.qml"]),
    ("qrc", ["*.qrc"]),
    ("qui", ["*.ui"]),
    ("r", ["*.R", "*.r", "*.Rmd", "*.rmd", "*.Rnw", "*.rnw"]),
    ("racket", ["*.rkt"]),
    ("raku", ["*.raku", "*.rakumod", "*.rakudoc", "*.rakutest", "*.p6", "*.pl6", "*.pm6"]),
    ("rdoc", ["*.rdoc"]),
    ("readme", ["README*", "*README"]),
    ("reasonml", ["*.re", "*.rei"]),
    ("red", ["*.r", "*.red", "*.reds"]),
    ("rescript", ["*.res", "*.resi"]),
    ("robot", ["*.robot"]),
    ("rocq", ["*.v"]),
    ("rst", ["*.rst"]),
    ("ruby", ["config.ru", "Gemfile", ".irbrc", "Rakefile", "*.gemspec", "*.rb", "*.rbw", "*.rake"]),
    ("rust", ["*.rs"]),
    ("sass", ["*.sass", "*.scss"]),
    ("scala", ["*.scala", "*.sbt"]),
    ("scdoc", ["*.scd", "*.scdoc"]),
    ("seed7", ["*.sd7", "*.s7i"]),
    ("sh", [
      ".env", ".login", ".logout", ".profile", "profile", ".bash_login", "bash_login", ".bash_logout", "bash_logout",
      ".bash_profile", "bash_profile", ".bashrc", "bashrc", "*.bashrc", ".cshrc", "*.cshrc", ".kshrc", "*.kshrc",
      ".tcshrc", ".zshenv", "zshenv", ".zlogin", "zlogin", ".zlogout", "zlogout", ".zprofile", "zprofile", ".zshrc",
      "zshrc", "*.bash", "*.csh", "*.env", "*.ksh", "*.sh", "*.tcsh", "*.zsh",
    ]),
    ("slim", ["*.skim", "*.slim", "*.slime"]),
    ("smarty", ["*.tpl"]),
    ("sml", ["*.sml", "*.sig"]),
    ("solidity", ["*.sol"]),
    ("soy", ["*.soy"]),
    ("spark", ["*.spark"]),
    ("spec", ["*.spec"]),
    ("sql", ["*.sql", "*.psql"]),
    ("ssa", ["*.ssa"]),
    ("stylus", ["*.styl"]),
    ("sv", ["*.v", "*.vg", "*.sv", "*.svh", "*.h"]),
    ("svelte", ["*.svelte", "*.svelte.ts"]),
    ("svg", ["*.svg"]),
    ("swift", ["*.swift"]),
    ("swig", ["*.def", "*.i"]),
    ("systemd", [
      "*.automount", "*.conf", "*.device", "*.link", "*.mount", "*.path", "*.scope", "*.service", "*.slice",
      "*.socket", "*.swap", "*.target", "*.timer",
    ]),
    ("taskpaper", ["*.taskpaper"]),
    ("tcl", ["*.tcl"]),
    ("tex", ["*.tex", "*.ltx", "*.cls", "*.sty", "*.bib", "*.dtx", "*.ins"]),
    ("texinfo", ["*.texi"]),
    ("textile", ["*.textile"]),
    ("tf", [
      "*.tf", "*.tf.json", "*.tfvars", "*.tfvars.json", "*.terraformrc", "terraform.rc", "*.tfrc",
      "*.terraform.lock.hcl",
    ]),
    ("thrift", ["*.thrift"]),
    ("toml", ["*.toml", "Cargo.lock"]),
    ("ts", ["*.ts", "*.tsx", "*.cts", "*.mts"]),
    ("typescript", ["*.ts", "*.tsx", "*.cts", "*.mts"]),
    ("twig", ["*.twig"]),
    ("txt", ["*.txt"]),
    ("typoscript", ["*.typoscript", "*.ts"]),
    ("typst", ["*.typ"]),
    ("usd", ["*.usd", "*.usda", "*.usdc"]),
    ("v", ["*.v", "*.vsh"]),
    ("vala", ["*.vala"]),
    ("vb", ["*.vb"]),
    ("vcl", ["*.vcl"]),
    ("verilog", ["*.v", "*.vh", "*.sv", "*.svh"]),
    ("vhdl", ["*.vhd", "*.vhdl"]),
    ("vim", ["*.vim", ".vimrc", ".gvimrc", "vimrc", "gvimrc", "_vimrc", "_gvimrc"]),
    ("vimscript", ["*.vim", ".vimrc", ".gvimrc", "vimrc", "gvimrc", "_vimrc", "_gvimrc"]),
    ("vue", ["*.vue"]),
    ("webidl", ["*.idl", "*.webidl", "*.widl"]),
    ("wgsl", ["*.wgsl"]),
    ("wiki", ["*.mediawiki", "*.wiki"]),
    ("xml", ["*.xml", "*.xml.dist", "*.dtd", "*.xsl", "*.xslt", "*.xsd", "*.xjb", "*.rng", "*.sch", "*.xhtml"]),
    ("xz", ["*.xz", "*.txz"]),
    ("yacc", ["*.y"]),
    ("yaml", ["*.yaml", "*.yml"]),
    ("yang", ["*.yang"]),
    ("z", ["*.Z"]),
    ("zig", ["*.zig"]),
    ("zsh", [
      ".zshenv", "zshenv", ".zlogin", "zlogin", ".zlogout", "zlogout", ".zprofile", "zprofile", ".zshrc", "zshrc",
      "*.zsh",
    ]),
    ("zstd", ["*.zst", "*.zstd"]),
  ]

  /// The definitions after applying `--type-add` and `--type-clear` in
  /// order, and the `-t`/`-T` selections (`all` stands for every type
  /// defined at that point).
  static func resolve(_ changes: [TypeChange]) throws(UsageError) -> (table: [String: [String]], selections: [(String, Bool)]) {
    var table: [String: [String]] = [:]
    for (name, globs) in defaults {
      table[name, default: []].append(contentsOf: globs)
    }
    var selections: [(name: String, selected: Bool)] = []
    for change in changes {
      switch change {
      case let .add(definition): try add(definition, to: &table)
      case let .clear(name): table[name] = nil
      case let .select(name), let .negate(name):
        let selected = if case .select = change {
          true
        } else {
          false
        }
        if name == "all" {
          selections += table.keys.map { ($0, selected) }
        } else {
          selections.append((name, selected))
        }
      }
    }
    return (table, selections)
  }

  /// `name:glob` or `name:include:type,...`.
  private static func add(_ definition: String, to table: inout [String: [String]]) throws(UsageError) {
    let invalid = UsageError("invalid definition (format is type:glob, e.g., html:*.html)")
    let parts = definition.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    func add(_ name: String, _ glob: String) throws(UsageError) {
      guard name != "all", name.allSatisfy({ $0.isLetter || $0.isNumber }) else { throw invalid }
      table[name, default: []].append(glob)
    }
    switch parts.count {
    case 2:
      guard !parts[0].isEmpty, !parts[1].isEmpty else { throw invalid }
      try add(parts[0], parts[1])
    case 3:
      guard !parts[0].isEmpty, parts[1] == "include", !parts[2].isEmpty else { throw invalid }
      let included = parts[2].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
      guard included.allSatisfy({ table[$0] != nil }) else { throw invalid }
      for other in included {
        for glob in table[other] ?? [] {
          try add(parts[0], glob)
        }
      }
    default:
      throw invalid
    }
  }
}

/// Decides which files pass `-t`/`-T`: the last selection with a glob that
/// matches the file name decides, and with any `-t`, files no selection
/// matches are skipped.
struct TypeMatcher: Sendable {
  /// One rule per glob of each selection, in order; selected types are
  /// whitelisting rules.
  let rules: IgnoreRules
  let hasSelected: Bool

  /// Returns nil if no type is selected or negated.
  init?(_ changes: [TypeChange]) throws(UsageError) {
    // The table is only built when it's needed: it costs startup time.
    guard changes.contains(where: {
      if case .select = $0 {
        true
      } else if case .negate = $0 {
        true
      } else {
        false
      }
    })
    else { return nil }
    let (table, selections) = try FileTypes.resolve(changes)
    guard !selections.isEmpty else { return nil }
    var rules: [IgnoreRule] = []
    for (name, selected) in selections {
      guard let globs = table[name] else { throw UsageError("unrecognized file type: \(name)") }
      for glob in globs {
        // Type globs are matched against the file name.
        let parsed: Glob
        do {
          parsed = try Glob(parsing: Array(glob.utf8), anchored: true, caseInsensitive: false)
        } catch {
          throw UsageError("error parsing glob '\(glob)': \(error.message)")
        }
        rules.append(IgnoreRule(glob: parsed, negated: selected, directoryOnly: false))
      }
    }
    self.rules = IgnoreRules(rules: rules)
    hasSelected = selections.contains { $0.1 }
  }

  func match(name: Span<UInt8>) -> IgnoreMatch {
    switch rules.match(name, nameStart: 0, isDirectory: false) {
    case .none: hasSelected ? .ignore : .none
    case let result: result
    }
  }

  /// `--type-list`: each type with its globs, both sorted.
  static func listing(_ changes: [TypeChange]) throws(UsageError) -> String {
    let (table, _) = try FileTypes.resolve(changes)
    return table.keys.sorted().map { "\($0): \(table[$0]!.sorted().joined(separator: ", "))\n" }.joined()
  }
}

/// A command line usage error.
public struct UsageError: Error, CustomStringConvertible {
  public let description: String
  public init(_ message: String) {
    description = message
  }
}
