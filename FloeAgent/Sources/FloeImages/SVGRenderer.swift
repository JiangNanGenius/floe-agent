// FloeImages — bounded native SVG raster rendering.
//
// SPDX-License-Identifier: MPL-2.0
//
// The chat preview and the image.renderSVG tool share ONE renderer so
// what the user sees is exactly what the tool encodes.
//
// Embedding route (chosen with actual pixels, see HANDOFF): the
// validated SVG is embedded as an isolated `data:image/svg+xml`
// <img> inside a tiny native-authored HTML page with CSP
// `default-src 'none'; img-src data:; style-src 'unsafe-inline'` and
// JavaScript disabled. SVG-as-image semantics give platform-level
// hardening on top of the validator: scripts never run, event
// handlers never fire and external references never load inside an
// image context. Unlike raw HTML interpolation this route parses the
// payload as an XML image document, so qualified `svg:svg` roots,
// CDATA sections and <style> behave exactly as authored, and nested
// <svg> viewports are untouched (no global `svg{...}` CSS). The
// navigation delegate admits ONLY the first main-frame about:
// document load; the img payload is a CSP-governed subresource.
//
// WebKit generates a transparent PDF in memory. CoreGraphics rasterizes
// that generated page into an exact pixel-sized bitmap; no external PDF
// document is opened. A background-only first capture gets one bounded
// retry, while valid white/transparent documents remain valid outputs.
// Nothing here has any provider, Linux or network path.

#if canImport(WebKit)
import Foundation
import CoreGraphics
import ImageIO
import WebKit
import FloeTools
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Opaque backing fill used while rendering. PNG uses the caller's
/// choice (transparent by default); the tool's JPEG path always asks
/// for white so transparent SVG content never turns into a black box.
public enum SVGBackground: Sendable, Hashable {
    case transparent
    case white
    case rgb(red: Double, green: Double, blue: Double)

    /// Accepts "transparent", "white" and "#rrggbb" (case-insensitive).
    public static func parse(_ text: String?) -> SVGBackground? {
        guard let text else { return nil }
        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch lower {
        case "transparent": return .transparent
        case "white": return .white
        default:
            guard lower.hasPrefix("#"), lower.count == 7,
                  lower.dropFirst().allSatisfy({ $0.isHexDigit }) else { return nil }
            let digits = Array(lower.dropFirst())
            func component(_ offset: Int) -> Double? {
                guard let value = Int(String(digits[offset...(offset + 1)]), radix: 16) else { return nil }
                return Double(value) / 255.0
            }
            guard let r = component(0), let g = component(2), let b = component(4) else { return nil }
            return .rgb(red: r, green: g, blue: b)
        }
    }

    fileprivate func apply(to context: CGContext) {
        switch self {
        case .transparent:
            break
        case .white:
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        case .rgb(let r, let g, let b):
            context.setFillColor(red: r, green: g, blue: b, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        }
    }

    /// The premultiplied RGBA8 bytes a fully-covered blank capture
    /// would show for this background.
    fileprivate var expectedBlankBytes: (UInt8, UInt8, UInt8, UInt8) {
        switch self {
        case .transparent: return (0, 0, 0, 0)
        case .white: return (255, 255, 255, 255)
        case .rgb(let r, let g, let b):
            return (
                UInt8((max(0, min(1, r)) * 255).rounded()),
                UInt8((max(0, min(1, g)) * 255).rounded()),
                UInt8((max(0, min(1, b)) * 255).rounded()),
                255)
        }
    }
}

public enum SVGRenderingError: Error, Sendable, Hashable, LocalizedError {
    case cancelled
    case timedOut
    case webContentTerminated
    case snapshotFailed
    case blankCapture
    case rendererUnavailable
    case encodeFailed(String)
    case busy

