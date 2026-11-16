// FloeAndroid shared/Sources/FloeBrowser — the dumb platform renderer port.
//
// Android mirror delta (documented): the iOS original drove WKWebView
// directly inside BrowserTaskSession (MainActor). On Android the WebView is
// a platform component owned by feature/browser; the Swift session reaches it
// only through this port. The port executes; it never authorizes. Page-origin
// facts (URL, title, DOM JSON, screenshots) return as UNTRUSTED data and are
// consumed only after the session's own fences (sessionID, documentID,
// takeover, policy) have been applied by Swift.

import Foundation

/// Synchronous cross-actor fence for trusted lifecycle events lost at ingress.
/// A tab remains fenced until its queued gap is delivered to its owner.
public final class BrowserLifecycleHealth: @unchecked Sendable {
    public static let shared = BrowserLifecycleHealth()
    private struct Key: Hashable { let epoch: UInt64; let tabID: UUID }
    private let lock = NSLock()
    private var gaps: Set<Key> = []
    private var saturatedEpoch: UInt64?
    private init() {}
    public func markGap(epoch: UInt64, tabID: UUID) { lock.lock(); gaps.insert(Key(epoch: epoch, tabID: tabID)); lock.unlock() }
    public func clearGap(epoch: UInt64, tabID: UUID) { lock.lock(); gaps.remove(Key(epoch: epoch, tabID: tabID)); lock.unlock() }
    public func markEpochSaturated(_ epoch: UInt64) { lock.lock(); if saturatedEpoch == nil || epoch > saturatedEpoch! { saturatedEpoch = epoch }; lock.unlock() }
    public func epochIsSaturated(_ epoch: UInt64) -> Bool { lock.lock(); defer { lock.unlock() }; return saturatedEpoch == epoch }
    public func hasGap(epoch: UInt64, tabID: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return saturatedEpoch == epoch || gaps.contains(Key(epoch: epoch, tabID: tabID)) }
}

/// Snapshot of the renderer's tab surface. `url`/`title`/`isLoading` are
/// Android WebView getters surfaced as data; the original read the same
/// values from WKWebView on MainActor.
public struct BrowserRendererTabState: Sendable, Codable, Hashable {
    public var url: String?
    public var title: String?
    public var isLoading: Bool
    public var viewportWidth: Double
    public var viewportHeight: Double
    public var scrollX: Double
    public var scrollY: Double
    public var canGoBack: Bool
    public var canGoForward: Bool

    public init(
        url: String? = nil,
        title: String? = nil,
        isLoading: Bool = false,
        viewportWidth: Double = 1,
        viewportHeight: Double = 1,
        scrollX: Double = 0,
        scrollY: Double = 0,
        canGoBack: Bool = false,
        canGoForward: Bool = false
    ) {
        self.url = url
        self.title = title
        self.isLoading = isLoading
        self.viewportWidth = max(1, viewportWidth)
        self.viewportHeight = max(1, viewportHeight)
        self.scrollX = scrollX
        self.scrollY = scrollY
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
    }

    private enum CodingKeys: String, CodingKey {
        case url, title, isLoading, viewportWidth, viewportHeight, scrollX, scrollY, canGoBack, canGoForward
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            url: try values.decodeIfPresent(String.self, forKey: .url),
            title: try values.decodeIfPresent(String.self, forKey: .title),
            isLoading: try values.decode(Bool.self, forKey: .isLoading),
            viewportWidth: try values.decode(Double.self, forKey: .viewportWidth),
            viewportHeight: try values.decode(Double.self, forKey: .viewportHeight),
            scrollX: try values.decode(Double.self, forKey: .scrollX),
            scrollY: try values.decode(Double.self, forKey: .scrollY),
            canGoBack: try values.decodeIfPresent(Bool.self, forKey: .canGoBack) ?? false,
            canGoForward: try values.decodeIfPresent(Bool.self, forKey: .canGoForward) ?? false
        )
    }
}

/// Raw viewport capture returned by the renderer. Bytes are Floe-owned
/// evidence; the session bounds, hashes and stores them.
public struct BrowserScreenshotData: Sendable {
    public var jpeg: Data
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var state: BrowserRendererTabState

    public init(jpeg: Data, pixelWidth: Int, pixelHeight: Int, state: BrowserRendererTabState) {
        self.jpeg = jpeg
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.state = state
    }
}

public enum BrowserRendererError: Error, Sendable, Equatable {
    /// No WebView surface is attachable right now (feature not bound to a
    /// window yet). The session reports this as a typed failure; there is no
    /// secondary executor and no simulated page.
    case unavailable
    /// The session that owned the renderer was released mid-flight.
    case released
    /// A renderer round trip did not answer within its bounded deadline.
    case timedOut
    /// The platform refused the operation (for example a destroyed tab).
    case failed(String)
}

/// The platform executor a task session drives. Main's JNI bridge implements
/// this over `android.webkit.WebView` (feature/browser). Every method may be
/// awaited from the Swift session actor; implementations must bound their own
/// work and never block a page thread on Swift.
///
/// `addJavascriptInterface` is FORBIDDEN by design: the only script channel is
/// `evaluate(expression:)` with Swift-constructed, JSON-escaped payloads, and
/// its reply is untrusted data.
public protocol BrowserRenderer: Sendable {
    /// Creates the platform tab and arranges for `BrowserProbeScript.installSource`
    /// to run before document scripts where the platform supports it
    /// (document-start); otherwise the renderer re-injects it at every page
    /// commit. An absent `__floeProtocol` is an unavailable observation,
    /// not evidence that the real page has an empty DOM.
    func createTab(tabID: UUID, probeSource: String) async throws

    func destroyTab(tabID: UUID) async
    func navigate(tabID: UUID, url: URL) async throws
    func goBack(tabID: UUID) async throws
    func goForward(tabID: UUID) async throws
    func reload(tabID: UUID) async throws
    func stopLoading(tabID: UUID) async
    func state(tabID: UUID) async throws -> BrowserRendererTabState

    /// Runs one already-built, already-escaped JavaScript expression and
    /// returns its JSON text result (evaluateJavascript semantics). The
    /// returned string is page-derived data: callers must decode it
    /// defensively and treat failures as observation failures only.
    func evaluate(tabID: UUID, expression: String, timeoutMilliseconds: Int) async throws -> String

    /// Viewport capture. Must return real surface bytes (or throw
    /// `.unavailable`); never a placeholder image.
    func captureScreenshot(tabID: UUID) async throws -> BrowserScreenshotData

    /// Stops and drops every platform resource owned by this renderer.
    func release() async
}
