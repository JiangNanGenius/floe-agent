# Source availability and rebuild access for the OCCT static library

FloeCADKit (and the Floe application that embeds it) links **Open CASCADE
Technology (OCCT) version 7.8.1** as static libraries for iOS device and
simulator. OCCT is distributed under the **GNU Lesser General Public License
v2.1 with the Open CASCADE exception 1.0**; the verbatim texts are in
`../license.occt.txt` and `../OCCT_LGPL_EXCEPTION.txt`.

Because the library is statically linked, this file records, as an engineering
fact, where the **complete corresponding source** of the exact linked version
is publicly available and how the exact build inputs can be obtained to
rebuild and relink the library.

## Complete source for the exact linked version

OCCT 7.8.1 is unmodified upstream source (Floe modifies no OCCT source file):

- Project: https://github.com/Open-Cascade-SAS/OCCT
- Exact release tag: **`V7_8_1`** — a lightweight Git tag pointing directly at
  commit **`bd2a789f15235755ce4d1a3b07379a2e062fdc2e`**
  (`Update version to 7.8.1`, 2024-03-31; resolved 2026-10-10 via
  `git ls-remote` and the GitHub API).
- Fixed export archive:
  `https://github.com/Open-Cascade-SAS/OCCT/archive/refs/tags/V7_8_1.tar.gz`
- The source is public; obtaining it requires no registration, request or
  contact.

## Build inputs for rebuilding / relinking

The exact cross-build program and toolchain used for the shipped slices are
retained in this directory, pinned by content hash:

1. `build_occt_ios.sh` (5,831 bytes; SHA-256
   `6d46c488bec5c37d7ba543ce7a08b86caf66e92dd79216da1d9ea90b2f471289`),
   taken verbatim from OpenShape3D commit
   `30b3c7c1784754f237466e093ab42ff085175d40`.
2. `ios.toolchain.cmake` (58,209 bytes; SHA-256
   `8d17b77feb69999ebcf9aa4ce3e07babc3d39f9daa23151b1a4f05b825021f2e`),
   leetal/ios-cmake tag `4.6.1`, commit
   `b36d5bce6f9a2d11d9f144bd5882ba31cfdca420`, BSD-3-Clause
   (`LICENSE-ios-cmake.txt`).
3. Step-by-step build/relink instructions: `README.md` in this directory and
   `../OCCT_RELINK.md`.

A recipient can download the pinned source and rebuild or replace the slices
using these retained inputs. The relink kit also retains, one directory up, the
pinned `bootstrap.py`/`DEPENDENCIES.json` pair that re-obtains the exact
reviewed upstream slices by content hash.

## Scope and status

- This file records source-availability and rebuild-access facts only. It is
  **not a legal certification** and does not state or guarantee compliance for
  any particular distribution.
- Floe has not independently rebuilt OCCT from these inputs and does not claim
  a byte-identical reproduction of the shipped slices (see the Determinism
  section of `README.md`).
- This checkout is an **unreleased implementation**: no tag, upload or
  distribution has been produced from it.
- The release owner performs the final license review before distribution.
