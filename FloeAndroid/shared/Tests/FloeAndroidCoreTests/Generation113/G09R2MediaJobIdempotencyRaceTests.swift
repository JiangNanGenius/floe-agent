// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 media-job idempotency atomicity regressions (Full112 image
// lifecycle package, job-f5e25bf678e2493a).
// Authored source; the coordinator executes the combined gate (this lane
// performs NO build/test execution). These cases exercise the REAL
// `MediaGenerationJobStore.createJob` against an in-memory GRDB database and
// pin the ONE-writer create-or-attach decision:
//
//  * two concurrent conversation-owned submissions with the same submitting
//    operation identity (and exact request) produce ONE durable row and ONE
//    paid submission;
//  * a call that races another call to terminal still attaches to the
//    ORIGINAL row (no second paying job), with local producer/delivery fields
//    excluded from the request identity;
//  * a reused operation identity for a DIFFERENT request is refused, never
//    silently attached or duplicated;
//  * nil-key and document-owned UI/Canvas retry semantics keep the original
//    active-only behavior: a terminal row does not absorb an explicit retry.
import XCTest
import Foundation
import FloeCore
import FloePersistence

final class G09R2MediaJobIdempotencyRaceTests: XCTestCase {
    private var databases: [DatabaseManager] = []
    private let providerID = UUID()
    private let modelID = UUID()

    override func tearDown() async throws {
        for database in databases { try? await database.close() }
        databases.removeAll()
        try await super.tearDown()
    }

    private func makeStore() async throws -> MediaGenerationJobStore {
        let manager = try DatabaseManager.inMemory()
        try await manager.migrate()
        databases.append(manager)
        return MediaGenerationJobStore(database: manager)
    }

    private func makeJob(
        request: String, id: UUID = UUID()
    ) -> MediaGenerationJob {
        MediaGenerationJob(
            id: id,
            providerID: providerID,
            modelID: modelID,
            mediaKind: .image,
            credentialReference: nil,
            sourceNodeIDs: [],
            resultNodeID: UUID(),
            requestJSON: Data("{\"prompt\":\"\(request)\"}".utf8))
    }

    /// Two concurrent conversation submissions with the same key/request:
    /// the DB writer serializes them and the second sees the first row.
    func testConcurrentConversationCreateJobProducesOneRowAndOneSubmission() async throws {
        let store = try await makeStore()
        let owner = MediaJobOwner.conversation(UUID())
        let key = "run:call"
        let request = "draw a square"
        let jobs = [makeJob(request: request), makeJob(request: request)]
        let creations = try await withThrowingTaskGroup(
            of: MediaJobCreation.self
        ) { group in
            for job in jobs {
                group.addTask {
                    try await store.createJob(
                        job, owner: owner, originRunID: nil,
                        idempotencyKey: key)
                }
            }
            var values: [MediaJobCreation] = []
            for try await creation in group { values.append(creation) }
            return values
        }
        XCTAssertEqual(creations.count, 2)
        XCTAssertEqual(Set(creations.map { $0.job.id }).count, 1,
                       "one submitting operation must own one durable row")
        XCTAssertEqual(creations.filter { $0.deduplicated }.count, 1,
                       "exactly one call inserts; the other attaches")
        let rows = try await store.jobs(owner: owner)
        XCTAssertEqual(rows.count, 1)
    }

    /// The first call completed while the second was between its precheck and
    /// its create decision. The atomic store lookup must attach to the
    /// terminal row, ignoring local producer/artifact/target fields, and must
    /// not insert a second paying job.
    func testConversationCreateJobAttachesAcrossTerminalState() async throws {
        let store = try await makeStore()
        let owner = MediaJobOwner.conversation(UUID())
        let key = "run:call"
        let first = try await store.createJob(
            makeJob(request: "draw a square"),
            owner: owner, idempotencyKey: key)
        XCTAssertFalse(first.deduplicated)
        let completedJSON = Data("""
            {"prompt":"draw a square","producerReceipt":{"schemaVersion":1},
             "artifacts":[{"relativePath":"GeneratedMedia/x.png","sha256":"abc"}],
             "workspaceRelativePath":"GeneratedMedia/x.png",
             "deliveredByteCount":12,"deliveredSHA256":"abc",
             "targetWorkspaceID":"00000000-0000-0000-0000-000000000001",
             "targetWorkspaceRootPath":"/tmp/old"}
            """.utf8)
        _ = try await store.transition(id: first.job.id, to: .ready) {
            $0.requestJSON = completedJSON
        }
        let replay = try await store.createJob(
            makeJob(request: "draw a square"),
            owner: owner, idempotencyKey: key)
        XCTAssertTrue(replay.deduplicated)
        XCTAssertEqual(replay.job.id, first.job.id)
        XCTAssertEqual(replay.job.state, .ready)
        let replayRows = try await store.jobs(owner: owner)
        XCTAssertEqual(replayRows.count, 1)
    }

    /// A reused operation identity for a DIFFERENT request is refused. It
    /// must never attach the wrong request or insert a duplicate charge.
    func testConversationCreateJobRefusesReusedKeyForDifferentRequest() async throws {
        let store = try await makeStore()
        let owner = MediaJobOwner.conversation(UUID())
        let key = "run:call"
        _ = try await store.createJob(
            makeJob(request: "draw a square"),
            owner: owner, idempotencyKey: key)
        do {
            _ = try await store.createJob(
                makeJob(request: "draw a triangle"),
                owner: owner, idempotencyKey: key)
            XCTFail("a different request under the same operation identity must be refused")
        } catch MediaGenerationJobStoreError.idempotencyConflict {
            // expected
        }
        let conflictRows = try await store.jobs(owner: owner)
        XCTAssertEqual(conflictRows.count, 1)
    }

    /// Key-less legacy retry: a terminal row is not an active duplicate, so
    /// an explicit retry inserts a new row (the original UI/Canvas contract).
    func testNilKeyLegacyRetryAfterTerminalCreatesNewJob() async throws {
        let store = try await makeStore()
        let owner = MediaJobOwner.conversation(UUID())
        let first = try await store.createJob(
            makeJob(request: "draw a square"), owner: owner)
        _ = try await store.transition(id: first.job.id, to: .ready)
        let second = try await store.createJob(
            makeJob(request: "draw a square"), owner: owner)
        XCTAssertFalse(second.deduplicated)
        XCTAssertNotEqual(second.job.id, first.job.id)
        let legacyRows = try await store.jobs(owner: owner)
        XCTAssertEqual(legacyRows.count, 2)
    }

    /// Document/Canvas keyed submits keep the original active-only dedupe:
    /// a terminal row does not absorb an explicit retry.
    func testDocumentOwnerKeyedRetryAfterTerminalCreatesNewJob() async throws {
        let store = try await makeStore()
        let owner = MediaJobOwner.document(UUID())
        let key = "canvas-op"
        let first = try await store.createJob(
            makeJob(request: "draw a square"),
            owner: owner, idempotencyKey: key)
        _ = try await store.transition(id: first.job.id, to: .ready)
        let second = try await store.createJob(
            makeJob(request: "draw a square"),
            owner: owner, idempotencyKey: key)
        XCTAssertFalse(second.deduplicated)
        XCTAssertNotEqual(second.job.id, first.job.id)
        let documentRows = try await store.jobs(owner: owner)
        XCTAssertEqual(documentRows.count, 2)
    }
}
