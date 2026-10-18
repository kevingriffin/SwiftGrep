#!/usr/bin/env python3
"""Compares SwiftGrep's output with ripgrep's on a corpus.

Usage: Scripts/compare.py [CORPUS]    (default: ~/Developer/nixpkgs)

Each query runs with both tools from the corpus root. Output lines are sorted
before comparing, since both tools print files in a nondeterministic order.
Set SG_NO_CACHE=1 to compare without SwiftGrep's directory listing cache.
"""
import os
import subprocess
import sys

QUERIES = [
    ["fetchFromGitHub"],
    ["-n", "fetchFromGitHub"],
    ["-i", "license = lib.licenses.mit"],
    ["-c", "fetchFromGitHub"],
    ["-l", "buildPythonPackage"],
    ["-n", r"maintainers = with lib.maintainers; \[ [a-z]+ \]"],
    ["-c", "-w", "rec"],
    ["-c", r"\bmkDerivation\b"],
    ["-o", r"sha256-[A-Za-z0-9+/=]{44}"],
    ["--files"],
    ["-c", "-F", "${"],
    ["-i", "-c", "kernel"],
    ["-c", r"^\s*#"],
    ["-c", r"\w+@\w+\.\w+"],
    ["-v", "-c", "e"],
    ["-c", "-t", "nix", "stdenv"],
    ["-c", "-g", "*.md", "nixos"],
    ["-c", "-g", "!pkgs/**", "nixos"],
    ["-c", "zzzzqqqnotfound"],
    ["-C2", "-n", "allowUnfree = true"],
    ["-c", "--hidden", "fetchFromGitHub"],
    ["-c", "-u", "fetchFromGitHub"],
    ["-c", "-uu", "fetchFromGitHub"],
    ["--count-matches", "lib"],
    ["-c", "ü|é|ß"],
    ["-c", "-x", "}"],
    ["-S", "-c", "Darwin"],
    ["-c", "-e", "foo", "-e", "bar"],
    ["-c", "(?i)nixos|darwin"],
    ["-c", r"[[:upper:]]{5,}"],
    ["-c", r"\p{Lu}\p{Ll}+Builder"],
    ["--vimgrep", "TODO"],
    ["-c", "-w", "-i", "the"],
    ["--files-without-match", "lib"],
    ["-c", "-m", "2", "lib"],
    ["-c", r"\d{4}-\d{2}-\d{2}"],
    ["-c", "a.b.c"],
    ["-l", "-i", "-F", "SPDX-License-Identifier"],
    ["-c", "--max-depth", "2", "nixpkgs"],
    ["-c", ""],
    ["--color=always", "-n", "callPackage ./"],
    ["-c", r"(foo|bar|baz|qux|quux)\s*="],
    ["-c", r"[^\x00-\x7F]"],
    ["--max-filesize", "10K", "-c", "lib"],
    ["--max-filesize", "1M", "--files"],
    ["-L", "-c", "fetchFromGitHub"],
    ["-c", "fetchFromGitHub", "pkgs/by-name", "lib"],
    ["-n", "-B1", "-A2", "-m3", "mkDerivation", "pkgs/by-name/aa"],
    # ripgrep's benchsuite queries (meant for a Linux kernel checkout).
    ["-n", "PM_RESUME"],
    ["-n", "-i", "PM_RESUME"],
    ["-n", "[A-Z]+_RESUME"],
    ["-n", "-w", "PM_RESUME"],
    ["-n", r"\wAh"],
    ["-n", r"(?-u)\wAh"],
    ["-n", r"\w{5}\s+\w{5}\s+\w{5}\s+\w{5}\s+\w{5}"],
    ["-n", "ERR_SYS|PME_TURN_OFF|LINK_REQ_RST|CFG_BME_EVT"],
    ["-n", "-i", "ERR_SYS|PME_TURN_OFF|LINK_REQ_RST|CFG_BME_EVT"],
    ["-c", "-t", "c", "-e", "struct", "-e", "union", "-e", "enum"],
]


def run(binary, args, cwd):
    p = subprocess.run([binary, *args], cwd=cwd, capture_output=True, stdin=subprocess.DEVNULL)
    return p.returncode, sorted(p.stdout.split(b"\n")), p.stderr


def main():
    corpus = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else "~/Developer/nixpkgs")
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    bin_dir = subprocess.run(["swift", "build", "-c", "release", "--show-bin-path"], cwd=root,
                             capture_output=True, text=True).stdout.strip()
    sg = os.environ.get("SG", os.path.join(bin_dir, "sg"))
    failures = 0
    for args in QUERIES:
        rg_code, rg_out, rg_err = run("rg", args, corpus)
        sg_code, sg_out, sg_err = run(sg, args, corpus)
        label = " ".join(args)
        if rg_code == sg_code and rg_out == sg_out:
            print(f"ok    {len(rg_out) - 1:>7} lines  {label}")
            continue
        failures += 1
        print(f"FAIL  {label}  (exit rg={rg_code} sg={sg_code}, lines rg={len(rg_out)} sg={len(sg_out)})")
        rg_set, sg_set = set(rg_out), set(sg_out)
        for line in sorted(rg_set - sg_set)[:5]:
            print("      only rg:", line[:200])
        for line in sorted(sg_set - rg_set)[:5]:
            print("      only sg:", line[:200])
        if sg_err:
            print("      sg stderr:", sg_err[:300])
    print(f"\n{len(QUERIES) - failures}/{len(QUERIES)} queries identical")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
