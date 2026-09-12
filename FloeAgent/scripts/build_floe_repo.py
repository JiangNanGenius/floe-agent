#!/usr/bin/env python3
"""Builds the Floe Debian repository from `pool/` sources.

Each package lives in `pool/<component>/<package>/`:
    control            Debian control stanza (Package, Version, Architecture, ...)
    DEBIAN/            optional maintainer scripts (preinst, postinst, prerm, postrm)
    payload/           files installed into the container root

Outputs (under `pool/repo/`):
    pool/<component>/<file>.deb
    dists/<suite>/<component>/binary-<arch>/Packages(.gz)
    dists/<suite>/Release
    dists/<suite>/InRelease                OpenPGP clearsigned Release
    dists/<suite>/Release.gpg              OpenPGP detached signature
    catalog.json                           machine-readable package index

Signing imports an OpenPGP secret key from FLOE_REPO_SIGNING_KEY into a temporary
GnuPG home. Unsigned output is allowed only with FLOE_REPO_ALLOW_UNSIGNED=1 and
is not consumable by the production client.
"""

from __future__ import annotations

import gzip
import hashlib
import io
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tarfile
import time
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
POOL = ROOT / "pool"
REPO = POOL / "repo"
SUITE = os.environ.get("FLOE_REPO_SUITE", "floe-1.7")
COMPONENTS = ["node", "wasm", "python-native", "toolchain", "media", "data", "db"]


