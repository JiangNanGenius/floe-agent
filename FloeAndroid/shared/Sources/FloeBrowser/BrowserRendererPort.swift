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

    public init(
        url: String? = nil,
        title: String? = nil,
        isLoading: Bool = false,
        viewportWidth: Double = 1,
        viewportHeight: Double = 1,
        scrollX: Double = 0,
        scrollY: Double = 0
    ) {
        self.url = url
        self.title = title
        self.isLoading = isLoading
        self.viewportWidth = max(1, viewportWidth)
        self.viewportHeight = max(1, viewportHeight)
        self.scrollX = scrollX
        self.scrollY = scrollY
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
    /// commit. The probe tolerates the race exactly like the iOS original
    /// (absent `__floeProtocol` returns the degraded honest snapshot).
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
