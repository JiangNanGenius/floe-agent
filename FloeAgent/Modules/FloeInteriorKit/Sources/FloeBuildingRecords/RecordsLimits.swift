import Foundation

/// Hard bounds enforced by this service. They keep archive reads, listings,
/// searches and table extraction finite even when a project is malformed or a
/// file was produced by another tool.
public struct RecordsLimits: Sendable, Equatable {
    public let maxSourceBytes: Int
    public let maxTextLength: Int
    public let maxTitleLength: Int
    public let maxRoomNameLength: Int
    public let maxAliasCount: Int
    public let maxOriginalNameLength: Int
    public let maxIdempotencyKeyLength: Int
    public let maxSearchLimit: Int
    public let maxSearchOffset: Int
    public let maxListLimit: Int

    public init(
        maxSourceBytes: Int = 64 * 1024 * 1024,
        maxTextLength: Int = 20_000,
        maxTitleLength: Int = 200,
        maxRoomNameLength: Int = 120,
        maxAliasCount: Int = 20,
        maxOriginalNameLength: Int = 255,
        maxIdempotencyKeyLength: Int = 200,
        maxSearchLimit: Int = 100,
        maxSearchOffset: Int = 1_000,
        maxListLimit: Int = 500
    ) {
        self.maxSourceBytes = maxSourceBytes
        self.maxTextLength = maxTextLength
        self.maxTitleLength = maxTitleLength
        self.maxRoomNameLength = maxRoomNameLength
        self.maxAliasCount = maxAliasCount
        self.maxOriginalNameLength = maxOriginalNameLength
        self.maxIdempotencyKeyLength = maxIdempotencyKeyLength
        self.maxSearchLimit = maxSearchLimit
        self.maxSearchOffset = maxSearchOffset
        self.maxListLimit = maxListLimit
    }

    func validate() throws {
        guard maxSourceBytes > 0 else {
            throw BuildingRecordsError.invalidValue(field: "maxSourceBytes", reason: "must be positive")
        }
        guard maxTextLength > 0, maxTextLength <= 20_000 else {
            throw BuildingRecordsError.invalidValue(field: "maxTextLength", reason: "must be 1...20000")
        }
        guard maxTitleLength > 0, maxTitleLength <= 200 else {
            throw BuildingRecordsError.invalidValue(field: "maxTitleLength", reason: "must be 1...200")
        }
        guard maxRoomNameLength > 0, maxRoomNameLength <= 200 else {
            throw BuildingRecordsError.invalidValue(field: "maxRoomNameLength", reason: "must be 1...200")
        }
        guard maxAliasCount > 0, maxAliasCount <= 100 else {
            throw BuildingRecordsError.invalidValue(field: "maxAliasCount", reason: "must be 1...100")
        }
        guard maxOriginalNameLength > 0, maxOriginalNameLength <= 255 else {
            throw BuildingRecordsError.invalidValue(field: "maxOriginalNameLength", reason: "must be 1...255")
        }
        guard maxIdempotencyKeyLength > 0, maxIdempotencyKeyLength <= 1_024 else {
            throw BuildingRecordsError.invalidValue(field: "maxIdempotencyKeyLength", reason: "must be 1...1024")
        }
        guard maxSearchLimit > 0 else {
            throw BuildingRecordsError.invalidValue(field: "maxSearchLimit", reason: "must be positive")
        }
        guard maxSearchOffset >= 0 else {
            throw BuildingRecordsError.invalidValue(field: "maxSearchOffset", reason: "must not be negative")
        }
        guard maxListLimit > 0 else {
            throw BuildingRecordsError.invalidValue(field: "maxListLimit", reason: "must be positive")
        }
    }
}

/// Result metadata for one committed records revision. A no-op replay reports
/// `previousRevision == revision` and `didChange == false`.
public struct MutationReceipt: Codable, Sendable, Hashable {
    public let projectID: ProjectID
    public let previousRevision: Int
    public let revision: Int
    public let didChange: Bool

    public init(projectID: ProjectID, previousRevision: Int, revision: Int, didChange: Bool) {
        self.projectID = projectID
        self.previousRevision = previousRevision
        self.revision = revision
        self.didChange = didChange
    }
}

/// A committed value plus the revision that contains it. Batch operations bump
/// the project revision once, so the receipt is the caller's CAS token for the
/// next operation rather than a per-row revision.
public struct ProjectMutation<Value: Codable & Sendable>: Codable, Sendable {
    public let value: Value
    public let receipt: MutationReceipt

    public init(value: Value, receipt: MutationReceipt) {
        self.value = value
        self.receipt = receipt
    }
}
