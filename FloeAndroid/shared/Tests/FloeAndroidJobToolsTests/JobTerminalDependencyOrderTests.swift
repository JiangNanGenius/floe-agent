// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeTools
import FloePersistence
@testable import FloeAndroidJobTools

private actor JobTerminalDependencyObservation {
    struct Value: Sendable {
        let pendingCount: Int?
        let state: RunDependencyState?
    }
    private var value: Value?
    func record(pendingCount: Int?, state: RunDependencyState?) {
        value = Value(pendingCount: pendingCount, state: state)
    }
    func snapshot() -> Value? { value }
}

final class JobTerminalDependencyOrderTests: XCTestCase {
    /// A terminal callback is the consumer's opportunity to resume a parked
    /// run. Its first durable read must see the resolved edge, even when that
    /// write suspends. No engine, device, provider or real command is used.
    func testTerminalCallbackSeesCommittedDependencyAfterQueuedCancellation() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = BackgroundJobStore(database: database)
        let dependencies = SQLiteRunDependencyStore(database: database)
        let observation = JobTerminalDependencyObservation()
        let job = try await store.submit(BackgroundJob(
            conversationID: UUID(), runID: UUID(), kind: .tool,
            targetTool: "exec.shell", payloadJSON: Data("{}".utf8)))
        try await dependencies.register(RunDependencyRecord(
            jobID: job.id, runID: job.runID,
            conversationID: job.conversationID, kind: "job"))
        let service = BackgroundJobService(
            store: store, registry: ToolRunnerRegistry(),
            onTerminal: { terminal in
                let pending = try? await dependencies.pending(runID: terminal.runID)
                let edge = try? await dependencies.record(jobID: terminal.id)
                await observation.record(pendingCount: pending?.count, state: edge?.state)
            },
            resolveDependency: { id, state, note in
                // Widen the actual write suspension that previously raced the
                // independent terminal callback, rather than mocking a read.
                try? await Task.sleep(nanoseconds: 50_000_000)
                _ = try? await dependencies.resolve(jobID: id, state: state, note: note)
            })
        let cancelled = try await service.cancel(id: job.id)
        XCTAssertEqual(cancelled.state, .cancelled)
        let delivered = await jobWaitUntil { await observation.snapshot() != nil }
        XCTAssertTrue(delivered, "the original terminal callback must still be delivered")
        let value = await observation.snapshot()
        XCTAssertEqual(value?.pendingCount, 0,
                       "the callback must not lose the continuation to a pending-edge race")
        XCTAssertEqual(value?.state, .cancelled)
    }
}
