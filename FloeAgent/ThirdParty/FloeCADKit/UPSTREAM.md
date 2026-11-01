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
- Base slices (upstream pins; the installed slice is derived from these):
  - `ios-arm64/libOCCT-OS64.a` — size 149,038,832 bytes,
    SHA-256 `b4abdbf22f704cfad0be3e67a686f727cc9bb0429d09dbef2153728b81850b50`
  - `ios-arm64-simulator/libOCCT-SIMULATORARM64.a` — size 147,189,584 bytes,
    SHA-256 `a46899cb51e03fcf57c159bfca2b99e2931b2fdfbd457fd2e1074c19c2b4b087`
  - Headers: the device slice's 7,963 flat headers (`ios-arm64/Headers`);
    the simulator slice symlinks to them (they are platform-independent).
  - Floe source change: one surgical backport in
    `src/Standard/Standard_Type.cxx` (registry allocation lifetime). The exact
    base, patched overlay and unified diff are retained under
    `relink/derivations/standard-type-lifetime/`; the recipe and all hashes
    are in `relink/derivations/standard-type-lifetime.v1.json`. Every other
    archive member is byte-identical to the pinned base.
  - Current qualified reconstruction results (`expectedResult` pins): device
    149,038,056 bytes / SHA-256 `bb43f464…`; simulator 147,188,808 bytes /
    SHA-256 `06a28492…`. These are the actual Xcode 27.1 Release O3
    single-object results. Root recorded an App121 relink identity; the App125 normal
    STEP/process-exit gate remains pending and is not claimed here.
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
- `bootstrap.py` requests the exact base objects from the pinned LFS batch
  endpoint `https://github.com/laanlabs/OpenShape3D.git/info/lfs/objects/batch`,
  verifies byte size and SHA-256, refuses paths outside this package and
  installs atomically (a partial or wrong-hash download cannot corrupt existing
  bytes). The LFS batch response is size-bounded, HTTPS redirects may not
  downgrade to plain HTTP, and remote error text is redacted so short-lived
  pre-signed URLs never reach logs. `DEPENDENCIES.json` schema 2 additionally
  requires the reviewed Standard_Type derivation for each slice; an older
  bootstrap refuses schema 2 instead of replacing the corrected slice with the
  crashing base.
  - prepare/repair (required derivation): `python3 bootstrap.py` — fetch and
    verify the pinned base, compile the one reviewed object, splice it into the
    archive, verify every other member and install the result atomically; the
    bare base is never accepted as prepared.
  - read-only verification (no network, no writes): `python3 bootstrap.py
    --check` — `PREPD` for a valid receipt, `UNPREP` for the bare base,
    `STALE`/`UNDERI` for a missing/mismatched receipt.
  - release gate (read-only): `python3 bootstrap.py --release-check` — requires
    a valid receipt, the recipe's qualified Xcode/SDK toolchain and the tracked
    `expectedResult` size/SHA-256.
  - deliberate local rebuild/replacement opt-in: `python3 bootstrap.py --check
    --local-relink` (or `FLOECAD_LOCAL_RELINK=1`), which keeps differing local
    bytes and reports them `LOCAL`; the bare pinned base remains `UNPREP` and
    cannot satisfy `--release-check`. The hook contract is documented in
    `OCCT_RELINK.md` and `relink/README.md`.
- `OCCT_RELINK.md` and `relink/` record the pinned relink material (upstream
  build program, toolchain, OCCT commit and source-availability statement) and
  the exact one-file Standard_Type backport (base, overlay, patch, recipe).
  The base slices are upstream-built; installed slices are local single-object
  reconstructions. Floe claims no full byte-identical 47-toolkit rebuild.
- `Vendor/OCCT.xcframework/**/*.a` is Git-ignored (see `.gitignore` beside this
  file and the repository root) so future history never re-adds the blobs.
- Tests for the integrity/partial-download/wrong-hash/read-only/offline/absent,
  path-escape, schema-version, bounded-batch, redaction, redirect-downgrade and
  local-relink behaviours live in `Tests/bootstrap_tests.py`. The derivation
  contract, receipt/archive invariants and bootstrap derived-flow tests live in
  `Tests/derivation_tests.py`; archive surgery tests live in
  `Tests/occt_archive_tests.py`.

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
