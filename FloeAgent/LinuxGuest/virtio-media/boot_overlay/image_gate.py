#!/usr/bin/env python3
"""Validate a staged video overlay and (optionally) its image manifest.

This is the metadata gate the App-side image resolver can mirror:
  * deviceCapabilities.videoAcceleration is explicitly true;
  * the overlay carries the pinned virtio-media dependency closure and a
    modules.dep that names every staged module;
  * floe-codec is a 64-bit little-endian AArch64 ELF at the installed path;
  * a video-enabled image contains the same executable in its project base;
  * every receipt hash matches the bytes on disk.

It does not boot, load a module, or claim /dev/video operation. Exit 0 only
when every requested check passed; the report is JSON on stdout.
"""
import argparse, hashlib, json, struct, sys
from pathlib import Path

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

def fail(errors, message):
    errors.append(message)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--overlay", type=Path, required=True)
    ap.add_argument("--manifest", type=Path)
    ap.add_argument("--base-root", type=Path,
                    help="unpacked clean /base used by project root filesystems")
    ap.add_argument("--expected-kernel", default="6.12.107+deb13-arm64")
    args = ap.parse_args()
    overlay = args.overlay
    errors, checks = [], []
    receipt_path = overlay / "INSTALL_RECEIPT.json"
    receipt = {}
    if not receipt_path.is_file():
        fail(errors, "missing INSTALL_RECEIPT.json")
    else:
        receipt = json.loads(receipt_path.read_text())
        checks.append("receipt-present")
        if receipt.get("kernelRelease") != args.expected_kernel:
            fail(errors, "receipt kernelRelease mismatch")
        for entry in receipt.get("modules", []):
            path = overlay / "lib" / "modules" / Path(entry["initrdPath"]).name
            if not path.is_file():
                fail(errors, f"missing module {entry['initrdPath']}")
                continue
            if sha256(path) != entry["sha256"]:
                fail(errors, f"module hash mismatch {entry['initrdPath']}")
        codec = receipt.get("floeCodec", {})
        codec_path = overlay / "usr" / "local" / "bin" / "floe-codec"
        if not codec_path.is_file():
            fail(errors, "missing usr/local/bin/floe-codec")
        else:
            blob = codec_path.read_bytes()[:20]
            if len(blob) < 20 or blob[:4] != b"\x7fELF" or blob[4] != 2 or blob[5] != 1 \
                    or int.from_bytes(blob[18:20], "little") != 183:
                fail(errors, "floe-codec is not 64-bit little-endian AArch64 ELF")
            actual = sha256(codec_path)
            if codec.get("sha256") != actual:
                fail(errors, "floe-codec receipt hash mismatch")
            if not (codec_path.stat().st_mode & 0o111):
                fail(errors, "floe-codec is not executable")
        dep = overlay / "lib" / "modules" / "modules.dep"
        if not dep.is_file():
            fail(errors, "missing lib/modules/modules.dep")
        else:
            staged = {p.name for p in (overlay / "lib" / "modules").glob("*.ko")}
            named = set()
            for line in dep.read_text().splitlines():
                if ":" in line:
                    left, right = line.split(":", 1)
                    named.add(Path(left.strip()).name)
                    for dep_name in right.split():
                        named.add(Path(dep_name).name)
            missing = staged - named
            if missing:
                fail(errors, f"modules.dep does not name staged modules: {sorted(missing)}")

    if args.manifest:
        try:
            manifest = json.loads(args.manifest.read_text())
        except Exception as exc:
            fail(errors, f"manifest unreadable: {exc}")
            manifest = {}
        caps = (manifest.get("deviceCapabilities") or {}) if isinstance(manifest, dict) else {}
        if caps.get("videoAcceleration") is not True:
            fail(errors, "deviceCapabilities.videoAcceleration is not true")
        else:
            checks.append("manifest-video-capability")
            # The initrd has its own root. A project uses the base filesystem,
            # so a client present only in the initrd is invisible to it.
            if args.base_root is None:
                fail(errors, "video-enabled image requires --base-root to verify the project client")
            else:
                base_codec = args.base_root / "usr" / "local" / "bin" / "floe-codec"
                if not base_codec.is_file():
                    fail(errors, "missing /base/usr/local/bin/floe-codec")
                elif not (base_codec.stat().st_mode & 0o111):
                    fail(errors, "project floe-codec is not executable")
                elif sha256(base_codec) != receipt.get("floeCodec", {}).get("sha256"):
                    fail(errors, "project floe-codec differs from the verified overlay client")
                else:
                    checks.append("project-client-installed")

    report = {
        "schemaVersion": 1,
        "overlay": str(overlay),
        "manifest": str(args.manifest) if args.manifest else None,
        "baseRoot": str(args.base_root) if args.base_root else None,
        "kernelRelease": args.expected_kernel,
        "checks": checks,
        "errors": errors,
        "status": "passed" if not errors else "failed",
        "explicitlyNotProven": [
            "initrd assembly, insmod, /dev/video operation and FFmpeg/GStreamer runtime",
            "App ABI4 create, Simulator/device execution and visual acceptance",
        ],
    }
    print(json.dumps(report, indent=1))
    return 0 if not errors else 1

if __name__ == "__main__":
    sys.exit(main())
