import SwiftUI
import WebKit
import UniformTypeIdentifiers

public struct ChemistrySketchDocument: Sendable, Equatable {
    public var identity: String
    public var revision: String
    public var source: String
    public init(identity: String, revision: String, source: String) {
        self.identity = identity; self.revision = revision; self.source = source
    }
}
public struct ChemistrySketchSnapshot: Sendable {
    public var ket: String
    public var format: String?
    public var source: String?
    public var smiles: String?
    public var properties: [String: String]?
    public init(ket: String, format: String?, source: String?, smiles: String?, properties: [String:String]? = nil) {
        self.ket = ket; self.format = format; self.source = source; self.smiles = smiles; self.properties = properties
    }
}
public enum ChemistrySketchStatus: Sendable, Equatable { case loading, saved, editing, saving, failed(String) }

/// A complete, offline Ketcher editor. The caller binds identity/revision and performs
/// permission-checked persistence. No project identifiers or paths are accepted from JS.
@MainActor public struct ChemistrySketchView: View {
    public var document: ChemistrySketchDocument
    public var onSave: @MainActor (ChemistrySketchSnapshot, String) async throws -> String
    public var onStatus: @MainActor (ChemistrySketchStatus) -> Void
    public init(document: ChemistrySketchDocument,
                onSave: @escaping @MainActor (ChemistrySketchSnapshot, String) async throws -> String,
                onStatus: @escaping @MainActor (ChemistrySketchStatus) -> Void = { _ in }) {
        self.document = document; self.onSave = onSave; self.onStatus = onStatus
    }
    public var body: some View {
        SketchWebView(document: document, onSave: onSave, onStatus: onStatus)
            .onAppear { onStatus(.loading) }
    }
}

private struct SketchWebView {
    var document: ChemistrySketchDocument
    var onSave: @MainActor (ChemistrySketchSnapshot, String) async throws -> String
    var onStatus: @MainActor (ChemistrySketchStatus) -> Void
    @MainActor func makeCoordinator() -> SketchCoordinator { SketchCoordinator(self) }
    @MainActor func makeWebView(_ coordinator: SketchCoordinator) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(SketchAssets(), forURLScheme: "floechem")
        let script = (try? String(contentsOf: Bundle.module.url(forResource: "bridge", withExtension: "js")!, encoding: .utf8)) ?? ""
        config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        config.userContentController.add(WeakSketchHandler(coordinator), name: "chemistry")
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = coordinator; web.isInspectable = false
        #if os(iOS)
        web.scrollView.isScrollEnabled = false
        web.isOpaque = true; web.backgroundColor = .white
        #endif
        coordinator.web = web
        web.load(URLRequest(url: URL(string: "floechem://editor/index.html?hiddenControls=open,save")!))
        return web
    }
}
#if os(iOS)
extension SketchWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateUIView(_ web: WKWebView, context: Context) { context.coordinator.update(self) }
    static func dismantleUIView(_ web: WKWebView, coordinator: SketchCoordinator) { coordinator.dispose() }
}
#elseif os(macOS)
extension SketchWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateNSView(_ web: WKWebView, context: Context) { context.coordinator.update(self) }
    static func dismantleNSView(_ web: WKWebView, coordinator: SketchCoordinator) { coordinator.dispose() }
}
#endif

final class SketchAssets: NSObject, WKURLSchemeHandler {
    private let root = Bundle.module.url(forResource: "Ketcher", withExtension: nil)!.standardizedFileURL
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        do {
            guard let url = task.request.url, url.scheme == "floechem", url.host == "editor",
                  task.request.httpMethod == "GET", let decoded = url.path.removingPercentEncoding,
                  !decoded.split(separator: "/").contains(".."), !decoded.contains("\\") else { throw URLError(.badURL) }
            let file = root.appendingPathComponent(decoded).standardizedFileURL
            guard file.path.hasPrefix(root.path + "/"), file.resolvingSymlinksInPath().path == file.path else { throw URLError(.noPermissionsToReadFile) }
            let mime: String
            switch file.pathExtension {
            case "js": mime = "application/javascript"
            case "css": mime = "text/css"
            case "html": mime = "text/html"
            case "wasm": mime = "application/wasm"
            case "svg": mime = "image/svg+xml"
            default: mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            }
            let bytes = try Data(contentsOf: file)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Type": mime, "Content-Length": String(bytes.count),
                "Content-Security-Policy": "default-src 'self'; script-src 'self' 'unsafe-eval' blob:; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self' data: blob:; worker-src 'self' blob:; frame-src 'none'; object-src 'none'; base-uri 'self'"
            ])!
            task.didReceive(response); task.didReceive(bytes); task.didFinish()
        } catch { task.didFailWithError(error) }
    }
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) { }
}

