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
        poll: Duration, retry: Duration) -> (Task<ToolExecutionOutput, any Error>, OwnedLoopCompletion) {
        let completion = OwnedLoopCompletion()
        let parent = Task {
            do {
                let result = try await LocalServiceOwnedLoop.run(controller: controller, handle: handle,
                    jobID: job.id, runtime: "shell", cancellation: cancellation, store: store,
                    previewURL: "http://127.0.0.1:8123/", pollInterval: poll, stopRetryInterval: retry)
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
