# Floe 1.7.23 (build 264) — Media workbench candidate note

Status: **uncommitted validation candidate** on `codex/build264-media-workbench`
(branch base `3b001ba3`). Not published, not tagged, not uploaded. TestFlight,
public test group and website deployment remain with the primary agent.

## Scope

Unified image/video workbench: versioned Floe-owned project document,
non-destructive image renderer (layers, interactive crop/resize/color,
mosaic/filter, guarded export), multi-track video renderer (multi-clip primary
track, music track, caption track, hard cut/cross-dissolve, explicit
H.264/HEVC fps/resolution, verified atomic output), rendered preview proxy
sharing the export pipeline, `media.project` tool with trusted confirmation
grants, AI drawer reusing existing enabled providers and durable video jobs,
saved-project reopen/resume, and entrances from Files, workspace preview and
Canvas.

## Executed evidence

| Check | Command | Result |
| --- | --- | --- |
| Module build (host) | `swift build --target FloeWorkbench` (Xcode 27 toolchain) | passed |
| Module tests | `xcrun xctest FloeWorkbenchTests.xctest` | **46/46 passed** |
| App tests (simulator) | `xcodebuild test-without-building … -only-testing:FloeAppTests/WorkbenchAIReviewTests` | **4/4 passed** |
| Export delivery tests (simulator) | same runner, `-only-testing:FloeAppTests/WorkbenchExportDeliveryTests` | **15/15 passed** (`logs/app-tests-export-delivery.log`): verified result retained + entrance callback exactly once; failure/invalid options/cancel/project switch clear stale success; async generation ownership + duplicate-submit guards; same-task vs other-task access |
| App compile (simulator, app + test bundles) | `xcodebuild build-for-testing -scheme FloeAgent -destination 'generic/platform=iOS Simulator' -jobs 6` | TEST BUILD SUCCEEDED (`logs/app-build-export-delivery.log`) |
| Native export delivery (primary, iPad) | PNG 960×540 export → Share/Save to Files → On My iPad | saved file hash-identical (`ae273ac1…f2eba5f3`); screenshot `Local/Private/build264-ui/export-native-share.png` |
| App compile (simulator, app + test bundles) | `xcodebuild build-for-testing -scheme FloeAgent -destination 'generic/platform=iOS Simulator' -jobs 6` | TEST BUILD SUCCEEDED (`logs/app-build-22.log`) |
| App compile (device, unsigned) | `xcodebuild build -scheme FloeAgent -destination 'generic/platform=iOS' -jobs 6` | BUILD SUCCEEDED; artifact `Local/Artifacts/build264-media/FloeAgent-1.7.23-264-unsigned-device-validation.zip` (sha256 `2306ad2c…f12dc38`); predates the preview/layout repairs |
| Rendered preview probe (iPad Air 13-inch M4 simulator) | `simctl launch org.floeagent.ios -ui-testing --ui-test-workbench-fixture --ui-test-workbench-video --ui-test-workbench-preview-probe` | proxy item `readyToPlay` (status 1), playback advanced to **1.90s**, decoded frame non-black (avg 0.318); screenshot `evidence/sim-video-preview-fixed.png` |
| Portrait layout | same simulator, screen capture | drawer layout with large preview and visible 44pt controls; screenshot `evidence/sim-portrait-compact.png` |

The 46 module tests include real Core Image renders (EXIF orientation, layer
order, transparency vs JPEG rejection, Chinese text glyphs, explicit-dimension
export re-verification, determinism, big-image guard) and real synthesized
video renders (mixed orientation/fps normalization, per-clip trim+speed
retiming, cross-dissolve contraction and blending, music mix with audio/video
sync, caption burn-in, cancellation with no output file, failure preserving
the previous output) plus the preview-proxy behavior (ready item, decoded
frames, orientation/crop, dissolve ramp, audio mix, preview/export agreement).

## Version

- `FloeAgent/project.yml`: `MARKETING_VERSION 1.7.23`,
  `CURRENT_PROJECT_VERSION 264` on the app and its three extensions; the Xcode
  project was regenerated with xcodegen.

## Not verified here

- Physical-device rendering/playback, HDR/wide-colour and hardware encoders;
  the preview proxy was verified on the iOS 27 simulator only.
- Real paid cloud generations.
- The `FloeAgentUITests` UI-test bundle was compiled but not executed; module
  tests plus `FloeAppTests` are the executed behavioral evidence.
- Signed/packaged release, Apple processing and test-group availability.

## Primary rendered-UI acceptance

- iPad portrait/landscape and 13-inch three-column layout, iPhone compact toolbar and overflow menu, full-screen return retaining video position.
- Actual speed slider changes timeline duration; one Undo restores the prior speed and Redo restores the edit. Saved-project reopen preserves edits.
- H.264 export independently reopened: 640×360, 24fps, 3.833333s video with AAC audio. PNG960×540 exported through native Share → Save to Files, with identical source/destination SHA256.
- OS window resizing could not be actuated even in Apple Settings through the simulator controller, so actual split-window dragging remains unverified. Physical-device performance, HDR and paid providers remain separate acceptance items.
