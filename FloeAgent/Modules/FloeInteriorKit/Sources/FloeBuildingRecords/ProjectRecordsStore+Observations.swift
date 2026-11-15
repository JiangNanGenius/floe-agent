import Foundation
import GRDB

extension ProjectRecordsStore {
    public func recordObservation(
        _ draft: ObservationDraft,
        expectedRevision: Int
    ) throws -> ProjectMutation<ObservationRecord> {
        let batch = try recordObservations([draft], expectedRevision: expectedRevision)
        guard let first = batch.value.first else {
            throw BuildingRecordsError.invalidValue(field: "observation", reason: "the observation was not created")
        }
        return ProjectMutation(value: first, receipt: batch.receipt)
    }

    public func recordObservations(
        _ drafts: [ObservationDraft],
        expectedRevision: Int
    ) throws -> ProjectMutation<[ObservationRecord]> {
        if drafts.isEmpty {
            let revision = try currentRevision()
            return ProjectMutation(
                value: [],
                receipt: MutationReceipt(
                    projectID: projectID,
                    previousRevision: revision,
                    revision: revision,
                    didChange: false
                )
            )
        }

        let now = Date()
        return try database.write { db in
            let state = try Self.loadProjectState(db)
            var validated: [ValidatedObservation] = []
            validated.reserveCapacity(drafts.count)
            for draft in drafts {
                validated.append(try validateObservation(db, draft: draft))
            }
            try requireRevision(db, expected: expectedRevision, actual: state.revision)

            var records: [ObservationRecord] = []
            records.reserveCapacity(validated.count)
            for item in validated {
                let observationID = ObservationID()
                let value = item.value
                try db.execute(
                    sql: """
                        INSERT INTO observation
                            (id, project_id, room_id, property_key, raw_value, origin, value_kind,
                             value_number, value_text, value_boolean, value_unit, source_version_id,
                             locator_json, note, created_at, supersedes_observation_id)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        observationID.databaseValue,
                        projectID.databaseValue,
                        item.roomID.databaseValue,
                        item.propertyKey,
                        item.rawValue,
                        item.origin.rawValue,
                        value?.kind.rawValue,
                        value?.number,
                        value?.text,
                        value?.boolean,
                        value?.unit,
                        item.sourceVersionID?.databaseValue,
                        item.locatorJSON,
                        item.note,
                        now,
                        item.supersedesObservationID?.databaseValue
                    ]
                )
                records.append(ObservationRecord(
                    id: observationID,
                    projectID: projectID,
                    roomID: item.roomID,
                    propertyKey: item.propertyKey,
                    rawValue: item.rawValue,
                    normalizedValue: value,
                    origin: item.origin,
                    sourceVersionID: item.sourceVersionID,
                    locator: item.locator,
                    note: item.note,
                    createdAt: now,
                    supersedesObservationID: item.supersedesObservationID,
                    adoptionState: .unverified
                ))
            }
            let revision = try bumpRevision(db, from: state.revision)
            return ProjectMutation(
                value: records,
                receipt: MutationReceipt(
                    projectID: projectID,
                    previousRevision: state.revision,
                    revision: revision,
                    didChange: true
                )
            )
        }
    }

    public func observation(_ id: ObservationID) throws -> ObservationRecord {
        try database.read { db in
            try observationRecord(db, id: id)
        }
    }

    public func observations(
        roomID: RoomID? = nil,
        propertyKey: String? = nil,
        limit: Int = 100,
        offset: Int = 0
    ) throws -> [ObservationRecord] {
        try validateListLimit(limit)
        try validateOffset(offset)
        let normalizedKey = try propertyKey.map { try normalizePropertyKey($0) }
        let roomValue = roomID?.databaseValue
        return try database.read { db in
            let arguments: StatementArguments = [
                projectID.databaseValue,
                roomValue,
                roomValue,
                normalizedKey,
                normalizedKey,
                limit,
                offset
            ]
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT o.*,
                        cur.id AS current_adoption_id,
                        last.id AS last_adoption_id,
                        last.superseded_by AS last_superseded_by
                    FROM observation o
                    LEFT JOIN adopted_value cur
                        ON cur.observation_id = o.id AND cur.superseded_by IS NULL
                    LEFT JOIN adopted_value last
                        ON last.id = (
                            SELECT av.id FROM adopted_value av
                            WHERE av.observation_id = o.id
                            ORDER BY av.adopted_at DESC, av.id DESC
                            LIMIT 1
                        )
                    WHERE o.project_id = ?
                        AND (? IS NULL OR o.room_id = ?)
                        AND (? IS NULL OR o.property_key = ?)
                    ORDER BY o.created_at DESC, o.id
                    LIMIT ? OFFSET ?
                    """,
                arguments: arguments
            )
            return try rows.map { try observationRecord(row: $0) }
        }
    }

    // MARK: - Adoption

    public func adoptObservation(
        _ id: ObservationID,
        expectedRevision: Int
    ) throws -> ProjectMutation<AdoptedValueRecord> {
        try database.write { db in
            let state = try Self.loadProjectState(db)
            let observation = try observationRecord(db, id: id)
            if case .adopted(let currentID) = observation.adoptionState {
                let current = try adoptedValueRecord(db, id: currentID)
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
            guard let value = observation.normalizedValue else {
                throw BuildingRecordsError.invalidValue(
                    field: "observation.normalizedValue",
                    reason: "an observation without a normalized value cannot be adopted"
                )
            }
            try requireRevision(db, expected: expectedRevision, actual: state.revision)
            let newID = AdoptedValueID()
            let now = Date()
            let current = try currentAdoptedValueRecord(
                db,
                roomID: observation.roomID,
                propertyKey: observation.propertyKey
            )
            if let current {
                try db.execute(
                    sql: """
                        UPDATE adopted_value
                        SET superseded_by = ?
                        WHERE id = ? AND superseded_by IS NULL
                        """,
                    arguments: [newID.databaseValue, current.id.databaseValue]
                )
                guard db.changesCount == 1 else {
                    throw BuildingRecordsError.invalidValue(
                        field: "adoptedValue",
                        reason: "the current adopted value changed during adoption"
                    )
                }
            }
            try db.execute(
                sql: """
                    INSERT INTO adopted_value
                        (id, project_id, room_id, property_key, value_kind, value_number,
                         value_text, value_boolean, value_unit, observation_id, adopted_at,
                         adopted_revision, superseded_by)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
                    """,
                arguments: [
                    newID.databaseValue,
                    projectID.databaseValue,
                    observation.roomID.databaseValue,
                    observation.propertyKey,
                    value.kind.rawValue,
                    value.number,
                    value.text,
                    value.boolean,
                    value.unit,
                    observation.id.databaseValue,
                    now,
                    state.revision + 1
                ]
            )
            let revision = try bumpRevision(db, from: state.revision)
            return ProjectMutation(
                value: AdoptedValueRecord(
                    id: newID,
                    projectID: projectID,
                    roomID: observation.roomID,
                    propertyKey: observation.propertyKey,
                    value: value,
                    observationID: observation.id,
                    adoptedAt: now,
                    adoptedRevision: revision,
                    supersededBy: nil
                ),
                receipt: MutationReceipt(
                    projectID: projectID,
                    previousRevision: state.revision,
                    revision: revision,
                    didChange: true
                )
            )
        }
    }

    public func adoptedValue(roomID: RoomID, propertyKey: String) throws -> AdoptedValueRecord? {
        let key = try normalizePropertyKey(propertyKey)
        return try database.read { db in
            try currentAdoptedValueRecord(db, roomID: roomID, propertyKey: key)
        }
    }

    public func adoptedValues(roomID: RoomID) throws -> [AdoptedValueRecord] {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM adopted_value
                    WHERE project_id = ? AND room_id = ? AND superseded_by IS NULL
                    ORDER BY property_key
                    """,
                arguments: [projectID.databaseValue, roomID.databaseValue]
            )
            return try rows.map { try adoptedValueRecord(row: $0) }
        }
    }

    public func adoptedValueHistory(roomID: RoomID, propertyKey: String) throws -> [AdoptedValueRecord] {
        let key = try normalizePropertyKey(propertyKey)
        return try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM adopted_value
                    WHERE project_id = ? AND room_id = ? AND property_key = ?
                    ORDER BY adopted_at DESC, id DESC
                    """,
                arguments: [projectID.databaseValue, roomID.databaseValue, key]
            )
            return try rows.map { try adoptedValueRecord(row: $0) }
        }
    }

