// SPDX-License-Identifier: MPL-2.0
// FloeApp — DEBUG-only, launch-argument-gated passive Office touch telemetry.
//
// Observability only. Nothing here changes product gesture routing, engine
// state, layout or drawing behaviour:
//   * The whole file compiles only under `DEBUG`; the code path additionally
//     requires the explicit launch argument `--office-touch-qualification`.
//     Normal UI runs and every Release build never construct or install it.
//   * Installation uses the existing WKWebView evaluateJavaScript seam while
//     the native document is ready (the same channel OfficeExplicitSaveBridge
//     and OfficeCommandBridge already use). The injected DOM listeners are
//     `passive: true` capture-phase observers; they never preventDefault,
//     stop propagation, synthesize events, mutate CSS, zoom or handler order.
//   * Every DOM side effect is owned by a monotonic installation token that
//     travels into the page: a stale install or a stale teardown can never
//     tear down or shadow a newer probe on a reused WKWebView, and Swift
//     pre-checks ownership before dispatching either script.
//   * Teardown happens with the document session (close/cancel); every late
//     JavaScript callback is fenced by the same token so a stale task can
//     never touch a newer session, and no controller/session is retained.
//
// The captured window-side snapshot is published to the XCUITest runner
// through a 1x1pt non-interactive accessibility overlay (diagnostic-only,
// never created without the flag; `isUserInteractionEnabled = false` so it
// cannot intercept touches; clear background and inserted at the bottom of
// the native host's own view so it cannot alter document geometry).
//
// Payload contract (compact JSON, all strings truncated, no document text,
// paths, titles or tool output; the page guarantees a structurally bounded
// snapshot and Swift never slices an encoded JSON string): bounded recent
// ring (128 events, shrunk from the oldest side for transfer with an honest
// `rtv` count while the first-start window is always kept whole), never-
// evicted first-start samples (first 16 touchstart/pointerdown per
// diagnostic install) plus an all-start counter, per-type capture/bubble/
// defaultPrevented counters, per-event isTrusted / touches.length /
// changedTouches.length / pointerType / pointerId / rounded client
// coordinates / bounded target tag, id and first class token. Trusted
// two-finger touchmove records additionally carry the RAW full-precision
// passive finger distance `d` (the pinned container's own distance formula
// over this event's immutable touch list) and the per-gesture arrival
// counter `mv`. Touch and
// pointer-down records additionally carry an in-flight compact section
// snapshot (`q`: multiTouch, positionOnMouseDown, sectionOnMouseDown.name,
// touchEventInProgress, getZoom) captured INSIDE the passive handler, so
// gesture-birth container state survives even though touchend resets it
// before the next poll. Start records (`ts`/`pd`) additionally carry `cg`:
// the page canvas `getBoundingClientRect` plus `window.innerWidth/innerHeight`
// read synchronously inside the SAME passive capture dispatch and bound to
// the record's own time (`cg.t` equals the record `t`). The rounded client
// coordinates in the record are CSS-viewport coordinates at that same
// dispatch, so `cg` is the only geometry a consumer may use to prove a start
// point lay inside the canvas: a later periodic snapshot can legitimately
// report a different layout viewport (a keyboard re-presenting resizes it),
// and substituting that post-event geometry for start-time geometry is an
// event-time error, not a product fact. The rect read flushes pending layout
// but mutates nothing; it is DEBUG-only, runs at most once per start record,
// and reports null instead of throwing when the canvas accessor is
// unavailable, so the consumer fails closed honestly.
// The snapshot additionally carries a bounded passive focus/resize journal
// (`jr`, plus honest totals `jns` and no-eviction drops `jdr`, own dispatch
// ordinal `j`): window resize, visualViewport resize, focusin, focusout,
// click and dblclick observed through capture-phase passive listeners
// registered and removed by this installation only. Entries hold ONLY
// internal event tags, rounded numeric geometry (layout viewport, canvas
// height, visualViewport size, click client coordinates), the dispatch
// time/ordinal and the focus/click target's clipped tagName/id. The click
// entries additionally carry `tr` (isTrusted) so a WebKit-synthesized mouse
// click is not mistaken for a fresh trusted gesture, and `x`/`y` (rounded
// finite client CSS coordinates) so the documented Map.js click path can be
// attributed without reading any text. No document text, selection, caret,
// URL, user data or key values; the probe never preventDefaults, stops
// propagation, moves focus or changes layout. The journal exists to
// calibrate WHEN a viewport resize, focus transition or click happens
// relative to trusted gesture records; the consumer attaches and reports
// it, and no acceptance threshold is derived from it.
// Start records and the periodic snapshot additionally carry `eg`, the
// minimum read-only numeric group needed to separate the documented
// center-then-clamp view math from a residual anchor-capture error (pinned
// ViewLayout.setViewRectangleFromPointAndScale). `eg` copies PRIMITIVES only
// with explicit unit suffixes: `x/y` twips, `pX/pY` core (canvas) pixels,
// `cX/cY` CSS pixels, `dpi` = app.dpiScale for unit conversion. Groups:
// viewedRectangle (v*), live `_viewSize` (vs*), `frameSize` (fs*, derived
// from the document anchor section's core size), document-anchor section
// `myTopLeft`/`size` (da*), `_documentAnchorPosition` (dap*), settled
// `scrollProperties.viewX/viewY` (sc*), and the actual ZoomControl
// `pinchAnchor` SimplePoint (pa*, present per flag `paN`). No object
// references, arrays or section instances are retained, and no layout write
// or redraw is triggered: an absent getter yields null fields. `eg` is
// captured synchronously at a trusted start record (event-time) and once in
// each periodic snapshot (settled state); it is bounded per record, so the
// existing transfer budget and the never-evicted start window are unchanged.
// This timing matters for the engine's actual anchor: pinned
// ZoomControl.onMultiTouchStart clears `pinchAnchor`, the anchor is created
// only inside the FIRST `onMultiTouchMove` target handler, and the release
// handler clears it again before the touchend bubble sample. A start-time
// `eg` (correctly) reports no anchor, and the settled snapshot after the
// gesture reports none either. Therefore the probe retains ONE bounded
// in-flight record (`ia`) read from the post-target window-bubble sample (or
// a genuinely pre-end render-step fallback) of a trusted two-finger move.
// `ia` carries the same primitive SimplePoint units (`paX/paY` twips,
// `papX/papY` core pixels, `pacX/pacY` CSS pixels, `dpi`), plus its own
// event time `t`, sample time `at`, phase `ph='m'`, event key `k='tm'`,
// passive `seq`, per-gesture move ordinal `mv`, sampling `src`, gesture `gi`
// and the install owner/generation (`og`/`ng`). `iaT` counts eligible
// capture attempts and `iaN` counts honest unavailable (null) results. The
// retained record is never overwritten by a null; a null in-flight anchor
// means the engine exposed none, never invented coordinates. This capture
// is one read per gesture (bounded attempts) and is NOT added to every ring
// record; the settled layout/scroll group remains the periodic snapshot `eg`.
//
// Live-pinch fields (additive, schema `v` remains 1): every event carries
// `gi` (gesture serial) and `ph` (start/move/end/cancel). Touch records also
// carry `s`, a sample taken after the event has run through the canvas/
// `ZoomControl` target handler. The primary source is the event's own window
// bubble listener (`src='b'`); if propagation is stopped before that
// listener, a bounded requestAnimationFrame fallback samples at the render
// step (`src='r'`). A capture-handler microtask is NOT used: HTML can run a
// microtask checkpoint between listeners, before the target handler. `at` is
// the monotonic sample time, `iz` is
// `app.sectionContainer.isInZoomAnimation()` (pinned
// `CanvasSectionContainer.ts`), `zfs` is
// `app.map._docLayer._painter.zoomFrameScale()` (pinned
// `CanvasTileLayer.js`), `z` is the committed `app.map.getZoom()`, `post` is
// 1 only when the sample ran at or after its own gesture's last-finger
// touchend/touchcancel, and `stale` is 1 when a newer gesture had already
// started. `q` remains the synchronous pre-handler snapshot. A post-end or
// stale sample is never pre-end live-frame evidence. Trusted two-finger
// touchmove records carry `d`: the passive Euclidean finger distance of
// THIS event's own touch list, computed with the pinned container's own
// formula and recorded at RAW JSON double precision (no num4 rounding).
// Touch lists are immutable during dispatch, so the recorded value is the
// bit-identical double the engine latched; recording it raw removes any
// need for a distance-quantization bound across the fixture reference
// sizes. `d0` is the first bubble-sampled live move distance that fixed
// this gesture's engine pinch-start reference: set once per gesture at the
// first synchronous window-bubble sample observing the just-opened live
// frame, reset only at gesture birth, never established from the bounded
// rAF fallback, and snapshotted into every sample so its immutability is
// verifiable by every consumer of the same gesture. `mv` is the probe's
// own per-gesture arrival counter, which orders 0.1 ms event-time ties by
// real dispatch order instead of by the recorded timestamps. `lfin`
// retains the LAST qualifying same-event bubble live move independently
// of the bounded ring, together with its raw start zoom and its UNCLAMPED
// input target (z0 + Math.log(d/d0)/Math.log(1.2), the engine's own
// DocumentBase.getScaleZoom formula). Every record carries a monotonic
// `seq` from the probe's passive dispatch order, so the frozen move is
// proven to precede the release (seq < endSeq) even when their recorded
// times tie at the 0.1 ms resolution; the consumer rounds the
// full-precision JS target with exact Math.round semantics (floor(x+0.5)),
// never a rounded frame scale.
//
// SYNCHRONOUS NEAREST COMMIT (current candidate): the trusted last-finger
// touchend record remains a RAW INPUT-END record and is never rewritten as
// closed/final. The release handler commits the NEAREST integer level
// (floor(rawTarget + 0.5), then the pure range clamp) synchronously, so its
// own after-target sample must observe `iz` 0, no live frame scale (`zfs`
// nil) and the committed zoom. There is no asynchronous settle observer,
// watchdog, timer or post-release record: an open terminal frame is a
// contract failure and the consumer rejects it, even if a later frame or a
// fabricated post-release record looks valid. The marker badge's closed
// token comes only from a real after-target sample that actually read the
// closed frame; it proves handler-level state, not compositor presentation.
//
// When the probe session was launched with BOTH qualification arguments,
// the page also shows a marker badge: one fixed-position, fixed-size,
// pointer-events:none DOM node outside the canvas content flow. Its text
// carries ONLY the gesture serial, the move counter, the CURRENT actual
// touch count (0/1/2, display-capped) and the frame-closed phase (C only
// when a real after-target sample saw a closed committed frame; O
// otherwise — closed means frame/map commit, not raster ready). It is
// updated only from the probe's own passive real-event path: no
// manufactured time, touches or zoom, no document or user text, no engine
// mutation and no requestReDraw. It proves handler-level state transitions,
// not compositor presentation timing.
//
// The snapshot adds `gid/ga/gst/lmt/gend/gc`, a four-entry `gest` summary
// (start, last-finger end, move count, start/end zoom, frame state), a
// single `latest` current-gesture sample, `terminal` (the one record that
// actually ended the current gesture, retained independently of the ring),
// `fl` (the first eight pre-end live move samples of the current gesture,
// reset at birth, and now carrying the per-sample `d`/`d0`/`mv` input
// correlation fields), `lfin` (the LAST trusted same-event bubble live
// move of the current gesture, frozen by the probe's monotonic dispatch
// sequence and retained independently of the ring, so a 0.1 ms event-time
// tie with the release cannot misselect it), `eseq`/`lmseq` (the
// current gesture's last-finger end sequence and its last trusted move
// sequence), `mk` (the marker badge's current bounded tokens, with `n` = 1
// only when the badge node exists), and `pd` (fallback samples dropped by
// the bounded pending cap), so a bounded ring that overwrites early events
// still exposes the
// latest start/end timestamps, the terminal record and the gesture-start
// live frame. `st` adds `iza`, `zfs`, `minz` and `maxz`. These fields describe
// the requested layout/zoom-frame state only; they do not prove that the
// WebKit compositor presented a frame. The periodic snapshot retains engine
// numerics: app.map.getZoom, the same sectionContainer fields, app.dpiScale,
// the gate's __floeOfficePenState fields, and viewport facts
// (innerWidth/Height, devicePixelRatio, visualViewport width/height/scale,
// screen size and orientation type).
//
// BOUNDED CALL-SITE INSTRUMENTATION (same DEBUG + explicit launch gate,
// separate owner/generation fence, and NOT a purely passive listener): the
// probe additionally wraps a FIXED list of already-existing engine methods on
// the live instances of this document — Map.focus, Map._changeFocusWidget,
// TextInput.focus, docLayer._onInvalidateCursorMsg/_onCursorVisibleMsg/
// _onCellCursorMsg, _onUpdateCursor, _updateCursorAndOverlay,
// _onStatusMsg, _syncTileContainerSize, _mobileChecksAfterResizeEvent,
// _nonDesktopChecksAfterResizeEvent, _scrollCellCursorIntoView,
// _calculateScrollForNewCellCursor, and the exact scroll writer
// activeLayout.scrollTo. There is no generic execution surface: only these
// fixed names are wrapped, and installation is idempotent per instance (the
// existing snapshot poll retries wrapping while a method is not yet
// available). Every wrapper forwards the receiver, all arguments and the
// original return value, lets an original throw propagate, and never calls
// preventDefault, stops propagation, or writes model/focus/scroll/selection/
// zoom/frame state. This is deliberately labelled call-site instrumentation,
// not an observation of the event pipeline: it proves WHICH internal call ran
// and with what primitive arguments, not that the call produced a visible
// effect.
//
// Recording is fenced twice: a wrapped call only records while
// `window.__floeTouchProbe` still belongs to this installation's owner token
// AND page generation, and only after the current gesture serial is non-zero
// (`gid > 0`). The bounded trace ring (`cl`, 32 entries) is reset at each
// gesture birth so startup/page-load calls cannot fill it; the post-end
// window keeps recording until the NEXT gesture starts. `clN` counts every
// traced entry since birth, `clD` counts ring drops, and `clW` counts entries
// withheld by the export budget for THIS transfer (see the snapshot trimming
// order). Entries carry only fixed internal method tags (`k`), the probe's
// monotonic ordinal (`q`), install-relative milliseconds (`t`), the gesture
// serial (`gi`), fixed-schema primitive argument slots (`a`), whitelisted
// message-type constants (`tp`, only cursorvisible/invalidatecursor/
// cellcursor), read-only Calc/entry flag groups (`g`, `exg`), a derived
// height-increase flag (`hi`) and the exact scroll delta (`d`), and 2–3
// sanitized stack FUNCTION names with line/column (`sk`) whose source URLs are
// discarded. At the raw end-touch, a trusted click and a focusin the ring
// also receives one moment entry (`k='fx'`) with the active element's clipped
// tag/id, a whitelisted `role` constant and `map.editorHasFocus()` as 0/1.
// Stack capture is budgeted per gesture — 48 general attempts plus 24 slots
// reserved for the decisive focus/cursor/scroll tags — so a newly retained
// record still carries its product caller after the bounded ring has
// overflowed; retained records that receive no stack are counted honestly in
// `ctO` (exported only when non-zero, so the no-trace worst case is
// unchanged). `Object.floeCTwrap`-style dotted probe frames, anonymous/eval
// frames and source URLs are all discarded; only up to three sanitized product
// function names with line/column are kept.
// No message bodies, document text, selection, caret, URLs, paths, HTML or
// error strings are ever read into an exported field.
//
// PUBLIC INPUT-STATE OBSERVATION (additive; same DEBUG + explicit launch
// gate). Two bounded fixed-fact surfaces exist to explain a genuine
// visible-keyboard precondition failure WITHOUT changing any input, window,
// focus or selection behaviour:
//   * Page-side fixed facts: the periodic snapshot additionally carries `po`
//     (passive-only mode 0/1), `is` (the current fixed DOM input-state group)
//     and a never-evicted-first ring `sf` (max 8 entries, honest counters
//     `sfn`/`sfd`, own ordinal `q` fed by the SAME passive listeners that
//     already produce the raw end-touch, trusted-click and focus-in moments;
//     no new listener and no new teardown surface). Each `is`/`sf.is` group
//     exports ONLY booleans, fixed enums and nulls read from the live
//     document: active-element class enum `ae`, editor-textarea identity
//     match `ta`, contenteditable attribute enum `ce`, computed
//     `isContentEditable` `cev`, `readOnly`/`disabled` where the property
//     exists, `map.isEditMode()` `em`, the TextInput intent flag
//     `_acceptInput` `ai`, `map.editorHasFocus()` `ef`, `document.hasFocus()`
//     `hf` and `navigator.userActivation` `ui`/`ub` (null when absent). No
//     document text, selection, caret, HTML, URL or attribute value beyond
//     the whitelisted contenteditable token enum is ever read.
//   * Native fixed facts are published on their OWN bounded accessibility
//     element (identifier `office.touch-qualification.input-state`, label
//     `FLOE_INPUT_STATE`; a 1x1pt non-interactive static-text element like
//     the snapshot overlay, so the event JSON is never restructured or
//     reserialized). On every snapshot poll it reports wall time `wt`, the
//     passive-only mode `po`, owned-window key state `kw`, owned scene
//     activation enum `as` + foreground-activity bool `fa`, a bounded
//     read-only first-responder walk result `fr` (0 none in THIS owned
//     window, 1 the WebView or a descendant, 2 another owned-window view,
//     3 cap reached before a conclusive answer; with visited count `vn` and
//     cap flag `vc`), WebView `canBecomeFirstResponder` `wc` and
//     `isFirstResponder` `wf`, and the public `GCKeyboard.coalesced`
//     presence facts `gc`/`gk`. The walk touches only public `subviews` /
//     `isFirstResponder` / `isDescendant(of:)` inside the probe's OWN window:
//     no UIApplication global first-session or foreign-window scan, no
//     private UIKit class, selector, KVC or swizzle, and no
//     become/resign/reloadInputViews or keyboard forcing. `GCKeyboard`
//     presence is a public service report, never a claim of physical-
//     keyboard truth on a Simulator.
//
// PASSIVE-ONLY CONTROL (explicit DEBUG launch argument
// `--office-touch-qualification-passive-only`, meaningful only together with
// `--office-touch-qualification`): the probe installs its full passive touch/
// geometry journal, the focus/resize/click journal, the fixed input-state
// facts and both accessibility surfaces EXACTLY as before, but the bounded
// call-site instrumentation is never installed: `ctInstall` returns 0 and
// resets `ctn` to 0 without wrapping anything, moment entries are not pushed
// (the trace ring stays empty: `cl`= [], `clN`/`clD`/`clW`/`ctO` absent or
// zero), and a new-owner install still tears down any older generation's
// wrappers first, so neither teardown nor a new owner can keep stale
// wrappers. Ordinary (non-flagged) launches keep the current call-trace
// behaviour unchanged; nothing is silently turned off.
#if DEBUG && canImport(UIKit) && canImport(WebKit)
import UIKit
import WebKit
#if canImport(GameController)
import GameController
#endif

