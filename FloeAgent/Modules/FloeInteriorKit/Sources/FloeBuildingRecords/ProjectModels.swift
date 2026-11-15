import Foundation

public struct ProjectRecord: Codable, Sendable, Hashable, Identifiable {
    public let id: ProjectID
    public let name: String
    public let createdAt: Date
    public let updatedAt: Date
    public let revision: Int
}

public enum RoomKind: String, Codable, Sendable, Hashable, CaseIterable {
    case livingRoom = "living_room"
    case bedroom
    case kitchen
    case bathroom
    case dining
    case study
    case balcony
    case hallway
    case storage
    case garage
    case office
    case utility
    case other
}

public struct RoomDraft: Codable, Sendable, Hashable {
    public var name: String
    public var storey: String?
    public var kind: RoomKind
    public var notes: String
    public var aliases: [String]

    public init(
        name: String,
        storey: String? = nil,
        kind: RoomKind = .other,
        notes: String = "",
        aliases: [String] = []
    ) {
        self.name = name
        self.storey = storey
        self.kind = kind
        self.notes = notes
        self.aliases = aliases
    }
}

public struct RoomRecord: Codable, Sendable, Hashable, Identifiable {
    public let id: RoomID
    public let projectID: ProjectID
    public let name: String
    public let storey: String?
    public let kind: RoomKind
    public let notes: String
    public let aliases: [String]
    public let createdAt: Date
    public let updatedAt: Date
}

public enum SourceKind: String, Codable, Sendable, Hashable, CaseIterable {
    case sketch
    case photo
    case document
    case scan
    case note
    case cad
    case assetImport = "asset_import"
    case aiRequest = "ai_request"
    case table
    case other
}

public struct SourceImportRequest: Sendable, Codable, Hashable {
    public var kind: SourceKind
    public var title: String
    public var originalName: String
    public var mediaType: String
    public var data: Data
    public var note: String
    public var roomIDs: [RoomID]
    /// Optional caller-owned replay token. When supplied, reusing the token
    /// with identical content and metadata returns the original source version;
    /// reusing it with different bytes or metadata is rejected.
    public var idempotencyKey: String?

    public init(
        kind: SourceKind,
        title: String,
        originalName: String,
        mediaType: String,
        data: Data,
        note: String = "",
        roomIDs: [RoomID] = [],
        idempotencyKey: String? = nil
    ) {
        self.kind = kind
        self.title = title
        self.originalName = originalName
        self.mediaType = mediaType
        self.data = data
        self.note = note
        self.roomIDs = roomIDs
        self.idempotencyKey = idempotencyKey
    }
}

public struct SourceRecord: Codable, Sendable, Hashable, Identifiable {
    public let id: SourceID
    public let projectID: ProjectID
    public let kind: SourceKind
    public let title: String
    public let createdAt: Date
    public let updatedAt: Date
    public let latestVersionID: SourceVersionID
    public let latestVersionNumber: Int
    public let latestOriginalName: String
    public let versionCount: Int
    /// Every room associated with the source, independent of its version. A
    /// room rename therefore does not invalidate the association.
    public let roomIDs: [RoomID]
}

public struct SourceVersion: Codable, Sendable, Hashable, Identifiable {
    public let id: SourceVersionID
    public let sourceID: SourceID
    public let version: Int
    public let contentSHA256: String
    public let byteCount: Int
    public let mediaType: String
    public let originalName: String
    /// Project-relative content-addressed path. Readers do not accept a caller
    /// supplied path; this value is diagnostic provenance.
    public let relativePath: String
    public let note: String
    public let importedAt: Date
}

public struct SourceVersionContent: Sendable, Hashable {
    public let version: SourceVersion
    public let data: Data
}

public struct SourceImportResult: Codable, Sendable, Hashable {
    public let source: SourceRecord
    public let version: SourceVersion
    public let roomIDs: [RoomID]
}
