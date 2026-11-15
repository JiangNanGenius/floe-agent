#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Read-only contracts for the included Linux acceleration source trees.

Checks that the product tree contains the final video host/guest sources,
the ABI1 header, licenses, the BLAS/Blender/OpenCL packages and the dispatcher
entries, and that no private absolute path or worker detail leaked into them.
No build, VM, codec, GPU or device is used.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
VIDEO_HOST = REPO / "FloeAgent" / "Modules" / "FloeLinuxVideo"
VIDEO_GUEST = REPO / "FloeAgent" / "LinuxGuest" / "virtio-media"
VIDEO_CLIENT = REPO / "FloeAgent" / "LinuxGuest" / "acceleration" / "video"
BLAS = REPO / "FloeAgent" / "LinuxGuest" / "acceleration" / "blas"
BLENDER = REPO / "FloeAgent" / "LinuxGuest" / "acceleration" / "blender"
OPENCL = REPO / "FloeAgent" / "LinuxGuest" / "acceleration" / "opencl"
ACCEL = REPO / "FloeAgent" / "LinuxGuest" / "acceleration" / "floe-accel"
ROOTS = (VIDEO_HOST, VIDEO_GUEST, VIDEO_CLIENT, BLAS, BLENDER, OPENCL,
         ACCEL.parent / "graphics")
PRIVATE = re.compile(r"/(?:Volumes|Users|home)/[A-Za-z0-9_.-]+/|job-[0-9a-f]{6,}")


def check(condition: bool, message: str, failures: list[str]) -> None:
    if not condition:
        failures.append(message)


def main() -> int:
    failures: list[str] = []
    checks = 0

    def add(condition: bool, message: str) -> None:
        nonlocal checks
        checks += 1
        check(condition, message, failures)

    for root in ROOTS:
        add(root.is_dir(), f"missing source root {root}")
    for path in (
        VIDEO_HOST / "Package.swift",
        VIDEO_HOST / "Sources/FloeLinuxVideoNative/include/floe_linux_video.h",
        VIDEO_HOST / "Sources/FloeLinuxVideoHost/FLVHostPublic.m",
        VIDEO_HOST / "Sources/FloeLinuxVideoBroker/FLVBrokerServer.c",
        VIDEO_GUEST / "driver/Kbuild",
        VIDEO_GUEST / "scripts/build_module.py",
        VIDEO_GUEST / "boot_overlay/install_recipe.py",
        VIDEO_CLIENT / "floe_codec.c",
        VIDEO_CLIENT / "Makefile",
        BLAS / "Makefile",
        BLAS / "build/build_spirv.py",
        BLAS / "scripts/install-floe-blas.sh",
        BLENDER / "floe-blender",
        BLENDER / "install.sh",
        ACCEL.parent / "graphics/floe_gl_probe.py",
        OPENCL / "tools/floe_opencl_probe.py",
        REPO / "FloeAgent" / "Qualification" / "Graphics" / "acceleration_guest_checks.sh",
        OPENCL / "PINS.json",
        OPENCL / "patches/0001-floe-private-icd-output-name.patch",
        OPENCL / "scripts/build_clvk_runtime_aarch64.sh",
        ACCEL,
    ):
        add(path.exists(), f"missing required source {path.relative_to(REPO)}")

    for root in ROOTS:
        for path in root.rglob("*"):
            if ".build" in path.parts:
                continue
            if not path.is_file() or path.suffix in {".o", ".a", ".so", ".dylib", ".bin", ".cpio", ".gz"}:
                continue
            if path.stat().st_size > 4 * 1024 * 1024:
                continue
            try:
                text = path.read_text(errors="ignore")
            except OSError:
                continue
            match = PRIVATE.search(text)
            if match:
                add(False, f"private path/worker marker in {path.relative_to(REPO)}: {match.group(0)}")

    if (VIDEO_HOST / "Sources/FloeLinuxVideoNative/include/floe_linux_video.h").is_file():
        header = (VIDEO_HOST / "Sources/FloeLinuxVideoNative/include/floe_linux_video.h").read_text()
        add("FLV_ABI_VERSION 1u" in header, "video C ABI version changed")
        add(len(re.findall(r"\bflv_[a-z_]+\(", header)) >= 12, "video C ABI exports are incomplete")

    if (VIDEO_CLIENT / "Makefile").is_file():
        makefile = (VIDEO_CLIENT / "Makefile").read_text()
        add("floe-codec" in makefile, "video client target is not floe-codec")

    if (BLAS / "Makefile").is_file():
        makefile = (BLAS / "Makefile").read_text()
        add("libfloe_blas.so" in makefile, "BLAS provider target changed")
        add("SPV_HEADERS" in makefile, "BLAS build no longer requires generated SPIR-V headers")

    if (ACCEL).is_file():
        accel = ACCEL.read_text()
        for command in ("status", "graphics", "info", "egl", "video", "compute",
                        "opencl", "blender", "floe-gl-probe", "floe-opencl-probe",
                        "--capabilities"):
            add(command in accel, f"floe-accel missing {command} entry")
        add("A Linux guest is required" in accel, "floe-accel lost its Linux-only guard")
        add("renderD128" not in accel, "floe-accel status hardcodes a DRM node index")
        add("/dev/video0" not in accel and "/dev/video1" not in accel,
            "floe-accel status hardcodes a V4L2 node index")

    pins = OPENCL / "PINS.json"
    if pins.is_file():
        data = json.loads(pins.read_text())
        add(data.get("components", {}).get("clvk", {}).get("commit") ==
            "399abf00c30b6d1d7a65d7ac06beee60b5991d7b", "clvk pin changed")
        add(data.get("components", {}).get("clspv-header", {}).get("commit") ==
            "7ee3a40e652b3649d175758f72d7af98b9450a68", "clspv pin changed")

    for license_path in (
        VIDEO_HOST / "LICENSE",
        VIDEO_CLIENT / "LICENSE",
        BLENDER / "LICENSE",
        BLAS / "LICENSE",
        VIDEO_GUEST / "LICENSE",
        OPENCL / "licenses/clvk-LICENSE",
    ):
        add(license_path.is_file(), f"missing license {license_path.relative_to(REPO)}")

    result = {
        "schema": "floe.linux-acceleration.source-contracts.v1",
        "checks": checks,
        "failures": failures,
        "status": "passed" if not failures else "failed",
    }
    print(json.dumps(result, indent=2))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
