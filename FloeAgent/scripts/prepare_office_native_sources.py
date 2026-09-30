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


def expected_receipt(lock):
    """Build the receipt, including the lifecycle overlays when pinned."""
    overlay = lock["embeddingOverlay"]
    receipt = {"sourceCommit": lock["commit"], "patchSHA256": overlay["sha256"],
               "requiredFrameworks": overlay["requiredFrameworks"],
               "files": {name: data["preparedSHA256"]
                         for name, data in overlay["files"].items()},
               "nativeCompilePassed": False, "deviceKeyboardPassed": False}
    scheme_overlay = lock.get("schemeTaskLifecycleOverlay")
    if scheme_overlay is not None:
        receipt["schemeTaskLifecycle"] = {
            "patchSHA256": scheme_overlay["sha256"],
            "files": {name: data["preparedSHA256"]
                      for name, data in scheme_overlay["files"].items()}}
    forwarding_overlay = lock.get("forwardingLifecycleOverlay")
    if forwarding_overlay is not None:
        receipt["forwardingLifecycle"] = {
            "patchSHA256": forwarding_overlay["sha256"],
            "files": {name: data["preparedSHA256"]
                      for name, data in forwarding_overlay["files"].items()}}
    return receipt


def prepared_files(lock):
    """Every file the preparation must own: name -> prepared checksum.

    Overlays merge in application order (embedding, scheme, forwarding); on
    overlap the later overlay's output is the expected final state.
    """
    files = dict(lock["embeddingOverlay"]["files"])
    scheme_overlay = lock.get("schemeTaskLifecycleOverlay")
    if scheme_overlay is not None:
        files.update(scheme_overlay["files"])
    forwarding_overlay = lock.get("forwardingLifecycleOverlay")
    if forwarding_overlay is not None:
        files.update(forwarding_overlay["files"])
    return files


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

    scheme_overlay = lock.get("schemeTaskLifecycleOverlay")
    scheme_patch = None
    if scheme_overlay is not None:
        scheme_patch = contained(lock_path.parent, scheme_overlay["patch"])
        if digest(scheme_patch) != scheme_overlay["sha256"]:
            raise ValueError("Office scheme lifecycle patch checksum mismatch")
        for name, hashes in scheme_overlay["files"].items():
            source = contained(root / "source", name)
            if digest(source) != hashes["originalSHA256"]:
                raise ValueError(
                    f"Office source does not match the scheme lifecycle overlay: {name}")

    forwarding_overlay = lock.get("forwardingLifecycleOverlay")
    forwarding_patch = None
    if forwarding_overlay is not None:
        forwarding_patch = contained(lock_path.parent, forwarding_overlay["patch"])
        if digest(forwarding_patch) != forwarding_overlay["sha256"]:
            raise ValueError("Office forwarding lifecycle patch checksum mismatch")
        # Its input hashes describe the embedding-prepared state (it applies
        # after the embedding overlay), verified against the staged files
        # below rather than the pristine pinned sources.

    receipt = expected_receipt(lock)
    destination = root / "prepared/native"
    if destination.exists() or destination.is_symlink():
        if destination.is_symlink() or not (destination / "overlay.json").is_file():
            raise ValueError("Existing native preparation is not owned by this overlay")
        if json.loads((destination / "overlay.json").read_text()) != receipt:
            raise ValueError("Existing native preparation uses a different overlay")
        for name, checksum in prepared_files(lock).items():
            if digest(contained(destination, name)) != checksum["preparedSHA256"]:
                raise ValueError("Prepared native source was edited; preserve it and use a fresh bundle")
        return receipt
    with tempfile.TemporaryDirectory(dir=root / "prepared", prefix=".native-") as folder:
        stage = Path(folder).resolve()
        for name in prepared_files(lock):
            target = contained(stage, name)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(root / "source" / name, target)
        subprocess.run(["git", "apply", "--check", str(patch)], cwd=stage, check=True, capture_output=True)
        subprocess.run(["git", "apply", str(patch)], cwd=stage, check=True, capture_output=True)
        if scheme_patch is not None:
            # Applies after the embedding overlay; the file sets do not overlap.
            subprocess.run(["git", "apply", "--check", str(scheme_patch)],
                           cwd=stage, check=True, capture_output=True)
            subprocess.run(["git", "apply", str(scheme_patch)],
                           cwd=stage, check=True, capture_output=True)
        if forwarding_patch is not None:
            # Applies after the embedding (and scheme) overlays; its declared
            # input state is the embedding-prepared file, checked here so a
            # drifted embedding overlay fails before the patch is applied.
            for name, hashes in forwarding_overlay["files"].items():
                if digest(contained(stage, name)) != hashes["originalSHA256"]:
                    raise ValueError(
                        f"Office prepared source does not match the forwarding lifecycle overlay input: {name}")
            subprocess.run(["git", "apply", "--check", str(forwarding_patch)],
                           cwd=stage, check=True, capture_output=True)
            subprocess.run(["git", "apply", str(forwarding_patch)],
                           cwd=stage, check=True, capture_output=True)
        expected = {name: data["preparedSHA256"]
                    for name, data in prepared_files(lock).items()}
        for name, checksum in expected.items():
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
