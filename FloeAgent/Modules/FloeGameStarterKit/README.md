# FloeGameStarterKit

Unified **create-from-zero** starter SDK for the exact 20 engines already agreed
by Floe. It provides one deterministic catalog, one guarded initialization
service, actual original project files/data and explicit user SDK prerequisites.
It does **not** replace the existing import, AI authoring, editing, runtime,
build or App integration layers.

## What it does

- Lists exactly 20 engines with entry, source license, engine prerequisite,
  readiness, expected files and a validated default physical-key declaration.
- Seeds a template only into an explicitly created **empty, owned, current**
  project. A non-empty project, wrong owner, stale revision, changed
  environment/root, concurrent initialization or cancellation is rejected
  without touching the existing revision.
- Creates the blank project via the existing `FileGameProjectRepository` and
  imports the generated tree as one atomic repository revision.
- Writes `floe-game.json` (machine-readable starter/engine/prerequisite
  provenance) and preserves/canonicalizes `floe-inputs.json`.
- Never auto-seeds a folder/archive import and never merges template files into
  an imported tree. Import remains "whole folder/archive into an empty project".

## Public API

```swift
let catalog = try GameStarterCatalog.bundled()
let scaffolder = GameStarterScaffolder(
    repository: repository,
    contexts: host,                 // existing GameAuthoringContextHost
    catalog: catalog,
    resources: .init()              // optional prepared Phaser/KAPLAY/Babylon/PlayCanvas packs
)

// 1. Create a real empty project (engine is recorded when known).
let project = try await scaffolder.createBlankProject(
    projectID: id, owner: .space(recordID: id), title: "My game", engine: .phaser)

// 2. Resolve the exact project/root/revision context through the host.
let context = try await appHost.context(id: id, owner: .space(recordID: id))

// 3. Initialize only that empty revision.
let result = try await scaffolder.initializeStarter(
    context: context, engine: .phaser, title: "My game")
```

`result.manifestSHA256` is a stable digest over the final repository file list
(path + content hash + bytes). `result.repositoryEngine` is `nil` only when the
blank project was created before choosing an engine; `floe-game.json` still
records the selected engine for `GameProjectInspector` recognition.

## Engines

| Engine | Starter route | Source entry | Readiness | User prerequisite |
| --- | --- | --- | --- | --- |
| RPG Maker XP | Static original standard project | `Game.rxproj` | source + editor/runtime | licensed XP editor + RGSS1 |
| RPG Maker VX | Static original standard project | `Game.rvproj` | source + editor/runtime | licensed VX editor + RGSS2 |
| RPG Maker VX Ace | Static original standard project | `Game.rvproj2` | source + editor/runtime | licensed VX Ace editor + RGSS3 |
| RPG Maker MV | Existing portable template | `index.html` | source + build tool | prepared MIT CoreScript 1.3b pack |
| RPG Maker MZ | Static original standard JSON project | `Game.rmmzproject` | source + editor/runtime | licensed MZ editor/runtime; no `rmmz_*` shipped |
| Phaser | Existing `GamePhaserTemplate` | `index.html` | runtime pack required | prepared Phaser 3.90.0 pack |
| KAPLAY | Runtime-pack template | `index.html` | runtime pack required | prepared KAPLAY 3001.0.0 pack |
| Godot | Static original GDScript project | `project.godot` | source + build tool | Godot 4.7.2.stable |
| Babylon.js | Runtime-pack template | `index.html` | runtime pack required | prepared Babylon 9.35.0 pack |
| PlayCanvas | Runtime-pack template | `index.html` | runtime pack required | prepared PlayCanvas 2.24.0 pack |
| LÖVE | Existing portable template | `main.lua` | source + build tool | love.js 11.4.1 |
| Ren'Py | Existing portable template (Save/F5, Load/F9, Continue) | `game/script.rpy` | source + build tool | Ren'Py 8.5.3 SDK |
| TIC-80 | Existing narrative adapter | `cart.tic` | source + build tool | TIC-80 1.4.1 player pack |
| ink / inkjs | Existing narrative adapter | `story.ink` | source + build tool | inkjs 2.4.0 pack |
| Twine / SugarCube | Existing narrative adapter | `story.twine.json` | source + build tool | SugarCube 2.37.3 pack |
| GDevelop | Existing official-shape template | `game.json` | source + build tool | GDevelop 5.6.287 |
| Cocos Creator | Static original 3.8 project | `assets/Scenes/Main.scene` | source + editor | Cocos Creator 3.8.6 |
| microStudio | Existing narrative adapter | `src/main.ms` | source + build tool | microStudio 1.0.0 pack |
| WASM-4 | Existing narrative adapter | `cart.wasm` | source + build tool | WASM-4 2.7.1 pack |
| Unity | Static original 2022.3 project | `Assets/Scenes/Main.unity` | source + editor | Unity 2022.3.0f1 + WebGL module |

No engine/editor/build was executed by this source delivery. "source + editor"
and "source + build tool" are truthful prerequisites, not development gates.
Static starter files and user game code are MIT; engine runtimes, editors and
imported third-party assets retain their exact upstream terms.

## Original legacy RPG data

XP/VX/VX Ace use real Ruby Marshal 4.8 data (`Data/*.rxdata|rvdata|rvdata2`) with
original map tiles, events, database records, System and a compressed Scripts
archive. The Ruby source is a self-contained original RGSS starter that loads
the map, renders tiles with `Bitmap`/`Sprite`, moves with arrows, confirms with
C/Z/Enter/Space, opens the menu with B/cancel, and saves/loads with `Marshal`.
It contains no Enterbrain default scripts, RTP, DLL, font or commercial art.

The repository must still use a licensed RPG Maker editor for editing/exporting
and an RGSS-compatible host for play. This package never calls an HTML/Web mock
the same engine.

## Keyboards

Ren'Py uses the current portable-final starter bytes, including Save/F5,
Load/F9, Continue and the Root focus fix (quick buttons do not take keyboard
focus; the first choice is the default focus). F5/F9 are explicit bindings of
this original project, not universal Ren'Py defaults.

Every descriptor carries a bounded default declaration validated by the shared
`GameTouchProjectBindings` validator. RPG Maker XP uses C/Enter/Space confirm,
X/Esc cancel and Z/Shift dash; VX/Ace use Z/Enter/Space confirm, X/Esc cancel,
Shift dash and Q/W page. Ren'Py F5/F9 Save/Load are explicit bindings of the
original starter project, not a universal Ren'Py default. There is no blanket
ABXY/gamepad model; project declarations can override keys explicitly.

## Verification

- `python3 Scripts/verify_starters.py` checks the catalog, exact 20 engines,
  static file hashes, entry files, JSON/PNG signatures, Marshal parse/roundtrip
  and the absence of bundled proprietary engine files.
- `python3 Scripts/verify_prepared_packs.py --root <dir>` checks the actual
  prepared Phaser/KAPLAY/Babylon/PlayCanvas packs against the catalog hashes.
- `swift test` (Root, when native work is granted) compiles the service/tests
  and exercises guarded initialization, all embedded engines, real
  `FloeRPGCore` map/database/scripts roundtrips, license assertions and runtime
  pack prerequisite errors. Runtime-pack creation tests require
  `FLOE_STARTER_TEST_RESOURCES` pointing at the four prepared packs.

## Integration

See `INTEGRATION-RECIPE.md` in the parent directory. Root adds an optional
"Initialize starter" entry to the existing private Host/UI, keeps empty
New -> Import unchanged, and supplies the four prepared packs through the
existing `GameEnginePackStore`. This package does not edit the host or App.
