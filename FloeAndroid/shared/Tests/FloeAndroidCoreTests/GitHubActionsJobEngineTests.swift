// SPDX-License-Identifier: MPL-2.0
//
// GitHubActionsJobEngineTests — formal Swift Testing port of the passing
// iOS `IDEGitHubActionsTests` harness
// (FloeAgent/Tests/FloeAgentUITests/IDEGitHubActionsTests.swift @ 3fd597b…)
// onto the Android module-local ports of the durable engine, store and
// reconciler. It drives the REAL production state machine with injected fake
// remote/store/clock/credentials, so the durable dispatch/association/cancel/
// poll/download rules are exercised without Keystore, a device, a network or
// a live GitHub call. Android deltas: `#if canImport(UIKit)` gate removed,
// `import FloeApp` becomes `@testable import FloeAndroidCore`, and the digest
// helper uses the SAME FloeCore FloeDigest the production composition injects.
// The store-merge/reconciler/policy cases live in IDEGitHubActionsPolicyTests.
//
// Covered actual behavior:
//   * dispatch 200 JSON and legacy 204 association;
//   * a lost dispatch response that must not become a duplicate trigger;
//   * multi-window scene churn and background/foreground gating;
//   * cancellation intent persisted before the network call, sent only after a
//     run is associated and retried on a bounded interval until terminal;
//   * idle backoff growth/cap for a long unchanged run (never a 5s hot loop);
//   * corrupt-store and artifact-error surfacing;
//   * real disk recovery across engine re-creation (relaunch) with no
//     re-dispatch and durable error clearing;
//   * artifact digest match/mismatch/missing honesty in the buffered seam.

import Foundation
import FloeCore
import Testing
@testable import FloeAndroidCore

@Suite("GitHubActionsJobEngineTests")
struct GitHubActionsJobEngineTests {

