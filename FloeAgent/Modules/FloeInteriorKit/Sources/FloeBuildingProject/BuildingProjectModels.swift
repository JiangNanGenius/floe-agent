import Foundation
import FloeBuildingRecords

// MARK: - Commit identity

/// Stable caller-supplied idempotency key for one publish attempt. Reusing the
/// same value with different inputs is rejected; reusing it after the exact
/// generation was published returns the existing generation instead of writing
/// a second copy.
public struct BuildingCommitID: Codable, Sendable, Hashable, CustomStringConvertible {
    public let rawValue: String

    public init(uuid: UUID = UUID()) {
        self.rawValue = uuid.uuidString.lowercased()
    }

    public init(rawValue: String) throws {
        guard let uuid = UUID(uuidString: rawValue) else {
            throw BuildingProjectError.invalidCommitID(rawValue)
        }
        self.rawValue = uuid.uuidString.lowercased()
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        try self.init(rawValue: raw)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}

// MARK: - Stored identity

/// Identity the caller verified against the native CAD document before handing
/// the saved .floecad directory to this repository. The repository validates the
/// internal shape and binds these values to the copied bytes; validating the real
/// CAD storedIdentity remains the integration owner's responsibility.
public struct BuildingStoredIdentity: Codable, Sendable, Hashable {
    public let cadRevision: Int
    public let cadContentSHA256: String
    public let cadModelSHA256: String
    public let recordsProjectID: ProjectID
    public let recordsRevision: Int

    public init(
        cadRevision: Int,
        cadContentSHA256: String,
        cadModelSHA256: String,
        recordsProjectID: ProjectID,
        recordsRevision: Int
    ) throws {
        try Self.validate(
            cadRevision: cadRevision,
            cadContentSHA256: cadContentSHA256,
            cadModelSHA256: cadModelSHA256,
            recordsRevision: recordsRevision
        )
        self.cadRevision = cadRevision
        self.cadContentSHA256 = cadContentSHA256
        self.cadModelSHA256 = cadModelSHA256
        self.recordsProjectID = recordsProjectID
        self.recordsRevision = recordsRevision
    }

    private enum CodingKeys: String, CodingKey {
        case cadRevision
        case cadContentSHA256
        case cadModelSHA256
        case recordsProjectID
        case recordsRevision
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let cadRevision = try container.decode(Int.self, forKey: .cadRevision)
        let cadContentSHA256 = try container.decode(String.self, forKey: .cadContentSHA256)
        let cadModelSHA256 = try container.decode(String.self, forKey: .cadModelSHA256)
        let recordsProjectID = try container.decode(ProjectID.self, forKey: .recordsProjectID)
        let recordsRevision = try container.decode(Int.self, forKey: .recordsRevision)
        try self.init(
            cadRevision: cadRevision,
            cadContentSHA256: cadContentSHA256,
            cadModelSHA256: cadModelSHA256,
            recordsProjectID: recordsProjectID,
            recordsRevision: recordsRevision
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cadRevision, forKey: .cadRevision)
        try container.encode(cadContentSHA256, forKey: .cadContentSHA256)
        try container.encode(cadModelSHA256, forKey: .cadModelSHA256)
        try container.encode(recordsProjectID, forKey: .recordsProjectID)
        try container.encode(recordsRevision, forKey: .recordsRevision)
    }

    public func validated() throws {
        try Self.validate(
            cadRevision: cadRevision,
            cadContentSHA256: cadContentSHA256,
            cadModelSHA256: cadModelSHA256,
            recordsRevision: recordsRevision
        )
    }

    static func isSHA256Hex(_ value: String) -> Bool {
        guard value.count == 64 else { return false }
        return value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }

    private static func validate(
        cadRevision: Int,
        cadContentSHA256: String,
        cadModelSHA256: String,
        recordsRevision: Int
    ) throws {
        guard cadRevision >= 0 else {
            throw BuildingProjectError.invalidIdentity("the CAD revision must not be negative")
        }
        guard recordsRevision >= 0 else {
            throw BuildingProjectError.invalidIdentity("the records revision must not be negative")
        }
        guard isSHA256Hex(cadContentSHA256) else {
            throw BuildingProjectError.invalidIdentity(
                "the CAD content digest must be 64 lowercase hexadecimal characters"
            )
        }
        guard isSHA256Hex(cadModelSHA256) else {
            throw BuildingProjectError.invalidIdentity(
                "the CAD model digest must be 64 lowercase hexadecimal characters"
            )
        }
    }
}

// MARK: - Expected generation

public enum BuildingGenerationExpectation: Sendable, Hashable {
    case emptyProject
    case generation(String)

