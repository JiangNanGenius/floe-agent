// FloeApp — service-owned browser sessions for concurrent tasks.
//
// BrowserSessionCenter is the durable owner of handoff receipts, the panel
// request route and the *visible* projection. Execution itself lives in one
// independent BrowserTaskSession per trusted conversation, so a background
// task keeps operating its own tabs while another task's panel is on screen.

#if canImport(SwiftUI) && canImport(WebKit) && canImport(UIKit)
import Combine
import Foundation
import SwiftUI
import WebKit
import FloeCore
import FloeExecution

@MainActor
final class BrowserSessionCenter: NSObject, ObservableObject {
    typealias Tab = BrowserTaskSession.Tab
    typealias VisualFallbackEvidence = BrowserTaskSession.VisualFallbackEvidence
    typealias SurfaceState = BrowserTaskSession.SurfaceState

    struct Handoff: Codable, Equatable {
        let id: UUID
        let conversationID: UUID
        let runID: UUID?
        let sessionID: UUID
        var tabID: UUID?
        var returning: Bool
        // Older receipts only have the return ID. An assistance request creates no arrival event.
        var takeoverEventID: UUID?
        var closedAfterRestart: Bool?
        var humanPresent: Bool { takeoverEventID != nil && closedAfterRestart != true }
    }
    struct PanelRequest: Equatable {
        let id = UUID()
        let conversationID: UUID
        let show: Bool
    }
    /// The exact task session a model run just acquired and the lease it must
    /// present for later calls and `browser.release`.
    struct ModelControl {
        let session: BrowserTaskSession
        let lease: BrowserControlLease
        /// True when this call created the holding period rather than joining
        /// the run's existing one.
        let acquiredNow: Bool
    }

    /// The conversation whose browser the UI currently projects. Binding is a
    /// presentation choice only; it never moves execution between sessions.
    @Published private(set) var conversationID: UUID?
    /// An explicitly presented takeover owns the interactive web view until its panel closes.
    @Published private(set) var previewInteractionID: UUID?
    @Published private(set) var presentationRequest: PanelRequest?
    /// Route state for the panel request of each task. `presentationRequest`
    /// is the latest emitted request (the app's onChange route); this map
    /// keeps earlier owners' requests so one task's request cannot erase
    /// another's pending human-interaction prompt.
    @Published private(set) var pendingPanelRequests: [UUID: PanelRequest] = [:]
    @Published private(set) var handoff: Handoff?
    @Published private(set) var returningControl = false
    @Published private(set) var handoffError: String?
    @Published private(set) var handoffNeedsContinue = false
    @Published private(set) var handoffNotified = false

    /// There is deliberately no "most recent run" resolver: a handoff or a
    /// user takeover is attributed only to the run named by the runtime-issued
    /// ToolContext or by the browser's actual control holder.
    var deliverHandoff: ((Handoff, Bool) async throws -> Bool)?
    var deliverTakeover: ((Handoff) async throws -> Bool)?
    /// Set by AppEnvironment so an explicit owner release also stops that
    /// owner's local preview server. The coordinator is owned by the
    /// environment (not this center), and preview records are task-owned;
    /// stopping them belongs to the same lifecycle event as the browser.
    var ownerReleaseHook: ((UUID) -> Void)?

    private let durableHandoffs: Bool
    /// User-opened browsers share the browser engine, never a task's control
    /// handoff or its pending notification.
    let taskHandoffsEnabled: Bool
    private let artifactDirectory: URL
    private let sessionConfiguration: BrowserTaskSessionConfiguration
    private let settings: BrowserSettingsService
    private let store = BrowserTaskSessionStore(maximumSessions: 128)
    private var unboundSessionID = UUID()
    private var settingsCancellable: AnyCancellable?
    private var lastAdvancedBrowserFeaturesEnabled: Bool

