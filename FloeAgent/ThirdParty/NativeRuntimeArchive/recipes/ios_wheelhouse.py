#!/usr/bin/env python3
"""Emit shell-evaluable build settings for one ios-wheelhouse package.

Usage: ios_wheelhouse.py env <package>
Prints KEY=VALUE lines consumed by build_ios_wheel.sh via eval.
"""
from __future__ import annotations

import json
import shlex
import sys
from pathlib import Path

MANIFEST = Path(__file__).resolve().parents[2] / "ios-wheelhouse" / "manifest.json"


def main() -> int:
    if len(sys.argv) != 3 or sys.argv[1] != "env":
        print(__doc__, file=sys.stderr)
        return 2
    name = sys.argv[2]
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    package = manifest["packages"].get(name)
    if package is None:
        print(f"unknown wheelhouse package: {name}", file=sys.stderr)
        return 2
    sdist = package["sdist"]
    env = dict(package.get("env", {}))
    if not package.get("pure"):
        env.update({
            "PIP_EXTRA_INDEX_URL": manifest["buildDepsIndex"],
            "IPHONEOS_DEPLOYMENT_TARGET": manifest["deploymentTarget"],
        })
    values = {
        "FLOE_WHEEL_NAME": name,
        "FLOE_WHEEL_VERSION": package["version"],
        "FLOE_WHEEL_SDIST_URL": sdist["url"],
        "FLOE_WHEEL_SDIST_SHA256": sdist["sha256"],
        "FLOE_WHEEL_SDIST_DIR": sdist["dir"],
        "FLOE_WHEEL_SMOKE": package["smoke"],
        "FLOE_WHEEL_PURE": "1" if package.get("pure") else "0",
        "FLOE_WHEEL_RUST": "1" if package.get("rust") else "0",
        "FLOE_WHEEL_ENV": " ".join(f"{key}={shlex.quote(value)}" for key, value in env.items()),
        "FLOE_WHEEL_STRIP_BUILD_REQUIRES": ",".join(package.get("stripBuildRequires", [])),
    }
    for key, value in values.items():
        print(f"{key}={shlex.quote(value)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
