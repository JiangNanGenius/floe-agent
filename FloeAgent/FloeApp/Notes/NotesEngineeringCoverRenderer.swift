// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit) && canImport(WebKit) && canImport(Network)
import Foundation
import UIKit
import WebKit
import os
import FloeWorkspace

/// One app-wide, offscreen CAD cover renderer shared by every Notes library
/// card.
///
/// An engineering grid can contain many drawings. Starting a WebKit host (and
/// its workers/WASM decoders) per card would be neither bounded nor affordable,
/// so every card funnels through this single renderer: one `WKWebView`, one
/// `LocalPreviewServer`, one in-flight render. Requests are serialized with a
/// bounded queue, each render has a hard timeout and honors cancellation, and
/// the server and web view are torn down once idle. The renderer only ever
/// returns pixels the bundled viewer actually painted from the document's own
/// bytes — never a generic icon or a file name.
@MainActor
final class NotesEngineeringCoverRenderer: NSObject {
    struct Outcome {
        var image: UIImage?
        /// Local diagnosis for tests/logs; never shown in product UI.
        var diagnosis: String
    }

    static let shared = NotesEngineeringCoverRenderer()

    /// Hard bound on one cover render. DWG conversion and mesh/surface
    /// tessellation are slower than a bitmap decode, so this is generous but
    /// finite.
    static let perRequestTimeout: Duration = .seconds(25)
    /// Hard bound on loading the bundled viewer page. Without this, a stuck
    /// navigation would keep `ensureHost` suspended forever: `perRequestTimeout`
    /// only covers the JS bridge, not `WKWebView.load`.
    static let navigationTimeout: Duration = .seconds(15)
    /// The bundled viewer streams a base64 package through JavaScript. Card
    /// covers are far smaller than the full 20 MB preview limit, and this bounds
    /// both the JSON materialization and the web process memory.
    static let maximumSourceBytes = 8 * 1024 * 1024
    /// Keep the server/web view only while cards are rendering, then reclaim
    /// them. A cancelled or failed render tears down immediately.
    static let idleTimeout: Duration = .seconds(20)
    /// Bounded wait queue. Only small metadata (URL, name, size) is retained
    /// while waiting; bytes are read when a request reaches the head.
    static let maximumQueuedRequests = 16

    private struct Request {
        let id: UUID
        let source: URL
        let fileName: String
        let fileExtension: String
        let size: CGSize
        let continuation: CheckedContinuation<Outcome, Never>
    }

    private let logger = Logger(subsystem: "ai.floe.notes", category: "engineering-cover")
    private var queue: [Request] = []
    private var active: Task<Void, Never>?
    private var activeRequest: UUID?
    private var web: WKWebView?
    private var server: LocalPreviewServer?
    private var pageURL: URL?
    private var hostSize: CGSize = .zero
    private var pageLoad: PageLoadState?
    private var idleTask: Task<Void, Never>?

    private override init() { super.init() }

