#!/usr/bin/env python3
"""Verify one pinned source checkout without building anything.

A plain source tree with no .git is rejected. The build producer calls this
unconditionally for every required component so a missing .git cannot silently
skip the commit/tree/dirty checks.
"""
import argparse
import json
import os
import subprocess
import sys

GIT_ENV = dict(os.environ, GIT_TERMINAL_PROMPT="0", GIT_ASKPASS="/usr/bin/false")


def git(path, *args):
    return subprocess.run(["git", "-C", path, *args], env=GIT_ENV, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("name")
    ap.add_argument("path")
    ap.add_argument("--commit", required=True)
    ap.add_argument("--tree")
    args = ap.parse_args()
    result = {"name": args.name, "path": args.path,
              "expectedCommit": args.commit, "expectedTree": args.tree,
              "ok": False, "errors": []}
    path = args.path
    if not os.path.isdir(path):
        result["errors"].append("source directory missing")
    elif not os.path.exists(os.path.join(path, ".git")):
        result["errors"].append("not a git checkout (missing .git)")
    else:
        head = git(path, "rev-parse", "HEAD")
        if head.returncode != 0:
            result["errors"].append("git rev-parse HEAD failed")
        else:
            result["actualCommit"] = head.stdout.strip()
        tree = git(path, "rev-parse", "HEAD^{tree}")
        if tree.returncode == 0:
            result["actualTree"] = tree.stdout.strip()
        status = git(path, "status", "--porcelain")
        if status.returncode != 0:
            result["errors"].append("git status failed")
        else:
            result["dirty"] = bool(status.stdout.strip())
        if result.get("actualCommit") != args.commit:
            result["errors"].append("commit mismatch")
        if args.tree and result.get("actualTree") != args.tree:
            result["errors"].append("tree mismatch")
        if result.get("dirty"):
            result["errors"].append("worktree dirty")
    result["ok"] = not result["errors"]
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if result["ok"] else 2


if __name__ == "__main__":
    sys.exit(main())
