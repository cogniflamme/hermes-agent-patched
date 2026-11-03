"""Keep only the requirement blocks whose package Hermes' venv already has.

  python select.py REQUIREMENTS > FILTERED

A Hermes release that drops a package must not get it back from us, and one
that already ships the fixed version is left alone (uv sees it satisfied).
"""
import importlib.metadata as md
import re
import sys

blocks, cur = [], []
for line in open(sys.argv[1]):
    if re.match(r"^[A-Za-z0-9_.-]+==", line):
        cur = [line]; blocks.append(cur)
    elif line.startswith((" ", "\t")) and cur:
        cur.append(line)
    else:
        cur = []
for b in blocks:
    name = b[0].split("==")[0]
    try:
        have = md.version(name)
    except md.PackageNotFoundError:
        print(f"skip {name}: not in this Hermes", file=sys.stderr)
        continue
    print(f"upgrade {name} {have} -> {b[0].split('==')[1].split()[0]}", file=sys.stderr)
    sys.stdout.write("".join(b))
