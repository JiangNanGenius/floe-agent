// Build191 media-review — durable ownership + idempotency fixture.
//
// Compiled with the EDITED FloeCore sources and the edited persistence
// sources, plus a minimal `DatabaseManager` shim, so the real store and
// migrations run against a real SQLite database. No app, no network, no
// SwiftPM.

import Foundation
import GRDB
import FloeCore

/// Sendable projection of one job row (GRDB `Row` is not Sendable).
struct JobRow: Sendable {
    var ownerKind: String?
    var ownerID: String?
    var canvasID: String?
    var documentID: String?
    var idempotencyKey: String?
    var state: String?
    var providerTaskID: String?
}

@main
@MainActor
struct ReviewOwnershipTests {
    static var failures: [String] = []
    static var checks = 0

    static func check(_ condition: Bool, _ label: String) {
        checks += 1
        if !condition { failures.append(label) }
    }

    static func main() async {
        do {
            try await run()
        } catch {
            failures.append("unexpected error: \(error)")
        }
        if failures.isEmpty {
            print("REVIEW-OWNERSHIP: PASS (\(checks) checks)")
        } else {
            print("REVIEW-OWNERSHIP: FAIL (\(failures.count)/\(checks))")
            for failure in failures { print("  - \(failure)") }
            exit(1)
        }
    }

    nonisolated static func jobRow(_ db: Database, id: UUID) throws -> JobRow? {
        guard let row = try Row.fetchOne(
            db, sql: "SELECT * FROM media_generation_jobs WHERE id = ?",
            arguments: [id.uuidString]
        ) else { return nil }
        return JobRow(
            ownerKind: row["owner_kind"], ownerID: row["owner_id"],
            canvasID: row["canvas_id"], documentID: row["document_id"],
            idempotencyKey: row["idempotency_key"], state: row["state"],
            providerTaskID: row["provider_task_id"]
        )
    }

    nonisolated static func makeJob(
        providerID: UUID, modelID: UUID, canvasID: UUID?, documentID: UUID?,
        requestJSON: Data
    ) -> MediaGenerationJob {
        MediaGenerationJob(
            providerID: providerID, modelID: modelID, mediaKind: .video,
            credentialReference: nil, canvasID: canvasID, documentID: documentID,
            sourceNodeIDs: [], resultNodeID: UUID(), requestJSON: requestJSON
        )
    }

    static func run() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-review-ownership-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("review.sqlite").path
        let queue = try DatabaseQueue(path: path)
        let providerID = UUID()
        let modelID = UUID()
        let canvasID = UUID()
        let documentID = UUID()
        let legacyJobID = UUID()
        let conversationID = UUID()
        let otherConversationID = UUID()
        try await queue.write { db in
            try db.execute(sql: "CREATE TABLE providers (id TEXT PRIMARY KEY)")
            try db.execute(sql: "CREATE TABLE models (id TEXT PRIMARY KEY)")
            try db.execute(sql: "INSERT INTO providers (id) VALUES (?)", arguments: [providerID.uuidString])
            try db.execute(sql: "INSERT INTO models (id) VALUES (?)", arguments: [modelID.uuidString])
            // Verbatim V26 shape: canvas/document NOT NULL.
            try db.execute(sql: """
                CREATE TABLE media_generation_jobs (
                    id TEXT PRIMARY KEY,
                    provider_task_id TEXT,
                    provider_id TEXT NOT NULL REFERENCES providers(id) ON DELETE RESTRICT,
                    model_id TEXT NOT NULL REFERENCES models(id) ON DELETE RESTRICT,
                    media_kind TEXT NOT NULL,
                    credential_reference_json BLOB,
                    canvas_id TEXT NOT NULL,
                    document_id TEXT NOT NULL,
                    source_node_ids_json BLOB NOT NULL,
                    result_node_id TEXT NOT NULL,
                    request_json BLOB NOT NULL,
                    asset_references_json BLOB NOT NULL,
                    state TEXT NOT NULL,
                    created_at DATETIME NOT NULL,
                    estimated_completion_at DATETIME,
                    result_retention_expires_at DATETIME,
                    last_polled_at DATETIME,
                    next_poll_at DATETIME,
                    retry_count INTEGER NOT NULL DEFAULT 0,
                    last_error TEXT,
                    result_url TEXT,
                    result_url_expires_at DATETIME,
                    local_asset_id TEXT,
                    updated_at DATETIME NOT NULL
                )
                """)
            try db.execute(sql: "CREATE INDEX media_jobs_due ON media_generation_jobs(state, next_poll_at)")
            // One legacy canvas row that predates ownership.
            try db.execute(sql: """
                INSERT INTO media_generation_jobs (
                    id, provider_id, model_id, media_kind, canvas_id, document_id,
                    source_node_ids_json, result_node_id, request_json,
                    asset_references_json, state, created_at, retry_count, updated_at
                ) VALUES (?, ?, ?, 'video', ?, ?, ?, ?, ?, ?, 'running', ?, 0, ?)
                """, arguments: [
                    legacyJobID.uuidString, providerID.uuidString, modelID.uuidString,
                    canvasID.uuidString, documentID.uuidString,
                    Data("[]".utf8), UUID().uuidString, Data("{}".utf8),
                    Data("[]".utf8), Date(), Date()
                ])
        }
        // Apply the real migrations.
        try await queue.write { db in
            for statement in V42MediaJobOwners.statements { try db.execute(sql: statement) }
            for statement in V43MediaJobIdempotency.statements { try db.execute(sql: statement) }
        }

