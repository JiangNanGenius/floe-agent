// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeCore
import FloeTools
import FloeExecution
import FloePersistence
@testable import FloeApp

private actor OwnedLoopController: LinuxGuestLocalServiceControlling {
    struct Counts: Sendable {
        var snapshots: Int
        var stops: Int
        var cancelledWorker: Bool
        var wrongScope: Bool
    }
    let handle: LinuxGuestLocalServiceHandle
    private var snapshot: LinuxGuestLocalServiceSnapshot
    private var counts = Counts(snapshots: 0, stops: 0, cancelledWorker: false, wrongScope: false)

    init(handle: LinuxGuestLocalServiceHandle, snapshot: LinuxGuestLocalServiceSnapshot) {
        self.handle = handle
        self.snapshot = snapshot
    }
    func startLocalService(environmentID: String, request: LinuxGuestLocalServiceRequest,
        cancellation: CancellationToken?) async throws -> LinuxGuestLocalServiceHandle {
        throw FloeError.internalError("This fixture must not start a guest")
    }
    func localServiceSnapshot(_ handle: LinuxGuestLocalServiceHandle) async -> LinuxGuestLocalServiceSnapshot {
        counts.snapshots += 1
        counts.cancelledWorker = counts.cancelledWorker || Task.isCancelled
        counts.wrongScope = counts.wrongScope || handle != self.handle
        return snapshot
    }
    func stopLocalService(_ handle: LinuxGuestLocalServiceHandle) async {
        counts.stops += 1
        counts.cancelledWorker = counts.cancelledWorker || Task.isCancelled
        counts.wrongScope = counts.wrongScope || handle != self.handle
        // ACK only. The fixture decides separately when tree exit is proven.
    }
    func stopLocalServices(environmentID: String) async { counts.wrongScope = true }
    func setSnapshot(_ snapshot: LinuxGuestLocalServiceSnapshot) { self.snapshot = snapshot }
    func recordedCounts() -> Counts { counts }
}

private actor OwnedLoopCompletion {
    private(set) var finished = false
    func finish() { finished = true }
}

private actor OwnedLoopReadiness {
    private(set) var ids: [UUID] = []
    func record(_ id: UUID) { ids.append(id) }
}

@MainActor final class LocalServiceOwnedLoopTests: XCTestCase {
    private enum FixtureError: Error { case timedOut, returnedBeforeTerminal }

    private func fixture() async throws -> (BackgroundJobStore, BackgroundJob, LinuxGuestLocalServiceHandle) {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = BackgroundJobStore(database: database)
        let job = BackgroundJob(conversationID: UUID(), runID: UUID(), kind: .tool,
            targetTool: "exec.localService", payloadJSON: Data("{}".utf8), state: .running,
            environmentID: "owned-loop-fixture-environment")
        try await store.save(job)
        let handle = LinuxGuestLocalServiceHandle(token: UUID().uuidString,
            environmentID: job.environmentID!, runtime: .shell, pid: 8123, port: 8123,
            forward: .init(hostPort: 8123, guestPort: 8123), logHostPath: "/fixture/service.log",
            logGuestPath: "/fixture/service.log", startedAt: Date())
        return (store, job, handle)
    }

    private func begin(controller: OwnedLoopController, handle: LinuxGuestLocalServiceHandle,
        job: BackgroundJob, store: BackgroundJobStore, cancellation: CancellationToken,
        poll: Duration, retry: Duration,
        isReady: @escaping @Sendable () async -> Bool = { false },
        onServiceReady: (@Sendable (UUID) async -> Void)? = nil
    ) -> (Task<ToolExecutionOutput, any Error>, OwnedLoopCompletion) {
        let completion = OwnedLoopCompletion()
        let parent = Task {
            do {
                let result = try await LocalServiceOwnedLoop.run(controller: controller, handle: handle,
                    jobID: job.id, runtime: "shell", cancellation: cancellation, store: store,
                    previewURL: "http://127.0.0.1:8123/", isReady: isReady,
                    onServiceReady: onServiceReady, pollInterval: poll, stopRetryInterval: retry)
                await completion.finish()
                return result
            } catch {
                await completion.finish()
                throw error
            }
        }
        return (parent, completion)
    }

