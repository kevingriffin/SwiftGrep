# SwiftGrep

`sg` is a ripgrep-compatible recursive search tool for macOS, written in Swift
and tuned for APFS. It produces the same output as `rg` (including ignore
rules, binary file handling, colors and context) and is 5–9x faster than
ripgrep on large repositories: about 8.5x on nixpkgs and 5x on the Linux
kernel.

```
$ sg fetchFromGitHub              # search the current directory
$ sg -i -t nix 'license = .*mit'  # case-insensitive, Nix files only
$ sg -l -g '!pkgs/**' TODO        # list matching files outside pkgs/
```

## Why it is faster

Measurements on an M4 Max (12P + 4E cores), macOS 27, against a nixpkgs
checkout (55k files in 38.7k directories, everything in the page cache):

- **`open()` is the bottleneck, not searching.** It costs about 12 µs per file and
  goes through a kernel lock shared by every process. Throughput peaks at 4–5
  concurrent callers (~175k opens/s). Beyond 6 it collapses: 16 threads are
  ~6x slower than 4 and burn 30+ seconds of system time spinning. `stat()`,
  by contrast, is ~1.3 µs and scales across cores.
- **ripgrep uses one thread per core by default**, which on this machine lands
  on the cliff: `rg` takes 2.7 s with 32 s of system time, while `rg -j4`
  takes 0.67 s.

SwiftGrep is built around those numbers:

1. **Five workers.** That's the measured sweet spot, more workers only add
   contention. (`-j` overrides it.)
2. **No speculative opens.** Directories are read with `getattrlistbulk`, which
   returns names, types and sizes for many entries per call. The walker knows
   which `.gitignore`/`.ignore`/`.rgignore` files exist without probing for
   them and never `stat`s entries. A file is read with a single `read()`:
   a short read means end of file, so no second call is needed. Empty files
   in a freshly read listing aren't opened at all.
3. **A validated directory listing cache.** Enumerating a directory costs an
   `open()` as well, about 40% of all opens. An unchanged directory (same device,
   inode, mtime and ctime) is listed from a cache instead, checked with
   one cheap `lstat()`. On APFS every entry change updates the
   directory's mtime and ctime at nanosecond resolution, and ctime can't be
   set from user space, so a stale listing is never used. File contents and
   ignore files are always read fresh. The cache lives in
   `~/Library/Caches/SwiftGrep` (3.7 MB for nixpkgs), is only used on APFS,
   skips directories changed in the last two seconds, and can be turned off
   with `--no-cache` or `SG_NO_CACHE=1` (`--clear-cache` deletes it).

