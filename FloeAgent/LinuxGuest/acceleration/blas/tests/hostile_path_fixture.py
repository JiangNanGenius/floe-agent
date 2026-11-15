#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Focused source-level fixture for hostile-but-valid HOME/XDG path text.

The wrapper must emit valid JSON and must not interpolate a path containing a
quote, backslash, newline or other control byte.  We choose explicit rejection
for such bytes: `configPath` becomes null and `configPathState` says why.  A
safe path containing spaces remains a normal string.

No native compiler, Vulkan device or guest is used.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WRAPPER = ROOT / "scripts/floe-blas-run"
SHELL_LIBRARY = ROOT / "scripts/floe-blas-shell.sh"


def run_status(environment: dict[str, str]) -> dict:
    result = subprocess.run(
        [shutil.which("sh") or "/bin/sh", str(WRAPPER), "--status"],
        capture_output=True, text=True, env=environment)
    if result.returncode != 0:
        raise SystemExit("status failed: %s\n%s" % (result.returncode,
                                                    result.stderr))
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise SystemExit("status emitted invalid JSON: %s\n%s" %
                         (error, result.stdout))


def main() -> int:
    failures: list[str] = []
    base = Path(tempfile.mkdtemp(prefix="floe-blas-hostile-"))
    try:
        hostile = base / 'quote"back\\slash\nline'
        hostile.mkdir()
        environment = dict(os.environ)
        environment["HOME"] = str(hostile)
        environment["XDG_CONFIG_HOME"] = str(hostile)
        status = run_status(environment)
        if status.get("configPath") is not None:
            failures.append("hostile config path was emitted: %r" %
                            status.get("configPath"))
        if status.get("configPathState") != "unsupported-bytes":
            failures.append("hostile path state is %r" %
                            status.get("configPathState"))
        if not status.get("ok"):
            failures.append("hostile status was not a valid JSON success")

        safe = base / "safe path with spaces"
        safe.mkdir()
        environment["HOME"] = str(safe)
        environment["XDG_CONFIG_HOME"] = str(safe)
        status = run_status(environment)
        expected = str(safe / "floe-acceleration" / "blas.conf")
        if status.get("configPath") != expected:
            failures.append("safe spaced path not preserved: %r" %
                            status.get("configPath"))
        if status.get("configPathState") != "ok":
            failures.append("safe spaced path state is %r" %
                            status.get("configPathState"))

        # Direct predicate checks: quote, backslash, newline, tab, DEL and
        # non-ASCII bytes are unsupported; printable spaces are supported.
        checks = [
            ("plain/path", 0),
            ("path with spaces", 0),
            ('path"quote', 1),
            ("path\\backslash", 1),
            ("path\nnewline", 1),
            ("path\ttab", 1),
            ("path\x7fdel", 1),
            ("path\u00e9utf8", 1),
        ]
        for value, expected_code in checks:
            result = subprocess.run(
                [shutil.which("sh") or "/bin/sh", "-c",
                 '. "$1"; floe_blas_json_safe "$2"', "sh",
                 str(SHELL_LIBRARY), value],
                capture_output=True, text=True)
            if result.returncode != expected_code:
                failures.append("json_safe(%r) exit %d, expected %d" %
                                (value, result.returncode, expected_code))

        if failures:
            print("hostile path fixture: FAIL", file=sys.stderr)
            for failure in failures:
                print("  - " + failure, file=sys.stderr)
            return 1
        print("hostile path fixture: PASS")
        return 0
    finally:
        shutil.rmtree(base, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
