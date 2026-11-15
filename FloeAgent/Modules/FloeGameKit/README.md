# FloeGameKit

Usable independent components for AI-led game projects, with an actual offline
Phaser/WebKit workflow. Production App wiring is still separate; the selected
third Space overview layout is unchanged.

## Working components

| Component | Implemented behavior |
| --- | --- |
| `GameProjectInspector` | Read-only root inspection; 11 engine/version candidates; bounded metadata; no recursive choice of the first nested project |
| `FileGameProjectRepository` | Folder import, file/JSON editing, atomic revision commits, real cross-instance CAS, reopen, history, restoration, independent copies and folder export |
| `GameJSONPatch` | Replace an existing JSON object/array value while retaining unrelated and unknown values |
| `GameWebArtifactPackage` | Copy an actual Web-ready source tree, verify all bytes and licenses, produce a content manifest hash, detect resource tampering |
| `GamePhaserTemplate` | Real offline Phaser 3.90.0 starter using pinned prepared JS resources and original procedural artwork |
| `GameWebPlayer` | Real WebKit loading, typed game input, bounded logs/state, PNG screenshots, restart and confirmed stop |
| `GamePlayerView` | SwiftUI wrapper for UIKit/AppKit; service ownership stays outside View lifetime |
| `FileGameSaveRepository` | Durable progress with CAS; separate from source history and isolated by actual project/owner |

The repository retains empty directories, binary bytes and executable intent.
Immutable content objects deduplicate files; one HEAD identifies the authoritative
original. A repository-wide flock covers the CAS and publication boundary.
Failed batches clean only their new staged objects/revisions; a committed HEAD
is never rolled back by a late cancellation. Previous source and history remain
recoverable. Corrupt objects/history and symlink imports are rejected.

Default bounds: 64 MiB per file, 512 MiB per project, 10,000 file/directory
entries and 32 directory levels. File operations honor cancellation; exports
publish a fresh directory without overwriting an existing destination. iOS/File
Provider grants and source coordination remain host responsibilities.

## Actual engine scope

`GameEngineID` retains all 20 agreed engine/version identifiers. This is not an
availability list. Candidate detection currently covers RPG Maker XP, VX,
VX Ace, MV, MZ; Godot; Unity; and Phaser, KAPLAY, Babylon.js, PlayCanvas npm
projects. Marker files/dependency declarations are hints, not complete-format
validation or resolved engine versions.

**Phaser is the first actual template/runtime adapter in this component.**
Other engine runtimes, RGSS binary editing, full native map/event adapters,
ZIP intake, transpiling/bundling and Unity CI builds remain integration work.
The generic repository can preserve their raw files; that is distinct from
semantic editing or playing them. All registries start empty; only the host
registers genuinely available adapters. Native Unity-as-a-Library registration
is rejected because the selected Unity route is CI to Web playtesting.

## Integration contract

- Resolve grants, project identity, original root, saved revision and the
  existing environment ID through the current Space/workspace services.
  Imported metadata never grants access or chooses an owner.
- Save first, hold the original-file lifecycle lease, inspect a
  `GameProjectContext`, then recheck the authoritative revision. The
  read-only `inspect(rootURL:)` import probe cannot authorize launch planning.
- Bind artifacts to the same project, owner, root, environment and revision.
  Revalidate after asynchronous preparation and before each side effect.
  `inspectedPaths` covers metadata only, never a complete source revision.
- `GamePreparedArtifact` by itself checks metadata structure, not bytes.
  `GameWebArtifactPackage` supplies real byte verification for a Web-ready
  folder. CI-produced binaries need the existing host provenance/signature path.
- Reuse the current task, execution and download services. Model-authored build
  commands still use resolved Linux `exec.shell`/jobs. There is no new scheduler,
  general evaluator, AI tool alias or permissions system in this package.
- Space and ordinary conversations remain independent copies. Production hosts
  must adopt/adapt one authoritative store rather than keep two synchronized
  editable originals. Opening an IDE must not replace an unrelated global
  workspace or mistake an assistant execution folder for the Space original.

Relevant existing paths: [Space editor](../../FloeApp/Space/PersonalContentEditor.swift),
[assistant authority](../../FloeApp/Space/StudioDocumentAccess.swift),
[IDE entry](../../FloeApp/Workspace/WorkspaceIDEView.swift),
[run controller](../../FloeApp/Workspace/IDEWorkbenchState.swift),
[workspace binding](../../FloeApp/Workspace/WorkspaceCenter.swift).

