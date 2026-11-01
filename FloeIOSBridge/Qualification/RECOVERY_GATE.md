# Single-package recovery feasibility gate

This record covers the private recovery prototype. It is not acceptance of the
finished Bridge product or evidence of a public download.

## Current evidence

Source checkpoint: `256ca00ea9c18936248a9c3cb39251a7636529e5`.
Version: `0.1.0 (5)`. Toolchain: Xcode 27.1, iPhoneOS 27.1 SDK, Swift 6.
Physical target: iPhone 18 Pro, iOS 27.2. iPad behavior remains untested.

| Layer | Observed result |
| --- | --- |
| Source and compilation | 181 core checks; host, extension, shared framework and embedded test bundle compiled for arm64 iOS. |
| Package | One top-level app, one Packet Tunnel extension, one embedded test bundle; no strong host XCTest dependency or bundled DDI; all 100 recorded source hashes match the checkpoint. |
| Signing and installation | Dedicated development profiles with Network Extension support, strict nested-signature checks, install and ordinary host UI passed. Signed packages remain private. |
| Actual XCTest | Matching host/test process, real test-method entry, 1206 × 2622 screenshot, Settings activation and a click with a verified General-page destination passed. A missing-target attempt is retained separately as a failure. |
| Background | With the computer's physical-device view closed and pairing helper quit, a fresh request after 151 seconds reported background state and succeeded. Fresh screenshot and Home-button requests also succeeded. The idle interval contained 76 heartbeat samples, maximum gap 2.077 seconds. |
| Stop and resume | Service stopped and resumed in the same process; generation changed while the original bootstrap generation stayed unchanged. |
| Internal tunnel | The app's own signed Packet Tunnel connected; the proposed narrow IPv4 route reached the local development port at `10.7.0.1:49152`. No default route or DNS override is configured. |
| First setup | A RemotePairing record passed the official helper's validation and the app's import parser, then persisted in the device Keychain. Runtime DDI downloads completed. |
| Prototype credential rotation | Real Keychain replacement succeeded; both lanes rejected the revoked credential and accepted the replacement. No credential is included in this record. |

Unsigned prototype IPA SHA-256:
`ce873cdc883b0404ed5d7030ea016bb6d517d48dd6cf7442e49c6f023766837b`.
This identifies retained local evidence; it is not a published release asset.

## Build 6 reboot observation

Source checkpoint: `43a646cfb072f749cfcae6da937422ad9d7d8179`.
Version: `0.1.0 (6)`, same physical target and toolchain as above.
The recovery-preflight changes passed 224 core checks and a full arm64 build.
All 101 recorded regular source-file hashes matched this checkpoint.

After a full device reboot, the user opened Bridge and completed the system's
on-device password confirmation. Before any explicit computer developer-tool
reconnection, authenticated diagnostics over the phone's native Wi-Fi IPv6
reported a new process, reset system uptime, retained pairing, and a fresh real
XCTest entry in the ready state. The app had started the engine automatically.
The before-reboot endpoint rejected unauthenticated requests with HTTP 401 and
accepted authenticated requests with HTTP 200. Temporary diagnostics was then
disabled; both the host acknowledgement and a refused TCP connection confirmed
closure. No computer-side network or security settings were changed.

This is evidence of post-reboot in-app recovery with a preexisting system DDI.
It does **not** prove an absent-DDI transition or installation by Bridge. No
explicit Device Hub, Xcode or devicectl operations occurred during recovery;
background macOS developer daemons and the effectiveness of the earlier device
window closure were not independently excluded. Strict exclusion and own-mount
acceptance therefore remain open. A fresh 1206 × 2622 XCTest screenshot also
succeeded after reconnecting for diagnostic shutdown; that later result is
recorded separately from the pre-reconnection recovery evidence.

Unsigned Build 6 prototype IPA SHA-256:
`deb57720de2e94f9a05f12d552a3b424a71f42ec08774d0570d2614560e6cdee`.
This is a retained local prototype, not a published product.

## Pinned dependency review

Source inspection of idevice v0.1.68 (`d32c8189c51c2789496b0768039419c3705498c3`),
bound to the locked arm64 library, resolves the earlier crypto-provider question.
Both DDI installation methods use the in-tree HTTP client for TSS. RemotePairing
uses the in-tree TLS-PSK implementation. Neither path requires a separate rustls
provider initializer; the pin's HTTPS/lockdown rustls entry points install their
provider themselves. The earlier prototype's attempted Lockdown parse of a RemotePairing
record cannot reach its session initializer and is unnecessary.