    public var generationID: String? {
        switch self {
        case .emptyProject:
            return nil
        case .generation(let id):
            return id
        }
    }
}

// MARK: - Limits and configuration

public struct BuildingProjectLimits: Sendable, Equatable {
    public var maxFileCount: Int
    public var maxTotalBytes: Int
    public var maxSingleFileBytes: Int
    public var maxRelativePathLength: Int
    public var maxDirectoryDepth: Int
    public var maxManifestBytes: Int
    public var maxJournalBytes: Int
    public var maxEditorStateBytes: Int
    public var copyChunkBytes: Int

    public init(
        maxFileCount: Int = 50_000,
        maxTotalBytes: Int = 8 * 1024 * 1024 * 1024,
        maxSingleFileBytes: Int = 2 * 1024 * 1024 * 1024,
        maxRelativePathLength: Int = 1024,
        maxDirectoryDepth: Int = 64,
        maxManifestBytes: Int = 32 * 1024 * 1024,
        maxJournalBytes: Int = 4 * 1024 * 1024,
        maxEditorStateBytes: Int = 1024 * 1024,
        copyChunkBytes: Int = 1024 * 1024
    ) {
        self.maxFileCount = maxFileCount
        self.maxTotalBytes = maxTotalBytes
        self.maxSingleFileBytes = maxSingleFileBytes
        self.maxRelativePathLength = maxRelativePathLength
        self.maxDirectoryDepth = maxDirectoryDepth
        self.maxManifestBytes = maxManifestBytes
        self.maxJournalBytes = maxJournalBytes
        self.maxEditorStateBytes = maxEditorStateBytes
        self.copyChunkBytes = copyChunkBytes
    }

    func validate() throws {
        guard maxFileCount > 0 else {
            throw BuildingProjectError.budgetExceeded("maxFileCount must be positive")
        }
        guard maxTotalBytes > 0, maxSingleFileBytes > 0, maxSingleFileBytes <= maxTotalBytes else {
            throw BuildingProjectError.budgetExceeded("byte limits must be positive and ordered")
        }
        guard maxRelativePathLength >= 64, maxRelativePathLength <= 4096 else {
            throw BuildingProjectError.budgetExceeded("maxRelativePathLength must be 64...4096")
        }
        guard maxDirectoryDepth >= 1, maxDirectoryDepth <= 256 else {
            throw BuildingProjectError.budgetExceeded("maxDirectoryDepth must be 1...256")
        }
        guard maxManifestBytes >= 1024, maxJournalBytes >= 1024 else {
            throw BuildingProjectError.budgetExceeded("metadata byte limits are too small")
        }
        guard maxEditorStateBytes > 0, maxEditorStateBytes <= 16 * 1024 * 1024 else {
            throw BuildingProjectError.budgetExceeded("maxEditorStateBytes must be 1...16777216")
        }
        guard copyChunkBytes >= 64 * 1024, copyChunkBytes <= 8 * 1024 * 1024 else {
            throw BuildingProjectError.budgetExceeded("copyChunkBytes must be 65536...8388608")
        }
    }
}

public struct BuildingProjectConfiguration: Sendable {
    public var limits: BuildingProjectLimits
    public var lockTimeout: TimeInterval
    public var faultHooks: BuildingProjectFaultHooks?

    public init(
        limits: BuildingProjectLimits = BuildingProjectLimits(),
        lockTimeout: TimeInterval = 10,
        faultHooks: BuildingProjectFaultHooks? = nil
    ) {
        self.limits = limits
        self.lockTimeout = lockTimeout
        self.faultHooks = faultHooks
    }

    public static let `default` = BuildingProjectConfiguration()

    func validate() throws {
        try limits.validate()
        guard lockTimeout >= 0, lockTimeout <= 600 else {
            throw BuildingProjectError.lockFailed("lockTimeout must be 0...600 seconds")
        }
    }
}

// MARK: - Fault injection

public enum BuildingProjectFaultPoint: String, Codable, Sendable, CaseIterable {
    case afterPreparation
    case afterCADCopy
    case afterRecordsCopy
    case beforeManifestPublish
    case afterManifestPublish
}

public struct BuildingProjectFaultHooks: Sendable {
    public var onPoint: @Sendable (BuildingProjectFaultPoint) throws -> Void

    public init(onPoint: @escaping @Sendable (BuildingProjectFaultPoint) throws -> Void) {
        self.onPoint = onPoint
    }
}

// MARK: - Cancellation

public final class BuildingProjectCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func check() throws {
        if isCancelled { throw BuildingProjectError.cancelled }
    }
}

// MARK: - Errors

