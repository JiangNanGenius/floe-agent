import Foundation

/// The identity of a derived scene. Restoring an older object revision number
/// cannot make a different drawing match its cached coordinates.
public struct ChemistryPreviewKey: Codable, Equatable, Sendable {
    public let projectID: UUID
    public let objectID: UUID
    public let objectRevision: UInt64
    public let sourceDigest: String
    public let engine: String
    public let parameters: String

    public init(projectID: UUID, object: ChemicalObject, engine: String, parameters: String) throws {
        self.projectID = projectID
        objectID = object.id
        objectRevision = object.revision
        self.engine = engine
        self.parameters = parameters
        let input: [String?] = [object.kind.rawValue, object.format, object.source, object.sketchDocument, object.sketchSMILES]
        sourceDigest = ChemistryProjectStore.digest(try JSONEncoder().encode(input))
    }

    public func matches(_ object: ChemicalObject) throws -> Bool {
        guard object.id == objectID, object.revision == objectRevision else { return false }
        return try self == Self(projectID: projectID, object: object, engine: engine, parameters: parameters)
    }
}

public struct ChemistryCachedMoleculePreview: Codable, Sendable {
    public let key: ChemistryPreviewKey
    public let cjson: String
    public let molblock: String
    public let optimizationStatus: String
    private let checksum: String

    public init(key: ChemistryPreviewKey, cjson: String, molblock: String, optimizationStatus: String) throws {
        self.key = key
        self.cjson = cjson
        self.molblock = molblock
        self.optimizationStatus = optimizationStatus
        checksum = try Self.digest(key, cjson, molblock, optimizationStatus)
    }
    public var valid: Bool {
        guard !cjson.isEmpty, !molblock.isEmpty else { return false }
        return (try? Self.digest(key, cjson, molblock, optimizationStatus)) == checksum
    }
    private static func digest(_ key: ChemistryPreviewKey, _ cjson: String, _ mol: String, _ status: String) throws -> String {
        struct Payload: Encodable {
            let key: ChemistryPreviewKey
            let cjson: String
            let molblock: String
            let optimizationStatus: String
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return ChemistryProjectStore.digest(try encoder.encode(Payload(key: key, cjson: cjson, molblock: mol, optimizationStatus: status)))
    }
}
