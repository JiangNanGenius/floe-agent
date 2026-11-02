// SPDX-License-Identifier: MPL-2.0
//
// C02 — durable task continuity: recoverable storage pause and ONE
// canonical task/run wait identity for questions and approvals.
//
// This file owns the typed domain, the declarative schema and the original
// authorities used by the trusted-host `floe.continuity/21` channel.
//
// Invariants (audited against the existing Android implementation first):
//   * The original `UserQuestionStore` / `UserQuestionCoordinator` remains
//     the ONLY question store and answer settlement path. This module never
//     inserts a question, answer, draft or deadline row.
//   * Approvals remain owned by `AgentRuntime`/`ConversationRunService` and
//     the original `run.approval.resolve` CAS. This module only derives a
//     read-only pending identity from the durable run thread; it never
//     grants, denies, replays or auto-answers an approval.
//   * A canonical wait identity is derived from the ACTUAL root generation,
//     task, run, tool call and request/item identity. Questions and
//     approvals share that identity shape, but the store/authority stays the
//     original one. No second question/approval registry exists here.
//   * A storage pause is a durable, nonsecret marker over the ORIGINAL
//     task/run/target ownership plus a best-effort park of the live run
//     through the original `ConversationRunService` checkpoint path. When
//     the task database itself is unreachable, only a bounded recovery
//     metadata sidecar (IDs/reason/timestamps, never user content) is used.
//   * Resume is explicit, validated and claimed exactly once. It never
//     re-executes a command or replays a provider request: it delegates to
//     the existing `run.retry` checkpoint/history resume, whose own
//     interrupted-dispatch policy keeps unknown remote/mutation outcomes
//     unknown.
//   * Temporary chats never get a durable pause marker, wait snapshot or
//     recovery sidecar. A missing durable conversation row is refused.
//
// Source-only: Main registers the coordinated schema fragment (current 51,
// next 52) once and applies the central patches in the handoff package.
import Foundation
import GRDB
import FloeCore
import FloeModels
import FloePersistence

// MARK: - Wire constants

public enum C02TaskContinuityWire {
    /// Reserved trusted-host channel (BRIDGE_CHANNEL_RESERVATIONS 21).
    /// Main owns the C ABI / `Bridge.swift` branch.
    public static let version = 21
    public static let schema = "floe.continuity/21"
    public static let maximumRequestBytes = 65_536
    public static let maximumResponseBytes = 48 * 1_024
    public static let maximumIdentifierBytes = 160
    public static let maximumPromptBytes = 2_048
    public static let maximumWaits = 16
    public static let maximumRunHistoryEvents = 256
    /// A `resumeInProgress` marker older than this is reconciled against the
    /// durable run state instead of blocking the task forever after a
    /// process death during resume.
    public static let resumingStaleSeconds: TimeInterval = 60
    /// Refuse to resume onto a volume with less important-usage headroom.
    public static let minimumResumeFreeBytes: Int64 = 8 * 1_024 * 1_024
    public static var modelTools: Bool { false }
}

// MARK: - Errors

public enum C02TaskContinuityError: Error, Sendable, Equatable {
    case invalidRequest(String)
    case notInstalled
    case unsupportedOperation
    case taskNotFound
    case runNotFound
    case temporaryTaskRefused
    case rootEpochUnavailable
    case rootIdentityMismatch
    case schemaUnavailable
    case storeUnavailable(String)
    case storageUnavailable(TaskContinuityStorageCondition)
    case pauseNotFound
    case pauseAlreadyResolved
    case resumeInProgress
    case recoveryMetadataUnavailable(String)
    case waitUnavailable(String)

    /// Stable machine-facing reason used by the trusted-host wire. Never
    /// includes a path, question/approval text, provider prose or secret.
    public var code: String {
        switch self {
        case .invalidRequest(let reason): return "invalidRequest:\(reason)"
        case .notInstalled: return "notInstalled"
        case .unsupportedOperation: return "unsupportedOperation"
        case .taskNotFound: return "taskNotFound"
        case .runNotFound: return "runNotFound"
        case .temporaryTaskRefused: return "temporaryTaskRefused"
        case .rootEpochUnavailable: return "rootEpochUnavailable"
        case .rootIdentityMismatch: return "rootIdentityMismatch"
        case .schemaUnavailable: return "schemaUnavailable"
        case .storeUnavailable(let code): return "storeUnavailable:\(code)"
        case .storageUnavailable(let condition): return "storageUnavailable:\(condition.rawValue)"
        case .pauseNotFound: return "pauseNotFound"
        case .pauseAlreadyResolved: return "pauseAlreadyResolved"
        case .resumeInProgress: return "resumeInProgress"
        case .recoveryMetadataUnavailable(let code): return "recoveryMetadataUnavailable:\(code)"
        case .waitUnavailable(let code): return "waitUnavailable:\(code)"
        }
    }

    public var message: String {
        switch self {
        case .invalidRequest(let reason):
            return "The continuity request is invalid (\(reason))."
        case .notInstalled:
            return "Task continuity is not bound for this runtime generation."
        case .unsupportedOperation:
            return "This continuity operation is not supported."
        case .taskNotFound:
            return "This task no longer exists."
        case .runNotFound:
            return "This run no longer exists."
        case .temporaryTaskRefused:
            return "Temporary chats cannot persist continuity state."
        case .rootEpochUnavailable:
            return "The native runtime generation is not active."
        case .rootIdentityMismatch:
            return "This pause belongs to a different app-data root."
        case .schemaUnavailable:
            return "The task-continuity schema is not installed in this build."
        case .storeUnavailable:
            return "The task continuity store is unavailable."
        case .storageUnavailable(let condition):
            return condition.pauseReason?.message
                ?? "Storage is not available yet."
        case .pauseNotFound:
            return "No storage pause is recorded for this task."
        case .pauseAlreadyResolved:
            return "This pause was already resumed."
        case .resumeInProgress:
            return "This task is already resuming."
        case .recoveryMetadataUnavailable:
            return "Neither the task database nor the recovery metadata is writable."
        case .waitUnavailable:
            return "Pending questions or approvals could not be read."
        }
    }

    public var retryable: Bool {
        switch self {
        case .rootEpochUnavailable, .storageUnavailable, .resumeInProgress,
             .storeUnavailable, .recoveryMetadataUnavailable, .waitUnavailable:
            return true
        default:
            return false
        }
    }
}

// MARK: - Storage health

public enum TaskContinuityStorageCondition: String, Codable, Sendable, CaseIterable {
    case ready
    case permissionRevoked
    case volumeMissing
    case volumeReadOnly
    case volumeFull
    case databaseUnavailable
    case unknown

    public var isReady: Bool { self == .ready }

    /// The durable pause reason for a non-ready condition. `ready` and
    /// `unknown` have no pause reason on their own (`unknown` must never be
    /// presented as a storage failure the engine actually proved).
    public var pauseReason: TaskContinuityPauseReason? {
        switch self {
        case .permissionRevoked: return .permissionRevoked
        case .volumeMissing: return .volumeMissing
        case .volumeReadOnly: return .volumeReadOnly
        case .volumeFull: return .volumeFull
        case .databaseUnavailable: return .databaseUnavailable
        case .ready, .unknown: return nil
        }
    }
}

public enum TaskContinuityPauseReason: String, Codable, Sendable, CaseIterable {
    case permissionRevoked
    case volumeMissing
    case volumeReadOnly
    case volumeFull
    case databaseUnavailable

    public var message: String {
        switch self {
        case .permissionRevoked:
            return "Storage access was revoked. Restore access, then resume this task."
        case .volumeMissing:
            return "The task storage volume is missing. Reconnect it, then resume this task."
        case .volumeReadOnly:
            return "Task storage became read-only. Restore write access, then resume this task."
        case .volumeFull:
            return "Task storage is full. Free space, then resume this task."
        case .databaseUnavailable:
            return "The task database is unavailable. Restore it, then resume this task."
        }
    }
}

public struct TaskContinuityStorageStatus: Sendable, Equatable {
    public var condition: TaskContinuityStorageCondition
    public var checkedAt: Date
    public var availableBytes: Int64?
    public var detailCode: String?

    public init(
        condition: TaskContinuityStorageCondition,
        checkedAt: Date = Date(),
        availableBytes: Int64? = nil,
        detailCode: String? = nil
    ) {
        self.condition = condition
        self.checkedAt = checkedAt
        self.availableBytes = availableBytes
        self.detailCode = detailCode
    }

    public static func ready(at date: Date = Date()) -> TaskContinuityStorageStatus {
        TaskContinuityStorageStatus(condition: .ready, checkedAt: date)
    }

    public var isReady: Bool { condition.isReady }
}

/// Production storage probe over the ONE original database and the accepted
/// app-private root. It performs only a read plus filesystem metadata reads:
/// no migration, no second database, no content and no write probe.
public struct TaskContinuityRootStorageProbe: TaskContinuityStorageProbing {
    private let database: DatabaseManager?
    private let rootURL: URL?
    private let minimumFreeBytes: Int64

    public init(
        database: DatabaseManager?,
        rootURL: URL?,
        minimumFreeBytes: Int64 = C02TaskContinuityWire.minimumResumeFreeBytes
    ) {
        self.database = database
        self.rootURL = rootURL
        self.minimumFreeBytes = minimumFreeBytes
    }

    public func probe() async -> TaskContinuityStorageStatus {
        let now = Date()
        if let database {
            do {
                _ = try await database.reader { db in
                    try Int.fetchOne(db, sql: "SELECT 1")
                }
            } catch {
                let condition = TaskContinuityStorageClassifier.condition(for: error)
                    ?? .databaseUnavailable
                return TaskContinuityStorageStatus(
                    condition: condition,
                    checkedAt: now,
                    detailCode: "databaseRead")
            }
        }
        if let rootURL {
            let manager = FileManager.default
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return TaskContinuityStorageStatus(
                    condition: .volumeMissing,
                    checkedAt: now,
                    detailCode: "rootMissing")
            }
            guard manager.isWritableFile(atPath: rootURL.path) else {
                return TaskContinuityStorageStatus(
                    condition: .volumeReadOnly,
                    checkedAt: now,
                    detailCode: "rootReadOnly")
            }
            let attributes = try? manager.attributesOfFileSystem(forPath: rootURL.path)
            let available = (attributes?[.systemFreeSize] as? NSNumber)?.int64Value
            if let available, available >= 0, available < minimumFreeBytes {
                return TaskContinuityStorageStatus(
                    condition: .volumeFull,
                    checkedAt: now,
                    availableBytes: available,
                    detailCode: "capacityLow")
            }
            return TaskContinuityStorageStatus(
                condition: .ready,
                checkedAt: now,
                availableBytes: available)
        }
        return TaskContinuityStorageStatus(condition: .ready, checkedAt: now)
    }
}

public protocol TaskContinuityStorageProbing: Sendable {
    func probe() async -> TaskContinuityStorageStatus
}