    private func waitForProgress(_ marker: String, store: BackgroundJobStore, jobID: UUID,
        completion: OwnedLoopCompletion) async throws -> LocalServiceProgress {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if await completion.finished { throw FixtureError.returnedBeforeTerminal }
            if let job = try await store.job(id: jobID), let data = job.progressJSON {
                let progress = try JSONDecoder().decode(LocalServiceProgress.self, from: data)
                if progress.stdout == marker { return progress }
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw FixtureError.timedOut
    }

    private func waitForCompletion(_ completion: OwnedLoopCompletion) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if await completion.finished { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw FixtureError.timedOut
    }

    func testReadyManagedServiceUsesServiceProgressAndRetainsOwnershipUntilExit() async throws {
        let (store, job, handle) = try await fixture()
        let cancellation = CancellationToken(), readiness = OwnedLoopReadiness()
        let controller = OwnedLoopController(handle: handle,
            snapshot: .init(state: "running", alive: true, stdout: "ready"))
        let (parent, completion) = begin(controller: controller, handle: handle, job: job,
            store: store, cancellation: cancellation, poll: .milliseconds(25), retry: .milliseconds(75),
            isReady: { true }, onServiceReady: { await readiness.record($0) })
        do {
            let progress = try await waitForProgress("ready", store: store, jobID: job.id, completion: completion)
            let savedReady = try await store.job(id: job.id)
            let ready = try XCTUnwrap(savedReady)
            XCTAssertEqual(progress.state, "running")
            XCTAssertNotNil(progress.previewURL)
            XCTAssertEqual(ready.state, .running)
            XCTAssertNil(ready.completedAt, "Readiness is not service completion")
            XCTAssertEqual(ready.serviceState, .running)
            XCTAssertNotNil(ready.servicePreviewURL)

            let finite = BackgroundJob(conversationID: job.conversationID, runID: job.runID,
                kind: .tool, targetTool: "exec.shell", payloadJSON: Data("{}".utf8), state: .cancelled)
            let queued = BackgroundJob(conversationID: job.conversationID, runID: job.runID,
                kind: .tool, targetTool: "exec.localService", payloadJSON: Data("{}".utf8))
            var stopped = ready
            stopped.id = UUID(); stopped.state = .cancelled
            try await store.save(finite)
            try await store.save(queued)
            try await store.save(stopped)
            let records = try await store.jobs(conversationID: job.conversationID)
            let partition = BackgroundJobProgressPartition(records)
            XCTAssertEqual(partition.tasks.map(\.id), [finite.id])
            XCTAssertEqual(partition.cancelledTaskCount, 1, "Stopped services cannot inflate cancelled-task counts")
            XCTAssertEqual(LocalServicePresentation.statusKey(for: stopped), "services.state.cancelled")
            XCTAssertEqual(stopped.serviceState, .stopped)
            XCTAssertNil(stopped.servicePreviewURL)
            XCTAssertEqual(finite.state, .cancelled)
            XCTAssertNil(finite.serviceState)
            let counts = BackgroundWorkSessionCounts(runningJobs: partition.runningTaskCount,
                queuedJobs: partition.queuedTaskCount, activeServices: partition.activeServiceCount)
            XCTAssertEqual(counts.totalAdmitted, 0)
            XCTAssertEqual(counts.activeServices, 2, "Queued and running services both retain ownership")
            XCTAssertTrue(counts.hasAcceptedWork)
            XCTAssertFalse(BackgroundWorkSessionPolicy.shouldReleaseBackgroundLocation(counts: counts))
            let serviceDecision = BackgroundWorkSessionPolicy.activeState(for: counts)
            let serviceSnapshot = BackgroundWorkSessionSnapshot(state: serviceDecision.state,
                waitReason: serviceDecision.waitReason, counts: counts)
            XCTAssertTrue(serviceSnapshot.showsServiceOnlyActivity,
                "Home and qualification must show services, not a nonexistent due schedule")
            let queuedPartition = BackgroundJobProgressPartition([queued])
            let queuedOnly = BackgroundWorkSessionCounts(activeServices: queuedPartition.activeServiceCount)
            XCTAssertTrue(queuedOnly.hasAcceptedWork)
            XCTAssertEqual(queuedOnly.totalAdmitted, 0)
            let queuedDecision = BackgroundWorkSessionPolicy.activeState(for: queuedOnly)
            XCTAssertEqual(queuedDecision.state, .waiting, "Queued services are not proof of execution")
            XCTAssertTrue(BackgroundWorkSessionSnapshot(state: queuedDecision.state,
                waitReason: queuedDecision.waitReason, counts: queuedOnly).showsServiceOnlyActivity)
            var otherWork = serviceSnapshot
            otherWork.counts.runningJobs = 1
            XCTAssertFalse(otherWork.showsServiceOnlyActivity)
            otherWork = serviceSnapshot
            otherWork.counts.pendingApprovals = 1
            XCTAssertFalse(otherWork.showsServiceOnlyActivity)
            otherWork = serviceSnapshot
            otherWork.counts.enabledSchedules = 1
            XCTAssertFalse(otherWork.showsServiceOnlyActivity, "Real future schedules retain their due-work explanation")
            var legacy = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(counts)) as? [String: Any])
            legacy.removeValue(forKey: "activeServices")
            let decodedLegacy = try JSONDecoder().decode(BackgroundWorkSessionCounts.self,
                from: JSONSerialization.data(withJSONObject: legacy))
            XCTAssertEqual(decodedLegacy.activeServices, 0)
            var legacySnapshot = try XCTUnwrap(try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(serviceSnapshot)) as? [String: Any])
            legacySnapshot["counts"] = legacy
            let restoredLegacy = try JSONDecoder().decode(BackgroundWorkSessionSnapshot.self,
                from: JSONSerialization.data(withJSONObject: legacySnapshot))
            XCTAssertEqual(restoredLegacy.waitReason, .dueWork)
            XCTAssertFalse(restoredLegacy.showsServiceOnlyActivity)

