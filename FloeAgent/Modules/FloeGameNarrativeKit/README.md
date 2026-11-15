# FloeGameNarrativeKit

Independent predevelopment components for narrative and fantasy-console games:
real **[Ink/inkjs](#ink)** storyteller, **[Twine/SugarCube](#twine)** story format,
**[WASM-4](#wasm-4)** and **[TIC-80](#tic-80)** fantasy consoles, and
**[microStudio](#microstudio)** authoring/runtime. Production App wiring stays
separate; the App host owns grants, environment identity, packaging and GUI
acceptance. This package depends only on `FloeGameCore`/`FloeGameWebKit` from
`../FloeGameKit` and defines no execution service of its own.

Every adapter is a plain value/type API over folders: create an original
project, import an original standard project byte-exact, edit through the
existing `FileGameProjectRepository`, and build a genuinely runnable Web
artifact with the pinned upstream runtime. Engine script or build commands never
become model-facing executors: the only operations are the fixed Swift/Node
component steps in this package and the host's existing `exec.shell`/jobs ports.

## Engines, pins and licenses

| Engine | Runtime used in artifacts | Version / source pin | License |
| --- | --- | --- | --- |
| Ink | `inkjs` full build (engine + compiler) | npm `inkjs@2.4.0`, `dist/ink-full.js` sha256 `23d707b7…9b9e` | MIT (complete prepared set) |
| Twine | `SugarCube` story format (published page from its own `source` template) | `sugarcube-2.37.3-for-twine-2.1-local.zip`, `format.js` sha256 `64ccdac8…8820` | BSD-2-Clause top-level **plus selected jQuery et al. notices** |
| WASM-4 | upstream web runtime (`<wasm4-app>`) | npm `wasm4@2.7.1`, `assets/runtime/slim/wasm4.js` sha256 `266557b8…6c8b` | ISC top-level **plus Lit BSD-3-Clause and Press Start 2P OFL-1.1 notices** |
| TIC-80 | upstream emscripten JS player | GitHub release `v1.4.1`, `js/tic80.js` sha256 `f5f940a8…7f62`, `js/tic80js.wasm` sha256 `7ae37e4d…3cbc` | MIT top-level **plus GPL/LGPL/blip_buf/BSD/0BSD/Zlib/libpng/MIT/MiniScript2/Gravity/miniaudio/Unlicense notices + written source offer** |
| microStudio | upstream `microengine` order + microScript 2.0 compiler | GitHub `pmgl/microstudio@80594cff…a7718`; `play/player.js` sha256 `e99d44eb…120b` | MIT (complete prepared set) |

All runtime files are prepared on demand by
`Scripts/prepare_narrative.py` into an explicit resource directory; the script
pins every SHA-256, verifies after download, and `--check` re-verifies
read-only. No native binaries or proprietary assets are bundled. The starter
content emitted by `createProject` (ink story, Twine passages, WASM-4 cartridge,
TIC-80 cartridge, microScript source) is original and additionally MIT-licensed
(`licenses/FLOE-STARTER-MIT.txt`).

## Public API

```swift
GameInkAdapter.createProject(at:title:) / importProject(from:to:title:)
  / buildArtifact(projectAt:to:resources:) / buildArtifact(projectAt:to:resources:entry:)
  / entryCandidates(projectAt:)
GameTwineAdapter.…            GameWasm4Adapter.…            GameTIC80Adapter.…            GameMicroStudioAdapter.…
```

Each adapter exposes `profile: NarrativeEngineProfile` with the exact artifact
entry, runtime version, upstream identity, license, bridge capabilities and
state contract. `buildArtifact` verifies the prepared runtime bytes against the
pinned hashes and refuses to package changed resources. The built folder is a
real Web-ready tree that plugs into `GameWebArtifactPackage.build(source:…)`.

The Twine artifact is generated the way Twine publishes: the pinned
`format.js` package is read and its embedded runtime `source` template is taken.
`{{STORY_NAME}}` is substituted; `{{STORY_DATA}}` becomes a mount point and the
bootstrap script. The two upstream inline script bodies are extracted
byte-exact to `vendor/`, and an empty `script#script-sugarcube` placeholder
remains because SugarCube inserts its UI relative to it. The artifact is the
real SugarCube page, not a bare script include; the original story data lives
only in `game/story.twine.json`.

## Artifact file boundary

Every generated Web artifact is assembled by `NarrativeArtifactBuilder` and
carries a total `floe-artifact.json` manifest (path, role, license, bytes,
SHA-256). Files are never classified by filename; the explicit roles are:

| Role | Meaning |
| --- | --- |
| `html-shell` | Floe HTML shell (Twine also carries the upstream SugarCube page template). No game literals. |
| `floe-support-source` / `floe-support-style` | Readable MPL-2.0 Floe support code under `support/`. |
| `original-game-source` / `original-game-data` / `original-game-asset` / `original-game-cartridge` | User content: `story.ink`, `game/source/**`, `game/ink-sources.json`, `game/story.twine.json`, `game/microstudio-sources.json`, `game/resources.json`, official resource paths, `cart.wasm`, `cart.tic`. Never MPL. |
| `third-party-runtime` / `third-party-source` / `third-party-license` / `third-party-notice` / `third-party-source-offer` | Unchanged upstream runtime/source/notice bytes with their own licenses. |

Layout per engine:

- **Ink** — `index.html` shell; `support/floe-host.js`,
  `support/ink-bridge.js`, `support/ink.css`; `vendor/inkjs.js`;
  `game/ink-sources.json` (canonical INCLUDE map); `story.ink` (historical
  entry alias, original bytes); `game/source/<original path>` byte-exact
  sources.
- **Twine** — `index.html` published SugarCube page with
  `support/twine-bootstrap.js` mount and no story data; `game/story.twine.json`;
  `vendor/sugarcube-libraries.js` and `vendor/sugarcube-engine.js` extracted
  byte-exact from the pinned format; `vendor/sugarcube-format.js` unchanged;
  `support/twine-bridge.js`.
- **WASM-4** — `index.html` shell; `support/wasm4-bridge.js`; `wasm4.js`,
  `wasm4.css`; `cart.wasm`.
- **TIC-80** — `index.html` shell; `support/tic80-boot.js`,
  `support/tic80-bridge.js`; `tic80.js`, `tic80js.wasm`; `cart.tic`; the exact
  selected `source/tic80/` archives, sidecars, submodule pins and
  `SOURCE-OFFER.md` record (hash-verified, 8 MiB/file and 12 MiB total bounds).
  This is selected source, not a full LGPL clearance; submodule contents, exact
  emsdk and relink remain conditional and unverified.
- **microStudio** — `index.html` shell (title only); source and metadata in
  `game/microstudio-sources.json` / `game/resources.json`; original sources
  under `game/source/**`; `language.js`, `microengine.js`; official resource
  paths.

Support files are real readable package resources (not minified strings) and
are copied byte-exact. Data files are loaded with same-origin `fetch()`; a
failed fetch calls `window.FloeSupport.fail(...)`, renders an explicit error
panel and **never** reports readiness. No engine/source path can become
inline executable HTML.

## Launch and bridge contract

Artifacts use the existing `GameWebPlayer` typed bridge:

- readiness: `window.floeGameHost.ready({engine, runtime, input, state, …})`
  (the bridge source `floeGameHost.ready` is injected by `GameWebPlayer`;
  every artifact calls it exactly once when the engine is actually running)
- `window.FloeGame.input(directionOrButton, pressed)` — directions for consoles
  and story navigation; `confirm/cancel/action*/start/select` where meaningful
- `window.FloeGame.pointer(phase, x, y, button)` — normalized 0…1 coordinates
- `window.FloeGame.choose(index)` — narrative links (ink choices, Twine links)
- `window.FloeGame.snapshot()` → JSON object; `window.FloeGame.restore(state)` → bool

`GameWebRuntimePolicy` already grants each engine exactly what its real runtime
needs, so **no additional CSP directives are required**:

| Engine | WASM | JS eval | Workers | Extra MIME |
| --- | --- | --- | --- | --- |
| Ink | – | – | – | – |
| Twine | – | policy grants eval (SugarCube macro engine) | – | – |
| WASM-4 | yes (`wasm-unsafe-eval`) | – | – | `wasm` already mapped |
| TIC-80 | yes | **not required** — the v1.4.1 player contains no `eval`/`new Function` | policy grants workers for the emscripten runtime | `wasm` already mapped |
| microStudio | – | policy grants eval | – | – |

All engines load only same-artifact resources (`connect-src 'self'`,
`frame-src 'none'`, no external network). TIC-80 feeds the cartridge to the
player through `Module.arguments = ["cart.tic"]`; the upstream `emsStart`
path preloads it with `FS.createPreloadedFile`, which fetches the
same-artifact file through the host scheme handler.

### Keyboard and touch declaration

Touch controls are a virtual **keyboard**, not gamepad ABXY. Every created
project carries `floe-inputs.json` (also copied into the Web artifact):

```json
{ "schemaVersion": 1, "engine": "ink",
  "movement": { "left": [], "right": [], "up": ["up"], "down": ["down"] },
  "buttons": [{ "id": "confirm", "label": "Enter", "keys": ["enter", "space", "right"] }] }
```

Keys are fixed `GameKeyboardKey` raw values; they are never commands,
evaluators or native access. **Each `keys` array is one simultaneous chord**, so
alternate physical keys are never listed together: the defaults below bind one
key per direction/button, and empty direction arrays are left for unbound axes
(the Core resolver hides/ignores them). Additional in-game alternates that the
engine glue also accepts are documented after the table, not encoded as chords.
Defaults are the adapter/template bindings and were checked against the pinned
runtime sources:

| Engine | Verified keys |
| --- | --- |
| Ink / Twine (adapter glue) | ↑/↓ navigation, `enter` confirm |
| WASM-4 (upstream player) | arrows; `x` = button 1, `z` = button 2 |
| TIC-80 (v1.4.1 defaults) | arrows; `z`=A, `x`=B, `a`=X, `s`=Y |
| microStudio (canvas2d player) | arrows; starter declares no buttons |

Alternates handled by the engine/glue but intentionally **not** in the chord
manifest: Ink/Twine also accept Space and → for confirm (Twine additionally 1–9
quick links); WASM-4 also accepts `v`, space and period for button 1 and `c`,
comma for button 2; microStudio's own keyboard also maps `a`/`d`/`w`/`s` to
directions. Touch buttons send only the declared single key; a user may bind
extra buttons/chords in the host.

Imported project declarations are read through a bounded, `O_NOFOLLOW` reader
(256 KiB maximum, regular files only); oversize, symlinked or foreign
declarations are never used as authority. A valid project file is copied
byte-exact into the artifact, otherwise the truthful engine default is used and
`NarrativeInputs.resolutionForArtifact` reports the fallback reason. The Core
touch decoder remains the authoritative key validator.

Each artifact also exposes the optional host key hook:

```js
window.FloeGame.key({ key, code, keyCode, which, location, shiftKey, ctrlKey,
                      altKey, metaKey, repeat, pressed }) // true when handled
```

Ink and Twine install real DOM `keydown`/`keyup` listeners (hardware keyboards
work even where a host only dispatches DOM events). TIC-80 and microStudio
forward claimed keys as fixed `KeyboardEvent`s to their own SDK listeners.
WASM-4 sets the same gamepad bits its upstream player uses. Imported projects
with a valid declaration keep it; an absent or foreign declaration is replaced
by the truthful engine default rather than trusted blindly.

### State contracts (real engine state, with honest limits)

- **Ink** — `snapshot()` captures `story.state.toJson()`; `restore()` calls
  `state.LoadJson()`, which is ink's continuation state: choices are restored
  and no story logic re-executes. Variables ride inside the ink save state.
- **Twine** — `snapshot()` captures the real SugarCube save state
  (`State.marshalForSave()`, the same object save files persist). `restore()`
  calls `State.unmarshalForSave(...)` and then `Engine.show()`, which renders
  the restored passage **once without re-executing** `<<set>>`/`<<run>>`, so
  passage side effects cannot apply twice.
- **WASM-4** — `snapshot()` drives the upstream `saveGameState` path and
  serializes its `SavedGameState` (64 KiB cartridge memory, exported globals,
  persistent disk); `restore()` rebuilds that object and calls the upstream
  `loadGameState`. Starter cartridges export `px`/`py`/`frames` explicitly so
  position is captured; upstream also patches missing globals, but an
  arbitrary third-party cartridge is only guaranteed to restore state that it
  either uses in memory or exports as mutable globals.
- **TIC-80** — the upstream wasm player exposes no snapshot API, so the bridge
  reports `state: false`; restart is a host reload. In-cartridge persistence
  remains the cartridge's own behaviour.
- **microStudio** — `snapshot()` calls the game's `floe_snapshot()` microScript
  function through the upstream `Player.call` interpreter and stores its array
  result; `restore()` calls `floe_restore(...)`. Games without these functions
  report `state: false` at readiness.

### Ink multi-file INCLUDE

`buildArtifact` supports ordinary multi-file ink projects. `InkSourceGraph`
walks the bounded project tree (regular files only, no symlink following),
selects the entry deterministically — explicit `entry:`, root `story.ink`,
root `main.ink`, then a single unambiguous file — and resolves every
`INCLUDE` relative to the including file. Includes may ascend inside the
project (`../shared/x.ink`) but never above its root; absolute/drive paths,
control characters and symlinks are rejected with typed `InkArtifactError`
diagnostics (missing include, include cycle, unsafe path, symbolic link,
unreadable/oversized source, ambiguous entry).

The artifact stores the complete canonical source map in
`game/ink-sources.json`; `support/ink-bridge.js` loads it with a same-origin
`fetch()` and compiles it inside WebKit with the real `inkjs.Compiler` and a
`fileHandler` that reads only that map. Nothing is fetched from the host filesystem or network at compile time.
The source graph is **not** textually flattened: passage/choice/variable
semantics are decided by inkjs, and only `INCLUDE` path tokens are
canonicalised. Comments are masked exactly like ink's pre-processor, so a
commented-out INCLUDE is neither resolved nor rewritten. `story.ink` in the
artifact is the entry source for inspection; `game/source/` preserves every
original source path byte-exact, and the complete canonical graph lives in
`game/ink-sources.json`.

Limits: 128 files, 1 MiB per file, 4 MiB total, depth 32. Ambiguous root
projects require an explicit `entry:`; the old three-argument call keeps
working for single-root projects.

### microStudio ordinary canvas2d projects

The adapter reads the official archive/export layout: `project.json`,
`ms/` (or `src/` for Floe starters), `sprites/*.png`,
`maps/*.json`, `sounds/*.wav`, `music/*.mp3`, and `assets/*`. Nested archive
paths are flattened to microStudio's own dashed runtime names, exactly like its
importer. Sources are concatenated in official runtime-name order and, for
multi-file projects, wrapped in microScript 2.0 `function() … end()` file-local
blocks like upstream's HTML exporter (single ordinary files keep the historical
unwrapped form). `// javascript` blocks become `system.javascript("""…""")`.

The artifact carries the real `resources` object in `game/resources.json` and
the referenced files: `images` (with bounded `frames`/`fps` metadata), `assets`,
`sounds`, `music`, and `maps` as the official name→JSON dictionary. Original bytes and names are
preserved, unknown files stay in the source project and are never executed.
`project.json` is only non-authoritative metadata; it cannot grant commands,
permissions, host paths or network access. Higher-level graphics libraries
(`PIXI`, `BABYLON`, `M2D`, `M3D`), non-`microscript_v2` languages, optional
libraries and networking/server projects are rejected with typed
`MicroStudioArtifactError` diagnostics instead of being misplayed.

Limits: 128 sources (512 KiB each, 2 MiB total), 512 resources (16 MiB each,
64 MiB total), maps validated against the official width/height/block/sprites/
data shape (4 MiB each). TIC-80 still has no state contract; Ink and
microStudio keep their real state contracts above.

## Reproduce

```sh
RES="${FLOE_NARRATIVE_RESOURCES:?set FLOE_NARRATIVE_RESOURCES}"
# fresh preparation: pass the frozen local augmentation bundle (no downloads)
python3 FloeAgent/Modules/FloeGameNarrativeKit/Scripts/prepare_narrative.py --output "$RES" \
  --augmentation "${FLOE_GAME_AUGMENTATION:?set FLOE_GAME_AUGMENTATION}"
python3 FloeAgent/Modules/FloeGameNarrativeKit/Scripts/prepare_narrative.py --output "$RES" --check
# component tests + fixtures (serialized native check)
python3 "${FLOE_NATIVE_CHECK:?set FLOE_NATIVE_CHECK}" -- \
  xcrun swift test --package-path FloeAgent/Modules/FloeGameNarrativeKit \
  --scratch-path "$HOME/Library/Caches/CodexBuild/Floe/0dd039b5b74b/xcode27.2/game-narrative" --jobs 6
# runtime verification of the built artifacts (inkjs/SugarCube/WASM-4/TIC-80/microScript + bridge JS)
"$HOME/Library/Caches/CodexBuild/Floe/0dd039b5b74b/xcode27.2/game-narrative/debug/narrative-fixtures" \
  "${FLOE_NARRATIVE_FIXTURES:?set FLOE_NARRATIVE_FIXTURES}" "$RES"
node FloeAgent/Modules/FloeGameNarrativeKit/Scripts/verify_narrative.mjs \
  --fixtures "$FLOE_NARRATIVE_FIXTURES" --resources "$RES"
```

Node verification uses a dev-only `jsdom` (pinned in
`FLOE_NARRATIVE_NODE_TOOLS`;
not part of the App or any artifact).

## Licensing boundaries

- Floe-authored support source is MPL-2.0 and lives in `support/` plus the
  generated shell. The boundary notice `licenses/FLOE-COMPONENT-MPL-2.0.txt`
  lists every Floe file, every original-game file and every third-party
  runtime/notice, and states how complete Floe source is obtained
  (`FloeAgent/Modules/FloeGameNarrativeKit`). The full MPL text is always
  carried.
- `createProject` writes original Floe starter content and additionally
  MIT-licenses it (`licenses/FLOE-STARTER-MIT.txt`); project metadata marks
  only those starters (`template: floe-starter`, `starterLicense: MIT`) and
  describes engine metadata separately (`engineLicense`, engine notices).
- `importProject` preserves the imported tree byte-exact and adds only
  `project.json` (when absent) and `floe-inputs.json` (when absent). It never
  assigns the Floe starter license or an engine notice to user content.
- Artifacts always include the full actual engine notice and, for the three
  conditional engines, the selected transitive notice bundle from the prepared
  resource pack (`THIRD-PARTY-NOTICES.*`, per-library license texts, and the
  TIC-80 selected source bundle plus its as-bundled SOURCE-OFFER record). The
  build fails closed when a required bundle is missing; it never silently claims
  top-license-only completeness. The artifact does not assert a public SDK URL;
  SDK/source handoff is separate. The TIC-80 source bundle is not a full LGPL
  clearance or relink proof.
  The starter MIT notice is included only when the artifact actually carries a
  Floe-created starter project.
- Imported `LICENSE`, `LICENCE`, `NOTICE`, `COPYING`, `COPYRIGHT`,
  `UNLICENSE`, attribution/third-party notices and files under
  `licenses/`/`legal/` are copied byte-exact into
  `licenses/original/<original path>` (bounded: 32 files, 256 KiB each, 1 MiB
  total). Engine and bridge notices are never overwritten. Imported sources and
  assets keep their own terms; they are not relicensed by the module or the
  starter notice.