/// Maps real storage errors to a nonsecret condition. Only conditions that
/// the ORIGINAL error actually proves are returned; unknown failures stay
/// `nil` so they are never presented as a storage pause.
public enum TaskContinuityStorageClassifier {
    public static func condition(for error: Error) -> TaskContinuityStorageCondition? {
        if let databaseError = error as? DatabaseError {
            let primary = Int(databaseError.resultCode.rawValue) & 0xff
            switch primary {
            case 13: return .volumeFull
            case 8: return .volumeReadOnly
            case 14: return .volumeMissing
            case 10, 11, 26: return .databaseUnavailable
            default: break
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            switch Int32(nsError.code) {
            case 1, 13: return .permissionRevoked
            case 2, 6, 19: return .volumeMissing
            case 28, 69: return .volumeFull
            case 30: return .volumeReadOnly
            case 5, 9, 12: return .databaseUnavailable
            default: break
            }
        }
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                return .permissionRevoked
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                return .volumeMissing
            case NSFileWriteOutOfSpaceError:
                return .volumeFull
            case NSFileWriteVolumeReadOnlyError:
                return .volumeReadOnly
            default: break
            }
        }
        if let floe = error as? FloeError, case .storageCorrupted(let detail) = floe {
            let lowered = detail.lowercased()
            if lowered.contains("read-only") || lowered.contains("readonly") {
                return .volumeReadOnly
            }
            if lowered.contains("no space") || lowered.contains("disk full")
                || lowered.contains("full") {
                return .volumeFull
            }
            if lowered.contains("unable to open") || lowered.contains("missing") {
                return .volumeMissing
            }
            if lowered.contains("database") || lowered.contains("disk i/o")
                || lowered.contains("corrupt") {
                return .databaseUnavailable
            }
        }
        return nil
    }
}

// MARK: - Root identity

public enum TaskContinuityRootFingerprint {
    /// Nonsecret durable root identity used across app generations. The
    /// process-local owner token never enters the marker; the native epoch is
    /// stored separately for the same-generation callback fence.
    public static func make(rootPath: String) -> String {
        let normalized = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        return FloeDigest.sha256Hex(Data(normalized.utf8))
    }

    public static func isValid(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy {
            $0.isHexDigit && (!$0.isLetter || $0.isLowercase)
        }
    }
}

// MARK: - Durable pause marker

public enum TaskContinuityPauseState: String, Codable, Sendable, CaseIterable {
    /// The marker is durable and the task cannot admit new work until the
    /// user explicitly resumes after storage recovers.
    case awaitingStorageRecovery
    /// One explicit resume claimed the marker. A duplicate tap/restart sees
    /// this state and never starts a second launch.
    case resumeInProgress
    /// The explicit resume refused before any dispatch. The marker stays
    /// actionable; a later validated attempt is a new claim.
    case resumeFailed
    /// The explicit resume was handed to the original run resume path.
    case resumed
}

public enum TaskContinuityPauseDurability: String, Codable, Sendable, CaseIterable {
    /// Persisted in the coordinated task-database table (Main v52).
    case taskDatabase
    /// The task database was unreachable; only the bounded nonsecret
    /// recovery metadata sidecar was writable.
    case recoveryMetadata
    /// Neither durable medium was writable in this process. The marker is
    /// honest RAM-only state and is reported as such.
    case memoryOnly
}

public struct TaskContinuityPauseMarker: Codable, Sendable, Hashable, Identifiable {
    public static let schema = "floe.continuity.pause.v1"

    public var schema: String
    public var markerID: String

    public var id: String { markerID }
    public var taskID: UUID
    public var runID: UUID
    /// Native root generation that observed the failure.
    public var rootEpoch: UInt64
    /// Durable app-data root identity (never a token or path).
    public var rootFingerprint: String
    public var reason: TaskContinuityPauseReason
    public var state: TaskContinuityPauseState
    public var durability: TaskContinuityPauseDurability
    public var detectedAt: Date
    public var updatedAt: Date
    public var resumeAttempt: Int
    /// Exact C02 run pin captured at pause time (nil when the task never
    /// pinned a target). Resume refuses a changed revision/identity.
    public var targetRevision: Int64?
    public var targetRootEpoch: UInt64?
    public var environmentID: String?
    public var workspaceID: UUID?
    public var shellRootHash: String?
    public var engineOwnerHash: String?
    /// The live run was parked on the ORIGINAL checkpoint path (or was
    /// already terminal when the failure was observed).
    public var runCheckpointed: Bool
    /// Bounded count only — never remote output or command text.
    public var unknownOutcomeCount: Int
    /// True exactly when no automatic resume is permitted.
    public var explicitResumeOnly: Bool
    public var detailCode: String?

    public init(
        schema: String = TaskContinuityPauseMarker.schema,
        markerID: String,
        taskID: UUID,
        runID: UUID,
        rootEpoch: UInt64,
        rootFingerprint: String,
        reason: TaskContinuityPauseReason,
        state: TaskContinuityPauseState = .awaitingStorageRecovery,
        durability: TaskContinuityPauseDurability,
        detectedAt: Date,
        updatedAt: Date,
        resumeAttempt: Int = 0,
        targetRevision: Int64? = nil,
        targetRootEpoch: UInt64? = nil,
        environmentID: String? = nil,
        workspaceID: UUID? = nil,
        shellRootHash: String? = nil,
        engineOwnerHash: String? = nil,
        runCheckpointed: Bool = false,
        unknownOutcomeCount: Int = 0,
        explicitResumeOnly: Bool = true,
        detailCode: String? = nil
    ) {
        self.schema = schema
        self.markerID = markerID
        self.taskID = taskID
        self.runID = runID
        self.rootEpoch = rootEpoch
        self.rootFingerprint = rootFingerprint
        self.reason = reason
        self.state = state
        self.durability = durability
        self.detectedAt = detectedAt
        self.updatedAt = updatedAt
        self.resumeAttempt = resumeAttempt
        self.targetRevision = targetRevision
        self.targetRootEpoch = targetRootEpoch
        self.environmentID = environmentID
        self.workspaceID = workspaceID
        self.shellRootHash = shellRootHash
        self.engineOwnerHash = engineOwnerHash
        self.runCheckpointed = runCheckpointed
        self.unknownOutcomeCount = unknownOutcomeCount
        self.explicitResumeOnly = explicitResumeOnly
        self.detailCode = detailCode
    }

    public var isActionable: Bool {
        state == .awaitingStorageRecovery || state == .resumeFailed
    }

    public func validate() throws {
        guard schema == Self.schema else {
            throw C02TaskContinuityError.invalidRequest("markerSchema")
        }
        guard TaskContinuityPauseMarker.isIdentifier(markerID) else {
            throw C02TaskContinuityError.invalidRequest("markerID")
        }
        guard rootEpoch > 0 else {
            throw C02TaskContinuityError.invalidRequest("rootEpoch")
        }
        guard TaskContinuityRootFingerprint.isValid(rootFingerprint) else {
            throw C02TaskContinuityError.invalidRequest("rootFingerprint")
        }
        guard (0...1_000).contains(resumeAttempt) else {
            throw C02TaskContinuityError.invalidRequest("resumeAttempt")
        }
        if let targetRevision {
            guard targetRevision > 0 else {
                throw C02TaskContinuityError.invalidRequest("targetRevision")
            }
        }
        if let targetRootEpoch {
            guard targetRootEpoch > 0 else {
                throw C02TaskContinuityError.invalidRequest("targetRootEpoch")
            }
        }
        if let environmentID {
            guard TaskContinuityPauseMarker.isIdentifier(environmentID) else {
                throw C02TaskContinuityError.invalidRequest("environmentID")
            }
        }
        if let shellRootHash {
            guard TaskContinuityRootFingerprint.isValid(shellRootHash) else {
                throw C02TaskContinuityError.invalidRequest("shellRootHash")
            }
        }
        if let engineOwnerHash {
            guard TaskContinuityRootFingerprint.isValid(engineOwnerHash) else {
                throw C02TaskContinuityError.invalidRequest("engineOwnerHash")
            }
        }
        guard (0...10_000).contains(unknownOutcomeCount) else {
            throw C02TaskContinuityError.invalidRequest("unknownOutcomeCount")
        }
        guard explicitResumeOnly else {
            throw C02TaskContinuityError.invalidRequest("explicitResumeOnly")
        }
        if let detailCode {
            guard TaskContinuityPauseMarker.isIdentifier(detailCode) else {
                throw C02TaskContinuityError.invalidRequest("detailCode")
            }
        }
    }

    public static func isIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= C02TaskContinuityWire.maximumIdentifierBytes else {
            return false
        }
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.:")
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && allowed.contains(scalar)
        }
    }
}

public struct TaskContinuityPauseReceipt: Sendable, Equatable {
    public var marker: TaskContinuityPauseMarker
    public var runCheckpointed: Bool
    public var storage: TaskContinuityStorageStatus

    public init(
        marker: TaskContinuityPauseMarker,
        runCheckpointed: Bool,
        storage: TaskContinuityStorageStatus
    ) {
        self.marker = marker
        self.runCheckpointed = runCheckpointed
        self.storage = storage
    }
}

// MARK: - Canonical task/run wait identity

public enum TaskContinuityWaitKind: String, Codable, Sendable, CaseIterable {
    case question
    case approval
}

/// ONE identity shape for both kinds. `requestID` is the question request id
/// or the approval tool-call id; `itemID` is the exact question id or the
/// approval tool-call id. The stable digest is derived only from trusted
/// identities, never from prompt text or model content.
public struct TaskContinuityWaitIdentity: Codable, Sendable, Hashable {
    public var kind: TaskContinuityWaitKind
    public var rootEpoch: UInt64
    public var rootFingerprint: String
    public var taskID: UUID
    public var runID: UUID
    public var toolCallID: String
    public var requestID: String
    public var itemID: String
    /// Question revision, or approval requestedAt milliseconds. Monotonic
    /// per exact wait generation; a stale card cannot address a newer one.
    public var revision: Int

    public init(
        kind: TaskContinuityWaitKind,
        rootEpoch: UInt64,
        rootFingerprint: String,
        taskID: UUID,
        runID: UUID,
        toolCallID: String,
        requestID: String,
        itemID: String,
        revision: Int
    ) {
        self.kind = kind
        self.rootEpoch = rootEpoch
        self.rootFingerprint = rootFingerprint
        self.taskID = taskID
        self.runID = runID
        self.toolCallID = toolCallID
        self.requestID = requestID
        self.itemID = itemID
        self.revision = revision
    }

    /// Stable nonsecret identity shared by the UI/service/callback fence.
    public var waitID: String {
        let material = [
            "floe.continuity.wait.v1",
            kind.rawValue,
            String(rootEpoch),
            rootFingerprint,
            taskID.uuidString,
            runID.uuidString,
            toolCallID,
            requestID,
            itemID,
            String(revision),
        ].joined(separator: "\u{1f}")
        return "tw_" + String(FloeDigest.sha256Hex(Data(material.utf8)).prefix(40))
    }

    public func validate() throws {
        guard rootEpoch > 0 else {
            throw C02TaskContinuityError.invalidRequest("waitRootEpoch")
        }
        guard TaskContinuityRootFingerprint.isValid(rootFingerprint) else {
            throw C02TaskContinuityError.invalidRequest("waitRootFingerprint")
        }
        guard TaskContinuityPauseMarker.isIdentifier(toolCallID) else {
            throw C02TaskContinuityError.invalidRequest("waitToolCallID")
        }
        guard TaskContinuityPauseMarker.isIdentifier(requestID) else {
            throw C02TaskContinuityError.invalidRequest("waitRequestID")
        }
        guard TaskContinuityPauseMarker.isIdentifier(itemID) else {
            throw C02TaskContinuityError.invalidRequest("waitItemID")
        }
        guard revision > 0 else {
            throw C02TaskContinuityError.invalidRequest("waitRevision")
        }
    }
}

