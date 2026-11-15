# Third-party notices

## ZIPFoundation (MIT)

- Upstream: https://github.com/weichsel/ZIPFoundation
- License: MIT (Copyright (c) 2017-2025 Thomas Zoechling and the ZIP Foundation project authors)
- How used: consumed as a reviewed vendored SwiftPM path dependency at
  `../FloeDiagramKit/Vendor/ZIPFoundation`. No ZIPFoundation source is copied
  into this package. The vendor copy is the same 0.9.x line pinned by
  FloeDiagramKit (`exact: 0.9.20`) and retains its upstream `LICENSE`.
- Used for: ZIP container reading/writing, deflate, CRC32 computation.

## FloeGameKit / FloeGameCore (MPL-2.0)

- Path dependency `../FloeGameKit` (same repository, independent component).
- Used for: project identity/context types, repository (create/import/commit/
  export), engine identifiers, hashing helpers and web-artifact sealing.

No engine SDK, Unity Editor, RTP asset, proprietary DLL or GPL component is
bundled by this package.


## Build/CI tool references (not bundled)

- `game-ci/unity-builder` and the Unity Editor are user-configured CI tools;
  no Unity SDK/license is distributed by Floe.
- Godot export templates are MIT; the `barichello/godot-ci` container is a
  community image tagged `4.2` in the generated template.
- Cocos Creator is a proprietary user-installed editor; the generated template
  requires the user's CLI path and Android SDK/NDK.
- GDevelop 5.6.287 is MIT; the generated template downloads the official Linux
  release from the pinned URL and verifies its SHA-256. Floe's exporter helper
  is MPL-2.0 and is paired as readable source.
- WASM-4, TIC-80, inkjs, SugarCube, microStudio, LÖVE/love.js, Ren'Py and RPG
  Maker MV CoreScript notices are selected per distribution profile under
  `Resources/Distribution/Notices/`; linked/embedded third-party bytes retain
  their actual licenses.
- Actions are pinned by full commit SHA in generated YAML:
  `actions/checkout@fbc6f399...`, `actions/download-artifact@d3f86a10...`,
  `actions/upload-artifact@ea165f8d...`, `game-ci/unity-builder@4423ee75...`.
  Container images use explicit version tags.

## Distribution boundary

`Resources/Catalog/distribution-profiles.v1.json` selects the notices, readable
Floe helper source and paired corresponding-source/relink artifacts for each
engine. A distribution bundle re-hashes those bytes and fails closed when a
required paired source is missing; a private-playback bundle is explicitly
conditional and is never labelled distribution-ready. Original user game files
retain their own terms and are never relicensed by Floe.
