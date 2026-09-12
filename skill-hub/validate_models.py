#!/usr/bin/env python3
"""Validates skill-hub/models.json before publication.

Rules:
  * status=ready entries must have at least one file with https URL, 64-hex
    SHA-256 and a positive size; they are downloaded by the app and verified.
  * status=pending-assets entries may be empty (conversion CI fills them in).
  * status=license-check entries must stay out of ready until a human flips
    the license to a concrete value.
  * Allowed licenses: MIT, BSD-2-Clause, BSD-3-Clause, Apache-2.0, ISC, MPL-2.0,
    EPL-1.0, 0BSD, Zlib, CC0-1.0, Unlicense, Public-Domain. GPL/AGPL and
    non-commercial licenses are rejected.
  * Every entry must point at floe-video and declare a capability.

Usage: python3 skill-hub/validate_models.py [path/to/models.json]
"""

from __future__ import annotations

import json
import pathlib
import re
import sys

ALLOWED = {
    "MIT", "BSD-2-Clause", "BSD-3-Clause", "Apache-2.0", "ISC", "MPL-2.0",
    "EPL-1.0", "0BSD", "Zlib", "CC0-1.0", "Unlicense", "Public-Domain",
}
REJECTED = {"GPL", "GPL-2.0", "GPL-3.0", "LGPL", "LGPL-2.1", "LGPL-3.0", "AGPL-3.0", "S-Lab", "CC-BY-NC", "CC-BY-NC-4.0"}
HEX64 = re.compile(r"^[0-9a-fA-F]{64}$")
STATUSES = {"ready", "pending-assets", "license-check", "excluded"}


def main() -> int:
    path = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parent / "models.json"
    payload = json.loads(path.read_text())
    models = payload.get("models", [])
    errors: list[str] = []
    warnings: list[str] = []
    seen: set[str] = set()
    for model in models:
        identifier = model.get("id", "<missing id>")
        if identifier in seen:
            errors.append(f"{identifier}: duplicate id")
        seen.add(identifier)
        status = model.get("status", "pending-assets")
        if status not in STATUSES:
            errors.append(f"{identifier}: unknown status {status}")
        if model.get("skillID") != "floe-video":
            errors.append(f"{identifier}: skillID must be floe-video")
        if not model.get("capability"):
            errors.append(f"{identifier}: capability is required")
        license_name = model.get("license")
        if status == "excluded":
            if model.get("files") or not model.get("notes"):
                errors.append(f"{identifier}: excluded entries require a reason and no downloadable files")
            continue
        if license_name in REJECTED:
            errors.append(f"{identifier}: license {license_name} is not allowed")
        if status == "ready":
            if license_name == "check" or license_name not in ALLOWED:
                errors.append(f"{identifier}: ready entries need an allowed concrete license")
            files = model.get("files", [])
            if not files:
                errors.append(f"{identifier}: ready entries need at least one file")
            for file in files:
                if not file.get("url", "").startswith("https://"):
                    errors.append(f"{identifier}: file URL must be https")
                if not HEX64.match(file.get("sha256", "")):
                    errors.append(f"{identifier}: file sha256 must be 64 hex characters")
                if not isinstance(file.get("sizeBytes"), int) or file["sizeBytes"] <= 0:
                    errors.append(f"{identifier}: file sizeBytes must be a positive integer")
        elif status == "license-check":
            warnings.append(f"{identifier}: awaiting license confirmation")
        else:
            warnings.append(f"{identifier}: assets pending conversion CI")
    for warning in warnings:
        print(f"warning: {warning}")
    for error in errors:
        print(f"error: {error}")
    print(f"{len(models)} models, {len(errors)} errors")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
