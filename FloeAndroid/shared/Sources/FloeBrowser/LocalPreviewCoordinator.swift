// FloeAndroid shared/Sources/FloeBrowser — task-owned local previews.
//
// Android mirror of the iOS `LocalPreviewCoordinator` (FloeAgent/FloeApp/
// Browser/LocalPreviewServer.swift @ 3fd597b…, sha256 8bec3f01…). Every
// trusted owner gets its own preview server on its own loopback port and its
// own browser-session navigation: starting, reloading or stopping one owner's
// preview never touches another owner's. Records outlive any view (they
// belong to this service) and are released only by that owner's explicit stop
// or by the owner's browser release (Main wires `center.ownerReleaseHook` to
// `releasePreview(for:)`).
//
// Documented mirror deltas:
//  * Root/entry resolution runs against `PreviewResourcePort` (native path
//    authority), never FileManager on a raw URL; the accepted identity is the
//    `BrowserOwnerID` triple + a workspace-relative root (D4).
//  * The listener is the `BrowserPreviewTransport` port (Kotlin ServerSocket);
//    Swift keeps the lease/token/grant and every adjudication.
//  * Tool-facing results are typed here; the thin AgentTool adapters (Main's
//    scope) map them onto ToolExecutionOutput like the originals.

import Foundation
import FloeCore
import FloeTools

public struct BrowserPreviewOutcome: Sendable, Codable, Hashable {
    public var url: String
    public var entry: String
    public var relativeRoot: String

    public init(url: String, entry: String, relativeRoot: String) {
        self.url = url
        self.entry = entry
        self.relativeRoot = relativeRoot
    }
}

public enum BrowserPreviewError: Error, LocalizedError, Sendable, Equatable {
    case noBrowser
    case noPreview
    case notShowingPreview
    case superseded
    case replacedWhileReloading
    case validation(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .noBrowser: return "Visible browser is unavailable"
        case .noPreview: return "No preview is active for this task"
        case .notShowingPreview: return "This task's browser is no longer showing the preview; start it again"
        case .superseded: return "The preview start was superseded by a newer preview or a stop for this task"
        case .replacedWhileReloading: return "This task's preview changed while it was reloading; the current preview was not reloaded"
        case .validation(let message): return message
        case .cancelled: return "The preview operation was cancelled"
        }
    }
}

