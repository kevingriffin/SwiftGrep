/// File type definitions for `-t`/`-T`, a subset of ripgrep's defaults.
enum FileTypes {
  static let defaults: [(name: String, globs: [String])] = [
    ("agda", ["*.agda", "*.lagda"]),
    ("asm", ["*.asm", "*.s", "*.S"]),
    ("awk", ["*.awk"]),
    ("bazel", ["*.bazel", "*.bzl", "*.BUILD", "*.bazelrc", "BUILD", "MODULE.bazel", "WORKSPACE", "WORKSPACE.bazel"]),
    ("c", ["*.[chH]", "*.[chH].in", "*.cats"]),
    ("clojure", ["*.clj", "*.cljc", "*.cljs", "*.cljx"]),
    ("cmake", ["*.cmake", "CMakeLists.txt"]),
    ("config", ["*.cfg", "*.conf", "*.config", "*.ini"]),
    ("cpp", ["*.[ChH]", "*.cc", "*.[ch]pp", "*.[ch]xx", "*.hh", "*.inl", "*.[ChH].in", "*.cc.in", "*.[ch]pp.in", "*.[ch]xx.in", "*.hh.in"]),
    ("crystal", ["Projectfile", "*.cr", "*.ecr", "shard.yml"]),
    ("cs", ["*.cs"]),
    ("csharp", ["*.cs"]),
    ("css", ["*.css", "*.scss"]),
    ("csv", ["*.csv"]),
    ("cuda", ["*.cu", "*.cuh"]),
    ("d", ["*.d"]),
    ("dart", ["*.dart"]),
    ("diff", ["*.patch", "*.diff"]),
    ("docker", ["*Dockerfile*"]),
    ("dockercompose", ["docker-compose.yml", "docker-compose.*.yml"]),
    ("elixir", ["*.ex", "*.eex", "*.exs", "*.heex", "*.leex", "*.livemd"]),
    ("elm", ["*.elm"]),
    ("erlang", ["*.erl", "*.hrl"]),
    ("fish", ["*.fish"]),
    ("fsharp", ["*.fs", "*.fsx", "*.fsi"]),
    ("go", ["*.go"]),
    ("gradle", ["*.gradle", "*.gradle.kts"]),
    ("graphql", ["*.graphql", "*.graphqls"]),
    ("groovy", ["*.groovy", "*.gradle"]),
    ("h", ["*.h", "*.hh", "*.hpp"]),
    ("haskell", ["*.hs", "*.lhs", "*.cpphs", "*.c2hs", "*.hsc"]),
    ("hcl", ["*.hcl", "*.tf", "*.tfvars"]),
    ("html", ["*.htm", "*.html", "*.ejs"]),
    ("java", ["*.java", "*.jsp", "*.jspx", "*.properties"]),
    ("js", ["*.js", "*.jsx", "*.vue", "*.cjs", "*.mjs"]),
    ("json", ["*.json", "composer.lock", "*.sarif"]),
    ("jsonl", ["*.jsonl"]),
    ("julia", ["*.jl"]),
    ("jupyter", ["*.ipynb", "*.jpynb"]),
    ("kotlin", ["*.kt", "*.kts"]),
    ("less", ["*.less"]),
    ("license", ["COPYING", "COPYING[.-]*", "COPYRIGHT", "COPYRIGHT[.-]*", "EULA", "EULA[.-]*", "licen[cs]e", "licen[cs]e.*", "LICEN[CS]E", "LICEN[CS]E[.-]*", "*[.-]LICEN[CS]E*", "NOTICE", "NOTICE[.-]*", "PATENTS", "PATENTS[.-]*", "UNLICEN[CS]E", "UNLICEN[CS]E[.-]*"]),
    ("lisp", ["*.el", "*.jl", "*.lisp", "*.lsp", "*.sc", "*.scm"]),
    ("lua", ["*.lua"]),
    ("make", ["[Gg][Nn][Uu]makefile", "[Mm]akefile", "[Gg][Nn][Uu]makefile.am", "[Mm]akefile.am", "[Gg][Nn][Uu]makefile.in", "[Mm]akefile.in", "*.mk", "*.mak"]),
    ("markdown", ["*.markdown", "*.md", "*.mdown", "*.mdwn", "*.mkd", "*.mkdn", "*.mdx"]),
    ("md", ["*.markdown", "*.md", "*.mdown", "*.mdwn", "*.mkd", "*.mkdn", "*.mdx"]),
    ("meson", ["meson.build", "meson_options.txt", "meson.options"]),
    ("nim", ["*.nim", "*.nimf", "*.nimble", "*.nims"]),
    ("nix", ["*.nix"]),
    ("objc", ["*.h", "*.m"]),
    ("objcpp", ["*.h", "*.mm"]),
    ("ocaml", ["*.ml", "*.mli", "*.mll", "*.mly"]),
    ("perl", ["*.perl", "*.pl", "*.PL", "*.plh", "*.plx", "*.pm", "*.t"]),
    ("php", ["*.php", "*.php3", "*.php4", "*.php5", "*.php7", "*.php8", "*.pht", "*.phtml"]),
    ("protobuf", ["*.proto"]),
    ("ps", ["*.cdxml", "*.ps1", "*.ps1xml", "*.psd1", "*.psm1"]),
    ("py", ["*.py", "*.pyi"]),
    ("python", ["*.py", "*.pyi"]),
    ("r", ["*.R", "*.r", "*.Rmd", "*.Rnw"]),
    ("rst", ["*.rst"]),
    ("ruby", ["config.ru", "Gemfile", ".irbrc", "Rakefile", "*.gemspec", "*.rb", "*.rbw"]),
    ("rust", ["*.rs"]),
    ("sass", ["*.sass", "*.scss"]),
    ("scala", ["*.scala", "*.sbt"]),
    ("sh", ["*.bash", "*.bashrc", ".bashrc", ".bash_login", ".bash_logout", ".bash_profile", "*.csh", ".cshrc", "*.ksh", ".kshrc", "*.sh", ".login", ".logout", ".profile", "*.tcsh", "*.zsh", ".zshenv", ".zlogin", ".zlogout", ".zprofile", ".zshrc", "zshenv", "zlogin", "zlogout", "zprofile", "zshrc"]),
    ("sql", ["*.sql", "*.psql"]),
    ("svelte", ["*.svelte"]),
    ("swift", ["*.swift"]),
    ("tex", ["*.tex", "*.ltx", "*.cls", "*.sty", "*.bib", "*.dtx", "*.ins"]),
    ("toml", ["*.toml", "Cargo.lock"]),
    ("ts", ["*.ts", "*.tsx", "*.cts", "*.mts"]),
    ("typescript", ["*.ts", "*.tsx", "*.cts", "*.mts"]),
    ("txt", ["*.txt"]),
    ("vim", ["*.vim", ".vimrc", ".gvimrc", "vimrc", "gvimrc", "_vimrc", "_gvimrc"]),
    ("xml", ["*.xml", "*.xml.dist", "*.dtd", "*.xsl", "*.xslt", "*.xsd", "*.xjb", "*.rng", "*.sch", "*.xhtml"]),
    ("yaml", ["*.yaml", "*.yml"]),
    ("zig", ["*.zig"]),
    ("zsh", [".zshenv", ".zlogin", ".zlogout", ".zprofile", ".zshrc", "zshenv", "zlogin", "zlogout", "zprofile", "zshrc", "*.zsh"]),
  ]

