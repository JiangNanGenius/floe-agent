// SPDX-License-Identifier: MPL-2.0
//
// IDEGitHubActionsTests — formal Swift Testing port of the passing local
// `GitHubActionsJobEngine` harness. It drives the *real* production engine,
// store and reconciler (via `@testable import FloeApp`) with injected fake
// remote/store/clock/credentials, so the durable state machine is exercised
// without the Keychain, a simulator, a network or a live GitHub call.
//
// Covered actual behavior:
//   * dispatch 200 JSON and legacy 204 association;
//   * a lost dispatch response that must not become a duplicate trigger;
//   * multi-window scene churn and background/foreground gating;
//   * cancellation intent persisted before the network call, sent only after a
//     run is associated and retried on a bounded interval until terminal;
//   * idle backoff growth/cap for a long unchanged run (never a 5s hot loop);
//   * corrupt-store and artifact-error surfacing;
//   * the store's monotonic merge preserving cancel intent and download state.

#if canImport(UIKit)
import Foundation
import CryptoKit
import Testing
@testable import FloeApp

@Suite("IDEGitHubActionsTests")
struct IDEGitHubActionsTests {

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

    private func digestHex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
        let deps = GitHubActionsEngineDependencies(
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
        for _ in 0..<400 where clock.sleepCount < 5 {
            try? await Task.sleep(for: .milliseconds(5))
        }
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

    // MARK: - Store merge

    @Test func storeMergePreservesCancelIntentAndDownloadMetadata() {
        var existing = draft(requestID: "req-merge")
        existing.state = .running
        existing.cancelRequestedAt = Date(timeIntervalSince1970: 1_700_000_500)
        existing.cancelLastAttemptAt = Date(timeIntervalSince1970: 1_700_000_500)
        existing.runID = 90
        existing.artifacts = [
            GitHubActionsArtifactRecord(
                id: 1, name: "out", sizeInBytes: 10, expired: false,
                createdAt: Date(), expiresAt: nil,
                downloadedSHA256: "deadbeef", downloadedRelativePath: ".floe/artifacts/90/out.zip"
            )
        ]
        var stale = existing
        stale.cancelRequestedAt = nil
        stale.cancelLastAttemptAt = nil
        stale.state = .running
        stale.artifacts = [
            GitHubActionsArtifactRecord(
                id: 1, name: "out", sizeInBytes: 10, expired: false,
                createdAt: Date(), expiresAt: nil,
                downloadedSHA256: nil, downloadedRelativePath: nil
            )
        ]
        let merged = GitHubActionsJobStore.merge(existing: existing, incoming: stale)
        #expect(merged.cancelRequestedAt != nil)
        #expect(merged.state == .cancelling)
        #expect(merged.artifacts.first?.downloadedSHA256 == "deadbeef")
        #expect(merged.artifacts.first?.downloadedRelativePath == ".floe/artifacts/90/out.zip")
    }

    @Test func recordWithoutSnapshotIsNeverAutoResubmitted() {
        var record = draft(requestID: "req-no-snapshot")
        record.state = .preparing
        record.snapshotCommitSHA = nil
        record.workflowID = nil
        record.dispatchedAt = nil
        #expect(IDEGitHubActionsReconciler.actions(for: record) == [.awaitingManualRedispatch])
        #expect(!IDEGitHubActionsReconciler.hasActionableStep(record))
    }

    // MARK: - Artifact digest verification and stale writes

    private func artifactRecord(runID: Int64, requestID: String, remoteDigest: String?) -> GitHubActionsJobRecord {
        var record = draft(requestID: requestID)
        record.runID = runID
        record.state = .completed
        record.artifacts = [
            GitHubActionsArtifactRecord(
                id: 1, name: "floe-rust-build", sizeInBytes: 4, expired: false,
                createdAt: Date(), expiresAt: nil,
                downloadedSHA256: nil, downloadedRelativePath: nil,
                remoteDigest: remoteDigest, downloadVerified: nil
            )
        ]
        return record
    }

    @Test func artifactDigestMatchCommitsVerified() async {
        let h = makeHarness()
        let bytes = Data("zip-match".utf8)
        let record = artifactRecord(runID: 90, requestID: "req-digest-match", remoteDigest: "sha256:" + digestHex(bytes))
        h.store.seed(record)
        h.remote.downloadHandler = { _, _, _, _, _, _, _, _ in
            GitHubActionsRemoteArtifactBytes(data: bytes, suggestedFileName: "out.zip")
        }
        let result = await h.engine.downloadArtifact(
            recordID: record.id, artifactID: 1, workspaceRunID: 90,
            workspaceRoot: URL(fileURLWithPath: "/tmp/ws"), overwrite: false
        )
        #expect(h.commits.count == 1)
        #expect(result?.downloadVerified == true)
        #expect(result?.downloadedSHA256 == digestHex(bytes))
        #expect(result?.downloadedRelativePath == ".floe/artifacts/90/out.zip")
    }

    @Test func artifactDigestMismatchDiscardsAndKeepsPrevious() async {
        let h = makeHarness()
        let previous = Data("previous".utf8)
        var record = artifactRecord(
            runID: 91, requestID: "req-digest-mismatch",
            remoteDigest: "sha256:" + digestHex(Data("attested".utf8))
        )
        record.artifacts[0].downloadedSHA256 = digestHex(previous)
        record.artifacts[0].downloadedRelativePath = ".floe/artifacts/91/out.zip"
        record.artifacts[0].downloadVerified = true
        h.store.seed(record)
        h.remote.downloadHandler = { _, _, _, _, _, _, _, _ in
            GitHubActionsRemoteArtifactBytes(data: Data("tampered".utf8), suggestedFileName: "out.zip")
        }
        let result = await h.engine.downloadArtifact(
            recordID: record.id, artifactID: 1, workspaceRunID: 91,
            workspaceRoot: URL(fileURLWithPath: "/tmp/ws"), overwrite: true
        )
        #expect(result == nil)
        #expect(h.commits.count == 0)
        let stored = h.store.snapshot(id: record.id)
        #expect(stored?.artifacts.first?.downloadedSHA256 == digestHex(previous))
        #expect(stored?.artifacts.first?.downloadedRelativePath == ".floe/artifacts/91/out.zip")
        #expect(stored?.artifacts.first?.downloadVerified == true)
        #expect(h.errors.current.contains { $0.contains("did not match") })
    }

    @Test func artifactDigestMissingIsChecksumOnly() async {
        let h = makeHarness()
        let bytes = Data("zip-unattested".utf8)
        let record = artifactRecord(runID: 92, requestID: "req-digest-missing", remoteDigest: nil)
        h.store.seed(record)
        h.remote.downloadHandler = { _, _, _, _, _, _, _, _ in
            GitHubActionsRemoteArtifactBytes(data: bytes, suggestedFileName: "out.zip")
        }
        let result = await h.engine.downloadArtifact(
            recordID: record.id, artifactID: 1, workspaceRunID: 92,
            workspaceRoot: URL(fileURLWithPath: "/tmp/ws"), overwrite: false
        )
        #expect(h.commits.count == 1)
        #expect(result?.downloadVerified == false)
        #expect(result?.downloadedSHA256 == digestHex(bytes))
    }

    @Test func staleArtifactRefreshCannotResurrectTerminalRun() async {
        let h = makeHarness()
        var record = draft(requestID: "req-stale-race")
        record.runID = 90
        record.state = .running
        record.remoteStatus = "in_progress"
        h.store.seed(record)

        let gate = AsyncGate()
        let entered = Box<Bool>(false)
        h.remote.artifactsHandler = { _, _, _, _ in
            entered.set(true)
            await gate.wait()
            return [
                GitHubActionsRemoteArtifact(
                    id: 1, name: "out.zip", sizeInBytes: 4, expired: false,
                    createdAt: Date(), expiresAt: nil
                )
            ]
        }

        let engine = h.engine
        let recordID = record.id
        let loading = Task { await engine.loadArtifacts(recordID: recordID) }
        for _ in 0..<5_000 where !entered.current { await Task.yield() }
        #expect(entered.current)

        h.remote.queryRunHandler = { _, _, id, _ in
            GitHubActionsRemoteRun(id: id, status: "completed", conclusion: "success", htmlURL: nil)
        }
        _ = await h.engine.refreshOne(id: record.id, reason: .automatic)
        #expect(h.store.snapshot(id: record.id)?.state == .completed)

        await gate.open()
        _ = await loading.value
        let final = h.store.snapshot(id: record.id)
        #expect(final?.state == .completed)
        #expect(final?.remoteConclusion == "success")
        #expect(final?.artifacts.first?.name == "out.zip")
    }

    @Test func legacyArtifactRecordDecodesMissingOptionalFields() throws {
        let legacy = """
        {"id":1,"name":"out","sizeInBytes":4,"expired":false,"createdAt":"2026-01-01T00:00:00Z","expiresAt":null}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let artifact = try decoder.decode(GitHubActionsArtifactRecord.self, from: Data(legacy.utf8))
        #expect(artifact.remoteDigest == nil)
        #expect(artifact.downloadVerified == nil)
        #expect(artifact.downloadedRelativePath == nil)
    }

    @Test func generatedWorkflowsKeepFileNamesOutOfShellSource() {
        for template in IDEGitHubActionsWorkflowCatalog.templates {
            let yaml = template.yaml
            let inputLines = yaml.split(separator: "\n").filter { $0.contains("${{ inputs.target_file }}") }
            #expect(inputLines.count == 1)
            #expect(inputLines.first?.trimmingCharacters(in: .whitespaces) == "FLOE_TARGET_FILE: ${{ inputs.target_file }}")
            #expect(yaml.contains("\"./$FLOE_TARGET_FILE\""))
            #expect(yaml.contains("permissions:\n  contents: read"))
            #expect(yaml.contains("ref: ${{ inputs.snapshot_sha }}"))
            #expect(yaml.contains("persist-credentials: false"))
            #expect(!yaml.contains("actions/checkout@v4"))
            #expect(!yaml.contains("actions/upload-artifact@v4"))
        }
    }

    @Test func storeMergeKeepsTerminalObservationMonotonic() {
        var terminal = draft(requestID: "req-terminal")
        terminal.runID = 77
        terminal.state = .completed
        terminal.remoteStatus = "completed"
        terminal.remoteConclusion = "success"
        terminal.remoteHTMLURL = "https://github.com/o/r/actions/runs/77"
        var stale = terminal
        stale.state = .running
        stale.remoteStatus = "in_progress"
        stale.remoteConclusion = nil
        stale.remoteHTMLURL = nil
        let merged = GitHubActionsJobStore.merge(existing: terminal, incoming: stale)
        #expect(merged.state == .completed)
        #expect(merged.remoteConclusion == "success")
        #expect(merged.remoteStatus == "completed")
        #expect(merged.remoteHTMLURL == "https://github.com/o/r/actions/runs/77")
    }
}
#endif
