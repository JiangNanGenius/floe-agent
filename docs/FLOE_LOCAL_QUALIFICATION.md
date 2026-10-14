# Floe local qualification and supplementary CI

This guide separates **what was actually run** from what a compressed status
line might imply. Local Xcode 27 compilation, focused tests, Simulator
verification, archiving and available signing/upload are the primary release
qualification path for Floe. CI is a short complementary lane: it adds
independent read-only checks on every push/PR and never blocks local
qualification as a waiting gate. A green CI run is not App, UI, device or
Apple evidence.

This page covers tooling, not a specific build. It does **not** claim that the
current work-in-progress App, UI flows or real-model paths passed; integrated
App acceptance is a separate, explicitly recorded step.

## 1. Qualification states

Keep these states separate in every report:

| State | What it proves | What it does not prove |
| --- | --- | --- |
| Source pinned | A checkout maps to one immutable source SHA/tag | Anything about compilation or behavior |
| Compiled | The compiler accepted a target or the App (Swift 6 concurrency needs object/SIL or full App compilation, not typecheck alone) | That tests ran or the UI works |
| Module tests executed | The listed test cases ran on that source and toolchain, with retained results | Full-App behavior, Simulator UI, device behavior |
| App built | A Simulator/device product was produced for the exact source | UI interaction, signing, Apple processing |
| Simulator UI | The named iPad/iPhone flows were exercised on a booted Simulator | Physical-device quality, real user configuration |
| Packaged artifact | An IPA/archive exists with recorded hash, bundle ID, version/build, toolchain and source SHA | Upload, Apple processing, installability |
| Apple `VALID` / group | The exact build is unexpired and available to the intended beta group, read back independently | That a specific tester installed it |
| Physical device | The user accepted the flows on a real device | Anything not exercised there |

A locally built product is not proof of tests; a test log is not proof of UI;
an upload is not proof of Apple processing; an Apple-valid build is not proof
of a user installation.

## 2. Local preflight commands

Run from the repository root. The first five mirror the CI lean lane; the
Office host pin is an additional read-only preflight for packaging. All six are
safe to run before any heavier local work:

```bash
cd FloeAgent
python3 scripts/check_engineering_viewer_assets.py
scripts/pin_check.sh
python3 scripts/validate_localization_catalog.py FloeApp/Resources/Localizable.xcstrings
python3 scripts/audit_native_runtime_free.py --project
scripts/license_inventory.sh --check
python3 scripts/pin_office_host_artifact.py --check
```

Notes:

- `--check` is read-only. Never run the generator first to make a check pass;
  a stale tracked manifest is a failure, not something to silently heal.
- `license_inventory.sh --check` reads the real `.build/checkouts` when
  present. A checkout whose revision does not match the committed pin fails
  closed on purpose. In a fresh clone (no `.build`) it reuses the recorded,
  revision-bound evidence and passes without resolving or downloading.
- The same check declares the app-graph-only native CAD packages from
  `ThirdParty/FloeCADKit/Package.resolved` (the single pin authority:
  Euclid, ShapeScript, LRUCache, SVGPath) and re-verifies the bundled
  native-OCCT source/relink record against
  `ThirdParty/FloeCADKit/DEPENDENCIES.json`. A moved lock revision, an edited
  reviewed copy under `FloeApp/Resources/Licenses`, a stale lock/manifest pair
  or a checkout whose HEAD differs from the declared revision fails closed.
  ShapeScript's HelpBuilder-only dependencies (swift-markdown, swift-cmark)
  are resolved but not linked and are deliberately not declared as shipped
  components.
- `FLOE_LICENSE_CHECKOUTS=<dir>` points a read-only qualification run at an
  explicit checkout root (for example another build's
  `SourcePackages/checkouts`); an empty directory reproduces the clean-clone
  contract. The default (unset) stays the real `.build/checkouts`, and the
  summary line separates verified checkouts (`N verified checkouts`, `N
  verified FloeCAD checkouts`) from reused evidence, so an empty override is
  never App-graph proof.
- Use the installed Xcode via `DEVELOPER_DIR` per command instead of changing
  the global `xcode-select`; check free space on the actual output volume.

## 3. Local compiled/test evidence

- Module and qualification tests run on that module, with the scratch path and
  job count recorded (start heavy compilation at six jobs, adjust from
  measured pressure).
- Keep each SwiftPM scratch directory sequential; do not run two `swift`
  commands sharing one scratch at once.
- After Simulator tests, debugging or screenshots, shut down Simulators that
  this task started; preserve device data and any simulator still owned by
  another task.

## 4. Supplementary CI scope

CI (`.github/workflows/ci.yml`) now has two distinct shapes:

| Trigger | Lanes |
| --- | --- |
| `push` to `main`, `pull_request` | `lean-checks` only |
| Manual dispatch, no selector | `lean-checks` only |
| Manual dispatch, `full: true` | complete matrix: `build-test`, `appstore-sdk-compatibility`, `spm-linux-build` |
| Manual dispatch, one special mode | that mode only |

The default `lean-checks` lane (ubuntu-latest, Python 3.13) runs only
read-only, independent-value checks:

- bundled engineering-viewer hashes, closed network policy and notices;
- committed SwiftPM pins without resolving dependencies;
- third-party license inventory in `--check` mode;
- localization catalog completeness;
- native Python/Node retirement audit on the project manifests;
- strict diagnostic/result-verifier contract tests (test-runner recovery,
  Simulator selector, App/Notes/IDE result verifiers, retry classification,
  deadline-suite coverage, release version/copy checks);
- the full-history secret scan with a pinned, SHA-256 verified gitleaks.

The lean lane does **not** compile the App, bootstrap native components,
download fonts, resolve SwiftPM/Xcode packages, boot a Simulator, archive or
restore build caches. The heavy `full` matrix keeps every original step and
strict verifier only as an explicit manual opt-in. It is supplementary; local
Xcode 27 qualification remains the primary release path and the full matrix is
never a release waiting gate.

### Running the full manual matrix

```bash
gh workflow run ci.yml -f full=true
# narrow reruns keep their historical semantics:
gh workflow run ci.yml -f build_test_only=true
gh workflow run ci.yml -f ide_only=true
```

At most one top-level mode may be dispatched. A new `validate-selectors` job
runs first for every manual dispatch and rejects ambiguous combinations (for
example `full` with `ide_only`, two special modes at once, or a `palette_*`
modifier without `feedback_ui`) before the paid demo, the write-capable
Skill Hub publish or any heavy lane can start. Push/PR and selector-free
dispatches never touch those lanes.

If a release step chooses to reuse CI artifacts for the exact source SHA, it
needs a successful explicit `full` run for that SHA; otherwise the release
workflow falls back to its local compile/test path, which is the primary path.

## 5. What CI still cannot prove

- The lean lane does not compile source, so it cannot catch compile or
  concurrency errors; local object/App compilation does.
- It does not run Simulator or device UI flows.
- It does not validate signing, Apple processing, TestFlight group membership
  or installability.
- A lean failure is a real failure of the selected contract; a lean pass must
  not be reported as "the App passed".

When in doubt, report the exact state: source SHA, toolchain, command, target,
actual result, retained evidence and limitations.
