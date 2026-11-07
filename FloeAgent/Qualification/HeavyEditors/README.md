# Heavy editor native qualification

Independent qualification for `FloeGISKit`, `FloeScoreKit` and `FloeFontKit`,
using the shared `FloeHeavyEditorSupport` bridge. Floe-authored files remain
MPL-2.0; bundled dependency sources retain their own licenses and notices.

## Run locally

From the repository root, with the installed Xcode selected per command:

```sh
node FloeAgent/Qualification/HeavyEditors/WebBuild/build.mjs
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  bash FloeAgent/Qualification/HeavyEditors/script/build_and_run.sh --verify
```

The launcher uses this round's shared native-build wrapper, two compiler jobs,
the internal SSD build cache, and a task-owned workspace under `Local/Private`.
It exports the macOS app under `Local/Artifacts` before running it. The separate
`--sim-build` mode compiles the arm64 iPad/iPhone target using a generic destination;
it does not start, create or reset a Simulator. Use `--run-only` to reuse an
unchanged exported app. The project is generated from `project.yml`.

For the automated native bridge smoke, launch the exported macOS app with
`--workspace <explicit qualification directory> --smoke-plans <repository>/FloeAgent/Modules`.
The host opens all three editors, executes the checked-in domain smoke plans
through `HeavyEditorModelCalls`, commits and reopens documents through new
controllers, rejects stale mutations, rejects score playback through a read-only
query, and verifies managed export receipts against actual files and signatures.
`SmokeResult.json`, native SwiftUI window captures and separate WK canvas
snapshots are written only to that workspace. The public domain EditorViews
mount the actual native lists, toolbars, inspectors, forms and transport controls;
see [Native editor presentation](NATIVE_UI_CONTRACT.md).
Use `--smoke-kind gis|score|font` to rerun only an affected editor.
Domain semantic tests and engine/native compiler tests remain in each module;
this smoke does not duplicate them or establish production App acceptance.

## Entrypoints and ownership

The host demonstrates GIS from Space / Note attachments / Task results,
Music editor → Score and Settings → Font manager → Font editing. Score and
font are not independent Space create cards. Closing an editor restores its
parent route. Recent documents and managed exports use an isolated index. The
reduced host uses an explicit `qualification` owner. Its
callbacks must never be copied as production authorization. Mainline composes
these features inside existing App navigation and existing project, Notes,
task, file, permission and conversation services, the existing music project
session and DeviceFontStore. Production score/font controllers bind the actual
`music` / `fontLibrary` owner; the model cannot choose this identity. Original documents and
editor undo/selection remain separate from chat/assistant state.

`Integration/FloeHeavyEditorsHostAdapter` compiles against the actual FloeTools
and FloeCore packages. It registers 18 tools: each of `gis`, `score`, `font`
has `create`, `describe`, `query`, `invoke`, `import`, `export`. Mainline supplies
context-bound grants, an editor lease, idempotent project creation and opaque
file-ID resolution. It also supplies the actual controller's owner checks,
save callback and committed/read-back export receipts. Tool arguments cannot
choose a path, owner, environment or permission callback. Temporary/read-only
contexts and effective catalog restrictions remain enforced; command schemas
come from the actual bundled editor registry.

Score accepts an optional `ScorePlaybackAdapter`. Mainline owns the existing
music instruments, audio authority, routing and cleanup. The independent
reference playback service is available for qualification; the score module
does not edit the existing DAW or copy sound banks.

## Offline bundle and notices

`WebBuild/package-lock.json` pins the browser toolchain and dependencies.
`build.mjs` uses only the task's installed toolchain cache, bundles resources
locally, and emits actual input inventories and original notices. The App
does not need npm, a remote CDN or a Python interpreter for these editors.
The font native compiler is a separately pinned Rust static library for macOS
arm64, iOS arm64 and iOS Simulator arm64. Its source, lock, build script and
dependency terms remain with `FloeFontKit`.

Read each module's `README.md`, `THIRD_PARTY.md` and `Integration/README.md`
for format variants, behavioral coverage and remaining acceptance boundaries.
Physical iPad performance, touch/Pencil, production App composition and
distribution are independent from this native qualification host.
