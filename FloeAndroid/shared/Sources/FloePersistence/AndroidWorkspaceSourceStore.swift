// SPDX-License-Identifier: MPL-2.0
import Foundation
import GRDB
import FloeCore

public enum AndroidWorkspaceSourceKind: String, Sendable, Codable { case saf, webdav, smb }
public enum AndroidWorkspaceRecoveryState: String, Sendable, Codable {
    case prepared, writing, committed, conflict, retained
}
public enum AndroidWorkspaceSourceError: Error, Sendable, Equatable {
    case invalidMetadata, missingSource, staleRevision, receiptMismatch, invalidTransition
}

/// Metadata only. Source references are OS content URIs or opaque native
/// connection IDs; credential material and document bytes never enter rows.
public struct AndroidWorkspaceSource: Sendable, Equatable {
    public init(id: UUID, workspaceID: UUID, logicalPath: String, kind: AndroidWorkspaceSourceKind,
                sourceReference: String, sourceDocumentID: String?, sourceSHA256: String?,
                entityTag: String?, revision: String) {
        self.id = id
        self.workspaceID = workspaceID
        self.logicalPath = logicalPath
        self.kind = kind
        self.sourceReference = sourceReference
        self.sourceDocumentID = sourceDocumentID
        self.sourceSHA256 = sourceSHA256
        self.entityTag = entityTag
        self.revision = revision
    }

    public let id: UUID
    public let workspaceID: UUID
    public let logicalPath: String
    public let kind: AndroidWorkspaceSourceKind
    public let sourceReference: String
    public let sourceDocumentID: String?
    public let sourceSHA256: String?
    public let entityTag: String?
    public let revision: String
}

public struct AndroidWorkspaceRecovery: Sendable, Equatable {
    public let id: UUID
    public let sourceID: UUID
    public let workspaceID: UUID
    public let sourceRevision: String
    public let sourceReference: String
    public let sourceDocumentID: String?
    public let backupRelativePath: String
    public let backupSHA256: String
    public let replacementSHA256: String
    public let state: AndroidWorkspaceRecoveryState
    public let observedSHA256: String?
}

