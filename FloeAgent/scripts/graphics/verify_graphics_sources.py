#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Read-only source and contract checks for the Linux graphics build inputs.

Checks performed:
  * SOURCE-SELECTION.json parses and its patch digests match the files;
  * SERIES.json is sequential and every patch exists with its recorded digest;
  * no selected patch or production graphics file embeds a private absolute path;
  * the Adopted FloeVirtualGPU capability-truth symbols are present;
  * CAPABILITY-POLICY.json is well formed and only names known gates;
  * retained license files exist.

This script never builds, downloads, boots a guest or touches a device. Pass
--tree to additionally dry-run the guest Mesa patch against an extracted
pristine Mesa 25.0.7 tree.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
GRAPHICS = REPO / "LinuxGuest" / "image" / "graphics"
SELECTION = GRAPHICS / "SOURCE-SELECTION.json"
POLICY = GRAPHICS / "CAPABILITY-POLICY.json"
SERIES = GRAPHICS / "patches" / "host-mesa-30da3918" / "SERIES.json"
GUEST_PATCH = GRAPHICS / "patches" / "guest-mesa-25.0.7" / "0001-floe-x11-cpu-present-complete.patch"
FVGPU = REPO / "ThirdParty" / "FloeVirtualGPU"
PRIVATE_PATH = re.compile(rb"/(?:Volumes/TECLAST|Users/jiangnangenius|home/[A-Za-z0-9_.-]+)/")
KNOWN_GATES = {"venusVulkan", "openGL", "shaderCache", "openCL"}
REQUIRED_FVGPU_MARKERS = (
    b"session_budget_bytes",
    b"floe_gpu_ledger_faulted",
    b"fvgpu_shm_fd_covers",
    b"fvgpu_trace",
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


class Checker:
    def __init__(self) -> None:
        self.failures: list[str] = []
        self.checks = 0

    def check(self, condition: bool, message: str) -> None:
        self.checks += 1
        if not condition:
            self.failures.append(message)

    def finish(self, summary: dict) -> int:
        summary["checks"] = self.checks
        summary["failures"] = self.failures
        summary["status"] = "passed" if not self.failures else "failed"
        print(json.dumps(summary, indent=2, ensure_ascii=False))
        return 0 if not self.failures else 1


def verify_selection(c: Checker) -> dict:
    c.check(SELECTION.is_file(), f"missing {SELECTION}")
    if not SELECTION.is_file():
        return {}
    selection = json.loads(SELECTION.read_text())
    c.check(selection.get("schema") == "floe.linux-graphics.source-selection.v1",
            "unexpected SOURCE-SELECTION schema")
    streams = selection.get("streams", {})
    for name in ("installedGuestMesa", "nextHostKosmicKrisp"):
        c.check(name in streams, f"missing stream {name}")
    guest = streams.get("installedGuestMesa", {})
    for patch in guest.get("patches", []):
        path = GRAPHICS / patch["file"]
        c.check(path.is_file(), f"missing guest patch {path}")
        if path.is_file():
            c.check(sha256(path) == patch["sha256"], f"guest patch digest mismatch {path}")
    host = streams.get("nextHostKosmicKrisp", {})
    c.check(host.get("patchSeries", {}).get("count", 0) == 96,
            "host patch series must contain 96 entries")
    return selection


def verify_series(c: Checker) -> list[dict]:
    c.check(SERIES.is_file(), f"missing {SERIES}")
    if not SERIES.is_file():
        return []
    data = json.loads(SERIES.read_text())
    patches = data.get("patches", [])
    c.check(data.get("count") == len(patches), "SERIES count does not match entries")
    orders = [entry["order"] for entry in patches]
    c.check(orders == list(range(1, len(patches) + 1)), "patch order is not 1...N sequential")
    for entry in patches:
        path = SERIES.parent / entry["file"]
        c.check(path.is_file(), f"missing series patch {path}")
        if path.is_file():
            c.check(sha256(path) == entry["sha256"], f"series patch digest mismatch {path}")
    return patches


def verify_no_private_paths(c: Checker) -> int:
    files = 0
    for root in (GRAPHICS / "patches", FVGPU / "src", FVGPU / "include", GRAPHICS):
        for path in root.rglob("*"):
            if not path.is_file() or path.suffix not in {".patch", ".c", ".h", ".md", ".json", ".py"}:
                continue
            files += 1
            c.check(PRIVATE_PATH.search(path.read_bytes()) is None,
                    f"private absolute path in {path}")
    return files


def verify_fvgpu(c: Checker) -> None:
    header = FVGPU / "include" / "floe_virtual_gpu.h"
    priv = FVGPU / "src" / "fvgpu_priv.h"
    ledger = FVGPU / "src" / "fvgpu_ledger.c"
    resources = FVGPU / "src" / "fvgpu_resources.c"
    trace = FVGPU / "src" / "fvgpu_trace.h"
    for path in (header, priv, ledger, resources, trace):
        c.check(path.is_file(), f"missing {path}")
    if not all(path.is_file() for path in (header, priv, ledger, resources)):
        return
    joined = b"\n".join(path.read_bytes() for path in (header, priv, ledger, resources))
    for marker in REQUIRED_FVGPU_MARKERS:
        c.check(marker in joined, f"FloeVirtualGPU source is missing {marker.decode()}")


def verify_policy(c: Checker) -> dict:
    c.check(POLICY.is_file(), f"missing {POLICY}")
    if not POLICY.is_file():
        return {}
    policy = json.loads(POLICY.read_text())
    c.check(policy.get("schema") == "floe.linux-graphics.capability-policy.v1",
            "unexpected capability policy schema")
    capabilities = policy.get("capabilities", {})
    for name, rule in capabilities.items():
        c.check(isinstance(rule.get("requires"), list) and bool(rule["requires"]),
                f"capability {name} has no required artifacts")
        for gate in rule.get("gates", []):
            c.check(gate in KNOWN_GATES, f"capability {name} names unknown gate {gate}")
    c.check("openCL" in capabilities, "openCL must be explicitly gated")
    c.check("video.hardwareDecode" in capabilities, "video hardwareDecode must be explicitly gated")
    return policy


def verify_licenses(c: Checker) -> None:
    for relative in (
        "LICENSES/Mesa/MIT",
        "LICENSES/Hadron-LICENSE",
        "LICENSES/virglrenderer-LICENSE.txt",
    ):
        c.check((GRAPHICS / relative).is_file(), f"missing license {relative}")


def verify_guest_patch(tree: Path | None, c: Checker) -> None:
    if tree is None:
        return
    c.check((tree / "src" / "vulkan" / "wsi" / "wsi_common_x11.c").is_file(),
            f"{tree} does not look like a Mesa source tree")
    if not (tree / "src" / "vulkan" / "wsi" / "wsi_common_x11.c").is_file():
        return
    result = subprocess.run(
        ["/usr/bin/patch", "-p1", "-F", "0", "--batch", "--forward", "--dry-run", "-i", str(GUEST_PATCH)],
        cwd=tree, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    c.check(result.returncode == 0, f"guest Mesa patch does not apply to {tree}:\n{result.stdout}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tree", type=Path,
                        help="optional extracted pristine Mesa 25.0.7 tree for a read-only patch check")
    args = parser.parse_args()
    c = Checker()
    selection = verify_selection(c)
    patches = verify_series(c)
    files = verify_no_private_paths(c)
    verify_fvgpu(c)
    policy = verify_policy(c)
    verify_licenses(c)
    verify_guest_patch(args.tree.expanduser().resolve() if args.tree else None, c)
    summary = {
        "schema": "floe.linux-graphics.source-verification.v1",
        "selection": str(SELECTION.relative_to(REPO)),
        "seriesPatches": len(patches),
        "capabilities": sorted(policy.get("capabilities", {})),
        "scannedFiles": files,
        "streams": sorted(selection.get("streams", {})),
    }
    return c.finish(summary)


if __name__ == "__main__":
    raise SystemExit(main())
