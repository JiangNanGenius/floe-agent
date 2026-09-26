# Office PPT simulator stage diagnostics

This directory records why the real Office engine cannot be exercised in the
iOS Simulator, and how a simulator run still produces honest, useful evidence
for the user-reported PPT/PPTX open and edit-entry failure. It never claims a
slide first frame, an editing session, a save or a device result.

## The pinned host has no simulator slice

- `engine.lock.json.qualifiedHostArtifact` pins one device framework
  (`executableSHA256 37167e935892c26cb0e0746dc9eb5af605d66f622730eb4bcb7ef44605870afd`
  for run `36000058922`). The extracted pin reports
  `LC_BUILD_VERSION platform IOS`, `minos 26.0`, `sdk 27.0`, a single `arm64`
  slice and `CFBundleSupportedPlatforms = [iPhoneOS]`.
- A simulator link against that same binary is refused:
  `ld: building for 'iOS-simulator', but linking in dylib (…) built for 'iOS'`.
- The engine static archives in the same lock are iphoneos-arm64 objects;
  upstream can build an iphonesimulator engine (`--enable-ios-simulator`), but
  Floe never configured that. A simulator host would require a fresh engine
  build, new packaging/hashes and a separate App linkage, not a relink.

At the pinned engine commit `27b21dc1a90ac67c90fb1addd6f9fb22eec40ccc` the
upstream `ios/README.md` states the engine "cannot run in a simulator, because
the engine is built for an `iOS` target while the simulator is
`iOS-simulator`", and `configure.ac` exposes no `--enable-ios-simulator` (or
equivalent) switch — a real simulator host needs a fresh LibreOffice core
cross-build for `iphonesimulator` (every static dependency included), then a
new host framework build, packaging, and a separate simulator pin. That is a
dedicated engine-toolchain effort; this record keeps the exact build/link
evidence instead of faking a stub.

`FloeAgent/scripts/check_office_simulator_blocker.py` reproduces all of the
above as a receipt:

```sh
python3 FloeAgent/scripts/check_office_simulator_blocker.py \
  <pinned>/FloeOfficeNative.framework \
  --expected-executable-sha256 <pinned executable SHA-256> \
  --output simulator-blocker.json
```

Exit code 0 means the device-only blocker was proven; a framework that suddenly
carries a simulator slice fails the check instead of invalidating the record.
`FloeAgent/scripts/tests/test_office_simulator_blocker.py` pins the parser and
runs the real probe when `FLOE_OFFICE_HOST_FRAMEWORK` names a framework.

## What the simulator run does prove

`.github/workflows/office-simulator-stage.yml` builds the real App for the
simulator and runs `OfficeSimulatorStageUITests`, which:

- creates a real PPTX (title, bullets, editable chart, shape) and a real DOCX
  through the product's own OOXML builders and the batch fixture workspace;
- opens the real PPTX through the Notes library, the Workspace preview and the
  IDE Office tab, and the real DOCX through the Workspace preview;
- asserts the exact host-less surface each path reaches (explicit unavailable
  page, read-only fallback, bounded IDE failure) and that no path rests on the
  `正在打开文档…` spinner;
- leaves the App's durable `[FloeOfficeStage]` trace
  (`Library/Application Support/FloeAgent/OfficeDiagnostics/office-stage.jsonl`)
  and console log for the run receipt.

`FloeAgent/scripts/verify_office_simulator_stage_trace.py` then fails the run
unless every entry path recorded `engine.unavailable`, one session recorded the
ordered `intent.preview -> workingCopy.open -> workingCopy.ready ->
engine.unavailable -> session.failed` chain, no stage claims an engine open,
render, save or close, the blocker receipt proves the device-only platform and
the one focused XCTest case passed. The receipt always keeps
`realEngineOpened`, `pptFirstFrameObserved`, `officeEditSessionObserved` and
`officeSaveOrCloseObserved` false.

## Cloud runs

