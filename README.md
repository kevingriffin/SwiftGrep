# SwiftGrep

`sg` is a ripgrep-compatible recursive search tool for macOS, written in Swift
and tuned for APFS. Its frontend is rg compatible, but is much faster than rg on macOS.

This requires macOS 27 Golden Gate and thus Apple Silicon. A binary is provided in the releases section.

This is made with AI, and although I guided it, I still need to review it
and work out its findings. It seems to be that limiting the number of threads
and avoiding `open` calls is important. There's also some caching to avoid needless
`open` calls based on some comtinatoin of inode and timestamps.

I want to learn more from ghostty and see if there isn't still performance to find, but it's a good start.

Here's a test on the [nixpkgs](https://github.com/nixOS/nixpkgs) repo:


| `-c fetchFromGitHub` on nixpkgs | wall time | system time | peak footprint |
|---------------------------------|----------:|------------:|---------------:|
| `rg` (default)                  | 2.74 s    | 32 s        | 23 MB          |
| `rg -j4` (rg's best)            | 0.67 s    | 2.4 s       | 21 MB          |
| `sg --no-cache`                 | 0.57 s    | 2.7 s       | 21 MB          |
| `sg`                            | **0.32 s** | 1.4 s      | 21 MB          |

And some more based on different query types (this on the Linux kernel source code):

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

## Memory safety

The package marks all targets as `.strictMemorySafety()`, but there is a collection of
unsafe functions in `Sources/SwiftGrepKit/OS.swift`, which I'll be checking. It's been security
reviewed by AI a few times, but human review is coming too.

When possible, `Span`, `RawSpan` and `UniqueArray` are used instead.

## Building and testing

```
swift build -c release          # binary: $(swift build -c release --show-bin-path)/sg
swift test                      # unit, consistency and end-to-end tests
Scripts/compare.py [corpus]     # output parity with rg (default: ~/Developer/nixpkgs)
Scripts/bench.py [corpus]       # timing against rg with hyperfine (the linux
                                # suite is picked for a directory named linux)
Scripts/compare_cli.py [corpus] # flag-by-flag behavior vs rg, piped and on a
                                # terminal (default: ~/Developer/linux)
Scripts/missing_flags.py        # rg flags sg doesn't recognize
```


## Nix
There's a nix flake in the repository as well, which should let you build the project without the exact toolchain I used.