/// Uses the SAME original SQLite/GRDB writer as workspaces/conversations.
/// The trusted coordinator validates actual file ownership and hashes before
/// calling prepareRecovery. A committed DB receipt is necessary for a write
/// permit; neither a Kotlin success string nor a picker result replaces it.
public actor AndroidWorkspaceSourceStore {
    private let database: DatabaseManager
    public init(database: DatabaseManager) { self.database = database }

    public func source(id: UUID) async throws -> AndroidWorkspaceSource? {
        try await database.reader { db in
            try Row.fetchOne(db, sql: "SELECT * FROM android_workspace_sources WHERE id = ?",
                             arguments: [id.uuidString]).map(Self.decodeSource)
        }
    }
    public func source(workspaceID: UUID, logicalPath: String) async throws -> AndroidWorkspaceSource? {
        guard Self.validPath(logicalPath) else { throw AndroidWorkspaceSourceError.invalidMetadata }
        return try await database.reader { db in
            try Row.fetchOne(db, sql: "SELECT * FROM android_workspace_sources WHERE workspace_id = ? AND logical_path = ?",
                             arguments: [workspaceID.uuidString, logicalPath]).map(Self.decodeSource)
        }
    }

    /// Only native picker/import/connection composition calls this method.
    /// Updating an existing binding requires its exact opaque revision;
    /// the UNIQUE path constraint refuses aliases over another source ID.
    public func bind(id: UUID, workspaceID: UUID, logicalPath: String,
                     kind: AndroidWorkspaceSourceKind, sourceReference: String,
                     sourceDocumentID: String? = nil, sourceSHA256: String?,
                     entityTag: String? = nil, expectedRevision: String? = nil) async throws -> AndroidWorkspaceSource {
        guard Self.validPath(logicalPath), Self.validReference(sourceReference, kind: kind),
              sourceSHA256.map(Self.validDigest) ?? true,
              sourceDocumentID.map({ !$0.isEmpty && $0.utf8.count <= 8192 }) ?? true,
              entityTag.map({ $0.utf8.count <= 8192 }) ?? true else {
            throw AndroidWorkspaceSourceError.invalidMetadata
        }
        let revision = UUID().uuidString
        return try await database.writer { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM workspaces WHERE id = ?)",
                                    arguments: [workspaceID.uuidString]) == true else {
                throw AndroidWorkspaceSourceError.missingSource
            }
            let old = try Row.fetchOne(db, sql: "SELECT * FROM android_workspace_sources WHERE id = ?", arguments: [id.uuidString])
            if let old {
                let previous = try Self.decodeSource(old)
                guard try !Self.hasPreparedRecovery(db, sourceID: id) else { throw AndroidWorkspaceSourceError.invalidTransition }
                guard previous.workspaceID == workspaceID, let expectedRevision,
                      previous.revision == expectedRevision else { throw AndroidWorkspaceSourceError.staleRevision }
                try db.execute(sql: """
                    UPDATE android_workspace_sources SET logical_path = ?, kind = ?, source_reference = ?,
                    source_document_id = ?, source_sha256 = ?, entity_tag = ?, revision = ?, updated_at = ?
                    WHERE id = ? AND revision = ?
                    """, arguments: [logicalPath, kind.rawValue, sourceReference, sourceDocumentID, sourceSHA256,
                                     entityTag, revision, Date().timeIntervalSince1970, id.uuidString, expectedRevision])
            } else {
                guard expectedRevision == nil else { throw AndroidWorkspaceSourceError.staleRevision }
                try db.execute(sql: """
                    INSERT INTO android_workspace_sources
                    (id, workspace_id, logical_path, kind, source_reference, source_document_id,
                     source_sha256, entity_tag, revision, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [id.uuidString, workspaceID.uuidString, logicalPath, kind.rawValue, sourceReference,
                                     sourceDocumentID, sourceSHA256, entityTag, revision, Date().timeIntervalSince1970])
            }
            return AndroidWorkspaceSource(id: id, workspaceID: workspaceID, logicalPath: logicalPath,
                kind: kind, sourceReference: sourceReference, sourceDocumentID: sourceDocumentID,
                sourceSHA256: sourceSHA256, entityTag: entityTag, revision: revision)
        }
    }

    /// Compare binding revision and commit recovery metadata in ONE writer
    /// transaction. A source mismatch is durably recorded as conflict; it
    /// never receives a prepared permit. Duplicate IDs must match all bytes.
    public func prepareRecovery(id: UUID, sourceID: UUID, expectedRevision: String,
                                backupRelativePath: String, backupSHA256: String,
                                replacementSHA256: String) async throws -> AndroidWorkspaceRecovery {
        guard Self.validPath(backupRelativePath), Self.validDigest(backupSHA256),
              Self.validDigest(replacementSHA256) else { throw AndroidWorkspaceSourceError.invalidMetadata }
        return try await database.writer { db in
            if let old = try Row.fetchOne(db, sql: "SELECT * FROM android_workspace_recovery WHERE id = ?", arguments: [id.uuidString]) {
                let receipt = try Self.decodeRecovery(old)
                guard receipt.sourceID == sourceID, receipt.sourceRevision == expectedRevision,
                      receipt.backupRelativePath == backupRelativePath, receipt.backupSHA256 == backupSHA256,
                      receipt.replacementSHA256 == replacementSHA256 else { throw AndroidWorkspaceSourceError.receiptMismatch }
                return receipt
            }
            guard try !Self.hasPreparedRecovery(db, sourceID: sourceID) else { throw AndroidWorkspaceSourceError.invalidTransition }
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM android_workspace_sources WHERE id = ?", arguments: [sourceID.uuidString])
            else { throw AndroidWorkspaceSourceError.missingSource }
            let source = try Self.decodeSource(row)
            guard source.revision == expectedRevision else { throw AndroidWorkspaceSourceError.staleRevision }
            let state: AndroidWorkspaceRecoveryState = source.sourceSHA256 == backupSHA256 ? .prepared : .conflict
            let now = Date().timeIntervalSince1970
            try db.execute(sql: """
                INSERT INTO android_workspace_recovery
                (id, source_id, workspace_id, source_revision, source_reference, source_document_id,
                 backup_relative_path, backup_sha256, replacement_sha256, state, observed_sha256, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [id.uuidString, sourceID.uuidString, source.workspaceID.uuidString, expectedRevision,
                    source.sourceReference, source.sourceDocumentID, backupRelativePath, backupSHA256,
                    replacementSHA256, state.rawValue, backupSHA256, now, now])
            return AndroidWorkspaceRecovery(id: id, sourceID: sourceID, workspaceID: source.workspaceID,
                sourceRevision: expectedRevision, sourceReference: source.sourceReference,
                sourceDocumentID: source.sourceDocumentID, backupRelativePath: backupRelativePath,
                backupSHA256: backupSHA256, replacementSHA256: replacementSHA256, state: state,
                observedSHA256: backupSHA256)
        }
    }

    /// One durable claim per recovery receipt. The coordinator supplies a
    /// fresh actual source hash after validating backup ownership/bytes.
    /// Replaying a claimed receipt never issues a second write permit;
    /// process-death recovery must reconcile its actual provider state.
    public func claimRecovery(id: UUID, observedSourceSHA256: String) async throws -> AndroidWorkspaceRecovery {
        guard Self.validDigest(observedSourceSHA256) else { throw AndroidWorkspaceSourceError.invalidMetadata }
        return try await database.writer { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM android_workspace_recovery WHERE id = ?", arguments: [id.uuidString])
            else { throw AndroidWorkspaceSourceError.missingSource }
            let receipt = try Self.decodeRecovery(row)
            guard receipt.state == .prepared else { throw AndroidWorkspaceSourceError.invalidTransition }
            let sourceRow = try Row.fetchOne(db, sql: "SELECT * FROM android_workspace_sources WHERE id = ?", arguments: [receipt.sourceID.uuidString])
            let source = try sourceRow.map(Self.decodeSource)
            let matches = source?.workspaceID == receipt.workspaceID && source?.revision == receipt.sourceRevision &&
                source?.sourceReference == receipt.sourceReference && observedSourceSHA256 == receipt.backupSHA256
            let state: AndroidWorkspaceRecoveryState = matches ? .writing : .conflict
            try db.execute(sql: "UPDATE android_workspace_recovery SET state = ?, observed_sha256 = ?, updated_at = ? WHERE id = ? AND state = 'prepared'",
                arguments: [state.rawValue, observedSourceSHA256, Date().timeIntervalSince1970, id.uuidString])
            guard db.changesCount == 1,
                  let updated = try Row.fetchOne(db, sql: "SELECT * FROM android_workspace_recovery WHERE id = ?", arguments: [id.uuidString])
            else { throw AndroidWorkspaceSourceError.invalidTransition }
            return try Self.decodeRecovery(updated)
        }
    }

    /// Complete after actual provider/network read-back. A raced native
    /// binding revision records conflict and preserves recovery. No generic
    /// provider atomic-CAS claim and no automatic recovery-byte deletion.
    public func finishRecovery(id: UUID, requestedState: AndroidWorkspaceRecoveryState,
                               observedSHA256: String?, entityTag: String? = nil) async throws -> AndroidWorkspaceRecovery {
        guard requestedState != .prepared, requestedState != .writing, observedSHA256.map(Self.validDigest) ?? true,
              entityTag.map({ $0.utf8.count <= 8192 }) ?? true else { throw AndroidWorkspaceSourceError.invalidMetadata }
        return try await database.writer { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM android_workspace_recovery WHERE id = ?", arguments: [id.uuidString])
            else { throw AndroidWorkspaceSourceError.missingSource }
            let receipt = try Self.decodeRecovery(row)
            if receipt.state != .prepared && receipt.state != .writing {
                guard receipt.state == requestedState, receipt.observedSHA256 == observedSHA256 else {
                    throw AndroidWorkspaceSourceError.invalidTransition
                }
                return receipt
            }
            var finalState = requestedState
            if requestedState == .committed {
                guard receipt.state == .writing else { throw AndroidWorkspaceSourceError.invalidTransition }
                guard observedSHA256 == receipt.replacementSHA256 else { throw AndroidWorkspaceSourceError.receiptMismatch }
                try db.execute(sql: """
                    UPDATE android_workspace_sources SET source_sha256 = ?, entity_tag = ?, revision = ?, updated_at = ?
                    WHERE id = ? AND workspace_id = ? AND revision = ? AND source_reference = ?
                    """, arguments: [observedSHA256, entityTag, UUID().uuidString, Date().timeIntervalSince1970,
                        receipt.sourceID.uuidString, receipt.workspaceID.uuidString, receipt.sourceRevision, receipt.sourceReference])
                if db.changesCount != 1 { finalState = .conflict }
            }
            try db.execute(sql: "UPDATE android_workspace_recovery SET state = ?, observed_sha256 = ?, updated_at = ? WHERE id = ? AND state IN ('prepared', 'writing')",
                arguments: [finalState.rawValue, observedSHA256, Date().timeIntervalSince1970, id.uuidString])
            guard let updated = try Row.fetchOne(db, sql: "SELECT * FROM android_workspace_recovery WHERE id = ?", arguments: [id.uuidString])
            else { throw AndroidWorkspaceSourceError.missingSource }
            return try Self.decodeRecovery(updated)
        }
    }

    /// Recovery survives process death and task deletion. Bounded pages;
    /// callers reconcile actual bytes before any cleanup or new permit.
    public func pendingRecovery(workspaceID: UUID? = nil, afterID: String? = nil, limit: Int = 100) async throws -> [AndroidWorkspaceRecovery] {
        let bounded = min(max(limit, 1), 200)
        return try await database.reader { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM android_workspace_recovery WHERE state != 'committed'
                AND (? IS NULL OR workspace_id = ?) AND (? IS NULL OR id > ?) ORDER BY id LIMIT ?
                """, arguments: [workspaceID?.uuidString, workspaceID?.uuidString, afterID, afterID, bounded])
                .map(Self.decodeRecovery)
        }
    }

    /// METADATA journal page over EVERY recovery state — the settled
    /// `committed` receipts included — in stable id order with the same
    /// bounds/pagination as the pending view. The pending view above stays
    /// unfinished-only because reconcile sweeps must never re-admit a
    /// settled receipt; the journal page is the receipt history the trusted
    /// host UI reads (metadata only, never bytes).
    public func recoveryJournal(workspaceID: UUID? = nil, afterID: String? = nil, limit: Int = 100) async throws -> [AndroidWorkspaceRecovery] {
        let bounded = min(max(limit, 1), 200)
        return try await database.reader { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM android_workspace_recovery
                WHERE (? IS NULL OR workspace_id = ?) AND (? IS NULL OR id > ?) ORDER BY id LIMIT ?
                """, arguments: [workspaceID?.uuidString, workspaceID?.uuidString, afterID, afterID, bounded])
                .map(Self.decodeRecovery)
        }
    }

    private static func hasPreparedRecovery(_ db: Database, sourceID: UUID) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM android_workspace_recovery WHERE source_id = ? AND state IN ('prepared', 'writing'))",
                          arguments: [sourceID.uuidString]) == true
    }

    private static func validDigest(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func validPath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 4096, !path.hasPrefix("/"), !path.hasPrefix("~"),
              !path.contains("\\"), !path.contains("\0"), path == (path as NSString).standardizingPath else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    private static func validReference(_ reference: String, kind: AndroidWorkspaceSourceKind) -> Bool {
        guard reference.utf8.count <= 8192 else { return false }
        if kind != .saf { return UUID(uuidString: reference) != nil }
        guard let components = URLComponents(string: reference), components.scheme == "content",
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              components.fragment == nil else { return false }
        return !reference.contains("\0") && !reference.contains("\n") && !reference.contains("\r")
    }
    private static func decodeSource(_ row: Row) throws -> AndroidWorkspaceSource {
        guard let id = UUID(uuidString: row["id"]), let workspaceID = UUID(uuidString: row["workspace_id"]),
              let kind = AndroidWorkspaceSourceKind(rawValue: row["kind"]) else { throw AndroidWorkspaceSourceError.invalidMetadata }
        return AndroidWorkspaceSource(id: id, workspaceID: workspaceID, logicalPath: row["logical_path"], kind: kind,
            sourceReference: row["source_reference"], sourceDocumentID: row["source_document_id"],
            sourceSHA256: row["source_sha256"], entityTag: row["entity_tag"], revision: row["revision"])
    }
    private static func decodeRecovery(_ row: Row) throws -> AndroidWorkspaceRecovery {
        guard let id = UUID(uuidString: row["id"]), let sourceID = UUID(uuidString: row["source_id"]),
              let workspaceID = UUID(uuidString: row["workspace_id"]),
              let state = AndroidWorkspaceRecoveryState(rawValue: row["state"]) else { throw AndroidWorkspaceSourceError.invalidMetadata }
        return AndroidWorkspaceRecovery(id: id, sourceID: sourceID, workspaceID: workspaceID,
            sourceRevision: row["source_revision"], sourceReference: row["source_reference"], sourceDocumentID: row["source_document_id"],
            backupRelativePath: row["backup_relative_path"], backupSHA256: row["backup_sha256"], replacementSHA256: row["replacement_sha256"],
            state: state, observedSHA256: row["observed_sha256"])
    }
}