    // MARK: - Observation helpers

    struct ValidatedObservation {
        let roomID: RoomID
        let propertyKey: String
        let rawValue: String
        let value: RecordedValue?
        let origin: ObservationOrigin
        let sourceVersionID: SourceVersionID?
        let locator: SourceLocator?
        let locatorJSON: String?
        let note: String
        let supersedesObservationID: ObservationID?
    }

    func validateObservation(_ db: Database, draft: ObservationDraft) throws -> ValidatedObservation {
        let key = try normalizePropertyKey(draft.propertyKey)
        guard !draft.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BuildingRecordsError.invalidValue(field: "observation.rawValue", reason: "must not be empty")
        }
        guard draft.rawValue.count <= limits.maxTextLength else {
            throw BuildingRecordsError.invalidValue(
                field: "observation.rawValue",
                reason: "must be at most \(limits.maxTextLength) characters"
            )
        }
        guard draft.note.count <= limits.maxTextLength else {
            throw BuildingRecordsError.invalidValue(
                field: "observation.note",
                reason: "must be at most \(limits.maxTextLength) characters"
            )
        }
        guard try Int.fetchOne(
            db,
            sql: "SELECT count(*) FROM room WHERE id = ? AND project_id = ?",
            arguments: [draft.roomID.databaseValue, projectID.databaseValue]
        ) == 1 else {
            throw BuildingRecordsError.roomNotFound(draft.roomID)
        }
        if let sourceVersionID = draft.sourceVersionID {
            guard try Int.fetchOne(
                db,
                sql: """
                    SELECT count(*) FROM source_version v
                    JOIN source s ON s.id = v.source_id
                    WHERE v.id = ? AND s.project_id = ?
                    """,
                arguments: [sourceVersionID.databaseValue, projectID.databaseValue]
            ) == 1 else {
                throw BuildingRecordsError.sourceVersionNotFound(sourceVersionID)
            }
        }
        if let locator = draft.locator {
            guard draft.sourceVersionID != nil else {
                throw BuildingRecordsError.invalidSourceLocator("a locator requires a source version")
            }
            try locator.validate()
        }
        if let supersedes = draft.supersedesObservationID {
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT room_id, property_key FROM observation
                    WHERE id = ? AND project_id = ?
                    """,
                arguments: [supersedes.databaseValue, projectID.databaseValue]
            ) else {
                throw BuildingRecordsError.observationNotFound(supersedes)
            }
            let roomID: RoomID = try row.recordID("room_id")
            let supersededKey: String = row["property_key"]
            guard roomID == draft.roomID, supersededKey == key else {
                throw BuildingRecordsError.invalidValue(
                    field: "observation.supersedesObservationID",
                    reason: "the superseded observation has a different room or property"
                )
            }
        }
        let locatorJSON = try draft.locator.map { try RecordsCodec.json($0) }
        return ValidatedObservation(
            roomID: draft.roomID,
            propertyKey: key,
            rawValue: draft.rawValue,
            value: draft.normalizedValue,
            origin: draft.origin,
            sourceVersionID: draft.sourceVersionID,
            locator: draft.locator,
            locatorJSON: locatorJSON,
            note: draft.note,
            supersedesObservationID: draft.supersedesObservationID
        )
    }

    func normalizePropertyKey(_ rawKey: String) throws -> String {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty, key.count <= 64 else {
            throw BuildingRecordsError.invalidValue(field: "observation.propertyKey", reason: "must be 1...64 characters")
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard key.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw BuildingRecordsError.invalidValue(
                field: "observation.propertyKey",
                reason: "use letters, numbers, dots, underscores or hyphens"
            )
        }
        return key
    }

    func observationRecord(_ db: Database, id: ObservationID) throws -> ObservationRecord {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT o.*,
                    cur.id AS current_adoption_id,
                    last.id AS last_adoption_id,
                    last.superseded_by AS last_superseded_by
                FROM observation o
                LEFT JOIN adopted_value cur
                    ON cur.observation_id = o.id AND cur.superseded_by IS NULL
                LEFT JOIN adopted_value last
                    ON last.id = (
                        SELECT av.id FROM adopted_value av
                        WHERE av.observation_id = o.id
                        ORDER BY av.adopted_at DESC, av.id DESC
                        LIMIT 1
                    )
                WHERE o.id = ? AND o.project_id = ?
                """,
            arguments: [id.databaseValue, projectID.databaseValue]
        ) else {
            throw BuildingRecordsError.observationNotFound(id)
        }
        return try observationRecord(row: row)
    }

    func observationRecord(row: Row) throws -> ObservationRecord {
        let id: ObservationID = try row.recordID("id")
        let projectID: ProjectID = try row.recordID("project_id")
        let roomID: RoomID = try row.recordID("room_id")
        let propertyKey: String = row["property_key"]
        let rawValue: String = row["raw_value"]
        let value = try recordedValue(row: row)
        let origin: ObservationOrigin = try row.requiredEnum("origin", as: ObservationOrigin.self)
        let sourceVersionID: SourceVersionID? = try row.optionalRecordID("source_version_id")
        let note: String = row["note"]
        let createdAt: Date = row["created_at"]
        let supersedes: ObservationID? = try row.optionalRecordID("supersedes_observation_id")
        let locatorJSON: String? = row["locator_json"]
        let locator: SourceLocator?
        if let locatorJSON {
            let decoded = try RecordsCodec.decode(SourceLocator.self, from: locatorJSON)
            try decoded.validate()
            locator = decoded
        } else {
            locator = nil
        }

        let currentID: AdoptedValueID? = try row.optionalRecordID("current_adoption_id")
        let lastID: AdoptedValueID? = try row.optionalRecordID("last_adoption_id")
        let lastSuperseded: AdoptedValueID? = try row.optionalRecordID("last_superseded_by")
        let state: ObservationAdoptionState
        if let currentID {
            state = .adopted(currentID)
        } else if lastID != nil, let lastSuperseded {
            state = .superseded(by: lastSuperseded)
        } else {
            state = .unverified
        }

        return ObservationRecord(
            id: id,
            projectID: projectID,
            roomID: roomID,
            propertyKey: propertyKey,
            rawValue: rawValue,
            normalizedValue: value,
            origin: origin,
            sourceVersionID: sourceVersionID,
            locator: locator,
            note: note,
            createdAt: createdAt,
            supersedesObservationID: supersedes,
            adoptionState: state
        )
    }

    func recordedValue(row: Row) throws -> RecordedValue? {
        guard let kind: String = row["value_kind"] else { return nil }
        switch kind {
        case "number":
            guard let number: Double = row["value_number"] else {
                throw BuildingRecordsError.invalidValue(field: "observation.value", reason: "missing number")
            }
            let unit: String? = row["value_unit"]
            return try RecordedValue(number: number, unit: unit)
        case "text":
            guard let text: String = row["value_text"] else {
                throw BuildingRecordsError.invalidValue(field: "observation.value", reason: "missing text")
            }
            return try RecordedValue(text: text)
        case "boolean":
            guard let boolean: Int = row["value_boolean"] else {
                throw BuildingRecordsError.invalidValue(field: "observation.value", reason: "missing boolean")
            }
            return RecordedValue(boolean: boolean != 0)
        default:
            throw BuildingRecordsError.invalidValue(field: "observation.value", reason: "unknown value kind \(kind)")
        }
    }

    func currentAdoptedValueRecord(
        _ db: Database,
        roomID: RoomID,
        propertyKey: String
    ) throws -> AdoptedValueRecord? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT * FROM adopted_value
                WHERE project_id = ? AND room_id = ? AND property_key = ?
                    AND superseded_by IS NULL
                LIMIT 1
                """,
            arguments: [projectID.databaseValue, roomID.databaseValue, propertyKey]
        ) else {
            return nil
        }
        return try adoptedValueRecord(row: row)
    }

    func adoptedValueRecord(_ db: Database, id: AdoptedValueID) throws -> AdoptedValueRecord {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM adopted_value WHERE id = ? AND project_id = ?",
            arguments: [id.databaseValue, projectID.databaseValue]
        ) else {
            throw BuildingRecordsError.adoptedValueNotFound(id)
        }
        return try adoptedValueRecord(row: row)
    }

    func adoptedValueRecord(row: Row) throws -> AdoptedValueRecord {
        let id: AdoptedValueID = try row.recordID("id")
        let projectID: ProjectID = try row.recordID("project_id")
        let roomID: RoomID = try row.recordID("room_id")
        let propertyKey: String = row["property_key"]
        guard let value = try recordedValue(row: row) else {
            throw BuildingRecordsError.invalidValue(field: "adoptedValue.value", reason: "missing normalized value")
        }
        let observationID: ObservationID = try row.recordID("observation_id")
        let adoptedAt: Date = row["adopted_at"]
        let adoptedRevision: Int = row["adopted_revision"]
        let supersededBy: AdoptedValueID? = try row.optionalRecordID("superseded_by")
        return AdoptedValueRecord(
            id: id,
            projectID: projectID,
            roomID: roomID,
            propertyKey: propertyKey,
            value: value,
            observationID: observationID,
            adoptedAt: adoptedAt,
            adoptedRevision: adoptedRevision,
            supersededBy: supersededBy
        )
    }
}
