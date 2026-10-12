// FloeCore — Atomic provider save request and runner.
//
// The provider editor had a time-of-check/time-of-use window: it validated
// the fields, then awaited Keychain writes, and only afterwards rebuilt the
// profile from still-mutable published fields. An edit landing during those
// awaits (or a second save) could commit content that never passed
// preflight — after credentials had already been touched.
//
// `ProviderSaveRequest` freezes the COMPLETE validated content synchronously
// on the main actor before the first side effect. `ProviderSaveRunner`
// performs every subsequent operation against that one immutable snapshot:
// sync preference → secret write → local bundle commit → persisted readback.
// The orchestration lives in FloeCore (UIKit/Keychain/CloudKit-free) behind
// narrow gateway protocols so the ordering contract is testable on the host
// with deterministic fakes; the App layer supplies the production gateways.

import Foundation

/// Writes the provider secret and applies its Keychain-sync preference.
/// Production is backed by `KeychainSecretStore`; tests use a recording fake.
public protocol ProviderSecretSaving: Sendable {
    func setSyncEnabled(_ enabled: Bool, for providerID: UUID) async throws
    func storeSecret(_ secret: Data, scopeProviderID: UUID) async throws
}

/// Result of one local bundle commit. The local SQLite transaction and the
/// CloudKit sync enqueue are separate steps: a local commit that succeeded
/// while sync delivery/enqueue did not is NOT a save failure.
public struct ProviderBundleCommitResult: Sendable, Equatable {
    /// Canonical stored models (stable UUID merges).
    public let saved: [ModelProfile]
    /// True when local bytes are durable but CloudKit sync did not complete;
    /// the caller should surface a "saved, waiting for iCloud" state.
    public let syncPending: Bool
    /// Secret-free reason when `syncPending` is true.
    public let syncError: String?

    public init(saved: [ModelProfile], syncPending: Bool, syncError: String? = nil) {
        self.saved = saved
        self.syncPending = syncPending
        self.syncError = syncError
    }
}

/// Commits the frozen bundle to local durable storage and verifies readback.
/// Production is backed by `ConversationCenter`/`ModelConfigurationStore`;
/// tests use a recording fake.
public protocol ProviderBundleCommitting: Sendable {
    /// Applies provider + models in one local transaction, then enqueues sync
    /// metadata. Must NOT throw when the local transaction succeeded but sync
    /// enqueue failed: report that through `syncPending`/`syncError`.
    func commitProviderBundle(
        _ request: ProviderSaveRequest
    ) async throws -> ProviderBundleCommitResult

    /// Re-reads the provider and selected models and returns a secret-free
    /// user-facing failure reason, or nil when persisted bytes match.
    func verifyProviderPersisted(
        _ request: ProviderSaveRequest
    ) async -> String?
}

/// Raw, editable form state for one Save tap, captured synchronously BEFORE
/// any suspension point. `makeRequest()` is the single canonical mapping from
/// form fields to the frozen, validated request; the App editor and host tests
/// use the same code path, so a save can never commit content that was not
/// validated from this exact snapshot.
public struct ProviderSaveDraft: Sendable, Equatable {
    public let providerID: UUID
    public let kind: ProviderKind
    public let wireProtocol: ModelProtocol
    public let baseURLString: String
    public let displayName: String
    public let presetID: String?
    public let existingSecretRef: SecretReference?
    public let nonSecretHeaders: [String: String]
    public let isEnabled: Bool
    public let allowsPlainHTTP: Bool
    public let toolNameCompatibility: Bool
    public let syncEnabled: Bool
    public let enteredAPIKey: String
    public let selectedModels: [ModelProfile]
    public let managedCapabilities: ModelCapabilities
    public let serviceRoleIsConversation: Bool
    public let defaultModelID: UUID?
    public let existingCreatedAt: Date?
    public let existingSyncRevision: Int64

