# FloeCADKit OCCT relink kit

This directory holds the **pinned inputs** needed to rebuild the Open CASCADE
Technology (OCCT) static slices that FloeCADKit links, and the procedure to
replace the vendored slices with a locally built framework.

Status honesty: these inputs are pinned and available. Floe has **not**
independently rebuilt OCCT here, and makes **no claim** that a local rebuild is
byte-identical to the slices shipped by upstream (see "Determinism" below).
The shipped slices are the upstream OpenShape3D Git-LFS objects.

> This is engineering/reproducibility material and a source-availability
> record — **not a legal opinion or certification**. The release owner conducts
> the final license review before distribution. See `../OCCT_RELINK.md`.

## Two distinct paths — do not mix them

| Path | When it applies | Behaviour |
| --- | --- | --- |
| **Required derivation** (default) | CI, release builds, fresh checkouts | `python3 bootstrap.py` fetches and verifies the exact pinned base, reconstructs the reviewed single `Standard_Type.cxx.o` member from the tracked recipe/source/patch, verifies every other member and installs the derived slice atomically. `--check` reports `UNPREP` for the bare base and `STALE`/`UNDERI` for a missing/mismatched receipt; `--release-check` additionally requires the qualified Xcode/SDK and tracked `expectedResult`. |
| **Deliberate local rebuild/replacement** (opt-in) | A developer intentionally relinks a locally built OCCT | Set `FLOECAD_LOCAL_RELINK=1` (or pass `--local-relink`). Differing existing slices are **never overwritten**; `--check --local-relink` reports them as `LOCAL` and exits 0. The bare pinned base is still `UNPREP` (it is not a local replacement), and `LOCAL` never satisfies `--release-check`. |
| **Legacy pinned-only manifest** (schema 1) | Historical checkouts / older bootstrap revisions | Exact upstream slices only, no derivation. The new schema-2 official path does not use this mode. |

Without the opt-in, bootstrap is in required-derivation mode: a
present-but-mismatching slice is reconstructed from the pinned base and tracked
recipe (logged as `prepare`) and installed only after receipt verification.
With the opt-in, differing bytes are kept and reported `LOCAL` — bootstrap
never overwrites a deliberate local replacement. In opt-in mode a **missing**
slice is still prepared from the pinned base plus derivation (there is nothing
to overwrite); only existing differing bytes are protected.

## Build-script integration (hook contract)

`FloeAgent/scripts/local_build.sh` and the CI app job currently run
`python3 bootstrap.py` before building. For an intentional local replacement,
the hook must honor the same opt-in, exactly:

```sh
# FLOECAD_LOCAL_RELINK=1 is set only by a developer deliberately using local
# OCCT slices; official/CI/release builds must never set it.  Without it,
# bootstrap fetches the pinned base and reconstructs/verifies the required
# Standard_Type derivation before the App builds.
if [ "${FLOECAD_LOCAL_RELINK:-0}" = "1" ]; then
    echo "FloeCADKit: local relink in effect; skipping required derivation bootstrap"
else
    python3 ThirdParty/FloeCADKit/bootstrap.py
fi
```

Rules for the hook owner:

- `FLOECAD_LOCAL_RELINK=1` is **only** for a deliberate local rebuild; it must
  not be set in an official release or CI build.
- `bootstrap.py` itself honors the opt-in, so even a hook that still calls it
  directly will not overwrite a local replacement. The hook skip above only
  avoids the redundant network call.
- Official verification gates must run plain `python3 bootstrap.py --check`
  without the opt-in; that enforces the derivation receipt, the pinned base
  binding and every unchanged archive member. The release gate additionally
  runs `python3 bootstrap.py --release-check` (qualified toolchain and tracked
  `expectedResult`).
- `--local-relink` is the equivalent command-line flag when bootstrap is
  invoked directly rather than through the hook.

## Contents (all pinned by content hash)