public struct TaskContinuityWait: Sendable, Equatable {
    public var identity: TaskContinuityWaitIdentity
    public var prompt: String
    public var promptTruncated: Bool
    /// Question wait policy (`required`/`optionalContinue`/`optionalDeadline`)
    /// or `approval`. Presentation only; never an authorization input.
    public var waitPolicy: String
    /// A real live owner exists in this process. When false the durable
    /// question/approval survives, but the task must be resumed first.
    public var answerableNow: Bool
    public var requiresResume: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var deadlineAt: Date?
    /// Question-only CAS inputs routed to the ORIGINAL `question.answer`
    /// command. Approval answers always use `run.approval.resolve` against
    /// the live card.
    public var requestDigest: String?
    public var answerNonce: String?
    /// Approval-only live revision (`approval.<callID>/<requestedAt>`).
    public var approvalVersion: String?
    public var runState: String

    public init(
        identity: TaskContinuityWaitIdentity,
        prompt: String,
        promptTruncated: Bool,
        waitPolicy: String,
        answerableNow: Bool,
        requiresResume: Bool,
        createdAt: Date,
        updatedAt: Date,
        deadlineAt: Date?,
        requestDigest: String?,
        answerNonce: String?,
        approvalVersion: String?,
        runState: String
    ) {
        self.identity = identity
        self.prompt = prompt
        self.promptTruncated = promptTruncated
        self.waitPolicy = waitPolicy
        self.answerableNow = answerableNow
        self.requiresResume = requiresResume
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deadlineAt = deadlineAt
        self.requestDigest = requestDigest
        self.answerNonce = answerNonce
        self.approvalVersion = approvalVersion
        self.runState = runState
    }
}

public struct TaskContinuityWaitRead: Sendable, Equatable {
    public var waits: [TaskContinuityWait]
    public var truncated: Bool
    public var questionsUnavailable: Bool
    public var approvalsUnavailable: Bool

    public init(
        waits: [TaskContinuityWait],
        truncated: Bool = false,
        questionsUnavailable: Bool = false,
        approvalsUnavailable: Bool = false
    ) {
        self.waits = waits
        self.truncated = truncated
        self.questionsUnavailable = questionsUnavailable
        self.approvalsUnavailable = approvalsUnavailable
    }
}

public struct TaskContinuitySnapshot: Sendable, Equatable {
    public var schema: String
    public var taskID: UUID
    public var runID: UUID?
    public var rootEpoch: UInt64
    public var rootFingerprint: String
    public var storage: TaskContinuityStorageStatus
    public var pause: TaskContinuityPauseMarker?
    public var waits: [TaskContinuityWait]
    public var waitsTruncated: Bool
    public var waitsUnavailable: Bool
    public var unknownOutcomeCount: Int
    public var generatedAt: Date

    public init(
        schema: String = C02TaskContinuityWire.schema,
        taskID: UUID,
        runID: UUID?,
        rootEpoch: UInt64,
        rootFingerprint: String,
        storage: TaskContinuityStorageStatus,
        pause: TaskContinuityPauseMarker?,
        waits: [TaskContinuityWait],
        waitsTruncated: Bool,
        waitsUnavailable: Bool,
        unknownOutcomeCount: Int,
        generatedAt: Date
    ) {
        self.schema = schema
        self.taskID = taskID
        self.runID = runID
        self.rootEpoch = rootEpoch
        self.rootFingerprint = rootFingerprint
        self.storage = storage
        self.pause = pause
        self.waits = waits
        self.waitsTruncated = waitsTruncated
        self.waitsUnavailable = waitsUnavailable
        self.unknownOutcomeCount = unknownOutcomeCount
        self.generatedAt = generatedAt
    }
}

// MARK: - Run / target observations

public struct TaskContinuityTaskDescriptor: Sendable, Equatable {
    public var taskID: UUID
    public var purpose: String

    public init(taskID: UUID, purpose: String) {
        self.taskID = taskID
        self.purpose = purpose
    }

    public var isTemporary: Bool { purpose == "temporary" }
}

public struct TaskContinuityRunDescriptor: Sendable, Equatable {
    public var taskID: UUID
    public var runID: UUID
    public var state: String
    public var conversationMode: String?
    public var modelID: UUID?
    public var providerID: UUID?

    public init(
        taskID: UUID,
        runID: UUID,
        state: String,
        conversationMode: String?,
        modelID: UUID?,
        providerID: UUID?
    ) {
        self.taskID = taskID
        self.runID = runID
        self.state = state
        self.conversationMode = conversationMode
        self.modelID = modelID
        self.providerID = providerID
    }

    public var isTerminal: Bool {
        state == "completed" || state == "idle"
    }

    /// A durable checkpoint already exists for this run. A storage pause on
    /// such a run did not need to write another one, but the UI must not say
    /// it "stopped before saving a checkpoint".
    public var isCheckpointed: Bool {
        state == "checkpointed" || state == "completed"
    }

    public var isResumable: Bool {
        state == "preparing" || state == "streamingModel"
            || state == "waitingApproval" || state == "executingTool"
            || state == "compacting" || state == "paused"
            || state == "interrupted" || state == "verifying"
            || state == "cancelling" || state == "failed"
            || state == "checkpointed"
    }
}

public struct TaskContinuityTargetSnapshot: Sendable, Equatable {
    public var targetRevision: Int64?
    public var targetRootEpoch: UInt64?
    public var environmentID: String?
    public var workspaceID: UUID?
    public var shellRootHash: String?
    public var engineOwnerHash: String?
    public var unknownOutcomeCount: Int

    public init(
        targetRevision: Int64? = nil,
        targetRootEpoch: UInt64? = nil,
        environmentID: String? = nil,
        workspaceID: UUID? = nil,
        shellRootHash: String? = nil,
        engineOwnerHash: String? = nil,
        unknownOutcomeCount: Int = 0
    ) {
        self.targetRevision = targetRevision
        self.targetRootEpoch = targetRootEpoch
        self.environmentID = environmentID
        self.workspaceID = workspaceID
        self.shellRootHash = shellRootHash
        self.engineOwnerHash = engineOwnerHash
        self.unknownOutcomeCount = unknownOutcomeCount
    }
}

public struct TaskContinuityLiveApproval: Sendable, Equatable {
    public var callID: String
    public var tool: String
    public var reason: String
    public var requestedAt: Date

    public init(callID: String, tool: String, reason: String, requestedAt: Date) {
        self.callID = callID
        self.tool = tool
        self.reason = reason
        self.requestedAt = requestedAt
    }
}

// MARK: - Ports (production adapters live in Integration; tests use fakes)

public protocol TaskContinuityTaskReading: Sendable {
    func task(taskID: UUID) async throws -> TaskContinuityTaskDescriptor?
}

public protocol TaskContinuityRunCoordinating: Sendable {
    func run(taskID: UUID, runID: UUID) async throws -> TaskContinuityRunDescriptor
    func latestRun(taskID: UUID) async throws -> TaskContinuityRunDescriptor?
    /// Ask the ORIGINAL live service to write its durable checkpoint and
    /// park. Returns true only after the checkpoint path accepted the park.
    func requestPause(taskID: UUID, runID: UUID) async -> Bool
    /// Delegate to the ORIGINAL `run.retry` checkpoint/history resume. The
    /// caller has already validated and claimed the marker exactly once.
    func resume(
        taskID: UUID,
        runID: UUID,
        expectedState: String,
        markerID: String
    ) async throws -> TaskContinuityRunResumeResult
}

public struct TaskContinuityRunResumeResult: Sendable, Equatable {
    public var detail: [String: String]

    public init(detail: [String: String]) {
        self.detail = detail
    }
}

public protocol TaskContinuityTargetReading: Sendable {
    func target(taskID: UUID, runID: UUID) async throws -> TaskContinuityTargetSnapshot
}

public protocol TaskContinuityWaitProviding: Sendable {
    func pendingWaits(taskID: UUID, runID: UUID?) async throws -> TaskContinuityWaitRead
}

// MARK: - Pause store

public protocol TaskContinuityPauseStoring: Sendable {
    func activePause(taskID: UUID) async throws -> TaskContinuityPauseMarker?
    func activePause(runID: UUID) async throws -> TaskContinuityPauseMarker?
    /// Latest row in ANY state (including `.resumed`) for recovery
    /// reconciliation. A resumed database row always outranks an older
    /// sidecar marker, so a stale sidecar can never resurrect a pause.
    func latestPause(taskID: UUID) async throws -> TaskContinuityPauseMarker?
    func latestPause(runID: UUID) async throws -> TaskContinuityPauseMarker?
    func marker(id: String) async throws -> TaskContinuityPauseMarker?
    /// Idempotent per active run: an existing awaiting/resumeFailed marker is
    /// refreshed, an in-flight claim is never disturbed, and a resumed
    /// history row is replaced by the new pause generation.
    func record(_ marker: TaskContinuityPauseMarker) async throws -> TaskContinuityPauseMarker
    /// Exactly-once CAS into `resumeInProgress`.
    func claimResume(
        markerID: String,
        taskID: UUID,
        runID: UUID,
        expectedRootEpoch: UInt64,
        now: Date
    ) async throws -> TaskContinuityPauseMarker?
    func settleResume(
        markerID: String,
        expectedRootEpoch: UInt64,
        state: TaskContinuityPauseState,
        runCheckpointed: Bool,
        now: Date
    ) async throws -> TaskContinuityPauseMarker?
    /// Reverts a stale `resumeInProgress` marker to `resumeFailed` (never
    /// silently ready) unless the caller proved the run is live.
    func settleStaleResume(
        markerID: String,
        expectedRootEpoch: UInt64,
        runLive: Bool,
        now: Date
    ) async throws -> TaskContinuityPauseMarker?
    func clear(
        markerID: String,
        taskID: UUID,
        runID: UUID,
        rootEpoch: UInt64
    ) async throws -> Bool
}

/// Minimal nonsecret recovery sidecar used ONLY while the task database is
/// unreachable. It carries identifiers/reason/timestamps, never question or
/// approval text, tool output, paths or secrets.
public protocol TaskContinuityRecoveryMetadataStoring: Sendable {
    func load(taskID: UUID) async throws -> TaskContinuityPauseMarker?
    func load(markerID: String) async throws -> TaskContinuityPauseMarker?
    func save(_ marker: TaskContinuityPauseMarker) async throws
    func clear(
        markerID: String,
        taskID: UUID,
        runID: UUID,
        rootEpoch: UInt64
    ) async throws -> Bool
}

// MARK: - SQLite schema (declarative; Main registers once)

