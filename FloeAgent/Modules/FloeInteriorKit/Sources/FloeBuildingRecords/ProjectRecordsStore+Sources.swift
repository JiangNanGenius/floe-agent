import Foundation
import GRDB

extension ProjectRecordsStore {
    // MARK: - Import

    public func importSource(
        _ request: SourceImportRequest,
        expectedRevision: Int
    ) throws -> ProjectMutation<SourceImportResult> {
        let file = try validatedFile(
            data: request.data,
            originalName: request.originalName,
            mediaType: request.mediaType,
            note: request.note
        )
        let roomIDs = try normalizedRoomIDs(request.roomIDs)
        let sha256 = RecordsCodec.sha256Hex(file.data)
        let title = try sourceTitle(request.title, originalName: file.originalName)
        let operationKey = try validatedIdempotencyKey(request.idempotencyKey)
        let fingerprint = try importFingerprint(
            kind: request.kind,
            title: title,
            originalName: file.originalName,
            mediaType: file.mediaType,
            note: file.note,
            sha256: sha256,
            roomIDs: roomIDs
        )

        if let operationKey {
            let existing = try database.read { db -> ImportOperation? in
                try loadImportOperation(db, key: operationKey)
            }
            if let existing {
                guard existing.fingerprint == fingerprint else {
                    throw BuildingRecordsError.idempotencyConflict(operationKey)
                }
                try installBlobOrThrow(data: file.data, sha256: sha256)
                return try existingImportResult(
                    sourceID: existing.sourceID,
                    versionID: existing.versionID,
                    fingerprint: fingerprint,
                    operationKey: operationKey
                )
            }
        }

        try database.read { db in
            try validateRoomsExist(db, roomIDs: roomIDs)
        }
        try installBlobOrThrow(data: file.data, sha256: sha256)
        let now = Date()
        let sourceID = SourceID()
        let versionID = SourceVersionID()

        return try database.write { db in
            let state = try Self.loadProjectState(db)
            if let operationKey, let existing = try loadImportOperation(db, key: operationKey) {
                guard existing.fingerprint == fingerprint else {
                    throw BuildingRecordsError.idempotencyConflict(operationKey)
                }
                let source = try sourceRecord(db, id: existing.sourceID)
                let version = try sourceVersionRecord(db, id: existing.versionID)
                return ProjectMutation(
                    value: SourceImportResult(source: source, version: version, roomIDs: source.roomIDs),
                    receipt: MutationReceipt(
                        projectID: projectID,
                        previousRevision: state.revision,
                        revision: state.revision,
                        didChange: false
                    )
                )
            }
            try validateRoomsExist(db, roomIDs: roomIDs)
            try requireRevision(db, expected: expectedRevision, actual: state.revision)
            try insertContentBlob(db, data: file.data, sha256: sha256, mediaType: file.mediaType, at: now)
            try db.execute(
                sql: """
                    INSERT INTO source (id, project_id, kind, title, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    sourceID.databaseValue,
                    projectID.databaseValue,
                    request.kind.rawValue,
                    title,
                    now,
                    now
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO source_version
                        (id, source_id, version, sha256, original_name, media_type, byte_length, note, imported_at)
                    VALUES (?, ?, 1, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    versionID.databaseValue,
                    sourceID.databaseValue,
                    sha256,
                    file.originalName,
                    file.mediaType,
                    file.data.count,
                    file.note,
                    now
                ]
            )
            for roomID in roomIDs {
                try db.execute(
                    sql: "INSERT INTO source_room (source_id, room_id, linked_at) VALUES (?, ?, ?)",
                    arguments: [sourceID.databaseValue, roomID.databaseValue, now]
                )
            }
            if let operationKey {
                try db.execute(
                    sql: """
                        INSERT INTO import_operation
                            (operation_key, project_id, request_fingerprint, source_id, source_version_id, created_at)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        operationKey,
                        projectID.databaseValue,
                        fingerprint,
                        sourceID.databaseValue,
                        versionID.databaseValue,
                        now
                    ]
                )
            }
            let revision = try bumpRevision(db, from: state.revision)
            let source = try sourceRecord(db, id: sourceID)
            let version = try sourceVersionRecord(db, id: versionID)
            return ProjectMutation(
                value: SourceImportResult(source: source, version: version, roomIDs: source.roomIDs),
                receipt: MutationReceipt(
                    projectID: projectID,
                    previousRevision: state.revision,
                    revision: revision,
                    didChange: true
                )
            )
        }
    }

    /// Append an immutable version to an existing source. Retrying the exact
    /// latest bytes/name/media type/note returns the existing version without a
    /// revision bump; different bytes create the next version.
    public func addSourceVersion(
        _ sourceID: SourceID,
        data: Data,
        originalName: String,
        mediaType: String,
        note: String = "",
        expectedRevision: Int
    ) throws -> ProjectMutation<SourceVersion> {
        let file = try validatedFile(
            data: data,
            originalName: originalName,
            mediaType: mediaType,
            note: note
        )
        let sha256 = RecordsCodec.sha256Hex(file.data)
        let latestBefore = try database.read { db in
            try latestSourceVersion(db, sourceID: sourceID)
        }
        if latestBefore.contentSHA256 == sha256,
           latestBefore.originalName == file.originalName,
           latestBefore.mediaType == file.mediaType,
           latestBefore.note == file.note {
            try installBlobOrThrow(data: file.data, sha256: sha256)
            let revision = try database.read { db in try Self.loadProjectState(db).revision }
            return ProjectMutation(
                value: latestBefore,
                receipt: MutationReceipt(
                    projectID: projectID,
                    previousRevision: revision,
                    revision: revision,
                    didChange: false
                )
            )
        }

        try installBlobOrThrow(data: file.data, sha256: sha256)
        let now = Date()
        let versionID = SourceVersionID()

        return try database.write { db in
            let state = try Self.loadProjectState(db)
            let latest = try latestSourceVersion(db, sourceID: sourceID)
            if latest.contentSHA256 == sha256,
               latest.originalName == file.originalName,
               latest.mediaType == file.mediaType,
               latest.note == file.note {
                return ProjectMutation(
                    value: latest,
                    receipt: MutationReceipt(
                        projectID: projectID,
                        previousRevision: state.revision,
                        revision: state.revision,
                        didChange: false
                    )
                )
            }
            try requireRevision(db, expected: expectedRevision, actual: state.revision)
            try insertContentBlob(db, data: file.data, sha256: sha256, mediaType: file.mediaType, at: now)
            let nextVersion = latest.version + 1
            try db.execute(
                sql: """
                    INSERT INTO source_version
                        (id, source_id, version, sha256, original_name, media_type, byte_length, note, imported_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    versionID.databaseValue,
                    sourceID.databaseValue,
                    nextVersion,
                    sha256,
                    file.originalName,
                    file.mediaType,
                    file.data.count,
                    file.note,
                    now
                ]
            )
            try db.execute(
                sql: "UPDATE source SET updated_at = ? WHERE id = ? AND project_id = ?",
                arguments: [now, sourceID.databaseValue, projectID.databaseValue]
            )
            let revision = try bumpRevision(db, from: state.revision)
            let version = try sourceVersionRecord(db, id: versionID)
            return ProjectMutation(
                value: version,
                receipt: MutationReceipt(
                    projectID: projectID,
                    previousRevision: state.revision,
                    revision: revision,
                    didChange: true
                )
            )
        }
    }

    // MARK: - Reading and listing

    public func sources(
        roomID: RoomID? = nil,
        kind: SourceKind? = nil,
        limit: Int = 50,
        offset: Int = 0
    ) throws -> [SourceRecord] {
        try validateListLimit(limit)
        try validateOffset(offset)
        let kindRaw = kind?.rawValue
        let roomValue = roomID?.databaseValue
        return try database.read { db in
            let arguments: StatementArguments = [
                projectID.databaseValue,
                kindRaw,
                kindRaw,
                roomValue,
                roomValue,
                limit,
                offset
            ]
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT s.*,
                        (SELECT v.id FROM source_version v
                            WHERE v.source_id = s.id ORDER BY v.version DESC LIMIT 1) AS latest_version_id,
                        (SELECT v.version FROM source_version v
                            WHERE v.source_id = s.id ORDER BY v.version DESC LIMIT 1) AS latest_version_number,
                        (SELECT v.original_name FROM source_version v
                            WHERE v.source_id = s.id ORDER BY v.version DESC LIMIT 1) AS latest_original_name,
                        (SELECT count(*) FROM source_version v WHERE v.source_id = s.id) AS version_count
                    FROM source s
                    WHERE s.project_id = ?
                        AND (? IS NULL OR s.kind = ?)
                        AND (? IS NULL OR EXISTS (
                            SELECT 1 FROM source_room sr
                            WHERE sr.source_id = s.id AND sr.room_id = ?
                        ))
                    ORDER BY s.updated_at DESC, s.id
                    LIMIT ? OFFSET ?
                    """,
                arguments: arguments
            )
            var result: [SourceRecord] = []
            result.reserveCapacity(rows.count)
            for row in rows {
                let sourceIDs = try sourceRoomIDs(db, sourceID: row.recordID("id"))
                result.append(try sourceRecord(row: row, roomIDs: sourceIDs))
            }
            return result
        }
    }

    public func source(_ id: SourceID) throws -> SourceRecord {
        try database.read { db in
            try sourceRecord(db, id: id)
        }
    }

    public func sourceVersions(of sourceID: SourceID) throws -> [SourceVersion] {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT v.* FROM source_version v
                    JOIN source s ON s.id = v.source_id
                    WHERE v.source_id = ? AND s.project_id = ?
                    ORDER BY v.version ASC
                    """,
                arguments: [sourceID.databaseValue, projectID.databaseValue]
            )
            return try rows.map { try sourceVersionRecord(row: $0) }
        }
    }

    public func sourceVersion(_ id: SourceVersionID) throws -> SourceVersion {
        try database.read { db in
            try sourceVersionRecord(db, id: id)
        }
    }

    public func sourceVersionContent(_ id: SourceVersionID) throws -> SourceVersionContent {
        let version = try sourceVersion(id)
        do {
            let data = try container.readBlob(sha256: version.contentSHA256, maxBytes: limits.maxSourceBytes)
            return SourceVersionContent(version: version, data: data)
        } catch ProjectFileError.missing {
            throw BuildingRecordsError.sourceFileMissing(id)
        } catch ProjectFileError.corrupted {
            throw BuildingRecordsError.sourceFileCorrupted(id)
        } catch ProjectFileError.pathEscapesProject {
            throw BuildingRecordsError.pathEscapesProject
        }
    }

    // MARK: - Associations

    public func setSourceRooms(
        _ sourceID: SourceID,
        roomIDs: Set<RoomID>,
        expectedRevision: Int
    ) throws -> ProjectMutation<SourceRecord> {
        let normalized = roomIDs.sorted { $0.description < $1.description }
        return try database.write { db in
            let state = try Self.loadProjectState(db)
            let current = try sourceRecord(db, id: sourceID)
            let currentIDs = Set(current.roomIDs)
            if currentIDs == roomIDs {
                return ProjectMutation(
                    value: current,
                    receipt: MutationReceipt(
                        projectID: projectID,
                        previousRevision: state.revision,
                        revision: state.revision,
                        didChange: false
                    )
                )
            }
            try validateRoomsExist(db, roomIDs: normalized)
            try requireRevision(db, expected: expectedRevision, actual: state.revision)
            try db.execute(
                sql: "DELETE FROM source_room WHERE source_id = ?",
                arguments: [sourceID.databaseValue]
            )
            let now = Date()
            for roomID in normalized {
                try db.execute(
                    sql: "INSERT INTO source_room (source_id, room_id, linked_at) VALUES (?, ?, ?)",
                    arguments: [sourceID.databaseValue, roomID.databaseValue, now]
                )
            }
            try db.execute(
                sql: "UPDATE source SET updated_at = ? WHERE id = ? AND project_id = ?",
                arguments: [now, sourceID.databaseValue, projectID.databaseValue]
            )
            let revision = try bumpRevision(db, from: state.revision)
            let updated = try sourceRecord(db, id: sourceID)
            return ProjectMutation(
                value: updated,
                receipt: MutationReceipt(
                    projectID: projectID,
                    previousRevision: state.revision,
                    revision: revision,
                    didChange: true
                )
            )
        }
    }

    // MARK: - Internal source helpers

    struct ImportOperation {
        let fingerprint: String
        let sourceID: SourceID
        let versionID: SourceVersionID
    }

    struct ValidatedFile {
        let data: Data
        let originalName: String
        let mediaType: String
        let note: String
    }

    func validatedFile(
        data: Data,
        originalName: String,
        mediaType: String,
        note: String
    ) throws -> ValidatedFile {
        guard !data.isEmpty else { throw BuildingRecordsError.emptyContent }
        guard data.count <= limits.maxSourceBytes else {
            throw BuildingRecordsError.contentTooLarge(limit: limits.maxSourceBytes, actual: data.count)
        }
        let name = originalName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= limits.maxOriginalNameLength else {
            throw BuildingRecordsError.invalidOriginalName
        }
        guard !name.contains("/"), !name.contains("\\") else {
            throw BuildingRecordsError.invalidOriginalName
        }
        guard !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw BuildingRecordsError.invalidOriginalName
        }
        let type = mediaType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !type.isEmpty, type.count <= 200 else {
            throw BuildingRecordsError.invalidMediaType
        }
        guard !type.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw BuildingRecordsError.invalidMediaType
        }
        guard note.count <= limits.maxTextLength else {
            throw BuildingRecordsError.invalidValue(
                field: "source.note",
                reason: "must be at most \(limits.maxTextLength) characters"
            )
        }
        return ValidatedFile(data: data, originalName: name, mediaType: type, note: note)
    }

    private func sourceTitle(_ rawTitle: String, originalName: String) throws -> String {
        let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return String(originalName.prefix(limits.maxTitleLength))
        }
        guard trimmed.count <= limits.maxTitleLength else {
            throw BuildingRecordsError.invalidValue(
                field: "source.title",
                reason: "must be 1...\(limits.maxTitleLength) characters"
            )
        }
        return trimmed
    }

    private func validatedIdempotencyKey(_ rawKey: String?) throws -> String? {
        guard let rawKey else { return nil }
        let trimmed = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= limits.maxIdempotencyKeyLength else {
            throw BuildingRecordsError.invalidValue(
                field: "idempotencyKey",
                reason: "must be 1...\(limits.maxIdempotencyKeyLength) characters"
            )
        }
        return trimmed
    }

    private func normalizedRoomIDs(_ roomIDs: [RoomID]) throws -> [RoomID] {
        let unique = Set(roomIDs)
        let sorted = unique.sorted { $0.description < $1.description }
        return sorted
    }

    func validateRoomsExist(_ db: Database, roomIDs: [RoomID]) throws {
        for roomID in roomIDs {
            guard try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM room WHERE id = ? AND project_id = ?",
                arguments: [roomID.databaseValue, projectID.databaseValue]
            ) == 1 else {
                throw BuildingRecordsError.roomNotFound(roomID)
            }
        }
    }

    private struct SourceImportFingerprint: Encodable {
        let kind: String
        let title: String
        let originalName: String
        let mediaType: String
        let note: String
        let sha256: String
        let roomIDs: [String]
    }

    private func importFingerprint(
        kind: SourceKind,
        title: String,
        originalName: String,
        mediaType: String,
        note: String,
        sha256: String,
        roomIDs: [RoomID]
    ) throws -> String {
        try RecordsCodec.fingerprint(SourceImportFingerprint(
            kind: kind.rawValue,
            title: title,
            originalName: originalName,
            mediaType: mediaType,
            note: note,
            sha256: sha256,
            roomIDs: roomIDs.map(\.description)
        ))
    }

    func loadImportOperation(_ db: Database, key: String) throws -> ImportOperation? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT request_fingerprint, source_id, source_version_id
                FROM import_operation WHERE operation_key = ?
                """,
            arguments: [key]
        ) else {
            return nil
        }
        let fingerprint: String = row["request_fingerprint"]
        let sourceID: SourceID = try row.recordID("source_id")
        let versionID: SourceVersionID = try row.recordID("source_version_id")
        return ImportOperation(fingerprint: fingerprint, sourceID: sourceID, versionID: versionID)
    }

    private func existingImportResult(
        sourceID: SourceID,
        versionID: SourceVersionID,
        fingerprint: String,
        operationKey: String
    ) throws -> ProjectMutation<SourceImportResult> {
        try database.read { db in
            let state = try Self.loadProjectState(db)
            let operation = try loadImportOperation(db, key: operationKey)
            guard let operation, operation.fingerprint == fingerprint else {
                throw BuildingRecordsError.idempotencyConflict(operationKey)
            }
            let source = try sourceRecord(db, id: sourceID)
            let version = try sourceVersionRecord(db, id: versionID)
            return ProjectMutation(
                value: SourceImportResult(source: source, version: version, roomIDs: source.roomIDs),
                receipt: MutationReceipt(
                    projectID: projectID,
                    previousRevision: state.revision,
                    revision: state.revision,
                    didChange: false
                )
            )
        }
    }

    func installBlobOrThrow(data: Data, sha256: String) throws {
        do {
            _ = try container.installBlob(data, sha256: sha256)
        } catch ProjectFileError.pathEscapesProject {
            throw BuildingRecordsError.pathEscapesProject
        } catch ProjectFileError.corrupted {
            throw BuildingRecordsError.invalidValue(
                field: "sourceFile",
                reason: "existing content does not match its recorded digest"
            )
        } catch ProjectFileError.missing {
            throw BuildingRecordsError.invalidValue(
                field: "sourceFile",
                reason: "the staged source file disappeared"
            )
        }
    }

    func insertContentBlob(
        _ db: Database,
        data: Data,
        sha256: String,
        mediaType: String,
        at date: Date
    ) throws {
        let relativePath = try container.blobRelativePath(for: sha256)
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO content_blob
                    (sha256, byte_length, media_type, relative_path, created_at)
                VALUES (?, ?, ?, ?, ?)
                """,
            arguments: [sha256, data.count, mediaType, relativePath, date]
        )
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT byte_length, relative_path FROM content_blob WHERE sha256 = ?",
            arguments: [sha256]
        ) else {
            throw BuildingRecordsError.invalidValue(field: "sha256", reason: "content blob was not registered")
        }
        let storedLength: Int = row["byte_length"]
        let storedPath: String = row["relative_path"]
        guard storedLength == data.count, storedPath == relativePath else {
            throw BuildingRecordsError.invalidValue(
                field: "sourceFile",
                reason: "the content-addressed blob index disagrees with the imported bytes"
            )
        }
    }

    func sourceRecord(_ db: Database, id: SourceID) throws -> SourceRecord {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT s.*,
                    (SELECT v.id FROM source_version v
                        WHERE v.source_id = s.id ORDER BY v.version DESC LIMIT 1) AS latest_version_id,
                    (SELECT v.version FROM source_version v
                        WHERE v.source_id = s.id ORDER BY v.version DESC LIMIT 1) AS latest_version_number,
                    (SELECT v.original_name FROM source_version v
                        WHERE v.source_id = s.id ORDER BY v.version DESC LIMIT 1) AS latest_original_name,
                    (SELECT count(*) FROM source_version v WHERE v.source_id = s.id) AS version_count
                FROM source s
                WHERE s.id = ? AND s.project_id = ?
                """,
            arguments: [id.databaseValue, projectID.databaseValue]
        ) else {
            throw BuildingRecordsError.sourceNotFound(id)
        }
        let roomIDs = try sourceRoomIDs(db, sourceID: id)
        return try sourceRecord(row: row, roomIDs: roomIDs)
    }

    func sourceRecord(row: Row, roomIDs: [RoomID]) throws -> SourceRecord {
        let id: SourceID = try row.recordID("id")
        let projectID: ProjectID = try row.recordID("project_id")
        let kind: SourceKind = try row.requiredEnum("kind", as: SourceKind.self)
        let title: String = row["title"]
        let createdAt: Date = row["created_at"]
        let updatedAt: Date = row["updated_at"]
        let latestVersionID: SourceVersionID = try row.recordID("latest_version_id")
        let latestVersionNumber: Int = row["latest_version_number"]
        let latestOriginalName: String = row["latest_original_name"]
        let versionCount: Int = row["version_count"]
        return SourceRecord(
            id: id,
            projectID: projectID,
            kind: kind,
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            latestVersionID: latestVersionID,
            latestVersionNumber: latestVersionNumber,
            latestOriginalName: latestOriginalName,
            versionCount: versionCount,
            roomIDs: roomIDs
        )
    }

    func sourceRoomIDs(_ db: Database, sourceID: SourceID) throws -> [RoomID] {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT room_id FROM source_room WHERE source_id = ? ORDER BY room_id",
            arguments: [sourceID.databaseValue]
        )
        return try rows.map { row -> RoomID in
            try row.recordID("room_id")
        }
    }

    func latestSourceVersion(_ db: Database, sourceID: SourceID) throws -> SourceVersion {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT v.* FROM source_version v
                JOIN source s ON s.id = v.source_id
                WHERE v.source_id = ? AND s.project_id = ?
                ORDER BY v.version DESC LIMIT 1
                """,
            arguments: [sourceID.databaseValue, projectID.databaseValue]
        ) else {
            throw BuildingRecordsError.sourceNotFound(sourceID)
        }
        return try sourceVersionRecord(row: row)
    }

    func sourceVersionRecord(_ db: Database, id: SourceVersionID) throws -> SourceVersion {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT v.* FROM source_version v
                JOIN source s ON s.id = v.source_id
                WHERE v.id = ? AND s.project_id = ?
                """,
            arguments: [id.databaseValue, projectID.databaseValue]
        ) else {
            throw BuildingRecordsError.sourceVersionNotFound(id)
        }
        return try sourceVersionRecord(row: row)
    }

    func sourceVersionRecord(row: Row) throws -> SourceVersion {
        let id: SourceVersionID = try row.recordID("id")
        let sourceID: SourceID = try row.recordID("source_id")
        let version: Int = row["version"]
        let sha256: String = row["sha256"]
        let originalName: String = row["original_name"]
        let mediaType: String = row["media_type"]
        let byteCount: Int = row["byte_length"]
        let note: String = row["note"]
        let importedAt: Date = row["imported_at"]
        let relativePath = try container.blobRelativePath(for: sha256)
        return SourceVersion(
            id: id,
            sourceID: sourceID,
            version: version,
            contentSHA256: sha256,
            byteCount: byteCount,
            mediaType: mediaType,
            originalName: originalName,
            relativePath: relativePath,
            note: note,
            importedAt: importedAt
        )
    }
}
