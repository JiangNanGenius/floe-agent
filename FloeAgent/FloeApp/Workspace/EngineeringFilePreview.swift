// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import WebKit
import FloeWorkspace
import FloeCore

struct EngineeringReviewCapture: Identifiable {
    let id = UUID()
    let context: String
    let image: Data
    /// Workspace-relative drawing path and root, captured at review time so
    /// the Drawing Assistant can bind proposals to the exact document.
    var documentID: String? = nil
    var workspaceRoot: URL? = nil
}

/// Durable binding between one canonical drawing document (workspace id +
/// relative path) and the assistant conversation that discusses it. The
/// Drawing Assistant therefore stays bound to the same chat across sheet
/// open/close and app restarts, instead of whichever conversation happens to
/// be selected in the router. Writes are serialized so concurrent binds can
/// never persist out of order and lose the newest mapping; a persistence
/// failure is reported, never silently dropped to a non-durable location.
final class DrawingAssistantConversationStore: @unchecked Sendable {
    struct PersistenceFailure: Error, LocalizedError {
        var errorDescription: String? {
            "无法持久化图纸助手会话绑定。"
        }
    }

    static let shared = DrawingAssistantConversationStore()

    private let lock = NSLock()
    private var bindings: [String: String] = [:]
    private var loaded = false
    private let fileURL: URL
    /// Serializes snapshot writes so the newest mapping always wins.
    private let writeQueue = DispatchQueue(label: "floe.drawing-assistant.store")