public enum C02TaskContinuitySchema {
    /// Exact additive statements for Main's ONE coordinated v52 migration.
    /// No `PRAGMA user_version` here; Main pairs it with the coordinated
    /// version registration. Existing v1-v51 and G09-R2 selected_at stay
    /// untouched.
    public static let createStatements: [String] = [
        """
        CREATE TABLE IF NOT EXISTS task_continuity_pauses (
            marker_id TEXT PRIMARY KEY NOT NULL,
            task_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
            run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
            root_epoch INTEGER NOT NULL CHECK(root_epoch > 0),
            root_fingerprint TEXT NOT NULL,
            reason TEXT NOT NULL CHECK(reason IN (
                'permissionRevoked','volumeMissing','volumeReadOnly',
                'volumeFull','databaseUnavailable')),
            state TEXT NOT NULL CHECK(state IN (
                'awaitingStorageRecovery','resumeInProgress',
                'resumeFailed','resumed')),
            durability TEXT NOT NULL CHECK(durability IN (
                'taskDatabase','recoveryMetadata','memoryOnly')),
            detected_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            resume_attempt INTEGER NOT NULL CHECK(resume_attempt >= 0),
            target_revision INTEGER,
            target_root_epoch INTEGER,
            environment_id TEXT,
            workspace_id TEXT,
            run_checkpointed INTEGER NOT NULL CHECK(run_checkpointed IN (0,1)),
            unknown_outcome_count INTEGER NOT NULL DEFAULT 0,
            body_json TEXT NOT NULL,
            UNIQUE (run_id)
        ) STRICT
        """,
        """
        CREATE INDEX IF NOT EXISTS task_continuity_pauses_task
        ON task_continuity_pauses(task_id, state, updated_at)
        """,
        """
        CREATE INDEX IF NOT EXISTS task_continuity_pauses_run
        ON task_continuity_pauses(run_id, state)
        """,
    ]
}

public struct C02SQLiteTaskContinuityStore: TaskContinuityPauseStoring {
    private let database: DatabaseManager

    public init(database: DatabaseManager) {
        self.database = database
    }

    public func activePause(taskID: UUID) async throws -> TaskContinuityPauseMarker? {
        try await database.reader { db in
            try Self.requireSchema(db)
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT * FROM task_continuity_pauses
                    WHERE task_id = ? AND state IN ('awaitingStorageRecovery','resumeInProgress','resumeFailed')
                    ORDER BY updated_at DESC, marker_id LIMIT 1
                    """,
                arguments: [taskID.uuidString])
            return try row.map(Self.marker(_:))
        }
    }

    public func activePause(runID: UUID) async throws -> TaskContinuityPauseMarker? {
        try await database.reader { db in
            try Self.requireSchema(db)
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT * FROM task_continuity_pauses
                    WHERE run_id = ? AND state IN ('awaitingStorageRecovery','resumeInProgress','resumeFailed')
                    ORDER BY updated_at DESC, marker_id LIMIT 1
                    """,
                arguments: [runID.uuidString])
            return try row.map(Self.marker(_:))
        }
    }

    public func latestPause(taskID: UUID) async throws -> TaskContinuityPauseMarker? {
        try await database.reader { db in
            try Self.requireSchema(db)
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT * FROM task_continuity_pauses
                    WHERE task_id = ?
                    ORDER BY updated_at DESC, marker_id LIMIT 1
                    """,
                arguments: [taskID.uuidString])
            return try row.map(Self.marker(_:))
        }
    }

    public func latestPause(runID: UUID) async throws -> TaskContinuityPauseMarker? {
        try await database.reader { db in
            try Self.requireSchema(db)
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT * FROM task_continuity_pauses
                    WHERE run_id = ?
                    ORDER BY updated_at DESC, marker_id LIMIT 1
                    """,
                arguments: [runID.uuidString])
            return try row.map(Self.marker(_:))
        }
    }

    public func marker(id: String) async throws -> TaskContinuityPauseMarker? {
        try await database.reader { db in
            try Self.requireSchema(db)
            let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM task_continuity_pauses WHERE marker_id = ?",
                arguments: [id])
            return try row.map(Self.marker(_:))
        }
    }

    public func record(_ marker: TaskContinuityPauseMarker) async throws -> TaskContinuityPauseMarker {
        try marker.validate()
        return try await database.writer { db in
            try Self.requireSchema(db)
            if let existingRow = try Row.fetchOne(
                db,
                sql: "SELECT * FROM task_continuity_pauses WHERE run_id = ?",
                arguments: [marker.runID.uuidString]) {
                var existing = try Self.marker(existingRow)
                if existing.rootEpoch == marker.rootEpoch,
                   existing.state == .resumeInProgress {
                    return existing
                }
                if existing.rootEpoch == marker.rootEpoch,
                   existing.state == .awaitingStorageRecovery || existing.state == .resumeFailed {
                    existing.reason = marker.reason
                    existing.durability = marker.durability
                    existing.detectedAt = marker.detectedAt
                    existing.updatedAt = marker.updatedAt
                    existing.runCheckpointed = existing.runCheckpointed || marker.runCheckpointed
                    existing.unknownOutcomeCount = max(
                        existing.unknownOutcomeCount, marker.unknownOutcomeCount)
                    existing.targetRevision = marker.targetRevision ?? existing.targetRevision
                    existing.targetRootEpoch = marker.targetRootEpoch ?? existing.targetRootEpoch
                    existing.environmentID = marker.environmentID ?? existing.environmentID
                    existing.workspaceID = marker.workspaceID ?? existing.workspaceID
                    existing.shellRootHash = marker.shellRootHash ?? existing.shellRootHash
                    existing.engineOwnerHash = marker.engineOwnerHash ?? existing.engineOwnerHash
                    existing.detailCode = marker.detailCode ?? existing.detailCode
                    try Self.update(db, existing)
                    return existing
                }
                try db.execute(
                    sql: "DELETE FROM task_continuity_pauses WHERE run_id = ?",
                    arguments: [marker.runID.uuidString])
            }
            try Self.insert(db, marker)
            return marker
        }
    }

    public func claimResume(
        markerID: String,
        taskID: UUID,
        runID: UUID,
        expectedRootEpoch: UInt64,
        now: Date
    ) async throws -> TaskContinuityPauseMarker? {
        try await database.writer { db in
            try Self.requireSchema(db)
            try db.execute(
                sql: """
                    UPDATE task_continuity_pauses
                    SET state = 'resumeInProgress',
                        resume_attempt = resume_attempt + 1,
                        updated_at = ?
                    WHERE marker_id = ? AND task_id = ? AND run_id = ?
                      AND root_epoch = ?
                      AND state IN ('awaitingStorageRecovery','resumeFailed')
                    """,
                arguments: [
                    now.timeIntervalSince1970, markerID, taskID.uuidString,
                    runID.uuidString, Int64(expectedRootEpoch),
                ])
            guard db.changesCount == 1 else { return nil }
            let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM task_continuity_pauses WHERE marker_id = ?",
                arguments: [markerID])
            return try row.map(Self.marker(_:))
        }
    }

    public func settleResume(
        markerID: String,
        expectedRootEpoch: UInt64,
        state: TaskContinuityPauseState,
        runCheckpointed: Bool,
        now: Date
    ) async throws -> TaskContinuityPauseMarker? {
        guard state == .resumed || state == .resumeFailed else { return nil }
        return try await database.writer { db in
            try Self.requireSchema(db)
            try db.execute(
                sql: """
                    UPDATE task_continuity_pauses
                    SET state = ?, run_checkpointed = MAX(run_checkpointed, ?), updated_at = ?
                    WHERE marker_id = ? AND root_epoch = ? AND state = 'resumeInProgress'
                    """,
                arguments: [
                    state.rawValue, runCheckpointed ? 1 : 0,
                    now.timeIntervalSince1970, markerID, Int64(expectedRootEpoch),
                ])
            guard db.changesCount == 1 else { return nil }
            let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM task_continuity_pauses WHERE marker_id = ?",
                arguments: [markerID])
            return try row.map(Self.marker(_:))
        }
    }

    public func settleStaleResume(
        markerID: String,
        expectedRootEpoch: UInt64,
        runLive: Bool,
        now: Date
    ) async throws -> TaskContinuityPauseMarker? {
        let state: TaskContinuityPauseState = runLive ? .resumed : .resumeFailed
        return try await database.writer { db in
            try Self.requireSchema(db)
            try db.execute(
                sql: """
                    UPDATE task_continuity_pauses SET state = ?, updated_at = ?
                    WHERE marker_id = ? AND root_epoch = ? AND state = 'resumeInProgress'
                    """,
                arguments: [
                    state.rawValue, now.timeIntervalSince1970,
                    markerID, Int64(expectedRootEpoch),
                ])
            guard db.changesCount == 1 else { return nil }
            let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM task_continuity_pauses WHERE marker_id = ?",
                arguments: [markerID])
            return try row.map(Self.marker(_:))
        }
    }

    public func clear(
        markerID: String,
        taskID: UUID,
        runID: UUID,
        rootEpoch: UInt64
    ) async throws -> Bool {
        try await database.writer { db in
            try Self.requireSchema(db)
            try db.execute(
                sql: """
                    DELETE FROM task_continuity_pauses
                    WHERE marker_id = ? AND task_id = ? AND run_id = ? AND root_epoch = ?
                    """,
                arguments: [
                    markerID, taskID.uuidString, runID.uuidString,
                    Int64(rootEpoch),
                ])
            return db.changesCount == 1
        }
    }

    // MARK: Row mapping

    private static func requireSchema(_ db: Database) throws {
        guard try db.tableExists("task_continuity_pauses") else {
            throw C02TaskContinuityError.schemaUnavailable
        }
    }

    private static func insert(_ db: Database, _ marker: TaskContinuityPauseMarker) throws {
        let body = try encode(marker)
        try db.execute(
            sql: """
                INSERT INTO task_continuity_pauses (
                    marker_id, task_id, run_id, root_epoch, root_fingerprint,
                    reason, state, durability, detected_at, updated_at,
                    resume_attempt, target_revision, target_root_epoch,
                    environment_id, workspace_id, run_checkpointed,
                    unknown_outcome_count, body_json
                ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """,
            arguments: [
                marker.markerID, marker.taskID.uuidString, marker.runID.uuidString,
                Int64(marker.rootEpoch), marker.rootFingerprint,
                marker.reason.rawValue, marker.state.rawValue,
                marker.durability.rawValue,
                marker.detectedAt.timeIntervalSince1970,
                marker.updatedAt.timeIntervalSince1970,
                marker.resumeAttempt,
                marker.targetRevision,
                marker.targetRootEpoch.map { Int64($0) },
                marker.environmentID,
                marker.workspaceID?.uuidString,
                marker.runCheckpointed ? 1 : 0,
                marker.unknownOutcomeCount,
                body,
            ])
    }

    private static func update(_ db: Database, _ marker: TaskContinuityPauseMarker) throws {
        let body = try encode(marker)
        try db.execute(
            sql: """
                UPDATE task_continuity_pauses SET
                    root_fingerprint = ?, reason = ?, state = ?, durability = ?,
                    detected_at = ?, updated_at = ?, resume_attempt = ?,
                    target_revision = ?, target_root_epoch = ?,
                    environment_id = ?, workspace_id = ?, run_checkpointed = ?,
                    unknown_outcome_count = ?, body_json = ?
                WHERE marker_id = ?
                """,
            arguments: [
                marker.rootFingerprint, marker.reason.rawValue,
                marker.state.rawValue, marker.durability.rawValue,
                marker.detectedAt.timeIntervalSince1970,
                marker.updatedAt.timeIntervalSince1970,
                marker.resumeAttempt,
                marker.targetRevision,
                marker.targetRootEpoch.map { Int64($0) },
                marker.environmentID,
                marker.workspaceID?.uuidString,
                marker.runCheckpointed ? 1 : 0,
                marker.unknownOutcomeCount,
                body,
                marker.markerID,
            ])
    }

    private static func marker(_ row: Row) throws -> TaskContinuityPauseMarker {
        guard let body: String = row["body_json"],
              let data = body.data(using: .utf8) else {
            throw C02TaskContinuityError.storeUnavailable("markerBody")
        }
        do {
            let marker = try JSONDecoder().decode(TaskContinuityPauseMarker.self, from: data)
            try marker.validate()
            return marker
        } catch let error as C02TaskContinuityError {
            throw error
        } catch {
            throw C02TaskContinuityError.storeUnavailable("markerDecode")
        }
    }

    private static func encode(_ marker: TaskContinuityPauseMarker) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(marker)
        } catch {
            throw C02TaskContinuityError.invalidRequest("markerEncode")
        }
        guard data.count <= 16_384 else {
            throw C02TaskContinuityError.invalidRequest("markerTooLarge")
        }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Recovery metadata sidecar

