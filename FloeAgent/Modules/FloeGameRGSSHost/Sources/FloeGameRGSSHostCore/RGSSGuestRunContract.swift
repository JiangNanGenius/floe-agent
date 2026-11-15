// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore
import FloeGameIDEBridge
import FloeGameRGSS
import FloeGameRunKit

/// Stable host-facing error surface for the RGSS guest route. Every case is
/// actionable; no case is a placeholder for "the engine may work".
public enum RGSSGuestRunError: Error, Equatable, Sendable {
    case invalidEngine(GameEngineID)
    case missingEnvironment
    case invalidRequest(String)
    case engineMismatch(detected: GameEngineID, requested: GameEngineID)
    case sourceRootUnavailable(String)
    case sourceLimitExceeded(String)
    case unsafeSourceEntry(String)
    case sourceChangedDuringPreparation
    case runLayerViolation(String)
    case saveLayerViolation(String)
    case stagedRunMissing
    case sessionNotActive
    case staleSession
    case stopUnconfirmed(String)
    case saveLimitExceeded(String)
    case invalidSaveName(String)
    case saveBytesMismatch(String)
    case saveCheckpointUnsupported
    case saveCheckpointMissing
    case saveCheckpointCorrupt(String)
    case saveCheckpointDuplicateName(String)
    case saveDuplicateName(String)
    case saveDestinationExists(String)
    case savePreconditionFailed(String)
    case saveInsufficientSpace(required: Int, available: Int)
    case saveTransactionRecoveryRequired(String)
    case saveRenameRetryRequired(source: String, destination: String)
    case saveRawBackupMissing(UUID)
    case saveRawBackupMissingForName(String)
    case saveRawBackupCorrupt(String)
    case developerOverlayUnsupported(String)
    case developerOverlayMissing
    case engineInstallMissing(String)
    case engineInstallInvalid(String)
    case displayUnavailable(String)
    case inputUnavailable(String)
    case jobIdentityMismatch
}

extension RGSSGuestRunError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidEngine(let engine):
            return "\(engine.rawValue) has no RGSS guest runtime."
        case .missingEnvironment:
            return "Select a resolved Linux environment before running this game."
        case .invalidRequest(let detail):
            return "The game run request is invalid: \(detail)"
        case .engineMismatch(let detected, let requested):
            return "This project is \(detected.rawValue), not \(requested.rawValue). Choose the detected engine or explicitly override the engine."
        case .sourceRootUnavailable(let detail):
            return "The game source is unavailable: \(detail)"
        case .sourceLimitExceeded(let detail):
            return "The game source exceeds the run limits: \(detail)"
        case .unsafeSourceEntry(let path):
            return "The game source contains a symbolic link or unsupported file: \(path)"
        case .sourceChangedDuringPreparation:
            return "The game source changed while the run was being prepared. Save and run again."
        case .runLayerViolation(let detail):
            return "The run layer is not safe: \(detail)"
        case .saveLayerViolation(let detail):
            return "The save layer is not safe: \(detail)"
        case .stagedRunMissing:
            return "The game run copy is missing. Prepare the run again."
        case .sessionNotActive:
            return "This game session is no longer active."
        case .staleSession:
            return "A newer game run replaced this session."
        case .stopUnconfirmed(let detail):
            return "The game process stop could not be confirmed: \(detail)"
        case .saveLimitExceeded(let detail):
            return "The game save exceeds the configured limit: \(detail)"
        case .invalidSaveName(let name):
            return "The save file name is not a standard RGSS save: \(name)"
        case .saveBytesMismatch(let name):
            return "The save file changed while it was read: \(name)"
        case .saveCheckpointUnsupported:
            return "Checkpoint storage is not configured for this save layer."
        case .saveCheckpointMissing:
            return "No save checkpoint exists for this game."
        case .saveCheckpointCorrupt(let detail):
            return "The save checkpoint is damaged: \(detail)"
        case .saveCheckpointDuplicateName(let name):
            return "The save checkpoint contains the same file name more than once: \(name)"
        case .saveDuplicateName(let name):
            return "More than one save file resolves to the same name: \(name)"
        case .saveDestinationExists(let name):
            return "A save file already exists: \(name). Choose an explicit replace or a different name."
        case .savePreconditionFailed(let detail):
            return "The save precondition no longer matches: \(detail)"
        case .saveInsufficientSpace(let required, let available):
            return "The save layer needs \(required) bytes but only \(available) bytes are available."
        case .saveTransactionRecoveryRequired(let detail):
            return "A previous save update needs recovery: \(detail). No ambiguous bytes were deleted."
        case .saveRenameRetryRequired(let source, let destination):
            return "Both \(source) and \(destination) exist with identical bytes. Repeat the rename to finish it."
        case .saveRawBackupMissing(let id):
            return "The retained save backup \(id.uuidString.lowercased()) no longer exists."
        case .saveRawBackupMissingForName(let name):
            return "No retained save backup exists for \(name)."
        case .saveRawBackupCorrupt(let detail):
            return "The retained save backup is damaged: \(detail)"
        case .developerOverlayUnsupported(let detail):
            return "Development controls are unavailable for this project: \(detail)"
        case .developerOverlayMissing:
            return "The Floe developer overlay is not installed in this run copy. Install it explicitly; the imported source stays unchanged."
        case .engineInstallMissing(let detail):
            return "The reviewed RGSS guest engine is not installed in this environment: \(detail)"
        case .engineInstallInvalid(let detail):
            return "The installed RGSS guest engine failed preflight: \(detail)"
        case .displayUnavailable(let detail):
            return "The local Linux display is unavailable: \(detail)"
        case .inputUnavailable(let detail):
            return "The game input service is unavailable: \(detail)"
        case .jobIdentityMismatch:
            return "The guest job identity changed; the owned job was stopped."
        }
    }
}

