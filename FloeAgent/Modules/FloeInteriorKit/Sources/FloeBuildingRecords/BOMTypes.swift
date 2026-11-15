import Foundation

public enum BOMField: String, Codable, Sendable, Hashable, CaseIterable {
    case brand
    case model
    case orderCode = "order_code"
    case productName = "product_name"
    case series
    case quantity
    case unit
    case room
    case storey
    case system
    case role
    case channelsPerDevice = "channels_per_device"
    case spareQuantity = "spare_quantity"
    case notes
}

public struct BOMColumnMapping: Codable, Sendable, Hashable {
    private enum CodingKeys: String, CodingKey {
        case headers
        case columns
        case unmappedHeaderIndexes = "unmapped_header_indexes"
    }

    public let headers: [String]
    public let columns: [BOMField: Int]
    public let unmappedHeaderIndexes: [Int]

    public init(headers: [String], columns: [BOMField: Int], unmappedHeaderIndexes: [Int]) {
        self.headers = headers
        self.columns = columns
        self.unmappedHeaderIndexes = unmappedHeaderIndexes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        headers = try container.decode([String].self, forKey: .headers)
        let rawColumns = try container.decode([String: Int].self, forKey: .columns)
        var typed: [BOMField: Int] = [:]
        for (key, value) in rawColumns {
            if let field = BOMField(rawValue: key) {
                typed[field] = value
            }
        }
        columns = typed
        unmappedHeaderIndexes = try container.decode([Int].self, forKey: .unmappedHeaderIndexes)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(headers, forKey: .headers)
        var rawColumns: [String: Int] = [:]
        for (field, index) in columns {
            rawColumns[field.rawValue] = index
        }
        try container.encode(rawColumns, forKey: .columns)
        try container.encode(unmappedHeaderIndexes, forKey: .unmappedHeaderIndexes)
    }

    public func column(for field: BOMField) -> Int? {
        columns[field]
    }
}

public enum BOMRole: String, Codable, Sendable, Hashable, CaseIterable {
    case designRequirement = "design_requirement"
    case quotation
    case ordered
    case received
    case installed
    case spare
    case kitComponent = "kit_component"
    case sourceNote = "source_note"
}

public enum BOMQuantityKind: String, Codable, Sendable, Hashable, CaseIterable {
    case devices
    case channels
    case sets
    case packages
    case metres
    case other
}

public enum BOMIssueKind: String, Codable, Sendable, Hashable, CaseIterable {
    case missingRequiredColumn = "missing_required_column"
    case duplicateColumn = "duplicate_column"
    case columnCountMismatch = "column_count_mismatch"
    case missingQuantity = "missing_quantity"
    case invalidQuantity = "invalid_quantity"
    case negativeQuantity = "negative_quantity"
    case zeroQuantity = "zero_quantity"
    case missingUnit = "missing_unit"
    case unknownUnit = "unknown_unit"
    case conflictingUnit = "conflicting_unit"
    case unknownRole = "unknown_role"
    case unresolvedRoom = "unresolved_room"
    case ambiguousRoom = "ambiguous_room"
    case missingModel = "missing_model"
    case missingProductIdentity = "missing_product_identity"
    case invalidSourceLocator = "invalid_source_locator"
    case valueTooLong = "value_too_long"
    case duplicateRowKey = "duplicate_row_key"
    case invalidChannels = "invalid_channels"
    case negativeSpareQuantity = "negative_spare_quantity"
    case invalidSpareQuantity = "invalid_spare_quantity"
}

public enum BOMIssueSeverity: String, Codable, Sendable, Hashable, CaseIterable {
    case blocking
    case warning
    case info
}

public enum BOMIssueState: String, Codable, Sendable, Hashable {
    case open
    case resolved
}