    /// Renders a bounded, read-only cover for a validated engineering file.
    func thumbnail(source: URL, fileName: String, fileExtension: String, size: CGSize) async -> Outcome {
        guard isValid(fileName: fileName, fileExtension: fileExtension, size: size) else {
            return Outcome(image: nil, diagnosis: "invalid parameters")
        }
        guard queue.count < Self.maximumQueuedRequests else {
            return Outcome(image: nil, diagnosis: "cover queue full")
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
                // Cancellation can be observed before this continuation body
                // runs (already-cancelled task). Enqueueing then would render a
                // card nobody is waiting for, so settle it here and never take a
                // queue slot.
                guard !Task.isCancelled else {
                    continuation.resume(returning: Outcome(image: nil, diagnosis: "cancelled"))
                    return
                }
                queue.append(Request(id: id, source: source, fileName: fileName,
                                     fileExtension: fileExtension, size: size, continuation: continuation))
                pump()
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
    }

    // MARK: - Validation

    private func isValid(fileName: String, fileExtension: String, size: CGSize) -> Bool {
        guard size.width > 0, size.height > 0,
              size.width <= 2048, size.height <= 2048,
              !fileName.isEmpty, fileName == (fileName as NSString).lastPathComponent,
              !fileName.contains("\\"), !fileName.contains(":"),
              fileName.utf8.count <= 255,
              fileExtension == (fileExtension as NSString).lastPathComponent,
              fileExtension == fileExtension.lowercased(),
              (fileName as NSString).pathExtension.lowercased() == fileExtension else {
            return false
        }
        guard let kind = EngineeringPreviewKind.identify(fileName) else { return false }
        return kind != .unsupported
    }

    // MARK: - Serialized queue

    private func pump() {
        guard active == nil, !queue.isEmpty else { return }
        let request = queue.removeFirst()
        activeRequest = request.id
        let task = Task { @MainActor [weak self] in
            guard let self else {
                request.continuation.resume(returning: Outcome(image: nil, diagnosis: "renderer released"))
                return
            }
            let outcome = await self.perform(request)
            request.continuation.resume(returning: outcome)
            if self.activeRequest == request.id { self.activeRequest = nil }
            self.active = nil
            self.pump()
            self.scheduleIdleTeardown()
        }
        active = task
    }

    private func cancel(_ id: UUID) {
        if let index = queue.firstIndex(where: { $0.id == id }) {
            queue.remove(at: index).continuation.resume(returning: Outcome(image: nil, diagnosis: "cancelled"))
            return
        }
        guard activeRequest == id else { return }
        _ = web?.evaluateJavaScript("window.floeEngineeringAbort && window.floeEngineeringAbort();",
                                    completionHandler: nil)
        active?.cancel()
        // The in-flight task always resumes its continuation (bounded by the
        // request timeout), so the teardown below is best-effort and safe to
        // repeat.
        teardown()
    }

    // MARK: - One render

    private func perform(_ request: Request) async -> Outcome {
        if Task.isCancelled { return Outcome(image: nil, diagnosis: "cancelled") }
        let data: Data
        do {
            data = try await Self.read(source: request.source, maximumBytes: Self.maximumSourceBytes)
        } catch is CancellationError {
            return Outcome(image: nil, diagnosis: "cancelled")
        } catch {
            return Outcome(image: nil, diagnosis: "drawing unreadable")
        }
        if Task.isCancelled { return Outcome(image: nil, diagnosis: "cancelled") }

        let package: EngineeringPreviewPackage
        do {
            package = try EngineeringPreviewPackage.single(name: request.fileName, bytes: data)
        } catch {
            return Outcome(image: nil, diagnosis: "drawing too large or unsupported")
        }
        guard let packageJSON = try? JSONEncoder().encode(package).asUTF8String else {
            return Outcome(image: nil, diagnosis: "drawing could not be encoded")
        }
        if Task.isCancelled { return Outcome(image: nil, diagnosis: "cancelled") }

        do {
            try await ensureHost(size: request.size)
        } catch {
            teardown()
            return Outcome(image: nil, diagnosis: "drawing viewer unavailable")
        }
        guard let web, pageURL != nil, !Task.isCancelled else {
            teardown()
            return Outcome(image: nil, diagnosis: "cancelled")
        }
        do {
            let result = try await Self.runBridge(on: web, packageJSON: packageJSON,
                                                  size: request.size, timeout: Self.perRequestTimeout)
            return try Self.decode(result)
        } catch is CancellationError {
            teardown()
            return Outcome(image: nil, diagnosis: "cancelled")
        } catch {
            // A hung or crashed web process is reclaimed rather than reused.
            logger.error("[engineering-cover] render failed")
            teardown()
            return Outcome(image: nil, diagnosis: "drawing render failed")
        }
    }

    private nonisolated static func read(source: URL, maximumBytes: Int) async throws -> Data {
        let worker = Task.detached(priority: .utility) {
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let byteCount = values.fileSize,
                  byteCount > 0, byteCount <= maximumBytes else {
                throw CoverError.sourceRejected
            }
            let handle = try FileHandle(forReadingFrom: source)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
            try Task.checkCancellation()
            guard data.count <= maximumBytes else { throw CoverError.sourceRejected }
            return data
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    // MARK: - Web host lifecycle

    private func ensureHost(size: CGSize) async throws {
        if web != nil, pageURL != nil,
           abs(hostSize.width - size.width) < 0.5, abs(hostSize.height - size.height) < 0.5 {
            idleTask?.cancel(); idleTask = nil
            return
        }
        teardown()
        guard let root = Bundle.main.url(forResource: "EngineeringViewers", withExtension: nil) else {
            throw CoverError.viewerUnavailable
        }
        let (started, session) = try await LocalPreviewServer.start(root: root, entry: "index.html")
        server = started
        pageURL = session.url
        hostSize = size

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let options: [String: Any] = [
            "language": Locale.current.identifier,
            "dark": false,
            "canReview": false,
            "canEdit": false,
            // Keeps the 2D canvas readable for the read-only thumbnail export.
            "thumbnail": true
        ]
        if let bytes = try? JSONSerialization.data(withJSONObject: options),
           let json = String(data: bytes, encoding: .utf8) {
            configuration.userContentController.addUserScript(WKUserScript(
                source: "window.floeEngineeringConfiguration = \(json);",
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        let webView = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: configuration)
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.scrollView.isScrollEnabled = false
        web = webView
        try await loadPage(webView, url: session.url)
    }

    /// Loads the viewer page with a hard timeout and single-resume semantics.
    /// The continuation is stored in a state object (not a bare property) so a
    /// delegate callback or timeout that fires before the continuation is
    /// attached can never orphan it, and so the timeout task is always
    /// cancelled once the page settles.
    private func loadPage(_ webView: WKWebView, url: URL) async throws {
        let state = PageLoadState()
        pageLoad = state
        defer { if pageLoad === state { pageLoad = nil } }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard state.attach(continuation) else { return }
                webView.load(URLRequest(url: url))
                state.timeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: Self.navigationTimeout)
                    guard !Task.isCancelled else { return }
                    // A hung navigation would otherwise suspend the whole
                    // render queue; fail and reclaim the host.
                    self?.finishPageLoad(.failure(CoverError.viewerUnavailable))
                    self?.teardown()
                }
            }
        } onCancel: {
            Task { @MainActor in self.finishPageLoad(.failure(CancellationError())) }
        }
    }

    private func finishPageLoad(_ result: Result<Void, Error>) {
        pageLoad?.finish(result)
    }

    private func teardown() {
        idleTask?.cancel(); idleTask = nil
        finishPageLoad(.failure(CancellationError()))
        pageLoad = nil
        web?.stopLoading()
        web?.navigationDelegate = nil
        web = nil
        server?.stop()
        server = nil
        pageURL = nil
        hostSize = .zero
    }

    /// Single-resume page-load guard. Both `attach` and `finish` are
    /// main-actor isolated, so a delegate callback or timeout that wins the
    /// race resumes the continuation as soon as it is attached rather than
    /// dropping it.
    @MainActor
    private final class PageLoadState {
        private var continuation: CheckedContinuation<Void, Error>?
        private var pending: Result<Void, Error>?
        private var finished = false
        var timeoutTask: Task<Void, Never>?

        func attach(_ continuation: CheckedContinuation<Void, Error>) -> Bool {
            guard !finished else {
                continuation.resume(with: pending ?? .failure(CoverError.viewerUnavailable))
                return false
            }
            self.continuation = continuation
            return true
        }

        func finish(_ result: Result<Void, Error>) {
            guard !finished else { return }
            finished = true
            pending = result
            timeoutTask?.cancel(); timeoutTask = nil
            let continuation = continuation
            self.continuation = nil
            continuation?.resume(with: result)
        }
    }

    private func scheduleIdleTeardown() {
        guard queue.isEmpty, active == nil else { return }
        idleTask?.cancel()
        idleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.idleTimeout)
            guard !Task.isCancelled, let self, self.queue.isEmpty, self.active == nil else { return }
            self.teardown()
        }
    }

    // MARK: - Read-only JS bridge

    private static func runBridge(on web: WKWebView, packageJSON: String, size: CGSize,
                                  timeout: Duration) async throws -> Any? {
        let state = BridgeState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
                // Attach before starting the JS: if cancellation already won,
                // `attach` resumes immediately and no request is started.
                guard state.attach(continuation) else { return }
                web.callAsyncJavaScript(
                    "return await window.floeEngineeringThumbnail(pkgJson, width, height);",
                    arguments: ["pkgJson": packageJSON, "width": Int(size.width), "height": Int(size.height)],
                    in: nil,
                    in: .page
                ) { result in
                    // The completion handler is already main-actor isolated.
                    switch result {
                    case .success(let value): state.finish(.success(value))
                    case .failure(let error): state.finish(.failure(error))
                    }
                }
                state.timeoutTask = Task { @MainActor in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    _ = try? await web.evaluateJavaScript(
                        "window.floeEngineeringAbort && window.floeEngineeringAbort();")
                    state.finish(.failure(CoverError.timedOut))
                }
            }
        } onCancel: {
            Task { @MainActor in state.finish(.failure(CancellationError())) }
        }
    }

    private static func decode(_ result: Any?) throws -> Outcome {
        guard let dictionary = result as? [String: Any],
              (dictionary["ok"] as? Bool) == true,
              let dataURL = dictionary["dataURL"] as? String,
              dataURL.hasPrefix("data:image/png;base64,"),
              dataURL.utf8.count <= 16 * 1024 * 1024 else {
            let reason = (result as? [String: Any])?["error"] as? String
            throw CoverError.bridgeRejected(reason ?? "unusable render result")
        }
        let base64 = String(dataURL.dropFirst("data:image/png;base64,".count))
        guard let data = Data(base64Encoded: base64), let image = UIImage(data: data),
              image.size.width > 0, image.size.height > 0, image.cgImage != nil else {
            throw CoverError.bridgeRejected("empty image")
        }
        // `toDataURL` returning a non-empty PNG only proves the canvas exists,
        // not that anything was painted. An offscreen WKWebView can return a
        // uniformly blank buffer, so reject it here instead of publishing a
        // blank cover as `.engineeringPreview`.
        guard hasVisibleGeometry(image) else {
            throw CoverError.bridgeRejected("viewer painted no geometry")
        }
        return Outcome(image: image, diagnosis: "bundled viewer")
    }

    /// Conservative content check: a blank canvas is a single uniform color,
    /// while real geometry introduces either foreground coverage over a
    /// transparent backdrop (gerber) or luminance contrast over an opaque
    /// backdrop (DXF/DWG/mesh). Sampled at a small fixed size so the cost is
    /// bounded regardless of the requested cover size.
    private nonisolated static func hasVisibleGeometry(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage else { return false }
        let width = min(cgImage.width, 96)
        let height = min(cgImage.height, 96)
        guard width > 1, height > 1 else { return false }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        return pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            let buffer = raw.bindMemory(to: UInt8.self)
            let total = width * height
            var opaque = 0
            var minimum = Double.greatestFiniteMagnitude
            var maximum = 0.0
            for index in 0..<total {
                let offset = index * 4
                let alpha = Double(buffer[offset + 3]) / 255
                guard alpha >= 0.04 else { continue }
                opaque += 1
                let luminance = (0.2126 * Double(buffer[offset])
                                 + 0.7152 * Double(buffer[offset + 1])
                                 + 0.0722 * Double(buffer[offset + 2])) / 255
                minimum = min(minimum, luminance)
                maximum = max(maximum, luminance)
            }
            guard opaque >= 8 else { return false }
            let opaqueFraction = Double(opaque) / Double(total)
            if opaqueFraction < 0.995 {
                // Foreground over a transparent/partial backdrop: enough coverage.
                return opaqueFraction >= 0.005
            }
            // Fully opaque: require real contrast between background and drawing.
            return maximum - minimum > 0.12
        }
    }

    private enum CoverError: Error {
        case sourceRejected
        case viewerUnavailable
        case timedOut
        case bridgeRejected(String)
    }

    /// Single-resume guard shared by the JS callback, the timeout and
    /// cancellation, so a late callback can never double-resume. A result that
    /// arrives before the continuation is attached is retained and delivered on
    /// `attach`, so a cancellation racing the bridge start cannot hang, and the
    /// timeout task is always cancelled once the bridge settles.
    @MainActor
    private final class BridgeState {
        private var continuation: CheckedContinuation<Any?, Error>?
        private var pending: Result<Any?, Error>?
        private var finished = false
        var timeoutTask: Task<Void, Never>?

        func attach(_ continuation: CheckedContinuation<Any?, Error>) -> Bool {
            guard !finished else {
                continuation.resume(with: pending ?? .failure(CoverError.timedOut))
                return false
            }
            self.continuation = continuation
            return true
        }

        func finish(_ result: Result<Any?, Error>) {
            guard !finished else { return }
            finished = true
            pending = result
            timeoutTask?.cancel(); timeoutTask = nil
            let continuation = continuation
            self.continuation = nil
            continuation?.resume(with: result)
        }
    }
}

extension NotesEngineeringCoverRenderer: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        // A torn-down or replaced host must not steer the current one.
        guard webView === web else { decisionHandler(.cancel); return }
        // Only the exact loopback preview page may navigate; never a data:,
        // file: or remote URL.
        decisionHandler(navigationAction.request.url == pageURL ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === web else { return }
        finishPageLoad(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === web else { return }
        finishPageLoad(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === web else { return }
        finishPageLoad(.failure(error))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === web else { return }
        finishPageLoad(.failure(CoverError.viewerUnavailable))
        teardown()
    }
}

private extension Data {
    var asUTF8String: String? { String(data: self, encoding: .utf8) }
}
#endif