/// Bounded nonsecret marker file used only when the task database is
/// unreachable. The path is supplied by the trusted host (an app-private
/// recovery directory); no model/tool input can select it.
public actor TaskContinuityFileRecoveryMetadata: TaskContinuityRecoveryMetadataStoring {
    private let directory: URL
    private let fileURL: URL
    private let maximumBytes = 16_384
    private let maximumMarkers = 8

    public init(directory: URL) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("task-continuity-pause.json", isDirectory: false)
    }

    public func load(taskID: UUID) async throws -> TaskContinuityPauseMarker? {
        let markers = try read()
        return markers.values
            .filter { $0.taskID == taskID && $0.state != .resumed }
            .sorted { $0.updatedAt > $1.updatedAt }
            .first
    }

    public func load(markerID: String) async throws -> TaskContinuityPauseMarker? {
        try read()[markerID]
    }

    public func save(_ marker: TaskContinuityPauseMarker) async throws {
        try marker.validate()
        var markers = (try? read()) ?? [:]
        if markers.count >= maximumMarkers, markers[marker.markerID] == nil {
            if let oldest = markers.values.min(by: { $0.updatedAt < $1.updatedAt }) {
                markers.removeValue(forKey: oldest.markerID)
            }
        }
        var stored = marker
        stored.durability = .recoveryMetadata
        markers[stored.markerID] = stored
        try write(markers)
    }

    public func clear(
        markerID: String,
        taskID: UUID,
        runID: UUID,
        rootEpoch: UInt64
    ) async throws -> Bool {
        var markers = (try? read()) ?? [:]
        guard let marker = markers[markerID],
              marker.taskID == taskID,
              marker.runID == runID,
              marker.rootEpoch == rootEpoch else { return false }
        markers.removeValue(forKey: markerID)
        if markers.isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
        } else {
            try write(markers)
        }
        return true
    }

    private func read() throws -> [String: TaskContinuityPauseMarker] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        if let size = attributes?[.size] as? NSNumber,
           size.intValue > maximumBytes {
            throw C02TaskContinuityError.recoveryMetadataUnavailable("sidecarTooLarge")
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        } catch {
            throw C02TaskContinuityError.recoveryMetadataUnavailable("sidecarRead")
        }
        guard data.count <= maximumBytes else {
            throw C02TaskContinuityError.recoveryMetadataUnavailable("sidecarTooLarge")
        }
        do {
            let stored = try JSONDecoder().decode([String: TaskContinuityPauseMarker].self, from: data)
            var result: [String: TaskContinuityPauseMarker] = [:]
            for (key, marker) in stored {
                try marker.validate()
                guard marker.markerID == key else {
                    throw C02TaskContinuityError.recoveryMetadataUnavailable("sidecarIdentity")
                }
                result[key] = marker
            }
            return result
        } catch let error as C02TaskContinuityError {
            throw error
        } catch {
            throw C02TaskContinuityError.recoveryMetadataUnavailable("sidecarDecode")
        }
    }

    private func write(_ markers: [String: TaskContinuityPauseMarker]) throws {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(markers)
            guard data.count <= maximumBytes else {
                throw C02TaskContinuityError.recoveryMetadataUnavailable("sidecarTooLarge")
            }
            try data.write(to: fileURL, options: [.atomic])
        } catch let error as C02TaskContinuityError {
            throw error
        } catch {
            throw C02TaskContinuityError.recoveryMetadataUnavailable("sidecarWrite")
        }
    }
}

/// RAM-only recovery metadata for a process where no recovery directory is
/// bound (component tests and the honest memory-only fallback).
public actor TaskContinuityMemoryRecoveryMetadata: TaskContinuityRecoveryMetadataStoring {
    private var markers: [String: TaskContinuityPauseMarker] = [:]

    public init() {}

    public func load(taskID: UUID) async throws -> TaskContinuityPauseMarker? {
        markers.values
            .filter { $0.taskID == taskID && $0.state != .resumed }
            .sorted { $0.updatedAt > $1.updatedAt }
            .first
    }

    public func load(markerID: String) async throws -> TaskContinuityPauseMarker? {
        markers[markerID]
    }

    public func save(_ marker: TaskContinuityPauseMarker) async throws {
        try marker.validate()
        var stored = marker
        stored.durability = .memoryOnly
        markers[stored.markerID] = stored
    }

    public func clear(
        markerID: String,
        taskID: UUID,
        runID: UUID,
        rootEpoch: UInt64
    ) async throws -> Bool {
        guard let marker = markers[markerID],
              marker.taskID == taskID,
              marker.runID == runID,
              marker.rootEpoch == rootEpoch else { return false }
        markers.removeValue(forKey: markerID)
        return true
    }
}

// MARK: - Resume validation

public struct TaskContinuityResumeRequest: Sendable, Equatable {
    public var taskID: UUID
    public var runID: UUID
    public var markerID: String
    public var expectedRootEpoch: UInt64
    public var expectedTargetRevision: Int64?
    /// Must be true. A model, deep link, notification or automatic retry can
    /// never set this through the closed wire parser.
    public var explicitUserAction: Bool

    public init(
        taskID: UUID,
        runID: UUID,
        markerID: String,
        expectedRootEpoch: UInt64,
        expectedTargetRevision: Int64? = nil,
        explicitUserAction: Bool
    ) {
        self.taskID = taskID
        self.runID = runID
        self.markerID = markerID
        self.expectedRootEpoch = expectedRootEpoch
        self.expectedTargetRevision = expectedTargetRevision
        self.explicitUserAction = explicitUserAction
    }
}

public enum TaskContinuityResumeRefusal: Error, Sendable, Equatable {
    case explicitActionRequired
    case taskNotFound
    case runNotFound
    case temporaryTaskRefused
    case pauseNotFound
    case alreadyResumed
    case resumeInProgress
    case rootEpochChanged(expected: UInt64, actual: UInt64)
    case rootIdentityMismatch
    case storageStillUnavailable(TaskContinuityStorageCondition)
    case targetChanged(expected: Int64?, actual: Int64?)
    case environmentChanged
    case runAlreadyTerminal(String)
    case runNotResumable(String)
    case resumeRejected(String)
    case storeUnavailable(String)

    public var code: String {
        switch self {
        case .explicitActionRequired: return "explicitActionRequired"
        case .taskNotFound: return "taskNotFound"
        case .runNotFound: return "runNotFound"
        case .temporaryTaskRefused: return "temporaryTaskRefused"
        case .pauseNotFound: return "pauseNotFound"
        case .alreadyResumed: return "alreadyResumed"
        case .resumeInProgress: return "resumeInProgress"
        case .rootEpochChanged: return "rootEpochChanged"
        case .rootIdentityMismatch: return "rootIdentityMismatch"
        case .storageStillUnavailable(let condition):
            return "storageStillUnavailable:\(condition.rawValue)"
        case .targetChanged: return "targetChanged"
        case .environmentChanged: return "environmentChanged"
        case .runAlreadyTerminal: return "runAlreadyTerminal"
        case .runNotResumable: return "runNotResumable"
        case .resumeRejected(let code): return "resumeRejected:\(code)"
        case .storeUnavailable(let code): return "storeUnavailable:\(code)"
        }
    }

    public var message: String {
        switch self {
        case .explicitActionRequired:
            return "Resuming this task requires an explicit user action."
        case .taskNotFound:
            return "This task no longer exists."
        case .runNotFound:
            return "This run no longer exists."
        case .temporaryTaskRefused:
            return "Temporary chats cannot be resumed from continuity state."
        case .pauseNotFound:
            return "No storage pause is recorded for this task."
        case .alreadyResumed:
            return "This pause was already resumed."
        case .resumeInProgress:
            return "This task is already resuming."
        case .rootEpochChanged:
            return "The runtime generation changed. Refresh the task and resume again."
        case .rootIdentityMismatch:
            return "This pause belongs to a different app-data root."
        case .storageStillUnavailable:
            return "Storage is still unavailable. Restore it before resuming."
        case .targetChanged:
            return "The task execution target changed after the pause. Review the target before resuming."
        case .environmentChanged:
            return "The task execution environment changed after the pause."
        case .runAlreadyTerminal:
            return "This run already finished and cannot be resumed."
        case .runNotResumable:
            return "This run has no resumable checkpoint or history."
        case .resumeRejected:
            return "The original run resume refused. Refresh the task and try again."
        case .storeUnavailable:
            return "The continuity state could not be read."
        }
    }
}

public enum TaskContinuityResumeOutcome: Sendable, Equatable {
    case accepted(TaskContinuityRunResumeResult, TaskContinuityPauseMarker?)
    case refused(TaskContinuityResumeRefusal)

    public var isAccepted: Bool {
        if case .accepted = self { return true }
        return false
    }
}

public enum TaskContinuityResumeValidation {
    /// Pure pre-CAS validation. The caller still claims the marker with a
    /// store CAS; this function never mutates state.
    public static func validate(
        request: TaskContinuityResumeRequest,
        marker: TaskContinuityPauseMarker?,
        task: TaskContinuityTaskDescriptor?,
        run: TaskContinuityRunDescriptor?,
        target: TaskContinuityTargetSnapshot,
        storage: TaskContinuityStorageStatus,
        currentRootEpoch: UInt64,
        currentRootFingerprint: String,
        now: Date
    ) -> TaskContinuityResumeRefusal? {
        guard request.explicitUserAction else { return .explicitActionRequired }
        guard let task, task.taskID == request.taskID else { return .taskNotFound }
        guard !task.isTemporary else { return .temporaryTaskRefused }
        guard let marker, marker.markerID == request.markerID,
              marker.taskID == request.taskID,
              marker.runID == request.runID else { return .pauseNotFound }
        guard marker.rootFingerprint == currentRootFingerprint else {
            return .rootIdentityMismatch
        }
        guard marker.state != .resumed else { return .alreadyResumed }
        if marker.state == .resumeInProgress {
            let age = now.timeIntervalSince(marker.updatedAt)
            if age < C02TaskContinuityWire.resumingStaleSeconds {
                return .resumeInProgress
            }
        }
        guard request.expectedRootEpoch == currentRootEpoch,
              currentRootEpoch > 0 else {
            return .rootEpochChanged(
                expected: request.expectedRootEpoch,
                actual: currentRootEpoch)
        }
        guard storage.isReady else {
            return .storageStillUnavailable(storage.condition)
        }
        guard let run, run.runID == request.runID, run.taskID == request.taskID else {
            return .runNotFound
        }
        guard !run.isTerminal else { return .runAlreadyTerminal(run.state) }
        guard run.isResumable else { return .runNotResumable(run.state) }
        // A pause recorded while the task database was unreachable could not
        // capture the pin. Its nil is "not observed", not a target change;
        // the current pin is re-read and validated when storage is back.
        if let expected = marker.targetRevision,
           expected != target.targetRevision {
            return .targetChanged(
                expected: expected,
                actual: target.targetRevision)
        }
        if let expected = marker.environmentID,
           expected != target.environmentID {
            return .environmentChanged
        }
        if let expected = marker.workspaceID,
           expected != target.workspaceID {
            return .environmentChanged
        }
        if let expected = marker.shellRootHash,
           expected != target.shellRootHash {
            return .environmentChanged
        }
        if let expected = marker.engineOwnerHash,
           expected != target.engineOwnerHash {
            return .environmentChanged
        }
        if let expected = request.expectedTargetRevision,
           expected != target.targetRevision {
            return .targetChanged(expected: expected, actual: target.targetRevision)
        }
        return nil
    }
}

