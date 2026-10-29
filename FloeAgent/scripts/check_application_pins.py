#!/usr/bin/env python3
"""Validate the Xcode application pins before any expensive release build.

`project.yml` declares the app-only Xcode packages; `Package.resolved` is the
committed host lock that supplies the full pin state. Every remote Xcode package
must be an immutable revision and must agree with the committed lock before an
archive starts, so a mutable or drifted declaration fails in seconds instead of
after the build. The committed `Package.resolved` of each explicitly declared
local package (for example FloeCADKit) supplies the App-local dependency closure;
the host lock may omit those pins, but the Xcode graph must contain them. The
first-party FloeMacBridge sibling is allowed at its fixed `../FloeMacBridge`
path only when it is a tracked, clean directory of the same Git checkout whose
manifest matches the reviewed SHA-256, with every non-cache file tracked and no
symlinks, and with no lock of its own. The reviewed manifest, not a missing
lock, is its dependency guarantee: a changed manifest or new file needs an
explicit policy/test review. The full license inventory needs resolved package
checkouts and normally runs later, after packaging.

Read-only: no package checkouts, no lock or project writes. Standard library
only.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from resolved_pins import (
    application_local_pins,
    application_pins,
    resolved_pins,
    verify_resolution,
)

ROOT = Path(__file__).resolve().parents[1]  # FloeAgent/
REPO = ROOT.parent  # repository root


def load_committed_lock() -> list[dict]:
    """Read the committed host lock exactly like license_inventory.load_pins."""
    document = json.loads(
        subprocess.check_output(
            ["git", "show", "HEAD:FloeAgent/Package.resolved"], cwd=REPO, text=True
        )
    )
    return resolved_pins(document)


def check(
    project_yml: Path | None = None,
    lock: Path | None = None,
    committed: list[dict] | None = None,
) -> tuple[list[dict], list[dict]]:
    """Return (declared app pins, verified combined distribution pins).

    Raises ValueError for a mutable or drifted declaration and OSError /
    json.JSONDecodeError for unreadable inputs.
    """
    project_path = project_yml or (ROOT / "project.yml")
    project = project_path.read_text(encoding="utf-8")
    current = resolved_pins(
        json.loads((lock or (ROOT / "Package.resolved")).read_text(encoding="utf-8"))
    )
    app = application_pins(project)
    local = application_local_pins(project, project_path.parent)
    combined = verify_resolution(
        current,
        committed if committed is not None else load_committed_lock(),
        app,
        local,
    )
    return app, combined


def main(argv: list[str] | None = None) -> int:
    del argv  # no options: the release preflight requires the repository paths
    try:
        app, combined = check()
    except (ValueError, OSError, json.JSONDecodeError, subprocess.CalledProcessError) as error:
        print(f"error: application pin check failed: {error}", file=sys.stderr)
        return 1
    for pin in app:
        revision = pin.get("state", {}).get("revision", "")
        if len(revision) != 40:
            print(
                f"error: application pin is not an immutable revision: {pin.get('identity')}",
                file=sys.stderr,
            )
            return 1
    print(
        f"application pins OK: {len(app)} immutable Xcode package revision(s) match "
        f"HEAD:FloeAgent/Package.resolved and declared local package locks "
        f"({len(combined)} distribution pins; first-party sibling FloeMacBridge is "
        f"tracked at its fixed source path with a reviewed manifest and no lock of its own)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
