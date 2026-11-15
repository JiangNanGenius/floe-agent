#!/usr/bin/env python3
"""Read-only source/packaging boundary verification for FloeGameNarrativeKit.

This does not execute Swift, a browser, an engine or a VM. It checks the source
layout, support/shell resource files, generated-artifact contract strings,
profile labels and the prepared notice bundle hashes, then writes a JSON
receipt. Runtime/Node/native checks remain separate and must be run after the
Root native window is released.
"""
from pathlib import Path
import argparse
import hashlib
import json
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
SUPPORT = ROOT / "Sources/FloeGameNarrativeKit/Resources/Support"
SHELLS = ROOT / "Sources/FloeGameNarrativeKit/Resources/Shells"
ADAPTERS = ROOT / "Sources/FloeGameNarrativeKit"
TESTS = ROOT / "Tests/FloeGameNarrativeKitTests"

EXPECTED_SUPPORT = {
    "floe-host.js", "ink-bridge.js", "ink.css", "twine-bootstrap.js",
    "twine-bridge.js", "wasm4-bridge.js", "wasm4-shell.css", "tic80-boot.js",
    "tic80-bridge.js", "tic80.css", "microstudio-bridge.js", "microstudio.css",
}
EXPECTED_SHELLS = {"ink.html", "wasm4.html", "tic80.html", "microstudio.html"}
EXPECTED_BUNDLE_TERMS = {
    "tic80": ["GPL-3.0-or-later", "LGPL-2.1-or-later", "blip_buf", "SOURCE-OFFER"],
    "wasm4": ["Lit", "BSD-3-Clause", "Press Start 2P", "OFL-1.1"],
    "twine": ["jQuery", "MIT", "Unlicense"],
}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--resources", help="Prepared resources-mpl-1 directory (optional)")
    parser.add_argument("--evidence", help="Write JSON receipt to this path")
    args = parser.parse_args()

    checks = []

    def ok(name: str, value: bool, detail=None):
        checks.append({"check": name, "passed": bool(value), "detail": detail})

    support_names = {p.name for p in SUPPORT.glob("*") if p.is_file()}
    shell_names = {p.name for p in SHELLS.glob("*") if p.is_file()}
    ok("support resource set", support_names == EXPECTED_SUPPORT, sorted(support_names))
    ok("shell resource set", shell_names == EXPECTED_SHELLS, sorted(shell_names))

    for path in sorted(SUPPORT.glob("*")):
        if not path.is_file():
            continue
        first = path.read_text(encoding="utf-8").splitlines()[0] if path.stat().st_size else ""
        ok("MPL header: " + path.name, first.startswith("/* SPDX-License-Identifier: MPL-2.0"),
           first[:80])
        text = path.read_text(encoding="utf-8")
        ok("readable support (not a minified one-liner): " + path.name,
           text.count("\n") >= 8 and max((len(line) for line in text.splitlines()), default=0) <= 600,
           {"lines": text.count("\n"), "maxLine": max((len(line) for line in text.splitlines()), default=0)})
        marker_free = not re.search(r"FLOE[- ](WASM-4 POSTIE|TIC-80|microStudio)|森林邮差", text)
        ok("no original game marker in support: " + path.name, marker_free)

    for path in sorted(SHELLS.glob("*.html")):
        text = path.read_text(encoding="utf-8")
        ok("shell references support host: " + path.name, "support/floe-host.js" in text)
        ok("shell has no inline FloeGame code: " + path.name,
           "window.FloeGame" not in text and "new Player(" not in text and "inkjs.Compiler" not in text)
        ok("shell has no inline script body: " + path.name,
           not re.search(r"<script(?![^>]*\bsrc=)[^>]*>\s*[^\s<]", text))

    adapter_text = "\n".join(p.read_text(encoding="utf-8") for p in ADAPTERS.glob("*.swift"))
    all_source_text = "\n".join(p.read_text(encoding="utf-8") for p in ROOT.glob("Sources/FloeGameNarrativeKit/*.swift"))
    for name in ["NarrativeArtifactBuilder", "NarrativeLicenseAugmentation", "floe-artifact.json",
                 "support/", "game/ink-sources.json", "game/story.twine.json",
                 "game/microstudio-sources.json", "game/source/"]:
        ok("adapter source references " + name, name in adapter_text)
    ok("TIC-80 selected source bundle loader present", "NarrativeSourceBundle" in all_source_text)
    ok("TIC-80 source bundle has explicit third-party-source role", "thirdPartySource" in all_source_text)
    ok("TIC-80 source status is conditional, not clearance", "not cleared" in adapter_text and "not a full LGPL clearance" in all_source_text)
    ok("no unverified public source-URL assertion", "github.com/JiangNanGenius" not in all_source_text)
    ok("no old inline ink source element", 'id=\\"ink-sources\\"' not in adapter_text)
    ok("no old inline microScript #code element", 'id=\\"code\\" type=\\"text/x-microscript\\"' not in adapter_text)
    ok("no old Twine inline bridge insertion", "bridgeScript" not in adapter_text)
    ok("no old inline HTML artifact builders", "artifactHTML" not in adapter_text)

    profiles = {
        "tic80": ["GPL-3.0-or-later", "LGPL-2.1-or-later", "blip_buf", "source/relink"],
        "wasm4": ["Lit", "BSD-3-Clause", "OFL-1.1"],
        "twine": ["jQuery", "MIT", "Unlicense"],
    }
    for engine, terms in profiles.items():
        ok("profile license bundle labels " + engine,
           all(term in adapter_text for term in terms), terms)

    test_methods = re.findall(r"func test[A-Za-z0-9_]+", "\n".join(
        p.read_text(encoding="utf-8") for p in TESTS.glob("*.swift")))
    ok("original 37 XCTest methods retained (plus boundary tests)",
       len(test_methods) >= 37, {"count": len(test_methods)})

    prep = (ROOT / "Scripts/prepare_narrative.py").read_text(encoding="utf-8")
    ok("producer carries augmentation hash receipt", "AUGMENTATION_HASHES" in prep)
    ok("producer labels conditional license bundles", "licenseBundles" in prep)
    ok("producer supports local augmentation copy", "--augmentation" in prep)

    if args.resources:
        resources = Path(args.resources)
        count = 0
        for rel, digest in {
            "tic80/THIRD-PARTY-NOTICES.md": "ce637ceabf8794820a9a328189cea9cb3310e4179c490b2bb8babd7628edf567",
            "wasm4/LIT-3.1.2-BSD-3-Clause.txt": "45d31799d0db956cc3eb5469346abbd9b7025babc5ff29fab10d7095da992ef1",
            "sugarcube/THIRD-PARTY-NOTICES.txt": "ccfc10de3c1ea3c1fa7c49473b1ef79d51f251febde5e763b86f5a4be9e81a1c",
        }.items():
            path = resources / rel
            ok("prepared notice bundle " + rel,
               path.is_file() and sha256(path) == digest,
               {"exists": path.is_file(), "sha256": sha256(path) if path.is_file() else None})
            count += 1
        receipt = resources.parent / (resources.name + "-receipt.json")
        ok("prepared resource receipt present", receipt.is_file(), str(receipt))
        ok("prepared receipt reports augmentation", receipt.is_file() and
           len(json.loads(receipt.read_text(encoding="utf-8")).get("added", [])) >= 30,
           {"added": len(json.loads(receipt.read_text(encoding="utf-8")).get("added", [])) if receipt.is_file() else 0})

    failures = [c for c in checks if not c["passed"]]
    result = {
        "format": "floe-narrative-source-boundary-verification",
        "version": 1,
        "kind": "source-only (no Swift/browser/engine/VM execution)",
        "passed": len(checks) - len(failures),
        "failed": len(failures),
        "checks": checks,
        "deferred": [
            "Swift package XCTest (native window held)",
            "actual Node/jsdom engine/glue verification on rebuilt artifacts",
            "Root AppKit/WebKit/iPad acceptance",
        ],
    }
    if args.evidence:
        path = Path(args.evidence)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"passed": result["passed"], "failed": result["failed"],
                      "deferred": result["deferred"]}, ensure_ascii=False))
    if failures:
        for failure in failures:
            print("FAIL", failure["check"], failure["detail"], file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
