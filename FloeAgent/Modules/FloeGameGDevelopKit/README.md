# FloeGameGDevelopKit

Independent GDevelop adapter for Floe's game predevelopment flow. It provides
real standard GDevelop project JSON, an intact-tree inspector, a procedural
starter project, a typed export plan over the **official GDevelop SDK**, a
checked host export recipe, artifact byte verification, Web-artifact sealing
through `FloeGameCore`, and a truthful keyboard declaration for the existing
touch controls.

It is **not** App wiring, a new executor, or a claim that GDevelop runs on
iOS. The official GDevelop exporter is a desktop/Electron application; the
supported automated route is the existing Linux/CI build host. The resulting
static Web bundle can be played by the existing `GameWebPlayer`/WebKit route.

## Status

| Area | State |
| --- | --- |
| Standard project JSON + procedural PNG + events | implemented in this package |
| Intact tree inspection (unknown/nested projects preserved) | implemented, advisory only |
| Official SDK export | executable checked recipe + mac actual run verified |
| Real engine play/input proof | actual GDJS export run in headless Chromium (WebGL), ArrowRight/ArrowDown/Z observed |
| Artifact verification + sealing | implemented; 12 Swift tests pass on macOS against the real official export |
| Linux CI route | recipe implemented; not executed in this environment (mac route executed) |
| iOS arm64 objects | clean library build for `arm64-apple-ios26.0-simulator` passed (9 objects) |
| iOS App integration / UI | not included; root owns App wiring and native acceptance |
| On-device export | deliberately unsupported; see below |

## Project and import

`GameGDevelopTemplate.makeProject(title:projectUUID:)` returns a real
`game.json`, a procedurally generated `assets/floe_orb.png`, and
`floe-inputs.json`. The JSON contains a `Main` scene, a `Sprite` object, five
standard events (ArrowLeft/ArrowRight/ArrowUp/ArrowDown plus `z` reset), a real
GDevelop resource entry, and no generated HTML.

`GameGDevelopInspector.inspect(rootURL:)` is a bounded read-only probe:

- selects a primary project using `game.json`, `project.json`, `floe-game.json`
  then nested candidates;
- reports additional nested projects without deleting or merging them;
- reports missing/unsafe resources and malformed GDevelop-looking JSON;
- never imports, executes, downloads, edits or deletes source;
- returns diagnostics instead of gating an import.

`GameGDevelopProjectDocument` keeps the original bytes and exposes typed
project-name, UUID and instance-position edits for AI organization. Unknown
plugin fields, events, resources and nested data remain in the document; tests
assert this explicitly.

## Export contract

`GameGDevelopSDKPin.official56287` pins:

- tag `v5.6.287`, source commit `cfaccd2c20bba2b43fea529523042249c90b9a41`
- macOS universal asset sha256 `796c400bf38486146286f1c09d2605f4dc1cc00627e1ee7a06344919ac2ff7db`
- Linux portable asset sha256 `d40a70cbb9e16b1ec14a9ad9e864a58120a4b310ff6f99adfb44a57804fc8c05`
- MIT license (see `THIRD-PARTY-NOTICES.md`)

`GameGDevelopExportPlanner.plan(...)` emits a typed plan containing one
checked command. It runs on the existing Linux/macOS host/CI execution service;
this package does not spawn processes outside `GameGDevelopExportRunner`, which
uses `FloeGameBuildKit.GameBuildHostPort`. The command's script path must be a
host-readable path: the App-bundle `GameGDevelopTooling.exportScriptURL` is for
a local host, while a remote Linux host/CI job should stage
`Resources/gdevelop-export.py` into its workspace and pass that path. Headless
Linux requires `xvfb-run`; the recipe fails closed without it.

The bundled `Resources/gdevelop-export.py` recipe:

1. verifies the official release archive SHA256 and extracts it to a private
   SDK root (or reuses a verified `sdk-receipt.json`);
2. copies the complete source tree to a private staging directory (never edits
   the source; verifies the source project hash before/after);
3. runs the official CLI:
   `GDevelop --no-sandbox --disable-update-check --run-command EXPORT_HTML5_EXTERNAL <project>`;
4. requires the official output `index.html`, `data.js`, `gd.js`,
   compiled `code*.js`, pixi runtime and `LICENSE.GDevelop.txt`;
5. clears the editor's random `latestCompilationDirectory` staging path from
   `data.js` (metadata only), copies `floe-inputs.json`, and publishes a
   deterministic manifest with per-file SHA256 and a canonical digest;
