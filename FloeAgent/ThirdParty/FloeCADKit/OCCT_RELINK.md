# OCCT linking, license and relink statement

FloeCADKit links Open CASCADE Technology 7.8.1 as **static libraries**
(`Vendor/OCCT.xcframework`, device + simulator slices). OCCT is licensed under
**LGPL 2.1 with the Open CASCADE exception**; the verbatim texts ship beside
this file (`license.occt.txt`, `OCCT_LGPL_EXCEPTION.txt`).

## Exact provenance of the linked library

| Material | Pin |
| --- | --- |
| OCCT source | Upstream OCCT git tag `V7_8_1` (7.8.1), https://github.com/Open-Cascade-SAS/OCCT |
| Build program | OpenShape3D `scripts/build_occt_ios.sh` at commit `30b3c7c1784754f237466e093ab42ff085175d40`; file size 5,831 bytes, SHA-256 `6d46c488bec5c37d7ba543ce7a08b86caf66e92dd79216da1d9ea90b2f471289` (copy retained for release material, see below) |
| Cross toolchain | leetal `ios-cmake` `ios.toolchain.cmake` (CMake ≥ 3.16; script tested with CMake 4.4), passed via `IOS_TOOLCHAIN` |
| Configuration | Headless modelling + DataExchange/XDE: 47 toolkits; `BUILD_MODULE_*` set by the script; no visualization, no Draw, no third-party deps |
| Vendored slices | `ios-arm64/libOCCT-OS64.a` (149,038,832 bytes, SHA-256 `b4abdbf2…`) and `ios-arm64-simulator/libOCCT-SIMULATORARM64.a` (147,189,584 bytes, SHA-256 `a46899cb…`) — full hashes in `UPSTREAM.md`; byte-identical to the upstream OpenShape3D Git-LFS objects |
| Floe changes to OCCT | **none** — no OCCT source file is modified by FloeCADKit |

## Reproducible relink procedure

The LGPL relink route for the statically linked library is:

1. Obtain the OCCT 7.8.1 source tree (tag `V7_8_1`) and the pinned
   `ios.toolchain.cmake`.
2. Run the exact build program recorded above (it is self-contained; the
   header documents all environment variables):

   ```sh
   OCCT_SRC=/path/to/OCCT-7_8_1 \
   IOS_TOOLCHAIN=/path/to/ios.toolchain.cmake \
   WORK=/path/to/build-scratch \
   PLATFORMS="OS64 SIMULATORARM64" \
   ./build_occt_ios.sh          # pinned revision 30b3c7c, SHA-256 6d46c488…
   ```

3. Replace `FloeCADKit/Vendor/OCCT.xcframework` with the produced framework.
   The package's ObjC++ façade (`Sources/OCCTShim`) is FloeCAD's own code, is
   not part of OCCT, and needs no change: its header search path points into
   `Vendor/OCCT.xcframework/ios-arm64/Headers`, so a rebuilt framework with the
   same layout relinks the whole app against the rebuilt library.
4. Rebuild the app with the normal `xcodebuild` flow; the static archive is
   relinked into the app binary.

Verification that a replacement is the reviewed build: the two archive
SHA-256 values above, and the `OCCTKernel.version` string surfaced through the
native `capabilities` action.

## Compliance status of this worktree (unreleased)

- This checkout is an **unreleased implementation**: no tag, TestFlight upload,
  website deployment or other distribution was produced from it.
- The material above is the complete planned-compliance record available at
  this stage: the pinned build program, its hash, the OCCT source tag, the
  toolchain reference and the byte-identical slice hashes. Keeping this file,
  `UPSTREAM.md`, `license.occt.txt` and `OCCT_LGPL_EXCEPTION.txt` beside the
  package is the local obligation and is satisfied here.
- **Release-gating follow-up** (must not be claimed as done): before any
  distribution of a binary containing these slices, the release material must
  also include the exact `build_occt_ios.sh` file at the pinned revision (or a
  durable archive of it), a written offer/source availability statement for
  OCCT 7.8.1, and the relink kit (source archive + toolchain pin) or a
  documented download route for it. This statement is a planned-compliance
  record, not a legal opinion; the primary agent owns release review.