/// One concrete run of one selected project root with one RGSS generation.
/// All identity comes from the host's existing workspace/context service; a
/// project file can never create this value.
public struct RGSSGuestRunRequest: Sendable, Equatable {
    public let id: UUID
    public let workspaceID: UUID
    public let context: GameProjectContext
    public let engine: GameEngineID
    /// "." or a validated nested relative root inside `context.rootURL`.
    public let rootRelative: String
    public let displayServiceID: String
    /// Only an explicit user choice may run a project whose marker names a
    /// different RGSS generation. AI recommendations never set this.
    public let engineOverride: Bool

    public init(
        id: UUID = UUID(),
        workspaceID: UUID,
        context: GameProjectContext,
        engine: GameEngineID,
        rootRelative: String = ".",
        displayServiceID: String,
        engineOverride: Bool = false
    ) throws {
        guard RGSSEngineProfiles.isRGSS(engine) else {
            throw RGSSGuestRunError.invalidEngine(engine)
        }
        guard let environmentID = context.environmentID,
              !environmentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RGSSGuestRunError.missingEnvironment
        }
        let trimmedDisplay = displayServiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDisplay.isEmpty, trimmedDisplay.utf8.count <= 256 else {
            throw RGSSGuestRunError.invalidRequest("display service identity")
        }
        if case .conversation(_, let ownedWorkspace) = context.owner,
           ownedWorkspace != workspaceID {
            throw RGSSGuestRunError.invalidRequest("workspace pin")
        }
        // Reuses the existing selection validation (relative root, revision).
        _ = try GameRunSelection(context: context, root: rootRelative)
        self.id = id
        self.workspaceID = workspaceID
        self.context = context
        self.engine = engine
        self.rootRelative = rootRelative
        self.displayServiceID = trimmedDisplay
        self.engineOverride = engineOverride
    }

    /// Consumes the existing whole-project IDE dispatch request. The caller
    /// supplies the display generation it acquired from the local display
    /// owner; this type never resolves a display by itself.
    public init(
        ideRequest: GameIDEProjectRunRequest,
        displayServiceID: String,
        engineOverride: Bool = false
    ) throws {
        try self.init(
            id: ideRequest.id,
            workspaceID: ideRequest.workspace.workspaceID,
            context: ideRequest.context,
            engine: ideRequest.engine,
            rootRelative: ideRequest.gameRoot?.value ?? ".",
            displayServiceID: displayServiceID,
            engineOverride: engineOverride
        )
        try ideRequest.workspace.validate(context: ideRequest.context)
    }

    /// The saved revision and root are captured once; every later stage uses
    /// the frozen context, never the current workspace default.
    public var selection: GameRunSelection {
        try! GameRunSelection(context: context, root: rootRelative)
    }

    public var environmentID: String {
        context.environmentID!
    }

    public func validate(current: GameProjectContext) throws {
        do {
            try context.validate(current: current)
        } catch {
            throw RGSSGuestRunError.invalidRequest("project context changed")
        }
        guard let currentEnvironment = current.environmentID,
              currentEnvironment == environmentID else {
            throw RGSSGuestRunError.invalidRequest("environment changed")
        }
    }
}

