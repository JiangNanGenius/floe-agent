// SPDX-License-Identifier: MPL-2.0
//
// GitHubActionsJobEngine — the app-owned lifecycle coordinator for IDE GitHub
// Actions runs. It is deliberately Foundation-only (no UIKit, no SwiftUI and no
// FloeCore/FloeWorkspace imports) so the exact production state machine can be
// compiled and driven by flat harnesses and Swift Testing with injected
// clients, store, credential provider and clock.
//
// It owns the durable, honest parts the UI must never fake:
// * a single scheduler with an explicit foreground flag and a monotonically
//   increasing generation, so a cancelled poll can never clear a newer one and
//   a foreground refresh can never restart polling after the app backgrounds;
// * per-record refresh de-duplication plus merge-safe saves, so a poll, cancel
//   or artifact download cannot overwrite a newer cancellation intent or
//   artifact metadata with a stale snapshot;
// * cancellation intent persisted BEFORE any network request, re-sent after a
//   run id is finally associated, and retried until GitHub reports the run
//   cancelled (an HTTP 202 is never treated as a finished stop);
// * observation change detection, so an hour-long unchanged run backs off to a
//   bounded poll interval instead of being queried every 5 seconds;
// * transport/credential/store failures surfaced to the caller instead of
//   being silently swallowed, including corrupt persisted records.
//
// The engine stores no credential and never logs one. The bearer token is
// fetched per operation through `GitHubActionsTokenProviding`.

import Foundation

// MARK: - Abstract remote observation

/// A remote run observation, independent of the FloeGit wire model so the
/// state machine has no module dependency and can be driven by fixtures.
struct GitHubActionsRemoteRun: Sendable, Equatable {
    var id: Int64
    var status: String
    var conclusion: String?
    var htmlURL: String?

    var isTerminal: Bool { status == "completed" || conclusion != nil }

    /// A completed run's terminal Floe state.
    var terminalState: GitHubActionsJobState {
        if conclusion == "success" { return .completed }
        if conclusion == "cancelled" { return .cancelled }
        return .failed
    }
}

struct GitHubActionsRemoteArtifact: Sendable, Equatable {
    var id: Int64
    var name: String
    var sizeInBytes: Int64
    var expired: Bool
    var createdAt: Date
    var expiresAt: Date?
    /// API-attested content digest (`sha256:<hex>`) when GitHub returns one.
    /// Absent means the download is checksum-only, not verified.
    var digest: String? = nil
}

struct GitHubActionsRemoteArtifactBytes: Sendable {
    var data: Data
    var suggestedFileName: String
}

struct GitHubActionsRemoteBaseline: Sendable, Equatable {
    var runIDs: [Int64]
    var capturedAt: Date
}

struct GitHubActionsRemoteTrigger: Sendable, Equatable {
    var runID: Int64?
    var htmlURL: String?
}

/// A remote snapshot publication result: the git-data commit/tree that carries
/// exactly the reviewed files.
struct GitHubActionsPublishedSnapshot: Sendable, Equatable {
    var commitSHA: String
    var treeSHA: String
}

// MARK: - Typed engine failures

/// Transport-neutral error the engine can reason about without importing the
/// FloeGit error type. The app adapter maps `GitHubActionsError` onto it and a
/// test fake can throw it directly.
enum GitHubActionsEngineError: Error, Equatable, Sendable, LocalizedError {
    case transport(String)
    case http(status: Int, message: String)
    case rateLimited
    case notFound
    case ambiguous([Int64])
    case unresolved(String)
    case invalidConfiguration(String)
    case store(String)
    case responseTooLarge(limit: Int)
    case artifactDestination(String)

    var errorDescription: String? {
        switch self {
        case .transport(let detail): return "GitHub Actions network error: \(detail)"
        case .http(let status, let message): return "GitHub Actions request failed (\(status)): \(message)"
        case .rateLimited: return "GitHub Actions rate limit reached"
        case .notFound: return "GitHub Actions resource was not found"
        case .ambiguous(let ids): return "Multiple GitHub Actions runs matched (\(ids.map(String.init).joined(separator: ", ")))"
        case .unresolved(let detail): return detail
        case .invalidConfiguration(let detail): return detail
        case .store(let detail): return "The local run store failed: \(detail)"
        case .responseTooLarge(let limit): return "GitHub Actions response exceeded the \(limit) byte limit"
        case .artifactDestination(let detail): return detail
        }
    }

