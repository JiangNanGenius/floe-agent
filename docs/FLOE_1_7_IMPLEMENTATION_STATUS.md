# Floe 1.7 implementation status

Accepted scope: integrate environments, package management, Node, media processing,
33 model evaluations covering 15 capabilities, and a lightweight workspace media
workbench. Prepare a TestFlight-ready build; do not publish a production release.
Environments provide dependency/data layering, not process security isolation.

Branch: `codex/floe-1-7-integration-20260912`.

## Checkpoints

- `fb3480f`: original new-module source checkpoint (not build-qualified).
- `d0b6454`: previous shell branch integration, including pending native runtime fixes.
- Fourteen local qualification tests pass: six environment ownership/durability,
  four package integrity/scoped hold, three real media export, and one job migration test.
  Reproduction: `swift test --package-path FloeAgent/Qualification --scratch-path FloeAgent/.build --force-resolved-versions --jobs 2` with Xcode 27 beta.
  Evidence: `docs/evidence/floe-1.7/platform-qualification.txt`.
- Real h264 transcode verifies resized output, requested frame rate and valid sample count.
  Audio conversion verifies 48 kHz stereo to 16 kHz mono and non-silent samples.
  Rejected/cancelled exports retain existing files. These are macOS host tests,
  not long-file, background, iOS device, memory or all-codec acceptance.
- Four prior native shell reproductions now pass in a minimal iOS Simulator App:
  scoped environment, no inheritance leak, stdin/output bound and exit 7,
  compound loop piped to `tr`. Evidence: `docs/evidence/floe-1.7/native-shell-smoke.json`.
- Native worker lifetime tracking prevents lifecycle success while a timed-out worker
  still runs. Native bridge builds; destructive lifecycle integration still needs testing.
- Background jobs persist environment IDs using schema migration 40. Package indexes
  and durable hold states are scoped to environments. Empty trust keys fail closed;
  independent GnuPG signatures and tampering are tested.
- Unconnected frame enhancements now fail instead of returning deferred success;
  injected frame processors are routed through the tool registry.

- `aea3fb6`: first environment/media integration checkpoint, pushed. CI run
  `34695828782`: Linux passed; both App jobs stopped at stale generated Xcode project.
  The next checkpoint regenerates the project and adds the pinned Node framework.
- Native Node host: eight iOS Simulator cases pass, plus three host suites including
  the pinned npm/pnpm/yarn entry points. See `FLOE_1_7_NODE_RUNTIME.md` and evidence.
  Check mode also preserved lock bytes and modification time.

- `8173639`: pinned Node and generated project checkpoint. CI `34696909375`
  passed all three Node host tests, then failed because the workflow invoked a
  non-executable pin script directly. The next change invokes it through Bash.
  The release-SDK job also found an unavailable super-resolution probe type;
  the unused probe is removed while that runner remains unavailable.
- Current local package work passes 26 qualification tests: six environment,
  sixteen package (integrity/hold, transaction recovery, dependency resolution,
  publisher-to-client installs), three media and one persistence test. This is
  checkpoint evidence, not acceptance of a release build. See
  `docs/evidence/floe-1.7/package-qualification.txt`.
  The end-to-end fixture exposed and fixed a missing Debian ar archive header
  in the repository publisher. Production source provisioning remains open.

- `3d3aa55`: transactional package checkpoint; `0d47ac4`: cloud-signed
  floe-video 1.0.1 artifacts, pulled and verified locally with `build.py --check`.
  The Skill now advertises only verified conversion paths. Signing is a branch
  artifact update, not an App release or model inference qualification.

- Model catalog wiring now uses `catalog.sig` and filters pending assets from
  installable results. Resource installs reject unsafe paths, size mismatches and
  corrupt registries. Capability output distinguishes installed from runnable.
  Thirty focused tests pass, including three model-resource tests and verification
  of every package in the signed v2 Skill catalog. These are resource-management
  tests, not model inference or per-environment model-lifecycle acceptance.

- Basic edit rendering now applies trim, synchronized speed, volume and audio
  fades, then routes export settings through the verified transcode path. Unsupported
  operations fail before processing. Workspace video preview connects to a lightweight
  editor with persisted parameters and output playback; App/UI/device acceptance,
  shared jobs and chat attachment handoff remain open. Thirty-three focused tests
  pass, including edited-file parameters and synchronized audio/video duration.
  Evidence: `docs/evidence/floe-1.7/media-edit-qualification.txt`.

- The 33 model records now reference fixed commits and license evidence from
  31 upstream repositories. AMT/E2FGVI are excluded from this distribution scope
  because of non-commercial terms without additional permission; GPEN is excluded
  pending a verifiable distribution grant. Missing conversion scripts are no longer
  recorded as completed provenance. Full weight, conversion and device qualification
  remains open; see the per-model matrix.

- The minimal NativeMedia iOS Simulator App builds the production editor/player.
  Its editor-model smoke passes save/reopen, trim/speed, dimensions, frame rate,
  playable output and source preservation. Evidence:
  `docs/evidence/floe-1.7/native-media-editor-model.json`; startup screenshot:
  `docs/evidence/floe-1.7/native-media-workbench.png`. Automated tap/gesture
  testing was unavailable through the current computer-control surface; no complete
  workspace-navigation or device acceptance is claimed.

## Documentation

See [build and acceptance](FLOE_1_7_BUILD_AND_ACCEPTANCE.md),
[migration/recovery](FLOE_1_7_MIGRATION.md), [compatibility](FLOE_1_7_COMPATIBILITY.md)
and [documentation audit](FLOE_1_7_DOCUMENTATION_AUDIT.md).

## Remaining acceptance gates

- Complete App build and native shell runtime tests; previous minimal App reproduced
  pipe/environment defects are closed by the four-case smoke above; multi-stage pipelines,
  interactive cancellation and complete runtime scenarios remain open.
- Durable background job context, Python/WASM installer routing, scoped native worker
  shutdown, environment migrations/templates/promotion/quota durability.
- Node full-App linkage, interactive shell input forwarding, cross-runtime cwd,
  package installation compatibility and physical-device profiling.
- Production signed apt source provisioning, full transactional interruption/rollback
  acceptance and compatible package pool; signed publisher/client fixtures pass.
- Real media export/enhancement, model resources/runners, and per-capability device evidence.
- Lightweight workbench, file/attachment navigation, persistent edits and shared jobs.
- Full legacy regression, immutable CI/SDK/device checks and distribution build.

No release, model readiness, native runtime acceptance or complete-plan success is
implied by these checkpoints. Source presence and successful downloads are not
execution evidence.