/// Read-only planning result. It proves only that the selected root contains a
/// recognizable RGSS project and that the requested generation matches (or the
/// user explicitly overrode it). It is not a play claim.
public struct RGSSGuestRunPlan: Sendable, Equatable {
    public let request: RGSSGuestRunRequest
    public let version: RGSSVersion
    public let profile: RGSSEngineProfile
    public let selectedRoot: URL
    public let sourceDigest: String
    public let inspection: RGSSProjectInspection
    public let routeID: String
    public let prerequisites: [GameRunPrerequisite]
    public let notes: [String]

    public init(
        request: RGSSGuestRunRequest,
        version: RGSSVersion,
        profile: RGSSEngineProfile,
        selectedRoot: URL,
        sourceDigest: String,
        inspection: RGSSProjectInspection,
        routeID: String,
        prerequisites: [GameRunPrerequisite],
        notes: [String]
    ) {
        self.request = request
        self.version = version
        self.profile = profile
        self.selectedRoot = selectedRoot
        self.sourceDigest = sourceDigest
        self.inspection = inspection
        self.routeID = routeID
        self.prerequisites = prerequisites
        self.notes = notes
    }
}

/// Read-only route result for XP/VX/VX Ace. It is the guest counterpart of a
/// `GameRunRoutePlan` and can be produced before any display or job starts.
public struct RGSSGuestRoutePlan: Sendable, Equatable {
    public let context: GameProjectContext
    public let engine: GameEngineID
    public let rootRelative: String
    public let engineOverride: Bool
    public let version: RGSSVersion
    public let profile: RGSSEngineProfile
    public let selectedRoot: URL
    public let sourceDigest: String
    public let inspection: RGSSProjectInspection
    public let routeID: String
    public let notes: [String]

    public init(
        context: GameProjectContext,
        engine: GameEngineID,
        rootRelative: String,
        engineOverride: Bool,
        version: RGSSVersion,
        profile: RGSSEngineProfile,
        selectedRoot: URL,
        sourceDigest: String,
        inspection: RGSSProjectInspection,
        routeID: String,
        notes: [String]
    ) {
        self.context = context
        self.engine = engine
        self.rootRelative = rootRelative
        self.engineOverride = engineOverride
        self.version = version
        self.profile = profile
        self.selectedRoot = selectedRoot
        self.sourceDigest = sourceDigest
        self.inspection = inspection
        self.routeID = routeID
        self.notes = notes
    }
}

/// One owned run copy plus its separate save/home/log layers. The source root
/// and the run root are never the same directory and neither is inside the
/// other. Save bytes live in `saveRoot`, not in the imported source.
public struct RGSSGuestStagedRun: Sendable, Equatable {
    public let request: RGSSGuestRunRequest
    public let plan: RGSSGuestRunPlan
    public let selectedRoot: URL
    public let sourceRoot: URL
    public let sourceDigest: String
    public let runRoot: URL
    public let saveRoot: URL
    public let homeRoot: URL
    public let logFile: URL
    public let importedSaveNames: [String]
    public let stagedAt: Date

