> Historical prototype guide, retained for reproduction. It does not describe the 1.0 product.

# FloeIOSBridge — single-package recovery prototype

This is the next bounded feasibility gate, not a finished Bridge product and not a
public release candidate. It builds **one ordinary app** containing:

- a UIScene UIKit host with a minimal bilingual SwiftUI setup/status UI;
- a dynamic `BridgeCore.framework` shared by the host and the embedded test
  bundle (lifecycle, readiness, generation fences, diagnostics, token and the
  IPv4 reflector engine);
- an internal Packet Tunnel app extension that reflects only the
  `10.7.0.1 ↔ 10.7.0.2/32` pair, with no default route or DNS interception;
- one real embedded `.xctest` at `PlugIns/BridgeTests.xctest`, loaded only after
  the DDI exists; the host has no strong XCTest link;
- an on-device DDI manager (runtime download/import, RemotePairing import,
  Keychain storage, staged Rust FFI input, cryptex/personalized mount), linking
  the pinned MIT `idevice` static slice.

The prototype deliberately retains a private file command lane and an opt-in,
read-only, authenticated LAN diagnostics endpoint. Both are compiled for this
gate only and are not part of a public product.

## Build

Requirements: Xcode 27.1 at `/Applications/Xcode-27.1.app`, XcodeGen, Python 3.

```sh
DEVELOPER_DIR=/Applications/Xcode-27.1.app/Contents/Developer \
bash scripts/build_bridge.sh
```

The script:

1. verifies/fetches the pinned `idevice` v0.1.68 iOS arm64 slice
   (`Vendor/idevice.lock.json`);
2. runs the macOS self-check for packet validation, lifecycle generations,
   Stop-during-initialization/late-entry, token and lane policy;
3. generates the Xcode project with XcodeGen;
4. builds the test bundle and then the host for `generic/platform=iOS` arm64
   with `CODE_SIGNING_ALLOWED=NO`, 6 jobs initially;
5. packages the unsigned IPA and runs the topology/linkage verifier.

The checks are executable evidence, not compile-only claims: 86 core checks
(packet validation/reflection, lifecycle generations, Stop-during-init/late
entry, tunnel epoch fencing, DDI method selection) and 58 package/linkage
checks. No signing, install or device runtime was performed by the worker.

Expected output under `Local/Artifacts/ios-bridge-20261031/recovery/`:

```text
FloeBridge-unsigned.ipa
BridgeHost.app/
manifest.json          # artifact hashes, source hashes, Xcode version, idevice pin
verify.txt             # human-readable topology/linkage checks
verify-app.json / verify-ipa.json
core-checks.log
build-host.log / build-test.log
otool-*.txt / plutil-*.txt / file-*.txt
```

`BridgeHost.app` is also the extracted app used for signing and install; an IPA
must not be passed to `devicectl device install app`. The exact source snapshot
and dSYMs are exported beside it for primary recovery.

## Package invariants checked

- Exactly one top-level `Payload/BridgeHost.app`, one `PlugIns/BridgeTunnel.appex`
  and one `PlugIns/BridgeTests.xctest`; no nested `.app`.
- Host bundle ID `org.floeagent.iosbridge`, tunnel
  `org.floeagent.iosbridge.tunnel`; all roles `0.1.0 (6)`.
- Host has **no** XCTest/XCUIAutomation load command and no `_XCTestMain`
  undefined symbol; the test bundle links XCTest, XCUIAutomation and BridgeCore.
- `BridgeCore.framework` is embedded in the host and its own appex copy, has
  install name `@rpath/BridgeCore.framework/BridgeCore`, and the appex copy is
  byte-identical to the host copy.
- Host/appex/test rpaths resolve BridgeCore and the DDI developer frameworks.
- No DDI images, developer XCTest frameworks, code signatures or embedded
  provisioning profiles in the unsigned IPA.
- The host embeds the `idevice` symbols used for RPPairing/RSD/cryptexd.
- Prototype channel/diagnostic plist flags exist only in this prototype.

## Sign (primary only)

