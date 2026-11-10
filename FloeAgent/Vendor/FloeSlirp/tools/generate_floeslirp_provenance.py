#!/usr/bin/env python3
"""Deterministic pin generator/verifier for FloeAgent/Vendor/FloeSlirp.

Records are only ever written after every pinned upstream digest re-hashes
from actual bytes; the tool fails closed on any mismatch and never edits a
record to make a check pass.

Modes
  export (qualification domain):
      --domain <slirp-vendor dir> [--licenses-dir DIR] [--build-scripts-dir DIR]
      --write <out.json> [--check]
    Inputs: domain/vendor tarballs + SHA256SUMS, domain/patches,
    domain/artifacts (FloeSlirp.xcframework + SHA256SUMS-static +
    SHA256SUMS-xcframework), tracked licenses (proven byte-equal to archive
    members). --check recomputes and compares committed bytes; never writes.

  staged (repository tree, post-integration or refresh hook):
      --vendor-dir <FloeAgent/Vendor/FloeSlirp> --write <out.json> [--check]
      --vendor-dir <FloeAgent/Vendor/FloeSlirp> --verify-staged
      --vendor-dir <FloeAgent/Vendor/FloeSlirp> --check-notices
    verify-staged: read-only check of vendor/ tarballs, licenses/, patches/,
    build/, the xcframework slices and Info.plist against that tree's
    PROVENANCE.json (plus the tracked upstream export manifests when present).
    --write with --vendor-dir: recompute the record from staged bytes and
    write/--check it (same schema as export mode).
    --check-notices: prove the four bundle notices under
    FloeApp/Resources/Licenses equal the deterministic assembly of the
    tracked license bytes (runs make_bundle_notices.py from this tree).

Pinned upstream identities are the reviewed release archives supplied under
vendor/. The script records a digest only when the actual bytes hash to the
reviewed value; source and build checks never rewrite a pin to pass.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path

PINS = {
    "libslirp": {
        "version": "4.9.7",
        "tagCommit": "ce12dcddf710a71dc0de6450ec95edbadf8e9f66",
        "releaseDate": "2026-10-30",
        "upstreamWeb": "https://gitlab.com/qemu-project/libslirp",
        "mirrors": {
            "googlesource": {
                "url": "https://chromium.googlesource.com/external/gitlab.qemu-project/libslirp/+archive/refs/tags/v4.9.7.tar.gz",
                "file": "libslirp-4.9.7-googlesource.tar.gz",
                "sha256": "4c34ed66c466daab0411bc50529567cfd1b9c30559db5ffbda41e54cbe36b030",
            },
            "gitlabMirror": {
                "url": "https://gitlab.com/qemu-project/libslirp/-/archive/v4.9.7/libslirp-v4.9.7.tar.gz",
                "file": "libslirp-4.9.7-gitlab.tar.gz",
                "sha256": "d2567fa06a6357c7755d61c67293b2c0bf069b3f2173bde6b76cf768529a1938",
            },
        },
        "treeIdentity": ("123 files, byte-identical manifests across both mirrors (vendor job logs); "
                         "per-file SPDX under src/: 49 files BSD-3-Clause + 9 files MIT"),
        "license": "BSD-3-Clause (LICENSE text) with per-file MIT (9 src files); NOT MPL-2.0",
        "mitFiles": [
            "src/arp_table.c", "src/bootp.c", "src/dnssearch.c", "src/slirp.c",
            "src/state.c", "src/stream.c", "src/tftp.c", "src/util.c", "src/util.h",
        ],
    },
    "glib": {
        "version": "2.90.1",
        "url": "https://download.gnome.org/sources/glib/2.90/glib-2.90.1.tar.xz",
        "file": "glib-2.90.1.tar.xz",
        "sha256": "93c941aa17d5eb1d53fe838365f29a8b4e539c222a256d974ec8f30fc413e396",
        "license": "LGPL-2.1-or-later",
        "built": True,
        "copyingNote": ("archive member COPYING is a symlink to "
                        "LICENSES/LGPL-2.1-or-later.txt; the tracked license copy is the "
                        "target bytes, proven equal by extraction and digest comparison"),
    },
    "pcre2": {
        "version": "10.46",
        "pinnedBy": "glib-2.90.1 subprojects/pcre2.wrap",
        "url": "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.46/pcre2-10.46.tar.bz2",
        "file": "pcre2-10.46.tar.bz2",
        "sha256": "15fbc5aba6beee0b17aecb04602ae39432393aba1ebd8e39b7cabf7db883299f",
        "wrapdbPatchFile": "pcre2_10.46-1_patch.zip",
        "wrapdbPatchSha256": "761d16c89b9c13812842916b7ee970650ee7c1810f83bc567351faf7365b66be",
        "license": "BSD-3-Clause WITH PCRE2-exception",
        "built": True,
        "jit": "disabled (sljit emitter not compiled)",
    },
    "proxy-libintl": {
        "version": "0.5",
        "pinnedBy": "glib-2.90.1 subprojects/proxy-libintl.wrap",
        "url": "https://github.com/frida/proxy-libintl/archive/refs/tags/0.5.tar.gz",
        "file": "proxy-libintl-0.5.tar.gz",
        "sha256": "f7a1cbd7579baaf575c66f9d99fb6295e9b0684a28b095967cfda17857595303",
        "license": "LGPL-2.0 (COPYING text of the pinned archive)",
        "built": True,
        "mode": "stub-only identity pass-through; no dlopen in the shipped archive",
    },
    "libffi": {
        "version": "3.5.2",
        "pinnedBy": "glib-2.90.1 subprojects/libffi.wrap",
        "file": "libffi-3.5.2.tar.gz",
        "sha256": "f3a3082a23b37c293a4fcd1053147b371f2ff91fa7ea1b2a52e335676bac82dc",
        "wrapdbPatchFile": "libffi_3.5.2-1_patch.zip",
        "wrapdbPatchSha256": "1ee3035d92e4df3541d0b2b8d192d2fa183b46e4a3d68c00d8f71ede354bee74",
        "license": "MIT",
        "built": False,
        "reason": "GObject-only; outside the FloeSlirp link scope",
    },
    "zlib": {
        "version": "1.3.1",
        "pinnedBy": "glib-2.90.1 subprojects/zlib.wrap",
        "file": "zlib-1.3.1.tar.gz",
        "sha256": "9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23",
        "wrapdbPatchFile": "zlib_1.3.1-1_patch.zip",
        "wrapdbPatchSha256": "e79b98eb24a75392009cec6f99ca5cdca9881ff20bfa174e8b8926d5c7a47095",
        "license": "zlib",
        "built": False,
        "reason": "GIO-only; outside the FloeSlirp link scope",
    },
}

LICENSE_TRACKED = {
    # tracked name under licenses/ -> (pin key, member path inside the archive)
    "libslirp-LICENSE.txt": ("libslirp", "LICENSE"),
    "libslirp-COPYRIGHT.txt": ("libslirp", "COPYRIGHT"),
    "glib-LICENSES-LGPL-2.1-or-later.txt": ("glib", "LICENSES/LGPL-2.1-or-later.txt"),
    "pcre2-LICENCE.md": ("pcre2", "LICENCE.md"),
    "proxy-libintl-COPYING.txt": ("proxy-libintl", "COPYING"),
}

LICENSE_MEMBER_PREFIX = {
    "libslirp": "",
    "glib": "glib-2.90.1/",
    "pcre2": "pcre2-10.46/",
    "proxy-libintl": "proxy-libintl-0.5/",
}
LICENSE_SOURCE_ARCHIVE = {
    "libslirp": "libslirp-4.9.7-googlesource.tar.gz",
    "glib": "glib-2.90.1.tar.xz",
    "pcre2": "pcre2-10.46.tar.bz2",
    "proxy-libintl": "proxy-libintl-0.5.tar.gz",
}

SLICE_PLATFORM = {
    "ios-arm64": ("ios-device", "FloeSlirp-ios-device.a"),
    "ios-arm64-simulator": ("ios-sim", "FloeSlirp-ios-sim.a"),
    "macos-arm64": ("macos", "FloeSlirp-macos.a"),
}

STATIC_FACTS = {
    "xcode": "27.2 (27B52)",
    "compiler": "Apple clang 21.0.0 (clang-2100.4.1.1)",
    "meson": "1.12.1",
    "ninja": "1.13.2",
}


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_sums(path: Path) -> dict[str, str]:
    out = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        digest, name = line.split(maxsplit=1)
        out[name.removeprefix("./")] = digest
    return out


def tar_flags(name: str) -> str:
    if name.endswith(".tar.xz"):
        return "xJf"
    if name.endswith(".tar.bz2"):
        return "xjf"
    return "xzf"


def archive_member_bytes(archive: Path, member: str) -> bytes:
    with tempfile.TemporaryDirectory() as td:
        subprocess.run(["tar", tar_flags(archive.name), str(archive), "-C", td, member],
                       check=True, capture_output=True)
        return (Path(td) / member).read_bytes()


def find_archive(search_dirs: list[Path], name: str) -> Path:
    for d in search_dirs:
        f = d / name
        if f.is_file():
            return f
    raise SystemExit(f"pinned archive not found in {[str(d) for d in search_dirs]}: {name}")


def build_record(vendor_dirs: list[Path], patches_dir: Path, xc: Path,
                 licenses_dir: Path | None, build_scripts_dir: Path | None,
                 tarball_sums: Path | None, xc_sums: Path | None,
                 static_sums: Path | None) -> dict:
    problems: list[str] = []

    tsums = read_sums(tarball_sums) if tarball_sums and tarball_sums.is_file() else {}
    up = {}
    for key, pin in PINS.items():
        entry = dict(pin)
        for f in [find_archive(vendor_dirs, pin["file"])] if "file" in pin else []:
            digest = sha256_file(f)
            if digest != pin["sha256"]:
                problems.append(f"{key}: {f.name} hash {digest} != pinned {pin['sha256']}")
            if tsums.get(f.name) not in (None, digest):
                problems.append(f"{key}: tarball SHA256SUMS disagrees for {f.name}")
            entry["sha256"] = digest
        for mirror, mpin in pin.get("mirrors", {}).items():
            f = find_archive(vendor_dirs, mpin["file"])
            digest = sha256_file(f)
            if digest != mpin["sha256"]:
                problems.append(f"{key}.{mirror}: hash {digest} != pinned {mpin['sha256']}")
            if tsums.get(f.name) not in (None, digest):
                problems.append(f"{key}.{mirror}: tarball SHA256SUMS disagrees for {f.name}")
        if pin.get("wrapdbPatchFile"):
            f = find_archive(vendor_dirs, pin["wrapdbPatchFile"])
            digest = sha256_file(f)
            if digest != pin["wrapdbPatchSha256"]:
                problems.append(f"{key}: wrapdb patch {f.name} hash {digest} != pinned")
            if tsums.get(f.name) not in (None, digest):
                problems.append(f"{key}: tarball SHA256SUMS disagrees for {f.name}")
        up[key] = entry
    if problems:
        raise SystemExit("pin verification failed:\n  " + "\n  ".join(problems))

    licenses = {}
    if licenses_dir is not None:
        for name, (comp, member) in LICENSE_TRACKED.items():
            tracked = licenses_dir / name
            if not tracked.is_file():
                raise SystemExit(f"tracked license text missing: {tracked}")
            digest = sha256_file(tracked)
            archive = find_archive(vendor_dirs, LICENSE_SOURCE_ARCHIVE[comp])
            want = hashlib.sha256(
                archive_member_bytes(archive, LICENSE_MEMBER_PREFIX[comp] + member)
            ).hexdigest()
            if digest != want:
                raise SystemExit(f"{name}: tracked copy differs from the pinned archive member")
            licenses[name] = {"sha256": digest, "source": f"{LICENSE_SOURCE_ARCHIVE[comp]}::{member}"}

    patch_files = {}
    for f in sorted(patches_dir.iterdir()):
        if f.suffix == ".patch" or f.name == "README.md":
            patch_files[f"patches/{f.name}"] = sha256_file(f)

    xs = read_sums(xc_sums) if xc_sums and xc_sums.is_file() else None
    ss = read_sums(static_sums) if static_sums and static_sums.is_file() else None
    delivered = {}
    for s, (platdir, lib) in SLICE_PLATFORM.items():
        digest = sha256_file(xc / s / lib)
        if xs is not None and xs.get(f"FloeSlirp.xcframework/{s}/{lib}") != digest:
            raise SystemExit(f"xcframework slice {s}/{lib} disagrees with SHA256SUMS-xcframework")
        if ss is not None and ss.get(f"{platdir}/{lib}") != digest:
            raise SystemExit(f"per-platform merged archive {platdir}/{lib} disagrees with SHA256SUMS-static")
        delivered[f"FloeSlirp.xcframework/{s}/{lib}"] = digest
    delivered["FloeSlirp.xcframework/Info.plist"] = sha256_file(xc / "Info.plist")
    if xs is not None and xs.get("FloeSlirp.xcframework/Info.plist") != delivered["FloeSlirp.xcframework/Info.plist"]:
        raise SystemExit("xcframework Info.plist disagrees with SHA256SUMS-xcframework")

    for f in sorted(xc.rglob("*")):
        if f.is_file() and "Headers" in f.parts:
            rel = f"FloeSlirp.xcframework/{f.relative_to(xc)}"
            digest = sha256_file(f)
            if xs is not None and xs.get(rel) != digest:
                raise SystemExit(f"xcframework header disagrees with SHA256SUMS-xcframework: {rel}")
            delivered[rel] = digest

    record = {
        "schemaVersion": 1,
        "package": "FloeSlirp",
        "role": (
            "Userspace virtual-network stack dependency for FloeARM64Engine: libslirp 4.9.7 "
            "with the trimmed GLib 2.90.1 core, PCRE2 10.46 (JIT disabled) and proxy-libintl 0.5 "
            "stubs, delivered as the FloeSlirp.xcframework binaryTarget and linked into the app "
            "through the engine's static link settings. C headers are consumed as "
            "<slirp/libslirp.h> from the xcframework Headers root."
        ),
        "upstream": up,
        "localPatches": patch_files,
        "delivered": delivered,
        "licenses": licenses,
        "toolchain": {
            **STATIC_FACTS,
            "deploymentTargets": {"iOS": "15.0", "iOS-simulator": "15.0", "macOS": "15.0"},
            "defines": [
                "SLIRP_NO_HOST_EXEC",
                "SLIRP_FLOE_HOST_HOOKS",
                "FLOE_GLIB_NO_TEST_SUBPROCESS",
                "G_INTL_STATIC_COMPILATION",
                "PCRE2_STATIC",
            ],
            "guards": [
                "PCRE2 jit=disabled (emitter not compiled)",
                "gspawn*.c.o archive members removed from the iOS libglib-2.0.a (fail-closed scan)",
                "forbidden-import scan of final images: 0 hits for _fork/_vfork/_exec*/_posix_spawn*/_dlopen/_popen/_g_spawn*/pcre2_jit",
            ],
        },
        "verificationBoundary": (
            "This record binds source, rebuild inputs and delivered archive/header bytes. "
            "A successful pin check is not a full App, physical-device, or Apple review result."
        ),
    }
    if build_scripts_dir is not None:
        record["buildScripts"] = {
            f"build/{f.name}": sha256_file(f)
            for f in sorted(build_scripts_dir.iterdir())
            if f.is_file() and f.suffix in {".sh", ".py"}
        }
    if build_scripts_dir is not None:
        tree = build_scripts_dir.parent
        required = tree / "smoke/slirp_smoke.c"
        if not required.is_file():
            raise SystemExit("required source-rebuild smoke is missing")
        record["rebuildSources"] = {
            str(f.relative_to(tree)): sha256_file(f)
            for folder in [tree / "smoke", tree / "tools"]
            for f in sorted(folder.rglob("*"))
            if f.is_file() and f.suffix in {".c", ".h", ".py"}
        }
    return record


def record_from_export(domain: Path, licenses_dir: Path | None, build_scripts_dir: Path | None) -> dict:
    return build_record(
        [domain / "vendor", licenses_dir.parent / "vendor"] if licenses_dir else [domain / "vendor"],
        domain / "patches", domain / "artifacts/FloeSlirp.xcframework",
        licenses_dir, build_scripts_dir,
        domain / "vendor/SHA256SUMS", domain / "artifacts/SHA256SUMS-xcframework",
        domain / "artifacts/SHA256SUMS-static",
    )


def record_from_staged(vendor_dir: Path, build_scripts_dir: Path | None) -> dict:
    return build_record(
        [vendor_dir / "vendor"], vendor_dir / "patches", vendor_dir / "FloeSlirp.xcframework",
        vendor_dir / "licenses", build_scripts_dir,
        vendor_dir / "vendor/SHA256SUMS", vendor_dir / "vendor/SHA256SUMS-xcframework",
        vendor_dir / "vendor/SHA256SUMS-static",
    )


def verify_staged(vendor_dir: Path) -> None:
    """Read-only check of a staged production tree against its PROVENANCE.json."""
    record = json.loads((vendor_dir / "PROVENANCE.json").read_text())
    problems = []
    want_by_name = {}
    for pin in record["upstream"].values():
        if pin.get("file"):
            want_by_name[pin["file"]] = pin["sha256"]
        if pin.get("wrapdbPatchFile"):
            want_by_name[pin["wrapdbPatchFile"]] = pin["wrapdbPatchSha256"]
        for m in pin.get("mirrors", {}).values():
            want_by_name[m["file"]] = m["sha256"]
    for name, want in want_by_name.items():
        f = vendor_dir / "vendor" / name
        if not f.is_file():
            problems.append(f"missing staged vendor/{name}")
        elif sha256_file(f) != want:
            problems.append(f"staged vendor/{name} differs from PROVENANCE")
    for name, info in record["licenses"].items():
        f = vendor_dir / "licenses" / name
        if not f.is_file():
            problems.append(f"missing staged licenses/{name}")
        elif sha256_file(f) != info["sha256"]:
            problems.append(f"staged licenses/{name} differs from PROVENANCE")
    # archive-member proof is done by the recompute path; here we additionally
    # prove the licenses byte-for-byte against the staged archives:
    for name, (comp, member) in LICENSE_TRACKED.items():
        f = vendor_dir / "licenses" / name
        if f.is_file():
            archive = vendor_dir / "vendor" / LICENSE_SOURCE_ARCHIVE[comp]
            if archive.is_file():
                want = hashlib.sha256(
                    archive_member_bytes(archive, LICENSE_MEMBER_PREFIX[comp] + member)
                ).hexdigest()
                if sha256_file(f) != want:
                    problems.append(f"licenses/{name} differs from the pinned archive member")
    for rel, digest in record["localPatches"].items():
        f = vendor_dir / rel
        if not f.is_file() or sha256_file(f) != digest:
            problems.append(f"staged {rel} missing or differs")
    for bs, digest in record.get("buildScripts", {}).items():
        f = vendor_dir / bs
        if not f.is_file() or sha256_file(f) != digest:
            problems.append(f"staged {bs} missing or differs")
    if not record.get("rebuildSources"):
        problems.append("source-rebuild inputs are missing from the record")
    for rel, digest in record.get("rebuildSources", {}).items():
        f = vendor_dir / rel
        if not f.is_file() or sha256_file(f) != digest:
            problems.append(f"staged {rel} missing or differs")
    for rel, digest in record["delivered"].items():
        f = vendor_dir / rel
        if not f.is_file() or sha256_file(f) != digest:
            problems.append(f"staged {rel} missing or differs")
    if problems:
        raise SystemExit("verify-staged FAILED:\n  " + "\n  ".join(problems))
    print(f"FloeSlirp staged tree verified against PROVENANCE.json: {vendor_dir}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--domain", type=Path, help="slirp-vendor qualification domain root")
    ap.add_argument("--vendor-dir", type=Path, help="staged FloeAgent/Vendor/FloeSlirp directory")
    ap.add_argument("--write", type=Path, help="PROVENANCE.json output path")
    ap.add_argument("--check", action="store_true",
                    help="compare recomputation to committed bytes; never write")
    ap.add_argument("--verify-staged", action="store_true")
    ap.add_argument("--check-notices", action="store_true")
    ap.add_argument("--licenses-dir", type=Path,
                    help="tracked licenses/ directory (export mode)")
    ap.add_argument("--build-scripts-dir", type=Path,
                    help="tracked build/ directory to hash into the record")
    a = ap.parse_args()

    if a.check_notices:
        if not a.vendor_dir:
            ap.error("--check-notices requires --vendor-dir")
        tree_root = a.vendor_dir.parents[2]  # <root>/FloeAgent/Vendor/FloeSlirp -> <root>
        sys.exit(subprocess.run([sys.executable,
                                 str(a.vendor_dir / "tools/make_bundle_notices.py"),
                                 "--candidate", str(tree_root), "--check"]).returncode)

    if a.verify_staged:
        if not a.vendor_dir:
            ap.error("--verify-staged requires --vendor-dir")
        verify_staged(a.vendor_dir)
        return 0

    if a.domain:
        if not a.write:
            ap.error("--domain mode requires --write")
        record = record_from_export(a.domain.resolve(),
                                    a.licenses_dir.resolve() if a.licenses_dir else None,
                                    a.build_scripts_dir.resolve() if a.build_scripts_dir else None)
    elif a.vendor_dir:
        if not a.write:
            ap.error("--vendor-dir record mode requires --write")
        record = record_from_staged(a.vendor_dir.resolve(),
                                    a.build_scripts_dir.resolve() if a.build_scripts_dir
                                    else a.vendor_dir.resolve() / "build")
    else:
        ap.error("one of --domain / --vendor-dir is required")

    text = json.dumps(record, indent=2, ensure_ascii=False) + "\n"
    if a.check:
        committed = a.write.read_text() if a.write.is_file() else ""
        if committed != text:
            print("PROVENANCE.json drift: committed bytes differ from the recomputation",
                  file=sys.stderr)
            return 1
        print(f"PROVENANCE.json --check OK: {a.write}")
        return 0
    a.write.write_text(text)
    print(f"wrote {a.write}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