// MARK: - Admission decision

public enum TaskContinuityAdmissionOperation: Sendable, Equatable {
    case launch
    case resume
}

public enum TaskContinuityAdmission: Sendable, Equatable {
    case paused(markerID: String, reason: TaskContinuityPauseReason)
    case resumeAuthorized(markerID: String)
}

// MARK: - Coordinator

/// Generation-bound continuity coordinator. It is the ONLY writer for pause
/// markers and the only place that authorizes a `run.retry` while a pause is
/// active. It never writes questions/answers/approvals.
public actor TaskContinuityCoordinator {
    public nonisolated let epoch: UInt64
    public nonisolated let rootFingerprint: String

    private let taskReader: any TaskContinuityTaskReading
    private let runCoordinator: any TaskContinuityRunCoordinating
    private let targetReader: any TaskContinuityTargetReading
    private let waitProvider: any TaskContinuityWaitProviding
    private let store: any TaskContinuityPauseStoring
    private let recovery: any TaskContinuityRecoveryMetadataStoring
    private let storage: any TaskContinuityStorageProbing
    private let now: @Sendable () -> Date

    /// Exactly-once resume authorization consumed by the central run gate.
    private var resumeAuthorizations: Set<String> = []
    /// Honest RAM-only markers when both durable media are unavailable.
    private var memoryMarkers: [String: TaskContinuityPauseMarker] = [:]

    public init(
        epoch: UInt64,
        rootFingerprint: String,
        taskReader: any TaskContinuityTaskReading,
        runCoordinator: any TaskContinuityRunCoordinating,
        targetReader: any TaskContinuityTargetReading,
        waitProvider: any TaskContinuityWaitProviding,
        store: any TaskContinuityPauseStoring,
        recovery: any TaskContinuityRecoveryMetadataStoring,
        storage: any TaskContinuityStorageProbing,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.epoch = epoch
        self.rootFingerprint = rootFingerprint
        self.taskReader = taskReader
        self.runCoordinator = runCoordinator
        self.targetReader = targetReader
        self.waitProvider = waitProvider
        self.store = store
        self.recovery = recovery
        self.storage = storage
        self.now = now
    }

    // MARK: Snapshot

    public func snapshot(taskID: UUID, runID: UUID?) async throws -> TaskContinuitySnapshot {
        let now = now()
        guard epoch > 0 else { throw C02TaskContinuityError.rootEpochUnavailable }
        let storage = await self.storage.probe()
        // When the task database itself is unreachable, the durable marker
        // sidecar is the ONLY state this call may read. The trusted host
        // already refused temporary tasks and supplied real IDs; no DB task
        // or run read is attempted in that mode.
        let descriptor: TaskContinuityRunDescriptor?
        if storage.isReady {
            guard let task = try await taskReader.task(taskID: taskID) else {
                throw C02TaskContinuityError.taskNotFound
            }
            guard !task.isTemporary else {
                throw C02TaskContinuityError.temporaryTaskRefused
            }
            if let runID {
                do {
                    descriptor = try await runCoordinator.run(
                        taskID: taskID, runID: runID)
                } catch C02TaskContinuityError.runNotFound {
                    throw C02TaskContinuityError.runNotFound
                }
            } else {
                descriptor = try? await runCoordinator.latestRun(taskID: taskID)
            }
        } else {
            descriptor = nil
        }
        let effectiveRunID = runID ?? descriptor?.runID

        // A task-level snapshot (no runID) shows the task's latest active
        // pause; a run snapshot shows only that run's marker.
        var pause = await loadPause(taskID: taskID, runID: runID)
        if let marker = pause, marker.state == .resumeInProgress {
            pause = await reconcileStaleResume(
                marker: marker, run: descriptor, storage: storage, now: now)
        }
        if pause?.state == .resumed { pause = nil }

        var waits = TaskContinuityWaitRead(waits: [])
        var waitsUnavailable = false
        if storage.isReady {
            do {
                waits = try await waitProvider.pendingWaits(
                    taskID: taskID, runID: runID)
                let originalCount = waits.waits.count
                waits.waits = Array(waits.waits.prefix(C02TaskContinuityWire.maximumWaits))
                waits.truncated = waits.truncated
                    || originalCount > waits.waits.count
            } catch {
                waitsUnavailable = true
                waits = TaskContinuityWaitRead(
                    waits: [], truncated: false,
                    questionsUnavailable: true, approvalsUnavailable: true)
            }
        } else {
            waitsUnavailable = !storage.isReady
        }
        let target: TaskContinuityTargetSnapshot
        if storage.isReady, let effectiveRunID {
            target = (try? await targetReader.target(
                taskID: taskID, runID: effectiveRunID))
                ?? TaskContinuityTargetSnapshot()
        } else {
            target = TaskContinuityTargetSnapshot()
        }
        return TaskContinuitySnapshot(
            taskID: taskID,
            runID: pause?.runID ?? effectiveRunID,
            rootEpoch: epoch,
            rootFingerprint: rootFingerprint,
            storage: storage,
            pause: pause,
            waits: waits.waits,
            waitsTruncated: waits.truncated,
            waitsUnavailable: waitsUnavailable || waits.questionsUnavailable || waits.approvalsUnavailable,
            unknownOutcomeCount: max(
                target.unknownOutcomeCount,
                pause?.unknownOutcomeCount ?? 0),
            generatedAt: now)
    }

    // MARK: Pause

    public func noteStorageFailure(
        taskID: UUID,
        runID: UUID,
        error: Error
    ) async throws -> TaskContinuityPauseReceipt? {
        guard let condition = TaskContinuityStorageClassifier.condition(for: error),
              let reason = condition.pauseReason else { return nil }
        return try await pause(
            taskID: taskID,
            runID: runID,
            reason: reason,
            detailCode: "classified")
    }

    /// Explicit probe path used by the trusted host before it admits further
    /// work. It records a pause only for a PROVEN non-ready condition and
    /// only for an existing ordinary task/run.
    public func checkStorage(
        taskID: UUID,
        runID: UUID
    ) async throws -> TaskContinuityPauseReceipt? {
        let storage = await self.storage.probe()
        guard let reason = storage.condition.pauseReason else { return nil }
        do {
            return try await pause(
                taskID: taskID,
                runID: runID,
                reason: reason,
                detailCode: storage.detailCode)
        } catch let error as C02TaskContinuityError {
            if case .invalidRequest(let code) = error, code == "runTerminal" {
                return nil
            }
            throw error
        }
    }

    public func pause(
        taskID: UUID,
        runID: UUID,
        reason: TaskContinuityPauseReason,
        detailCode: String? = nil
    ) async throws -> TaskContinuityPauseReceipt {
        let now = now()
        guard epoch > 0 else { throw C02TaskContinuityError.rootEpochUnavailable }
        let storage = await self.storage.probe()
        // With the task DB unreachable, only the bounded recovery sidecar is
        // available. The host-supplied task/run IDs are trusted; no second
        // database or fallback identity is opened.
        let run: TaskContinuityRunDescriptor?
        let target: TaskContinuityTargetSnapshot
        if storage.isReady {
            guard let task = try await taskReader.task(taskID: taskID) else {
                throw C02TaskContinuityError.taskNotFound
            }
            guard !task.isTemporary else {
                throw C02TaskContinuityError.temporaryTaskRefused
            }
            let resolved = try await runCoordinator.run(
                taskID: taskID, runID: runID)
            guard resolved.taskID == taskID else {
                throw C02TaskContinuityError.taskNotFound
            }
            guard !resolved.isTerminal else {
                throw C02TaskContinuityError.invalidRequest("runTerminal")
            }
            run = resolved
            target = (try? await targetReader.target(
                taskID: taskID, runID: runID))
                ?? TaskContinuityTargetSnapshot()
        } else {
            run = nil
            target = TaskContinuityTargetSnapshot()
        }
        let base = TaskContinuityPauseMarker(
            markerID: UUID().uuidString.lowercased(),
            taskID: taskID,
            runID: runID,
            rootEpoch: epoch,
            rootFingerprint: rootFingerprint,
            reason: reason,
            state: .awaitingStorageRecovery,
            durability: .taskDatabase,
            detectedAt: now,
            updatedAt: now,
            resumeAttempt: 0,
            targetRevision: target.targetRevision,
            targetRootEpoch: target.targetRootEpoch,
            environmentID: target.environmentID,
            workspaceID: target.workspaceID,
            shellRootHash: target.shellRootHash,
            engineOwnerHash: target.engineOwnerHash,
            runCheckpointed: run?.isCheckpointed ?? false,
            unknownOutcomeCount: target.unknownOutcomeCount,
            detailCode: boundedDetail(detailCode))
        var marker = try await persistPause(base, storage: storage)
        let checkpointed = await runCoordinator.requestPause(taskID: taskID, runID: runID)
        if checkpointed != marker.runCheckpointed {
            marker.runCheckpointed = marker.runCheckpointed || checkpointed
            marker.updatedAt = self.now()
            marker = (try? await persistPause(marker, storage: storage)) ?? marker
        }
        return TaskContinuityPauseReceipt(
            marker: marker, runCheckpointed: marker.runCheckpointed, storage: storage)
    }

    // MARK: Resume

    public func resume(_ request: TaskContinuityResumeRequest) async throws
        -> TaskContinuityResumeOutcome {
        let now = now()
        guard request.explicitUserAction else {
            return .refused(.explicitActionRequired)
        }
        guard epoch > 0 else {
            return .refused(.rootEpochChanged(expected: request.expectedRootEpoch, actual: 0))
        }
        let storage = await self.storage.probe()
        var marker = await loadPause(taskID: request.taskID, runID: request.runID)
        if !storage.isReady {
            // Refuse before any task/run DB read. The marker identity is
            // still checked so a foreign task/root never gets a resume hint.
            guard let marker,
                  marker.taskID == request.taskID,
                  marker.runID == request.runID else {
                return .refused(.pauseNotFound)
            }
            guard marker.rootFingerprint == rootFingerprint else {
                return .refused(.rootIdentityMismatch)
            }
            guard marker.state != .resumed else {
                return .refused(.alreadyResumed)
            }
            guard marker.state != .resumeInProgress
                    || now.timeIntervalSince(marker.updatedAt)
                        >= C02TaskContinuityWire.resumingStaleSeconds else {
                return .refused(.resumeInProgress)
            }
            return .refused(.storageStillUnavailable(storage.condition))
        }
        guard let task = try await taskReader.task(taskID: request.taskID) else {
            return .refused(.taskNotFound)
        }
        guard !task.isTemporary else { return .refused(.temporaryTaskRefused) }
        let run: TaskContinuityRunDescriptor
        do {
            run = try await runCoordinator.run(
                taskID: request.taskID, runID: request.runID)
        } catch {
            return .refused(.runNotFound)
        }
        let target = (try? await targetReader.target(
            taskID: request.taskID, runID: request.runID)) ?? TaskContinuityTargetSnapshot()
        // A pause recorded while the DB was unreachable could not capture
        // the run pin. Now that storage is readable, bind the missing
        // evidence to the run's OWN historical pin (or the current target
        // when the run has no pin) BEFORE validation, and migrate a sidecar
        // marker into the coordinated table. This never invents a target.
        if var enriched = marker, enriched.isActionable {
            var changed = false
            if enriched.targetRevision == nil, let value = target.targetRevision {
                enriched.targetRevision = value
                changed = true
            }
            if enriched.targetRootEpoch == nil, let value = target.targetRootEpoch {
                enriched.targetRootEpoch = value
                changed = true
            }
            if enriched.environmentID == nil, let value = target.environmentID {
                enriched.environmentID = value
                changed = true
            }
            if enriched.workspaceID == nil, let value = target.workspaceID {
                enriched.workspaceID = value
                changed = true
            }
            if enriched.shellRootHash == nil, let value = target.shellRootHash {
                enriched.shellRootHash = value
                changed = true
            }
            if enriched.engineOwnerHash == nil, let value = target.engineOwnerHash {
                enriched.engineOwnerHash = value
                changed = true
            }
            if changed {
                enriched.updatedAt = now
                marker = (try? await persistPause(enriched, storage: storage))
                    ?? enriched
            }
        }
        if let current = marker, current.state == .resumeInProgress {
            let wasStale = now.timeIntervalSince(current.updatedAt)
                >= C02TaskContinuityWire.resumingStaleSeconds
            marker = await reconcileStaleResume(
                marker: current, run: run, storage: storage, now: now)
            if marker == nil, wasStale {
                // The stale claim was reconciled onto a live run; it is
                // already resuming. Never start a second one.
                return .refused(.alreadyResumed)
            }
        }
        if let refusal = TaskContinuityResumeValidation.validate(
            request: request,
            marker: marker,
            task: task,
            run: run,
            target: target,
            storage: storage,
            currentRootEpoch: epoch,
            currentRootFingerprint: rootFingerprint,
            now: now) {
            // A terminal run has nothing left to resume; keeping the marker
            // would strand a permanent pause in the UI. Clear that exact
            // generation only after the identity validation above.
            if case .runAlreadyTerminal = refusal, let marker {
                await clearPause(marker)
            }
            return .refused(refusal)
        }
        guard var currentMarker = marker else { return .refused(.pauseNotFound) }
        guard currentMarker.isActionable else {
            return .refused(currentMarker.state == .resumed ? .alreadyResumed : .resumeInProgress)
        }
        // ONE CAS claim. A duplicate tap/restart cannot start a second run.
        guard let claimed = try await claim(&currentMarker, now: now) else {
            return .refused(.resumeInProgress)
        }
        let claimedMarker = claimed
        resumeAuthorizations.insert(request.runID.uuidString)
        do {
            let result = try await runCoordinator.resume(
                taskID: request.taskID,
                runID: request.runID,
                expectedState: run.state,
                markerID: claimedMarker.markerID)
            resumeAuthorizations.remove(request.runID.uuidString)
            let settled = try? await settle(
                marker: claimedMarker, state: .resumed,
                runCheckpointed: false, now: now)
            return .accepted(result, settled)
        } catch {
            resumeAuthorizations.remove(request.runID.uuidString)
            let settled = try? await settle(
                marker: claimedMarker, state: .resumeFailed,
                runCheckpointed: claimedMarker.runCheckpointed, now: now)
            let reason: String
            if let refusal = error as? TaskContinuityResumeRefusal {
                return .refused(refusal)
            } else if let floe = error as? C02TaskContinuityError {
                reason = floe.code
            } else {
                reason = "resumeRejected"
            }
            _ = settled
            return .refused(.resumeRejected(reason))
        }
    }

    // MARK: Central run-gate

    /// Called by `FacadeRunDomain.start`/`retry`. `nil` means no continuity
    /// coordinator is installed or no marker is active: the original path is
    /// unchanged.
    public func admissionDecision(
        taskID: UUID,
        runID: UUID?,
        operation: TaskContinuityAdmissionOperation
    ) async -> TaskContinuityAdmission? {
        guard let runID else {
            // A launch may not name the future run id. Resolve the latest run
            // for the task; a paused task blocks every new launch.
            let marker = await loadPause(taskID: taskID, runID: nil)
            guard let marker, marker.isActionable || marker.state == .resumeInProgress else {
                return nil
            }
            if operation == .resume, marker.state == .resumeInProgress,
               resumeAuthorizations.contains(marker.runID.uuidString) {
                resumeAuthorizations.remove(marker.runID.uuidString)
                return .resumeAuthorized(markerID: marker.markerID)
            }
            return .paused(markerID: marker.markerID, reason: marker.reason)
        }
        let marker = await loadPause(taskID: taskID, runID: runID)
        guard let marker else { return nil }
        if marker.state == .resumed { return nil }
        if operation == .resume, resumeAuthorizations.contains(runID.uuidString) {
            resumeAuthorizations.remove(runID.uuidString)
            return .resumeAuthorized(markerID: marker.markerID)
        }
        if marker.state == .resumeInProgress {
            // A stale claim is reconciled only by `snapshot`/`resume` with a
            // real run observation. The admission gate never guesses.
            return .paused(markerID: marker.markerID, reason: marker.reason)
        }
        return .paused(markerID: marker.markerID, reason: marker.reason)
    }

    // MARK: Internal persistence

    private func loadPause(taskID: UUID, runID: UUID?) async -> TaskContinuityPauseMarker? {
        if let runID {
            if let marker = memoryMarkers.values.first(where: {
                $0.taskID == taskID && $0.runID == runID
                    && $0.state != .resumed
            }) {
                return marker
            }
            if let marker = try? await store.activePause(runID: runID) {
                return marker
            }
            // A database row for THIS run in any state (including resumed)
            // is newer truth than a stale sidecar left after a crash.
            if let latest = try? await store.latestPause(runID: runID) {
                _ = try? await recovery.clear(
                    markerID: latest.markerID,
                    taskID: latest.taskID,
                    runID: latest.runID,
                    rootEpoch: latest.rootEpoch)
                return nil
            }
            return try? await recovery.load(taskID: taskID)
        }
        if let marker = memoryMarkers.values
            .filter({ $0.taskID == taskID && $0.state != .resumed })
            .sorted(by: { $0.updatedAt > $1.updatedAt })
            .first {
            return marker
        }
        if let marker = try? await store.activePause(taskID: taskID) {
            return marker
        }
        if let latest = try? await store.latestPause(taskID: taskID) {
            _ = try? await recovery.clear(
                markerID: latest.markerID,
                taskID: latest.taskID,
                runID: latest.runID,
                rootEpoch: latest.rootEpoch)
            return nil
        }
        return try? await recovery.load(taskID: taskID)
    }

    private func clearPause(_ marker: TaskContinuityPauseMarker) async {
        if marker.durability == .taskDatabase {
            _ = try? await store.clear(
                markerID: marker.markerID,
                taskID: marker.taskID,
                runID: marker.runID,
                rootEpoch: marker.rootEpoch)
        }
        _ = try? await recovery.clear(
            markerID: marker.markerID,
            taskID: marker.taskID,
            runID: marker.runID,
            rootEpoch: marker.rootEpoch)
        memoryMarkers.removeValue(forKey: marker.markerID)
    }

    private func persistPause(
        _ marker: TaskContinuityPauseMarker,
        storage: TaskContinuityStorageStatus
    ) async throws -> TaskContinuityPauseMarker {
        if storage.isReady {
            do {
                var stored = marker
                stored.durability = .taskDatabase
                return try await store.record(stored)
            } catch let error as C02TaskContinuityError {
                if case .schemaUnavailable = error {
                    // Main has not registered v52 in this build: the sidecar
                    // is the only honest durable medium.
                } else {
                    return try await persistRecovery(marker, original: error)
                }
            } catch {
                return try await persistRecovery(marker, original: error)
            }
        }
        return try await persistRecovery(marker, original: nil)
    }

    private func persistRecovery(
        _ marker: TaskContinuityPauseMarker,
        original: Error?
    ) async throws -> TaskContinuityPauseMarker {
        var sidecar = marker
        sidecar.durability = .recoveryMetadata
        do {
            try await recovery.save(sidecar)
            return sidecar
        } catch {
            // A genuinely unwritable volume cannot persist anything. Keep an
            // honest RAM-only marker so the current process still gates work
            // and the UI still explains the pause.
            var memory = marker
            memory.durability = .memoryOnly
            memory.updatedAt = now()
            memoryMarkers[memory.markerID] = memory
            if let original {
                _ = original
            }
            return memory
        }
    }

    private func claim(
        _ marker: inout TaskContinuityPauseMarker,
        now: Date
    ) async throws -> TaskContinuityPauseMarker? {
        if marker.durability == .taskDatabase {
            if let claimed = try? await store.claimResume(
                markerID: marker.markerID,
                taskID: marker.taskID,
                runID: marker.runID,
                expectedRootEpoch: marker.rootEpoch,
                now: now) {
                return claimed
            }
        }
        // Recovery/memory claim is serialized by this actor; re-check the
        // exact identity and actionable state before transitioning.
        guard marker.isActionable,
              marker.rootEpoch == epoch,
              marker.rootFingerprint == rootFingerprint else { return nil }
        marker.state = .resumeInProgress
        marker.resumeAttempt += 1
        marker.updatedAt = now
        memoryMarkers[marker.markerID] = marker
        if marker.durability == .recoveryMetadata {
            try? await recovery.save(marker)
        }
        return marker
    }

    private func settle(
        marker: TaskContinuityPauseMarker,
        state: TaskContinuityPauseState,
        runCheckpointed: Bool,
        now: Date
    ) async throws -> TaskContinuityPauseMarker? {
        if marker.durability == .taskDatabase {
            if let settled = try? await store.settleResume(
                markerID: marker.markerID,
                expectedRootEpoch: marker.rootEpoch,
                state: state,
                runCheckpointed: runCheckpointed,
                now: now) {
                // Once the database accepted the result, an older sidecar
                // copy is stale and must not resurrect the pause.
                _ = try? await recovery.clear(
                    markerID: marker.markerID,
                    taskID: marker.taskID,
                    runID: marker.runID,
                    rootEpoch: marker.rootEpoch)
                memoryMarkers.removeValue(forKey: marker.markerID)
                return settled
            }
        }
        var updated = marker
        updated.state = state
        updated.runCheckpointed = updated.runCheckpointed || runCheckpointed
        updated.updatedAt = now
        if updated.durability == .recoveryMetadata {
            if state == .resumed {
                _ = try? await recovery.clear(
                    markerID: marker.markerID,
                    taskID: marker.taskID,
                    runID: marker.runID,
                    rootEpoch: marker.rootEpoch)
                memoryMarkers.removeValue(forKey: marker.markerID)
            } else {
                try? await recovery.save(updated)
            }
        }
        if state != .resumed {
            memoryMarkers[marker.markerID] = updated
        } else {
            memoryMarkers.removeValue(forKey: marker.markerID)
        }
        return updated
    }

    private func reconcileStaleResume(
        marker: TaskContinuityPauseMarker,
        run: TaskContinuityRunDescriptor?,
        storage: TaskContinuityStorageStatus,
        now: Date
    ) async -> TaskContinuityPauseMarker? {
        guard marker.state == .resumeInProgress,
              now.timeIntervalSince(marker.updatedAt)
                >= C02TaskContinuityWire.resumingStaleSeconds else {
            return marker
        }
        let runLive = run.map {
            $0.state != "completed" && $0.state != "failed"
                && $0.state != "checkpointed" && $0.state != "idle"
        } ?? false
        if marker.durability == .taskDatabase,
           let settled = try? await store.settleStaleResume(
            markerID: marker.markerID,
            expectedRootEpoch: marker.rootEpoch,
            runLive: runLive,
            now: now) {
            return settled.state == .resumed ? nil : settled
        }
        var updated = marker
        updated.state = runLive ? .resumed : .resumeFailed
        updated.updatedAt = now
        if updated.durability == .recoveryMetadata {
            if updated.state == .resumeFailed {
                try? await recovery.save(updated)
            } else {
                _ = try? await recovery.clear(
                    markerID: updated.markerID, taskID: updated.taskID,
                    runID: updated.runID, rootEpoch: updated.rootEpoch)
            }
        }
        memoryMarkers[updated.markerID] = updated
        return updated.state == .resumed ? nil : updated
    }

    private func boundedDetail(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let normalized = value.unicodeScalars
            .filter { $0.isASCII }
            .prefix(64)
            .map(Character.init)
        let text = normalized.map { String($0) }.joined()
        return TaskContinuityPauseMarker.isIdentifier(text) ? text : "storage"
    }
}

