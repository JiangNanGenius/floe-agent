# Floe 1.7 implementation status

Build 225 delivery: TinyEMU Runtime v2 is integrated on `main`. The verified base image is content-addressed and shared; environments own CoW system deltas and durable data while VM directories are disposable; a four-VM pool, one-writer leases and the 1.5–2 GiB memory budget coordinate with the MLX local model through one heavy-runtime arbiter. Build 225 keeps the Build 224 slice — Build 223 startup/migration repairs (fresh-registry open regression, idempotent legacy image/environment migration, accurate post-migration install state, repairRequired fail-closed at the migrator and integrator seams, recovery rebuilding of lost expanded views), resident local-model retention across retained-task idle gaps, the PPT/PPTX edit-entry first render (host re-pinned by CI run 35747909238), GitHub-primary/Gitee-sharded Linux image fallback with verified resume and the one-way GitHub→Gitee `gitee-mirror` workflow — and adds the compile repair that Build 224 needed: an exhaustive typed-throws catch in the App's `LinuxGuestImageDownloader` (`session.bytes` non-`URLError` failures fail closed as `.responseInvalid`; `URLError.cancelled` is `.cancelled` only under actual task cancellation). Build 224's accepted-SDK App build failed on exactly that line (Xcode 26.6; immutable tag `v1.7.0-beta.81`, run [35767875337](https://github.com/JiangNanGenius/floe-agent/actions/runs/35767875337), retained). Local evidence: `RuntimeV2StartupTests` (16 tests), `FloeLocalModels`/heavy-runtime arbiter suites, Gitee shard/fallback tests and PPT edit-entry tests from the Build 224 slice; for this repair, 23 focused Linux image tests (mirror contract, shard staging, coalescing, install state) plus a Swift 6 iOS-SDK object compile of the repaired source with a contract stub that reproduces the original error. The accepted-SDK App build and distribution completed from immutable tag `v1.7.0-beta.82` / source `fe0852b4`; Apple build `b53b6e02-a0cb-4eba-8d94-921805ff80e1` is `VALID`, unexpired and `IN_BETA_TESTING` in the sole private Floe QA group. Physical-device behavior is not yet claimed. See [Runtime v2 architecture](TINYEMU_RUNTIME_V2.md), the [Gitee sharded mirror](FLOE_LINUX_GUEST_IMAGE_BUILD.md#distribution-mirror-gitee-sharded) and [Build 225 notes](RELEASE_NOTES_1.7.0_BUILD_225.md).

Accepted scope: integrate environments, package management, Node, media processing,
33 model evaluations covering 15 capabilities, and a lightweight workspace media
workbench. Prepare a TestFlight-ready build; do not publish a production release.
Environments provide dependency/data layering, not process security isolation.

Current internal delivery: `v1.7.0-beta.82` / `fe0852b4` (build 225). Release run 35773856510 completed the accepted-SDK App build, retained the unsigned IPA, signed, validated and uploaded the App, and published the GitHub prerelease. Apple build `b53b6e02-a0cb-4eba-8d94-921805ff80e1` was verified `VALID`, unexpired, attached only to the private internal Floe QA group with no public link, and `IN_BETA_TESTING` at 2026-09-22T20:17:32Z; both `en-US` and `zh-Hans` beta notes were read back. The one-way Gitee mirror contains the same release source and tag. Physical-device acceptance remains with the user. See [delivery record](TESTFLIGHT_1.7.0_BETA.md).

Build 221 delivery: the App-compile repair of the integrated Build 220 source. Build 220's accepted-SDK device App compile stopped with 14 diagnostics (rebuild run 35673428023); the repair adds the missing `FloeExecution`/`FloeModels` imports in `BackgroundRunCoordinator.swift`, fixes the `LinuxImageInstallCard` async fallback and `FloeTools` import, and corrects the `OfficeVisibleRenderGate` property name, plus one Swift 6 sendable-payload routing fix ([release notes](RELEASE_NOTES_1.7.0_BUILD_221.md)). All four shipping targets are 1.7.0 (221). Cloud build, signed upload, Apple processing, internal Floe QA distribution, GitHub prerelease and Feather publication are complete; physical-device acceptance is separate.

Build 220 candidate (superseded): version and release metadata was prepared from the integrated source `9e83fcfa` on branch `codex/build220-release-metadata` ([candidate notes](RELEASE_NOTES_1.7.0_BUILD_220.md)), covering Linux environment disks, caches, 9P `ls -l` semantics and install state, the explicit background mode with measured-only metrics, task-completion notifications and the PPTX visible-render/edit-entry repair. Its cloud device App compile failed (rebuild run 35673428023, 14 diagnostics, no artifact or upload); the repaired source is Build 221.

## Build 219 slice (delivered to Floe QA; device acceptance separate)

This source slice addresses the build-218 device findings recorded in the
TinyEMU Linux task log: first-use Linux preparation now runs automatically from
every Linux-required entry point (shell, Python, Node/npm, apt, local services,
language packages) through the shared cancellable download; Settings →
Execution Environments has an explicit component download/update/start/stop entry
that reports the guest network state; the guest configures its own interface,
default route, resolvers and git `safe.directory` before answering capability
negotiation (`net=up|partial|down`); the 9p server answers `xattrwalk` so `ls -l`
no longer reports "Unknown error 524"; MLX load failures distinguish a damaged
snapshot from insufficient memory, the preflight subtracts a running Linux
guest's reservation, and Gemma 4 E4B is retired from the selectable catalog;
agent Git mutations refresh an open source-control pane immediately; workspace
Office previews keep the standalone full-screen editor, the edit intent can no
longer be dropped, and the standalone close path offers save/discard/cancel.
Build 219 (tag `v1.7.0-beta.76`, source `0b21be93`) contains this slice; the build
and TestFlight upload followed this record. Apple processing, the existing private
Floe QA group and IN_BETA_TESTING are verified; physical-device acceptance remains separate. Evidence, commands and the remaining
physical-device checks are in
[the repair slice record](FLOE_1_7_REPAIR_LIFECYCLE_MLX_IDE_OFFICE.md).
`FloeAgent/scripts/audit_native_runtime_free.py` remains the anti-regression gate
for native Python/Node/Ruby payloads.

A follow-up source-only repair restores the real TinyEMU guest network in the
runner-only component pipeline: the component boot now passes the same network
switch the App uses (`floe_vm_host --net` / `FloeVMConfig.net_enable`), the
guest DNS plan leads with slirp's engine-served `10.0.2.3` alias plus public
fallbacks with an ordered bounded probe, the CAPS parser accepts and verifies
the `net=up|partial|down` field, and the cloud boot gate requires a real eth0,
a userland DNS answer and `net=up` (run 35645930554 failed with no eth0 because
the boot command omitted `--net`). See
[the network repair record](FLOE_1_7_LINUX_GUEST_NETWORK_REPAIR.md).

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

- Complete App build and native shell runtime regressions. Minimal-App Debug and
  Release qualification now covers multi-stage pipelines, interactive input/close,
  cancellation and timeout with stopped workers; blocking native commands and
  physical-device runtime acceptance remain open.
- Full-App background job context, Python/WASM installer routing, scoped native
  worker shutdown, migration/restart and quota acceptance. Host tests cover
  template independence, promotion recovery and selected lifecycle failure paths;
  cross-registry/CAS deletion recovery is not fully qualified.
- Node full-App linkage, interactive shell input forwarding, cross-runtime cwd,
  package installation compatibility and physical-device profiling.
- Production signed apt source provisioning, full transactional interruption/rollback
  acceptance and compatible package pool; signed publisher/client fixtures pass.
- Full-App and device media acceptance, enhancement runners and per-capability
  device evidence. Real host exports and focused native editor outputs pass;
  background operation, space pressure and long-video memory remain unqualified.
- Complete workspace/attachment navigation and shared jobs. Focused native
  workbench tests cover saved edits, trim/export and timed Chinese captions;
  Agent-to-workbench task visibility and conversation handoff remain open.
- Full legacy regression, immutable CI/SDK/device checks and distribution build.

No release, model readiness, native runtime acceptance or complete-plan success is
implied by these checkpoints. Source presence and successful downloads are not
execution evidence.

## TestFlight preparation checkpoint

- Candidate version: 1.7.0 (144); beta tag is not created until the source is fixed. Beta tags suppress automatic public GitHub release publication.
- VideoEditorKit is pinned and integrated with manual timed captions; the native Chinese-caption pixel test passes before/during/after checks. See FLOE_1_7_VIDEO_EDITOR_INTEGRATION.md.
- Sidebar footer now contains only the settings button; screenshots are retained in user guides.
- Native Node cwd tests: 9 cases pass; 4 host tests pass. Full App CI additionally found the missing CancellationToken import and Int/UInt bridge mismatch; both are corrected in source.
- CAS index corruption and failed reference writes now fail closed. Ingest preserves its source until the reference index is durable. Trash removal counts only successful deletions; failed CAS releases retain trash and references. Thirty-five module tests pass, including 8 environment tests.
- Workspace opening now creates its own project environment; settings includes environment records, installed layer packages and measured storage usage. App acceptance of these additions remains pending.
- App Store Connect discovery 34705408935 confirmed latest VALID upload 1.6.6 (142). No 1.7 TestFlight upload is claimed.

The original remaining acceptance gates still apply. This checkpoint does not qualify all 15 media model capability classes or all 15 native package pool entries.

- Follow-up native qualification: 9 bridge cases and 4 Swift adapter checks pass. Environment qualification now runs 11 tests, adding cross-workspace session ownership, registry write-failure rollback and template independence after CAS collection. See `native-node-adapter.json` and `environment-template-qualification.txt` in the evidence directory. Full App cloud verification remains required.

- Environment promotion now uses the same recoverable file transaction as package installation, verifies regular files and checksums, refuses ownership/path conflicts, and commits dpkg metadata with the layer manifest. Source copies are retained. Two new promotion tests cover source removal, missing files and traversal. Project deletion rejects dependent sessions; inherited rebuild state blocks execution. Full local qualification executes 42 tests (15 environment, 16 package, 9 media, 1 persistence, 1 signed catalog); this remains host/module evidence.

- Expanded native shell qualification found that ios_kill could invoke dash's signal handler on the Swift caller thread. The bridge now records per-session cancellation; dash checks it on its own interpreter thread. Debug and Release minimal-App runs pass 9 command cases plus interactive input/close, with every worker stopped. Evidence: `native-shell-cooperative-cancellation.json`. Full-App cancellation and timeout regressions are added. Non-cooperative blocking native commands remain a separate cancellation boundary.

- Audio inspection now reads the complete file in bounded chunks. Audio edits apply trim, gain, fades and both mix gains to streamed samples, enforce workspace/output boundaries, verify the temporary file and preserve existing output on running cancellation. PNG/JPEG frame batches use actual requested encoders and a new output directory; cancelled batches do not commit partial files. Proxies preserve aspect ratio; thumbnail generation cannot overwrite the video. Custom cancellation is forwarded to remux/proxy/thumbnail/extraction. Forty-seven host/module tests pass (15 environment, 16 package, 14 media, 1 persistence, 1 signed catalog).
- The accepted-SDK build additionally rejected Foundation enumerator iteration inside an asynchronous closure. Environment size reporting now uses explicit nextObject iteration. The missing font-import await and this SDK fix require fresh full-App cloud verification.

### UI and environment management continuation

- General settings owns Automatic/Light/Dark appearance previews. Root appearance now observes its persisted preference directly; Canvas inherits the app preference when its own appearance is automatic. Composer boundaries use semantic separators; document/media content is not recolored.
- Execution settings links to a searchable grouped container manager. Explicit-ID management API exposes installed/inherited packages, sources, install/remove/hold, stop/resume/delete and stopped-environment template saving. Package jobs survive navigation and are drained by lifecycle deletion. Repository provisioning is still pending; missing or untrusted sources cannot appear as verified downloads.
- Forty-nine host/module tests pass (15 environment, 18 package, 14 media, one persistence, one signed catalog). Two management API tests cover cross-project mutation/lifecycle scope, inherited read-only dependencies, rebuild refusal and template preconditions. Native management screen compilation passes. Two native UI interaction tests pass: manual appearance choices and reasoning disclosure; folded completed calls with newly arriving active calls retained. [Screenshots and evidence](evidence/floe-1.7/interface/README.md) use a synthetic fixture.
- Reasoning/tool cards share framed typography and semantic status. Tool groups count invocations rather than request/result pairs; manual collapse survives event arrivals, with active/error/approval rows retained. Timeline insertion and disclosure honor Reduce Motion. Full-App qualification and TestFlight processing remain open.
