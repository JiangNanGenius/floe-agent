#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Prepare source presets in a disposable, mounted clean Debian image root.

Does not boot, install, fetch, repackage or update any image ID/checksum.
--check is read-only. Existing environment disks are never an input.
"""
import argparse
import importlib.util
import json
from pathlib import Path

resources = Path(__file__).resolve().parents[3] / "Sources/FloeExecution/Resources"
spec = importlib.util.spec_from_file_location("floe_package_sources", resources / "linux_package_sources.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    catalog = json.loads((resources / "LinuxPackageSources.json").read_text())
    module.prepare_image(args.root, catalog, check=args.check)
    print(json.dumps({"prepared": True, "readOnlyCheck": args.check,
                      "defaultAPT": "official", "availableAPT": [p["id"] for p in catalog["apt"]],
                      "availablePyPI": [p["indexURL"] for p in catalog["python"]],
                      "guestAPTConfigVerified": False}))

if __name__ == "__main__":
    main()