// MARK: - Default wait provider

/// Read-only wait projection over the ORIGINAL question store/coordinator and
/// the durable run thread. It never registers, settles, cancels or mutates a
/// question or approval.
public struct C02SQLiteTaskContinuityWaitProvider: TaskContinuityWaitProviding {
    private let database: DatabaseManager
    private let epoch: UInt64
    private let rootFingerprint: String
    private let liveApproval: @Sendable (UUID, UUID) async -> TaskContinuityLiveApproval?
    private let now: @Sendable () -> Date

    public init(
        database: DatabaseManager,
        epoch: UInt64,
        rootFingerprint: String,
        liveApproval: @escaping @Sendable (UUID, UUID) async -> TaskContinuityLiveApproval?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.database = database
        self.epoch = epoch
        self.rootFingerprint = rootFingerprint
        self.liveApproval = liveApproval
        self.now = now
    }

    public func pendingWaits(taskID: UUID, runID: UUID?) async throws -> TaskContinuityWaitRead {
        var waits: [TaskContinuityWait] = []
        var questionsUnavailable = false
        var approvalsUnavailable = false
        let runStore = SQLiteRunStore(database: database)
        let runs: [TaskContinuityRunDescriptor]
        if let runID {
            if let record = try? await runStore.run(id: runID),
               record.conversationID == taskID {
                runs = [Self.descriptor(record)]
            } else {
                runs = []
            }
        } else {
            let records = (try? await runStore.recentRuns(conversationID: taskID, limit: 5)) ?? []
            runs = records.map(Self.descriptor)
        }
        // Questions: the live coordinator is the authority when installed;
        // the store is a read-only fallback for a cold generation. Neither
        // path creates, answers or cancels a question here.
        do {
            let snapshots: [UserQuestionWaitingSnapshot]
            let coordinator = UserQuestionHostAPI.shared.current(epoch: epoch)
            if let coordinator {
                snapshots = try await coordinator.snapshots(
                    conversationID: taskID, includeSettled: false)
            } else {
                snapshots = try await UserQuestionStore(database: database)
                    .snapshots(conversationID: taskID, includeSettled: false)
            }
            for snapshot in snapshots {
                if let runID, snapshot.runID != runID { continue }
                let active: Bool
                if let coordinator {
                    active = await coordinator.isActivelyWaiting(
                        requestID: snapshot.requestID)
                } else {
                    active = false
                }
                let runState = runs.first(where: { $0.runID == snapshot.runID })?.state
                    ?? "unknown"
                for question in snapshot.questions where question.isPending {
                    let prompt = Self.boundedPrompt(question.text)
                    let identity = TaskContinuityWaitIdentity(
                        kind: .question,
                        rootEpoch: epoch,
                        rootFingerprint: rootFingerprint,
                        taskID: taskID,
                        runID: snapshot.runID,
                        toolCallID: snapshot.toolCallID,
                        requestID: snapshot.requestID,
                        itemID: question.questionID,
                        revision: max(1, question.revision))
                    waits.append(TaskContinuityWait(
                        identity: identity,
                        prompt: prompt.text,
                        promptTruncated: prompt.truncated,
                        waitPolicy: question.waitPolicy.rawValue,
                        answerableNow: active,
                        requiresResume: !active,
                        createdAt: question.createdAt,
                        updatedAt: question.updatedAt,
                        deadlineAt: question.deadlineAt,
                        requestDigest: snapshot.requestDigest,
                        answerNonce: UserQuestionHostWire.answerNonce(
                            requestID: snapshot.requestID,
                            questionID: question.questionID,
                            revision: max(1, question.revision),
                            requestDigest: snapshot.requestDigest),
                        approvalVersion: nil,
                        runState: runState))
                }
            }
        } catch {
            questionsUnavailable = true
        }
        // Approvals: durable request events are readable without a live
        // service. A live owner always wins for the same call, because only
        // it can accept `run.approval.resolve`.
        for run in runs {
            var live = await liveApproval(taskID, run.runID)
            if let value = live, value.callID.isEmpty { live = nil }
            if let live {
                var identity = TaskContinuityWaitIdentity(
                    kind: .approval,
                    rootEpoch: epoch,
                    rootFingerprint: rootFingerprint,
                    taskID: taskID,
                    runID: run.runID,
                    toolCallID: live.callID,
                    requestID: live.callID,
                    itemID: live.callID,
                    revision: max(1, Self.milliseconds(live.requestedAt)))
                try identity.validate()
                waits.removeAll {
                    $0.identity.kind == .approval
                        && $0.identity.runID == run.runID
                        && $0.identity.itemID == live.callID
                }
                waits.append(TaskContinuityWait(
                    identity: identity,
                    prompt: Self.boundedPrompt("\(live.tool): \(live.reason)").text,
                    promptTruncated: false,
                    waitPolicy: "approval",
                    answerableNow: true,
                    requiresResume: false,
                    createdAt: live.requestedAt,
                    updatedAt: live.requestedAt,
                    deadlineAt: nil,
                    requestDigest: nil,
                    answerNonce: nil,
                    approvalVersion: RunWireDate.encode(live.requestedAt),
                    runState: run.state))
                continue
            }
            guard run.state == "waitingApproval" else { continue }
            let events: [RunEventRecord]
            do {
                events = try await runStore.recentEvents(
                    runID: run.runID,
                    limit: C02TaskContinuityWire.maximumRunHistoryEvents)
            } catch {
                approvalsUnavailable = true
                continue
            }
            if let pending = Self.durablePendingApproval(events: events) {
                var identity = TaskContinuityWaitIdentity(
                    kind: .approval,
                    rootEpoch: epoch,
                    rootFingerprint: rootFingerprint,
                    taskID: taskID,
                    runID: run.runID,
                    toolCallID: pending.callID,
                    requestID: pending.callID,
                    itemID: pending.callID,
                    revision: max(1, Self.milliseconds(pending.requestedAt)))
                try identity.validate()
                waits.append(TaskContinuityWait(
                    identity: identity,
                    prompt: Self.boundedPrompt(
                        "\(pending.tool): \(pending.reason)").text,
                    promptTruncated: false,
                    waitPolicy: "approval",
                    answerableNow: false,
                    requiresResume: true,
                    createdAt: pending.requestedAt,
                    updatedAt: pending.requestedAt,
                    deadlineAt: nil,
                    requestDigest: nil,
                    answerNonce: nil,
                    approvalVersion: RunWireDate.encode(pending.requestedAt),
                    runState: run.state))
            }
        }
        let bounded = Array(waits.prefix(C02TaskContinuityWire.maximumWaits))
        return TaskContinuityWaitRead(
            waits: bounded.sorted {
                if $0.requiresResume != $1.requiresResume {
                    return !$0.requiresResume
                }
                return $0.createdAt < $1.createdAt
            },
            truncated: waits.count > bounded.count,
            questionsUnavailable: questionsUnavailable,
            approvalsUnavailable: approvalsUnavailable)
    }

