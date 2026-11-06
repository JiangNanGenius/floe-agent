// SPDX-License-Identifier: MPL-2.0
import Foundation
import WebKit
import FloeCore

/// A service-owned, disposable on-device WASM process. Only the fixed bundled
/// adapter executes; snapshot strings enter through JavaScript arguments.
@MainActor
final class CADBuildingLocalIFCHost: NSObject, WKNavigationDelegate {
    nonisolated struct Output: Sendable {
        var ifc: Data
        var ids: Data?
        var metadata: Data
    }
    private var web: WKWebView?
    private var server: LocalPreviewServer?
    private var pageRoot: URL?
    private var navigationError: Error?
    private var closed = false
    private var timedOut = false
    private var pending: CheckedContinuation<String, Error>?
    private var pendingID: UUID?
    private struct Manifest: Decodable { var schemaVersion: Int; var backend: String; var version: String; var files: [String: String] }

    private func verifiedAssets() throws -> URL {
        guard let root = Bundle.main.url(forResource: "BuildingNative", withExtension: nil) else {
            throw FloeError.validationFailed("Building calculation resources are unavailable.")
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        guard manifest.schemaVersion == 1, manifest.backend == "web-ifc", manifest.version == "0.0.75",
              Set(manifest.files.keys) == ["index.html", "building.js", "web-ifc-api-iife.js", "web-ifc.wasm"] else {
            throw FloeError.validationFailed("The local IFC resources are incomplete.")
        }
        for (name, hash) in manifest.files {
            let bytes = try Data(contentsOf: root.appendingPathComponent(name))
            guard bytes.count <= 8 * 1024 * 1024, FloeDigest.sha256Hex(bytes) == hash else {
                throw FloeError.validationFailed("The local IFC resources failed their integrity check.")
            }
        }
        return root
    }

    func run(input: Data) async throws -> Output {
        guard web == nil, !closed, input.count <= 64 * 1024 * 1024,
              let json = String(data: input, encoding: .utf8) else {
            throw FloeError.validationFailed("Building calculation resources are unavailable.")
        }
        let assets = try verifiedAssets()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 64, height: 64), configuration: configuration)
        view.navigationDelegate = self
        web = view
        let deadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(300)) } catch { return }
            self?.timedOut = true; self?.close()
        }
        defer { deadline.cancel(); close() }
        let (server, session) = try await LocalPreviewServer.start(root: assets, entry: "index.html")
        guard !closed, !Task.isCancelled else { server.stop(); throw CancellationError() }
        self.server = server
        pageRoot = session.url.deletingLastPathComponent()
        view.load(URLRequest(url: session.url))
        var ready = false
        for _ in 0..<450 {
            try checkRunning()
            if let navigationError { throw navigationError }
            if (try? await evaluate("return String(typeof FloeBuilding === 'object' && FloeBuilding.ready === true);", arguments: [:], in: view)) == "true" {
                ready = true; break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard ready else { throw FloeError.validationFailed("The local IFC engine did not become ready.") }
        try checkRunning()
        let raw = try await evaluate("return await FloeBuilding.run(inputJSON);", arguments: ["inputJSON": json], in: view)
        try checkRunning()
        guard let metadata = raw.data(using: .utf8), metadata.count <= 2 * 1024 * 1024,
              let receipt = try JSONSerialization.jsonObject(with: metadata) as? [String: Any],
              let ifcBytes = receipt["ifcBytes"] as? Int, let idsBytes = receipt["idsBytes"] as? Int,
              (1...128 * 1024 * 1024).contains(ifcBytes), (0...2 * 1024 * 1024).contains(idsBytes) else {
            throw FloeError.validationFailed("The local IFC engine returned an invalid receipt.")
        }
        let ifc = try await read(name: "ifc", count: ifcBytes, from: view)
        let ids = idsBytes > 0 ? try await read(name: "ids", count: idsBytes, from: view) : nil
        try checkRunning()
        return Output(ifc: ifc, ids: ids, metadata: metadata)
    }
    private func read(name: String, count: Int, from view: WKWebView) async throws -> Data {
        var data = Data(); data.reserveCapacity(count)
        while data.count < count {
            try checkRunning()
            let raw = try await evaluate("return FloeBuilding.chunk(name, offset);", arguments: ["name": name, "offset": data.count], in: view)
            guard let chunk = Data(base64Encoded: raw), !chunk.isEmpty,
                  chunk.count <= 49_152, data.count + chunk.count <= count else {
                throw FloeError.validationFailed("A local IFC output chunk is incomplete.")
            }
            data.append(chunk)
        }
        return data
    }
    private func evaluate(_ body: String, arguments: [String: Any], in view: WKWebView) async throws -> String {
        try checkRunning()
        guard pending == nil else { throw FloeError.validationFailed("The local IFC engine is busy.") }
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            pendingID = id; pending = continuation
            view.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { [weak self] result in
                guard let self, pendingID == id else { return }
                pendingID = nil
                let completion = pending; pending = nil
                switch result {
                case .success(let value):
                    guard let string = value as? String else {
                        completion?.resume(throwing: FloeError.validationFailed("The local IFC engine returned invalid data.")); return
                    }
                    completion?.resume(returning: string)
                case .failure(let error): completion?.resume(throwing: error)
                }
            }
        }
    }
    private func checkRunning() throws {
        if timedOut { throw FloeError.validationFailed("The local IFC calculation timed out.") }
        guard !closed else { throw CancellationError() }
        try Task.checkCancellation()
    }
    func close() {
        closed = true
        pendingID = nil
        let completion = pending; pending = nil
        if timedOut { completion?.resume(throwing: FloeError.validationFailed("The local IFC calculation timed out.")) }
        else { completion?.resume(throwing: navigationError ?? CancellationError()) }
        server?.stop(); server = nil
        web?.stopLoading(); web?.navigationDelegate = nil
        web?.removeFromSuperview(); web = nil
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationError = error }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { navigationError = error }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        navigationError = FloeError.validationFailed("The local IFC calculation was interrupted.")
        close()
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let root = pageRoot, let url = navigationAction.request.url,
              url.scheme == root.scheme, url.host == root.host, url.port == root.port,
              url.path.hasPrefix(root.path + (root.path.hasSuffix("/") ? "" : "/")) else { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
}
