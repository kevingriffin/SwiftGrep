#!/usr/bin/env python3
"""Lists ripgrep flags that SwiftGrep does not recognize.

Usage: Scripts/missing_flags.py

Collects every flag spelling from `rg --help` (including the --no-* forms
mentioned in descriptions), runs sg with each one, and reports those that sg
rejects as unrecognized.
"""
import re, subprocess, os, sys
help_text = subprocess.run(["rg", "--help"], capture_output=True, text=True, stdin=subprocess.DEVNULL).stdout
headers = re.findall(r"^    (?:-(\S), )?--([a-z0-9-]+)(=\S+)?", help_text, re.M)
documented = {long: (short or None, bool(val)) for short, long, val in headers}
# Negations and other flags mentioned in descriptions.
mentioned = set(re.findall(r"--([a-z][a-z0-9-]+)", help_text))
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
bin_dir = subprocess.run(["swift", "build", "-c", "release", "--show-bin-path"], cwd=root,
                         capture_output=True, text=True).stdout.strip()
sg = os.environ.get("SG", os.path.join(bin_dir, "sg"))
values = {"regexp": "x", "file": "/dev/null", "pre": "cat", "pre-glob": "*", "dfa-size-limit": "10M", "encoding": "utf-8",
          "engine": "default", "max-count": "1", "regex-size-limit": "10M", "threads": "2", "glob": "*", "iglob": "*",
          "ignore-file": "/dev/null", "max-depth": "1", "max-filesize": "1M", "type": "rust", "type-not": "rust",
          "type-add": "foo:*.foo", "type-clear": "rust", "after-context": "1", "before-context": "1", "color": "never",
          "colors": "match:fg:red", "context": "1", "context-separator": "--", "field-context-separator": "-",
          "field-match-separator": ":", "hostname-bin": "hostname", "hyperlink-format": "default", "max-columns": "80",
          "path-separator": "/", "replace": "y", "sort": "path", "sortr": "path", "generate": "man"}
def recognized(flag, value):
    args = [sg, f"--{flag}"] + ([value] if value is not None else []) + ["-e", "zzz", "/dev/null"]
    r = subprocess.run(args, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=10)
    err = r.stderr
    return not ("unrecognized flag" in err or "does not take a value" in err), err.strip().splitlines()[0] if err.strip() else ""
missing, ok = [], []
for flag in sorted(set(documented) | mentioned):
    takes = documented.get(flag, (None, False))[1]
    good, err = recognized(flag, values.get(flag, "x") if takes else None)
    if not good and flag not in documented:
        # rg mentions it; check rg itself accepts it bare
        rr = subprocess.run(["rg", f"--{flag}", "-e", "zzz", "/dev/null"], capture_output=True, text=True, stdin=subprocess.DEVNULL)
        if "unrecognized" in rr.stderr or "unexpected" in rr.stderr: continue
    (ok if good else missing).append(flag)
print(f"recognized {len(ok)}, missing {len(missing)}")
print("MISSING:", " ".join(missing))
