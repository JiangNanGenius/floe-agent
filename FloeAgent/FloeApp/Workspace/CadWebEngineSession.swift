// SPDX-License-Identifier: MPL-2.0
// FloeApp — disposable WKWebView host for the bundled Rust CAD engine.
//
// Agent tools and the Drawing Assistant need the engine without a visible
// editor. This host runs the same `cad-worker.js` Worker (same wasm, same
// typed operations) inside an offscreen WKWebView served by the local preview
// server:
//   * containment: on timeout or close the WKWebView is destroyed (loader
//     stopped, handlers removed, reference released), which terminates the
//     page and its Worker — there is no in-process evaluation that cannot be
//     stopped;
//   * bounded: the wasm build caps linear memory at 384 MiB and the engine
//     enforces 10 MiB files / 20k entities / bounded history;
//   * one session per document revision; a timed-out session is discarded and
//     the caller opens a fresh one from bytes.

#if canImport(UIKit)
import Foundation
import WebKit
import FloeCore

@MainActor
final class CadWebEngineSession: NSObject, WKNavigationDelegate {
    private final class StateBox: @unchecked Sendable {
        let lock = NSLock()
        var closed = false
    }

    private let state = StateBox()
    private var web: WKWebView?
    private var server: LocalPreviewServer?
    private var loaded = false
    private var navigationCompletion: ((Error?) -> Void)?
    private let defaultTimeout: TimeInterval

    init(timeout: TimeInterval = 45) {
        self.defaultTimeout = timeout
        super.init()
    }

    /// Readable from any isolation domain; a terminated session is never reused.
    nonisolated var isTerminated: Bool {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.closed
    }

    private var closed: Bool {
        get { isTerminated }
        set {
            state.lock.lock(); defer { state.lock.unlock() }
            state.closed = newValue
        }
    }

    /// Starts the hidden page and waits until the Worker is ready.
    func start(timeout: TimeInterval? = nil) async throws {
        let deadline = timeout ?? defaultTimeout
        if loaded { return }
        try Task.checkCancellation()
        guard let root = Bundle.main.url(forResource: "EngineeringViewers", withExtension: nil) else {
            throw CadEngineHostError.assetsMissing("EngineeringViewers")
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let errorCapture = """
        window.__floeHostErrors = [];
        window.addEventListener('error', function (event) {
          window.__floeHostErrors.push(String(event.message || event.error));
        });
        window.addEventListener('unhandledrejection', function (event) {
          window.__floeHostErrors.push('rejection: ' + String(event.reason));
        });
        """
        config.userContentController.addUserScript(WKUserScript(
            source: errorCapture, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 64, height: 64), configuration: config)
        web.navigationDelegate = self
        web.isOpaque = false
        self.web = web
        do {
            let (server, session) = try await LocalPreviewServer.start(root: root, entry: "cad-host.html")
            self.server = server
            do {
                try await withDeadline(deadline) { [weak self] in
                    guard let self else { throw CadEngineHostError.unavailable }
                    try await self.load(page: session.url)
                    // Module scripts normally run before the load event, but
                    // simulator scheduling can make them land just after
                    // didFinish; poll briefly and report captured page errors
                    // instead of failing with an opaque type error.
                    var readyState = "unknown"
                    var isReady = false
                    for _ in 0..<60 {
                        readyState = try await self.evaluate(
                            "return (typeof window.floeCadHostReady === 'function') ? 'function' : (document.readyState + ' errors=' + JSON.stringify(window.__floeHostErrors || []));",
                            arguments: [:], timeout: deadline)
                        if readyState == "function" {
                            isReady = true
                            break
                        }
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }
                    guard isReady else {
                        throw CadEngineHostError.engine("CAD host not ready: \(readyState)")
                    }
                    let ready = try await self.evaluate(
                        "return (await window.floeCadHostReady()) ? 'ready' : 'no';",
                        arguments: [:], timeout: deadline)
                    guard ready == "ready" else {
                        throw CadEngineHostError.engine("CAD host did not report ready")
                    }
                }
            } catch {
                destroy()
                throw error
            }
            loaded = true
        } catch {
            destroy()
            throw error
        }
    }

    func open(bytes: Data, format: String) async throws -> String {
        try await hostCall("open", payload: ["bytes": bytes.base64EncodedString(), "format": format])
    }

    func edit(_ requestJSON: String) async throws -> String {
        try await hostCall("edit", payload: ["edit": requestJSON])
    }

    func query(_ requestJSON: String) async throws -> String {
        try await hostCall("query", payload: ["request": requestJSON])
    }

    func inspect(offset: Int, limit: Int) async throws -> String {
        try await hostCall("inspect", payload: ["offset": offset, "limit": limit])
    }

    /// Rolls the in-memory engine back by exactly one edit snapshot. Used to
    /// restore the pre-apply revision when a commit fails.
    func undo() async throws {
        _ = try await hostCall("undo", payload: [:])
    }

    func save() async throws -> Data {
        let base64 = try await hostCall("save", payload: [:])
        guard let data = Data(base64Encoded: base64), !data.isEmpty else {
            throw CadEngineHostError.engine("CAD engine returned no saved bytes")
        }
        return data
    }

    func displayDXF() async throws -> Data {
        let base64 = try await hostCall("dxf", payload: [:])
        guard let data = Data(base64Encoded: base64), !data.isEmpty else {
            throw CadEngineHostError.engine("CAD engine returned no DXF projection")
        }
        return data
    }

    /// Terminates the page and its Worker; the instance must not be reused.
    func shutdown() async {
        if !closed, loaded {
            _ = try? await withDeadline(5) { [weak self] in
                guard let self else { return }
                _ = try await self.evaluate(
                    "return await window.floeCadHostCall(operation, payload);",
                    arguments: ["operation": "shutdown", "payload": [:]],
                    timeout: 5)
            }
        }
        destroy()
    }

    // MARK: - Plumbing

    private func hostCall(_ operation: String, payload: [String: Any]) async throws -> String {
        if closed { throw CadEngineHostError.unavailable }
        guard loaded, web != nil else { throw CadEngineHostError.unavailable }
        return try await evaluate(
            "return String(await window.floeCadHostCall(operation, payload));",
            arguments: ["operation": operation, "payload": payload],
            timeout: defaultTimeout)
    }

    private func evaluate(_ body: String, arguments: [String: Any], timeout: TimeInterval) async throws -> String {
        guard let web else { throw CadEngineHostError.unavailable }
        do {
            return try await withCheckedThrowingContinuation { continuation in
                let state = ResumeOnceString(continuation: continuation)
                Task { @MainActor in
                    do {
                        let value = try await web.callAsyncJavaScript(
                            body, arguments: arguments, contentWorld: .page)
                        if let string = value as? String {
                            state.succeed(string)
                        } else {
                            state.succeed(String(describing: value))
                        }
                    } catch {
                        state.fail(error)
                    }
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0.01, timeout)) { [weak self] in
                    guard let self, state.fail(CadEngineHostError.timedOut) else { return }
                    Task { @MainActor in self.destroy() }
                }
            }
        } catch {
            destroy()
            throw error
        }
    }

