import Foundation
import GRDB

extension ProjectRecordsStore {
    // MARK: - Targets

    public func createBOMTarget(
        name: String,
        expectedRevision: Int
    ) throws -> ProjectMutation<BOMTarget> {
        let trimmed = try validatedTargetName(name)
        return try database.write { db in
            let state = try Self.loadProjectState(db)
            if let existing = try bomTargetByName(db, name: trimmed) {
                return ProjectMutation(
                    value: existing,
                    receipt: MutationReceipt(
                        projectID: projectID,
                        previousRevision: state.revision,
                        revision: state.revision,
                        didChange: false
                    )
                )
            }
            try requireRevision(db, expected: expectedRevision, actual: state.revision)
            let id = BOMTargetID()
            let now = Date()
            try db.execute(
                sql: """
                    INSERT INTO bom_target (id, project_id, name, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [id.databaseValue, projectID.databaseValue, trimmed, now, now]
            )
            let revision = try bumpRevision(db, from: state.revision)
            return ProjectMutation(
                value: BOMTarget(
                    id: id,
                    projectID: projectID,
                    name: trimmed,
                    createdAt: now,
                    updatedAt: now
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

    public func bomTargets() throws -> [BOMTarget] {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM bom_target
                    WHERE project_id = ?
                    ORDER BY created_at, id
                    """,
                arguments: [projectID.databaseValue]
            )
            return try rows.map { try bomTargetRecord(row: $0) }
        }
    }

    public func bomTarget(_ id: BOMTargetID) throws -> BOMTarget {
        try database.read { db in
            try bomTargetRecord(db, id: id)
        }
    }

    // MARK: - Draft build and persistence

    public func previewBOMDraft(
        csv data: Data,
        sourceVersionID: SourceVersionID,
        targetID: BOMTargetID? = nil,
        options: BOMDraftOptions = BOMDraftOptions()
    ) throws -> BOMDraftContent {
        let table = try CSVTableReader.parse(data, options: options.csv)
        let extraction = try table.extractionTable()
        return try previewBOMDraft(
            table: extraction,
            delimiter: table.delimiter,
            sourceVersionID: sourceVersionID,
            targetID: targetID,
            options: options
        )
    }

    public func previewBOMDraft(
        table: BOMExtractionTable,
        sourceVersionID: SourceVersionID,
        targetID: BOMTargetID? = nil,
        options: BOMDraftOptions = BOMDraftOptions()
    ) throws -> BOMDraftContent {
        try previewBOMDraft(
            table: table,
            delimiter: nil,
            sourceVersionID: sourceVersionID,
            targetID: targetID,
            options: options
        )
    }

    private func previewBOMDraft(
        table: BOMExtractionTable,
        delimiter: CSVDelimiter?,
        sourceVersionID: SourceVersionID,
        targetID: BOMTargetID?,
        options: BOMDraftOptions
    ) throws -> BOMDraftContent {
        _ = try sourceVersion(sourceVersionID)
        if let targetID {
            _ = try bomTarget(targetID)
        }
        let rooms = try rooms()
        return try BOMDraftBuilder.build(
            table: table,
            projectID: projectID,
            sourceVersionID: sourceVersionID,
            targetID: targetID,
            rooms: rooms,
            options: options,
            delimiter: delimiter
        )
    }

    public func importBOMDraft(
        csv data: Data,
        sourceVersionID: SourceVersionID,
        targetID: BOMTargetID? = nil,
        options: BOMDraftOptions = BOMDraftOptions(),
        expectedRevision: Int
    ) throws -> ProjectMutation<BOMDraft> {
        let table = try CSVTableReader.parse(data, options: options.csv)
        let extraction = try table.extractionTable()
        return try importBOMDraft(
            table: extraction,
            delimiter: table.delimiter,
            sourceVersionID: sourceVersionID,
            targetID: targetID,
            options: options,
            expectedRevision: expectedRevision
        )
    }

    public func importBOMDraft(
        table: BOMExtractionTable,
        sourceVersionID: SourceVersionID,
        targetID: BOMTargetID? = nil,
        options: BOMDraftOptions = BOMDraftOptions(),
        expectedRevision: Int
    ) throws -> ProjectMutation<BOMDraft> {
        try importBOMDraft(
            table: table,
            delimiter: nil,
            sourceVersionID: sourceVersionID,
            targetID: targetID,
            options: options,
            expectedRevision: expectedRevision
        )
    }

