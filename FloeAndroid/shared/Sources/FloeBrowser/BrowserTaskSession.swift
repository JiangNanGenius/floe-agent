// FloeAndroid shared/Sources/FloeBrowser — one trusted task's independent browser.
//
// Android mirror of the iOS original `BrowserTaskSession`
// (FloeAgent/FloeApp/Browser/BrowserTaskSessionStore.swift @ 3fd597b…,
// sha256 1820588626b3d3e10668d09dcea6c17129efe5a38dde9e91c14c5b509ea92e03).
// The session owns exactly one task's tabs, document identities, visual
// evidence, event buffers and user-control state. It is selected from a
// trusted owner identity, never from model input, and it outlives any view
// that happens to show it.
//
// Documented mirror deltas against the original:
//  * The session no longer holds WKWebView objects; all engine work crosses
//    the `BrowserRenderer` port (Main's JNI/feature/browser implementation).
//    Tab lifecycle facts return as typed `BrowserRendererLifecycleEvent`s —
//    the exact role WKNavigationDelegate played. Page-derived JSON is treated
//    strictly as untrusted data (decoded defensively, never executed).
//  * The unbounded WKWebView callback race that iOS fenced with
//    `BrowserProbeRequest` (continuation + deadline + release invalidation)
//    is fenced here by `raced(...)` around each bounded renderer round trip;
//    a late renderer answer is dropped exactly like a late WebKit callback.
//  * `WKContentWorld` has no Android equivalent. Isolation of the probe is
//    therefore a documented platform limitation (see MODULE_API honest
//    availability): the probe exposes only its four whitelisted functions and
//    no evaluation endpoint; the page can overwrite it, which can only make
//    observations degraded/stale, never privileged, and no privileged JS API
//    is bridged (addJavascriptInterface is never used).
//  * `@MainActor` becomes `actor` + FIFO serialization of mutating actions
//    per tab (iOS serialized on the main queue).

import Foundation
import FloeCore
import FloeTools

/// Immutable engine settings shared by every task session. Values are copied
/// at session creation so a session never reaches back into the visible
/// center for protocol or buffer configuration.
public struct BrowserTaskSessionConfiguration: Sendable {
    public let protocolVersion: String
    public let artifacts: BrowserArtifactStore
    public let maximumTabs: Int
    public let maximumEventsPerTab: Int
    public let visualText: BrowserVisualTextRecognitionPort

    public init(
        protocolVersion: String = "FloeBrowser/1.0",
        artifacts: BrowserArtifactStore,
        maximumTabs: Int = 6,
        maximumEventsPerTab: Int = 256,
        visualText: BrowserVisualTextRecognitionPort? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.artifacts = artifacts
        self.maximumTabs = maximumTabs
        self.maximumEventsPerTab = maximumEventsPerTab
        self.visualText = visualText ?? BrowserVisualTextRecognitionPorts.unavailableOnAndroid
    }
}

/// Screenshot text anchors. The iOS original used Vision synchronously; on
/// Android the linked FloeCore recognizer resolves to the honest empty set
/// (documented availability, not a placeholder success).
public typealias BrowserVisualTextRecognitionPort =
    @Sendable (_ imageData: Data, _ pixelWidth: Int, _ pixelHeight: Int) throws -> [VisualTextRegion]

public enum BrowserVisualTextRecognitionPorts {
    public static let unavailableOnAndroid: BrowserVisualTextRecognitionPort = { data, width, height in
        try VisualTextRecognizer.recognize(imageData: data, pixelWidth: width, pixelHeight: height)
    }
}

/// A callback may never arrive after a renderer failure/navigation. Resolve a
/// bounded request on answer, deadline, cancellation, or owner release; a
/// late callback cannot resume it twice. No task waits for an uncooperative
/// native callback before returning the failure. (Original
/// BrowserProbeRequest/BrowserProbeError role.)
enum BrowserProbeError: Error, Sendable, Equatable {
    case timedOut
    case released
}

enum BrowserInteractionError: Error, Sendable, Equatable {
    case needsUser(String)
    case stale(String)
}

