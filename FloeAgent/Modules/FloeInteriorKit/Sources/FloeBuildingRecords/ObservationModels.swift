import Foundation

/// A rectangle normalized to the source page or image (0...1 from the top-left).
public struct NormalizedRect: Codable, Sendable, Hashable {
    private enum CodingKeys: String, CodingKey {
        case x, y, width, height
    }

    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) throws {
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite else {
            throw BuildingRecordsError.invalidValue(field: "region", reason: "coordinates must be finite")
        }
        let tolerance = 1e-9
        guard x >= 0, y >= 0, width > 0, height > 0,
              x + width <= 1 + tolerance, y + height <= 1 + tolerance else {
            throw BuildingRecordsError.invalidValue(
                field: "region",
                reason: "must be a non-empty rectangle inside 0...1"
            )
        }
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let x = try container.decode(Double.self, forKey: .x)
        let y = try container.decode(Double.self, forKey: .y)
        let width = try container.decode(Double.self, forKey: .width)
        let height = try container.decode(Double.self, forKey: .height)
        do {
            try self.init(x: x, y: y, width: width, height: height)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .width,
                in: container,
                debugDescription: "Normalized rectangle is outside the page/image bounds."
            )
        }
    }
}

public struct TextSpan: Codable, Sendable, Hashable {
    private enum CodingKeys: String, CodingKey {
        case start, length
    }

    public let start: Int
    public let length: Int

    public init(start: Int, length: Int) throws {
        guard start >= 0, length > 0 else {
            throw BuildingRecordsError.invalidValue(field: "textSpan", reason: "start must be >= 0 and length > 0")
        }
        self.start = start
        self.length = length
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let start = try container.decode(Int.self, forKey: .start)
        let length = try container.decode(Int.self, forKey: .length)
        do {
            try self.init(start: start, length: length)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .length,
                in: container,
                debugDescription: "Text span must have a non-negative start and positive length."
            )
        }
    }
}

/// Where a source value can be found. The enum is typed at the API boundary and
/// stored as JSON, so future adapters can add locator kinds through a migration
/// instead of an arbitrary metadata blob.
public enum SourceLocator: Codable, Sendable, Hashable {
    case spreadsheet(sheetName: String?, row: Int?, cell: String?)
    case pdf(page: Int, region: NormalizedRect?)
    case image(region: NormalizedRect?)
    case text(span: TextSpan?)

    public func validate() throws {
        switch self {
        case .spreadsheet(let sheetName, let row, let cell):
            let sheet = sheetName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let cellText = cell?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard sheet?.isEmpty == false || row != nil || cellText?.isEmpty == false else {
                throw BuildingRecordsError.invalidSourceLocator("a spreadsheet locator needs a sheet, row or cell")
            }
            if let sheet {
                guard !sheet.isEmpty, sheet.count <= 200 else {
                    throw BuildingRecordsError.invalidSourceLocator("sheet name must be 1...200 characters")
                }
            }
            if let row {
                guard row >= 1 else {
                    throw BuildingRecordsError.invalidSourceLocator("row must be at least 1")
                }
            }
            if let cellText {
                guard !cellText.isEmpty, cellText.count <= 32 else {
                    throw BuildingRecordsError.invalidSourceLocator("cell must be 1...32 characters")
                }
            }
        case .pdf(let page, let region):
            guard page >= 1 else {
                throw BuildingRecordsError.invalidSourceLocator("PDF page must be at least 1")
            }
            _ = region
        case .image:
            break
        case .text(let span):
            if let span {
                try span.validate()
            }
        }
    }

    public var displayName: String {
        switch self {
        case .spreadsheet(let sheet, let row, let cell):
            var parts: [String] = []
            if let sheet, !sheet.isEmpty { parts.append(sheet) }
            if let row { parts.append("row \(row)") }
            if let cell, !cell.isEmpty { parts.append(cell) }
            return parts.joined(separator: " · ")
        case .pdf(let page, _):
            return "PDF page \(page)"
        case .image(let region):
            return region == nil ? "Image" : "Image region"
        case .text(let span):
            guard let span else { return "Text" }
            return "Text span \(span.start)–\(span.start + span.length)"
        }
    }
}

extension TextSpan {
    func validate() throws {
        guard start >= 0, length > 0 else {
            throw BuildingRecordsError.invalidSourceLocator("text span must have start >= 0 and length > 0")
        }
    }
}

public enum ObservationOrigin: String, Codable, Sendable, Hashable, CaseIterable {
    /// Older records without provenance are unknown, never relabelled as measured.
    case unknown
    case user
    case manualMeasurement = "manual_measurement"
    case ar
    case lidar
    case aiExtracted = "ai_extracted"
    case aiInferred = "ai_inferred"
    case calculated
    case imported
}