| `-c fetchFromGitHub` on nixpkgs | wall time | system time | peak footprint |
|---------------------------------|----------:|------------:|---------------:|
| `rg` (default)                  | 2.74 s    | 32 s        | 23 MB          |
| `rg -j4` (rg's best)            | 0.67 s    | 2.4 s       | 21 MB          |
| `sg --no-cache`                 | 0.57 s    | 2.7 s       | 21 MB          |
| `sg`                            | **0.32 s** | 1.4 s      | 21 MB          |

(Peak footprint is dirty memory as reported by `/usr/bin/time -l`. `sg`'s
resident size is higher, because large files are memory mapped and those
clean pages are shared with the page cache.)

The advantage holds for every kind of query (`Scripts/bench.py`, means of 5 runs):

| query                          | rg (s) | sg (s) | speedup |
|--------------------------------|-------:|-------:|--------:|
| literal                        | 2.74   | 0.32   | 8.6x    |
| literal, `-i`                  | 2.81   | 0.32   | 8.8x    |
| `\w+@\w+\.\w+` (no literal)    | 2.71   | 0.32   | 8.5x    |
| `[[:upper:]]{5,}`              | 2.69   | 0.34   | 8.0x    |
| `-w -i the`                    | 2.77   | 0.35   | 8.0x    |
| alternation                    | 2.66   | 0.34   | 7.8x    |
| `-v e`                         | 2.67   | 0.34   | 7.8x    |
| `-n lib` (46k lines of output) | 2.71   | 0.32   | 8.4x    |
| `--files`                      | 0.76   | 0.04   | 18x     |

At 0.32 s SwiftGrep is close to the floor set by opening 55k files at the
kernel's maximum rate. Search itself uses about 0.16 s of CPU in total.

### The Linux kernel

A Linux checkout is the corpus of ripgrep's own benchmark suite, and a very
different shape: 96k files in only 6.3k directories, 1.64 GB in total (8.6x
the bytes of nixpkgs, with 188 MB of generated headers in a single
directory). Directory listings matter much less here and search speed
matters more. `Scripts/bench.py ~/Developer/linux` runs the benchsuite
queries (`\p{Greek}` is left out, scripts aren't supported):

| query               | rg (s) | sg (s) | speedup |
|---------------------|-------:|-------:|--------:|
| `PM_RESUME`         | 2.95   | 0.58   | 5.1x    |
| `-n PM_RESUME`      | 2.88   | 0.58   | 5.0x    |
| `-n -i PM_RESUME`   | 2.97   | 0.59   | 5.0x    |
| `-n [A-Z]+_RESUME`  | 2.91   | 0.58   | 5.0x    |
| `-n -w PM_RESUME`   | 2.94   | 0.58   | 5.1x    |
| `-n \wAh`           | 2.92   | 0.58   | 5.0x    |
| `-n (?-u)\wAh`      | 2.89   | 0.57   | 5.0x    |
| `-n \w{5}\s+…` (five words, no literal) | 2.89 | 0.91 | 3.2x |
| `-n (?-u)\w{5}\s+…` | 2.90   | 0.90   | 3.2x    |
| `-n ERR_SYS\|PME_TURN_OFF\|…` | 2.90 | 0.59 | 4.9x |
| `-n -i ERR_SYS\|PME_TURN_OFF\|…` | 2.90 | 0.59 | 4.9x |
| `--files`           | 0.066  | 0.028  | 2.3x    |

Almost every query sits at the 0.58 s floor of opening 96k files. Most of the
advantage is the thread count: ripgrep with a hand-tuned `-j` gets close
(`rg -j5 -n PM_RESUME`: 0.62 s). The no-literal query is the exception. It runs
the DFA over every byte, which takes 2.4 s of CPU, so five workers are busy
searching rather than waiting for `open()`. There `rg -j6` (0.85 s) is a little
faster than `sg` (0.91 s). With `-j6`, `sg` takes 0.82 s, but six workers make
open-bound queries 10% slower. Capping concurrent `open()` calls with a
semaphore and adding more workers doesn't help: system time still climbs
past six threads.

The Linux tree also exposed problems that nixpkgs doesn't, now fixed:

- **Ignore rules were matched one by one.** Linux's root `.gitignore` has
  119 rules (plus 406 nested files), and copying globs cost reference
  counting on every check, which made `--files` 2x *slower* than ripgrep. Rules
  are now indexed by literal name, extension and path, as in ripgrep's
  globset, and glob tokens are plain values. `--files` went from 137 ms to
  28 ms.
- **Case-insensitive and multi-literal searches were slow.** Unicode case
  folding turns `-i PM_RESUME` into two literals (`s` also matches `ſ`, U+017F), and
  the old multi-literal scan checked a single byte per position. They now use
  Teddy (below), which is 2–5x faster and matches or beats ripgrep's
  throughput.
- **Large files were searched in their directory's order.** A worker
  that lists a directory now hands files over 1 MB to the shared queue, so
  idle workers help with directories full of large files. At five workers
  the no-literal query keeps every worker busy anyway, but at `-j6` this
  cut it from 0.89 s to 0.82 s.
- **Parity:** ripgrep skips a leading UTF-8 byte order mark (four
  translations in `Documentation/` have one), and reports an error when
  filters leave nothing to search. SwiftGrep now does both.

## Compatibility

`Scripts/compare.py` runs 58 queries through both tools on a corpus and compares
the results (exit status and sorted output). All 58 are identical on nixpkgs
and on the Linux kernel, with and without the listing cache.
Terminal output (headings, colors, line numbers) is byte-for-byte identical too.

Supported: ripgrep's regex syntax (Unicode classes, `\p{..}` general
categories, case folding, `\b`, `\b{start-half}` and friends, inline flags,
nested classes with `&&`/`--`/`~~`), `-e/-f/-F/-i/-S/-s/-w/-x/-v`,
`-c/--count-matches/-l/--files-without-match/-q/-o/--vimgrep`, context
(`-A/-B/-C`), `-n/--column/-H/-I/--heading/--color/-p/-0`, `-m`, `--files`,
`-g/--iglob`, `-t/-T/--type-add/--type-list`, gitignore semantics (including
parent directories, `.git/info/exclude` and the global excludes file),
`--hidden`, `--no-ignore*`, `-u/-uu/-uuu`, `-L`, `--max-depth`,
`--max-filesize`, `-a/--binary`, ripgrep's exact binary file behavior, UTF-8
byte order marks (`-E none` keeps them), stdin, and `--sort path` (output is
sorted, while the search stays parallel).

Not implemented: PCRE2 (`-P`), multiline search (`-U`), `--json`, `--replace`,
encodings other than UTF-8 (UTF-16 detection, `-E` with other values), preprocessors, `\p{Script}` classes, and most of
ripgrep's ~250 built-in file types (about 80 common ones are included).

## Design

```
Sources/
  GrepRegex/     A byte-oriented regex engine
  SwiftGrepKit/  Walking, ignore rules, searching, output, CLI parsing
  sg/            The executable
```

**GrepRegex** compiles Rust `regex` syntax through a Thompson NFA over
UTF-8 bytes into:

- a **lazy DFA** that answers "does this line match?". States are built on
  demand over byte equivalence classes. Matches are detected one byte late so
  `$` and word boundaries see the next byte, and the DFA stops at the first
  match. With Unicode word boundaries it hands lines containing non-ASCII
  bytes to the PikeVM.
- a **PikeVM** for exact leftmost-first match spans (colors, `-o`, `--column`).
- **literal prefilters**: the extractor finds strings every match must contain,
  using a byte frequency table, and searches for them with SIMD (`SIMD16<UInt8>`
  compiled to NEON). A single string uses a "packed pair" of its two rarest
  bytes, and `-i` uses ASCII case folding. Sets of up to 64 literals use
  **Teddy** (from Hyperscan, as in ripgrep): the literals are put in eight
  buckets, and for a three-byte window two NEON `tbl` lookups per byte map
  its nibbles to the buckets it could belong to, testing 16 positions at
  once. Pure literals skip verification entirely.

The lazy DFA stores state IDs as byte offsets into its transition table and
byte classes premultiplied by 4, so each byte costs one add and one
(bounds-checked) load. Haystacks are `Span<UInt8>` all the way down, and the
SIMD loops load vectors with `RawSpan.load`, so the engine contains no
unsafe code. Per-thread state (`LineMatcher`, `LazyDFA`, `PikeVM`) is
`~Copyable` and keeps its tables in `UniqueArray`s; the compiled
`Matcher` is an immutable, `Sendable` class shared by all workers. Unicode
tables (`\w`, `\d`, `\s`, general categories, simple case folding) are
generated from the standard library's Unicode data by
`Scripts/GenerateUnicodeTables.swift`.

**SwiftGrepKit** runs the workers in a `DiscardingTaskGroup`. They share a
`WorkQueue` (a `Mutex`-protected LIFO plus continuations) that ends when every
worker is idle. Each `Worker` is `~Copyable` and owns its `DirectoryListing`
(the `getattrlistbulk` buffer and name storage), `FileBuffer` and a
`FileSearcher` (output buffer and `LineMatcher`), all backed by
`UniqueArray`, so no memory is shared on the hot path. Output is written per file under one
lock, so files never interleave. Ignore rules form an immutable chain of
`IgnoreLevel`s shared between directories, with ripgrep's precedence:
`.rgignore` > `.ignore` > `.gitignore` > `.git/info/exclude` > global, and
gitignore rules stopping at nested repositories. Each ignore file's rules are
indexed: hash tables, probed without allocating, find the rules that can
only match one name, extension or path, and only the rest are tried in turn.

System calls go through `OS.swift`, built on the System framework
(swift-system, which macOS 27 ships with `Stat`): descriptors are
`FileDescriptor`s owned by a `~Copyable` `OpenFile` that closes itself, file
metadata is `Stat`, and failures are typed `Errno` throws, so an error can't
be lost or overwritten between the failing call and the report. Directory
entries and the listing cache are parsed with swift-binary-parsing's
`ParserSpan`, which bounds every read and turns malformed input into a
`ParsingError` (its `#magicNumber` macro checks the cache header).

Command line flags are declared once, as annotated enum cases:

```swift
@CommandLineFlags
enum Flag {
  @Section("PATTERNS")
  @Spelling("-e", "--regexp", value: "PATTERN", help: "A pattern to search for (repeatable)")
  case regexp
  ...
}
```

The `@CommandLineFlags` macro (in `Sources/SwiftGrepMacros`) generates the
spelling switches, lookup tables and the options part of `--help` at compile
time, and reports a conflicting spelling as a compile error at the
annotation.

### Dependencies considered

Each candidate was measured against the previous build (interleaved runs,
medians, both corpora):

| library | outcome | cost | benefit |
|---------|---------|------|---------|
| swift-system (the macOS 27 System framework) | adopted | none measurable | typed `Errno`, `FileDescriptor`, `Stat` |
| swift-binary-parsing 0.0.4 | adopted | +170 KB binary, swift-syntax prebuilt download | bounded, declarative parsing of untrusted input |
| macro (`@CommandLineFlags`) | adopted | none at runtime | one declaration per flag, compile-time conflict checks |
| swift-argument-parser 1.8 | not adopted | +2.3 ms startup (doubles a single-file search), +1.6 MB | declarative options, but rejects rg's `-niC1` and loses order-dependent precedence between flags |
| swift-algorithms 1.2 | not adopted | adds swift-numerics | would shorten a few loops in regex compilation only |
| swift-collections | not needed | | `UniqueArray` is in the macOS 27 standard library |

## Memory safety

Every target builds with Swift's strict memory safety checking
(`.strictMemorySafety()`), which requires each use of an unsafe construct
to be marked `unsafe`. The only file with such code is
`Sources/SwiftGrepKit/OS.swift`: 35 expressions, each a system call or
memory map wrapped in a function with a safe signature (spans, arrays and
values in and out) that checks its preconditions first. Everything else,
including the SIMD prefilters, the lazy DFA, directory parsing and the
cache format, uses bounds-checked `Span`, `RawSpan` and `UniqueArray`
access. Runtime exclusivity checks stay on; they cost nothing measurable.

Inputs that may come from someone else are treated as hostile:

- **Directory entries.** `getattrlistbulk` results are validated (entry
  lengths and name references must stay inside the buffer), and names that
  are empty, `.`, `..`, or contain `/` or NUL are skipped, so a misbehaving
  network or FUSE file system can't make the walker escape the tree or loop.
- **Ignore files.** Globs are matched by tracking the set of reachable
  positions, in O(pattern × path) time with no recursion, so a `.gitignore`
  line like `*a*a*a*a*a*a*b` can't stall a search (backtracking matchers
  take exponential time on it).
