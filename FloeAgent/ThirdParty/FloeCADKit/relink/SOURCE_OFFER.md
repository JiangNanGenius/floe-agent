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

The upstream OCCT 7.8.1 base is unmodified:

- Project: https://github.com/Open-Cascade-SAS/OCCT
- Exact release tag: **`V7_8_1`** — a lightweight Git tag pointing directly at
  commit **`bd2a789f15235755ce4d1a3b07379a2e062fdc2e`**
  (`Update version to 7.8.1`, 2024-03-31; resolved 2026-10-10 via
  `git ls-remote` and the GitHub API).
- Fixed export archive:
  `https://github.com/Open-Cascade-SAS/OCCT/archive/refs/tags/V7_8_1.tar.gz`
- The source is public; obtaining it requires no registration, request or
  contact.

## Complete corresponding source of the linked (modified) library

Floe applies exactly one source change above that base:
`src/Standard/Standard_Type.cxx` keeps the non-owning type-registry allocation
alive for the OCCT image/process lifetime. The complete modified source is the
pinned upstream tree plus the retained patch, both shipped in this repository:

- base file:
  `relink/derivations/standard-type-lifetime/base/src/Standard/Standard_Type.cxx`
  (4,409 bytes; SHA-256
  `5b3489f3d4ecb10a87d5963ce67fc61c5a48390c8c18f8b34f2cfc2438743442`);
- patched overlay:
  `relink/derivations/standard-type-lifetime/overlay/src/Standard/Standard_Type.cxx`
  (4,709 bytes; SHA-256
  `54aed57c03ce3204c94c372c143f5dcab4b1362a2b07fc9f2579cb3926384846`);
- unified diff:
  `relink/derivations/standard-type-lifetime/minimal.patch`
  (1,198 bytes; SHA-256
  `b4afd8174eec4b92bec3fd906059654952d1712f049728b9201723af5c794e8f`);
- build/target/recipe record:
  `relink/derivations/standard-type-lifetime.v1.json`.

No other OCCT source file, header or public class layout is changed.

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
4. Single-object derivation producer and archive/receipt verifier:
   `derivations/derive_standard_type_slice.py`,
   `derivations/derivation_common.py` and `derivations/occt_archive.py`.

A recipient can download the pinned source, apply the retained patch, and
rebuild or replace the slices using these retained inputs. The relink kit also
retains, one directory up, the pinned `bootstrap.py`/`DEPENDENCIES.json` pair:
it re-obtains the exact upstream base slices by content hash and reconstructs
the reviewed single-object derivation, verifying every other archive member
and the resulting receipt. The base archive alone is not accepted as a usable
slice because it lacks the reviewed lifetime repair.

## Scope and status

- This file records source-availability and rebuild-access facts only. It is
  **not a legal certification** and does not state or guarantee compliance for
  any particular distribution.
- Floe has not independently rebuilt all 47 OCCT toolkits and does not claim a
  full byte-identical rebuild. The installed slices are single-object
  reconstructions from the pinned upstream base: only `Standard_Type.cxx.o`
  changes; every other object payload is verified byte-identical to the base.
  The current qualified reconstruction results are pinned as `expectedResult`
  in `DEPENDENCIES.json` (device 149,038,056 bytes / `bb43f464…`; simulator
  147,188,808 bytes / `06a28492…`).
- This checkout is an **unreleased implementation**: no tag, upload or
  distribution has been produced from it.
- The release owner performs the final license review before distribution.

### Closed-profile guide contact backport

The additional OCCT 7.8.1 modification is retained in `derivations/guided-contact/`: the original and modified `src/GeomFill/GeomFill_LocationGuide.cxx` plus `minimal.patch`, under the upstream LGPL-2.1/Open CASCADE exception terms preserved in the files. `derivations/guided-contact.v1.json` declares the single-member build recipe and qualified toolchain. Bootstrap composes this after the existing Standard_Type lifetime derivation, retains the upstream archive anchor, and verifies the source/recipe hashes, nested parent receipt and final expected result. The unchanged single-object derivation producer can rebuild this member without rebuilding the full OCCT library.
