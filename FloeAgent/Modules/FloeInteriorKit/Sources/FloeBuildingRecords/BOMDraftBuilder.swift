import Foundation

/// Builds a reviewable BOM draft from a bounded extraction table. CSV parsing
/// is implemented by `CSVTableReader`; XLSX/PDF/OCR adapters can produce the
/// same `BOMExtractionTable` later without any database or path authority.
public enum BOMDraftBuilder {
    public static func build(
        csv data: Data,
        projectID: ProjectID,
        sourceVersionID: SourceVersionID,
        targetID: BOMTargetID?,
        rooms: [RoomRecord],
        options: BOMDraftOptions = BOMDraftOptions()
    ) throws -> BOMDraftContent {
        let table = try CSVTableReader.parse(data, options: options.csv)
        let extraction = try table.extractionTable()
        return try build(
            table: extraction,
            projectID: projectID,
            sourceVersionID: sourceVersionID,
            targetID: targetID,
            rooms: rooms,
            options: options,
            delimiter: table.delimiter
        )
    }

    public static func build(
        table: BOMExtractionTable,
        projectID: ProjectID,
        sourceVersionID: SourceVersionID,
        targetID: BOMTargetID?,
        rooms: [RoomRecord],
        options: BOMDraftOptions = BOMDraftOptions(),
        delimiter: CSVDelimiter? = nil
    ) throws -> BOMDraftContent {
        try options.csv.validate()
        let adapterIdentifier = table.adapterIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !adapterIdentifier.isEmpty, adapterIdentifier.count <= 80 else {
            throw BuildingRecordsError.invalidValue(field: "adapterIdentifier", reason: "must be 1...80 characters")
        }
        let headers = table.headers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !headers.isEmpty else {
            throw BuildingRecordsError.invalidValue(field: "headers", reason: "the extraction table has no headers")
        }
        guard headers.count <= options.csv.maxColumns else {
            throw CSVParseError.tooManyColumns(recordIndex: 0, limit: options.csv.maxColumns)
        }
        guard table.rows.count <= options.csv.maxRows else {
            throw CSVParseError.tooManyRows(limit: options.csv.maxRows)
        }

        let draftID = BOMDraftID()
        let now = Date()
        let mapping = try mapColumns(headers: headers, overrides: options.columnOverrides)
        var draftIssues: [BOMIssue] = []

        func makeIssue(
            rowID: BOMDraftRowID?,
            rowIndex: Int?,
            kind: BOMIssueKind,
            severity: BOMIssueSeverity,
            field: BOMField?,
            message: String,
            rawValue: String?
        ) -> BOMIssue {
            BOMIssue(
                id: BOMIssueID(),
                projectID: projectID,
                draftID: draftID,
                rowID: rowID,
                rowIndex: rowIndex,
                kind: kind,
                severity: severity,
                field: field,
                message: message,
                rawValue: rawValue,
                state: .open,
                createdAt: now
            )
        }

        for field in mapping.duplicateFields.sorted(by: { $0.rawValue < $1.rawValue }) {
            draftIssues.append(makeIssue(
                rowID: nil,
                rowIndex: nil,
                kind: .duplicateColumn,
                severity: .warning,
                field: field,
                message: "More than one header maps to \(field.rawValue); the first column is used.",
                rawValue: nil
            ))
        }
        if mapping.mapping.column(for: .quantity) == nil {
            draftIssues.append(makeIssue(
                rowID: nil,
                rowIndex: nil,
                kind: .missingRequiredColumn,
                severity: .warning,
                field: .quantity,
                message: "No quantity column was recognized.",
                rawValue: nil
            ))
        }
        if mapping.mapping.column(for: .unit) == nil {
            draftIssues.append(makeIssue(
                rowID: nil,
                rowIndex: nil,
                kind: .missingRequiredColumn,
                severity: .warning,
                field: .unit,
                message: "No unit column was recognized; a unit embedded in the quantity text is still used when it is known.",
                rawValue: nil
            ))
        }
        if mapping.mapping.column(for: .model) == nil && mapping.mapping.column(for: .productName) == nil {
            draftIssues.append(makeIssue(
                rowID: nil,
                rowIndex: nil,
                kind: .missingProductIdentity,
                severity: .warning,
                field: .model,
                message: "No model or product-name column was recognized.",
                rawValue: nil
            ))
        }

        var seeds: [BOMRowSeed] = []
        seeds.reserveCapacity(table.rows.count)
        var usedSourceKeys: [String: Int] = [:]

        for (rowOffset, extractionRow) in table.rows.enumerated() {
            if extractionRow.values.count > options.csv.maxColumns {
                throw CSVParseError.tooManyColumns(recordIndex: rowOffset, limit: options.csv.maxColumns)
            }
            for (column, value) in extractionRow.values.enumerated() where value.count > options.csv.maxFieldCharacters {
                throw CSVParseError.fieldTooLong(
                    recordIndex: rowOffset,
                    column: column,
                    limit: options.csv.maxFieldCharacters
                )
            }
            if extractionRow.rawRecord.count > options.csv.maxRecordCharacters {
                throw CSVParseError.recordTooLong(
                    recordIndex: rowOffset,
                    limit: options.csv.maxRecordCharacters
                )
            }

            let lineNumber = max(1, extractionRow.lineNumber)
            var sourceRowKey = extractionRow.sourceRowKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if sourceRowKey.isEmpty {
                sourceRowKey = "row:\(lineNumber)"
            }
            guard sourceRowKey.count <= 200 else {
                throw BuildingRecordsError.invalidValue(field: "sourceRowKey", reason: "must be at most 200 characters")
            }
            let occurrence = (usedSourceKeys[sourceRowKey] ?? 0) + 1
            usedSourceKeys[sourceRowKey] = occurrence
            if occurrence > 1 {
                sourceRowKey = "\(sourceRowKey)#\(occurrence)"
                if sourceRowKey.count > 200 {
                    sourceRowKey = "row:\(lineNumber)#\(occurrence)"
                }
            }

            var seed = BOMRowSeed(
                id: BOMDraftRowID(),
                rowIndex: rowOffset,
                lineNumber: lineNumber,
                sourceRowKey: sourceRowKey,
                rawFields: extractionRow.values,
                rawRecord: extractionRow.rawRecord,
                locator: extractionRow.locator
            )

            func cell(_ field: BOMField) -> String? {
                guard let column = mapping.mapping.column(for: field),
                      column < extractionRow.values.count else { return nil }
                let value = extractionRow.values[column].trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }

            let rowID = seed.id
            let rowIndex = seed.rowIndex
            var lengthIssues: [BOMIssue] = []
            func bounded(_ value: String?, limit: Int, field: BOMField, identityCritical: Bool) -> String? {
                guard let value else { return nil }
                guard value.count > limit else { return value }
                lengthIssues.append(makeIssue(
                    rowID: rowID,
                    rowIndex: rowIndex,
                    kind: .valueTooLong,
                    severity: .warning,
                    field: field,
                    message: "The \(field.rawValue) value exceeds \(limit) characters; the raw row is retained.",
                    rawValue: String(value.prefix(80))
                ))
                return identityCritical ? nil : String(value.prefix(limit))
            }

            do {
                try extractionRow.locator.validate()
            } catch {
                // A malformed adapter locator must not make the persisted draft
                // unreadable. The row is blocked and the original raw row still
                // carries the evidence; the fallback locator is explicit.
                seed.locator = .text(span: nil)
                seed.issues.append(makeIssue(
                    rowID: seed.id,
                    rowIndex: seed.rowIndex,
                    kind: .invalidSourceLocator,
                    severity: .blocking,
                    field: nil,
                    message: "The source locator is invalid; the row is blocked and uses a text fallback locator.",
                    rawValue: nil
                ))
            }
            if occurrence > 1 {
                seed.issues.append(makeIssue(
                    rowID: seed.id,
                    rowIndex: seed.rowIndex,
                    kind: .duplicateRowKey,
                    severity: .warning,
                    field: nil,
                    message: "A duplicate source row key was made unique.",
                    rawValue: extractionRow.sourceRowKey
                ))
            }
            if extractionRow.values.count != headers.count {
                seed.issues.append(makeIssue(
                    rowID: seed.id,
                    rowIndex: seed.rowIndex,
                    kind: .columnCountMismatch,
                    severity: .warning,
                    field: nil,
                    message: "The row has \(extractionRow.values.count) fields but the table has \(headers.count) headers.",
                    rawValue: nil
                ))
            }

            seed.brand = bounded(cell(.brand), limit: 500, field: .brand, identityCritical: false)
            seed.model = bounded(cell(.model), limit: 500, field: .model, identityCritical: true)
            seed.orderCode = bounded(cell(.orderCode), limit: 200, field: .orderCode, identityCritical: true)
            seed.productName = bounded(cell(.productName), limit: 1_000, field: .productName, identityCritical: false)
            seed.series = bounded(cell(.series), limit: 200, field: .series, identityCritical: false)
            seed.roomName = bounded(cell(.room), limit: 200, field: .room, identityCritical: true)
            seed.storey = bounded(cell(.storey), limit: 80, field: .storey, identityCritical: true)
            seed.systemName = bounded(cell(.system), limit: 200, field: .system, identityCritical: false)
            seed.notes = bounded(cell(.notes), limit: 20_000, field: .notes, identityCritical: false) ?? ""
            seed.issues.append(contentsOf: lengthIssues)

            let roleRaw = cell(.role)
            seed.roleRaw = roleRaw
            if let roleRaw {
                seed.role = BOMColumnAliases.role(for: roleRaw)
                if seed.role == nil {
                    seed.issues.append(makeIssue(
                        rowID: seed.id,
                        rowIndex: seed.rowIndex,
                        kind: .unknownRole,
                        severity: .blocking,
                        field: .role,
                        message: "The role value is not a recognized design, quotation, procurement, delivery, installation, spare or kit role.",
                        rawValue: roleRaw
                    ))
                }
            } else {
                seed.role = options.defaultRole
            }

            let rawQuantity = cell(.quantity) ?? ""
            seed.rawQuantity = rawQuantity
            var unitFromQuantity: String?
            if rawQuantity.isEmpty {
                seed.issues.append(makeIssue(
                    rowID: seed.id,
                    rowIndex: seed.rowIndex,
                    kind: .missingQuantity,
                    severity: .blocking,
                    field: .quantity,
                    message: "No quantity is present.",
                    rawValue: nil
                ))
            } else if let parsed = BOMColumnAliases.parseQuantityAndSuffix(rawQuantity) {
                unitFromQuantity = parsed.suffix
                if !parsed.value.isFinite || abs(parsed.value) > 1e12 {
                    seed.issues.append(makeIssue(
                        rowID: seed.id,
                        rowIndex: seed.rowIndex,
                        kind: .invalidQuantity,
                        severity: .blocking,
                        field: .quantity,
                        message: "The quantity is outside the supported numeric range.",
                        rawValue: rawQuantity
                    ))
                } else {
                    seed.quantity = parsed.value
                    if parsed.value < 0 {
                        seed.issues.append(makeIssue(
                            rowID: seed.id,
                            rowIndex: seed.rowIndex,
                            kind: .negativeQuantity,
                            severity: .blocking,
                            field: .quantity,
                            message: "A negative source adjustment is retained but is not an accepted device count.",
                            rawValue: rawQuantity
                        ))
                    } else if parsed.value == 0 {
                        seed.issues.append(makeIssue(
                            rowID: seed.id,
                            rowIndex: seed.rowIndex,
                            kind: .zeroQuantity,
                            severity: .blocking,
                            field: .quantity,
                            message: "A zero quantity is retained but does not create a counted allocation.",
                            rawValue: rawQuantity
                        ))
                    }
                }
            } else {
                seed.issues.append(makeIssue(
                    rowID: seed.id,
                    rowIndex: seed.rowIndex,
                    kind: .invalidQuantity,
                    severity: .blocking,
                    field: .quantity,
                    message: "The quantity text is not a supported number.",
                    rawValue: rawQuantity
                ))
            }

            let unitColumn = cell(.unit)
            if let unitColumn, let unitFromQuantity,
               BOMColumnAliases.normalizeToken(unitColumn) != BOMColumnAliases.normalizeToken(unitFromQuantity) {
                seed.issues.append(makeIssue(
                    rowID: seed.id,
                    rowIndex: seed.rowIndex,
                    kind: .conflictingUnit,
                    severity: .warning,
                    field: .unit,
                    message: "The unit column conflicts with the unit embedded in the quantity; the unit column is used.",
                    rawValue: "\(unitColumn) / \(unitFromQuantity)"
                ))
            }
            let effectiveUnit = unitColumn ?? unitFromQuantity
            seed.rawUnit = effectiveUnit
            if let effectiveUnit {
                seed.quantityKind = BOMColumnAliases.quantityKind(for: effectiveUnit)
                if seed.quantityKind == nil {
                    seed.issues.append(makeIssue(
                        rowID: seed.id,
                        rowIndex: seed.rowIndex,
                        kind: .unknownUnit,
                        severity: .warning,
                        field: .unit,
                        message: "The unit is not recognized; the quantity is retained but not counted.",
                        rawValue: effectiveUnit
                    ))
                }
            } else {
                seed.issues.append(makeIssue(
                    rowID: seed.id,
                    rowIndex: seed.rowIndex,
                    kind: .missingUnit,
                    severity: .warning,
                    field: .unit,
                    message: "No unit is available; the quantity is retained but not counted.",
                    rawValue: nil
                ))
            }

            if let rawChannels = cell(.channelsPerDevice) {
                if let channels = BOMColumnAliases.parseChannels(rawChannels), channels > 0, channels <= 10_000 {
                    seed.channelsPerDevice = channels
                } else {
                    seed.issues.append(makeIssue(
                        rowID: seed.id,
                        rowIndex: seed.rowIndex,
                        kind: .invalidChannels,
                        severity: .warning,
                        field: .channelsPerDevice,
                        message: "The channel count is not a positive integer; it remains an unresolved field.",
                        rawValue: rawChannels
                    ))
                }
            }

            if let rawSpare = cell(.spareQuantity) {
                if let value = BOMColumnAliases.parseQuantityAndSuffix(rawSpare)?.value,
                   value.isFinite, abs(value) <= 1e12 {
                    if value < 0 {
                        seed.issues.append(makeIssue(
                            rowID: seed.id,
                            rowIndex: seed.rowIndex,
                            kind: .negativeSpareQuantity,
                            severity: .warning,
                            field: .spareQuantity,
                            message: "A negative spare quantity is retained as an issue, not as stock.",
                            rawValue: rawSpare
                        ))
                    } else {
                        seed.spareQuantity = value
                    }
                } else {
                    seed.issues.append(makeIssue(
                        rowID: seed.id,
                        rowIndex: seed.rowIndex,
                        kind: .invalidSpareQuantity,
                        severity: .warning,
                        field: .spareQuantity,
                        message: "The spare quantity is not a supported number.",
                        rawValue: rawSpare
                    ))
                }
            }

            if seed.model == nil {
                seed.issues.append(makeIssue(
                    rowID: seed.id,
                    rowIndex: seed.rowIndex,
                    kind: .missingModel,
                    severity: .warning,
                    field: .model,
                    message: "No model is present; the line remains source-backed and cannot be counted as a resolved device.",
                    rawValue: cell(.model)
                ))
            }

            if let roomName = seed.roomName {
                let normalizedName = BOMColumnAliases.normalizedRoomName(roomName)
                var candidates = rooms.filter { room in
                    if BOMColumnAliases.normalizedRoomName(room.name) == normalizedName { return true }
                    return room.aliases.contains {
                        BOMColumnAliases.normalizedRoomName($0) == normalizedName
                    }
                }
                if let storey = seed.storey, !storey.isEmpty {
                    let normalizedStorey = BOMColumnAliases.normalizedRoomName(storey)
                    candidates = candidates.filter { room in
                        BOMColumnAliases.normalizedRoomName(room.storey ?? "") == normalizedStorey
                    }
                }
                if candidates.count == 1 {
                    seed.matchedRoomID = candidates[0].id
                } else if candidates.isEmpty {
                    seed.issues.append(makeIssue(
                        rowID: seed.id,
                        rowIndex: seed.rowIndex,
                        kind: .unresolvedRoom,
                        severity: .warning,
                        field: .room,
                        message: "The room name does not match exactly one project room; the line stays unplaced.",
                        rawValue: roomName
                    ))
                } else {
                    seed.issues.append(makeIssue(
                        rowID: seed.id,
                        rowIndex: seed.rowIndex,
                        kind: .ambiguousRoom,
                        severity: .warning,
                        field: .room,
                        message: "The room name matches \(candidates.count) rooms; the line stays unplaced instead of choosing the first.",
                        rawValue: roomName
                    ))
                }
            }

            seed.isCountedCandidate = (seed.quantity ?? 0) > 0
                && seed.quantityKind != nil
                && seed.role != nil
                && seed.model != nil
            seed.baseComparisonKey = [
                seed.role?.rawValue ?? "unknown-role",
                BOMColumnAliases.keyComponent(seed.roomName),
                BOMColumnAliases.keyComponent(seed.storey),
                BOMColumnAliases.keyComponent(seed.brand),
                BOMColumnAliases.keyComponent(seed.model),
                BOMColumnAliases.keyComponent(seed.orderCode),
                BOMColumnAliases.keyComponent(seed.productName),
                BOMColumnAliases.keyComponent(seed.series)
            ].joined(separator: "|")
            seeds.append(seed)
        }

        var keyCounts: [String: Int] = [:]
        for index in seeds.indices {
            let base = seeds[index].baseComparisonKey
            let count = (keyCounts[base] ?? 0) + 1
            keyCounts[base] = count
            seeds[index].comparisonKey = count == 1 ? base : "\(base)#\(count)"
        }

        var allocationCounts: [String: Int] = [:]
        for index in seeds.indices {
            let roomIdentity: String
            if let roomID = seeds[index].matchedRoomID {
                roomIdentity = "room:\(roomID.databaseValue)"
            } else {
                roomIdentity = "room-name:\(BOMColumnAliases.keyComponent(seeds[index].roomName))"
                    + "|\(BOMColumnAliases.keyComponent(seeds[index].storey))"
            }
            let stableProduct = seeds[index].model
                ?? seeds[index].orderCode
                ?? seeds[index].productName
            let productIdentity = [
                seeds[index].role?.rawValue ?? "unknown-role",
                BOMColumnAliases.keyComponent(seeds[index].brand),
                BOMColumnAliases.keyComponent(stableProduct)
            ].joined(separator: "|")
            let base = "\(roomIdentity)|\(productIdentity)"
            let count = (allocationCounts[base] ?? 0) + 1
            allocationCounts[base] = count
            seeds[index].allocationIdentity = "\(base)#\(count)"
        }

        var rows: [BOMDraftRow] = []
        rows.reserveCapacity(seeds.count)
        for seed in seeds {
            let state: BOMDraftRowState
            if seed.issues.contains(where: { $0.severity == .blocking }) {
                state = .blocked
            } else if seed.issues.contains(where: { $0.severity == .warning }) {
                state = .needsReview
            } else {
                state = .ready
            }
            rows.append(BOMDraftRow(
                id: seed.id,
                rowIndex: seed.rowIndex,
                lineNumber: seed.lineNumber,
                sourceRowKey: seed.sourceRowKey,
                rawFields: seed.rawFields,
                rawRecord: seed.rawRecord,
                locator: seed.locator,
                brand: seed.brand,
                model: seed.model,
                orderCode: seed.orderCode,
                productName: seed.productName,
                series: seed.series,
                roomName: seed.roomName,
                storey: seed.storey,
                systemName: seed.systemName,
                rawQuantity: seed.rawQuantity,
                rawUnit: seed.rawUnit,
                quantity: seed.quantity,
                quantityKind: seed.quantityKind,
                channelsPerDevice: seed.channelsPerDevice,
                spareQuantity: seed.spareQuantity,
                role: seed.role,
                roleRaw: seed.roleRaw,
                matchedRoomID: seed.matchedRoomID,
                notes: seed.notes,
                comparisonKey: seed.comparisonKey,
                allocationIdentity: seed.allocationIdentity,
                state: state,
                isCountedCandidate: seed.isCountedCandidate
            ))
            draftIssues.append(contentsOf: seed.issues)
        }

        let fingerprintPayload = BOMDraftFingerprint(
            sourceVersionID: sourceVersionID,
            targetID: targetID,
            adapterIdentifier: adapterIdentifier,
            defaultRole: options.defaultRole,
            headers: headers,
            mapping: mapping.mapping,
            rows: table.rows.map { row in
                BOMFingerprintRow(
                    sourceRowKey: row.sourceRowKey,
                    values: row.values,
                    lineNumber: row.lineNumber,
                    locator: row.locator
                )
            }
        )
        let fingerprint = try RecordsCodec.fingerprint(fingerprintPayload)

        return BOMDraftContent(
            id: draftID,
            projectID: projectID,
            sourceVersionID: sourceVersionID,
            targetID: targetID,
            adapterIdentifier: adapterIdentifier,
            delimiter: delimiter,
            fingerprint: fingerprint,
            mapping: mapping.mapping,
            rows: rows,
            issues: draftIssues
        )
    }

