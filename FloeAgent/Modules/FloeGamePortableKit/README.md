# FloeGamePortableKit

Independent predevelopment package for real, reusable browser-game adapters:
**RPG Maker MV CoreScript**, **LÖVE/love.js**, and **Ren'Py Web (Beta)**.
It is not wired into the App, `project.yml`, the root Package or any release.
The host owns WebKit, projects, environments, jobs, credentials and acceptance.

## Engine matrix

| Engine | Source preserved | Web route | Template | Host input | Host snapshot | Restart | In-engine save |
| --- | --- | --- | --- | --- | --- | --- | --- |
| RPG Maker MV | Whole tree, all unknown files | Pinned official MIT CoreScript + reviewed MIT libs; imported `index.html` served unchanged when complete | Original RTP-free map/event/data/art | Typed keyboard key hook + logical actions | `DataManager.makeSaveContents` JSON snapshot/restore | Host restart | Through host snapshot |
| LÖVE | `main.lua`/`conf.lua`/`.love` | Pinned love.js 11.4.1 compatibility runtime (LÖVE 11.4.0 WASM, single-threaded) | Original Lua game | Typed keyboard key hook + pointer | Not available | Host restart | `love.filesystem`, engine-internal only |
| Ren'Py | `game/*.rpy` and assets | Official 8.5.3 `launcher web_build` Web (Beta) output | Original visual-novel project | Typed keyboard key hook | Not available | Host restart | Ren'Py save system, engine-internal only |

`GamePortableReadiness.webReady` means a complete Web entry exists. It is not a
claim that the App rendered it. `buildRequired` means the source survives but the
pinned tool must produce a separate artifact. `sourceOnly`/`blocked` are reported
honestly; nothing silently switches engines or rewrites imported source.

## Components

- `GamePortableRegistry`, `GamePortableRootScanner`: bounded inspection and
  candidate roots; no automatic nested-root choice, no archive expansion.
- `GamePortableRuntimePins` and `GamePortablePreparedResources`: exact upstream
  pins, file-set/SHA-256 verification, manifest digest and tamper failure.
