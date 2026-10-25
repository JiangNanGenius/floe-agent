// FloeAndroid shared/Sources/FloeBrowser — service-owned browser sessions for
// concurrent tasks.
//
// Android mirror of the public iOS original
// FloeAgent/FloeApp/Browser/BrowserSessionCenter.swift @ 3fd597b…
// (sha256 0661d76d31088c0d697210ef013c65d2db63d89ab690f362f6374e456ca2f5e8).
// The center is the durable owner of handoff receipts, the panel request
// route and the *visible* projection. Execution lives in one independent
// BrowserTaskSession per trusted task, so a background task keeps operating
// its own tabs while another task's panel is on screen.
//
// Documented mirror deltas against the original:
//  * `@MainActor final class … ObservableObject/@Published` becomes an actor
//    that emits an immutable `BrowserProjection` through the injected
//    `projectionUpdate` sink after every projection-bearing transition, in
//    FIFO order. The Kotlin surface renders the projection only; it stores no
//    parallel truth (no local Boolean permission store).
//  * Sessions key on the exact `BrowserOwnerID` triple (task + workspace +
//    root epoch). The iOS original keyed only the conversation; when a task's
//    workspace binding or root epoch changes, the old owner is released and
//    fenced before anything new may be admitted. `ownerAuthority` is the
//    trusted revalidation hook Main wires to the native root-epoch readback
//    and the conversation/workspace store.
//  * `activeWebView.url` reads become the session's trusted cached tab surface
//    (renderer lifecycle facts). Receipt sanitisation rules are identical:
//    user, password, query and fragment are never persisted.
//  * Durable receipts and the artifact sweep use Main-provided directories;
//    the receipt JSON shape matches the original BrowserHandoffs.json format.

import Foundation
import FloeCore
import FloeTools

public struct BrowserCenterConfiguration: Sendable {
    public var protocolVersion: String
    public var artifactsDirectory: URL
    public var receiptsDirectory: URL
    public var maximumTabs: Int
    public var maximumEventsPerTab: Int
    public var maximumSessions: Int
    public var maximumOwnerFences: Int
    public var durableHandoffs: Bool
    public var evictionIdleSeconds: TimeInterval

    public init(
        protocolVersion: String = "FloeBrowser/1.0",
        artifactsDirectory: URL,
        receiptsDirectory: URL,
        maximumTabs: Int = 6,
        maximumEventsPerTab: Int = 256,
        maximumSessions: Int = 128,
        maximumOwnerFences: Int = 512,
        durableHandoffs: Bool = true,
        evictionIdleSeconds: TimeInterval = 6 * 60 * 60
    ) {
        self.protocolVersion = protocolVersion
        self.artifactsDirectory = artifactsDirectory
        self.receiptsDirectory = receiptsDirectory
        self.maximumTabs = maximumTabs
        self.maximumEventsPerTab = maximumEventsPerTab
        self.maximumSessions = maximumSessions
        self.maximumOwnerFences = maximumOwnerFences
        self.durableHandoffs = durableHandoffs
        self.evictionIdleSeconds = evictionIdleSeconds
    }
}

/// Outcome of an explicit user-continue attempt (visible result for the
/// Kotlin Continue button; the durable receipt remains the only truth).
public enum BrowserReturnOutcome: Sendable, Codable, Hashable {
    case delivered(continueTask: Bool)
    case noReceipt
    case receiptMismatch
    case deliveringInProgress
    case failed(String)
}