    public init(
        providerID: UUID,
        kind: ProviderKind,
        wireProtocol: ModelProtocol,
        baseURLString: String,
        displayName: String,
        presetID: String?,
        existingSecretRef: SecretReference?,
        nonSecretHeaders: [String: String],
        isEnabled: Bool,
        allowsPlainHTTP: Bool,
        toolNameCompatibility: Bool,
        syncEnabled: Bool,
        enteredAPIKey: String,
        selectedModels: [ModelProfile],
        managedCapabilities: ModelCapabilities,
        serviceRoleIsConversation: Bool,
        defaultModelID: UUID?,
        existingCreatedAt: Date?,
        existingSyncRevision: Int64
    ) {
        self.providerID = providerID
        self.kind = kind
        self.wireProtocol = wireProtocol
        self.baseURLString = baseURLString
        self.displayName = displayName
        self.presetID = presetID
        self.existingSecretRef = existingSecretRef
        self.nonSecretHeaders = nonSecretHeaders
        self.isEnabled = isEnabled
        self.allowsPlainHTTP = allowsPlainHTTP
        self.toolNameCompatibility = toolNameCompatibility
        self.syncEnabled = syncEnabled
        self.enteredAPIKey = enteredAPIKey
        self.selectedModels = selectedModels
        self.managedCapabilities = managedCapabilities
        self.serviceRoleIsConversation = serviceRoleIsConversation
        self.defaultModelID = defaultModelID
        self.existingCreatedAt = existingCreatedAt
        self.existingSyncRevision = existingSyncRevision
    }

    /// Builds the frozen request from the draft, or every field-level issue.
    /// Pure and non-async: safe to call synchronously on the main actor so no
    /// mutation can interleave between validation and freezing.
    public func makeRequest() -> Result<ProviderSaveRequest, ProviderConfigurationValidationReport> {
        let trimmedBaseURL = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedBaseURL) else {
            return .failure(ProviderConfigurationValidationReport(issues: [
                ProviderConfigurationIssue(
                    field: .baseURL,
                    problem: .baseURLMalformed,
                    messageKey: "providers.validation.endpoint_malformed"
                )
            ]))
        }
        let trimmedKey = enteredAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasKey = !trimmedKey.isEmpty || existingSecretRef != nil
        let secretRef = hasKey ? SecretReference(
            keychainAccount: existingSecretRef?.keychainAccount
                ?? "provider.\(providerID.uuidString)",
            synchronizable: syncEnabled
        ) : nil
        // Blank/whitespace-only names persist as nil (preset/kind fallback).
        // Copy/paste formatting is normalized; oversized/unsupported names are never truncated.
        let normalizedName = ProviderConfigurationValidation.normalizedDisplayName(displayName)
        let profile = ProviderProfile(
            id: providerID,
            kind: kind,
            wireProtocol: wireProtocol,
            baseURL: url,
            displayName: normalizedName,
            presetID: presetID,
            secretRef: secretRef,
            nonSecretHeaders: nonSecretHeaders,
            isEnabled: isEnabled,
            allowsPlainHTTP: allowsPlainHTTP,
            toolNameCompatibility: toolNameCompatibility,
            createdAt: existingCreatedAt ?? Date(),
            updatedAt: Date(),
            syncRevision: existingSyncRevision
        )
        let issues = ProviderConfigurationValidation.issues(
            provider: profile,
            models: selectedModels
        )
        guard issues.isEmpty else {
            return .failure(ProviderConfigurationValidationReport(issues: issues))
        }
        let intent: ProviderSaveRequest.DefaultModelIntent
        if let chosenID = defaultModelID,
           let staged = selectedModels.first(where: {
               $0.id == chosenID && $0.isEnabled && $0.isVisibleInPrimaryPicker
           }) {
            intent = .chosen(remoteModelID: staged.remoteModelID)
        } else {
            intent = .automatic
        }
        return .success(ProviderSaveRequest(
            profile: profile,
            selectedModels: selectedModels,
            apiKey: trimmedKey.isEmpty ? nil : trimmedKey,
            syncEnabled: syncEnabled,
            managedCapabilities: managedCapabilities,
            serviceRoleIsConversation: serviceRoleIsConversation,
            defaultModelIntent: intent,
            providerEnabled: isEnabled
        ))
    }
}

