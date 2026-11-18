import Foundation
import XCTest
@testable import FloeDesktopSync

final class RunProjectionProducerTests: XCTestCase {
    private actor Source: RunProjectionSource {
        var allEvents: [ProjectionSourceEvent]
        var messages: [EntityID: ProjectionCanonicalMessage]
        var ignoreLimit = false
        var reads = 0

        init(events: [ProjectionSourceEvent], messages: [EntityID: ProjectionCanonicalMessage] = [:]) {
            allEvents = events
            self.messages = messages
        }

        func setMessage(_ message: ProjectionCanonicalMessage) { messages[message.id] = message }
        func setEvents(_ events: [ProjectionSourceEvent]) { allEvents = events }
        func setIgnoreLimit() { ignoreLimit = true }
        func readCount() -> Int { reads }

        func events(taskID: TaskID, runID: RunID, afterSequence: Int64, limit: Int) async throws -> [ProjectionSourceEvent] {
            reads += 1
            let later = allEvents.filter { $0.sequence > afterSequence }
            return ignoreLimit ? later : Array(later.prefix(limit))
        }

        func message(id: EntityID) async throws -> ProjectionCanonicalMessage? { messages[id] }
    }

    private struct Fixture {
        let device = DeviceID()
        let task = TaskID()
        let run = RunID()
        let messageID = EntityID()
        let epoch = try! ExecutionEpoch(1)

        func event(_ sequence: Int64, _ kind: ProjectionSourceEvent.Kind) -> ProjectionSourceEvent {
            ProjectionSourceEvent(taskID: task, runID: run, sequence: sequence, kind: kind)
        }
        func message(_ text: String = "hello") -> ProjectionCanonicalMessage {
            ProjectionCanonicalMessage(id: messageID, taskID: task, runID: run, role: .assistant, text: text)
        }
        func bind(_ store: SyncStore) async throws {
            _ = try await store.establishExecutionHead(runID: run, taskID: task,
                                                       epoch: epoch, ownerDeviceID: device)
        }
    }

    private struct AdvancingSource: RunProjectionSource {
        let store: SyncStore
        let task: TaskID
        let run: RunID
        let event: ProjectionSourceEvent

        func events(taskID: TaskID, runID: RunID, afterSequence: Int64, limit: Int) async throws -> [ProjectionSourceEvent] {
            _ = try await store.establishExecutionHead(runID: run, taskID: task,
                                                       epoch: ExecutionEpoch(2), ownerDeviceID: DeviceID())
            return [event]
        }

        func message(id: EntityID) async throws -> ProjectionCanonicalMessage? { nil }
    }

    func testBoundedPagesResumeAfterReopeningAndUseCanonicalMessage() async throws {
        let db = try TestDatabase(), f = Fixture()
        addTeardownBlock { db.remove() }
        let source = Source(events: [f.event(1, .excludedReasoning), f.event(2, .canonicalMessage(f.messageID)),
                                     f.event(3, .canonicalMessage(f.messageID))],
                            messages: [f.messageID: f.message()])
        let first = try db.makeStore(deviceID: f.device)
        try await f.bind(first)
        let firstResult = try await RunProjectionProducer(store: first, source: source)
            .projectNextPage(taskID: f.task, runID: f.run, executionEpoch: f.epoch, limit: 2)
        XCTAssertEqual(firstResult?.checkpoint.sourceSequence, 2)
        XCTAssertEqual(firstResult?.checkpoint.appendedRecords, 1)
        await first.close()
        let reopened = try db.makeStore(deviceID: f.device)
        let secondResult = try await RunProjectionProducer(store: reopened, source: source)
            .projectNextPage(taskID: f.task, runID: f.run, executionEpoch: f.epoch, limit: 2)
        XCTAssertEqual(secondResult?.checkpoint.sourceSequence, 3)
        XCTAssertEqual(secondResult?.checkpoint.unchangedRecords, 1)
        let stored = try await reopened.storedRecord(kind: .message, entityID: f.messageID)
        XCTAssertEqual(stored?.record.payload["text"]?.stringValue, "hello")
        XCTAssertEqual(stored?.record.payload["runID"]?.stringValue, f.run.canonical)
        let end = try await RunProjectionProducer(store: reopened, source: source)
            .projectNextPage(taskID: f.task, runID: f.run, executionEpoch: f.epoch)
        XCTAssertNil(end)
        await reopened.close()
    }

    func testUpdatedCanonicalMessageUsesExistingRevisionAndBaseline() async throws {
        let db = try TestDatabase(), f = Fixture()
        addTeardownBlock { db.remove() }
        let source = Source(events: [f.event(1, .canonicalMessage(f.messageID))], messages: [f.messageID: f.message()])
        let store = try db.makeStore(deviceID: f.device)
        try await f.bind(store)
        let producer = RunProjectionProducer(store: store, source: source)
        _ = try await producer.projectNextPage(taskID: f.task, runID: f.run, executionEpoch: f.epoch)
        await source.setMessage(f.message("updated"))
        await source.setEvents([f.event(1, .canonicalMessage(f.messageID)), f.event(2, .canonicalMessage(f.messageID))])
        _ = try await producer.projectNextPage(taskID: f.task, runID: f.run, executionEpoch: f.epoch)
        let record = try await store.storedRecord(kind: .message, entityID: f.messageID)
        XCTAssertEqual(record?.record.revision, try Revision(2))
        XCTAssertEqual(record?.record.baseRevision, try Revision(1))
        XCTAssertNotNil(record?.record.baseDigest)
        XCTAssertEqual(record?.record.payload["text"]?.stringValue, "updated")
        await store.close()
    }