public actor BrowserSessionCenter {
    // MARK: Ports

    public typealias RendererFactory = @Sendable (BrowserOwnerID) -> any BrowserRenderer
    /// Routes a returned handoff into the original runtime's user-message
    /// delivery. Returns whether the task needs an explicit continue. Same
    /// contract as the iOS `deliverHandoff`.
    public typealias DeliverHandoff = @Sendable (BrowserHandoff, Bool) async throws -> Bool
    public typealias HandoffRunResolver = @Sendable (UUID) -> UUID?
    public typealias OwnerReleaseHook = @Sendable (UUID) -> Void
    public typealias ProjectionUpdate = @Sendable (BrowserProjection) -> Void
    /// Trusted revalidation of the exact native ownership triple. Consumed at
    /// session admission, trusted restore and handoff delivery. Model/page
    /// data never reaches this hook; only composition installs it.
    public typealias OwnerAuthority = @Sendable (BrowserOwnerID) async -> Bool

    // MARK: Lifecycle fence

    /// Lifecycle fence for one browser-owning task. `generation` is bumped on
    /// every release and every explicit trusted reactivation; a session
    /// records the generation it was created under, so a completion from an
    /// older session/generation can never authorize work after the owner
    /// moved on. The tombstone is permanent while retained: neither elapsed
    /// time nor registry pressure re-authorizes a released owner's tool
    /// callbacks to recreate a browser — recreation requires explicit trusted
    /// reactivation (a UI restore or a newly admitted run), and a late call
    /// from a cancelled run is refused by its ToolContext cancellation
    /// regardless of retention. The registry is bounded; on FIFO eviction the
    /// runtime's run cancellation remains the second fence.
    private struct OwnerFence {
        var generation: Int
        var releasedAt: Date
        var isReleased: Bool
        var lastKnownOwner: BrowserOwnerID?
    }

    // MARK: State

    private let configuration: BrowserCenterConfiguration
    private let rendererFactory: RendererFactory
    public let policy: BrowserURLPolicy
    private let visualText: BrowserVisualTextRecognitionPort
    private let artifacts: BrowserArtifactStore
    private let deliverHandoff: DeliverHandoff?
    private let handoffRun: HandoffRunResolver?
    private let ownerReleaseHook: OwnerReleaseHook?
    private let projectionUpdate: ProjectionUpdate
    private let ownerAuthority: OwnerAuthority?

    private var sessions: [UUID: BrowserTaskSession] = [:]
    private var sessionOwnerBindings: [UUID: BrowserOwnerID] = [:]
    private var ownerFences: [UUID: OwnerFence] = [:]
    private var ownerFenceOrder: [UUID] = []

    /// The conversation whose browser the UI currently projects. Binding is a
    /// presentation choice only; it never moves execution between sessions.
    private var conversationID: UUID?
    private var presentationRequest: BrowserPanelRequest?
    /// Route state for the panel request of each task. `presentationRequest`
    /// is the latest emitted request (the app's onChange route); this map
    /// keeps earlier owners' requests so one task's request cannot erase
    /// another's pending human-interaction prompt.
    private var pendingPanelRequests: [UUID: BrowserPanelRequest] = [:]
    private var handoffs: [UUID: BrowserHandoff] = [:]
    private var deliveringHandoffs: Set<UUID> = []
    private var deliveredHandoffIDs: Set<UUID> = []
    private var knownRunIDs: [UUID: UUID] = [:]
    private var handoffNeedsContinueByConversation: [UUID: Bool] = [:]
    private var returningControl = false
    private var handoffNotified = false
    private var handoffNeedsContinue = false
    private var handoffError: String?
    private var unboundSessionID = UUID()

    nonisolated(unsafe) private static var didRunArtifactSweep = false
    private var projectionTail: Task<Void, Never>?

    private var handoffURL: URL {
        configuration.receiptsDirectory.appendingPathComponent("BrowserHandoffs.json")
    }
    private var protocolVersion: String { configuration.protocolVersion }

    /// The durable outbox receipt for the currently visible conversation
    /// (projection mirror; the map remains the authority).
    public private(set) var currentVisibleHandoff: BrowserHandoff?

    public init(
        configuration: BrowserCenterConfiguration,
        rendererFactory: @escaping RendererFactory,
        policy: BrowserURLPolicy,
        visualText: BrowserVisualTextRecognitionPort? = nil,
        deliverHandoff: DeliverHandoff? = nil,
        handoffRun: HandoffRunResolver? = nil,
        ownerReleaseHook: OwnerReleaseHook? = nil,
        projectionUpdate: @escaping ProjectionUpdate,
        ownerAuthority: OwnerAuthority? = nil
    ) {
        self.configuration = configuration
        self.rendererFactory = rendererFactory
        self.policy = policy
        self.visualText = visualText ?? BrowserVisualTextRecognitionPorts.unavailableOnAndroid
        self.artifacts = BrowserArtifactStore(directory: configuration.artifactsDirectory)
        self.deliverHandoff = deliverHandoff
        self.handoffRun = handoffRun
        self.ownerReleaseHook = ownerReleaseHook
        self.projectionUpdate = projectionUpdate
        self.ownerAuthority = ownerAuthority
        // Durable handoff persistence and shared-artifact retention are owned
        // by exactly one center per process; ephemeral centers
        // (durableHandoffs: false) must not delete another owner's evidence.
        // Swift 6: a nonisolated actor init cannot read the actor-isolated
        // `handoffURL` computed property; use the init parameter directly —
        // identical value (self.configuration was just assigned from it) and
        // identical durable-load semantics.
        if configuration.durableHandoffs,
           let data = try? Data(contentsOf: configuration.receiptsDirectory
               .appendingPathComponent("BrowserHandoffs.json")),
           let saved = try? JSONDecoder().decode([BrowserHandoff].self, from: data) {
            handoffs = Dictionary(saved.map { ($0.conversationID, $0) }, uniquingKeysWith: { _, latest in latest })
        }
        if configuration.durableHandoffs, !Self.didRunArtifactSweep {
            Self.didRunArtifactSweep = true
            artifacts.sweep()
        }
    }

    // MARK: - Visible projection

    /// Binds the visible surface to one task. Tabs stay owned by their task
    /// session; unbinding a view never stops another task's renderers. A
    /// human explicitly reopening an archived or restored task is a trusted
    /// reactivation; a late tool callback can never do this. View
    /// recreation alone re-binds and NEVER returns control.
    public func bind(to newConversationID: UUID?, owner: BrowserOwnerID? = nil) async {
        if newConversationID == conversationID,
           newConversationID.map({ sessions[$0] != nil }) ?? true {
            return
        }
        conversationID = newConversationID
        handoffError = nil
        if let newConversationID {
            var admitted = true
            if let owner { admitted = await isOwnerAdmitted(owner) }
            if admitted {
                if let owner,
                   let existing = sessions[newConversationID],
                   sessionOwnerBindings[newConversationID] != owner {
                    // Same task, different workspace/epoch binding: that
                    // owner retired. Fence it before admitting the new one.
                    await discard(conversationID: newConversationID, notifyHook: true)
                    _ = try? await restoreSession(owner: owner)
                } else if sessions[newConversationID] == nil, let owner {
                    _ = try? await restoreSession(owner: owner)
                } else if let session = sessions[newConversationID] {
                    await session.promoteSurfaceAfterRebind()
                }
            }
            refreshHandoffProjection(for: newConversationID)
        } else {
            unboundSessionID = UUID()
            currentVisibleHandoff = nil
            handoffNeedsContinue = false
            handoffNotified = false
        }
        emitProjection()
    }

    /// A late disappearing panel may hide only its own visible task.
    /// This transition contains no suspension, so another task's later bind
    /// cannot be cleared between the ownership check and the state change.
    public func unbindVisible(if taskID: UUID) {
        guard conversationID == taskID else { return }
        conversationID = nil
        handoffError = nil
        unboundSessionID = UUID()
        currentVisibleHandoff = nil
        handoffNeedsContinue = false
        handoffNotified = false
        emitProjection()
    }

    // MARK: - Task session resolution

    /// Current lifecycle generation of one owner. Bumped on every release and
    /// every explicit trusted reactivation; sessions are stamped with the
    /// generation they were created under.
    public func generation(for taskID: UUID) -> Int {
        ownerFences[taskID]?.generation ?? 0
    }

    private func isOwnerAdmitted(_ owner: BrowserOwnerID) async -> Bool {
        guard let ownerAuthority else { return true }
        return await ownerAuthority(owner)
    }

    /// Resolves the independent session for a trusted task, creating it on
    /// first use. Model input never reaches this decision: callers pass the
    /// owner triple from a runtime-issued ToolContext. A released owner is
    /// refused here permanently (no elapsed-time or pressure
    /// re-authorization); only `restoreSession(owner:)` or a newly admitted
    /// owner run may reactivate.
    @discardableResult
    public func taskSession(for owner: BrowserOwnerID) async throws -> BrowserTaskSession {
        if let existing = sessions[owner.taskID] {
            guard sessionOwnerBindings[owner.taskID] == owner else {
                throw FloeError.validationFailed("This task's browser session belongs to a different workspace binding")
            }
            return existing
        }
        if isReleaseFenced(owner.taskID) {
            throw FloeError.validationFailed("This task's browser session was released")
        }
        guard await isOwnerAdmitted(owner) else {
            throw FloeError.validationFailed("This task's browser ownership binding is no longer admitted")
        }
        try await makeRoomForSession()
        return await makeSession(for: owner)
    }

    /// Explicit trusted reactivation used by the visible UI (`bind`): a human
    /// reopened this task, so the release fence lifts and a fresh session of
    /// the next generation may be created. Never callable from a tool path.
    @discardableResult
    public func restoreSession(owner: BrowserOwnerID) async throws -> BrowserTaskSession {
        if let existing = sessions[owner.taskID] {
            guard sessionOwnerBindings[owner.taskID] == owner else {
                throw FloeError.validationFailed("This task's browser session belongs to a different workspace binding")
            }
            return existing
        }
        guard await isOwnerAdmitted(owner) else {
            throw FloeError.validationFailed("This task's browser ownership binding is no longer admitted")
        }
        liftReleaseFence(for: owner)
        try await makeRoomForSession()
        return await makeSession(for: owner)
    }

    private func makeSession(for owner: BrowserOwnerID) async -> BrowserTaskSession {
        let task = BrowserTaskSession(
            owner: owner,
            generation: generation(for: owner.taskID),
            renderer: rendererFactory(owner),
            configuration: BrowserTaskSessionConfiguration(
                protocolVersion: configuration.protocolVersion,
                artifacts: artifacts,
                maximumTabs: configuration.maximumTabs,
                maximumEventsPerTab: configuration.maximumEventsPerTab,
                visualText: visualText
            ),
            policy: policy,
            requestUserControl: { [weak self] conversationID, reason in
                guard let self else { return }
                Task { await self.beginUserControl(conversationID: conversationID, runID: nil, reason: reason) }
            }
        )
        sessions[owner.taskID] = task
        sessionOwnerBindings[owner.taskID] = owner
        if var fence = ownerFences[owner.taskID] {
            fence.lastKnownOwner = owner
            ownerFences[owner.taskID] = fence
        }
        // The first tab is created before the session is handed out (the
        // iOS original did this synchronously inside makeSession).
        _ = await task.createTab()
        await task.markSurfaceReady()
        return task
    }

    public func session(for conversationID: UUID) -> BrowserTaskSession? {
        sessions[conversationID]
    }

    public var activeTaskSessionCount: Int { sessions.count }

    public func handoff(for conversationID: UUID) -> BrowserHandoff? {
        handoffs[conversationID]
    }

    /// Capacity pressure may release only a session that has been idle for
    /// hours, is not visible, not user-controlled, not executing and holds no
    /// pending handoff. An active owner is never discarded silently. At hard
    /// capacity (nothing evictable) new sessions are REFUSED with the
    /// original's actionable error; tombstones and live owners are never
    /// silently dropped to make room.
    private func makeRoomForSession() async throws {
        guard sessions.count >= configuration.maximumSessions else { return }
        let cutoff = Date().addingTimeInterval(-configuration.evictionIdleSeconds)
        let ordered = sessions.values.sorted { lhs, rhs in
            (ownerFences[lhs.conversationID]?.releasedAt ?? .distantPast)
                < (ownerFences[rhs.conversationID]?.releasedAt ?? .distantPast)
        }
        for candidate in ordered {
            guard sessions.count >= configuration.maximumSessions else { break }
            let candidateConversation = candidate.conversationID
            guard candidateConversation != conversationID,
                  handoffs[candidateConversation] == nil else { continue }
            let evictable = await candidate.evictableIfIdle(notVisible: candidateConversation != conversationID, cutoff: cutoff)
            guard evictable else { continue }
            sessions.removeValue(forKey: candidateConversation)
            sessionOwnerBindings.removeValue(forKey: candidateConversation)
            await candidate.release()
        }
        guard sessions.count < configuration.maximumSessions else {
            throw FloeError.validationFailed(
                "Too many task browsers are open; close a browser or delete a task you no longer use"
            )
        }
    }

    private func fenceReleasedOwner(_ conversationID: UUID) {
        let generation = (ownerFences[conversationID]?.generation ?? 0) + 1
        if ownerFences[conversationID] == nil {
            ownerFenceOrder.append(conversationID)
        }
        ownerFences[conversationID] = OwnerFence(
            generation: generation,
            releasedAt: Date(),
            isReleased: true,
            lastKnownOwner: sessionOwnerBindings[conversationID] ?? ownerFences[conversationID]?.lastKnownOwner
        )
        while ownerFenceOrder.count > configuration.maximumOwnerFences || ownerFences.count > configuration.maximumOwnerFences {
            let evicted = ownerFenceOrder.removeFirst()
            ownerFences.removeValue(forKey: evicted)
        }
    }

    private func liftReleaseFence(for owner: BrowserOwnerID) {
        let current = ownerFences[owner.taskID]
        let generation = (current?.generation ?? 0) + 1
        ownerFences[owner.taskID] = OwnerFence(generation: generation, releasedAt: Date(), isReleased: false, lastKnownOwner: owner)
        if !ownerFenceOrder.contains(owner.taskID) { ownerFenceOrder.append(owner.taskID) }
    }

    /// A release-fenced owner can never regain a browser through a tool
    /// callback. There is deliberately no time expiry: retention is bounded,
    /// and after FIFO eviction the cancelled run's ToolContext cancellation is
    /// the remaining fence, so time or pressure alone never re-authorizes.
    private func isReleaseFenced(_ conversationID: UUID) -> Bool {
        ownerFences[conversationID]?.isReleased == true
    }

    // MARK: - Visible-session operations

    public func setAddressText(_ text: String, in conversationID: UUID) async {
        guard let session = sessions[conversationID], conversationID == self.conversationID else { return }
        await session.setAddressText(text)
    }

    public func setEditingAddress(_ editing: Bool, in conversationID: UUID) async {
        guard let session = sessions[conversationID], conversationID == self.conversationID else { return }
        await session.setEditingAddress(editing)
        emitProjection()
    }

    public func navigateFromAddressBar(in conversationID: UUID) async {
        guard let session = sessions[conversationID], conversationID == self.conversationID else { return }
        await session.navigateFromAddressBar()
        emitProjection()
    }

    /// Draft-carrying commit (G04-R2 address-bar repair): ONE await into a
    /// single session-owned commit operation. The center deliberately does
    /// not split this into separate address/editing/navigate hops — between
    /// two awaits of different actor calls, an older per-keystroke echo Task
    /// could interleave and overwrite the draft. Inside the session
    /// operation the draft is applied, the editing flag cleared and the
    /// navigation target captured + policy-validated before its first
    /// suspension, so a late echo can never change what THIS commit
    /// navigates to. [draft] nil keeps the exact legacy two-op flow (the UI
    /// cleared editing through `setEditingAddress` before committing).
    public func navigateFromAddressBar(in conversationID: UUID, draft: String?) async {
        guard let session = sessions[conversationID], conversationID == self.conversationID else { return }
        await session.navigateFromAddressBar(draft: draft)
        emitProjection()
    }

    /// Panel "Retry" path (the iOS BrowserView retried via the session's web
    /// view directly). Reloads only this conversation's active tab.
    public func reloadVisibleTab(in conversationID: UUID) async {
        guard let session = sessions[conversationID], conversationID == self.conversationID else { return }
        await session.reloadActiveTab()
        emitProjection()
    }

    /// Panel history arrows (same visible-session rule as retry).
    public func goBackVisibleTab(in conversationID: UUID) async {
        guard let session = sessions[conversationID], conversationID == self.conversationID else { return }
        await session.goBackActiveTab()
    }

    public func goForwardVisibleTab(in conversationID: UUID) async {
        guard let session = sessions[conversationID], conversationID == self.conversationID else { return }
        await session.goForwardActiveTab()
    }

    @discardableResult
    public func createTab(in conversationID: UUID) async -> UUID? {
        guard let session = sessions[conversationID] else { return nil }
        let id = await session.createTab()
        emitProjection()
        return id
    }

    public func activate(_ id: UUID, in conversationID: UUID) async {
        guard let session = sessions[conversationID] else { return }
        await session.activate(id)
        emitProjection()
    }

    public func close(_ id: UUID, in conversationID: UUID) async {
        guard let session = sessions[conversationID] else { return }
        await session.close(id)
        emitProjection()
    }

    public func takeControl(in conversationID: UUID, runID: UUID? = nil) async {
        guard sessions[conversationID] != nil else { return }
        await beginUserControl(
            conversationID: conversationID,
            runID: runID,
            reason: "Browser control is yours; the task can continue other work."
        )
    }

    /// Opens the panel of the exact owning task. A background task's request
    /// carries its own conversationID; the app only routes it when that task
    /// is the selected one, so another task's panel is never replaced.
    public func requestUserInteraction(
        reason: String,
        tabID: UUID?,
        runID: UUID? = nil,
        in conversationID: UUID
    ) async throws {
        // Handoff is not a way to conjure a browser for a task that has none:
        // the task must already own a session with a navigated page. This also
        // keeps a forged/absent owner from opening a panel.
        guard let session = sessions[conversationID] else {
            throw FloeError.validationFailed(
                "This task's browser is not open; navigate before requesting user interaction"
            )
        }
        if let tabID {
            guard await session.hasTab(tabID) else {
                throw FloeError.notFound("Unknown browser tab")
            }
            let controlling = await session.isUserControlling
            let active = await session.activeTabID
            if controlling, active != tabID {
                throw FloeError.validationFailed("The user controls the current tab")
            }
            await session.activate(tabID)
        }
        await beginUserControl(conversationID: conversationID, runID: runID, reason: reason)
        let request = BrowserPanelRequest(conversationID: conversationID, show: true)
        pendingPanelRequests[conversationID] = request
        presentationRequest = request
        emitProjection()
    }

    public func pendingPanelRequest(for conversationID: UUID) -> BrowserPanelRequest? {
        pendingPanelRequests[conversationID]
    }

    /// Reads and clears one owner's pending panel request. The app calls this
    /// when the user explicitly selects the owning conversation, so a
    /// background task's request is presented exactly once and never steals
    /// the panel of another selected task.
    public func consumePendingPanelRequest(for conversationID: UUID) -> BrowserPanelRequest? {
        pendingPanelRequests.removeValue(forKey: conversationID)
    }

    /// Closes only the calling task's panel. A different task's visible panel
    /// is never dismissed by this call.
    public func requestPanelDismissal(conversationID: UUID) async throws {
        guard sessions[conversationID] != nil else {
            throw FloeError.validationFailed("This task's browser is not open")
        }
        // Routing gate first: dismissal is only ever about the visible task's
        // own panel. Every background owner that requested user interaction is
        // marked user-controlled by design, so evaluating control first made
        // the visibility refusal unreachable for exactly the tasks it
        // protects. The control gate below still refuses to hide a visible
        // panel the user is operating.
        guard self.conversationID == conversationID else {
            throw FloeError.validationFailed("This task's browser panel is not visible; no panel was closed")
        }
        let controlling = await sessions[conversationID]?.isUserControlling ?? false
        guard !controlling else {
            throw FloeError.validationFailed("Wait for the user to return browser control before closing their panel")
        }
        pendingPanelRequests.removeValue(forKey: conversationID)
        presentationRequest = BrowserPanelRequest(conversationID: conversationID, show: false)
        emitProjection()
    }

    // MARK: - Execution

    /// Runs a command against the calling task's own session. The session is
    /// selected from the runtime-issued owner, never from command contents.
    public func execute(
        _ command: BrowserCommand,
        in owner: BrowserOwnerID,
        cancellation: CancellationToken? = nil
    ) async -> BrowserResult {
        do {
            let session = try await taskSession(for: owner)
            let result = await session.execute(command, cancellation: cancellation)
            emitProjection()
            return result
        } catch {
            let message = error.localizedDescription
            return BrowserResult(
                requestID: command.requestID,
                status: .stale,
                message: message,
                error: BrowserFailure(code: "session", message: message)
            )
        }
    }

    /// Visible-session execution retained for LocalPreview and the protocol
    /// tests. Tools use the explicit owner overload.
    public func execute(_ command: BrowserCommand, cancellation: CancellationToken? = nil) async -> BrowserResult {
        if let conversationID, let session = sessions[conversationID] {
            let result = await session.execute(command, cancellation: cancellation)
            emitProjection()
            return result
        }
        guard command.sessionID == unboundSessionID else {
            return BrowserResult(
                requestID: command.requestID,
                status: .stale,
                message: "Browser session is no longer active",
                error: BrowserFailure(code: "session", message: "Browser session is no longer active")
            )
        }
        guard command.action == .protocolInfo else {
            return BrowserResult(
                requestID: command.requestID,
                status: .stale,
                message: "No task browser is active",
                error: BrowserFailure(code: "owner", message: "No task browser is active")
            )
        }
        return BrowserResult(
            requestID: command.requestID,
            status: .ok,
            protocolVersion: protocolVersion
        )
    }

    public func executeProtocol(
        _ request: FloeBrowserProtocolCommand,
        cancellation: CancellationToken? = nil
    ) async -> FloeBrowserProtocolResponse {
        if let conversationID, let session = sessions[conversationID] {
            return await session.executeProtocol(request, cancellation: cancellation)
        }
        // A detached center still answers parameter validation truthfully, but
        // cannot dispatch because no task owns a browser session.
        if request.method == .activateTarget, request.targetID == nil {
            return protocolFailure(request, "Target.activateTarget requires targetID")
        }
        if request.method == .closeTarget, request.targetID == nil {
            return protocolFailure(request, "Target.closeTarget requires targetID")
        }
        if request.method == .getVersion, request.sessionID == unboundSessionID {
            return FloeBrowserProtocolResponse(
                id: request.id,
                protocolVersion: protocolVersion,
                result: BrowserResult(requestID: UUID(), status: .ok, protocolVersion: protocolVersion)
            )
        }
        return protocolUnavailable(request, "No task browser is active")
    }

    public func executeProtocol(
        _ request: FloeBrowserProtocolCommand,
        in owner: BrowserOwnerID,
        cancellation: CancellationToken? = nil
    ) async -> FloeBrowserProtocolResponse {
        guard let session = try? await taskSession(for: owner) else {
            return protocolUnavailable(request, "This task's browser session is not active")
        }
        return await session.executeProtocol(request, cancellation: cancellation)
    }

    // MARK: - Renderer ingress

    /// Lifecycle ingress from the trusted platform renderer. The center routes
    /// by exact tab ownership; an unknown tab is dropped (it can never bind
    /// onto another task's session).
    public func ingress(_ event: BrowserRendererLifecycleEvent) async {
        guard let conversation = await conversationOwning(tab: tabID(of: event)) else { return }
        guard let session = sessions[conversation] else { return }
        await session.ingress(event)
        emitProjection()
    }

    public func popupDecision(_ query: BrowserPopupQuery) async -> BrowserPopupDecision {
        guard let conversation = await conversationOwning(tab: query.tabID),
              let session = sessions[conversation] else {
            return .blocked(reason: "This task's browser session is not active")
        }
        return await session.popupDecision(for: query)
    }

    private func tabID(of event: BrowserRendererLifecycleEvent) -> UUID {
        switch event {
        case .loadStarted(let id), .loadCommitted(let id),
             .loadFinished(let id, _, _), .loadFailed(let id, _, _, _):
            return id
        }
    }

    private func conversationOwning(tab tabID: UUID) async -> UUID? {
        for (conversation, session) in sessions where await session.hasTab(tabID) {
            return conversation
        }
        return nil
    }

    private func protocolUnavailable(
        _ request: FloeBrowserProtocolCommand,
        _ message: String
    ) -> FloeBrowserProtocolResponse {
        FloeBrowserProtocolResponse(
            id: request.id,
            protocolVersion: protocolVersion,
            result: BrowserResult(
                requestID: UUID(),
                status: .stale,
                message: message,
                error: BrowserFailure(code: "session", message: message),
                protocolVersion: protocolVersion
            )
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

    // MARK: - Handoff receipts

    /// The runtime admits one authorized run for this task. That is explicit
    /// lifecycle evidence the owner is active again: it lifts the release
    /// fence (without creating a session) so the new run's own tool calls may
    /// create one. A late callback from an earlier, cancelled run is still
    /// refused by its ToolContext cancellation before any session is created.
    public func recordOwnerRun(conversationID: UUID, runID: UUID) {
        knownRunIDs[conversationID] = runID
        liftReleaseFenceFromStore(conversationID)
    }

    private func liftReleaseFenceFromStore(_ conversationID: UUID) {
        guard ownerFences[conversationID] != nil else { return }
        let generation = ownerFences[conversationID]!.generation + 1
        ownerFences[conversationID] = OwnerFence(
            generation: generation,
            releasedAt: Date(),
            isReleased: false,
            lastKnownOwner: ownerFences[conversationID]?.lastKnownOwner
        )
    }

    /// The recorded owner run, used to attribute durable work (page capture,
    /// handoff receipts) to the actual admitted run instead of a newer one.
    public func recordedOwnerRun(for conversationID: UUID) -> UUID? {
        knownRunIDs[conversationID]
    }

    private func beginUserControl(
        conversationID owner: UUID,
        runID: UUID?,
        reason: String?
    ) async {
        guard let session = sessions[owner] else { return }
        // Only the owner's CURRENT, unreleased session may initiate user
        // control. A session from an older generation (released, then
        // reactivated) is fenced here: its late delegate callbacks can never
        // hand control or rewrite the durable receipt for a newer session.
        guard sessions[owner] === session, !(await session.isReleased) else { return }
        let existing = handoffs[owner]
        let existingWasDelivered = existing.map { deliveredHandoffIDs.contains($0.id) } ?? false
        let sessionID = await session.sessionID
        // A failed delivery leaves the receipt marked returning but
        // undelivered; taking control again must keep that exact receipt for a
        // later retry.
        if existing == nil
            || existing?.sessionID != sessionID
            || (existing?.returning == true && existingWasDelivered) {
            if let existing { deliveredHandoffIDs.remove(existing.id) }
            let event = BrowserHandoff(
                id: UUID(),
                conversationID: owner,
                runID: runID ?? handoffRun?(owner) ?? knownRunIDs[owner],
                sessionID: sessionID,
                tabID: await session.activeTabID,
                returning: false
            )
            handoffs[owner] = event
            do { try persistHandoffs() } catch {
                if conversationID == owner { handoffError = error.localizedDescription }
            }
        } else if var updated = handoffs[owner], updated.tabID != (await session.activeTabID) {
            // Keep the same durable receipt while the user takes control of
            // another tab in this task's own browser.
            updated.tabID = await session.activeTabID
            handoffs[owner] = updated
            try? persistHandoffs()
        }
        await session.setUserControlling(true)
        if let reason { await session.setSurfaceNeedsUser(reason) }
        handoffNeedsContinueByConversation[owner] = false
        guard conversationID == owner else { return }
        currentVisibleHandoff = handoffs[owner]
        handoffNeedsContinue = false
        handoffNotified = false
        handoffError = nil
        emitProjection()
    }

    public func returnToAgent(continueTask: Bool = false) async -> BrowserReturnOutcome {
        guard let conversationID else { return .noReceipt }
        guard let event = handoffs[conversationID] else { return .noReceipt }
        guard !returningControl else { return .deliveringInProgress }
        guard deliveringHandoffs.insert(event.id).inserted else { return .deliveringInProgress }
        guard let deliverHandoff else {
            deliveringHandoffs.remove(event.id)
            return .failed("No handoff delivery route is configured")
        }
        returningControl = true
        handoffError = nil
        defer { returningControl = false; deliveringHandoffs.remove(event.id) }
        do {
            let firstReturn = !event.returning
            var updated = event
            updated.returning = true
            // Only the exact session that produced this receipt may donate its
            // page address or have its document references invalidated.
            let ownerSession: BrowserTaskSession?
            if let candidate = sessions[conversationID], await candidate.sessionID == event.sessionID {
                ownerSession = candidate
            } else {
                ownerSession = nil
            }
            // Never persist credentials, fragments or query parameters from
            // the page.
            if firstReturn,
               let ownerSession,
               let addressValue = await ownerSession.technicalAddress,
               var address = URLComponents(string: addressValue) {
                address.user = nil
                address.password = nil
                address.query = nil
                address.fragment = nil
                updated.pageAddress = address.url?.absoluteString
            }
            handoffs[conversationID] = updated
            try persistHandoffs()
            // Invalidate every pre-takeover element/document reference of the
            // exact task that returned control.
            await ownerSession?.invalidateDocumentsForHandoff()
            let needsContinue = try await deliverHandoff(updated, continueTask)
            deliveredHandoffIDs.insert(event.id)
            // Keep the durable outbox until a later takeover replaces it. On
            // app recovery the input store decides whether this ID was
            // consumed.
            handoffs[conversationID] = updated
            handoffNeedsContinueByConversation[conversationID] = needsContinue
            pendingPanelRequests.removeValue(forKey: conversationID)
            await ownerSession?.setUserControlling(false)
            try persistHandoffs()
            currentVisibleHandoff = updated
            self.handoffNeedsContinue = needsContinue
            handoffNotified = !needsContinue
            emitProjection()
            return .delivered(continueTask: needsContinue)
        } catch {
            handoffError = error.localizedDescription
            emitProjection()
            return .failed(error.localizedDescription)
        }
    }

    /// The Kotlin Continue/close buttons must carry this native receipt; a
    /// receipt id that is not the durable current one returns a mismatch
    /// outcome and never touches control state.
    public func returnToAgent(receiptID: UUID, continueTask: Bool) async -> BrowserReturnOutcome {
        guard let conversationID else { return .noReceipt }
        guard let event = handoffs[conversationID] else { return .noReceipt }
        guard event.id == receiptID else { return .receiptMismatch }
        return await returnToAgent(continueTask: continueTask)
    }

    /// Called from the original runtime's state stream, including after cold
    /// recovery. Targets the exact recorded task/run and never rebinds or
    /// restarts another task.
    public func recoverHandoff(conversationID targetConversationID: UUID, runID: UUID) async {
        guard let event = handoffs[targetConversationID], event.returning, event.runID == runID,
              let deliverHandoff, deliveringHandoffs.insert(event.id).inserted else { return }
        defer { deliveringHandoffs.remove(event.id) }
        do {
            let needsContinue = try await deliverHandoff(event, false)
            deliveredHandoffIDs.insert(event.id)
            handoffNeedsContinueByConversation[targetConversationID] = needsContinue
            pendingPanelRequests.removeValue(forKey: targetConversationID)
            if let ownerSession = sessions[targetConversationID],
               await ownerSession.sessionID == event.sessionID {
                await ownerSession.setUserControlling(false)
            }
            if self.conversationID == targetConversationID {
                currentVisibleHandoff = event
                handoffNeedsContinue = needsContinue
                handoffNotified = !needsContinue
                handoffError = nil
            }
            emitProjection()
        } catch {
            if self.conversationID == targetConversationID { handoffError = error.localizedDescription }
            emitProjection()
        }
    }

    /// Releases exactly one task's renderers, documents, evidence and pending
    /// handoff. Late callbacks for this owner are fenced — permanently while
    /// the tombstone is retained, and afterwards by the cancelled run's own
    /// ToolContext cancellation; other tasks keep their sessions and any
    /// visible panel. Only an explicit UI restore or a newly admitted run may
    /// reactivate this owner.
    public func discard(conversationID: UUID, notifyHook: Bool = true) async {
        fenceReleasedOwner(conversationID)
        if notifyHook { ownerReleaseHook?(conversationID) }
        if self.conversationID == conversationID {
            self.conversationID = nil
            unboundSessionID = UUID()
            currentVisibleHandoff = nil
            handoffNeedsContinue = false
            handoffNotified = false
            handoffError = nil
        }
        if presentationRequest?.conversationID == conversationID {
            presentationRequest = nil
        }
        pendingPanelRequests.removeValue(forKey: conversationID)
        if let event = handoffs[conversationID] { deliveredHandoffIDs.remove(event.id) }
        handoffs.removeValue(forKey: conversationID)
        try? persistHandoffs()
        handoffNeedsContinueByConversation.removeValue(forKey: conversationID)
        knownRunIDs.removeValue(forKey: conversationID)
        if let session = sessions.removeValue(forKey: conversationID) {
            sessionOwnerBindings.removeValue(forKey: conversationID)
            await session.release()
        }
        emitProjection()
    }

    // MARK: - Projection

    private func refreshHandoffProjection(for conversationID: UUID) {
        let event = handoffs[conversationID]
        currentVisibleHandoff = event
        let needsContinue = handoffNeedsContinueByConversation[conversationID]
            ?? (event?.returning == true)
        handoffNeedsContinue = event != nil && needsContinue
        handoffNotified = event?.returning == true && !handoffNeedsContinue
    }

    public func projection() async -> BrowserProjection {
        var projection = BrowserProjection()
        projection.visibleTaskID = conversationID
        projection.presentationRequest = presentationRequest
        projection.handoff = currentVisibleHandoff
        projection.returningControl = returningControl
        projection.handoffNeedsContinue = handoffNeedsContinue
        projection.handoffNotified = handoffNotified
        projection.handoffError = handoffError
        if let conversationID, let session = sessions[conversationID] {
            projection.tabs = await session.tabSnapshots()
            projection.activeTabID = await session.activeTabID
            projection.isUserControlling = await session.isUserControlling
            projection.surfaceState = await session.surfaceState
            projection.addressText = await session.addressText
            projection.isEditingAddress = await session.isEditingAddress
            projection.technicalAddress = await session.technicalAddress
            projection.isDisplayingLocalPreview = await session.isDisplayingLocalPreview
        } else {
            projection.surfaceState = .unbound
        }
        return projection
    }

    private func emitProjection() {
        let previous = projectionTail
        projectionTail = Task { [weak self] in
            // FIFO ordering: an older projection never overwrites a newer one.
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            let snapshot = await self.projection()
            self.projectionUpdate(snapshot)
        }
    }

    // MARK: - Durable receipts

    private func persistHandoffs() throws {
        guard configuration.durableHandoffs else { return }
        try FileManager.default.createDirectory(
            at: handoffURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(Array(handoffs.values)).write(to: handoffURL, options: .atomic)
    }
}
