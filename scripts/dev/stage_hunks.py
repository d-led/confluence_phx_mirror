#!/usr/bin/env python3
"""Stage only the hunks of a file whose added/removed lines match a pattern.

    python3 scripts/dev/stage_hunks.py <file> <regex> [<regex> ...]

Used in a checkout where two people are editing the same file: it builds a
patch from `git diff`, keeps the hunks that mention the given patterns, and
applies that patch to the index only.
"""
import re
import subprocess
import sys
import tempfile

path = sys.argv[1]
patterns = [re.compile(p) for p in sys.argv[2:]]

diff = subprocess.run(
    ["git", "diff", "-U3", "--", path], capture_output=True, text=True, check=True
).stdout

lines = diff.splitlines(keepends=True)
head = []
hunks = []
current = None
for line in lines:
    if line.startswith("@@"):
        if current:
            hunks.append(current)
        current = [line]
    elif current is None:
        head.append(line)
    else:
        current.append(line)
if current:
    hunks.append(current)

keep = [h for h in hunks if any(p.search("".join(h)) for p in patterns)]
if not keep:
    sys.exit(f"no hunk of {path} matches {sys.argv[2:]}")

with tempfile.NamedTemporaryFile("w", suffix=".patch", delete=False) as patch:
    patch.write("".join(head) + "".join("".join(h) for h in keep))
    name = patch.name

subprocess.run(["git", "apply", "--cached", "--recount", name], check=True)
print(f"staged {len(keep)} of {len(hunks)} hunks of {path}")
