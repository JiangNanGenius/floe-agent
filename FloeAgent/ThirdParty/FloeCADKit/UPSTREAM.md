# FloeCADKit upstream provenance

FloeCADKit vendors geometry/kernel/editor code and toolchain artifacts from
three upstream sources. All three are pinned; hashes below are the ones
actually recorded during extraction on 2026-10-09/10.

## OpenShape3D (geometry kernel, feature graph, editor state machine, Metal viewport)

- Repository: https://github.com/laanlabs/OpenShape3D
- Commit: `30b3c7c1784754f237466e093ab42ff085175d40` (branch `main`, 2026-10-05)
- License: MIT (`LICENSE`, copied here). Copyright 2026 Laan Labs and the
  openshape3d contributors.
- Extracted directories (with Floe modifications, see PATCHES.md):
  `Sources/FloeCAD/Kernel/**`, `Model/**`, `Rendering/**`, `Interaction/**`,
  `Editor/**`, `WorkbenchUI/**`.
- Explicitly NOT extracted: `Agent/**` (their MCP/HTTP agent),
  `App/**` (SwiftData project gallery/account/settings/bug reporting),
  `UI/EditorView.swift` shell navigation, `UI/ProjectGalleryView.swift`,
  `UI/SettingsView.swift`, `Demos/`, `Assets.xcassets/`.
  Their command vocabulary (`Agent/AgentExec.swift`) IS extracted as a typed
  operation model; execution goes through Floe's own gate (see PATCHES.md).

## OCCT.xcframework (Open CASCADE Technology 7.8.1 static slices)

- Source: same OpenShape3D repository, `ThirdParty/OCCT.xcframework`
  (Git LFS), built by upstream `scripts/build_occt_ios.sh` (OCCT 7.8.1,
  headless modelling + DataExchange/XDE, 47 toolkits).
- Vendored slices in `Vendor/OCCT.xcframework`:
  - `ios-arm64/libOCCT-OS64.a` — size 149,038,832 bytes,
    SHA-256 `b4abdbf22f704cfad0be3e67a686f727cc9bb0429d09dbef2153728b81850b50`
  - `ios-arm64-simulator/libOCCT-SIMULATORARM64.a` — size 147,189,584 bytes,
    SHA-256 `a46899cb51e03fcf57c159bfca2b99e2931b2fdfbd457fd2e1074c19c2b4b087`
  - Headers: the device slice's 7,963 flat headers (`ios-arm64/Headers`);
    the simulator slice symlinks to them (they are platform-independent).
  - The upstream `ios-arm64-maccatalyst` slice (147,197,528 bytes) is
    intentionally NOT vendored: FloeAgent is an iOS/iPadOS app and the extra
    147 MB is not needed. This is a recorded deviation, not an accidental
    omission; its upstream LFS object id was not downloaded, so no hash is
    claimed for it here.
- License: LGPL 2.1 with the Open CASCADE exception. `license.occt.txt`,
  `OCCT_LGPL_EXCEPTION.txt` and the relink statement are copied here;
  see `OCCT_RELINK.md`.

### Distribution and bootstrap (added 2026-10-10)

Both slices exceed GitHub's ordinary block-push limit (each is >100 MiB), so
they must not be committed as Git blobs; the copies currently present in
unpublished local history are being untracked by the coordinator's history
cleanup. Headers and `Info.plist` remain Git-tracked. Instead:

- `DEPENDENCIES.json` pins each slice by install path, byte size and SHA-256,
  plus the durable upstream Git-LFS source (repository, commit
  `30b3c7c1784754f237466e093ab42ff085175d40`, in-repo path and object oid).
  Git-LFS object oids are content-addressed and equal the SHA-256 values above.
- `bootstrap.py` requests the exact objects from the pinned LFS batch endpoint
  `https://github.com/laanlabs/OpenShape3D.git/info/lfs/objects/batch`, verifies
  byte size and SHA-256 before installing, refuses paths outside this package,
  never rewrites an already-matching file, and installs atomically (a partial
  or wrong-hash download cannot corrupt existing bytes). The LFS batch response
  is size-bounded, HTTPS redirects may not downgrade to plain HTTP, and remote
  error text is redacted so short-lived pre-signed URLs never reach logs.
  - install/repair (official pinned slices): `python3 bootstrap.py`
  - read-only verification (no network, no writes): `python3 bootstrap.py --check`
  - deliberate local rebuild/replacement opt-in: `python3 bootstrap.py --check
    --local-relink` (or `FLOECAD_LOCAL_RELINK=1`), which keeps local bytes and
    reports them `LOCAL` instead of restoring the pinned slices; the hook
    contract is documented in `OCCT_RELINK.md` and `relink/README.md`.
- `OCCT_RELINK.md` and `relink/` record the pinned relink material (upstream
  build program, toolchain, OCCT commit and source-availability statement).
  The shipped slices are upstream-built; Floe has not independently rebuilt
  OCCT and claims no byte-identical local reproduction.
- `Vendor/OCCT.xcframework/**/*.a` is Git-ignored (see `.gitignore` beside this
  file and the repository root) so future history never re-adds the blobs.
- Tests for the integrity/partial-download/wrong-hash/read-only/offline/absent,
  path-escape, schema-version, bounded-batch, redaction, redirect-downgrade and
  local-relink behaviours live in `Tests/bootstrap_tests.py`.

## ShapeScript (scripted mesh workflow)

- Repository: https://github.com/nicklockwood/ShapeScript
- Revision: `cda3024b2f17ac06aef23aae7ddcf39c217c6237` (master, library version
  1.11.6; MIT). Declared in `Package.swift` as an exact `revision` pin; the
  resolved transitive pins (LRUCache, SVGPath, Euclid 0.9.6) are recorded in
  `Package.resolved`.
- Usage: the `ShapeScript` library target is evaluated headlessly in
  `Sources/FloeCAD/Kernel/ShapeScriptKit.swift`; no ShapeScript app shell,
  viewer, CLI or docs are copied. Imports/models/textures/fonts are refused by
  a sandboxed `EvaluationDelegate`, evaluation is deadline/triangle bounded,
  and script records/results are Floe-owned (`CADScriptService`).
- License: MIT (upstream `LICENSE` applies to the linked package; no source is
  vendored into this repository).

## Euclid (mesh CSG)

- Repository: https://github.com/nicklockwood/Euclid
- Exact version: `0.9.6` (declared `exact` in `Package.swift`). Upstream
  OpenShape3D's lockfile pinned `0.8.18`; 0.9.6 is API-compatible for every
  call this extraction uses (`Mesh`, `Polygon`, `Path`, `Transform`,
  `Mesh.union/subtracting/intersection`, `makeWatertight`, `stlData`,
  `lathe/extrude/loft`) and is the version the upstream 2026-10 release is
  built against.
- License: MIT (retained by upstream and by SwiftPM; no source vendored).

## ShapeScript / Canvas creation path

ShapeScript is integrated (see above). The Canvas child-project entry from the
native workbench is still open; the 2D Canvas binding path from 1.7.24 is
unchanged. See the completion matrix in `docs/FLOE_CAD_AND_DRAWING_ASSISTANT.md`.