| File | What it is | Pinned identity |
| --- | --- | --- |
| `build_occt_ios.sh` | Upstream's exact, self-contained OCCT cross-build program | OpenShape3D `scripts/build_occt_ios.sh` @ `30b3c7c1784754f237466e093ab42ff085175d40`; 5,831 bytes; SHA-256 `6d46c488bec5c37d7ba543ce7a08b86caf66e92dd79216da1d9ea90b2f471289` |
| `ios.toolchain.cmake` | leetal ios-cmake cross toolchain used by the build | tag `4.6.1`, commit `b36d5bce6f9a2d11d9f144bd5882ba31cfdca420`; 58,209 bytes; SHA-256 `8d17b77feb69999ebcf9aa4ce3e07babc3d39f9daa23151b1a4f05b825021f2e` |
| `LICENSE-ios-cmake.txt` | BSD-3-Clause license for the toolchain file | copied from the pinned ios-cmake commit |
| `SOURCE_OFFER.md` | Source-availability and rebuild-access statement for OCCT 7.8.1 | public pins + retained build inputs |
| `derivations/standard-type-lifetime.v1.json` | Required single-object backport recipe | OCCT commit, base/overlay/patch hashes, member identity, per-slice base archive/member digests, declared flags, qualified toolchain |
| `derivations/standard-type-lifetime/{base,overlay,minimal.patch}` | Exact modified source and diff | hashes recorded in the recipe (base `5b3489f3…`, overlay `54aed57c…`, patch `b4afd817…`) |
| `derivations/{occt_archive,derivation_common,derive_standard_type_slice}.py` | Archive surgery, receipt contract and derivation producer (`record`/`verify`/`inspect` modes included) | reviewed with the FloeCADKit package; no network/service dependency |
| `derivations/README.md` | Derivation contract, Root record workflow, honest limits | source packet |

OCCT's own license texts live one directory up and are not duplicated here:

- `../license.occt.txt` — GNU LGPL v2.1
- `../OCCT_LGPL_EXCEPTION.txt` — Open CASCADE exception 1.0

The machine-readable pin set (library sizes/hashes, LFS object ids, endpoint,
commit, toolchain) is `../DEPENDENCIES.json`.

## Pinned inputs

- **OCCT source:** Open-Cascade-SAS/OCCT tag `V7_8_1` (7.8.1). The tag is a
  **lightweight tag pointing directly at commit
  `bd2a789f15235755ce4d1a3b07379a2e062fdc2e`** (`Update version to 7.8.1`,
  2024-03-31; verified 2026-10-10 with `git ls-remote` and the GitHub API).
  The full, unmodified source is publicly available:
  - Web: https://github.com/Open-Cascade-SAS/OCCT
  - Obtain a reproducible source tree with either:
    ```sh
    git clone https://github.com/Open-Cascade-SAS/OCCT.git OCCT-src
    git -C OCCT-src checkout bd2a789f15235755ce4d1a3b07379a2e062fdc2e
    # or a fixed export tarball:
    curl -L -o occt-V7_8_1.tar.gz \
      https://github.com/Open-Cascade-SAS/OCCT/archive/refs/tags/V7_8_1.tar.gz
    ```