public actor BrowserTaskSession {
    public struct VisualFallbackEvidence: Sendable {
        public var documentID: String
        public var sha256: String
        public var capturedAt: Date
        public var pixelWidth: Int
        public var pixelHeight: Int
        public var viewportWidth: Double
        public var viewportHeight: Double
        public var revision: Int
        public var visualTextRegions: [VisualTextRegion]
    }

    public struct Tab: Sendable {
        public let id: UUID
        public var documentID: String
        public var revision: Int
        public var nextEventSequence: Int
        public var events: [BrowserProtocolEvent]
        public var visualFallbackEvidence: VisualFallbackEvidence?
        /// Last trusted platform facts (renderer getter values mirrored into
        /// Swift state; used for snapshot assembly and origin checks).
        public var surface: BrowserRendererTabState

        init(id: UUID, documentID: String) {
            self.id = id
            self.documentID = documentID
            self.revision = 0
            self.nextEventSequence = 1
            self.events = []
            self.visualFallbackEvidence = nil
            self.surface = BrowserRendererTabState()
        }
    }

    public let conversationID: UUID
    /// The exact native ownership triple this session was admitted under.
    public let owner: BrowserOwnerID
    /// Owner lifecycle generation stamped at creation by the owning center.
    public let generation: Int

    public private(set) var sessionID = UUID()
    public private(set) var tabs: [Tab] = []
    public private(set) var activeTabID: UUID?
    public private(set) var isUserControlling = false
    public private(set) var addressText = ""
    public private(set) var surfaceState: BrowserSurfaceState = .unbound
    public private(set) var isEditingAddress = false
    public private(set) var isReleased = false
    public private(set) var activeExecutionCount = 0
    public private(set) var lastActivityAt = Date()

    private let renderer: any BrowserRenderer
    private let protocolVersion: String
    private let artifacts: BrowserArtifactStore
    private let maximumTabs: Int
    private let maximumEventsPerTab: Int
    private let visualText: BrowserVisualTextRecognitionPort
    private let policy: BrowserURLPolicy
    /// Identity-bearing user-control transition hook to the durable receipt
    /// owner (the original `BrowserTaskSessionHost` callback, now a closure
    /// because the center is an actor, not an ObservableObject).
    private let requestUserControlHook: @Sendable (UUID, String) -> Void

    /// FIFO gates for mutating actions, one queue per tab. Reads (observe,
    /// events, listTabs, protocolInfo) are never gated.
    private var mutationTails: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    public init(
        owner: BrowserOwnerID,
        generation: Int,
        renderer: any BrowserRenderer,
        configuration: BrowserTaskSessionConfiguration,
        policy: BrowserURLPolicy,
        requestUserControl: @escaping @Sendable (UUID, String) -> Void
    ) {
        self.conversationID = owner.taskID
        self.owner = owner
        self.generation = generation
        self.renderer = renderer
        self.protocolVersion = configuration.protocolVersion
        self.artifacts = configuration.artifacts
        self.maximumTabs = configuration.maximumTabs
        self.maximumEventsPerTab = configuration.maximumEventsPerTab
        self.visualText = configuration.visualText
        self.policy = policy
        self.requestUserControlHook = requestUserControl
    }

    // MARK: - Tabs

    public var activeTabSurface: BrowserRendererTabState? {
        guard let activeTabID else { return nil }
        return tabs.first(where: { $0.id == activeTabID })?.surface
    }

    /// The title never replaces the navigable address, including loopback pages.
    public var technicalAddress: String? { activeTabSurface?.url }

    public var isDisplayingLocalPreview: Bool {
        guard let value = activeTabSurface?.url, let url = URL(string: value) else { return false }
        return Self.isLocalPreview(url)
    }

    static func isLocalPreview(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http" else { return false }
        return url.host == "127.0.0.1" || url.host?.lowercased() == "localhost"
    }

    @discardableResult
    public func createTab() async -> UUID? {
        guard !isReleased, tabs.count < maximumTabs else { return nil }
        lastActivityAt = Date()
        let id = UUID()
        tabs.append(Tab(id: id, documentID: UUID().uuidString))
        // Register the platform surface before the tab is usable. If the
        // renderer cannot accept a new tab the session state is rolled back.
        do {
            try await renderer.createTab(tabID: id, probeSource: BrowserProbeScript.installSource)
        } catch {
            tabs.removeAll { $0.id == id }
            return nil
        }
        activeTabID = id
        appendEvent(tabID: id, method: "Target.targetCreated")
        return id
    }

    public func activate(_ id: UUID) {
        guard !isReleased, tabs.contains(where: { $0.id == id }) else { return }
        activeTabID = id
        refreshVisibleAddress()
        appendEvent(tabID: id, method: "Target.targetActivated")
    }

    public func close(_ id: UUID) async {
        guard !isReleased, tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closed = tabs.remove(at: index)
        await renderer.stopLoading(tabID: closed.id)
        await renderer.destroyTab(tabID: closed.id)
        if activeTabID == id { activeTabID = tabs[min(index, tabs.count - 1)].id }
    }

    public func navigateFromAddressBar() async {
        guard !isReleased else { return }
        if let currentURL = activeTabSurface?.url, let url = URL(string: currentURL),
           Self.isLocalPreview(url),
           addressText == currentURL {
            await reloadActiveTab()
            return
        }
        let candidate = addressText.contains("://") ? addressText : "https://\(addressText)"
        guard let url = try? policy.validate(candidate, conversationID: conversationID) else { return }
        guard let activeTabID else { return }
        try? await renderer.navigate(tabID: activeTabID, url: url)
    }

    public func reloadActiveTab() async {
        guard let activeTabID, !isReleased else { return }
        try? await renderer.reload(tabID: activeTabID)
    }

    public func goBackActiveTab() async {
        guard let activeTabID, !isReleased else { return }
        try? await renderer.goBack(tabID: activeTabID)
    }

    public func goForwardActiveTab() async {
        guard let activeTabID, !isReleased else { return }
        try? await renderer.goForward(tabID: activeTabID)
    }

    public func refreshVisibleAddress() {
        guard !isReleased, !isEditingAddress else { return }
        addressText = activeTabSurface?.url ?? ""
    }

    // MARK: - Ownership lifecycle

    public func setUserControlling(_ value: Bool) {
        isUserControlling = value
        if value {
            surfaceState = .needsUser("User takeover is active")
        } else if case .needsUser = surfaceState {
            surfaceState = .ready
        }
    }

    public func setAddressText(_ value: String) {
        addressText = value
    }

    public func setEditingAddress(_ value: Bool) {
        isEditingAddress = value
    }

    public func setSurfaceNeedsUser(_ reason: String) {
        surfaceState = .needsUser(reason)
    }

    public func markSurfaceReady() {
        if surfaceState == .unbound || surfaceState == .ready { surfaceState = .ready }
    }

    /// Trusted rebind (the user explicitly reopened this task's panel): an
    /// unbound surface becomes ready, user control keeps its needsUser state,
    /// and address editing resets. Control is NEVER returned here; only the
    /// receipt-bearing returnToAgent path can clear user control.
    public func promoteSurfaceAfterRebind() {
        guard !isReleased else { return }
        if surfaceState == .unbound { surfaceState = .ready }
        if isUserControlling { surfaceState = .needsUser("User takeover is active") }
        isEditingAddress = false
    }

    public func hasTab(_ id: UUID) -> Bool {
        tabs.contains(where: { $0.id == id })
    }

    /// Eviction eligibility for the center's bounded registry (the original
    /// makeRoomForSession guards): never visible (caller passes the decision),
    /// never user-controlled, never executing, and idle past the cutoff.
    public func evictableIfIdle(notVisible: Bool, cutoff: Date) -> Bool {
        notVisible
            && !isUserControlling
            && activeExecutionCount == 0
            && lastActivityAt < cutoff
    }

    /// Invalidate every element/document reference before the user or a new
    /// run takes the page. Only this task's evidence is affected.
    public func invalidateDocumentsForHandoff() {
        guard !isReleased else { return }
        for index in tabs.indices {
            tabs[index].documentID = UUID().uuidString
            tabs[index].visualFallbackEvidence = nil
        }
    }

    /// Service-owned release. Stops only this task's renderer surfaces and
    /// fences its delegate/probe callbacks; no other task session is touched.
    public func release() async {
        guard !isReleased else { return }
        isReleased = true
        let closedTabs = tabs
        tabs.removeAll()
        activeTabID = nil
        isUserControlling = false
        surfaceState = .unbound
        addressText = ""
        // A caller may already be awaiting a gated mutation; release their
        // tickets so queued work observes `released` instead of hanging.
        for (_, waiters) in mutationTails {
            for continuation in waiters { continuation.resume() }
        }
        mutationTails.removeAll()
        for tab in closedTabs {
            await renderer.stopLoading(tabID: tab.id)
            await renderer.destroyTab(tabID: tab.id)
        }
        await renderer.release()
    }

    // MARK: - Renderer ingress (trusted platform facts)

    public func ingress(_ event: BrowserRendererLifecycleEvent) {
        guard !isReleased else { return }
        switch event {
        case .loadStarted(let tabID):
            guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
            tabs[index].surface.isLoading = true
            appendEvent(tabID: tabID, method: "Page.frameStartedLoading")
            surfaceState = .loading
        case .loadCommitted(let tabID):
            guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
            // Navigation commit rotates document identity exactly like the
            // original didCommit: older refs and evidence are dead data.
            tabs[index].documentID = UUID().uuidString
            tabs[index].revision = 0
            tabs[index].visualFallbackEvidence = nil
            appendEvent(tabID: tabs[index].id, method: "Page.frameNavigated")
        case .loadFinished(let tabID, let url, let title):
            guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
            tabs[index].surface.url = url
            tabs[index].surface.title = title
            tabs[index].surface.isLoading = false
            appendEvent(tabID: tabs[index].id, method: "Page.loadEventFired")
            if tabs[index].id == activeTabID { refreshVisibleAddress() }
            surfaceState = isUserControlling ? .needsUser("User takeover is active") : .ready
        case .loadFailed(let tabID, let errorDomain, let errorCode, let errorDescription):
            guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
            tabs[index].surface.isLoading = false
            appendEvent(
                tabID: tabs[index].id,
                method: "Network.loadingFailed",
                detail: "\(errorDomain):\(errorCode)"
            )
            surfaceState = .failed("\(errorDescription) (\(errorCode))")
        }
    }

    /// A popup/new-window request from the platform. The renderer opened
    /// nothing itself; Swift applies the tab limit, the navigation policy and
    /// ownership, then the renderer adopts the window into the returned tab.
    public func popupDecision(for query: BrowserPopupQuery) async -> BrowserPopupDecision {
        guard !isReleased else { return .blocked(reason: "session released") }
        guard tabs.count < maximumTabs else { return .blocked(reason: "The six-tab limit was reached") }
        guard let id = await createTab() else { return .blocked(reason: "The tab could not be created") }
        guard let url = try? policy.validate(query.url, conversationID: conversationID) else {
            await close(id)
            return .blocked(reason: "Only http and https public URLs or authorized previews are allowed")
        }
        do {
            try await renderer.navigate(tabID: id, url: url)
        } catch {
            await close(id)
            return .blocked(reason: "The popup surface was unavailable")
        }
        return .openInNewTab(tabID: id, url: url.absoluteString)
    }

    /// Current committed origin of one tab (used to fence downloads and
    /// cross-origin escalation attempts). Trusted platform facts only.
    public func tabOrigin(tabID: UUID) -> String? {
        guard let surface = tabs.first(where: { $0.id == tabID })?.surface,
              let value = surface.url, let url = URL(string: value),
              let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        let port = url.port.map(String.init) ?? (scheme == "http" ? "80" : "443")
        return "\(scheme)://\(host):\(port)"
    }

    // MARK: - Command execution

    public func execute(_ command: BrowserCommand, cancellation: CancellationToken? = nil) async -> BrowserResult {
        guard !isReleased else {
            return failure(command, status: .stale, code: "released", "This task's browser session was released")
        }
        guard cancellation?.isCancelled != true, !Task.isCancelled else {
            return failure(command, status: .failed, code: "cancelled", "Browser action was cancelled")
        }
        lastActivityAt = Date()
        activeExecutionCount += 1
        defer { activeExecutionCount -= 1 }

        guard command.version == 1 else {
            return failure(command, status: .failed, code: "version", "Unsupported browser protocol version")
        }
        guard command.sessionID == sessionID else {
            return failure(command, status: .stale, code: "session", "Browser session is no longer active")
        }
        if isUserControlling {
            switch command.action {
            case .protocolInfo, .observe, .listTabs, .events:
                break
            default:
                // Includes actions that were queued before takeover: the gate
                // reads the CURRENT flag at execution time, never at enqueue
                // time, so a late mutation stays refused while the user has
                // the page.
                return failure(command, status: .needsUser, code: "takeover", "The user currently controls the browser")
            }
        }

        switch command.action {
        case .protocolInfo:
            return BrowserResult(
                requestID: command.requestID,
                status: .ok,
                protocolVersion: protocolVersion
            )
        case .create:
            guard let id = await createTab() else {
                return failure(command, status: .blocked, code: "tab-limit", "The six-tab limit was reached")
            }
            return await observeResult(command, tabID: id, cursor: nil, cancellation: cancellation)
        case .listTabs:
            return await observeResult(command, tabID: command.tabID ?? activeTabID, cursor: nil, cancellation: cancellation)
        case .activateTab(let id):
            activate(id)
            return await observeResult(command, tabID: id, cursor: nil, cancellation: cancellation)
        case .closeTab(let id):
            await close(id)
            return await observeResult(command, tabID: activeTabID, cursor: nil, cancellation: cancellation)
        case .takeover:
            requestUserControlHook(conversationID, "Browser control was handed to the user")
            return failure(command, status: .needsUser, code: "takeover", "Browser control was handed to the user")
        default:
            break
        }

        guard let tabID = command.tabID ?? activeTabID,
              let index = tabs.firstIndex(where: { $0.id == tabID }) else {
            return failure(command, status: .stale, code: "tab", "Browser tab is no longer available")
        }
        if let expected = command.expectedDocumentID, expected != tabs[index].documentID {
            return failure(command, status: .stale, code: "document", "The page changed; observe it again")
        }

        // Mutating actions are serialized per tab (the iOS main queue gave
        // this for free; here the FIFO gate preserves it explicitly).
        let isMutation: Bool
        switch command.action {
        case .navigate, .back, .forward, .reload, .screenshot, .click, .type, .scroll:
            isMutation = true
        default:
            isMutation = false
        }
        if isMutation { await acquireMutationGate(tabID: tabID) }
        defer { if isMutation { releaseMutationGate(tabID: tabID) } }
        // The tab may have closed while this action waited for its gate.
        guard tabs.contains(where: { $0.id == tabID }) else {
            return failure(command, status: .stale, code: "tab", "Browser tab is no longer available")
        }
        // Re-read the takeover fence AFTER the gate: an action queued behind
        // slow work while the agent still had control must be refused if the
        // user took control during its wait. The flag is never captured at
        // enqueue time.
        if isMutation, isUserControlling {
            return failure(command, status: .needsUser, code: "takeover", "The user currently controls the browser")
        }

        do {
            switch command.action {
            case .navigate(let value):
                let url = try policy.validate(value, conversationID: conversationID)
                try await rendererCall(cancellation) { renderer in
                    try await renderer.navigate(tabID: tabID, url: url)
                }
            case .back:
                try await rendererCall(cancellation) { renderer in
                    try await renderer.goBack(tabID: tabID)
                }
            case .forward:
                try await rendererCall(cancellation) { renderer in
                    try await renderer.goForward(tabID: tabID)
                }
            case .reload:
                try await rendererCall(cancellation) { renderer in
                    try await renderer.reload(tabID: tabID)
                }
            case .observe(let cursor):
                return await observeResult(command, tabID: tabID, cursor: cursor, cancellation: cancellation)
            case .screenshot:
                let artifact = try await saveSnapshot(of: tabID, cancellation: cancellation)
                let visualTextRegions = try recognizeVisualText(in: artifact)
                var result = await observeResult(command, tabID: tabID, cursor: nil, cancellation: cancellation)
                result.page?.screenshotArtifact = artifact
                result.page?.visualTextRegions = visualTextRegions
                if let page = result.page,
                   let currentIndex = tabs.firstIndex(where: { $0.id == tabID }) {
                    tabs[currentIndex].visualFallbackEvidence = VisualFallbackEvidence(
                        documentID: tabs[currentIndex].documentID,
                        sha256: artifact.sha256.lowercased(),
                        capturedAt: Date(),
                        pixelWidth: artifact.pixelWidth,
                        pixelHeight: artifact.pixelHeight,
                        viewportWidth: page.viewportWidth,
                        viewportHeight: page.viewportHeight,
                        revision: page.revision,
                        visualTextRegions: visualTextRegions
                    )
                }
                return result
            case .click(let requestedTarget):
                var target: BrowserTarget = requestedTarget
                if case .visualText(let reference) = requestedTarget {
                    let evidence = try validateVisualFallback(command, in: tabID)
                    guard let region = evidence.visualTextRegions.first(where: { $0.reference == reference }) else {
                        throw BrowserPolicyError.blocked(
                            "The visual text reference is absent or stale; capture a new browser screenshot"
                        )
                    }
                    target = .point(x: Double(region.centerX), y: Double(region.centerY))
                }
                if case .point(let x, let y) = target {
                    let evidence = try validateVisualFallback(command, in: tabID)
                    guard x >= 0, y >= 0,
                          x < Double(evidence.pixelWidth),
                          y < Double(evidence.pixelHeight) else {
                        throw BrowserPolicyError.blocked(
                            "Visual click coordinates are outside the referenced screenshot"
                        )
                    }
                    let cssTarget = BrowserTarget.point(
                        x: x / Double(evidence.pixelWidth) * evidence.viewportWidth,
                        y: y / Double(evidence.pixelHeight) * evidence.viewportHeight
                    )
                    try await perform(
                        target: cssTarget,
                        in: tabID,
                        operation: "click",
                        text: nil,
                        submit: false,
                        visualFallbackReason: command.visualFallbackReason,
                        cancellation: cancellation
                    )
                    // Synthetic pointer dispatch is not proof that the
                    // intended visual target accepted the action. Capture the
                    // viewport again and require an observable state change.
                    try? await Task.sleep(for: .milliseconds(250))
                    let postArtifact = try await saveSnapshot(of: tabID, cancellation: cancellation)
                    let postVisualTextRegions = try recognizeVisualText(in: postArtifact)
                    var result = await observeResult(command, tabID: tabID, cursor: nil, cancellation: cancellation)
                    result.page?.screenshotArtifact = postArtifact
                    result.page?.visualTextRegions = postVisualTextRegions
                    let changed = (result.page.map {
                        $0.documentID != evidence.documentID
                            || $0.revision > evidence.revision
                            || postArtifact.sha256.lowercased() != evidence.sha256
                    } ?? false)
                    if let page = result.page,
                       let currentIndex = tabs.firstIndex(where: { $0.id == tabID }) {
                        tabs[currentIndex].visualFallbackEvidence = VisualFallbackEvidence(
                            documentID: page.documentID,
                            sha256: postArtifact.sha256.lowercased(),
                            capturedAt: Date(),
                            pixelWidth: postArtifact.pixelWidth,
                            pixelHeight: postArtifact.pixelHeight,
                            viewportWidth: page.viewportWidth,
                            viewportHeight: page.viewportHeight,
                            revision: page.revision,
                            visualTextRegions: postVisualTextRegions
                        )
                    }
                    if changed {
                        result.message = "Visual click produced an observable page change; the returned screenshot is post-click evidence."
                    } else {
                        let message = "Visual click produced no observable page change; the target was not confirmed. Use the returned post-click screenshot to choose a different point or hand control to the user."
                        result.status = .failed
                        result.message = message
                        result.error = BrowserFailure(code: "no-observable-effect", message: message)
                    }
                    return result
                }
                try await perform(
                    target: target,
                    in: tabID,
                    operation: "click",
                    text: nil,
                    submit: false,
                    visualFallbackReason: command.visualFallbackReason,
                    cancellation: cancellation
                )
            case .type(let target, let text, let submit):
                guard text.utf8.count <= 16 * 1024 else {
                    throw BrowserPolicyError.blocked("Browser input exceeds 16 KiB")
                }
                try await perform(
                    target: target,
                    in: tabID,
                    operation: "type",
                    text: text,
                    submit: submit,
                    visualFallbackReason: nil,
                    cancellation: cancellation
                )
            case .scroll(let x, let y):
                _ = try await evaluate(tabID: tabID, expression: BrowserProbeScript.scrollExpression(deltaX: x, deltaY: y), cancellation: cancellation)
                appendEvent(tabID: tabID, method: "Input.dispatchMouseEvent", detail: "scroll")
            case .wait(let condition):
                return await waitResult(command, tabID: tabID, condition: condition, cancellation: cancellation)
            case .events(let afterSequence, let limit):
                return await eventsResult(
                    command,
                    tabID: tabID,
                    afterSequence: afterSequence,
                    limit: limit,
                    cancellation: cancellation
                )
            case .protocolInfo, .create, .listTabs, .activateTab, .closeTab, .takeover:
                break
            }
            return await observeResult(command, tabID: tabID, cursor: nil, cancellation: cancellation)
        } catch BrowserInteractionError.needsUser(let message) {
            requestUserControlHook(conversationID, message)
            return failure(command, status: .needsUser, code: "takeover", message)
        } catch BrowserInteractionError.stale(let message) {
            return failure(command, status: .stale, code: "document", message)
        } catch let error as BrowserPolicyError {
            return failure(command, status: .blocked, code: "policy", error.localizedDescription)
        } catch is CancellationError {
            return failure(command, status: .failed, code: "cancelled", "Browser action was cancelled")
        } catch BrowserProbeError.released {
            return failure(command, status: .stale, code: "released", "This task's browser session was released")
        } catch {
            return failure(command, status: .failed, code: "webview", error.localizedDescription)
        }
    }

    /// CDP-shaped, allowlisted dispatch surface for integrations that prefer
    /// method/params requests over Floe's typed BrowserAction enum. Ported
    /// verbatim from the original including its parameter validation.
    public func executeProtocol(_ request: FloeBrowserProtocolCommand, cancellation: CancellationToken? = nil) async -> FloeBrowserProtocolResponse {
        let action: BrowserAction
        let documentID = request.documentID
        switch request.method {
        case .getVersion:
            action = .protocolInfo
        case .getTargets, .getDocument:
            action = request.method == .getTargets ? .listTabs : .observe(cursor: nil)
        case .createTarget:
            action = .create
        case .activateTarget:
            guard let targetID = request.targetID else {
                return protocolFailure(request, "Target.activateTarget requires targetID")
            }
            action = .activateTab(targetID)
        case .closeTarget:
            guard let targetID = request.targetID else {
                return protocolFailure(request, "Target.closeTarget requires targetID")
            }
            action = .closeTab(targetID)
        case .navigate:
            guard let url = request.url, !url.isEmpty else {
                return protocolFailure(request, "Page.navigate requires url")
            }
            action = .navigate(url: url)
        case .reload:
            action = .reload
        case .captureScreenshot:
            action = .screenshot
        case .waitForLoad:
            action = .wait(.load)
        case .waitForDOM:
            action = .wait(.domContentLoaded)
        case .waitForIdle:
            action = .wait(.idle(milliseconds: min(5_000, max(100, request.timeoutMilliseconds ?? 500))))
        case .dispatchMouseEvent:
            if let ref = request.ref, let documentID {
                action = .click(.element(ref: ref, documentID: documentID))
            } else if let x = request.x, let y = request.y,
                      x.isFinite, y.isFinite, x >= 0, y >= 0,
                      request.screenshotSHA256?.isEmpty == false,
                      request.fallbackReason?.isEmpty == false {
                action = .click(.point(x: x, y: y))
            } else {
                return protocolFailure(request, "Coordinate Input.dispatchMouseEvent requires documentID, a fresh screenshotSHA256, and fallbackReason")
            }
        case .insertText:
            guard let ref = request.ref, !ref.isEmpty,
                  let documentID, !documentID.isEmpty,
                  let text = request.text, text.utf8.count <= 16 * 1024 else {
                return protocolFailure(request, "Input.insertText requires ref, documentID, and bounded text")
            }
            action = .type(
                .element(ref: ref, documentID: documentID),
                text: text,
                submit: request.submit ?? false
            )
        case .getEvents:
            action = .events(
                afterSequence: request.afterSequence,
                limit: min(100, max(1, request.limit ?? 50))
            )
        }
        let command = BrowserCommand(
            requestID: UUID(),
            sessionID: request.sessionID,
            tabID: request.targetID,
            expectedDocumentID: documentID,
            timeoutMilliseconds: min(30_000, max(250, request.timeoutMilliseconds ?? 15_000)),
            visualEvidenceSHA256: request.screenshotSHA256,
            visualFallbackReason: request.fallbackReason,
            action: action
        )
        return FloeBrowserProtocolResponse(
            id: request.id,
            protocolVersion: protocolVersion,
            result: await execute(command, cancellation: cancellation)
        )
    }

    private func protocolFailure(
        _ request: FloeBrowserProtocolCommand,
        _ message: String
    ) -> FloeBrowserProtocolResponse {
        FloeBrowserProtocolResponse(
            id: request.id,
            protocolVersion: protocolVersion,
            result: BrowserResult(
                requestID: UUID(),
                status: .failed,
                message: message,
                error: BrowserFailure(code: "invalid-params", message: message),
                protocolVersion: protocolVersion
            )
        )
    }

    // MARK: - Actuator

    private func perform(
        target: BrowserTarget,
        in tabID: UUID,
        operation: String,
        text: String?,
        submit: Bool,
        visualFallbackReason: String?,
        cancellation: CancellationToken?
    ) async throws {
        guard let tab = tabs.first(where: { $0.id == tabID }) else {
            throw BrowserInteractionError.stale("Browser tab is no longer available")
        }
        let expression = BrowserProbeScript.performExpression(
            operation: operation,
            target: target,
            documentID: tab.documentID,
            text: text ?? "",
            submit: submit,
            visualFallbackReason: visualFallbackReason
        )
        let value = try await evaluate(tabID: tabID, expression: expression, cancellation: cancellation)
        struct PerformReply: Decodable { var status: String; var ref: String? }
        let reply = (try? JSONDecoder().decode(PerformReply.self, from: Data(value.utf8))) ?? PerformReply(status: "stale", ref: nil)
        switch reply.status {
        case "needsUser": throw BrowserInteractionError.needsUser("Sensitive input requires user takeover")
        case "stale": throw BrowserInteractionError.stale("The target is stale; observe the page again")
        case "structured":
            throw BrowserPolicyError.blocked(
                "A structured target (\(reply.ref ?? "unknown")) is available at these coordinates; use browser.click"
            )
        case "ok":
            appendEvent(
                tabID: tabID,
                method: operation == "click" ? "Input.dispatchMouseEvent" : "Input.insertText"
            )
        default:
            throw BrowserPolicyError.blocked("The target cannot accept this action")
        }
    }

    private func validateVisualFallback(_ command: BrowserCommand, in tabID: UUID) throws -> VisualFallbackEvidence {
        guard let tab = tabs.first(where: { $0.id == tabID }) else {
            throw BrowserInteractionError.stale("Browser tab is no longer available")
        }
        guard let reason = command.visualFallbackReason,
              ["noStructuredTarget", "insufficientStructuredInformation"].contains(reason) else {
            throw BrowserPolicyError.blocked(
                "Coordinate fallback requires a reason that structured information is absent or insufficient"
            )
        }
        guard let expectedDigest = command.visualEvidenceSHA256?.lowercased(),
              expectedDigest.count == 64,
              expectedDigest.allSatisfy(\.isHexDigit),
              let evidence = tab.visualFallbackEvidence,
              evidence.documentID == tab.documentID,
              evidence.sha256 == expectedDigest,
              evidence.pixelWidth > 0,
              evidence.pixelHeight > 0,
              evidence.viewportWidth > 0,
              evidence.viewportHeight > 0,
              Date().timeIntervalSince(evidence.capturedAt) <= 120 else {
            throw BrowserPolicyError.blocked(
                "Coordinate fallback requires a fresh screenshot from the current page"
            )
        }
        return evidence
    }

    // MARK: - Observation

    private func observeResult(
        _ command: BrowserCommand,
        tabID: UUID?,
        cursor: Int?,
        cancellation: CancellationToken?
    ) async -> BrowserResult {
        guard !isReleased else {
            return failure(command, status: .stale, code: "released", "This task's browser session was released")
        }
        guard cancellation?.isCancelled != true, !Task.isCancelled else {
            return failure(command, status: .failed, code: "cancelled", "Browser page observation was cancelled")
        }
        guard let tabID, tabs.contains(where: { $0.id == tabID }) else {
            return failure(command, status: .stale, code: "tab", "Browser tab is no longer available")
        }
        let timeout = min(30_000, max(250, command.timeoutMilliseconds))
        do {
            try Task.checkCancellation()
            await collectProbeEvents(tabID: tabID, timeout: timeout, cancellation: cancellation)
            try Task.checkCancellation()
            let start = max(0, cursor ?? 0)
            let pageSize = 40
            let probe = try await semanticSnapshot(
                tabID: tabID,
                cursor: start,
                limit: pageSize,
                timeout: timeout,
                cancellation: cancellation
            )
            guard !isReleased else { throw BrowserProbeError.released }
            if let index = tabs.firstIndex(where: { $0.id == tabID }) {
                tabs[index].revision = max(tabs[index].revision, probe.revision)
            }
            let surface = try await rendererState(tabID: tabID, timeout: timeout, cancellation: cancellation)
            if let index = tabs.firstIndex(where: { $0.id == tabID }) {
                tabs[index].surface = surface
            }
            guard let tab = tabs.first(where: { $0.id == tabID }) else {
                return failure(command, status: .stale, code: "tab", "Browser tab is no longer available")
            }
            let snapshot = PageSnapshot(
                documentID: tab.documentID,
                revision: max(tab.revision, probe.revision),
                url: surface.url ?? "",
                title: surface.title ?? "",
                isLoading: surface.isLoading,
                viewportWidth: probe.viewportWidth,
                viewportHeight: probe.viewportHeight,
                scrollX: surface.scrollX,
                scrollY: surface.scrollY,
                tabs: tabSnapshots(),
                nodes: probe.nodes,
                nextCursor: probe.nextCursor,
                screenshotArtifact: nil
            )
            return BrowserResult(requestID: command.requestID, status: .ok, page: snapshot)
        } catch BrowserProbeError.timedOut {
            return failure(command, status: .timeout, code: "timeout", "Browser page observation timed out")
        } catch BrowserProbeError.released {
            return failure(command, status: .stale, code: "released", "This task's browser session was released")
        } catch is CancellationError {
            return failure(command, status: .failed, code: "cancelled", "Browser page observation was cancelled")
        } catch {
            return failure(command, status: .failed, code: "observe", error.localizedDescription)
        }
    }

    private struct ProbeSnapshot: Decodable {
        var revision: Int
        var viewportWidth: Double
        var viewportHeight: Double
        var nodes: [BrowserNode]
        var nextCursor: Int?
    }

    private struct ProbeState: Decodable {
        var readyState: String
        var selectorFound: Bool
        var textFound: Bool
        var idleMilliseconds: Double
        var revision: Int
    }

    private struct ProbeEvent: Decodable {
        var method: String
        var detail: String?
        var revision: Int?
    }

    private func semanticSnapshot(
        tabID: UUID,
        cursor: Int,
        limit: Int,
        timeout: Int,
        cancellation: CancellationToken?
    ) async throws -> ProbeSnapshot {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { throw BrowserProbeError.released }
        let value = try await evaluate(
            tabID: tabID,
            expression: BrowserProbeScript.observeExpression(documentID: tab.documentID, cursor: cursor, limit: limit),
            cancellation: cancellation,
            timeout: timeout
        )
        if let probe = try? JSONDecoder().decode(ProbeSnapshot.self, from: Data(value.utf8)) {
            return probe
        }
        // A page without the installed probe still yields the honest degraded
        // snapshot (the original fallback contract, preserved).
        let surface = try await rendererState(tabID: tabID, timeout: timeout, cancellation: cancellation)
        return ProbeSnapshot(
            revision: 0,
            viewportWidth: surface.viewportWidth,
            viewportHeight: surface.viewportHeight,
            nodes: [],
            nextCursor: nil
        )
    }

    private func probeState(
        tabID: UUID,
        condition: BrowserWaitCondition,
        timeout: Int,
        cancellation: CancellationToken?
    ) async throws -> ProbeState {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { throw BrowserProbeError.released }
        var selector = ""
        var text = ""
        switch condition {
        case .selector(let value): selector = String(value.prefix(512))
        case .text(let value): text = String(value.prefix(512))
        default: break
        }
        let value = try await evaluate(
            tabID: tabID,
            expression: BrowserProbeScript.statusExpression(documentID: tab.documentID, selector: selector, text: text),
            cancellation: cancellation,
            timeout: timeout
        )
        guard let state = try? JSONDecoder().decode(ProbeState.self, from: Data(value.utf8)) else {
            throw BrowserPolicyError.blocked("The browser probe returned an invalid status")
        }
        return state
    }

    private func collectProbeEvents(tabID: UUID, timeout: Int, cancellation: CancellationToken?) async {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        do {
            let value = try await evaluate(
                tabID: tabID,
                expression: BrowserProbeScript.drainEventsExpression(documentID: tab.documentID),
                cancellation: cancellation,
                timeout: timeout
            )
            guard let events = try? JSONDecoder().decode([ProbeEvent].self, from: Data(value.utf8)) else { return }
            for event in events {
                appendEvent(
                    tabID: tabID,
                    method: event.method,
                    detail: event.detail,
                    revision: event.revision
                )
            }
        } catch {
            // A navigation may replace the JS world between lookup and call.
            // Native lifecycle events still describe that transition.
        }
    }

    private func appendEvent(tabID: UUID, method: String, detail: String? = nil, revision: Int? = nil) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let sequence = tabs[index].nextEventSequence
        tabs[index].nextEventSequence += 1
        tabs[index].events.append(BrowserProtocolEvent(
            sequence: sequence,
            timestamp: Date(),
            tabID: tabID,
            documentID: tabs[index].documentID,
            method: method,
            detail: detail.map { String($0.prefix(512)) },
            revision: revision
        ))
        if tabs[index].events.count > maximumEventsPerTab {
            tabs[index].events.removeFirst(tabs[index].events.count - maximumEventsPerTab)
        }
        if let revision {
            tabs[index].revision = max(tabs[index].revision, revision)
        }
    }

    private func eventsResult(
        _ command: BrowserCommand,
        tabID: UUID,
        afterSequence: Int?,
        limit: Int,
        cancellation: CancellationToken?
    ) async -> BrowserResult {
        await collectProbeEvents(tabID: tabID, timeout: min(30_000, max(250, command.timeoutMilliseconds)), cancellation: cancellation)
        guard let tab = tabs.first(where: { $0.id == tabID }) else {
            return failure(command, status: .stale, code: "tab", "Browser tab is no longer available")
        }
        let floor = max(0, afterSequence ?? 0)
        let available = tab.events.filter { $0.sequence > floor }
        let boundedLimit = min(100, max(1, limit))
        let selected = Array(available.prefix(boundedLimit))
        return BrowserResult(
            requestID: command.requestID,
            status: .ok,
            events: selected,
            nextEventSequence: selected.last?.sequence ?? afterSequence,
            protocolVersion: protocolVersion
        )
    }

    private func waitResult(
        _ command: BrowserCommand,
        tabID: UUID,
        condition: BrowserWaitCondition,
        cancellation: CancellationToken?
    ) async -> BrowserResult {
        let timeout = min(30_000, max(250, command.timeoutMilliseconds))
        let deadline = Date().addingTimeInterval(Double(timeout) / 1_000)
        repeat {
            guard !isReleased else {
                return failure(command, status: .stale, code: "released", "This task's browser session was released")
            }
            guard let tab = tabs.first(where: { $0.id == tabID }) else {
                return failure(command, status: .stale, code: "tab", "Browser tab is no longer available")
            }
            await collectProbeEvents(tabID: tabID, timeout: timeout, cancellation: cancellation)
            if case .documentChanged(let oldDocumentID) = condition,
               tab.documentID != oldDocumentID {
                appendEvent(tabID: tabID, method: "Runtime.waitConditionSatisfied")
                return await observeResult(command, tabID: tabID, cursor: nil, cancellation: cancellation)
            }
            do {
                let state = try await probeState(tabID: tabID, condition: condition, timeout: timeout, cancellation: cancellation)
                let isLoading = tabs.first(where: { $0.id == tabID })?.surface.isLoading ?? false
                let satisfied: Bool
                switch condition {
                case .load:
                    // `readyState` is the page-world lifecycle signal that
                    // corresponds to CDP's load event. The WebView loading
                    // flag may lag for late-loaded data, same as WKWebView.
                    satisfied = state.readyState == "complete"
                case .domContentLoaded:
                    satisfied = state.readyState == "interactive" || state.readyState == "complete"
                case .selector:
                    satisfied = state.selectorFound
                case .text:
                    satisfied = state.textFound
                case .documentChanged:
                    satisfied = false
                case .idle(let milliseconds):
                    satisfied = !isLoading
                        && state.idleMilliseconds >= Double(min(5_000, max(100, milliseconds)))
                }
                if satisfied {
                    appendEvent(tabID: tabID, method: "Runtime.waitConditionSatisfied")
                    return await observeResult(command, tabID: tabID, cursor: nil, cancellation: cancellation)
                }
            } catch {
                // Document-start injection and page-world commit can briefly
                // race. Treat that as a not-yet-satisfied wait and retry until
                // the bounded deadline.
                if Date() >= deadline {
                    return failure(command, status: .failed, code: "probe", error.localizedDescription)
                }
            }
            try? await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline && !Task.isCancelled && cancellation?.isCancelled != true
        if Task.isCancelled || cancellation?.isCancelled == true {
            return failure(command, status: .failed, code: "cancelled", "Browser wait was cancelled")
        }
        return failure(command, status: .timeout, code: "timeout", "Browser wait condition timed out")
    }

    // MARK: - Screenshot evidence

    private func saveSnapshot(of tabID: UUID, cancellation: CancellationToken?) async throws -> BrowserArtifactReference {
        guard !isReleased else { throw BrowserProbeError.released }
        let shot = try await raced(timeout: 30_000, cancellation: cancellation) { [renderer] in
            try await renderer.captureScreenshot(tabID: tabID)
        }
        return try artifacts.store(jpeg: shot.jpeg, pixelWidth: shot.pixelWidth, pixelHeight: shot.pixelHeight)
    }

    private func recognizeVisualText(in artifact: BrowserArtifactReference) throws -> [VisualTextRegion] {
        guard let data = artifacts.read(artifact) else {
            throw BrowserPolicyError.blocked("The screenshot evidence file is missing")
        }
        return try visualText(data, artifact.pixelWidth, artifact.pixelHeight)
    }

    // MARK: - Renderer round-trip plumbing

    private func rendererCall(
        _ cancellation: CancellationToken?,
        timeout: Int = 30_000,
        _ body: @Sendable @escaping (any BrowserRenderer) async throws -> Void
    ) async throws {
        guard !isReleased else { throw BrowserProbeError.released }
        try await raced(timeout: timeout, cancellation: cancellation) { [renderer] in
            try await body(renderer)
        }
    }

    private func rendererState(
        tabID: UUID,
        timeout: Int,
        cancellation: CancellationToken?
    ) async throws -> BrowserRendererTabState {
        if !isReleased {
            do {
                return try await raced(timeout: timeout, cancellation: cancellation) { [renderer] in
                    try await renderer.state(tabID: tabID)
                }
            } catch {
                // Fall back to the last trusted platform snapshot for reads.
                // A stale surface never grants new capability; it only
                // describes the last observed page.
                if let tab = tabs.first(where: { $0.id == tabID }) { return tab.surface }
                throw error
            }
        }
        guard let tab = tabs.first(where: { $0.id == tabID }) else { throw BrowserProbeError.released }
        return tab.surface
    }

    private func evaluate(
        tabID: UUID,
        expression: String,
        cancellation: CancellationToken?,
        timeout: Int = 15_000
    ) async throws -> String {
        guard !isReleased else { throw BrowserProbeError.released }
        return try await raced(timeout: timeout, cancellation: cancellation) { [renderer] in
            try await renderer.evaluate(tabID: tabID, expression: expression, timeoutMilliseconds: timeout)
        }
    }

    /// Bound one renderer round trip: answer, deadline, cancellation, or
    /// owner release resolve it once; a late answer is dropped (the original
    /// BrowserProbeRequest contract).
    /// Bound one renderer round trip the way the iOS original bounded the
    /// uncooperative WKWebView callback (`BrowserProbeRequest`): the first
    /// of answer/deadline/cancellation/release settles the continuation
    /// EXACTLY ONCE; a late answer is dropped and NO task waits on an
    /// uncooperative native callback before returning the failure.
    private func raced<T: Sendable>(
        timeout: Int,
        cancellation: CancellationToken?,
        _ body: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        guard cancellation?.isCancelled != true else { throw CancellationError() }
        let gate = BrowserRaceGate<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                gate.install(continuation)
                let work = Task {
                    do {
                        let value = try await body()
                        gate.settle(.success(value))
                    } catch {
                        gate.settle(.failure(error))
                    }
                }
                gate.attach(work)
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(max(250, timeout)) * 1_000_000)
                    if !Task.isCancelled {
                        gate.settle(.failure(BrowserProbeError.timedOut))
                    }
                    work.cancel()
                }
            }
        } onCancel: {
            gate.settle(.failure(CancellationError()))
            gate.cancelWork()
        }
    }

    // MARK: - Mutation serialization

    private func acquireMutationGate(tabID: UUID) async {
        if mutationTails[tabID] != nil {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                mutationTails[tabID, default: []].append(continuation)
            }
        } else {
            mutationTails[tabID] = []
        }
    }

    private func releaseMutationGate(tabID: UUID) {
        guard var queue = mutationTails[tabID] else {
            mutationTails[tabID] = nil
            return
        }
        if queue.isEmpty {
            mutationTails[tabID] = nil
        } else {
            let next = queue.removeFirst()
            mutationTails[tabID] = queue
            next.resume()
        }
    }

    // MARK: - Snapshots

    public func tabSnapshots() -> [BrowserTabSnapshot] {
        tabs.map {
            BrowserTabSnapshot(
                id: $0.id,
                url: $0.surface.url ?? "",
                title: $0.surface.title ?? "",
                isActive: $0.id == activeTabID
            )
        }
    }

    private func failure(
        _ command: BrowserCommand,
        status: BrowserResult.Status,
        code: String,
        _ message: String
    ) -> BrowserResult {
        BrowserResult(
            requestID: command.requestID,
            status: status,
            message: message,
            error: BrowserFailure(code: code, message: message)
        )
    }
}
