import XCTest
import Foundation
import FloeCore
import FloeModels
import FloeNotes
import FloeProviders
@testable import FloeAndroidCore

private final class OCRFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

final class NotesOCRLifecycleTests: XCTestCase {
    private var notes: [OCRBoundNote] = []

    override func tearDown() async throws {
        for note in notes { await OCRTestSupport.retire(note) }
        notes.removeAll()
        try await super.tearDown()
    }

    private func note() async throws -> OCRBoundNote {
        let value = try await OCRTestSupport.bindNote()
        notes.append(value)
        return value
    }

    func testDrainWaitsForTheHeldProviderThenReleasesOwnedWork() async throws {
        let note = try await note()
        let port = AlwaysAttachOwnedWorkPort()
        let recorder = OCRRequestRecorder()
        let gate = ProviderGate()
        let adapter = ScriptedOCRAdapter(recorder: recorder) { _ in
            await gate.wait()
            return [.textDelta(.init(text: "held result")),
                    .completed(.init(stopReason: .endTurn))]
        }
        let domain = try OCRRouteFixture.domain(
            note,
            routing: FixedOCRRouting(outcome: .resolved(
                OCRRouteFixture.route(adapter: adapter))),
            port: port)
        let stageID = try await OCRTestSupport.stage(
            domain, OCRTestSupport.stageInput(note), image: OCRTestSupport.png)
        let recognition = Task {
            try await domain.recognize(stageID: stageID, conversationID: nil)
        }
        defer { gate.open() }
        try await OCRTestSupport.waitUntil("provider started") {
            recorder.count() == 1 && port.counts().attached == 1
        }
        let drained = OCRFlag()
        let drain = Task {
            let report = try await domain.drain(epoch: note.epoch)
            drained.set()
            return report
        }
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertFalse(drained.isSet, "drain must wait for the actual provider terminal")
        XCTAssertEqual(port.counts().attached, 1)
        XCTAssertEqual(port.counts().detached, 0)

        gate.open()
        let result = try await recognition.value
        XCTAssertEqual(result.text, "held result")
        let report = try await drain.value
        XCTAssertTrue(report.drained)
        XCTAssertEqual(report.pendingCount, 0)
        XCTAssertEqual(port.counts().detached, 1)
        XCTAssertTrue(drained.isSet)
    }

    func testPrepareRootStopFencesNewWorkAndAbortReArmsTheSameEpoch() async throws {
        let note = try await note()
        let port = AlwaysAttachOwnedWorkPort()
        let gate = ProviderGate()
        let adapter = ScriptedOCRAdapter { _ in
            await gate.wait()
            return [.textDelta(.init(text: "held")),
                    .completed(.init(stopReason: .endTurn))]
        }
        let domain = try OCRRouteFixture.domain(
            note,
            routing: FixedOCRRouting(outcome: .resolved(
                OCRRouteFixture.route(adapter: adapter))),
            port: port)
        let stageID = try await OCRTestSupport.stage(
            domain, OCRTestSupport.stageInput(note), image: OCRTestSupport.png)
        let recognition = Task {
            try await domain.recognize(stageID: stageID, conversationID: nil)
        }
        defer { gate.open() }
        try await OCRTestSupport.waitUntil("provider started") {
            port.counts().attached == 1
        }

        let report = await domain.prepareForRootStop(epoch: note.epoch,
                                                     deadlineMillis: 200)
        XCTAssertEqual(report.epoch, note.epoch)
        XCTAssertEqual(report.cancelRequestedCount, 1)
        XCTAssertEqual(report.pendingCount, 0)
        XCTAssertTrue(report.canRetire)

        // The cancelled recognition must settle as cancelled, not succeed.
        do {
            _ = try await recognition.value
            XCTFail("a cancelled OCR call must not report success")
        } catch let refusal as NotesOCRRefusal {
            XCTAssertEqual(refusal, .cancelled)
        }
        XCTAssertEqual(port.counts().detached, 1)

        // Fenced: no new stage can start until the same epoch aborts the stop.
        do {
            _ = try await domain.beginStage(OCRTestSupport.stageInput(note))
            XCTFail("root-stop must fence new OCR")
        } catch let refusal as NotesOCRRefusal {
            XCTAssertEqual(refusal, .fenced)
        }
        await domain.abortRootStop(epoch: note.epoch)
        let fresh = try await domain.beginStage(OCRTestSupport.stageInput(note))
        await domain.abort(stageID: fresh.stageID)
    }