Run from this `FloeIOSBridge/` directory. The worker does not use a signing
identity, account or physical device. The primary supplies the two dedicated
development profiles. The helper validates
the selected certificate in both profiles, the team, both bundle IDs, the
required capabilities, and emits only minimal entitlements:

- host: application-identifier, team-id, get-task-allow, `vpn.api=[allow-vpn]`,
  `networkextension=[packet-tunnel-provider]`;
- appex: application-identifier, team-id, get-task-allow,
  `networkextension=[packet-tunnel-provider]`;
- xctest: identity only, host bundle ID, no entitlements;
- nested BridgeCore copies: identity only.

```sh
bash scripts/sign_bridge_ipa.sh \
  --ipa ../Local/Artifacts/ios-bridge-20261031/recovery/FloeBridge-unsigned.ipa \
  --host-profile <host-profile-path-or-UUID> \
  --tunnel-profile <tunnel-profile-path-or-UUID> \
  --identity <codesign-identity-SHA-1-or-name> \
  --output ../Local/Artifacts/ios-bridge-20261031/recovery/FloeBridge-signed.ipa
```

Add `--check-only` to validate profiles and the package without signing. The
helper signs inside-out: appex nested frameworks → appex with its own profile →
host frameworks → xctest with host identity/id → host with host profile. It
reads the signatures, entitlements and embedded profiles back and verifies the
signed IPA again. It never creates identities or changes accounts.

The profiles are development profiles and contain device identifiers. The
signed IPA and any profile are private; do not publish them.

## Install and first setup (primary)

```sh
export DEVELOPER_DIR=/Applications/Xcode-27.1.app/Contents/Developer
DEVICE="<device>"
ditto -x -k FloeBridge-signed.ipa ./signed
xcrun devicectl device install app --device "$DEVICE" ./signed/Payload/BridgeHost.app
xcrun devicectl device process launch --device "$DEVICE" org.floeagent.iosbridge
```

The app shows its real UI before any Start. Then:

1. Import a **RemotePairing** record (`public_key`, `private_key`,
   `identifier`) with the file picker. Lockdown records with `HostID` /
   `HostCertificate` are rejected with a clear message.
2. Download the DDI files in-app, or import a folder containing the expected
   files (BuildManifest, Image.dmg, trustcache, and cryptex_info/root_hash on
   iOS 26.4+). DDI images are never bundled.
3. Tap **Start engine / 启动引擎**. The sequence observes the DDI, downloads if
   needed, starts the reflector, probes `10.7.0.1:49152`, mounts the DDI,
   verifies XCTest is readable, enters `_XCTestMain(nil)` once on the main thread through a main-run-loop callback,
   and waits for the actual test method entry. The system may ask for the
   device passcode for UI automation.
4. Engine control is only shown ready after the test method writes
   `engine-ready.json` with the matching PID and test bundle ID.

Stop closes the command entrance immediately and cancels cancellable
preparation. If `_XCTestMain` was already dispatched, it is not killed or
re-dispatched; a late real entry is recorded as an initialized driver without
enabling a stopped service. A later Start reuses that driver. A test
initialization fault that never enters requires reopening the app.

## Prototype diagnostics and command lanes

All paths are under the app's `Documents/Bridge/`:

```text
diagnostics/status.json
diagnostics/engine-ready.json
diagnostics/engine-heartbeat.json
logs/host.log
logs/engine.log
commands/host/<id>.json      # setup/start/stop/tunnel/DDI
commands/engine/<id>.json    # legacy engine actions and typed cross-app actions
results/host/result-<id>.json
results/engine/result-<id>.json
```

The UI reveals the random per-install token stored in the Keychain. Every
command must carry the current process PID and that token; the lane action set
is separate. Example host command (write one file at a time):

```json
{"id":"start-1","action":"start","pid":1234,"token":"<token>"}
```

Host actions include `status`, `start`, `stop`, `resume`, `start_tunnel`,
`stop_tunnel`, `download_ddi`, `mount_ddi`, `configure_recovery`,
`rotate_token` and the one-way `shutdown`.
Engine actions: `status`, `screenshot`, `open_settings`, `tap_general`, `home`,
`stop_engine`, plus the typed generic actions below.

