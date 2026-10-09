# OCCT linking, license and relink statement

FloeCADKit links Open CASCADE Technology 7.8.1 as **static libraries**
(`Vendor/OCCT.xcframework`, device + simulator slices). OCCT is licensed under
**LGPL 2.1 with the Open CASCADE exception**; the verbatim texts ship beside
this file (`license.occt.txt`, `OCCT_LGPL_EXCEPTION.txt`).

Compliance notes:

- The vendored slices are byte-identical to the upstream OpenShape3D
  `ThirdParty/OCCT.xcframework` Git-LFS objects (hashes in UPSTREAM.md). No
  OCCT source is modified by FloeCADKit.
- The relink route is the upstream build script
  (`OpenShape3D/scripts/build_occt_ios.sh`, OCCT 7.8.1, CMake + ios-cmake),
  which produces the same xcframework from public OCCT source. Replacing
  `Vendor/OCCT.xcframework` with a locally built copy (and keeping this
  package's `OCCTShim` target unchanged) relinks the app against the modified
  library.
- The Objective-C++ façade (`Sources/OCCTShim`) is FloeCAD's own code and is
  not part of OCCT.
- Because the library is statically linked into the app binary, the LGPL
  obligations (license text, source availability for the linked library,
  relink capability) are documented here rather than satisfied by a build
  script comment alone. Release material must keep this file, the two license
  texts and the upstream build script reference with the shipped binary.
- This statement is a planned-compliance record, not a legal opinion; the
  primary agent owns release review.