For WebKit, the artifact scheme serves only indexed, hash-verified resources.
HTML receives a restrictive CSP before project content; external network,
frames, workers, forms and objects are blocked. The only native messages are
readiness and bounded logs. Typed input/state operations are available only
when a game actually implements the adapter contract. Game progress contains
no native grants and is not placed in Web storage or source exports.
`stop()` fences callbacks, drains owned reads and waits for blank-document
navigation; its Boolean result explicitly reports whether stop was confirmed.
A View disappearing does not silently delete a game service or source.

## Reproduce lightweight qualification

Run from the repository root with explicit internal-SSD scratch and fresh
evidence paths. Preparing JS resources is a development helper; App integration
will use the existing resource service. After preparation this workflow is
offline. `--check` is read-only and never downloads or rewrites a manifest.

```sh
GAME_CHECKOUT_ID="$(python3 -c 'import hashlib,pathlib; print(hashlib.sha256(str(pathlib.Path.cwd().resolve()).encode()).hexdigest()[:12])')"
GAME_CACHE="$HOME/Library/Caches/CodexBuild/Floe/$GAME_CHECKOUT_ID/xcode27.2/game-usable"
GAME_RESOURCES="${FLOE_GAME_RESOURCES:?set FLOE_GAME_RESOURCES to the reviewed Phaser pack}"
python3 FloeAgent/Modules/FloeGameKit/Scripts/prepare_phaser.py --output "$GAME_RESOURCES"
python3 FloeAgent/Modules/FloeGameKit/Scripts/prepare_phaser.py --output "$GAME_RESOURCES" --check
python3 FloeAgent/Modules/FloeGameKit/Scripts/qualify.py --cache-root "$GAME_CACHE" --resources "$GAME_RESOURCES" --evidence-root "${FLOE_GAME_EVIDENCE:?set FLOE_GAME_EVIDENCE}"
```

The qualifier runs component tests, 11 synthetic detector examples and real
arm64 iOS 26+ object compilation. It retains exact source hashes, original logs,
compiled objects, development executables, a real game snapshot, screenshots
and the exported playable project. No Simulator is created or booted.

The real engine assertions run in a small AppKit executable with `NSApp.run()`.
An in-process command-line XCTest WebKit document remained hidden and correctly
paused Phaser at frame zero. Those original failures are retained. The native
host runs the same movement, score, progress, CSP and stop/restart assertions
with a real visible document; it closes its own window and restores focus if
it still owns it. This is macOS WebKit evidence, not an iPad runtime claim.

See [current component qualification](../../../docs/qualification/FLOE_GAME_COMPONENTS_20261111.json)
and the [historical initial-core record](../../../docs/qualification/FLOE_GAME_CORE_20261111.json).

## License and prepared resources

Native component code is [MPL-2.0](LICENSE). Newly authored embedded starter-game
files are additionally MIT-licensed and include `licenses/FLOE-STARTER-MIT.txt`;
exporting the starter does not require relicensing an entire user's game MPL.
The Phaser Arcade distribution is pinned to upstream commit
`a9965625f49cf366584f454556b039e06e8adad6`, with exact Git blob and SHA-256 checks.
It is prepared on demand rather than embedded as a native engine SDK.

Generated projects retain Phaser's MIT notice, the EventEmitter3 5.0.1 MIT
notice and all 29 distinct original copyright/license comment blocks from the
verified unminified Arcade distribution, including its bundled notices.
No official RPG Maker RTP, stock assets, Spine runtime or native engine binary
is included. This component qualification is separate from the final per-engine
license assessment and Apple review; it adds no downloaded native code or
private WebKit API.

Primary references:
[Phaser source/license](https://github.com/phaserjs/phaser/tree/a9965625f49cf366584f454556b039e06e8adad6),
[EventEmitter license](https://github.com/primus/eventemitter3/blob/5.0.1/LICENSE),
[Godot roots](https://docs.godotengine.org/en/stable/tutorials/io/data_paths.html),
[Unity directories](https://docs.unity.com/en-us/engine/6000.7/manual/get-started/project-configuration/default-directories),
[legacy RPG data source](https://github.com/RPG-Maker-Translation-Tools/rvpacker-txt-rs-lib/blob/1feec3d6579b9770944379245600e99d446a4eaf/src/json.rs).
