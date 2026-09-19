// Route the native editor's explicit Save action through Floe's original-file
// commit. Autosaves remain private recovery writes.
#if canImport(UIKit) && canImport(WebKit)
import UIKit
import WebKit

@MainActor
final class OfficeExplicitSaveBridge: NSObject, WKScriptMessageHandler {
    private static let handler = "floeCommitDocument"
    private weak var webView: WKWebView?
    private var save: (@MainActor () async -> Bool)?
    private var pending = false

    init(controller: UIViewController, save: @escaping @MainActor () async -> Bool) throws {
        super.init()
        // The native controller creates its WebView in viewDidLoad, but opens
        // the file in viewWillAppear. Install before the surface is mounted.
        controller.loadViewIfNeeded()
        guard let webView = Self.findWebView(in: controller.view) else {
            throw CocoaError(.featureUnsupported)
        }
        self.webView = webView
        self.save = save
        let content = webView.configuration.userContentController
        content.add(self, name: Self.handler)
        content.addUserScript(WKUserScript(source: Self.script,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    }

    func invalidate() {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.handler)
        save = nil
        webView = nil
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard !pending, message.name == Self.handler, message.frameInfo.isMainFrame,
              let webView, message.webView === webView,
              let url = message.frameInfo.request.url, url.isFileURL,
              url.lastPathComponent == "cool.html",
              let body = message.body as? String, body == "save", let save else { return }
        pending = true
        Task { @MainActor [weak self, weak webView] in
            let success = await save()
            guard let self else { return }
            self.pending = false
            guard let webView, self.webView === webView else { return }
            // A UI failure cannot turn a failed original-file commit into a
            // success. Never replay a save if this acknowledgement is lost.
            _ = try? await webView.evaluateJavaScript(
                "window.floeCompleteOriginalSave?.(\(success ? "true" : "false"));")
        }
    }

    static func findWebView(in view: UIView) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        for child in view.subviews {
            if let found = findWebView(in: child) { return found }
        }
        return nil
    }

    // FLOE_OFFICE_INK_BRIDGE_BEGIN
    /// Outcome of a native Office ink attribute dispatch. `verified` requires a
    /// fresh, token-correlated engine `commandstatechanged` event for *every*
    /// requested attribute that matches the requested value. A command that was
    /// accepted by the WebView but never independently confirmed stays
    /// `dispatchedUnverified` and must never be presented as applied.
    ///
    /// The pinned host's `stateChangeHandler.getItemValue` returns a cached
    /// `_items` value that any earlier `commandstatechanged` event can satisfy,
    /// so cached read-back alone can never prove a new dispatch took effect.
    enum InkApplyOutcome: Equatable { case verified, dispatchedUnverified }

    enum InkApplyError: LocalizedError {
        case bridgeUnavailable
        case notReady
        case invalidArguments
        case objectSelected
        case dispatchFailed(String)

        var errorDescription: String? {
            switch self {
            case .bridgeUnavailable:
                OfficeInkText.t("批注工具桥接不可用。", "The annotation bridge is unavailable.")
            case .notReady:
                OfficeInkText.t("文档尚未进入可编辑状态，暂时无法应用笔迹参数。",
                                "The document is not editable yet; ink settings cannot be applied.")
            case .objectSelected:
                OfficeInkText.t("请先轻点文档空白处，取消对象选择后再调整画笔。",
                                "Tap a blank area to deselect the object before changing pen settings.")
            case .invalidArguments:
                OfficeInkText.t("笔迹参数无效。", "The ink settings are invalid.")
            case .dispatchFailed(let reason):
                OfficeInkText.t("文档引擎未能应用笔迹参数（\(reason)）。",
                                "The document engine could not apply the ink settings (\(reason)).")
            }
        }
    }