    var isRateLimited: Bool { self == .rateLimited }
}

// MARK: - Injected seams

protocol GitHubActionsRemoteClient: Sendable {
    func queryRun(owner: String, repository: String, runID: Int64, token: String) async throws -> GitHubActionsRemoteRun
    func associateRun(
        owner: String, repository: String, workflowID: Int64, ref: String, headSHA: String,
        dispatchedAt: Date, baselineRunIDs: [Int64], returnedRunID: Int64?,
        token: String, maxAttempts: Int, pollInterval: TimeInterval
    ) async throws -> GitHubActionsRemoteRun
    func cancelRun(owner: String, repository: String, runID: Int64, token: String) async throws
    func artifacts(owner: String, repository: String, runID: Int64, token: String) async throws -> [GitHubActionsRemoteArtifact]
    func downloadArtifact(
        owner: String, repository: String, runID: Int64, artifactID: Int64,
        name: String, sizeInBytes: Int64, archiveURL: URL, token: String
    ) async throws -> GitHubActionsRemoteArtifactBytes
    func dispatchBaseline(
        owner: String, repository: String, workflowID: Int64, branch: String, token: String
    ) async throws -> GitHubActionsRemoteBaseline
    func triggerDispatch(
        owner: String, repository: String, workflowID: Int64, ref: String,
        inputs: [String: String], token: String
    ) async throws -> GitHubActionsRemoteTrigger
}

protocol GitHubActionsJobStoring: Sendable {
    func load() async throws -> GitHubActionsStoreLoad
    func record(id: UUID) async throws -> GitHubActionsJobRecord?
    func record(requestID: String) async throws -> GitHubActionsJobRecord?
    /// Merge-safe save: the store preserves a newer cancellation intent and
    /// artifact download metadata that the caller's snapshot does not carry.
    func save(_ record: GitHubActionsJobRecord) async throws
}

protocol GitHubActionsTokenProviding: Sendable {
    func token() async throws -> String?
}

protocol GitHubActionsClock: Sendable {
    func now() -> Date
    func sleep(seconds: TimeInterval) async throws
}

struct SystemGitHubActionsClock: GitHubActionsClock {
    func now() -> Date { Date() }
    func sleep(seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }
}

/// Everything the engine needs. All callbacks are `@Sendable`; the app adapter
/// hops to `@MainActor` for publishing and redacts before surfacing an error.
struct GitHubActionsEngineDependencies: Sendable {
    let remote: any GitHubActionsRemoteClient
    let store: any GitHubActionsJobStoring
    let credentials: any GitHubActionsTokenProviding
    let clock: any GitHubActionsClock
    let digest: @Sendable (Data) -> String
    let redact: @Sendable (String) -> String
    /// Commits verified artifact bytes below the workspace. Returns the
    /// workspace-relative path that was written.
    let commitArtifact: @Sendable (Data, String, Bool, URL) async throws -> String
    /// Publishes one record so the UI can render it immediately.
    let publish: @Sendable (GitHubActionsJobRecord) async -> Void
    /// Publishes a full recovered list (launch / foreground).
    let publishAll: @Sendable ([GitHubActionsJobRecord]) async -> Void
    /// Surfaces a user-visible message; nil clears it.
    let reportError: @Sendable (String?) async -> Void
}

/// Resolves a registered workflow path to its numeric id on the default branch.
typealias GitHubActionsWorkflowResolver =
    @Sendable (_ owner: String, _ repository: String, _ path: String, _ token: String) async throws -> Int64?

/// Publishes the reviewed snapshot as a commit on the run-owned branch.
typealias GitHubActionsSnapshotPublisher =
    @Sendable (_ record: GitHubActionsJobRecord, _ token: String) async throws -> GitHubActionsPublishedSnapshot

// MARK: - Engine