| Run | Result |
| --- | --- |
| [36245115825](https://github.com/JiangNanGenius/floe-agent/actions/runs/36245115825) | Blocker step passed; App build stopped on the missing untracked `dash*.xcframework` (workflow bootstrap omission, not a simulator-slice limitation). |
| [36245268353](https://github.com/JiangNanGenius/floe-agent/actions/runs/36245268353) | Same bootstrap omission before the dash build was added. |
| [36245810244](https://github.com/JiangNanGenius/floe-agent/actions/runs/36245810244) | Blocker step and 15 focused harness tests passed; App build stopped at mlx-swift Metal kernels (`xcodebuild -downloadComponent MetalToolchain` missing). |
| [36246400751](https://github.com/JiangNanGenius/floe-agent/actions/runs/36246400751) | Blocker step and 15 focused harness tests passed; App build reached resource copying, then failed on the gitignored `FloeApp/Resources/Fonts/Bundled` input (`error: The file “Bundled” couldn’t be opened because there is no such file`). |
| [36250288391](https://github.com/JiangNanGenius/floe-agent/actions/runs/36250288391) | Failed closed by design: the edit-surface host-source repair landed before the repin, so `bootstrap_office_host.py` refused with "Native host must be rebuilt for its changed public or implementation source". |
| [36248761459](https://github.com/JiangNanGenius/floe-agent/actions/runs/36248761459) | Cloud host rebuild of the repaired sources (`codex/ppt-edit-stall-repair` @ `c966b831`): compile/link/Swift-import qualification passed; artifact repinned in `engine.lock.json` (`archiveSHA256 2c610884…`, `executableSHA256 4de49bd1…`). The rebuilt framework is still device-only (`platform IOS`, `arm64`, simulator link refused, hash matched — local receipt `Local/Artifacts/office-host-36248761459/simulator-blocker.json`). |
| [36251954157](https://github.com/JiangNanGenius/floe-agent/actions/runs/36251954157) | Full honest stage run at the repin head `78e6f3b0`: blocker proof, all focused harness checks, the complete App simulator build, and `OfficeSimulatorStageUITests.testRealOfficeEntryPathsReachTheExactSimulatorHostBlocker` passed against real PPTX/DOCX fixtures on the iPad simulator; the stage trace records 4 `engine.unavailable` events, one ordered session chain, no forbidden stage and no engine success claim (`realEngineOpened`, `pptFirstFrameObserved`, `officeEditSessionObserved`, `officeSaveOrCloseObserved` all false). Receipt: `Local/Artifacts/office-simulator-stage-36251954157/office-simulator-receipt.json`. |

Both blocker receipts are retained (`simulator-blocker.json` in
`office-simulator-stage-*` artifacts; local copies under
`Local/Artifacts/office-simulator-stage-36245810244` and
`Local/Artifacts/office-simulator-stage-36246400751`) and state
`platform: IOS`, `architectures: [arm64]`, `simulatorLinkRefused: true`,
`matchesPinnedExecutable: true`, `simulatorHostBlockerProven: true`,
`realEngineInSimulator: false`.

The workflow now bootstraps all three gitignored build inputs before the App
build: the dash simulator slices (`bootstrap_native_components.sh`), the Xcode
Metal toolchain, and the pinned bundled fonts
(`scripts/fonts/fetch_fonts.py --check || fetch_fonts.py`); the full-App
simulator stage execution remains pending a future bounded run. The pinned
engine still has no simulator slice, so that run can only prove the blocker and
the host-less entry surfaces — never a PPT first frame.

## Smallest real-device evidence path

The same stage trace, the host's own `[FloeOffice]` lines
(`render-probe-facts`, `edit-entry-deferred`, `edit-entry-extent-bootstrap`,
`first-paint`, `visible-render`) and the host `renderDiagnostics` snapshot are
the device-side evidence. On a physical iPad run a real PPTX through Workspace,
Notes and IDE and export `office-stage.jsonl` plus the console filter
`[FloeOfficeStage]`/`[FloeOffice]`; the first missing stage in that trace names
the exact failing transition (working copy, engine runtime, open permission,
first paint, edit entry, edit surface paint, save or close).
