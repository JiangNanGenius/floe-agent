// SPDX-License-Identifier: MPL-2.0
import XCTest
import UIKit
import FloeNotes
import FloeDocuments
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
            maxAttempts: 3, totalDeadline: .seconds(90),
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
            maxAttempts: 3, totalDeadline: .seconds(90),
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

    // MARK: - Bounded generator lifecycle (deterministic driver seam)

    /// The product request lifecycle with a driver that never replies: the
    /// bounded deadline must cancel the outstanding request exactly once, settle
    /// as timed out, and drop a callback that arrives after the settle.
    func testRequestDeadlineCancelsOutstandingGeneratorOnceAndDropsLateCallback() async {
        let started = expectation(description: "generator request started")
        let probe = NotesThumbnailDriverProbe()
        let driver = NotesQuickLookRequestDriver(
            start: { completion in
                probe.completion = completion
                started.fulfill()
            },
            cancel: { probe.cancelCount += 1 })

        let start = ContinuousClock.now
        let task = Task { @MainActor in
            await NotesOfficeThumbnailGenerator.drive(driver, timeout: .milliseconds(250))
        }
        await fulfillment(of: [started], timeout: 5)
        let outcome = await task.value
        XCTAssertNil(outcome.image)
        XCTAssertTrue(outcome.timedOut, "a driver that never replies must settle as timed out")
        XCTAssertEqual(probe.cancelCount, 1,
                       "the outstanding generator request must be cancelled exactly once")
        XCTAssertLessThan(start.duration(to: ContinuousClock.now), .seconds(10),
                          "the deadline must settle promptly, not hang")

        // A late callback after the settle is dropped by the single-resume
        // state: no crash, no second delivery, no second cancel.
        probe.deliver(.content(image: NotesThumbnailDriverProbe.image(), diagnosis: nil))
        await Task.yield()
        XCTAssertEqual(probe.cancelCount, 1)
    }

    /// Cancelling the owning task while a request is outstanding must cancel the
    /// generator request once and settle with the cancellation diagnosis.
    func testOwningTaskCancellationCancelsOutstandingGeneratorOnce() async {
        let started = expectation(description: "generator request started")
        let probe = NotesThumbnailDriverProbe()
        let driver = NotesQuickLookRequestDriver(
            start: { completion in
                probe.completion = completion
                started.fulfill()
            },
            cancel: { probe.cancelCount += 1 })

        let start = ContinuousClock.now
        let task = Task { @MainActor in
            await NotesOfficeThumbnailGenerator.drive(driver, timeout: .seconds(30))
        }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        let outcome = await task.value
        XCTAssertNil(outcome.image)
        XCTAssertFalse(outcome.timedOut)
        XCTAssertEqual(outcome.diagnosis, "task cancelled")
        XCTAssertEqual(probe.cancelCount, 1)
        XCTAssertLessThan(start.duration(to: ContinuousClock.now), .seconds(10),
                          "cancellation must settle promptly, not after the 30s deadline")
        probe.deliver(.content(image: NotesThumbnailDriverProbe.image(), diagnosis: nil))
        await Task.yield()
        XCTAssertEqual(probe.cancelCount, 1)
    }

    /// A request that is merely late is never restarted: the bounded loop treats
    /// a timed-out attempt as terminal because the extension host may still hold
    /// it. This is the deterministic seam for the measured build 185
    /// cancel/restart storm.
    func testBoundedLoopDoesNotRestartAfterTimeout() async {
        var calls = 0
        let outcome = await NotesOfficeThumbnailGenerator.thumbnail(
            url: URL(fileURLWithPath: "/nonexistent/preview.docx"),
            size: CGSize(width: 320, height: 420), fileExtension: "docx",
            policy: NotesOfficeThumbnailPolicy(maxAttempts: 3, totalDeadline: .seconds(30),
                                               initialBackoff: .milliseconds(10),
                                               maximumBackoff: .milliseconds(50)),
            request: { _, _, _ in
                calls += 1
                return NotesOfficeThumbnailGenerator.AttemptOutcome(
                    image: nil, diagnosis: "request deadline", timedOut: true, elapsed: .zero)
            })
        XCTAssertEqual(calls, 1,
                       "a timed-out request must not be restarted while the host may still hold it")
        XCTAssertEqual(outcome.attempts, 1)
        XCTAssertTrue(outcome.timedOut)
        XCTAssertNil(outcome.image)
    }

    /// Only a settled generator failure may retry; a later attempt can still
    /// succeed inside the total budget and publishes a real image.
    func testBoundedLoopRetriesAfterSettledFailureWithinBudget() async {
        var calls = 0
        let outcome = await NotesOfficeThumbnailGenerator.thumbnail(
            url: URL(fileURLWithPath: "/nonexistent/preview.docx"),
            size: CGSize(width: 320, height: 420), fileExtension: "docx",
            policy: NotesOfficeThumbnailPolicy(maxAttempts: 3, totalDeadline: .seconds(30),
                                               initialBackoff: .milliseconds(10),
                                               maximumBackoff: .milliseconds(50)),
            request: { _, _, _ in
                calls += 1
                if calls == 1 {
                    return NotesOfficeThumbnailGenerator.AttemptOutcome(
                        image: nil, diagnosis: "transient generator failure", timedOut: false,
                        elapsed: .zero, errorDomain: "QLThumbnailErrorDomain", errorCode: 1)
                }
                return NotesOfficeThumbnailGenerator.AttemptOutcome(
                    image: NotesThumbnailDriverProbe.image(), diagnosis: "content",
                    timedOut: false, elapsed: .zero)
            })
        XCTAssertEqual(calls, 2, "a settled failure may retry once inside the budget")
        XCTAssertEqual(outcome.attempts, 2)
        XCTAssertNotNil(outcome.image)
    }

    // MARK: - Production service-path coalescing

    /// Production wiring check: two concurrent cover renders for the same
    /// resource must share one service-owned operation. The second card joins
    /// the flight *before* the shared host slot, so only one generator request
    /// is ever made, both cards receive the same real cover, and the shared
    /// operation cleans up its single staged copy. This exercises
    /// `NotesDocumentCoverService.render` end to end; an isolated registry test
    /// cannot catch a cover-service caller that waits for the gate first.
    func testConcurrentCoverRendersForOneResourceShareOneBoundedRequest() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-cover-coalesce-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, document) = try await makeOfficeDocument(root: root)
        let size = CGSize(width: 320, height: 420)
        let maximumSourceBytes = 128 * 1024 * 1024
        let key = NotesDocumentCoverService.officeResourceKey(
            document: document, store: store, fileExtension: "docx",
            size: size, maximumSourceBytes: maximumSourceBytes)

        let started = expectation(description: "shared cover operation reached the generator seam")
        let probe = NotesThumbnailDriverProbe()
        let seam: @MainActor (URL, CGSize, Duration) async -> NotesOfficeThumbnailGenerator.AttemptOutcome = { staged, _, _ in
            probe.calls += 1
            probe.stagedURL = staged
            probe.stagedExisted = FileManager.default.fileExists(atPath: staged.path)
            // Only the shared operation's first (and expected only) request
            // suspends. A regression that issues a second request returns
            // immediately with a real image so the call-count assertion fails
            // instead of hanging the suite.
            if probe.calls == 1 {
                started.fulfill()
                await withCheckedContinuation { probe.release = $0 }
            }
            return NotesOfficeThumbnailGenerator.AttemptOutcome(
                image: NotesThumbnailDriverProbe.image(), diagnosis: "content",
                timedOut: false, elapsed: .zero)
        }
        let first = Task { @MainActor in
            await NotesDocumentCoverService.render(document: document, store: store, size: size,
                                                   maximumSourceBytes: maximumSourceBytes, request: seam)
        }
        await fulfillment(of: [started], timeout: 5)
        let second = Task { @MainActor in
            await NotesDocumentCoverService.render(document: document, store: store, size: size,
                                                   maximumSourceBytes: maximumSourceBytes, request: seam)
        }
        let joinDeadline = ContinuousClock.now + .seconds(5)
        while NotesOfficeCoverFlights.shared.waiterCount(forKey: key) < 2,
              ContinuousClock.now < joinDeadline {
            await Task.yield()
        }
        XCTAssertGreaterThanOrEqual(NotesOfficeCoverFlights.shared.waiterCount(forKey: key), 2,
                                    "the second card must join the shared operation before the host slot")
        XCTAssertEqual(probe.calls, 1, "the second card must not issue its own generator request")
        XCTAssertTrue(probe.stagedExisted ?? false,
                      "the shared operation must stage the document's own bytes")

        probe.release?.resume()
        probe.release = nil
        let firstOutcome = await first.value
        let secondOutcome = await second.value
        XCTAssertEqual(probe.calls, 1,
                       "the production service path must coalesce, not only an isolated registry")
        XCTAssertEqual(firstOutcome.source, .quickLookThumbnail)
        XCTAssertNotNil(firstOutcome.image)
        XCTAssertEqual(secondOutcome.source, .quickLookThumbnail)
        XCTAssertNotNil(secondOutcome.image, "the coalesced waiter must receive the shared real cover")
        if let staged = probe.stagedURL {
            XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path),
                           "the shared operation must remove its staged copy once it settles")
        }
    }

    /// Staging belongs to the shared operation, not to the first caller: a
    /// cancelled first waiter must neither cancel the second waiter's operation
    /// nor delete the staged copy it is still using. The shared result is still
    /// delivered to both waiters.
    func testCancelledFirstWaiterKeepsSharedOperationAndStagedCopyAlive() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-cover-cancel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, document) = try await makeOfficeDocument(root: root)
        let size = CGSize(width: 320, height: 420)
        let maximumSourceBytes = 128 * 1024 * 1024
        let key = NotesDocumentCoverService.officeResourceKey(
            document: document, store: store, fileExtension: "docx",
            size: size, maximumSourceBytes: maximumSourceBytes)

        let started = expectation(description: "shared cover operation reached the generator seam")
        let probe = NotesThumbnailDriverProbe()
        let seam: @MainActor (URL, CGSize, Duration) async -> NotesOfficeThumbnailGenerator.AttemptOutcome = { staged, _, _ in
            probe.calls += 1
            probe.stagedURL = staged
            // Only the shared operation's first request suspends; a regression
            // that restarts the request returns immediately so the call-count
            // assertion fails instead of hanging the suite.
            if probe.calls == 1 {
                started.fulfill()
                await withCheckedContinuation { probe.release = $0 }
            }
            return NotesOfficeThumbnailGenerator.AttemptOutcome(
                image: NotesThumbnailDriverProbe.image(), diagnosis: "content",
                timedOut: false, elapsed: .zero)
        }
        let first = Task { @MainActor in
            await NotesDocumentCoverService.render(document: document, store: store, size: size,
                                                   maximumSourceBytes: maximumSourceBytes, request: seam)
        }
        await fulfillment(of: [started], timeout: 5)
        let second = Task { @MainActor in
            await NotesDocumentCoverService.render(document: document, store: store, size: size,
                                                   maximumSourceBytes: maximumSourceBytes, request: seam)
        }
        let joinDeadline = ContinuousClock.now + .seconds(5)
        while NotesOfficeCoverFlights.shared.waiterCount(forKey: key) < 2,
              ContinuousClock.now < joinDeadline {
            await Task.yield()
        }
        XCTAssertGreaterThanOrEqual(NotesOfficeCoverFlights.shared.waiterCount(forKey: key), 2)

        first.cancel()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(probe.calls, 1, "the cancelled first waiter must not restart the shared request")
        if let staged = probe.stagedURL {
            XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path),
                          "the shared operation's staged copy must survive a cancelled first waiter")
        }

        probe.release?.resume()
        probe.release = nil
        let secondOutcome = await second.value
        let firstOutcome = await first.value
        XCTAssertEqual(secondOutcome.source, .quickLookThumbnail)
        XCTAssertNotNil(secondOutcome.image, "the remaining waiter must still receive the real cover")
        XCTAssertEqual(firstOutcome.source, .quickLookThumbnail,
                       "the shared operation's result is still delivered to the cancelled waiter")
        XCTAssertEqual(probe.calls, 1)
        if let staged = probe.stagedURL {
            XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path),
                           "the shared operation must remove its staged copy once it settles")
        }
    }

    /// Creates a real generated Word package, imports it through the shared
    /// Notes importer and returns the store plus the created document.
    private func makeOfficeDocument(root: URL) async throws -> (NotesStore, NoteDocument) {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("coalesce.docx")
        try OfficeDocumentBuilder.createWord(at: source, title: "并发封面验收", paragraphs: ["并发封面合成样本"])
        let store = try NotesStore(root: root.appendingPathComponent("store"))
        let draft = try await NoteFileImporter.importFile(source, notebookID: nil, store: store)
        return (store, try await store.create(draft))
    }

    /// The shared app-wide gate admits one Office cover host request at a time,
    /// so a second card cannot consume its deadline while the shared extension
    /// host is busy with another card. The waiters are served first-in,
    /// first-out and a cancelled waiter is removed without consuming a slot.
    func testSharedHostGateAdmitsOneRequestAtATime() async {
        let first = await NotesOfficeThumbnailGate.shared.acquire(id: UUID())
        XCTAssertTrue(first)
        var secondAdmitted = false
        let second = Task { @MainActor in
            secondAdmitted = await NotesOfficeThumbnailGate.shared.acquire(id: UUID())
        }
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(secondAdmitted,
                       "a queued card must not be admitted while the single host slot is held")
        NotesOfficeThumbnailGate.shared.release()
        await second.value
        XCTAssertTrue(secondAdmitted)
        NotesOfficeThumbnailGate.shared.release()
    }
}

/// Deterministic driver probe for the bounded request lifecycle. It never
/// touches Quick Look: it holds the completion, counts cancels and records the
/// service-owned request count and staged copy for the single-flight tests.
@MainActor
private final class NotesThumbnailDriverProbe {
    var completion: (@MainActor (NotesQuickLookAttemptSignal) -> Void)?
    var cancelCount = 0
    var calls = 0
    var release: CheckedContinuation<Void, Never>?
    var stagedURL: URL?
    var stagedExisted: Bool?

    func deliver(_ signal: NotesQuickLookAttemptSignal) {
        completion?(signal)
    }

    static func image(width: Int = 4, height: Int = 4) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }
}
