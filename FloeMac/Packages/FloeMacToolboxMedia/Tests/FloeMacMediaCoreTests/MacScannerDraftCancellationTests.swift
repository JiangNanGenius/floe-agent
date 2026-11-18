import XCTest
import FloeToolboxUtilities
@testable import FloeMacMediaCore

private actor ScannerRecognitionGate {
    private(set) var calls = 0
    private var waiter: CheckedContinuation<[OpticsScanItem], Never>?
    private let blocked: Bool
    init(blocked: Bool = false) { self.blocked = blocked }
    func run() async -> [OpticsScanItem] {
        calls += 1
        guard blocked else { return [] }
        return await withCheckedContinuation { waiter = $0 }
    }
    func release() { waiter?.resume(returning: []); waiter = nil }
}

@MainActor
final class MacScannerDraftCancellationTests: XCTestCase {
    private func png() throws -> Data {
        try MacTestFixtures.pngData(for: XCTUnwrap(MacTestFixtures.colorImage(width: 4, height: 4)))
    }

    func testQueuedRecognitionIsNotStartedAfterQuitPreparation() async throws {
        let gate = ScannerRecognitionGate()
        let session = MacScanSession(testingCompleteTextRecognizer: { _ in await gate.run() })
        let owner = MacScannerDraftOwner(session: session, writer: { _, _ in .uncertain })
        let ticket = owner.appear()
        try owner.addImage(png(), source: .imported, ticket: ticket)
        try owner.recognizeAll(ticket: ticket)
        owner.beginTermination()
        await MacTestFixtures.waitUntil { !owner.hasPendingWork }
        XCTAssertFalse(owner.hasPendingWork)
        let calls = await gate.calls
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(owner.pages.count, 1)
        let blocked = await owner.drain(timeout: 1)
        XCTAssertFalse(blocked, "the in-memory draft still requires a choice")
    }

    func testQueuedRecognitionIsNotStartedForChangedPages() async throws {
        let gate = ScannerRecognitionGate()
        let session = MacScanSession(testingCompleteTextRecognizer: { _ in await gate.run() })
        let owner = MacScannerDraftOwner(session: session, writer: { _, _ in .uncertain })
        let ticket = owner.appear()
        try owner.addImage(png(), source: .imported, ticket: ticket)
        try owner.recognizeAll(ticket: ticket)
        try owner.addImage(png(), source: .imported, ticket: ticket)
        await MacTestFixtures.waitUntil { !owner.hasPendingWork }
        XCTAssertFalse(owner.hasPendingWork)
        let calls = await gate.calls
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(owner.pages.count, 2)
    }

    func testAlreadyEnteredRecognizerKeepsOwnerUntilActualReturn() async throws {
        let gate = ScannerRecognitionGate(blocked: true)
        let session = MacScanSession(testingCompleteTextRecognizer: { _ in await gate.run() })
        let owner = MacScannerDraftOwner(session: session, writer: { _, _ in .uncertain })
        let ticket = owner.appear()
        try owner.addImage(png(), source: .imported, ticket: ticket)
        try owner.recognizeAll(ticket: ticket)
        for _ in 0..<250 {
            if await gate.calls > 0 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let calls = await gate.calls
        guard calls == 1 else { await gate.release(); return XCTFail("recognizer did not enter") }
        owner.beginTermination()
        let early = await owner.drain(timeout: 0.05)
        XCTAssertFalse(early)
        XCTAssertTrue(owner.hasPendingWork)
        await gate.release()
        await MacTestFixtures.waitUntil { !owner.hasPendingWork }
        XCTAssertFalse(owner.hasPendingWork)
        XCTAssertEqual(owner.pages.count, 1)
    }

    func testOldDrainCannotAuthorizeLaterTermination() async throws {
        let gate = ScannerRecognitionGate(blocked: true)
        let session = MacScanSession(testingCompleteTextRecognizer: { _ in await gate.run() })
        let owner = MacScannerDraftOwner(session: session, writer: { _, _ in .uncertain })
        let ticket = owner.appear()
        try owner.addImage(png(), source: .imported, ticket: ticket)
        try owner.recognizeAll(ticket: ticket)
        for _ in 0..<250 {
            if await gate.calls > 0 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard await gate.calls == 1 else { await gate.release(); return XCTFail("recognizer did not enter") }
        owner.beginTermination()
        var started = false
        var finished = false
        let oldDrain = Task { @MainActor in
            started = true
            let value = await owner.drain(timeout: 2)
            finished = true
            return value
        }
        await MacTestFixtures.waitUntil { started }
        XCTAssertTrue(started)
        owner.cancelTermination()
        owner.beginTermination()
        try await Task.sleep(for: .milliseconds(100))
        let finishedBeforeWorkerReturns = finished
        await gate.release()
        let oldResult = await oldDrain.value
        XCTAssertTrue(finishedBeforeWorkerReturns, "old drain must be fenced immediately by the new termination")
        XCTAssertFalse(oldResult)
        await MacTestFixtures.waitUntil { !owner.hasPendingWork }
        XCTAssertTrue(owner.allowExitDiscardingDraft())
        let newResult = await owner.drain(timeout: 1)
        XCTAssertTrue(newResult)
    }

    func testStaleClearConfirmationCannotRemoveChangedDraft() throws {
        let owner = MacScannerDraftOwner()
        let ticket = owner.appear()
        try owner.addImage(png(), source: .imported, ticket: ticket)
        let shownRevision = owner.currentRevision
        try owner.addImage(png(), source: .imported, ticket: ticket)
        XCTAssertThrowsError(try owner.clear(ticket: ticket, expectedRevision: shownRevision))
        XCTAssertEqual(owner.pages.count, 2)
        try owner.clear(ticket: ticket, expectedRevision: owner.currentRevision)
        XCTAssertTrue(owner.pages.isEmpty)
    }
}
