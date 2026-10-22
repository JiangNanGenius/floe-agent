#if canImport(Network) && canImport(WebKit) && canImport(SwiftUI)
import Foundation
import Network
import FloeCore
import FloeModels
import FloeTools

/// Task-owned local previews. Every trusted owner (a ToolContext
/// conversation, or the one owner the file UI explicitly selected) gets its
/// own preview server on its own loopback port and its own browser-session
/// navigation: starting, reloading or stopping one owner's preview never
/// touches another owner's. Records outlive any view (they belong to the
/// environment) and are released only by that owner's explicit stop or by
/// the owner's browser release.
@MainActor
final class LocalPreviewCoordinator: ObservableObject, @unchecked Sendable {
    private struct PreviewRecord {
        let server: LocalPreviewServer
        let session: LocalPreviewServer.Session
    }

    /// Deterministic lifecycle seam used only by tests. Production keeps it
    /// nil; it runs after the staged server exists and after the owner's page
    /// navigation returns, which are the two real suspension boundaries this
    /// coordinator must fence. It never grants authority: all lifecycle and
    /// cancellation checks still run after the seam returns.
    enum StartPhase {
        case afterServerStart(owner: UUID, stagedURL: URL)
        case afterNavigation(owner: UUID, stagedURL: URL)
    }
    var previewStartPhaseHookForTesting: (@MainActor (StartPhase) async -> Void)?

    private weak var browser: BrowserSessionCenter?
    /// One preview record per trusted owner, keyed by conversation.
    private var records: [UUID: PreviewRecord] = [:]
    /// The owner whose preview the file UI currently presents. Explicit UI
    /// selection only — it is never inferred from a model call or a start.
    @Published private(set) var selectedOwner: UUID?
    @Published private(set) var activeURL: URL?

    /// Monotonic operation identity for every start and every stop/release.
    /// A start captures its id before its first suspension and may promote
    /// only while that id is still the owner's latest operation. `stop`,
    /// `releasePreview` and a newer start all take a newer id, so an earlier
    /// start that resumes late can never resurrect a stopped owner or replace
    /// a newer preview. There is deliberately no time- or pressure-based
    /// expiry: at capacity new starts are refused instead of evicting a
    /// tombstone, because eviction would hand stale authority back.
    private var nextOperationID = 0
    private var latestOperationID: [UUID: Int] = [:]
    private var activeStarts: [Int: UUID] = [:]
    private let maximumActiveStarts = 32

    init(browser: BrowserSessionCenter) { self.browser = browser }

    // MARK: - Tool path (trusted ToolContext owner)

    func start(
        root: URL,
        relativeRoot: String?,
        entry: String?,
        owner: UUID,
        cancellation: CancellationToken? = nil
    ) async throws -> ToolExecutionOutput {
        try await startPreview(
            root: root,
            relativeRoot: relativeRoot,
            entry: entry,
            owner: owner,
            cancellation: cancellation
        )
    }

    func reload(owner: UUID, cancellation: CancellationToken? = nil) async throws -> ToolExecutionOutput {
        guard let browser else { throw FloeError.invalidConfiguration("Visible browser is unavailable") }
        try checkCancellation(cancellation)
        guard let record = records[owner] else {
            throw FloeError.notFound("No preview is active for this task")
        }
        guard let session = browser.session(for: owner) else {
            throw FloeError.notFound("This task's browser session was released")
        }
        // Reload is only a preview reload while this task's own page still
        // shows this owner's staged preview. A page the user navigated away
        // from is not reported as a reloaded preview.
        guard let currentURL = session.activeWebView?.url,
              isPreviewURL(currentURL, matching: record.session.url) else {
            throw FloeError.validationFailed(
                "This task's browser is no longer showing the preview; start it again"
            )
        }
        let result = await browser.execute(
            BrowserCommand(sessionID: session.sessionID, action: .reload),
            in: owner
        )
        try checkCancellation(cancellation)
        // A newer start may have replaced this record while the reload was in
        // flight; its page is not what this call reloaded.
        guard records[owner]?.server === record.server else {
            throw FloeError.validationFailed(
                "This task's preview changed while it was reloading; the current preview was not reloaded"
            )
        }
        switch result.status {
        case .ok:
            return ToolExecutionOutput(
                summary: "Preview reloaded at \(record.session.url.absoluteString)",
                fullOutputSHA256: ""
            )
        case .needsUser:
            // The browser still belongs to the user; the task can continue and
            // retry after control returns. Never report this as success.
            return ToolExecutionOutput(
                summary: "Preview reload needs the user: "
                    + (result.message ?? "The user currently controls this task's browser"),
                fullOutputSHA256: "",
                requiresUserAction: true
            )
        case .stale, .blocked, .timeout, .failed:
            throw FloeError.validationFailed(
                result.message ?? "Preview could not be reloaded"
            )
        }
    }