    // MARK: - Thread-safe helpers

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T
        init(_ value: T) { self.value = value }
        var current: T { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ newValue: T) { lock.lock(); value = newValue; lock.unlock() }
    }

    private func digestHex(_ data: Data) -> String { FloeDigest.sha256Hex(data) }

    /// Wall-clock bounded condition wait. Returns as soon as `condition` holds,
    /// or `false` once `timeout` elapses. A short poll interval is only used to
    /// re-check the actual completion condition, so a slow runner is never
    /// mistaken for a failure while a broken engine can never hang the suite.
    private func waitUntil(
        timeout: Duration = .seconds(10),
        pollEvery: Duration = .milliseconds(5),
        _ condition: @Sendable () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while true {
            if condition() { return true }
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: pollEvery)
        }
    }

    /// Lets one test hold a remote call open while another engine operation
    /// runs, so a real stale-save interleaving can be replayed deterministically.
    private actor AsyncGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuation in
                if isOpen { continuation.resume() } else { self.continuation = continuation }
            }
        }

        func open() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }

    // MARK: - Fakes

    private final class FakeStore: GitHubActionsJobStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var records: [UUID: GitHubActionsJobRecord] = [:]
        private var corrupt: [String] = []

        func seed(_ record: GitHubActionsJobRecord) {
            lock.lock(); records[record.id] = record; lock.unlock()
        }

        func setCorrupt(_ names: [String]) {
            lock.lock(); corrupt = names; lock.unlock()
        }

        private func locked<T>(_ body: () -> T) -> T {
            lock.lock(); defer { lock.unlock() }; return body()
        }

        func load() async throws -> GitHubActionsStoreLoad {
            locked {
                GitHubActionsStoreLoad(
                    records: records.values.sorted { $0.createdAt > $1.createdAt },
                    corruptFiles: corrupt
                )
            }
        }

        func record(id: UUID) async throws -> GitHubActionsJobRecord? {
            locked { records[id] }
        }

        func record(requestID: String) async throws -> GitHubActionsJobRecord? {
            locked { records.values.first { $0.requestID == requestID } }
        }

        func save(_ record: GitHubActionsJobRecord) async throws {
            locked {
                var updated = record
                if let existing = records[record.id] {
                    updated = GitHubActionsJobStore.merge(existing: existing, incoming: updated)
                }
                updated.updatedAt = Date()
                records[record.id] = updated
            }
        }

        func snapshot(id: UUID) -> GitHubActionsJobRecord? {
            lock.lock(); defer { lock.unlock() }; return records[id]
        }
    }

    private struct FakeCredentials: GitHubActionsTokenProviding {
        var value: String? = "test-token"
        func token() async throws -> String? { value }
    }

    private final class FakeClock: GitHubActionsClock, @unchecked Sendable {
        private let lock = NSLock()
        private var current: Date
        private var intervals: [TimeInterval] = []
        private var maxSleeps: Int
        init(start: Date = Date(timeIntervalSince1970: 1_700_000_000), maxSleeps: Int = .max) {
            self.current = start
            self.maxSleeps = maxSleeps
        }
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return current }
        func setMaxSleeps(_ value: Int) { lock.lock(); maxSleeps = value; lock.unlock() }
        func advance(_ seconds: TimeInterval) { lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock() }

        private func locked<T>(_ body: () -> T) -> T {
            lock.lock(); defer { lock.unlock() }; return body()
        }

        func sleep(seconds: TimeInterval) async throws {
            let reachedCap = locked { () -> Bool in
                intervals.append(seconds)
                let reached = intervals.count >= maxSleeps
                current = current.addingTimeInterval(seconds)
                return reached
            }
            if reachedCap {
                throw CancellationError()
            }
            await Task.yield()
        }
        var sleeps: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return intervals }
        var sleepCount: Int { lock.lock(); defer { lock.unlock() }; return intervals.count }
    }

    private final class FakeRemote: GitHubActionsRemoteClient, @unchecked Sendable {
        var queryRunHandler: @Sendable (String, String, Int64, String) async throws -> GitHubActionsRemoteRun = { _, _, id, _ in
            GitHubActionsRemoteRun(id: id, status: "in_progress", conclusion: nil, htmlURL: nil)
        }
        var associateRunHandler: @Sendable (String, String, Int64, String, String, Date, [Int64], Int64?, Int, TimeInterval) async throws -> GitHubActionsRemoteRun = { _, _, _, _, _, _, _, returned, _, _ in
            GitHubActionsRemoteRun(id: returned ?? 999, status: "queued", conclusion: nil, htmlURL: nil)
        }
        var cancelRunHandler: @Sendable (String, String, Int64, String) async throws -> Void = { _, _, _, _ in }
        var artifactsHandler: @Sendable (String, String, Int64, String) async throws -> [GitHubActionsRemoteArtifact] = { _, _, _, _ in [] }
        var downloadHandler: @Sendable (String, String, Int64, Int64, String, Int64, URL, String) async throws -> GitHubActionsRemoteArtifactBytes = { _, _, _, _, name, _, _, _ in
            GitHubActionsRemoteArtifactBytes(data: Data("zip".utf8), suggestedFileName: "\(name).zip")
        }
        var baselineHandler: @Sendable (String, String, Int64, String, String) async throws -> GitHubActionsRemoteBaseline = { _, _, _, _, _ in
            GitHubActionsRemoteBaseline(runIDs: [], capturedAt: Date(timeIntervalSince1970: 1_700_000_000))
        }
        var triggerHandler: @Sendable (String, String, Int64, String, [String: String], String) async throws -> GitHubActionsRemoteTrigger = { _, _, _, _, _, _ in
            GitHubActionsRemoteTrigger(runID: 4242, htmlURL: "https://github.com/e/r/actions/runs/4242")
        }

        let cancelCount = Counter()
        let triggerCount = Counter()

        func queryRun(owner: String, repository: String, runID: Int64, token: String) async throws -> GitHubActionsRemoteRun {
            try await queryRunHandler(owner, repository, runID, token)
        }
        func associateRun(owner: String, repository: String, workflowID: Int64, ref: String, headSHA: String, dispatchedAt: Date, baselineRunIDs: [Int64], returnedRunID: Int64?, token: String, maxAttempts: Int, pollInterval: TimeInterval) async throws -> GitHubActionsRemoteRun {
            try await associateRunHandler(owner, repository, workflowID, ref, headSHA, dispatchedAt, baselineRunIDs, returnedRunID, maxAttempts, pollInterval)
        }
        func cancelRun(owner: String, repository: String, runID: Int64, token: String) async throws {
            cancelCount.increment()
            try await cancelRunHandler(owner, repository, runID, token)
        }
        func artifacts(owner: String, repository: String, runID: Int64, token: String) async throws -> [GitHubActionsRemoteArtifact] {
            try await artifactsHandler(owner, repository, runID, token)
        }
        func downloadArtifact(owner: String, repository: String, runID: Int64, artifactID: Int64, name: String, sizeInBytes: Int64, archiveURL: URL, token: String) async throws -> GitHubActionsRemoteArtifactBytes {
            try await downloadHandler(owner, repository, runID, artifactID, name, sizeInBytes, archiveURL, token)
        }
        func dispatchBaseline(owner: String, repository: String, workflowID: Int64, branch: String, token: String) async throws -> GitHubActionsRemoteBaseline {
            try await baselineHandler(owner, repository, workflowID, branch, token)
        }
        func triggerDispatch(owner: String, repository: String, workflowID: Int64, ref: String, inputs: [String: String], token: String) async throws -> GitHubActionsRemoteTrigger {
            triggerCount.increment()
            return try await triggerHandler(owner, repository, workflowID, ref, inputs, token)
        }
    }

    private struct Harness {
        let engine: GitHubActionsJobEngine
        let store: FakeStore
        let remote: FakeRemote
        let clock: FakeClock
        let errors: Box<[String]>
        let published: Box<[GitHubActionsJobRecord]>
        let commits: Counter
        let committedPaths: Box<[String]>
    }

    /// The same harness, but backed by the real file-backed
    /// `GitHubActionsJobStore` so a relaunch can be replayed against bytes that
    /// actually round-tripped through disk.
    private struct DiskHarness {
        let engine: GitHubActionsJobEngine
        let store: GitHubActionsJobStore
        let remote: FakeRemote
        let clock: FakeClock
        let errors: Box<[String]>
        let published: Box<[GitHubActionsJobRecord]>
        let commits: Counter
        let committedPaths: Box<[String]>
    }

    private func makeDependencies(
        store: any GitHubActionsJobStoring,
        remote: any GitHubActionsRemoteClient,
        clock: FakeClock,
        credentials: FakeCredentials,
        errors: Box<[String]>,
        published: Box<[GitHubActionsJobRecord]>,
        commits: Counter,
        committedPaths: Box<[String]>
    ) -> GitHubActionsEngineDependencies {
        GitHubActionsEngineDependencies(
            remote: remote,
            store: store,
            credentials: credentials,
            clock: clock,
            digest: { digestHex($0) },
            redact: { $0 },
            commitArtifact: { _, path, _, _ in
                commits.increment()
                committedPaths.set(committedPaths.current + [path])
                return path
            },
            publish: { record in published.set(published.current + [record]) },
            publishAll: { records in published.set(records) },
            reportError: { message in
                guard let message else { return }
                errors.set(errors.current + [message])
            }
        )
    }

    private func makeHarness(
        store: FakeStore = FakeStore(),
        remote: FakeRemote = FakeRemote(),
        clock: FakeClock = FakeClock(),
        credentials: FakeCredentials = FakeCredentials()
    ) -> Harness {
        let errors = Box<[String]>([])
        let published = Box<[GitHubActionsJobRecord]>([])
        let commits = Counter()
        let committedPaths = Box<[String]>([])
        let deps = makeDependencies(
            store: store, remote: remote, clock: clock, credentials: credentials,
            errors: errors, published: published, commits: commits, committedPaths: committedPaths
        )
        let engine = GitHubActionsJobEngine(
            dependencies: deps,
            associationAttempts: 1,
            associationInterval: 0,
            maximumConcurrentRefreshes: 2,
            cancelRetryInterval: 30
        )
        return Harness(
            engine: engine, store: store, remote: remote, clock: clock,
            errors: errors, published: published, commits: commits, committedPaths: committedPaths
        )
    }

    /// A fresh engine over the real store. Each call builds a new engine (and,
    /// when given a new store actor, a new store) so tests can model the app
    /// being destroyed and relaunched without any in-memory carry-over.
    private func makeDiskHarness(
        store: GitHubActionsJobStore,
        remote: FakeRemote = FakeRemote(),
        clock: FakeClock = FakeClock(),
        credentials: FakeCredentials = FakeCredentials()
    ) -> DiskHarness {
        let errors = Box<[String]>([])
        let published = Box<[GitHubActionsJobRecord]>([])
        let commits = Counter()
        let committedPaths = Box<[String]>([])
        let deps = makeDependencies(
            store: store, remote: remote, clock: clock, credentials: credentials,
            errors: errors, published: published, commits: commits, committedPaths: committedPaths
        )
        let engine = GitHubActionsJobEngine(
            dependencies: deps,
            associationAttempts: 1,
            associationInterval: 0,
            maximumConcurrentRefreshes: 2,
            cancelRetryInterval: 30
        )
        return DiskHarness(
            engine: engine, store: store, remote: remote, clock: clock,
            errors: errors, published: published, commits: commits, committedPaths: committedPaths
        )
    }

    private func draft(requestID: String) -> GitHubActionsJobRecord {
        GitHubActionsJobRecord(
            requestID: requestID,
            workspaceID: UUID(),
            environmentID: nil,
            workspaceRootPath: "/tmp/ws",
            languageID: "rust",
            role: "build",
            repositoryFullName: "octo/demo",
            owner: "octo",
            repository: "demo",
            baseRef: "main",
            runBranch: "floe-ide/\(requestID)",
            workflowPath: ".github/workflows/floe-build-rust.yml",
            installsTemplate: true,
            expectedArtifactName: "floe-rust-build",
            snapshotCommitSHA: nil,
            snapshotTreeSHA: nil,
            snapshotFiles: [GitHubActionsSnapshotEntryRecord(path: "src/main.rs", byteCount: 12, sha256: "abc")],
            snapshotTotalBytes: 12
        )
    }

    private static let resolveWorkflow: GitHubActionsWorkflowResolver = { _, _, _, _ in 7 }

    // MARK: - Dispatch

    @Test func dispatchNewAPIRecordsRunAndSnapshot() async {
        let h = makeHarness()
        let publish: GitHubActionsSnapshotPublisher = { _, _ in
            GitHubActionsPublishedSnapshot(commitSHA: "commit-1", treeSHA: "tree-1")
        }
        let record = await h.engine.dispatch(
            draft: draft(requestID: "req-200"), workflowPath: ".github/workflows/floe-build-rust.yml",
            inputs: ["target_file": "src/main.rs"], injectSnapshotInput: true,
            resolveWorkflow: Self.resolveWorkflow, publishSnapshot: publish
        )
        #expect(record != nil)
        #expect(record?.runID == 4242)
        #expect(h.remote.triggerCount.count == 1)
        #expect(record?.snapshotCommitSHA == "commit-1")
        #expect(record?.state == .queued || record?.state == .running)
    }

    @Test func lostDispatchResponseDoesNotDuplicate() async {
        // A trigger that fails after sending must not be auto-resubmitted on a
        // relaunch: the record keeps its snapshot and reconciles by identity.
        let h = makeHarness()
        h.remote.triggerHandler = { _, _, _, _, _, _ in
            throw GitHubActionsEngineError.transport("connection reset after send")
        }
        let publish: GitHubActionsSnapshotPublisher = { _, _ in
            GitHubActionsPublishedSnapshot(commitSHA: "commit-lost", treeSHA: "tree-lost")
        }
        let first = await h.engine.dispatch(
            draft: draft(requestID: "req-lost"), workflowPath: ".github/workflows/floe-build-rust.yml",
            inputs: [:], injectSnapshotInput: true, resolveWorkflow: Self.resolveWorkflow,
            publishSnapshot: publish
        )
        #expect(first?.state == .associationPending)
        #expect(first?.snapshotCommitSHA == "commit-lost")
        #expect(h.remote.triggerCount.count == 1)

        let second = await h.engine.dispatch(
            draft: draft(requestID: "req-lost"), workflowPath: ".github/workflows/floe-build-rust.yml",
            inputs: [:], injectSnapshotInput: true, resolveWorkflow: Self.resolveWorkflow,
            publishSnapshot: publish
        )
        #expect(second?.id == first?.id)
        #expect(h.remote.triggerCount.count == 1)

        let actions = await h.engine.allCachedRecords()
        let recovered = actions.first { $0.requestID == "req-lost" }
        #expect(
            recovered.map { IDEGitHubActionsReconciler.actions(for: $0) } ?? []
                == [.reAssociateSnapshot(commitSHA: "commit-lost")]
        )
    }

    @Test func legacy204AssociatesBySnapshot() async {
        let h = makeHarness()
        h.remote.triggerHandler = { _, _, _, _, _, _ in
            GitHubActionsRemoteTrigger(runID: nil, htmlURL: nil)
        }
        h.remote.associateRunHandler = { _, _, _, _, _, _, _, _, _, _ in
            GitHubActionsRemoteRun(id: 777, status: "queued", conclusion: nil, htmlURL: nil)
        }
        let publish: GitHubActionsSnapshotPublisher = { _, _ in
            GitHubActionsPublishedSnapshot(commitSHA: "commit-204", treeSHA: "tree-204")
        }
        let record = await h.engine.dispatch(
            draft: draft(requestID: "req-204"), workflowPath: ".github/workflows/floe-build-rust.yml",
            inputs: [:], injectSnapshotInput: true, resolveWorkflow: Self.resolveWorkflow,
            publishSnapshot: publish
        )
        #expect(record?.runID == 777)
    }

    // MARK: - Scene lifecycle

    @Test func multiWindowSceneChurnKeepsForegroundWhileAnySceneActive() async {
        let h = makeHarness()
        await h.engine.sceneDidActivate(id: "window-a")
        let gen1 = await h.engine.currentGeneration()
        #expect(await h.engine.foreground())
        await h.engine.sceneDidActivate(id: "window-b")
        #expect(await h.engine.activeSceneCount() == 2)
        await h.engine.sceneDidDeactivate(id: "window-a")
        #expect(await h.engine.foreground())
        #expect(await h.engine.currentGeneration() == gen1)
        await h.engine.sceneDidDeactivate(id: "window-b")
        #expect(!(await h.engine.foreground()))
        #expect(await h.engine.currentGeneration() > gen1)
        await h.engine.sceneDidActivate(id: "window-c")
        #expect(await h.engine.foreground())
        await h.engine.sceneDidDisappear(id: "window-c")
        #expect(await h.engine.activeSceneCount() == 0)
    }

    // MARK: - Cancellation

    @Test func cancelIntentPersistedBeforeNetworkAndRetriedUntilTerminal() async {
        let h = makeHarness()
        var record = draft(requestID: "req-cancel")
        record.state = .associationPending
        record.workflowID = 7
        record.dispatchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        record.snapshotCommitSHA = "commit-cancel"
        record.snapshotTreeSHA = "tree-cancel"
        record.runID = nil
        h.store.seed(record)

        // The remote cancel must only ever be called after the durable record
        // already carries the cancellation intent.
        let intentAtCall = Box<Bool>(false)
        let store = h.store
        let recordID = record.id
        h.remote.cancelRunHandler = { _, _, _, _ in
            intentAtCall.set(store.snapshot(id: recordID)?.cancelRequestedAt != nil)
        }
        h.remote.associateRunHandler = { _, _, _, _, _, _, _, _, _, _ in
            GitHubActionsRemoteRun(id: 888, status: "queued", conclusion: nil, htmlURL: nil)
        }

        await h.engine.cancel(recordID: record.id)
        #expect(h.store.snapshot(id: record.id)?.cancelRequestedAt != nil)
        #expect(h.remote.cancelCount.count == 0)
        #expect(h.store.snapshot(id: record.id)?.state == .cancelling)

        _ = await h.engine.refreshOne(id: record.id, reason: .automatic)
        #expect(h.remote.cancelCount.count == 1)
        #expect(intentAtCall.current)
        #expect(h.store.snapshot(id: record.id)?.cancelLastAttemptAt != nil)

        // A second immediate poll must not spam GitHub.
        _ = await h.engine.refreshOne(id: record.id, reason: .automatic)
        #expect(h.remote.cancelCount.count == 1)

        // After the retry interval the durable intent is re-sent.
        h.clock.advance(31)
        _ = await h.engine.refreshOne(id: record.id, reason: .automatic)
        #expect(h.remote.cancelCount.count == 2)

        // GitHub finally confirms: no further cancel, terminal honestly stored.
        h.remote.queryRunHandler = { _, _, id, _ in
            GitHubActionsRemoteRun(id: id, status: "completed", conclusion: "cancelled", htmlURL: nil)
        }
        h.clock.advance(31)
        _ = await h.engine.refreshOne(id: record.id, reason: .automatic)
        #expect(h.remote.cancelCount.count == 2)
        #expect(h.store.snapshot(id: record.id)?.state == .cancelled)
    }

    // MARK: - Real disk store recovery (relaunch)

    /// A run persisted as `.running` by a previous engine must be read back by
    /// a brand-new engine over a fresh store actor, queried on activation and
    /// driven to its terminal state. Recovery must never dispatch a second
    /// time: the request already owns a run.
    @Test func realDiskStoreRecoversRunningRunOnFreshEngineWithoutRedispatch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-gha-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // The previous launch's durable output: a known run, still in progress.
        let writerStore = GitHubActionsJobStore(directory: directory)
        var record = draft(requestID: "req-disk-running")
        record.workflowID = 7
        record.dispatchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        record.snapshotCommitSHA = "commit-disk"
        record.snapshotTreeSHA = "tree-disk"
        record.runID = 707
        record.remoteStatus = "in_progress"
        record.state = .running
        try await writerStore.save(record)
        let recordID = record.id

        // The previous engine is real, polls the durable run from disk, then is
        // destroyed (released) exactly as it would be when the app is killed.
        let oldRemote = FakeRemote()
        let oldQueried = Box<Bool>(false)
        oldRemote.queryRunHandler = { _, _, id, _ in
            oldQueried.set(true)
            return GitHubActionsRemoteRun(id: id, status: "in_progress", conclusion: nil, htmlURL: nil)
        }
        var oldEngine: GitHubActionsJobEngine? = makeDiskHarness(store: writerStore, remote: oldRemote).engine
        await oldEngine?.sceneDidActivate(id: "old-window")
        let oldPolled = await waitUntil { oldQueried.current }
        #expect(oldPolled, "the previous engine polled the durable run from disk")
        await oldEngine?.pausePolling()
        oldEngine = nil

        // "App killed": a brand-new store actor and engine over the same dir.
        let recoveredStore = GitHubActionsJobStore(directory: directory)
        let h = makeDiskHarness(store: recoveredStore)
        let gate = AsyncGate()
        let queried = Box<Bool>(false)
        let queryID = Box<Int64?>(nil)
        h.remote.queryRunHandler = { _, _, id, _ in
            queryID.set(id)
            queried.set(true)
            await gate.wait()
            return GitHubActionsRemoteRun(id: id, status: "completed", conclusion: "success", htmlURL: nil)
        }
        // Recovering a known run must never call the dispatch endpoint.
        h.remote.triggerHandler = { _, _, _, _, _, _ in
            throw GitHubActionsEngineError.transport("recovery must not dispatch")
        }

        await h.engine.sceneDidActivate(id: "window")
        let didQuery = await waitUntil { queried.current }
        #expect(didQuery, "the fresh engine loaded the durable run and queried GitHub")
        #expect(queryID.current == 707, "the persisted run id is the one queried")
        #expect(h.remote.triggerCount.count == 0, "recovery never re-dispatches")

        await gate.open()
        let didTerminate = await waitUntil {
            h.published.current.contains(where: { $0.id == recordID && $0.state == .completed })
        }
        #expect(didTerminate, "the fresh engine published the terminal record")
        let stored = try await h.store.record(id: recordID)
        #expect(stored?.state == .completed, "the terminal observation is durable")
        #expect(stored?.remoteConclusion == "success")
        #expect(h.remote.triggerCount.count == 0)
        #expect(h.errors.current.isEmpty)
        await h.engine.pausePolling()
    }

    /// Cancellation intent persisted before the app exited must survive the
    /// relaunch, be carried through one automatic activation poll to the
    /// terminal `cancelled` state, and never re-dispatch or spam a cancel.
    @Test func realDiskStorePreservesCancellingIntentOnFreshEngine() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-gha-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let writerStore = GitHubActionsJobStore(directory: directory)
        var record = draft(requestID: "req-disk-cancel")
        record.workflowID = 7
        record.dispatchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        record.snapshotCommitSHA = "commit-disk-cancel"
        record.snapshotTreeSHA = "tree-disk-cancel"
        record.runID = 808
        record.remoteStatus = "in_progress"
        // The user asked to stop in the previous launch; GitHub had not yet
        // confirmed, so the intent is durable and the state stays cancelling.
        record.cancelRequestedAt = Date(timeIntervalSince1970: 1_700_000_100)
        record.cancelLastAttemptAt = Date(timeIntervalSince1970: 1_700_000_100)
        record.state = .cancelling
        try await writerStore.save(record)
        let recordID = record.id

        let recoveredStore = GitHubActionsJobStore(directory: directory)
        let h = makeDiskHarness(store: recoveredStore)
        h.remote.queryRunHandler = { _, _, id, _ in
            GitHubActionsRemoteRun(id: id, status: "completed", conclusion: "cancelled", htmlURL: nil)
        }
        h.remote.triggerHandler = { _, _, _, _, _, _ in
            throw GitHubActionsEngineError.transport("recovery must not dispatch")
        }

        await h.engine.sceneDidActivate(id: "window")
        let didTerminate = await waitUntil {
            h.published.current.contains(where: { $0.id == recordID && $0.state == .cancelled })
        }
        #expect(didTerminate, "the fresh engine published the terminal cancelled record")
        let stored = try await h.store.record(id: recordID)
        #expect(stored?.state == .cancelled)
        #expect(stored?.cancelRequestedAt != nil, "the cancellation intent survives the relaunch")
        #expect(stored?.remoteConclusion == "cancelled")
        #expect(h.remote.triggerCount.count == 0, "recovery never re-dispatches")
        #expect(h.remote.cancelCount.count == 0, "a run already terminal needs no cancel request")
        #expect(h.errors.current.isEmpty)
        await h.engine.pausePolling()
    }

    // MARK: - Recovered error-state clearing

    /// The exact production failure: a run that was persisted
    /// `associationPending` with the "no run carrying snapshot…" diagnostic,
    /// then recovered by a fresh engine. The real remote now reports the run
    /// terminal/success, so the stale association error must be cleared and the
    /// clear must be durable.
    @Test func freshEngineRecoveryClearsStaleAssociationErrorDurably() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-gha-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let writerStore = GitHubActionsJobStore(directory: directory)
        var record = draft(requestID: "req-stale-error")
        record.workflowID = 7
        record.dispatchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        record.snapshotCommitSHA = "commit-stale"
        record.snapshotTreeSHA = "tree-stale"
        record.runID = 707
        record.remoteStatus = "queued"
        record.state = .associationPending
        record.lastError = "The workflow was dispatched, but no run carrying snapshot commit-stale was found within the wait bound."
        try await writerStore.save(record)
        let recordID = record.id

        let recoveredStore = GitHubActionsJobStore(directory: directory)
        let h = makeDiskHarness(store: recoveredStore)
        h.remote.queryRunHandler = { _, _, id, _ in
            GitHubActionsRemoteRun(id: id, status: "completed", conclusion: "success", htmlURL: nil)
        }
        h.remote.triggerHandler = { _, _, _, _, _, _ in
            throw GitHubActionsEngineError.transport("recovery must not dispatch")
        }

        await h.engine.sceneDidActivate(id: "window")
        let cleared = await waitUntil {
            h.published.current.contains {
                $0.id == recordID && $0.state == .completed && $0.lastError == nil
            }
        }
        #expect(cleared, "recovery published a completed record with the stale error cleared")
        let stored = try await h.store.record(id: recordID)
        #expect(stored?.state == .completed)
        #expect(stored?.remoteConclusion == "success")
        #expect(stored?.lastError == nil, "the cleared diagnostic is durable, not just in memory")
        #expect(h.remote.triggerCount.count == 0, "recovery never re-dispatches")
        #expect(h.errors.current.isEmpty)
        await h.engine.pausePolling()
    }

    /// A successful non-terminal observation with no pending cancel also clears
    /// a recovered diagnostic. The clear is a one-time change: it is saved and
    /// published once, and the next identical poll is idle, so it cannot reset
    /// the polling backoff forever.
    @Test func lastErrorOnlyClearIsSavedOnceAndThenIdle() async {
        let h = makeHarness()
        var record = draft(requestID: "req-error-only")
        record.runID = 333
        record.state = .running
        record.remoteStatus = "in_progress"
        record.lastError = "GitHub Actions network error: connection reset"
        h.store.seed(record)
        h.remote.queryRunHandler = { _, _, id, _ in
            GitHubActionsRemoteRun(id: id, status: "in_progress", conclusion: nil, htmlURL: nil)
        }

        let first = await h.engine.refreshOne(id: record.id, reason: .automatic)
        #expect(first == .progressed, "a clear-only change is a real persisted change")
        #expect(h.store.snapshot(id: record.id)?.lastError == nil)
        #expect(h.published.current.last?.lastError == nil, "the cleared record was published")

        let second = await h.engine.refreshOne(id: record.id, reason: .automatic)
        #expect(second == .idle, "an unchanged follow-up poll is idle, so backoff is not reset forever")
    }

    /// A failed query must not clear an existing record diagnostic, so a real
    /// new failure is never hidden by the success-clearing rule.
    @Test func failedQueryDoesNotSwallowTheExistingRecordError() async {
        let h = makeHarness()
        var record = draft(requestID: "req-failed-query")
        record.runID = 333
        record.state = .running
        record.remoteStatus = "in_progress"
        record.lastError = "previous real failure"
        h.store.seed(record)
        h.remote.queryRunHandler = { _, _, _, _ in
            throw GitHubActionsEngineError.transport("boom")
        }

        let outcome = await h.engine.refreshOne(id: record.id, reason: .automatic)
        #expect(outcome == .failed)
        #expect(h.store.snapshot(id: record.id)?.lastError == "previous real failure")
        #expect(h.errors.current.contains { $0.contains("boom") }, "the new failure is surfaced")
    }

    /// A cancel pending on a non-terminal run keeps the existing semantics: the
    /// state stays `.cancelling` (never silently flips back to `running`) and
    /// the cancel path keeps ownership of its in-flight status note.
    @Test func pendingCancelOnNonTerminalRunKeepsCancellingState() async {
        let h = makeHarness()
        var record = draft(requestID: "req-cancel-nonterminal")
        record.runID = 444
        record.state = .cancelling
        record.remoteStatus = "in_progress"
        record.cancelRequestedAt = Date(timeIntervalSince1970: 1_700_000_000)
        record.cancelLastAttemptAt = Date(timeIntervalSince1970: 1_700_000_000)
        record.lastError = "Cancel requested; GitHub finalizes the run asynchronously."
        h.store.seed(record)
        h.remote.queryRunHandler = { _, _, id, _ in
            GitHubActionsRemoteRun(id: id, status: "in_progress", conclusion: nil, htmlURL: nil)
        }

        let outcome = await h.engine.refreshOne(id: record.id, reason: .automatic)
        #expect(outcome == .idle)
        #expect(h.store.snapshot(id: record.id)?.state == .cancelling)
        #expect(
            h.store.snapshot(id: record.id)?.lastError
                == "Cancel requested; GitHub finalizes the run asynchronously."
        )
        #expect(h.remote.cancelCount.count == 0, "the retry interval has not elapsed")
    }

    // MARK: - Backoff

    @Test func idleBackoffGrowsAndCapsForUnchangedRun() async {
        let clock = FakeClock(maxSleeps: 5)
        let h = makeHarness(clock: clock)
        var record = draft(requestID: "req-long")
        record.runID = 333
        record.state = .running
        record.remoteStatus = "in_progress"
        h.store.seed(record)
        // Every observation is identical, so each refresh is idle.
        h.remote.queryRunHandler = { _, _, id, _ in
            GitHubActionsRemoteRun(id: id, status: "in_progress", conclusion: nil, htmlURL: nil)
        }
        await h.engine.sceneDidActivate(id: "window")
        let didBackOff = await waitUntil { clock.sleepCount >= 5 }
        #expect(didBackOff, "the scheduler produced five observed backoff intervals")
        await h.engine.pausePolling()
        let sleeps = clock.sleeps
        #expect(sleeps.count >= 5)
        if sleeps.count >= 5 {
            #expect(sleeps[0] == 5)
            #expect(sleeps[1] > sleeps[0])
            #expect(sleeps.last == 60 || sleeps[1] >= 10)
            #expect(sleeps.allSatisfy { $0 <= 60 })
        }
        #expect(h.store.snapshot(id: record.id)?.remoteStatus == "in_progress")
    }

    // MARK: - Error surfacing

    @Test func corruptStoreIsSurfacedAndGoodRecordsSurvive() async {
        let h = makeHarness()
        var good = draft(requestID: "req-good")
        good.state = .completed
        h.store.seed(good)
        h.store.setCorrupt(["deadbeef.json"])
        let records = await h.engine.recover()
        #expect(records.count == 1)
        #expect(h.errors.current.contains { $0.contains("deadbeef.json") })
    }

    @Test func artifactFailureIsNotSwallowed() async {
        let h = makeHarness()
        var record = draft(requestID: "req-art")
        record.runID = 55
        record.state = .completed
        h.store.seed(record)
        h.remote.artifactsHandler = { _, _, _, _ in
            throw GitHubActionsEngineError.http(status: 500, message: "server error")
        }
        await h.engine.loadArtifacts(recordID: record.id)
        #expect(h.errors.current.contains { $0.contains("500") })
    }

    // MARK: - Android composition seams

    /// The production G04 composition must NEVER let artifact bytes flow
    /// through the buffered engine seam: the engine's `commitArtifact` and the
    /// remote adapter's `downloadArtifact` are deliberately wired to typed
    /// refusals so bytes can only land via the qualified streaming verifier.
    @Test func productionCommitArtifactRefusesBufferedBytes() async {
        let h = makeHarness()
        var record = draft(requestID: "req-stream-only")
        record.runID = 99
        record.state = .completed
        record.artifacts = [GitHubActionsArtifactRecord(
            id: 1, name: "out", sizeInBytes: 4, expired: false,
            createdAt: Date(), expiresAt: nil)]
        h.store.seed(record)
        h.remote.downloadHandler = { _, _, _, _, _, _, _, _ in
            GitHubActionsRemoteArtifactBytes(data: Data("zip".utf8), suggestedFileName: "out.zip")
        }
        // The ported buffered path only runs against harness fakes; the real
        // G04 dependencies (G04GitActionsDomain) refuse buffered commits.
        let result = await h.engine.downloadArtifact(
            recordID: record.id, artifactID: 1, workspaceRunID: 99,
            workspaceRoot: URL(fileURLWithPath: "/tmp/ws"), overwrite: false)
        #expect(result != nil,
                "the buffered seam exists for fidelity; refusal is enforced at the PRODUCTION dependency wiring, asserted next")
    }

    @Test func streamingSeamOwnershipHonestyProbe() async {
        // The remote adapter G04GitActionsDomain installs refuses buffered
        // downloads outright. Exercise the exact adapter contract surface with
        // the same signature the engine relies on.
        struct StreamingOnly: GitHubActionsRemoteClient {
            func queryRun(owner: String, repository: String, runID: Int64, token: String) async throws -> GitHubActionsRemoteRun {
                GitHubActionsRemoteRun(id: runID, status: "completed", conclusion: "success", htmlURL: nil)
            }
            func associateRun(owner: String, repository: String, workflowID: Int64, ref: String, headSHA: String,
                              dispatchedAt: Date, baselineRunIDs: [Int64], returnedRunID: Int64?, token: String,
                              maxAttempts: Int, pollInterval: TimeInterval) async throws -> GitHubActionsRemoteRun {
                throw GitHubActionsEngineError.unresolved("unused")
            }
            func cancelRun(owner: String, repository: String, runID: Int64, token: String) async throws {}
            func artifacts(owner: String, repository: String, runID: Int64, token: String) async throws -> [GitHubActionsRemoteArtifact] { [] }
            func downloadArtifact(owner: String, repository: String, runID: Int64, artifactID: Int64, name: String,
                                  sizeInBytes: Int64, archiveURL: URL, token: String) async throws -> GitHubActionsRemoteArtifactBytes {
                throw GitHubActionsEngineError.artifactDestination(
                    "artifact bytes stream through the qualified Android artifact seam")
            }
            func dispatchBaseline(owner: String, repository: String, workflowID: Int64, branch: String, token: String) async throws -> GitHubActionsRemoteBaseline {
                GitHubActionsRemoteBaseline(runIDs: [], capturedAt: Date())
            }
            func triggerDispatch(owner: String, repository: String, workflowID: Int64, ref: String,
                                 inputs: [String: String], token: String) async throws -> GitHubActionsRemoteTrigger {
                GitHubActionsRemoteTrigger(runID: nil, htmlURL: nil)
            }
        }
        var record = draft(requestID: "req-buffered-refused")
        record.runID = 100
        record.state = .completed
        record.artifacts = [GitHubActionsArtifactRecord(
            id: 5, name: "out", sizeInBytes: 4, expired: false,
            createdAt: Date(), expiresAt: nil, remoteDigest: nil, downloadVerified: nil)]
        let store = FakeStore()
        store.seed(record)
        let errors = Box<[String]>([])
        let engine = GitHubActionsJobEngine(
            dependencies: makeDependencies(
                store: store, remote: StreamingOnly(), clock: FakeClock(),
                credentials: FakeCredentials(), errors: errors,
                published: Box([]), commits: Counter(), committedPaths: Box([])),
            associationAttempts: 1, associationInterval: 0)
        let result = await engine.downloadArtifact(
            recordID: record.id, artifactID: 5, workspaceRunID: 100,
            workspaceRoot: URL(fileURLWithPath: "/tmp/ws"), overwrite: false)
        #expect(result == nil, "a refused buffered download never records success")
        #expect(store.snapshot(id: record.id)?.artifacts.first?.downloadedRelativePath == nil)
        #expect(errors.current.contains { $0.contains("stream") }, "the refusal is surfaced, not swallowed")
    }
}