  /// All definitions after applying `--type-add name:glob[,glob]` entries.
  static func definitions(adding additions: [String]) throws(UsageError) -> [String: [String]] {
    var table: [String: [String]] = [:]
    for (name, globs) in defaults { table[name] = globs }
    for addition in additions {
      guard let colon = addition.firstIndex(of: ":") else {
        throw UsageError("invalid definition (format is type:glob, e.g., html:*.html): \(addition)")
      }
      let name = String(addition[..<colon])
      let rest = addition[addition.index(after: colon)...]
      if rest.hasPrefix("include:") {
        for other in rest.dropFirst("include:".count).split(separator: ",") {
          table[name, default: []].append(contentsOf: table[String(other)] ?? [])
        }
      } else {
        table[name, default: []].append(contentsOf: rest.split(separator: ",").map(String.init))
      }
    }
    return table
  }
}

/// Decides which files pass `-t`/`-T`.
struct TypeMatcher: Sendable {
  let selected: [Glob]
  let negated: [Glob]

  init(select: [String], negate: [String], additions: [String]) throws(UsageError) {
    let table = try FileTypes.definitions(adding: additions)
    func globs(_ names: [String]) throws(UsageError) -> [Glob] {
      var result: [Glob] = []
      for name in names {
        if name == "all" {
          for (_, g) in table { result.append(contentsOf: g.map { Glob(Array($0.utf8), anchored: false) }) }
          continue
        }
        guard let definition = table[name] else { throw UsageError("unrecognized file type: \(name)") }
        result.append(contentsOf: definition.map { Glob(Array($0.utf8), anchored: false) })
      }
      return result
    }
    selected = try globs(select)
    negated = try globs(negate)
  }

  var isEmpty: Bool { selected.isEmpty && negated.isEmpty }

  func match(name: Span<UInt8>) -> IgnoreMatch {
    for glob in negated where glob.matches(name, nameStart: 0) { return .ignore }
    guard !selected.isEmpty else { return .none }
    for glob in selected where glob.matches(name, nameStart: 0) { return .whitelist }
    return .ignore
  }

  static func listing(additions: [String]) throws(UsageError) -> String {
    let table = try FileTypes.definitions(adding: additions)
    return table.keys.sorted().map { "\($0): \(table[$0]!.joined(separator: ", "))" }.joined(separator: "\n") + "\n"
  }
}

/// A command line usage error.
public struct UsageError: Error, CustomStringConvertible {
  public let description: String
  public init(_ message: String) { description = message }
}