    func stop(owner: UUID) -> ToolExecutionOutput {
        releaseRecord(for: owner)
        return ToolExecutionOutput(summary: "Preview stopped", fullOutputSHA256: "")
    }

    // MARK: - Explicit UI selection

    /// Binds the file preview surface to one owner (or clears it). This is
    /// the only way `selectedOwner` changes; model calls never select, and a
    /// start for a background owner never moves the selected projection.
    func select(_ owner: UUID?) {
        selectedOwner = owner
        activeURL = owner.flatMap { records[$0]?.session.url }
    }

    func url(for owner: UUID) -> URL? {
        records[owner]?.session.url
    }

    /// Called by the browser center's owner-release hook when the task's
    /// browser is released: only that owner's preview record stops.
    func releasePreview(for owner: UUID) {
        releaseRecord(for: owner)
    }

    // MARK: - Shared start

    /// Starts one owner's preview. The caller always supplies the trusted
    /// owner (the file UI resolves it from the file's task, never from the
    /// visible browser). The tool path also supplies the runtime cancellation
    /// token, which is checked after every suspension.
    private func startPreview(
        root: URL,
        relativeRoot: String?,
        entry: String?,
        owner: UUID,
        cancellation: CancellationToken?
    ) async throws -> ToolExecutionOutput {
        guard let browser else { throw FloeError.invalidConfiguration("Visible browser is unavailable") }
        try checkCancellation(cancellation)
        let resolved = try resolvePreviewRoot(root: root, relativeRoot: relativeRoot, entry: entry)
        // Register the operation before the first suspension, atomically on
        // the main actor, so a stop/release/new start that happens during any
        // following await is observed by the final fence.
        let operationID = try beginStart(owner: owner)
        var staged: (server: LocalPreviewServer, session: LocalPreviewServer.Session)?
        var navigation: (sessionID: UUID, url: URL)?
        var navigationUncertain = false
        var priorRecord: PreviewRecord?
        var priorPageURL: URL?
        do {
            // Start the new server before touching any existing record: a
            // failed or cancelled start cleans up only its own staging.
            let started = try await LocalPreviewServer.start(root: resolved.root, entry: resolved.entry)
            staged = started
            await previewStartPhaseHookForTesting?(
                .afterServerStart(owner: owner, stagedURL: started.1.url)
            )
            try verifyStart(operationID: operationID, owner: owner, cancellation: cancellation)
            let session = try browser.taskSession(for: owner)
            try verifyStart(operationID: operationID, owner: owner, cancellation: cancellation)
            priorRecord = records[owner]
            priorPageURL = session.activeWebView?.url
            let command = BrowserCommand(
                sessionID: session.sessionID,
                action: .navigate(url: started.1.url.absoluteString)
            )
            FloeLogger(category: .tools).info("Preview navigation operation=\(operationID) request=\(command.requestID.uuidString) phase=begin")
            let result = await browser.execute(command, in: owner)
            FloeLogger(category: .tools).info("Preview navigation operation=\(operationID) request=\(command.requestID.uuidString) phase=end status=\(result.status.rawValue)")
            // The load is issued before the protocol observes the page. Ok is
            // conclusive; a failed observe is also a real navigation when the
            // task's page already points at this staging allocation.
            let navigationIssued = result.status == .ok
                || (session.activeWebView?.url.map {
                    isPreviewURL($0, matching: started.1.url)
                } ?? false)
            if navigationIssued {
                navigation = (session.sessionID, started.1.url)
            } else if result.status == .failed || result.status == .timeout {
                // The load may have been issued even though the observe step
                // failed and no URL is visible yet. Treat the page state as
                // unknown instead of claiming the attempt had no effect.
                navigationUncertain = true
            }
            await previewStartPhaseHookForTesting?(
                .afterNavigation(owner: owner, stagedURL: started.1.url)
            )
            try verifyStart(operationID: operationID, owner: owner, cancellation: cancellation)
            guard let current = browser.session(for: owner),
                  current.sessionID == session.sessionID else {
                throw FloeError.validationFailed(
                    "This task's browser session changed while the preview was starting"
                )
            }
            guard result.status == .ok else {
                throw FloeError.validationFailed(
                    result.message ?? "Preview could not open in the browser"
                )
            }
            // Commit point: no suspension between the fence above and this
            // promotion, so a late start cannot overwrite a newer record.
            records[owner] = PreviewRecord(server: started.0, session: started.1)
            priorRecord?.server.stop()
            if selectedOwner == owner { activeURL = started.1.url }
            endStart(operationID: operationID, owner: owner)
            return ToolExecutionOutput(
                summary: "Preview started at \(started.1.url.absoluteString)",
                fullOutputSHA256: ""
            )
        } catch {
            // Clean only the staging created by this attempt. The previous
            // record (this owner's or another owner's) keeps serving until it
            // is explicitly replaced at the commit point above.
            staged?.server.stop()
            var restoreFailed = false
            var uncertaintyNote: String?
            if let navigation {
                // A live prior preview is the strongest restore target (its
                // URL is authorized and serving). With no prior preview, the
                // task's own pre-existing page is restored instead; a prior
                // preview that was stopped is never navigated to.
                let restoreURL: URL?
                if let priorRecord {
                    if let liveRecord = records[owner],
                       liveRecord.server === priorRecord.server {
                        restoreURL = liveRecord.session.url
                    } else {
                        restoreURL = nil
                    }
                } else {
                    restoreURL = priorPageURL
                }
                restoreFailed = !(await restoreAbandonedNavigation(
                    owner: owner,
                    sessionID: navigation.sessionID,
                    stagedURL: navigation.url,
                    restoreURL: restoreURL
                ))
                if restoreFailed {
                    uncertaintyNote = " The task's browser page may still show the stopped preview."
                }
            } else if navigationUncertain {
                restoreFailed = true
                uncertaintyNote = " The preview navigation outcome is unknown; the task's browser page may still load the stopped preview."
            }
            endStart(operationID: operationID, owner: owner)
            if restoreFailed, !isCancellation(error) {
                // This attempt may have changed this owner's page (or may
                // still be loading the stopped staging) and no live prior page
                // could be restored. Say so instead of implying the abandoned
                // start had no effect.
                throw FloeError.validationFailed(
                    error.localizedDescription + (uncertaintyNote ?? "")
                )
            }
            throw error
        }
    }