@MainActor
final class OfficeTouchQualificationProbe {
    static let shared = OfficeTouchQualificationProbe()

    static let launchArgument = "--office-touch-qualification"
    /// Second, narrower gate for the on-page pinch marker badge. The badge
    /// node is created only in a DEBUG build launched with BOTH this
    /// explicit argument and `launchArgument`; ordinary qualification runs
    /// never create it, and Release never compiles it at all.
    static let visibleMarkerLaunchArgument = "--office-touch-qualification-visible-marker"
    /// Third, control-shaped gate: it only DISABLES the bounded call-site
    /// instrumentation (method wrappers and their trace/moment records).
    /// Every passive touch/geometry journal, the fixed DOM input-state facts
    /// and the native input-state element stay exactly as in an ordinary
    /// qualification run. Meaningful only together with `launchArgument`;
    /// without it the probe never exists at all, so the default (flag
    /// absent) is unambiguous: current behaviour, wrappers enabled.
    static let passiveOnlyLaunchArgument = "--office-touch-qualification-passive-only"
    static let snapshotAccessibilityIdentifier = "office.touch-qualification.snapshot"
    static let snapshotAccessibilityLabel = "FLOE_TOUCH_PROBE"
    static let canvasAnchorIdentifier = "office.touch-qualification.canvas-anchor"
    static let canvasAnchorLabel = "FLOE_CANVAS_ANCHOR"
    /// Fixed read-only identifier for the native public input-state facts.
    /// It carries only the fixed boolean/enum/integer group described in
    /// the header — never user content — and is published on its own 1x1pt
    /// non-interactive element so the snapshot event JSON is never
    /// restructured or reserialized.
    static let inputStateAccessibilityIdentifier = "office.touch-qualification.input-state"
    static let inputStateAccessibilityLabel = "FLOE_INPUT_STATE"

    /// True only in a DEBUG build launched with the explicit qualification
    /// argument. Absent in normal UI runs and impossible in Release (the type
    /// itself does not compile there).
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    /// True only when BOTH qualification arguments are present. The page
    /// still records everything without the marker argument; the badge DOM
    /// node is the single additional side effect gated here.
    static var isMarkerRequested: Bool {
        isRequested && ProcessInfo.processInfo.arguments.contains(visibleMarkerLaunchArgument)
    }

    /// True only in a DEBUG build launched with BOTH the qualification
    /// argument and the explicit passive-only control. Passive-only keeps
    /// the whole passive observation surface (raw touch/pointer records,
    /// start window, focus/resize/click journal, in-flight anchor, fixed
    /// input-state facts, both accessibility surfaces) and installs NO
    /// call-site wrapper at all. Launch-argument based, so it is constant
    /// for the whole process lifetime.
    static var isPassiveOnly: Bool {
        isRequested && ProcessInfo.processInfo.arguments.contains(passiveOnlyLaunchArgument)
    }

    /// Page-side transfer budget (JSON.stringify length). Swift accepts up to
    /// `maxSnapshotCharacters` and, on any violation, replaces the value with
    /// a complete valid bounded failure object — never a sliced JSON string.
    private static let maxSnapshotCharacters = 45_000
    private static let pollIntervalNanoseconds: UInt64 = 250_000_000
    private static let webViewSearchAttempts = 8
    private static let webViewSearchIntervalNanoseconds: UInt64 = 250_000_000
    /// Bounds for the read-only first-responder walk. The walk never leaves
    /// the probe's OWN window, only reads `subviews`/`isFirstResponder` and
    /// stops at the first responder or at these caps (an inconclusive cap is
    /// reported honestly as `fr`:3 with `vc`:1 instead of guessing).
    private static let responderScanMaxNodes = 800
    private static let responderScanMaxDepth = 48

    /// One document-controller installation. All references are weak except
    /// the overlay it owns; a replaced controller or a close clears the whole
    /// record, and every async continuation and every DOM side effect is
    /// fenced by the monotonic `token`.
    private final class Installation {
        let controllerID: ObjectIdentifier
        let token: Int
        weak var controller: UIViewController?
        weak var webView: WKWebView?
        var overlay: UIView?
        var anchor: UIView?
        var stateView: UIView?
        var jsInstalled = false
        var webRetryScheduled = false

        init(controller: UIViewController, token: Int) {
            self.controllerID = ObjectIdentifier(controller)
            self.token = token
            self.controller = controller
        }
    }

    private var installation: Installation?
    private var pollTask: Task<Void, Never>?
    private var nextToken = 0

    /// Narrow entry called by `OfficeFileSession` at its own document-ready
    /// transitions. Idempotent per controller; a replaced controller swaps
    /// the installation cleanly. Returns immediately when the flag is absent.
    func installIfNeeded(for controller: UIViewController) {
        guard Self.isRequested else { return }
        let id = ObjectIdentifier(controller)
        if let current = installation {
            if current.controllerID == id {
                // Same document: only re-arm the bounded webview lookup if the
                // page host was never found; the JS install itself is once.
                if current.webView == nil, !current.webRetryScheduled, !current.jsInstalled,
                   controller.isViewLoaded {
                    current.webRetryScheduled = true
                    scheduleWebViewSearch(for: current)
                }
                return
            }
            removeCurrentInstallation()
        }
        guard controller.isViewLoaded else { return }
        nextToken += 1
        let inst = Installation(controller: controller, token: nextToken)
        installation = inst
        attachOverlay(to: controller, in: inst)
        searchOnceOrSchedule(inst)
    }

    /// Narrow teardown entry called by `OfficeFileSession.closeController()`
    /// — the single path that releases every mounted editor (close, release,
    /// recovery, preview switch). Stops polling, removes the overlay and
    /// removes the DOM listeners only if this page probe is still owned by
    /// exactly this installation token.
    func removeTouchTelemetry(for controller: UIViewController) {
        guard let current = installation, current.controllerID == ObjectIdentifier(controller) else { return }
        removeCurrentInstallation()
    }