actor GitHubActionsJobEngine {
    private let dependencies: GitHubActionsEngineDependencies

    /// Bounded dispatch association wait.
    private let associationAttempts: Int
    private let associationInterval: TimeInterval
    /// Maximum records refreshed at once.
    private let maximumConcurrentRefreshes: Int
    /// A cancel is re-sent no more often than this until the run is terminal.
    private let cancelRetryInterval: TimeInterval
    private let initialBackoff: TimeInterval
    private let maximumIdleBackoff: TimeInterval
    private let maximumRateLimitedBackoff: TimeInterval

    /// Monotonic scheduler ownership. Every pause/foreground transition bumps
    /// it, and a task only clears `pollTask` when its generation still matches.
    private var generation = 0
    private var isForeground = false
    private var activeSceneIDs: Set<String> = []
    private var pollTask: Task<Void, Never>?
    private var recoverTask: Task<Void, Never>?
    private var refreshing: Set<UUID> = []
    private var cachedRecords: [GitHubActionsJobRecord] = []

    init(
        dependencies: GitHubActionsEngineDependencies,
        associationAttempts: Int = 8,
        associationInterval: TimeInterval = 4,
        maximumConcurrentRefreshes: Int = 3,
        cancelRetryInterval: TimeInterval = 30,
        initialBackoff: TimeInterval = 5,
        maximumIdleBackoff: TimeInterval = 60,
        maximumRateLimitedBackoff: TimeInterval = 300
    ) {
        self.dependencies = dependencies
        self.associationAttempts = max(associationAttempts, 1)
        self.associationInterval = max(associationInterval, 0)
        self.maximumConcurrentRefreshes = max(maximumConcurrentRefreshes, 1)
        self.cancelRetryInterval = max(cancelRetryInterval, 0)
        self.initialBackoff = max(initialBackoff, 1)
        self.maximumIdleBackoff = max(maximumIdleBackoff, self.initialBackoff)
        self.maximumRateLimitedBackoff = max(maximumRateLimitedBackoff, self.maximumIdleBackoff)
    }

    // MARK: Recovery

    /// Loads every durable record, surfaces corrupt files, and returns the
    /// list. Never swallows a store failure.
    @discardableResult
    func recover() async -> [GitHubActionsJobRecord] {
        do {
            let load = try await dependencies.store.load()
            cachedRecords = load.records
            await dependencies.publishAll(load.records)
            if load.corruptFiles.isEmpty {
                await dependencies.reportError(nil)
            } else {
                await dependencies.reportError(
                    dependencies.redact(
                        "\(load.corruptFiles.count) run record(s) could not be read and were left untouched: "
                        + load.corruptFiles.joined(separator: ", ")
                    )
                )
            }
            return load.records
        } catch {
            await dependencies.reportError(dependencies.redact(error.localizedDescription))
            return cachedRecords
        }
    }

    func cachedRecord(id: UUID) -> GitHubActionsJobRecord? {
        cachedRecords.first { $0.id == id }
    }

    func allCachedRecords() -> [GitHubActionsJobRecord] { cachedRecords }

    // MARK: Scene lifecycle (multi-window aware)

    /// Records a scene becoming active. Polling starts only when the active
    /// scene set transitions from empty to non-empty.
    func sceneDidActivate(id: String) {
        let wasEmpty = activeSceneIDs.isEmpty
        activeSceneIDs.insert(id)
        guard wasEmpty else { return }
        isForeground = true
        generation &+= 1
        let scheduledGeneration = generation
        recoverTask?.cancel()
        recoverTask = Task { [weak self] in
            await self?.recoverAndRefresh(generation: scheduledGeneration)
        }
    }

    /// Records a scene leaving the foreground (inactive/background). Polling
    /// pauses only when no scene remains active, so one iPad window going
    /// inactive never stops a run owned by another active window.
    func sceneDidDeactivate(id: String) {
        activeSceneIDs.remove(id)
        guard activeSceneIDs.isEmpty else { return }
        pausePolling()
    }

    /// A window closed entirely.
    func sceneDidDisappear(id: String) {
        sceneDidDeactivate(id: id)
    }

    func activeSceneCount() -> Int { activeSceneIDs.count }

    func foreground() -> Bool { isForeground }

    func currentGeneration() -> Int { generation }

    func isSchedulerRunning() -> Bool { pollTask != nil }

    /// Launch/foreground recovery: load all records, refresh every live one
    /// once, then start the bounded scheduler — but only if this generation is
    /// still the current foreground generation.
    func recoverAndRefresh(generation scheduledGeneration: Int? = nil) async {
        let expected = scheduledGeneration ?? generation
        await recover()
        guard expected == generation, isForeground else { return }
        let ids = cachedRecords.filter { !$0.state.isTerminal && IDEGitHubActionsReconciler.hasActionableStep($0) }.map(\.id)
        _ = await refresh(ids: ids, expectedGeneration: expected, reason: .automatic)
        guard expected == generation, isForeground else { return }
        startScheduler(generation: expected)
    }

    /// Stops the local poller. The remote run is unaffected; the next
    /// foreground transition re-queries it. Cancelling does not clear a newer
    /// task: the generation guard handles that.
    func pausePolling() {
        generation &+= 1
        isForeground = false
        recoverTask?.cancel()
        recoverTask = nil
        pollTask?.cancel()
        pollTask = nil
    }

    private func startScheduler(generation scheduledGeneration: Int) {
        guard isForeground, scheduledGeneration == generation, pollTask == nil else { return }
        pollTask = Task { [weak self] in
            await self?.runScheduler(generation: scheduledGeneration)
        }
    }

    private func runScheduler(generation scheduledGeneration: Int) async {
        var backoff = initialBackoff
        while !Task.isCancelled {
            guard scheduledGeneration == generation, isForeground else { break }
            let live = await liveRecords()
            if live.isEmpty { break }
            let outcome = await refresh(ids: live.map(\.id), expectedGeneration: scheduledGeneration, reason: .automatic)
            guard scheduledGeneration == generation, isForeground else { break }
            let interval: TimeInterval
            switch outcome {
            case .rateLimited:
                backoff = min(max(backoff, 30) * 2, maximumRateLimitedBackoff)
                interval = backoff
            case .progressed:
                backoff = initialBackoff
                interval = backoff
            case .failed:
                backoff = min(max(backoff, 10) * 1.5, maximumIdleBackoff)
                interval = backoff
            case .idle:
                // Doubling (5, 10, 20, 40, 60) keeps an unchanged hour-long run
                // from being queried every 5 seconds.
                interval = backoff
                backoff = min(backoff * 2, maximumIdleBackoff)
            }
            guard scheduledGeneration == generation, isForeground, !Task.isCancelled else { break }
            do {
                try await dependencies.clock.sleep(seconds: interval)
            } catch {
                break
            }
        }
        if scheduledGeneration == generation {
            pollTask = nil
        }
    }

    private func liveRecords() async -> [GitHubActionsJobRecord] {
        do {
            let load = try await dependencies.store.load()
            cachedRecords = load.records
            return load.records.filter { !$0.state.isTerminal && IDEGitHubActionsReconciler.hasActionableStep($0) }
        } catch {
            await dependencies.reportError(dependencies.redact(error.localizedDescription))
            return []
        }
    }

    // MARK: Refresh

    enum RefreshReason: Sendable { case automatic, explicit }
    enum RefreshOutcome: Sendable, Equatable { case idle, progressed, rateLimited, failed }

    private func loadRecord(id: UUID) async throws -> GitHubActionsJobRecord? {
        let record = try await dependencies.store.record(id: id)
        if let record {
            if let index = cachedRecords.firstIndex(where: { $0.id == id }) {
                cachedRecords[index] = record
            } else {
                cachedRecords.insert(record, at: 0)
            }
        }
        return record
    }

    private func saveAndPublish(_ record: GitHubActionsJobRecord) async throws {
        try await dependencies.store.save(record)
        if let saved = try await dependencies.store.record(id: record.id) {
            if let index = cachedRecords.firstIndex(where: { $0.id == saved.id }) {
                cachedRecords[index] = saved
            } else {
                cachedRecords.insert(saved, at: 0)
            }
            await dependencies.publish(saved)
        } else {
            await dependencies.publish(record)
        }
    }

    /// Refreshes the given records with bounded concurrency. A record already
    /// being refreshed by another caller is skipped rather than raced.
    @discardableResult
    func refresh(ids: [UUID], expectedGeneration: Int? = nil, reason: RefreshReason = .explicit) async -> RefreshOutcome {
        guard !ids.isEmpty else { return .idle }
        var outcome: RefreshOutcome = .idle
        await withTaskGroup(of: RefreshOutcome.self) { group in
            var iterator = ids.makeIterator()
            let window = min(maximumConcurrentRefreshes, ids.count)
            for _ in 0..<window {
                guard let id = iterator.next() else { break }
                group.addTask { [weak self] in
                    guard let self else { return .idle }
                    return await self.refreshOne(id: id, expectedGeneration: expectedGeneration, reason: reason)
                }
            }
            while let result = await group.next() {
                switch result {
                case .rateLimited: outcome = .rateLimited
                case .progressed where outcome != .rateLimited: outcome = .progressed
                case .failed where outcome == .idle: outcome = .failed
                default: break
                }
                if let id = iterator.next() {
                    group.addTask { [weak self] in
                        guard let self else { return .idle }
                        return await self.refreshOne(id: id, expectedGeneration: expectedGeneration, reason: reason)
                    }
                }
            }
        }
        return outcome
    }

    @discardableResult
    func refreshOne(id: UUID, expectedGeneration: Int? = nil, reason: RefreshReason = .explicit) async -> RefreshOutcome {
        guard !refreshing.contains(id) else { return .idle }
        refreshing.insert(id)
        defer { refreshing.remove(id) }
        do {
            guard var record = try await loadRecord(id: id) else { return .idle }
            guard let token = try await dependencies.credentials.token() else {
                await dependencies.reportError(
                    "Connect GitHub in Settings to refresh this cloud run."
                )
                return .failed
            }
            var progressed = false
            var cancelSent = false
            for action in IDEGitHubActionsReconciler.actions(for: record) {
                switch action {
                case .queryKnownRun(let runID):
                    let run = try await dependencies.remote.queryRun(
                        owner: record.owner, repository: record.repository, runID: runID, token: token
                    )
                    let changed = apply(run, to: &record)
                    progressed = progressed || changed
                    // A queued cancel is re-sent until GitHub confirms it.
                    if record.cancelRequestedAt != nil, !run.isTerminal {
                        cancelSent = await sendCancelIfDue(record: &record, token: token, force: reason == .explicit) || cancelSent
                    }
                case .reAssociateSnapshot(let commitSHA):
                    guard let workflowID = record.workflowID,
                          let dispatchedAt = record.dispatchedAt else { continue }
                    let run = try await dependencies.remote.associateRun(
                        owner: record.owner, repository: record.repository,
                        workflowID: workflowID, ref: record.runBranch, headSHA: commitSHA,
                        dispatchedAt: dispatchedAt, baselineRunIDs: record.baselineRunIDs,
                        returnedRunID: record.runID, token: token,
                        maxAttempts: 1, pollInterval: 0
                    )
                    record.lastError = nil
                    let changed = apply(run, to: &record)
                    progressed = progressed || changed
                    // The run was only just found: a cancel that was queued
                    // while the run id was unknown must be sent now.
                    if record.cancelRequestedAt != nil, !run.isTerminal {
                        cancelSent = await sendCancelIfDue(record: &record, token: token, force: true) || cancelSent
                    }
                case .awaitingManualRedispatch:
                    continue
                case .resumeArtifactDownload:
                    // Artifact bytes are fetched on explicit user action so a
                    // large download never starts without consent.
                    continue
                }
            }
            if progressed || cancelSent {
                try await saveAndPublish(record)
            }
            if cancelSent { progressed = true }
            return progressed ? .progressed : .idle
        } catch {
            if let engineError = error as? GitHubActionsEngineError {
                if engineError.isRateLimited { return .rateLimited }
                await dependencies.reportError(dependencies.redact(engineError.localizedDescription))
            } else {
                await dependencies.reportError(dependencies.redact(error.localizedDescription))
            }
            return .failed
        }
    }

    /// Applies a run observation and reports whether anything materially
    /// changed. An unchanged observation must not reset the poll backoff.
    ///
    /// A successful remote observation is proof the run is reachable, so a
    /// recovered association/network diagnostic is cleared instead of being
    /// left to look current. `lastError` is part of the compared observation so
    /// a clear-only change is persisted; it becomes a no-op on the next poll,
    /// which is what keeps a stale-diagnostic clear from resetting backoff
    /// forever. While a cancel is pending on a non-terminal run the cancel path
    /// owns the in-flight status note, and that branch is left untouched.
    private func apply(_ run: GitHubActionsRemoteRun, to record: inout GitHubActionsJobRecord) -> Bool {
        let before = Observation(
            runID: record.runID, status: record.remoteStatus,
            conclusion: record.remoteConclusion, state: record.state, html: record.remoteHTMLURL,
            lastError: record.lastError
        )
        record.runID = run.id
        record.remoteStatus = run.status
        record.remoteConclusion = run.conclusion
        record.remoteHTMLURL = run.htmlURL
        if run.isTerminal {
            record.state = run.terminalState
            record.lastError = nil
        } else if record.cancelRequestedAt != nil {
            // Keep the honest `.cancelling` state until GitHub finalizes. The
            // cancel path owns the in-flight status message, so leave it alone.
            record.state = .cancelling
        } else if run.status == "in_progress" {
            record.state = .running
            record.lastError = nil
        } else {
            record.state = .queued
            record.lastError = nil
        }
        let after = Observation(
            runID: record.runID, status: record.remoteStatus,
            conclusion: record.remoteConclusion, state: record.state, html: record.remoteHTMLURL,
            lastError: record.lastError
        )
        return before != after
    }

    private struct Observation: Equatable {
        let runID: Int64?
        let status: String?
        let conclusion: String?
        let state: GitHubActionsJobState
        let html: String?
        let lastError: String?
    }

    // MARK: Cancellation

    /// Persists the cancellation intent BEFORE any network request, then sends
    /// it when a run id is known. When the run id is not yet known the intent
    /// stays durable and the refresh/reconcile path sends it as soon as the run
    /// is associated.
    func cancel(recordID: UUID) async {
        do {
            guard var record = try await loadRecord(id: recordID) else { return }
            if record.cancelRequestedAt == nil {
                record.cancelRequestedAt = dependencies.clock.now()
            }
            record.state = .cancelling
            // Durable first: a crash or a failed request must not lose the stop.
            try await saveAndPublish(record)
            guard let token = try await dependencies.credentials.token() else {
                await dependencies.reportError("Connect GitHub in Settings to cancel this run.")
                return
            }
            guard record.runID != nil else {
                await dependencies.reportError("Cancel requested. Floe will send it as soon as the run is associated.")
                return
            }
            _ = await sendCancelIfDue(record: &record, token: token, force: true)
            try await saveAndPublish(record)
        } catch {
            await dependencies.reportError(dependencies.redact(error.localizedDescription))
        }
    }

    /// Re-sends a persisted cancel until the run is terminal. Returns true when
    /// a request was actually made this pass. Repeat-safe: the intent and the
    /// last-attempt time are durable, so a relaunch resumes the same stop.
    private func sendCancelIfDue(
        record: inout GitHubActionsJobRecord, token: String, force: Bool
    ) async -> Bool {
        guard let runID = record.runID else { return false }
        let now = dependencies.clock.now()
        if !force, let last = record.cancelLastAttemptAt,
           now.timeIntervalSince(last) < cancelRetryInterval {
            return false
        }
        record.cancelLastAttemptAt = now
        do {
            try await dependencies.remote.cancelRun(
                owner: record.owner, repository: record.repository, runID: runID, token: token
            )
            record.state = .cancelling
            record.lastError = "Cancel requested; GitHub finalizes the run asynchronously."
            return true
        } catch let error as GitHubActionsEngineError {
            if case .http(let status, _) = error, status == 409 || status == 422 {
                // Already cancelling/finished: the intent is satisfied.
                record.state = .cancelling
                record.lastError = nil
                return true
            }
            if error == .notFound {
                // The run is gone; treat as cancelled without inventing a run.
                record.state = .cancelled
                record.lastError = nil
                return true
            }
            record.lastError = dependencies.redact(error.localizedDescription)
            await dependencies.reportError(record.lastError)
            return true
        } catch {
            record.lastError = dependencies.redact(error.localizedDescription)
            await dependencies.reportError(record.lastError)
            return true
        }
    }

    // MARK: Dispatch

    /// Publishes the snapshot and dispatches exactly once per `requestID`.
    /// `publishSnapshot` supplies the commit/tree; `resolveWorkflow` resolves
    /// the registered numeric id. A lost dispatch response leaves the record
    /// `.associationPending` with the snapshot identity and baseline persisted,
    /// so a relaunch re-associates instead of dispatching a duplicate.
    @discardableResult
    func dispatch(
        draft: GitHubActionsJobRecord,
        workflowPath: String,
        inputs: [String: String],
        injectSnapshotInput: Bool,
        resolveWorkflow: GitHubActionsWorkflowResolver,
        publishSnapshot: GitHubActionsSnapshotPublisher
    ) async -> GitHubActionsJobRecord? {
        do {
            if let existing = try await dependencies.store.record(requestID: draft.requestID) {
                await dependencies.publish(existing)
                return existing
            }
            guard let token = try await dependencies.credentials.token() else {
                throw GitHubActionsEngineError.invalidConfiguration("Connect GitHub in Settings first.")
            }
            var record = draft
            // Persist the intent before any network call.
            try await saveAndPublish(record)

            guard let workflowID = try await resolveWorkflow(record.owner, record.repository, workflowPath, token) else {
                throw GitHubActionsEngineError.invalidConfiguration(
                    "GitHub has no registered workflow at \(workflowPath). workflow_dispatch workflows must exist on the default branch."
                )
            }
            record.workflowID = workflowID
            try await saveAndPublish(record)

            let snapshot = try await publishSnapshot(record, token)
            record.snapshotCommitSHA = snapshot.commitSHA
            record.snapshotTreeSHA = snapshot.treeSHA
            record.state = .snapshotPublished
            try await saveAndPublish(record)

            // Baseline BEFORE the trigger so a crash is reconcilable.
            let baseline = try await dependencies.remote.dispatchBaseline(
                owner: record.owner, repository: record.repository,
                workflowID: workflowID, branch: record.runBranch, token: token
            )
            record.baselineRunIDs = baseline.runIDs.sorted()
            record.dispatchedAt = baseline.capturedAt
            record.remoteStatus = "queued"
            record.state = .dispatching
            try await saveAndPublish(record)

            var resolvedInputs = inputs
            if injectSnapshotInput { resolvedInputs["snapshot_sha"] = snapshot.commitSHA }
            let trigger: GitHubActionsRemoteTrigger
            do {
                trigger = try await dependencies.remote.triggerDispatch(
                    owner: record.owner, repository: record.repository,
                    workflowID: workflowID, ref: record.runBranch, inputs: resolvedInputs, token: token
                )
            } catch {
                // The trigger may or may not have landed. Keep the snapshot and
                // baseline so recovery re-associates by identity; never auto-
                // dispatch again for this request.
                record.state = .associationPending
                record.lastError = dependencies.redact(error.localizedDescription)
                try? await saveAndPublish(record)
                // A new dispatch must (re)start the single scheduler while the
                // app is in the foreground, even if launch started with no
                // actionable jobs.
                if isForeground { startScheduler(generation: generation) }
                return record
            }
            record.runID = trigger.runID
            record.remoteHTMLURL = trigger.htmlURL
            try await saveAndPublish(record)

            await associate(record: &record, workflowID: workflowID, token: token, attempts: associationAttempts)
            if record.cancelRequestedAt != nil, record.runID != nil,
               record.state != .completed, record.state != .failed, record.state != .cancelled {
                _ = await sendCancelIfDue(record: &record, token: token, force: true)
            }
            try await saveAndPublish(record)
            if isForeground { startScheduler(generation: generation) }
            return record
        } catch {
            await dependencies.reportError(dependencies.redact(error.localizedDescription))
            return nil
        }
    }

    private func associate(
        record: inout GitHubActionsJobRecord, workflowID: Int64, token: String, attempts: Int
    ) async {
        guard let commitSHA = record.snapshotCommitSHA, let dispatchedAt = record.dispatchedAt else { return }
        do {
            let run = try await dependencies.remote.associateRun(
                owner: record.owner, repository: record.repository,
                workflowID: workflowID, ref: record.runBranch, headSHA: commitSHA,
                dispatchedAt: dispatchedAt, baselineRunIDs: record.baselineRunIDs,
                returnedRunID: record.runID, token: token,
                maxAttempts: attempts, pollInterval: associationInterval
            )
            _ = apply(run, to: &record)
            record.lastError = nil
        } catch {
            record.state = .associationPending
            record.lastError = dependencies.redact(error.localizedDescription)
        }
    }

    // MARK: Artifacts

    func loadArtifacts(recordID: UUID) async {
        do {
            guard var record = try await loadRecord(id: recordID),
                  let runID = record.runID,
                  let token = try await dependencies.credentials.token() else { return }
            let artifacts = try await dependencies.remote.artifacts(
                owner: record.owner, repository: record.repository, runID: runID, token: token
            )
            // The store's merge-safe save preserves any download metadata that
            // a concurrent download wrote while this list was in flight.
            record.artifacts = artifacts.map { artifact in
                let existing = record.artifacts.first { $0.id == artifact.id }
                return GitHubActionsArtifactRecord(
                    id: artifact.id, name: artifact.name, sizeInBytes: artifact.sizeInBytes,
                    expired: artifact.expired, createdAt: artifact.createdAt, expiresAt: artifact.expiresAt,
                    downloadedSHA256: existing?.downloadedSHA256,
                    downloadedRelativePath: existing?.downloadedRelativePath,
                    remoteDigest: artifact.digest ?? existing?.remoteDigest,
                    downloadVerified: existing?.downloadVerified
                )
            }
            try await saveAndPublish(record)
        } catch {
            await dependencies.reportError(dependencies.redact(error.localizedDescription))
        }
    }

    @discardableResult
    func downloadArtifact(
        recordID: UUID, artifactID: Int64, workspaceRunID: Int64,
        workspaceRoot: URL, overwrite: Bool
    ) async -> GitHubActionsArtifactRecord? {
        do {
            guard var record = try await loadRecord(id: recordID),
                  let token = try await dependencies.credentials.token(),
                  let artifact = record.artifacts.first(where: { $0.id == artifactID }) else { return nil }
            let archiveURL = URL(
                string: "https://api.github.com/repos/\(record.owner)/\(record.repository)/actions/artifacts/\(artifact.id)/zip"
            )
            guard let archiveURL else {
                throw GitHubActionsEngineError.invalidConfiguration("invalid artifact URL")
            }
            let downloaded = try await dependencies.remote.downloadArtifact(
                owner: record.owner, repository: record.repository,
                runID: workspaceRunID, artifactID: artifact.id,
                name: artifact.name, sizeInBytes: artifact.sizeInBytes,
                archiveURL: archiveURL, token: token
            )
            let digest = dependencies.digest(downloaded.data)
            // Verify against the API-attested digest BEFORE committing. A local
            // self-hash alone is checksum-only and must never be presented as
            // verified integrity. A mismatch discards the bytes and leaves any
            // previously committed file untouched.
            let expected = IDEGitHubActionsArtifactPolicy.normalizedSHA256(artifact.remoteDigest)
            if let expected,
               !IDEGitHubActionsArtifactPolicy.verify(
                   data: downloaded.data, expectedSHA256: expected,
                   sha256: { dependencies.digest($0) }
               ) {
                throw GitHubActionsEngineError.invalidConfiguration(
                    "Downloaded artifact \(artifact.id) did not match GitHub's digest; the file was discarded."
                )
            }
            let destination = IDEGitHubActionsArtifactPolicy.destination(
                runID: workspaceRunID,
                suggestedFileName: downloaded.suggestedFileName,
                overwrite: overwrite
            )
            guard IDEGitHubActionsArtifactPolicy.isSafeDestination(destination.relativePath) else {
                throw GitHubActionsEngineError.artifactDestination("artifact destination is outside the workspace")
            }
            let committedPath = try await dependencies.commitArtifact(
                downloaded.data, destination.relativePath, overwrite, workspaceRoot
            )
            guard let index = record.artifacts.firstIndex(where: { $0.id == artifactID }) else { return nil }
            record.artifacts[index].downloadedSHA256 = digest
            record.artifacts[index].downloadedRelativePath = committedPath
            record.artifacts[index].remoteDigest = artifact.remoteDigest
            record.artifacts[index].downloadVerified = expected != nil
            try await saveAndPublish(record)
            return record.artifacts[index]
        } catch {
            await dependencies.reportError(dependencies.redact(error.localizedDescription))
            return nil
        }
    }

    // MARK: Queries

    func record(id: UUID) -> GitHubActionsJobRecord? {
        cachedRecords.first { $0.id == id }
    }

    func records(workspaceID: UUID) -> [GitHubActionsJobRecord] {
        cachedRecords.filter { $0.workspaceID == workspaceID }
    }
}
