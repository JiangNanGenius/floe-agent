import Foundation

/// A stable record identity scoped to one kind of building record.
///
/// The phantom tag prevents accidentally passing a room identifier to a source
/// API. The value is persisted as a lowercase UUID string and encoded as one
/// JSON string, not as an object with an implementation-specific wrapper.
public struct RecordID<Tag: Sendable>: RawRepresentable, Sendable, Hashable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(UUID.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String {
        rawValue.uuidString
    }
}

extension RecordID {
    /// Canonical SQLite representation. UUID text is always lowercase so that
    /// imported and generated identifiers cannot form duplicate database rows.
    var databaseValue: String {
        rawValue.uuidString.lowercased()
    }
}

public enum ProjectIDTag: Sendable {}
public enum RoomIDTag: Sendable {}
public enum SourceIDTag: Sendable {}
public enum SourceVersionIDTag: Sendable {}
public enum ObservationIDTag: Sendable {}
public enum AdoptedValueIDTag: Sendable {}
public enum BOMTargetIDTag: Sendable {}
public enum BOMDraftIDTag: Sendable {}
public enum BOMDraftRowIDTag: Sendable {}
public enum BOMIssueIDTag: Sendable {}
public enum BOMItemIDTag: Sendable {}

public typealias ProjectID = RecordID<ProjectIDTag>
public typealias RoomID = RecordID<RoomIDTag>
public typealias SourceID = RecordID<SourceIDTag>
public typealias SourceVersionID = RecordID<SourceVersionIDTag>
public typealias ObservationID = RecordID<ObservationIDTag>
public typealias AdoptedValueID = RecordID<AdoptedValueIDTag>
public typealias BOMTargetID = RecordID<BOMTargetIDTag>
public typealias BOMDraftID = RecordID<BOMDraftIDTag>
public typealias BOMDraftRowID = RecordID<BOMDraftRowIDTag>
public typealias BOMIssueID = RecordID<BOMIssueIDTag>
public typealias BOMItemID = RecordID<BOMItemIDTag>