/// A typed normalized value. The observation separately keeps the untouched
/// source text, so an unrecognized unit or malformed number is never presented
/// as a clean measurement.
public struct RecordedValue: Codable, Sendable, Hashable {
    private enum CodingKeys: String, CodingKey {
        case kind, number, text, boolean, unit
    }

    public enum Kind: String, Codable, Sendable, Hashable {
        case number
        case text
        case boolean
    }

    public let kind: Kind
    public let number: Double?
    public let text: String?
    public let boolean: Bool?
    public let unit: String?

    public init(number: Double, unit: String? = nil) throws {
        guard number.isFinite, abs(number) <= 1e12 else {
            throw BuildingRecordsError.invalidValue(field: "normalizedNumber", reason: "must be finite and bounded")
        }
        let normalizedUnit = try Self.normalizedUnit(unit)
        self.kind = .number
        self.number = number
        self.text = nil
        self.boolean = nil
        self.unit = normalizedUnit
    }

    public init(text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 20_000 else {
            throw BuildingRecordsError.invalidValue(field: "normalizedText", reason: "must be 1...20000 characters")
        }
        self.kind = .text
        self.number = nil
        self.text = trimmed
        self.boolean = nil
        self.unit = nil
    }

    public init(boolean: Bool) {
        self.kind = .boolean
        self.number = nil
        self.text = nil
        self.boolean = boolean
        self.unit = nil
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .number:
            let number = try container.decode(Double.self, forKey: .number)
            let unit = try container.decodeIfPresent(String.self, forKey: .unit)
            try self.init(number: number, unit: unit)
        case .text:
            let text = try container.decode(String.self, forKey: .text)
            try self.init(text: text)
        case .boolean:
            let boolean = try container.decode(Bool.self, forKey: .boolean)
            self.init(boolean: boolean)
        }
    }

    public var displayString: String {
        switch kind {
        case .number:
            let numberText = number.map { String($0) } ?? ""
            return unit.map { "\(numberText) \($0)" } ?? numberText
        case .text:
            return text ?? ""
        case .boolean:
            return (boolean ?? false) ? "true" : "false"
        }
    }

    static func normalizedUnit(_ unit: String?) throws -> String? {
        guard let unit else { return nil }
        let trimmed = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 24 else {
            throw BuildingRecordsError.invalidValue(field: "unit", reason: "must be 1...24 characters")
        }
        guard !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw BuildingRecordsError.invalidValue(field: "unit", reason: "must not contain control characters")
        }
        return trimmed
    }
}

public struct ObservationDraft: Codable, Sendable, Hashable {
    public var roomID: RoomID
    public var propertyKey: String
    public var rawValue: String
    public var normalizedValue: RecordedValue?
    public var origin: ObservationOrigin
    public var sourceVersionID: SourceVersionID?
    public var locator: SourceLocator?
    public var note: String
    public var supersedesObservationID: ObservationID?

    public init(
        roomID: RoomID,
        propertyKey: String,
        rawValue: String,
        normalizedValue: RecordedValue? = nil,
        origin: ObservationOrigin = .user,
        sourceVersionID: SourceVersionID? = nil,
        locator: SourceLocator? = nil,
        note: String = "",
        supersedesObservationID: ObservationID? = nil
    ) {
        self.roomID = roomID
        self.propertyKey = propertyKey
        self.rawValue = rawValue
        self.normalizedValue = normalizedValue
        self.origin = origin
        self.sourceVersionID = sourceVersionID
        self.locator = locator
        self.note = note
        self.supersedesObservationID = supersedesObservationID
    }
}

public enum ObservationAdoptionState: Codable, Sendable, Hashable {
    case unverified
    case adopted(AdoptedValueID)
    case superseded(by: AdoptedValueID)
}

public struct ObservationRecord: Codable, Sendable, Hashable, Identifiable {
    public let id: ObservationID
    public let projectID: ProjectID
    public let roomID: RoomID
    public let propertyKey: String
    public let rawValue: String
    public let normalizedValue: RecordedValue?
    public let origin: ObservationOrigin
    public let sourceVersionID: SourceVersionID?
    public let locator: SourceLocator?
    public let note: String
    public let createdAt: Date
    public let supersedesObservationID: ObservationID?
    public let adoptionState: ObservationAdoptionState
}

public struct AdoptedValueRecord: Codable, Sendable, Hashable, Identifiable {
    public let id: AdoptedValueID
    public let projectID: ProjectID
    public let roomID: RoomID
    public let propertyKey: String
    public let value: RecordedValue
    public let observationID: ObservationID
    public let adoptedAt: Date
    public let adoptedRevision: Int
    public let supersededBy: AdoptedValueID?
}
