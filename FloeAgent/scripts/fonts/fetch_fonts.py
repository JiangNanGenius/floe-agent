#!/usr/bin/env python3
"""Fetch and stage bundled Chinese fonts for FloeAgent.

Reads scripts/fonts/manifest.json, downloads every pinned upstream source,
extracts archives, and stages font files into the manifest's outputDir
(FloeApp/Resources/Fonts/Bundled/<family-id>/). Every staged file is
SHA-256 hashed into provenance.json so builds can verify integrity and the
font catalog can record fixed sources and digests (升级计划 2.4).

Usage:
    python3 scripts/fonts/fetch_fonts.py [--only <id,id>] [--check]

--check verifies already-staged files against provenance.json without
downloading anything.
"""
from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile
from pathlib import Path
from urllib.parse import unquote, urlparse

REPO_ROOT = Path(__file__).resolve().parents[2]
MANIFEST_PATH = Path(__file__).resolve().parent / "manifest.json"
CACHE_DIR = REPO_ROOT / "Vendor" / "Fonts" / "downloads"
FONT_EXTS = {".ttf", ".otf", ".ttc", ".otc"}


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def download(url: str, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists() and dest.stat().st_size > 0:
        print(f"    cached: {dest.name} ({dest.stat().st_size / 1e6:.1f} MB)")
        return
    print(f"    downloading: {url}")
    cmd = [
        "curl", "-fL", "--retry", "3", "--retry-delay", "5",
        "-C", "-", "--connect-timeout", "30",
        "-A", "FloeAgent-FontFetcher/1.0",
        "-o", str(dest) + ".part", url,
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        # Some CDNs reject ranged requests; retry once without resume.
        result = subprocess.run(
            [c for c in cmd if c not in {"-C", "-"}],
            capture_output=True, text=True,
        )
    if result.returncode != 0:
        raise RuntimeError(f"curl failed ({result.returncode}): {result.stderr.strip()[-300:]}")
    Path(str(dest) + ".part").replace(dest)


def extract_7z(archive: Path, dest_dir: Path) -> list[Path]:
    """Extract a 7z archive via py7zr or a 7z CLI; returns extracted files."""
    try:
        import py7zr  # type: ignore

        dest_dir.mkdir(parents=True, exist_ok=True)
        with py7zr.SevenZipFile(archive, "r") as z:
            z.extractall(dest_dir)
        return [p for p in dest_dir.rglob("*") if p.is_file()]
    except ImportError:
        pass
    for tool in ("7zz", "7z", "7za"):
        if shutil.which(tool):
            dest_dir.mkdir(parents=True, exist_ok=True)
            subprocess.run(
                [tool, "x", "-y", f"-o{dest_dir}", str(archive)],
                check=True, capture_output=True,
            )
            return [p for p in dest_dir.rglob("*") if p.is_file()]
    raise RuntimeError(
        "7z archive requires py7zr (pip install py7zr) or a 7z CLI on PATH"
    )


def stage_family(family: dict, output_root: Path) -> dict:
    fid = family["id"]
    fam_dir = output_root / fid
    fam_dir.mkdir(parents=True, exist_ok=True)
    staged: list[dict] = []
    seen_names: set[str] = set()

    # Weight/file picks change over time: drop every previously staged font
    # file before re-staging; provenance.json is rewritten below.
    for old in fam_dir.iterdir():
        if old.suffix.lower() in FONT_EXTS:
            old.unlink()

    for source in family.get("sources", []):
        url = source["url"]
        name = unquote(Path(urlparse(url).path).name)
        cache_path = CACHE_DIR / fid / name
        download(url, cache_path)
        archive = source.get("archive")
        includes = source.get("include") or [
            f"*{e}" for e in sorted(FONT_EXTS)
        ]

        candidates: list[Path]
        if archive == "zip":
            with tempfile.TemporaryDirectory() as tmp:
                with zipfile.ZipFile(cache_path) as z:
                    z.extractall(tmp)
                candidates = [p for p in Path(tmp).rglob("*") if p.is_file()]
                staged += copy_matches(candidates, includes, fam_dir, seen_names)
        elif archive == "7z":
            with tempfile.TemporaryDirectory() as tmp:
                candidates = extract_7z(cache_path, Path(tmp))
                staged += copy_matches(candidates, includes, fam_dir, seen_names)
        elif archive:
            raise RuntimeError(f"unsupported archive type: {archive}")
        else:
            staged += copy_matches([cache_path], includes, fam_dir, seen_names)

    if not staged:
        raise RuntimeError(f"no font files matched include rules for {fid}")

    license_info = family.get("license", {})
    license_path = fam_dir / "LICENSE.txt"
    if license_info.get("textUrl") and not license_path.exists():
        try:
            download(license_info["textUrl"], license_path)
        except Exception as exc:  # license text is provenance, not a blocker
            license_path.write_text(
                f"{license_info.get('name', '详见上游')}\n授权文本获取失败，"
                f"请查阅上游: {license_info['textUrl']}\n（下载错误: {exc}）\n",
                encoding="utf-8",
            )

    provenance = {
        "id": fid,
        "displayName": family.get("displayName"),
        "category": family.get("category"),
        "version": family.get("version"),
        "prerelease": family.get("prerelease", False),
        "note": family.get("note"),
        "license": license_info,
        "upstream": family.get("upstream"),
        "languages": family.get("languages", []),
        "fetchedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "files": staged,
    }
    (fam_dir / "provenance.json").write_text(
        json.dumps(provenance, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    total = sum(f["bytes"] for f in staged)
    print(f"  ✓ {fid}: {len(staged)} files, {total / 1e6:.1f} MB")
    return provenance


def copy_matches(
    candidates: list[Path], includes: list[str], fam_dir: Path, seen: set[str]
) -> list[dict]:
    staged = []
    for path in candidates:
        if path.suffix.lower() not in FONT_EXTS:
            continue
        if not any(fnmatch.fnmatch(path.name, pat) for pat in includes):
            continue
        if path.name in seen:
            continue
        seen.add(path.name)
        dest = fam_dir / path.name
        shutil.copy2(path, dest)
        staged.append(
            {
                "fileName": dest.name,
                "bytes": dest.stat().st_size,
                "sha256": sha256_file(dest),
            }
        )
    return staged


def check_family(family: dict, output_root: Path) -> bool:
    fam_dir = output_root / family["id"]
    prov_path = fam_dir / "provenance.json"
    if not prov_path.exists():
        print(f"  ✗ {family['id']}: missing provenance.json")
        return False
    prov = json.loads(prov_path.read_text(encoding="utf-8"))
    ok = True
    for entry in prov["files"]:
        path = fam_dir / entry["fileName"]
        if not path.exists():
            print(f"  ✗ {family['id']}: missing {entry['fileName']}")
            ok = False
        elif sha256_file(path) != entry["sha256"]:
            print(f"  ✗ {family['id']}: digest mismatch {entry['fileName']}")
            ok = False
    # Stale fonts from older pick sets must not silently ship.
    expected = {entry["fileName"] for entry in prov["files"]}
    for path in fam_dir.iterdir():
        if path.suffix.lower() in FONT_EXTS and path.name not in expected:
            print(f"  ✗ {family['id']}: stale unpinned font {path.name}")
            ok = False
    if ok:
        print(f"  ✓ {family['id']}: {len(prov['files'])} files verified")
    return ok


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--only", help="comma-separated family ids")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--include-optional", action="store_true",
                        help="also stage tier=optional families (display/calligraphy fonts users can install on demand)")
    args = parser.parse_args()

    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    output_root = REPO_ROOT / manifest["outputDir"]
    families = manifest["families"]
    if not args.include_optional:
        skipped = [f["id"] for f in families if f.get("tier") == "optional"]
        families = [f for f in families if f.get("tier") != "optional"]
        if skipped:
            print(f"tier=optional families skipped ({len(skipped)}); --include-optional stages them on demand")
    if args.only:
        wanted = set(args.only.split(","))
        families = [f for f in families if f["id"] in wanted]
        missing = wanted - {f["id"] for f in families}
        if missing:
            print(f"unknown family ids: {sorted(missing)}", file=sys.stderr)
            return 2

    failures = 0
    for family in families:
        print(f"[{family['id']}]")
        try:
            if args.check:
                ok = check_family(family, output_root)
                failures += 0 if ok else 1
            else:
                stage_family(family, output_root)
        except Exception as exc:
            failures += 1
            print(f"  ✗ {family['id']}: {exc}")
    print(f"\n{'CHECK ' if args.check else ''}DONE — failures: {failures}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
