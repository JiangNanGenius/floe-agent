#!/usr/bin/env python3
"""Verify the Debian trixie ARM64 sysroot and loader bytes read-only.

This replaces the predecessor's inline Vulkan checks with a reusable strict
input check. It does not install the .deb, configure CMake or execute anything
from the sysroot.
"""
import argparse
import hashlib
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
REPO = ROOT.parents[3]


def sha256_file(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pins", type=pathlib.Path, default=ROOT / "PINS.json")
    ap.add_argument("--out", type=pathlib.Path)
    args = ap.parse_args()
    pins = json.loads(args.pins.read_text())
    sysroot = pathlib.Path(pins["toolchain"]["sysroot"])
    if not sysroot.is_absolute():
        sysroot = (REPO / sysroot).resolve()
    result = {
        "schema": 1,
        "sysroot": str(sysroot),
        "checks": [],
        "errors": [],
        "executedAnything": False,
    }

    def check(name, condition, detail=None):
        entry = {"check": name, "ok": bool(condition)}
        if detail is not None:
            entry["detail"] = detail
        result["checks"].append(entry)
        if not condition:
            result["errors"].append(f"{name}: {detail}" if detail else name)

    check("sysroot.exists", sysroot.is_dir(), str(sysroot))
    vulkan = pins["components"]["vulkan"]
    for rel, expected in vulkan["sysrootPaths"].items():
        p = sysroot / rel
        if not p.is_file():
            check(f"file:{rel}", False, "missing")
            continue
        actual = sha256_file(p)
        check(f"file:{rel}", actual == expected,
              None if actual == expected else f"{actual} != {expected}")
    ocl = pins["components"]["ocl-icd"]
    debs = list((ROOT / "deps").glob("ocl-icd-libopencl1_*.deb")) if (ROOT / "deps").is_dir() else []
    if debs:
        for deb in debs:
            actual = sha256_file(deb)
            check(f"deb:{deb.name}", actual == ocl["binarySHA256"],
                  None if actual == ocl["binarySHA256"] else f"{actual} != {ocl['binarySHA256']}")
            check(f"deb:{deb.name}:bytes", deb.stat().st_size == ocl["binaryBytes"],
                  None if deb.stat().st_size == ocl["binaryBytes"] else f"{deb.stat().st_size} != {ocl['binaryBytes']}")
    else:
        result["checks"].append({
            "check": "deb:ocl-icd",
            "ok": True,
            "detail": "loader .deb not present in this source package; runtime install is an explicit later gate",
        })
    result["ok"] = not result["errors"]
    result["status"] = "pass" if result["ok"] else "fail"
    text = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(text)
    print(text, end="")
    return 0 if result["ok"] else 2


if __name__ == "__main__":
    sys.exit(main())