@MainActor private final class WeakSketchHandler: NSObject, WKScriptMessageHandler {
    weak var target: SketchCoordinator?
    init(_ target: SketchCoordinator) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) { target?.receive(message) }
}

@MainActor private final class SketchCoordinator: NSObject, WKNavigationDelegate {
    var parent: SketchWebView
    weak var web: WKWebView?
    private var loadedRevision: String
    private var ready = false
    private var dirty = false
    private var disposed = false
    private var retiring = false
    private var latest: ChemistrySketchSnapshot?
    private var lastVersion = -1
    private var saving: Task<Void, Never>?
    init(_ parent: SketchWebView) { self.parent = parent; loadedRevision = parent.document.revision }
    func update(_ value: SketchWebView) {
        guard !disposed, !retiring, value.document.identity == parent.document.identity else { return }
        parent = value
        guard ready, value.document.revision != loadedRevision, saving == nil else { return }
        guard !dirty else { parent.onStatus(.failed("The saved structure changed. Your drawing is retained in this editor.")); return }
        load()
    }
    private func load() {
        guard let web, ready else { return }
        let source = parent.document.source, revision = parent.document.revision
        parent.onStatus(.loading)
        Task { [weak self, weak web] in
            do {
                _ = try await web?.callAsyncJavaScript("await window.floeChemistry.load(source);", arguments: ["source": source], in: nil, contentWorld: .page)
                guard let self, !self.disposed else { return }
                self.loadedRevision = revision; self.dirty = false; self.parent.onStatus(.saved)
            } catch { self?.parent.onStatus(.failed(error.localizedDescription)) }
        }
    }
    func receive(_ message: WKScriptMessage) {
        guard !disposed, message.frameInfo.isMainFrame,
              message.frameInfo.request.url?.scheme == "floechem", message.frameInfo.request.url?.host == "editor",
              let value = message.body as? [String: Any], let type = value["type"] as? String else { return }
        switch type {
        case "ready": ready = true; load()
        case "dirty": dirty = true; parent.onStatus(.editing)
        case "unchanged": if saving == nil, latest == nil { dirty = false; parent.onStatus(.saved) }
        case "error": parent.onStatus(.failed(String((value["message"] as? String ?? "The structure editor could not finish the operation.").prefix(2000))))
        case "snapshot":
            guard let ket = value["ket"] as? String, ket.utf8.count <= 16 * 1024 * 1024,
                  let version = value["version"] as? Int, version > lastVersion else { return }
            let source = value["source"] as? String, smiles = value["smiles"] as? String
            guard (source?.utf8.count ?? 0) <= 16 * 1024 * 1024, (smiles?.utf8.count ?? 0) <= 1024 * 1024 else {
                parent.onStatus(.failed("The drawing exceeds the save limit.")); return
            }
            lastVersion = version
            let properties = value["properties"] as? [String: String]
            guard (properties?.count ?? 0) <= 16, properties?.values.allSatisfy({ $0.utf8.count <= 4096 }) ?? true else { return }
            latest = ChemistrySketchSnapshot(ket: ket, format: value["format"] as? String, source: source, smiles: smiles, properties: properties)
            drain()
        default: break
        }
    }
    private func drain() {
        guard saving == nil, latest != nil else { return }
        saving = Task { [self] in
            defer { saving = nil }
            while let snapshot = latest {
                latest = nil; parent.onStatus(.saving)
                do {
                    // This closure captures the original project/object and checks revision.
                    loadedRevision = try await parent.onSave(snapshot, loadedRevision)
                    dirty = latest != nil
                    if !disposed { parent.onStatus(dirty ? .editing : .saved) }
                } catch {
                    if latest == nil { latest = snapshot }
                    if !disposed { parent.onStatus(.failed(error.localizedDescription)) }
                    return
                }
            }
            if !disposed { update(parent) }
        }
    }
    func dispose() {
        guard !retiring else { return }; retiring = true
        // Keep this exact page alive until its final draft is handed to the original
        // object's service. A navigation never redirects a late save to another object.
        let page = web
        Task { [self, page] in
            if ready { _ = try? await page?.callAsyncJavaScript("await window.floeChemistry.flush(); window.floeChemistry.dispose();", arguments: [:], in: nil, contentWorld: .page) }
            if let saving { await saving.value }
            disposed = true
            page?.configuration.userContentController.removeScriptMessageHandler(forName: "chemistry")
            page?.stopLoading(); page?.navigationDelegate = nil; web = nil
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url, url.scheme == "floechem", url.host == "editor", navigationAction.targetFrame?.isMainFrame == true else { return .cancel }
        return .allow
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { parent.onStatus(.failed(error.localizedDescription)) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { parent.onStatus(.failed("The structure editor stopped. Reopen the saved object to continue.")) }
}
