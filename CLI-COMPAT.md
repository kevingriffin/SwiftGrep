# Remaining ripgrep CLI differences

Status on 2026-10-19, against ripgrep 15.2.0 (built with PCRE2):

- `Scripts/compare.py ~/Developer/nixpkgs` and `~/Developer/linux`: 58/58
  queries identical (keep it that way).
- `Scripts/compare_cli.py` (218 flag combinations, piped and on a
  terminal): 435/436 identical. The difference is `--debug`, below.
- `Scripts/missing_flags.py`: all 148 of rg's flag spellings are
  recognized.

Examples run from a Linux kernel checkout (`~/Developer/linux`) unless noted.
Check expected behavior by running rg. Pass `< /dev/null`, because both tools
read stdin when it is a pipe or socket and no path is given. For terminal
behavior, use `script -q /dev/null rg ...`.

Flags are declared once in `Sources/SwiftGrepKit/Arguments.swift` as
`@Spelling` cases. The `@CommandLineFlags` macro generates the lookup tables,
`--help`, and the data `--generate` builds the man page and completions from.

## Known differences

1. **No PCRE2.** `-P`/`--pcre2` and `--engine pcre2` fail with "PCRE2 is not
   available in this build of SwiftGrep" (status 2), and `--pcre2-version`
   says so (status 1). `--engine auto` uses the default engine, so a pattern
   that needs PCRE2 (backreferences, look-around) is an error where rg would
   fall back to PCRE2. Regex errors leave out rg's "Consider enabling PCRE2"
   hint, as an rg built without PCRE2 does.

2. **`--debug` and `--trace`** print sg's own diagnostics (the search
   strategy, workers and listing cache), not rg's log lines. Intentional.

3. **`--generate`** writes sg's man page and completions, built from sg's flag
   table (`Generate.swift`): they name `sg`, document sg's one-line help and
   include the sg-only flags. rg's are hand-written prose for rg.

4. **CJK encodings** (`-E` with gbk, gb18030, big5, euc-jp, iso-2022-jp,
   shift_jis or euc-kr) are decoded by the system's iconv, loaded only when
   needed, using its closest table (GB18030, BIG5-HKSCS, EUC-JP,
   ISO-2022-JP, CP932, CP949). Valid text decodes as encoding_rs decodes it;
   malformed input becomes one U+FFFD per bad byte, where encoding_rs
   sometimes takes two bytes, and ISO-2022-JP's half-width katakana escape
   isn't supported. UTF-8, UTF-16 and the single-byte encodings use
   encoding_rs's own tables (`Scripts/generate_encodings.py`) and match
   exactly.

## sg-only flags

- `--no-cache` searches without the directory listing cache, and
  `--clear-cache` deletes it.
- `--mmap`/`--no-mmap` are accepted and hidden; files over 4 MB are always
  mapped.

## Where things live

- `-U`: `Multiline.swift` ports rg's multi-line searcher. The lazy DFA picks
  its start state from the byte before the search position, so `\A`, `^`
  and word boundaries work when a search resumes mid-file.
- `--pre`, `--pre-glob` and `-z`: `Preprocess.swift`, with processes run by
  `OS.spawn`.
- Encodings and byte order marks: `Encodings.swift`, with the tables in
  `EncodingTables.swift`.
- Regex syntax: `Parser.swift` follows regex-syntax: patterns are parsed
  joined as `(?:p1)|(?:p2)`, and errors show the joined pattern with the
  same spans. `Scripts/generate_unicode_tables.py` builds
  `UnicodeTables.swift` from regex-syntax's Unicode 16.0 tables, so `\w`,
  `\p{...}`, case folding and smart case match rg (the Swift standard
  library is on a newer Unicode version).
