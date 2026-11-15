# FloeGameBuildKit

Usable independent exchange + build-orchestration components for AI-led game
projects. Depends on `FloeGameCore` (`../FloeGameKit`) and the reviewed
vendored ZIPFoundation copy (`../FloeDiagramKit/Vendor/ZIPFoundation`, MIT).
App integration is deliberately separate; nothing here mutates the App.

## Components

| Component | Implemented behavior |
| --- | --- |
| `GameArchiveExchange` | Real ZIP import/export over ZIPFoundation: bounds, zip-slip/absolute/backslash rejection, symlink rejection, duplicate/case/ancestor collision detection, CRC validation, staged exclusive publication (never overwrites), preserved binary bytes/empty directories/executable intent. Explicit root choice (`.asIs` / `.container(name)`); never silently picks a nested project |
| `GameArchiveOriginalStore` | Content-addressed, immutable preservation of the exact original archive bytes; bounded size, digest-only object names, staged write + read-back verification |
| `GameArchiveProjectImporter` | Product flow: create project first, then import the WHOLE archive into it (`importIntoProject`). Unknown engines, multiple nested roots and mixed content import successfully; diagnostics are advisory, never a gate. `replaceExisting` keeps the previous revision in history |
| `GameArchiveProjectPreviewer` | Post-import diagnostics: engine markers, nested root candidates, dependency hints, packaged/downloaded runtime classification, and separate limitations (EXE/DLL/encrypted assets/RTP/no play route). Never executes anything |
| `GameExternalArchiveHostPort` | Narrow typed port for tar/tar.gz/tar.bz2/tar.xz/7z/RAR using the App's existing archive services. Magic-byte format detection; the host tree is re-walked here (links/traversal/bounds) before import. No extra decoder is bundled |
| `GameProjectArchiveRoundtrip` | Qualification helper: ZIP -> repository -> edit/save -> source ZIP -> re-import, verified file-by-file (not the product flow) |
| `GameBuildCapabilityRegistry` | Resource-backed plans for all 20 agreed engines. Every engine has a concrete adapter binding (host exporter, CI compile, user-licensed editor or source archive); engine version preserved; web / native-installer / native-project / source outputs distinguished; proof level is explicit. No blanket `sourceOnlyEngine` throw |
| `GameBuildRouteCatalog` | Validated catalog (`Resources/Catalog/build-routes.v1.json`) with adapter component/entry, stages, outputs, prerequisites, proof level, distribution profile and source transports |
| `GameCIWorkflowTemplates` | Deterministic, runnable GitHub Actions templates for Unity, Godot, Cocos, GDevelop, script/web, WASM-4 and RPG Maker editor-export packaging. Explicit repository/artifact source transport, canonical-digest verification before engine code, pinned actions, provenance attestation, `actuallyDispatched == false` |
| `GameBuildSourceTransport` | Explicit repository-snapshot or prior-artifact identity (run id, artifact id, name, bytes, digest), source publisher/verifier ports, and strict provenance verification. No credential values or guessed newest run |
| `GitHubActionsBuildCIAdapter` | Concrete adapter over the host's existing GitHub Actions transport/token seams: workflow resolution, pre-dispatch baseline, dispatch, association, poll, provenance, artifact size/digest checks, cross-run source verification and cancel |
| `GameBuildCoordinator` | Real lifecycle over injected existing services: bind saved revision + manifest digest, check prerequisites, stage an export, host preflight, publish/verify the explicit source transport, dispatch, poll, reject stale digest/revision, verify provenance and artifact bytes, recheck the saved revision, seal web bundles, preserve the source archive, cancel/switch/delete. Durable per-build records with owner/environment/source root |
| `GameArtifactValidator` | Byte-level validation for web zips, APKs, Xcode projects, native projects, PE/Mach-O/ELF; a Cocos native project or Xcode project is not reported as a signed installer/IPA |
| `GameDistributionBundle` | Source-accompanying export: re-hashes every selected notice, copies readable MPL helper source, preserves user content and user notices, verifies paired corresponding-source/relink artifacts, and fails closed in distribution mode. Private playback can be produced with an explicit conditional result |
| `GameNativePackaging` | Honest standalone target/config/packaging recipes per engine; iOS is explicitly not installable from a template (requires the user's signing pipeline) |

## User sequence supported

1. Create the game project (`FileGameProjectRepository.createProject`).
2. Import the external archive/file (`importIntoProject` /
   `importExistingProjectArchive`): the target identity/revision is checked
   first, the bounded original archive is preserved to
   `GameArchiveOriginalStore`, extraction runs only from that immutable copy
   (no TOCTOU), diagnostics are advisory, and then the whole tree is CAS
   imported at the project root — every unknown file kept.
3. AI identification/organization is a later explicit action (normal commits
   with diffs/history/rollback); no silent root pruning.
4. Edit/play through the existing component routes.

Downloaded/published RPG Maker games (RPG_RT.exe/Game.ini, Data, encrypted
`.rgssad/.rgss2a/.rgss3a`, DLL/RTP) are in scope for import: bytes are
preserved and classified; EXE/DLL/Ruby are never executed.

## Bounds and safety

- Defaults: 64 MiB/file, 512 MiB/archive, 10,000 entries, 32 levels.
- Extraction never lets ZIPFoundation touch the filesystem: entry bytes are
  read in memory, validated (path shape, collisions, CRC computed by the vendor
  and compared here), written to a staged directory, then exclusively renamed.
- Archive names may be decoded with an explicit legacy encoding override
  (e.g. GBK/Shift-JIS for older Chinese/Japanese zips). UTF-8/CP437 remains the
  default; wrong selections fail closed rather than silently relabeling bytes.
- Non-ZIP containers go through `GameExternalArchiveHostPort`; the host output
  is independently re-walked here and symlinks/devices/out-of-bounds content
  are rejected before any project write.
- No executor, credential store, task system or network client exists in this
  package; build commands are data for the host's existing services.

## Known gaps (honest)

- Unity, Cocos and GDevelop CI commands are `commandOnly` unless actual build
  evidence is attached; the catalog does not turn an unexecuted command into an
  installable claim. Godot Web is the only engine with a recorded actual build
  plus runtime proof in this closure.
- Cocos `--build` produces a native project. Only `stage=make`/Gradle plus the
  APK magic check can yield an APK; both are represented separately.
- Unity iOS output is an Xcode project, never an installable IPA from these
  templates; signing belongs to the user's pipeline.
- GDevelop's actual exporter is the private host adapter / official 5.6.287 SDK
  path; the Linux CI template is documented but not executed in this closure.
- XP/VX/VX Ace/MZ native runtimes and Unity/Cocos SDKs remain user-licensed;
  Floe does not redistribute them. MZ Web is `sourceQualified` unless the
  project already carries the user's official runtime.
- The RGSS guest has no built binary in this source stage and is not claimed.
- CI templates are exported/validated only; this package never dispatches a
  workflow, pushes a repo or installs anything. Root decides any real remote
  run.
- App/File Provider grants, environment identity and job-service wiring belong
  to the App integration owner.

## Verification

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path FloeAgent/Modules/FloeGameBuildKit \
  --scratch-path ~/Library/Caches/CodexBuild/Floe/0dd039b5b74b/xcode27.2/FloeGameBuildKit/macos

# iOS object compilation (no Simulator boot)
swift build ... --sdk <iPhoneSimulator.sdk> --triple arm64-apple-ios26.0-simulator
```

The private closure also runs a pure-Python structural/semantic verifier
(`tools/verify_closure.py`): 20-engine route invariants, template parsing/pins,
nested static-export bytes, distribution notice/source hashing, and shared
source-transport vectors. Swift compilation and native acceptance remain with
Root under the active native hold.

`floe-game-build-export` prints validated templates and native packaging
recipes as deterministic JSON for the host integration.

License: MPL-2.0 (see `LICENSE`). ZIPFoundation is MIT and consumed as a
reviewed vendored path dependency (see `THIRD-PARTY-NOTICES.md`).