    func testUnsupportedAndGapDoNotWriteOrAdvanceCheckpoint() async throws {
        let db = try TestDatabase(), f = Fixture()
        addTeardownBlock { db.remove() }
        let source = Source(events: [f.event(1, .canonicalMessage(f.messageID)), f.event(2, .unsupported)],
                            messages: [f.messageID: f.message()])
        let store = try db.makeStore(deviceID: f.device)
        try await f.bind(store)
        let producer = RunProjectionProducer(store: store, source: source)
        do {
            _ = try await producer.projectNextPage(taskID: f.task, runID: f.run, executionEpoch: f.epoch)
            XCTFail("unsupported event must fail closed")
        } catch let error as RunProjectionProducerError { XCTAssertEqual(error, .unsupportedEvent) }
        let checkpoint = try await store.runProjectionCheckpoint(for: f.run)
        let count = try await store.recordCount()
        XCTAssertNil(checkpoint)
        XCTAssertEqual(count, 0)
        await source.setEvents([f.event(2, .excludedReasoning)])
        do {
            _ = try await producer.projectNextPage(taskID: f.task, runID: f.run, executionEpoch: f.epoch)
            XCTFail("gap must fail closed")
        } catch let error as RunProjectionProducerError { XCTAssertEqual(error, .sourceSequenceMismatch) }
        let afterGap = try await store.runProjectionCheckpoint(for: f.run)
        XCTAssertNil(afterGap)
        await store.close()
    }

    func testMissingOrForeignCanonicalMessageCannotAdvance() async throws {
        let db = try TestDatabase(), f = Fixture()
        addTeardownBlock { db.remove() }
        let source = Source(events: [f.event(1, .canonicalMessage(f.messageID))])
        let store = try db.makeStore(deviceID: f.device)
        try await f.bind(store)
        let producer = RunProjectionProducer(store: store, source: source)
        do {
            _ = try await producer.projectNextPage(taskID: f.task, runID: f.run, executionEpoch: f.epoch)
            XCTFail("missing canonical row must fail")
        } catch let error as RunProjectionProducerError { XCTAssertEqual(error, .canonicalMessageMissing) }
        await source.setMessage(ProjectionCanonicalMessage(id: f.messageID, taskID: TaskID(), runID: f.run,
                                                           role: .assistant, text: "wrong task"))
        do {
            _ = try await producer.projectNextPage(taskID: f.task, runID: f.run, executionEpoch: f.epoch)
            XCTFail("foreign canonical row must fail")
        } catch let error as RunProjectionProducerError { XCTAssertEqual(error, .canonicalMessageMismatch) }
        let checkpoint = try await store.runProjectionCheckpoint(for: f.run)
        XCTAssertNil(checkpoint)
        await store.close()
    }

    func testHeadMustBeOwnedBeforeReadingSourceAndSourceMustRespectLimit() async throws {
        let db = try TestDatabase(), f = Fixture()
        addTeardownBlock { db.remove() }
        let source = Source(events: [f.event(1, .excludedReasoning), f.event(2, .excludedReasoning)])
        let store = try db.makeStore(deviceID: f.device)
        let producer = RunProjectionProducer(store: store, source: source)
        do {
            _ = try await producer.projectNextPage(taskID: f.task, runID: f.run, executionEpoch: f.epoch)
            XCTFail("missing head must fail")
        } catch let error as RunProjectionProducerError { XCTAssertEqual(error, .executionBindingMismatch) }
        let reads = await source.readCount()
        XCTAssertEqual(reads, 0)
        try await f.bind(store)
        await source.setIgnoreLimit()
        do {
            _ = try await producer.projectNextPage(taskID: f.task, runID: f.run, executionEpoch: f.epoch, limit: 1)
            XCTFail("oversized page must fail")
        } catch let error as RunProjectionProducerError { XCTAssertEqual(error, .oversizedPage) }
        let checkpoint = try await store.runProjectionCheckpoint(for: f.run)
        XCTAssertNil(checkpoint)
        await store.close()
    }

    func testOwnershipChangeDuringSourceReadCannotAdvanceCheckpoint() async throws {
        let db = try TestDatabase(), f = Fixture()
        addTeardownBlock { db.remove() }
        let store = try db.makeStore(deviceID: f.device)
        try await f.bind(store)
        let source = AdvancingSource(store: store, task: f.task, run: f.run,
                                     event: f.event(1, .excludedReasoning))
        do {
            _ = try await RunProjectionProducer(store: store, source: source)
                .projectNextPage(taskID: f.task, runID: f.run, executionEpoch: f.epoch)
            XCTFail("stale owner must not commit after handoff")
        } catch let error as SyncStoreError {
            guard case .staleExecutionEpoch = error else { return XCTFail("unexpected error: \(error)") }
        }
        let checkpoint = try await store.runProjectionCheckpoint(for: f.run)
        let count = try await store.recordCount()
        XCTAssertNil(checkpoint)
        XCTAssertEqual(count, 0)
        await store.close()
    }
}
