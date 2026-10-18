#!/usr/bin/env python3
"""Compares SwiftGrep's command line behavior with ripgrep's, flag by flag.

Usage: Scripts/compare_cli.py [CORPUS] [-v]    (default: ~/Developer/linux)

Runs each flag combination below through both tools, once with output to a
pipe and once to a pseudo-terminal (via script(1), since colors, headings and
line numbers depend on it), and compares exit status and output. Output is
compared as sorted lines unless the run sorts its output, because both tools
print files in a nondeterministic order. On a terminal, stderr is mixed into
the output, so the "rg: "/"sg: " message prefixes are normalized. With -v,
differing lines are shown. The queries assume a Linux kernel checkout.
"""
import os, subprocess, sys, shlex

args = [a for a in sys.argv[1:] if a != "-v"]
verbose = "-v" in sys.argv[1:]
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
bin_dir = subprocess.run(["swift", "build", "-c", "release", "--show-bin-path"], cwd=root,
                         capture_output=True, text=True).stdout.strip()
sg = os.environ.get("SG", os.path.join(bin_dir, "sg"))
cwd = os.path.expanduser(args[0] if args else "~/Developer/linux")
P = "kernel/sched"   # a moderately sized subtree, multiple files
Q = [
  ["--pretty", "rq_clock", P],
  ["-p", "-C2", "rq_clock_pelt", P],
  ["--ignore-case", "-c", "SCHED_FIFO", P],
  ["-i", "-s", "-c", "SCHED_FIFO", P],
  ["-s", "-i", "-c", "SCHED_FIFO", P],
  ["--smart-case", "-c", "sched_fifo", P],
  ["--smart-case", "-c", "Sched_fifo", P],
  ["-S", "-i", "-c", "Sched_fifo", P],
  ["--context", "2", "-n", "update_curr\\(", P],
  ["--context=1", "--heading", "-n", "update_curr\\(", P],
  ["-A", "1", "-B", "3", "-n", "update_curr\\(", P],
  ["-A1", "-B3", "--no-heading", "update_curr\\(", P],
  ["-C3", "-m", "2", "-n", "update_curr", P],
  ["-C1", "--context-separator", "@@", "-n", "update_curr", P],
  ["-C1", "--no-context-separator", "-n", "update_curr", P],
  ["-C2", "-v", "-n", "-m", "5", "e", "kernel/sched/sched.h"],
  ["-C2", "-c", "update_curr", P],
  ["-C2", "-l", "update_curr", P],
  ["-C1", "-o", "-n", "update_curr", P],
  ["--column", "-n", "update_curr", P],
  ["--vimgrep", "update_curr", P],
  ["--vimgrep", "-C1", "update_curr", P],
  ["-o", "-n", "rq_[a-z]+", P],
  ["--only-matching", "--column", "rq_[a-z]+", "kernel/sched/core.c"],
  ["--count-matches", "rq", P],
  ["-o", "-c", "rq", P],
  ["--include-zero", "-c", "update_curr", P],
  ["--null", "-l", "update_curr", P],
  ["-0", "-c", "update_curr", P],
  ["-H", "update_curr", "kernel/sched/fair.c"],
  ["-I", "update_curr", P],
  ["--no-filename", "--heading", "update_curr", P],
  ["-N", "update_curr", P],
  ["--line-number", "--no-line-number", "update_curr", P],
  ["--no-line-number", "--line-number", "update_curr", P],
  ["--heading", "--no-heading", "-n", "update_curr", P],
  ["-p", "--no-heading", "update_curr", P],
  ["-p", "--color", "never", "update_curr", P],
  ["--color", "always", "-n", "update_curr", P],
  ["--color=always", "-o", "rq_[a-z]+", "kernel/sched/core.c"],
  ["--color=always", "-C1", "-n", "--column", "update_curr", P],
  ["--color=always", "-v", "-n", "-m3", "e", "kernel/sched/sched.h"],
  ["--color=always", "-i", "-w", "rq", "kernel/sched/core.c"],
  ["--color=always", "--files-without-match", "update_curr", P],
  ["--color=always", "-c", "update_curr", P],
  ["--color=always", "--vimgrep", "update_curr", P],
  ["--color=ansi", "-n", "update_curr", P],
  ["-w", "-x", "-c", "}", P],
  ["--word-regexp", "-c", "rq", P],
  ["--line-regexp", "-c", "\\{", P],
  ["-F", "-c", "rq->curr", P],
  ["--fixed-strings", "-e", "a.b", "-e", "(", "-c", P],
  ["-e", "update_curr", "-e", "rq_clock", "-c", P],
  ["--regexp=update_curr", "-n", P],
  ["-v", "-c", "e", P],
  ["--invert-match", "--count", "e", P],
  ["-q", "update_curr", P],
  ["--quiet", "zzzznope", P],
  ["-l", "update_curr", P],
  ["--files-with-matches", "--sort", "path", "rq", P],
  ["--files-without-match", "update_curr", P],
  ["--sort", "path", "-n", "update_curr", P],
  ["--sortr", "path", "-c", "rq", P],
  ["--sort=none", "-c", "rq", P],
  ["-m1", "-n", "rq", P],
  ["--max-count", "2", "-c", "rq", P],
  ["--max-depth", "1", "-c", "rq", "kernel"],
  ["-d", "0", "-c", "rq", "kernel"],
  ["--files", "kernel/sched"],
  ["--files", "-g", "*.h", "kernel"],
  ["--files", "--iglob", "*.H", "kernel"],
  ["--files", "--glob-case-insensitive", "-g", "*.H", "kernel"],
  ["--files", "-t", "c", "-T", "h", "kernel/sched"],
  ["--files", "--type-add", "foo:*.h", "-t", "foo", "kernel/sched"],
  ["--files", "--type-add", "foo:include:c,h", "-t", "foo", "kernel/sched"],
  ["--type-list"],
  ["-t", "nope", "x"],
  ["--hidden", "--files", "-g", ".*", "."],
  ["-.", "--files", "-g", ".git*", "."],
  ["--no-hidden", "--hidden", "--files", "-g", ".*", "."],
  ["-u", "--files", "-g", "*.o", "."],
  ["-uu", "--files", "-g", ".*", "-d", "1", "."],
  ["--no-ignore", "-c", "zzz", "."],
  ["--no-ignore-vcs", "--files", "-g", "*.cmd", "."],
  ["--max-filesize", "2K", "-c", "rq", P],
  ["-L", "--files", "-d", "1", "."],
  ["--follow", "-c", "rq", P],
  ["-a", "-c", "rq", P],
  ["--text", "-c", "\\x00", "."],
  ["--binary", "-c", "ELF", "."],
  ["-j", "1", "-c", "rq", P],
  ["--threads=3", "-c", "rq", P],
  ["--stats", "-q", "rq", P],
  ["-f", "/dev/null", P],
  ["--debug", "-c", "zzz", "kernel/sched/core.c"],
  ["--mmap", "-c", "rq", P],
  ["--no-mmap", "-c", "rq", P],
  ["-E", "none", "-c", "rq", P],
  ["--encoding=utf-8", "-c", "rq", P],
  ["--no-encoding", "-c", "rq", P],
  ["--unknown-flag", "x"],
  ["-Z", "x"],
  ["-A", "x", "y"],
  ["--context", "-1", "y"],
  ["--color", "sometimes", "y"],
  ["-m", "0", "rq", P],
  ["-C0", "-n", "rq_clock_pelt", P],
  ["-A0", "-n", "rq_clock_pelt", P],
  ["--", "-rq", P],
  ["-e", "-rq", P],
  ["-ic2", "rq_clock_pelt", P],
  ["-niC1", "rq_clock_pelt", P],
  ["-nC", "1", "rq_clock_pelt", P],
  ["-C1n", "rq_clock_pelt", P],
]
def run(binary, args, tty):
    cmd = [binary] + args
    if tty:
        cmd = ["script", "-q", "/dev/null"] + cmd
    r = subprocess.run(cmd, cwd=cwd, capture_output=True, stdin=subprocess.DEVNULL, timeout=60)
    out = r.stdout
    if tty:
        # script(1) echoes ^D and backspaces, and translates newlines.
        out = out.replace(b"^D\x08\x08", b"").replace(b"\r\n", b"\n")
        out = out.replace(b"rg: ", b"X: ").replace(b"sg: ", b"X: ")
    out = out.replace(b"\x00", b"\x00\n")
    return r.returncode, out, r.stderr.replace(b"rg: ", b"X: ").replace(b"sg: ", b"X: ")
fails = 0
for tty in (False, True):
    for args in Q:
        rc1, o1, e1 = run("rg", args, tty)
        rc2, o2, e2 = run(sg, args, tty)
        exact = any(a in ("--sort", "--sortr", "--sort=path") for a in args) and "none" not in args
        same_out = o1 == o2 if exact else sorted(o1.split(b"\n")) == sorted(o2.split(b"\n"))
        # rg's file order is nondeterministic, so compare output as sorted lines unless sorted.
        if rc1 == rc2 and same_out:
            continue
        fails += 1
        print(f"{'TTY ' if tty else ''}DIFF {shlex.join(args)}: exit rg={rc1} sg={rc2}, out {len(o1)} vs {len(o2)} bytes")
        if not same_out and verbose:
            a, b = set(o1.split(b"\n")), set(o2.split(b"\n"))
            for l in sorted(a - b)[:3]: print("   rg:", l[:160])
            for l in sorted(b - a)[:3]: print("   sg:", l[:160])
        if verbose and e1 != e2 and (rc1 == 2 or rc2 == 2):
            print("   rg err:", e1[:200]); print("   sg err:", e2[:200])
print(f"{2*len(Q) - fails}/{2*len(Q)} identical")