    private var handoffs: [UUID: Handoff] = [:]
    private var deliveringHandoffs = Set<UUID>()
    private var deliveredHandoffIDs = Set<UUID>()
    private var takeoverDeliveries: [UUID: Task<Bool, Error>] = [:]
    private var deliveredTakeovers = Set<UUID>()
    private var knownRunIDs: [UUID: UUID] = [:]
    private var handoffNeedsContinueByConversation: [UUID: Bool] = [:]

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
    }
    private var ownerFences: [UUID: OwnerFence] = [:]
    private var ownerFenceOrder: [UUID] = []
    private let maximumOwnerFences = 512
    private static var didRunArtifactSweep = false

    private let handoffURL: URL
    private var protocolVersion: String { sessionConfiguration.protocolVersion }

    init(
        durableHandoffs: Bool = true,
        taskHandoffsEnabled: Bool = true,
        settings: BrowserSettingsService? = nil,
        handoffStoreURL: URL? = nil
    ) {
        let settings = settings ?? BrowserSettingsService.shared
        self.durableHandoffs = durableHandoffs || handoffStoreURL != nil
        self.taskHandoffsEnabled = taskHandoffsEnabled
        self.settings = settings
        self.lastAdvancedBrowserFeaturesEnabled = settings.advancedBrowserFeaturesEnabled
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        let artifacts = support
            .appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent("BrowserArtifacts", isDirectory: true)
        artifactDirectory = artifacts
        handoffURL = handoffStoreURL ?? artifacts.deletingLastPathComponent().appendingPathComponent("BrowserHandoffs.json")
        sessionConfiguration = BrowserTaskSessionConfiguration(
            protocolVersion: "FloeBrowser/1.0",
            contentWorld: WKContentWorld.world(name: "org.floeagent.browser.agent"),
            artifactDirectory: artifacts,
            maximumTabs: 6,
            maximumEventsPerTab: 256,
            websiteDataStoreProvider: { @MainActor in settings.websiteDataStore },
            userAgentProvider: { @MainActor in settings.userAgent.effectiveValue },
            linkOpenBehaviorProvider: { @MainActor in settings.linkOpenBehavior },
            usesWideLayout: { @MainActor url in settings.usesWideLayout(for: url) }
        )
        super.init()
        settingsCancellable = settings.$revision
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.applyBrowserSettings() }
            }
        if durableHandoffs {
            BrowserCookieProviderRegistry.shared.install(self)
        }
        // Durable handoff persistence and shared-artifact retention are owned
        // by exactly one service instance per process. Task sessions never
        // write handoff receipts or prune screenshots, and ephemeral preview
        // centers (durableHandoffs: false) must not delete another owner's
        // evidence.
        if durableHandoffs, !Self.didRunArtifactSweep {
            Self.didRunArtifactSweep = true
            cleanupArtifacts()
        }
        if taskHandoffsEnabled, self.durableHandoffs, let data = try? Data(contentsOf: handoffURL),
           let saved = try? JSONDecoder().decode([Handoff].self, from: data) {
            for var receipt in saved {
                // WebKit sessions are process-local. A receipt alone cannot restore human control of a page.
                if !receipt.returning {
                    receipt.returning = true
                    receipt.closedAfterRestart = true
                }
                handoffs[receipt.conversationID] = receipt
            }
            if saved.contains(where: { !$0.returning }) {
                do { try persistHandoffs() } catch { handoffError = error.localizedDescription }
            }
        }
    }

    var settingsService: BrowserSettingsService { settings }

    /// Applies a settings revision to every live task session. Advanced OFF
    /// only fences AI-owned downloads; ordinary website data keeps the shared
    /// persistent store and the user stays logged in.
    private func applyBrowserSettings() {
        let advancedWasEnabled = lastAdvancedBrowserFeaturesEnabled
        lastAdvancedBrowserFeaturesEnabled = settings.advancedBrowserFeaturesEnabled
        if advancedWasEnabled && !settings.advancedBrowserFeaturesEnabled {
            // Turning advanced AI access OFF must not clear cookies, log the
            // user out or replace the ordinary persistent website-data store.
            for session in liveSessions() { session.cancelAdvancedBrowserWork() }
        }
        let userAgent = settings.userAgent.effectiveValue
        for session in liveSessions() {
            session.applyBrowserSettings(userAgent: userAgent)
        }
    }

    private func liveSessions() -> [BrowserTaskSession] {
        store.sessionsByLeastRecentActivity()
    }

    // MARK: - Visible projection

    /// The session the UI shows, or nil when no task is bound.
    var visibleSession: BrowserTaskSession? {
        conversationID.flatMap { store.session(for: $0) }
    }

    var sessionID: UUID { visibleSession?.sessionID ?? unboundSessionID }
    var tabs: [Tab] { visibleSession?.tabs ?? [] }
    var activeTabID: UUID? { visibleSession?.activeTabID }
    var isUserControlling: Bool { visibleSession?.isUserControlling ?? false }
    var surfaceState: SurfaceState { visibleSession?.surfaceState ?? .unbound }
    var addressText: String {
        get { visibleSession?.addressText ?? "" }
        set { visibleSession?.addressText = newValue }
    }
    var isEditingAddress: Bool {
        get { visibleSession?.isEditingAddress ?? false }
        set { visibleSession?.isEditingAddress = newValue }
    }
    var activeWebView: WKWebView? { visibleSession?.activeWebView }
    var technicalAddress: String? { visibleSession?.technicalAddress }
    var isDisplayingLocalPreview: Bool { visibleSession?.isDisplayingLocalPreview ?? false }

    /// Binds the visible surface to one task. Tabs stay owned by their task
    /// session; unbinding a view never stops another task's WebViews.
    func bind(to newConversationID: UUID?) {
        if newConversationID == conversationID,
           newConversationID.map({ store.session(for: $0) != nil }) ?? true {
            return
        }
        conversationID = newConversationID
        handoffError = nil
        if let newConversationID {
            // A human explicitly reopening an archived or restored task is a
            // trusted reactivation: it lifts the release fence and may create
            // a fresh session. A late tool callback can never do this.
            if let session = try? restoreSession(for: newConversationID) {
                if session.surfaceState == .unbound { session.surfaceState = .ready }
                if session.isUserControlling { session.surfaceState = .needsUser("User takeover is active") }
                session.isEditingAddress = false
            }
            refreshHandoffProjection(for: newConversationID)
        } else {
            unboundSessionID = UUID()
            handoff = nil
            handoffNeedsContinue = false
            handoffNotified = false
        }
    }

    // MARK: - Task session resolution

    /// Current lifecycle generation of one owner. Bumped on every release and
    /// every explicit trusted reactivation; sessions are stamped with the
    /// generation they were created under.
    func generation(for conversationID: UUID) -> Int {
        ownerFences[conversationID]?.generation ?? 0
    }

    /// Resolves the independent session for a trusted task, creating it on
    /// first use. Model input never reaches this decision: callers pass the
    /// conversationID from a runtime-issued ToolContext. A released owner is
    /// refused here permanently (no elapsed-time or pressure re-authorization);
    /// only `restoreSession(for:)` or a newly admitted owner run may reactivate.
    @discardableResult
    func taskSession(for conversationID: UUID) throws -> BrowserTaskSession {
        if let existing = store.session(for: conversationID) { return existing }
        if isReleaseFenced(conversationID) {
            throw FloeError.validationFailed("This task's browser session was released")
        }
        return try makeSession(for: conversationID)
    }

    /// Explicit trusted reactivation used by the visible UI (`bind(to:)`): a
    /// human reopened this task, so the release fence lifts and a fresh
    /// session of the next generation may be created. Never callable from a
    /// tool path.
    @discardableResult
    func restoreSession(for conversationID: UUID) throws -> BrowserTaskSession {
        if let existing = store.session(for: conversationID) { return existing }
        liftReleaseFence(for: conversationID)
        return try makeSession(for: conversationID)
    }

    private func makeSession(for conversationID: UUID) throws -> BrowserTaskSession {
        makeRoomForSession()
        let session = BrowserTaskSession(
            conversationID: conversationID,
            generation: generation(for: conversationID),
            configuration: sessionConfiguration,
            host: self
        )
        try store.insert(session)
        objectWillChange.send()
        _ = session.createTab()
        session.surfaceState = .ready
        return session
    }

    /// Atomic first acquisition for one model run. Existing sessions yield
    /// their current lease or refuse; a new session acquires the lease BEFORE
    /// its first tab/WebView exists, so no read or creation can race another
    /// holder. A session already controlled by the user returns needsUser and
    /// never yields page data.
    func beginModelControl(
        conversationID: UUID,
        runID: UUID
    ) throws -> ModelControl {
        if let existing = store.session(for: conversationID) {
            switch try existing.acquireModelControl(runID: runID) {
            case .acquired(let lease):
                return ModelControl(session: existing, lease: lease, acquiredNow: false)
            case .heldByAnotherRun:
                throw BrowserControlError.heldByAnotherRun
            case .needsUser(let message):
                throw BrowserControlError.needsUser(message)
            }
        }
        if isReleaseFenced(conversationID) {
            throw FloeError.validationFailed("This task's browser session was released")
        }
        makeRoomForSession()
        let session = BrowserTaskSession(
            conversationID: conversationID,
            generation: generation(for: conversationID),
            configuration: sessionConfiguration,
            host: self
        )
        let lease: BrowserControlLease
        switch try session.acquireModelControl(runID: runID) {
        case .acquired(let acquired): lease = acquired
        case .heldByAnotherRun: throw BrowserControlError.heldByAnotherRun
        case .needsUser(let message): throw BrowserControlError.needsUser(message)
        }
        try store.insert(session)
        objectWillChange.send()
        _ = session.createTab()
        session.surfaceState = .ready
        return ModelControl(session: session, lease: lease, acquiredNow: true)
    }

    /// Explicit release of one holding period. Never creates a session and
    /// never returns the user's page to the model on the user's behalf.
    func releaseModelControl(
        conversationID: UUID,
        runID: UUID,
        controlID: UUID
    ) -> BrowserControlReleaseOutcome {
        guard let session = store.session(for: conversationID) else {
            return .alreadyReleased
        }
        return session.releaseModelControl(controlID: controlID, runID: runID)
    }

    /// This run reached its real terminal state. Only its own holding period
    /// is released; the page survives and a user takeover stays in place.
    @discardableResult
    func endModelControl(conversationID: UUID, runID: UUID) -> Bool {
        guard let session = store.session(for: conversationID) else { return false }
        return session.endModelControl(runID: runID)
    }

    func session(for conversationID: UUID) -> BrowserTaskSession? {
        store.session(for: conversationID)
    }

    var activeTaskSessionCount: Int { store.count }

    func handoff(for conversationID: UUID) -> Handoff? {
        handoffs[conversationID]
    }

    /// Capacity pressure may release only a session that has been idle for
    /// hours, is not visible, not user-controlled, not executing and holds no
    /// pending handoff. An active owner is never discarded silently.
    private func makeRoomForSession() {
        guard store.count >= store.maximumSessions else { return }
        let cutoff = Date().addingTimeInterval(-6 * 60 * 60)
        for session in store.sessionsByLeastRecentActivity() {
            guard store.count >= store.maximumSessions else { break }
            guard session.conversationID != conversationID,
                  !session.isUserControlling,
                  !session.hasModelControlHolder,
                  session.activeExecutionCount == 0,
                  session.lastActivityAt < cutoff,
                  handoffs[session.conversationID] == nil else { continue }
            store.release(session.conversationID)?.release()
        }
    }

    private func fenceReleasedOwner(_ conversationID: UUID) {
        let generation = (ownerFences[conversationID]?.generation ?? 0) + 1
        if ownerFences[conversationID] == nil {
            ownerFenceOrder.append(conversationID)
        }
        ownerFences[conversationID] = OwnerFence(generation: generation, releasedAt: Date(), isReleased: true)
        while ownerFenceOrder.count > maximumOwnerFences || ownerFences.count > maximumOwnerFences {
            let evicted = ownerFenceOrder.removeFirst()
            ownerFences.removeValue(forKey: evicted)
        }
    }

    private func liftReleaseFence(for conversationID: UUID) {
        guard ownerFences[conversationID] != nil else { return }
        let generation = ownerFences[conversationID]!.generation + 1
        ownerFences[conversationID] = OwnerFence(generation: generation, releasedAt: Date(), isReleased: false)
    }

    /// A release-fenced owner can never regain a browser through a tool
    /// callback. There is deliberately no time expiry: retention is bounded,
    /// and after FIFO eviction the cancelled run's ToolContext cancellation is
    /// the remaining fence, so time or pressure alone never re-authorizes.
    private func isReleaseFenced(_ conversationID: UUID) -> Bool {
        ownerFences[conversationID]?.isReleased == true
    }

    // MARK: - Visible-session operations

    func navigateFromAddressBar() {
        visibleSession?.navigateFromAddressBar()
    }

    func refreshVisibleAddress() {
        visibleSession?.refreshVisibleAddress()
    }

    @discardableResult
    func createTab() -> UUID? {
        visibleSession?.createTab()
    }

    func activate(_ id: UUID) {
        visibleSession?.activate(id)
    }

    func close(_ id: UUID) {
        visibleSession?.close(id)
    }

    func takeControl(runID: UUID? = nil) {
        guard let session = visibleSession else { return }
        beginUserControl(
            for: session,
            runID: runID,
            reason: "Browser control is yours; the task can continue other work.",
            humanPresent: true
        )
    }

    /// Passive viewers use session(for:) only. Binding/handing over happens on this explicit user action.
    func openPreviewInteraction(
        session: BrowserTaskSession, page: BrowserPreviewPageIdentity?, displayedLease: BrowserControlLease?, presentationID: UUID
    ) -> Bool {
        guard taskHandoffsEnabled, previewInteractionID == nil, !session.isReleased,
              store.session(for: session.conversationID) === session, page != nil, session.previewPageIdentity == page,
              session.isUserControlling || session.activeWebView?.isLoading == false,
              session.modelControl == displayedLease, session.isUserControlling || session.isModelActive else { return false }
        bind(to: session.conversationID)
        takeControl()
        guard session.isUserControlling else { return false }
        previewInteractionID = presentationID
        _ = consumePendingPanelRequest(for: session.conversationID)
        return true
    }

    func closePreviewInteraction(_ presentationID: UUID) {
        if previewInteractionID == presentationID { previewInteractionID = nil }
    }

    /// Visible-session form retained for the UI and existing callers.
    func requestUserInteraction(reason: String, tabID: UUID?, runID: UUID? = nil) throws {
        guard let conversationID else { throw FloeError.validationFailed("No task browser is active") }
        try requestUserInteraction(reason: reason, tabID: tabID, runID: runID, in: conversationID)
    }

    /// Opens the panel of the exact owning task. A background task's request
    /// carries its own conversationID; the app only routes it when that task
    /// is the selected one, so another task's panel is never replaced.
    func requestUserInteraction(
        reason: String,
        tabID: UUID?,
        runID: UUID? = nil,
        in conversationID: UUID
    ) throws {
        guard taskHandoffsEnabled else {
            throw FloeError.validationFailed("This browser is already operated by the user")
        }
        // Handoff is not a way to conjure a browser for a task that has none:
        // the task must already own a session with a navigated page. This also
        // keeps a forged/absent owner from opening a panel.
        guard let session = store.session(for: conversationID) else {
            throw FloeError.validationFailed(
                "This task's browser is not open; navigate before requesting user interaction"
            )
        }
        guard !session.returningToModel else { throw FloeError.validationFailed("Browser handback is still in progress") }
        // A yield request can only hand over the calling run's own control. It
        // can never take the page from a different run that currently owns it.
        if let runID, let holder = session.modelControl, holder.runID != runID {
            throw FloeError.validationFailed(
                "This browser is being used by another run; continue with other authorized work"
            )
        }
        if session.isUserControlling, let runID, let current = handoffs[conversationID],
           current.sessionID == session.sessionID, !deliveredHandoffIDs.contains(current.id), current.runID != runID {
            throw FloeError.validationFailed("Another run is waiting for this user interaction")
        }
        if let tabID {
            guard session.tabs.contains(where: { $0.id == tabID }) else {
                throw FloeError.notFound("Unknown browser tab")
            }
            guard !session.isUserControlling || session.activeTabID == tabID else {
                throw FloeError.validationFailed("The user controls the current tab")
            }
            session.activate(tabID)
        }
        beginUserControl(for: session, runID: runID, reason: reason)
        let request = PanelRequest(conversationID: conversationID, show: true)
        pendingPanelRequests[conversationID] = request
        presentationRequest = request
    }

    func pendingPanelRequest(for conversationID: UUID) -> PanelRequest? {
        pendingPanelRequests[conversationID]
    }

    /// Acknowledges this owner's request when the user actually opens its interactive page.
    func consumePendingPanelRequest(for conversationID: UUID) -> PanelRequest? {
        pendingPanelRequests.removeValue(forKey: conversationID)
    }

    /// Visible-session form retained for the UI and existing callers.
    func requestPanelDismissal() throws {
        guard let conversationID else { throw FloeError.validationFailed("No task browser is active") }
        try requestPanelDismissal(conversationID: conversationID)
    }

    /// Withdraws a model request only. Presentation and web-page ownership stay with the user.
    func requestPanelDismissal(conversationID: UUID) throws {
        guard let session = store.session(for: conversationID) else {
            throw FloeError.validationFailed("This task's browser is not open")
        }
        guard !session.isUserControlling else {
            throw FloeError.validationFailed("Wait for the user to return browser control before closing their panel")
        }
        pendingPanelRequests.removeValue(forKey: conversationID)
        if presentationRequest?.conversationID == conversationID { presentationRequest = nil }
    }

    // MARK: - Execution

    /// Visible-session execution retained for LocalPreview, design capture and
    /// the existing protocol tests. Tools use the explicit owner overload.
    func execute(_ command: BrowserCommand) async -> BrowserResult {
        if let session = visibleSession {
            return await session.execute(command)
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

    /// Runs a command against the calling task's own session. The session is
    /// selected from the runtime-issued owner, never from command contents.
    func execute(_ command: BrowserCommand, in conversationID: UUID) async -> BrowserResult {
        do {
            let session = try taskSession(for: conversationID)
            return await session.execute(command)
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

    /// Runs one command under a previously acquired model lease. A lease from
    /// a released/reacquired holding period is refused inside the session,
    /// so a late callback can never act on the new holder's page.
    func execute(
        _ command: BrowserCommand,
        in conversationID: UUID,
        control: BrowserControlLease
    ) async -> BrowserResult {
        guard let session = store.session(for: conversationID) else {
            return BrowserResult(
                requestID: command.requestID,
                status: .stale,
                message: "This task's browser session is no longer active",
                error: BrowserFailure(code: "session", message: "This task's browser session is no longer active")
            )
        }
        return await session.execute(command, control: control)
    }

    func executeProtocol(_ request: FloeBrowserProtocolCommand) async -> FloeBrowserProtocolResponse {
        if let session = visibleSession {
            return await session.executeProtocol(request)
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

    func executeProtocol(
        _ request: FloeBrowserProtocolCommand,
        in conversationID: UUID
    ) async -> FloeBrowserProtocolResponse {
        guard let session = try? taskSession(for: conversationID) else {
            return protocolUnavailable(request, "This task's browser session is not active")
        }
        return await session.executeProtocol(request)
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
    func recordOwnerRun(conversationID: UUID, runID: UUID) {
        knownRunIDs[conversationID] = runID
        if let event = handoffs[conversationID], event.runID == runID, let id = event.takeoverEventID {
            deliveredTakeovers.remove(id)
        }
        liftReleaseFence(for: conversationID)
    }

    /// The recorded owner run, used to attribute durable work (page capture,
    /// handoff receipts) to the actual admitted run instead of a newer one.
    func recordedOwnerRun(for conversationID: UUID) -> UUID? {
        knownRunIDs[conversationID]
    }

    /// Transfers this task's browser to the user. `runID` is the real
    /// original run for a model-requested handoff (already runtime-issued) or
    /// the current holder's logical run for a user takeover. There is
    /// deliberately no "most recent run" fallback: an idle browser that no
    /// model run holds becomes user-controlled locally and creates no receipt
    /// to notify a run that never owned it.
    private func beginUserControl(
        for session: BrowserTaskSession,
        runID: UUID?,
        reason: String?,
        humanPresent: Bool = false
    ) {
        guard taskHandoffsEnabled else { return }
        let owner = session.conversationID
        // Only the owner's CURRENT, unreleased session may initiate user
        // control. A session from an older generation (released, then
        // reactivated) is fenced here: its late delegate callbacks can never
        // hand control or rewrite the durable receipt for a newer session.
        guard store.session(for: owner) === session, !session.isReleased else { return }
        guard !session.returningToModel else { return }
        let existing = handoffs[owner]
        let wasHumanControlled = session.isUserControlling
        let existingWasDelivered = existing.map { deliveredHandoffIDs.contains($0.id) } ?? false
        let current = wasHumanControlled && existing?.sessionID == session.sessionID && !existingWasDelivered ? existing : nil
        let receiptRun = current?.runID ?? runID ?? session.currentModelRunID
        if !wasHumanControlled { session.beginUserTakeover(reason: reason) }
        if wasHumanControlled, let current,
           (!humanPresent || current.humanPresent), current.tabID == session.activeTabID { return }
        // A failed delivery leaves the receipt marked returning but undelivered;
        // taking control again must keep that exact receipt for a later retry.
        if let receiptRun {
            if existing == nil
                || existing?.sessionID != session.sessionID
                || (existing?.returning == true && existingWasDelivered)
                || existing?.runID != receiptRun {
                if let existing {
                    deliveredHandoffIDs.remove(existing.id)
                    if let id = existing.takeoverEventID { deliveredTakeovers.remove(id) }
                }
                let event = Handoff(
                    id: UUID(),
                    conversationID: owner,
                    runID: receiptRun,
                    sessionID: session.sessionID,
                    tabID: session.activeTabID,
                    returning: false, takeoverEventID: humanPresent ? UUID() : nil
                )
                handoffs[owner] = event
            } else if var updated = handoffs[owner] {
                updated.tabID = session.activeTabID
                if humanPresent, updated.takeoverEventID == nil { updated.takeoverEventID = UUID() }
                handoffs[owner] = updated
            }
        }
        handoffNeedsContinueByConversation[owner] = false
        if conversationID == owner {
            handoff = receiptRun == nil ? nil : handoffs[owner]
            handoffNeedsContinue = false
            handoffNotified = false
            handoffError = nil
        }
        guard receiptRun != nil, let event = handoffs[owner] else { return }
        do {
            try persistHandoffs()
        } catch {
            if conversationID == owner { handoffError = error.localizedDescription }
        }
        if event.humanPresent { _ = startTakeoverDelivery(event) }
    }

    /// All entry points, including handback and recovery, join the same phase delivery.
    private func startTakeoverDelivery(_ event: Handoff) -> Task<Bool, Error>? {
        guard let id = event.takeoverEventID, event.humanPresent, currentHumanOwner(for: event) != nil,
              !deliveredTakeovers.contains(id), let deliverTakeover else { return nil }
        if let existing = takeoverDeliveries[id] { return existing }
        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            defer { takeoverDeliveries.removeValue(forKey: id) }
            guard handoffs[event.conversationID]?.id == event.id else { throw CancellationError() }
            do {
                let settled = try await deliverTakeover(event)
                if handoffs[event.conversationID]?.id == event.id, settled { deliveredTakeovers.insert(id) }
                return settled
            } catch {
                if conversationID == event.conversationID, handoff?.id == event.id { handoffError = error.localizedDescription }
                throw error
            }
        }
        takeoverDeliveries[id] = task
        return task
    }

    func returnControlIfCurrent(for session: BrowserTaskSession, handoffID: UUID?, presentationID: UUID? = nil) async -> Bool {
        guard visibleSession === session, !session.isReleased, session.isUserControlling, !session.takeoverPending,
              handoff?.id == handoffID, previewInteractionID == presentationID else { return false }
        await returnToAgent()
        return visibleSession === session && !session.isReleased && !session.isUserControlling
            && handoff?.id == handoffID && previewInteractionID == presentationID
    }

    // Older callers may request continuation. Resuming a stopped run belongs to the original task.
    func returnToAgent(continueTask _: Bool = false) async {
        guard taskHandoffsEnabled, !returningControl, visibleSession?.takeoverPending != true else { return }
        // A user who took over an idle browser (no model holder, no receipt)
        // simply returns that browser to idle. Nothing is delivered and no
        // task is started or continued on their behalf.
        guard let event = handoff else {
            if let session = visibleSession, session.isUserControlling {
                session.endUserControl()
                pendingPanelRequests.removeValue(forKey: session.conversationID)
                handoffNotified = false
                handoffNeedsContinue = false
            }
            return
        }
        guard let deliverHandoff else { return }
        guard deliveringHandoffs.insert(event.id).inserted else { return }
        returningControl = true
        handoffError = nil
        defer { returningControl = false; deliveringHandoffs.remove(event.id) }
        do {
            var updated = event
            updated.returning = true
            let ownerSession = currentHumanOwner(for: event)
            let page = ownerSession?.activeWebView
            ownerSession?.returningToModel = true
            defer {
                ownerSession?.returningToModel = false
                if ownerSession?.isUserControlling == true { page?.isUserInteractionEnabled = true }
            }
            page?.isUserInteractionEnabled = false
            handoffs[event.conversationID] = updated
            try persistHandoffs()
            if let prior = startTakeoverDelivery(updated) { _ = try await prior.value }
            guard handoffs[event.conversationID]?.id == event.id else { return }
            // Invalidate every pre-takeover element/document reference of the
            // exact task that returned control.
            ownerSession?.invalidateDocumentsForHandoff()
            let needsContinue = try await deliverHandoff(updated, false)
            guard handoffs[event.conversationID]?.id == event.id else { return }
            if deliveredHandoffIDs.insert(event.id).inserted {
                pendingPanelRequests.removeValue(forKey: event.conversationID)
                ownerSession?.endUserControl()
            }
            // Keep the durable outbox until a later takeover replaces it. On app
            // recovery the input store decides whether this ID was consumed.
            handoffs[event.conversationID] = updated
            handoffNeedsContinueByConversation[event.conversationID] = needsContinue
            try persistHandoffs()
            guard conversationID == event.conversationID else { return }
            handoff = updated
            handoffNotified = !needsContinue
            handoffNeedsContinue = needsContinue
        } catch {
            if conversationID == event.conversationID { handoffError = error.localizedDescription }
        }
    }

    private func ownerSessionFor(_ event: Handoff) -> BrowserTaskSession? {
        store.session(for: event.conversationID).flatMap {
            $0.sessionID == event.sessionID ? $0 : nil
        }
    }

    /// Retrying a notification must never relinquish a later holding period of this same page.
    private func currentHumanOwner(for event: Handoff) -> BrowserTaskSession? {
        guard handoffs[event.conversationID]?.id == event.id, !deliveredHandoffIDs.contains(event.id),
              let session = ownerSessionFor(event), session.isUserControlling else { return nil }
        return session
    }

    /// Called from the original runtime's state stream, including after cold
    /// recovery. Targets the exact recorded task/run and never rebinds or
    /// restarts another task.
    func recoverHandoff(conversationID: UUID, runID: UUID) async {
        guard taskHandoffsEnabled, let event = handoffs[conversationID], event.runID == runID else { return }
        if let prior = startTakeoverDelivery(event) {
            do { _ = try await prior.value } catch { return }
        }
        guard event.returning, handoffs[conversationID]?.id == event.id, let deliverHandoff,
              deliveringHandoffs.insert(event.id).inserted else { return }
        let ownerSession = currentHumanOwner(for: event)
        let page = ownerSession?.activeWebView
        ownerSession?.returningToModel = true
        page?.isUserInteractionEnabled = false
        defer {
            ownerSession?.returningToModel = false
            if ownerSession?.isUserControlling == true { page?.isUserInteractionEnabled = true }
        }
        defer { deliveringHandoffs.remove(event.id) }
        do {
            let needsContinue = try await deliverHandoff(event, false)
            guard handoffs[conversationID]?.id == event.id else { return }
            if deliveredHandoffIDs.insert(event.id).inserted {
                pendingPanelRequests.removeValue(forKey: conversationID)
                ownerSession?.endUserControl()
            }
            handoffNeedsContinueByConversation[conversationID] = needsContinue
            guard self.conversationID == conversationID else { return }
            if visibleSession?.isUserControlling == true, handoff?.id != event.id { return }
            handoff = event
            handoffNeedsContinue = needsContinue
            handoffNotified = !needsContinue
            handoffError = nil
        } catch {
            if self.conversationID == conversationID { handoffError = error.localizedDescription }
        }
    }

    func recoverHandoff() async {
        guard handoff?.returning == true else { return }
        await returnToAgent()
    }

    /// Releases exactly one task's WebViews, documents, evidence and pending
    /// handoff. Late callbacks for this owner are fenced — permanently while
    /// the tombstone is retained, and afterwards by the cancelled run's own
    /// ToolContext cancellation; other tasks keep their sessions and any
    /// visible panel. Only an explicit UI restore or a newly admitted run may
    /// reactivate this owner.
    func discard(conversationID: UUID) {
        fenceReleasedOwner(conversationID)
        ownerReleaseHook?(conversationID)
        if self.conversationID == conversationID {
            self.conversationID = nil
            unboundSessionID = UUID()
            handoff = nil
            handoffNeedsContinue = false
            handoffNotified = false
            handoffError = nil
        }
        if presentationRequest?.conversationID == conversationID {
            presentationRequest = nil
        }
        pendingPanelRequests.removeValue(forKey: conversationID)
        if let event = handoffs[conversationID] {
            deliveredHandoffIDs.remove(event.id)
            if let id = event.takeoverEventID {
                takeoverDeliveries[id]?.cancel()
                deliveredTakeovers.remove(id)
            }
        }
        handoffs.removeValue(forKey: conversationID)
        try? persistHandoffs()
        handoffNeedsContinueByConversation.removeValue(forKey: conversationID)
        knownRunIDs.removeValue(forKey: conversationID)
        store.release(conversationID)?.release()
    }

    private func refreshHandoffProjection(for conversationID: UUID) {
        let event = handoffs[conversationID].flatMap { receipt -> Handoff? in
            if let current = store.session(for: conversationID), current.isUserControlling,
               current.sessionID != receipt.sessionID || deliveredHandoffIDs.contains(receipt.id) { return nil }
            return receipt
        }
        handoff = event
        let needsContinue = handoffNeedsContinueByConversation[conversationID]
            ?? (event?.returning == true)
        handoffNeedsContinue = event != nil && needsContinue
        handoffNotified = event?.returning == true && !handoffNeedsContinue
    }

    private func persistHandoffs() throws {
        guard durableHandoffs else { return }
        try FileManager.default.createDirectory(
            at: handoffURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(Array(handoffs.values)).write(to: handoffURL, options: .atomic)
    }

    /// Screenshot evidence is ephemeral. Keep a bounded recent set and
    /// remove stale Floe-owned artifacts without touching user files.
    private func cleanupArtifacts(now: Date = Date()) {
        let manager = FileManager.default
        guard let urls = try? manager.contentsOfDirectory(
            at: artifactDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = now.addingTimeInterval(-24 * 60 * 60)
        let files = urls.compactMap { url -> (URL, Date)? in
            guard url.pathExtension.lowercased() == "jpg",
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true else { return nil }
            return (url, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.1 > $1.1 }
        for (index, file) in files.enumerated() where index >= 128 || file.1 < cutoff {
            try? manager.removeItem(at: file.0)
        }
    }
}

extension BrowserSessionCenter: BrowserTaskSessionHost {
    func browserSessionRequestedUserControl(_ session: BrowserTaskSession, reason: String) {
        // This path is a model `browser.panel(requestUser)` or a WebKit
        // sensitive-input escalation; the model's own lease (if any) names
        // the real run. Never fall back to a guessed recent run.
        beginUserControl(for: session, runID: session.currentModelRunID, reason: reason)
    }

    func browserSessionUserStartedInput(_ session: BrowserTaskSession, reason: String) {
        // First real human input: the current model holder's logical run is
        // the only run to notify. Browsing that no run holds stays local.
        beginUserControl(for: session, runID: session.currentModelRunID, reason: reason, humanPresent: true)
    }
}

extension BrowserSessionCenter: BrowserCookieProviding {
    /// Supplies browser cookies only for the exact active page origin and only
    /// after the active provider recipient has a one-time grant. Values cross
    /// into the URLSession Cookie header; they are never logged or returned as
    /// ordinary tool output by this method.
    func browserWebContext(
        for url: URL,
        conversationID: UUID?,
        runID: UUID?
    ) async throws -> BrowserWebContext {
        guard let conversationID else { throw BrowserCookieProviderError.noTask }
        guard let runID else { throw BrowserCookieProviderError.notAuthorized }
        guard let session = store.session(for: conversationID), !session.isReleased else {
            throw BrowserCookieProviderError.noTask
        }
        // Borrowing this browser's cookies is page/session data. While the
        // user operates the page the model gets no task cookie context.
        guard !session.isUserControlling, !session.takeoverPending else {
            throw BrowserCookieProviderError.notAuthorized
        }
        // Never let one run borrow cookies from a page another run owns.
        if let holder = session.modelControl, holder.runID != runID {
            throw BrowserCookieProviderError.notAuthorized
        }
        guard let tab = session.activeTab else {
            throw BrowserCookieProviderError.noActivePage
        }
        guard let pageURL = tab.webView.url,
              let pageOrigin = HTTPCookiePolicy.origin(pageURL),
              let requestOrigin = HTTPCookiePolicy.origin(url),
              pageOrigin == requestOrigin else {
            throw BrowserCookieProviderError.originMismatch
        }
        let authorization = try await BrowserProviderTrustCoordinator.shared.requireBrowserDataAuthorization(
            runID: runID,
            conversationID: conversationID
        )
        // Consent can take a human-visible moment: recheck the exact page
        // ownership before reading and again before returning cookie values.
        func ensureStillAuthorized() throws {
            guard store.session(for: conversationID) === session, !session.isReleased,
                  !session.isUserControlling, !session.takeoverPending else {
                throw BrowserCookieProviderError.notAuthorized
            }
            if let holder = session.modelControl, holder.runID != runID {
                throw BrowserCookieProviderError.notAuthorized
            }
        }
        try ensureStillAuthorized()
        let allCookies = await session.websiteDataStore.httpCookieStore.allCookies()
        try BrowserProviderTrustCoordinator.shared.revalidateBrowserDataAuthorization(
            runID: runID,
            expectedProviderID: authorization.provider.id,
            advancedGeneration: authorization.advancedGeneration
        )
        try ensureStillAuthorized()
        let cookies = allCookies.map(HTTPCookiePolicy.snapshot(from:))
        let matched = HTTPCookiePolicy.matchingCookies(for: url, cookies: cookies)
        return BrowserWebContext(
            cookies: matched,
            userAgent: tab.webView.customUserAgent ?? settings.userAgent.effectiveValue,
            origin: pageOrigin,
            authorizationProviderID: authorization.provider.id,
            authorizationGeneration: authorization.advancedGeneration
        )
    }

    func revalidateBrowserWebContext(
        _ context: BrowserWebContext,
        conversationID: UUID?,
        runID: UUID?
    ) async throws {
        guard let runID else { throw BrowserCookieProviderError.notAuthorized }
        guard let providerID = context.authorizationProviderID else {
            throw BrowserCookieProviderError.notAuthorized
        }
        if let conversationID, let session = store.session(for: conversationID) {
            if session.isUserControlling || session.takeoverPending {
                throw BrowserCookieProviderError.notAuthorized
            }
            if let holder = session.modelControl, holder.runID != runID {
                throw BrowserCookieProviderError.notAuthorized
            }
        }
        try BrowserProviderTrustCoordinator.shared.revalidateBrowserDataAuthorization(
            runID: runID,
            expectedProviderID: providerID,
            advancedGeneration: context.authorizationGeneration
        )
    }
}
#endif
