#!/usr/bin/env python3
"""Package the native editor's build inputs, without certifying app integration."""
import hashlib
import io
import json
import os
from pathlib import Path
import tarfile

EXCLUDED = {".git", "node_modules", ".DS_Store"}
HEADER_SUFFIXES = {".h", ".hpp", ".hxx", ".inc", ".inl", ".ipp", ".tcc"}
REQUIRED = (
    "ios/Mobile.xcodeproj/project.pbxproj", "ios/Mobile/DocumentViewController.mm",
    "common", "kit", "net", "wsd", "browser/dist", "engine/config_host",
    "engine/include", "engine/instdir",
    "engine/workdir/UnoApiHeadersTarget", "engine/workdir/CustomTarget/ios",
)


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def package(root):
    root = Path(root).resolve()
    report = json.loads((root / "qualification.json").read_text())
    if not report.get("nativeBuildPassed"):
        raise ValueError("Cannot package an unqualified native build")
    source = root / "source"
    for name in REQUIRED:
        if not (source / name).exists():
            raise ValueError(f"Missing editor build input: {name}")
    paths = set()
    links = {}
    visited = set()

    def collect(path, headers_only=False):
        if path.name in EXCLUDED:
            return
        # Resolve every link against the build root, including directory links.
        # Never ship runner-specific absolute symlinks or an outside dependency.
        if path.is_symlink():
            target = path.resolve(strict=True)
            if not target.is_relative_to(root):
                raise ValueError(f"Dependency escapes build root: {path.relative_to(root)}")
            links[path] = os.path.relpath(target, path.parent)
            paths.add(path)
            # The top-level engine alias must not pull in all object files.
            if target != source / "engine":
                collect(target, headers_only)
            return
        key = (path, headers_only)
        if key in visited:
            return
        visited.add(key)
        if path.is_dir():
            for child in sorted(path.iterdir()):
                collect(child, headers_only)
        elif path.is_file():
            if not headers_only or path.suffix in HEADER_SUFFIXES or path.name.startswith(("LICENSE", "COPYING", "NOTICE")):
                paths.add(path)

    # Native Mobile compiles common/kit/net/wsd sources itself; retaining only
    # engine archives and JavaScript is not sufficient for the embedding build.
    for child in sorted(source.iterdir()):
        if child.name != "engine":
            collect(child)
    for subtree in ("config_host", "include", "instdir", "workdir/CustomTarget/ios", "workdir/UnoApiHeadersTarget"):
        collect(source / "engine" / subtree)
    # Boost, libpng, POCO and zstd headers referenced by Mobile.xcodeproj.
    unpacked = source / "engine/workdir/UnpackedTarball"
    if unpacked.exists():
        collect(unpacked, headers_only=True)
    for path in sorted((source / "engine").rglob("*.a")):
        collect(path)
    for pattern in ("COPYING*", "LICENSE*", "NOTICE*"):
        for path in (source / "engine").glob(pattern):
            collect(path)

    archive_list = source / "engine/workdir/CustomTarget/ios/ios-all-static-libs.list"
    linker_inputs = []
    for line in archive_list.read_text().splitlines():
        if not line.strip():
            continue
        path = Path(line.strip())
        if not path.is_absolute():
            path = source / "engine" / path
        path = path.resolve(strict=True)
        if not path.is_relative_to(root) or path.suffix not in {".a", ".o"}:
            raise ValueError("Native linker list contains an unsupported input path")
        collect(path)
        linker_inputs.append(str(path.relative_to(root)))
    if not linker_inputs:
        raise ValueError("Native linker archive list is empty")

    entries = []
    for path in sorted(paths):
        item = {"path": str(path.relative_to(root))}
        if path in links:
            item["symlink"] = links[path]
        else:
            item.update(size=path.stat().st_size, sha256=digest(path))
        entries.append(item)
    manifest = {
        "formatVersion": 2, "sourceCommit": report["commit"],
        "originalBuildRoot": str(root), "linkerInputs": linker_inputs,
        "linkerArchives": [name for name in linker_inputs if name.endswith(".a")],
        "embeddingVerified": False, "deviceRoundtripVerified": False,
        "files": entries,
    }
    destination = root / "office-engine-ios-arm64.tar.gz"
    temporary = destination.with_suffix(".partial")
    try:
        with tarfile.open(temporary, "w:gz", compresslevel=3, dereference=False) as archive:
            archive.add(root / "qualification.json", arcname="qualification.json")
            data = json.dumps(manifest, indent=2).encode()
            info = tarfile.TarInfo("bundle-manifest.json")
            info.size = len(data)
            archive.addfile(info, io.BytesIO(data))
            for path in sorted(paths):
                info = archive.gettarinfo(str(path), arcname=str(path.relative_to(root)))
                if path in links:
                    info.linkname = links[path]
                    archive.addfile(info)
                else:
                    # Materialize hard links too: every hashed file is portable.
                    info.type = tarfile.REGTYPE
                    info.linkname = ""
                    info.size = path.stat().st_size
                    with path.open("rb") as stream:
                        archive.addfile(info, stream)
        temporary.replace(destination)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise
    return manifest


if __name__ == "__main__":
    result = package(os.environ["FLOE_OFFICE_BUILD_ROOT"])
    print(f"Packaged {len(result['files'])} verified build inputs; editor embedding and device roundtrip remain unverified")