    private struct DurableApproval {
        var callID: String
        var tool: String
        var reason: String
        var requestedAt: Date
    }

    private static func durablePendingApproval(events: [RunEventRecord]) -> DurableApproval? {
        var resolvedCallIDs = Set<String>()
        for event in events.reversed() {
            guard let data = event.payloadJSON.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let callID = object["callID"] as? String, !callID.isEmpty else {
                continue
            }
            if resolvedCallIDs.contains(callID) { continue }
            if event.kind == .approval {
                if object["outcome"] != nil {
                    resolvedCallIDs.insert(callID)
                    continue
                }
                let tool = (object["tool"] as? String) ?? "tool"
                let reason = (object["reason"] as? String) ?? ""
                return DurableApproval(
                    callID: callID, tool: tool, reason: reason,
                    requestedAt: event.createdAt)
            }
            // A later tool request/result, status, error or terminal event
            // proves this call is no longer awaiting the human decision.
            if event.kind == .toolRequest || event.kind == .toolResult
                || event.kind == .status || event.kind == .terminal
                || event.kind == .error {
                resolvedCallIDs.insert(callID)
            }
        }
        return nil
    }

    private static func descriptor(_ record: RunRecord) -> TaskContinuityRunDescriptor {
        TaskContinuityRunDescriptor(
            taskID: record.conversationID,
            runID: record.id,
            state: record.state,
            conversationMode: record.conversationMode,
            modelID: record.modelID,
            providerID: record.providerID)
    }

    private static func milliseconds(_ date: Date) -> Int {
        let value = date.timeIntervalSince1970 * 1_000
        guard value.isFinite, value >= 1, value <= Double(Int.max) else { return 1 }
        return Int(value)
    }

    private static func boundedPrompt(_ value: String) -> (text: String, truncated: Bool) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count > C02TaskContinuityWire.maximumPromptBytes else {
            return (trimmed, false)
        }
        var result = ""
        var used = 0
        for character in trimmed {
            let bytes = String(character).utf8.count
            if used + bytes > C02TaskContinuityWire.maximumPromptBytes { break }
            result.append(character)
            used += bytes
        }
        return (result, true)
    }
}
