# iCTRL automation adaptations (Build 12 source)

Upstream: OpenMinis/iCTRL, commit `c1e4268859ba858d1579f7b846a56cb40641b7f6`
(tag v1.98.16), Apache-2.0. `LICENSE` and `NOTICE.md` are retained.

The generic cross-app controls in this prototype adapt the **semantics** of the
pinned runner in `iCTRLUITests/ActionHandler.swift` and its helpers; they do not
copy the upstream RPC/session server or its private C bridge.

## Adapted

- **Foreground binding**: actions follow the explicitly named target app and
  refuse when it is not actually in the foreground, instead of silently
  retargeting the current screen. Upstream's `snapshotPrecheck`, `resolveRef`,
  and `activateApp` describe the same failure mode (a query against a
  backgrounded app can block and then report a misleading "element gone").
  `Sources/BridgeTests/BridgeEngineTests.swift` performs the check through
  public `XCUIApplication.state`; there is no private `ForegroundApp` shim.
- **Bounded snapshot**: upstream `pageSource` walks one snapshot and trims
  depth/count instead of enumerating an unbounded query per element. Its
  `defaultMaxDepth` is 40, `maxChildrenPerNode` is 1000 and its default
  `maxElements` is 2000; the default depth exists because real apps put
  structural wrappers above their controls. This prototype uses the public
  `XCUIElement.snapshot()` path with default depth 40 (hard cap 64), 400 nodes
  (hard cap 800) and explicit per-string/serialized-byte budgets. Public XCTest
  still materializes the tree before our trim; upstream's bounded private fetch
  is deliberately not imported. The adapter is lazy and budgeted: metadata is
  read on admission and a child wrapper is created only when the depth/node/byte
  budget asks for it, avoiding a second full-tree copy. All metadata/child
  reads stay inside the Objective-C exception guard.
- **Unique identifier tap**: an identifier is resolved once against the live
  snapshot; zero matches and multiple matches are refusals, not guesses. The
  tap is a real synthesized point at the unique element's center, and the result
  reports the normalized point, resolved screen point and frame.
- **Gesture semantics**: normalized start/end points, a bounded duration, and a
  derived velocity; no implicit pixel/point conversion. Upstream's `swipe`
  derives gesture character from duration/velocity in the same way.
- **Focus-aware text**: upstream's `typeText` treats keyboard focus, appends
  versus replaces, and unknown outcomes as caller-visible facts. Its
  `focusedFieldValue` query uses `hasKeyboardFocus`, not the public `hasFocus`
  attribute; iOS text fields commonly leave `hasFocus` false even while the
  keyboard is open. This prototype therefore accepts one explicit selector
  (identifier, label, placeholder or point), resolves exactly one non-secure
  editable element, taps it, and calls `XCUIElement.typeText`. The SDK's public
  contract requires that element or a descendant to have keyboard focus and
  raises otherwise, so that assertion is the dispatch gate. A bounded
  `hasKeyboardFocus` query is advisory evidence and the only selectorless path.
  Results keep dispatch, focus evidence and actual-value verification distinct;
  text and values are never returned or logged. A scoped `XCTestCase.record(_:)`
  hook counts XCTest issues recorded while each SDK call is active and forwards
  every issue to `super`; a returned-with-issue call is not a dispatch/focus
  success. Append evidence requires a trustworthy before value and the exact
  expected append result; unchanged, suffix-only or request-equal replacement
  values are weaker evidence only.
- **Exception boundary**: upstream documents that `exists`, `isHittable` and
  `snapshot()` can raise Objective-C exceptions that Swift `try?` cannot catch,
  and routes them through an Obj-C catcher. This prototype uses its existing
  `BRCatchException` shim for activate/tap/swipe/type/snapshot and does not
  forward a text-related exception reason. The typing helper inspects only the
  static "Neither element nor any descendant has keyboard focus" phrase to
  distinguish a pre-dispatch SDK focus refusal from an unknown call outcome.
- **Recorded-issue boundary**: upstream documents that XCTest UI methods can
  record an issue and return rather than throw. This prototype wraps each
  affected SDK call with a bounded, content-free issue count and forwards the
  issue to XCTest. A normal return with an issue is classified
  `returned-with-issue` and stays unknown unless independently observed value
  equality proves the effect; `continueAfterFailure` and the long-lived engine
  are preserved. The native `Tests/Automation` fixture exercises the actual
  macOS `record(_:)` hook; the iOS engine object is compiled separately.
- **Home evidence**: upstream verifies Home by leaving the previously
  foreground app and observing SpringBoard/frontmost state. This prototype
  observes the last controlled app plus public `XCUIApplication.state` for
  SpringBoard and the host, and reports departure and an actual SpringBoard
  foreground as separate facts. It does not claim lock-screen or unlock proof.

## Not imported

- `ForegroundApp.{h,m}` and other private XCTest/accessibility/LSApplication
  calls. The current lane stays on public `XCUITest` APIs so the embedded test
  target remains buildable and auditable without a new private C surface.
- The JSON-RPC server, `/rpc`, `/pair`, `/skill`, `/schema`, `/stream`, OCR,
  browser automation, reference store, and synthesized-event helpers that are
  outside the LAN control contract.
- WebDriverAgent code; it is prior art only in the upstream NOTICE.

## Ownership

These are independent Swift implementations for the Floe Bridge prototype.
Where the upstream behavior is the source of a decision (foreground refusal,
snapshot trimming, unique-ref resolution, focus-aware typing), the adaptation is
recorded here and in `ThirdParty/PATCHES.md`.