    func testRetireRemovesTheTransientStageAndUnbinds() async throws {
        let note = try await note()
        let adapter = ScriptedOCRAdapter { _ in [] }
        let domain = try OCRRouteFixture.domain(
            note, routing: FixedOCRRouting(outcome: .resolved(
                OCRRouteFixture.route(adapter: adapter))))
        let descriptor = try await domain.beginStage(OCRTestSupport.stageInput(note))
        _ = try await domain.append(stageID: descriptor.stageID, offset: 0,
                                    data: OCRTestSupport.png)
        XCTAssertFalse((try? FileManager.default.contentsOfDirectory(
            atPath: note.stagingRoot.path))?.isEmpty ?? true)

        await domain.retire(epoch: note.epoch)
        let bound = await domain.boundEpoch
        XCTAssertNil(bound)
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            atPath: note.stagingRoot.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty)
        do {
            _ = try await domain.beginStage(OCRTestSupport.stageInput(note))
            XCTFail("a retired domain must not accept a stage")
        } catch let refusal as NotesOCRRefusal {
            XCTAssertEqual(refusal, .notBound)
        }
    }


    func testBindRemovesStaleHiddenStageFiles() async throws {
        let note = try await note()
        try FileManager.default.createDirectory(at: note.stagingRoot,
                                                withIntermediateDirectories: true)
        let stale = note.stagingRoot.appendingPathComponent(".ocr-stale.part")
        try Data([0x01, 0x02, 0x03]).write(to: stale)
        let port = AlwaysAttachOwnedWorkPort()
        let domain = try NotesOCRDomain(
            epoch: note.epoch,
            source: NotesOCRServiceSource(epoch: note.epoch),
            routing: FixedOCRRouting(outcome: .notConfigured("visionModelMissing")),
            ownedWork: ConfigOwnedWorkLifecycle(
                registry: port, epochProvider: FixedEpochProvider(epoch: note.epoch)),
            stagingRoot: note.stagingRoot)
        let bound = await domain.boundEpoch
        XCTAssertEqual(bound, note.epoch)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path),
                       "dot-prefixed stale stage files must be removed on bind")
    }

    func testBoundedStageCountRefusesTheNextBegin() async throws {
        let note = try await note()
        let adapter = ScriptedOCRAdapter { _ in [] }
        let domain = try OCRRouteFixture.domain(
            note, routing: FixedOCRRouting(outcome: .resolved(
                OCRRouteFixture.route(adapter: adapter))))
        var ids: [String] = []
        for _ in 0..<NotesOCRPolicy.maximumStages {
            let descriptor = try await domain.beginStage(OCRTestSupport.stageInput(note))
            ids.append(descriptor.stageID)
        }
        do {
            _ = try await domain.beginStage(OCRTestSupport.stageInput(note))
            XCTFail("the stage cap must be enforced")
        } catch let refusal as NotesOCRRefusal {
            XCTAssertEqual(refusal, .busy("stageLimit"))
        }
        for id in ids { await domain.abort(stageID: id) }
    }

    func testProviderErrorIsCachedAsTypedErrorAndNeverAsText() async throws {
        let note = try await note()
        let adapter = ScriptedOCRAdapter { _ in
            [.error(.init(kind: .server, providerMessage: "upstream failed")),
             .completed(.init(stopReason: .endTurn))]
        }
        let domain = try OCRRouteFixture.domain(
            note, routing: FixedOCRRouting(outcome: .resolved(
                OCRRouteFixture.route(adapter: adapter))))
        let stageID = try await OCRTestSupport.stage(
            domain, OCRTestSupport.stageInput(note), image: OCRTestSupport.png)
        do {
            _ = try await domain.recognize(stageID: stageID, conversationID: nil)
            XCTFail("a provider error must be typed")
        } catch let refusal as NotesOCRRefusal {
            XCTAssertEqual(refusal, .providerFailure("server"))
        }
        let after = try await OCRTestSupport.document(note.epoch, note.documentID)
        XCTAssertNil(after.pages.first?.ocrText)
        XCTAssertEqual(after.pages.first?.ocrError, "server")
        XCTAssertEqual(after.revision, note.revision)
    }
}
