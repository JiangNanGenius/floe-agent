// FloeApp — service-owned browser sessions for concurrent tasks.
//
// BrowserSessionCenter is the durable owner of handoff receipts, the panel
// request route and the *visible* projection. Execution itself lives in one
// independent BrowserTaskSession per trusted conversation, so a background
// task keeps operating its own tabs while another task's panel is on screen.

#if canImport(SwiftUI) && canImport(WebKit) && canImport(UIKit)
import Foundation
import SwiftUI
import WebKit
import FloeCore

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
        var pageAddress: String? = nil
    }
    struct PanelRequest: Equatable {
        let id = UUID()
        let conversationID: UUID
        let show: Bool
    }

    /// The conversation whose browser the UI currently projects. Binding is a
    /// presentation choice only; it never moves execution between sessions.
    @Published private(set) var conversationID: UUID?
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

    var handoffRun: ((UUID) -> UUID?)?
    var deliverHandoff: ((Handoff, Bool) async throws -> Bool)?
    /// Set by AppEnvironment so an explicit owner release also stops that
    /// owner's local preview server. The coordinator is owned by the
    /// environment (not this center), and preview records are task-owned;
    /// stopping them belongs to the same lifecycle event as the browser.
    var ownerReleaseHook: ((UUID) -> Void)?

    private let durableHandoffs: Bool
    private let artifactDirectory: URL
    private let sessionConfiguration: BrowserTaskSessionConfiguration
    private let store = BrowserTaskSessionStore(maximumSessions: 128)
    private var unboundSessionID = UUID()

    private var handoffs: [UUID: Handoff] = [:]
    private var deliveringHandoffs = Set<UUID>()
    private var deliveredHandoffIDs = Set<UUID>()
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

    private var handoffURL: URL {
        artifactDirectory.deletingLastPathComponent().appendingPathComponent("BrowserHandoffs.json")
    }
    private var protocolVersion: String { sessionConfiguration.protocolVersion }

    init(durableHandoffs: Bool = true) {
        self.durableHandoffs = durableHandoffs
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
        sessionConfiguration = BrowserTaskSessionConfiguration(
            protocolVersion: "FloeBrowser/1.0",
            contentWorld: WKContentWorld.world(name: "org.floeagent.browser.agent"),
            artifactDirectory: artifacts,
            maximumTabs: 6,
            maximumEventsPerTab: 256
        )
        super.init()
        // Durable handoff persistence and shared-artifact retention are owned
        // by exactly one service instance per process. Task sessions never
        // write handoff receipts or prune screenshots, and ephemeral preview
        // centers (durableHandoffs: false) must not delete another owner's
        // evidence.
        if durableHandoffs, !Self.didRunArtifactSweep {
            Self.didRunArtifactSweep = true
            cleanupArtifacts()
        }
        if durableHandoffs, let data = try? Data(contentsOf: handoffURL),
           let saved = try? JSONDecoder().decode([Handoff].self, from: data) {
            handoffs = Dictionary(saved.map { ($0.conversationID, $0) }, uniquingKeysWith: { _, latest in latest })
        }
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
        _ = session.createTab()
        session.surfaceState = .ready
        return session
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
            reason: "Browser control is yours; the task can continue other work."
        )
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
        // Handoff is not a way to conjure a browser for a task that has none:
        // the task must already own a session with a navigated page. This also
        // keeps a forged/absent owner from opening a panel.
        guard let session = store.session(for: conversationID) else {
            throw FloeError.validationFailed(
                "This task's browser is not open; navigate before requesting user interaction"
            )
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

    /// Reads and clears one owner's pending panel request. The app calls this
    /// when the user explicitly selects the owning conversation, so a
    /// background task's request is presented exactly once and never steals
    /// the panel of another selected task.
    func consumePendingPanelRequest(for conversationID: UUID) -> PanelRequest? {
        pendingPanelRequests.removeValue(forKey: conversationID)
    }

    /// Visible-session form retained for the UI and existing callers.
    func requestPanelDismissal() throws {
        guard let conversationID else { throw FloeError.validationFailed("No task browser is active") }
        try requestPanelDismissal(conversationID: conversationID)
    }

    /// Closes only the calling task's panel. A different task's visible panel
    /// is never dismissed by this call.
    func requestPanelDismissal(conversationID: UUID) throws {
        guard let session = store.session(for: conversationID) else {
            throw FloeError.validationFailed("This task's browser is not open")
        }
        guard !session.isUserControlling else {
            throw FloeError.validationFailed("Wait for the user to return browser control before closing their panel")
        }
        guard self.conversationID == conversationID else {
            throw FloeError.validationFailed("This task's browser panel is not visible; no panel was closed")
        }
        pendingPanelRequests.removeValue(forKey: conversationID)
        presentationRequest = PanelRequest(conversationID: conversationID, show: false)
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
        liftReleaseFence(for: conversationID)
    }

    /// The recorded owner run, used to attribute durable work (page capture,
    /// handoff receipts) to the actual admitted run instead of a newer one.
    func recordedOwnerRun(for conversationID: UUID) -> UUID? {
        knownRunIDs[conversationID]
    }

    private func beginUserControl(
        for session: BrowserTaskSession,
        runID: UUID?,
        reason: String?
    ) {
        let owner = session.conversationID
        // Only the owner's CURRENT, unreleased session may initiate user
        // control. A session from an older generation (released, then
        // reactivated) is fenced here: its late delegate callbacks can never
        // hand control or rewrite the durable receipt for a newer session.
        guard store.session(for: owner) === session, !session.isReleased else { return }
        let existing = handoffs[owner]
        let existingWasDelivered = existing.map { deliveredHandoffIDs.contains($0.id) } ?? false
        // A failed delivery leaves the receipt marked returning but undelivered;
        // taking control again must keep that exact receipt for a later retry.
        if existing == nil
            || existing?.sessionID != session.sessionID
            || (existing?.returning == true && existingWasDelivered) {
            if let existing { deliveredHandoffIDs.remove(existing.id) }
            let event = Handoff(
                id: UUID(),
                conversationID: owner,
                runID: runID ?? handoffRun?(owner) ?? knownRunIDs[owner],
                sessionID: session.sessionID,
                tabID: session.activeTabID,
                returning: false
            )
            handoffs[owner] = event
            do { try persistHandoffs() } catch {
                if conversationID == owner { handoffError = error.localizedDescription }
            }
        } else if var updated = handoffs[owner], updated.tabID != session.activeTabID {
            // Keep the same durable receipt while the user takes control of
            // another tab in this task's own browser.
            updated.tabID = session.activeTabID
            handoffs[owner] = updated
            try? persistHandoffs()
        }
        session.setUserControlling(true)
        if let reason { session.surfaceState = .needsUser(reason) }
        handoffNeedsContinueByConversation[owner] = false
        guard conversationID == owner else { return }
        handoff = handoffs[owner]
        handoffNeedsContinue = false
        handoffNotified = false
        handoffError = nil
    }

    func returnToAgent(continueTask: Bool = false) async {
        guard !returningControl, let event = handoff, let deliverHandoff else { return }
        guard deliveringHandoffs.insert(event.id).inserted else { return }
        returningControl = true
        handoffError = nil
        defer { returningControl = false; deliveringHandoffs.remove(event.id) }
        do {
            let firstReturn = !event.returning
            var updated = event
            updated.returning = true
            // Only the exact session that produced this receipt may donate its
            // page address or have its document references invalidated.
            let ownerSession = store.session(for: event.conversationID).flatMap {
                $0.sessionID == event.sessionID ? $0 : nil
            }
            // Never persist credentials, fragments or query parameters from the page.
            if firstReturn,
               let ownerSession,
               var address = ownerSession.activeWebView?.url.flatMap({
                   URLComponents(url: $0, resolvingAgainstBaseURL: false)
               }) {
                address.user = nil; address.password = nil; address.query = nil; address.fragment = nil
                updated.pageAddress = address.url?.absoluteString
            }
            handoffs[event.conversationID] = updated
            try persistHandoffs()
            // Invalidate every pre-takeover element/document reference of the
            // exact task that returned control.
            ownerSession?.invalidateDocumentsForHandoff()
            let needsContinue = try await deliverHandoff(updated, continueTask)
            deliveredHandoffIDs.insert(event.id)
            // Keep the durable outbox until a later takeover replaces it. On app
            // recovery the input store decides whether this ID was consumed.
            handoffs[event.conversationID] = updated
            handoffNeedsContinueByConversation[event.conversationID] = needsContinue
            pendingPanelRequests.removeValue(forKey: event.conversationID)
            ownerSession?.setUserControlling(false)
            try persistHandoffs()
            guard conversationID == event.conversationID else { return }
            handoff = updated
            handoffNotified = !needsContinue
            handoffNeedsContinue = needsContinue
        } catch {
            if conversationID == event.conversationID { handoffError = error.localizedDescription }
        }
    }

    /// Called from the original runtime's state stream, including after cold
    /// recovery. Targets the exact recorded task/run and never rebinds or
    /// restarts another task.
    func recoverHandoff(conversationID: UUID, runID: UUID) async {
        guard let event = handoffs[conversationID], event.returning, event.runID == runID,
              let deliverHandoff, deliveringHandoffs.insert(event.id).inserted else { return }
        defer { deliveringHandoffs.remove(event.id) }
        do {
            let needsContinue = try await deliverHandoff(event, false)
            deliveredHandoffIDs.insert(event.id)
            handoffNeedsContinueByConversation[conversationID] = needsContinue
            pendingPanelRequests.removeValue(forKey: conversationID)
            if let ownerSession = store.session(for: conversationID),
               ownerSession.sessionID == event.sessionID {
                ownerSession.setUserControlling(false)
            }
            guard self.conversationID == conversationID else { return }
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
        if let event = handoffs[conversationID] { deliveredHandoffIDs.remove(event.id) }
        handoffs.removeValue(forKey: conversationID)
        try? persistHandoffs()
        handoffNeedsContinueByConversation.removeValue(forKey: conversationID)
        knownRunIDs.removeValue(forKey: conversationID)
        store.release(conversationID)?.release()
    }

    private func refreshHandoffProjection(for conversationID: UUID) {
        let event = handoffs[conversationID]
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
        beginUserControl(for: session, runID: nil, reason: reason)
    }
}
#endif