    private struct HeaderMapping {
        let mapping: BOMColumnMapping
        let duplicateFields: [BOMField]
    }

    private static func mapColumns(
        headers: [String],
        overrides: [BOMField: Int]
    ) throws -> HeaderMapping {
        var columns: [BOMField: Int] = [:]
        var overrideFields: Set<BOMField> = []
        var duplicateFields: Set<BOMField> = []

        for (index, header) in headers.enumerated() {
            let token = BOMColumnAliases.normalizeToken(header)
            guard !token.isEmpty,
                  let field = BOMColumnAliases.field(forNormalizedHeader: token) else {
                continue
            }
            if columns[field] != nil {
                duplicateFields.insert(field)
            } else {
                columns[field] = index
            }
        }

        for (field, index) in overrides {
            guard index >= 0, index < headers.count else {
                throw BuildingRecordsError.invalidValue(
                    field: "columnOverrides.\(field.rawValue)",
                    reason: "column index is outside the header row"
                )
            }
            if let previous = columns[field], previous != index {
                duplicateFields.insert(field)
            }
            columns[field] = index
            overrideFields.insert(field)
        }

        var byIndex: [Int: [BOMField]] = [:]
        for (field, index) in columns {
            byIndex[index, default: []].append(field)
        }
        for fields in byIndex.values where fields.count > 1 {
            let ordered = fields.sorted { $0.rawValue < $1.rawValue }
            let keep = ordered.first(where: { overrideFields.contains($0) }) ?? ordered[0]
            for field in ordered where field != keep {
                columns.removeValue(forKey: field)
                duplicateFields.insert(field)
            }
        }

        let mappedIndexes = Set(columns.values)
        let unmapped = headers.indices.filter { !mappedIndexes.contains($0) }
        let duplicateList = duplicateFields.sorted { $0.rawValue < $1.rawValue }
        return HeaderMapping(
            mapping: BOMColumnMapping(
                headers: headers,
                columns: columns,
                unmappedHeaderIndexes: unmapped
            ),
            duplicateFields: duplicateList
        )
    }
}

