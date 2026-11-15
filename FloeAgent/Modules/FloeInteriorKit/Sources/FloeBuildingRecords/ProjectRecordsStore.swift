import Foundation
import GRDB

/// The project-owned building records database.
///
/// One store is bound to one `.floeproject`-style container and one project
/// identity. Callers address records by typed IDs; there is no public API that
/// accepts SQL or a source file path. A simple revision counter provides
/// compare-and-swap for every committed mutation, and batch operations commit
/// in a single SQLite transaction.
public final class ProjectRecordsStore: @unchecked Sendable {
    public let projectID: ProjectID
    public let limits: RecordsLimits

    let database: DatabaseQueue
    let container: ProjectContainer

    private init(
        projectID: ProjectID,
        database: DatabaseQueue,
        container: ProjectContainer,
        limits: RecordsLimits
    ) {
        self.projectID = projectID
        self.database = database
        self.container = container
        self.limits = limits
    }

    // MARK: - Open and create

    /// Create a new project container. Fails instead of opening or replacing an
    /// existing records database. On a failed first write the newly created
    /// database file and its sidecars are removed.
    public static func createProject(
        at containerURL: URL,
        name: String,
        projectID: ProjectID = ProjectID(),
        limits: RecordsLimits = RecordsLimits()
    ) throws -> ProjectRecordsStore {
        try limits.validate()
        let normalizedName = try validatedProjectName(name, limits: limits)
        let container = ProjectContainer(rootURL: containerURL)
        do {
            try container.prepareRoot()
            let databaseURL = try container.prepareDatabaseFile()
            guard !FileManager.default.fileExists(atPath: databaseURL.path) else {
                throw BuildingRecordsError.projectAlreadyExists
            }
            let database = try makeDatabase(at: databaseURL)
            do {
                try makeMigrator().migrate(database)
                let now = Date()
                try database.write { db in
                    try db.execute(
                        sql: """
                            INSERT INTO project_state
                                (singleton, project_id, name, created_at, updated_at, records_revision)
                            VALUES (1, ?, ?, ?, ?, 0)
                            """,
                        arguments: [projectID.databaseValue, normalizedName, now, now]
                    )
                }
                return ProjectRecordsStore(
                    projectID: projectID,
                    database: database,
                    container: container,
                    limits: limits
                )
            } catch {
                try? database.close()
                removeDatabaseFiles(at: databaseURL)
                throw error
            }
        } catch let fileError as ProjectFileError {
            throw mapContainerError(fileError)
        }
    }

    /// Open an existing project. Migrations are applied before any record is
    /// returned; a container without a project identity is rejected.
    public static func openProject(
        at containerURL: URL,
        limits: RecordsLimits = RecordsLimits()
    ) throws -> ProjectRecordsStore {
        try limits.validate()
        let container = ProjectContainer(rootURL: containerURL)
        let databaseURL: URL
        do {
            databaseURL = try container.existingRegularFileURL(
                relativePath: ProjectContainer.databaseRelativePath
            )
        } catch ProjectFileError.missing {
            throw BuildingRecordsError.projectNotFound
        } catch let fileError as ProjectFileError {
            throw mapContainerError(fileError)
        }
        let database = try makeDatabase(at: databaseURL)
        do {
            try makeMigrator().migrate(database)
            let state = try database.read { db in
                try Self.loadProjectState(db)
            }
            return ProjectRecordsStore(
                projectID: state.id,
                database: database,
                container: container,
                limits: limits
            )
        } catch {
            try? database.close()
            throw error
        }
    }

    /// Release the SQLite connection. The store cannot be used afterwards.
    public func close() throws {
        try database.close()
    }

    // MARK: - Project

    public func currentProject() throws -> ProjectRecord {
        try database.read { db in
            try Self.loadProjectState(db).record
        }
    }

    public func currentRevision() throws -> Int {
        try database.read { db in
            try Self.loadProjectState(db).revision
        }
    }

