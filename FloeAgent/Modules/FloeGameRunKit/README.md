# FloeGameRunKit

Unified run preparation for the Floe game IDE/Space. It implements the existing
`GameWebRunPreparationHost` contract from `FloeGameKit.FloeGameWebKit` and plugs
into `GameProjectRunController` without changing the controller or player.

Status: **source package only**. It has not been compiled, unit-tested, run in a
Simulator, or accepted on a device by this worker. Native verification belongs
to Root after the ownership transfer.

## What it does

- Plans and prepares a selected project root for all 20 `GameEngineID` values.
- Serves a ready static Web project, including a selected nested imported root,
  without mutating the original tree.
- Calls the reviewed portable/narrative/GDevelop adapters for source projects.
- Hands external build work to typed host ports; it never spawns a process,
  Node, Python, Ren'Py, Godot, Unity, a browser engine or a shell, and has no
  generic evaluator/exec alias.
- Builds from private copies for LÖVE/Ren'Py and external builds, preserving the
  imported tree, including existing Ren'Py `.rpyc` companions.
- Rechecks the host context before and after preparation and cleans only its own
  staging directory.
- Keeps the original `GameProjectContext` (project ID, owner, revision,
  environment, root) in the prepared artifact even when a nested content root is
  served.

## Public entry points

- `GameUnifiedRunPreparer` — actor implementing `GameWebRunPreparationHost`.
- `GameRunPreparationConfiguration` — immutable host wiring.
- `GameRunSelection` — selected root/entry for one saved revision.
- `GameRunRoutePlan` — readiness, route identity, entry and prerequisites.
- `GameRunRuntimePack` / `GameRunRuntimePackProviding` — verified data-only
  runtime packs (for example KAPLAY/Babylon/PlayCanvas or a host Phaser pack).
- `GameRunExternalBuildProviding` — typed jobs/CI seam for Unity/Cocos/Godot/
  GDevelop/MZ and npm bundles. It defines no remote dispatch permission.
- `GameRunStaticRuntimePackProvider`, `GameEngineResourcePackProvider` — host
  adapters for prepared packs.

## Engine routing

| Engine | Route |
| --- | --- |
| RPG Maker XP/VX/VX Ace | Explicit guest/RGSS runtime requirement; no fake Web engine. |
| RPG Maker MV | Ready Web export, project-core assembly, or prepared CoreScript template assembly. |
| RPG Maker MZ | Ready MZ Web export, otherwise licensed MZ runtime/deployment requirement. |
| Phaser/KAPLAY/Babylon/PlayCanvas | Ready static Web, verified runtime-pack assembly, or typed web-bundle build. |
| LÖVE | Ready love.js Web or the prepared love.js build through the host portable build port. |
| Ren'Py | Ready Web build (`game.zip` or `game.data`), or the official pinned 8.5.3 `web_build` for a compatible project with scripts or standard RPA archives. |
| TyranoScript | Import a complete browser export with its own runtime and game assets. Playback uses the game's own touch controls and saves. |
| ink/Twine/WASM-4/TIC-80/microStudio | Reviewed narrative adapters with prepared runtime resources. |
| GDevelop | Verified GDJS export, otherwise the official SDK export through the host external build port. |
| Godot | Ready Web export, otherwise the pinned Godot Web export through the host external build port. |
| Unity | Ready WebGL export, otherwise the CI/Editor WebGL export through the host external build port. |
| Cocos Creator | Ready Web build, otherwise the CI/Editor Web export through the host external build port. |

Imported `.exe`/CAB/DLL and unknown files are never executed. Unknown files are
retained in static/runtime-pack copies and in the original repository.

## Resources

The package does not ship engine binaries. The host injects reviewed data:

- `FLOE_GAME_RUN_NARRATIVE_RESOURCES` — prepared inkjs/SugarCube/WASM-4/TIC-80/
  microStudio resource root.
- `FLOE_GAME_RUN_PORTABLE_RESOURCES` — prepared love.js and MV CoreScript roots
  with their manifest files.
- `FLOE_GAME_RUN_STARTER_PACKS` — reviewed KAPLAY/Babylon/PlayCanvas/Phaser
  starter resource directories.
- A pinned Ren'Py 8.5.3 Web SDK path plus the host portable build port.
- A host external build provider adapted to the existing jobs/CI service.

Missing resources produce an explicit `missingPrerequisite` error, not a
developer-account gate and not a fake success.

## Tests

`Tests/FloeGameRunKitTests/GameRunPreparerTests.swift` is self-contained and uses
the actual `FileGameProjectRepository` create → import → export → prepare flow.
It covers nested static Web, provenance, symlink/traversal rejection, all 20
route plans, export layouts, missing prerequisites, runtime-pack assembly,
external output verification, revision switch, cancellation, Ren'Py `.rpyc`
propagation to the official build port, and LÖVE source prerequisites.

`GameRunResourceBackedTests.swift` is opt-in and clearly skipped (XCTSkip with
the env name) when the real prepared packs are absent. It covers real Ink,
Twine, microStudio, MV CoreScript assembly and KAPLAY pack assembly.

Static Python checks in `../tools/` are not native evidence.

## License

MPL-2.0 for this package's self-authored source. Third-party runtimes, notices
and original game content retain their own terms; the adapters and prepared
packs carry their own license files.
