"""Writes each `run: |` block of action.yml to <out_dir>/<n>.sh and prints
"<n>\t<step name>" per step. Standard library only, so it runs on any runner;
it relies on action.yml using literal block scalars for every run: script."""
import os
import re
import sys

action, out_dir = sys.argv[1], sys.argv[2]
lines = open(action, encoding="utf-8").read().splitlines()

name = ""
n = 0
i = 0
while i < len(lines):
    line = lines[i]
    m = re.match(r"^\s*- name:\s*(.+)$", line)
    if m:
        name = m.group(1).strip()
    m = re.match(r"^(\s*)run:\s*\|\s*$", line)
    if m:
        key_indent = len(m.group(1))
        body = []
        i += 1
        while i < len(lines):
            cur = lines[i]
            if cur.strip() and len(cur) - len(cur.lstrip()) <= key_indent:
                break
            body.append(cur)
            i += 1
        indent = min(len(b) - len(b.lstrip()) for b in body if b.strip())
        n += 1
        with open(os.path.join(out_dir, f"{n}.sh"), "w", encoding="utf-8") as f:
            f.write("\n".join(b[indent:] for b in body) + "\n")
        print(f"{n}\t{name}")
        continue
    i += 1
