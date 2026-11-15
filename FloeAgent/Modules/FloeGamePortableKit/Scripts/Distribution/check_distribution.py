#!/usr/bin/env python3
"""Read-only preflight for the FloeGamePortableKit distribution profile.

Checks the machine-readable lock, the prepared resources, the notice bundle,
the exact-source package depot, the pin manifests and the license hygiene.
It never downloads, writes, executes downloaded code or changes a file.

Path safety: every entry declared by the lock is treated as a relative POSIX
path under its declared root. Absolute paths, traversal components, empty
components and symlink components are rejected. A local source-depot override
is supported with --source-root; the default is <kit>/../source-packages.

Exit status: 0 = all required checks pass; 1 = at least one failure.
Warnings are reported but do not fail unless --strict-warnings is used.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path, PurePosixPath
from urllib.parse import urlparse


class Report:
    def __init__(self) -> None:
        self.failures: list[str] = []
        self.warnings: list[str] = []
        self.checks = 0

    def check(self, condition: bool, message: str) -> bool:
        self.checks += 1
        if not condition:
            self.failures.append(message)
        return condition

    def warn(self, condition: bool, message: str) -> bool:
        if not condition:
            self.warnings.append(message)
        return condition

    def file_hash(self, path: Path, expected_sha: str | None, expected_bytes: int | None,
                  label: str) -> bool:
        self.checks += 1
        if not path.is_file():
            self.failures.append(f"{label}: missing {path}")
            return False
        if expected_sha and sha(path) != expected_sha:
            self.failures.append(f"{label}: sha256 mismatch {path}")
            return False
        if expected_bytes is not None and path.stat().st_size != expected_bytes:
            self.failures.append(f"{label}: size mismatch {path}")
            return False
        return True


def sha(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def validate_rel(rel: object) -> tuple[str, ...]:
    if not isinstance(rel, str) or not rel:
        raise ValueError("empty or non-string path")
    if rel != rel.strip() or rel.startswith("/") or rel.startswith("\\"):
        raise ValueError("leading/trailing whitespace or absolute path")
    if "\\" in rel or "\x00" in rel or any(ord(c) < 32 for c in rel):
        raise ValueError("backslash, NUL or control character")
    p = PurePosixPath(rel)
    if p.is_absolute():
        raise ValueError("absolute POSIX path")
    parts = p.parts
    if not parts or any(part in ("", ".", "..") for part in parts):
        raise ValueError("empty, dot or traversal component")
    return parts


def safe_path(root: Path, rel: object, label: str, r: Report) -> Path | None:
    """Resolve a declared relative path, rejecting traversal and symlinks."""
    r.checks += 1
    try:
        parts = validate_rel(rel)
    except ValueError as exc:
        r.failures.append(f"{label}: unsafe path {rel!r}: {exc}")
        return None
    root = root.resolve()
    target = root.joinpath(*parts)
    current = root
    for part in parts:
        current = current / part
        if current.is_symlink():
            r.failures.append(f"{label}: symlink path component {current}")
            return None
    try:
        resolved = target.resolve(strict=True)
    except (FileNotFoundError, RuntimeError) as exc:
        r.failures.append(f"{label}: missing or unreadable {target}: {exc}")
        return None
    if not resolved.is_relative_to(root):
        r.failures.append(f"{label}: path escapes root {root}: {resolved}")
        return None
    if not resolved.is_file():
        r.failures.append(f"{label}: not a regular file {target}")
        return None
    return target


def safe_dir(root: Path, rel: object, label: str, r: Report) -> Path | None:
    r.checks += 1
    try:
        parts = validate_rel(rel)
    except ValueError as exc:
        r.failures.append(f"{label}: unsafe path {rel!r}: {exc}")
        return None
    root = root.resolve()
    target = root.joinpath(*parts)
    current = root
    for part in parts:
        current = current / part
        if current.is_symlink():
            r.failures.append(f"{label}: symlink path component {current}")
            return None
    if not target.is_dir():
        r.failures.append(f"{label}: missing directory {target}")
        return None
    return target


def safe_abs(path: Path, label: str, r: Report) -> Path | None:
    """Bound an explicitly external Root-owned reference without symlinks."""
    r.checks += 1
    if not path.is_absolute():
        r.failures.append(f"{label}: external path is not absolute: {path}")
        return None
    if any(part in ("", ".", "..") for part in path.parts[1:]):
        r.failures.append(f"{label}: external path has a dot/traversal component: {path}")
        return None
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current = current / part
        if current.is_symlink():
            r.failures.append(f"{label}: symlink path component {current}")
            return None
    try:
        resolved = path.resolve(strict=True)
    except (FileNotFoundError, RuntimeError) as exc:
        r.failures.append(f"{label}: missing external file {path}: {exc}")
        return None
    if not resolved.is_file():
        r.failures.append(f"{label}: external path is not a regular file {path}")
        return None
    return path


def reject_symlinks(root: Path, label: str, r: Report) -> None:
    r.checks += 1
    if root.is_symlink() or not root.is_dir():
        r.failures.append(f"{label}: root is a symlink or not a directory: {root}")
        return
    for p in root.rglob("*"):
        if p.is_symlink():
            r.failures.append(f"{label}: symlink present: {p}")
            return


def read_json(path: Path, label: str, r: Report) -> dict | None:
    r.checks += 1
    if not path.is_file():
        r.failures.append(f"{label}: missing {path}")
        return None
    try:
        return json.loads(path.read_text())
    except Exception as exc:  # noqa: BLE001
        r.failures.append(f"{label}: invalid JSON {path}: {exc}")
        return None


def source_entry(entry) -> tuple[str, str | None, bool]:
    if isinstance(entry, str):
        return entry, None, True
    if not isinstance(entry, dict):
        return "", None, False
    return entry.get("path", ""), entry.get("sha256"), bool(entry.get("local", "sha256" in entry))


def check_source(entry, source_root: Path, iid: str, r: Report) -> bool:
    if isinstance(entry, dict) and entry.get("local") is False:
        path = entry.get("path", "")
        r.checks += 1
        if not isinstance(path, str) or urlparse(path).scheme not in ("http", "https"):
            r.failures.append(f"{iid}: remote source must be an http(s) URL: {path!r}")
            return False
        return True
    path, digest, local = source_entry(entry)
    if not local:
        r.failures.append(f"{iid}: LGPL source is not local")
        return False
    safe = safe_path(source_root, path, f"{iid} source", r)
    if safe is None:
        return False
    return r.file_hash(safe, digest, None, f"{iid} source")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--kit", type=Path, default=Path(__file__).resolve().parent.parent.parent,
                    help="FloeGamePortableKit root")
    ap.add_argument("--resources", type=Path, default=None,
                    help="prepared-resource root (default: <kit>/../resources)")
    ap.add_argument("--notices", type=Path, default=None,
                    help="notice bundle root (default: <kit>/../notices)")
    ap.add_argument("--source-root", type=Path, default=None,
                    help="exact-source package depot (default: <kit>/../source-packages)")
    ap.add_argument("--strict-warnings", action="store_true")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    kit = args.kit.resolve()
    resources = (args.resources or (kit.parent / "resources")).resolve()
    notices = (args.notices or (kit.parent / "notices")).resolve()
    source_root = (args.source_root or (kit.parent / "source-packages")).resolve()
    repo_root = kit.parents[4] if len(kit.parents) > 4 else kit.parent
    r = Report()

    for root, label in ((resources, "resources"), (notices, "notices"), (source_root, "source depot")):
        if not root.is_dir():
            print(json.dumps({
                "ok": False,
                "failures": [f"{label} root not found: {root}; pass --source-root for an external depot"],
                "warnings": [],
            }, indent=2))
            return 1
        reject_symlinks(root, label, r)

    lock_path = kit / "Scripts/Distribution/distribution-lock.json"
    lock = read_json(lock_path, "distribution lock", r)
    if lock is None:
        print(json.dumps({"ok": False, "failures": r.failures, "warnings": r.warnings}, indent=2))
        return 1

    r.check(lock.get("schemaVersion") == 1, "lock schemaVersion must be 1")
    r.check(lock.get("primaryLicense") == "MPL-2.0", "primaryLicense must be MPL-2.0")
    policy = lock.get("licensePolicy", {})
    r.check(policy.get("selfAuthored") == "MPL-2.0", "selfAuthored must be MPL-2.0")
    r.check(policy.get("wholeAppRelicensing") == "none", "wholeAppRelicensing must be none")
    r.check(policy.get("additionalUseRestrictions") == "none added by Floe",
            "no additional use restrictions")

    # Pin manifests and prepared resources.
    manifest_dir = kit / "Sources/FloeGamePortableKit/Resources/Manifests"
    pins = lock.get("pins", {})
    prepared_by_root: dict[str, dict] = {}
    for pin_id, pin_record in pins.items():
        pin_name = f"{pin_id}.json"
        pin_path = safe_path(manifest_dir, pin_name, f"pin {pin_id}", r)
        if pin_path is None:
            continue
        pin = read_json(pin_path, f"pin {pin_id}", r)
        if pin is None:
            continue
        r.check(pin.get("id") == pin_id, f"pin {pin_id}: id mismatch")
        r.check(pin.get("revision") == pin_record.get("revision"),
                f"pin {pin_id}: revision differs from lock")
        r.check(pin.get("artifactSHA256") == pin_record.get("artifactSHA256"),
                f"pin {pin_id}: artifactSHA256 differs from lock")
        r.check(bool(pin.get("licenseFiles")), f"pin {pin_id}: licenseFiles empty")
        prepared_root_rel = pin_record.get("preparedRoot")
        prepared_root = safe_dir(resources, prepared_root_rel, f"pin {pin_id} preparedRoot", r)
        if prepared_root is None:
            continue
        for rel in pin.get("licenseFiles", []):
            safe = safe_path(prepared_root, rel, f"pin {pin_id} license", r)
            if safe is not None:
                r.check(safe.stat().st_size > 0, f"pin {pin_id}: empty license {rel}")
        prepared_manifest = safe_path(resources, pin_record.get("preparedManifest"),
                                      f"prepared manifest {pin_id}", r)
        if prepared_manifest is None:
            continue
        manifest = read_json(prepared_manifest, f"prepared manifest {pin_id}", r)
        if manifest is None:
            continue
        r.check(manifest.get("pinID") == pin_id, f"prepared manifest {pin_id}: pinID mismatch")
        prepared_by_root[prepared_root_rel] = manifest
        for f in manifest.get("files", []):
            safe = safe_path(prepared_root, f.get("path"), f"prepared {pin_id}", r)
            if safe is not None:
                r.file_hash(safe, f.get("sha256"), f.get("bytes"), f"prepared {pin_id}/{f.get('path')}")

    # Items.
    items = lock.get("items", [])
    r.check(len(items) >= 8, "lock must contain the distribution items")
    for item in items:
        iid = item.get("id", "?")
        eligibility = item.get("eligibility", "")
        floe = bool(item.get("floeProvided"))
        if floe:
            r.check(not eligibility.startswith("ineligible"),
                    f"{iid}: Floe-provided item is ineligible")
        if eligibility == "eligible-with-conditions":
            r.check(bool(item.get("conditions")), f"{iid}: conditions missing")
        for notice in item.get("notices", []):
            path = notice.get("path", "")
            safe = safe_path(notices.parent, path, f"{iid} notice", r)
            if safe is not None:
                r.file_hash(safe, notice.get("sha256"), notice.get("bytes"), f"{iid} notice")
        for src in item.get("sourcePackages", []):
            check_source(src, source_root, iid, r)

        # Runtime files must match the prepared manifest exactly (or be a declared subset).
        prepared_root_rel = item.get("runtimeRoot")
        if prepared_root_rel:
            manifest = prepared_by_root.get(prepared_root_rel)
            if manifest is None:
                r.failures.append(f"{iid}: no prepared manifest for {prepared_root_rel}")
            else:
                expected = {f["path"]: f for f in manifest.get("files", [])}
                declared = {f["path"]: f for f in item.get("runtimeFiles", [])}
                if not item.get("runtimeSubset"):
                    r.check(set(expected) == set(declared),
                            f"{iid}: runtime file set differs from prepared manifest")
                else:
                    r.check(set(declared) <= set(expected),
                            f"{iid}: runtime subset declares a file not in the prepared manifest")
                prepared_root = safe_dir(resources, prepared_root_rel, f"{iid} runtimeRoot", r)
                if prepared_root is not None:
                    for path, f in declared.items():
                        safe = safe_path(prepared_root, path, f"{iid} runtime", r)
                        if safe is not None:
                            r.file_hash(safe, f.get("sha256"), f.get("bytes"),
                                        f"{iid} runtime {path}")
            r.check(safe_path(resources, item.get("preparedManifest"),
                              f"{iid} prepared manifest", r) is not None,
                    f"{iid}: prepared manifest missing")

        # LGPL components must have exact local source packages.
        for comp in item.get("lgplComponents", []):
            name = comp.get("name", "?")
            sp = comp.get("sourcePackage")
            if not sp:
                r.failures.append(f"{iid}/{name}: no source package")
                continue
            path, digest, local = source_entry(sp)
            if not local:
                r.failures.append(f"{iid}/{name}: LGPL source is not local")
                continue
            safe = safe_path(source_root, path, f"{iid}/{name} LGPL source", r)
            if safe is not None:
                r.file_hash(safe, digest, None, f"{iid}/{name} LGPL source")
            r.check(bool(comp.get("relinkDocument") or comp.get("relink")),
                    f"{iid}/{name}: no relink document")

    # LÖVE persistence evidence (Root-owned candidate; warn if absent outside this tree).
    love_item = next((i for i in items if i.get("id") == "lovejs-runtime"), None)
    if love_item:
        persistence = love_item.get("sourceLock", {}).get("persistence", {})
        r.check(persistence.get("idbfs") is True, "love: IDBFS must be recorded")
        r.check(persistence.get("unpatchedRuntime", {}).get("loaderSHA256")
                == "12db012a5cf4e0661f9eaf154c4c10c3cba7a7db31e6a36856028bbaf5f942f0",
                "love: unpatched loader hash")
        candidate = persistence.get("qualifiedCandidate", {})
        r.check(candidate.get("loaderSHA256")
                == "a9fec12804500c6dcfc524c0c40ef06fc3b772afc23eaa36f4c3aff2ae3da955",
                "love: qualified candidate loader hash")
        r.check(candidate.get("wasmSHA256")
                == "ecc9e098bb8af918d20fbe3f26d23495c5184ff6b5d203d2e4b27bf17a771d6f",
                "love: candidate WASM hash must equal upstream")
        r.check(candidate.get("crossPlayerBuiltInSavePersistenceVerified") is True,
                "love: candidate must record the real cross-player PASS")
        r.check("PASS" in persistence.get("actualCrossPlayer", ""),
                "love: actualCrossPlayer must record Root PASS")
        for key in ("receipt", "actualResult"):
            raw = candidate.get(key, "")
            p = Path(raw)
            if not p.is_absolute():
                p = repo_root / raw
            safe = safe_abs(p, f"love candidate {key}", r)
            if safe is not None:
                r.file_hash(safe, candidate.get(key + "SHA256"), None, f"love candidate {key}")
            else:
                r.warn(False, f"love candidate {key} not present at {p} (outside this package)")

    # License hygiene.
    license_file = kit / "LICENSE"
    r.checks += 1
    if not license_file.is_file() or "Mozilla Public License Version 2.0" not in license_file.read_text(errors="replace"):
        r.failures.append("kit LICENSE is not MPL-2.0")
    swift_sources = list((kit / "Sources").rglob("*.swift"))
    r.check(len(swift_sources) > 0, "no Swift sources found")
    for src in swift_sources:
        text = src.read_text(errors="replace")
        if "SPDX-License-Identifier: MPL-2.0" not in text:
            r.failures.append(f"self-authored Swift lacks MPL-2.0 SPDX: {src}")
    # Third-party notice files must not claim MPL-2.0 or add an Exhibit B notice.
    for group in ("love", "renpy", "mv"):
        for p in (notices / group).rglob("*"):
            if not p.is_file() or p.is_symlink():
                continue
            # The official Ren'Py LICENSE.txt quotes the full MPL-2.0 text for
            # the bundled certifi package, including the standard Exhibit B
            # template. That is not a Floe relicense or an added notice.
            if p.name == "RENPY-LICENSE.txt":
                continue
            text = p.read_text(errors="replace")
            if "SPDX-License-Identifier: MPL-2.0" in text or "Incompatible With Secondary Licenses" in text:
                r.failures.append(f"third-party notice claims MPL/Exhibit B: {p}")
    r.check(not (notices / "love/LOVE-11.5-LICENSE.txt").exists(),
            "LOVE-11.5 notice must not be in the active love notice bundle")
    addendum = notices / "love/LOVE-11.4-COMPONENT-ADDENDUM.md"
    r.check(addendum.is_file(), "LOVE 11.4 component addendum missing")
    if addendum.is_file():
        text = addendum.read_text(errors="replace")
        r.check("8f9a7b85" in text, "LOVE addendum must name the actual source commit")
        r.check("mpg123" in text and "LGPL" in text, "LOVE addendum must state the LGPL component")
        r.check("11.5" in text, "LOVE addendum must explain the retained 11.5 notice")
    renpy_addendum = notices / "renpy/RENPY-8.5.3-COMPONENT-ADDENDUM.md"
    r.check(renpy_addendum.is_file(), "Ren'Py component addendum missing")
    if renpy_addendum.is_file():
        text = renpy_addendum.read_text(errors="replace")
        for token in ("FFmpeg", "FriBidi", "chardet", "SDL_gfx", "39895c1e", "7bfab40c"):
            r.check(token in text, f"Ren'Py addendum missing {token}")

    # Source depot must contain the LGPL key archives.
    for rel in (
        "love/mpg123-1.25.6-megasource.tar.gz",
        "love/davidobot-love-a79ab87.tar.gz",
        "love/davidobot-megasource-b1faef45.tar.gz",
        "renpy/ffmpeg-4.3.1.tar.gz",
        "renpy/fribidi-1.0.7.tar.bz2",
        "renpy/chardet-5.2.0.tar.gz",
        "renpy/renpy-39895c1.tar.gz",
        "renpy/renpy-build-7bfab40.tar.gz",
    ):
        safe = safe_path(source_root, rel, "source depot key", r)
        if safe is not None:
            r.check(safe.stat().st_size > 0, f"source depot empty {rel}")

    ok = not r.failures
    result = {
        "ok": ok,
        "checks": r.checks,
        "failures": r.failures,
        "warnings": r.warnings,
        "kit": str(kit),
        "resources": str(resources),
        "notices": str(notices),
        "sourceRoot": str(source_root),
    }
    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(f"{'OK' if ok else 'FAIL'}: {r.checks} checks, "
              f"{len(r.failures)} failures, {len(r.warnings)} warnings")
        for f in r.failures:
            print("  FAIL", f)
        for w in r.warnings:
            print("  WARN", w)
    if args.strict_warnings and r.warnings:
        return 1
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