- **Build program / reference slices:** OpenShape3D @
  `30b3c7c1784754f237466e093ab42ff085175d40`
  (https://github.com/laanlabs/OpenShape3D). The shipped slices are byte
  identical to that commit's Git-LFS objects; the bootstrap fetches them by
  content hash (see `../bootstrap.py`).
- **Toolchain:** the exact `ios.toolchain.cmake` retained here (hash above).
- **Build tools:** CMake ≥ 3.16 (upstream tested 4.4), Xcode with the iOS
  SDK, `libtool`, `xcodebuild`. The script runs `sysctl -n hw.ncpu` jobs by
  default; override with `JOBS=N`.

## Build + relink (deliberate local replacement)

The retained script derives its output root from its own location
(`<dir of script>/../ThirdParty/OCCT.xcframework`), so place it under a
`scripts/` directory in a scratch workspace to reproduce upstream layout:

```sh
set -euo pipefail
RELKIT=/path/to/FloeAgent/ThirdParty/FloeCADKit/relink
WORK="$HOME/occt-relink-scratch"
mkdir -p "$WORK/scripts" "$WORK/ThirdParty"

# 1) Lay down the pinned build program at its expected path.
cp "$RELKIT/build_occt_ios.sh" "$WORK/scripts/build_occt_ios.sh"
chmod +x "$WORK/scripts/build_occt_ios.sh"
# Integrity-check the pinned program and toolchain before use; the two
# expected SHA-256 values must match exactly:
shasum -a 256 "$WORK/scripts/build_occt_ios.sh" "$RELKIT/ios.toolchain.cmake"
#   6d46c488bec5c37d7ba543ce7a08b86caf66e92dd79216da1d9ea90b2f471289  .../build_occt_ios.sh
#   8d17b77feb69999ebcf9aa4ce3e07babc3d39f9daa23151b1a4f05b825021f2e  .../ios.toolchain.cmake

# 2) Get the OCCT 7.8.1 source (see pinned inputs), then build the two slices.
OCCT_SRC="$WORK/OCCT-src" \
IOS_TOOLCHAIN="$RELKIT/ios.toolchain.cmake" \
WORK="$WORK/build" \
PLATFORMS="OS64 SIMULATORARM64" \
DEPLOYMENT_TARGET="16.0" \
JOBS="$(sysctl -n hw.ncpu)" \
"$WORK/scripts/build_occt_ios.sh"
# -> produces "$WORK/ThirdParty/OCCT.xcframework"
```

Configuration baked into the pinned program: headless modelling +
ApplicationFramework (XDE) + DataExchange (STEP/IGES); Visualization, Draw,
DETools and all optional third-party dependencies OFF; static libs; C++17;
47 toolkits merged per slice with `libtool -static`.

### Replace and verify the vendored framework (opt-in path)

1. Build the slices with the recipe above (a single run for both platforms, so
   the two slices come from the same source revision).
2. Replace the two `.a` files in
   `FloeAgent/ThirdParty/FloeCADKit/Vendor/OCCT.xcframework/`:
   - `ios-arm64/libOCCT-OS64.a` ← built device slice
   - `ios-arm64-simulator/libOCCT-SIMULATORARM64.a` ← built simulator slice

   Keep the Git-tracked `Info.plist` and the flat `Headers` layout the binary
   package expects. The ObjC++ façade in `Sources/OCCTShim` is FloeCAD's own
   code and needs no change; its header search path points at
   `Vendor/OCCT.xcframework/ios-arm64/Headers`.
3. Opt in for subsequent builds and verification:
   `export FLOECAD_LOCAL_RELINK=1`. Plain `bootstrap.py` is the required
   derivation path and would replace a differing local slice; do not run it
   over a deliberate local rebuild.
4. Verify presence (read-only, no network):

   ```sh
   python3 ../bootstrap.py --check --local-relink
   # -> a locally built slice normally differs from the pinned base, so it is
   #    reported LOCAL with exit code 0. LOCAL confirms presence only and is
   #    explicitly NOT a hash check of the local build. The bare pinned base is
   #    still UNPREP and fails. LOCAL never satisfies the release gate.
   ```
5. Rebuild the app with the normal `xcodebuild` flow; the static archive is
   relinked into the app binary. The OCCT version is also surfaced through the
   native `capabilities` action (`OCCTKernel.version`).

### Restoring the required repaired slices

Unset the opt-in and run the default path:

```sh
unset FLOECAD_LOCAL_RELINK
python3 ../bootstrap.py          # fetch/verify base + reconstruct derivation
python3 ../bootstrap.py --check  # both slices must report PREPD
```

This intentionally replaces local rebuilds with the reviewed derived slices;
back up locally built slices first if they matter. The bare pinned upstream
base is never installed as a usable slice.

## Determinism and honest limits

- Floe has **not** independently reproduced the upstream slices, and no
  byte-equality is claimed or required for a local rebuild. The base SHA-256
  values identify the reviewed upstream archives; `expectedResult` identifies
  the qualified single-object reconstruction.
- OCCT is a C/C++ build: compiler/Xcode version, CMake version, absolute build
  paths, timestamps, locale and `libtool` input order can all change archive
  bytes even from identical source. Upstream's exact build environment is not
  recorded here, so equality is not asserted.
- A local rebuild substitutes the library only for local development. Official
  releases use the required derivation: the pinned base plus the reviewed
  Standard_Type object replacement, identified by its receipt and (after Root
  qualification) the tracked `expectedResult`. Official verification runs
  plain `bootstrap.py --check`; the release gate runs
  `bootstrap.py --release-check`.
- Floe modifies exactly one OCCT source file, `src/Standard/Standard_Type.cxx`.
  No other source, header or public ABI is changed.
- The single-object derivation is deterministic for the same base archive,
  replacement object and `ranlib`: member order and every non-index,
  non-target record are preserved, and the index record header is normalised.
  That is narrower than a full 47-toolkit rebuild reproducibility claim.