Read-only LAN diagnostics (off by default): enable it in the app, then:

```sh
curl -sS -H "Authorization: Bearer <token>" http://<iphone-ip>:47654/v1/status
```

It exposes redacted status only; no command endpoint. The same token is shown in
the app. Use this for post-reboot readback when devicectl/Xcode must not be
attached.

## Encrypted LAN control (prototype, separate from diagnostics)

Build 11 passed host qualification and physical iPhone encrypted-LAN,
Keychain persistence, screenshots, app switching and bounded background
acceptance with developer clients closed. Own DDI installation, clean reboot
recovery and iPad acceptance remain open; see [recovery evidence](Qualification/RECOVERY_GATE.md).

Build 11 已通过 iPhone 真机加密局域网控制、截图、应用切换与有限时长后台验证。
DDI 自行安装、严格重启恢复及 iPad 验收仍未完成。

This is a second, independent opt-in listener on port `47655`. It is off by
default and communicates over ordinary LAN after developer tools are
disconnected. It never accepts the read-only bearer token. It uses a **separate 32-byte control key** stored in the Keychain;
the key is provisioned only through the authenticated local
`configure_recovery` file command:

```sh
python3 scripts/LANControl/provision_control_key.py \
  --token-file <private-install-token-file> \
  --pid <current Bridge host PID> \
  --host <phone-lan-address> \
  --key-out <private-controller-key.json> \
  --command-out <configure-recovery-command.json>
```

The helper writes the command and controller key as `0600` files, never prints
either secret, and returns only the non-secret fingerprint. Copy the command to
`Documents/Bridge/commands/host/` before disconnecting developer tools. The app
stores the key and reports `controlKeyFingerprint`, `controlEnabled`,
`controlListening` and the actual control URL; no key is echoed.

The controller uses only Python's standard library and the pinned iCTRL v1
envelope (HMAC-SHA256 direction-separated keys, PRF-CTR, `tok`/`ts`/`nonce`/
`ct`/`tag`, ±120 s window, replay cache). Each invocation first calls the
authenticated, no-side-effect `/v1/session` discovery and stores the current
PID/generation/per-arm session in the `0600` key file. Definitive pre-dispatch
session/stale errors are refreshed and retried once; a transport failure is
`outcome_unknown` and a mutation is never retried in that case.

```sh
python3 scripts/LANControl/bridge_control.py --key-file <private-controller-key.json> status
python3 scripts/LANControl/bridge_control.py --key-file <private-controller-key.json> run start
python3 scripts/LANControl/bridge_control.py --key-file <private-controller-key.json> screenshot --out shot.png
python3 scripts/LANControl/bridge_control.py --key-file <private-controller-key.json> shutdown
```

### Operation receipt and read-only reconciliation

Every **mutating** controller invocation writes a `0600` receipt next to the
key file (default `<key-file>.operation.json`) **before** sending the request.
It contains only `id`, `action`, `lane`, request `pid`/`generation`/`session`
and a normalized non-secret parameter summary; text is represented only by
`textUTF8Bytes`. Read-only `status`, `screenshot` and `inspect` do not write a
receipt. A transport-lost or accepted-but-result-timeout operation remains
`outcome_unknown`/`result_timeout`; a later mutation using the same receipt path
is refused before dispatch until that identity is reconciled. A distinct
explicit `--receipt-file` is required for a new parallel operation, while a
`result_ready` or definitive `refused_pre_dispatch` receipt may be reused.

```sh
# The receipt defaults to <key-file>.operation.json; pass --receipt-file to name it.
python3 scripts/LANControl/bridge_control.py --key-file <key.json>   --receipt-file <key.json>.operation.json reconcile
```