- **The listing cache.** It is read into memory and parsed with
  `ParserSpan`, so a damaged file is just a cache miss. It is only used from a directory
  owned by the user and closed to others (not a symlink), a relative
  `XDG_CACHE_HOME` is ignored, and new cache files are created with
  `O_EXCL | O_NOFOLLOW` before being renamed into place.
- **Regexes** compile with ripgrep's nesting limit and a size limit, and
  matching is linear time (lazy DFA or Pike VM, never backtracking).

One known limit: files over 4 MB are memory mapped, so if another process
truncates such a file while it is being searched, the process gets SIGBUS
(a crash, never a wrong read). ripgrep avoids this by not memory mapping
during recursive searches, at the cost of more copying.

## Building and testing

```
swift build -c release          # binary: $(swift build -c release --show-bin-path)/sg
swift test                      # unit, consistency and end-to-end tests
Scripts/compare.py [corpus]     # output parity with rg (default: ~/Developer/nixpkgs)
Scripts/bench.py [corpus]       # timing against rg with hyperfine (the linux
                                # suite is picked for a directory named linux)
```

Requires Swift 6.4+ and macOS 27+ (`Span`, `InlineArray`, `Mutex`, and
macOS 27's `UniqueArray`, byte-order-aware `RawSpan` loads and System
framework `Stat`). Dependencies: swift-binary-parsing and swift-syntax, which
SwiftPM fetches as a prebuilt binary matching the toolchain on first build.