def sha256_file(path: pathlib.Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def ar_member(name: str, data: bytes) -> bytes:
    header = f"{name:<16}{0:<12}{0:<6}{0:<6}{0o100644:<8o}{len(data):<10}`\n".encode()
    padding = b"\n" if len(data) % 2 else b""
    return header + data + padding


def tar_bytes(entries: list[tuple[str, bytes, int]]) -> bytes:
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w") as archive:
        for path, data, mode in entries:
            info = tarfile.TarInfo(name=path)
            info.size = len(data)
            info.mode = mode
            archive.addfile(info, io.BytesIO(data))
    return buffer.getvalue()


def build_deb(package_dir: pathlib.Path, component: str) -> dict | None:
    control_path = package_dir / "control"
    if not control_path.is_file():
        return None
    control_text = control_path.read_text().strip()
    fields = {}
    for line in control_text.splitlines():
        if ":" in line:
            key, value = line.split(":", 1)
            fields[key.strip()] = value.strip()
    name = fields.get("Package")
    version = fields.get("Version")
    architecture = fields.get("Architecture", "all")
    if not name or not version:
        raise SystemExit(f"{package_dir}: control needs Package and Version")

    data_entries: list[tuple[str, bytes, int]] = []
    payload = package_dir / "payload"
    if payload.is_dir():
        for file in sorted(payload.rglob("*")):
            if file.is_dir():
                continue
            relative = "./" + file.relative_to(payload).as_posix()
            data_entries.append((relative, file.read_bytes(), 0o644))
    data_tar_gz = gzip.compress(tar_bytes(data_entries), mtime=0)

    control_entries: list[tuple[str, bytes, int]] = [("./control", control_text.encode(), 0o644)]
    debian = package_dir / "DEBIAN"
    if debian.is_dir():
        for script in sorted(debian.iterdir()):
            if script.is_file() and script.name in {"preinst", "postinst", "prerm", "postrm"}:
                control_entries.append((f"./{script.name}", script.read_bytes(), 0o755))
    control_tar_gz = gzip.compress(tar_bytes(control_entries), mtime=0)

    deb = (
        b"!<arch>\n" + ar_member("debian-binary", b"2.0\n")
        + ar_member("control.tar.gz", control_tar_gz)
        + ar_member("data.tar.gz", data_tar_gz)
    )
    destination = REPO / "pool" / component / f"{name}_{version}_{architecture}.deb"
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(deb)
    info = dict(fields)
    info["Filename"] = f"pool/{component}/{destination.name}"
    info["Size"] = str(len(deb))
    info["SHA256"] = hashlib.sha256(deb).hexdigest()
    info["_component"] = component
    return info


def gzip_deterministic(data: bytes) -> bytes:
    buffer = io.BytesIO()
    with gzip.GzipFile(fileobj=buffer, mode="wb", mtime=0) as handle:
        handle.write(data)
    return buffer.getvalue()


def build_repository() -> int:
    if not POOL.is_dir():
        print(f"no pool directory at {POOL}; nothing to build")
        return 0
    for directory in (REPO,):
        if directory.exists():
            shutil.rmtree(directory)
    packages: list[dict] = []
    for component in COMPONENTS:
        component_dir = POOL / component
        if not component_dir.is_dir():
            continue
        for package_dir in sorted(component_dir.iterdir()):
            if not package_dir.is_dir() or package_dir.name.startswith("."):
                continue
            info = build_deb(package_dir, component)
            if info:
                packages.append(info)
    if not packages:
        print("no packages found")
        return 0

    for component in COMPONENTS:
        component_packages = [p for p in packages if p["_component"] == component]
        if not component_packages:
            continue
        architectures = sorted({p.get("Architecture", "all") for p in component_packages})
        for architecture in architectures:
            # Architecture-independent entries remain available to each native index.
            selected = [p for p in component_packages if p.get("Architecture", "all") in {architecture, "all"}]
            stanzas = []
            for package in selected:
                lines = [f"{key}: {value}" for key, value in package.items() if not key.startswith("_")]
                stanzas.append("\n".join(lines))
            document = "\n\n".join(stanzas) + "\n"
            index_dir = REPO / "dists" / SUITE / component / f"binary-{architecture}"
            index_dir.mkdir(parents=True, exist_ok=True)
            (index_dir / "Packages").write_bytes(document.encode())
            (index_dir / "Packages.gz").write_bytes(gzip_deterministic(document.encode()))

    release_lines = [
        f"Origin: Floe",
        f"Label: Floe",
        f"Suite: {SUITE}",
        f"Codename: {SUITE}",
        f"Date: {time.strftime('%a, %d %b %Y %H:%M:%S UTC', time.gmtime())}",
        f"Architectures: {' '.join(sorted({p.get('Architecture', 'all') for p in packages}))}",
        f"Components: {' '.join(sorted({p['_component'] for p in packages}))}",
        f"Description: Floe local capability repository",
        "SHA256:",
    ]
    for path in sorted((REPO / "dists" / SUITE).rglob("Packages*")):
        data = path.read_bytes()
        relative = path.relative_to(REPO / "dists" / SUITE).as_posix()
        release_lines.append(f" {hashlib.sha256(data).hexdigest()} {len(data):>16} {relative}")
    release_path = REPO / "dists" / SUITE / "Release"
    release_path.write_bytes(("\n".join(release_lines) + "\n").encode())

    key_path = os.environ.get("FLOE_REPO_SIGNING_KEY")
    if key_path and pathlib.Path(key_path).is_file():
        with tempfile.TemporaryDirectory(prefix="floe-repo-sign-") as temporary:
            home = pathlib.Path(temporary)
            home.chmod(0o700)
            command = ["gpg", "--homedir", str(home), "--batch", "--yes"]
            try:
                subprocess.run(command + ["--import", key_path], check=True, capture_output=True)
                signer = command + ["--pinentry-mode", "loopback", "--passphrase-fd", "0", "--digest-algo", "SHA256"]
                passphrase = (os.environ.get("FLOE_REPO_KEY_PASSPHRASE", "") + "\n").encode()
                for options in [
                    ["--armor", "--clearsign", "--output", str(release_path.with_name("InRelease"))],
                    ["--detach-sign", "--output", str(release_path.with_name("Release.gpg"))],
                ]:
                    subprocess.run(signer + options + [str(release_path)], input=passphrase, check=True, capture_output=True)
                public_key = subprocess.run(command + ["--armor", "--export"], check=True, capture_output=True).stdout
                (REPO / "repo-key.asc").write_bytes(public_key)
            finally:
                subprocess.run(["gpgconf", "--homedir", str(home), "--kill", "all"], capture_output=True)
        print("signed OpenPGP InRelease and Release.gpg")
    elif os.environ.get("FLOE_REPO_ALLOW_UNSIGNED") == "1":
        print("qualification-only unsigned repository; production client will reject it")
    else:
        raise RuntimeError("A production repository requires FLOE_REPO_SIGNING_KEY (OpenPGP)")

    catalog = {
        "schemaVersion": 1,
        "suite": SUITE,
        "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "releaseSHA256": sha256_file(release_path),
        "packages": packages,
    }
    (REPO / "catalog.json").write_text(json.dumps(catalog, indent=2, sort_keys=True) + "\n")
    print(f"built {len(packages)} packages for suite {SUITE}")
    return 0


def main() -> int:
    global REPO
    key = os.environ.get("FLOE_REPO_SIGNING_KEY")
    if not (key and pathlib.Path(key).is_file()) and os.environ.get("FLOE_REPO_ALLOW_UNSIGNED") != "1":
        raise RuntimeError("A production repository requires FLOE_REPO_SIGNING_KEY (OpenPGP)")
    if not POOL.is_dir():
        print(f"no pool directory at {POOL}; nothing to build")
        return 0
    destination = REPO
    with tempfile.TemporaryDirectory(prefix=".repo-stage-", dir=POOL) as temporary:
        REPO = pathlib.Path(temporary) / "repo"
        try:
            result = build_repository()
            if not (REPO / "catalog.json").is_file(): return result
            backup = pathlib.Path(tempfile.mkdtemp(prefix=".repo-recovery-", dir=POOL))
            previous = backup / "repo"
            try:
                if destination.exists(): destination.rename(previous)
                try: REPO.rename(destination)
                except BaseException:
                    if previous.exists(): previous.rename(destination)
                    raise
            except BaseException:
                # Retain any recovery directory if a rollback itself fails.
                raise
            else: shutil.rmtree(backup)
            return result
        finally: REPO = destination


if __name__ == "__main__":
    sys.exit(main())
