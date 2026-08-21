// FloeApp — wire-neutral visible-browser protocol.

#if canImport(SwiftUI) && canImport(WebKit)
import Foundation

enum BrowserAction: Sendable, Codable, Hashable {
    case protocolInfo
    case create
    case navigate(url: String)
    case back
    case forward
    case reload
    case observe(cursor: Int?)
    case screenshot
    case click(BrowserTarget)
    case type(BrowserTarget, text: String, submit: Bool)
    case scroll(deltaX: Double, deltaY: Double)
    case wait(BrowserWaitCondition)
    case events(afterSequence: Int?, limit: Int)
    case listTabs
    case activateTab(UUID)
    case closeTab(UUID)
    case takeover
}

/// Public-WebKit approximation of CDP wait primitives. Network idle means
/// main-frame loading has stopped and the DOM has stayed unchanged for the
/// requested interval; WKWebView does not expose CDP's network domain.
enum BrowserWaitCondition: Sendable, Codable, Hashable {
    case load
    case domContentLoaded
    case selector(String)
    case text(String)
    case documentChanged(from: String)
    case idle(milliseconds: Int)
}

enum BrowserTarget: Sendable, Codable, Hashable {
    case element(ref: String, documentID: String)
    case point(x: Double, y: Double)
}

struct BrowserCommand: Sendable, Codable, Hashable {
    var version: Int = 1
    var requestID: UUID = UUID()
    var sessionID: UUID
    var tabID: UUID?
    var expectedDocumentID: String?
    var timeoutMilliseconds: Int = 15_000
    /// Required only for coordinate fallback. It must identify a fresh
    /// screenshot captured from the same tab and document.
    var visualEvidenceSHA256: String?
    /// Why semantic DOM observation was not sufficient for this action.
    var visualFallbackReason: String?
    var action: BrowserAction
}

struct BrowserNode: Sendable, Codable, Hashable, Identifiable {
    var id: String { ref }
    var ref: String
    var role: String
    var name: String
    var text: String
    var value: String?
    var state: [String: Bool]
    var bounds: BrowserBounds
}

struct BrowserBounds: Sendable, Codable, Hashable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

/// A bounded event emitted by the native delegate or isolated DOM probe.
/// Method names intentionally mirror CDP domains where the semantics match.
struct BrowserProtocolEvent: Sendable, Codable, Hashable, Identifiable {
    var id: Int { sequence }
    var sequence: Int
    var timestamp: Date
    var tabID: UUID
    var documentID: String
    var method: String
    var detail: String?
    var revision: Int?
}

enum FloeBrowserProtocolMethod: String, Sendable, Codable, Hashable, CaseIterable {
    case getVersion = "Browser.getVersion"
    case getTargets = "Target.getTargets"
    case createTarget = "Target.createTarget"
    case activateTarget = "Target.activateTarget"
    case closeTarget = "Target.closeTarget"
    case navigate = "Page.navigate"
    case reload = "Page.reload"
    case getDocument = "DOM.getDocument"
    case captureScreenshot = "Page.captureScreenshot"
    case waitForLoad = "Page.waitForLoad"
    case waitForDOM = "Page.waitForDOM"
    case waitForIdle = "Page.waitForIdle"
    case dispatchMouseEvent = "Input.dispatchMouseEvent"
    case insertText = "Input.insertText"
    case getEvents = "Runtime.getEvents"
}

/// JSON-friendly CDP-shaped request. Only the allowlisted methods above are
/// accepted; arbitrary Runtime.evaluate is deliberately not implemented.
struct FloeBrowserProtocolCommand: Sendable, Codable, Hashable {
    var id: Int
    var sessionID: UUID
    var targetID: UUID?
    var method: FloeBrowserProtocolMethod
    var url: String?
    var documentID: String?
    var ref: String?
    var x: Double?
    var y: Double?
    var screenshotSHA256: String?
    var fallbackReason: String?
    var text: String?
    var submit: Bool?
    var timeoutMilliseconds: Int?
    var afterSequence: Int?
    var limit: Int?

    init(
        id: Int,
        sessionID: UUID,
        targetID: UUID? = nil,
        method: FloeBrowserProtocolMethod,
        url: String? = nil,
        documentID: String? = nil,
        ref: String? = nil,
        x: Double? = nil,
        y: Double? = nil,
        screenshotSHA256: String? = nil,
        fallbackReason: String? = nil,
        text: String? = nil,
        submit: Bool? = nil,
        timeoutMilliseconds: Int? = nil,
        afterSequence: Int? = nil,
        limit: Int? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.targetID = targetID
        self.method = method
        self.url = url
        self.documentID = documentID
        self.ref = ref
        self.x = x
        self.y = y
        self.screenshotSHA256 = screenshotSHA256
        self.fallbackReason = fallbackReason
        self.text = text
        self.submit = submit
        self.timeoutMilliseconds = timeoutMilliseconds
        self.afterSequence = afterSequence
        self.limit = limit
    }
}

struct FloeBrowserProtocolResponse: Sendable, Codable, Hashable {
    var id: Int
    var protocolVersion: String
    var result: BrowserResult
}

struct BrowserTabSnapshot: Sendable, Codable, Hashable, Identifiable {
    var id: UUID
    var url: String
    var title: String
    var isActive: Bool
}

struct PageSnapshot: Sendable, Codable, Hashable {
    var documentID: String
    var revision: Int
    var url: String
    var title: String
    var isLoading: Bool
    var viewportWidth: Double
    var viewportHeight: Double
    var scrollX: Double
    var scrollY: Double
    var tabs: [BrowserTabSnapshot]
    var nodes: [BrowserNode]
    var nextCursor: Int?
    var screenshotArtifact: BrowserArtifactReference?
}

struct BrowserArtifactReference: Sendable, Codable, Hashable {
    var id: UUID
    var relativePath: String
    var mimeType: String
    var byteCount: Int
    var sha256: String
}

struct BrowserFailure: Sendable, Codable, Hashable {
    var code: String
    var message: String
}

struct BrowserResult: Sendable, Codable, Hashable {
    enum Status: String, Sendable, Codable, Hashable {
        case ok, stale, blocked, needsUser, timeout, failed
    }

    var requestID: UUID
    var status: Status
    var page: PageSnapshot?
    var message: String?
    var error: BrowserFailure?
    var events: [BrowserProtocolEvent] = []
    var nextEventSequence: Int?
    var protocolVersion: String?
}
#endif