6. publishes only after success; the source tree remains unchanged.

`GameGDevelopArtifactVerifier.verify(...)` independently re-checks the output:

- parses `gdjs.projectData` from `data.js` and validates the standard project;
- checks the GDJS entry/runtime, compiled code, resource files and license;
- checks `floe-inputs.json` against the expected declaration;
- returns a manifest whose digest can be bound to the source revision.

`GameGDevelopArtifactManifest.seal(source:to:)` builds the existing
`GameWebArtifactPackage` for the `.gdevelop` engine, so App/WebKit acceptance
uses the same sealed-artifact route as other Web engines.

## Keyboard / touch contract

GDevelop's official runtime binds browser `keydown`/`keyup` itself through
`getRenderer().bindStandardEvents(...)`; no `window.FloeGame.key` hook is
needed. The starter declares:

```json
{
  "schemaVersion": 1,
  "engine": "gdevelop",
  "movement": {"left": ["left"], "right": ["right"], "up": ["up"], "down": ["down"]},
  "buttons": [{"id": "reset", "label": "Z", "keys": ["z"]}]
}
```

Keys use fixed `GameKeyboardKey` raw values or DOM codes. The declaration is
validated; arbitrary gamepad labels are not claimed. The existing touch layer
maps its keyboard events to GDevelop's built-in keys.

## Why on-device export is not claimed

The official exporter is `newIDE`/Electron with Node filesystem access and the
GDJS desktop runtime bundle. It is not an iOS framework and there is no
official iOS libGD.js exporter distribution. Bundling the ~900 MB desktop app
in the App is not acceptable, and this package does not add a JS/Python/WASM
executor. Therefore:

- source creation, editing, import inspection, repository history and play of
  an already-exported Web artifact remain on-device;
- **export runs on the existing resolved Linux host or CI** via the checked
  recipe and the existing jobs/service lifecycle;
- the exported bundle is downloaded/attached by the host, verified, then sealed
  for the existing WebKit player.

To bundle an extension that is not part of the reviewed official runtime, the
CI recipe must install it explicitly from a pinned source into the SDK
distribution and record it in the manifest. This package does not execute or
trust arbitrary model-authored extensions.

## BuildKit integration recommendation (root-owned; not written here)

Minimal change for the existing `GameBuildCapabilityRegistry.gdevelopPlan`
and `floe-game-build-gdevelop` template:

1. replace the `manualEditor` stage with a `userCI` stage that downloads the
   pinned Linux portable zip, verifies `d40a70...c8c05`, extracts it, and runs
   `gdevelop --no-sandbox --disable-update-check --run-command
   EXPORT_HTML5_EXTERNAL <staged project>`;
2. run the checked `gdevelop-export.py` recipe instead of hand-written shell
   so SDK receipt, source staging, input copy and output manifest stay
   identical to this package;
3. change the output from `manualEditorExport` to `webBundle` named
   `gdevelop-web.zip`, produced by the export stage;
4. keep the version from the project's `gdVersion` / pinned SDK and preserve
   the project source archive as a separate non-downloadable source output;
5. add `floe-inputs.json` to the artifact and verify it before sealing.

No workflow YAML, App `project.yml`, root package or production file was
written by this task.

## Verification evidence

Actual official export (macOS universal app, 5.6.287):

- SDK archive SHA256 `796c400b...fdb`, verified by the recipe;
- export command `EXPORT_HTML5_EXTERNAL` exit 0;
- output `index.html` 6.9 KB, `data.js` 4.0 KB, compiled `code0.js`, 77 files,
  936,084 bytes, deterministic canonical digest `5ef70488...16d07b` in the private evidence manifest;
- headless Chromium (WebGL) loaded the official `index.html`; ArrowRight moved
  `Orb.x` 280→424, ArrowDown moved `Orb.y` 140→229.98, Z reset to (280,140);
- screenshot saved privately, not part of the App;
- 12 Swift tests passed on macOS (project/template/import, whole-tree preservation,
  artifact/seal, SDK receipt, typed plan/runner); clean iOS simulator object
  build passed (9 arm64 objects).

The host's private qualification workspace and artifact directory retain the exact logs,
manifest and hashes. No CI, App UI, Simulator or physical-device result is
claimed.

## License

Package source: MPL-2.0 (`LICENSE`). GDevelop official runtime/export bytes are
MIT; see `THIRD-PARTY-NOTICES.md`. The GDevelop name/logo are trademarks of
their owner and are not granted by the MIT license.
