// FloeAndroid shared/Sources/FloeBrowser — wire-neutral task-scoped browser protocol.
//
// Android mirror of the public iOS original
// FloeAgent/FloeApp/Browser/BrowserModels.swift @ 3fd597b537590b4e6c11c0a25f413361a66b42b6
// (sha256 08f36895d61711ef0a82c5f9bfe9802631060f618eda058df9ff3dcaa0c0a995).
// Mirror deltas (documented, minimal):
//  1. The original `#if canImport(SwiftUI) && canImport(WebKit)` guard is removed;
//     every type here is pure Foundation and compiles under Swift 6 strict
//     concurrency for Android. No WebKit type ever crosses into a model.
//  2. `VisualTextRegion` comes from FloeCore (already Android-linked; Vision
//     island resolves to the honest empty recognizer on Android).
//  3. Added portable ownership/ingress types (BrowserOwnerID, surface state,
//     renderer lifecycle events, popup query/decision, projection, panel
//     request, handoff receipt) that the iOS original expressed through
//     SwiftUI classes and WKNavigationDelegate. Shapes follow the original
//     semantics exactly.
//
// BrowserCommand carries the owning session's exact sessionID (and optional
// tab/document identities); it deliberately has no owner field. The calling
// task is selected from the runtime-issued ToolContext before a command is
// built, so model-supplied JSON can never choose another task's browser.
// The sessionID is also the per-owner lifecycle fence: recreation after an
// explicit trusted reactivation mints a new sessionID, so any command or
// completion from an older, released session/generation stays stale.

import Foundation
import FloeCore

// MARK: - Commands

public enum BrowserAction: Sendable, Codable, Hashable {
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
/// requested interval; the Android WebView surface does not expose CDP's
/// network domain either (same semantics as the iOS original).
public enum BrowserWaitCondition: Sendable, Codable, Hashable {
    case load
    case domContentLoaded
    case selector(String)
    case text(String)
    case documentChanged(from: String)
    case idle(milliseconds: Int)
}

public enum BrowserTarget: Sendable, Codable, Hashable {
    case element(ref: String, documentID: String)
    case visualText(reference: String)
    case point(x: Double, y: Double)
}

public struct BrowserCommand: Sendable, Codable, Hashable {
    public var version: Int
    public var requestID: UUID
    public var sessionID: UUID
    public var tabID: UUID?
    public var expectedDocumentID: String?
    public var timeoutMilliseconds: Int
    /// Required only for coordinate fallback. It must identify a fresh
    /// screenshot captured from the same tab and document.
    public var visualEvidenceSHA256: String?
    /// Why semantic DOM observation was not sufficient for this action.
    public var visualFallbackReason: String?
    public var action: BrowserAction

    public init(
        version: Int = 1,
        requestID: UUID = UUID(),
        sessionID: UUID,
        tabID: UUID? = nil,
        expectedDocumentID: String? = nil,
        timeoutMilliseconds: Int = 15_000,
        visualEvidenceSHA256: String? = nil,
        visualFallbackReason: String? = nil,
        action: BrowserAction
    ) {
        self.version = version
        self.requestID = requestID
        self.sessionID = sessionID
        self.tabID = tabID
        self.expectedDocumentID = expectedDocumentID
        self.timeoutMilliseconds = timeoutMilliseconds
        self.visualEvidenceSHA256 = visualEvidenceSHA256
        self.visualFallbackReason = visualFallbackReason
        self.action = action
    }
}

// MARK: - Observation payloads

public struct BrowserNode: Sendable, Codable, Hashable, Identifiable {
    public var id: String { ref }
    public var ref: String
    public var role: String
    public var name: String
    public var text: String
    public var value: String?
    public var state: [String: Bool]
    public var bounds: BrowserBounds

    public init(
        ref: String,
        role: String,
        name: String,
        text: String,
        value: String?,
        state: [String: Bool],
        bounds: BrowserBounds
    ) {
        self.ref = ref
        self.role = role
        self.name = name
        self.text = text
        self.value = value
        self.state = state
        self.bounds = bounds
    }
}

public struct BrowserBounds: Sendable, Codable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// A bounded event emitted by the native renderer delegate or the isolated
/// DOM probe. Method names intentionally mirror CDP domains where the
/// semantics match.
public struct BrowserProtocolEvent: Sendable, Codable, Hashable, Identifiable {
    public var id: Int { sequence }
    public var sequence: Int
    public var timestamp: Date
    public var tabID: UUID
    public var documentID: String
    public var method: String
    public var detail: String?
    public var revision: Int?

