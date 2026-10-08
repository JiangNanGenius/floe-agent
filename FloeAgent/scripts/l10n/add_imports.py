#!/usr/bin/env python3
"""Insert `import FloeCore` into files that reference FloeL10n but lack it."""
import os
import re
import subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def main():
    out = subprocess.run(
        ["rg", "-l", r"FloeL10n\.",
         os.path.join(ROOT, "FloeApp"), os.path.join(ROOT, "Sources"),
         "-g", "*.swift"],
        capture_output=True, text=True).stdout.splitlines()
    added = 0
    for path in out:
        rel = os.path.relpath(path, ROOT)
        if rel.startswith(os.path.join("Sources", "FloeCore")):
            continue
        with open(path, encoding="utf-8") as fh:
            s = fh.read()
        if re.search(r"(?m)^import FloeCore\s*$", s):
            continue
        imports = list(re.finditer(r"(?m)^import [A-Za-z0-9_]+\s*$", s))
        if not imports:
            print("no import block:", rel)
            continue
        at = imports[-1].end()
        s = s[:at] + "\nimport FloeCore" + s[at:]
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(s)
        added += 1
    print("imports added:", added)


if __name__ == "__main__":
    main()
