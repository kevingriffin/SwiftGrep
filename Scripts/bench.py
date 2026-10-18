#!/usr/bin/env python3
"""Benchmarks SwiftGrep against ripgrep with hyperfine.

Usage: Scripts/bench.py [CORPUS] [--runs N] [--suite nixpkgs|linux]

The corpus defaults to ~/Developer/nixpkgs. The linux suite holds the queries
of ripgrep's own benchmark suite (benchsuite/benchsuite in the ripgrep repo),
which runs on a Linux kernel checkout; it is picked automatically for a corpus
directory named "linux".
"""
import json
import os
import shlex
import subprocess
import sys
import tempfile

NIXPKGS = [
    ("literal", ["-c", "fetchFromGitHub"]),
    ("literal, -i", ["-c", "-i", "license = lib.licenses.mit"]),
    ("no literal", ["-c", r"\w+@\w+\.\w+"]),
    ("class repeat", ["-c", "[[:upper:]]{5,}"]),
    ("-w -i", ["-c", "-w", "-i", "the"]),
    ("alternation", ["-c", r"(foo|bar|baz|qux|quux)\s*="]),
    ("-v", ["-c", "-v", "e"]),
    ("many lines", ["-n", "lib"]),
    ("--files", ["--files"]),
]

# ripgrep's benchsuite, minus \p{Greek} (scripts aren't supported).
LINUX = [
    ("literal_default", ["PM_RESUME"]),
    ("literal", ["-n", "PM_RESUME"]),
    ("literal_casei", ["-n", "-i", "PM_RESUME"]),
    ("re_literal_suffix", ["-n", "[A-Z]+_RESUME"]),
    ("word", ["-n", "-w", "PM_RESUME"]),
    ("unicode_word", ["-n", r"\wAh"]),
    ("ascii_word", ["-n", r"(?-u)\wAh"]),
    ("no_literal", ["-n", r"\w{5}\s+\w{5}\s+\w{5}\s+\w{5}\s+\w{5}"]),
    ("ascii_no_literal", ["-n", r"(?-u)\w{5}\s+\w{5}\s+\w{5}\s+\w{5}\s+\w{5}"]),
    ("alternates", ["-n", "ERR_SYS|PME_TURN_OFF|LINK_REQ_RST|CFG_BME_EVT"]),
    ("alternates_casei", ["-n", "-i", "ERR_SYS|PME_TURN_OFF|LINK_REQ_RST|CFG_BME_EVT"]),
    ("--files", ["--files"]),
]

SUITES = {"nixpkgs": NIXPKGS, "linux": LINUX}


def main():
    args = sys.argv[1:]
    runs = "5"
    if "--runs" in args:
        i = args.index("--runs")
        runs = args[i + 1]
        del args[i:i + 2]
    suite = None
    if "--suite" in args:
        i = args.index("--suite")
        suite = args[i + 1]
        del args[i:i + 2]
    corpus = os.path.expanduser(args[0] if args else "~/Developer/nixpkgs")
    if suite is None:
        suite = "linux" if os.path.basename(os.path.normpath(corpus)) == "linux" else "nixpkgs"
    queries = SUITES[suite]
    width = max(len(name) for name, _ in queries)
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    bin_dir = subprocess.run(["swift", "build", "-c", "release", "--show-bin-path"], cwd=root,
                             capture_output=True, text=True).stdout.strip()
    sg = os.environ.get("SG", os.path.join(bin_dir, "sg"))
    print(f"{'query':<{width}} {'rg (s)':>8} {'sg (s)':>8} {'speedup':>8}   {'rg sys':>7} {'sg sys':>7}")
    for name, query in queries:
        q = " ".join(shlex.quote(a) for a in query)
        with tempfile.NamedTemporaryFile(suffix=".json") as out:
            subprocess.run(["hyperfine", "-N", "-w", "1", "-r", runs, "--input", "null",
                            "--output", "null", "--export-json", out.name,
                            f"rg {q}", f"{sg} {q}"], cwd=corpus, capture_output=True, check=True)
            results = json.load(open(out.name))["results"]
        def stat(result, key):
            # Newer hyperfine versions nest statistics under "summary".
            if "summary" in result:
                return result["summary"][key]["mean"]
            return result["mean" if key == "time_wall_clock" else key.replace("time_", "")]
        rg, sgr = stat(results[0], "time_wall_clock"), stat(results[1], "time_wall_clock")
        rg_sys, sg_sys = stat(results[0], "time_system"), stat(results[1], "time_system")
        print(f"{name:<{width}} {rg:>8.3f} {sgr:>8.3f} {rg / sgr:>7.2f}x   {rg_sys:>7.2f} {sg_sys:>7.2f}", flush=True)


if __name__ == "__main__":
    main()