    public init(
        sequence: Int,
        timestamp: Date,
        tabID: UUID,
        documentID: String,
        method: String,
        detail: String?,
        revision: Int?
    ) {
        self.sequence = sequence
        self.timestamp = timestamp
        self.tabID = tabID
        self.documentID = documentID
        self.method = method
        self.detail = detail
        self.revision = revision
    }
}

/// JSON-friendly CDP-shaped request. Only the allowlisted methods below are
/// accepted; arbitrary Runtime.evaluate is deliberately not implemented.
public struct FloeBrowserProtocolCommand: Sendable, Codable, Hashable {
    public var id: Int
    public var sessionID: UUID
    public var targetID: UUID?
    public var method: FloeBrowserProtocolMethod
    public var url: String?
    public var documentID: String?
    public var ref: String?
    public var x: Double?
    public var y: Double?
    public var screenshotSHA256: String?
    public var fallbackReason: String?
    public var text: String?
    public var submit: Bool?
    public var timeoutMilliseconds: Int?
    public var afterSequence: Int?
    public var limit: Int?

    public init(
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

public struct FloeBrowserProtocolResponse: Sendable, Codable, Hashable {
    public var id: Int
    public var protocolVersion: String
    public var result: BrowserResult

    public init(id: Int, protocolVersion: String, result: BrowserResult) {
        self.id = id
        self.protocolVersion = protocolVersion
        self.result = result
    }
}

public enum FloeBrowserProtocolMethod: String, Sendable, Codable, Hashable, CaseIterable {
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

public struct BrowserTabSnapshot: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var url: String
    public var title: String
    public var isActive: Bool

    public init(id: UUID, url: String, title: String, isActive: Bool) {
        self.id = id
        self.url = url
        self.title = title
        self.isActive = isActive
    }
}

public struct PageSnapshot: Sendable, Codable, Hashable {
    public var documentID: String
    public var revision: Int
    public var url: String
    public var title: String
    public var isLoading: Bool
    public var viewportWidth: Double
    public var viewportHeight: Double
    public var scrollX: Double
    public var scrollY: Double
    public var tabs: [BrowserTabSnapshot]
    public var nodes: [BrowserNode]
    public var visualTextRegions: [VisualTextRegion]
    public var nextCursor: Int?
    public var screenshotArtifact: BrowserArtifactReference?

    public init(
        documentID: String,
        revision: Int,
        url: String,
        title: String,
        isLoading: Bool,
        viewportWidth: Double,
        viewportHeight: Double,
        scrollX: Double,
        scrollY: Double,
        tabs: [BrowserTabSnapshot],
        nodes: [BrowserNode],
        visualTextRegions: [VisualTextRegion] = [],
        nextCursor: Int?,
        screenshotArtifact: BrowserArtifactReference?
    ) {
        self.documentID = documentID
        self.revision = revision
        self.url = url
        self.title = title
        self.isLoading = isLoading
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
        self.scrollX = scrollX
        self.scrollY = scrollY
        self.tabs = tabs
        self.nodes = nodes
        self.visualTextRegions = visualTextRegions
        self.nextCursor = nextCursor
        self.screenshotArtifact = screenshotArtifact
    }
}

public struct BrowserArtifactReference: Sendable, Codable, Hashable {
    public var id: UUID
    public var relativePath: String
    public var mimeType: String
    public var byteCount: Int
    public var sha256: String
    /// Encoded screenshot dimensions. Visual click coordinates are expressed
    /// in this pixel space and converted back to the page's CSS viewport.
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(
        id: UUID,
        relativePath: String,
        mimeType: String,
        byteCount: Int,
        sha256: String,
        pixelWidth: Int,
        pixelHeight: Int
    ) {
        self.id = id
        self.relativePath = relativePath
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.sha256 = sha256
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

public struct BrowserFailure: Sendable, Codable, Hashable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct BrowserResult: Sendable, Codable, Hashable {
    public enum Status: String, Sendable, Codable, Hashable {
        case ok, stale, blocked, needsUser, timeout, failed
    }

    public var requestID: UUID
    public var status: Status
    public var page: PageSnapshot?
    public var message: String?
    public var error: BrowserFailure?
    public var events: [BrowserProtocolEvent]
    public var nextEventSequence: Int?
    public var protocolVersion: String?

    public init(
        requestID: UUID,
        status: Status,
        page: PageSnapshot? = nil,
        message: String? = nil,
        error: BrowserFailure? = nil,
        events: [BrowserProtocolEvent] = [],
        nextEventSequence: Int? = nil,
        protocolVersion: String? = nil
    ) {
        self.requestID = requestID
        self.status = status
        self.page = page
        self.message = message
        self.error = error
        self.events = events
        self.nextEventSequence = nextEventSequence
        self.protocolVersion = protocolVersion
    }
}

// MARK: - Android portable ownership / ingress types (mirror deltas)

/// The exact native ownership triple every browser entry point carries. The
/// iOS original keyed only by conversation; Android composition also proves
/// the workspace binding and the native root epoch, so a task reopened on a
/// different workspace root or after an epoch bump can never inherit an older
/// session or preview.
public struct BrowserOwnerID: Sendable, Codable, Hashable {
    public var taskID: UUID
    public var workspaceID: UUID
    public var rootEpoch: UInt64

    public init(taskID: UUID, workspaceID: UUID, rootEpoch: UInt64) {
        self.taskID = taskID
        self.workspaceID = workspaceID
        self.rootEpoch = rootEpoch
    }
}

/// Portable mirror of the original BrowserTaskSession.SurfaceState.
public enum BrowserSurfaceState: Sendable, Codable, Hashable, Equatable {
    case unbound
    case ready
    case loading
    case failed(String)
    case needsUser(String)
}

/// Trusted platform facts posted by the renderer adapter (android.webkit
/// WebViewClient callbacks). These are OS-level navigation signals, not page
/// content: only they rotate a tab's document identity, exactly like
/// WKNavigationDelegate.didCommit did on iOS.
public enum BrowserRendererLifecycleEvent: Sendable, Codable, Hashable {
    case loadStarted(tabID: UUID)
    case loadCommitted(tabID: UUID)
    case loadFinished(tabID: UUID, url: String, title: String)
    case loadFailed(tabID: UUID, errorDomain: String, errorCode: Int, errorDescription: String)
}

/// A popup / new-window request observed by the renderer. The renderer never
/// opens anything itself; it awaits the Swift decision for its own tab.
public struct BrowserPopupQuery: Sendable, Codable, Hashable {
    public var tabID: UUID
    public var url: String

    public init(tabID: UUID, url: String) {
        self.tabID = tabID
        self.url = url
    }
}

public enum BrowserPopupDecision: Sendable, Codable, Hashable {
    /// Swift minted the tab (rendered via the port) and admitted the URL;
    /// the platform attaches/loads exactly this identity.
    case openInNewTab(tabID: UUID, url: String)
    case blocked(reason: String)
}

/// Durable handoff receipt. Field names and JSON shape are identical to the
/// iOS `BrowserSessionCenter.Handoff` so the outbox remains format-compatible.
public struct BrowserHandoff: Sendable, Codable, Hashable {
    public let id: UUID
    public let conversationID: UUID
    public let runID: UUID?
    public let sessionID: UUID
    public var tabID: UUID?
    public var returning: Bool
    public var pageAddress: String?

    public init(
        id: UUID,
        conversationID: UUID,
        runID: UUID?,
        sessionID: UUID,
        tabID: UUID? = nil,
        returning: Bool = false,
        pageAddress: String? = nil
    ) {
        self.id = id
        self.conversationID = conversationID
        self.runID = runID
        self.sessionID = sessionID
        self.tabID = tabID
        self.returning = returning
        self.pageAddress = pageAddress
    }
}

public struct BrowserPanelRequest: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public let conversationID: UUID
    public let show: Bool

    public init(id: UUID = UUID(), conversationID: UUID, show: Bool) {
        self.id = id
        self.conversationID = conversationID
        self.show = show
    }
}

/// The only UI truth the platform may render. Emitted by the center after
/// every projection-bearing transition; the Kotlin surface keeps no parallel
/// control state (no local Boolean permission store).
public struct BrowserProjection: Sendable, Codable, Hashable {
    public var visibleTaskID: UUID?
    public var presentationRequest: BrowserPanelRequest?
    public var handoff: BrowserHandoff?
    public var returningControl: Bool
    public var handoffNeedsContinue: Bool
    public var handoffNotified: Bool
    public var handoffError: String?
    public var surfaceState: BrowserSurfaceState
    public var tabs: [BrowserTabSnapshot]
    public var activeTabID: UUID?
    public var isUserControlling: Bool
    public var addressText: String
    public var isEditingAddress: Bool
    public var technicalAddress: String?
    public var isDisplayingLocalPreview: Bool

    public init(
        visibleTaskID: UUID? = nil,
        presentationRequest: BrowserPanelRequest? = nil,
        handoff: BrowserHandoff? = nil,
        returningControl: Bool = false,
        handoffNeedsContinue: Bool = false,
        handoffNotified: Bool = false,
        handoffError: String? = nil,
        surfaceState: BrowserSurfaceState = .unbound,
        tabs: [BrowserTabSnapshot] = [],
        activeTabID: UUID? = nil,
        isUserControlling: Bool = false,
        addressText: String = "",
        isEditingAddress: Bool = false,
        technicalAddress: String? = nil,
        isDisplayingLocalPreview: Bool = false
    ) {
        self.visibleTaskID = visibleTaskID
        self.presentationRequest = presentationRequest
        self.handoff = handoff
        self.returningControl = returningControl
        self.handoffNeedsContinue = handoffNeedsContinue
        self.handoffNotified = handoffNotified
        self.handoffError = handoffError
        self.surfaceState = surfaceState
        self.tabs = tabs
        self.activeTabID = activeTabID
        self.isUserControlling = isUserControlling
        self.addressText = addressText
        self.isEditingAddress = isEditingAddress
        self.technicalAddress = technicalAddress
        self.isDisplayingLocalPreview = isDisplayingLocalPreview
    }
}