- `GamePortableMVAssembler`: deterministic on-device merge/concatenation of the
  pinned CoreScript and libs (or a project's own `js/rpg_core/*.js` order). It
  copies original bytes and never executes JavaScript.
- `GamePortableBuildPlan`/`GamePortableBuildPort`: typed plan for the host's
  existing Linux `exec.shell`/jobs service. This package has **no** Process,
  shell, network or generic evaluator backend. LOVE and Ren'Py compiler steps are
  data, not hidden host execution.
- `GamePortableOverlayInstaller`: adds the original Floe bridge and
  `floe-inputs.json` to an already-built LOVE/Ren'Py artifact; it never edits the
  imported source.
- `GamePortableArtifactVerifier`/`GamePortableArtifactSealer`: required entries,
  WASM/ZIP sanity, runtime hash binding, native-executable rejection, input
  declaration validation, provenance receipt and stale-context rejection.
- `GamePortableSaveBridge`: JSON snapshot persistence for engines that actually
  expose a complete snapshot (currently MV), using `FileGameSaveRepository`.

## Minimal host flow

```swift
let registry = try FloeGamePortableKit.registry()
let project = try GamePortableProjectDescriptor(project: stored, rootURL: exportedHead, context: context)
let profile = try registry.inspect(project, engine: .rpgMakerMV)
// Optional: try GamePortableTemplateCatalog.install(.mv, to: destination)
let plan = try registry.plan(project, engine: .rpgMakerMV, outputURL: buildOutput,
                             resources: preparedCorescript, sdkURL: nil)
// The host executes plan.steps through its authorized build port.
let verification = try registry.verifyArtifact(at: buildOutput, engine: .rpgMakerMV,
                                               profile: profile, resources: preparedCorescript)
let sealed = try GamePortableArtifactSealer.seal(source: context, engine: .rpgMakerMV,
    entry: verification.entry, contentRoot: buildOutput, to: artifactURL,
    profile: profile, resources: preparedCorescript, buildKind: plan.kind)
try sealed.validate(current: context) // call again after every await
```

For an imported complete MV Web project, `plan.kind == .sourceCopy` and the
existing `index.html`/core/plugins are served unchanged. For an imported LOVE or
Ren'Py project the plan requires the injected build port; no host interpreter is
used as a product runtime.

## Keyboard declaration

Every starter emits `floe-inputs.json` with `schemaVersion: 1`, `engine`,
`movement` and `buttons`. Keys are fixed `GameKeyboardKey` raw values (for
example `left`, `z`, `shift`, `pageUp`) or browser DOM codes (`KeyZ`, `Digit1`,
`ArrowLeft`). They are data, not commands or permissions.

Verified template bindings:

- **MV:** arrows; Z/Enter/Space confirm; X/Escape cancel; Shift dash; Q/W page
  up/down. The bridge's `window.FloeGame.key(event)` forwards the exact key event
  to the original `Input` handlers; `window.FloeGame.input` remains for logical
  AI/legacy actions, not touch labels.
- **LÖVE:** arrows move; Z/Space pulse; X reset; S save; L load; Escape quit.
  The key hook forwards real keyboard events to love.js; pointer is forwarded as
  mouse events.
- **Ren'Py:** arrows focus; Enter/Space advance; Escape menu; Ctrl skip; Tab
  toggle skip; PageUp/PageDown rollback/rollforward. These are the actual
  `renpy/common/00keymap.rpy` defaults for 8.5.3.

Imported projects with custom bindings are not assumed to use these keys. If no
valid declaration exists, the profile reports unknown inputs and the host should
prompt or allow explicit user keys.

## Pinned on-demand resources and distribution profile

`Scripts/prepare_corescript.py`, `prepare_lovejs.py` and `prepare_renpy_web.py`
download/clone only on explicit execution and write a new resource; `--check`
is read-only. The pins are in `Resources/Manifests` and copied into artifact
provenance. No runtime binary is embedded in this native package.

- MV CoreScript: `182e31449707ba7e406db0485c44c2a9d11e2dcd`, MIT, dist SHA-256
  checked against the upstream module order; PIXI 4.5.4 and vendored libs retain
  their MIT notices. MIT-only path.
- love.js: npm `love.js@11.4.1`, tarball SHA-256
  `9eb2db1f789254faed8e5cf7eeeded46a7e56ecbc931c88be809526c448d25fb`, source
  commit `8f9a7b85...` (the WASM is byte-identical; text is CRLF-normalized).
  The compatibility runtime is LÖVE 11.4.0. mpg123 1.25.6 is LGPL-2.1 and is
  covered by the exact-source/relink package in
  `licenses/LOVE-11.4-COMPONENT-ADDENDUM.md`. The retained 11.5 notice is not
  used for this binary. IDBFS persistence requires Root's patched
  `Module.floePrepareToStop` candidate or equivalent; the unpatched loader is
  not durable.
- Ren'Py: official `renpy-8.5.3-web.zip` SHA-256
  `954db897e65f51ea63cb2fb7b203d02be0447f4e22069514020bbe6c6691fdfc`, SDK
  `8.5.3.26051504` SHA-256
  `0579782517f203ba3535dcc2dab54e34bfc318f2f2a7510a5130b6f809f901f6`, source
  pins `39895c1e...` / `7bfab40c...`; build through
  `renpy.sh launcher web_build`. LGPL components (FFmpeg, FriBidi, chardet,
  SDL_gfx, pygame portions) have exact source/relink records in
  `licenses/RENPY-8.5.3-COMPONENT-ADDENDUM.md`.
- The machine-readable receipt is `Scripts/Distribution/distribution-lock.json`
  and the read-only preflight is `Scripts/Distribution/check_distribution.py`.
  It verifies pin/revision/artifact hashes, every runtime file, every notice,
  every source package, the LGPL source/relink records and the MPL-2.0 hygiene.
- The full public source publication remains the release owner's task. The
  private depot contains the exact source packages; the release owner must
  publish them with the binary or provide the LGPL §6(c) written offer.

## What was actually exercised

Private qualification artifacts contain real Node/Chromium runs (not native
rendering acceptance) for all three templates:

- MV: actual CoreScript `Scene_Title -> Scene_Map`, map/event command 101/121,
  real save snapshot/restore, typed direction, fixed key hook and adapter
  readiness.
- LÖVE: actual love.js compatibility WASM boot (`LÖVE 11.4.0`), Lua movement,
  keypressed pulse, `love.filesystem` save/load, pointer/key input, restart.
- Ren'Py: official `web_build` output, actual `renpy.wasm`/`game.zip` load,
  script state/menu transitions, fixed key hook, trusted pointer choice, restart.
- Data/import/codec tests are the existing GameKit coverage; no claim is made
  here for a full native App/UI run.

## Known limits

- No App/WebKit integration, Xcode project membership, versioning, release,
  credential, Simulator or physical-device claim lives here.
- Ren'Py Web is officially Beta; networking, Python threading and arbitrary
  requests are unavailable. Its complete host snapshot is unavailable.
- The unpatched love.js loader has no host snapshot and flushes IDBFS only on
  `beforeunload`; a real new-player save failed on the original runtime. Root's
  patched candidate passed actual native WebKit cross-player save with unchanged
  `love.wasm`/`game.data`; the candidate's 11.5 notice folder must be replaced
  with this package's 11.4 bundle before distribution. Do not claim durable
  saves from the unpatched loader.
- MV imported projects can contain plugins that use Node/nw.js; those are
  detected and reported, not made to work on Web. Encrypted assets require the
  project's original key and are not claimed.
- LGPL components are retained with exact source, notices and a relink route
  (LGPL-2.1 §6(a)); this is not legal advice and not an App Store approval.
- No RTP, RPG Maker editor assets, MZ runtime, Unity Editor, proprietary SDK or
  signed iOS executable is bundled.

## Verify locally

```sh
swift test --package-path FloeAgent/Modules/FloeGamePortableKit
swift build --package-path FloeAgent/Modules/FloeGamePortableKit --product floe-game-portable
floe-game-portable pins
floe-game-portable inspect <project-root>
floe-game-portable verify <artifact-dir> --engine rpgMakerMV \
  --resources <prepared-resource> --manifest <prepared-resource.manifest.json>
```

Native/Swift checks must run through the repository's serialized native window;
this README does not claim they have run in a later environment.

License: MPL-2.0 for component source. Starter game content is additionally MIT;
third-party runtimes retain their upstream licenses.


## Root keyboard contract correction (2026-11-12)

This source supersedes the worker checkpoint only for the keyboard contract.
`FloeGameTouch` is now the shared declaration validator. Imported custom IDs,
empty/partial movement, optional labels, 64 controls and chords of up to eight
unique physical keys follow the same rules as native settings. Original JSON
bytes are validated before a typed decode can discard unknown fields.

Default arrays name one physical key. Z/Enter/Space alternatives are not
pressed together; actual user chords remain supported. Duplicate preset keys
were removed. Source/archive preservation, runtime pins and engine code are
unchanged. The prior worker source ZIP and all original evidence remain under
a host qualification artifact directory. The App host records its
separate qualification and source inventory in `portable-final`.
