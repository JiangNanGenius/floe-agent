#!/usr/bin/env python3
"""Prepare pinned Office source overlays without altering verified bundle inputs."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
from package_office_engine import digest
from verify_office_engine import contained, verify

DEFAULT_LOCK = Path(__file__).resolve().parent.parent / "ThirdParty/Collabora/engine.lock.json"


def prepare(root, lock_path=DEFAULT_LOCK):
    root = Path(root).resolve()
    lock_path = Path(lock_path).resolve()
    lock = json.loads(lock_path.read_text())
    checked = verify(root, prepare=True)
    if checked["sourceCommit"] != lock["commit"]:
        raise ValueError("Office source commit does not match the embedding lock")
    overlay = lock["embeddingOverlay"]
    patch = contained(lock_path.parent, overlay["patch"])
    if digest(patch) != overlay["sha256"]:
        raise ValueError("Office embedding patch checksum mismatch")
    for name, hashes in overlay["files"].items():
        source = contained(root / "source", name)
        if digest(source) != hashes["originalSHA256"]:
            raise ValueError(f"Office source does not match the pinned overlay: {name}")
    receipt = {"sourceCommit": lock["commit"], "patchSHA256": overlay["sha256"],
               "requiredFrameworks": overlay["requiredFrameworks"],
               "files": {name: data["preparedSHA256"] for name, data in overlay["files"].items()},
               "nativeCompilePassed": False, "deviceKeyboardPassed": False}
    destination = root / "prepared/native"
    if destination.exists() or destination.is_symlink():
        if destination.is_symlink() or not (destination / "overlay.json").is_file():
            raise ValueError("Existing native preparation is not owned by this overlay")
        if json.loads((destination / "overlay.json").read_text()) != receipt:
            raise ValueError("Existing native preparation uses a different overlay")
        for name, checksum in receipt["files"].items():
            if digest(contained(destination, name)) != checksum:
                raise ValueError("Prepared native source was edited; preserve it and use a fresh bundle")
        return receipt
    with tempfile.TemporaryDirectory(dir=root / "prepared", prefix=".native-") as folder:
        stage = Path(folder).resolve()
        for name in overlay["files"]:
            target = contained(stage, name)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(root / "source" / name, target)
        subprocess.run(["git", "apply", "--check", str(patch)], cwd=stage, check=True, capture_output=True)
        subprocess.run(["git", "apply", str(patch)], cwd=stage, check=True, capture_output=True)
        for name, checksum in receipt["files"].items():
            if digest(contained(stage, name)) != checksum:
                raise ValueError(f"Prepared native source checksum mismatch: {name}")
        (stage / "overlay.json").write_text(json.dumps(receipt, indent=2) + "\n")
        stage.replace(destination)
    return receipt


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("--lock", type=Path, default=DEFAULT_LOCK)
    arguments = parser.parse_args()
    print(json.dumps(prepare(arguments.root, arguments.lock), indent=2))
