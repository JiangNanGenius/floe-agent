// SPDX-License-Identifier: MPL-2.0
//
// RuntimeFacadePrivacyTypes — G02 privacy settings backend wire types and
// bounded report carriers.
//
// Authority: the frozen rev3 settings contract
// (settings-domain-main-acceptance-20261019/input-final/contract.json,
// sha256 f3ddecdca061ae17fbe4280b7bfb549d8a1673fd8d9ae6e1ba363332ef5db46c)
// commands 24..26, plus the settled Main additive decisions:
//   * MAIN_PRIVACY_REPORT_STREAMING_DECISION_20261019.json — bounded initial
//     failure arrays + optional same-root report paging, typed
//     remaining/remainingFailure/preferencesFailure, no fabricated zeros.
//   * PRIVACY_SOURCE_MAIN_INTEGRATION_DIRECTIONS_20261019.json — exact
//     same-writer CAS/monotonic preference revision, no dummy provider id.
//
// Nothing in this file registers a command, reads a store or invents an
// authority. Counts are display-only; the digest is the binding. A clear is
// never one atomic transaction and is never reported as one.
import Foundation

// MARK: - Bounded limits (one place; validators and stores share them)

public enum PrivacyReportLimits {
    /// How many failure items ride the initial clear report value. Every
    /// remaining item is reachable through the same-root report store; the
    /// 48 KiB value / 64 KiB frame budgets stay small and predictable.
    public static let initialFailureItems = 8
    public static let minimumPageItems = 1
    public static let maximumPageItems = 128
    /// Bounded opaque reason tokens never carry row content or secrets.
    public static let maximumReasonCharacters = 96
    public static let maximumReportHandleCharacters = 256
    public static let maximumReportCursorCharacters = 256
    /// Process-lifetime bounded store (per root/epoch). Eviction only makes
    /// an older report unavailable (typed notFound) — it never fabricates a
    /// truncated page.
    public static let maximumLiveReportsPerRoot = 8
}

public enum PrivacyConfirmationLimits {
    /// Opaque one-operation capability spelling: `pc:v1:<32 lowercase hex>`.
    public static let tokenPrefix = "pc:v1:"
    public static let tokenLogicalBytes = 38
    public static let tokenCapacity = 39
    public static let maximumTokenCharacters = 64
    /// A confirmation is short-lived by design; the countdown never extends
    /// itself and expiry is evaluated on consume.
    public static let maximumTTLSeconds: TimeInterval = 120
    public static let maximumLiveCapabilities = 8
    public static let historyAction = "historyClear"
    public static let modelConfigurationAction = "modelConfigClear"
}

// MARK: - Typed wire failures (frozen errorCodeVocabulary subset)

/// Frozen contract error vocabulary for the privacy domain. `wireReason`
/// stays a bounded opaque token — never row content, paths, account names
/// or secret material.
public enum PrivacyDomainError: Error, Sendable, Equatable {
    case invalidEnvelope(String)
    case staleRevision
    case duplicateInFlight
    case notFound
    /// persistenceUnavailable carries an optional bounded reason token;
    /// `unstableGrantSnapshot` is the typed g1/g2 bracket failure.
    case persistenceUnavailable(String?)
    /// needsConfiguration carries a bounded reason token; the model-config
    /// clear reports `gatewayUnregistered` BEFORE any mutation when no
    /// product gateway is registered (never a fake success).
    case needsConfiguration(String)
    /// Unbound REQUIRED owner port or typed owner refusal.
    case runtimeUnavailable(String)
    /// Epoch/identity fencing failures (fence misuse, foreign token).
    case sessionFenced(String)

    public var wireCode: String {
        switch self {
        case .invalidEnvelope: return "invalidEnvelope"
        case .staleRevision: return "staleRevision"
        case .duplicateInFlight: return "duplicateInFlight"
        case .notFound: return "notFound"
        case .persistenceUnavailable: return "persistenceUnavailable"
        case .needsConfiguration: return "needsConfiguration"
        case .runtimeUnavailable: return "runtimeUnavailable"
        case .sessionFenced: return "sessionFenced"
        }
    }

    public var wireReason: String? {
        switch self {
        case .invalidEnvelope(let reason),
             .persistenceUnavailable(.some(let reason)),
             .needsConfiguration(let reason),
             .runtimeUnavailable(let reason),
             .sessionFenced(let reason):
            return PrivacyWireBounding.reason(reason)
        case .persistenceUnavailable(.none), .staleRevision,
             .duplicateInFlight, .notFound:
            return nil
        }
    }
}

