#!/usr/bin/env python3
"""Read-only author checks. This does not run or qualify a macOS Skill."""
import argparse
import hashlib
import json
import re
from pathlib import Path, PurePosixPath

HEX40 = re.compile(r"[0-9a-f]{40}\Z")
HEX64 = re.compile(r"[0-9a-f]{64}\Z")
VERSION = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\Z")
COMPONENT = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,99}\Z")
ID = re.compile(r"[a-z][a-z0-9-]{0,63}\Z")
CATEGORIES = {"office-documents", "writing-communication", "web-development", "research-data", "design-creation", "product-requirements", "productivity-organization"}
LIMIT = 16 * 1024 * 1024

def require(value, reason):
    if not value:
        raise ValueError(reason)

def relative(value):
    return isinstance(value, str) and 0 < len(value.encode()) <= 1024 and not value.startswith("/") and "\\" not in value and "\0" not in value and all(part not in ("", ".", "..") for part in value.split("/"))

def validate(feed, source_root=None):
    require(set(feed) == {"schemaVersion", "channel", "entries"}, "unknown/missing feed fields")
    require(feed["schemaVersion"] == 1 and feed["channel"] == "macos-original", "wrong schema/channel")
    require(isinstance(feed["entries"], list) and len(feed["entries"]) <= 256, "entry count")
    seen = set()
    fields = {"id", "name", "description", "category", "version", "minimumAppVersion", "repository", "subdirectory", "commit", "license", "licensePath", "digest", "files"}
    for entry in feed["entries"]:
        require(set(entry) == fields, "unknown/missing entry fields")
        require(ID.fullmatch(entry["id"]) and entry["id"] not in seen, "invalid/duplicate id")
        seen.add(entry["id"])
        for key in ("name", "description"):
            require(set(entry[key]) == {"en", "zh-Hans"} and all(isinstance(v, str) and v.strip() for v in entry[key].values()), "bilingual text")
        require(entry["category"] in CATEGORIES, "category")
        require(VERSION.fullmatch(entry["version"]) and VERSION.fullmatch(entry["minimumAppVersion"]), "semantic versions")
        repo = entry["repository"].split("/")
        require(len(repo) == 2 and all(COMPONENT.fullmatch(v) for v in repo), "repository")
        require(HEX40.fullmatch(entry["commit"]) and HEX64.fullmatch(entry["digest"]), "commit/digest")
        require(entry["subdirectory"] == "" or relative(entry["subdirectory"]), "subdirectory")
        require(entry["license"].strip() and relative(entry["licensePath"]), "license")
        require(isinstance(entry["files"], list) and 0 < len(entry["files"]) <= 2048, "files")
        paths, total, manifest = set(), 0, []
        for file in entry["files"]:
            require(set(file) == {"path", "sourcePath", "sha256", "bytes", "mode"}, "unknown/missing file fields")
            path = file["path"]
            require(relative(path) and path not in paths, "unsafe/duplicate file path")
            paths.add(path)
            require(relative(file["sourcePath"]), "unsafe upstream source path")
            expected_source = entry["subdirectory"] + "/" + path if entry["subdirectory"] else path
            require(path == entry["licensePath"] or file["sourcePath"] == expected_source, "original package layout differs")
            require(HEX64.fullmatch(file["sha256"]) and type(file["bytes"]) is int and 0 <= file["bytes"] <= LIMIT, "file identity")
            require(file["mode"] in ("100644", "100755"), "file mode")
            total += file["bytes"]
            manifest.append({k: file[k] for k in ("path", "sourcePath", "sha256", "mode")})
            if source_root is not None:
                root = (source_root / entry["id"]).resolve()
                target = root.joinpath(*PurePosixPath(path).parts)
                require(not target.is_symlink() and target.resolve().is_relative_to(root) and target.is_file(), "source file escapes package")
                data = target.read_bytes()
                require(len(data) == file["bytes"] and hashlib.sha256(data).hexdigest() == file["sha256"], "source file differs")
                require(bool(target.stat().st_mode & 0o111) == (file["mode"] == "100755"), "source executable mode differs")
        require(total <= LIMIT and "SKILL.md" in paths and entry["licensePath"] in paths, "package size/SKILL/license")
        encoded = json.dumps(sorted(manifest, key=lambda row: row["path"]), ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
        require(hashlib.sha256(encoded).hexdigest() == entry["digest"], "manifest digest differs")
    return len(feed["entries"])

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("catalog", type=Path)
    parser.add_argument("--source-root", type=Path)
    args = parser.parse_args()
    data = args.catalog.read_bytes()
    require(len(data) <= 4 * 1024 * 1024, "catalog size")
    count = validate(json.loads(data), args.source_root)
    print(f"Validated {count} macOS-original declarations; no execution qualification performed.")
