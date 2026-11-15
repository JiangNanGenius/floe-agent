#!/usr/bin/env python3
"""Read-only verification of the reviewed UIKit joystick and its sole patch."""
from pathlib import Path
import hashlib
import json

root = Path(__file__).resolve().parents[1] / "ThirdParty"
pin = json.loads((root / "Joystick-PIN.json").read_text())
for item in pin["files"]:
    data = (root / "JoyStickView" / item["path"]).read_bytes()
    prefix, suffix = b"#if canImport(UIKit)\n", b"#endif\n"
    if not data.startswith(prefix) or not data.endswith(b"\n" + suffix):
        raise SystemExit("Unexpected portability patch: " + item["path"])
    original = data[len(prefix):-len(suffix)]
    identity = hashlib.sha1(b"blob " + str(len(original)).encode() + b"\0" + original).hexdigest()
    if identity != item["upstreamBlob"]:
        raise SystemExit("Changed upstream source: " + item["path"])
license_bytes = (root / pin["licenseFile"]).read_bytes()
if hashlib.sha256(license_bytes).hexdigest() != pin["licenseSHA256"]:
    raise SystemExit("Changed upstream license")
print(json.dumps({"result": "passed", "commit": pin["commit"], "license": pin["license"], "files": len(pin["files"])}))