/// One bounded opaque reason rule for every producer. It never passes
/// control characters, path separators, account-shaped text or long
/// payloads to the wire; callers must already supply a symbolic token.
public enum PrivacyWireBounding {
    public static func reason(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        var text = raw.filter { character in
            !character.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
        }
        text = text.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        if text.count > PrivacyReportLimits.maximumReasonCharacters {
            text = String(text.prefix(PrivacyReportLimits.maximumReasonCharacters))
        }
        return text.isEmpty ? nil : text
    }
}

// MARK: - privacy.summary.get

public struct PrivacyHistorySnapshot: Sendable, Equatable, Codable {
    public var conversationCount: Int
    public var runCount: Int
    public var persistedGrantCount: Int
    public var inMemoryGrantCount: Int
    /// `sha256:<hex>` floe.privacy-history.v3 exact identity/state stream.
    public var revision: String

    public init(conversationCount: Int, runCount: Int,
                persistedGrantCount: Int, inMemoryGrantCount: Int,
                revision: String) {
        self.conversationCount = conversationCount
        self.runCount = runCount
        self.persistedGrantCount = persistedGrantCount
        self.inMemoryGrantCount = inMemoryGrantCount
        self.revision = revision
    }
}

public struct PrivacyModelConfigurationSnapshot: Sendable, Equatable, Codable {
    public var providerCount: Int
    public var modelCount: Int
    /// Providers with a non-null secret reference (display-only count).
    public var secretReferenceCount: Int
    public var preferencesSyncRevision: Int
    /// `sha256:<hex>` floe.privacy-modelconfig.v3 exact identity/state stream.
    public var revision: String

    public init(providerCount: Int, modelCount: Int,
                secretReferenceCount: Int, preferencesSyncRevision: Int,
                revision: String) {
        self.providerCount = providerCount
        self.modelCount = modelCount
        self.secretReferenceCount = secretReferenceCount
        self.preferencesSyncRevision = preferencesSyncRevision
        self.revision = revision
    }
}

public enum PrivacyCredentialAvailability: String, Sendable, Equatable, Codable {
    case available = "AVAILABLE"
    case needsConfiguration = "NEEDS_CONFIGURATION"
}

public struct PrivacySnapshotReceipt: Sendable, Equatable, Codable {
    public var dbSnapshotTransaction: Bool
    public var inMemoryGrantBracket: String
    public var retriesBounded: Int

    public init(dbSnapshotTransaction: Bool, inMemoryGrantBracket: String,
                retriesBounded: Int) {
        self.dbSnapshotTransaction = dbSnapshotTransaction
        self.inMemoryGrantBracket = inMemoryGrantBracket
        self.retriesBounded = retriesBounded
    }
}

public struct PrivacySnapshotReply: Sendable, Equatable, Codable {
    public var history: PrivacyHistorySnapshot
    public var modelConfiguration: PrivacyModelConfigurationSnapshot
    public var credentialAvailability: PrivacyCredentialAvailability
    public var snapshot: PrivacySnapshotReceipt

    public init(history: PrivacyHistorySnapshot,
                modelConfiguration: PrivacyModelConfigurationSnapshot,
                credentialAvailability: PrivacyCredentialAvailability,
                snapshot: PrivacySnapshotReceipt) {
        self.history = history
        self.modelConfiguration = modelConfiguration
        self.credentialAvailability = credentialAvailability
        self.snapshot = snapshot
    }
}

// MARK: - Additive optional report paging (same privacy.summary.get command)

public enum PrivacyReportKind: String, Sendable, Equatable, Codable {
    case history
    case modelConfiguration
}

/// Strict parsed request for the optional `{report:{…}}` payload. An
/// absent/empty payload means the ordinary summary and is represented by
/// `PrivacySummaryRequest.summary`.
public enum PrivacySummaryRequest: Sendable, Equatable {
    case summary
    case page(handle: String, cursor: String?, maxItems: Int)

