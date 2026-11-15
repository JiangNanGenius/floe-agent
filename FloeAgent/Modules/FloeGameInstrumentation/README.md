# FloeGameInstrumentation

Source-only package that installs the two missing **project-side** development
hooks for the Floe game workspace:

- **Unity WebGL**: the three reviewed `FloeGameDeveloperKit` files
  (`FloeDeveloper.jslib`, `FloeDeveloperBridge.cs`,
  `FloeDeveloperBridgeBehaviour.cs`) under a selected Unity root.
- **Godot 4 Web**: the reviewed `floe_developer.gd` autoload plus the
  `FloeDeveloper="*res://floe_developer.gd"` entry in `project.godot`.

It composes the existing frozen SDK instead of copying it:

- `FloeGameCore` repository, immutable revisions, CAS, digest and context
- `FloeGameAuthoring` context handoff
- `FloeGameDeveloperCore` 20-engine catalog and exact descriptors

The package does not run, build, sign, export or install an engine; it does not
create a second project, menu, evaluator, bridge or revision store. The App,
Root UI, build service, Git, environments and player remain owned by their
existing services.

## Source-only status

Main's native/Simulator/engine execution HOLD was active when this package was
produced. **No Swift compiler, XCTest, Simulator, device, VM, Unity or Godot was
run.** The executable checks are the static Python checks in
`../checks/verify_instrumentation_source.py`; they verify structure, API
symbols, exact template bytes/pins, catalog classification, helper defaults,
and test-source coverage. The Swift regression suite is included and ready for
the coordinator's serialized native window.

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --package-path "FloeAgent/Modules/FloeGameInstrumentation" \
  --scratch-path "$HOME/Library/Caches/CodexBuild/FloeAgent/game-instrumentation-20261114" \
  --jobs 4
```

## Products

- `FloeGameInstrumentation`:
  `GameDeveloperProjectInstrumenter`, preview/apply plans, exact
  repository CAS, source/notice bundle and build-provenance record.

## Bounded behavior

- Only `.unity` and `.godot` are installable here. All other engines keep their
  existing host hook, bridge, snapshot route or guest route; `audit()` returns
  the exact remaining gap and never claims universal cheat support.
- Plan fails closed on a stale context/root/owner/revision, a wrong engine
  marker, an unsupported Unity/Godot version, a target-byte collision, a
  duplicate Unity helper declaration, a conflicting Godot autoload, or a
  template that fails the production-dormancy gate.
- Exact already-installed bytes are idempotent and create no revision.
- Apply writes only the listed files through the existing
  `FileGameProjectRepository.commit`; unknown files, nested projects, native
  binaries, empty directories and administrative files remain in the revision.
- The helper is inert without the Floe host's `window.FloeDeveloper` object;
  there is no HUD, menu, reflection or arbitrary evaluator.
- The Unity duplicate-definition scan is bounded (default 500 `.cs`/`.jslib`
  files and 8 MiB, metadata files up to 1 MiB). A larger source tree fails
  closed; the host may raise `GameDeveloperInstrumentationLimits` up to the
  reviewed caps.
- Arbitrary gold/HP/variables are **not** claimed. The reviewed defaults are
  scene/frame/time-scale/pause for Unity and scene/pause/time-scale/frames for
  Godot; project-specific values need explicit typed registration in a project
  revision.

## Frozen pins

The four helper templates and the MPL license are byte-pinned in
`Resources/TEMPLATE-PINS.json` against the frozen `FloeGameDeveloperKit`
catalog version `1.0.0` / source revision
`3763b5ce836c0fb7b980b02a2becaa5c6234100f`. Integrating against a different SDK
revision requires reviewing the copies and deliberately updating the pins and
the template-identity regression; do not silently point the package at a newer
SDK.

## License

MPL-2.0. See `LICENSE` and the source notice in
`Sources/FloeGameInstrumentation/Resources/NOTICE.md`.