    /// Applies one document's stroke settings to the pinned engine's own
    /// freehand shape tool. This is not a screen overlay: it drives the same
    /// editable vector shapes the engine saves and exports.
    ///
    /// Verified argument encodings (see `office-ink-implementation` evidence):
    /// - `.uno:XLineColor`        object form `XLineColor.Color`, long, 0xRRGGBB
    ///   (pinned `JSDialog.sendColorCommand` derives `<Command>.Color`).
    /// - `.uno:LineWidth`         object form `LineWidth`, long, 1/100 mm
    ///   (`SvxMetricField::ModifyHdl` dispatches exactly this property).
    /// - `.uno:LineTransparence`  string form `?LineTransparence:short=<percent>`
    ///   (pinned `Control.NotebookbarBuilder._lineTransparencyControl`).
    static func applyInk(_ stroke: OfficeInkStroke,
                         controller: UIViewController) async throws -> InkApplyOutcome {
        controller.loadViewIfNeeded()
        guard let webView = findWebView(in: controller.view) else { throw InkApplyError.bridgeUnavailable }
        let dispatch: Any?
        do {
            dispatch = try await webView.evaluateJavaScript(
                "window.__floeApplyOfficeInk ? window.__floeApplyOfficeInk(\(inkRequestJSON(stroke))) : null")
        } catch {
            throw InkApplyError.dispatchFailed("bridge-unreachable")
        }
        guard let result = dispatch as? [String: Any] else { throw InkApplyError.bridgeUnavailable }
        guard (result["ok"] as? Bool) == true else {
            switch result["reason"] as? String {
            case "not-ready": throw InkApplyError.notReady
            case "invalid": throw InkApplyError.invalidArguments
            case "object-selected": throw InkApplyError.objectSelected
            case .some(let reason): throw InkApplyError.dispatchFailed(reason)
            case .none: throw InkApplyError.dispatchFailed("unknown")
            }
        }
        // The pinned host only reports attributes on a later socket tick, so
        // poll the fresh `commandstatechanged` stream under this dispatch's
        // token. Every requested attribute must arrive fresh and match; if the
        // host never emits (or reports a different shape/unit) the result is
        // explicitly unverified rather than fabricated.
        guard let token = (result["token"] as? NSNumber)?.intValue, token > 0 else {
            return .dispatchedUnverified
        }
        for _ in 0..<15 {
            if Task.isCancelled { return .dispatchedUnverified }
            try? await Task.sleep(nanoseconds: 100_000_000)
            let verification = (try? await webView.evaluateJavaScript(
                "window.__floeOfficeInkVerification ? window.__floeOfficeInkVerification(\(token)) : null")) as? [String: Any]
            if (verification?["allFreshMatched"] as? Bool) == true { return .verified }
        }
        return .dispatchedUnverified
    }

    static func inkRequestJSON(_ stroke: OfficeInkStroke) -> String {
        "{\"color\":\(stroke.colorValue),\"width\":\(stroke.lineWidthValue),\"transparency\":\(stroke.transparencyValue)}"
    }

