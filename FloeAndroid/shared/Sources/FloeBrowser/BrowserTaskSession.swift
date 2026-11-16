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
//    availability): the probe exposes only bounded whitelisted functions and
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
    case unavailable
}

enum BrowserInteractionError: Error, Sendable, Equatable {
    case needsUser(String)
    case stale(String)
}

enum BrowserNavigationError: Error, Sendable {
    case failed(BrowserFailure)
}

public actor BrowserTaskSession {
    public struct VisualFallbackEvidence: Sendable {
        public var documentID: String
        public var documentToken: String
        public var documentURL: String
        public var sha256: String
        public var capturedAt: Date
        public var pixelWidth: Int
        public var pixelHeight: Int
        public var viewportWidth: Double
        public var viewportHeight: Double
        public var scrollX: Double
        public var scrollY: Double
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
        // A platform error can be followed by loadFinished for its error page.
        // Keep that fact per tab until a genuinely new navigation starts.
        var navigationFailure: BrowserFailure?
        /// Invalidates reads as soon as a navigation is requested or begins,
        /// not only after the platform eventually reports its commit.
        var navigationRevision: UInt64 = 0
        var navigationPending = false
        var navigationUncertain = false
        var navigationAttempt: UInt64 = 0
        var committedAttempt: UInt64?
        var probeDocumentToken: String?
        var previousProbeDocumentToken: String?

        init(id: UUID, documentID: String) {
            self.id = id
            self.documentID = documentID
            self.revision = 0
            self.nextEventSequence = 1
            self.events = []
            self.visualFallbackEvidence = nil
            self.surface = BrowserRendererTabState()
            self.navigationFailure = nil
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
    public func createTab(tabApprovalProof: BrowserTabApprovalProof? = nil, cancellation: CancellationToken? = nil) async -> UUID? {
        guard !isReleased, tabs.count < maximumTabs else { return nil }
        if let proof = tabApprovalProof, !matchesCreateApproval(proof) { return nil }
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
        guard !isReleased, tabs.contains(where: { $0.id == id }) else {
            await renderer.destroyTab(tabID: id)
            return nil
        }
        if let proof = tabApprovalProof,
           (isUserControlling || cancellation?.isCancelled == true || Task.isCancelled ||
            activeTabID != proof.activeTabID || tabs.filter({ $0.id != id }).map(\.id) != proof.tabIDs) {
            // Creation was already dispatched; preserve the tab and the user's
            // current selection, and let the caller inspect the uncertain result.
            appendEvent(tabID: id, method: "Target.targetCreated")
            return nil
        }
        activeTabID = id
        appendEvent(tabID: id, method: "Target.targetCreated")
        return id
    }

    /// Complete, non-mutating presentation proof for one reviewed tab
    /// action. `create` needs no target identity; `activate`/`close` bind the
    /// exact target tab through native session state (tab UUID, document
    /// identity, navigation revision and the surfaced URL/title). Page
    /// JavaScript never supplies or overrides any of these facts.
    public func approvalTabProof(action: String, tabID: UUID?) async throws -> BrowserTabApprovalProof {
        guard !isReleased, !isUserControlling,
              !BrowserLifecycleHealth.shared.epochIsSaturated(owner.rootEpoch) else {
            throw BrowserInteractionError.stale("The browser tab action cannot be reviewed")
        }
        switch action {
        case "create":
            guard tabID == nil, tabs.count < maximumTabs else {
                throw BrowserInteractionError.stale("The browser tab action cannot be reviewed")
            }
            return BrowserTabApprovalProof(owner: owner, sessionID: sessionID, operation: "create",
                tabID: nil, activeTabID: activeTabID, documentID: nil, navigationRevision: nil,
                url: nil, title: nil, tabCount: tabs.count, maximumTabs: maximumTabs, tabIDs: tabs.map(\.id))
        case "activate", "close":
            guard let tabID, let tab = tabs.first(where: { $0.id == tabID }),
                  targetIsReviewable(tab) else {
                throw BrowserInteractionError.stale("The browser tab is no longer available")
            }
            if action == "activate", activeTabID == tabID {
                throw BrowserInteractionError.stale("The browser tab is already active")
            }
            if action == "close", tabs.count <= 1 {
                throw BrowserInteractionError.stale("The last browser tab cannot be closed")
            }
            return BrowserTabApprovalProof(owner: owner, sessionID: sessionID, operation: action,
                tabID: tabID, activeTabID: activeTabID, documentID: tab.documentID,
                navigationRevision: tab.navigationRevision, url: tab.surface.url, title: tab.surface.title,
                tabCount: tabs.count, maximumTabs: maximumTabs, tabIDs: tabs.map(\.id))
        default:
            throw BrowserInteractionError.stale("The browser tab action cannot be reviewed")
        }
    }

    /// Inspect the live target without returning its current value. This is a
    /// presentation proof, not a grant; it must be checked again on dispatch.
    public func approvalInteractionProof(action: BrowserAction, tabID requested: UUID?) async throws -> BrowserInteractionApprovalProof {
        guard !isReleased, !isUserControlling,
              !BrowserLifecycleHealth.shared.epochIsSaturated(owner.rootEpoch),
              let id = requested ?? activeTabID, let tab = tabs.first(where: { $0.id == id }),
              targetIsReviewable(tab), let token = tab.probeDocumentToken, !token.isEmpty,
              let url = tab.surface.url, !url.isEmpty, url.utf8.count <= 2_048,
              tab.documentID.utf8.count <= 128 else {
            throw BrowserInteractionError.stale("Observe the current page before reviewing this action")
        }
        var operation = ""; var ref: String?; var role: String?; var label: String?
        var targetRole: String?; var targetLabel: String?
        var digest: String?; var bytes: Int?; var submit: Bool?; var dx: Double?; var dy: Double?
        switch action {
        case .click(.element(let target, let document)):
            guard document == tab.documentID, !target.isEmpty, target.utf8.count <= 128 else { throw BrowserInteractionError.stale("The browser target changed") }
            operation = "click"; ref = target
        case .type(.element(let target, let document), let text, let shouldSubmit):
            guard document == tab.documentID, !target.isEmpty, target.utf8.count <= 128,
                  text.utf8.count <= 16 * 1024 else { throw BrowserInteractionError.stale("The browser target changed") }
            operation = "type"; ref = target; digest = FloeDigest.sha256Hex(Data(text.utf8))
            bytes = text.utf8.count; submit = shouldSubmit
        case .scroll(let x, let y):
            guard x.isFinite, y.isFinite, abs(x) <= 20_000, abs(y) <= 20_000 else { throw BrowserInteractionError.stale("The scroll request is invalid") }
            operation = "scroll"; dx = x; dy = y
        default: throw BrowserInteractionError.stale("This browser action cannot be reviewed")
        }
        let revision: Int
        if let ref {
            struct ReviewTarget: Decodable {
                let status: String; let documentToken: String?; let documentURL: String?
                let revision: Int?; let role: String?; let label: String?
                let sensitive: Bool?; let editable: Bool?
            }
            let raw = try await evaluate(tabID: id, expression: BrowserProbeScript.reviewTargetExpression(documentID: tab.documentID, ref: ref), cancellation: nil, timeout: 1_200)
            try ensureObservationCurrent(tabID: id, documentID: tab.documentID, revision: tab.navigationRevision)
            guard let item = try? JSONDecoder().decode(ReviewTarget.self, from: Data(raw.utf8)),
                  item.status == "ok", item.documentToken == token, item.documentURL == url,
                  let pageRevision = item.revision, pageRevision >= 0, item.sensitive == false,
                  let rawRole = item.role, let rawLabel = item.label,
                  (operation != "type" || item.editable == true) else {
                throw BrowserInteractionError.stale("The browser target cannot be reviewed")
            }
            role = Self.approvalDisplayText(item.role, maximumBytes: 128)
            label = Self.approvalDisplayText(item.label, maximumBytes: 512)
            targetRole = rawRole; targetLabel = rawLabel
            guard role != nil || label != nil else { throw BrowserInteractionError.stale("The browser target has no identifiable label") }
            revision = pageRevision
        } else {
            let raw = try await evaluate(tabID: id, expression: BrowserProbeScript.identityExpression, cancellation: nil, timeout: 1_200)
            try ensureObservationCurrent(tabID: id, documentID: tab.documentID, revision: tab.navigationRevision)
            guard let item = try? JSONDecoder().decode(ProbeIdentity.self, from: Data(raw.utf8)),
                  item.probeAvailable, item.documentToken == token, item.documentURL == url,
                  let pageRevision = item.revision, pageRevision >= 0 else { throw BrowserInteractionError.stale("The browser page cannot be reviewed") }
            revision = pageRevision
        }
        guard !isUserControlling, requested != nil || activeTabID == id else { throw BrowserInteractionError.stale("The active browser tab changed") }
        return BrowserInteractionApprovalProof(owner: owner, sessionID: sessionID, operation: operation,
            requestedTabID: requested, tabID: id, documentID: tab.documentID,
            navigationRevision: tab.navigationRevision, documentToken: token, pageRevision: revision,
            url: url, title: Self.approvalDisplayText(tab.surface.title, maximumBytes: 512),
            ref: ref, role: role, label: label, targetRole: targetRole, targetLabel: targetLabel,
            textDigest: digest, textBytes: bytes, submit: submit, deltaX: dx, deltaY: dy)
    }

    private static func approvalDisplayText(_ text: String?, maximumBytes: Int) -> String? {
        guard let text else { return nil }
        let safe = String(text.unicodeScalars.filter { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .unassigned: false
            default: true
            }
        }).trimmingCharacters(in: .whitespacesAndNewlines)
        var result = ""
        for c in safe { if result.utf8.count + String(c).utf8.count > maximumBytes { break }; result.append(c) }
        return result.isEmpty ? nil : result
    }

    private func matchesInteractionApproval(_ proof: BrowserInteractionApprovalProof, command: BrowserCommand) -> Bool {
        guard !isReleased, !isUserControlling, proof.owner == owner, proof.sessionID == sessionID,
              command.tabID == proof.requestedTabID, (command.tabID ?? activeTabID) == proof.tabID,
              let tab = tabs.first(where: { $0.id == proof.tabID }), targetIsReviewable(tab),
              tab.documentID == proof.documentID, tab.navigationRevision == proof.navigationRevision,
              tab.probeDocumentToken == proof.documentToken, tab.surface.url == proof.url else { return false }
        switch command.action {
        case .click(.element(let ref, let document)):
            return proof.operation == "click" && proof.ref == ref && proof.documentID == document &&
                proof.targetRole != nil && proof.targetLabel != nil
        case .type(.element(let ref, let document), let text, let submit):
            return proof.operation == "type" && proof.ref == ref && proof.documentID == document &&
                proof.targetRole != nil && proof.targetLabel != nil &&
                proof.textDigest == FloeDigest.sha256Hex(Data(text.utf8)) && proof.textBytes == text.utf8.count && proof.submit == submit
        case .scroll(let x, let y):
            return proof.operation == "scroll" && proof.deltaX == x && proof.deltaY == y
        default: return false
        }
    }

    private func matchesCreateApproval(_ proof: BrowserTabApprovalProof) -> Bool {
        guard !isReleased, !isUserControlling,
              !BrowserLifecycleHealth.shared.epochIsSaturated(owner.rootEpoch),
              proof.owner == owner, proof.sessionID == sessionID, proof.operation == "create",
              proof.tabID == nil, proof.documentID == nil, proof.navigationRevision == nil,
              proof.url == nil, proof.title == nil,
              proof.activeTabID == activeTabID, proof.tabCount == tabs.count,
              proof.maximumTabs == maximumTabs, proof.tabIDs == tabs.map(\.id) else { return false }
        return tabs.count < maximumTabs
    }

    /// Recheck the complete reviewed snapshot immediately before the exact
    /// tab action runs. Every difference (target document/navigation, the tab
    /// set, the active tab, ownership, session or user takeover) is a refusal,
    /// never a substitute target.
    private func matchesTabApproval(_ proof: BrowserTabApprovalProof, command: BrowserCommand) -> Bool {
        guard !isReleased, !isUserControlling,
              !BrowserLifecycleHealth.shared.epochIsSaturated(owner.rootEpoch),
              proof.owner == owner, proof.sessionID == sessionID,
              command.expectedDocumentID == nil,
              proof.activeTabID == activeTabID,
              proof.tabCount == tabs.count, proof.maximumTabs == maximumTabs,
              proof.tabIDs == tabs.map(\.id) else { return false }
        switch command.action {
        case .create:
            guard command.tabID == nil else { return false }
            return matchesCreateApproval(proof)
        case .activateTab(let id):
            guard proof.operation == "activate", proof.tabID == id,
                  command.tabID == nil || command.tabID == id,
                  activeTabID != id,
                  let tab = tabs.first(where: { $0.id == id }) else { return false }
            return matchesApprovedTarget(proof, tab: tab)
        case .closeTab(let id):
            guard proof.operation == "close", proof.tabID == id,
                  command.tabID == nil || command.tabID == id,
                  tabs.count > 1,
                  let tab = tabs.first(where: { $0.id == id }) else { return false }
            return matchesApprovedTarget(proof, tab: tab)
        default:
            return false
        }
    }

    private func matchesApprovedTarget(_ proof: BrowserTabApprovalProof, tab: Tab) -> Bool {
        targetIsReviewable(tab) && proof.documentID == tab.documentID &&
            proof.navigationRevision == tab.navigationRevision &&
            proof.url == tab.surface.url &&
            proof.title == tab.surface.title
    }

    /// A retained URL/title is not evidence of the currently displayed page
    /// while navigation is in flight, uncertain, or lifecycle events were lost.
    private func targetIsReviewable(_ tab: Tab) -> Bool {
        !tab.navigationPending && !tab.navigationUncertain &&
            !BrowserLifecycleHealth.shared.hasGap(epoch: owner.rootEpoch, tabID: tab.id)
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
        if activeTabID == id, !isReleased, !tabs.isEmpty { activeTabID = tabs[min(index, tabs.count - 1)].id }
    }

    public func navigateFromAddressBar() async {
        await navigateFromAddressBar(draft: nil)
    }

    /// Commit the address bar. With a [draft] (the draft-carrying G04 commit
    /// op) the exact text is applied, the editing flag cleared, the candidate
    /// captured and the policy validated BEFORE the first suspension: actor
    /// interleaving (an older keystroke-echo Task) can still happen after
    /// that point, but it can never change the target THIS commit navigates
    /// to. A nil draft keeps the exact legacy semantics (editing state is
    /// untouched and the stored addressText is used, as when the UI cleared
    /// editing through a separate `setEditingAddress` call).
    public func navigateFromAddressBar(draft: String?) async {
        guard !isReleased else { return }
        if let draft {
            addressText = draft
            isEditingAddress = false
        }
        if let currentURL = activeTabSurface?.url, let url = URL(string: currentURL),
           Self.isLocalPreview(url),
           addressText == currentURL {
            await reloadActiveTab()
            return
        }
        let candidate = addressText.contains("://") ? addressText : "https://\(addressText)"
        // The policy itself is unchanged; only its SILENCE is fixed. The
        // original `try?` dead-ends left the user staring at a blank tab
        // with no way to tell "blocked" from "nothing happened".
        let url: URL
        do {
            url = try policy.validate(candidate, conversationID: conversationID)
        } catch {
            surfaceState = .failed(error.localizedDescription)
            return
        }
        guard let activeTabID else { return }
        do {
            if let index = tabs.firstIndex(where: { $0.id == activeTabID }) {
                tabs[index].navigationFailure = nil
            }
            try await renderer.navigate(tabID: activeTabID, url: url)
            // Accepted navigation: clear a stale blocked/failure banner so
            // the lifecycle pump owns the state from loadStarted onward.
            if self.activeTabID == activeTabID,
               let tab = tabs.first(where: { $0.id == activeTabID }),
               tab.navigationFailure == nil, case .failed = surfaceState {
                surfaceState = .loading
            }
        } catch let error as BrowserRendererError {
            switch error {
            case .released, .unavailable:
                break // the lifecycle/release owner already reports this honestly
            case .failed(let reason):
                surfaceState = .failed(reason) // platform fact, like the loadFailed ingress
            case .timedOut:
                // Reuses the existing browser_load_failed sentence; no new
                // copy framework is introduced in this flow.
                surfaceState = .failed("The page could not be loaded.")
            }
        } catch {
            surfaceState = .failed("The page could not be loaded.")
        }
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
            if !tabs[index].navigationPending {
                tabs[index].navigationRevision &+= 1
                tabs[index].navigationAttempt &+= 1
                tabs[index].navigationPending = true
                tabs[index].previousProbeDocumentToken = tabs[index].probeDocumentToken
                tabs[index].visualFallbackEvidence = nil
            }
            tabs[index].navigationFailure = nil
            tabs[index].surface.isLoading = true
            appendEvent(tabID: tabID, method: "Page.frameStartedLoading")
            surfaceState = .loading
        case .loadCommitted(let tabID):
            guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
            // Navigation commit rotates document identity exactly like the
            // original didCommit: older refs and evidence are dead data.
            tabs[index].documentID = UUID().uuidString
            tabs[index].revision = 0
            tabs[index].navigationRevision &+= 1
            tabs[index].navigationPending = false
            tabs[index].navigationUncertain = false
            tabs[index].committedAttempt = tabs[index].navigationAttempt
            tabs[index].probeDocumentToken = nil
            tabs[index].visualFallbackEvidence = nil
            appendEvent(tabID: tabs[index].id, method: "Page.frameNavigated")
        case .loadFinished(let tabID, let url, let title):
            guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
            // A finish without a matching commit may belong to the previous
            // page. It cannot complete an outstanding navigation.
            guard !tabs[index].navigationPending || tabs[index].navigationFailure != nil else { return }
            tabs[index].surface.url = url
            tabs[index].surface.title = title
            tabs[index].surface.isLoading = false
            if tabs[index].navigationFailure == nil {
                appendEvent(tabID: tabs[index].id, method: "Page.loadEventFired")
            } else {
                appendEvent(tabID: tabs[index].id, method: "Page.frameStoppedLoading", detail: "loadFailed")
            }
            if tabs[index].id == activeTabID { refreshVisibleAddress() }
            if tabs[index].id == activeTabID {
                if let failure = tabs[index].navigationFailure {
                    surfaceState = .failed(failure.message)
                } else {
                    surfaceState = isUserControlling ? .needsUser("User takeover is active") : .ready
                }
            }
        case .loadFailed(let tabID, let errorDomain, let errorCode, let errorDescription):
            guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
            tabs[index].navigationPending = false
            tabs[index].navigationRevision &+= 1
            if errorDomain == "FloeLifecycle" && errorCode == -699 {
                tabs[index].navigationUncertain = true
                tabs[index].visualFallbackEvidence = nil
            }
            tabs[index].surface.isLoading = false
            tabs[index].navigationFailure = BrowserFailure(
                code: "navigation-load-failed",
                message: "\(errorDescription.prefix(512)) (\(errorDomain.prefix(64)):\(errorCode))"
            )
            appendEvent(
                tabID: tabs[index].id,
                method: "Network.loadingFailed",
                detail: "\(errorDomain):\(errorCode)"
            )
            if tabs[index].id == activeTabID {
                surfaceState = .failed("\(errorDescription) (\(errorCode))")
            }
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
        if let proof = command.tabApprovalProof {
            guard matchesTabApproval(proof, command: command) else {
                return failure(command, status: .stale, code: "approval-changed", "The reviewed browser tab state changed")
            }
        }
        if let proof = command.interactionApprovalProof, !matchesInteractionApproval(proof, command: command) {
            return failure(command, status: .stale, code: "approval-changed", "The reviewed browser action changed")
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
            guard let id = await createTab(tabApprovalProof: command.tabApprovalProof, cancellation: cancellation) else {
                if command.tabApprovalProof != nil {
                    return failure(command, status: .failed, code: "outcome-unknown", "Tab creation may have started. Inspect the tabs before trying again.")
                }
                return failure(command, status: .blocked, code: "tab-limit", "The six-tab limit was reached")
            }
            return tabManagementResult(command, tabID: id, message: "Tab created. Page contents have not been observed.")
        case .listTabs:
            return tabManagementResult(command, tabID: command.tabID ?? activeTabID, message: "Tabs listed. Page contents have not been observed.")
        case .activateTab(let id):
            guard tabs.contains(where: { $0.id == id }) else {
                return failure(command, status: .stale, code: "tab", "Browser tab is no longer available")
            }
            activate(id)
            return tabManagementResult(command, tabID: id, message: "Tab activated. Page contents have not been observed.")
        case .closeTab(let id):
            guard tabs.contains(where: { $0.id == id }) else {
                return failure(command, status: .stale, code: "tab", "Browser tab is no longer available")
            }
            guard tabs.count > 1 else {
                return failure(command, status: .blocked, code: "last-tab", "The last browser tab cannot be closed")
            }
            await close(id)
            return tabManagementResult(command, tabID: activeTabID, message: "Tab closed. Page contents have not been observed.")
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
        if let expected = command.expectedDocumentID,
           tabs.first(where: { $0.id == tabID })?.documentID != expected {
            return failure(command, status: .stale, code: "document", "The page changed; observe it again")
        }
        // Re-read the takeover fence AFTER the gate: an action queued behind
        // slow work while the agent still had control must be refused if the
        // user took control during its wait. The flag is never captured at
        // enqueue time.
        if isMutation, isUserControlling {
            return failure(command, status: .needsUser, code: "takeover", "The user currently controls the browser")
        }

        var startedAttempt: UInt64?
        defer {
            if let attempt = startedAttempt,
               let index = tabs.firstIndex(where: { $0.id == tabID }),
               tabs[index].navigationAttempt == attempt, tabs[index].navigationPending {
                // A timeout or cancellation does not establish which document
                // is visible. Fence reads until a real commit or new navigation.
                tabs[index].navigationPending = false
                tabs[index].navigationUncertain = true
                tabs[index].navigationRevision &+= 1
                tabs[index].visualFallbackEvidence = nil
            }
        }
        if BrowserLifecycleHealth.shared.epochIsSaturated(owner.rootEpoch) {
            return failure(command, status: .stale, code: "lifecycle-capacity", "Browser events could not be processed. Restart the app to resume browsing.")
        }
        if BrowserLifecycleHealth.shared.hasGap(epoch: owner.rootEpoch, tabID: tabID) {
            return failure(command, status: .stale, code: "lifecycle-gap", "Browser events were missed. Wait, then reload or navigate again.")
        }
        if tabs.first(where: { $0.id == tabID })?.navigationUncertain == true {
            switch command.action {
            case .navigate, .reload:
                break // A new explicit navigation can recover this tab.
            default:
                return failure(command, status: .stale, code: "navigation-uncertain",
                               "The page could not be confirmed. Navigate to the address again or reload it.")
            }
        }
        do {
            switch command.action {
            case .navigate(let value):
                let url = try policy.validate(value, conversationID: conversationID)
                let prior = await currentProbeToken(tabID: tabID, cancellation: cancellation)
                let priorURL = try? await rendererState(tabID: tabID, timeout: 1_200, cancellation: cancellation).url
                let sameDocument = priorURL.flatMap(URL.init(string:)).map { Self.isFragmentChange(from: $0, to: url) } ?? false
                let attempt = try beginNavigation(tabID: tabID, priorToken: prior, expectedDocumentID: command.expectedDocumentID, cancellation: cancellation)
                startedAttempt = attempt
                try await rendererCall(cancellation) { renderer in
                    try await renderer.navigate(tabID: tabID, url: url)
                }
                if sameDocument, let prior {
                    try await waitForFragmentNavigation(tabID: tabID, attempt: attempt, target: url,
                                                        token: prior, timeout: command.timeoutMilliseconds,
                                                        cancellation: cancellation)
                } else {
                    try await waitForNavigationCommit(tabID: tabID, attempt: attempt,
                                                      timeout: command.timeoutMilliseconds, cancellation: cancellation)
                }
            case .back:
                let state = try await rendererState(tabID: tabID, timeout: 1_200, cancellation: cancellation)
                guard state.canGoBack else { return failure(command, status: .blocked, code: "no-history", "There is no previous page") }
                let prior = await currentProbeToken(tabID: tabID, cancellation: cancellation)
                let attempt = try beginNavigation(tabID: tabID, priorToken: prior, expectedDocumentID: command.expectedDocumentID, cancellation: cancellation)
                startedAttempt = attempt
                try await rendererCall(cancellation) { renderer in
                    try await renderer.goBack(tabID: tabID)
                }
                try await waitForHistoryNavigation(tabID: tabID, attempt: attempt, oldURL: state.url,
                                                   token: prior, timeout: command.timeoutMilliseconds, cancellation: cancellation)
            case .forward:
                let state = try await rendererState(tabID: tabID, timeout: 1_200, cancellation: cancellation)
                guard state.canGoForward else { return failure(command, status: .blocked, code: "no-history", "There is no next page") }
                let prior = await currentProbeToken(tabID: tabID, cancellation: cancellation)
                let attempt = try beginNavigation(tabID: tabID, priorToken: prior, expectedDocumentID: command.expectedDocumentID, cancellation: cancellation)
                startedAttempt = attempt
                try await rendererCall(cancellation) { renderer in
                    try await renderer.goForward(tabID: tabID)
                }
                try await waitForHistoryNavigation(tabID: tabID, attempt: attempt, oldURL: state.url,
                                                   token: prior, timeout: command.timeoutMilliseconds, cancellation: cancellation)
            case .reload:
                let prior = await currentProbeToken(tabID: tabID, cancellation: cancellation)
                let attempt = try beginNavigation(tabID: tabID, priorToken: prior, expectedDocumentID: command.expectedDocumentID, cancellation: cancellation)
                startedAttempt = attempt
                try await rendererCall(cancellation) { renderer in
                    try await renderer.reload(tabID: tabID)
                }
                try await waitForNavigationCommit(tabID: tabID, attempt: attempt,
                                                  timeout: command.timeoutMilliseconds, cancellation: cancellation)
            case .observe(let cursor):
                return await observeResult(command, tabID: tabID, cursor: cursor, cancellation: cancellation)
            case .screenshot:
                let capture = try await saveSnapshot(of: tabID, cancellation: cancellation)
                let artifact = capture.artifact
                var delivered = false
                defer { if !delivered { artifacts.discard(artifact) } }
                let visualTextRegions = try recognizeVisualText(in: artifact)
                var result = await observeResult(command, tabID: tabID, cursor: nil, cancellation: cancellation)
                try await verifyScreenshot(capture, tabID: tabID, cancellation: cancellation)
                if result.error?.code == "probe-unavailable" {
                    result = tabManagementResult(command, tabID: tabID, message: "Screenshot captured; structured page contents are unavailable.")
                    result.page?.url = capture.url
                }
                result.page?.screenshotArtifact = artifact
                result.page?.visualTextRegions = visualTextRegions
                delivered = result.page != nil
                if let page = result.page, page.structuredObservationAvailable == true,
                   capture.probeFrame?.revision == page.revision, capture.probeFrame?.width == page.viewportWidth,
                   capture.probeFrame?.height == page.viewportHeight, capture.probeFrame != nil,
                   let currentIndex = tabs.firstIndex(where: { $0.id == tabID }) {
                    tabs[currentIndex].visualFallbackEvidence = VisualFallbackEvidence(
                        documentID: tabs[currentIndex].documentID,
                        documentToken: capture.token,
                        documentURL: capture.url,
                        sha256: artifact.sha256.lowercased(),
                        capturedAt: Date(),
                        pixelWidth: artifact.pixelWidth,
                        pixelHeight: artifact.pixelHeight,
                        viewportWidth: page.viewportWidth,
                        viewportHeight: page.viewportHeight,
                        scrollX: capture.probeFrame!.scrollX,
                        scrollY: capture.probeFrame!.scrollY,
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
                        expectedVisualRevision: evidence.revision,
                        expectedVisualToken: evidence.documentToken,
                        expectedVisualURL: evidence.documentURL,
                        expectedVisualScrollX: evidence.scrollX,
                        expectedVisualScrollY: evidence.scrollY,
                        expectedVisualWidth: evidence.viewportWidth,
                        expectedVisualHeight: evidence.viewportHeight,
                        cancellation: cancellation
                    )
                    // Synthetic pointer dispatch is not proof that the
                    // intended visual target accepted the action. Capture the
                    // viewport again and require an observable state change.
                    try? await Task.sleep(for: .milliseconds(250))
                    let postCapture = try await saveSnapshot(of: tabID, cancellation: cancellation)
                    let postArtifact = postCapture.artifact
                    var delivered = false
                    defer { if !delivered { artifacts.discard(postArtifact) } }
                    let postVisualTextRegions = try recognizeVisualText(in: postArtifact)
                    var result = await observeResult(command, tabID: tabID, cursor: nil, cancellation: cancellation)
                    try await verifyScreenshot(postCapture, tabID: tabID, cancellation: cancellation)
                    result.page?.screenshotArtifact = postArtifact
                    result.page?.visualTextRegions = postVisualTextRegions
                    delivered = result.page != nil
                    let changed = (result.page.map {
                        $0.documentID != evidence.documentID
                            || $0.revision > evidence.revision
                            || postArtifact.sha256.lowercased() != evidence.sha256
                    } ?? false)
                    if let page = result.page, page.structuredObservationAvailable == true,
                       postCapture.probeFrame?.revision == page.revision, postCapture.probeFrame?.width == page.viewportWidth,
                       postCapture.probeFrame?.height == page.viewportHeight, postCapture.probeFrame != nil,
                       let currentIndex = tabs.firstIndex(where: { $0.id == tabID }) {
                        tabs[currentIndex].visualFallbackEvidence = VisualFallbackEvidence(
                            documentID: page.documentID,
                            documentToken: postCapture.token,
                            documentURL: postCapture.url,
                            sha256: postArtifact.sha256.lowercased(),
                            capturedAt: Date(),
                            pixelWidth: postArtifact.pixelWidth,
                            pixelHeight: postArtifact.pixelHeight,
                            viewportWidth: page.viewportWidth,
                            viewportHeight: page.viewportHeight,
                            scrollX: postCapture.probeFrame!.scrollX,
                            scrollY: postCapture.probeFrame!.scrollY,
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
                    expectedVisualRevision: command.interactionApprovalProof?.pageRevision,
                    expectedVisualToken: command.interactionApprovalProof?.documentToken,
                    expectedVisualURL: command.interactionApprovalProof?.url,
                    expectedReviewRole: command.interactionApprovalProof?.targetRole,
                    expectedReviewLabel: command.interactionApprovalProof?.targetLabel,
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
                    expectedVisualRevision: command.interactionApprovalProof?.pageRevision,
                    expectedVisualToken: command.interactionApprovalProof?.documentToken,
                    expectedVisualURL: command.interactionApprovalProof?.url,
                    expectedReviewRole: command.interactionApprovalProof?.targetRole,
                    expectedReviewLabel: command.interactionApprovalProof?.targetLabel,
                    cancellation: cancellation
                )
                // A post-input DOM snapshot can echo the complete text,
                // fragments or a submitted URL. Do not place that content in
                // live or durable tool results. The user may explicitly
                // observe the page in a separate operation.
                try cancellation?.throwIfCancelled()
                try Task.checkCancellation()
                return BrowserResult(requestID: command.requestID, status: .ok,
                    message: "Input was applied. Observe the page to continue.")
            case .scroll(let x, let y):
                guard let index = tabs.firstIndex(where: { $0.id == tabID }),
                      !tabs[index].navigationPending, !tabs[index].navigationUncertain,
                      !BrowserLifecycleHealth.shared.hasGap(epoch: owner.rootEpoch, tabID: tabID),
                      let token = tabs[index].probeDocumentToken, !token.isEmpty,
                      let url = tabs[index].surface.url, !url.isEmpty else {
                    throw BrowserInteractionError.stale("Observe the current page before scrolling")
                }
                let documentID = tabs[index].documentID
                let navigationRevision = tabs[index].navigationRevision
                tabs[index].visualFallbackEvidence = nil
                let raw = try await evaluate(tabID: tabID, expression: BrowserProbeScript.scrollExpression(deltaX: x, deltaY: y, expectedDocumentToken: command.interactionApprovalProof?.documentToken ?? token, expectedDocumentURL: command.interactionApprovalProof?.url ?? url, expectedRevision: command.interactionApprovalProof?.pageRevision), cancellation: cancellation)
                try ensureObservationCurrent(tabID: tabID, documentID: documentID, revision: navigationRevision)
                struct ScrollReply: Decodable { let status: String }
                guard let reply = try? JSONDecoder().decode(ScrollReply.self, from: Data(raw.utf8)), reply.status == "ok" else {
                    throw BrowserInteractionError.stale("The page changed; observe it again before scrolling")
                }
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
        } catch BrowserProbeError.timedOut {
            return failure(command, status: .timeout, code: "timeout", "Browser navigation did not commit before the deadline")
        } catch BrowserNavigationError.failed(let error) {
            return BrowserResult(requestID: command.requestID, status: .failed, message: error.message, error: error)
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

    /// Tab management commits independently of page JS. Return its real tab
    /// receipt even if a blank/new page has not installed a semantic probe.
    private func tabManagementResult(_ command: BrowserCommand, tabID: UUID?, message: String) -> BrowserResult {
        guard !isReleased, let tabID, let tab = tabs.first(where: { $0.id == tabID }) else {
            return failure(command, status: .stale, code: "tab", "Browser tab is no longer available")
        }
        let state = tab.surface
        let page = PageSnapshot(documentID: tab.documentID, revision: tab.revision,
                                url: state.url ?? "", title: state.title ?? "", isLoading: state.isLoading,
                                viewportWidth: state.viewportWidth, viewportHeight: state.viewportHeight,
                                scrollX: state.scrollX, scrollY: state.scrollY, tabs: tabSnapshots(), nodes: [],
                                nextCursor: nil, screenshotArtifact: nil, structuredObservationAvailable: false)
        return BrowserResult(requestID: command.requestID, status: .ok, page: page, message: message)
    }

    /// Fence old document data before asking the platform to start a load.
    private func beginNavigation(
        tabID: UUID, priorToken: String?, expectedDocumentID: String?, cancellation: CancellationToken?
    ) throws -> UInt64 {
        try Task.checkCancellation()
        if cancellation?.isCancelled == true { throw CancellationError() }
        guard !isReleased else { throw BrowserProbeError.released }
        if isUserControlling { throw BrowserInteractionError.needsUser("The user currently controls the browser") }
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else {
            throw BrowserInteractionError.stale("Browser tab is no longer available")
        }
        if let expectedDocumentID, tabs[index].documentID != expectedDocumentID {
            throw BrowserInteractionError.stale("The page changed; observe it again")
        }
        tabs[index].navigationAttempt &+= 1
        tabs[index].navigationRevision &+= 1
        tabs[index].navigationPending = true
        tabs[index].navigationUncertain = false
        tabs[index].navigationFailure = nil
        tabs[index].previousProbeDocumentToken = priorToken ?? tabs[index].probeDocumentToken
        tabs[index].visualFallbackEvidence = nil
        return tabs[index].navigationAttempt
    }

    private struct ProbeIdentity: Decodable {
        let probeAvailable: Bool
        let documentToken: String?
        let documentURL: String?
        let revision: Int?
        let scrollX: Double?
        let scrollY: Double?
        let viewportWidth: Double?
        let viewportHeight: Double?
    }

    private static func isFragmentChange(from oldURL: URL, to newURL: URL) -> Bool {
        guard var old = URLComponents(url: oldURL, resolvingAgainstBaseURL: false),
              var new = URLComponents(url: newURL, resolvingAgainstBaseURL: false),
              old.fragment != new.fragment else { return false }
        old.fragment = nil
        new.fragment = nil
        return old.url == new.url
    }

    /// Fragment changes do not always emit a WebView commit. Confirm both
    /// the actual destination and the unchanged real document token instead.
    private func waitForFragmentNavigation(
        tabID: UUID, attempt: UInt64, target: URL, token: String,
        timeout: Int, cancellation: CancellationToken?
    ) async throws {
        let deadline = Date().addingTimeInterval(Double(min(30_000, max(250, timeout))) / 1_000)
        while Date() < deadline {
            try Task.checkCancellation()
            if cancellation?.isCancelled == true { throw CancellationError() }
            guard !isReleased else { throw BrowserProbeError.released }
            guard !BrowserLifecycleHealth.shared.hasGap(epoch: owner.rootEpoch, tabID: tabID) else {
                throw BrowserInteractionError.stale("Browser events were missed. Reload or navigate again.")
            }
            guard let tab = tabs.first(where: { $0.id == tabID }), tab.navigationAttempt == attempt else {
                throw BrowserInteractionError.stale("The page changed; observe it again")
            }
            if isUserControlling { throw BrowserInteractionError.needsUser("The user currently controls the browser") }
            if let error = tab.navigationFailure { throw BrowserNavigationError.failed(error) }
            if !tab.navigationPending && tab.committedAttempt == attempt { return }
            if let surface = try? await rendererState(tabID: tabID, timeout: 1_000, cancellation: cancellation),
               surface.url.flatMap(URL.init(string:)) == target,
               let raw = try? await evaluate(tabID: tabID, expression: BrowserProbeScript.documentStampExpression,
                                              cancellation: cancellation, timeout: 1_000),
               let identity = try? JSONDecoder().decode(ProbeIdentity.self, from: Data(raw.utf8)),
               identity.probeAvailable, identity.documentToken == token,
               identity.documentURL.flatMap(URL.init(string:)) == target,
               let index = tabs.firstIndex(where: { $0.id == tabID }),
               !isReleased, !isUserControlling, !Task.isCancelled, cancellation?.isCancelled != true,
               tabs[index].navigationPending, tabs[index].navigationAttempt == attempt {
                tabs[index].navigationPending = false
                tabs[index].navigationRevision &+= 1
                tabs[index].committedAttempt = attempt
                tabs[index].probeDocumentToken = token
                tabs[index].previousProbeDocumentToken = nil
                tabs[index].surface = surface
                return
            }
            try await Task.sleep(for: .milliseconds(75))
        }
        throw BrowserProbeError.timedOut
    }

    private func waitForHistoryNavigation(tabID: UUID, attempt: UInt64, oldURL: String?, token: String?, timeout: Int, cancellation: CancellationToken?) async throws {
        let deadline = Date().addingTimeInterval(Double(min(30_000, max(250, timeout))) / 1_000)
        while Date() < deadline {
            try Task.checkCancellation()
            if cancellation?.isCancelled == true { throw CancellationError() }
            guard !isReleased else { throw BrowserProbeError.released }
            guard !BrowserLifecycleHealth.shared.hasGap(epoch: owner.rootEpoch, tabID: tabID) else {
                throw BrowserInteractionError.stale("Browser events were missed. Reload or navigate again.")
            }
            guard let tab = tabs.first(where: { $0.id == tabID }), tab.navigationAttempt == attempt else { throw BrowserInteractionError.stale("The page changed; observe it again") }
            if isUserControlling { throw BrowserInteractionError.needsUser("The user currently controls the browser") }
            if let error = tab.navigationFailure { throw BrowserNavigationError.failed(error) }
            if !tab.navigationPending && tab.committedAttempt == attempt { return }
            if let token, let oldURL,
               let state = try? await rendererState(tabID: tabID, timeout: 1_000, cancellation: cancellation),
               let url = state.url, url != oldURL,
               let raw = try? await evaluate(tabID: tabID, expression: BrowserProbeScript.documentStampExpression, cancellation: cancellation, timeout: 1_000),
               let identity = try? JSONDecoder().decode(ProbeIdentity.self, from: Data(raw.utf8)),
               identity.probeAvailable, identity.documentToken == token, identity.documentURL == url,
               let index = tabs.firstIndex(where: { $0.id == tabID }), !isReleased, !isUserControlling,
               !Task.isCancelled, cancellation?.isCancelled != true,
               tabs[index].navigationPending, tabs[index].navigationAttempt == attempt {
                tabs[index].navigationPending = false
                tabs[index].navigationUncertain = false
                tabs[index].navigationRevision &+= 1
                tabs[index].committedAttempt = attempt
                tabs[index].probeDocumentToken = token
                tabs[index].previousProbeDocumentToken = nil
                tabs[index].surface = state
                return
            }
            try await Task.sleep(for: .milliseconds(75))
        }
        throw BrowserProbeError.timedOut
    }

    /// Capture even an old page that has not yet been observed by a tool.
    /// Failure is non-authoritative; it never blocks a new navigation.
    private func currentProbeToken(tabID: UUID, cancellation: CancellationToken?) async -> String? {
        guard let before = tabs.first(where: { $0.id == tabID }), !before.navigationPending else { return nil }
        if let token = before.probeDocumentToken { return token }
        guard let raw = try? await evaluate(tabID: tabID, expression: BrowserProbeScript.documentStampExpression,
                                            cancellation: cancellation, timeout: 1_200),
              let identity = try? JSONDecoder().decode(ProbeIdentity.self, from: Data(raw.utf8)),
              identity.probeAvailable, let token = identity.documentToken, !token.isEmpty, token.utf8.count <= 128,
              let after = tabs.first(where: { $0.id == tabID }), !after.navigationPending,
              after.navigationRevision == before.navigationRevision,
              after.documentID == before.documentID else { return nil }
        return token
    }

    /// A dispatched load is not a new page. Wait for that tab's platform
    /// commit and retain the actual URL (which may be a valid redirect).
    private func waitForNavigationCommit(
        tabID: UUID, attempt: UInt64, timeout: Int, cancellation: CancellationToken?
    ) async throws {
        let deadline = Date().addingTimeInterval(Double(min(30_000, max(250, timeout))) / 1_000)
        while Date() < deadline {
            try Task.checkCancellation()
            if cancellation?.isCancelled == true { throw CancellationError() }
            guard !isReleased else { throw BrowserProbeError.released }
            guard !BrowserLifecycleHealth.shared.hasGap(epoch: owner.rootEpoch, tabID: tabID) else {
                throw BrowserInteractionError.stale("Browser events were missed. Reload or navigate again.")
            }
            guard let tab = tabs.first(where: { $0.id == tabID }) else {
                throw BrowserInteractionError.stale("Browser tab is no longer available")
            }
            guard tab.navigationAttempt == attempt else {
                throw BrowserInteractionError.stale("The page changed; observe it again")
            }
            if isUserControlling { throw BrowserInteractionError.needsUser("The user currently controls the browser") }
            if let error = tab.navigationFailure { throw BrowserNavigationError.failed(error) }
            if !tab.navigationPending && tab.committedAttempt == attempt { return }
            try await Task.sleep(for: .milliseconds(75))
        }
        throw BrowserProbeError.timedOut
    }

    private func perform(
        target: BrowserTarget,
        in tabID: UUID,
        operation: String,
        text: String?,
        submit: Bool,
        visualFallbackReason: String?,
        expectedVisualRevision: Int? = nil,
        expectedVisualToken: String? = nil,
        expectedVisualURL: String? = nil,
        expectedVisualScrollX: Double? = nil,
        expectedVisualScrollY: Double? = nil,
        expectedVisualWidth: Double? = nil,
        expectedVisualHeight: Double? = nil,
        expectedReviewRole: String? = nil,
        expectedReviewLabel: String? = nil,
        cancellation: CancellationToken?
    ) async throws {
        guard let tab = tabs.first(where: { $0.id == tabID }) else {
            throw BrowserInteractionError.stale("Browser tab is no longer available")
        }
        guard !BrowserLifecycleHealth.shared.hasGap(epoch: owner.rootEpoch, tabID: tabID), !tab.navigationPending, !tab.navigationUncertain else {
            throw BrowserInteractionError.stale("Browser events were missed. Reload or navigate again.")
        }
        guard let token = expectedVisualToken ?? tab.probeDocumentToken, !token.isEmpty,
              let url = expectedVisualURL ?? tab.surface.url, !url.isEmpty else {
            throw BrowserInteractionError.stale("Observe the current page before interacting with it")
        }
        let expression = BrowserProbeScript.performExpression(
            operation: operation,
            target: target,
            documentID: tab.documentID,
            text: text ?? "",
            submit: submit,
            visualFallbackReason: visualFallbackReason,
            expectedVisualRevision: expectedVisualRevision,
            expectedDocumentToken: token,
            expectedDocumentURL: url,
            expectedScrollX: expectedVisualScrollX,
            expectedScrollY: expectedVisualScrollY,
            expectedViewportWidth: expectedVisualWidth,
            expectedViewportHeight: expectedVisualHeight,
            expectedReviewRole: expectedReviewRole,
            expectedReviewLabel: expectedReviewLabel
        )
        let value = try await evaluate(tabID: tabID, expression: expression, cancellation: cancellation)
        try ensureObservationCurrent(tabID: tabID, documentID: tab.documentID, revision: tab.navigationRevision)
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
              evidence.documentToken == tab.probeDocumentToken,
              evidence.documentURL == tab.surface.url,
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
        guard let original = tabs.first(where: { $0.id == tabID }), !original.navigationPending, !original.navigationUncertain else {
            return failure(command, status: .stale, code: "navigation-pending", "The page is still navigating; wait for it to load")
        }
        let documentID = original.documentID
        let navigationRevision = original.navigationRevision
        let timeout = min(30_000, max(250, command.timeoutMilliseconds))
        do {
            try Task.checkCancellation()
            await collectProbeEvents(tabID: tabID, timeout: timeout, cancellation: cancellation)
            try Task.checkCancellation()
            try ensureObservationCurrent(tabID: tabID, documentID: documentID, revision: navigationRevision)
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
            try ensureObservationCurrent(tabID: tabID, documentID: documentID, revision: navigationRevision)
            if let index = tabs.firstIndex(where: { $0.id == tabID }) {
                tabs[index].revision = max(tabs[index].revision, probe.revision)
            }
            let surface = try await rendererState(tabID: tabID, timeout: timeout, cancellation: cancellation)
            try ensureObservationCurrent(tabID: tabID, documentID: documentID, revision: navigationRevision)
            if probe.documentURL != surface.url {
                throw BrowserInteractionError.stale("The page changed during observation; observe it again")
            }
            if let token = probe.documentToken {
                // The platform's lifecycle event can lag behind evaluateJS.
                // Re-read the identity in the actual document, including for
                // a same-URL reload, before binding its DOM to this snapshot.
                let rawIdentity = try await evaluate(tabID: tabID, expression: BrowserProbeScript.identityExpression,
                                                     cancellation: cancellation, timeout: timeout)
                guard let identity = try? JSONDecoder().decode(ProbeIdentity.self, from: Data(rawIdentity.utf8)),
                      identity.probeAvailable, identity.documentToken == token,
                      identity.documentURL == probe.documentURL else {
                    throw BrowserInteractionError.stale("The page changed during observation; observe it again")
                }
                try ensureObservationCurrent(tabID: tabID, documentID: documentID, revision: navigationRevision)
                guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { throw BrowserProbeError.released }
                if tabs[index].previousProbeDocumentToken == token {
                    throw BrowserInteractionError.stale("The previous page is still visible; wait for the new page")
                }
                if let bound = tabs[index].probeDocumentToken, bound != token {
                    throw BrowserInteractionError.stale("The page changed during observation; observe it again")
                }
                tabs[index].probeDocumentToken = token
                tabs[index].previousProbeDocumentToken = nil
            }
            if let index = tabs.firstIndex(where: { $0.id == tabID }) {
                tabs[index].surface = surface
            }
            guard cancellation?.isCancelled != true, !Task.isCancelled else { throw CancellationError() }
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
                screenshotArtifact: nil,
                structuredObservationAvailable: true
            )
            if let failure = tab.navigationFailure, !surface.isLoading {
                return BrowserResult(requestID: command.requestID, status: .failed,
                                     page: snapshot, message: failure.message, error: failure)
            }
            return BrowserResult(requestID: command.requestID, status: .ok, page: snapshot)
        } catch BrowserProbeError.timedOut {
            return failure(command, status: .timeout, code: "timeout", "Browser page observation timed out")
        } catch BrowserProbeError.released {
            return failure(command, status: .stale, code: "released", "This task's browser session was released")
        } catch BrowserProbeError.unavailable {
            return failure(command, status: .failed, code: "probe-unavailable", "Page contents are not available yet; wait or try a screenshot")
        } catch BrowserInteractionError.stale(let message) {
            return failure(command, status: .stale, code: "document", message)
        } catch is CancellationError {
            return failure(command, status: .failed, code: "cancelled", "Browser page observation was cancelled")
        } catch {
            return failure(command, status: .failed, code: "observe", error.localizedDescription)
        }
    }

    private struct ProbeSnapshot: Decodable {
        var probeAvailable: Bool?
        var documentToken: String?
        var documentURL: String?
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
        let deadline = Date().addingTimeInterval(Double(timeout) / 1_000)
        for attempt in 0..<4 {
            let remaining = Int(deadline.timeIntervalSinceNow * 1_000)
            guard remaining > 0 else { throw BrowserProbeError.timedOut }
            let value = try await evaluate(
                tabID: tabID,
                expression: BrowserProbeScript.observeExpression(documentID: tab.documentID, cursor: cursor, limit: limit),
                cancellation: cancellation,
                timeout: remaining
            )
            if let object = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any],
               object["probeAvailable"] as? Bool == false {
                // Page commit and WebView probe injection are asynchronous.
                // Give a real committed page a short opportunity to install
                // its probe without turning absence into an empty DOM.
                if attempt < 3 {
                    try await Task.sleep(for: .milliseconds(100))
                    continue
                }
                throw BrowserProbeError.unavailable
            }
            if let probe = try? JSONDecoder().decode(ProbeSnapshot.self, from: Data(value.utf8)),
               probe.probeAvailable == true,
               let token = probe.documentToken, !token.isEmpty, token.utf8.count <= 128,
               let url = probe.documentURL, !url.isEmpty, url.utf8.count <= 8192,
               URL(string: url)?.scheme != nil {
                return probe
            }
            throw BrowserProbeError.unavailable
        }
        throw BrowserProbeError.unavailable
    }

    private func ensureObservationCurrent(tabID: UUID, documentID: String, revision: UInt64) throws {
        guard !isReleased else { throw BrowserProbeError.released }
        guard !BrowserLifecycleHealth.shared.hasGap(epoch: owner.rootEpoch, tabID: tabID),
              let tab = tabs.first(where: { $0.id == tabID }), !tab.navigationPending, !tab.navigationUncertain,
              tab.documentID == documentID, tab.navigationRevision == revision else {
            throw BrowserInteractionError.stale("The page changed during observation; observe it again")
        }
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
        guard !BrowserLifecycleHealth.shared.hasGap(epoch: owner.rootEpoch, tabID: tabID) else {
            return failure(command, status: .stale, code: "lifecycle-gap", "Browser events were missed. Reload or navigate again.")
        }
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
            guard !BrowserLifecycleHealth.shared.hasGap(epoch: owner.rootEpoch, tabID: tabID) else {
                return failure(command, status: .stale, code: "lifecycle-gap", "Browser events were missed. Reload or navigate again.")
            }
            guard let tab = tabs.first(where: { $0.id == tabID }) else {
                return failure(command, status: .stale, code: "tab", "Browser tab is no longer available")
            }
            if let failure = tab.navigationFailure {
                return BrowserResult(requestID: command.requestID, status: .failed,
                                     message: failure.message, error: failure)
            }
            if tab.navigationPending {
                try? await Task.sleep(for: .milliseconds(100))
                continue
            }
            await collectProbeEvents(tabID: tabID, timeout: timeout, cancellation: cancellation)
            guard let current = tabs.first(where: { $0.id == tabID }),
                  !current.navigationPending, !current.navigationUncertain,
                  !BrowserLifecycleHealth.shared.hasGap(epoch: owner.rootEpoch, tabID: tabID), current.navigationRevision == tab.navigationRevision else { continue }
            if case .documentChanged(let oldDocumentID) = condition,
               tab.documentID != oldDocumentID {
                appendEvent(tabID: tabID, method: "Runtime.waitConditionSatisfied")
                return await observeResult(command, tabID: tabID, cursor: nil, cancellation: cancellation)
            }
            do {
                let state = try await probeState(tabID: tabID, condition: condition, timeout: timeout, cancellation: cancellation)
                guard let current = tabs.first(where: { $0.id == tabID }),
                      !current.navigationPending, !current.navigationUncertain,
                      !BrowserLifecycleHealth.shared.hasGap(epoch: owner.rootEpoch, tabID: tabID), current.navigationRevision == tab.navigationRevision,
                      current.documentID == tab.documentID else { continue }
                let isLoading = current.surface.isLoading
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

    private struct BoundScreenshot {
        let artifact: BrowserArtifactReference
        let documentID: String
        let navigationRevision: UInt64
        let token: String
        let url: String
        let probeFrame: ScreenshotProbeFrame?
    }

    private struct ScreenshotProbeFrame: Equatable {
        let revision: Int
        let scrollX: Double
        let scrollY: Double
        let width: Double
        let height: Double
    }

    private func screenshotProbeFrame(tabID: UUID, token: String, url: String, cancellation: CancellationToken?) async -> ScreenshotProbeFrame? {
        guard let raw = try? await evaluate(tabID: tabID, expression: BrowserProbeScript.identityExpression, cancellation: cancellation, timeout: 1_200),
              let identity = try? JSONDecoder().decode(ProbeIdentity.self, from: Data(raw.utf8)),
              identity.probeAvailable, identity.documentToken == token, identity.documentURL == url,
              let revision = identity.revision, revision >= 0,
              let x = identity.scrollX, x.isFinite, let y = identity.scrollY, y.isFinite,
              let width = identity.viewportWidth, width.isFinite, width > 0,
              let height = identity.viewportHeight, height.isFinite, height > 0 else { return nil }
        return ScreenshotProbeFrame(revision: revision, scrollX: x, scrollY: y, width: width, height: height)
    }

    private func screenshotIdentity(tabID: UUID, cancellation: CancellationToken?) async throws -> ProbeIdentity {
        let raw = try await evaluate(tabID: tabID, expression: BrowserProbeScript.documentStampExpression, cancellation: cancellation, timeout: 1_200)
        guard let identity = try? JSONDecoder().decode(ProbeIdentity.self, from: Data(raw.utf8)),
              identity.probeAvailable, let token = identity.documentToken, !token.isEmpty, token.utf8.count <= 128,
              let url = identity.documentURL, !url.isEmpty, url.utf8.count <= 8192, URL(string: url)?.scheme != nil else {
            throw BrowserInteractionError.stale("Cannot identify the page for this screenshot")
        }
        return identity
    }

    private func saveSnapshot(of tabID: UUID, cancellation: CancellationToken?) async throws -> BoundScreenshot {
        guard let tab = tabs.first(where: { $0.id == tabID }), !tab.navigationPending, !tab.navigationUncertain else {
            throw BrowserInteractionError.stale("The page is navigating; capture again")
        }
        let before = try await screenshotIdentity(tabID: tabID, cancellation: cancellation)
        try ensureObservationCurrent(tabID: tabID, documentID: tab.documentID, revision: tab.navigationRevision)
        guard let token = before.documentToken, let url = before.documentURL,
              tab.probeDocumentToken == nil || tab.probeDocumentToken == token,
              tab.previousProbeDocumentToken != token else {
            throw BrowserInteractionError.stale("The page changed; capture again")
        }
        let beforeRevision = await screenshotProbeFrame(tabID: tabID, token: token, url: url, cancellation: cancellation)
        try ensureObservationCurrent(tabID: tabID, documentID: tab.documentID, revision: tab.navigationRevision)
        let shot = try await raced(timeout: 30_000, cancellation: cancellation) { [renderer] in
            try await renderer.captureScreenshot(tabID: tabID)
        }
        try ensureObservationCurrent(tabID: tabID, documentID: tab.documentID, revision: tab.navigationRevision)
        guard shot.state.url == url else { throw BrowserInteractionError.stale("The page changed during capture") }
        let after = try await screenshotIdentity(tabID: tabID, cancellation: cancellation)
        try ensureObservationCurrent(tabID: tabID, documentID: tab.documentID, revision: tab.navigationRevision)
        guard after.documentToken == token, after.documentURL == url else {
            throw BrowserInteractionError.stale("The page changed during capture")
        }
        let afterRevision = await screenshotProbeFrame(tabID: tabID, token: token, url: url, cancellation: cancellation)
        try ensureObservationCurrent(tabID: tabID, documentID: tab.documentID, revision: tab.navigationRevision)
        if let beforeRevision, beforeRevision != afterRevision {
            throw BrowserInteractionError.stale("The page changed during capture; capture again")
        }
        let artifact = try artifacts.store(jpeg: shot.jpeg, pixelWidth: shot.pixelWidth, pixelHeight: shot.pixelHeight)
        return BoundScreenshot(artifact: artifact, documentID: tab.documentID, navigationRevision: tab.navigationRevision, token: token, url: url, probeFrame: beforeRevision)
    }

    private func verifyScreenshot(_ capture: BoundScreenshot, tabID: UUID, cancellation: CancellationToken?) async throws {
        try ensureObservationCurrent(tabID: tabID, documentID: capture.documentID, revision: capture.navigationRevision)
        let identity = try await screenshotIdentity(tabID: tabID, cancellation: cancellation)
        try ensureObservationCurrent(tabID: tabID, documentID: capture.documentID, revision: capture.navigationRevision)
        guard identity.documentToken == capture.token, identity.documentURL == capture.url else {
            throw BrowserInteractionError.stale("The page changed after capture")
        }
        if let expected = capture.probeFrame {
            let revision = await screenshotProbeFrame(tabID: tabID, token: capture.token, url: capture.url, cancellation: cancellation)
            try ensureObservationCurrent(tabID: tabID, documentID: capture.documentID, revision: capture.navigationRevision)
            guard revision == expected else { throw BrowserInteractionError.stale("The page changed after capture; capture again") }
        }
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
        guard !isReleased else { throw BrowserProbeError.released }
        return try await raced(timeout: timeout, cancellation: cancellation) { [renderer] in
            try await renderer.state(tabID: tabID)
        }
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
