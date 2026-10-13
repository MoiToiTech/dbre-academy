#!/usr/bin/env python3
"""Run the code blocks in the course lessons against a running lab.

A fenced block is executed when its info string contains the word ``test``:

    ```sql test                  run on the primary as root, must succeed
    ```sql test replica          run on the replica
    ```sql test expect-error     must FAIL (e.g. a permission-denied demo)
    ```bash test                 run with bash from labs/ (./lab works there)
    ```bash test expect-error

Untagged blocks are shown to students but not executed — use that for output
samples, configuration excerpts and anything destructive or interactive.

Blocks of one file run in order, so a later block may depend on an earlier
one. Each file starts from whatever state the previous one left; files are
expected to clean up after themselves (or call ./lab scenario reset ...).

    tests/doctest.py                              # every lesson in courses/
    tests/doctest.py path/to/file.md [...]        # specific files
    tests/doctest.py --list                       # show what would run

Exit code is the number of failed blocks.
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

LAB_DIR = Path(__file__).resolve().parent.parent
REPO = LAB_DIR.parent
FENCE = re.compile(r"^(?P<indent> {0,3})(?P<fence>`{3,}|~{3,})(?P<info>[^\n`]*)$")
TIMEOUT = int(os.environ.get("DOCTEST_TIMEOUT", "300"))


def blocks(path: Path):
    """Yield (line_no, lang, flags, body) for every tagged block."""
    lines = path.read_text(encoding="utf-8").splitlines()
    i = 0
    while i < len(lines):
        m = FENCE.match(lines[i])
        if not m:
            i += 1
            continue
        fence, info, start = m.group("fence"), m.group("info").split(), i + 1
        body = []
        i += 1
        while i < len(lines) and not lines[i].strip().startswith(fence):
            body.append(lines[i])
            i += 1
        i += 1
        if len(info) >= 2 and info[0] in ("sql", "bash", "sh") and "test" in info[1:]:
            yield start, info[0], set(info[1:]), "\n".join(body) + "\n"


def run(lang: str, flags: set[str], body: str) -> subprocess.CompletedProcess:
    env = dict(os.environ, NO_COLOR="1")
    if lang == "sql":
        target = "replica" if "replica" in flags else "primary"
        cmd = ["./lab", "sql", target, "--table"]
    else:
        cmd = ["bash", "-euo", "pipefail", "-c", body]
        body = ""
    return subprocess.run(cmd, input=body, cwd=LAB_DIR, env=env, text=True,
                          capture_output=True, timeout=TIMEOUT)


def default_files() -> list[Path]:
    return sorted((REPO / "courses").glob("*/*/*.md"))


def main(argv: list[str]) -> int:
    listing = "--list" in argv
    files = [Path(a).resolve() for a in argv if not a.startswith("--")] or default_files()
    failures = total = 0
    for path in files:
        found = list(blocks(path))
        if not found:
            continue
        rel = path.relative_to(REPO) if path.is_relative_to(REPO) else path
        print(f"== {rel} ({len(found)} block(s))")
        for line, lang, flags, body in found:
            total += 1
            label = f"{rel}:{line} [{lang} {' '.join(sorted(flags))}]"
            if listing:
                print(f"   {label}")
                continue
            try:
                res = run(lang, flags, body)
                ok = (res.returncode != 0) if "expect-error" in flags else (res.returncode == 0)
                out = (res.stdout + res.stderr).strip()
            except subprocess.TimeoutExpired:
                ok, out = False, f"timed out after {TIMEOUT}s"
            if ok:
                print(f"   ok   {label}")
            else:
                failures += 1
                print(f"   FAIL {label}")
                print("        " + "\n        ".join(body.strip().splitlines()))
                print("        --- output ---")
                print("        " + "\n        ".join(out.splitlines()[-25:]))
    print(f"\n{total - failures}/{total} blocks passed" if not listing else f"\n{total} block(s)")
    return failures


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
