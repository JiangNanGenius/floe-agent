// SPDX-License-Identifier: MPL-2.0
import XCTest
@testable import FloeNotesNativeQualification

@MainActor
final class NotesThumbnailGateTests: XCTestCase {
    func testCancelledQueuedPreviewDoesNotConsumeTheNextSlot() async {
        let gate = NotesOfficeThumbnailGate(limit: 1)
        let first = await gate.acquire(id: UUID())
        XCTAssertTrue(first)
        let cancelled = Task { await gate.acquire(id: UUID()) }
        await Task.yield()
        cancelled.cancel()
        let acquired = await cancelled.value
        XCTAssertFalse(acquired)
        gate.release()
        let next = await gate.acquire(id: UUID())
        XCTAssertTrue(next)
        gate.release()
    }

    func testRapidCardLoadsAndCancellationEventuallyReleaseEverySlot() async {
        let gate = NotesOfficeThumbnailGate(limit: 2)
        let finished = expectation(description: "all scrolling card tasks settle")
        finished.expectedFulfillmentCount = 100
        var active = 0
        var maximumActive = 0
        let tasks = (0..<100).map { _ in
            Task { @MainActor in
                defer { finished.fulfill() }
                guard await gate.acquire(id: UUID()) else { return }
                defer { gate.release(); active -= 1 }
                active += 1
                maximumActive = max(maximumActive, active)
                await Task.yield()
            }
        }
        for index in stride(from: 0, to: tasks.count, by: 3) { tasks[index].cancel() }
        await fulfillment(of: [finished], timeout: 5)
        for task in tasks { task.cancel() }
        XCTAssertLessThanOrEqual(maximumActive, 2)
        XCTAssertEqual(active, 0)
    }
}