private struct BOMRowSeed {
    let id: BOMDraftRowID
    let rowIndex: Int
    let lineNumber: Int
    let sourceRowKey: String
    let rawFields: [String]
    let rawRecord: String
    var locator: SourceLocator
    var brand: String?
    var model: String?
    var orderCode: String?
    var productName: String?
    var series: String?
    var roomName: String?
    var storey: String?
    var systemName: String?
    var rawQuantity: String = ""
    var rawUnit: String?
    var quantity: Double?
    var quantityKind: BOMQuantityKind?
    var channelsPerDevice: Int?
    var spareQuantity: Double?
    var role: BOMRole?
    var roleRaw: String?
    var matchedRoomID: RoomID?
    var notes: String = ""
    var issues: [BOMIssue] = []
    var baseComparisonKey: String = ""
    var comparisonKey: String = ""
    var allocationIdentity: String = ""
    var isCountedCandidate: Bool = false
}

private struct BOMFingerprintRow: Encodable {
    let sourceRowKey: String
    let values: [String]
    let lineNumber: Int
    let locator: SourceLocator
}

private struct BOMDraftFingerprint: Encodable {
    let sourceVersionID: SourceVersionID
    let targetID: BOMTargetID?
    let adapterIdentifier: String
    let defaultRole: BOMRole
    let headers: [String]
    let mapping: BOMColumnMapping
    let rows: [BOMFingerprintRow]
}