    public init(
        request: RGSSGuestRunRequest,
        plan: RGSSGuestRunPlan,
        selectedRoot: URL,
        sourceRoot: URL,
        sourceDigest: String,
        runRoot: URL,
        saveRoot: URL,
        homeRoot: URL,
        logFile: URL,
        importedSaveNames: [String],
        stagedAt: Date = Date()
    ) {
        self.request = request
        self.plan = plan
        self.selectedRoot = selectedRoot
        self.sourceRoot = sourceRoot
        self.sourceDigest = sourceDigest
        self.runRoot = runRoot
        self.saveRoot = saveRoot
        self.homeRoot = homeRoot
        self.logFile = logFile
        self.importedSaveNames = importedSaveNames
        self.stagedAt = stagedAt
    }

    /// A stale run copy can be detected before touching a new one.
    public func isStillCurrent(sourceDigest: String, revision: String) -> Bool {
        sourceDigest == self.sourceDigest && revision == request.context.savedRevision
    }
}

/// One standard save file found in the owned save layer.
public struct RGSSGuestSaveDescriptor: Sendable, Equatable, Identifiable {
    public let name: String
    public let bytes: Int
    public let sha256: String
    public let modifiedAt: Date?
    public var id: String { name }

    public init(name: String, bytes: Int, sha256: String, modifiedAt: Date?) {
        self.name = name
        self.bytes = bytes
        self.sha256 = sha256
        self.modifiedAt = modifiedAt
    }
}

/// Result of importing/collecting standard saves. `skipped` is non-empty only
/// for names that are not standard RGSS save files; nothing is silently
/// rewritten under a different name.
public struct RGSSGuestSaveCollection: Sendable, Equatable {
    public let names: [String]
    public let bytes: Int
    public let digests: [String: String]
    public let skipped: [String]

    public init(names: [String], bytes: Int, digests: [String: String], skipped: [String]) {
        self.names = names
        self.bytes = bytes
        self.digests = digests
        self.skipped = skipped
    }

    public static let empty = RGSSGuestSaveCollection(names: [], bytes: 0, digests: [:], skipped: [])
}

public enum RGSSGuestSaveLimits {
    public static let maximumFiles = 64
    public static let maximumFileBytes = 16 * 1_024 * 1_024
    public static let maximumTotalBytes = 128 * 1_024 * 1_024
    public static let maximumSaveNameBytes = 128

    public static func isValidSaveName(_ name: String, engine: GameEngineID) -> Bool {
        guard name.utf8.count <= maximumSaveNameBytes,
              !name.contains("/"), !name.contains("\\"), !name.contains("..") else {
            return false
        }
        let lower = name.lowercased()
        let expected: String
        switch engine {
        case .rpgMakerXP: expected = ".rxdata"
        case .rpgMakerVX: expected = ".rvdata"
        case .rpgMakerVXAce: expected = ".rvdata2"
        default: return false
        }
        return lower.hasPrefix("save") && lower.hasSuffix(expected)
    }
}

/// An import is never a silent overwrite. The caller chooses rejection, a CAS
/// replace against the exact current digest, or a replace that first writes a
/// verified raw backup outside the save root.
///
/// `.replaceKeepingBackup` is the unconditional form retained for explicit
/// callers. A UI row chosen before a confirmation alert must use
/// `.replaceKeepingBackupVerified(expectedSHA256:)` (or
/// `importFile(from:expectedSHA256:keepBackup:true)`) so a stale row cannot
/// replace bytes that changed after the row was displayed. Both forms keep the
/// previous bytes as a retained raw backup; neither depends on the 4 MiB
/// whole-checkpoint envelope.
public enum RGSSGuestSaveImportPolicy: Sendable, Equatable {
    case rejectExisting
    case replace(expectedSHA256: String)
    case replaceKeepingBackup
    case replaceKeepingBackupVerified(expectedSHA256: String)
}

public enum RGSSGuestSaveMutationOutcome: String, Sendable, Equatable {
    case committed
    case alreadySatisfied
    case requiresRetry
}