    public var errorDescription: String? {
        switch self {
        case .cancelled: return "SVG rendering was cancelled"
        case .timedOut: return "SVG rendering timed out"
        case .webContentTerminated: return "The SVG renderer process stopped unexpectedly"
        case .snapshotFailed: return "SVG snapshot produced no pixels"
        case .blankCapture: return "SVG snapshot produced no visible pixels although the document paints content"
        case .rendererUnavailable: return "SVG rendering is unavailable on this platform"
        case .encodeFailed(let detail): return "SVG raster encoding failed: \(detail)"
        case .busy: return "SVG renderer is at capacity; retry shortly"
        }
    }
}

/// Shared fixed ceilings for one snapshot render.
public enum SVGRenderLimits {
    public static let maxConcurrentRenders = 2
    public static let navigationTimeout: Double = 12        // seconds
    public static let snapshotTimeout: Double = 12          // seconds
    public static let capacityWaitTimeout: Double = 30      // seconds
    public static let pollIntervalNanoseconds: UInt64 = 100_000_000
    /// Subresource settle before the first snapshot, and the longer
    /// settle used by the single blank-capture retry.
    public static let settleNanoseconds: UInt64 = 250_000_000
    public static let retrySettleNanoseconds: UInt64 = 600_000_000
    public static let blankSampleMax = 4_096
}

public enum SVGRendering {
    /// Renders the validated document into `width`×`height` PNG bytes
    /// (alpha preserved). Honors the native cancellation flag (not
    /// only Swift Task cancellation) and hard timeouts.
    public static func renderPNG(
        document: ValidatedSVGDocument,
        width: Int,
        height: Int,
        background: SVGBackground = .transparent,
        cancellation: CancellationToken? = nil
    ) async throws -> Data {
        try await render(document: document, width: width, height: height,
                         background: background, format: .png, quality: 0,
                         cancellation: cancellation)
    }

    /// Renders into JPEG bytes over an explicit white fill (JPEG has no
    /// alpha). `quality` is clamped by ImageFileEncoder conventions.
    public static func renderJPEG(
        document: ValidatedSVGDocument,
        width: Int,
        height: Int,
        quality: Double = ImageFileEncoder.defaultQuality,
        cancellation: CancellationToken? = nil
    ) async throws -> Data {
        try await render(document: document, width: width, height: height,
                         background: .white, format: .jpeg, quality: quality,
                         cancellation: cancellation)
    }

    /// Bounded cached preview used by the chat surface and the
    /// run-output SVG receipt loader. Repeated identical bytes hit the
    /// cache and never reload the page.
    public static func previewPNG(
        for document: ValidatedSVGDocument,
        maxEdge: Int = 960,
        cancellation: CancellationToken? = nil
    ) async throws -> Data {
        let edge = max(1, min(SVGSafetyLimits.maxOutputEdge, maxEdge))
        let key = "\(document.sourceDigest)@\(edge)"
        if let cached = await SVGPreviewCache.shared.data(forKey: key) { return cached }
        guard let size = SVGRenderSize.resolve(
            metrics: document.metrics,
            requestedWidth: nil, requestedHeight: nil,
            maxEdge: edge
        ) else {
            throw SVGRenderingError.snapshotFailed
        }
        let png = try await renderPNG(
            document: document, width: size.width, height: size.height,
            background: .transparent, cancellation: cancellation
        )
        await SVGPreviewCache.shared.setData(png, forKey: key)
        return png
    }

    // MARK: - Shared pipeline

    enum RasterFormat { case png, jpeg }