    /// App-owned adapter that dispatches the shape-line attributes through the
    /// pinned engine. It refuses to report success when the map is absent, not
    /// editable, or the dispatch throws. Verification is a separate, token-
    /// correlated read of the engine's *fresh* `commandstatechanged` stream:
    /// `getItemValue` is deliberately never used because it only replays the
    /// host's cached `_items`.
    static let inkBridgeScript = #"""
    (() => {
        if (window.__floeOfficeInkBridgeInstalled) return;
        window.__floeOfficeInkBridgeInstalled = true;

        const UNO = '.uno:';
        const withPrefix = (name) => {
            if (typeof name !== 'string' || name.length === 0) return '';
            return name.substring(0, UNO.length) === UNO ? name : UNO + name;
        };

        // Arrival counters/values for the engine's own commandstatechanged
        // stream. A counter that advanced *after* a dispatch is the only proof
        // that a new attribute report was correlated with that dispatch.
        window.__floeOfficeInkEventSeq = window.__floeOfficeInkEventSeq || {};
        window.__floeOfficeInkEventValue = window.__floeOfficeInkEventValue || {};
        window.__floeOfficeInkListenerMap = null;
        window.__floeOfficeInkListener = null;
        window.__floeOfficeInkLastDispatch = null;
        window.__floeOfficeInkLastToken = 0;

        const recordState = (event) => {
            if (!event || typeof event.commandName !== 'string') return;
            const key = withPrefix(event.commandName);
            if (!key) return;
            window.__floeOfficeInkEventSeq[key] = (window.__floeOfficeInkEventSeq[key] || 0) + 1;
            window.__floeOfficeInkEventValue[key] = event.state;
        };

        const ensureListener = (map) => {
            if (!map || typeof map.on !== 'function') return false;
            if (window.__floeOfficeInkListenerMap === map) return true;
            try {
                const previous = window.__floeOfficeInkListenerMap;
                if (previous && typeof previous.off === 'function' && window.__floeOfficeInkListener)
                    previous.off('commandstatechanged', window.__floeOfficeInkListener);
                const listener = (event) => {
                    if (window.__floeOfficeInkListenerMap === map) recordState(event);
                };
                map.on('commandstatechanged', listener);
                window.__floeOfficeInkListener = listener;
            } catch (_) {
                return false;
            }
            window.__floeOfficeInkListenerMap = map;
            return true;
        };

        const seqFor = (command) => window.__floeOfficeInkEventSeq[command] || 0;

        const sameNumber = (state, expected) => {
            if (typeof state === 'number') return Number.isFinite(state) && state === expected;
            if (typeof state === 'string') {
                const trimmed = state.trim();
                return /^-?\d+$/.test(trimmed) && parseInt(trimmed, 10) === expected;
            }
            return false;
        };

        window.__floeApplyOfficeInk = (request) => {
            const map = window.app && window.app.map;
            if (!map || typeof map.sendUnoCommand !== 'function'
                || typeof map.isEditMode !== 'function' || !map.isEditMode())
                return { ok: false, reason: 'not-ready' };
            const color = request && request.color;
            const width = request && request.width;
            const transparency = request && request.transparency;
            if (![color, width, transparency].every(Number.isInteger)
                || color < 0 || color > 0xFFFFFF || width <= 0 || width > 600
                || transparency < 0 || transparency > 100)
                return { ok: false, reason: 'invalid' };
            // These commands also style selected shapes. Only apply pen
            // defaults after the pinned engine confirms no graphic selection.
            const selection = window.app.definitions && window.app.definitions.graphicSelection;
            if (!selection || typeof selection.hasActiveSelection !== 'function')
                return { ok: false, reason: 'not-ready' };
            if (selection.hasActiveSelection())
                return { ok: false, reason: 'object-selected' };
            const listener = ensureListener(map);
            const commands = {
                color: '.uno:XLineColor',
                width: '.uno:LineWidth',
                transparency: '.uno:LineTransparence',
            };
            const before = {
                color: seqFor(commands.color),
                width: seqFor(commands.width),
                transparency: seqFor(commands.transparency),
            };
            try {
                map.sendUnoCommand('.uno:XLineColor',
                    { 'XLineColor.Color': { type: 'long', value: color } });
                map.sendUnoCommand('.uno:LineWidth',
                    { 'LineWidth': { type: 'long', value: width } });
                map.sendUnoCommand('.uno:LineTransparence?LineTransparence:short=' + transparency);
            } catch (error) {
                return {
                    ok: false,
                    reason: 'dispatch-failed',
                    message: String((error && error.message) || error)
                };
            }
            window.__floeOfficeInkLastToken += 1;
            window.__floeOfficeInkLastDispatch = {
                token: window.__floeOfficeInkLastToken,
                listener: listener,
                before: before,
                commands: commands,
                expected: { color: color, width: width, transparency: transparency },
            };
            return { ok: true, reason: 'dispatched', token: window.__floeOfficeInkLastToken };
        };

        // Reports whether a *fresh* correlated event for all three requested
        // attributes arrived after the given dispatch token. The cached
        // getItemValue never participates, so a stale cache cannot acknowledge.
        window.__floeOfficeInkVerification = (token) => {
            const dispatch = window.__floeOfficeInkLastDispatch;
            if (!dispatch || dispatch.token !== token)
                return { known: false, allFreshMatched: false, missing: ['dispatch'] };
            const check = (key) => {
                const command = dispatch.commands[key];
                const seq = seqFor(command);
                const fresh = seq > dispatch.before[key];
                const value = window.__floeOfficeInkEventValue[command];
                const matched = fresh && sameNumber(value, dispatch.expected[key]);
                return {
                    fresh: fresh,
                    matched: matched,
                    value: (typeof value === 'undefined' ? null : value),
                };
            };
            const color = check('color');
            const width = check('width');
            const transparency = check('transparency');
            const allFreshMatched = dispatch.listener === true
                && color.matched && width.matched && transparency.matched;
            return {
                known: dispatch.listener === true,
                token: token,
                color: color,
                width: width,
                transparency: transparency,
                allFreshMatched: allFreshMatched,
            };
        };
    })();
    """#
    // FLOE_OFFICE_INK_BRIDGE_END

    // FLOE_MODIFIED_STATUS_PROBE_BEGIN
    /// Reports the pinned engine's `.uno:ModifiedStatus` state. `true`/`false`
    /// are authoritative; `null` means the accessor or its value is unknown and
    /// must never be treated as a clean document.
    static let modifiedStatusProbeScript = #"""
    (() => {
        try {
            if (window.floeModifiedSinceCommit === true) return true;
            if (window.floeModifiedSinceCommit !== false) return null;
            const map = window.app && window.app.map;
            const handler = map && map.stateChangeHandler;
            if (!handler || typeof handler.getItemValue !== 'function') return null;
            const state = handler.getItemValue('.uno:ModifiedStatus');
            if (state === true || state === 'true') return true;
            if (state === false || state === 'false') return false;
            return null;
        } catch (_) {
            return null;
        }
    })()
    """#
    // FLOE_MODIFIED_STATUS_PROBE_END

    // FLOE_PERMISSION_PROBE_BEGIN
    /// Reads the pinned engine's *actual* permission state after a session is
    /// mounted. `app.file.readOnly` is the backing permission (handshake
    /// `permission` query, WOPI props, real edit grants); `map._permission` and
    /// `_shouldStartReadOnly()` describe the mobile viewing-first UI, which the
    /// editor forces for editable documents too, so they are not denial.
    /// `nil`/absent fields mean "unknown" and are never treated as writable.
    /// An unknown or missing `app.file.readOnly` stays `null`: only a real
    /// boolean is reported, so a partially initialised engine can never be
    /// read as an editable grant.
    static let permissionProbeScript = #"""
    (() => {
        try {
            const map = window.app && window.app.map;
            if (!map) return null;
            const file = window.app && window.app.file;
            const backendReadOnly = file && typeof file.readOnly === 'boolean' ? file.readOnly : null;
            const permission = typeof map._permission === 'string' ? map._permission : null;
            const isEditMode = typeof map.isEditMode === 'function' ? map.isEditMode() === true : null;
            const readOnlyMode = typeof map.isReadOnlyMode === 'function' ? map.isReadOnlyMode() === true : null;
            const shouldStartReadOnly = typeof map._shouldStartReadOnly === 'function'
                ? map._shouldStartReadOnly() === true : null;
            let documentProtected = null;
            const docLayer = map._docLayer || (map.getDocLayer && map.getDocLayer());
            if (docLayer && docLayer._docInfo && typeof docLayer._docInfo.isProtected === 'boolean')
                documentProtected = docLayer._docInfo.isProtected;
            else if (typeof map._isDocProtected === 'boolean')
                documentProtected = map._isDocProtected;
            return { backendReadOnly, permission, isEditMode, readOnlyMode, shouldStartReadOnly, documentProtected };
        } catch (_) {
            return null;
        }
    })()
    """#
    // FLOE_PERMISSION_PROBE_END

    // FLOE_ENTER_EDIT_MODE_BEGIN
    /// Forces the pinned engine's own mobile edit entry after the host mounted
    /// an editable session whose engine still reported readonly. This is the
    /// engine's documented switch (`_switchToEditMode`), the same guarded path
    /// the host's fullscreen script uses — the engine keeps its format/password/
    /// lock checks. The backing permission decides denial; `_shouldStartReadOnly`
    /// is the mobile viewing-first startup and must not block an editable file.
    /// The caller re-probes afterwards and falls back to the preview session
    /// when the engine still refuses.
    static let enterEditModeScript = #"""
    (() => {
        try {
            const map = window.app && window.app.map;
            if (!map) return { ok: false, reason: 'not-ready' };
            if (window.app && window.app.file && window.app.file.readOnly === true)
                return { ok: false, reason: 'readonly' };
            if (typeof map._switchToEditMode === 'function') {
                map._switchToEditMode();
                return { ok: true, reason: 'switch' };
            }
            const button = document.querySelector('#mobile-edit-button, .mobile-edit-button');
            if (button && typeof button.click === 'function') {
                button.click();
                return { ok: true, reason: 'button' };
            }
            return { ok: false, reason: 'unsupported' };
        } catch (_) {
            return { ok: false, reason: 'error' };
        }
    })()
    """#
    // FLOE_ENTER_EDIT_MODE_END

    static func didCommit(controller: UIViewController) async {
        guard let webView = findWebView(in: controller.view) else { return }
        // Only the verified original-file commit clears this latch. Engine
        // autosaves and their ModifiedStatus=false notifications cannot do so.
        _ = try? await webView.evaluateJavaScript("if (window.floeModificationTrackingInstalled === true) window.floeModifiedSinceCommit = false;")
    }

    /// Host-owned chrome applies to previews as well as editable sessions.
    /// Keep the pinned engine bundle intact; the app owns this small adapter.
    static func installEmbeddedControls(controller: UIViewController) throws {
        controller.loadViewIfNeeded()
        guard let webView = findWebView(in: controller.view) else {
            throw CocoaError(.featureUnsupported)
        }
        let content = webView.configuration.userContentController
        content.addUserScript(WKUserScript(
            source: embeddedControlsScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        content.addUserScript(WKUserScript(
            source: inkBridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    // FLOE_EMBEDDED_CONTROLS_SCRIPT_BEGIN
    static let embeddedControlsScript = #"""
    (() => {
        const install = () => {
            if (window.floeEmbeddedControlsInstalled) return;
            window.floeEmbeddedControlsInstalled = true;
            // Floe's tab close saves/commits before releasing the native session.
            // The engine's close button bypasses that owner and strands the tab.
            // The engine's floating mobile edit entry is hidden for the same
            // reason: the App's own top toolbar owns the preview/edit entry, so
            // no edit affordance floats over the document's lower-left corner.
            const style = document.createElement('style');
            style.textContent = '#closebuttonwrapper, #closebuttonwrapperseparator, #closebutton { display: none !important; } #mobile-edit-button, #mobile-edit-buttonwrapper, .mobile-edit-button { display: none !important; }';
            document.head.appendChild(style);
            if (window.L && window.L.Params) window.L.Params.closeButtonEnabled = false;

            const proto = window.L && window.L.Control && window.L.Control.NotebookbarBuilder
                && window.L.Control.NotebookbarBuilder.prototype;
            if (!proto || !window.JSDialog || typeof window.JSDialog.combobox !== 'function') return;
            const original = proto._comboboxControl;
            if (typeof original !== 'function') return;
            // Use the same searchable, anchored dropdown as font size. Its entries
            // come from the engine, not the device's unrelated system font list.
            proto._comboboxControl = function (parent, data, builder) {
                if (data.id === 'fontnamecombobox')
                    return window.JSDialog.combobox(parent, data, builder);
                return original.apply(this, arguments);
            };
            const stateChanged = proto.onCommandStateChanged;
            if (typeof stateChanged !== 'function') return;
            window.floeModificationTrackingInstalled = true;
            window.floeModifiedSinceCommit = false;
            proto.onCommandStateChanged = function (event) {
                if (event.commandName === '.uno:ModifiedStatus'
                    && (event.state === true || event.state === 'true'))
                    window.floeModifiedSinceCommit = true;
                if (event.commandName === '.uno:CharFontName') {
                    const control = document.getElementById('fontnamecombobox');
                    if (control && typeof control.onSetText === 'function') control.onSetText(event.state);
                }
                return stateChanged.apply(this, arguments);
            };
        };
        if (document.readyState === 'loading')
            document.addEventListener('DOMContentLoaded', install, { once: true });
        else install();
    })();
    """#
    // FLOE_EMBEDDED_CONTROLS_SCRIPT_END

    // FLOE_EXPLICIT_SAVE_SCRIPT_BEGIN
    static let script = #"""
    (() => {
        const install = () => {
            const proto = window.L && window.L.Map && window.L.Map.prototype;
            if (!proto || typeof proto.fire !== 'function' || proto.floeExplicitSaveInstalled) return;
            proto.floeExplicitSaveInstalled = true;
            const fire = proto.fire;
            let pendingMap = null;
            let savedStatus = null;
            // Bounded watchdog: if the native handoff is lost (the message is
            // dropped by the native guard, or the native save never
            // acknowledges), the engine's save widget must not sit on
            // "Saving…" forever and swallow every later save. The watchdog
            // fails the save after a bounded window so the surface recovers
            // and a later save can run.
            let saveWatchdog = null;
            window.floeCompleteOriginalSave = (success) => {
                if (saveWatchdog) { clearTimeout(saveWatchdog); saveWatchdog = null; }
                const map = pendingMap;
                if (!map) return;
                pendingMap = null;
                const status = map.saveState;
                if (status && savedStatus) status.showSavedStatus = savedStatus;
                savedStatus = null;
                const changedAgain = window.app && window.app.file && window.app.file.modified === true;
                if (success === true && changedAgain && status) {
                    if (typeof status.showModifiedStatus === 'function') status.showModifiedStatus();
                } else if (success === true && status && typeof status.showSavedStatus === 'function')
                    status.showSavedStatus();
                else if (status && typeof status.showSaveFailedStatus === 'function')
                    status.showSaveFailedStatus();
            };
            proto.fire = function (type, event) {
                if (type !== 'postMessage' || !event || event.msgId !== 'UI_Save')
                    return fire.apply(this, arguments);
                // Every shipped Save entry (toolbar, notebookbar, file menu
                // and keyboard dispatcher) checks this after emitting UI_Save.
                this._disableDefaultAction = this._disableDefaultAction || {};
                this._disableDefaultAction.UI_Save = true;
                if (pendingMap || (typeof this.isReadOnlyMode === 'function' && this.isReadOnlyMode()))
                    return this;
                pendingMap = this;
                if (this.saveState && typeof this.saveState.showSavedStatus === 'function') {
                    savedStatus = this.saveState.showSavedStatus;
                    // The engine receipt only confirms a private working copy.
                    // Keep Saved hidden until the original-file CAS completes.
                    this.saveState.showSavedStatus = function () {};
                }
                // Arm the bounded watchdog before handing off to native.
                saveWatchdog = setTimeout(() => {
                    try { window.floeCompleteOriginalSave(false); } catch (_) {}
                }, 20000);
                try {
                    window.webkit.messageHandlers.floeCommitDocument.postMessage('save');
                } catch (_) {
                    window.floeCompleteOriginalSave(false);
                }
                return this;
            };
        };
        if (document.readyState === 'loading')
            document.addEventListener('DOMContentLoaded', install, { once: true });
        else install();
    })();
    """#
    // FLOE_EXPLICIT_SAVE_SCRIPT_END
}
#endif
