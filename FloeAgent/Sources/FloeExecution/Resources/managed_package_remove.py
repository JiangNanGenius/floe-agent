"""Remove one managed distribution with RECORD ownership and rollback."""
import csv
import importlib.metadata
import json
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile


def normalized(name):
    return re.sub(r"[-_.]+", "-", name).lower()


def remove_distribution(root, name):
    root = Path(root).resolve(strict=True)
    distributions = list(importlib.metadata.distributions(path=[str(root)]))
    matches = [d for d in distributions if normalized(d.metadata.get("Name", "")) == normalized(name)]
    if len(matches) != 1:
        raise ValueError("Distribution is missing or ambiguous in the managed root")
    selected = matches[0]
    selected_files = list(selected.files or [])
    if not selected_files:
        raise ValueError("Distribution has no ownership RECORD")
    shared = {str(f) for d in distributions if d is not selected for f in (d.files or [])}
    paths = []
    for entry in selected_files:
        relative = Path(str(entry))
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError("RECORD escapes managed root")
        path = root / relative
        if not path.resolve().is_relative_to(root):
            raise ValueError("RECORD follows a link outside managed root")
        if str(entry) in shared:
            continue
        if path.is_dir():
            raise ValueError("RECORD must name files, not directories")
        if path.exists() or path.is_symlink():
            paths.append((relative, path))
    backup = Path(tempfile.mkdtemp(prefix="floe-remove-", dir=root.parent))
    moved = []
    try:
        for relative, source in paths:
            destination = backup / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            os.replace(source, destination)
            moved.append((source, destination))
    except BaseException:
        for source, destination in reversed(moved):
            os.replace(destination, source)
        raise
    finally:
        shutil.rmtree(backup)
    return len(moved)


if __name__ == "__main__":
    request = json.loads(input)
    root = next((p for p in sys.path if p.endswith("PythonPackages")), None)
    if root is None:
        raise RuntimeError("Managed package directory is unavailable")
    count = remove_distribution(root, request["distribution"])
    print("uninstalled=" + request["distribution"])
    print("filesRemoved=" + str(count))