This closes a source-level dependency question, not the physical DDI gate. It
requires no library replacement and must be re-evaluated if the pin changes.

## Build 7 controlled no-DDI trial

Source checkpoint: `c959d51ef7f959b957a581d99b421e55fd616737`.
Version: `0.1.0 (7)`, same iPhone and toolchain. All 330 core checks passed;
the full arm64 build, 104 regular source-file hashes, test dSYM UUID, single-app
package and strict nested development signatures were verified. The host still
has no strong XCTest dependency and the IPA contains no DDI.

The app's own Packet Tunnel and RemotePairing/RSD path removed the existing DDI
cryptex in 3.54 seconds. Both remote service views then reported absence, and
the host could no longer read XCTest. The removal-owned tunnel stopped. With
computer developer clients closed, the user force-quit and reopened Bridge. A
new host process displayed its ordinary home screen and served authenticated
native-LAN diagnostics with DDI absent and no XCTest bootstrap. This closes the
physical no-DDI host-UI gate on this iPhone.

The following own-install attempt did **not** pass. Before installation, both
remote queries and the local probe definitively reported absence. The own tunnel
connected and its development-port probe succeeded, but the opaque cryptex
installation call did not return during 700.5 seconds of observed waiting. DDI
remained unreadable and no real test entry occurred. The user pressed Stop:
service generation was fenced and the tunnel disconnected, while the log still
reported a live DDI worker. This proves logical stop, not FFI termination.

