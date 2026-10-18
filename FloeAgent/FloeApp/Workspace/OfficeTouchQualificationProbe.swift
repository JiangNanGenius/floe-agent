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
// before the next poll. The periodic snapshot adds engine numerics:
// app.map.getZoom, the same sectionContainer fields, app.dpiScale, the
// gate's __floeOfficePenState fields, and viewport facts (innerWidth/Height,
// devicePixelRatio, visualViewport width/height/scale, screen size and
// orientation type).
#if DEBUG && canImport(UIKit) && canImport(WebKit)
import UIKit
import WebKit

@MainActor
final class OfficeTouchQualificationProbe {
    static let shared = OfficeTouchQualificationProbe()

    static let launchArgument = "--office-touch-qualification"
    static let snapshotAccessibilityIdentifier = "office.touch-qualification.snapshot"
    static let snapshotAccessibilityLabel = "FLOE_TOUCH_PROBE"

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
        guard let web = inst.webView else { return }
        let raw = (try? await web.evaluateJavaScript(Self.domSnapshotScript)) as? String
        guard let json = raw, installation === inst else { return }
        setOverlayValue(inst, json)
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

    private func attachOverlay(to controller: UIViewController, in inst: Installation) {
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
      dr: 0, ns: 0, starts: [], ring: [], handles: []
    };
    const R = (x) => (typeof x === 'number' && isFinite(x)) ? Math.round(x * 10) / 10 : null;
    const clip = (s, n) => (typeof s === 'string') ? s.slice(0, n) : null;
    const coord = (p) => [R(p && p.clientX), R(p && p.clientY)];
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
        if (key === 'ts' || key === 'tm' || key === 'pd') { quickState(rec); }
        P.cnt[key] = (P.cnt[key] || 0) + 1;
        if (key === 'ts' || key === 'pd') {
          P.ns += 1;
          if (P.starts.length < MAXSTARTS) { P.starts.push(rec); }
        }
        if (P.ring.length >= CAP) { P.ring.shift(); P.dr += 1; }
        P.ring.push(rec);
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
    const app = window.app || null;
    const map = app && app.map;
    const sc = app && app.sectionContainer;
    const st = { hasApp: app ? 1 : 0, z: null, mt: null, pmd: null, som: null, tei: null, dpi: null };
    if (map && typeof map.getZoom === 'function') { try { st.z = num(map.getZoom()); } catch (e) {} }
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
    const body = { v: 1, ok: 1, gen: P.gen, owner: P.owner, wall0: P.wall0,
                   t: Math.round((performance.now() - P.pn0) * 10) / 10,
                   cnt: P.cnt, cntB: P.cntB, cntD: P.cntD, dr: P.dr, ns: P.ns,
                   starts: P.starts, ring: P.ring, rtv: 0, st: st, pen: pen, vp: vp,
                   rs: document.readyState.slice(0, 12) };
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
