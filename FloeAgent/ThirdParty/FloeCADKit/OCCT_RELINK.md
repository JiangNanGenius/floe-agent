# OCCT linking, license and relink statement

FloeCADKit links Open CASCADE Technology 7.8.1 as **static libraries**
(`Vendor/OCCT.xcframework`, device + simulator slices). OCCT is licensed under
**LGPL 2.1 with the Open CASCADE exception**; the verbatim texts ship beside
this file (`license.occt.txt`, `OCCT_LGPL_EXCEPTION.txt`).

## Exact provenance of the linked library

| Material | Pin |
| --- | --- |
| OCCT source | Upstream OCCT tag `V7_8_1` (7.8.1); lightweight tag pointing directly at commit `bd2a789f15235755ce4d1a3b07379a2e062fdc2e` (`Update version to 7.8.1`, 2024-03-31; resolved 2026-10-10), https://github.com/Open-Cascade-SAS/OCCT |
| Build program | OpenShape3D `scripts/build_occt_ios.sh` at commit `30b3c7c1784754f237466e093ab42ff085175d40`; 5,831 bytes, SHA-256 `6d46c488bec5c37d7ba543ce7a08b86caf66e92dd79216da1d9ea90b2f471289`; retained verbatim in `relink/build_occt_ios.sh` |
| Cross toolchain | leetal `ios-cmake` tag `4.6.1`, commit `b36d5bce6f9a2d11d9f144bd5882ba31cfdca420`; `ios.toolchain.cmake` retained in `relink/ios.toolchain.cmake` (58,209 bytes, SHA-256 `8d17b77feb69999ebcf9aa4ce3e07babc3d39f9daa23151b1a4f05b825021f2e`), BSD-3-Clause; passed via `IOS_TOOLCHAIN`; CMake ≥ 3.16 (upstream tested 4.4) |
| Configuration | Headless modelling + DataExchange/XDE: 47 toolkits; `BUILD_MODULE_*` set by the script; no visualization, no Draw, no third-party deps |
| Vendored slices | `ios-arm64/libOCCT-OS64.a` (149,038,832 bytes, SHA-256 `b4abdbf2…`) and `ios-arm64-simulator/libOCCT-SIMULATORARM64.a` (147,189,584 bytes, SHA-256 `a46899cb…`) — full hashes in `UPSTREAM.md`; byte-identical to the upstream OpenShape3D Git-LFS objects (verified 2026-10-10). These are the **upstream-built** slices; Floe has not rebuilt OCCT. |
| Floe changes to OCCT | **none** — no OCCT source file is modified by FloeCADKit |

## Available source vs. actually rebuilt

- **Available:** the complete OCCT 7.8.1 source is public at the pinned commit
  above; the exact build program and toolchain are retained in `relink/` at
  their content hashes; the build recipe is documented in `relink/README.md`.
- **Actually rebuilt:** nothing. Floe has **not** independently built OCCT from
  these inputs in this project, and does not claim that a local rebuild is
  byte-identical to the shipped upstream slices. The recorded SHA-256 values
  identify the reviewed official slices only. See the Determinism section of
  `relink/README.md`.

## Relink procedure (deliberate local replacement)

The relink route for the statically linked library is:

1. Obtain the OCCT 7.8.1 source tree at the pinned commit/tag and the retained
   toolchain:

   ```sh
   git clone https://github.com/Open-Cascade-SAS/OCCT.git OCCT-7_8_1
   git -C OCCT-7_8_1 checkout bd2a789f15235755ce4d1a3b07379a2e062fdc2e
   # or: curl -L -o occt-V7_8_1.tar.gz \
   #   https://github.com/Open-Cascade-SAS/OCCT/archive/refs/tags/V7_8_1.tar.gz
   ```

2. Run the retained build program `relink/build_occt_ios.sh` (it is
   self-contained; the header documents all environment variables). It derives
   its output root from its own location, so place it in a `scripts/` directory
   in a scratch workspace; `relink/README.md` gives the full recipe:

   ```sh
   OCCT_SRC=/path/to/OCCT-7_8_1 \
   IOS_TOOLCHAIN=/path/to/relink/ios.toolchain.cmake \
   WORK=/path/to/build-scratch \
   PLATFORMS="OS64 SIMULATORARM64" \
   ./build_occt_ios.sh          # pinned revision 30b3c7c, SHA-256 6d46c488…
   ```

3. Replace the two slice files under
   `FloeCADKit/Vendor/OCCT.xcframework` with the produced libraries, keeping
   the Git-tracked `Info.plist` and `Headers` layout. The package's ObjC++
   façade (`Sources/OCCTShim`) is FloeCAD's own code, is not part of OCCT, and
   needs no change: its header search path points into
   `Vendor/OCCT.xcframework/ios-arm64/Headers`, so a rebuilt framework with the
   same layout relinks the whole app against the rebuilt library.

4. Opt in so the pinned bootstrap and build hooks do not restore the official
   bytes over the local replacement: `export FLOECAD_LOCAL_RELINK=1` (or invoke
   `bootstrap.py --local-relink`). **Do not run plain `bootstrap.py`** while
   local slices are in place — that is the official path and would replace them
   with the pinned objects. The integration contract for
   `scripts/local_build.sh` / CI is in `relink/README.md`.

5. Rebuild the app with the normal `xcodebuild` flow; the static archive is
   relinked into the app binary.

6. Verify: `python3 bootstrap.py --check --local-relink` reports a rebuilt
   slice `LOCAL` (present; explicitly not a hash check of the local build,
   exit 0) — a slice that still matches the official pin reports `OK` — and
   the `OCCTKernel.version` string surfaced through the native `capabilities`
   action confirms the linked OCCT version at run time. Official verification
   of the pinned slices remains plain `python3 bootstrap.py --check`, which
   must report `OK` for both.

To restore the official slices deliberately: unset `FLOECAD_LOCAL_RELINK` and
run `python3 bootstrap.py` (re-obtains and verifies the pinned Git-LFS objects).

## Compliance status of this worktree (unreleased)

- This checkout is an **unreleased implementation**: no tag, TestFlight upload,
  website deployment or other distribution was produced from it.
- The relink material is present in `relink/` and is not left as a promise:
  - exact pinned build program `relink/build_occt_ios.sh` (whole-file SHA-256
    `6d46c488bec5c37d7ba543ce7a08b86caf66e92dd79216da1d9ea90b2f471289`);
  - pinned toolchain `relink/ios.toolchain.cmake` (tag `4.6.1`, commit
    `b36d5bce…`, file SHA-256 `8d17b77f…`) with its BSD-3-Clause license
    (`relink/LICENSE-ios-cmake.txt`);
  - public, immutable OCCT 7.8.1 source route (tag `V7_8_1` → commit
    `bd2a789f…`, fixed upstream archive URL) and the written
    source-availability statement `relink/SOURCE_OFFER.md`;
  - step-by-step rebuild/relink and verification instructions in
    `relink/README.md`, with the machine-readable pin set `DEPENDENCIES.json`;
    the two reviewed slices themselves are re-obtainable by content hash from
    the pinned upstream Git-LFS objects via `bootstrap.py`.
- License texts remain beside the package: `license.occt.txt` (LGPL 2.1),
  `OCCT_LGPL_EXCEPTION.txt` (Open CASCADE exception 1.0) and the MIT notice
  for the extracted OpenShape3D code (`LICENSE-OpenShape3D-MIT.txt`).
- The release owner performs the final license review for the intended
  distribution channels; this document is an engineering record, not a legal
  opinion or certification.