    /// Closed additive grammar. The shared validator already enforces the
    /// same rules before dispatch; this parse is the processor's defensive
    /// re-read and never widens them.
    public static func parse(_ payload: SettingsDomainV1.JSONValue?)
        throws -> PrivacySummaryRequest
    {
        guard let payload else { return .summary }
        guard case .object(let object) = payload else {
            throw PrivacyDomainError.invalidEnvelope("invalidPayload")
        }
        if object.isEmpty { return .summary }
        guard object.count == 1, case .object(let report)? = object["report"] else {
            throw PrivacyDomainError.invalidEnvelope("unknownPrivacyField")
        }
        guard let handleValue = report["handle"], case .string(let handle) = handleValue,
              !handle.isEmpty, handle.count <= PrivacyReportLimits.maximumReportHandleCharacters,
              !handle.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw PrivacyDomainError.invalidEnvelope("invalidPayloadField:handle")
        }
        var cursor: String?
        if let value = report["cursor"] {
            guard case .string(let raw) = value, !raw.isEmpty,
                  raw.count <= PrivacyReportLimits.maximumReportCursorCharacters,
                  !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else {
                throw PrivacyDomainError.invalidEnvelope("invalidPayloadField:cursor")
            }
            cursor = raw
        }
        var maxItems = PrivacyReportLimits.initialFailureItems
        if let value = report["maxItems"] {
            guard case .integer(let raw) = value,
                  raw >= Int64(PrivacyReportLimits.minimumPageItems),
                  raw <= Int64(PrivacyReportLimits.maximumPageItems)
            else {
                throw PrivacyDomainError.invalidEnvelope("invalidPayloadField:maxItems")
            }
            maxItems = Int(raw)
        }
        let allowed: Set<String> = ["handle", "cursor", "maxItems"]
        guard report.keys.allSatisfy({ allowed.contains($0) }) else {
            throw PrivacyDomainError.invalidEnvelope("unknownPrivacyReportField")
        }
        return .page(handle: handle, cursor: cursor, maxItems: maxItems)
    }
}

/// One failure item in a report page. History failures carry `itemID`
/// (conversation/grant); model-config failures carry `providerID`. `phase`
/// and `reason` are the authoritative bounded strings.
public struct PrivacyFailurePageItem: Sendable, Equatable, Codable {
    public var itemID: UUID?
    public var providerID: UUID?
    public var phase: String
    public var reason: String

    public init(itemID: UUID?, providerID: UUID?, phase: String, reason: String) {
        self.itemID = itemID
        self.providerID = providerID
        self.phase = phase
        self.reason = reason
    }
}

public struct PrivacyFailurePage: Sendable, Equatable, Codable {
    public var handle: String
    public var kind: PrivacyReportKind
    public var items: [PrivacyFailurePageItem]
    public var nextCursor: String?
    public var total: Int
    public var done: Bool

    public init(handle: String, kind: PrivacyReportKind,
                items: [PrivacyFailurePageItem], nextCursor: String?,
                total: Int, done: Bool) {
        self.handle = handle
        self.kind = kind
        self.items = items
        self.nextCursor = nextCursor
        self.total = total
        self.done = done
    }
}

/// The summary command's page reply is `{"report":{…}}` — a typed OBJECT
/// riding the RB1 value carrier, never a JSON string in `detail`.
public struct PrivacyFailurePageReply: Sendable, Equatable, Codable {
    public var report: PrivacyFailurePage

    public init(report: PrivacyFailurePage) {
        self.report = report
    }
}

/// Terminal-page summary attached to a clear report when the initial
/// bounded array does not hold every failure. `returned` is exactly the
/// count in the report's `failures`/`deletionFailures`; `nextCursor` is the
/// cursor for the NEXT page (nil only when `returned == total`).
public struct PrivacyFailurePageSummary: Sendable, Equatable, Codable {
    public var handle: String
    public var returned: Int
    public var total: Int
    public var nextCursor: String?

    public init(handle: String, returned: Int, total: Int,
                nextCursor: String?) {
        self.handle = handle
        self.returned = returned
        self.total = total
        self.nextCursor = nextCursor
    }
}

// MARK: - Shared clear request

/// Trusted-host confirmation echo. The token ALONE never proves permission:
/// the trusted native binder mints an opaque `pc:v1:` one-operation
/// capability only after an explicit user dialog on the exact preview; the
/// envelope revision binds the actual identity/state set. Model-authored
/// JSON, a bare digest or a replayed token can never mint or reuse it.
public struct PrivacyClearRequest: Sendable, Equatable {
    public var confirmToken: String

    public init(confirmToken: String) {
        self.confirmToken = confirmToken
    }
}

// MARK: - privacy.history.clear report

public enum PrivacyHistoryClearPhase: String, Sendable, Equatable, Codable {
    case quiesce
    case deleteConversation
    case grantRevoke
    case drain
}

public struct PrivacyClearFailure: Sendable, Equatable, Codable {
    public var itemID: UUID?
    public var phase: PrivacyHistoryClearPhase
    public var reason: String

    public init(itemID: UUID?, phase: PrivacyHistoryClearPhase,
                reason: String) {
        self.itemID = itemID
        self.phase = phase
        self.reason = reason
    }

    public var pageItem: PrivacyFailurePageItem {
        PrivacyFailurePageItem(itemID: itemID, providerID: nil,
                               phase: phase.rawValue, reason: reason)
    }
}