    private func importBOMDraft(
        table: BOMExtractionTable,
        delimiter: CSVDelimiter?,
        sourceVersionID: SourceVersionID,
        targetID: BOMTargetID?,
        options: BOMDraftOptions,
        expectedRevision: Int
    ) throws -> ProjectMutation<BOMDraft> {
        _ = try sourceVersion(sourceVersionID)
        if let targetID {
            _ = try bomTarget(targetID)
        }
        let rooms = try rooms()
        let content = try BOMDraftBuilder.build(
            table: table,
            projectID: projectID,
            sourceVersionID: sourceVersionID,
            targetID: targetID,
            rooms: rooms,
            options: options,
            delimiter: delimiter
        )

        if let existing = try existingDraft(
            sourceVersionID: sourceVersionID,
            fingerprint: content.fingerprint
        ) {
            let revision = try currentRevision()
            return ProjectMutation(
                value: existing,
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
            if let existing = try existingDraft(
                db,
                sourceVersionID: sourceVersionID,
                fingerprint: content.fingerprint
            ) {
                return ProjectMutation(
                    value: existing,
                    receipt: MutationReceipt(
                        projectID: projectID,
                        previousRevision: state.revision,
                        revision: state.revision,
                        didChange: false
                    )
                )
            }
            _ = try sourceVersionRecord(db, id: sourceVersionID)
            if let targetID {
                _ = try bomTargetRecord(db, id: targetID)
            }
            try requireRevision(db, expected: expectedRevision, actual: state.revision)
            try persist(content: content, createdAt: now, db: db)
            let revision = try bumpRevision(db, from: state.revision)
            let draft = try bomDraftRecord(db, id: content.id)
            return ProjectMutation(
                value: draft,
                receipt: MutationReceipt(
                    projectID: projectID,
                    previousRevision: state.revision,
                    revision: revision,
                    didChange: true
                )
            )
        }
    }

    public func bomDraft(_ id: BOMDraftID) throws -> BOMDraft {
        try database.read { db in
            try bomDraftRecord(db, id: id)
        }
    }

    public func bomDraftSummaries(
        targetID: BOMTargetID? = nil,
        limit: Int = 50,
        offset: Int = 0
    ) throws -> [BOMDraftSummary] {
        try validateListLimit(limit)
        try validateOffset(offset)
        if let targetID {
            _ = try bomTarget(targetID)
        }
        let targetValue = targetID?.databaseValue
        return try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT d.*,
                        (SELECT count(*) FROM bom_draft_row r WHERE r.draft_id = d.id) AS row_count,
                        (SELECT count(*) FROM bom_issue i WHERE i.draft_id = d.id AND i.state = 'open') AS issue_count,
                        (SELECT count(*) FROM bom_draft_row r WHERE r.draft_id = d.id AND r.state = 'ready') AS ready_count,
                        (SELECT count(*) FROM bom_draft_row r WHERE r.draft_id = d.id AND r.state = 'needs_review') AS needs_review_count,
                        (SELECT count(*) FROM bom_draft_row r WHERE r.draft_id = d.id AND r.state = 'blocked') AS blocked_count
                    FROM bom_draft d
                    WHERE d.project_id = ? AND (? IS NULL OR d.target_id = ?)
                    ORDER BY d.created_at DESC, d.id
                    LIMIT ? OFFSET ?
                    """,
                arguments: [projectID.databaseValue, targetValue, targetValue, limit, offset]
            )
            return try rows.map { row in
                let id: BOMDraftID = try row.recordID("id")
                let projectID: ProjectID = try row.recordID("project_id")
                let sourceVersionID: SourceVersionID = try row.recordID("source_version_id")
                let targetID: BOMTargetID? = try row.optionalRecordID("target_id")
                let createdAt: Date = row["created_at"]
                let adapterIdentifier: String = row["adapter_identifier"]
                let rowCount: Int = row["row_count"]
                let issueCount: Int = row["issue_count"]
                let readyCount: Int = row["ready_count"]
                let needsReviewCount: Int = row["needs_review_count"]
                let blockedCount: Int = row["blocked_count"]
                return BOMDraftSummary(
                    id: id,
                    projectID: projectID,
                    sourceVersionID: sourceVersionID,
                    targetID: targetID,
                    createdAt: createdAt,
                    adapterIdentifier: adapterIdentifier,
                    rowCount: rowCount,
                    issueCount: issueCount,
                    readyCount: readyCount,
                    needsReviewCount: needsReviewCount,
                    blockedCount: blockedCount
                )
            }
        }
    }

    // MARK: - Apply

    public func applyBOMDraft(
        _ draftID: BOMDraftID,
        to targetID: BOMTargetID,
        selectedRowIDs: Set<BOMDraftRowID>? = nil,
        expectedRevision: Int
    ) throws -> ProjectMutation<BOMApplyReceipt> {
        let now = Date()
        return try database.write { db in
            let state = try Self.loadProjectState(db)
            let draft = try bomDraftRecord(db, id: draftID)
            _ = try bomTargetRecord(db, id: targetID)
            if let boundTarget = draft.targetID, boundTarget != targetID {
                throw BuildingRecordsError.draftTargetMismatch
            }

            let selected: [BOMDraftRow]
            if let selectedRowIDs {
                guard !selectedRowIDs.isEmpty else { throw BuildingRecordsError.emptySelection }
                let rowIDs = Set(draft.rows.map(\.id))
                for id in selectedRowIDs where !rowIDs.contains(id) {
                    throw BuildingRecordsError.unknownDraftRow(id)
                }
                selected = draft.rows.filter { selectedRowIDs.contains($0.id) }
            } else {
                selected = draft.rows
            }

            let roomStoreys = try loadRoomStoreys(db)
            var planned: [(row: BOMDraftRow, payload: BOMItemPayload)] = []
            var skipped: [BOMDraftRowID] = []
            for row in selected {
                if row.state == .blocked {
                    skipped.append(row.id)
                    continue
                }
                guard let role = row.role,
                      let quantity = row.quantity,
                      quantity > 0,
                      quantity.isFinite else {
                    skipped.append(row.id)
                    continue
                }
                let modelPresent = row.model != nil
                let matchState: BOMProductMatchState = modelPresent ? .sourceBackedCustom : .identityUnresolved
                let isCounted = row.isCountedCandidate
                    && row.quantityKind != nil
                    && modelPresent
                let storey = row.storey ?? row.matchedRoomID.flatMap { roomStoreys[$0] }
                let allocationKey = try sourceAllocationKey(
                    targetID: targetID,
                    allocationIdentity: row.allocationIdentity
                )
                let origin = BOMItemOrigin.source(
                    sourceVersionID: draft.sourceVersionID,
                    draftID: draft.id,
                    sourceRowKey: row.sourceRowKey
                )
                let payload = BOMItemPayload(
                    targetID: targetID,
                    role: role,
                    roomID: row.matchedRoomID,
                    storey: storey,
                    systemName: row.systemName,
                    brand: row.brand,
                    rawModel: row.model,
                    series: row.series,
                    orderCode: row.orderCode,
                    productName: row.productName,
                    quantity: quantity,
                    quantityKind: row.quantityKind,
                    rawQuantity: row.rawQuantity,
                    rawUnit: row.rawUnit,
                    channelsPerDevice: row.channelsPerDevice,
                    spareQuantity: row.spareQuantity,
                    matchState: matchState,
                    capabilityState: .unknown,
                    isCounted: isCounted,
                    notes: row.notes,
                    allocationKey: allocationKey,
                    origin: origin
                )
                planned.append((row, payload))
            }

            var inserts: [(BOMItemID, BOMItemPayload)] = []
            var updates: [(BOMItemID, BOMItemPayload)] = []
            var adoptedItemIDs: [BOMItemID] = []
            for entry in planned {
                let existing = try existingItemPayload(db, allocationKey: entry.payload.allocationKey)
                if let existing {
                    adoptedItemIDs.append(existing.id)
                    if existing.payload != entry.payload {
                        updates.append((existing.id, entry.payload))
                    }
                } else {
                    let id = BOMItemID()
                    inserts.append((id, entry.payload))
                    adoptedItemIDs.append(id)
                }
            }

            let pendingIssues = openIssues(
                draft.issues,
                selectedRowIDs: Set(selected.map(\.id))
            )
            let affectedRoomIDs = Set(planned.compactMap { $0.payload.roomID })
                .sorted { $0.description < $1.description }

            if inserts.isEmpty, updates.isEmpty {
                return ProjectMutation(
                    value: BOMApplyReceipt(
                        draftID: draft.id,
                        targetID: targetID,
                        adoptedItemIDs: adoptedItemIDs,
                        skippedRowIDs: skipped,
                        pendingIssues: pendingIssues,
                        affectedRoomIDs: affectedRoomIDs,
                        projectRevision: state.revision,
                        changed: false
                    ),
                    receipt: MutationReceipt(
                        projectID: projectID,
                        previousRevision: state.revision,
                        revision: state.revision,
                        didChange: false
                    )
                )
            }

            try requireRevision(db, expected: expectedRevision, actual: state.revision)
            let revision = state.revision + 1
            for (id, payload) in inserts {
                try insertBOMItem(
                    db,
                    id: id,
                    payload: payload,
                    appliedRevision: revision,
                    createdAt: now,
                    updatedAt: now
                )
            }
            for (id, payload) in updates {
                try updateBOMItem(
                    db,
                    id: id,
                    payload: payload,
                    appliedRevision: revision,
                    updatedAt: now
                )
            }
            let bumped = try bumpRevision(db, from: state.revision)
            return ProjectMutation(
                value: BOMApplyReceipt(
                    draftID: draft.id,
                    targetID: targetID,
                    adoptedItemIDs: adoptedItemIDs,
                    skippedRowIDs: skipped,
                    pendingIssues: pendingIssues,
                    affectedRoomIDs: affectedRoomIDs,
                    projectRevision: bumped,
                    changed: true
                ),
                receipt: MutationReceipt(
                    projectID: projectID,
                    previousRevision: state.revision,
                    revision: bumped,
                    didChange: true
                )
            )
        }
    }

    // MARK: - Items

    public func bomItems(
        targetID: BOMTargetID,
        role: BOMRole? = nil,
        roomID: RoomID? = nil,
        limit: Int = 200,
        offset: Int = 0
    ) throws -> [BOMItem] {
        try validateListLimit(limit)
        try validateOffset(offset)
        _ = try bomTarget(targetID)
        let roleRaw = role?.rawValue
        let roomValue = roomID?.databaseValue
        return try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT i.*, r.locator_json AS source_locator_json
                    FROM bom_item i
                    LEFT JOIN bom_draft_row r
                        ON r.draft_id = i.draft_id AND r.source_row_key = i.source_row_key
                    WHERE i.project_id = ? AND i.target_id = ?
                        AND (? IS NULL OR i.role = ?)
                        AND (? IS NULL OR i.room_id = ?)
                    ORDER BY i.role, i.room_id, i.raw_model, i.id
                    LIMIT ? OFFSET ?
                    """,
                arguments: [
                    projectID.databaseValue,
                    targetID.databaseValue,
                    roleRaw,
                    roleRaw,
                    roomValue,
                    roomValue,
                    limit,
                    offset
                ]
            )
            return try rows.map { try bomItemRecord(row: $0) }
        }
    }

    public func bomItem(_ id: BOMItemID) throws -> BOMItem {
        try database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT i.*, r.locator_json AS source_locator_json
                    FROM bom_item i
                    LEFT JOIN bom_draft_row r
                        ON r.draft_id = i.draft_id AND r.source_row_key = i.source_row_key
                    WHERE i.id = ? AND i.project_id = ?
                    """,
                arguments: [id.databaseValue, projectID.databaseValue]
            ) else {
                throw BuildingRecordsError.bomItemNotFound(id)
            }
            return try bomItemRecord(row: row)
        }
    }

    public func addManualBOMItem(
        _ draft: ManualBOMItemDraft,
        expectedRevision: Int
    ) throws -> ProjectMutation<BOMItem> {
        let target = try bomTarget(draft.targetID)
        guard draft.quantity.isFinite, draft.quantity > 0, draft.quantity <= 1e12 else {
            throw BuildingRecordsError.invalidValue(field: "bomItem.quantity", reason: "must be finite and greater than zero")
        }
        let spare = draft.spareQuantity
        if let spare, !spare.isFinite || spare < 0 || spare > 1e12 {
            throw BuildingRecordsError.invalidValue(field: "bomItem.spareQuantity", reason: "must be finite and non-negative")
        }
        if let channels = draft.channelsPerDevice, channels <= 0 || channels > 10_000 {
            throw BuildingRecordsError.invalidValue(field: "bomItem.channelsPerDevice", reason: "must be 1...10000")
        }
        let rawUnit = try manualText(draft.rawUnit, field: "bomItem.rawUnit", limit: 24)
        let brand = try manualText(draft.brand, field: "bomItem.brand", limit: 500)
        let model = try manualText(draft.model, field: "bomItem.model", limit: 500)
        let series = try manualText(draft.series, field: "bomItem.series", limit: 200)
        let orderCode = try manualText(draft.orderCode, field: "bomItem.orderCode", limit: 200)
        let productName = try manualText(draft.productName, field: "bomItem.productName", limit: 1_000)
        let systemName = try manualText(draft.systemName, field: "bomItem.systemName", limit: 200) ?? ""
        let notes = draft.notes
        guard notes.count <= limits.maxTextLength else {
            throw BuildingRecordsError.invalidValue(field: "bomItem.notes", reason: "must be at most \(limits.maxTextLength) characters")
        }
        var storey = try manualText(draft.storey, field: "bomItem.storey", limit: 80)
        if let roomID = draft.roomID {
            let room = try room(roomID)
            if storey == nil { storey = room.storey }
        }
        let matchState: BOMProductMatchState = model == nil ? .identityUnresolved : .manualCustom
        let isCounted = model != nil && draft.quantityKind != .other
        let itemID = BOMItemID()
        let allocationKey = "manual:\(itemID.databaseValue)"
        let payload = BOMItemPayload(
            targetID: target.id,
            role: draft.role,
            roomID: draft.roomID,
            storey: storey,
            systemName: systemName.isEmpty ? nil : systemName,
            brand: brand,
            rawModel: model,
            series: series,
            orderCode: orderCode,
            productName: productName,
            quantity: draft.quantity,
            quantityKind: draft.quantityKind,
            rawQuantity: String(draft.quantity),
            rawUnit: rawUnit,
            channelsPerDevice: draft.channelsPerDevice,
            spareQuantity: spare,
            matchState: matchState,
            capabilityState: .unknown,
            isCounted: isCounted,
            notes: notes,
            allocationKey: allocationKey,
            origin: .manual
        )
        let now = Date()
        return try database.write { db in
            let state = try Self.loadProjectState(db)
            _ = try bomTargetRecord(db, id: target.id)
            if let roomID = draft.roomID {
                _ = try roomRecord(db, id: roomID)
            }
            try requireRevision(db, expected: expectedRevision, actual: state.revision)
            try insertBOMItem(
                db,
                id: itemID,
                payload: payload,
                appliedRevision: state.revision + 1,
                createdAt: now,
                updatedAt: now
            )
            let revision = try bumpRevision(db, from: state.revision)
            let item = try bomItemRecord(db, id: itemID)
            return ProjectMutation(
                value: item,
                receipt: MutationReceipt(
                    projectID: projectID,
                    previousRevision: state.revision,
                    revision: revision,
                    didChange: true
                )
            )
        }
    }

    public func bomQuantitySummary(
        targetID: BOMTargetID,
        role: BOMRole? = nil
    ) throws -> BOMQuantitySummary {
        _ = try bomTarget(targetID)
        let roleRaw = role?.rawValue
        return try database.read { db in
            let groupRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT quantity_kind, SUM(quantity) AS total, COUNT(*) AS item_count
                    FROM bom_item
                    WHERE project_id = ? AND target_id = ? AND is_counted = 1
                        AND (? IS NULL OR role = ?)
                    GROUP BY quantity_kind
                    """,
                arguments: [projectID.databaseValue, targetID.databaseValue, roleRaw, roleRaw]
            )
            var totals: [BOMQuantityKind: Double] = [:]
            var counted = 0
            for row in groupRows {
                let kindRaw: String = row["quantity_kind"]
                guard let kind = BOMQuantityKind(rawValue: kindRaw) else { continue }
                let total: Double = row["total"]
                totals[kind] = total
                let itemCount: Int = row["item_count"]
                counted += itemCount
            }
            let uncounted = try Int.fetchOne(
                db,
                sql: """
                    SELECT count(*) FROM bom_item
                    WHERE project_id = ? AND target_id = ? AND is_counted = 0
                        AND (? IS NULL OR role = ?)
                    """,
                arguments: [projectID.databaseValue, targetID.databaseValue, roleRaw, roleRaw]
            ) ?? 0
            return BOMQuantitySummary(
                totalsByKind: totals,
                countedItemCount: counted,
                uncountedItemCount: uncounted
            )
        }
    }

    // MARK: - Source-version comparison

    public func compareBOMDrafts(
        previousDraftID: BOMDraftID,
        currentDraftID: BOMDraftID
    ) throws -> BOMDraftComparison {
        let previous = try bomDraft(previousDraftID)
        let current = try bomDraft(currentDraftID)
        var previousByKey: [String: BOMDraftRow] = [:]
        for row in previous.rows { previousByKey[row.comparisonKey] = row }
        var currentByKey: [String: BOMDraftRow] = [:]
        for row in current.rows { currentByKey[row.comparisonKey] = row }

        var added: [BOMDraftRowSummary] = []
        var changed: [BOMDraftChange] = []
        var absent: [BOMDraftRowSummary] = []
        var unchanged = 0

        for row in current.rows {
            if let old = previousByKey[row.comparisonKey] {
                let fields = changedFields(previous: old, current: row)
                if fields.isEmpty {
                    unchanged += 1
                } else {
                    changed.append(BOMDraftChange(
                        previous: draftRowSummary(old),
                        current: draftRowSummary(row),
                        fields: fields
                    ))
                }
            } else {
                added.append(draftRowSummary(row))
            }
        }
        for row in previous.rows where currentByKey[row.comparisonKey] == nil {
            absent.append(draftRowSummary(row))
        }

        return BOMDraftComparison(
            previousDraftID: previousDraftID,
            currentDraftID: currentDraftID,
            added: added,
            changed: changed,
            absent: absent,
            unchangedCount: unchanged
        )
    }

    // MARK: - Target helpers

    func validatedTargetName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= limits.maxTitleLength else {
            throw BuildingRecordsError.invalidValue(
                field: "bomTarget.name",
                reason: "must be 1...\(limits.maxTitleLength) characters"
            )
        }
        return trimmed
    }

    func bomTargetByName(_ db: Database, name: String) throws -> BOMTarget? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM bom_target WHERE project_id = ? AND name = ? LIMIT 1",
            arguments: [projectID.databaseValue, name]
        ) else {
            return nil
        }
        return try bomTargetRecord(row: row)
    }

    func bomTargetRecord(_ db: Database, id: BOMTargetID) throws -> BOMTarget {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM bom_target WHERE id = ? AND project_id = ?",
            arguments: [id.databaseValue, projectID.databaseValue]
        ) else {
            throw BuildingRecordsError.bomTargetNotFound(id)
        }
        return try bomTargetRecord(row: row)
    }

    func bomTargetRecord(row: Row) throws -> BOMTarget {
        let id: BOMTargetID = try row.recordID("id")
        let projectID: ProjectID = try row.recordID("project_id")
        let name: String = row["name"]
        let createdAt: Date = row["created_at"]
        let updatedAt: Date = row["updated_at"]
        return BOMTarget(
            id: id,
            projectID: projectID,
            name: name,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    // MARK: - Draft helpers

    func existingDraft(
        sourceVersionID: SourceVersionID,
        fingerprint: String
    ) throws -> BOMDraft? {
        try database.read { db in
            try existingDraft(db, sourceVersionID: sourceVersionID, fingerprint: fingerprint)
        }
    }

    func existingDraft(
        _ db: Database,
        sourceVersionID: SourceVersionID,
        fingerprint: String
    ) throws -> BOMDraft? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT id FROM bom_draft
                WHERE project_id = ? AND source_version_id = ? AND fingerprint = ?
                """,
            arguments: [projectID.databaseValue, sourceVersionID.databaseValue, fingerprint]
        ) else {
            return nil
        }
        let id: BOMDraftID = try row.recordID("id")
        return try bomDraftRecord(db, id: id)
    }

    func persist(content: BOMDraftContent, createdAt: Date, db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO bom_draft
                    (id, project_id, source_version_id, target_id, adapter_identifier,
                     fingerprint, mapping_json, delimiter, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                content.id.databaseValue,
                projectID.databaseValue,
                content.sourceVersionID.databaseValue,
                content.targetID?.databaseValue,
                content.adapterIdentifier,
                content.fingerprint,
                try RecordsCodec.json(content.mapping),
                content.delimiter?.rawValue,
                createdAt
            ]
        )
        for row in content.rows {
            try db.execute(
                sql: """
                    INSERT INTO bom_draft_row
                        (id, draft_id, row_index, line_number, source_row_key, raw_fields_json,
                         raw_record, locator_json, brand, model, order_code, product_name, series,
                         room_name, storey, system_name, raw_quantity, raw_unit, quantity,
                         quantity_kind, channels_per_device, spare_quantity, role, role_raw,
                         matched_room_id, notes, comparison_key, allocation_identity, state, countable)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    row.id.databaseValue,
                    content.id.databaseValue,
                    row.rowIndex,
                    row.lineNumber,
                    row.sourceRowKey,
                    try RecordsCodec.json(row.rawFields),
                    row.rawRecord,
                    try RecordsCodec.json(row.locator),
                    row.brand,
                    row.model,
                    row.orderCode,
                    row.productName,
                    row.series,
                    row.roomName,
                    row.storey,
                    row.systemName,
                    row.rawQuantity,
                    row.rawUnit,
                    row.quantity,
                    row.quantityKind?.rawValue,
                    row.channelsPerDevice,
                    row.spareQuantity,
                    row.role?.rawValue,
                    row.roleRaw,
                    row.matchedRoomID?.databaseValue,
                    row.notes,
                    row.comparisonKey,
                    row.allocationIdentity,
                    row.state.rawValue,
                    row.isCountedCandidate
                ]
            )
        }
        for issue in content.issues {
            try db.execute(
                sql: """
                    INSERT INTO bom_issue
                        (id, project_id, draft_id, row_id, row_index, kind, severity, field,
                         message, raw_value, state, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    issue.id.databaseValue,
                    projectID.databaseValue,
                    content.id.databaseValue,
                    issue.rowID?.databaseValue,
                    issue.rowIndex,
                    issue.kind.rawValue,
                    issue.severity.rawValue,
                    issue.field?.rawValue,
                    issue.message,
                    issue.rawValue,
                    issue.state.rawValue,
                    issue.createdAt
                ]
            )
        }
    }

    func bomDraftRecord(_ db: Database, id: BOMDraftID) throws -> BOMDraft {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM bom_draft WHERE id = ? AND project_id = ?",
            arguments: [id.databaseValue, projectID.databaseValue]
        ) else {
            throw BuildingRecordsError.bomDraftNotFound(id)
        }
        let rowRows = try Row.fetchAll(
            db,
            sql: "SELECT * FROM bom_draft_row WHERE draft_id = ? ORDER BY row_index",
            arguments: [id.databaseValue]
        )
        let issueRows = try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM bom_issue
                WHERE draft_id = ?
                ORDER BY CASE WHEN row_index IS NULL THEN 0 ELSE 1 END, row_index, created_at, id
                """,
            arguments: [id.databaseValue]
        )
        let draftID: BOMDraftID = try row.recordID("id")
        let projectID: ProjectID = try row.recordID("project_id")
        let sourceVersionID: SourceVersionID = try row.recordID("source_version_id")
        let targetID: BOMTargetID? = try row.optionalRecordID("target_id")
        let createdAt: Date = row["created_at"]
        let adapterIdentifier: String = row["adapter_identifier"]
        let delimiter: CSVDelimiter? = try row.optionalEnum("delimiter", as: CSVDelimiter.self)
        let fingerprint: String = row["fingerprint"]
        let mappingJSON: String = row["mapping_json"]
        let mapping = try RecordsCodec.decode(BOMColumnMapping.self, from: mappingJSON)
        return BOMDraft(
            id: draftID,
            projectID: projectID,
            sourceVersionID: sourceVersionID,
            targetID: targetID,
            createdAt: createdAt,
            adapterIdentifier: adapterIdentifier,
            delimiter: delimiter,
            fingerprint: fingerprint,
            mapping: mapping,
            rows: try rowRows.map { try bomDraftRowRecord(row: $0) },
            issues: try issueRows.map { try bomIssueRecord(row: $0) }
        )
    }

    func bomDraftRowRecord(row: Row) throws -> BOMDraftRow {
        let id: BOMDraftRowID = try row.recordID("id")
        let rowIndex: Int = row["row_index"]
        let lineNumber: Int = row["line_number"]
        let sourceRowKey: String = row["source_row_key"]
        let rawFieldsJSON: String = row["raw_fields_json"]
        let rawFields = try RecordsCodec.decode([String].self, from: rawFieldsJSON)
        let rawRecord: String = row["raw_record"]
        let locatorJSON: String = row["locator_json"]
        let locator = try RecordsCodec.decode(SourceLocator.self, from: locatorJSON)
        try locator.validate()
        let brand: String? = row["brand"]
        let model: String? = row["model"]
        let orderCode: String? = row["order_code"]
        let productName: String? = row["product_name"]
        let series: String? = row["series"]
        let roomName: String? = row["room_name"]
        let storey: String? = row["storey"]
        let systemName: String? = row["system_name"]
        let rawQuantity: String = row["raw_quantity"]
        let rawUnit: String? = row["raw_unit"]
        let quantity: Double? = row["quantity"]
        let quantityKind: BOMQuantityKind? = try row.optionalEnum("quantity_kind", as: BOMQuantityKind.self)
        let channelsPerDevice: Int? = row["channels_per_device"]
        let spareQuantity: Double? = row["spare_quantity"]
        let role: BOMRole? = try row.optionalEnum("role", as: BOMRole.self)
        let roleRaw: String? = row["role_raw"]
        let matchedRoomID: RoomID? = try row.optionalRecordID("matched_room_id")
        let notes: String = row["notes"]
        let comparisonKey: String = row["comparison_key"]
        let allocationIdentity: String = row["allocation_identity"]
        let state: BOMDraftRowState = try row.requiredEnum("state", as: BOMDraftRowState.self)
        let countable: Bool = try row.requiredBool("countable")
        return BOMDraftRow(
            id: id,
            rowIndex: rowIndex,
            lineNumber: lineNumber,
            sourceRowKey: sourceRowKey,
            rawFields: rawFields,
            rawRecord: rawRecord,
            locator: locator,
            brand: brand,
            model: model,
            orderCode: orderCode,
            productName: productName,
            series: series,
            roomName: roomName,
            storey: storey,
            systemName: systemName,
            rawQuantity: rawQuantity,
            rawUnit: rawUnit,
            quantity: quantity,
            quantityKind: quantityKind,
            channelsPerDevice: channelsPerDevice,
            spareQuantity: spareQuantity,
            role: role,
            roleRaw: roleRaw,
            matchedRoomID: matchedRoomID,
            notes: notes,
            comparisonKey: comparisonKey,
            allocationIdentity: allocationIdentity,
            state: state,
            isCountedCandidate: countable
        )
    }

    func bomIssueRecord(row: Row) throws -> BOMIssue {
        let id: BOMIssueID = try row.recordID("id")
        let projectID: ProjectID = try row.recordID("project_id")
        let draftID: BOMDraftID = try row.recordID("draft_id")
        let rowID: BOMDraftRowID? = try row.optionalRecordID("row_id")
        let rowIndex: Int? = row["row_index"]
        let kind: BOMIssueKind = try row.requiredEnum("kind", as: BOMIssueKind.self)
        let severity: BOMIssueSeverity = try row.requiredEnum("severity", as: BOMIssueSeverity.self)
        let field: BOMField? = try row.optionalEnum("field", as: BOMField.self)
        let message: String = row["message"]
        let rawValue: String? = row["raw_value"]
        let state: BOMIssueState = try row.requiredEnum("state", as: BOMIssueState.self)
        let createdAt: Date = row["created_at"]
        return BOMIssue(
            id: id,
            projectID: projectID,
            draftID: draftID,
            rowID: rowID,
            rowIndex: rowIndex,
            kind: kind,
            severity: severity,
            field: field,
            message: message,
            rawValue: rawValue,
            state: state,
            createdAt: createdAt
        )
    }

    // MARK: - Item helpers

    struct BOMItemPayload: Equatable {
        let targetID: BOMTargetID
        let role: BOMRole
        let roomID: RoomID?
        let storey: String?
        let systemName: String?
        let brand: String?
        let rawModel: String?
        let series: String?
        let orderCode: String?
        let productName: String?
        let quantity: Double
        let quantityKind: BOMQuantityKind?
        let rawQuantity: String
        let rawUnit: String?
        let channelsPerDevice: Int?
        let spareQuantity: Double?
        let matchState: BOMProductMatchState
        let capabilityState: BOMCapabilityState
        let isCounted: Bool
        let notes: String
        let allocationKey: String
        let origin: BOMItemOrigin
    }

    struct ExistingItemPayload {
        let id: BOMItemID
        let payload: BOMItemPayload
    }

    func sourceAllocationKey(
        targetID: BOMTargetID,
        allocationIdentity: String
    ) throws -> String {
        let digest = try RecordsCodec.fingerprint(BOMSourceAllocationKeyPayload(
            targetID: targetID,
            allocationIdentity: allocationIdentity
        ))
        return "source:\(digest)"
    }

    func existingItemPayload(_ db: Database, allocationKey: String) throws -> ExistingItemPayload? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT id, target_id, role, room_id, storey, system_name, brand, raw_model,
                    series, order_code, product_name, quantity, quantity_kind, raw_quantity,
                    raw_unit, channels_per_device, spare_quantity, match_state, capability_state,
                    is_counted, notes, allocation_key, origin_kind, source_version_id, draft_id,
                    source_row_key
                FROM bom_item
                WHERE project_id = ? AND allocation_key = ?
                """,
            arguments: [projectID.databaseValue, allocationKey]
        ) else {
            return nil
        }
        let id: BOMItemID = try row.recordID("id")
        let targetID: BOMTargetID = try row.recordID("target_id")
        let role: BOMRole = try row.requiredEnum("role", as: BOMRole.self)
        let roomID: RoomID? = try row.optionalRecordID("room_id")
        let storey: String? = row["storey"]
        let systemName: String? = row["system_name"]
        let brand: String? = row["brand"]
        let rawModel: String? = row["raw_model"]
        let series: String? = row["series"]
        let orderCode: String? = row["order_code"]
        let productName: String? = row["product_name"]
        let quantity: Double = row["quantity"]
        let quantityKind: BOMQuantityKind? = try row.optionalEnum("quantity_kind", as: BOMQuantityKind.self)
        let rawQuantity: String = row["raw_quantity"]
        let rawUnit: String? = row["raw_unit"]
        let channelsPerDevice: Int? = row["channels_per_device"]
        let spareQuantity: Double? = row["spare_quantity"]
        let matchState: BOMProductMatchState = try row.requiredEnum("match_state", as: BOMProductMatchState.self)
        let capabilityState: BOMCapabilityState = try row.requiredEnum("capability_state", as: BOMCapabilityState.self)
        let isCounted: Bool = try row.requiredBool("is_counted")
        let notes: String = row["notes"]
        let key: String = row["allocation_key"]
        let originKind: String = row["origin_kind"]
        let origin: BOMItemOrigin
        if originKind == "source" {
            let sourceVersionID: SourceVersionID = try row.recordID("source_version_id")
            let draftID: BOMDraftID = try row.recordID("draft_id")
            let rowKey: String = row["source_row_key"]
            origin = .source(sourceVersionID: sourceVersionID, draftID: draftID, sourceRowKey: rowKey)
        } else {
            origin = .manual
        }
        return ExistingItemPayload(
            id: id,
            payload: BOMItemPayload(
                targetID: targetID,
                role: role,
                roomID: roomID,
                storey: storey,
                systemName: systemName,
                brand: brand,
                rawModel: rawModel,
                series: series,
                orderCode: orderCode,
                productName: productName,
                quantity: quantity,
                quantityKind: quantityKind,
                rawQuantity: rawQuantity,
                rawUnit: rawUnit,
                channelsPerDevice: channelsPerDevice,
                spareQuantity: spareQuantity,
                matchState: matchState,
                capabilityState: capabilityState,
                isCounted: isCounted,
                notes: notes,
                allocationKey: key,
                origin: origin
            )
        )
    }

    func insertBOMItem(
        _ db: Database,
        id: BOMItemID,
        payload: BOMItemPayload,
        appliedRevision: Int,
        createdAt: Date,
        updatedAt: Date
    ) throws {
        let originKind: String
        let sourceVersionID: SourceVersionID?
        let draftID: BOMDraftID?
        let sourceRowKey: String?
        switch payload.origin {
        case .source(let version, let draft, let rowKey):
            originKind = "source"
            sourceVersionID = version
            draftID = draft
            sourceRowKey = rowKey
        case .manual:
            originKind = "manual"
            sourceVersionID = nil
            draftID = nil
            sourceRowKey = nil
        }
        try db.execute(
            sql: """
                INSERT INTO bom_item
                    (id, project_id, target_id, role, room_id, storey, system_name, brand,
                     raw_model, series, order_code, product_name, quantity, quantity_kind,
                     raw_quantity, raw_unit, channels_per_device, spare_quantity, origin_kind,
                     source_version_id, draft_id, source_row_key, allocation_key, match_state,
                     capability_state, is_counted, notes, applied_revision, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                id.databaseValue,
                projectID.databaseValue,
                payload.targetID.databaseValue,
                payload.role.rawValue,
                payload.roomID?.databaseValue,
                payload.storey,
                payload.systemName,
                payload.brand,
                payload.rawModel,
                payload.series,
                payload.orderCode,
                payload.productName,
                payload.quantity,
                payload.quantityKind?.rawValue,
                payload.rawQuantity,
                payload.rawUnit,
                payload.channelsPerDevice,
                payload.spareQuantity,
                originKind,
                sourceVersionID?.databaseValue,
                draftID?.databaseValue,
                sourceRowKey,
                payload.allocationKey,
                payload.matchState.rawValue,
                payload.capabilityState.rawValue,
                payload.isCounted,
                payload.notes,
                appliedRevision,
                createdAt,
                updatedAt
            ]
        )
    }

    func updateBOMItem(
        _ db: Database,
        id: BOMItemID,
        payload: BOMItemPayload,
        appliedRevision: Int,
        updatedAt: Date
    ) throws {
        try db.execute(
            sql: """
                UPDATE bom_item
                SET target_id = ?, role = ?, room_id = ?, storey = ?, system_name = ?, brand = ?,
                    raw_model = ?, series = ?, order_code = ?, product_name = ?, quantity = ?,
                    quantity_kind = ?, raw_quantity = ?, raw_unit = ?, channels_per_device = ?,
                    spare_quantity = ?, match_state = ?, capability_state = ?, is_counted = ?,
                    notes = ?, applied_revision = ?, updated_at = ?, origin_kind = ?,
                    source_version_id = ?, draft_id = ?, source_row_key = ?
                WHERE id = ? AND project_id = ?
                """,
            arguments: [
                payload.targetID.databaseValue,
                payload.role.rawValue,
                payload.roomID?.databaseValue,
                payload.storey,
                payload.systemName,
                payload.brand,
                payload.rawModel,
                payload.series,
                payload.orderCode,
                payload.productName,
                payload.quantity,
                payload.quantityKind?.rawValue,
                payload.rawQuantity,
                payload.rawUnit,
                payload.channelsPerDevice,
                payload.spareQuantity,
                payload.matchState.rawValue,
                payload.capabilityState.rawValue,
                payload.isCounted,
                payload.notes,
                appliedRevision,
                updatedAt,
                originKind(for: payload.origin),
                payload.origin.sourceVersionID?.databaseValue,
                payload.origin.draftID?.databaseValue,
                payload.origin.sourceRowKey,
                id.databaseValue,
                projectID.databaseValue
            ]
        )
        guard db.changesCount == 1 else {
            throw BuildingRecordsError.bomItemNotFound(id)
        }
    }

    func originKind(for origin: BOMItemOrigin) -> String {
        switch origin {
        case .source: return "source"
        case .manual: return "manual"
        }
    }

    func bomItemRecord(_ db: Database, id: BOMItemID) throws -> BOMItem {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT i.*, r.locator_json AS source_locator_json
                FROM bom_item i
                LEFT JOIN bom_draft_row r
                    ON r.draft_id = i.draft_id AND r.source_row_key = i.source_row_key
                WHERE i.id = ? AND i.project_id = ?
                """,
            arguments: [id.databaseValue, projectID.databaseValue]
        ) else {
            throw BuildingRecordsError.bomItemNotFound(id)
        }
        return try bomItemRecord(row: row)
    }

    func bomItemRecord(row: Row) throws -> BOMItem {
        let id: BOMItemID = try row.recordID("id")
        let projectID: ProjectID = try row.recordID("project_id")
        let targetID: BOMTargetID = try row.recordID("target_id")
        let role: BOMRole = try row.requiredEnum("role", as: BOMRole.self)
        let roomID: RoomID? = try row.optionalRecordID("room_id")
        let storey: String? = row["storey"]
        let systemName: String? = row["system_name"]
        let brand: String? = row["brand"]
        let rawModel: String? = row["raw_model"]
        let series: String? = row["series"]
        let orderCode: String? = row["order_code"]
        let productName: String? = row["product_name"]
        let quantity: Double = row["quantity"]
        let quantityKind: BOMQuantityKind? = try row.optionalEnum("quantity_kind", as: BOMQuantityKind.self)
        let rawQuantity: String = row["raw_quantity"]
        let rawUnit: String? = row["raw_unit"]
        let channelsPerDevice: Int? = row["channels_per_device"]
        let spareQuantity: Double? = row["spare_quantity"]
        let originKind: String = row["origin_kind"]
        let origin: BOMItemOrigin
        if originKind == "source" {
            let sourceVersionID: SourceVersionID = try row.recordID("source_version_id")
            let draftID: BOMDraftID = try row.recordID("draft_id")
            let rowKey: String = row["source_row_key"]
            origin = .source(sourceVersionID: sourceVersionID, draftID: draftID, sourceRowKey: rowKey)
        } else {
            origin = .manual
        }
        let matchState: BOMProductMatchState = try row.requiredEnum("match_state", as: BOMProductMatchState.self)
        let capabilityState: BOMCapabilityState = try row.requiredEnum("capability_state", as: BOMCapabilityState.self)
        let isCounted: Bool = try row.requiredBool("is_counted")
        let notes: String = row["notes"]
        let locatorJSON: String? = row["source_locator_json"]
        let sourceLocator: SourceLocator?
        if let locatorJSON {
            let decoded = try RecordsCodec.decode(SourceLocator.self, from: locatorJSON)
            try decoded.validate()
            sourceLocator = decoded
        } else {
            sourceLocator = nil
        }
        let createdAt: Date = row["created_at"]
        let updatedAt: Date = row["updated_at"]
        let appliedRevision: Int = row["applied_revision"]
        return BOMItem(
            id: id,
            projectID: projectID,
            targetID: targetID,
            role: role,
            roomID: roomID,
            storey: storey,
            systemName: systemName,
            brand: brand,
            rawModel: rawModel,
            series: series,
            orderCode: orderCode,
            productName: productName,
            quantity: quantity,
            quantityKind: quantityKind,
            rawQuantity: rawQuantity,
            rawUnit: rawUnit,
            channelsPerDevice: channelsPerDevice,
            spareQuantity: spareQuantity,
            origin: origin,
            matchState: matchState,
            capabilityState: capabilityState,
            isCounted: isCounted,
            notes: notes,
            sourceLocator: sourceLocator,
            createdAt: createdAt,
            updatedAt: updatedAt,
            appliedRevision: appliedRevision
        )
    }

    func loadRoomStoreys(_ db: Database) throws -> [RoomID: String] {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT id, storey FROM room WHERE project_id = ?",
            arguments: [projectID.databaseValue]
        )
        var result: [RoomID: String] = [:]
        for row in rows {
            let id: RoomID = try row.recordID("id")
            let storey: String? = row["storey"]
            if let storey { result[id] = storey }
        }
        return result
    }

    func openIssues(_ issues: [BOMIssue], selectedRowIDs: Set<BOMDraftRowID>) -> [BOMIssue] {
        issues.filter { issue in
            guard issue.state == .open else { return false }
            if let rowID = issue.rowID {
                return selectedRowIDs.contains(rowID)
            }
            return true
        }
    }

    func manualText(_ raw: String?, field: String, limit: Int) throws -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count <= limit else {
            throw BuildingRecordsError.invalidValue(field: field, reason: "must be at most \(limit) characters")
        }
        return trimmed
    }

    func draftRowSummary(_ row: BOMDraftRow) -> BOMDraftRowSummary {
        BOMDraftRowSummary(
            rowID: row.id,
            comparisonKey: row.comparisonKey,
            lineNumber: row.lineNumber,
            role: row.role,
            roomName: row.roomName,
            storey: row.storey,
            brand: row.brand,
            model: row.model,
            productName: row.productName,
            quantity: row.quantity,
            quantityKind: row.quantityKind,
            rawUnit: row.rawUnit,
            state: row.state
        )
    }

    func changedFields(previous: BOMDraftRow, current: BOMDraftRow) -> [BOMDraftChangeField] {
        var fields: [BOMDraftChangeField] = []
        if previous.brand != current.brand { fields.append(.brand) }
        if previous.model != current.model { fields.append(.model) }
        if previous.orderCode != current.orderCode { fields.append(.orderCode) }
        if previous.productName != current.productName { fields.append(.productName) }
        if previous.series != current.series { fields.append(.series) }
        if previous.quantity != current.quantity { fields.append(.quantity) }
        if previous.quantityKind != current.quantityKind { fields.append(.quantityKind) }
        if previous.rawUnit != current.rawUnit { fields.append(.rawUnit) }
        if previous.roomName != current.roomName { fields.append(.room) }
        if previous.storey != current.storey { fields.append(.storey) }
        if previous.role != current.role { fields.append(.role) }
        if previous.channelsPerDevice != current.channelsPerDevice { fields.append(.channelsPerDevice) }
        if previous.spareQuantity != current.spareQuantity { fields.append(.spareQuantity) }
        if previous.notes != current.notes { fields.append(.notes) }
        return fields
    }
}


private struct BOMSourceAllocationKeyPayload: Encodable {
    let targetID: BOMTargetID
    let allocationIdentity: String
}