/// Immutable, validated content of one Save tap. Constructed on the main
/// actor from the editor's current fields; no later field mutation can affect
/// a save that already started.
///
/// The raw initializer is internal on purpose: the supported public
/// construction path is `ProviderSaveDraft.makeRequest()`, which validates.
/// `ProviderSaveRunner.run` re-validates before any side effect so even a
/// same-module test request cannot cause writes.
public struct ProviderSaveRequest: Sendable, Equatable {
    public let profile: ProviderProfile
    public let selectedModels: [ModelProfile]
    /// UTF-8 secret entered for THIS save, or nil to keep the existing
    /// Keychain item untouched. Never persisted to SQLite/CloudKit.
    public let apiKey: String?
    /// Frozen Keychain-sync preference applied before the secret write. Kept
    /// explicitly because a provider without any secret has a nil
    /// `secretRef` and would otherwise fall back to `true`.
    public let syncEnabled: Bool
    public let managedCapabilities: ModelCapabilities
    public let serviceRoleIsConversation: Bool
    /// Snapshot of the editor's routing choice at Save time.
    public let defaultModelIntent: DefaultModelIntent
    public let providerEnabled: Bool

    public enum DefaultModelIntent: Sendable, Equatable {
        /// User selected this model as default (identified by remote id).
        case chosen(remoteModelID: String)
        /// No explicit choice; apply the existing fallback rules.
        case automatic
    }

    init(
        profile: ProviderProfile,
        selectedModels: [ModelProfile],
        apiKey: String?,
        syncEnabled: Bool,
        managedCapabilities: ModelCapabilities,
        serviceRoleIsConversation: Bool,
        defaultModelIntent: DefaultModelIntent,
        providerEnabled: Bool
    ) {
        self.profile = profile
        self.selectedModels = selectedModels
        self.apiKey = apiKey
        self.syncEnabled = syncEnabled
        self.managedCapabilities = managedCapabilities
        self.serviceRoleIsConversation = serviceRoleIsConversation
        self.defaultModelIntent = defaultModelIntent
        self.providerEnabled = providerEnabled
    }
}

/// Outcome of running a frozen save request.
public enum ProviderSaveRunResult: Sendable, Equatable {
    /// Local commit and readback succeeded. `syncPending` is true when the
    /// local bytes are durable but CloudKit delivery did not complete; that is
    /// reported separately from a save failure.
    case committed(canonicalModels: [ModelProfile], syncPending: Bool, syncError: String?)
}

/// Error thrown by the runner at a specific, user-classifiable phase.
public enum ProviderSaveRunError: Error, Sendable, Hashable {
    /// The request failed the canonical validation gate before any side
    /// effect (a caller bypassed `ProviderSaveDraft`, or the rule changed).
    /// Nothing was written.
    case invalidRequest([ProviderConfigurationProblem])
    /// Another save for the same provider is already in flight. The actor can
    /// suspend at awaits, so concurrent runs are rejected instead of being
    /// silently interleaved.
    case concurrentSaveRejected
    /// Keychain sync-preference change or secret write failed. The local
    /// configuration transaction never ran; only credential state may differ.
    case credentialOrSync(String)
    /// Local SQLite bundle commit failed.
    case localCommit(String)
    /// Persisted readback did not match the frozen request.
    case readbackMismatch(String)

    public var phase: String {
        switch self {
        case .invalidRequest: "invalid_request"
        case .concurrentSaveRejected: "concurrent_rejected"
        case .credentialOrSync: "credential_or_sync"
        case .localCommit: "local_commit"
        case .readbackMismatch: "readback"
        }
    }
}

extension ProviderSaveRunError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let problems):
            return "provider save request failed validation: \(problems.map(\.rawValue).joined(separator: ","))"
        case .concurrentSaveRejected:
            return "another save for this provider is already running"
        case .credentialOrSync(let detail),
             .localCommit(let detail),
             .readbackMismatch(let detail):
            return detail
        }
    }
}

