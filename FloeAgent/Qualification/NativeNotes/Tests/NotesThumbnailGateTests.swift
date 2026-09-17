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

    /// Cancelling before the first attempt starts must prevent any generator
    /// request at all: the retry loop's cancellation check runs before
    /// attempt one, so `attempts` stays zero.
    func testSharedThumbnailRequestHonoursCancellationPromptly() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-thumb-cancel-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("preview.docx")
        try? Data("not a real package".utf8).write(to: file)

        let policy = NotesOfficeThumbnailPolicy(
            perAttemptTimeout: .seconds(30), maxAttempts: 3, totalDeadline: .seconds(90),
            initialBackoff: .milliseconds(10), maximumBackoff: .milliseconds(50))
        let start = ContinuousClock.now
        let task = Task {
            await NotesOfficeThumbnailGenerator.thumbnail(
                url: file, size: CGSize(width: 320, height: 420), policy: policy)
        }
        task.cancel()
        let outcome = await task.value
        XCTAssertNil(outcome.image)
        XCTAssertEqual(outcome.attempts, 0,
                       "cancellation before the first attempt must prevent any generator request")
        XCTAssertLessThan(start.duration(to: ContinuousClock.now), .seconds(10),
                          "a cancelled thumbnail request must settle promptly, not after the 30s timeout")
    }

    /// Cancellation while a request is genuinely in flight must settle
    /// promptly: the injected request hangs until the per-attempt timeout, so
    /// only an explicit cancellation path can return before 30s. The request
    /// closure fulfills `started` as its first statement, so `task.cancel()`
    /// only runs after the first attempt is deterministically in flight; the
    /// retry loop must then not start attempt two, and the whole card request
    /// must finish far inside the total deadline.
    func testInFlightThumbnailRequestCancelsPromptly() async {
        let policy = NotesOfficeThumbnailPolicy(
            perAttemptTimeout: .seconds(30), maxAttempts: 3, totalDeadline: .seconds(90),
            initialBackoff: .milliseconds(10), maximumBackoff: .milliseconds(50))
        let started = expectation(description: "first attempt is in flight")
        let start = ContinuousClock.now
        let task = Task {
            await NotesOfficeThumbnailGenerator.thumbnail(
                url: URL(fileURLWithPath: "/nonexistent/preview.docx"),
                size: CGSize(width: 320, height: 420),
                policy: policy,
                request: { _, _, _ in
                    started.fulfill()
                    // Hangs until cancelled (or 30s); returning here would
                    // mean cancellation failed to interrupt the in-flight work.
                    try? await Task.sleep(for: .seconds(30))
                    return NotesOfficeThumbnailGenerator.AttemptOutcome(
                        image: nil, diagnosis: "injected hang", timedOut: false, elapsed: .seconds(30))
                })
        }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        let outcome = await task.value
        XCTAssertNil(outcome.image)
        XCTAssertEqual(outcome.attempts, 1,
                       "a cancelled in-flight request must not start a second attempt")
        XCTAssertLessThan(start.duration(to: ContinuousClock.now), .seconds(10),
                          "an in-flight cancelled request must settle promptly, not after the 30s timeout")
    }
}