    public func renameProject(
        to name: String,
        expectedRevision: Int
    ) throws -> ProjectMutation<ProjectRecord> {
        let normalizedName = try Self.validatedProjectName(name, limits: limits)
        return try database.write { db in
            let state = try Self.loadProjectState(db)
            if state.name == normalizedName {
                return ProjectMutation(
                    value: state.record,
                    receipt: MutationReceipt(
                        projectID: projectID,
                        previousRevision: state.revision,
                        revision: state.revision,
                        didChange: false
                    )
                )
            }
            try requireRevision(db, expected: expectedRevision, actual: state.revision)
            try db.execute(
                sql: """
                    UPDATE project_state
                    SET name = ?, updated_at = ?, records_revision = records_revision + 1
                    WHERE singleton = 1 AND records_revision = ?
                    """,
                arguments: [normalizedName, Date(), state.revision]
            )
            guard db.changesCount == 1 else {
                let actual = try Self.loadProjectState(db).revision
                throw BuildingRecordsError.revisionConflict(expected: expectedRevision, actual: actual)
            }
            let revision = state.revision + 1
            let updated = try Self.loadProjectState(db)
            return ProjectMutation(
                value: updated.record,
                receipt: MutationReceipt(
                    projectID: projectID,
                    previousRevision: state.revision,
                    revision: revision,
                    didChange: true
                )
            )
        }
    }

    // MARK: - Rooms

    public func createRoom(
        _ draft: RoomDraft,
        expectedRevision: Int
    ) throws -> ProjectMutation<RoomRecord> {
        let validated = try validatedRoom(draft)
        return try database.write { db in
            let state = try Self.loadProjectState(db)
            try requireRevision(db, expected: expectedRevision, actual: state.revision)
            let roomID = RoomID()
            let now = Date()
            try db.execute(
                sql: """
                    INSERT INTO room
                        (id, project_id, name, storey, kind, notes, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    roomID.databaseValue,
                    projectID.databaseValue,
                    validated.name,
                    validated.storey,
                    validated.kind.rawValue,
                    validated.notes,
                    now,
                    now
                ]
            )
            for alias in validated.aliases {
                try db.execute(
                    sql: "INSERT INTO room_alias (room_id, alias) VALUES (?, ?)",
                    arguments: [roomID.databaseValue, alias]
                )
            }
            let revision = try bumpRevision(db, from: state.revision)
            let room = try roomRecord(db, id: roomID)
            return ProjectMutation(
                value: room,
                receipt: MutationReceipt(
                    projectID: projectID,
                    previousRevision: state.revision,
                    revision: revision,
                    didChange: true
                )
            )
        }
    }

    public func updateRoom(
        _ id: RoomID,
        with draft: RoomDraft,
        expectedRevision: Int
    ) throws -> ProjectMutation<RoomRecord> {
        let validated = try validatedRoom(draft)
        return try database.write { db in
            let state = try Self.loadProjectState(db)
            let current = try roomRecord(db, id: id)
            if current.name == validated.name,
               current.storey == validated.storey,
               current.kind == validated.kind,
               current.notes == validated.notes,
               current.aliases == validated.aliases {
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
            try requireRevision(db, expected: expectedRevision, actual: state.revision)
            try db.execute(
                sql: """
                    UPDATE room
                    SET name = ?, storey = ?, kind = ?, notes = ?, updated_at = ?
                    WHERE id = ? AND project_id = ?
                    """,
                arguments: [
                    validated.name,
                    validated.storey,
                    validated.kind.rawValue,
                    validated.notes,
                    Date(),
                    id.databaseValue,
                    projectID.databaseValue
                ]
            )
            guard db.changesCount == 1 else { throw BuildingRecordsError.roomNotFound(id) }
            try db.execute(
                sql: "DELETE FROM room_alias WHERE room_id = ?",
                arguments: [id.databaseValue]
            )
            for alias in validated.aliases {
                try db.execute(
                    sql: "INSERT INTO room_alias (room_id, alias) VALUES (?, ?)",
                    arguments: [id.databaseValue, alias]
                )
            }
            let revision = try bumpRevision(db, from: state.revision)
            let room = try roomRecord(db, id: id)
            return ProjectMutation(
                value: room,
                receipt: MutationReceipt(
                    projectID: projectID,
                    previousRevision: state.revision,
                    revision: revision,
                    didChange: true
                )
            )
        }
    }

    public func renameRoom(
        _ id: RoomID,
        to name: String,
        expectedRevision: Int
    ) throws -> ProjectMutation<RoomRecord> {
        let current = try room(id)
        var draft = RoomDraft(
            name: name,
            storey: current.storey,
            kind: current.kind,
            notes: current.notes,
            aliases: current.aliases
        )
        draft.name = name
        return try updateRoom(id, with: draft, expectedRevision: expectedRevision)
    }

    public func rooms() throws -> [RoomRecord] {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM room
                    WHERE project_id = ?
                    ORDER BY COALESCE(storey, ''), name COLLATE NOCASE, id
                    """,
                arguments: [projectID.databaseValue]
            )
            let aliasRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT a.room_id, a.alias
                    FROM room_alias a
                    JOIN room r ON r.id = a.room_id
                    WHERE r.project_id = ?
                    ORDER BY a.alias COLLATE NOCASE
                    """,
                arguments: [projectID.databaseValue]
            )
            var aliases: [String: [String]] = [:]
            for row in aliasRows {
                let roomID: String = row["room_id"]
                let alias: String = row["alias"]
                aliases[roomID, default: []].append(alias)
            }
            return try rows.map { row in
                let id: RoomID = try row.recordID("id")
                let sortedAliases = (aliases[id.databaseValue] ?? [])
                    .sorted { $0.lowercased() < $1.lowercased() }
                return try Self.roomRecord(row: row, aliases: sortedAliases)
            }
        }
    }

    public func room(_ id: RoomID) throws -> RoomRecord {
        try database.read { db in
            try roomRecord(db, id: id)
        }
    }

    // MARK: - Internal state helpers

    struct ProjectState {
        let id: ProjectID
        let name: String
        let createdAt: Date
        let updatedAt: Date
        let revision: Int

        var record: ProjectRecord {
            ProjectRecord(
                id: id,
                name: name,
                createdAt: createdAt,
                updatedAt: updatedAt,
                revision: revision
            )
        }
    }

    static func loadProjectState(_ db: Database) throws -> ProjectState {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT project_id, name, created_at, updated_at, records_revision
                FROM project_state WHERE singleton = 1
                """
        ) else {
            throw BuildingRecordsError.projectNotFound
        }
        let id: ProjectID = try row.recordID("project_id")
        let name: String = row["name"]
        let createdAt: Date = row["created_at"]
        let updatedAt: Date = row["updated_at"]
        let revision: Int = row["records_revision"]
        return ProjectState(
            id: id,
            name: name,
            createdAt: createdAt,
            updatedAt: updatedAt,
            revision: revision
        )
    }

