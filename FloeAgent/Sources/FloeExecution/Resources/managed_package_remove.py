"""Remove one managed distribution with RECORD ownership and rollback."""
import csv
import importlib.metadata
import json
import io
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile


def normalized(name):
    return re.sub(r"[-_.]+", "-", name).lower()


def ownership_entries(distribution):
    # Validate the literal RECORD, not importlib.metadata.files: newer Python
    # versions filter nonexistent entries and can hide a malformed escape.
    record = distribution.read_text("RECORD")
    if not record or len(record) > 8 * 1024 * 1024:
        raise ValueError("Distribution has no bounded ownership RECORD")
    entries = []
    for row in csv.reader(io.StringIO(record), strict=True):
        if len(row) != 3 or not row[0]:
            raise ValueError("Malformed ownership RECORD")
        relative = Path(row[0])
        if relative.is_absolute() or ".." in relative.parts or "\\" in row[0]:
            raise ValueError("RECORD escapes managed root")
        entries.append(str(relative))
    if not entries:
        raise ValueError("Distribution has no ownership RECORD")
    return entries


def remove_distribution(root, name):
    root = Path(root).resolve(strict=True)
    distributions = list(importlib.metadata.distributions(path=[str(root)]))
    matches = [d for d in distributions if normalized(d.metadata.get("Name", "")) == normalized(name)]
    if len(matches) != 1:
        raise ValueError("Distribution is missing or ambiguous in the managed root")
    selected = matches[0]
    selected_files = ownership_entries(selected)
    shared = {f for d in distributions if d is not selected for f in ownership_entries(d)}
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
    # Inventory enumerates dist-info directories. Leaving an empty directory
    # after removing METADATA makes the next inventory fail as a corrupt install.
    # Only prune parents of owned files, deepest first; shared/unowned files keep
    # their directories intact and the managed root itself is never removed.
    parents = {parent for _, path in paths for parent in path.parents
               if parent != root and parent.is_relative_to(root)}
    for parent in sorted(parents, key=lambda path: len(path.parts), reverse=True):
        try:
            parent.rmdir()
        except OSError:
            pass
    return len(moved)


if __name__ == "__main__":
    request = input if isinstance(input, dict) else json.loads(input)
    root = os.environ.get("FLOE_PYTHON_PACKAGE_TARGET") or next((p for p in sys.path if p.endswith("PythonPackages")), None)
    if root is None:
        raise RuntimeError("Managed package directory is unavailable")
    layer = os.environ.get("FLOE_PYTHON_WRITABLE_LAYER")
    if layer and not Path(root).resolve().is_relative_to(Path(layer).resolve()):
        raise ValueError("Managed package directory escapes its environment")
    count = remove_distribution(root, request["distribution"])
    print("uninstalled=" + request["distribution"])
    print("filesRemoved=" + str(count))
