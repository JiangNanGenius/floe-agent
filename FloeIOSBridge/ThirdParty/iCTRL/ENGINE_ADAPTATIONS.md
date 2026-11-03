# Embedded engine adaptations (Bridge 1.0)

Upstream reference: OpenMinis/iCTRL, commit
`c1e4268859ba858d1579f7b846a56cb40641b7f6` (Apache-2.0; `LICENSE` and
`NOTICE.md` retained). The final engine is an independent Swift implementation.
The upstream files were read for exact API and behavior, not copied wholesale.

## Adapted behaviors

- **Text input** (`iCTRLUITests/ActionHandler.swift`): the pinned runner sends
  text through the private text-input event path with
  `typeText:atOffset:typingSpeed:shouldRedact:` and `shouldRedact:false`.
  `Sources/BridgeTests/BridgeEnginePrivateShims.m` now creates the same
  `XCSynthesizedEventRecord`/`XCPointerEventPath` pair through
  `NSClassFromString` and `NSInvocation`, but always passes
  `shouldRedact:YES`. The selector is runtime-checked; when it is absent,
  `type` and `clear_text` are not advertised and the executor never falls back
  to a path that can log raw text. Ordinary and secure third-party input both
  use the redacted path.
- **Continuous drag** (`iCTRLUITests/ContinuousDragPath.swift`): one synthesized
  single-finger path with equally spaced waypoint timestamps. The engine keeps a
  pure `points`/`duration` shape and the ObjC shim emits the actual
  `pressDownAtOffset:`, `moveToPoint:atOffset:` and `liftUpAtOffset:` events.
  Two-point endpoint drags use the public `XCUICoordinate` pipeline; both paths
  are bounded to the target app frame.
- **Foreground app** (`iCTRLUITests/ForegroundApp.{h,m}`): the engine uses a
  bounded adaptation of the XCTest accessibility client route
  (`XCUIDevice -> accessibilityInterface -> activeApplications`) to read the
  actual frontmost bundle identifier. It skips SpringBoard in favor of a
  foreground app, returns SpringBoard when that is the real surface, and returns
  nil rather than guessing. A public-state fallback covers the host app and the
  last actually controlled app.
- **Installed apps / URL opening** (`ForegroundApp.m`): `LSApplicationWorkspace`
  enumeration and `openApplicationWithBundleID:`/`openSensitiveURL:withOptions:`
  are used behind class/selector checks. URL opening first tries
  `XCTRunnerDaemonSession openDefaultApplicationForURL:completion:` (the pinned
  WDA-style route) and falls back to the workspace. A false return is a failure;
  dispatch acceptance is not reported as destination verification.
- **Lock state** (`iCTRLUITests/LockStateMonitor.{h,m}`): the SpringBoard
  `com.apple.springboard.lockstate` notify token is registered once and its
  current value is read at registration, so an engine started while already
  locked does not report "unlocked" until a change. Pressing the lock button
  uses the private `XCUIDevice pressLockButton` selector behind a guard.
  Unlock only presses Home (twice) and never enters a passcode; a still-locked
  result is a failure with that limitation.
- **Frames** (`iCTRLUITests/VideoStreamer.swift`): the pinned streamer's
  `Content-Type` is `video/mp4` (fMP4); its stale MPEG-TS comments are not used.
  The embedded engine does not implement a VideoToolbox encoder, muxer or HTTP
  server. It exposes bounded JPEG `BridgeScreenFrame` values through the shared
  `BridgeScreenFrameProvider`; the host media owner consumes/muxes them.
- **RPC contract**: method names/parameters/results follow the independent
  `Sources/BridgeCore/RPC/BridgeRPCMethods.swift` contract, which was already
  reconciled with the pinned schema. The executor implements the 30 non-host
  methods; `config`, `logs` and `stream_ticket` remain host-owned.

## Review repairs (2026-11-02)