    func requireRevision(_ db: Database, expected: Int, actual: Int) throws {
        guard actual == expected else {
            throw BuildingRecordsError.revisionConflict(expected: expected, actual: actual)
        }
    }

    @discardableResult
    func bumpRevision(_ db: Database, from previous: Int) throws -> Int {
        try db.execute(
            sql: """
                UPDATE project_state
                SET records_revision = records_revision + 1, updated_at = ?
                WHERE singleton = 1 AND records_revision = ?
                """,
            arguments: [Date(), previous]
        )
        guard db.changesCount == 1 else {
            let actual = try Self.loadProjectState(db).revision
            throw BuildingRecordsError.revisionConflict(expected: previous, actual: actual)
        }
        return previous + 1
    }

    // MARK: - Room helpers

    struct ValidatedRoom {
        let name: String
        let storey: String?
        let kind: RoomKind
        let notes: String
        let aliases: [String]
    }

    func validatedRoom(_ draft: RoomDraft) throws -> ValidatedRoom {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= limits.maxRoomNameLength else {
            throw BuildingRecordsError.invalidValue(
                field: "room.name",
                reason: "must be 1...\(limits.maxRoomNameLength) characters"
            )
        }
        let storey: String?
        if let rawStorey = draft.storey?.trimmingCharacters(in: .whitespacesAndNewlines), !rawStorey.isEmpty {
            guard rawStorey.count <= 80 else {
                throw BuildingRecordsError.invalidValue(field: "room.storey", reason: "must be at most 80 characters")
            }
            storey = rawStorey
        } else {
            storey = nil
        }
        guard draft.notes.count <= limits.maxTextLength else {
            throw BuildingRecordsError.invalidValue(
                field: "room.notes",
                reason: "must be at most \(limits.maxTextLength) characters"
            )
        }
        guard draft.aliases.count <= limits.maxAliasCount else {
            throw BuildingRecordsError.invalidValue(
                field: "room.aliases",
                reason: "must contain at most \(limits.maxAliasCount) aliases"
            )
        }
        var seen: Set<String> = []
        var aliases: [String] = []
        for rawAlias in draft.aliases {
            let alias = rawAlias.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !alias.isEmpty, alias.count <= 200 else {
                throw BuildingRecordsError.invalidValue(field: "room.aliases", reason: "aliases must be 1...200 characters")
            }
            let key = alias.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            ).lowercased()
            if seen.insert(key).inserted {
                aliases.append(alias)
            }
        }
        aliases.sort { lhs, rhs in
            lhs.lowercased() < rhs.lowercased()
        }
        return ValidatedRoom(
            name: name,
            storey: storey,
            kind: draft.kind,
            notes: draft.notes,
            aliases: aliases
        )
    }

    func roomRecord(_ db: Database, id: RoomID) throws -> RoomRecord {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM room WHERE id = ? AND project_id = ?",
            arguments: [id.databaseValue, projectID.databaseValue]
        ) else {
            throw BuildingRecordsError.roomNotFound(id)
        }
        let aliases = try String.fetchAll(
            db,
            sql: "SELECT alias FROM room_alias WHERE room_id = ?",
            arguments: [id.databaseValue]
        ).sorted { $0.lowercased() < $1.lowercased() }
        return try Self.roomRecord(row: row, aliases: aliases)
    }

    static func roomRecord(row: Row, aliases: [String]) throws -> RoomRecord {
        let id: RoomID = try row.recordID("id")
        let projectID: ProjectID = try row.recordID("project_id")
        let name: String = row["name"]
        let storey: String? = row["storey"]
        let kind: RoomKind = try row.requiredEnum("kind", as: RoomKind.self)
        let notes: String = row["notes"]
        let createdAt: Date = row["created_at"]
        let updatedAt: Date = row["updated_at"]
        return RoomRecord(
            id: id,
            projectID: projectID,
            name: name,
            storey: storey,
            kind: kind,
            notes: notes,
            aliases: aliases,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    static func validatedProjectName(_ name: String, limits: RecordsLimits) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= limits.maxTitleLength else {
            throw BuildingRecordsError.invalidValue(
                field: "project.name",
                reason: "must be 1...\(limits.maxTitleLength) characters"
            )
        }
        return trimmed
    }

    // MARK: - Database setup

    static func makeDatabase(at url: URL) throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.journalMode = .wal
        configuration.observesSuspensionNotifications = true
        return try DatabaseQueue(path: url.path, configuration: configuration)
    }

    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("building.records.v1") { db in
            for statement in RecordsSchema.v1Records {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration("building.records.v2.bom") { db in
            for statement in RecordsSchema.v2BOM {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration("building.records.v3.observation-origin") { db in
            for statement in RecordsSchema.v3ObservationOrigin { try db.execute(sql: statement) }
        }
        return migrator
    }

    static func removeDatabaseFiles(at url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    static func mapContainerError(_ error: ProjectFileError) -> BuildingRecordsError {
        switch error {
        case .missing:
            return .projectNotFound
        case .corrupted:
            return .invalidValue(field: "projectFile", reason: "the file is not a regular readable file")
        case .pathEscapesProject:
            return .pathEscapesProject
        }
    }

    func validateListLimit(_ limit: Int) throws {
        guard limit > 0, limit <= limits.maxListLimit else {
            throw BuildingRecordsError.invalidValue(
                field: "limit",
                reason: "must be 1...\(limits.maxListLimit)"
            )
        }
    }

    func validateOffset(_ offset: Int) throws {
        guard offset >= 0, offset <= 1_000_000 else {
            throw BuildingRecordsError.invalidValue(field: "offset", reason: "must be 0...1000000")
        }
    }
}