/// Truthful result of a save mutation. `inventory` is the standard-save
/// inventory after the operation (or the unchanged inventory for
/// `.alreadySatisfied`). `preservedNames` and `unchangedNames` distinguish
/// unrelated slots from requested files whose bytes were already correct.
public struct RGSSGuestSaveMutationReceipt: Sendable, Equatable {
    public let outcome: RGSSGuestSaveMutationOutcome
    public let operation: String
    public let transactionID: UUID?
    public let createdNames: [String]
    public let replacedNames: [String]
    public let removedNames: [String]
    public let unchangedNames: [String]
    public let preservedNames: [String]
    public let inventory: [RGSSGuestSaveDescriptor]
    public let checkpointRevision: UInt64?
    public let backupDirectory: URL?
    public let rawBackupID: UUID?
    public let message: String?

    public init(outcome: RGSSGuestSaveMutationOutcome,
                operation: String,
                transactionID: UUID? = nil,
                createdNames: [String] = [],
                replacedNames: [String] = [],
                removedNames: [String] = [],
                unchangedNames: [String] = [],
                preservedNames: [String] = [],
                inventory: [RGSSGuestSaveDescriptor] = [],
                checkpointRevision: UInt64? = nil,
                backupDirectory: URL? = nil,
                rawBackupID: UUID? = nil,
                message: String? = nil) {
        self.outcome = outcome
        self.operation = operation
        self.transactionID = transactionID
        self.createdNames = createdNames
        self.replacedNames = replacedNames
        self.removedNames = removedNames
        self.unchangedNames = unchangedNames
        self.preservedNames = preservedNames
        self.inventory = inventory
        self.checkpointRevision = checkpointRevision
        self.backupDirectory = backupDirectory
        self.rawBackupID = rawBackupID
        self.message = message
    }

    public var changedNames: [String] {
        createdNames + replacedNames + removedNames
    }
}

/// One retained raw replacement backup. `id` is stable for the UI and can be
/// passed to `restoreRawBackup(id:expectedSHA256:)`. `backupDirectory` in a
/// receipt is diagnostic only; use this descriptor for a user-facing restore.
public struct RGSSGuestSaveRawBackupDescriptor: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let bytes: Int
    public let sha256: String
    public let createdAt: Date

    public init(id: UUID, name: String, bytes: Int, sha256: String, createdAt: Date) {
        self.id = id
        self.name = name
        self.bytes = bytes
        self.sha256 = sha256
        self.createdAt = createdAt
    }
}

public struct RGSSGuestSaveSnapshotFile: Sendable, Equatable {
    public let descriptor: RGSSGuestSaveDescriptor
    public let data: Data

    public init(descriptor: RGSSGuestSaveDescriptor, data: Data) {
        self.descriptor = descriptor
        self.data = data
    }
}

public enum RGSSGuestCheckpointAvailability: Sendable, Equatable {
    case supported
    case unsupported(String)
}

/// Source-tree limits used for the run copy and digest. They are deliberately
/// independent from the edit repository limits: imported originals may be
/// larger than a live Web artifact but still must be bounded.
public struct RGSSGuestTreeLimits: Sendable, Equatable {
    public let maximumEntries: Int
    public let maximumDepth: Int
    public let maximumFileBytes: Int
    public let maximumTotalBytes: Int

    public init(
        maximumEntries: Int = 20_000,
        maximumDepth: Int = 32,
        maximumFileBytes: Int = 256 * 1_024 * 1_024,
        maximumTotalBytes: Int = 1_024 * 1_024 * 1_024
    ) throws {
        guard (1...100_000).contains(maximumEntries),
              (1...32).contains(maximumDepth),
              (1...256 * 1_024 * 1_024).contains(maximumFileBytes),
              maximumTotalBytes >= maximumFileBytes,
              maximumTotalBytes <= 1_024 * 1_024 * 1_024 else {
            throw RGSSGuestRunError.invalidRequest("tree limits")
        }
        self.maximumEntries = maximumEntries
        self.maximumDepth = maximumDepth
        self.maximumFileBytes = maximumFileBytes
        self.maximumTotalBytes = maximumTotalBytes
    }

    public static let `default` = try! RGSSGuestTreeLimits()
}