public struct BOMIssue: Codable, Sendable, Hashable, Identifiable {
    public let id: BOMIssueID
    public let projectID: ProjectID
    public let draftID: BOMDraftID
    public let rowID: BOMDraftRowID?
    public let rowIndex: Int?
    public let kind: BOMIssueKind
    public let severity: BOMIssueSeverity
    public let field: BOMField?
    public let message: String
    public let rawValue: String?
    public let state: BOMIssueState
    public let createdAt: Date
}

public enum BOMDraftRowState: String, Codable, Sendable, Hashable {
    case ready
    case needsReview = "needs_review"
    case blocked
}

public struct BOMDraftRow: Codable, Sendable, Hashable, Identifiable {
    public let id: BOMDraftRowID
    public let rowIndex: Int
    public let lineNumber: Int
    public let sourceRowKey: String
    public let rawFields: [String]
    public let rawRecord: String
    public let locator: SourceLocator
    public let brand: String?
    public let model: String?
    public let orderCode: String?
    public let productName: String?
    public let series: String?
    public let roomName: String?
    public let storey: String?
    public let systemName: String?
    public let rawQuantity: String
    public let rawUnit: String?
    public let quantity: Double?
    public let quantityKind: BOMQuantityKind?
    public let channelsPerDevice: Int?
    public let spareQuantity: Double?
    public let role: BOMRole?
    public let roleRaw: String?
    public let matchedRoomID: RoomID?
    public let notes: String
    public let comparisonKey: String
    public let allocationIdentity: String
    public let state: BOMDraftRowState
    /// A source-backed line may still be presented when identity or unit is
    /// unresolved, but only countable rows contribute to quantity totals.
    public let isCountedCandidate: Bool
}

public struct BOMDraftContent: Codable, Sendable, Hashable {
    public let id: BOMDraftID
    public let projectID: ProjectID
    public let sourceVersionID: SourceVersionID
    public let targetID: BOMTargetID?
    public let adapterIdentifier: String
    public let delimiter: CSVDelimiter?
    public let fingerprint: String
    public let mapping: BOMColumnMapping
    public let rows: [BOMDraftRow]
    public let issues: [BOMIssue]
}

public struct BOMDraft: Codable, Sendable, Hashable, Identifiable {
    public let id: BOMDraftID
    public let projectID: ProjectID
    public let sourceVersionID: SourceVersionID
    public let targetID: BOMTargetID?
    public let createdAt: Date
    public let adapterIdentifier: String
    public let delimiter: CSVDelimiter?
    public let fingerprint: String
    public let mapping: BOMColumnMapping
    public let rows: [BOMDraftRow]
    public let issues: [BOMIssue]

    public var rowCount: Int { rows.count }
    public var issueCount: Int { issues.count }
}

public struct BOMDraftSummary: Codable, Sendable, Hashable, Identifiable {
    public let id: BOMDraftID
    public let projectID: ProjectID
    public let sourceVersionID: SourceVersionID
    public let targetID: BOMTargetID?
    public let createdAt: Date
    public let adapterIdentifier: String
    public let rowCount: Int
    public let issueCount: Int
    public let readyCount: Int
    public let needsReviewCount: Int
    public let blockedCount: Int
}

public struct BOMTarget: Codable, Sendable, Hashable, Identifiable {
    public let id: BOMTargetID
    public let projectID: ProjectID
    public let name: String
    public let createdAt: Date
    public let updatedAt: Date
}

public enum BOMProductMatchState: String, Codable, Sendable, Hashable {
    case sourceBackedCustom = "source_backed_custom"
    case identityUnresolved = "identity_unresolved"
    case manualCustom = "manual_custom"
}

public enum BOMCapabilityState: String, Codable, Sendable, Hashable {
    case unknown
    case sourceDeclared = "source_declared"
    case verified
}

public enum BOMItemOrigin: Codable, Sendable, Hashable {
    case source(sourceVersionID: SourceVersionID, draftID: BOMDraftID, sourceRowKey: String)
    case manual
}

extension BOMItemOrigin {
    var sourceVersionID: SourceVersionID? {
        if case .source(let id, _, _) = self { return id }
        return nil
    }

