# Remaining ripgrep CLI differences

Status on 2026-10-18, against ripgrep 15.2.0:

- `Scripts/compare.py ~/Developer/nixpkgs` and `~/Developer/linux`: 58/58
  queries identical (keep it that way).
- `Scripts/compare_cli.py` (114 flag combinations, piped and on a
  terminal): 188/228 identical. Every difference is listed below.
- `Scripts/missing_flags.py`: 79 of rg's 148 flag spellings are not
  recognized.

Examples run from a Linux kernel checkout (`~/Developer/linux`) unless noted.
Check expected behavior by running rg. Pass `< /dev/null`, because both tools
read stdin when it is a pipe or socket and no path is given. For terminal
behavior, use `script -q /dev/null rg ...`.

Flags are declared once in `Sources/SwiftGrepKit/Arguments.swift` as
`@Spelling` cases. The `@CommandLineFlags` macro generates the lookup tables
and `--help`, so a new flag needs one annotation plus one case in `apply`.

## Wrong behavior in supported flags (fix these first)

1. **Headings are printed when file names are off.** rg prints the heading
   (path) line only when it prints file names. It keeps the blank line
   between files but omits the path. sg prints the path anyway. This also
   affects a single explicit file on a terminal, where names are off by
   default.
   - `sg --no-filename --heading update_curr kernel/sched` (also `-I` on a
     terminal)
   - On a terminal: `sg --color=always -o 'rq_[a-z]+' kernel/sched/core.c`,
     `sg --color=always -i -w rq kernel/sched/core.c` and
     `sg --color=always -v -n -m3 e kernel/sched/sched.h` each print a
     heading line that rg doesn't.
   - Where: `SwiftGrep.resolveSettings` (`heading:` should require
     `withFilename`), and the file separator in `SwiftGrep.search`.

2. **`--column` should imply `--line-number`** unless `-N` is given (in
   either order).
   - `sg --only-matching --column 'rq_[a-z]+' kernel/sched/core.c`, piped:
     rg `80:16:rq_regs`, sg `16:rq_regs`.
   - Where: `resolveSettings` (`lineNumbers:`).

3. **`-o -c` should count matches, not lines**, like `--count-matches`.
   - `sg -o -c rq kernel/sched/core.c`: rg 1954, sg 1303.
   - Where: `Arguments.swift` / `Configuration` mode resolution, or
     `FileSearch` count mode.

4. **`-m 0` should match nothing** (no output, exit 1). sg treats 0 as
   unlimited.
   - `sg -m 0 rq kernel/sched`
   - Where: `.maxCount` in `Arguments.swift` and the check in
     `FileSearch.select` (`Searcher.swift`). A zero limit can skip searching
     entirely.

5. **In the trailing context after the `-m` limit, lines that match are
   printed as matches** (`:`), not as context (`-`), but they don't count.
   - In a scratch directory: `printf 'a1\nb\na2\na3\nc\n' > m.txt; sg -m1
     -A3 -n a m.txt`. rg prints `1:a1 2-b 3:a2 4:a3`; sg prints `3-a2 4-a3`.
   - Kernel example: `sg -C2 -v -n -m 5 e kernel/sched/sched.h` prints line
     82 as `82-`; rg prints `82:`.
   - Where: after-context emission (`afterRemaining`) in `Searcher.swift`.

6. **With `-v` and color, matches in context lines are highlighted.** Under
   `-v` the context lines are the ones that do match, and rg colors the
   matches in them. sg prints them uncolored.
   - On a terminal: `sg -C2 -v -n -m 5 e kernel/sched/sched.h`
   - Where: context line printing in `Searcher.swift` for invert mode.

7. **`--vimgrep` with color highlights only the entry's own match.** rg
   prints one line per match and colors just that match; sg colors every
   match on the line.
   - `sg --color=always --vimgrep update_curr kernel/sched/deadline.c` (line
     3675 has two matches). The same happens on a terminal, and with `-C1`.
   - Where: `Searcher.swift`, the `settings.vimgrep && highlight` branch.

8. **`--files` paths are colored whenever color is on** (on a terminal, or
   with `--color=always` to a pipe), as `ESC[0mESC[35m<path>ESC[0m`. sg
   prints them plain.
   - `sg --files --color=always kernel/sched`. Every `--files` row in the
     terminal part of the harness fails for this reason.
   - Where: `FileSearcher.list` in `Walker.swift` (use `ColorSpec.path`).