`reconcile` performs only authenticated `/v1/session` discovery and one
`/v1/result` fetch for the exact receipted ID. It refuses a different current
session or host PID before the result fetch, never dispatches `/v1/control`, and
never retries. A definitive pre-dispatch stale refusal is the only case where
the controller automatically re-discovers and retries once; that retry writes a
new receipt for the newly generated operation. A lost mutation reply is always
`outcome_unknown` and must be reconciled or observed, never blindly reissued.

`POST /v1/session` is an authenticated, no-side-effect discovery request that
returns the current PID, generation and fresh per-arm session ID. `POST
/v1/control` accepts only host `status/start/stop/resume/shutdown` and engine
`status/screenshot/open_settings/tap_general/home/stop_engine`. `POST
/v1/result` retrieves the bound result and, for an authorized screenshot, the
bounded PNG artifact. Every control/result payload carries the current host
PID, shared generation and session ID; the dispatcher and result fetch
revalidate all three. A result is accepted only when its command ID, action,
PID, request generation and session bind to the original submission. The
listener prohibits cellular, does not advertise Bonjour, and has no plaintext
control path or arbitrary file/path action.

### Generic cross-app control (Build 12 source)

Build 12 adds five typed engine actions to the same encrypted
LAN/listener/file-dispatcher path. Its unplugged iPhone run verified Settings
and Calculator activation, coordinate taps, scrolling, screenshots and over
six minutes of background response. That run also exposed three source
boundaries: depth 10 was consumed by structural wrappers before any control,
public `hasFocus` is not iOS keyboard focus, and the legacy Home check observed
only Settings and the host. This source raises the bounded tree depth, adds an
explicit field-target `typeText` path with the SDK's own focus assertion, and
classifies the controlled app plus SpringBoard evidence. Build 13's unplugged
iPhone run read 225 actual nodes through depth 21, verified a known-value text
append, and captured the actual Home screen after Calculator. An initially
empty field was typed successfully but retained an `unverified` action result
because its before value was unavailable; clients must read back the UI instead
of retrying. A stale source-App diagnostic was also observed and is corrected
in source after the installed Build 13; that correction is not in its IPA.
See [the recovery gate](Qualification/RECOVERY_GATE.md#build-13-targeted-control-acceptance).
For this round, iPad compatibility is assumed from the verified iPhone path
by owner direction; a separate iPad physical acceptance is waived.

| Action | Required parameters | Optional parameters | Effect |
|---|---|---|---|
| `activate_app` | `bundleIdentifier` | — | `XCUIApplication.activate()` only; never launch/terminate/reset, then verify an actual foreground state |
| `inspect_ui` | `bundleIdentifier` | `maxDepth`, `maxNodes`, `maxStringBytes`, `maxTotalBytes` | one bounded `XCUIElement.snapshot()` tree with secure values redacted |
| `tap` | `bundleIdentifier` plus exactly one of `identifier` or (`normalizedX`,`normalizedY`) | — | real tap on the unique element's center or the normalized point |
| `swipe` | `bundleIdentifier`, `startNormalizedX/Y`, `endNormalizedX/Y` | `durationMilliseconds` (50...2000) | bounded drag between two normalized points |
| `type_text` | `bundleIdentifier`, `text` | at most one of `identifier`, `label`, `placeholder` or (`normalizedX`,`normalizedY`); omit only for a verified focused field | resolve one non-secure editable field and type through its SDK focus assertion; no text is echoed |

The wire request adds one optional object; legacy actions must omit it:

```json
{"v":1,"id":"ctl-123","lane":"engine","action":"tap","pid":1234,
 "generation":7,"session":"<32 hex>",
 "params":{"bundleIdentifier":"com.apple.Preferences","normalizedX":0.5,"normalizedY":0.25}}
```

Accepted responses and results carry the normalized non-secret `parameters`
summary and a `parametersDigest`/`argumentsDigest`; text is represented only
by `textUTF8Bytes`, never by its value.

`inspect_ui` defaults to depth 40, 400 nodes, 512 string bytes and 64 KiB of
serialized tree; hard caps are depth 64, 800 nodes, 2048 string bytes and
128 KiB. The default depth follows the pinned iCTRL `page_source` default (40),
which covers the structural `Other`/window wrappers real Settings-style
hierarchies put above their controls while the byte/node caps keep one response
finite. The tree is returned as the `uiTree` detail (`floe-ui-tree-v1`);
`truncatedDepth/Nodes/Bytes/Strings` and `secureValueRedactions` report what
was bounded. Public `XCUIElement.snapshot()` still materializes the SDK tree
before this code trims it (`snapshotMaterialization=public-full-tree-then-trimmed`);
the caps bound the response, not the accessibility fetch. The adapter itself is
lazy (`adapterTraversal=lazy-budgeted-by-depth-nodes-bytes`): metadata is read
when a node is admitted, and a child wrapper is constructed only after the
depth/node/byte budget admits it, so there is no second full-tree copy or
unbounded recursion after the SDK snapshot. Metadata/child reads run inside the
existing Objective-C exception guard with sanitized error text.

**Coordinate contract.** Coordinates are fractions of the target app's frame
reported by `XCUIApplication.frame`: `(0,0)` is its top-left, `(1,1)` its
bottom-right, independent of pixels/points or device scale. Results also report
the resolved screen point and the app frame. `tap` resolves an identifier
through the live snapshot and refuses zero or multiple matches; both an
identifier and coordinates together are refused.

**Text contract.** `type_text` requires 1...4096 UTF-8 bytes and no NUL. The
controller reads `--text-file`, which must be `0600`, and never puts the text in
argv. Supply at most one explicit field selector: `--identifier` (exact
accessibility identifier), `--label` (exact label), `--placeholder` (exact
placeholder) or `--x/--y` (a normalized point that must land in exactly one
non-secure editable field). Zero/multiple/secure/non-editable matches are
refused before any tap or text. The engine resolves the selected field to a
live element, taps its center, and calls `XCUIElement.typeText`, whose public
contract requires that element (or a descendant) to have keyboard focus and
raises otherwise. That SDK assertion is the dispatch gate; public `hasFocus` is
not used because iOS text fields often do not report that attribute even with
the keyboard open. The XCTest `hasKeyboardFocus` query is used only as bounded
advisory evidence and for the optional selectorless path: without a selector,
exactly one `hasKeyboardFocus` non-secure editable field must be found, else
nothing is typed and `--identifier/--label/--placeholder/--x/--y` is required.
A normal return is not treated as text-dispatch or focus proof. Every SDK call
runs inside a scoped count of XCTest issues recorded through the test case's
`record(_:)` hook; the hook always forwards to `super`, so XCTest failure and
bootstrap/lifecycle handling are preserved. Results distinguish
`callOutcome` (`returned-clean`, `returned-with-issue`, `focus-refused`,
`threw`, `not-entered`), `recordedIssueCount`, `textDispatched`,
`focusVerified` and `actualValueVerified`. A returned-with-issue call is
unverified/unknown unless independent value evidence proves the effect; a
returned-clean call is still not dispatch proof by itself. Append verification
requires a trustworthy before value and the exact expected result: a trusted
empty base plus `after == text`, or a trusted nonempty base plus
`after == before + text`. An unchanged value (including `before == request` and
`after == request`), a suffix-only coincidence, a request-equal replacement, or
a request match with an unavailable before value is weaker evidence only, never
a verified append. Results carry only observation labels, booleans and byte
counts, never the input text, before/after value or field value. An unverified
focus refusal reports `textDispatched=false` and `sdkFocusRefusal=true`. The
private command file is `0600` with complete file protection and is removed
after processing, including rejection.

**Home contract.** `home` keeps its legacy no-argument form. The engine
observes the last app it actually controlled (for example Calculator) and the
public `XCUIApplication.state` of `com.apple.springboard` before and after the
press. Results keep `dispatched`, `sourceLeftForeground`, `springboardForeground`,
`hostBackgrounded` and `actualHomeObserved`/`homeVerified` distinct. A source
departure alone is reported as `source-left-foreground-only`; it is not upgraded
to a Home or lock-screen claim. `destinationVerified=true` requires an actual
SpringBoard foreground observation (a background-to-foreground transition, or
SpringBoard already foreground when the source was not), so a lagging iOS app
state does not hide a real Home transition. If both reports stay foreground and
SpringBoard does not transition, the evidence is `source-still-foreground` and
no Home effect is claimed. `lockscreenVerified` remains `false` and
`unlockRequired` remains `unknown`.

**Safety.** Every generic action except `activate_app` requires the expected
bundle identifier to be observed in `runningForeground` immediately before the
SDK call; a user switch is a refusal, not a retarget. After every potentially
blocking snapshot, query or focus wait, a single final admission check re-reads
the expected app's foreground state and the shared generation/engine readiness
from one lifecycle snapshot. A stale command, Stop/fence, or foreground change
refuses without entering the next SDK closure. A Stop during an SDK call that
was already entered is reported as call-entered/unknown, never as cancelled;
no global lock is held around the SDK call. `activate_app` intentionally does
not require pre-existing foreground, but its lifecycle is checked immediately
before `activate()` and after return. SpringBoard, passcode and
authentication bundle identifiers are refused for input/activation; secure text
fields are refused; there is no unlock action. Results distinguish a dispatched
call from a verified effect: activation success requires an observed foreground
state, while tap/swipe/type cannot claim their destination effect and say so.
Objective-C exceptions are caught for activate/tap/swipe/type/snapshot; text
input and UI-query exceptions are deliberately not echoed because they may
contain UI content or text. The issue capture is synchronous around each SDK
operation; a late asynchronous XCTest issue after the operation has returned is
outside that scope and leaves the result unverified rather than fabricating
success.

Controller examples (all require the private key file; text uses a private
file, never argv):

```sh
python3 scripts/LANControl/bridge_control.py --key-file <key.json> \
  activate --bundle-id com.apple.Preferences
python3 scripts/LANControl/bridge_control.py --key-file <key.json> \
  inspect --bundle-id com.apple.Preferences --max-nodes 120
python3 scripts/LANControl/bridge_control.py --key-file <key.json> \
  tap --bundle-id com.apple.Preferences --identifier <identifier-from-inspect>
python3 scripts/LANControl/bridge_control.py --key-file <key.json> \
  swipe --bundle-id com.apple.Preferences --start-x 0.5 --start-y 0.8 \
  --end-x 0.5 --end-y 0.2 --duration-ms 300
python3 scripts/LANControl/bridge_control.py --key-file <key.json> \
  type-text --bundle-id com.apple.Preferences --text-file <0600-utf8-file> \
  --identifier <editable-identifier-from-inspect>
python3 scripts/LANControl/bridge_control.py --key-file <key.json> \
  type-text --bundle-id com.apple.Preferences --text-file <0600-utf8-file> \
  --label <exact-field-label>
python3 scripts/LANControl/bridge_control.py --key-file <key.json> \
  type-text --bundle-id com.apple.Preferences --text-file <0600-utf8-file> \
  --x 0.5 --y 0.13
```

The controller's top-level `ok` is the end-to-end action outcome. A sealed
transport can be complete while the engine action is `unverified` (for example,
text focus was not proven): the JSON then has `transportOk=true`,
`state=ready`, `actionStatus=unverified`, `actionOk=false` and `ok=false`, and
the process exits nonzero. That is not presented as successful typing. Receipts
still record `result_ready` for a processed operation and are never replayed;
`reconcile` uses the same classification without dispatching.

The prototype-only Details screen includes a transient control-test surface with
stable IDs `floe.controlTest.textField`, `floe.controlTest.counterButton`,
`floe.controlTest.counterValue`, `floe.controlTest.scrollList` and
`floe.controlTest.scrollItem.<0...23>`. Nothing on that surface is persisted.
Because the embedded XCTest engine runs inside the host process, driving the
host's own UI is not assumed to work; use an external app such as Settings
search for physical qualification when necessary.

Lifecycle boundaries:

- A normal **Stop** closes the control entrance and clears the owner-armed
  preference. The separate key is retained, but only the device owner can
  toggle control back on. Remote `start`/`resume` through the old listener is
  impossible after Stop.
- **`stop_engine`** stops only the engine command lane and leaves host control
  armed, so the computer can resume the existing driver.
- **`shutdown`** is one-way: it stops owned work, closes the read-only endpoint,
  closes the control listener and deletes the separate control key. The sealed
  final acknowledgement is the only response; a lost acknowledgement is
  reported as `outcome_unknown` and must not be retried.
- Per-listener/auth/request epochs plus a fresh unpredictable per-arm session ID
  reject a captured packet after disable/rearm even when the key, PID,
  generation and timestamp are unchanged. The session ID travels inside the
  authenticated/encrypted payload and is checked atomically at dispatch, result
  fetch and seal. The nonce cache still rejects exact replays; the timestamp
  window is extra replay defense, not the arm boundary. A new key immediately
  invalidates queued old-key requests; an already-entered SDK call keeps its
  honest late or unknown outcome and is never retried.

This is limited provisioning, not full upstream iCTRL `/pair`/`/rpc` parity:
there is no X25519 pairing exchange, no `/skill`, `/schema`, `/stream` or
`/logs`, and one provisioned controller key rather than a paired-client
session list. The per-arm session ID is an authorization fence, not a paired
client session.

## Reboot / no-computer gate (unproven here)

After a successful first run, Auto-recover is enabled by default (the user can
turn it off). Opening Bridge after a reboot should retry the cached DDI,
internal tunnel and on-device mount, then bootstrap without a computer. Do not
claim recovery while Device Hub/Xcode/devicectl is mounting or preparing the
phone; release developer connections before the gate. Preserve the app's own
status, marker, heartbeat, tunnel and mount evidence before reconnecting tools.
A DDI mounted by Xcode/Mac is reported as `preexisting` and is not evidence of
on-device recovery.

## Current unresolved risks

- The `10.7.0.1/32` route and interface `10.7.0.2` are the proposed narrow
  layout. The pinned upstream uses the same reflector idea but a `/24`
  interface; this must be proven on the real iPhone. Do not broaden routing.
- The RemotePairing service port is the pinned upstream fallback `49152`. If the
  iPhone's `remoted` port differs, transport needs a bounded resolver; the app
  reports the probe result rather than widening the route.
- The DDI mirror is runtime-only and can change; it is not bundled. A cryptex
  image must match the OS. Mount success is not assumed from file presence.
- Crypto priming copied from pinned upstream calls
  `idevice_pairing_file_read` on an RPPairing record. The pinned lockdownd
  parser does not accept that record, so the provider is **not** proven
  installed. Personalized-image TSS may abort; this is recorded as an unresolved
  risk, not a passed step. The cryptex path on iOS 26.4+ may avoid TSS but is
  likewise unproven here.
- The system passcode/UI-automation prompt, testmanagerd acceptance of this
  host, end-to-end tunnel/DDI/engine flow, background lifetime and reboot
  recovery require the primary's real-device run. Compilation, packaging and
  signing-structure checks are not runtime proof.

## Licensing

- `ThirdParty/iCTRL/LICENSE` and `NOTICE.md`: pinned OpenMinis/iCTRL
  `c1e4268859ba858d1579f7b846a56cb40641b7f6` (Apache-2.0). DDI/pairing
  sequencing and the Build 12 bounded-cross-app-control semantics are adapted
  from the pinned `iCTRLUITests/ActionHandler.swift`; only public XCTest APIs
  are used, no private `ForegroundApp` C shim was imported. See
  `ThirdParty/PATCHES.md` and `ThirdParty/iCTRL/ADAPTATIONS.md`.
- `ThirdParty/idevice/LICENSE`: MIT, released v0.1.68, commit
  `d32c8189c51c2789496b0768039419c3705498c3`; archive and slice hashes are pinned
  in `Vendor/idevice.lock.json`.
- No LocalDevVPN custom-license source was copied; the reflector is an
  independent implementation of the documented address-swap behavior. No
  AGPL StikDebug/ldid code or ldid signer is used.