public struct PrivacyHistoryEnumerated: Sendable, Equatable, Codable {
    public var conversations: Int
    public var runs: Int
    public var persistedGrants: Int
    public var inMemoryGrants: Int

    public init(conversations: Int, runs: Int, persistedGrants: Int,
                inMemoryGrants: Int) {
        self.conversations = conversations
        self.runs = runs
        self.persistedGrants = persistedGrants
        self.inMemoryGrants = inMemoryGrants
    }
}

/// Per-layer grant deletion truth (persisted SQLite layer vs in-memory
/// ApprovalGrantStore layer are separate numbers; a half-cleared state is
/// never hidden behind one merged count).
public struct PrivacyHistoryDeleted: Sendable, Equatable, Codable {
    public var conversations: Int
    public var runs: Int
    public var persistedGrants: Int
    public var inMemoryGrants: Int

    public init(conversations: Int, runs: Int, persistedGrants: Int,
                inMemoryGrants: Int) {
        self.conversations = conversations
        self.runs = runs
        self.persistedGrants = persistedGrants
        self.inMemoryGrants = inMemoryGrants
    }
}

public struct PrivacyHistoryRemaining: Sendable, Equatable, Codable {
    public var conversationCount: Int
    public var runCount: Int
    public var persistedGrantCount: Int
    public var inMemoryGrantCount: Int

    public init(conversationCount: Int, runCount: Int,
                persistedGrantCount: Int, inMemoryGrantCount: Int) {
        self.conversationCount = conversationCount
        self.runCount = runCount
        self.persistedGrantCount = persistedGrantCount
        self.inMemoryGrantCount = inMemoryGrantCount
    }
}

/// Truthful owned private-workspace DIRECTORY accounting for one
/// `privacy.history.clear`. Counts are real effects over conversations
/// whose ownership row existed at the snapshot:
///  * `removed` — an owned directory actually existed and was deleted;
///  * `absent` — nothing existed at the owned path (the lifecycle goal was
///    already satisfied; NEVER counted as a removal and never a failure);
///  * `deferred` — cleanup was refused/deferred typed (survivors, changed
///    ownership, unbound cleaner, foreign target, removal failure): the
///    per-item typed reason is in `failures` and the durable V36 queue row
///    survives for the retry sweep.
public struct PrivacyWorkspaceDirectoryCleanup: Sendable, Equatable, Codable {
    public var removed: Int
    public var absent: Int
    public var deferred: Int
    /// G03-R3 ADDITIVE (nil on reports produced before this field existed):
    /// conversations whose runtime-UID workspace-copy cleanup obligation is
    /// open (queued / retrying / unavailable). The directory may already be
    /// gone; the PRODUCT wipe is not complete until the real receipt lands.
    public var runtimeHandoffAwaiting: Int?
    /// Conversations whose runtime cleanup received a REAL settled cleared
    /// receipt inside this clear.
    public var runtimeHandoffSettled: Int?

    public init(removed: Int = 0, absent: Int = 0, deferred: Int = 0,
                runtimeHandoffAwaiting: Int? = nil,
                runtimeHandoffSettled: Int? = nil) {
        self.removed = removed
        self.absent = absent
        self.deferred = deferred
        self.runtimeHandoffAwaiting = runtimeHandoffAwaiting
        self.runtimeHandoffSettled = runtimeHandoffSettled
    }
}

public struct PrivacyHistoryClearReport: Sendable, Equatable, Codable {
    public var enumerated: PrivacyHistoryEnumerated
    public var deleted: PrivacyHistoryDeleted
    /// Initial BOUNDED page only; `failurePage` proves nothing was lost.
    public var failures: [PrivacyClearFailure]
    public var partial: Bool
    /// REAL post-execution re-count; new conversations/grants created after
    /// the snapshot survive and are surfaced here, never silently absorbed.
    /// nil ONLY with a typed `remainingFailure` and `partial=true`.
    public var remaining: PrivacyHistoryRemaining?
    public var remainingFailure: String?
    /// ADDITIVE (2026-10-21, G02-R7): real per-conversation private
    /// workspace-directory effects. Absent from reports produced before
    /// this field existed; otherwise always present — an all-zero block is
    /// the REAL effect set of a clear whose enumerated conversations had no
    /// private-task ownership rows, never an invented default.
    public var workspaceDirectories: PrivacyWorkspaceDirectoryCleanup?
    public var failurePage: PrivacyFailurePageSummary?