9. **`--stats` differs in content and in how `-q` behaves.** With
   `--stats`, rg searches everything even under `-q`. It prints, after a
   blank line: `N matches`, `N matched lines`, `N files contained matches`,
   `N files searched`, `N bytes printed`, `N bytes searched`,
   `X.XXXXXX seconds spent searching`, `X.XXXXXX seconds total`. sg stops at
   the first match under `-q` and prints five lines in a different format.
   - `sg --stats -q rq kernel/sched`
   - Where: the stats block at the end of `SwiftGrep.search`, and the `-q`
     stop in `FileSearcher.search`. Needs a matches counter and a bytes
     printed counter.

10. **File types.** `--type-list`, `-t` and `-T` know about 80 of rg's ~250
    types (`FileTypes.swift`). The full table could be generated from
    `rg --type-list`.

11. **Error wording for invalid values** (exit codes already match):

    | command | rg | sg |
    |---|---|---|
    | `-A x` | `error parsing flag -A: value is not a valid number: invalid digit found in string` | `invalid value 'x' for --after-context: expected a non-negative integer` |
    | `--context -1` | `error parsing flag --context: value is not a valid number: ...` | `invalid value '-1' for --context: ...` |
    | `-C1n` | `error parsing flag -C: value is not a valid number: ...` | `invalid value '1n' for --context: ...` |
    | `--color sometimes` | `error parsing flag --color: choice 'sometimes' is unrecognized` | `invalid value 'sometimes' for --color: expected never, auto, always or ansi` |

12. **`--debug`** prints sg's own strategy line, not rg's trace. This is
    intentional and low priority.

### Harness noise (not real differences)

On a terminal, the harness occasionally reports a one-byte difference for
`-p -C2 rq_clock_pelt kernel/sched` and `--sort path -n update_curr
kernel/sched`. Run directly, both are byte-identical; the difference comes
from `script(1)`.

## Missing flags (79 spellings)

**Output:**
- `-b/--byte-offset`, `-r/--replace`, `--passthru` (alias `--passthrough`),
  `--trim`
- `-M/--max-columns`, `--max-columns-preview`
- `--colors SPEC`
- `--field-context-separator`, `--field-match-separator`, `--path-separator`
- `--hyperlink-format`, `--hostname-bin`
- `--line-buffered`, `--block-buffered`
- `--json`
- `--messages`/`--no-messages`, `--ignore-messages`/`--no-ignore-messages`
- `--sort-files` (deprecated alias of `--sort path`)

**Search:**
- `-U/--multiline`, `--multiline-dotall`
- `-P/--pcre2`, `--pcre2-unicode`, `--pcre2-version`, `--engine`,
  `--auto-hybrid-regex`
- `--crlf`, `--null-data`, `--unicode`/`--no-unicode`
- `--stop-on-nonmatch`, `--dfa-size-limit`, `--regex-size-limit`
- `-z/--search-zip`, `--pre`, `--pre-glob`

**Files:**
- `--ignore-file`, `--ignore-file-case-insensitive`
- `--ignore-files`/`--no-ignore-files`, `--type-clear`, `--one-file-system`

**Negations:** rg has a `--no-X`/`--X` pair for almost every switch. sg is
missing:
- `--no-fixed-strings`, `--no-invert-match`, `--no-text`, `--no-binary`,
  `--no-follow`
- `--no-glob-case-insensitive`, `--no-stats`, `--no-include-zero`,
  `--no-trim`
- `--no-multiline`, `--no-multiline-dotall`, `--no-pcre2`, `--no-crlf`
- `--no-search-zip`, `--no-pre`, `--no-one-file-system`, `--no-json`,
  `--no-byte-offset`
- `--no-line-buffered`, `--no-block-buffered`, `--no-max-columns-preview`,
  `--no-sort-files`
- `--no-auto-hybrid-regex`, `--no-pcre2-unicode`,
  `--no-ignore-file-case-insensitive`
- the positive forms of the `--no-ignore*` flags (`--ignore`, `--ignore-vcs`,
  `--ignore-dot`, `--ignore-parent`, `--ignore-global`, `--ignore-exclude`)
- `--require-git`

**Other:**
- `--generate` (man page and completions), `--trace`, `--no-config`.
- The config file: rg reads flags from the file named by
  `RIPGREP_CONFIG_PATH` before the command line. sg ignores it.

Several of these are out of scope by design: PCRE2, preprocessors,
compressed files, and encodings other than UTF-8; the README lists them. If
one is added later, it still has to keep the startup cost and the
APFS-oriented design described in `CLAUDE.md`.
