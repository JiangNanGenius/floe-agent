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
        webView.configuration.userContentController.addUserScript(WKUserScript(
            source: embeddedControlsScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    // FLOE_EMBEDDED_CONTROLS_SCRIPT_BEGIN
    static let embeddedControlsScript = #"""
    (() => {
        const install = () => {
            if (window.floeEmbeddedControlsInstalled) return;
            window.floeEmbeddedControlsInstalled = true;
            // Floe's tab close saves/commits before releasing the native session.
            // The engine's close button bypasses that owner and strands the tab.
            const style = document.createElement('style');
            style.textContent = '#closebuttonwrapper, #closebuttonwrapperseparator, #closebutton { display: none !important; }';
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
            window.floeCompleteOriginalSave = (success) => {
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