    public init(enumerated: PrivacyHistoryEnumerated,
                deleted: PrivacyHistoryDeleted,
                failures: [PrivacyClearFailure],
                partial: Bool,
                remaining: PrivacyHistoryRemaining?,
                remainingFailure: String? = nil,
                workspaceDirectories: PrivacyWorkspaceDirectoryCleanup? = nil,
                failurePage: PrivacyFailurePageSummary? = nil) {
        self.enumerated = enumerated
        self.deleted = deleted
        self.failures = failures
        self.partial = partial
        self.remaining = remaining
        self.remainingFailure = remainingFailure
        self.workspaceDirectories = workspaceDirectories
        self.failurePage = failurePage
    }
}

// MARK: - privacy.modelConfiguration.clear report

public enum PrivacyModelConfigDeletePhase: String, Sendable, Equatable, Codable {
    case secretReferenceChanged
    case enqueue
    case gatewayDelete
    case complete
    case record
}

public struct PrivacyModelConfigDeletionFailure: Sendable, Equatable, Codable {
    public var providerID: UUID
    public var phase: PrivacyModelConfigDeletePhase
    public var reason: String

    public init(providerID: UUID, phase: PrivacyModelConfigDeletePhase,
                reason: String) {
        self.providerID = providerID
        self.phase = phase
        self.reason = reason
    }

    public var pageItem: PrivacyFailurePageItem {
        PrivacyFailurePageItem(itemID: nil, providerID: providerID,
                               phase: phase.rawValue, reason: reason)
    }
}

public struct PrivacyModelConfigEnumerated: Sendable, Equatable, Codable {
    public var providers: Int
    public var models: Int
    public var secretReferences: Int

    public init(providers: Int, models: Int, secretReferences: Int) {
        self.providers = providers
        self.models = models
        self.secretReferences = secretReferences
    }
}

public struct PrivacyModelConfigDeleted: Sendable, Equatable, Codable {
    public var providers: Int
    public var models: Int
    /// Real gateway-confirmed secret deletions only. A swallowed
    /// "already absent" still counts as removed state; a missing gateway is
    /// NEVER reported here — it fails closed before any mutation.
    public var secrets: Int

    public init(providers: Int, models: Int, secrets: Int) {
        self.providers = providers
        self.models = models
        self.secrets = secrets
    }
}

public struct PrivacyModelConfigRemaining: Sendable, Equatable, Codable {
    public var providerCount: Int
    public var modelCount: Int
    public var secretReferenceCount: Int

    public init(providerCount: Int, modelCount: Int,
                secretReferenceCount: Int) {
        self.providerCount = providerCount
        self.modelCount = modelCount
        self.secretReferenceCount = secretReferenceCount
    }
}

public struct PrivacyModelConfigClearReport: Sendable, Equatable, Codable {
    public var enumerated: PrivacyModelConfigEnumerated
    public var deleted: PrivacyModelConfigDeleted
    /// Initial BOUNDED page only; `failurePage` proves nothing was lost.
    public var deletionFailures: [PrivacyModelConfigDeletionFailure]
    /// Truthful preference-reset state: false when a newer preference save
    /// superseded the confirmed snapshot (never overwritten by fresh
    /// defaults or a stale previous+1).
    public var preferencesReset: Bool
    /// Actual monotonic sync revision after a real reset; the observed
    /// current revision when the reset was superseded.
    public var preferencesSyncRevision: Int
    /// REAL post-execution re-count; nil ONLY with `remainingFailure`.
    public var remaining: PrivacyModelConfigRemaining?
    /// Bounded reason for a preferences-reset FAILURE (superseded is not a
    /// failure: reset=false with the actual revision and no token).
    public var preferencesFailure: String?
    public var remainingFailure: String?
    public var partial: Bool
    public var failurePage: PrivacyFailurePageSummary?

    public init(enumerated: PrivacyModelConfigEnumerated,
                deleted: PrivacyModelConfigDeleted,
                deletionFailures: [PrivacyModelConfigDeletionFailure],
                preferencesReset: Bool,
                preferencesSyncRevision: Int,
                remaining: PrivacyModelConfigRemaining?,
                partial: Bool,
                preferencesFailure: String? = nil,
                remainingFailure: String? = nil,
                failurePage: PrivacyFailurePageSummary? = nil) {
        self.enumerated = enumerated
        self.deleted = deleted
        self.deletionFailures = deletionFailures
        self.preferencesReset = preferencesReset
        self.preferencesSyncRevision = preferencesSyncRevision
        self.remaining = remaining
        self.preferencesFailure = preferencesFailure
        self.remainingFailure = remainingFailure
        self.partial = partial
        self.failurePage = failurePage
    }
}