        // MARK: migration truth

        let columnNames: [String] = try await queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('media_generation_jobs')")
        }
        let notNullColumns: [String] = try await queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('media_generation_jobs') WHERE \"notnull\" = 1")
        }
        check(columnNames.contains("idempotency_key"), "v43 idempotency_key column exists")
        check(!notNullColumns.contains("canvas_id"), "v42 canvas_id is nullable")
        check(!notNullColumns.contains("document_id"), "v42 document_id is nullable")
        let userVersion: Int? = try await queue.read { db in
            try Int.fetchOne(db, sql: "PRAGMA user_version")
        }
        check(userVersion == 43, "user_version is 43, got \(userVersion ?? -1)")
        let indexes: [String] = try await queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'media_generation_jobs'")
        }
        check(indexes.contains("media_jobs_idempotency"), "v43 idempotency index exists")
        check(indexes.contains("media_jobs_owner"), "v42 owner index exists")

        let legacyRow = try await queue.read { db in try jobRow(db, id: legacyJobID) }
        check(legacyRow?.ownerKind == "canvas", "legacy row backfilled as canvas")
        check(legacyRow?.ownerID == canvasID.uuidString, "legacy owner_id keeps canvas id")
        check(legacyRow?.canvasID == canvasID.uuidString, "legacy canvas_id preserved")
        check(legacyRow?.idempotencyKey == nil, "legacy row idempotency key is NULL")

        let store = MediaGenerationJobStore(database: DatabaseManager(queue: queue))
        let legacyOwned = try await store.ownedJob(id: legacyJobID)
        check(legacyOwned?.owner == .canvas(canvasID), "legacy owned job resolves canvas owner")
        check(legacyOwned?.job.canvasID == canvasID, "legacy decoded job keeps canvas id")
        check(legacyOwned?.job.documentID == documentID, "legacy decoded job keeps document id")

        // MARK: conversation ownership

        let requestJSON = try JSONEncoder().encode(["prompt": "a cat", "model": "m"])
        let conversationJob = makeJob(
            providerID: providerID, modelID: modelID,
            canvasID: nil, documentID: nil, requestJSON: requestJSON
        )
        try await store.save(
            conversationJob, owner: .conversation(conversationID),
            originRunID: nil, idempotencyKey: "run-1:call-a"
        )
        let conversationRow = try await queue.read { db in try jobRow(db, id: conversationJob.id) }
        check(conversationRow?.canvasID == nil, "conversation row stores NULL canvas_id")
        check(conversationRow?.documentID == nil, "conversation row stores NULL document_id")
        check(conversationRow?.ownerKind == "conversation", "conversation owner_kind stored")
        check(conversationRow?.ownerID == conversationID.uuidString, "conversation owner_id stored")
        check(conversationRow?.idempotencyKey == "run-1:call-a", "idempotency key stored")

        let decodedConversation = try await store.ownedJob(id: conversationJob.id)
        check(decodedConversation?.job.canvasID == nil, "decoded conversation job has no placeholder canvas id")
        check(decodedConversation?.job.documentID == nil, "decoded conversation job has no placeholder document id")
        check(decodedConversation?.canvasID == nil && decodedConversation?.documentID == nil,
              "owned row canvas/document are nil")
        check(decodedConversation?.idempotencyKey == "run-1:call-a", "owned row carries idempotency key")

        // MARK: legacy canvas save

        let canvasJob = makeJob(
            providerID: providerID, modelID: modelID,
            canvasID: canvasID, documentID: nil, requestJSON: Data("{\"canvas\":1}".utf8)
        )
        try await store.save(canvasJob)
        let canvasRow = try await queue.read { db in try jobRow(db, id: canvasJob.id) }
        check(canvasRow?.ownerKind == "canvas", "legacy save keeps canvas owner")
        check(canvasRow?.canvasID == canvasID.uuidString, "legacy save stores real canvas id")
        check(canvasRow?.documentID == canvasID.uuidString, "legacy save fills missing document id from owner")
        var missingCanvas = false
        do {
            _ = try await store.save(makeJob(
                providerID: providerID, modelID: modelID,
                canvasID: nil, documentID: nil, requestJSON: Data()
            ))
        } catch MediaGenerationJobStoreError.missingCanvasOwnership {
            missingCanvas = true
        }
        check(missingCanvas, "legacy save rejects a job without canvas identity")

        let canvasJobs = try await store.jobs(canvasID: canvasID)
        check(Set(canvasJobs.map(\.id)) == Set([legacyJobID, canvasJob.id]),
              "canvas query returns exactly the canvas jobs")
        check(!canvasJobs.contains { $0.id == conversationJob.id },
              "canvas query excludes the conversation job")
        let conversationJobs = try await store.jobs(owner: .conversation(conversationID))
        check(conversationJobs.count == 1 && conversationJobs[0].id == conversationJob.id,
              "owner query is conversation scoped")

        // MARK: createJob idempotency

        let secondRequest = try JSONEncoder().encode(["prompt": "a dog", "model": "m"])
        let creationA = try await store.createJob(
            makeJob(providerID: providerID, modelID: modelID, canvasID: nil, documentID: nil, requestJSON: secondRequest),
            owner: .conversation(conversationID), originRunID: nil, idempotencyKey: "run-2:call-a"
        )
        check(!creationA.deduplicated, "first createJob inserts")
        let replayA = try await store.createJob(
            makeJob(providerID: providerID, modelID: modelID, canvasID: nil, documentID: nil, requestJSON: secondRequest),
            owner: .conversation(conversationID), originRunID: nil, idempotencyKey: "run-2:call-a"
        )
        check(replayA.deduplicated && replayA.job.id == creationA.job.id,
              "replayed tool call dedupes on operation identity")

        let distinctRequest = try await store.createJob(
            makeJob(providerID: providerID, modelID: modelID, canvasID: nil, documentID: nil, requestJSON: secondRequest),
            owner: .conversation(conversationID), originRunID: nil, idempotencyKey: "run-3:call-b"
        )
        check(!distinctRequest.deduplicated && distinctRequest.job.id != creationA.job.id,
              "distinct user request with identical body is not merged")

        let noKeyCreate = try await store.createJob(
            makeJob(providerID: providerID, modelID: modelID, canvasID: canvasID, documentID: documentID,
                    requestJSON: Data("{\"legacy\":2}".utf8)),
            owner: .canvas(canvasID), originRunID: nil, idempotencyKey: nil
        )
        let noKeyReplay = try await store.createJob(
            makeJob(providerID: providerID, modelID: modelID, canvasID: canvasID, documentID: documentID,
                    requestJSON: Data("{\"legacy\":2}".utf8)),
            owner: .canvas(canvasID), originRunID: nil, idempotencyKey: nil
        )
        check(noKeyCreate.deduplicated == false, "canvas create without key inserts")
        check(noKeyReplay.deduplicated && noKeyReplay.job.id == noKeyCreate.job.id,
              "canvas create without key falls back to exact-request dedupe")

        // MARK: transition preserves ownership and identity

        _ = try await store.transition(id: creationA.job.id, to: .submitted) {
            $0.providerTaskID = "task-1"
        }
        let transitionedRow = try await queue.read { db in try jobRow(db, id: creationA.job.id) }
        check(transitionedRow?.ownerKind == "conversation", "transition preserves conversation owner")
        check(transitionedRow?.canvasID == nil, "transition does not invent canvas id")
        check(transitionedRow?.idempotencyKey == "run-2:call-a", "transition preserves idempotency key")
        check(transitionedRow?.providerTaskID == "task-1", "transition writes provider task id")

        let activeByKey = try await store.activeJob(
            owner: .conversation(conversationID), modelID: modelID,
            requestJSON: secondRequest, idempotencyKey: "run-2:call-a"
        )
        check(activeByKey?.job.id == creationA.job.id, "activeJob finds the operation by key")
        let activeByOtherKey = try await store.activeJob(
            owner: .conversation(conversationID), modelID: modelID,
            requestJSON: secondRequest, idempotencyKey: "run-4:call-c"
        )
        check(activeByOtherKey == nil, "activeJob never matches a different operation key")

        // Terminal jobs are never merged into a new request.
        _ = try await store.transition(id: creationA.job.id, to: .cancelled)
        let afterTerminal = try await store.createJob(
            makeJob(providerID: providerID, modelID: modelID, canvasID: nil, documentID: nil, requestJSON: secondRequest),
            owner: .conversation(conversationID), originRunID: nil, idempotencyKey: "run-2:call-a"
        )
        check(!afterTerminal.deduplicated && afterTerminal.job.id != creationA.job.id,
              "terminal job is not reused for a new submission")

        // MARK: isolation and cleanup

        let otherJob = makeJob(
            providerID: providerID, modelID: modelID,
            canvasID: nil, documentID: nil, requestJSON: Data("{\"other\":1}".utf8)
        )
        try await store.save(otherJob, owner: .conversation(otherConversationID))
        let scoped = try await store.jobs(owner: .conversation(conversationID))
        check(!scoped.contains(where: { $0.id == otherJob.id }), "owner query excludes other conversations")
        try await store.deleteJobs(owner: .conversation(otherConversationID))
        let others = try await store.jobs(owner: .conversation(otherConversationID))
        check(others.isEmpty, "owner delete removes only that owner's jobs")
        let survivors = try await store.jobs(owner: .conversation(conversationID))
        check(!survivors.isEmpty, "owner delete preserves other owners' jobs")

        let allOwned = try await store.allOwnedJobs(limit: 500)
        check(allOwned.allSatisfy { $0.owner.kind == .canvas ? $0.canvasID != nil : $0.canvasID == nil },
              "every decoded conversation job has NULL canvas columns")
    }
}