    static func render(
        document: ValidatedSVGDocument,
        width: Int,
        height: Int,
        background: SVGBackground,
        format: RasterFormat,
        quality: Double,
        cancellation: CancellationToken?
    ) async throws -> Data {
        guard width >= 1, height >= 1,
              width <= SVGSafetyLimits.maxOutputEdge,
              height <= SVGSafetyLimits.maxOutputEdge,
              width * height <= SVGSafetyLimits.maxOutputPixels else {
            throw SVGDocumentRejection.invalidDimensions(
                "target \(width)x\(height) is outside the raster ceilings")
        }
        try cancellation?.throwIfCancelled()
        // The gate owns exactly-once release even when the body throws
        // or cancellation lands mid-render.
        let data = try await SVGRenderGate.shared.withSlot(cancellation: cancellation) {
            try await SVGSnapshotRender.render(
                document: document,
                width: width, height: height,
                background: background,
                format: format, quality: quality,
                cancellation: cancellation
            )
        }
        try cancellation?.throwIfCancelled()
        return data
    }
}

/// One render slot per in-flight snapshot. Waiters poll with a bounded
/// total wait so flag-based cancellation can abandon the queue.
actor SVGRenderGate {
    static let shared = SVGRenderGate()
    private var running = 0

    /// Runs `body` with a render slot, releasing exactly once on
    /// success, thrown error and cancellation.
    func withSlot(
        cancellation: CancellationToken?,
        body: @Sendable () async throws -> Data
    ) async throws -> Data {
        try await acquire(cancellation: cancellation)
        do {
            let value = try await body()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }

    private func acquire(cancellation: CancellationToken?) async throws {
        let deadline = Date().addingTimeInterval(SVGRenderLimits.capacityWaitTimeout)
        while running >= SVGRenderLimits.maxConcurrentRenders {
            try? await Task.sleep(nanoseconds: 25_000_000)
            if Task.isCancelled || cancellation?.isCancelled == true {
                throw SVGRenderingError.cancelled
            }
            if Date() >= deadline { throw SVGRenderingError.busy }
        }
        try cancellation?.throwIfCancelled()
        running += 1
    }

    private func release() { running = max(0, running - 1) }
}

/// Count-bounded encoded-preview cache. Encoded PNG bytes only; never
/// the source document, never a live view.
public actor SVGPreviewCache {
    static let shared = SVGPreviewCache()
    private let storage = NSCache<NSString, NSData>()

    init() {
        storage.countLimit = 24
    }

    func data(forKey key: String) -> Data? {
        storage.object(forKey: key as NSString) as Data?
    }

    func setData(_ data: Data, forKey key: String) {
        storage.setObject(data as NSData, forKey: key as NSString, cost: data.count)
    }
}

/// MainActor-owned single-render WKWebView session. Created per render
/// and dropped after; a late navigation or snapshot callback can never
/// touch a finished session because every resolution path checks the
/// one-shot `resumed` flag first.
@MainActor
private final class SVGSnapshotRender: NSObject, WKNavigationDelegate {
    static func render(
        document: ValidatedSVGDocument,
        width: Int,
        height: Int,
        background: SVGBackground,
        format: SVGRendering.RasterFormat,
        quality: Double,
        cancellation: CancellationToken?
    ) async throws -> Data {
        let session = SVGSnapshotRender(
            width: width, height: height,
            background: background, format: format, quality: quality,
            expectVisibleContent: document.hasDrawableContent)
        return try await session.run(source: document.source, cancellation: cancellation)
    }

    private let width: Int
    private let height: Int
    private let background: SVGBackground
    private let format: SVGRendering.RasterFormat
    private let quality: Double
    private let expectVisibleContent: Bool
    private let configuration = WKWebViewConfiguration()
    private var webView: WKWebView?
    #if canImport(UIKit)
    /// Offscreen host window: an unattached WKWebView cannot snapshot
    /// reliably on iOS, so the view lives in a window placed far
    /// outside any display for the duration of the render only.
    private var offscreenWindow: UIWindow?
    #endif
    private var continuation: CheckedContinuation<Data, Error>?
    private var resumed = false
    private var initialLoadAllowed = true
    private var blankRetries = 0
    private var watchdog: Task<Void, Never>?

    init(width: Int, height: Int, background: SVGBackground,
         format: SVGRendering.RasterFormat, quality: Double,
         expectVisibleContent: Bool) {
        self.width = width
        self.height = height
        self.background = background
        self.format = format
        self.quality = quality
        self.expectVisibleContent = expectVisibleContent
        super.init()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    }

    func run(source: String, cancellation: CancellationToken?) async throws -> Data {
        let frame = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        let view = WKWebView(frame: frame, configuration: configuration)
        view.navigationDelegate = self
        view.underPageBackgroundColor = .clear
        #if canImport(UIKit)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        #elseif canImport(AppKit)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        #endif
        self.webView = view
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                if Task.isCancelled || cancellation?.isCancelled == true {
                    self.finish(.failure(.cancelled))
                    return
                }
                self.startWatchdog(
                    deadline: Date().addingTimeInterval(
                        SVGRenderLimits.navigationTimeout + SVGRenderLimits.snapshotTimeout),
                    cancellation: cancellation)
                view.loadHTMLString(
                    Self.pageHTML(svgSource: source, width: width, height: height),
                    baseURL: nil)
            }
        } onCancel: {
            Task { @MainActor in
                self.finish(.failure(.cancelled))
            }
        }
    }