    var draftID: BOMDraftID? {
        if case .source(_, let id, _) = self { return id }
        return nil
    }

    var sourceRowKey: String? {
        if case .source(_, _, let key) = self { return key }
        return nil
    }
}

public struct BOMItem: Codable, Sendable, Hashable, Identifiable {
    public let id: BOMItemID
    public let projectID: ProjectID
    public let targetID: BOMTargetID
    public let role: BOMRole
    public let roomID: RoomID?
    public let storey: String?
    public let systemName: String?
    public let brand: String?
    public let rawModel: String?
    public let series: String?
    public let orderCode: String?
    public let productName: String?
    public let quantity: Double
    public let quantityKind: BOMQuantityKind?
    public let rawQuantity: String
    public let rawUnit: String?
    public let channelsPerDevice: Int?
    public let spareQuantity: Double?
    public let origin: BOMItemOrigin
    public let matchState: BOMProductMatchState
    public let capabilityState: BOMCapabilityState
    public let isCounted: Bool
    public let notes: String
    public let sourceLocator: SourceLocator?
    public let createdAt: Date
    public let updatedAt: Date
    public let appliedRevision: Int
}

public struct BOMApplyReceipt: Codable, Sendable, Hashable {
    public let draftID: BOMDraftID
    public let targetID: BOMTargetID
    public let adoptedItemIDs: [BOMItemID]
    public let skippedRowIDs: [BOMDraftRowID]
    public let pendingIssues: [BOMIssue]
    public let affectedRoomIDs: [RoomID]
    public let projectRevision: Int
    public let changed: Bool
}

public struct ManualBOMItemDraft: Codable, Sendable, Hashable {
    public var targetID: BOMTargetID
    public var role: BOMRole
    public var roomID: RoomID?
    public var storey: String?
    public var systemName: String
    public var brand: String?
    public var model: String?
    public var series: String?
    public var orderCode: String?
    public var productName: String?
    public var quantity: Double
    public var quantityKind: BOMQuantityKind
    public var rawUnit: String?
    public var channelsPerDevice: Int?
    public var spareQuantity: Double?
    public var notes: String

    public init(
        targetID: BOMTargetID,
        role: BOMRole,
        roomID: RoomID? = nil,
        storey: String? = nil,
        systemName: String = "",
        brand: String? = nil,
        model: String? = nil,
        series: String? = nil,
        orderCode: String? = nil,
        productName: String? = nil,
        quantity: Double,
        quantityKind: BOMQuantityKind,
        rawUnit: String? = nil,
        channelsPerDevice: Int? = nil,
        spareQuantity: Double? = nil,
        notes: String = ""
    ) {
        self.targetID = targetID
        self.role = role
        self.roomID = roomID
        self.storey = storey
        self.systemName = systemName
        self.brand = brand
        self.model = model
        self.series = series
        self.orderCode = orderCode
        self.productName = productName
        self.quantity = quantity
        self.quantityKind = quantityKind
        self.rawUnit = rawUnit
        self.channelsPerDevice = channelsPerDevice
        self.spareQuantity = spareQuantity
        self.notes = notes
    }
}

public struct BOMQuantitySummary: Codable, Sendable, Hashable {
    public let totalsByKind: [BOMQuantityKind: Double]
    public let countedItemCount: Int
    public let uncountedItemCount: Int

    public var deviceCount: Double { totalsByKind[.devices] ?? 0 }
    public var channelCount: Double { totalsByKind[.channels] ?? 0 }
    public var setCount: Double { totalsByKind[.sets] ?? 0 }
    public var metreCount: Double { totalsByKind[.metres] ?? 0 }
    public var packageCount: Double { totalsByKind[.packages] ?? 0 }
}

