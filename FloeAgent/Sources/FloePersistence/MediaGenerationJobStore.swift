import Foundation
import GRDB
import FloeCore

public enum MediaGenerationJobStoreError: Error, Sendable, Equatable {
    case invalidStateTransition(from: MediaGenerationJobState, to: MediaGenerationJobState)
    case missingJob(UUID)
}

/// Transactional persistence for long-running provider jobs. A provider task
/// ID is committed before callers may present a submitted job to the user.
public actor MediaGenerationJobStore {
    private let database: DatabaseManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(database: DatabaseManager) { self.database = database }

    public func save(_ job: MediaGenerationJob) async throws {
        let credential = try job.credentialReference.map(encoder.encode)
        let sources = try encoder.encode(job.sourceNodeIDs)
        let assets = try encoder.encode(job.assetReferences)
        try await database.writer { db in
            try db.execute(sql: """
                INSERT INTO media_generation_jobs (
                    id, provider_task_id, provider_id, model_id, media_kind,
                    credential_reference_json, canvas_id, document_id,
                    source_node_ids_json, result_node_id, request_json,
                    asset_references_json, state, created_at,
                    estimated_completion_at, result_retention_expires_at,
                    last_polled_at, next_poll_at, retry_count, last_error,
                    result_url, result_url_expires_at, local_asset_id, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    provider_task_id=excluded.provider_task_id,
                    credential_reference_json=excluded.credential_reference_json,
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
                    job.canvasID.uuidString, job.documentID.uuidString, sources,
                    job.resultNodeID.uuidString, job.requestJSON, assets,
                    job.state.rawValue, job.createdAt, job.estimatedCompletionAt,
                    job.resultRetentionExpiresAt, job.lastPolledAt, job.nextPollAt,
                    job.retryCount, job.lastError, job.resultURL?.absoluteString,
                    job.resultURLExpiresAt, job.localAssetID?.uuidString, job.updatedAt
                ])
        }
    }

    public func transition(
        id: UUID, to state: MediaGenerationJobState,
        mutate: @Sendable (inout MediaGenerationJob) -> Void = { _ in }
    ) async throws -> MediaGenerationJob {
        guard var job = try await job(id: id) else {
            throw MediaGenerationJobStoreError.missingJob(id)
        }
        guard job.state.canTransition(to: state) else {
            throw MediaGenerationJobStoreError.invalidStateTransition(from: job.state, to: state)
        }
        mutate(&job)
        job.state = state
        job.updatedAt = Date()
        try await save(job)
        return job
    }

    public func job(id: UUID) async throws -> MediaGenerationJob? {
        try await database.reader { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM media_generation_jobs WHERE id = ?", arguments: [id.uuidString]) else { return nil }
            return try Self.decode(row, decoder: decoder)
        }
    }

    public func dueJobs(at date: Date = Date(), limit: Int = 24) async throws -> [MediaGenerationJob] {
        try await database.reader { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM media_generation_jobs
                WHERE state NOT IN ('ready','failed','cancelled','expired')
                  AND (next_poll_at IS NULL OR next_poll_at <= ?)
                ORDER BY COALESCE(result_url_expires_at, estimated_completion_at, next_poll_at, created_at), created_at
                LIMIT ?
                """, arguments: [date, max(1, min(limit, 100))]).map {
                    try Self.decode($0, decoder: decoder)
                }
        }
    }

    public func jobs(canvasID: UUID) async throws -> [MediaGenerationJob] {
        try await database.reader { db in
            try Row.fetchAll(db, sql: "SELECT * FROM media_generation_jobs WHERE canvas_id = ? ORDER BY created_at DESC", arguments: [canvasID.uuidString]).map {
                try Self.decode($0, decoder: decoder)
            }
        }
    }

    public func deleteJobs(canvasID: UUID, documentID: UUID? = nil) async throws {
        try await database.writer { db in
            if let documentID {
                try db.execute(
                    sql: "DELETE FROM media_generation_jobs WHERE canvas_id = ? AND document_id = ?",
                    arguments: [canvasID.uuidString, documentID.uuidString]
                )
            } else {
                try db.execute(
                    sql: "DELETE FROM media_generation_jobs WHERE canvas_id = ?",
                    arguments: [canvasID.uuidString]
                )
            }
        }
    }

    public func allJobs(limit: Int = 200) async throws -> [MediaGenerationJob] {
        try await database.reader { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM media_generation_jobs
                ORDER BY CASE WHEN state IN ('ready','failed','cancelled','expired') THEN 1 ELSE 0 END,
                         COALESCE(result_url_expires_at, estimated_completion_at, created_at),
                         created_at DESC
                LIMIT ?
                """, arguments: [max(1, min(limit, 1_000))]).map {
                    try Self.decode($0, decoder: decoder)
                }
        }
    }

    private static func decode(_ row: Row, decoder: JSONDecoder) throws -> MediaGenerationJob {
        let credentialData: Data? = row["credential_reference_json"]
        let credential = try credentialData.map { try decoder.decode(SecretReference.self, from: $0) }
        let sourceData: Data = row["source_node_ids_json"]
        let assetData: Data = row["asset_references_json"]
        return MediaGenerationJob(
            id: UUID(uuidString: row["id"])!, providerTaskID: row["provider_task_id"],
            providerID: UUID(uuidString: row["provider_id"])!,
            modelID: UUID(uuidString: row["model_id"])!,
            mediaKind: MediaKind(rawValue: row["media_kind"])!,
            credentialReference: credential, canvasID: UUID(uuidString: row["canvas_id"])!,
            documentID: UUID(uuidString: row["document_id"])!,
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