public enum BuildingProjectError: Error, Equatable, Sendable {
    case invalidRoot(String)
    case rootAlreadyExists
    case projectNotFound
    case lockTimeout
    case lockFailed(String)
    case invalidCommitID(String)
    case invalidIdentity(String)
    case recordsSnapshotMismatch(String)
    case generationExpectationConflict(expected: String?, actual: String?)
    case commitConflict(commitID: BuildingCommitID)
    case pendingRecovery([String])
    case generationNotFound(String)
    case generationAlreadyExists(String)
    case generationCorrupted(generationID: String, reason: String)
    case manifestCorrupted(String)
    case journalUnreadable(String)
    case workingCopyNotFound(String)
    case invalidWorkingCopy(String)
    case workingCopyBaseConflict(expected: String?, actual: String?)
    case workingCopySaveInProgress(BuildingCommitID)
    case workingCopySaveNotStarted
    case workingCopyProjectMismatch
    case workingCopyRevisionRegression(previous: Int, target: Int)
    case noPublishedGeneration
    case pathEscapesRoot(String)
    case symbolicLinkRejected(String)
    case unsupportedFileType(String)
    case duplicatePath(String)
    case outputExists(String)
    case budgetExceeded(String)
    case editorStateInvalid(String)
    case sourceChangedDuringCommit(String)
    case cancelled
    case injectedFailure(BuildingProjectFaultPoint)
    case unsupportedSchema(Int)
    case ioFailure(String)
}

extension BuildingProjectError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidRoot(let reason):
            return "The building project root is not usable: \(reason)"
        case .rootAlreadyExists:
            return "The building project root already exists and is not empty."
        case .projectNotFound:
            return "The building project root does not exist."
        case .lockTimeout:
            return "The building project is busy; the operation lock timed out."
        case .lockFailed(let reason):
            return "The building project lock could not be acquired: \(reason)"
        case .invalidCommitID(let value):
            return "The commit identifier is not a UUID: \(value)"
        case .invalidIdentity(let reason):
            return "The stored project identity is invalid: \(reason)"
        case .recordsSnapshotMismatch(let reason):
            return "The records snapshot does not match the supplied identity: \(reason)"
        case .generationExpectationConflict(let expected, let actual):
            return "The project was published by another commit (expected \(expected ?? "empty"), actual \(actual ?? "empty"))."
        case .commitConflict(let commitID):
            return "Commit \(commitID) is not the commit that published the current generation."
        case .pendingRecovery(let ids):
            return "Unfinished building project commits require recovery: \(ids.joined(separator: ", "))."
        case .generationNotFound(let id):
            return "The building project generation was not found: \(id)"
        case .generationAlreadyExists(let id):
            return "A different generation already exists at \(id)."
        case .generationCorrupted(let id, let reason):
            return "Generation \(id) failed integrity verification: \(reason)"
        case .manifestCorrupted(let reason):
            return "The published manifest is invalid: \(reason)"
        case .journalUnreadable(let name):
            return "The commit journal is unreadable: \(name)"
        case .workingCopyNotFound(let id):
            return "The working copy was not found: \(id)"
        case .invalidWorkingCopy(let reason):
            return "The working copy is invalid: \(reason)"
        case .workingCopyBaseConflict(let expected, let actual):
            return "The working copy baseline changed (expected \(expected ?? "empty"), actual \(actual ?? "empty"))."
        case .workingCopySaveInProgress(let commitID):
            return "Another save is already in progress for this working copy: \(commitID)"
        case .workingCopySaveNotStarted:
            return "The working copy has no in-flight save for this commit; call beginWorkingCopySave before publishing."
        case .workingCopyProjectMismatch:
            return "The published generation belongs to a different records project."
        case .workingCopyRevisionRegression(let previous, let target):
            return "The published records revision \(target) is older than the working copy baseline \(previous)."
        case .noPublishedGeneration:
            return "The building project has no published generation."
        case .pathEscapesRoot(let path):
            return "A path escapes the building project root: \(path)"
        case .symbolicLinkRejected(let path):
            return "A symbolic link is not allowed here: \(path)"
        case .unsupportedFileType(let path):
            return "Only regular files and directories are allowed: \(path)"
        case .duplicatePath(let path):
            return "Two project files resolve to the same path: \(path)"
        case .outputExists(let path):
            return "The output already exists and was not overwritten: \(path)"
        case .budgetExceeded(let reason):
            return "The building project operation exceeds its budget: \(reason)"
        case .editorStateInvalid(let reason):
            return "The editor state metadata is invalid: \(reason)"
        case .sourceChangedDuringCommit(let path):
            return "The source changed while the generation was being captured: \(path)"
        case .cancelled:
            return "The building project operation was cancelled."
        case .injectedFailure(let point):
            return "The commit stopped at the injected fault point \(point.rawValue)."
        case .unsupportedSchema(let schema):
            return "The building project uses an unsupported schema version: \(schema)"
        case .ioFailure(let reason):
            return "The building project filesystem operation failed: \(reason)"
        }
    }
}