    /// Restores this owner's own page to its still-live prior preview after
    /// an abandoned navigation. It never touches another task's session and
    /// never rolls back a page that no longer shows this attempt's staging.
    @discardableResult
    private func restoreAbandonedNavigation(
        owner: UUID,
        sessionID: UUID,
        stagedURL: URL,
        restoreURL: URL?
    ) async -> Bool {
        guard let browser,
              let session = browser.session(for: owner),
              session.sessionID == sessionID else { return false }
        // Unknown/absent current URL means this attempt cannot prove its
        // navigation is still the page. Do not roll back anything then.
        guard let currentURL = session.activeWebView?.url,
              isPreviewURL(currentURL, matching: stagedURL),
              let restoreURL else { return false }
        let result = await browser.execute(
            BrowserCommand(
                sessionID: sessionID,
                action: .navigate(url: restoreURL.absoluteString)
            ),
            in: owner
        )
        return result.status == .ok
    }

    private func beginStart(owner: UUID) throws -> Int {
        guard activeStarts.count < maximumActiveStarts else {
            throw FloeError.validationFailed(
                "Too many previews are starting; retry when one finishes"
            )
        }
        nextOperationID &+= 1
        latestOperationID[owner] = nextOperationID
        activeStarts[nextOperationID] = owner
        return nextOperationID
    }

    private func endStart(operationID: Int, owner: UUID) {
        activeStarts.removeValue(forKey: operationID)
        pruneOperationStateIfIdle(owner)
    }

    /// Stops or releases one owner's preview and invalidates every start
    /// already in flight for it. Other owners' operations are untouched.
    private func invalidateOwnerOperations(for owner: UUID) {
        nextOperationID &+= 1
        latestOperationID[owner] = nextOperationID
        pruneOperationStateIfIdle(owner)
    }

    /// Keeps the bounded operation state only while it can still reject a
    /// late completion: a live record or an in-flight start. Once both are
    /// gone no older start can resume and promote, so the entry is dropped.
    private func pruneOperationStateIfIdle(_ owner: UUID) {
        guard records[owner] == nil, !activeStarts.values.contains(owner) else { return }
        latestOperationID.removeValue(forKey: owner)
    }

    private func verifyStart(
        operationID: Int,
        owner: UUID,
        cancellation: CancellationToken?
    ) throws {
        try checkCancellation(cancellation)
        guard latestOperationID[owner] == operationID else {
            throw FloeError.validationFailed(
                "The preview start was superseded by a newer preview or a stop for this task"
            )
        }
    }

    private func checkCancellation(_ cancellation: CancellationToken?) throws {
        if cancellation?.isCancelled == true { throw FloeError.cancelled }
        try Task.checkCancellation()
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let floe = error as? FloeError, case .cancelled = floe { return true }
        return false
    }

    /// True when `candidate` still belongs to the same loopback preview
    /// allocation (scheme/host/port and the per-server token path segment).
    /// Entry/subpage changes inside the same preview remain valid.
    private func isPreviewURL(_ candidate: URL, matching previewURL: URL) -> Bool {
        guard candidate.scheme == previewURL.scheme,
              candidate.host == previewURL.host,
              candidate.port == previewURL.port,
              let token = previewURL.pathComponents.dropFirst().first else { return false }
        return candidate.pathComponents.dropFirst().first == token
    }