/// Fixed lifecycle stage reached while running a save. Mirrors the editor's
/// secret-free diagnostics; never carries user content.
public enum ProviderSavePhaseEvent: String, Sendable {
    case setSync = "set_sync"
    case writeSecret = "write_secret"
    case bundleSave = "bundle_save"
    case readback
}

/// Optional sink for save-phase diagnostics.
public protocol ProviderSavePhaseReporting: Sendable {
    func providerSaveReachedPhase(_ phase: ProviderSavePhaseEvent)
}

/// Runs a frozen provider save request through injected gateways.
///
/// Concurrency contract: the actor can suspend at awaits, so it explicitly
/// rejects a second run for a provider whose save is still in flight
/// (`concurrentSaveRejected`) instead of interleaving writes. The editor's
/// `isSaving` guard covers the same form; this guard covers any other caller.
public actor ProviderSaveRunner {
    private let secretStore: ProviderSecretSaving
    private let committer: ProviderBundleCommitting
    private let phaseReporter: ProviderSavePhaseReporting?
    private var inFlightProviderIDs: Set<UUID> = []

    public init(
        secretStore: ProviderSecretSaving,
        committer: ProviderBundleCommitting,
        phaseReporter: ProviderSavePhaseReporting? = nil
    ) {
        self.secretStore = secretStore
        self.committer = committer
        self.phaseReporter = phaseReporter
    }

    /// Executes the save. Throws a phase-specific `ProviderSaveRunError`.
    @discardableResult
    public func run(_ request: ProviderSaveRequest) async throws -> ProviderSaveRunResult {
        // 0) Re-validate the frozen content BEFORE any side effect. Public
        // construction goes through ProviderSaveDraft.makeRequest(), but this
        // guard means even a same-module caller with the internal initializer
        // cannot cause credential/database writes from an invalid request.
        let issues = ProviderConfigurationValidation.issues(
            provider: request.profile,
            models: request.selectedModels
        )
        guard issues.isEmpty else {
            throw ProviderSaveRunError.invalidRequest(issues.map(\.problem))
        }

        // 0b) Single-flight per provider. Actor reentrancy means a second
        // call can start while this one awaits; reject rather than interleave.
        guard inFlightProviderIDs.insert(request.profile.id).inserted else {
            throw ProviderSaveRunError.concurrentSaveRejected
        }
        defer { inFlightProviderIDs.remove(request.profile.id) }

        // 1) Keychain sync preference, then 2) secret write — both BEFORE any
        // configuration write, against the frozen snapshot. `syncEnabled` is
        // carried explicitly: a provider without a secret has a nil secretRef
        // and must not silently flip to the default `true`.
        do {
            phaseReporter?.providerSaveReachedPhase(.setSync)
            try await secretStore.setSyncEnabled(
                request.syncEnabled,
                for: request.profile.id
            )
            phaseReporter?.providerSaveReachedPhase(.writeSecret)
            if let key = request.apiKey,
               let data = key.data(using: .utf8), !data.isEmpty {
                try await secretStore.storeSecret(data, scopeProviderID: request.profile.id)
            }
        } catch {
            throw ProviderSaveRunError.credentialOrSync(
                SecretRedactor.redact(error.localizedDescription)
            )
        }

        // 3) Local bundle commit (provider + models in one transaction). A
        // local commit that succeeded but could not enqueue sync reports
        // syncPending instead of failing the save.
        phaseReporter?.providerSaveReachedPhase(.bundleSave)
        let commit: ProviderBundleCommitResult
        do {
            commit = try await committer.commitProviderBundle(request)
        } catch {
            throw ProviderSaveRunError.localCommit(
                SecretRedactor.redact(error.localizedDescription)
            )
        }

        // 4) Persisted readback BEFORE reporting success.
        phaseReporter?.providerSaveReachedPhase(.readback)
        if let reason = await committer.verifyProviderPersisted(request) {
            throw ProviderSaveRunError.readbackMismatch(reason)
        }

        return .committed(
            canonicalModels: commit.saved,
            syncPending: commit.syncPending,
            syncError: commit.syncError
        )
    }
}
