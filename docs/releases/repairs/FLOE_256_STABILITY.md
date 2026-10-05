# Build 256 stability work

## Changes

- Linux startup tools and both model prompt variants instruct the model to choose CPU/RAM from the task before its first shell call. User-selected resources take priority; the pool remains four cores total, at most three per guest.
- A successful guest launch records its granted shape in the environment directory. Cold shell starts and lifecycle restarts restore omitted dimensions after interruption.
- First multicore admission imports an existing verified image before checking its capability. Installation invalidates the pre-install status cache before the final verification.
- Python local services use the existing environment interpreter without implicitly creating a venv or running ensurepip. Startup jobs publish their starting state before activation.
- The task terminal defaults to a local workspace terminal and offers a separate Remote SSH selection.
- The pinned Impress engine no longer inserts a default freehand shape when iOS activates annotation. It waits for drawing input and keeps freehand mode active for subsequent strokes.

## Verification status

Local Swift lifecycle/service/shape tests and image migration/recovery tests passed. The Office overlay compiled for iOS 27 / arm64; its archive check verifies that only the locked members changed, including `drviewse.o` in `libsdlo.a`. Original failures and final receipts are retained privately.

Full App arm64 iPad Simulator builds passed with Xcode 27.0 (27A266a). Source `45ba78e3` was installed and checked: the local terminal shows its Linux install card, and Remote SSH opens the host list. [Screenshot](../../evidence/floe-1.7/build256/local-terminal-install.png). The test conversation reports that the Simulator has no available Apple system model; no model completion or live guest command is claimed.

Office host workflow [37261456081](https://github.com/JiangNanGenius/floe-agent/actions/runs/37261456081) passed from `7ab667eb`; artifact `11324529444` is pinned and verified. Its archive SHA-256 is `6598da3764dd7cf9b3dfc31f7392c62c82c3dddda8947c885b5c1dcaeccbf9b5`. Full device-target App compilation passed from `a4eb226f` with the new pinned host (Debug, arm64, iphoneos 27.0, signing disabled). The unsigned App archive is retained privately; this is not a TestFlight upload. This record does not claim a released build, completed device drawing/save acceptance, or a confirmed crash root cause. The reported session ends with process interruption; no system crash stack was supplied. Removing implicit pip installation addresses the observed startup work, not proof of why the app exited.


## Focused checks

- Lifecycle/service/shape: 83 XCTest cases passed; the final lifecycle revision passed 27 cases again.
- Image migration/template: 66 cases passed; the final image handoff suite passed 20, including absent versus corrupt legacy images.
- Model routing: 18 Swift Testing cases passed, including parallel-work tool discovery and compact prompt guidance.
- Shell boundaries: 9 cases passed, including visible-terminal installation policy.
- Office archive/bootstrap tooling: 11 + 21 Python cases passed; cloud native-host qualification passed independently.
- Full-App command: `xcodebuild -project FloeAgent/FloeAgent.xcodeproj -scheme FloeAgent -configuration Debug -sdk iphoneos -destination 'generic/platform=iOS' -jobs 6 ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build`, with an explicit task-owned internal-SSD DerivedData path. The Simulator build used `iphonesimulator` / `generic/platform=iOS Simulator`.

The first local Office compile exposed a module-header collision; Impress include roots are now scoped to its own object. ICU headers are hash-pinned, and their original upstream version is taken from the pinned engine's `download.lst`. The final archive check preserved every non-replaced member. A fresh-install UI run exposed the missing-image migration error and hidden terminal download; both were corrected and the affected UI rechecked. Earlier failure evidence remains available privately.