    private func releaseRecord(for owner: UUID) {
        invalidateOwnerOperations(for: owner)
        records[owner]?.server.stop()
        records[owner] = nil
        pruneOperationStateIfIdle(owner)
        if selectedOwner == owner {
            selectedOwner = nil
            activeURL = nil
        }
    }

    private func resolvePreviewRoot(
        root: URL,
        relativeRoot: String?,
        entry: String?
    ) throws -> (root: URL, entry: String?) {
        var selectedRoot: URL
        var selectedEntry = entry
        if let relativeRoot, !relativeRoot.isEmpty {
            guard !relativeRoot.hasPrefix("/"), !relativeRoot.split(separator: "/").contains("..") else {
                throw FloeError.validationFailed("Preview root must be a safe workspace-relative path")
            }
            let candidate = root.appendingPathComponent(relativeRoot)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                // The model passed a file (commonly the entry page) as root:
                // serve its directory and use the file as the entry.
                selectedRoot = candidate.deletingLastPathComponent()
                selectedEntry = candidate.lastPathComponent
            } else {
                selectedRoot = candidate
            }
        } else {
            selectedRoot = root
        }
        return (selectedRoot, selectedEntry)
    }
}

/// Resolves the trusted owner for a preview tool call exactly like the
/// browser tools: the runtime-issued ToolContext conversation, never a
/// model-supplied value, and never the temporary public-web ceiling.
private func previewOwner(for context: ToolContext) throws -> UUID {
    guard let owner = context.conversationID else {
        throw FloeError.validationFailed(
            "Preview tools require a task-owned run. Open a task and use its preview."
        )
    }
    guard !context.temporaryReadOnly, !context.publicWebOnly else {
        throw FloeError.validationFailed(
            "Temporary chat cannot start or control a durable preview"
        )
    }
    try context.cancellation.throwIfCancelled()
    return owner
}

private struct PreviewStartTool: AgentTool {
    struct Arguments: Decodable, Sendable { let root: String?; let entry: String? }
    static let name = "preview.start"
    static let toolDescription = "Serve static files from the current task workspace in its browser session without opening the user's panel. Use browser.panel requestUser only if human interaction is necessary. root is a workspace-relative directory (a file path is accepted; its parent is served with that file as the entry); entry is relative to root and defaults to index.html/index.htm/public/index.html/dist/index.html/build/index.html or the only HTML file in the directory."
    static let parametersJSON = #"{"type":"object","properties":{"root":{"type":"string","description":"Workspace-relative directory to serve; a file path serves its parent with that file as entry"},"entry":{"type":"string","description":"Entry file relative to root; defaults to common index names or the only HTML file"}},"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.controlsGUI]
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly
    let environment: LocalPreviewCoordinator
    func validate(_ args: Arguments) throws {}
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        guard let root = context.workspaceRootURL else { throw FloeError.notFound("No task workspace is open") }
        let owner = try previewOwner(for: context)
        return try await environment.start(
            root: root,
            relativeRoot: args.root,
            entry: args.entry,
            owner: owner,
            cancellation: context.cancellation
        )
    }
}

private struct PreviewReloadTool: AgentTool {
    struct Arguments: Decodable, Sendable {}
    static let name = "preview.reload"
    static let toolDescription = "Reload this task's active local static preview. Only the calling task's preview is affected."
    static let riskLabels: Set<RiskLabel> = [.controlsGUI]
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly
    let environment: LocalPreviewCoordinator
    func validate(_ args: Arguments) throws {}
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let owner = try previewOwner(for: context)
        let output = try await environment.reload(
            owner: owner,
            cancellation: context.cancellation
        )
        // The reload may have awaited the page; a run cancelled during that
        // window must not present its result as live work.
        try context.cancellation.throwIfCancelled()
        return output
    }
}

private struct PreviewStopTool: AgentTool {
    struct Arguments: Decodable, Sendable {}
    static let name = "preview.stop"
    static let toolDescription = "Stop this task's active local static preview. Other tasks' previews keep serving."
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly
    let environment: LocalPreviewCoordinator
    func validate(_ args: Arguments) throws {}
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        await environment.stop(owner: try previewOwner(for: context))
    }
}

@MainActor
func registerPreviewTools(environment: LocalPreviewCoordinator, registry: ToolRunnerRegistry = .shared) {
    ToolCatalog.register(PreviewStartTool.self)
    ToolCatalog.register(PreviewReloadTool.self)
    ToolCatalog.register(PreviewStopTool.self)
    registry.register(PreviewStartTool(environment: environment))
    registry.register(PreviewReloadTool(environment: environment))
    registry.register(PreviewStopTool(environment: environment))
}
#endif