    private func removeCurrentInstallation() {
        pollTask?.cancel()
        pollTask = nil
        guard let current = installation else { return }
        installation = nil
        current.overlay?.removeFromSuperview()
        current.overlay = nil
        current.anchor?.removeFromSuperview()
        current.anchor = nil
        // The input-state element is owned by this installation exactly like
        // the overlay: a removed installation cannot keep publishing a stale
        // native snapshot, and a new owner always creates its own element.
        current.stateView?.removeFromSuperview()
        current.stateView = nil
        if let web = current.webView {
            let token = current.token
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Swift ownership pre-check: if a newer installation already
                // lives on this same page, its install script has torn down
                // (or will not re-open) the older probe — sending removal now
                // could only race the newer owner, so skip it.
                if let newer = self.installation, newer.webView === web { return }
                _ = try? await web.evaluateJavaScript(Self.domRemovalScript(owner: token))
            }
        }
    }

    private func searchOnceOrSchedule(_ inst: Installation) {
        if let web = findLiveWebView(for: inst) {
            inst.webView = web
            evaluateDomInstall(inst, web: web)
        } else {
            inst.webRetryScheduled = true
            scheduleWebViewSearch(for: inst)
        }
    }

    private func findLiveWebView(for inst: Installation) -> WKWebView? {
        guard let view = inst.controller?.view else { return nil }
        return OfficeExplicitSaveBridge.findWebView(in: view)
    }

    private func scheduleWebViewSearch(for inst: Installation) {
        let token = inst.token
        Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<Self.webViewSearchAttempts {
                try? await Task.sleep(nanoseconds: Self.webViewSearchIntervalNanoseconds)
                guard !Task.isCancelled else { return }
                guard let current = self.installation, current.token == token,
                      !current.jsInstalled, current.webView == nil else { return }
                if let web = self.findLiveWebView(for: current) {
                    current.webRetryScheduled = false
                    current.webView = web
                    self.evaluateDomInstall(current, web: web)
                    return
                }
            }
            // Bounded: never claim success without the DOM ack. The overlay
            // stays observable with an explicit not-installed reason so the
            // runner can distinguish "probe missing" from "probe idle".
            guard let current = self.installation, current.token == token,
                  current.webView == nil else { return }
            current.webRetryScheduled = false
            self.setOverlayValue(current, "{\"v\":1,\"ok\":0,\"reason\":\"no-webview\"}")
            // Failure paths publish the native fixed facts too.
            self.updateInputState(current)
        }
    }

    private func evaluateDomInstall(_ inst: Installation, web: WKWebView) {
        let token = inst.token
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Pre-check Swift ownership before dispatching the side effect,
            // so an install that lost its installation while queued is never
            // sent to the page at all. The script re-checks page ownership.
            guard let current = self.installation, current.token == token,
                  current.webView === web else { return }
            let script = Self.domInstallScript(owner: token, marker: Self.isMarkerRequested,
                                                passive: Self.isPassiveOnly)
            let raw = try? await web.evaluateJavaScript(script)
            guard let current = self.installation, current.token == token,
                  current.webView === web else { return }
            if let ack = raw as? String, ack.hasPrefix("probe-ok") {
                current.jsInstalled = true
                await self.refreshSnapshot(current)
                self.startPolling(current)
            } else {
                self.setOverlayValue(current, "{\"v\":1,\"ok\":0,\"reason\":\"js-install-refused\"}")
                // The failure path still publishes the native fixed facts:
                // they need no page-side installation at all.
                self.updateInputState(current)
            }
        }
    }

    private func startPolling(_ inst: Installation) {
        pollTask?.cancel()
        let token = inst.token
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.pollIntervalNanoseconds)
                guard !Task.isCancelled else { return }
                guard let self, let current = self.installation, current.token == token,
                      current.jsInstalled else { return }
                // Poll only while the document surface is actually on screen;
                // a detached tab skips (and stays installed) without load.
                guard let web = current.webView, web.window != nil else { continue }
                await self.refreshSnapshot(current)
            }
        }
    }

    private func refreshSnapshot(_ inst: Installation) async {
        // The native fixed facts are collected on EVERY snapshot attempt,
        // including attempts where the page read fails: the keyboard-state
        // question must not depend on the page-side pipeline succeeding.
        updateInputState(inst)
        guard let web = inst.webView else {
            resetCanvasAnchor(inst, reason: "web-unavailable")
            return
        }
        let raw = (try? await web.evaluateJavaScript(Self.domSnapshotScript)) as? String
        guard installation === inst else { return }
        guard let json = raw else {
            resetCanvasAnchor(inst, reason: "snapshot-unavailable")
            return
        }
        setOverlayValue(inst, json)
        updateCanvasAnchor(inst, json: json)
    }

    /// The page already bounds the snapshot structurally (shrinking the
    /// oldest ring side for transfer and marking `rtv`, while the first-start
    /// window is always kept whole). Swift never slices an encoded JSON
    /// string: a value outside the contract is replaced with a complete,
    /// valid, explicitly-unbounded failure object instead.
    private func setOverlayValue(_ inst: Installation, _ json: String) {
        let bounded: String
        if json.hasPrefix("{"), json.hasSuffix("}"), json.utf16.count <= Self.maxSnapshotCharacters {
            bounded = json
        } else {
            bounded = "{\"v\":1,\"ok\":0,\"reason\":\"snapshot-unbounded\",\"length\":\(json.utf16.count)}"
        }
        inst.overlay?.accessibilityValue = bounded
    }

    private static func finiteDouble(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }

    private static func snapshotObject(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// DEBUG-only passive pinch anchor. It is a plain accessibility element
    /// whose frame is a safe sub-rectangle of the real document canvas,
    /// inserted at the bottom of the host view exactly like the 1x1 snapshot
    /// overlay. It is explicitly non-interactive and has no autoresizing or
    /// constraint participation, so it cannot intercept touches or alter
    /// layout. XCUITest pinches synthesize real UIKit touches whose hit
    /// testing still reaches the WebView underneath.
    private func attachCanvasAnchor(to controller: UIViewController, in inst: Installation) {
        let anchor = UIView(frame: .zero)
        anchor.backgroundColor = .clear
        anchor.isUserInteractionEnabled = false   // never intercept any touch
        anchor.autoresizingMask = []              // never participates in layout
        anchor.isHidden = true                    // no stale frame before valid geometry
        anchor.isAccessibilityElement = true
        anchor.accessibilityIdentifier = Self.canvasAnchorIdentifier
        anchor.accessibilityLabel = Self.canvasAnchorLabel
        anchor.accessibilityTraits = .staticText
        anchor.accessibilityValue = "{\"ok\":0,\"reason\":\"awaiting-geometry\"}"
        controller.view.insertSubview(anchor, at: 0)
        inst.anchor = anchor
    }

    /// Maps the page-reported canvas rectangle (CSS px, viewport relative)
    /// into a safe native sub-rectangle. The scale comes from the actual
    /// WKWebView bounds and the page's live `innerWidth/innerHeight`; the
    /// rectangle is intersected with the visible web/host/window bounds before
    /// the classical 72 pt side/bottom and 96 pt top insets. Every invalid or
    /// stale input clears the previous frame and value instead of leaving a
    /// formerly-valid anchor in place.
    private func updateCanvasAnchor(_ inst: Installation, json: String) {
        guard let host = inst.controller?.view, let anchor = inst.anchor else { return }
        guard let web = inst.webView,
              web.window != nil, host.window != nil, web.window === host.window,
              web === host || web.isDescendant(of: host),
              let window = host.window else {
            resetCanvasAnchor(inst, reason: "web-not-attached")
            return
        }
        guard let object = Self.snapshotObject(json),
              (object["ok"] as? NSNumber)?.intValue == 1,
              (object["owner"] as? NSNumber)?.intValue == inst.token,
              let ready = object["rs"] as? String,
              ready == "interactive" || ready == "complete",
              let viewport = object["vp"] as? [String: Any],
              let canvas = object["cv"] as? [String: Any],
              let innerWidth = Self.finiteDouble(viewport["iw"]), innerWidth > 0,
              let innerHeight = Self.finiteDouble(viewport["ih"]), innerHeight > 0,
              let x = Self.finiteDouble(canvas["x"]),
              let y = Self.finiteDouble(canvas["y"]),
              let width = Self.finiteDouble(canvas["w"]), width > 0,
              let height = Self.finiteDouble(canvas["h"]), height > 0 else {
            resetCanvasAnchor(inst, reason: "geometry-unavailable")
            return
        }
        let scaleX = web.bounds.width / CGFloat(innerWidth)
        let scaleY = web.bounds.height / CGFloat(innerHeight)
        guard scaleX.isFinite, scaleY.isFinite, scaleX > 0, scaleY > 0 else {
            resetCanvasAnchor(inst, reason: "scale-unavailable")
            return
        }
        let canvasInWeb = CGRect(x: CGFloat(x) * scaleX, y: CGFloat(y) * scaleY,
                                 width: CGFloat(width) * scaleX,
                                 height: CGFloat(height) * scaleY)
        let visibleWeb = canvasInWeb.intersection(web.bounds)
        guard !visibleWeb.isNull, visibleWeb.width > 0, visibleWeb.height > 0 else {
            resetCanvasAnchor(inst, reason: "canvas-not-visible")
            return
        }
        let visibleWindow = web.convert(visibleWeb, to: nil).intersection(window.bounds)
        guard !visibleWindow.isNull, visibleWindow.width > 0, visibleWindow.height > 0 else {
            resetCanvasAnchor(inst, reason: "canvas-off-window")
            return
        }
        let visibleHost = host.convert(visibleWindow, from: nil).intersection(host.bounds)
        guard !visibleHost.isNull, visibleHost.width > 0, visibleHost.height > 0 else {
            resetCanvasAnchor(inst, reason: "canvas-off-host")
            return
        }
        let inset = visibleHost.insetBy(dx: 72, dy: 72)
        let top = max(inset.minY, visibleHost.minY + 96)
        let safe = CGRect(x: inset.minX, y: top,
                          width: inset.width, height: inset.maxY - top)
        guard safe.width.isFinite, safe.height.isFinite,
              safe.width >= 200, safe.height >= 160,
              visibleHost.contains(safe) else {
            resetCanvasAnchor(inst, reason: "safe-area-too-small")
            return
        }
        anchor.isHidden = false
        anchor.frame = safe
        anchor.accessibilityValue = "{\"ok\":1}"
    }

    private func resetCanvasAnchor(_ inst: Installation, reason: String) {
        guard let anchor = inst.anchor else { return }
        anchor.isHidden = true
        anchor.frame = .zero
        anchor.accessibilityValue = "{\"ok\":0,\"reason\":\"\(reason)\"}"
    }

    private func attachOverlay(to controller: UIViewController, in inst: Installation) {
        attachCanvasAnchor(to: controller, in: inst)
        let overlay = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        overlay.backgroundColor = .clear
        overlay.isUserInteractionEnabled = false   // cannot intercept any touch
        overlay.autoresizingMask = []              // never participates in layout
        overlay.isAccessibilityElement = true
        overlay.accessibilityIdentifier = Self.snapshotAccessibilityIdentifier
        overlay.accessibilityLabel = Self.snapshotAccessibilityLabel
        overlay.accessibilityTraits = .staticText
        overlay.accessibilityValue = "{\"v\":1,\"ok\":0,\"reason\":\"awaiting-install\"}"
        // Bottom of the host's own view: the engine surface keeps its exact
        // geometry and z-order; the diagnostic marker only adds an AX element.
        controller.view.insertSubview(overlay, at: 0)
        inst.overlay = overlay
        attachInputStateView(to: controller, in: inst)
    }

    /// Creates the fixed native input-state element. Identical diagnostic
    /// shape to the snapshot overlay (1x1pt, clear, non-interactive, no
    /// layout participation, bottom of the host's own view): it can never
    /// intercept a touch, alter document geometry or change focus, and it
    /// exists only under the explicit qualification launch gate.
    private func attachInputStateView(to controller: UIViewController, in inst: Installation) {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false   // cannot intercept any touch
        view.autoresizingMask = []              // never participates in layout
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = Self.inputStateAccessibilityIdentifier
        view.accessibilityLabel = Self.inputStateAccessibilityLabel
        view.accessibilityTraits = .staticText
        view.accessibilityValue = "{\"v\":1,\"ok\":0,\"reason\":\"awaiting-snapshot\",\"po\":\(Self.isPassiveOnly ? 1 : 0)}"
        controller.view.insertSubview(view, at: 0)
        inst.stateView = view
    }

    /// Publishes the fixed native input-state facts on this installation's
    /// own element. All inputs are public UIKit/GameController APIs read on
    /// the main actor; every value is a bool, a fixed enum integer, an
    /// integer count or null. No user content, class name, path, error
    /// description or private API is ever exported.
    private func updateInputState(_ inst: Installation) {
        guard let view = inst.stateView else { return }
        view.accessibilityValue = Self.nativeInputStateJSON(webView: inst.webView,
                                                             controller: inst.controller)
    }

    /// Collects the native fixed facts. Scope is deliberately this
    /// installation's OWN surface only: the hosted WKWebView, the window it
    /// currently lives in and that window's scene. There is no
    /// UIApplication-wide first-responder or connected-scenes scan, no
    /// foreign-window probe, no responder mutation and no keyboard forcing;
    /// absent surfaces report null instead of being guessed.
    static func nativeInputStateJSON(webView web: WKWebView?, controller: UIViewController?) -> String {
        let window = web?.window ?? controller?.viewIfLoaded?.window
        var parts: [String] = ["\"v\":1", "\"ok\":1",
                               "\"po\":\(isPassiveOnly ? 1 : 0)",
                               "\"wt\":\(Int(Date().timeIntervalSince1970 * 1000))",
                               "\"uiAnimationsEnabled\":\(UIView.areAnimationsEnabled ? 1 : 0)"]
        if let window {
            parts.append("\"kw\":\(window.isKeyWindow ? 1 : 0)")
            if let scene = window.windowScene {
                parts.append("\"as\":\(scene.activationState.rawValue)")
                parts.append("\"fa\":\(scene.activationState == .foregroundActive ? 1 : 0)")
            } else {
                parts.append("\"as\":null")
                parts.append("\"fa\":null")
            }
            let walk = firstResponderScan(in: window, web: web)
            parts.append("\"fr\":\(walk.result)")
            parts.append("\"vn\":\(walk.visited)")
            parts.append("\"vc\":\(walk.capped ? 1 : 0)")
        } else {
            parts.append("\"kw\":null")
            parts.append("\"as\":null")
            parts.append("\"fa\":null")
            parts.append("\"fr\":null")
            parts.append("\"vn\":null")
            parts.append("\"vc\":null")
        }
        if let web {
            parts.append("\"wc\":\(web.canBecomeFirstResponder ? 1 : 0)")
            parts.append("\"wf\":\(web.isFirstResponder ? 1 : 0)")
        } else {
            parts.append("\"wc\":null")
            parts.append("\"wf\":null")
        }
        #if canImport(GameController)
        // Public report only: whether the coalesced keyboard service sees a
        // keyboard and an input profile. This is NOT a claim about the
        // Simulator's physical keyboard state, and nothing here observes or
        // changes key input.
        let coalesced = GCKeyboard.coalesced
        parts.append("\"gc\":\(coalesced != nil ? 1 : 0)")
        parts.append("\"gk\":\(coalesced?.keyboardInput != nil ? 1 : 0)")
        #else
        parts.append("\"gc\":null")
        parts.append("\"gk\":null")
        #endif
        return "{" + parts.joined(separator: ",") + "}"
    }

    /// Bounded read-only first-responder walk inside THIS owned window.
    /// Only public properties are read (`subviews`, `isFirstResponder`,
    /// `isDescendant(of:)`); nothing becomes, resigns or reloads anything.
    /// Result: 0 = none found (complete scan), 1 = the WebView itself or a
    /// descendant holds the responder status, 2 = another view in the owned
    /// window, 3 = the node/depth cap was reached before a conclusive
    /// answer (reported honestly via `vc` 1; never silently rounded to 0).
    static func firstResponderScan(in window: UIWindow,
                                   web: WKWebView?) -> (result: Int, visited: Int, capped: Bool) {
        var queue: [(view: UIView, depth: Int)] = [(window, 0)]
        var visited = 0
        while !queue.isEmpty {
            if visited >= responderScanMaxNodes {
                return (3, visited, true)
            }
            let (view, depth) = queue.removeFirst()
            visited += 1
            if view.isFirstResponder {
                if let web, view === web || view.isDescendant(of: web) {
                    return (1, visited, false)
                }
                return (2, visited, false)
            }
            if depth >= responderScanMaxDepth {
                // Deeper content cannot be answered within the cap; stop
                // and report inconclusive instead of guessing "none".
                return (3, visited, true)
            }
            for sub in view.subviews {
                queue.append((sub, depth + 1))
            }
        }
        return (0, visited, false)
    }

    // MARK: - DOM scripts

    /// Installs window-level capture-phase passive observers and resets the
    /// per-diagnostic-session buffers (this install call IS the explicit
    /// session reset: the first-start samples and counters start empty).
    /// `OWNER` is the monotonic Swift installation token: an install that
    /// lost to a newer page owner aborts without touching the newer probe or
    /// registering any listener, and the token is reported back so the later
    /// snapshot and removal can be matched to their owner. Handlers are
    /// passive; they cannot preventDefault or change propagation, and
    /// registration order is untouched relative to the pinned gate (observed
    /// later, which is itself reported: pointer records missing under
    /// drawing ON with touches present proves the gate's pointer-level stop
    /// upstream). The optional on-page pinch marker badge is created only
    /// when the explicit marker argument accompanied the qualification
    /// launch; the badge and its node reference are owned by this
    /// installation and removed by its teardown. `passive` is the explicit
    /// passive-only control: every passive listener, the journals, the
    /// fixed-moment input-state ring and the accessibility publication stay
    /// exactly as in an ordinary qualification run, while NO engine method
    /// is wrapped at all and the trace/moment counters stay honestly zero.
    private static func domInstallScript(owner token: Int, marker: Bool, passive: Bool) -> String {
        #"""
(() => {
  const OWNER = \#(token);
  const MARKER = \#(marker ? 1 : 0);
  // PASSIVE 1 = explicit passive-only control: install the full passive
  // observation surface but NEVER install the bounded call-site wrappers.
  // It is a launch-time constant of this process, mirrored onto P.passive
  // so the page, the snapshot and the runner agree on the mode.
  const PASSIVE = \#(passive ? 1 : 0);
  try {
    const old = window.__floeTouchProbe;
    if (old && typeof old.owner === 'number' && old.owner > OWNER) { return 'probe-stale:' + old.owner; }
    if (old && typeof old.teardown === 'function') { try { old.teardown(); } catch (e) {} }
    const CAP = 128, MAXSTARTS = 16, COORDS = 4, JMAX = 40;
    const P = {
      v: 1,
      gen: (old && typeof old.gen === 'number') ? old.gen + 1 : 1,
      owner: OWNER,
      wall0: Date.now(),
      pn0: performance.now(),
      cnt: {ts: 0, tm: 0, te: 0, tc: 0, pd: 0, pm: 0, pu: 0, pc: 0},
      cntB: {ts: 0, tm: 0, te: 0, tc: 0, pd: 0, pm: 0, pu: 0, pc: 0},
      cntD: {ts: 0, tm: 0, te: 0, tc: 0, pd: 0, pm: 0, pu: 0, pc: 0},
      dr: 0, ns: 0, starts: [], ring: [], handles: [], fl: [],
      jr: [], jns: 0, jdr: 0, jseq: 0, jhandles: [],
      gid: 0, ga: 0, gst: null, lmt: null, gend: null, gc: null,
      gmv: 0, gz0: null, gz0r: null, d0: null, lfin: null,
      ia: null, iaT: 0, iaN: 0,
      cl: [], clN: 0, clD: 0, clS: 0, ctK: 0, ctKc: 0, ctO: 0,
      cw: [], _sci: 0, _scf: 0, ctn: 0,
      passive: PASSIVE, sf: [], sfn: 0, sfd: 0, sfq: 0,
      mk: { g: 0, mv: 0, t: 0, c: 1, n: 0 },
      seq: 0, eseq: null, lmseq: null,
      latest: null, terminal: null, gest: [],
      pending: new Map(), pdrop: 0, ends: {}, endOrder: []
    };
    const R = (x) => (typeof x === 'number' && isFinite(x)) ? Math.round(x * 10) / 10 : null;
    const num4 = (x) => (typeof x === 'number' && isFinite(x)) ? Math.round(x * 10000) / 10000 : null;
    const gnum = (x) => (typeof x === 'number' && isFinite(x)) ? Math.round(x * 1000) / 1000 : null;
    const now = () => Math.round((performance.now() - P.pn0) * 10) / 10;
    const clip = (s, n) => (typeof s === 'string') ? s.slice(0, n) : null;
    const coord = (p) => [R(p && p.clientX), R(p && p.clientY)];
    // Synchronous read-only canvas + layout-viewport geometry for start
    // records. Mirrors the periodic snapshot `cv`/`vp` accessors exactly
    // (sectionContainer.canvas bounding rect, window inner sizes) so the
    // consumer's coordinates stay in matching CSS viewport numbers with the
    // same rounding. Null-safe and mutation-free; DEBUG-only passive path.
    const canvasGeom = (t) => {
      try {
        const c = window.app && window.app.sectionContainer && window.app.sectionContainer.canvas;
        if (!c || typeof c.getBoundingClientRect !== 'function') { return null; }
        const r = c.getBoundingClientRect();
        const g = { t: t, x: gnum(r.left), y: gnum(r.top), w: gnum(r.width), h: gnum(r.height),
                    iw: gnum(window.innerWidth), ih: gnum(window.innerHeight) };
        if (g.x === null || g.y === null || g.w === null || g.h === null ||
            g.iw === null || g.ih === null) { return null; }
        return g;
      } catch (e) { return null; }
    };
    // Optional on-page pinch marker badge (only when the probe session was
    // explicitly launched with the marker argument). One fixed-size,
    // fixed-position node in the same WK frame as the canvas, outside the
    // content flow, pointer-events:none and user-select:none, appended
    // outside the canvas element. Its text carries ONLY the gesture serial,
    // the move counter, the current actual touch count (0/1/2, capped for
    // display) and the frame-closed phase (C = a real after-target sample
    // saw the frame/map commit closed, NOT raster readiness; O otherwise).
    // It never touches engine state (no mutation, no requestReDraw, no
    // synthetic input, no fabricated timestamps or touches) and updates
    // only from the probe's own passive real-event path.
    let markerEl = null;
    const updateMarker = () => {
      if (!MARKER || !markerEl) return;
      try {
        markerEl.textContent = 'FLOE G' + P.mk.g + ' M' + P.mk.mv + ' T' + P.mk.t + ' '
          + (P.mk.c ? 'C' : 'O');
      } catch (e) {}
    };
    if (MARKER) {
      try {
        markerEl = document.createElement('div');
        markerEl.setAttribute('data-floe-pinch-marker', '1');
        markerEl.style.cssText = 'position:fixed;left:8px;bottom:8px;z-index:2147483647;'
          + 'pointer-events:none;user-select:none;background:rgba(0,0,0,0.82);color:#fff;'
          + 'font:700 20px/1.25 -apple-system,monospace;padding:5px 12px;border-radius:8px;';
        (document.body || document.documentElement).appendChild(markerEl);
        P.mk.n = markerEl ? 1 : 0;
      } catch (e) { markerEl = null; }
    }
    // Read only the pinned public/internal accessors already used by the
    // engine's own zoom-frame consumers. No mutation, no dispatch and no
    // layout side effect: an absent getter reports null instead of throwing.
    const zoomState = () => {
      const out = { iz: null, zfs: null, z: null, minz: null, maxz: null };
      try {
        const app = window.app, sc = app && app.sectionContainer, map = app && app.map;
        if (sc && typeof sc.isInZoomAnimation === 'function') {
          try { out.iz = sc.isInZoomAnimation() ? 1 : 0; } catch (e) {}
        }
        if (map) {
          if (typeof map.getZoom === 'function') { try { out.z = num4(map.getZoom()); } catch (e) {} }
          if (typeof map.getMinZoom === 'function') { try { out.minz = num4(map.getMinZoom()); } catch (e) {} }
          if (typeof map.getMaxZoom === 'function') { try { out.maxz = num4(map.getMaxZoom()); } catch (e) {} }
          const layer = map._docLayer;
          const painter = layer && layer._painter;
          if (painter && typeof painter.zoomFrameScale === 'function') {
            try { out.zfs = num4(painter.zoomFrameScale()); } catch (e) {}
          }
        }
      } catch (e) {}
      return out;
    };
    // The actual in-flight anchor, read ONLY from a post-target sample of a
    // trusted two-finger move. Pinned ZoomControl.onMultiTouchStart clears
    // `pinchAnchor`; the first `onMultiTouchMove` target handler creates it;
    // every later move keeps it; the release handler clears it before the
    // touchend bubble listener. A capture-phase start read or the settled
    // periodic snapshot therefore cannot see it. Returns null rather than
    // fabricating coordinates when the section/getter is absent.
    const anchorGeo = () => {
      try {
        const appw = window.app;
        if (!appw) return null;
        const sc = appw.sectionContainer;
        const name = appw.CSections && appw.CSections.ZoomControl
          && appw.CSections.ZoomControl.name;
        const zc = sc && name && typeof sc.getSectionWithName === 'function'
          ? sc.getSectionWithName(name) : null;
        const pa = zc ? zc.pinchAnchor : null;
        if (!pa) return null;
        const px = gnum(pa.x), py = gnum(pa.y);
        if (px === null || py === null) return null;
        return { dpi: gnum(appw.dpiScale), paX: px, paY: py,
                 papX: gnum(pa.pX), papY: gnum(pa.pY),
                 pacX: gnum(pa.cX), pacY: gnum(pa.cY) };
      } catch (e) { return null; }
    };
    // Sampling MUST NOT rely on a capture-handler microtask: HTML can run a
    // microtask checkpoint between event listeners, before the canvas/
    // `ZoomControl` target handler. The primary sample is the event's own
    // window bubble listener, which runs after the target handler. If
    // propagation is stopped before the window bubble, a bounded
    // requestAnimationFrame fallback samples at the render step instead.
    // Every sample records its source (`b` bubble-after-target, `r` render
    // step) and its event's captured gesture serial; delayed samples can
    // never be reinterpreted as live frames of a newer gesture.
    const MAXPENDING = 8;
    const EGA = 8;
    const sample = (entry, src) => {
      const rec = entry.rec, key = entry.key;
      try {
        const st = zoomState();
        const at = now();
        const ownEnd = P.ends[rec.gi];
        const post = (typeof ownEnd === 'number' && at >= ownEnd) ? 1 : 0;
        const stale = (P.gid !== rec.gi) ? 1 : 0;
        const d = (typeof rec.d === 'number' && isFinite(rec.d)) ? rec.d : null;
        // Bounded in-flight anchor capture: at most EGA=8 post-target,
        // pre-end samples per gesture, and only until the first non-null
        // anchor is retained. A null result is counted, never replaced by a
        // fabricated point or by the later cleared state. The record carries
        // its own event/sample times, phase, event key, dispatch sequence,
        // move ordinal, sampling source, gesture serial and owner/generation,
        // so an after-gesture snapshot cannot misattribute it.
        if (!stale && !post && P.ga === 1 && key === 'tm' && rec.tr === 1 &&
            rec.n === 2 && rec.gi === P.gid && P.ia === null && P.iaT < EGA) {
          P.iaT += 1;
          const ag = anchorGeo();
          if (ag) {
            P.ia = { gi: rec.gi, ph: 'm', k: key, t: rec.t, at: at,
                     seq: rec.seq, mv: rec.mv, src: src,
                     og: P.owner, ng: P.gen,
                     dpi: ag.dpi, paN: 1, paX: ag.paX, paY: ag.paY,
                     papX: ag.papX, papY: ag.papY,
                     pacX: ag.pacX, pacY: ag.pacY };
          } else {
            P.iaN += 1;
          }
        }
        // The engine fixes its pinch reference at the first move it actually
        // processes (ZoomControl.onMultiTouchMove latches pinchStartDistance
        // and opens the live zoom frame in that same call). Only a
        // synchronous window-bubble sample of THIS event proves the target
        // handler ran for it; the bounded rAF fallback may observe a later
        // move's state and must never establish the reference. Once set, d0
        // never changes for the gesture (reset only at birth) and is
        // snapshotted into every sample, so every verified consumer of the
        // same gesture reads the identical immutable reference.
        if (src === 'b' && !stale && !post && key === 'tm' && rec.tr === 1 &&
            rec.gi === P.gid && st.iz === 1 && d !== null && P.d0 === null) {
          P.d0 = d;
        }
        const d0 = (typeof P.d0 === 'number' && isFinite(P.d0)) ? P.d0 : null;
        rec.s = { at: at, iz: st.iz, zfs: st.zfs, z: st.z, post: post,
                  stale: stale, src: src, d: d, d0: d0 };
        if (!stale) {
          // Badge phase exclusively from this real after-target read of the
          // engine's frame state: closed (C) only when the frame actually
          // is closed, open (O) otherwise.
          P.mk.c = (st.iz === 0) ? 1 : 0;
          updateMarker();
        }
        // Bounded first-live window: only a trusted move of the current,
        // still-open gesture with a live finite frame scale qualifies. The
        // stored identity/time fields let the consumer reject a late or
        // relabelled sample instead of treating the oldest retained ring
        // record as the gesture start.
        if (!stale && !post && key === 'tm' && rec.tr === 1 &&
            rec.gi === P.gid && st.iz === 1 &&
            typeof st.zfs === 'number' && isFinite(st.zfs) &&
            P.fl.length < 8) {
          P.fl.push({ t: rec.t, at: at, gi: rec.gi, tr: rec.tr,
                      iz: st.iz, zfs: st.zfs, z: st.z,
                      post: post, stale: stale, src: src,
                      d: d, d0: d0, mv: rec.mv });
        }
        // Last input-owned live move, retained independently of the bounded
        // ring and frozen by real dispatch order: the current commit policy is
        // evaluated by the consumer against exactly this sample. Because it
        // advances with every qualifying synchronous bubble move and is
        // never rewritten after the release, a 0.1 ms event-time tie with
        // the terminal end cannot misselect it (the recorded UI2 run
        // contains exactly such a tie).
        if (src === 'b' && !stale && !post && key === 'tm' && rec.tr === 1 &&
            rec.gi === P.gid && st.iz === 1 && d !== null && d > 0 &&
            d0 !== null && d0 > 0 &&
            typeof P.gz0r === 'number' && isFinite(P.gz0r) &&
            typeof st.zfs === 'number' && isFinite(st.zfs)) {
          // Unclamped target of the engine's own formula
          // (DocumentBase.getScaleZoom), carried at full precision so the
          // consumer never rounds a rounded frame scale.
          const rt = P.gz0r + Math.log(d / d0) / Math.log(1.2);
          P.lfin = { gi: rec.gi, t: rec.t, at: at, mv: rec.mv, seq: rec.seq,
                     tr: 1, d: d, d0: d0, z0: P.gz0r,
                     rt: isFinite(rt) ? rt : null,
                     zfs: st.zfs, z: st.z, src: src };
          updateMarker();
        }
        if (!stale) {
          P.latest = { at: at, gi: rec.gi, ph: rec.ph, k: key,
                       iz: st.iz, zfs: st.zfs, z: st.z, post: post,
                       stale: stale, src: src };
        }
        const terminal = key === 'tc' || (key === 'te' && ownEnd === rec.t);
        if (terminal && !stale) {
          const summary = { g: rec.gi, st: P.gst, en: rec.t, mv: P.gmv,
                            z0: P.gz0, ze: st.z, iz: st.iz, zfs: st.zfs,
                            post: post, c: key === 'tc' ? 1 : 0 };
          P.gest.push(summary);
          while (P.gest.length > 4) { P.gest.shift(); }
          // The terminal record remains exactly what the after-target
          // sample observed. The current synchronous contract closes the
          // zoom frame in the release handler, so no post-release observer
          // exists and the marker's closed token can only come from the
          // real sample above; an open frame is rejected by the consumer.
        }
      } catch (e) {
        rec.s = { at: now(), err: 1, stale: (P.gid !== rec.gi) ? 1 : 0, src: src };
      }
    };
    const cancelPending = (entry) => {
      if (entry.raf === null) return;
      try {
        if (entry.kind === 'raf' && typeof window.cancelAnimationFrame === 'function') {
          window.cancelAnimationFrame(entry.raf);
        } else if (typeof clearTimeout === 'function') {
          clearTimeout(entry.raf);
        }
      } catch (e) {}
      entry.raf = null;
    };
    const takePending = (event, src) => {
      const entry = P.pending.get(event);
      if (!entry || entry.done) return;
      entry.done = 1;
      P.pending.delete(event);
      cancelPending(entry);
      sample(entry, src);
    };
    const scheduleSample = (rec, key, event) => {
      if (P.pending.size >= MAXPENDING) { P.pdrop += 1; return; }
      const entry = { rec: rec, key: key, done: 0, raf: null, kind: null };
      P.pending.set(event, entry);
      const run = () => {
        if (entry.done) return;
        entry.done = 1;
        P.pending.delete(event);
        entry.raf = null;
        sample(entry, 'r');
      };
      try {
        if (typeof window.requestAnimationFrame === 'function') {
          entry.kind = 'raf';
          entry.raf = window.requestAnimationFrame(run);
        } else if (typeof setTimeout === 'function') {
          entry.kind = 'timer';
          entry.raf = setTimeout(run, 16);
        } else {
          entry.done = 1;
          P.pending.delete(event);
          P.pdrop += 1;
        }
      } catch (e) {
        entry.done = 1;
        P.pending.delete(event);
        P.pdrop += 1;
      }
    };
    const tgt = (e) => {
      const t = e && e.target;
      let firstCls = null;
      try { firstCls = t && t.className != null ? String(t.className).trim().split(/\s+/)[0] : null; } catch (x) { firstCls = null; }
      return { g: clip(t && t.tagName, 16), i: clip(t && t.id, 32), c: clip(firstCls, 24) };
    };
    // Minimum passive numeric group for the Calc anchor/clamp question:
    // view math primitives (units in the field names) plus the actual
    // ZoomControl pinch anchor. Every read is guarded; nothing is retained.
    const fnum = (v) => (typeof v === 'number' && isFinite(v)) ? Math.round(v * 1000) / 1000 : null;
    const calcGeo = (t) => {
      const out = { t: t, dpi: null,
                    vrx: null, vry: null, vrw: null, vrh: null,
                    vrpX1: null, vrpY1: null, vrpX2: null, vrpY2: null,
                    vrcX1: null, vrcY1: null, vrcX2: null, vrcY2: null,
                    vsx: null, vsy: null, vspX: null, vspY: null, vscX: null, vscY: null,
                    fsx: null, fsy: null, fspX: null, fspY: null, fscX: null, fscY: null,
                    dax: null, day: null, daw: null, dah: null, dapx: null, dapy: null,
                    scx: null, scy: null,
                    paN: 0, paX: null, paY: null, papX: null, papY: null, pacX: null, pacY: null };
      try {
        const appw = window.app;
        if (!appw) return out;
        out.dpi = fnum(appw.dpiScale);
        const doc = appw.activeDocument;
        const layout = doc && doc.activeLayout;
        if (!layout) return out;
        const tryGet = (fn) => { try { return fn(); } catch (e) { return null; } };
        const vr = layout._viewedRectangle;
        if (vr) {
          out.vrx = fnum(tryGet(() => vr.x1)); out.vry = fnum(tryGet(() => vr.y1));
          out.vrw = fnum(tryGet(() => vr.width)); out.vrh = fnum(tryGet(() => vr.height));
          out.vrpX1 = fnum(tryGet(() => vr.pX1)); out.vrpY1 = fnum(tryGet(() => vr.pY1));
          out.vrpX2 = fnum(tryGet(() => vr.pX2)); out.vrpY2 = fnum(tryGet(() => vr.pY2));
          out.vrcX1 = fnum(tryGet(() => vr.cX1)); out.vrcY1 = fnum(tryGet(() => vr.cY1));
          out.vrcX2 = fnum(tryGet(() => vr.cX2)); out.vrcY2 = fnum(tryGet(() => vr.cY2));
        }
        const vs = layout._viewSize;
        if (vs) {
          out.vsx = fnum(tryGet(() => vs.x)); out.vsy = fnum(tryGet(() => vs.y));
          out.vspX = fnum(tryGet(() => vs.pX)); out.vspY = fnum(tryGet(() => vs.pY));
          out.vscX = fnum(tryGet(() => vs.cX)); out.vscY = fnum(tryGet(() => vs.cY));
        }
        const fs = tryGet(() => layout.frameSize);
        if (fs) {
          out.fsx = fnum(tryGet(() => fs.x)); out.fsy = fnum(tryGet(() => fs.y));
          out.fspX = fnum(tryGet(() => fs.pX)); out.fspY = fnum(tryGet(() => fs.pY));
          out.fscX = fnum(tryGet(() => fs.cX)); out.fscY = fnum(tryGet(() => fs.cY));
        }
        const sc = appw.sectionContainer;
        const anchor = sc && typeof sc.getDocumentAnchorSection === 'function'
          ? tryGet(() => sc.getDocumentAnchorSection()) : null;
        if (anchor) {
          out.dax = fnum(tryGet(() => anchor.myTopLeft[0]));
          out.day = fnum(tryGet(() => anchor.myTopLeft[1]));
          out.daw = fnum(tryGet(() => anchor.size[0]));
          out.dah = fnum(tryGet(() => anchor.size[1]));
        }
        const dap = layout._documentAnchorPosition;
        if (dap) { out.dapx = fnum(tryGet(() => dap[0])); out.dapy = fnum(tryGet(() => dap[1])); }
        const sp = layout.scrollProperties;
        if (sp) {
          out.scx = fnum(tryGet(() => sp.viewX)); out.scy = fnum(tryGet(() => sp.viewY));
        }
        const zcName = appw.CSections && appw.CSections.ZoomControl && appw.CSections.ZoomControl.name;
        const zc = sc && zcName && typeof sc.getSectionWithName === 'function'
          ? tryGet(() => sc.getSectionWithName(zcName)) : null;
        const pa = zc ? zc.pinchAnchor : null;
        if (pa) {
          const px = fnum(tryGet(() => pa.x)), py = fnum(tryGet(() => pa.y));
          if (px !== null && py !== null) {
            out.paN = 1; out.paX = px; out.paY = py;
            out.papX = fnum(tryGet(() => pa.pX)); out.papY = fnum(tryGet(() => pa.pY));
            out.pacX = fnum(tryGet(() => pa.cX)); out.pacY = fnum(tryGet(() => pa.cY));
          }
        }
      } catch (e) {}
      return out;
    };
    P.calcGeo = calcGeo;
    // In-flight container facts, sampled synchronously inside the passive
    // capture handler: this is the only chance to see positionOnMouseDown /
    // sectionOnMouseDown / multiTouch / getZoom DURING the gesture, because
    // touchend legitimately resets them before the next periodic snapshot.
    const quickState = (rec) => {
      try {
        const app = window.app, sc = app && app.sectionContainer, map = app && app.map;
        const q = { mt: null, pmd: null, som: null, tei: null, z: null };
        if (sc) {
          if (typeof sc.multiTouch === 'boolean') { q.mt = sc.multiTouch ? 1 : 0; }
          if ('positionOnMouseDown' in sc) { q.pmd = (sc.positionOnMouseDown == null) ? 0 : 1; }
          if ('sectionOnMouseDown' in sc) {
            try {
              q.som = sc.sectionOnMouseDown == null ? null
                : String(sc.sectionOnMouseDown.name == null ? 'anon' : sc.sectionOnMouseDown.name).slice(0, 32);
            } catch (x) { q.som = 'err'; }
          }
          if ('touchEventInProgress' in sc) { q.tei = sc.touchEventInProgress ? 1 : 0; }
        }
        if (map && typeof map.getZoom === 'function') { try { q.z = Math.round(map.getZoom() * 1000) / 1000; } catch (x) {} }
        rec.q = q;
      } catch (x) { rec.q = { err: 1 }; }
    };
    // ------------------------------------------------------------------
    // Fixed call-site instrumentation (DEBUG + explicit launch gate only).
    // Wraps exactly the methods listed in `ctInstall` on THIS document's live
    // instances, fenced by this installation's owner token and page
    // generation. A wrapper always forwards the receiver, every argument and
    // the original return value, and never catches or rewrites an original
    // throw. Records carry only primitive numbers/booleans, fixed internal
    // tags, whitelisted role names and sanitized function names with
    // line/column; source URLs and message bodies are discarded. Recording
    // starts only after the current gesture serial is non-zero and the
    // bounded ring is reset at each gesture birth.
    const CTMAX = 32, CTSTK = 3, CTSTKMAX = 48, CTSTKCRIT = 24;
    const CTROLES = ['textbox', 'searchbox', 'combobox', 'button', 'checkbox',
                     'radio', 'slider', 'spinbutton', 'document', 'application',
                     'group', 'link', 'none'];
    const CTINTERNAL = ['floeCTwrap', 'ctStack', 'ctInstall', 'ctPush', 'moment'];
    const CTNONPROD = ['<anonymous>', 'anonymous', 'eval'];
    // The decisive attribution tags keep a reserved stack budget so a newly
    // retained record still carries its caller after the ring overflowed.
    const CTCRIT = ['mf', 'cfw', 'tif', 'icm', 'cvm', 'ccm', 'ucr', 'uco',
                    'stm', 'sci', 'csc', 'scl'];
    const tri = (v) => (v === undefined || v === null) ? null : (v ? 1 : 0);
    const ctFence = () => {
      try {
        const cur = window.__floeTouchProbe;
        return !!(cur && cur.owner === OWNER && cur.gen === P.gen &&
                  typeof P.gid === 'number' && P.gid > 0);
      } catch (e) { return false; }
    };
    // 2-3 caller frames: a whitelisted identifier-like function name plus
    // line/column only. The captured stack's source URLs/paths are never
    // retained, and frames belonging to this probe's own wrapper/helpers are
    // skipped so the first kept frame is the real product caller.
    const ctStack = () => {
      try {
        const raw = String((new Error()).stack || '');
        const out = [];
        const lines = raw.split('\n');
        for (let i = 0; i < lines.length && out.length < CTSTK; i++) {
          const ln = lines[i];
          if (!ln) continue;
          let name = '', lineNo = 0, colNo = 0, m = null;
          if ((m = ln.match(/^\s*at\s+(.*?)\s*\((.*?):(\d+):(\d+)\)\s*$/))) {
            // V8/WebKit: "at fn (url:line:col)".
            name = m[1]; lineNo = parseInt(m[3], 10); colNo = parseInt(m[4], 10);
          } else if ((m = ln.match(/^\s*at\s+(.*?):(\d+):(\d+)\s*$/))) {
            // V8 bare form: "at url:line:col" (no function name, drop).
            lineNo = parseInt(m[2], 10); colNo = parseInt(m[3], 10);
          } else if ((m = ln.match(/^\s*(.*?)@(.*?):(\d+):(\d+)\s*$/))) {
            // JavaScriptCore/WebKit: "fn@url:line:col" or "@url:line:col".
            name = m[1]; lineNo = parseInt(m[3], 10); colNo = parseInt(m[4], 10);
          } else continue;
          name = String(name || '').trim();
          if (!/^[A-Za-z0-9_$.#<>\[\]-]{1,40}$/.test(name)) continue;
          // Skip this probe's own frames even when the engine prefixes the
          // receiver type (for example "Object.floeCTwrap").
          const seg = name.slice(name.lastIndexOf('.') + 1);
          if (CTINTERNAL.indexOf(seg) >= 0) continue;
          if (CTNONPROD.indexOf(name) >= 0) continue;
          if (!(lineNo > 0) || !(colNo > 0)) continue;
          out.push([name, lineNo, colNo]);
        }
        return out.length ? out : null;
      } catch (e) { return null; }
    };
    // Read-only Calc/entry flag group: viewed-rectangle origin, text-cursor
    // and cell-cursor visibility, and whether the Calc input bar has focus.
    // Both are the exact branch inputs of the traced decision points; no
    // layout write, redraw or focus change is triggered.
    const ctFlags = () => {
      const out = { vx: null, vy: null, ccv: null, tcv: null, cib: null };
      try {
        const a = window.app;
        const layout = a && a.activeDocument && a.activeDocument.activeLayout;
        const vr = layout && layout._viewedRectangle;
        if (vr) { out.vx = gnum(vr.x1); out.vy = gnum(vr.y1); }
        const tc = a && a.file && a.file.textCursor;
        out.tcv = tc ? (tc.visible ? 1 : 0) : null;
        const calc = a && a.calc;
        out.ccv = calc ? (calc.cellCursorVisible ? 1 : 0) : null;
        const map = a && a.map;
        if (map && typeof map.calcInputBarHasFocus === 'function') {
          out.cib = map.calcInputBarHasFocus() ? 1 : 0;
        }
      } catch (e) {}
      return out;
    };
    const ctNdrFlags = () => {
      const out = { sm: null, tb: null, dl: null, hv: null, ccv: null, cib: null };
      try {
        const md = window.mode;
        if (md && typeof md.isSmallScreenDevice === 'function') out.sm = md.isSmallScreenDevice() ? 1 : 0;
        if (md && typeof md.isTablet === 'function') out.tb = md.isTablet() ? 1 : 0;
        const a = window.app, map = a && a.map, layer = map && map._docLayer;
        out.dl = (map && typeof map._docLoaded !== 'undefined') ? (map._docLoaded ? 1 : 0) : null;
        try {
          const tc = a.file.textCursor;
          const marker = layer && layer._cursorMarker;
          out.hv = (tc && tc.visible && marker &&
                    typeof marker.isDomAttached === 'function' && marker.isDomAttached()) ? 1 : 0;
        } catch (e) {}
        const calc = a && a.calc;
        out.ccv = calc ? (calc.cellCursorVisible ? 1 : 0) : null;
        if (map && typeof map.calcInputBarHasFocus === 'function') out.cib = map.calcInputBarHasFocus() ? 1 : 0;
      } catch (e) {}
      return out;
    };
    const ctMbrFlags = () => {
      const out = { sm: null, bg: null };
      try {
        const md = window.mode;
        if (md && typeof md.isSmallScreenDevice === 'function') out.sm = md.isSmallScreenDevice() ? 1 : 0;
        out.bg = (document.activeElement === document.body) ? 1 : 0;
      } catch (e) {}
      return out;
    };
    const ctFramePY = () => {
      try {
        const a = window.app;
        const layout = a && a.activeDocument && a.activeDocument.activeLayout;
        const fs = layout && layout.frameSize;
        return fs ? gnum(fs.pY) : null;
      } catch (e) { return null; }
    };
    // Whitelisted role token of the active element. Only the fixed list above
    // may be exported; any other/missing role is null.
    const ctRole = (el) => {
      try {
        if (!el || typeof el.getAttribute !== 'function') return null;
        const r = el.getAttribute('role');
        if (typeof r !== 'string') return null;
        const low = r.toLowerCase();
        return CTROLES.indexOf(low) >= 0 ? low : null;
      } catch (e) { return null; }
    };
    // Focus attribution at one real moment: clipped active-element tag/id, a
    // whitelisted role constant and editorHasFocus() as a primitive. No text,
    // selection, caret, URL or metadata is read.
    const ctFocusFacts = () => {
      const out = { a: null, d: null, r: null, f: null };
      try {
        const el = document.activeElement;
        if (el) {
          out.a = clip(el.tagName, 16);
          out.d = clip(el.id, 32);
          out.r = ctRole(el);
        }
      } catch (e) {}
      try {
        const map = window.app && window.app.map;
        if (map && typeof map.editorHasFocus === 'function') out.f = map.editorHasFocus() ? 1 : 0;
      } catch (e) {}
      return out;
    };
    // ------------------------------------------------------------------
    // FIXED DOM INPUT-STATE FACTS (public read-only properties only).
    // Every exported value is a 0/1 boolean, a FIXED enum integer or null.
    // Nothing here reads document text, selection, caret, HTML, URLs or
    // attribute values beyond the whitelisted contenteditable token
    // mapping; nothing writes focus, selection, attributes or state. Each
    // accessor lives in its own try so an absent engine object reports
    // null (unknown) instead of throwing or guessing.
    //   ae:  active element: 0 none/body/html, 1 textarea, 2 input, 3 other
    //   ta:  1/0 identity match against the TextInput's own activeElement()
    //        (the editor textarea/contenteditable); null when unavailable
    //   ce:  contenteditable ATTRIBUTE enum: 0 absent (inherit), 1 'true'
    //        (including the empty-string synonym), 2 'false',
    //        3 'plaintext-only', 4 other token; null without an element
    //   cev: computed el.isContentEditable (0/1); null when absent
    //   ro:  el.readOnly where the property exists; di: el.disabled likewise
    //   em:  map.isEditMode() (0/1); ai: TextInput intent flag _acceptInput
    //        ONLY when it is a real boolean; ef: map.editorHasFocus()
    //   hf:  document.hasFocus(); ui/ub: navigator.userActivation
    //        isActive/hasBeenActive, null when the API is absent
    const inputFacts = () => {
      const out = { ae: null, ta: null, ce: null, cev: null, ro: null, di: null,
                    em: null, ai: null, ef: null, hf: null, ui: null, ub: null };
      try {
        const el = document.activeElement;
        if (el && typeof el.tagName === 'string') {
          const tag = String(el.tagName).toUpperCase();
          out.ae = (tag === 'BODY' || tag === 'HTML') ? 0
            : (tag === 'TEXTAREA' ? 1 : (tag === 'INPUT' ? 2 : 3));
          try {
            const attr = (typeof el.getAttribute === 'function') ? el.getAttribute('contenteditable') : null;
            if (attr === null || attr === undefined) { out.ce = 0; }
            else {
              const tok = String(attr).toLowerCase();
              out.ce = (tok === '' || tok === 'true') ? 1
                : (tok === 'false') ? 2 : (tok === 'plaintext-only') ? 3 : 4;
            }
          } catch (x) { out.ce = null; }
          try { if (typeof el.isContentEditable === 'boolean') out.cev = el.isContentEditable ? 1 : 0; } catch (x) {}
          try { if ('readOnly' in el) out.ro = el.readOnly ? 1 : 0; } catch (x) {}
          try { if ('disabled' in el) out.di = el.disabled ? 1 : 0; } catch (x) {}
          try {
            const map = window.app && window.app.map;
            const ti = map && map._textInput;
            if (ti && typeof ti.activeElement === 'function') {
              const target = ti.activeElement();
              if (target) out.ta = (el === target) ? 1 : 0;
            }
          } catch (x) {}
        } else {
          out.ae = 0;
        }
        const map = window.app && window.app.map;
        if (map) {
          try { if (typeof map.isEditMode === 'function') out.em = map.isEditMode() ? 1 : 0; } catch (x) {}
          try { if (typeof map.editorHasFocus === 'function') out.ef = map.editorHasFocus() ? 1 : 0; } catch (x) {}
          try {
            const ti = map._textInput;
            if (ti && typeof ti._acceptInput === 'boolean') out.ai = ti._acceptInput ? 1 : 0;
          } catch (x) {}
        }
        try { out.hf = document.hasFocus() ? 1 : 0; } catch (x) {}
        try {
          const ua = navigator.userActivation;
          if (ua) {
            if (typeof ua.isActive === 'boolean') out.ui = ua.isActive ? 1 : 0;
            if (typeof ua.hasBeenActive === 'boolean') out.ub = ua.hasBeenActive ? 1 : 0;
          }
        } catch (x) {}
      } catch (e) {}
      return out;
    };
    P.inputFacts = inputFacts;
    // Bounded fixed-MOMENT state ring, fed by the SAME passive listeners
    // that already produce the terminal touchend, trusted-click and focus-in
    // moments. It is independent of the call-site instrumentation (it keeps
    // working under the passive-only control), owns NO new listener (so no
    // new teardown surface), never evicts the first MAXSF entries (honest
    // `sfd` drop counter mirrors the journal), and carries only fixed
    // numeric fields plus the `is` group above.
    const MAXSF = 8;
    const sfPush = (m, tr) => {
      try {
        const cur = window.__floeTouchProbe;
        if (!cur || cur.owner !== OWNER || cur.gen !== P.gen) return;
        P.sfn += 1;
        if (P.sf.length >= MAXSF) { P.sfd += 1; return; }
        P.sf.push({ m: m, tr: tr, t: now(), q: (P.sfq += 1), is: inputFacts() });
      } catch (e) {}
    };
    // ------------------------------------------------------------------
    const ctPush = (rec) => {
      try {
        P.clN += 1;
        // Newest-kept bounded ring: once full, the oldest record is dropped
        // (counted in `clD`) so the post-end focus/scroll window — which is
        // the evidence this instrumentation exists for — is never crowded
        // out by earlier calls of the same gesture.
        if (P.cl.length >= CTMAX) { P.cl.shift(); P.clD += 1; }
        P.clS += 1;
        rec.q = P.clS;
        P.cl.push(rec);
      } catch (e) {}
    };
    // Moment entry for the raw end-touch, a trusted click and a focusin. It
    // shares the trace ring's bound/ordinal/drop accounting with the call
    // entries so one honest counter set covers the whole gesture window.
    const moment = (m) => {
      try {
        // Moment entries belong to the call-site instrumentation ring and
        // are disabled together with it under the passive-only control.
        // The fixed-moment state facts keep flowing through sfPush.
        if (PASSIVE) return;
        if (!ctFence()) return;
        const ff = ctFocusFacts();
        ctPush({ k: 'fx', m: m, t: now(), gi: P.gid,
                 a: ff.a, d: ff.d, r: ff.r, f: ff.f });
      } catch (e) {}
    };
    // Bounded per-gesture stack budget. Every attempt consumes a slot; the
    // reserved critical slots are only reachable once the general budget is
    // spent, so post-overflow focus/cursor-scroll records stay attributable.
    const ctStackBudget = (tag) => {
      if (P.ctK < CTSTKMAX) { P.ctK += 1; return true; }
      if (CTCRIT.indexOf(tag) >= 0 && P.ctKc < CTSTKCRIT) { P.ctKc += 1; return true; }
      return false;
    };
    // Idempotent per (instance, method). `enter` returns the record's extra
    // fixed-schema fields, or `false` to skip this call (used by the scroll
    // writer unless it is nested in _scrollCellCursorIntoView). `exit` may
    // only add primitive fields to the already-pushed record.
    const ctWrap = (obj, key, tag, enter, exit) => {
      try {
        if (!obj || typeof obj[key] !== 'function') return false;
        const cur = obj[key];
        if (cur.__floeCT && cur.__floeCT.o === OWNER) return true;
        if (!P.cw) P.cw = [];
        if (P.cw.length >= 64) return false;
        const hadOwn = Object.prototype.hasOwnProperty.call(obj, key);
        const orig = cur;
        const wrapped = function floeCTwrap() {
          let rec = null;
          try {
            if (ctFence()) {
              // A schema/stack problem may degrade the optional fields but
              // must never drop the record itself.
              let extra = {};
              try { extra = (typeof enter === 'function') ? enter(arguments) : {}; }
              catch (e) { extra = {}; }
              if (extra !== false) {
                rec = { k: tag, t: now(), gi: P.gid };
                if (extra) {
                  try {
                    for (const kk in extra) {
                      if (Object.prototype.hasOwnProperty.call(extra, kk)) rec[kk] = extra[kk];
                    }
                  } catch (e) {}
                }
                // Stack capture is bounded per gesture: CTSTKMAX attempts
                // for any record, plus CTSTKCRIT reserved for the decisive
                // focus/cursor/scroll tags, so a newly retained critical
                // record still gets its product caller after ring overflow.
                try {
                  if (ctStackBudget(tag)) {
                    const st = ctStack();
                    if (st) { rec.sk = st; } else { P.ctO += 1; }
                  } else {
                    P.ctO += 1;
                  }
                } catch (e) { P.ctO += 1; }
              }
            }
          } catch (e) {}
          if (rec) ctPush(rec);
          if (tag === 'sci') {
            P._sci += 1;
            P._scf = 0;
            try {
              return orig.apply(this, arguments);
            } finally {
              P._sci -= 1;
              try { if (rec && typeof exit === 'function') exit(rec); } catch (e) {}
            }
          }
          const out = orig.apply(this, arguments);
          try { if (rec && typeof exit === 'function') exit(rec, out); } catch (e) {}
          return out;
        };
        wrapped.__floeCT = { o: OWNER, g: P.gen, orig: orig };
        obj[key] = wrapped;
        P.cw.push([obj, key, orig, hadOwn]);
        return true;
      } catch (e) { return false; }
    };
    const ctInstall = () => {
      // Passive-only control: NO method is ever wrapped in this mode, the
      // wrapper table stays empty (so teardown/new-owner have nothing stale
      // to keep), and the exported call-site counters stay honestly zero.
      if (PASSIVE) { P.ctn = 0; return 0; }
      let n = 0;
      try {
        const cur = window.__floeTouchProbe;
        if (!cur || cur.owner !== OWNER || cur.gen !== P.gen) return 0;
        const a = window.app, map = a && a.map;
        if (!map) return 0;
        if (ctWrap(map, 'focus', 'mf',
                   (args) => ({ a: tri(args[0]) }))) n++;
        if (ctWrap(map, '_changeFocusWidget', 'cfw',
                   (args) => ({ a: [args[0] ? 1 : 0,
                     (typeof args[1] === 'number' && isFinite(args[1])) ? Math.round(args[1]) : null,
                     tri(args[2])] }))) n++;
        if (ctWrap(map._textInput, 'focus', 'tif',
                   (args) => ({ a: tri(args[0]) }))) n++;
        const layer = map._docLayer;
        if (layer) {
          if (ctWrap(layer, '_onInvalidateCursorMsg', 'icm',
                     () => ({ tp: 'invalidatecursor' }))) n++;
          if (ctWrap(layer, '_onCursorVisibleMsg', 'cvm',
                     () => ({ tp: 'cursorvisible' }))) n++;
          if (ctWrap(layer, '_onCellCursorMsg', 'ccm',
                     () => ({ tp: 'cellcursor' }))) n++;
          if (ctWrap(layer, '_onUpdateCursor', 'ucr',
                     (args) => ({ a: [tri(args[0]), tri(args[1]), tri(args[2])],
                                  g: ctFlags() }))) n++;
          if (ctWrap(layer, '_updateCursorAndOverlay', 'uco',
                     () => ({ g: ctFlags() }))) n++;
          if (ctWrap(layer, '_onStatusMsg', 'stm',
                     () => ({ g: ctFlags() }))) n++;
          if (ctWrap(layer, '_syncTileContainerSize', 'syn',
                     () => ({ g: ctFlags(), fp: ctFramePY() }),
                     (rec) => {
                       const py = ctFramePY();
                       rec.hi = (rec.fp !== null && py !== null) ? ((rec.fp < py) ? 1 : 0) : null;
                     })) n++;
          if (ctWrap(layer, '_mobileChecksAfterResizeEvent', 'mbr',
                     (args) => ({ a: tri(args[0]), g: ctMbrFlags() }))) n++;
          if (ctWrap(layer, '_nonDesktopChecksAfterResizeEvent', 'ndr',
                     (args) => ({ a: tri(args[0]), g: ctNdrFlags() }))) n++;
          if (ctWrap(layer, '_scrollCellCursorIntoView', 'sci',
                     () => ({ g: ctFlags() }),
                     (rec) => {
                       rec.sc = P._scf ? 1 : 0;
                       rec.ex = now();
                       const g2 = ctFlags();
                       rec.exg = { vx: g2.vx, vy: g2.vy };
                     })) n++;
          if (ctWrap(layer, '_calculateScrollForNewCellCursor', 'csc',
                     () => ({}),
                     (rec, out) => {
                       rec.ex = now();
                       rec.d = (out && typeof out.x === 'number' && typeof out.y === 'number')
                         ? [gnum(out.x), gnum(out.y)] : null;
                     })) n++;
        }
        const layout = a && a.activeDocument && a.activeDocument.activeLayout;
        if (layout) {
          if (ctWrap(layout, 'scrollTo', 'scl',
                     (args) => {
                       // Only the exact writer invoked from the traced cursor
                       // scroll path; every unrelated scroll is untraced.
                       if (P._sci <= 0) return false;
                       P._scf = 1;
                       return { a: [(typeof args[0] === 'number' && isFinite(args[0])) ? gnum(args[0]) : null,
                                    (typeof args[1] === 'number' && isFinite(args[1])) ? gnum(args[1]) : null,
                                    tri(args[2])] };
                     })) n++;
        }
      } catch (e) { n = -1; }
      P.ctn = n;
      return n;
    };
    P.ctInstall = ctInstall;
    const record = (key, e) => {
      try {
        const touch = key.charAt(0) === 't';
        const rec = { k: key, t: Math.round((performance.now() - P.pn0) * 10) / 10,
                      tr: e.isTrusted ? 1 : 0, dp: e.defaultPrevented ? 1 : 0 };
        // Monotonic passive dispatch sequence: every record (touch and
        // pointer) advances it exactly once in the probe's own capture
        // order, so "the last owned move before the release" is proven by
        // sequence, never by rounded timestamps (0.1 ms ties included).
        P.seq += 1;
        rec.seq = P.seq;
        if (touch) {
          rec.n = e.touches ? e.touches.length : null;
          rec.c = e.changedTouches ? e.changedTouches.length : null;
          const pts = [];
          if (e.changedTouches) {
            const m = Math.min(e.changedTouches.length, COORDS);
            for (let j = 0; j < m; j++) { pts.push(coord(e.changedTouches[j])); }
          }
          rec.o = pts;
          // Passive finger distance for the input-correlated live-frame and
          // commit evidence: the pinned container's own formula
          // (CanvasSectionContainer.onTouchMove:
          // Math.sqrt(Math.pow(diffX,2)+Math.pow(diffY,2)) of the absolute
          // client deltas of the two active touches) evaluated on THIS
          // event's own touch list in the capture phase. Touch lists are
          // immutable during dispatch, so the engine's target handler
          // computes the bit-identical double for the same event. Recorded
          // RAW (no num4): the acceptance needs no quantization bound
          // across the fixture reference distances because the recorded
          // value carries no distance quantization at all. touchmove only;
          // the live-frame contract never needs it elsewhere.
          rec.d = null;
          if (key === 'tm' && e.touches && e.touches.length === 2) {
            try {
              const ddx = Math.abs(e.touches[0].clientX - e.touches[1].clientX);
              const ddy = Math.abs(e.touches[0].clientY - e.touches[1].clientY);
              const dist = Math.sqrt(Math.pow(ddx, 2) + Math.pow(ddy, 2));
              rec.d = (isFinite(dist) && dist > 0) ? dist : null;
            } catch (x) { rec.d = null; }
          }
        } else {
          rec.p = e.pointerType || null;
          rec.pi = (typeof e.pointerId === 'number') ? e.pointerId : null;
          rec.o = [coord(e)];
        }
        rec.g = tgt(e);
        // Gesture identity is bound to single- versus two-finger birth:
        // increments only when no touch gesture is active, so a second
        // touchstart of the same pinch and a sequential two-finger start keep
        // one serial. A batched two-finger touchstart (touches=2) also starts
        // a gesture, matching the observed real UIKit birth.
        if (key === 'ts' && !P.ga) {
          P.gid += 1;
          P.ga = 1;
          P.gst = rec.t;
          P.gend = null;
          P.gc = null;
          P.lmt = null;
          P.gmv = 0;
          P.gz0 = null;
          P.gz0r = null;
          P.eseq = null;
          P.lmseq = null;
          P.d0 = null;
          P.lfin = null;
          P.latest = null;
          P.fl = [];
          P.terminal = null;
          P.ia = null;
          P.iaT = 0;
          P.iaN = 0;
          // Per-gesture trace reset: the bounded call/moment ring never
          // carries the previous gesture or any startup/page-load calls.
          P.cl = [];
          P.clN = 0;
          P.clD = 0;
          P.clS = 0;
          P.ctK = 0;
          P.ctKc = 0;
          P.ctO = 0;
          P._sci = 0;
          P._scf = 0;
          try {
            const m = window.app && window.app.map;
            P.gz0 = m && typeof m.getZoom === 'function' ? num4(m.getZoom()) : null;
            P.gz0r = m && typeof m.getZoom === 'function' ? m.getZoom() : null;
          } catch (x) {}
        }
        if ((key === 'te' && P.ga && e.touches && e.touches.length === 0) ||
            (key === 'tc' && P.ga)) {
          P.ga = 0;
          P.gend = rec.t;
          if (key === 'tc') { P.gc = rec.t; }
          // The one record that actually ended the gesture. The cache holds
          // the same object reference, so its own post-target sample remains
          // attached; a duplicate touches=0 end never enters this branch and
          // therefore never becomes terminal.
          rec.term = 1;
          P.terminal = rec;
          P.eseq = rec.seq;
          // Raw end-touch focus attribution: active element + editor focus at
          // the real terminal event, independent of any later poll.
          moment(key);
          // Fixed DOM input-state facts at the same real moment; unlike the
          // moment entry above this survives the passive-only control.
          sfPush('te', rec.tr);
          // Per-gesture end time: a delayed rAF sample is judged against its
          // own gesture, never against a newer gesture's global end/reset.
          P.ends[P.gid] = rec.t;
          P.endOrder.push(P.gid);
          while (P.endOrder.length > 4) {
            const oldGid = P.endOrder.shift();
            delete P.ends[oldGid];
          }
        }
        if (key === 'tm' && P.ga) {
          P.gmv += 1;
          P.lmt = rec.t;
          rec.mv = P.gmv;
          // Only a trusted two-touch move is pinch input: a one-finger move
          // (for example one finger lifted mid-gesture) never updates the
          // engine's target and must not masquerade as the commit input's
          // last sequence. gmv/mv still count every real move for the
          // badge; the commit-input sequence tracks only engine input.
          if (rec.tr === 1 && e.touches && e.touches.length === 2) {
            P.lmseq = rec.seq;
          }
        }
        rec.gi = P.gid;
        rec.ph = (key === 'ts' || key === 'pd') ? 's'
          : (key === 'tm' || key === 'pm') ? 'm'
          : (key === 'te' || key === 'pu') ? 'e' : 'c';
        if (key === 'ts' || key === 'tm' || key === 'pd') { quickState(rec); }
        // Event-time canvas geometry: read synchronously inside THIS passive
        // capture dispatch and bound to this record. The start coordinates
        // in `rec.o` are CSS-viewport numbers for the same dispatch, so a
        // consumer can prove target containment against `rec.cg` alone and
        // must never rebind them to a later `cv`. A failed read stays null
        // so the consumer fails closed instead of guessing.
        if (key === 'ts' || key === 'pd') {
          rec.cg = canvasGeom(rec.t);
          rec.eg = calcGeo(rec.t);
        }
        if (touch) {
          // The badge mirrors only this probe's own real-event ownership
          // state at the moment the real event arrived: gesture serial,
          // move counter and the CURRENT actual touch count (0/1/2; the
          // badge display caps at 2). No time, zoom, document text or
          // synthesized input is shown or implied.
          P.mk.g = P.gid;
          P.mk.mv = P.gmv;
          P.mk.t = e.touches ? Math.min(2, e.touches.length) : 0;
          updateMarker();
        }
        P.cnt[key] = (P.cnt[key] || 0) + 1;
        if (key === 'ts' || key === 'pd') {
          P.ns += 1;
          if (P.starts.length < MAXSTARTS) { P.starts.push(rec); }
        }
        if (P.ring.length >= CAP) { P.ring.shift(); P.dr += 1; }
        P.ring.push(rec);
        // The after-target/fallback sample is only needed for the trusted
        // touch pipeline; adding it to pointer records would spend
        // ring/transfer budget without changing the live-frame contract.
        if (touch) { scheduleSample(rec, key, e); }
      } catch (x) {}
    };
    const types = { touchstart: 'ts', touchmove: 'tm', touchend: 'te', touchcancel: 'tc',
                    pointerdown: 'pd', pointermove: 'pm', pointerup: 'pu', pointercancel: 'pc' };
    for (const name in types) {
      const key = types[name];
      const cap = (e) => { record(key, e); };
      const bub = (e) => {
        try {
          P.cntB[key] = (P.cntB[key] || 0) + 1;
          if (e.defaultPrevented) { P.cntD[key] = (P.cntD[key] || 0) + 1; }
          // Window bubble runs after the target/`ZoomControl` handler. This
          // is the primary post-target sample; a stopped-propagation event
          // stays pending for the bounded rAF fallback.
          takePending(e, 'b');
        } catch (x) {}
      };
      window.addEventListener(name, cap, { capture: true, passive: true });
      window.addEventListener(name, bub, { capture: false, passive: true });
      P.handles.push([name, cap, true], [name, bub, false]);
    }
    // Bounded passive focus/resize journal. Capture-phase, `passive: true`
    // listeners only: they cannot preventDefault, cannot reorder product
    // handlers relative to each other and cannot touch focus or layout.
    // Entries carry internal tags, rounded numeric geometry and the probe's
    // own monotonic ordinal/time. Never evicted: past JMAX the oldest
    // entries are kept and later ones are counted in `jdr` (an honest drop
    // counter mirroring the first-start window), so a consumer can always
    // see the FIRST resize/focus transition of the session.
    const journal = (k, extra) => {
      try {
        P.jns += 1;
        if (P.jr.length >= JMAX) { P.jdr += 1; return; }
        const e = { k: k, t: now(), j: (P.jseq += 1) };
        if (extra) { try { for (const key in extra) { e[key] = extra[key]; } } catch (x) {} }
        P.jr.push(e);
      } catch (x) {}
    };
    const jgeom = () => {
      const out = { ih: gnum(window.innerHeight), iw: gnum(window.innerWidth), cvh: null,
                    dpi: null, vrpX1: null, vrpY1: null, vrpX2: null, vrpY2: null,
                    vspX: null, vspY: null, scx: null, scy: null };
      try {
        const appw = window.app;
        const c = appw && appw.sectionContainer && appw.sectionContainer.canvas;
        if (c && typeof c.getBoundingClientRect === 'function') {
          out.cvh = gnum(c.getBoundingClientRect().height);
        }
        if (appw) {
          out.dpi = gnum(appw.dpiScale);
          const layout = appw.activeDocument && appw.activeDocument.activeLayout;
          const vr = layout && layout._viewedRectangle;
          if (vr) {
            out.vrpX1 = gnum(vr.pX1); out.vrpY1 = gnum(vr.pY1);
            out.vrpX2 = gnum(vr.pX2); out.vrpY2 = gnum(vr.pY2);
          }
          const vs = layout && layout._viewSize;
          if (vs) { out.vspX = gnum(vs.pX); out.vspY = gnum(vs.pY); }
          const sp = layout && layout.scrollProperties;
          if (sp) { out.scx = gnum(sp.viewX); out.scy = gnum(sp.viewY); }
        }
      } catch (e) {}
      return out;
    };
    {
      const hResize = () => { journal('wr', jgeom()); };
      window.addEventListener('resize', hResize, { capture: true, passive: true });
      P.jhandles.push([window, 'resize', hResize, true]);
      const mkFocus = (key) => (e) => {
        const t = e && e.target;
        journal(key, { g: clip(t && t.tagName, 16), i: clip(t && t.id, 32) });
        // Focus-in moment: active element and editor focus right after the
        // real focus transition (focusout keeps only the journal entry).
        // The sf push carries the fixed DOM input-state facts and stays
        // active even under the passive-only control.
        if (key === 'fi') { moment('fi'); sfPush('fi', (e && e.isTrusted) ? 1 : 0); }
      };
      const hFi = mkFocus('fi');
      const hFo = mkFocus('fo');
      window.addEventListener('focusin', hFi, { capture: true, passive: true });
      window.addEventListener('focusout', hFo, { capture: true, passive: true });
      P.jhandles.push([window, 'focusin', hFi, true], [window, 'focusout', hFo, true]);
      // Capture-only passive click/dblclick journal: WebKit may synthesize a
      // mouse click even when the probe saw no DOM pointer events, and the
      // documented iOS focus path in pinned Map.js is an actual click/dblclick
      // in edit mode. Entries carry only isTrusted, clipped target tag/id and
      // finite rounded client coordinates; no text, selection, focus call,
      // preventDefault or propagation change. Reuses the same JMAX/drop/
      // teardown ownership as every other journal entry.
      const mkClick = (key) => (e) => {
        journal(key, { tr: (e && e.isTrusted) ? 1 : 0,
                       g: clip(e && e.target && e.target.tagName, 16),
                       i: clip(e && e.target && e.target.id, 32),
                       x: gnum(e && e.clientX), y: gnum(e && e.clientY) });
        // Trusted click moment: what actually held focus when the click the
        // engine documents as its focus trigger arrived. The sf push again
        // carries the fixed input-state facts under every launch mode.
        if (key === 'ck') { moment('ck'); sfPush('ck', (e && e.isTrusted) ? 1 : 0); }
      };
      const hCk = mkClick('ck');
      const hDc = mkClick('dc');
      window.addEventListener('click', hCk, { capture: true, passive: true });
      window.addEventListener('dblclick', hDc, { capture: true, passive: true });
      P.jhandles.push([window, 'click', hCk, true], [window, 'dblclick', hDc, true]);
      if (window.visualViewport && typeof window.visualViewport.addEventListener === 'function') {
        const vv = window.visualViewport;
        const hVr = () => {
          journal('vr', { vh: gnum(vv.height), vw: gnum(vv.width), vs: gnum(vv.scale) });
        };
        vv.addEventListener('resize', hVr, { capture: true, passive: true });
        P.jhandles.push([vv, 'resize', hVr, true]);
      }
    }
    P.teardown = () => {
      // Restore only product methods still carrying THIS installation's
      // wrapper marker. A newer owner's wrapper is left untouched, and an
      // inherited method is restored by deleting the own property this
      // installation created.
      try {
        for (const w of P.cw) {
          try {
            const obj = w[0], key = w[1], orig = w[2], hadOwn = w[3];
            if (obj && obj[key] && obj[key].__floeCT && obj[key].__floeCT.o === OWNER) {
              if (hadOwn) { obj[key] = orig; } else { delete obj[key]; }
            }
          } catch (e) {}
        }
      } catch (e) {}
      try { P.cw.length = 0; } catch (e) {}
      for (const h of P.handles) {
        try { window.removeEventListener(h[0], h[1], { capture: h[2] }); } catch (e) {}
      }
      P.handles.length = 0;
      for (const h of P.jhandles) {
        try { h[0].removeEventListener(h[1], h[2], { capture: h[3] }); } catch (e) {}
      }
      P.jhandles.length = 0;
      // The badge node is owned by this installation and removed on
      // teardown; no DOM residue can outlive the session. A newer install
      // has already torn this probe down before re-creating its own state.
      if (markerEl && markerEl.parentNode) {
        try { markerEl.parentNode.removeChild(markerEl); } catch (e) {}
      }
      markerEl = null;
      try {
        for (const entry of P.pending.values()) {
          entry.done = 1;
          cancelPending(entry);
        }
      } catch (e) {}
      try { P.pending.clear(); } catch (e) {}
      try { delete window.__floeTouchProbe; } catch (e) { window.__floeTouchProbe = undefined; }
    };
    window.__floeTouchProbe = P;
    // Best-effort first wrap pass; the snapshot poll retries idempotently
    // until the live instances/methods exist.
    try { P.ctInstall(); } catch (e) {}
    return 'probe-ok:' + P.gen + ':' + P.owner;
  } catch (e) {
    return 'probe-fail';
  }
})()
"""#
    }

    /// Builds one compact snapshot string. Reads engine/global state through
    /// the same accessors the pinned gate already uses
    /// (window.app.map / window.app.sectionContainer / __floeOfficePenState),
    /// guarded so an unavailable field reports null instead of throwing.
    /// The value is STRUCTURALLY bounded here: if the serialized payload
    /// would exceed the transfer budget, the oldest ring records are withheld
    /// for this transfer (counted in `rtv`) and re-bounded, while the
    /// first-start window is always kept whole; the in-page ring itself is
    /// never mutated by a transfer.
    private static let domSnapshotScript = #"""
(() => {
  const P = window.__floeTouchProbe;
  if (!P) { return JSON.stringify({ v: 1, ok: 0, reason: 'not-installed' }); }
  // Existing snapshot polling also completes the fixed call-site wrapping
  // once the map/section/layout instances and their methods exist. The wrap
  // pass is idempotent and records nothing itself.
  if (typeof P.ctInstall === 'function') { try { P.ctInstall(); } catch (e) {} }
  const MAX = 42000;
  try {
    const num = (x) => (typeof x === 'number' && isFinite(x)) ? Math.round(x * 1000) / 1000 : null;
    const num4 = (x) => (typeof x === 'number' && isFinite(x)) ? Math.round(x * 10000) / 10000 : null;
    const app = window.app || null;
    const map = app && app.map;
    const sc = app && app.sectionContainer;
    const live = { iz: null, zfs: null, z: null, minz: null, maxz: null };
    if (sc && typeof sc.isInZoomAnimation === 'function') {
      try { live.iz = sc.isInZoomAnimation() ? 1 : 0; } catch (e) {}
    }
    if (map) {
      if (typeof map.getZoom === 'function') { try { live.z = num4(map.getZoom()); } catch (e) {} }
      if (typeof map.getMinZoom === 'function') { try { live.minz = num4(map.getMinZoom()); } catch (e) {} }
      if (typeof map.getMaxZoom === 'function') { try { live.maxz = num4(map.getMaxZoom()); } catch (e) {} }
      const layer = map._docLayer;
      const painter = layer && layer._painter;
      if (painter && typeof painter.zoomFrameScale === 'function') {
        try { live.zfs = num4(painter.zoomFrameScale()); } catch (e) {}
      }
    }
    const st = { hasApp: app ? 1 : 0, z: live.z, mt: null, pmd: null, som: null,
                 tei: null, dpi: null, iza: live.iz, zfs: live.zfs,
                 minz: live.minz, maxz: live.maxz };
    if (sc) {
      if (typeof sc.multiTouch === 'boolean') { st.mt = sc.multiTouch ? 1 : 0; }
      if ('positionOnMouseDown' in sc) { st.pmd = (sc.positionOnMouseDown == null) ? 0 : 1; }
      if ('sectionOnMouseDown' in sc) {
        try {
          st.som = sc.sectionOnMouseDown == null ? null
            : String(sc.sectionOnMouseDown.name == null ? 'anon' : sc.sectionOnMouseDown.name).slice(0, 32);
        } catch (e) { st.som = 'err'; }
      }
      if ('touchEventInProgress' in sc) { st.tei = sc.touchEventInProgress ? 1 : 0; }
    }
    if (app) { try { st.dpi = num(app.dpiScale); } catch (e) {} }
    let pen = null;
    if (typeof window.__floeOfficePenState === 'function') {
      try {
        const s = window.__floeOfficePenState();
        pen = { d: s.drawing ? 1 : 0, as: s.activeStroke ? 1 : 0, str: s.strokes, ce: s.coreEvents,
                ad: s.armedDispatches, sh: s.shapeHandleSuspensions, ph: s.previewHandoffs,
                cl: s.previewClears, ts: s.toolState == null ? null : String(s.toolState).slice(0, 24),
                lp: s.livePreview ? 1 : 0, wi: num(s.writerInsetTwips), wo: num(s.writerPageOriginTwips),
                er: s.error == null ? null : String(s.error).slice(0, 48) };
      } catch (e) { pen = { err: 1 }; }
    }
    const vv = window.visualViewport;
    let so = null;
    try { so = (window.screen && screen.orientation && typeof screen.orientation.type === 'string')
          ? screen.orientation.type.slice(0, 24) : null; } catch (e) {}
    const vp = { iw: num(window.innerWidth), ih: num(window.innerHeight), dpr: num(window.devicePixelRatio),
                 vw: vv ? num(vv.width) : null, vh: vv ? num(vv.height) : null, vs: vv ? num(vv.scale) : null,
                 sw: num(window.screen && screen.width), sh: num(window.screen && screen.height), so: so };
    // Read-only canvas rectangle (CSS px, viewport relative) used by the
    // DEBUG-only passive pinch anchor; no DOM mutation and no event hook.
    let cv = null;
    try {
      const cvCanvas = app && app.sectionContainer && app.sectionContainer.canvas;
      if (cvCanvas && typeof cvCanvas.getBoundingClientRect === 'function') {
        const r = cvCanvas.getBoundingClientRect();
        cv = { x: num(r.left), y: num(r.top), w: num(r.width), h: num(r.height) };
      }
    } catch (e) {}
    const body = { v: 1, ok: 1, gen: P.gen, owner: P.owner, wall0: P.wall0,
                   t: Math.round((performance.now() - P.pn0) * 10) / 10,
                   cnt: P.cnt, cntB: P.cntB, cntD: P.cntD, dr: P.dr, ns: P.ns,
                   gid: P.gid, ga: P.ga, gst: P.gst, lmt: P.lmt, gend: P.gend,
                   gc: P.gc, gest: P.gest, latest: P.latest,
                   terminal: P.terminal, fl: P.fl, lfin: P.lfin,
                   eseq: P.eseq, lmseq: P.lmseq,
                   mk: P.mk, pd: P.pdrop,
                   ia: P.ia, iaT: P.iaT, iaN: P.iaN,
                   cl: (P.cl || []), clN: P.clN, clD: P.clD, clW: 0,
                   ctn: (typeof P.ctn === 'number' ? P.ctn : 0),
                   // Passive-only mode, the settled fixed DOM input-state
                   // group and the bounded moment-state ring (independent
                   // of the call-site instrumentation; see the header).
                   po: (P.passive ? 1 : 0),
                   is: (() => { try { return typeof P.inputFacts === 'function' ? P.inputFacts() : null; } catch (e) { return null; } })(),
                   sf: (P.sf || []),
                   sfn: (typeof P.sfn === 'number' ? P.sfn : 0),
                   sfd: (typeof P.sfd === 'number' ? P.sfd : 0),
                   starts: P.starts, ring: P.ring, rtv: 0, st: st, pen: pen, vp: vp,
                   cv: cv, jr: P.jr, jns: P.jns, jdr: P.jdr,
                   eg: (() => { try { return P.calcGeo(Math.round((performance.now() - P.pn0) * 10) / 10); } catch (e) { return null; } })(),
                   rs: document.readyState.slice(0, 12) };
    // Honest omission counter: retained trace records that carry no `sk`
    // because the per-gesture stack budget was spent (or no sanitizable
    // frame was produced). Absent when zero, so the no-trace worst case is
    // unchanged.
    if (P.ctO > 0) { body.ctO = P.ctO; }
    let text = JSON.stringify(body);
    if (text.length > MAX) {
      // Trim order (never starts, never the journal): exported trace records
      // first (oldest first, counted in `clW`), then the recent-event ring
      // exactly as before (counted in `rtv`). Only if even the ring-free,
      // trace-free payload is over budget does the complete explicit failure
      // object below replace the snapshot.
      if (Array.isArray(body.cl) && body.cl.length) { body.cl = P.cl.slice(); }
      while (text.length > MAX && body.cl && body.cl.length > 0) {
        body.cl.shift();
        body.clW = (body.clW || 0) + 1;
        text = JSON.stringify(body);
      }
      let limit = Math.floor(P.ring.length / 2);
      while (text.length > MAX && limit > 0) {
        const keep = P.ring.slice(Math.max(0, P.ring.length - limit));
        body.ring = keep;
        body.rtv = P.ring.length - keep.length;
        text = JSON.stringify(body);
        limit = Math.floor(limit / 2);
      }
      if (text.length > MAX) {
        body.ring = [];
        body.rtv = P.ring.length;
        text = JSON.stringify(body);
      }
      // If even the ring-free payload (all starts and the whole journal kept
      // whole) exceeds the page budget, return a complete, explicit failure
      // object instead of an over-budget or partially sliced snapshot. The
      // consumer requires ok=1, so this is an honest instrumentation failure,
      // never silent loss or a start/journal eviction.
        if (text.length > MAX) {
          return JSON.stringify({ v: 1, ok: 0, reason: 'snapshot-over-budget',
                                  length: text.length, starts: P.starts.length,
                                  ns: P.ns, jr: P.jr.length, sf: P.sf.length });
        }
    }
    return text;
  } catch (e) {
    return JSON.stringify({ v: 1, ok: 1, gen: P.gen, owner: P.owner, err: 'snapshot-failed' });
  }
})()
"""#

    /// Removes only a probe this same installation token still owns. A page
    /// owned by a newer installation is left untouched (and vice versa: a
    /// stale removal arriving after a newer install is a no-op), so cleanup
    /// from an older install can never delete a newly installed probe on a
    /// reused WKWebView. Only `window.__floeTouchProbe` state is touched;
    /// product listeners are never enumerated or modified.
    private static func domRemovalScript(owner token: Int) -> String {
        #"""
(() => {
  const OWNER = \#(token);
  try {
    const P = window.__floeTouchProbe;
    if (P && typeof P.owner === 'number' && P.owner !== OWNER) { return 'owned-by-newer:' + P.owner; }
    if (P && typeof P.teardown === 'function') { P.teardown(); }
  } catch (e) {}
  return window.__floeTouchProbe ? 'left' : 'gone';
})()
"""#
    }
}
#endif
