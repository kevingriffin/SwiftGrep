# SwiftGrep (`sg`)

A ripgrep-compatible recursive search tool for macOS, tuned for APFS. The
goals, in order:

1. **Identical results to ripgrep.** rg is the spec.
2. **Fastest on APFS.**
3. **Memory safe.**
4. **Code that reads well.**

The README has the measurements behind every design decision.
`CLI-COMPAT.md` lists the remaining rg differences, which is the next work.

## Platform

- macOS 27+ and Swift 6.4+ only. There's no Linux or Windows portability
  and no `#if os(...)`.
- Use the newest standard library and OS APIs:
  - `Span`, `RawSpan`, `InlineArray`, `UniqueArray`
  - `Mutex`/`Atomic`
  - the System framework's `FileDescriptor`, `Stat` and `Errno`
- No Foundation, in our code or linked in: loading it adds 0.7 ms to a
  startup of about 2.2 ms, which matters for single-file use. `otool -L`
  on the binary must not list it. Dependencies that use Foundation when it's
  available pull it in; swift-binary-parsing was dropped for that.
- Don't enable experimental compiler features. In particular, methods can't
  return a `Span`, so pass spans as parameters or slice storage at the call
  site.

## Performance: what we measured, and the rules that follow

- **`open()` is the bottleneck on APFS.**
  - Every open goes through a kernel lock shared by all processes.
    Throughput peaks with 4–5 concurrent openers and collapses beyond 6.
  - The default is 5 workers. More workers, or more workers with a
    semaphore around `open()`, measured slower; don't retry this without new
    evidence.
- **Avoid system calls:**
  - `getattrlistbulk` lists a directory with types and sizes, so there are
    no `stat`s and no probing for ignore files.
  - Each file is read with one `read()`.
  - Directory listings are cached, validated by a single `stat` per
    directory.
- **Hot loops** (DFA, SIMD prefilters, glob and ignore matching) run once
  per byte or per entry:
  - Keep reference counting and copies out of them: no arrays of arrays or
    reference-counted enum payloads.
  - Check the generated assembly after changing them. Reading through a
    local copy of an `InlineArray` copies the whole array on every access,
    which once made the DFA 4x slower.
- **Measure every change.** Run the two binaries alternately and compare
  medians. The machine is noisy (±15%), because other processes' file I/O
  contends for the same kernel lock. Tiny regressions are acceptable only
  for big ergonomic wins.
- **Weigh every dependency's cost** in startup time, binary size and build
  time. swift-argument-parser was rejected for adding 2.3 ms of startup. The
  README has the full table.

## Safety

- Every target builds with `.strictMemorySafety()`.
  - All `unsafe` code lives in `Sources/SwiftGrepKit/OS.swift`, behind
    functions with safe signatures that check their preconditions.
  - Keep it that way: no `unsafe` elsewhere, no `@unchecked Sendable`, no
    `-enforce-exclusivity=unchecked`.
- Treat everything that comes from a file system, file or repository as
  hostile:
  - **Directory entries:** validate them, and skip names that are empty,
    `.`, `..`, or contain `/` or NUL.
  - **Ignore files:** glob matching must stay O(pattern × path) with no
    recursion.
  - **The cache file and `getattrlistbulk` results:** parse them with
    `ByteReader`, which throws instead of reading past its range; a damaged
    cache file is a cache miss. Use a private directory, and create files with
    `O_EXCL | O_NOFOLLOW`.
  - **Regexes:** keep the nesting and size limits and the linear-time
    engines.
- **Errors are typed.** System calls throw `Errno`; never read the global
  `errno` after other calls. A `~Copyable` `OpenFile` owns each descriptor.
- Every security fix gets a regression test.

## Code style

- Use `~Copyable` for anything that owns buffers or per-thread state
  (`Worker`, `LineMatcher`, `LazyDFA`, `OpenFile`). Shared state is
  immutable and `Sendable` (`Matcher`, `SearchRun`, `IgnoreRules`).
- Workers run in a `DiscardingTaskGroup`. Prefer enums for modes, `guard`
  for early exits, and typed throws.
- Spans of storage owned by `self`:
  - In mutating methods, scope them in `do {}` blocks or pass disjoint
    stored properties as `inout`.
  - Copy an array held by a class to a local before taking its span.
- Command line flags are declared once, with `@Spelling` in
  `Arguments.swift`. The `@CommandLineFlags` macro generates the tables and
  `--help`.
- Match the surrounding code's comment density. Comments explain why;
  measurements live in the README.

## Checking a change

```
swift build -c release && swift test
Scripts/compare.py ~/Developer/nixpkgs      # must stay 58/58 identical
Scripts/compare.py ~/Developer/linux        # must stay 58/58 identical
Scripts/compare_cli.py                      # flag-by-flag vs rg (see CLI-COMPAT.md)
Scripts/bench.py ~/Developer/nixpkgs        # directory-heavy: ~0.32 s vs rg ~2.7 s
Scripts/bench.py ~/Developer/linux          # file- and byte-heavy: ~0.58 s vs rg ~2.9 s
```

The test corpora:
- `~/Developer/nixpkgs`: 55k files in 38.7k directories, so directory
  listings dominate.
- `~/Developer/linux`: 96k files, 1.64 GB, so opens and search dominate.

Pitfalls when running sg or rg by hand:
- **Stdin.** With no path argument, both tools search stdin if it's a pipe,
  socket or file. Always use `< /dev/null` (hyperfine: `--input null`) and
  give `xctrace` an explicit path.
- **hyperfine `-N`.** It splits commands into words itself, so backslashes
  in regexes get mangled. Drive it from a Python script with
  `shlex.join`.
- **zsh.** Its MULTIOS makes `2>&1 >/dev/null` leak output into the pipe.
  Use bash for redirection tricks.