    private func withDeadline(_ seconds: TimeInterval, _ operation: @escaping @MainActor () async throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = ResumeOnceVoid(continuation: continuation)
            Task { @MainActor in
                do {
                    try await operation()
                    once.succeed()
                } catch {
                    once.fail(error)
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0.01, seconds)) {
                once.fail(CadEngineHostError.timedOut)
            }
        }
    }

    private func load(page: URL) async throws {
        guard let web, !loaded else { throw CadEngineHostError.unavailable }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let state = ResumeOnceVoid(continuation: continuation)
            navigationCompletion = { error in
                if let error { state.fail(error) } else { state.succeed() }
            }
            web.load(URLRequest(url: page))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationCompletion?(nil)
        navigationCompletion = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationCompletion?(error)
        navigationCompletion = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationCompletion?(error)
        navigationCompletion = nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        closed = true
    }

    private func destroy() {
        closed = true
        server?.stop()
        server = nil
        if let web {
            web.stopLoading()
            web.navigationDelegate = nil
            web.configuration.userContentController.removeAllScriptMessageHandlers()
            web.removeFromSuperview()
        }
        web = nil
    }
}

enum CadEngineHostError: LocalizedError {
    case assetsMissing(String)
    case unavailable
    case timedOut
    case engine(String)

    var errorDescription: String? {
        switch self {
        case .assetsMissing(let name): "CAD engine asset is missing: \(name)"
        case .unavailable: "CAD engine is unavailable"
        case .timedOut: "CAD engine call timed out"
        case .engine(let message): message
        }
    }
}

/// Resumes a string continuation exactly once under concurrent success/failure.
private final class ResumeOnceString: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private let continuation: CheckedContinuation<String, Error>

    init(continuation: CheckedContinuation<String, Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func succeed(_ value: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return false }
        finished = true
        continuation.resume(returning: value)
        return true
    }

    @discardableResult
    func fail(_ error: Error) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return false }
        finished = true
        continuation.resume(throwing: error)
        return true
    }
}

/// Resumes a void continuation exactly once under concurrent success/failure.
private final class ResumeOnceVoid: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private let continuation: CheckedContinuation<Void, Error>

    init(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func succeed() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return false }
        finished = true
        continuation.resume()
        return true
    }

    @discardableResult
    func fail(_ error: Error) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return false }
        finished = true
        continuation.resume(throwing: error)
        return true
    }
}
#endif
