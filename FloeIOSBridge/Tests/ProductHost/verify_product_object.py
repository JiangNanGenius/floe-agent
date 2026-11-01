#!/usr/bin/env python3
"""Inspect the real optimized product Host object; this is not final App proof."""
import ast
import json
from pathlib import Path
import subprocess
import sys

host = Path(sys.argv[1])
verifier = Path(__file__).resolve().parents[2] / "scripts" / "verify_bridge.py"
markers = None
for node in ast.parse(verifier.read_text()).body:
    if isinstance(node, ast.Assign) and any(
        isinstance(target, ast.Name) and target.id == "RELEASE_LEGACY_MARKERS"
        for target in node.targets
    ):
        markers = ast.literal_eval(node.value)
assert markers, "could not read unchanged packaging policy"
data = host.read_bytes()
found = [value for value in markers if value.encode() in data]
# Even if all user-visible strings vanished, retained constructors or token
# lookups would violate the product initialization boundary.
names = subprocess.check_output(["nm", str(host)], text=True)
demangled = subprocess.run(["xcrun", "swift-demangle"], input=names,
                           text=True, capture_output=True, check=True).stdout
legacy_types = ("BridgeHost.BridgeDiagnosticsServer", "BridgeHost.BridgeLANControlService",
                "BridgeHost.BridgeHostCommandPoller", "BridgeHost.BridgeDiagnosticsStatus",
                "BridgeCore.BridgeInstallToken", "BridgeCore.BridgeFileChannel")
retained = [name for name in legacy_types if name in demangled]
result = {"object": str(host), "legacyMarkers": found,
          "legacyTypesOrCredentialReferences": retained,
          "scope": "optimized arm64 Host object only; final App verifier still required",
          "ok": not found and not retained}
print(json.dumps(result, indent=2))
if not result["ok"]:
    sys.exit(1)