public struct BOMDraftRowSummary: Codable, Sendable, Hashable {
    public let rowID: BOMDraftRowID
    public let comparisonKey: String
    public let lineNumber: Int
    public let role: BOMRole?
    public let roomName: String?
    public let storey: String?
    public let brand: String?
    public let model: String?
    public let productName: String?
    public let quantity: Double?
    public let quantityKind: BOMQuantityKind?
    public let rawUnit: String?
    public let state: BOMDraftRowState
}

public enum BOMDraftChangeField: String, Codable, Sendable, Hashable, CaseIterable {
    case brand
    case model
    case orderCode = "order_code"
    case productName = "product_name"
    case series
    case quantity
    case quantityKind = "quantity_kind"
    case rawUnit = "raw_unit"
    case room
    case storey
    case role
    case channelsPerDevice = "channels_per_device"
    case spareQuantity = "spare_quantity"
    case notes
}

public struct BOMDraftChange: Codable, Sendable, Hashable {
    public let previous: BOMDraftRowSummary
    public let current: BOMDraftRowSummary
    public let fields: [BOMDraftChangeField]
}

public struct BOMDraftComparison: Codable, Sendable, Hashable {
    public let previousDraftID: BOMDraftID
    public let currentDraftID: BOMDraftID
    public let added: [BOMDraftRowSummary]
    public let changed: [BOMDraftChange]
    public let absent: [BOMDraftRowSummary]
    public let unchangedCount: Int
}

public struct BOMDraftOptions: Sendable, Equatable {
    public var defaultRole: BOMRole
    public var columnOverrides: [BOMField: Int]
    public var csv: CSVParseOptions

    public init(
        defaultRole: BOMRole = .designRequirement,
        columnOverrides: [BOMField: Int] = [:],
        csv: CSVParseOptions = CSVParseOptions()
    ) {
        self.defaultRole = defaultRole
        self.columnOverrides = columnOverrides
        self.csv = csv
    }
}

/// A format-neutral extraction result. CSV is implemented now; future XLSX,
/// PDF table and OCR adapters supply the same headers, rows and locators
/// without gaining any new database or file-system authority.
public struct BOMExtractionRow: Codable, Sendable, Hashable {
    public let sourceRowKey: String
    public let lineNumber: Int
    public let values: [String]
    public let rawRecord: String
    public let locator: SourceLocator

    public init(
        sourceRowKey: String,
        lineNumber: Int,
        values: [String],
        rawRecord: String,
        locator: SourceLocator
    ) {
        self.sourceRowKey = sourceRowKey
        self.lineNumber = lineNumber
        self.values = values
        self.rawRecord = rawRecord
        self.locator = locator
    }
}

public struct BOMExtractionTable: Codable, Sendable, Hashable {
    public let headers: [String]
    public let rows: [BOMExtractionRow]
    public let adapterIdentifier: String

    public init(headers: [String], rows: [BOMExtractionRow], adapterIdentifier: String) {
        self.headers = headers
        self.rows = rows
        self.adapterIdentifier = adapterIdentifier
    }
}

extension CSVTable {
    /// Convert the bounded CSV result into the extraction contract used by the
    /// BOM builder. `sourceRowKey` is stable for the whole CSV content but not
    /// across a different source version; comparison uses product/room keys,
    /// not this value.
    public func extractionTable(adapterIdentifier: String = "csv-v1") throws -> BOMExtractionTable {
        guard let header else { throw CSVParseError.noRecords }
        var extractionRows: [BOMExtractionRow] = []
        extractionRows.reserveCapacity(rows.count)
        for row in rows {
            let locator = SourceLocator.spreadsheet(sheetName: nil, row: row.recordIndex + 1, cell: nil)
            try locator.validate()
            extractionRows.append(
                BOMExtractionRow(
                    sourceRowKey: "row:\(row.recordIndex + 1)",
                    lineNumber: row.startLine,
                    values: row.fields,
                    rawRecord: row.rawRecord,
                    locator: locator
                )
            )
        }
        return BOMExtractionTable(
            headers: header,
            rows: extractionRows,
            adapterIdentifier: adapterIdentifier
        )
    }
}
