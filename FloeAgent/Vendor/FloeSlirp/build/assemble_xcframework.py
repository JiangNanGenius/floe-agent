#!/usr/bin/env python3
"""Merge rebuilt static components and package the three Apple arm64 slices.

Run after build-platform.sh has staged all three platforms. The output must
be a new path; existing deliverables are never removed or overwritten here.
Compilation and packaging callers must use the repository's shared build lock.
"""
from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

PLATFORMS = {
    "macos": ("macos-arm64", "macos", None),
    "ios-device": ("ios-arm64", "ios", None),
    "ios-sim": ("ios-arm64-simulator", "ios", "simulator"),
}
COMPONENTS = ("libslirp.a", "libglib-2.0.a", "libpcre2-8.a", "libintl.a")


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--staging-root", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--manifests-dir", required=True, type=Path)
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists():
        parser.error("output already exists; preserve it and choose a fresh output path")
    output.parent.mkdir(parents=True, exist_ok=True)
    os.environ["ZERO_AR_DATE"] = "1"
    with tempfile.TemporaryDirectory(prefix=".floeslirp-assembly-", dir=output.parent) as scratch:
        scratch = Path(scratch)
        command = ["xcodebuild", "-create-xcframework"]
        static_sums = []
        for platform in PLATFORMS:
            source = args.staging_root / platform
            inputs = [source / "lib" / name for name in COMPONENTS]
            required_headers = [source / "include/slirp/libslirp.h",
                                source / "include/slirp/floe_host_net.h",
                                source / "lib/glib-2.0/include/glibconfig.h"]
            for path in [*inputs, *required_headers]:
                if not path.is_file():
                    raise SystemExit(f"required rebuilt input is missing: {path}")
            target = scratch / platform
            target.mkdir()
            merged = target / f"FloeSlirp-{platform}.a"
            subprocess.run(["xcrun", "libtool", "-static", "-o", str(merged),
                            *map(str, inputs)], check=True)
            headers = target / "Headers"
            shutil.copytree(source / "include", headers)
            # Preserve the qualified header layout, including both paths used
            # by the generated GLib headers. Engine consumers need slirp/ only.
            config = source / "lib/glib-2.0/include/glibconfig.h"
            for relative in ["glib-2.0/glibconfig.h", "glib-2.0/glib/glibconfig.h"]:
                destination = headers / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(config, destination)
            static_sums.append(f"{digest(merged)}  {platform}/{merged.name}")
            command += ["-library", str(merged), "-headers", str(headers)]
        packaged = scratch / "FloeSlirp.xcframework"
        subprocess.run([*command, "-output", str(packaged)], check=True)
        info = plistlib.loads((packaged / "Info.plist").read_bytes())
        libraries = {entry["LibraryIdentifier"]: entry for entry in info["AvailableLibraries"]}
        if set(libraries) != {entry[0] for entry in PLATFORMS.values()}:
            raise SystemExit("unexpected architecture/platform set in assembled XCFramework")
        for platform, (identifier, system, variant) in PLATFORMS.items():
            entry = libraries[identifier]
            if (entry["SupportedArchitectures"] != ["arm64"] or
                    entry["SupportedPlatform"] != system or
                    entry.get("SupportedPlatformVariant") != variant or
                    entry["LibraryPath"] != f"FloeSlirp-{platform}.a"):
                raise SystemExit(f"wrong slice metadata: {identifier}")
        # Rename within the same filesystem after metadata validation.
        packaged.rename(output)
    args.manifests_dir.mkdir(parents=True, exist_ok=True)
    (args.manifests_dir / "SHA256SUMS-static").write_text("\n".join(static_sums) + "\n")
    entries = [f"{digest(path)}  FloeSlirp.xcframework/{path.relative_to(output)}"
               for path in sorted(output.rglob("*")) if path.is_file()]
    (args.manifests_dir / "SHA256SUMS-xcframework").write_text("\n".join(entries) + "\n")
    print(f"Assembled three arm64 slices: {output}")


if __name__ == "__main__":
    main()