public actor LocalPreviewCoordinator {
    private struct PreviewRecord {
        let server: LocalPreviewServer
        let leaseID: UUID
        let url: URL
        let entry: String
        let relativeRoot: String
    }

    private let browser: BrowserSessionCenter
    private let transport: BrowserPreviewTransport
    private let resource: PreviewResourcePort
    private let policy: BrowserURLPolicy

    /// One preview record per trusted owner, keyed by conversation.
    private var records: [UUID: PreviewRecord] = [:]
    private var serversByLease: [UUID: LocalPreviewServer] = [:]
    /// The owner whose preview the file UI currently presents. Explicit UI
    /// selection only — it is never inferred from a model call or a start.
    public private(set) var selectedOwner: UUID?
    public private(set) var activeURL: URL?

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

    public init(
        browser: BrowserSessionCenter,
        transport: BrowserPreviewTransport,
        resource: PreviewResourcePort,
        policy: BrowserURLPolicy
    ) {
        self.browser = browser
        self.transport = transport
        self.resource = resource
        self.policy = policy
    }

    // MARK: - JNI surface for the dumb transport

    /// Main's Kotlin loopback transport calls this (through the JNI bridge)
    /// with exactly what the peer sent; an unknown/stopped lease gets an
    /// honest 404 and nothing is read.
    public func adjudicate(leaseID: UUID, requestID: UUID, headerBlock: Data) async -> BrowserPreviewVerdict {
        guard let server = serversByLease[leaseID] else {
            return BrowserPreviewVerdict.error(requestID, "404 Not Found")
        }
        return await server.adjudicate(requestID: requestID, headerBlock: headerBlock)
    }

    public func readChunk(leaseID: UUID, requestID: UUID, offset: Int) async -> Data {
        guard let server = serversByLease[leaseID] else { return Data() }
        return await server.readChunk(requestID: requestID, offset: offset)
    }

    // MARK: - Tool path (trusted owner)

    public func start(
        owner: BrowserOwnerID,
        relativeRoot: String?,
        entry: String?,
        cancellation: CancellationToken? = nil
    ) async throws -> BrowserPreviewOutcome {
        try checkCancellation(cancellation)
        let baseRoot = PreviewWorkspaceRoot(owner: owner, relativeRoot: "")
        let resolved = try await resolvePreviewRoot(base: baseRoot, relativeRoot: relativeRoot, entry: entry)
        // Register the operation before the first suspension, atomically on
        // the actor, so a stop/release/new start that happens during any
        // following await is observed by the final fence.
        let operationID = try beginStart(owner: owner.taskID)
        var staged: (leaseID: UUID, server: LocalPreviewServer, url: URL, token: String)?
        var navigation: (sessionID: UUID, url: URL)?
        var navigationUncertain = false
        var priorRecord: PreviewRecord?
        var priorPageURL: URL?
        do {
            // Resolve the entry BEFORE binding anything: a missing entry must
            // not leak a running listener/port (original rule).
            let selectedEntry = try await resolveEntry(root: resolved.root, requested: resolved.entry)
            // Start the new listener before touching any existing record: a
            // failed or cancelled start cleans up only its own staging.
            let leaseID = UUID()
            let token = LocalPreviewServer.mintToken()
            let endpoint = try await transport.start(lease: BrowserPreviewLeaseRequest(leaseID: leaseID, token: token))
            guard (1024...65535).contains(endpoint.port) else {
                await transport.stop(leaseID: leaseID)
                throw BrowserPreviewTransportError.startFailed("The transport reported an invalid port")
            }
            let url = URL(string: "http://127.0.0.1:\(endpoint.port)/\(token)/\(selectedEntry)")!
            let session = LocalPreviewServer.Session(
                root: resolved.root,
                entry: selectedEntry,
                url: url,
                token: token,
                port: endpoint.port,
                leaseID: leaseID
            )
            let server = LocalPreviewServer(session: session, resource: resource)
            policy.authorizePreview(url)
            // The allocation is live from this moment: register it for
            // adjudication BEFORE navigation so the page load can be served.
            serversByLease[leaseID] = server
            staged = (leaseID, server, url, token)
            try verifyStart(operationID: operationID, owner: owner.taskID, cancellation: cancellation)
            let task = try await browser.taskSession(for: owner)
            try verifyStart(operationID: operationID, owner: owner.taskID, cancellation: cancellation)
            priorRecord = records[owner.taskID]
            priorPageURL = URL(string: (await task.technicalAddress) ?? "")
            let command = BrowserCommand(
                sessionID: await task.sessionID,
                action: .navigate(url: url.absoluteString)
            )
            let result = await browser.execute(command, in: owner, cancellation: cancellation)
            try checkCancellation(cancellation)
            // The load is issued before the protocol observes the page. Ok is
            // conclusive; a failed observe is also a real navigation when the
            // task's page already points at this staging allocation.
            let pageURL = URL(string: (await task.technicalAddress) ?? "")
            let navigationIssued = result.status == .ok
                || (pageURL.map { policy.isPreviewAllocation($0, matching: url) } ?? false)
            if navigationIssued {
                navigation = (await task.sessionID, url)
            } else if result.status == .failed || result.status == .timeout {
                // The load may have been issued even though the observe step
                // failed and no URL is visible yet. Treat the page state as
                // unknown instead of claiming the attempt had no effect.
                navigationUncertain = true
            }
            try verifyStart(operationID: operationID, owner: owner.taskID, cancellation: cancellation)
            guard let current = await browser.session(for: owner.taskID),
                  (await current.sessionID) == (await task.sessionID) else {
                throw BrowserPreviewError.validation("This task's browser session changed while the preview was starting")
            }
            guard result.status == .ok else {
                throw BrowserPreviewError.validation(result.message ?? "Preview could not open in the browser")
            }
            // Commit point: no suspension between the fence above and this
            // promotion, so a late start cannot overwrite a newer record.
            let record = PreviewRecord(server: server, leaseID: leaseID, url: url, entry: selectedEntry, relativeRoot: resolved.root.relativeRoot)
            records[owner.taskID] = record
            serversByLease[leaseID] = server
            if let prior = priorRecord, prior.leaseID != leaseID {
                serversByLease.removeValue(forKey: prior.leaseID)
                await stopLease(server: prior.server, leaseID: prior.leaseID, url: prior.url, token: prior.server.session.token)
            }
            if selectedOwner == owner.taskID { activeURL = url }
            endStart(operationID: operationID, owner: owner.taskID)
            return BrowserPreviewOutcome(url: url.absoluteString, entry: selectedEntry, relativeRoot: record.relativeRoot)
        } catch {
            // Clean only the staging created by this attempt. The previous
            // record (this owner's or another owner's) keeps serving until it
            // is explicitly replaced at the commit point above.
            if let staged {
                await stopLease(server: staged.server, leaseID: staged.leaseID, url: staged.url, token: staged.token)
            }
            var restoreFailed = false
            var uncertaintyNote: String?
            if let navigation {
                // A live prior preview is the strongest restore target (its
                // URL is authorized and serving). With no prior preview, the
                // task's own pre-existing page is restored instead; a prior
                // preview that was stopped is never navigated to.
                let restoreURL: URL?
                if let priorRecord {
                    if let liveRecord = records[owner.taskID], liveRecord.leaseID == priorRecord.leaseID {
                        restoreURL = liveRecord.url
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
            endStart(operationID: operationID, owner: owner.taskID)
            if restoreFailed, !isCancellation(error) {
                // This attempt may have changed this owner's page (or may
                // still be loading the stopped staging) and no live prior
                // page could be restored. Say so instead of implying the
                // abandoned start had no effect.
                throw BrowserPreviewError.validation((error.localizedDescription) + (uncertaintyNote ?? ""))
            }
            throw error
        }
    }

    public func reload(owner: BrowserOwnerID, cancellation: CancellationToken? = nil) async throws -> ToolExecutionOutput {
        try checkCancellation(cancellation)
        guard let record = records[owner.taskID] else {
            throw BrowserPreviewError.noPreview
        }
        guard let session = await browser.session(for: owner.taskID) else {
            throw BrowserPreviewError.noBrowser
        }
        // Reload is only a preview reload while this task's own page still
        // shows this owner's staged preview. A page the user navigated away
        // from is not reported as a reloaded preview.
        let pageValue = await session.technicalAddress
        let pageURL = pageValue.flatMap(URL.init(string:))
        guard let pageURL, policy.isPreviewAllocation(pageURL, matching: record.url) else {
            throw BrowserPreviewError.notShowingPreview
        }
        let result = await browser.execute(
            BrowserCommand(sessionID: await session.sessionID, action: .reload),
            in: owner,
            cancellation: cancellation
        )
        try checkCancellation(cancellation)
        // A newer start may have replaced this record while the reload was in
        // flight; its page is not what this call reloaded.
        guard records[owner.taskID]?.leaseID == record.leaseID else {
            throw BrowserPreviewError.replacedWhileReloading
        }
        switch result.status {
        case .ok:
            return ToolExecutionOutput(
                summary: "Preview reloaded at \(record.url.absoluteString)",
                fullOutputSHA256: ""
            )
        case .needsUser:
            // The browser still belongs to the user; the task can continue
            // and retry after control returns. Never report this as success.
            return ToolExecutionOutput(
                summary: "Preview reload needs the user: "
                    + (result.message ?? "The user currently controls this task's browser"),
                fullOutputSHA256: "",
                requiresUserAction: true
            )
        case .stale, .blocked, .timeout, .failed:
            throw BrowserPreviewError.validation(result.message ?? "Preview could not be reloaded")
        }
    }

    public func stop(owner: UUID) async -> ToolExecutionOutput {
        await releaseRecord(for: owner)
        return ToolExecutionOutput(summary: "Preview stopped", fullOutputSHA256: "")
    }

    // MARK: - Explicit UI selection

    /// Binds the file preview surface to one owner (or clears it). This is the
    /// only way `selectedOwner` changes; model calls never select, and a start
    /// for a background owner never moves the selected projection.
    public func select(_ owner: UUID?) {
        selectedOwner = owner
        activeURL = owner.flatMap { records[$0]?.url }
    }

    public func url(for owner: UUID) -> URL? {
        records[owner]?.url
    }

    /// Read-only inspection for qualification and (later) the inspector UI.
    public func isPreviewActive(for owner: UUID) -> Bool {
        records[owner] != nil
    }

    public func activeLeaseID(for owner: UUID) -> UUID? {
        records[owner]?.leaseID
    }

    /// Called (in a Task) by the browser center's owner-release hook when the
    /// task's browser is released: only that owner's preview record stops.
    /// Foreground/background view lifetime alone never calls this.
    public func releasePreview(for owner: UUID) async {
        await releaseRecord(for: owner)
    }

    // MARK: - Start bookkeeping (ported semantics)

    private func beginStart(owner: UUID) throws -> Int {
        guard activeStarts.count < maximumActiveStarts else {
            throw BrowserPreviewError.validation("Too many previews are starting; retry when one finishes")
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

    private func pruneOperationStateIfIdle(_ owner: UUID) {
        guard records[owner] == nil, !activeStarts.values.contains(owner) else { return }
        latestOperationID.removeValue(forKey: owner)
    }

    private func verifyStart(operationID: Int, owner: UUID, cancellation: CancellationToken?) throws {
        try checkCancellation(cancellation)
        guard latestOperationID[owner] == operationID else {
            throw BrowserPreviewError.superseded
        }
    }

    private func checkCancellation(_ cancellation: CancellationToken?) throws {
        if cancellation?.isCancelled == true { throw BrowserPreviewError.cancelled }
        try Task.checkCancellation()
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let preview = error as? BrowserPreviewError, case .cancelled = preview { return true }
        if let floe = error as? FloeError, case .cancelled = floe { return true }
        return false
    }

    /// Restores this owner's own page to its still-live prior preview after an
    /// abandoned navigation. It never touches another task's session and never
    /// rolls back a page that no longer shows this attempt's staging.
    @discardableResult
    private func restoreAbandonedNavigation(
        owner: BrowserOwnerID,
        sessionID: UUID,
        stagedURL: URL,
        restoreURL: URL?
    ) async -> Bool {
        guard let session = await browser.session(for: owner.taskID),
              await session.sessionID == sessionID else { return false }
        // Unknown/absent current URL means this attempt cannot prove its
        // navigation is still the page. Do not roll back anything then.
        let currentURL = (await session.technicalAddress).flatMap(URL.init(string:))
        guard let currentURL,
              policy.isPreviewAllocation(currentURL, matching: stagedURL),
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

    private func releaseRecord(for owner: UUID) async {
        invalidateOwnerOperations(for: owner)
        if let record = records.removeValue(forKey: owner) {
            serversByLease.removeValue(forKey: record.leaseID)
            await stopLease(
                server: record.server,
                leaseID: record.leaseID,
                url: record.url,
                token: record.server.session.token
            )
        }
        pruneOperationStateIfIdle(owner)
        if selectedOwner == owner {
            selectedOwner = nil
            activeURL = nil
        }
    }

    /// Joined teardown: stop adjudication, close the transport (the Kotlin
    /// transport joins its accept thread; no fake detach), then revoke the
    /// navigation grant for the exact allocation.
    private func stopLease(server: LocalPreviewServer, leaseID: UUID, url: URL, token: String) async {
        await server.stop()
        await transport.stop(leaseID: leaseID)
        serversByLease.removeValue(forKey: leaseID)
        if let port = url.port {
            policy.revokePreviewAllocation(port: port, token: token)
        }
    }

    // MARK: - Root/entry resolution (ported rules, native authority)

    private func resolvePreviewRoot(
        base: PreviewWorkspaceRoot,
        relativeRoot: String?,
        entry: String?
    ) async throws -> (root: PreviewWorkspaceRoot, entry: String?) {
        var selectedRoot = base
        var selectedEntry = entry
        if let relativeRoot, !relativeRoot.isEmpty {
            guard !relativeRoot.hasPrefix("/"), !relativeRoot.split(separator: "/").contains("..") else {
                throw BrowserPreviewError.validation("Preview root must be a safe workspace-relative path")
            }
            let candidate = PreviewWorkspaceRoot(owner: base.owner, relativeRoot: relativeRoot)
            let isDir = (try? await resource.isDirectory(candidate, relativePath: ".")) ?? false
            if !isDir {
                // The model passed a file (commonly the entry page) as root:
                // serve its directory and use the file as the entry.
                let lastSegment = (relativeRoot as NSString).lastPathComponent
                let parent = (relativeRoot as NSString).deletingLastPathComponent
                selectedRoot = PreviewWorkspaceRoot(
                    owner: base.owner,
                    relativeRoot: parent.isEmpty ? "." : parent
                )
                selectedEntry = lastSegment
            } else {
                selectedRoot = candidate
            }
        }
        return (selectedRoot, selectedEntry)
    }

    /// Candidate order and convenience rules ported verbatim from the iOS
    /// original (`resolveEntry`), evaluated against the native resource port.
    func resolveEntry(root: PreviewWorkspaceRoot, requested: String?) async throws -> String {
        let candidates = [requested, "index.html", "index.htm", "public/index.html", "dist/index.html", "build/index.html"]
            .compactMap { $0 }
        for candidate in candidates {
            guard !candidate.isEmpty,
                  !candidate.split(separator: "/").contains(".."),
                  !candidate.hasPrefix("/") else { continue }
            let exists = (try? await resource.stat(root, relativePath: candidate)) ?? nil
            let isDir = (try? await resource.isDirectory(root, relativePath: candidate)) ?? true
            if exists != nil, !isDir {
                return candidate
            }
        }
        // Convenience for the common flat-site case: serve the only HTML file
        // instead of failing with an opaque error.
        let listing = (try? await resource.listing(root, relativePath: ".")) ?? []
        let htmls = listing
            .filter { ["html", "htm"].contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted()
        if htmls.count == 1, let only = htmls.first {
            return only
        }
        if !htmls.isEmpty {
            throw BrowserPreviewError.validation(
                "No preview entry file was found in '\(root.relativeRoot)'; pass entry explicitly. HTML candidates: \(htmls.prefix(12).joined(separator: ", "))"
            )
        }
        throw BrowserPreviewError.validation(
            "No preview entry file was found in '\(root.relativeRoot)'; create an index.html or pass entry. The entry is relative to the served directory."
        )
    }
}