- **Generic touch authorization**: every synthesized tap, double tap, long
  press, swipe, page, scroll, drag, element tap, find-and-tap and on-screen
  keyboard key event passes one `mutationGuard` immediately before the SDK
  call. The guard is bound to the per-invocation
  `BridgeEngineInvocationAuthorization` created for one SDK-gate execution and
  invalidated in `defer`; it reads live lock (tri-state, fail closed),
  SpringBoard/AuthKit/LocalAuthentication/AuthenticationServices overlays, the
  live foreground app and the live focused-field state. Secure focus without
  the owner grant is refused for all of these paths, not only `type`. A grant
  permits third-party App secure keyboard/touch input only. Unknown
  lock/focus/foreground state denies. Home/activate/launch/terminate/lock remain
  device or contract escape routes and do not use generic touches.
- **Apple/system secure surfaces**: secure text input in any `com.apple.*` App
  bundle is denied even with the grant; SpringBoard, AuthKit,
  LocalAuthentication, AuthenticationServices and passcode surfaces are denied
  for all input. Settings pages with a visible secure field (or an unreadable
  secure-field query) conservatively refuse generic touches; ordinary
  Settings/Safari/Notes pages without secure fields remain usable. Settings
  additionally treats a standard ten-digit passcode keypad as secure input,
  because an in-process passcode prompt may not expose a secureTextField; an
  unreadable keypad/secure-field check is refused. This is a conservative
  limitation, not a claim of system capability.
- **Privacy**: every SDK exception line uses fixed `stage/kind/code` facts from
  an allowlist; exception descriptions, domains, user-info and accessibility
  dumps are never logged or returned. Product-mode
  `BridgeEngineTests.record` forwards a sanitized `XCTIssue` with the genuine
  type, severity and source context and no detailed description, associated
  error or attachments. Issue counting and real lifecycle forwarding are
  unchanged. The legacy original-issue path is retained only behind the literal
  `BridgeBuild.prototypeDiagnostics` flag. No raw text or low-entropy secret
  hashes are added to logs, results or receipts.
- **Lock and frames**: the ObjC lock source is tri-state and starts unknown; a
  failed first or later `notify_get_state` remains unknown, never unlocked.
  `BridgeEngineLockState`/`BRIsLocked` refuse unavailable and unknown states.
  `is_locked` reports unknown as a failure rather than a boolean guess;
  lock/unlock refuse to claim a state they cannot read. Frame capture rechecks
  the captured lifecycle generation and live lock state after the actual
  screenshot and encoding and returns nil on Stop/lock.
- **Legacy file lane**: `processPendingCommands` returns immediately in product
  builds (`guard BridgeBuild.prototypeDiagnostics`) before any pending-file
  read, serial-gate acquisition or `BridgeInstallToken` load-or-create. The
  heartbeat and real RPC loop remain active. The historical file-canary body is
  unchanged for the flag-on prototype, but a product client cannot use the file
  lane to bypass pairing, the per-client grant or replay checks.
- **Before-value evidence**: `BridgeTextBeforeValueClassifier` marks only an
  explicitly empty string as a known-empty base. Placeholder-as-value,
  unreadable and secure values remain untrusted; append verification stays
  unverified unless `clear:true` or explicit empty evidence exists. No empty
  result is synthesized and no retry is automatic.

## Not imported

The iCTRL JSON-RPC/AuthManager server, its HMAC envelope implementation, HTTP
listener, reference store, browser automation, anti-bot/slider solving,
WebDriverAgent code, video encoder/muxer and any AGPL component are not used.
BridgeCore's existing RPC/auth package owns the wire protocol.

## Safety and ownership

All private calls live only in `Sources/BridgeTests`; `BridgeCore` has no
XCTest/UIKit import and its object has no XCTest/XCUI undefined symbols. Every
private class/selector is guarded; missing capability produces
`method_not_available` or an explicit unknown/failure outcome, never a stub
success. Text is never logged, returned for secure fields, or included in a
receipt. Secure OCR regions are masked from the live secure-field frames.
System lock/passcode/SpringBoard authorization input is always denied, and
secure input in Apple-owned apps is denied even with the owner grant. Generic
touches on SpringBoard and Apple secure-settings surfaces are conservatively
refused; use the Home/launch/activate escape routes or direct owner input.
