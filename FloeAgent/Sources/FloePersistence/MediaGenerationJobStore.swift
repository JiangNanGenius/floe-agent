import Foundation
import GRDB
import FloeCore

public enum MediaGenerationJobStoreError: Error, Sendable, Equatable {
    case invalidStateTransition(from: MediaGenerationJobState, to: MediaGenerationJobState)
    case missingJob(UUID)
    /// `save(_:)` is the canvas-only legacy entry point; a job without a
    /// canvas identity cannot be persisted through it.
    case missingCanvasOwnership(UUID)
}

/// The outcome of `createJob`: either a newly inserted durable job or the
/// existing active job that an identical operation already owns.
public struct MediaJobCreation: Sendable {
    public var owned: OwnedMediaGenerationJob
    public var deduplicated: Bool

    public init(owned: OwnedMediaGenerationJob, deduplicated: Bool) {
        self.owned = owned
        self.deduplicated = deduplicated
    }

    public var job: MediaGenerationJob { owned.job }
}

/// Transactional persistence for long-running provider jobs. A provider task
/// ID is committed before callers may present a submitted job to the user.
///
/// Ownership is explicit (`owner_kind` + `owner_id`). Canvas jobs keep their
/// canvas/document references; conversation jobs store NULL there.
/// `MediaGenerationJob.canvasID/documentID` are optional and mirror the stored
/// columns exactly, so a conversation job never carries a fabricated canvas
/// identity. Dedupe is keyed on the submitting operation
/// (`idempotency_key`, normally `runID:toolCallID`) when known; the legacy
/// owner+model+request comparison is the fallback for canvas and older callers.
public actor MediaGenerationJobStore {
    private let database: DatabaseManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(database: DatabaseManager) { self.database = database }

    // MARK: - Writes

    /// Legacy canvas save. Preserves the pre-v42 behavior exactly.
    public func save(_ job: MediaGenerationJob) async throws {
        guard let canvasID = job.canvasID else {
            throw MediaGenerationJobStoreError.missingCanvasOwnership(job.id)
        }
        try await save(job, owner: .canvas(canvasID))
    }

    /// Owner-aware save. Canvas/document columns are written only for canvas
    /// ownership; conversation jobs persist NULL there.
    public func save(
        _ job: MediaGenerationJob,
        owner: MediaJobOwner,
        originRunID: UUID? = nil,
        idempotencyKey: String? = nil
    ) async throws {
        _ = try await database.writer { db in
            try Self.insert(
                db, job: job, owner: owner,
                originRunID: originRunID, idempotencyKey: idempotencyKey
            )
        }
    }

    /// Atomically returns the existing active job for this operation or inserts
    /// a new `preparing` row. The dedupe lookup and the insert share one write
    /// transaction, so two concurrent identical submissions can never both
    /// reach the provider. When `idempotencyKey` is present the key is the
    /// operation identity; otherwise the legacy owner+model+request comparison
    /// is used (canvas submits and pre-key rows).
    public func createJob(
        _ job: MediaGenerationJob,
        owner: MediaJobOwner,
        originRunID: UUID? = nil,
        idempotencyKey: String? = nil
    ) async throws -> MediaJobCreation {
        try await database.writer { db in
            if let existing = try Self.findActive(
                db, owner: owner, modelID: job.modelID,
                requestJSON: job.requestJSON, idempotencyKey: idempotencyKey
            ) {
                return MediaJobCreation(owned: existing, deduplicated: true)
            }
            let stored = try Self.insert(
                db, job: job, owner: owner,
                originRunID: originRunID, idempotencyKey: idempotencyKey
            )
            return MediaJobCreation(
                owned: OwnedMediaGenerationJob(
                    job: job, owner: owner,
                    canvasID: stored.canvasID, documentID: stored.documentID,
                    originRunID: originRunID, idempotencyKey: idempotencyKey
                ),
                deduplicated: false
            )
        }
    }

    /// Writes one job row. Returns the canvas/document identity that was
    /// actually stored: canvas ownership always persists a real canvas
    /// identity (falling back to the owner itself), conversation ownership
    /// always stores NULL.
    @discardableResult
    private static func insert(
        _ db: Database,
        job: MediaGenerationJob,
        owner: MediaJobOwner,
        originRunID: UUID?,
        idempotencyKey: String?
    ) throws -> (canvasID: UUID?, documentID: UUID?) {
        let encoder = JSONEncoder()
        let credential = try job.credentialReference.map(encoder.encode)
        let sources = try encoder.encode(job.sourceNodeIDs)
        let assets = try encoder.encode(job.assetReferences)
        let canvasID: UUID? = owner.kind == .canvas ? (job.canvasID ?? owner.id) : nil
        let documentID: UUID? = owner.kind == .canvas ? (job.documentID ?? owner.id) : nil
        try db.execute(sql: """
            INSERT INTO media_generation_jobs (
                id, provider_task_id, provider_id, model_id, media_kind,
                credential_reference_json, canvas_id, document_id,
                source_node_ids_json, result_node_id, request_json,
                asset_references_json, state, created_at,
                estimated_completion_at, result_retention_expires_at,
                last_polled_at, next_poll_at, retry_count, last_error,
                result_url, result_url_expires_at, local_asset_id, updated_at,
                owner_kind, owner_id, origin_run_id, idempotency_key
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                provider_task_id=excluded.provider_task_id,
                credential_reference_json=excluded.credential_reference_json,
                canvas_id=excluded.canvas_id,
                document_id=excluded.document_id,
                owner_kind=excluded.owner_kind,
                owner_id=excluded.owner_id,
                origin_run_id=excluded.origin_run_id,
                idempotency_key=COALESCE(excluded.idempotency_key, media_generation_jobs.idempotency_key),
                state=excluded.state,
                estimated_completion_at=excluded.estimated_completion_at,
                result_retention_expires_at=excluded.result_retention_expires_at,
                last_polled_at=excluded.last_polled_at,
                next_poll_at=excluded.next_poll_at,
                retry_count=excluded.retry_count,
                last_error=excluded.last_error,
                result_url=excluded.result_url,
                result_url_expires_at=excluded.result_url_expires_at,
                local_asset_id=excluded.local_asset_id,
                updated_at=excluded.updated_at
            """, arguments: [
                job.id.uuidString, job.providerTaskID, job.providerID.uuidString,
                job.modelID.uuidString, job.mediaKind.rawValue, credential,
                canvasID?.uuidString, documentID?.uuidString, sources,
                job.resultNodeID.uuidString, job.requestJSON, assets,
                job.state.rawValue, job.createdAt, job.estimatedCompletionAt,
                job.resultRetentionExpiresAt, job.lastPolledAt, job.nextPollAt,
                job.retryCount, job.lastError, job.resultURL?.absoluteString,
                job.resultURLExpiresAt, job.localAssetID?.uuidString, job.updatedAt,
                owner.kind.rawValue, owner.id.uuidString, originRunID?.uuidString,
                idempotencyKey
            ])
        return (canvasID, documentID)
    }

    public func transition(
        id: UUID, to state: MediaGenerationJobState,
        mutate: @Sendable (inout MediaGenerationJob) -> Void = { _ in }
    ) async throws -> MediaGenerationJob {
        guard let owned = try await ownedJob(id: id) else {
            throw MediaGenerationJobStoreError.missingJob(id)
        }
        var job = owned.job
        guard job.state.canTransition(to: state) else {
            throw MediaGenerationJobStoreError.invalidStateTransition(from: job.state, to: state)
        }
        mutate(&job)
        job.state = state
        job.updatedAt = Date()
        // Ownership and the operation identity never change through a
        // transition, so a conversation job cannot be rewritten as canvas (or
        // vice versa) by a lifecycle update.
        try await save(
            job, owner: owned.owner, originRunID: owned.originRunID,
            idempotencyKey: owned.idempotencyKey
        )
        return job
    }

    // MARK: - Reads

    public func job(id: UUID) async throws -> MediaGenerationJob? {
        try await ownedJob(id: id)?.job
    }

    public func ownedJob(id: UUID) async throws -> OwnedMediaGenerationJob? {
        try await database.reader { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM media_generation_jobs WHERE id = ?", arguments: [id.uuidString]) else { return nil }
            return try Self.decodeOwned(row, decoder: decoder)
        }
    }

    public func dueJobs(at date: Date = Date(), limit: Int = 24) async throws -> [MediaGenerationJob] {
        try await dueOwnedJobs(at: date, limit: limit).map(\.job)
    }

    public func dueOwnedJobs(at date: Date = Date(), limit: Int = 24) async throws -> [OwnedMediaGenerationJob] {
        try await database.reader { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM media_generation_jobs
                WHERE state NOT IN ('ready','failed','cancelled','expired')
                  AND (next_poll_at IS NULL OR next_poll_at <= ?)
                ORDER BY COALESCE(result_url_expires_at, estimated_completion_at, next_poll_at, created_at), created_at
                LIMIT ?
                """, arguments: [date, max(1, min(limit, 100))]).map {
                    try Self.decodeOwned($0, decoder: decoder)
                }
        }
    }

    /// Canvas-facing query. Conversation jobs are excluded so a chat job can
    /// never appear in a canvas timeline.
    public func jobs(canvasID: UUID) async throws -> [MediaGenerationJob] {
        try await database.reader { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM media_generation_jobs
                WHERE owner_kind = 'canvas' AND canvas_id = ?
                ORDER BY created_at DESC
                """, arguments: [canvasID.uuidString]).map {
                    try Self.decode($0, decoder: decoder)
                }
        }
    }

    public func jobs(owner: MediaJobOwner) async throws -> [MediaGenerationJob] {
        try await database.reader { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM media_generation_jobs
                WHERE owner_kind = ? AND owner_id = ?
                ORDER BY created_at DESC
                """, arguments: [owner.kind.rawValue, owner.id.uuidString]).map {
                    try Self.decode($0, decoder: decoder)
                }
        }
    }

    /// Idempotency guard for paid submissions: returns the newest active job
    /// for the same operation. When `idempotencyKey` is provided it identifies
    /// the submitting tool call exactly; otherwise the legacy comparison on
    /// owner, model and exact request body is used. Terminal jobs never match,
    /// so an explicit user retry is not silently merged into an old record.
    public func activeJob(
        owner: MediaJobOwner,
        modelID: UUID,
        requestJSON: Data,
        idempotencyKey: String? = nil
    ) async throws -> OwnedMediaGenerationJob? {
        try await database.reader { db in
            try Self.findActive(
                db, owner: owner, modelID: modelID, requestJSON: requestJSON,
                idempotencyKey: idempotencyKey
            )
        }
    }

    private static func findActive(
        _ db: Database,
        owner: MediaJobOwner,
        modelID: UUID,
        requestJSON: Data,
        idempotencyKey: String?
    ) throws -> OwnedMediaGenerationJob? {
        let decoder = JSONDecoder()
        let active = "state NOT IN ('ready','failed','cancelled','expired')"
        let row: Row?
        if let idempotencyKey {
            row = try Row.fetchOne(db, sql: """
                SELECT * FROM media_generation_jobs
                WHERE owner_kind = ? AND owner_id = ? AND idempotency_key = ?
                  AND \(active)
                ORDER BY created_at DESC
                LIMIT 1
                """, arguments: [
                    owner.kind.rawValue, owner.id.uuidString, idempotencyKey
                ])
        } else {
            row = try Row.fetchOne(db, sql: """
                SELECT * FROM media_generation_jobs
                WHERE owner_kind = ? AND owner_id = ? AND model_id = ? AND request_json = ?
                  AND \(active)
                ORDER BY created_at DESC
                LIMIT 1
                """, arguments: [
                    owner.kind.rawValue, owner.id.uuidString, modelID.uuidString, requestJSON
                ])
        }
        return try row.map { try decodeOwned($0, decoder: decoder) }
    }

    /// Jobs that were written before the provider call but never received a
    /// provider task ID (a crash between submit and persistence). Automatic
    /// retry is unsafe because the provider may have accepted the request, so
    /// these are surfaced separately for a truthful terminal state.
    public func stalePreparingJobs(before date: Date, limit: Int = 24) async throws -> [OwnedMediaGenerationJob] {
        try await database.reader { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM media_generation_jobs
                WHERE state = 'preparing' AND provider_task_id IS NULL AND created_at <= ?
                ORDER BY created_at
                LIMIT ?
                """, arguments: [date, max(1, min(limit, 100))]).map {
                    try Self.decodeOwned($0, decoder: decoder)
                }
        }
    }

    public func deleteJobs(canvasID: UUID, documentID: UUID? = nil) async throws {
        try await database.writer { db in
            if let documentID {
                try db.execute(
                    sql: "DELETE FROM media_generation_jobs WHERE owner_kind = 'canvas' AND canvas_id = ? AND document_id = ?",
                    arguments: [canvasID.uuidString, documentID.uuidString]
                )
            } else {
                try db.execute(
                    sql: "DELETE FROM media_generation_jobs WHERE owner_kind = 'canvas' AND canvas_id = ?",
                    arguments: [canvasID.uuidString]
                )
            }
        }
    }

    public func deleteJobs(owner: MediaJobOwner) async throws {
        try await database.writer { db in
            try db.execute(
                sql: "DELETE FROM media_generation_jobs WHERE owner_kind = ? AND owner_id = ?",
                arguments: [owner.kind.rawValue, owner.id.uuidString]
            )
        }
    }

    public func allJobs(limit: Int = 200) async throws -> [MediaGenerationJob] {
        try await allOwnedJobs(limit: limit).map(\.job)
    }

    public func allOwnedJobs(limit: Int = 200) async throws -> [OwnedMediaGenerationJob] {
        try await database.reader { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM media_generation_jobs
                ORDER BY CASE WHEN state IN ('ready','failed','cancelled','expired') THEN 1 ELSE 0 END,
                         COALESCE(result_url_expires_at, estimated_completion_at, created_at),
                         created_at DESC
                LIMIT ?
                """, arguments: [max(1, min(limit, 1_000))]).map {
                    try Self.decodeOwned($0, decoder: decoder)
                }
        }
    }

    // MARK: - Decoding

    private static func owner(from row: Row) -> MediaJobOwner {
        let kind = (row["owner_kind"] as String?).flatMap(MediaJobOwnerKind.init(rawValue:)) ?? .canvas
        let id = (row["owner_id"] as String?).flatMap(UUID.init(uuidString:))
            ?? (row["canvas_id"] as String?).flatMap(UUID.init(uuidString:))
            ?? UUID()
        return MediaJobOwner(kind: kind, id: id)
    }

    private static func decodeOwned(_ row: Row, decoder: JSONDecoder) throws -> OwnedMediaGenerationJob {
        let resolvedOwner = owner(from: row)
        let job = try decode(row, decoder: decoder)
        return OwnedMediaGenerationJob(
            job: job,
            owner: resolvedOwner,
            canvasID: (row["canvas_id"] as String?).flatMap(UUID.init(uuidString:)),
            documentID: (row["document_id"] as String?).flatMap(UUID.init(uuidString:)),
            originRunID: (row["origin_run_id"] as String?).flatMap(UUID.init(uuidString:)),
            idempotencyKey: row["idempotency_key"]
        )
    }

    private static func decode(_ row: Row, decoder: JSONDecoder) throws -> MediaGenerationJob {
        let credentialData: Data? = row["credential_reference_json"]
        let credential = try credentialData.map { try decoder.decode(SecretReference.self, from: $0) }
        let sourceData: Data = row["source_node_ids_json"]
        let assetData: Data = row["asset_references_json"]
        // The stored columns are the truth. A conversation job has NULL
        // canvas/document ids and the model must not invent one; a legacy
        // canvas job keeps exactly what it stored.
        return MediaGenerationJob(
            id: UUID(uuidString: row["id"])!, providerTaskID: row["provider_task_id"],
            providerID: UUID(uuidString: row["provider_id"])!,
            modelID: UUID(uuidString: row["model_id"])!,
            mediaKind: MediaKind(rawValue: row["media_kind"])!,
            credentialReference: credential,
            canvasID: (row["canvas_id"] as String?).flatMap(UUID.init(uuidString:)),
            documentID: (row["document_id"] as String?).flatMap(UUID.init(uuidString:)),
            sourceNodeIDs: try decoder.decode([UUID].self, from: sourceData),
            resultNodeID: UUID(uuidString: row["result_node_id"])!, requestJSON: row["request_json"],
            assetReferences: try decoder.decode([UUID].self, from: assetData),
            state: MediaGenerationJobState(rawValue: row["state"])!, createdAt: row["created_at"],
            estimatedCompletionAt: row["estimated_completion_at"],
            resultRetentionExpiresAt: row["result_retention_expires_at"],
            lastPolledAt: row["last_polled_at"], nextPollAt: row["next_poll_at"],
            retryCount: row["retry_count"], lastError: row["last_error"],
            resultURL: (row["result_url"] as String?).flatMap(URL.init(string:)),
            resultURLExpiresAt: row["result_url_expires_at"],
            localAssetID: (row["local_asset_id"] as String?).flatMap(UUID.init(uuidString:)),
            updatedAt: row["updated_at"]
        )
    }
}
