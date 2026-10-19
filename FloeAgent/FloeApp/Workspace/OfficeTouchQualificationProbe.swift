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
// coordinates / bounded target tag, id and first class token. Touch and
// pointer-down records additionally carry an in-flight compact section
// snapshot (`q`: multiTouch, positionOnMouseDown, sectionOnMouseDown.name,
// touchEventInProgress, getZoom) captured INSIDE the passive handler, so
// gesture-birth container state survives even though touchend resets it
// before the next poll.
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
// stale sample is never pre-end live-frame evidence.
//
// The snapshot adds `gid/ga/gst/lmt/gend/gc`, a four-entry `gest` summary
// (start, last-finger end, move count, start/end zoom, frame state), a
// single `latest` current-gesture sample, `terminal` (the one record that
// actually ended the current gesture, retained independently of the ring),
// `fl` (the first eight pre-end live move samples of the current gesture,
// reset at birth), and `pd` (fallback samples dropped by the bounded pending
// cap), so a bounded ring that overwrites early events still exposes the
// latest start/end timestamps, the terminal record and the gesture-start
// live frame. `st` adds `iza`, `zfs`, `minz` and `maxz`. These fields describe
// the requested layout/zoom-frame state only; they do not prove that the
// WebKit compositor presented a frame. The periodic snapshot retains engine
// numerics: app.map.getZoom, the same sectionContainer fields, app.dpiScale,
// the gate's __floeOfficePenState fields, and viewport facts
// (innerWidth/Height, devicePixelRatio, visualViewport width/height/scale,
// screen size and orientation type).
#if DEBUG && canImport(UIKit) && canImport(WebKit)
import UIKit
import WebKit

@MainActor
final class OfficeTouchQualificationProbe {
    static let shared = OfficeTouchQualificationProbe()

    static let launchArgument = "--office-touch-qualification"
    static let snapshotAccessibilityIdentifier = "office.touch-qualification.snapshot"
    static let snapshotAccessibilityLabel = "FLOE_TOUCH_PROBE"
    static let canvasAnchorIdentifier = "office.touch-qualification.canvas-anchor"
    static let canvasAnchorLabel = "FLOE_CANVAS_ANCHOR"

    /// True only in a DEBUG build launched with the explicit qualification
    /// argument. Absent in normal UI runs and impossible in Release (the type
    /// itself does not compile there).
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    /// Page-side transfer budget (JSON.stringify length). Swift accepts up to
    /// `maxSnapshotCharacters` and, on any violation, replaces the value with
    /// a complete valid bounded failure object — never a sliced JSON string.
    private static let maxSnapshotCharacters = 45_000
    private static let pollIntervalNanoseconds: UInt64 = 250_000_000
    private static let webViewSearchAttempts = 8
    private static let webViewSearchIntervalNanoseconds: UInt64 = 250_000_000

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
            let script = Self.domInstallScript(owner: token)
            let raw = try? await web.evaluateJavaScript(script)
            guard let current = self.installation, current.token == token,
                  current.webView === web else { return }
            if let ack = raw as? String, ack.hasPrefix("probe-ok") {
                current.jsInstalled = true
                await self.refreshSnapshot(current)
                self.startPolling(current)
            } else {
                self.setOverlayValue(current, "{\"v\":1,\"ok\":0,\"reason\":\"js-install-refused\"}")
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
    /// upstream).
    private static func domInstallScript(owner token: Int) -> String {
        #"""
(() => {
  const OWNER = \#(token);
  try {
    const old = window.__floeTouchProbe;
    if (old && typeof old.owner === 'number' && old.owner > OWNER) { return 'probe-stale:' + old.owner; }
    if (old && typeof old.teardown === 'function') { try { old.teardown(); } catch (e) {} }
    const CAP = 128, MAXSTARTS = 16, COORDS = 4;
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
      gid: 0, ga: 0, gst: null, lmt: null, gend: null, gc: null,
      gmv: 0, gz0: null, latest: null, terminal: null, gest: [],
      pending: new Map(), pdrop: 0, ends: {}, endOrder: []
    };
    const R = (x) => (typeof x === 'number' && isFinite(x)) ? Math.round(x * 10) / 10 : null;
    const num4 = (x) => (typeof x === 'number' && isFinite(x)) ? Math.round(x * 10000) / 10000 : null;
    const now = () => Math.round((performance.now() - P.pn0) * 10) / 10;
    const clip = (s, n) => (typeof s === 'string') ? s.slice(0, n) : null;
    const coord = (p) => [R(p && p.clientX), R(p && p.clientY)];
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
    const sample = (entry, src) => {
      const rec = entry.rec, key = entry.key;
      try {
        const st = zoomState();
        const at = now();
        const ownEnd = P.ends[rec.gi];
        const post = (typeof ownEnd === 'number' && at >= ownEnd) ? 1 : 0;
        const stale = (P.gid !== rec.gi) ? 1 : 0;
        rec.s = { at: at, iz: st.iz, zfs: st.zfs, z: st.z, post: post,
                  stale: stale, src: src };
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
                      post: post, stale: stale, src: src });
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
    const record = (key, e) => {
      try {
        const touch = key.charAt(0) === 't';
        const rec = { k: key, t: Math.round((performance.now() - P.pn0) * 10) / 10,
                      tr: e.isTrusted ? 1 : 0, dp: e.defaultPrevented ? 1 : 0 };
        if (touch) {
          rec.n = e.touches ? e.touches.length : null;
          rec.c = e.changedTouches ? e.changedTouches.length : null;
          const pts = [];
          if (e.changedTouches) {
            const m = Math.min(e.changedTouches.length, COORDS);
            for (let j = 0; j < m; j++) { pts.push(coord(e.changedTouches[j])); }
          }
          rec.o = pts;
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
          P.latest = null;
          P.fl = [];
          P.terminal = null;
          try {
            const m = window.app && window.app.map;
            P.gz0 = m && typeof m.getZoom === 'function' ? num4(m.getZoom()) : null;
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
          // Per-gesture end time: a delayed rAF sample is judged against its
          // own gesture, never against a newer gesture's global end/reset.
          P.ends[P.gid] = rec.t;
          P.endOrder.push(P.gid);
          while (P.endOrder.length > 4) {
            const oldGid = P.endOrder.shift();
            delete P.ends[oldGid];
          }
        }
        if (key === 'tm' && P.ga) { P.gmv += 1; P.lmt = rec.t; }
        rec.gi = P.gid;
        rec.ph = (key === 'ts' || key === 'pd') ? 's'
          : (key === 'tm' || key === 'pm') ? 'm'
          : (key === 'te' || key === 'pu') ? 'e' : 'c';
        if (key === 'ts' || key === 'tm' || key === 'pd') { quickState(rec); }
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
    P.teardown = () => {
      for (const h of P.handles) {
        try { window.removeEventListener(h[0], h[1], { capture: h[2] }); } catch (e) {}
      }
      P.handles.length = 0;
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
                   terminal: P.terminal, fl: P.fl, pd: P.pdrop,
                   starts: P.starts, ring: P.ring, rtv: 0, st: st, pen: pen, vp: vp,
                   cv: cv, rs: document.readyState.slice(0, 12) };
    let text = JSON.stringify(body);
    if (text.length > MAX) {
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