    /// The page embeds the validated SVG as an isolated data-URL image:
    /// XML image-document parsing (qualified roots, CDATA, internal
    /// <style> all behave as authored), platform-disabled scripts and
    /// external loads, no global CSS touching nested <svg> viewports,
    /// and an explicit pixel size for the raster normalization below.
    static func pageHTML(svgSource: String, width: Int, height: Int) -> String {
        let encoded = Data(svgSource.utf8).base64EncodedString()
        return """
        <!doctype html><html><head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
        <style>html,body{width:\(width)px;height:\(height)px;margin:0;padding:0;overflow:hidden;background:transparent}img{display:block;border:0;width:\(width)px;height:\(height)px}</style>
        </head><body><img src="data:image/svg+xml;base64,\(encoded)" alt=""></body></html>
        """
    }

    private func startWatchdog(deadline: Date, cancellation: CancellationToken?) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: SVGRenderLimits.pollIntervalNanoseconds)
                guard let self, !self.resumed else { return }
                if cancellation?.isCancelled == true {
                    self.finish(.failure(.cancelled))
                    return
                }
                if Date() >= deadline {
                    self.finish(.failure(.timedOut))
                    return
                }
            }
        }
    }

    /// Resolves exactly once. Every late delegate callback after this
    /// sees `resumed` and is dropped; stopLoading bounds the web
    /// process so a cancelled/failed session keeps no expensive work.
    private func finish(_ result: Result<Data, SVGRenderingError>) {
        guard !resumed, let continuation else { return }
        resumed = true
        watchdog?.cancel()
        webView?.stopLoading()
        teardown()
        switch result {
        case .success(let data): continuation.resume(returning: data)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }

    private func teardown() {
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        continuation = nil
    }

    // MARK: - WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard !resumed, initialLoadAllowed else {
            decisionHandler(.cancel)
            return
        }
        let url = navigationAction.request.url
        let isInitialDocument = navigationAction.navigationType == .other
            && navigationAction.targetFrame?.isMainFrame != false
            && (url == nil || url?.scheme == "about" || url?.absoluteString.isEmpty == true)
        if isInitialDocument {
            initialLoadAllowed = false
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !resumed else { return }
        scheduleSnapshot(of: webView, settle: SVGRenderLimits.settleNanoseconds)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(.snapshotFailed))
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        finish(.failure(.snapshotFailed))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failure(.webContentTerminated))
    }

    // MARK: - Snapshot + blank-capture proof

    /// didFinish does not prove the data-URL image decoded; give the
    /// subresource a bounded settle, re-check every fence, then
    /// snapshot. A blank capture of a document that paints content is
    /// retried once with a longer settle before failing honestly.
    private func scheduleSnapshot(of webView: WKWebView, settle: UInt64) {
        Task { @MainActor [weak self] in
            guard let self, !self.resumed else { return }
            try? await Task.sleep(nanoseconds: settle)
            guard !self.resumed, let view = self.webView, view === webView else { return }
            self.snapshot(view)
        }
    }

    private func snapshot(_ webView: WKWebView) {
        Task { @MainActor [weak self] in
            guard let self, !self.resumed else { return }
            let pdfData: Data
            do {
                let capture = WKPDFConfiguration()
                capture.rect = CGRect(x: 0, y: 0, width: width, height: height)
                capture.allowTransparentBackground = true
                pdfData = try await webView.pdf(configuration: capture)
            } catch {
                if !self.resumed { self.finish(.failure(.snapshotFailed)) }
                return
            }
            // Re-check after suspension: cancellation or timeout may
            // have resolved the session while the snapshot ran.
            guard !self.resumed else { return }
            guard !pdfData.isEmpty, pdfData.count <= 32 * 1024 * 1024 else {
                self.finish(.failure(.snapshotFailed))
                return
            }
            do {
                let data = try self.encode(generatedPDF: pdfData)
                self.finish(.success(data))
            } catch SVGNormalizationError.blankCapture where self.expectVisibleContent
                    && self.blankRetries < 1 {
                // One bounded retry with a longer settle; the watchdog
                // still caps the total time.
                self.blankRetries += 1
                self.scheduleSnapshot(of: webView, settle: SVGRenderLimits.retrySettleNanoseconds)
            } catch SVGNormalizationError.blankCapture {
                self.finish(.failure(.blankCapture))
            } catch let error as SVGRenderingError {
                self.finish(.failure(error))
            } catch {
                self.finish(.failure(.encodeFailed(error.localizedDescription)))
            }
        }
    }

    enum SVGNormalizationError: Error {
        case blankCapture
        case failed(String)
    }

    /// Normalizes the Apple snapshot (points and any screen scale) into
    /// exactly `width`×`height` real pixels, applies the requested
    /// background, proves a content-bearing document did not capture
    /// blank, then encodes via the shared ImageFileEncoder contract
    /// which re-opens the bytes and proves the decoded size.
    private func encode(generatedPDF data: Data) throws -> Data {
        // This RAM-only PDF is produced by this same WebKit instance from
        // validated SVG. No caller-supplied PDF or protected document enters
        // this path, and PDFKit is never opened or bypassed here.
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider), document.numberOfPages == 1,
              let page = document.page(at: 1) else {
            throw SVGNormalizationError.failed("SVG capture could not be decoded")
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw SVGNormalizationError.failed("no bitmap context")
        }
        context.interpolationQuality = .high
        context.setShouldAntialias(true)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.clear(bounds)
        background.apply(to: context)
        context.saveGState()
        context.concatenate(page.getDrawingTransform(.mediaBox, rect: bounds, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        context.restoreGState()
        // Blank-capture proof on the ACTUAL normalized pixels before
        // encoding: uniform background over a document that paints
        // content means the snapshot (not the SVG) failed.
        if expectVisibleContent, blankRetries == 0, let data = context.data {
            if SVGBlankProbe.pixelsAreBlank(
                data: data, width: width, height: height,
                bytesPerRow: context.bytesPerRow,
                background: background
            ) {
                throw SVGNormalizationError.blankCapture
            }
        }
        guard let pixels = context.makeImage() else {
            throw SVGNormalizationError.failed("normalized image unavailable")
        }
        do {
            switch format {
            case .png:
                return try ImageFileEncoder.encode(pixels, as: .png)
            case .jpeg:
                return try ImageFileEncoder.encode(pixels, as: .jpeg,
                                                   quality: min(max(quality, 0), 1))
            }
        } catch let error as ImageFileEncodingError {
            throw SVGNormalizationError.failed(error.localizedDescription)
        }
    }

}

/// Stride-sampled uniformity probe over a premultiplied RGBA8 buffer:
/// blank == every sampled pixel equals the background's blank bytes.
/// Internal (not public) so component tests can exercise it directly.
enum SVGBlankProbe {
    /// Stride-sampled uniformity probe over the premultiplied RGBA8
    /// buffer: blank == every sampled pixel equals the background's
    /// blank bytes. Exposed for component tests.
    static func pixelsAreBlank(
        data: UnsafeMutableRawPointer,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        background: SVGBackground
    ) -> Bool {
        let expected = background.expectedBlankBytes
        let pointer = data.assumingMemoryBound(to: UInt8.self)
        let total = width * height
        let stride = max(1, (total + SVGRenderLimits.blankSampleMax - 1)
                         / SVGRenderLimits.blankSampleMax)
        var sampled = 0
        var pixel = 0
        while pixel < total {
            let y = pixel / width
            let x = pixel % width
            let offset = y * bytesPerRow + x * 4
            if pointer[offset] != expected.0 || pointer[offset + 1] != expected.1
                || pointer[offset + 2] != expected.2 || pointer[offset + 3] != expected.3 {
                return false
            }
            sampled += 1
            pixel += stride
        }
        return sampled > 0
    }
}
#endif