            cancellation.cancel()
            // Poll a new marker to prove the explicit Stop was processed.
            await controller.setSnapshot(.init(state: "running", alive: true, stdout: "stopping"))
            _ = try await waitForProgress("stopping", store: store, jobID: job.id, completion: completion)
            let unjoined = await completion.finished
            let savedStopping = try await store.job(id: job.id)
            let stoppingRecord = try XCTUnwrap(savedStopping)
            XCTAssertFalse(unjoined, "A stop ACK cannot release a service before process-tree exit")
            XCTAssertEqual(stoppingRecord.state, .running)
            XCTAssertEqual(stoppingRecord.serviceState, .stopping)
            XCTAssertNil(stoppingRecord.servicePreviewURL)
            let stoppingCounts = BackgroundWorkSessionCounts(
                activeServices: BackgroundJobProgressPartition([stoppingRecord]).activeServiceCount)
            let stoppingDecision = BackgroundWorkSessionPolicy.activeState(for: stoppingCounts)
            XCTAssertTrue(BackgroundWorkSessionSnapshot(state: stoppingDecision.state,
                waitReason: stoppingDecision.waitReason, counts: stoppingCounts).showsServiceOnlyActivity)
            XCTAssertTrue(stoppingCounts.hasAcceptedWork, "Neutral presentation cannot release an unjoined service")
            await controller.setSnapshot(.init(state: "stopped", alive: false, stdout: "confirmed"))
            try await waitForCompletion(completion)
            let output = try await parent.value
            XCTAssertEqual(output.exitStatus, 0)
            let announcements = await readiness.ids
            XCTAssertEqual(announcements, [job.id], "Native readiness is announced exactly once")
            let owned = await controller.recordedCounts()
            XCTAssertFalse(owned.wrongScope)
            XCTAssertFalse(owned.cancelledWorker)
        } catch {
            cancellation.cancel()
            await controller.setSnapshot(.init(state: "stopped", alive: false))
            try await waitForCompletion(completion)
            _ = try? await parent.value
            throw error
        }
    }

    func testUnknownAndAliveSnapshotsKeepTheSameRunningJobOwned() async throws {
        let (store, job, handle) = try await fixture()
        let cancellation = CancellationToken()
        let controller = OwnedLoopController(handle: handle,
            snapshot: .init(state: "unavailable", alive: false, stdout: "unknown-0"))
        let (parent, completion) = begin(controller: controller, handle: handle, job: job,
            store: store, cancellation: cancellation, poll: .milliseconds(25), retry: .milliseconds(75))
        do {
            let samples: [(String, Bool)] = [
                ("unavailable", false), ("failed", false), ("stopped", true),
                ("notFound", true), ("completed", false), ("running", true)
            ]
            for (index, sample) in samples.enumerated() {
                let marker = "unknown-\(index)"
                await controller.setSnapshot(.init(state: sample.0, alive: sample.1, stdout: marker))
                let progress = try await waitForProgress(marker, store: store, jobID: job.id, completion: completion)
                XCTAssertEqual(progress.state, "stopping")
                XCTAssertNil(progress.previewURL)
                let saved = try await store.job(id: job.id)
                XCTAssertEqual(saved?.state, .running)
                XCTAssertEqual(saved?.environmentID, handle.environmentID)
                let active = try await store.activeJobs(environmentID: handle.environmentID)
                XCTAssertEqual(active.map(\.id), [job.id])
            }
            await controller.setSnapshot(.init(state: "stopped", alive: false, stdout: "confirmed"))
            try await waitForCompletion(completion)
            let output = try await parent.value
            XCTAssertEqual(output.exitStatus, 1, "A failed/unknown service must not become successful cleanup")
            let saved = try await store.job(id: job.id)
            let progress = try JSONDecoder().decode(LocalServiceProgress.self, from: XCTUnwrap(saved?.progressJSON))
            XCTAssertEqual(progress.state, "stopped")
            XCTAssertEqual(progress.stdout, "confirmed")
            // Only BackgroundJobService owns the subsequent terminal commit.
            XCTAssertEqual(saved?.state, .running)
            let counts = await controller.recordedCounts()
            XCTAssertGreaterThan(counts.stops, 0)
            XCTAssertFalse(counts.wrongScope)
            XCTAssertFalse(counts.cancelledWorker)
        } catch {
            await controller.setSnapshot(.init(state: "stopped", alive: false))
            try await waitForCompletion(completion)
            _ = try? await parent.value
            throw error
        }
    }

    func testParentCancellationBacksOffAndJoinsOnlyAfterConfirmedTreeExit() async throws {
        let (store, job, handle) = try await fixture()
        let cancellation = CancellationToken()
        let controller = OwnedLoopController(handle: handle,
            snapshot: .init(state: "running", alive: true, stdout: "started"))
        let (parent, completion) = begin(controller: controller, handle: handle, job: job,
            store: store, cancellation: cancellation, poll: .milliseconds(50), retry: .milliseconds(100))
        do {
            _ = try await waitForProgress("started", store: store, jobID: job.id, completion: completion)
            await controller.setSnapshot(.init(state: "unavailable", alive: false, stdout: "waiting-for-proof"))
            let before = await controller.recordedCounts()
            let cancelledAt = ContinuousClock.now
            parent.cancel()
            let progress = try await waitForProgress("waiting-for-proof", store: store, jobID: job.id, completion: completion)
            XCTAssertEqual(progress.state, "stopping")
            XCTAssertTrue(cancellation.isCancelled)
            try await Task.sleep(for: .milliseconds(230))
            let waiting = await controller.recordedCounts()
            let elapsed = cancelledAt.duration(to: ContinuousClock.now).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            let finished = await completion.finished
            XCTAssertFalse(finished, "Cancelling the parent must not release an unconfirmed worker")
            XCTAssertGreaterThanOrEqual(waiting.stops, 2, "An unconfirmed stop must be retried")
            XCTAssertLessThanOrEqual(waiting.snapshots - before.snapshots, Int(ceil(seconds / 0.05)) + 3,
                "Cancellation must not busy-spin")
            XCTAssertLessThanOrEqual(waiting.stops, Int(ceil(seconds / 0.1)) + 2,
                "Stop attempts must be spaced, not hammered")
            XCTAssertFalse(waiting.cancelledWorker)
            XCTAssertFalse(waiting.wrongScope)
            let retained = try await store.activeJobs(environmentID: handle.environmentID)
            XCTAssertEqual(retained.map(\.id), [job.id])
            await controller.setSnapshot(.init(state: "notFound", alive: false, stdout: "confirmed-exit"))
            try await waitForCompletion(completion)
            let output = try await parent.value
            XCTAssertEqual(output.exitStatus, 0)
            let saved = try await store.job(id: job.id)
            let finalProgress = try JSONDecoder().decode(LocalServiceProgress.self, from: XCTUnwrap(saved?.progressJSON))
            XCTAssertEqual(finalProgress.state, "notFound")
            XCTAssertEqual(finalProgress.stdout, "confirmed-exit")
            XCTAssertEqual(saved?.state, .running)
        } catch {
            await controller.setSnapshot(.init(state: "stopped", alive: false))
            try await waitForCompletion(completion)
            _ = try? await parent.value
            throw error
        }
    }
}