The pinned install path has no overall deadline or internal progress callback;
its TSS socket operations and HTTP/2 file-transfer waits can remain pending.
The later engine-entry timer cannot bound a mount that has not returned. The
blocked substage is unknown: this trial does not distinguish a small installer
RPC, TSS, bulk transfer or its reply. See the
[pinned installer entry](https://github.com/jkcoxson/idevice/blob/d32c8189c51c2789496b0768039419c3705498c3/ffi/src/cryptexd.rs#L733).

After the native evidence was saved and the acceptance window explicitly ended,
temporary diagnostics was disabled and a refused connection confirmed closure.
The computer then terminated the old process and restored the development
state. A fresh host observed an existing system DDI and retained pairing;
Auto-recover was restored, with diagnostics off and the engine idle. All such
post-reconnection observations are rollback evidence, never an own-install pass.

The next bounded diagnostic batch adds privacy-safe stage probes, a timed
no-identifier TSS reachability check and the existing extension's packet counters.
It keeps the single-app architecture and pinned library. Full product work stays
behind the remaining physical own-install gate.

Unsigned Build 7 prototype IPA SHA-256:
`92c0df990ae8844d3f6ec12169c97a6477aef6354c7e595c1049a9dd1adceb4c`.
This is retained local evidence, not a public release.

## Gates still open

- Observe absent DDI → installation through the internal tunnel → real engine
  entry, with timestamps proving that Bridge performed the mount.
- Close the remaining strict developer-tool exclusion uncertainty for reboot
  recovery; the Build 6 observation above proves actual reentry with an existing
  DDI, but not Bridge installation or complete exclusion of background tooling.
- Complete the same required physical checks on iPad and then the product,
  security, lifecycle, distribution and public-download acceptance in the plan.

The current successful XCTest runs used a **preexisting** DDI. They do not prove
that Bridge installed it. A DDI that remains present after reboot is also not an
on-device installation result. These are separate from no-computer usability.

## Recovery-test discipline

Before the clean reboot, cache DDI files and finish pairing/signing/installation.
Close computer developer connections. During recovery, do not scan, launch or
copy through Device Hub, Xcode or devicectl. Preserve the app's own pre-mount
probe, tunnel and installer outcome, and actual engine-entry marker through the
authenticated read-only diagnostics path before reconnecting those tools.
Temporary LAN diagnostics requires explicit opt-in and must be disabled after
this test. Device unlock and system passcode confirmations stay on the device.

Keep original failures. Do not repeat XCTest bootstrap in a process after an
initialization fault, substitute a second installed app, or expand normal
Internet routing to make the gate appear successful.

## Build 8 on-device installation and lifecycle boundary

Source checkpoint: `87d81cd0356e4f391f321848b69a43bc7e7c2e05`.
Version: `0.1.0 (8)`, same iPhone and toolchain. All 507 core checks, the
full arm64 build, 111 regular source-file hashes, matching embedded Core bytes,
test dSYM UUID and strict nested development signatures passed.

The own tunnel/RSD path again removed the DDI in 3.54 seconds. Both remote
views reported absence and local XCTest became unreadable. With no explicit
computer developer calls after removal, the user ran the new read-only stage
probe inside Bridge. All nine stages returned in 0.881 seconds, including
RemotePairing/RSD, cached assets, nonce-domain, personalization-identifier and
nonce reads. The no-identifier TSS HEAD received HTTP 401; this proves an
endpoint response, not the real TSS ticket request or its client implementation.

The following Start succeeded at installing DDI: the worker recorded cryptex
absent, image devices empty and local XCTest absent immediately before entry;
`cryptexd_install_ddi` returned in 2.859 seconds, the app verified local XCTest,
and a fresh real test entry appeared in the same process. Native Wi-Fi
diagnostics captured these results before any explicit developer reconnection.
The last sampled tunnel counters were 4,113 received and reflected packets,
with zero rejected packets. Counters are not a payload-integrity proof.
Background macOS developer daemons were not independently excluded. The Build 7
700.5-second nonreturning trial remains a failure with an unresolved cause.

This is **not** a full prototype pass. The first process later stopped
responding to diagnostics, and two file commands produced neither a received
log nor a result. Its last heartbeat was shortly after the first command was
issued. The second command was mistakenly dispatched before the first result
was reconciled; both unobserved requests are retained and were not replayed.
The phone showed Home. A later launch created a new process; the reason for
the original process loss is unknown, and debugger attempts yielded no stack.

The new process, using preexisting DDI, completed a fresh 1206 × 2622 XCTest
screenshot, activated Settings, and responded to native diagnostics and a host
command while Settings was foreground. The General tap reported `ok` despite
`destinationVerified=false`; the actual page remained Settings root. It is
recorded as failed click verification and a diagnostic correctness issue,
not a passed cross-App click. No reboot test was performed for this build.
The service was stopped and temporary LAN diagnostics disabled, with both the
host acknowledgement and TCP refusal verified; the phone was released.

The next bounded source review concerns first-process lifecycle and truthful
click reporting. Full product porting, iPad acceptance and publication remain
gated. No vendor or packet-tunnel source was changed by Build 8.

Unsigned Build 8 prototype IPA SHA-256:
`2f50c2e97fc12c9dac83a50edb4a7c14b23479a470cb289dfb83b415f1024a6f`.
This is retained private qualification evidence, not a public release.

## Build 9 startup regression

Source checkpoint: `653f446914be9b4b137ce9f58079685a175256be`.
Version: `0.1.0 (9)`, same iPhone/toolchain. The new local self-check and
lifecycle instrumentation passed 702 core checks, a full arm64 build,
115 source hashes, nested signing and symbol binding. The on-device check
then failed at ordinary host startup, before any DDI removal or self-check.

Four system crash reports match the exact Build 9 host dSYM. Each records
SIGTRAP on `org.floeagent.iosbridge.liveness.dispatch`, through
`_dispatch_assert_queue_fail`, `_swift_task_checkIsolatedSwift`, and
`closure #2 in BridgeLivenessMonitor.start()`. The new legacy timer handler
inherited main-actor isolation but ran on its independent dispatch queue.
This is a confirmed instrumentation regression, separate from the unresolved
Build 8 process loss. Compilation alone did not expose the callback's
runtime executor mismatch. The first host configuration request produced no
observed result and was not replayed; the diagnostic TCP port was refused.
The phone returned to Home and the device-view app was quit.

The next narrow repair must retain the independent heartbeat and qualify
actual asynchronous callback execution, then repeat ordinary physical startup
before the independent self-check/background gate. No Build 9 physical pass
or complete-product acceptance is claimed.

Unsigned Build 9 prototype IPA SHA-256:
`8bacc66eb7fd3d04a903a450cda5221c98e1fb9dfaad21739741b574e98bdd1d`.
The exact failing artifact, symbols and original reports remain private.

## Build 10 callback repair and repeated DDI wait

Source checkpoint: `73b1afa3c7c68a1b4f7fc43f7f0f864d0d9cade8`.
Version: `0.1.0 (10)`. The dispatch heartbeat now has an explicitly Sendable
callback before assignment to the legacy timer API. A real Darwin runtime
probe reproduced SIGTRAP with the original callback and recorded 15 independent
callbacks with the repaired handler while the main actor was blocked for
301 milliseconds. The 702 core checks, full arm64 build, 116 source hashes,
symbol binding and strict nested signatures passed. Actual ordinary iPhone
startup, visible home UI and independent main/dispatch heartbeats then passed.
This fixes the Build 9 startup regression; it does not explain Build 8's loss.

The own tunnel removed DDI in 3.528 seconds. After a user force-quit/reopen,
a fresh process opened the configuration UI with no local XCTest. The user
started the local self-check. Pre-install probes again recorded cryptex absent,
image devices empty and local XCTest unreadable. The opaque install call had
not returned after an observed 301.992 seconds. The main and dispatch heartbeats
remained current, the application remained foreground active, and protected
data was available. Tunnel counters rose to 16,435 by about 13 seconds and then
roughly four packets per second; no rejected packets or fragments were reported.
These are packet counts, not proof of an internal installation stage.

No XCTest entry or any of the seven canary commands occurred in this trial.
Stop fenced the generation, cancelled the pending canary and disconnected the
tunnel, while the entered native installer remained busy. After preserving the
native diagnostic evidence, the old process was terminated and the computer
explicitly restored DDI. A new ordinary host was idle with pairing retained,
AutoStart enabled and temporary LAN diagnostics disabled; both the host
acknowledgement and TCP refusal were checked before releasing the phone.
Computer restoration is rollback, not on-device installation proof.

Build 8's one successful own install and Builds 7/10's nonreturning calls remain
separate results. Delay after removal and the read-only preflight differ between
the trials and are confounded. Own installation is not yet reliable; independent
cross-App/background behavior, strict reboot recovery, iPad qualification and
publication remain open. No second installed helper app was introduced.

Unsigned Build 10 prototype IPA SHA-256:
`9d32adf99045039dd35ef38940980e695e9a41b966313264d7a71ecb6323c6f7`.
The exact package, symbols, callback negative control and original failures
remain private qualification evidence.

## Build 10 self-check with explicit developer clients closed

The same source and package were reinstalled and read back. Xcode, Device Hub,
LLDB/debugserver and devicectl clients were absent at the handoff boundary.
The user opened Bridge locally and reported automation running. No explicit
computer developer call was made during the following native Wi-Fi observation.

The fresh process recorded real XCTest entry with one original dispatch. The
user enabled read-only LAN diagnostics, stopped the service and started the
local self-check. The same initialized process resumed in generation 3 without
a second XCTest bootstrap. All seven serialized commands passed: status,
screenshot, activate Settings, tap General, screenshot, Home and final status.
The click verified the destination using About, rather than only reporting a
successful tap. Both screenshot artifacts recorded 1206 x 2622 pixels and
nonzero sizes; their pixel files had not yet been exported or visually reviewed.

After the self-check, native diagnostics still responded from the same process
218.305 seconds after its last background transition. Main-run-loop, independent
dispatch and engine heartbeats all remained current; no terminal marker was
present. This is positive cross-App and background evidence with explicit
developer clients closed. System background daemons were not independently
excluded, and cable removal was not separately confirmed. A later ordinary
network check received TCP refusal after the device-side cleanup request.
No developer reconnection was used to obtain these results.

DDI was preexisting, so this does not qualify own installation or clean reboot
recovery, and it does not establish that Xcode caused the older failures.
The user separately requested a new prototype build with opt-in encrypted LAN
control and result/screenshot retrieval. That source work is bounded to the
transport and existing dispatcher; full product, iPad and release gates remain.

## Build 11 encrypted LAN control

Runtime source: `7b5c086c5e40b48f4e2fb4edd3eb9286a6576636`.
Version: `0.1.0 (11)`, same iPhone/toolchain. The complete arm64 build passed;
124 regular source-file hashes match that immutable checkpoint. Nested Core
copies, all role versions, test dSYM UUID and strict role-specific development
signatures were checked. The single IPA was installed in place and the device
reported bundle version 11. No second app or new background mode was added.

The new opt-in control listener uses a separate Keychain credential and the
pinned iCTRL v1 encrypted envelope. An unpredictable per-arm session inside
the authenticated payload fences disable/rearm, independent of clock skew.
Final response revalidation and enqueue share the lifecycle lock: a real
negative-control run delivered 503 bytes decryptable by a revoked key before
that fix; the repaired path dropped the response. Host qualification passed
766 core checks and 91 real asynchronous LAN checks, including same-second and
future-dated prior-arm packets, revocation/late sends, replay, strict framing,
artifact confinement and shutdown admission. These are host results.

During initial setup the app saved the distinct control key, returned only its
fingerprint, retained pairing and stayed idle without XCTest bootstrap. That
preparatory computer-launched process was terminated. The user confirmed data
cable removal and opened Bridge locally. The fresh process loaded its stored
key and established a real XCTest entry; Xcode, Device Hub, debugger and device
command clients were absent at the handoff. Throughout the following observation
only native Wi-Fi encrypted API calls were used. System background daemons were
not independently excluded.

The computer retrieved and decrypted a real Home screenshot, activated
Settings, retrieved General, returned Home, stopped the engine lane, observed
`stopped` with `engineRunning=false`, and resumed the same initialized driver.
Shared generations advanced 1 → 2 → 3 while the original dispatch remained 1.
After resume, the same process remained in background with all three heartbeats
current for a measured 159.141 seconds. A fresh Home screenshot then succeeded.
All three PNGs were hash/size checked and visually reviewed at 1206 × 2622.
General was already open, so the unchanged SDK click evidence from Build 10
was reused rather than staging another click fixture.

On the physical gateway, exact replay, tampered tag, the read-only credential
used as a control key, stale PID, stale generation and wrong session were all
refused. These tests requested only safe host status; they did not fuzz SDK
mutations. Full paired-client management and all iCTRL endpoints remain outside
this prototype's limited provisioning surface.

A final authenticated normal host Stop was accepted. Both the control and
read-only diagnostic ports then refused TCP connections. The completed Stop
result could not be fetched because that entrance closes; no mutation was
retried. The authorized controller key was retained for future device-owner
rearm. The phone was released and no developer reconnection was used for
cleanup. The old Build 10 screenshots were archived during the subsequent
installation phase, separately from its earlier native observation window.

DDI was preexisting. No own-install, clean reboot or iPad pass is claimed for
Build 11, and this result does not establish Xcode as the cause of earlier
failures. Full product porting and public release remain gated. Floe mainline
versions, latest/feed/store and publication workflows were not changed.

Unsigned prototype IPA SHA-256:
`41a5dad29fcd27bd19232b0ef56c8ad0eba09e41edcf9d6ff0d29724d6733a7d`.
Exact packages, symbols, native responses, PNGs and original failures remain
local qualification evidence. After exporting them, duplicate app extractions
and finished standalone build outputs were removed (84,570,112 allocated bytes);
the unique negative-control executable and its reproduction source were kept.

## Build 12 concentrated control acceptance

Build 12 (`0.1.0`) was locally compiled, packaged, signed and installed from
source `b770849c4593445ae3ee1ca318f0dfb2b66a7800`. All 128 manifest source
files bind to that immutable snapshot; the test executable/dSYM UUID and
embedded Core copies match. The final App build passed 828 core checks. The
source lane separately passed 118 real macOS LAN checks and 61 controller
checks. A primary integration regression retained the original failure for a
valid 4 KiB input expanded by JSON escaping, then aligned the bounded command
and decoded-request ceilings to 32 KiB. The unsigned IPA SHA-256 is
`35da20d5a3a9929bd8abb993b510cadd76c2814919e403054500645e455c0159`.

The owner confirmed USB removal and local launch after the preparation process
was terminated and explicit developer clients were closed. A fresh process
entered XCTest once. The critical acceptance window used only the encrypted
native Wi-Fi controller, with no subsequent device-development calls. System
background daemons were not independently excluded. Existing DDI, pairing and
the separate controller key were retained; no mount removal, reboot, iPad run
or new pairing/key provisioning was performed.

Observed through actual SDK calls and five decoded, viewed screenshots:

- Generic bundle-ID activation opened both Settings and Calculator.
- A coordinate tap opened Settings search and its keyboard; another dismissed it.
- A real swipe changed the visible Settings list.
- Screenshot transport remained usable. The same process and original dispatch
  generation remained healthy for 363.881 seconds after foreign-App activation,
  with all three liveness beats current while the host was backgrounded.
- A single final host Stop was issued. Both network entrances then refused TCP.
  Its completed result was not observed after closure; it was not replayed and
  the controller key was retained.

The concentrated run also found specific limits, preserved as failures or
unverified outcomes:

- At the maximum UI depth of 10, structural wrappers consumed the budget: only
  15 nodes were returned, with depth truncation and no usable Settings controls.
  This is limited UI inspection, not a complete read-screen pass.
- With the search keyboard visibly open, `type_text` refused because no focused
  editable field was verified. It reported `textDispatched=false`; no text was
  typed. The input test did not pass.
- Home returned `unverified` after Calculator. The current verifier observes
  Settings and the host, so it cannot confirm this foreign-App transition. The
  actual Home effect was not captured before Stop and is not claimed either way.

This establishes the core LAN/App-control path and identifies bounded
inspection/input/verification repairs. It does not establish full iCTRL parity,
own-DDI stability, strict reboot recovery, iPad behavior or public release.

## Build 13 targeted control acceptance

Build 13 (`0.1.0`) was built and signed from immutable source
`412d140d372a7e9452eb36e1a8900ac967a68afe`: 135 manifest files match, the test
executable/dSYM UUID and embedded Core copies match, and the actual IPA retains
byte-identical Apache/iCTRL NOTICE/MIT license files. The full App build passed
928 core checks; the source lane separately passed 122 LAN and 78 controller
checks. A native macOS XCTest fixture deliberately forwarded one failure and
verified that a Void return with a recorded issue does not become a successful
input claim. Its runner exit 1 is retained as the expected negative result.

The unsigned IPA SHA-256 is
`d2dc84b5b81c7b08ef3201f36ee637c9e012f8c7da8249bbfc9258c459c22113`.
Installation succeeded, but subsequent device readback showed **wired**
transport. A wireless-first attempt is not proof of wireless installation.
The initial wireless-success description was corrected immediately.

After installation, the idle preparation process was terminated, explicit
developer clients were closed, and the owner confirmed USB removal and a fresh
local launch. The new process entered XCTest once. Only native encrypted Wi-Fi
was used in the acceptance window; background system daemons were not
independently excluded. DDI, pairing and controller key were retained.

Observed results:

- Default Settings inspection returned 225 actual nodes through depth 21,
  including real controls, without depth/node/byte truncation. A later larger
  search view hit the configured byte cap and reported truncation correctly.
- The first input into an empty Settings search field actually appeared in a
  viewed screenshot and UI readback. Its before value was unavailable, so the
  engine conservatively returned `unverified`, `textDispatched=unknown` and a
  nonzero CLI exit. The action was not blindly retried.
- After reading that known nonempty value, a distinct append command passed:
  `actualValueVerified=true`, `valueAppendVerified=true`, `textDispatched=true`,
  `focusVerified=true`, `recordedIssueCount=0`. A viewed screenshot independently
  confirmed the complete test string. The test text was then cleared and the
  search UI dismissed.
- Calculator activation followed by Home returned `actualHomeObserved=true`;
  a fresh, viewed Home-screen screenshot independently verified the effect.
  Its `sourceBundleIdentifier` diagnostic was still Settings, exposing a
  missing update after fresh generic activation. This is a diagnostic defect;
  Home acceptance here rests on the actual screenshot, not that stale field.
- The same process/original generation stayed healthy for 448.060 seconds
  after foreign-App activation, with all three liveness beats current. A single
  final host Stop was issued; both network entrances then refused TCP. The
  completed Stop reply was not observed after closure and the action was not
  replayed. The controller key was retained and the phone was released.

The missing controlled-App update is repaired in subsequent source only, with
an iOS arm64 object compilation; it is not substituted into the immutable
Build 13 artifact. Its next distributable binary must use a new build number.

These observations support basic iPhone control trials. They do not establish
full original-product completion, all control/IME behavior, strict own-DDI
reboot recovery, iPad qualification or public release.

## Current acceptance scope: iPad assumption accepted by owner

On 2026-11-01, after the Build 13 iPhone acceptance, the owner explicitly
accepted the working iPhone path as the compatibility assumption for iPad.
A separate iPad physical run is waived for this round and must not block
delivery or reopen the completed iPhone checks. Record iPad as **assumed
compatible by owner direction**, rather than physically verified. Earlier
iPad checklist entries describe historical gaps, not a current waiting gate.
This scope correction does not claim that the remaining original-product
features are implemented.
