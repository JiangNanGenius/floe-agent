# Native runtime archive (pre-Phase-2)

This directory preserves the bundled native Python/Node machinery exactly as
it shipped through Build 211, so the recipes stay recoverable. **Nothing here
is part of the build.** The next IPA contains no Python/NodeMobile frameworks,
no Python standard library, no extension wheels and no NodeTools resources;
local Python/Node run inside each environment's TinyEMU Linux guest
(see `docs/PHASE2_migration.md`).

Do not re-reference these files from `project.yml`, `Package.swift`, CI
workflows or the app target — `scripts/audit_native_runtime_free.py` fails the
release if a native Python/Node marker reappears in the IPA or the project.

## Layout

- `bridges/` — the retired Objective-C bridges (`FloeCPythonBridge`,
  `FloeNodeBridge`) and their Swift owner (`IOSSystemNodeRuntime`).
- `recipes/` — build/download/pin recipes: CPython 3.13 iOS bootstrap,
  extension packaging, ios-wheelhouse builders (pandas/lxml/numpy/Pillow),
  bundled pure-Python preset installer and pins, NodeMobile/NodeTools pins.
- `ios-wheelhouse/` — the iOS wheel build manifests/recipes (moved from the
  repository root).
- `tests/` — the retired app/bridge test fixtures (native runtime, native
  services, wheel download, CPython bridge harnesses).
- `NodeTools/`, `PythonServiceBootstrap.py`, `managed_package_install.py`,
  `managed_package_remove.py` — resources that shipped inside the app.

## If a native runtime must be resurrected

Recover from Git history or this archive, re-add the download/embed paths
deliberately, and delete or update `scripts/audit_native_runtime_free.py` in
the same change so the decision is explicit and reviewable.