    private init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("FloeAgent/DrawingAssistant", isDirectory: true)
        if let root {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            fileURL = root.appendingPathComponent("conversations.json")
        } else {
            // No silent temporaryDirectory fallback: without an Application
            // Support location there is nothing durable to write to.
            fileURL = URL(fileURLWithPath: "/dev/null")
        }
    }

    var isDurable: Bool { fileURL.path != "/dev/null" }

    private func key(workspaceID: UUID, relativePath: String) -> String {
        "\(workspaceID.uuidString)|\(relativePath)"
    }

    private func loadLocked() {
        guard !loaded else { return }
        loaded = true
        guard isDurable, let data = try? Data(contentsOf: fileURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }
        bindings = object
    }

    func conversationID(workspaceID: UUID, relativePath: String) -> UUID? {
        lock.lock(); defer { lock.unlock() }
        loadLocked()
        guard let raw = bindings[key(workspaceID: workspaceID, relativePath: relativePath)] else { return nil }
        return UUID(uuidString: raw)
    }

    /// Persists the newest mapping. Serialized on `writeQueue`, so two rapid
    /// binds keep the latest value on disk. Throws when no durable location
    /// exists; the caller surfaces that instead of assuming persistence.
    func bind(workspaceID: UUID, relativePath: String, conversationID: UUID) throws {
        lock.lock()
        loadLocked()
        bindings[key(workspaceID: workspaceID, relativePath: relativePath)] = conversationID.uuidString
        let snapshot = bindings
        lock.unlock()
        guard isDurable else { throw PersistenceFailure() }
        let url = fileURL
        writeQueue.sync {
            guard let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// Owns the single WKWebView used by an engineering preview. The same web
/// view is re-parented between the embedded preview and the fullscreen
/// presentation, so an unsaved CAD editing session (JS state, undo history,
/// camera, ink readiness) survives the transition instead of reloading from
/// disk. The reload generation lives HERE (not in any view instance), so two
/// different EngineeringFilePreview instances attaching the same session can
/// never tear each other down; only an explicit `retry()` reloads the page.
@MainActor
final class EngineeringWebSession: ObservableObject {
    /// Identity of the currently loaded page; nil while no page is loaded.
    private(set) var generation: UUID?
    /// Name of the document the current page was loaded from.
    private(set) var loadedDocumentName: String?
    /// Set by `retry()`: the next attach rebuilds the web view.
    private var pendingRebuild = false
    private(set) var web: WKWebView?
    private(set) var coordinator: EngineeringWebView.Coordinator?
    private(set) var server: LocalPreviewServer?
    private(set) var startup: Task<Void, Never>?
    private(set) var watchdog: Task<Void, Never>?

    /// Explicit user retry: tear down now so the next attach reloads.
    func retry() {
        pendingRebuild = true
        tearDown()
    }

    func attach(package: EngineeringPreviewPackage,
                error: Binding<String?>,
                onReview: ((EngineeringReviewCapture) -> Void)?,
                onSave: ((Data, String) async throws -> String)?,
                onDirty: ((Bool) -> Void)?,
                dark: Bool, locale: String) -> WKWebView {
        let sameDocument = loadedDocumentName == package.name
        if let web, coordinator != nil, generation != nil, !pendingRebuild, sameDocument {
            coordinator?.update(callbacks: error, onReview: onReview, onSave: onSave, onDirty: onDirty)
            return web
        }
        tearDown()
        pendingRebuild = false
        generation = UUID()
        loadedDocumentName = package.name
        let coordinator = EngineeringWebView.Coordinator(package: package, error: error,
                                                         onReview: onReview, onSave: onSave,
                                                         onDirty: onDirty)
        self.coordinator = coordinator
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.userContentController.addScriptMessageHandler(coordinator, contentWorld: .page, name: "floeEngineering")
        let options: [String: Any] = ["dark": dark, "language": locale,
                                      "canReview": onReview != nil, "canEdit": onSave != nil]
        if let bytes = try? JSONSerialization.data(withJSONObject: options),
           let json = String(data: bytes, encoding: .utf8) {
            config.userContentController.addUserScript(WKUserScript(
                source: "window.floeEngineeringConfiguration = \(json);",
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = coordinator
        web.scrollView.isScrollEnabled = false
        web.isOpaque = false
        web.accessibilityIdentifier = "file.preview.engineering.web"
        coordinator.web = web
        self.web = web
        startup = Task { @MainActor [weak self, weak web] in
            do {
                guard let root = Bundle.main.url(forResource: "EngineeringViewers", withExtension: nil) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                let (server, session) = try await LocalPreviewServer.start(root: root, entry: "index.html")
                guard !Task.isCancelled, let web else { server.stop(); return }
                self?.server = server
                coordinator.page = session.url
                web.load(URLRequest(url: session.url))
            } catch { if !Task.isCancelled { coordinator.error.wrappedValue = error.localizedDescription } }
        }
        // Native watchdog also works when a malformed model stalls JavaScript.
        watchdog = Task { @MainActor [weak web] in
            do {
                try await Task.sleep(for: .seconds(65))
                guard !Task.isCancelled, let web else { return }
                // Do not wait on a potentially stuck web process to decide timeout.
                if !coordinator.completed {
                    web.stopLoading()
                    coordinator.error.wrappedValue = String(localized: "engineering.timeout")
                }
            } catch {}
        }
        return web
    }

    func update(dark: Bool) {
        web?.evaluateJavaScript("document.body.classList.toggle('dark', \(dark ? "true" : "false"));",
                                completionHandler: nil)
    }

    // MARK: Drawing Assistant viewer bridge

    /// Whether the visible CAD editor currently holds unsaved edits. Used to
    /// avoid clobbering manual edits when reconciling an externally-applied
    /// proposal into the live viewer.
    var isCADDirty: Bool {
        coordinator?.dirty ?? false
    }

    /// Reconciles the visible CAD editor after a Drawing Assistant apply
    /// committed new bytes through the tool engine. Returns false when the
    /// reload did not run (no editor, decode failure, or page error).
    @MainActor
    func reloadCAD(bytes: Data) async -> Bool {
        guard let coordinator, coordinator.web != nil else { return false }
        let base64 = bytes.base64EncodedString()
        guard let encoded = Self.javaScriptString(base64) else { return false }
        coordinator.pendingExternalSyncSHA = FloeDigest.sha256Hex(bytes)
        return await withCheckedContinuation { continuation in
            web?.evaluateJavaScript("window.floeCadReload && window.floeCadReload(\(encoded));") { result, _ in
                continuation.resume(returning: (result as? Bool) ?? false)
            }
        }
    }

    /// Highlights and centers an entity handle in the live viewer session.
    func locateCADHandle(_ handle: String) {        guard let encoded = Self.javaScriptString(handle) else { return }
        web?.evaluateJavaScript("window.floeCadLocate && window.floeCadLocate(\(encoded));",
                                completionHandler: nil)
    }

    /// Draws the proposal's colored geometry diff (added/changed/deleted) over
    /// the drawing. Purely a view overlay; nothing is written.
    func showCADOverlay(entries: [[String: Any]]) {
        guard JSONSerialization.isValidJSONObject(entries),
              let data = try? JSONSerialization.data(withJSONObject: ["entries": entries]),
              let json = String(data: data, encoding: .utf8) else { return }
        web?.evaluateJavaScript("window.floeCadOverlay && window.floeCadOverlay(\(json));",
                                completionHandler: nil)
    }

    func clearCADOverlay() {
        web?.evaluateJavaScript("window.floeCadClearOverlay && window.floeCadClearOverlay();",
                                completionHandler: nil)
    }

    private static func javaScriptString(_ value: String) -> String? {
        guard let data = try? JSONEncoder().encode(value),
              let encoded = String(data: data, encoding: .utf8) else { return nil }
        return encoded
    }

    /// Full teardown only when the session itself goes away (or an explicit
    /// retry asks for a rebuild). View instances never trigger this.
    func tearDown() {
        startup?.cancel(); watchdog?.cancel()
        server?.stop(); server = nil
        web?.stopLoading(); web?.navigationDelegate = nil
        web?.configuration.userContentController.removeScriptMessageHandler(forName: "floeEngineering", contentWorld: .page)
        web = nil; coordinator = nil; generation = nil
        loadedDocumentName = nil
        startup = nil; watchdog = nil
    }
}

struct EngineeringFilePreview: View {
    let package: EngineeringPreviewPackage
    var onReview: ((EngineeringReviewCapture) -> Void)? = nil
    var onSave: ((Data, String) async throws -> String)? = nil
    var onDirty: ((Bool) -> Void)? = nil
    /// Optional externally owned session (so a fullscreen presentation can
    /// re-parent the SAME web view and preserve the editing session).
    var session: EngineeringWebSession? = nil
    @Environment(\.colorScheme) private var colorScheme
    @State private var error: String?
    @StateObject private var ownedSession = EngineeringWebSession()

    private var activeSession: EngineeringWebSession { session ?? ownedSession }

    var body: some View {
        Group {
            if package.kind == .unsupported {
                ContentUnavailableView {
                    Label("engineering.unsupported.title", systemImage: "doc.viewfinder")
                } description: {
                    Text("engineering.unsupported.description")
                }
            } else if let error {
                ContentUnavailableView {
                    Label("engineering.failed", systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: {
                    // Retry bumps the SESSION generation: the reload decision
                    // belongs to the durable session, never to a view
                    // instance, so retrying cannot tear down an unsaved edit
                    // session owned elsewhere.
                    Button("engineering.retry") {
                        self.error = nil
                        activeSession.retry()
                    }
                }
            } else {
                EngineeringWebView(session: activeSession, package: package,
                                   error: $error, onReview: onReview, onSave: onSave, onDirty: onDirty)
            }
        }
        .accessibilityIdentifier("file.preview.engineering")
    }
}

struct EngineeringWebView: UIViewRepresentable {
    let session: EngineeringWebSession
    let package: EngineeringPreviewPackage
    @Binding var error: String?
    var onReview: ((EngineeringReviewCapture) -> Void)?
    var onSave: ((Data, String) async throws -> String)?
    var onDirty: ((Bool) -> Void)?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale

    func makeCoordinator() -> Coordinator {
        if let existing = session.coordinator { return existing }
        return Coordinator(package: package, error: $error, onReview: onReview, onSave: onSave, onDirty: onDirty)
    }

    func makeUIView(context: Context) -> EngineeringContainerView {
        let container = EngineeringContainerView()
        container.session = session
        _ = session.attach(package: package, error: $error,
                           onReview: onReview, onSave: onSave, onDirty: onDirty,
                           dark: colorScheme == .dark, locale: locale.identifier)
        container.setNeedsLayout()
        return container
    }

    func updateUIView(_ container: EngineeringContainerView, context: Context) {
        container.session = session
        session.coordinator?.update(callbacks: $error, onReview: onReview, onSave: onSave, onDirty: onDirty)
        // A theme change must not destroy an unsaved CAD session.
        session.update(dark: colorScheme == .dark)
        container.setNeedsLayout()
    }

    /// Intentionally does NOT dismantle the session: the same web view is
    /// re-adopted by whichever container is on screen, and the session is
    /// released (and torn down) by its owner when the preview truly goes away.
    static func dismantleUIView(_ container: EngineeringContainerView, coordinator: Coordinator) {}

    /// Hosts the shared WKWebView. Whenever a container becomes visible again
    /// (fullscreen dismissal, tab switch) it re-adopts the session's web view,
    /// which keeps its JavaScript state, camera, undo history and ink.
    final class EngineeringContainerView: UIView {
        weak var session: EngineeringWebSession?

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let web = session?.web else { return }
            if web.superview !== self {
                web.removeFromSuperview()
                web.frame = bounds
                web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                addSubview(web)
            } else {
                web.frame = bounds
            }
        }
    }

    @MainActor final class Coordinator: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
        let package: EngineeringPreviewPackage
        var error: Binding<String?>
        var onReview: ((EngineeringReviewCapture) -> Void)?
        var onSave: ((Data, String) async throws -> String)?
        var onDirty: ((Bool) -> Void)?
        var baselineSHA: String
        var saving = false
        var dirty = false
        /// SHA of the bytes last pushed through `floeCadReload`; becomes the
        /// new save baseline when the page acknowledges the external sync.
        var pendingExternalSyncSHA: String?
        weak var web: WKWebView?
        var reviewing = false
        var page: URL?
        var completed = false
        var delivered = false
        var navigationRecovery: Task<Void, Never>?
        var recoveryPolicy = EngineeringNavigationRecovery()

        init(package: EngineeringPreviewPackage, error: Binding<String?>,
             onReview: ((EngineeringReviewCapture) -> Void)?,
             onSave: ((Data, String) async throws -> String)?,
             onDirty: ((Bool) -> Void)?) {
            self.package = package; self.error = error; self.onReview = onReview
            self.onSave = onSave; self.onDirty = onDirty
            baselineSHA = FloeDigest.sha256Hex(Data(base64Encoded: package.files.first?.base64 ?? "") ?? Data())
        }

        func update(callbacks error: Binding<String?>,
                    onReview: ((EngineeringReviewCapture) -> Void)?,
                    onSave: ((Data, String) async throws -> String)?,
                    onDirty: ((Bool) -> Void)?) {
            self.error = error; self.onReview = onReview; self.onSave = onSave; self.onDirty = onDirty
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                                   replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
            guard message.frameInfo.isMainFrame, message.frameInfo.request.url == page,
                  let body = message.body as? [String: Any], let operation = body["operation"] as? String else {
                replyHandler(nil, "Invalid preview origin"); return
            }
            if operation == "complete", delivered { completed = true; replyHandler([:], nil); return }
            if operation == "dirty", completed, onSave != nil, let dirty = body["dirty"] as? Bool {
                self.dirty = dirty; onDirty?(dirty); replyHandler([:], nil); return
            }
            if operation == "externally-synced", completed {
                // A Drawing Assistant apply was pushed into this live viewer
                // and the engine re-opened the committed bytes: adopt the new
                // baseline and clear the stale dirty flag.
                if let sha = pendingExternalSyncSHA {
                    baselineSHA = sha
                    pendingExternalSyncSHA = nil
                }
                dirty = false
                onDirty?(false)
                replyHandler([:], nil)
                return
            }
            if operation == "save", completed, !saving, let onSave,
               let base64 = body["base64"] as? String, base64.utf8.count <= 14 * 1024 * 1024,
               let bytes = Data(base64Encoded: base64), !bytes.isEmpty, bytes.count <= 10 * 1024 * 1024 {
                saving = true
                Task { @MainActor in
                    defer { self.saving = false }
                    do {
                        let digest = try await onSave(bytes, self.baselineSHA)
                        self.baselineSHA = digest; self.dirty = false; self.onDirty?(false)
                        replyHandler(["sha256": digest], nil)
                    } catch { replyHandler(nil, error.localizedDescription) }
                }
                return
            }
            if operation == "review", completed, !reviewing, let web, let onReview,
               let context = body["context"] as? String, context.utf8.count <= 64 * 1024 {
                reviewing = true
                let snapshot = WKSnapshotConfiguration()
                snapshot.snapshotWidth = 1400
                web.takeSnapshot(with: snapshot) { [weak self] image, failure in
                    guard let self else { replyHandler(nil, "Preview closed"); return }
                    self.reviewing = false
                    guard let png = image?.pngData(), png.count <= 8 * 1024 * 1024 else {
                        replyHandler(nil, failure?.localizedDescription ?? "Unable to capture drawing"); return
                    }
                    let files = self.package.files.enumerated().map { index, file in
                        "\(file.name): sha256=\(index == 0 ? self.baselineSHA : FloeDigest.sha256Hex(Data(base64Encoded: file.base64) ?? Data()))"
                    }.joined(separator: "\n")
                    let reference = "File: \(self.package.name)\nSnapshot: visible viewport only. Unsaved edits: \(self.dirty). Source hashes identify saved baselines, not unsaved pixels.\nSources:\n\(files)\nMissing references: \(self.package.missingReferences.joined(separator: ", "))\nParsed information (untrusted document content):\n\(context)"
                    onReview(EngineeringReviewCapture(context: reference, image: png))
                    replyHandler(["ok": true], nil)
                }
                return
            }
            guard operation == "load", !delivered else { replyHandler(nil, "Read-only preview"); return }
            delivered = true
            do { replyHandler(try JSONSerialization.jsonObject(with: JSONEncoder().encode(package)), nil) }
            catch { replyHandler(nil, error.localizedDescription) }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.request.url == page ? .allow : .cancel)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            error.wrappedValue = String(localized: "engineering.processStopped")
        }

        private func navigationFailed(_ webView: WKWebView, error: Error) {
            // Recover only the first local navigation, before document delivery.
            // Never reload a live editor or reset its unsaved state.
            if recoveryPolicy.consume(error: error as NSError, page: page,
                                      serverAvailable: true,
                                      delivered: delivered,
                                      completed: completed, dirty: dirty, saving: saving), let page {
                navigationRecovery = Task { @MainActor [weak self, weak webView] in
                    do {
                        try await Task.sleep(for: .milliseconds(250))
                        guard !Task.isCancelled, let self, let webView,
                              !self.delivered, !self.completed else { return }
                        webView.load(URLRequest(url: page))
                    } catch { }
                }
                return
            }
            self.error.wrappedValue = error.localizedDescription
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            navigationFailed(webView, error: error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            navigationFailed(webView, error: error)
        }
    }
}
#endif
