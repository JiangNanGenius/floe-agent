// SPDX-License-Identifier: MPL-2.0
//
// G03-R4 — the App-facing durable job surface over the ORIGINAL service/store.
// AUTHORED, NOT EXECUTED here. No device, engine, provider or command is used.
import XCTest
import Foundation
import FloeTools
import FloePersistence
@testable import FloeAndroidJobTools

final class BackgroundJobSurfaceTests: XCTestCase {
    private func makeService() async throws
        -> (BackgroundJobService, BackgroundJobStore) {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = BackgroundJobStore(database: database)
        let service = BackgroundJobService(store: store,
                                           registry: ToolRunnerRegistry())
        return (service, store)
    }

    private func job(conversationID: UUID, runID: UUID,
                     target: String = "exec.shell") -> BackgroundJob {
        BackgroundJob(conversationID: conversationID, runID: runID,
                      kind: .tool, targetTool: target,
                      payloadJSON: Data("{}".utf8))
    }

    func testListingIsTaskScopedAndRunNarrowed() async throws {
        let (service, store) = try await makeService()
        let conversationA = UUID()
        let conversationB = UUID()
        let runA1 = UUID()
        let runA2 = UUID()
        let jobA1 = try await store.submit(job(conversationID: conversationA, runID: runA1))
        let jobA2 = try await store.submit(job(conversationID: conversationA, runID: runA2))
        let jobB = try await store.submit(job(conversationID: conversationB, runID: UUID()))

        let wholeTask = try await service.jobs(conversationID: conversationA)
        XCTAssertEqual(Set(wholeTask.map(\.id)), Set([jobA1.id, jobA2.id]))
        XCTAssertFalse(wholeTask.contains { $0.id == jobB.id })

        let narrowed = try await service.jobs(conversationID: conversationA,
                                              runID: runA1)
        XCTAssertEqual(narrowed.map(\.id), [jobA1.id])
        // A foreign run identity can never widen the task scope.
        let foreignRun = try await service.jobs(conversationID: conversationA,
                                                runID: jobB.runID)
        XCTAssertTrue(foreignRun.isEmpty)
    }

    func testQueuedCancelIsTerminalButRunningCancelIsOnlyARequest() async throws {
        let (service, store) = try await makeService()
        let conversationID = UUID()
        let queued = try await store.submit(
            job(conversationID: conversationID, runID: UUID()))
        let cancelled = try await service.cancel(id: queued.id)
        XCTAssertEqual(cancelled.state, .cancelled)
        XCTAssertTrue(cancelled.state.isTerminal)

        let running = try await store.submit(
            job(conversationID: conversationID, runID: UUID()))
        _ = try await store.transition(id: running.id, to: .running)
        let requested = try await service.cancel(id: running.id)
        XCTAssertEqual(requested.state, .running,
                       "a running cancel is a request, never a fake terminal")
        XCTAssertFalse(requested.state.isTerminal)
        XCTAssertEqual(requested.lastError?.contains("waiting for the processor") == true,
                       true)

        // A job that finished first keeps its ACTUAL terminal state.
        let done = try await store.submit(
            job(conversationID: conversationID, runID: UUID()))
        _ = try await store.transition(id: done.id, to: .running)
        _ = try await store.transition(id: done.id, to: .completed)
        let kept = try await service.cancel(id: done.id)
        XCTAssertEqual(kept.state, .completed)
    }

    func testManagedServiceCompletionIsNotAReadinessResolution() {
        var service = job(conversationID: UUID(), runID: UUID(),
                          target: "exec.localService")
        service.state = .completed
        XCTAssertEqual(BackgroundJobService.dependencyResolution(for: service).state,
                       .failed,
                       "a service that exits before readiness is not a satisfied dependency")
        service.state = .running
        XCTAssertEqual(BackgroundJobService.dependencyResolution(for: service).state,
                       .pending)
        var finite = job(conversationID: UUID(), runID: UUID())
        finite.state = .completed
        XCTAssertEqual(BackgroundJobService.dependencyResolution(for: finite).state,
                       .resolved)
        finite.state = .cancelled
        XCTAssertEqual(BackgroundJobService.dependencyResolution(for: finite).state,
                       .cancelled)
    }

    func testCancelNeverClaimsTerminalForAnUnacknowledgedProcessor() async throws {
        let (service, store) = try await makeService()
        let conversationID = UUID()
        let job = try await store.submit(
            job(conversationID: conversationID, runID: UUID()))
        _ = try await store.transition(id: job.id, to: .running)
        _ = try await service.cancel(id: job.id)
        let first = try await service.job(id: job.id)
        XCTAssertEqual(first?.state, .running)
        // The processor acknowledgement is the ONLY writer of the terminal.
        _ = try await store.transition(id: job.id, to: .cancelled) {
            $0.lastError = "Cancelled by the processor after real cleanup."
        }
        let settled = try await service.job(id: job.id)
        XCTAssertEqual(settled?.state, .cancelled)
    }
}
