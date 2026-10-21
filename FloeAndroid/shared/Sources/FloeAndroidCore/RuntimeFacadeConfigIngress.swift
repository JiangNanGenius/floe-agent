// SPDX-License-Identifier: MPL-2.0
//
// RB2 — provider save ingress: one-shot `int:v1:` lease consumption, frozen
// candidate binding, and the ORIGINAL draft→runner authority chain, REPAIRED
// per MAIN_SOURCE_REVIEW_20261019.json MC-R1/R3/R4. REPAIR successor of
// job-d02beb16bd1840a9 (private source candidate; NOT compiled, NOT
// executed; see REPORT.md limitations).
//
// Repair delta over the parent:
// * MC-R1 — the executor stages the PREPARE observation (row absent vs
//   revision base) into the committer's durable same-writer CAS; the
//   provider row's persisted revision ADVANCES by one on every accepted
//   bundle write (store mirror), Int64.max refuses typed BEFORE any effect,
//   and post-write CAS rejection is reported honestly (typed staleRevision
//   + the secret-side physical truth + `databaseRowWritten` derived from the
//   committer's ACTUAL committed-stage evidence).
// * MC-R3 — clear/delete post-processing finalizes the cleanup entry ONLY on
//   the operation's own committed completion; pre-ticket
//   invalidReference/invalidValue rejections keep the durable entry and
//   report retryable diagnostics (never already-absent, never removed).
// * MC-R4 — the parent's unconditional `ownedWork.settle + endOperation`
//   after EVERY outcome is replaced by physical-truth-driven retention:
//   outcomes whose INDIVIDUAL mailbox signal proves never-executed or
//   completed release normally; outcomes that are physically outstanding (or
//   unobserved-ambiguous) PARK the exact ticket + retained registry lease +
//   receipt into the shared coordinator and surface a typed
//   providerPendingReconciliation so the drain/save retry path reconciles
//   via the real signal or process restart. New-resource Set records the
//   durable `.secretWrite` cleanup intent BEFORE the first native effect.
// * The begin seam is exact-ticket and shared-context
//   (ProviderOperationCoordinator): a same-kind tokenless release can never
//   free a later owner; two facades over one DatabaseManager coordinate or
//   reject instead of each running a private gate.
//
// Bound to ACTUAL reviewed source (no imagined methods) — unchanged from the
// parent:
// * SecretSaveIntentVault.consume(token:route:expectedSubject:) —
//   SecretSaveIntentVault.swift:220-271. One-shot: the LIVE slot is zeroized
//   on ANY consume outcome; wrong route token/generation, wrong subject,
//   expiry, replay and saturation map to typed IntentRejections
//   (SecretGatewayMailbox.swift:22-32). The lease is the typed NON-Sendable
//   SaveIntentLease (:67-110): candidateJSON + secret live ONLY in this
//   owned scope; close() zeroizes and releases the admission; a failed close
//   keeps the admission recorded fail-closed against the cap (:93-109). The
//   vault API is module-internal and the C ABI exports ONLY submit/discard
//   (:526-581), so the intended Swift-side consumer is exactly this
//   FloeAndroidCore facade layer. NO change to the vault/lease semantics:
//   the no-secret-JSON binary intent lease is preserved exactly.
// * ProviderSaveDraft.makeRequest() — FloeCore ProviderSaveRunner.swift
//   :146-232: the ONLY supported public construction of the frozen request
//   (the raw ProviderSaveRequest init is internal to FloeCore by design,
//   :239-284), including the connection-bound credential-reuse refusal
//   (:157-180) and the deterministic `provider.<uuid>` account mint
//   (:181-186). RB2 never edits the draft/runner; the ADVANCE policy lives
//   at the durable store boundary (mirror) with the executor staging the
//   observed expectation.
// * ProviderSaveRunner.run — :376-442 phase order
//   revalidate → single-flight → setSync → writeSecret → bundleSave →
//   readback, consumed VERBATIM; RB2 supplies only the Android
//   ProviderSecretSaving (file 2) and ProviderBundleCommitting (file 3).
//   Phase attribution comes from the frozen `ProviderSaveRunError.phase`
//   (:313-321) plus the secret store's recorded write/physical state — no
//   parallel phase machinery is invented.
// * BRIDGE_V3_MAIN_DECISIONS.credentialGatewayDownstreamIngress +
//   identity clarification: the intent is bound to the FROZEN candidate +
//   host route/generation + base revision BEFORE any secret or DB effect;
//   raw UI bytes never enter JSON; a cancellation/route close/replacement
//   cannot write a key onto another save (one-shot consume, subject/route
//   equality at consume, revision CAS against the actual row, close
//   zeroizes).
// * localSync: a candidate asking syncEnabled == true is refused TYPED
//   BEFORE any effect — never a claimed cross-device success, never a
//   phantom error on ordinary (false) saves.
//
// The candidate JSON schema below is RB2-owned (unchanged from the parent):
// it is the frozen user candidate captured at save-tap by the Kotlin host
// and stored inside the lease (:389-404 already enforces candidate.id ==
// subject.id and the closed provider/mcp cross-field rules). It carries NO
// secret material and NO route fields — the route is checked by the vault;
// model-authored JSON cannot mint authority by adding id/intent/route fields
// (closed whitelist + ConfigJSON credential-name refusal below).

import Foundation
import FloeCore
import FloePersistence

// MARK: - Frozen candidate schema (closed; secret-free)

public struct ProviderSaveCandidate: Sendable, Equatable {
    public let providerID: UUID
    public let kind: ProviderKind
    public let wireProtocol: ModelProtocol
    public let baseURLString: String
    public let displayName: String
    public let presetID: String?
    public let nonSecretHeaders: [String: String]
    public let isEnabled: Bool
    public let allowsPlainHTTP: Bool
    public let toolNameCompatibility: Bool
    public let syncEnabled: Bool
    public let selectedModels: [ModelProfile]
    public let managedCapabilities: ModelCapabilities
    public let serviceRoleIsConversation: Bool
    public let defaultModelID: UUID?
    /// Explicit create-intent marker (new provider). Edits bind the actual
    /// revision instead; RB2 never fabricates a resource version.
    public let createIntent: Bool
    /// Large-profile alternative representation: the canonical frozen
    /// reference `ms:v1:<32hex>.<64hex>` of a trusted-host staged model
    /// set (RuntimeFacadeProviderModelSets). Mutually exclusive with
    /// inline `selectedModels` — exactly one representation is parsed,
    /// never both, never neither. The executor resolves it into typed
    /// models BEFORE any effect; nothing downstream of prepare ever sees
    /// the reference (the frozen draft/runner/bundle chain is unchanged).
    public let modelSetRef: String?

    /// Closed wire keys. Anything else is refused BEFORE decoding
    /// (ConfigJSON.closed), so a smuggled field can never widen the draft.
    static let allowedKeys: Set<String> = [
        "id", "kind", "wireProtocol", "baseURL", "displayName", "presetID",
        "nonSecretHeaders", "isEnabled", "allowsPlainHTTP",
        "toolNameCompatibility", "syncEnabled", "selectedModels",
        "modelSetRef", "managedCapabilities", "serviceRoleIsConversation",
        "defaultModelID", "createIntent",
    ]

    static func parse(_ dictionary: [String: Any]) throws -> ProviderSaveCandidate {
        try ConfigJSON.closed(dictionary,
                              allowed: allowedKeys,
                              required: ["id", "kind", "wireProtocol", "baseURL",
                                         "displayName", "syncEnabled",
                                         "managedCapabilities",
                                         "serviceRoleIsConversation"],
                              context: "candidate")
        // Exactly ONE model representation (Main direction B): inline
        // selectedModels XOR a staged modelSetRef. A mixed or missing form
        // is a pre-effect typed refusal — never an ambiguity resolved by
        // guessing, never a silent precedence rule.
        let hasInline = dictionary["selectedModels"] != nil
        let hasRef = dictionary["modelSetRef"] != nil
        guard hasInline != hasRef else {
            throw ConfigDomainError(code: .invalidEnvelope,
                                    reason: hasInline ? "candidateModelFormMixed"
                                                      : "candidateModelsMissing")
        }
        guard let idString = dictionary["id"] as? String,
              let providerID = UUID(uuidString: idString) else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "candidate.id")
        }
        guard let kindRaw = dictionary["kind"] as? String,
              let kind = ProviderKind(rawValue: kindRaw) else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "candidate.kind")
        }
        // ALL native cloud kinds stay supported (openAI, anthropic,
        // volcengineArk, alibabaStudio, googleGemini, local, custom —
        // ProviderProfile.swift:7-15). Decoding through the ORIGINAL enum
        // rawValue means no kind can be silently dropped or narrowed away.
        guard let protocolRaw = dictionary["wireProtocol"] as? String,
              let wireProtocol = ModelProtocol(rawValue: protocolRaw) else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "candidate.wireProtocol")
        }
        guard let baseURLString = dictionary["baseURL"] as? String,
              !baseURLString.isEmpty,
              baseURLString.utf8.count <= 2_048 else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "candidate.baseURL")
        }
        guard let displayName = dictionary["displayName"] as? String else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "candidate.displayName")
        }
        var presetID: String?
        switch dictionary["presetID"] {
        case .none:
            presetID = nil
        case is NSNull:
            presetID = nil
        case let preset as String:
            guard !preset.isEmpty, preset.utf8.count <= 64 else {
                throw ConfigDomainError(code: .invalidEnvelope, reason: "candidate.presetID")
            }
            presetID = preset
        default:
            throw ConfigDomainError(code: .invalidEnvelope, reason: "candidate.presetID")
        }
        var headers: [String: String] = [:]
        switch dictionary["nonSecretHeaders"] {
        case .none, is NSNull:
            break
        case let headerObject as [String: Any]:
            for (name, value) in headerObject {
                guard let value = value as? String else {
                    throw ConfigDomainError(code: .invalidEnvelope,
                                            reason: "candidate.headerValue")
                }
                headers[name] = value
            }
            // Belt for the original rules: forbidden-header names are
            // refused here AND by ProviderConfigurationValidation during
            // makeRequest (its forbidden set: authorization,
            // proxy-authorization, x-api-key, api-key, x-auth-token,
            // x-amz-security-token, cookie, set-cookie — ProviderConfigura
            // tionValidation.swift:560-563).
            try ConfigJSON.assertNoCredentialMapKeys(headers,
                                                     context: "candidate.nonSecretHeaders")
        default:
            throw ConfigDomainError(code: .invalidEnvelope, reason: "candidate.nonSecretHeaders")
        }
        guard let syncEnabled = dictionary["syncEnabled"] as? Bool else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "candidate.syncEnabled")
        }
        let isEnabled = (dictionary["isEnabled"] as? Bool) ?? true
        let allowsPlainHTTP = (dictionary["allowsPlainHTTP"] as? Bool) ?? false
        let toolNameCompatibility = (dictionary["toolNameCompatibility"] as? Bool) ?? false
        guard let serviceRole = dictionary["serviceRoleIsConversation"] as? Bool else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "candidate.serviceRole")
        }
        var models: [ModelProfile] = []
        var modelSetRef: String?
        if hasInline {
            guard let modelsArray = dictionary["selectedModels"] as? [Any] else {
                throw ConfigDomainError(code: .invalidEnvelope, reason: "candidate.selectedModels")
            }
            guard modelsArray.count <= 512 else {
                throw ConfigDomainError(code: .payloadTooLarge,
                                        reason: "candidate.selectedModelsCount")
            }
            models.reserveCapacity(modelsArray.count)
            for element in modelsArray {
                models.append(try ConfigModelSnapshot.decode(element, context: "candidate.model"))
            }
        } else {
            // The frozen staged reference: exact canonical grammar only.
            // Resolution happens in the executor BEFORE ownership/effects
            // (binding/digest/epoch/route checks there, typed refusal
            // here for a malformed token).
            guard let raw = dictionary["modelSetRef"] as? String,
                  ProviderModelSetRef.parse(raw) != nil else {
                throw ConfigDomainError(code: .invalidEnvelope, reason: "candidate.modelSetRef")
            }
            modelSetRef = raw
        }
        let capabilities = try ConfigJSON.decodeCanonical(ModelCapabilities.self,
                                                          from: dictionary["managedCapabilities"] as Any,
                                                          context: "candidate.managedCapabilities")
        var defaultModelID: UUID?
        switch dictionary["defaultModelID"] {
        case .none, is NSNull:
            defaultModelID = nil
        case let chosen as String:
            guard let uuid = UUID(uuidString: chosen) else {
                throw ConfigDomainError(code: .invalidEnvelope, reason: "candidate.defaultModelID")
            }
            defaultModelID = uuid
        default:
            throw ConfigDomainError(code: .invalidEnvelope, reason: "candidate.defaultModelID")
        }
        let createIntent = (dictionary["createIntent"] as? Bool) ?? false
        return ProviderSaveCandidate(
            providerID: providerID,
            kind: kind,
            wireProtocol: wireProtocol,
            baseURLString: baseURLString,
            displayName: displayName,
            presetID: presetID,
            nonSecretHeaders: headers,
            isEnabled: isEnabled,
            allowsPlainHTTP: allowsPlainHTTP,
            toolNameCompatibility: toolNameCompatibility,
            syncEnabled: syncEnabled,
            selectedModels: models,
            managedCapabilities: capabilities,
            serviceRoleIsConversation: serviceRole,
            defaultModelID: defaultModelID,
            createIntent: createIntent,
            modelSetRef: modelSetRef
        )
    }

    /// Staged-reference candidates become the EXACT same typed candidate
    /// the inline path produces once the registry resolves the frozen set:
    /// the resolved models replace the reference and every downstream
    /// authority (ProviderSaveDraft.makeRequest, the runner phases, the
    /// atomic bundle writer, CAS, cleanup, retention) continues UNCHANGED.
    /// The reference itself never reaches the draft.
    func withResolvedModels(_ models: [ModelProfile]) -> ProviderSaveCandidate {
        ProviderSaveCandidate(
            providerID: providerID,
            kind: kind,
            wireProtocol: wireProtocol,
            baseURLString: baseURLString,
            displayName: displayName,
            presetID: presetID,
            nonSecretHeaders: nonSecretHeaders,
            isEnabled: isEnabled,
            allowsPlainHTTP: allowsPlainHTTP,
            toolNameCompatibility: toolNameCompatibility,
            syncEnabled: syncEnabled,
            selectedModels: models,
            managedCapabilities: managedCapabilities,
            serviceRoleIsConversation: serviceRoleIsConversation,
            defaultModelID: defaultModelID,
            createIntent: createIntent,
            modelSetRef: nil
        )
    }

    /// Map onto the ORIGINAL draft. `existingSecretRef`, createdAt and the
    /// base syncRevision come ONLY from the actual persisted row (never the
    /// wire), preserving the credential-reuse/connection rules
    /// (ProviderSaveRunner.swift:157-180,:202-204).
    func makeDraft(existingRow: ProviderProfile?,
                   enteredAPIKey: String,
                   dropExistingSecret: Bool = false) -> ProviderSaveDraft {
        ProviderSaveDraft(
            providerID: providerID,
            kind: kind,
            wireProtocol: wireProtocol,
            baseURLString: baseURLString,
            displayName: displayName,
            presetID: presetID,
            existingSecretRef: dropExistingSecret ? nil : existingRow?.secretRef,
            nonSecretHeaders: nonSecretHeaders,
            isEnabled: isEnabled,
            allowsPlainHTTP: allowsPlainHTTP,
            toolNameCompatibility: toolNameCompatibility,
            syncEnabled: false, // sync-true was refused before reaching here
            enteredAPIKey: enteredAPIKey,
            selectedModels: selectedModels,
            managedCapabilities: managedCapabilities,
            serviceRoleIsConversation: serviceRoleIsConversation,
            defaultModelID: defaultModelID,
            existingCreatedAt: existingRow?.createdAt,
            existingSyncRevision: existingRow?.syncRevision ?? 0,
            existingBaseURL: existingRow?.baseURL,
            existingKind: existingRow?.kind
        )
    }
}

// MARK: - Executor results

public enum ProviderSaveExecution: Sendable {
    public struct Committed: Sendable {
        public let providerID: UUID
        /// ACTUAL canonical models from the ORIGINAL store result. The
        /// runner reaches `committed` only after the readback phase passed
        /// (ProviderSaveRunner.swift:431-435), so canonical == verified.
        public let canonicalModels: [ModelProfile]
        public let deletedModelIDs: [UUID]
        public let disabledModelIDs: [UUID]
        /// Local-only truth carried from the ORIGINAL result fields (the
        /// Android committer always reports false/nil for ordinary saves).
        public let syncPending: Bool
        public let syncError: String?
        /// MC-R1: the ACTUAL PERSISTED provider revision (base + 1), never
        /// the frozen draft base. This is the token later edits/deletes must
        /// present.
        public let providerRevision: ConfigRevision
        /// MC-R1 fix: honest preset-sidecar stage flag (false = bundle
        /// committed, sidecar not yet recorded; converges on the next save;
        /// NEVER relabeled as a save failure/rollback).
        public var presetSidecarRecorded: Bool
        /// MC-R4: true when the create-path `.secretWrite` durable intent
        /// entry was compare-and-delete finalized after this commit. False
        /// keeps the entry for drain reconciliation (row-present branch
        /// never deletes a live reference).
        public var writeIntentFinalized: Bool
        /// True when SaveIntentLease.close() failed: the bounded ACTIVE
        /// admission stays recorded (vault fail-closed cap). Diagnostic
        /// only — never a secret; never retried by RB2.
        public var leaseAdmissionCloseFailed: Bool
        /// Compact-metadata keep: true when the committed write was the
        /// ORIGINAL provider-row enabled/disabled CAS ONLY (Main
        /// MAIN_PROVIDER_COMPACT_METADATA_DECISION_20261021). Models,
        /// presets, preferences and credential references are provably
        /// untouched because no other column or row was written. The
        /// persisted revision in `providerRevision` is the actual advanced
        /// value, never an optimistic guess.
        public var metadataOnly: Bool = false
    }
    case committed(Committed)

    public struct Failed: Sendable {
        public let error: ConfigDomainError
        /// Honest cross-store state at the failure point (C0/C1/committed).
        public let secretDisposition: SecretEffectDisposition?
        public let databaseRowWritten: Bool
        /// One of the ORIGINAL frozen phase strings (invalid_request/
        /// concurrent_rejected/credential_or_sync/local_commit/readback),
        /// or an RB2 pre-effect marker ("binding"/"validate"/"lease"/
        /// "bind"/"cleanupEnqueue"/"ownedWork"/"unknown").
        public let phase: String?
        /// MC-R4: the INDIVIDUAL physical settlement for the last secret
        /// effect of this chain (nil ⇒ no secret effect was attempted).
        public var physicalSettlement: PhysicalSettlement? = nil
        /// MC-R4: the individual physical receipt when the gateway exposed
        /// one (basis for later reconciliation; metadata only, no bytes).
        public var physicalReceipt: PhysicalOperationReceipt? = nil
        /// MC-R4: true when the owner gate + runtime registry lease were
        /// RETAINED (pending owner) because the physical lifetime is
        /// unsettled. New operations on this provider report
        /// providerPendingReconciliation until the real signal settles.
        public var pendingReconciliation: Bool = false
        public var leaseAdmissionCloseFailed: Bool

        /// MC-R4 retention predicate for this failure.
        var requiresOwnerRetention: Bool {
            switch physicalSettlement {
            case .executionOutstanding:
                return true
            case .unobserved:
                if case .outcomeUnknown? = secretDisposition { return true }
                return false
            case .neverExecuted, .executionSettled, .none:
                return false
            }
        }
    }
    case failed(Failed)

    public struct Cleared: Sendable {
        public let providerID: UUID
        public let cleanupDisposition: SecretEffectDisposition
        /// True when the durable secretClear entry was NOT finalized (kept
        /// for the drain — MC-R3: every non-committed disposition keeps it,
        /// including pre-ticket validation rejections).
        public let cleanupQueuedForRetry: Bool
        /// MC-R4 physical settlement for the clear's delete attempt.
        public let physicalSettlement: PhysicalSettlement?
        public let physicalReceipt: PhysicalOperationReceipt?
        public var pendingReconciliation: Bool
        public var leaseAdmissionCloseFailed: Bool

        var requiresOwnerRetention: Bool {
            switch physicalSettlement {
            case .executionOutstanding:
                return true
            case .unobserved:
                if case .outcomeUnknown = cleanupDisposition { return true }
                return false
            case .neverExecuted, .executionSettled, .none:
                return false
            }
        }
    }
    /// Clear intent: the bundle committed WITHOUT a secret reference and
    /// the deterministic old reference took its recovery path.
    case cleared(Cleared)

    /// Apply the post-scope lease-close outcome without duplicating the
    /// chain logic (the flag lives on every terminal shape). `didClose` is
    /// the TRUE result of `SaveIntentLease.close()`: release succeeded.
    ///
    /// Polarity repair (Main's provider-save-chain diagnostic finding): the
    /// flag marks ONLY a REAL close failure. A successful release leaves the
    /// terminal shape unchanged; the previous inversion stamped
    /// `leaseAdmissionCloseFailed = true` exactly when close SUCCEEDED.
    /// Nothing here retries the close, swallows a genuine failure, releases
    /// an ACTIVE lease early or changes the physical cleanup semantics: a
    /// failed close still keeps the bounded admission recorded and the
    /// vault cap fail-closed, and the flag stays diagnostic-only.
    func applyingLeaseClose(_ didClose: Bool) -> ProviderSaveExecution {
        guard !didClose else { return self }
        switch self {
        case .committed(var value):
            value.leaseAdmissionCloseFailed = true
            return .committed(value)
        case .failed(var value):
            value.leaseAdmissionCloseFailed = true
            return .failed(value)
        case .cleared(var value):
            value.leaseAdmissionCloseFailed = true
            return .cleared(value)
        }
    }

    /// MC-R4: stamp the retention result after runCandidate decides settle
    /// vs park. `parked` true means the owner ticket + registry lease were
    /// retained by the shared coordinator (or, at pending-capacity
    /// saturation, the RUNNING slot itself stays held — never a fake
    /// release).
    func applyingOwnerRetention(_ parked: Bool) -> ProviderSaveExecution {
        switch self {
        case .committed(let value):
            return .committed(value)
        case .failed(var value):
            value.pendingReconciliation = parked
            return .failed(value)
        case .cleared(var value):
            value.pendingReconciliation = parked
            return .cleared(value)
        }
    }
}

// MARK: - Lease rejection mapping

enum SaveIntentConsumption {
    /// Maps the ACTUAL typed vault errors onto frozen wire codes. No reason
    /// string ever carries candidate or secret content.
    static func mapRejection(_ error: Error) -> ConfigDomainError {
        if let backend = error as? SecretBackendError {
            switch backend {
            case .intentRejected(let rejection):
                switch rejection {
                case .unknownToken:
                    return ConfigDomainError(code: .notFound, reason: "saveIntentUnknown")
                case .consumed:
                    // Frozen-ingress REPLAY lands here: the one-shot slot is
                    // spent; nothing is written, ever.
                    return ConfigDomainError(code: .notFound, reason: "saveIntentAlreadyConsumed")
                case .expired:
                    return ConfigDomainError(code: .notFound, reason: "saveIntentExpired")
                case .routeMismatch:
                    // Route close/replacement: the frozen token/generation
                    // no longer equals the live host route. NEVER writes
                    // another candidate/secret.
                    return ConfigDomainError(code: .invalidEnvelope, reason: "saveIntentRouteMismatch")
                case .subjectMismatch:
                    // A provider id is never an MCP identity and vice versa
                    // (closed SubjectKind vocabulary, SecretGatewayMailbox
                    // .swift:62-65; candidate cross-field rules,
                    // SecretSaveIntentVault.swift:399-404).
                    return ConfigDomainError(code: .invalidEnvelope, reason: "saveIntentSubjectMismatch")
                case .envelopeDivergence:
                    return ConfigDomainError(code: .invalidEnvelope, reason: "saveIntentDivergence")
                case .createConflict:
                    return ConfigDomainError(code: .invalidEnvelope, reason: "saveIntentCreateConflict")
                case .baseRevisionConflict:
                    return ConfigDomainError(code: .staleRevision, reason: "saveIntentBaseRevision")
                case .intentSaturated:
                    return ConfigDomainError(code: .mailboxSaturated, reason: "saveIntentLeasesSaturated")
                }
            case .gatewayClosed:
                return ConfigDomainError(code: .runtimeUnavailable, reason: "gatewayClosed")
            default:
                return ConfigDomainError(code: .runtimeUnavailable, reason: "gatewayTransient")
            }
        }
        if error is SaveIntentVaultError {
            return ConfigDomainError(code: .invalidEnvelope, reason: "saveIntentSchema")
        }
        return ConfigDomainError(code: .runtimeUnavailable, reason: "saveIntentConsumeFailed")
    }
}

// MARK: - Executor

/// Owns the save/clear authority chain and the MC-R4 owner-lifetime
/// decision. The facade serializes command entry and binds the trusted
/// route; the ORIGINAL runner keeps its own per-provider single-flight. All
/// secret/DB effect ordering decisions live in this one type.
actor ProviderSaveExecutor: ProviderPendingReconciling {
    let secretStore: AndroidProviderSecretStore
    let committer: ModelConfigurationCommitter
    let runner: ProviderSaveRunner
    private let store: ModelConfigurationStore
    private let cleanup: ProviderSecretCleanup
    private let ownership: any ProviderOperationOwning
    private let ownedWork: ConfigOwnedWorkLifecycle

    init(database: DatabaseManager,
         gateway: any SecretGatewayServicing,
         ownership: any ProviderOperationOwning,
         ownedWork: ConfigOwnedWorkLifecycle,
         committerFault: ProviderCommitFaultPoint? = nil,
         secretWriteFault: (@Sendable (String, Int) async throws -> Void)? = nil) {
        let store = ModelConfigurationStore(database: database)
        self.store = store
        self.ownership = ownership
        self.ownedWork = ownedWork
        self.secretStore = AndroidProviderSecretStore(gateway: gateway,
                                                      faultSeam: secretWriteFault)
        self.committer = ModelConfigurationCommitter(database: database,
                                                     faultPoint: committerFault)
        self.cleanup = ProviderSecretCleanup(database: database)
        // The ORIGINAL phase-reporting sink is optional (:348-351). Phase
        // attribution for classification uses the frozen
        // `ProviderSaveRunError.phase` plus the secret store's recorded
        // write state — RB2 does not invent a parallel phase bus.
        self.runner = ProviderSaveRunner(secretStore: self.secretStore,
                                         committer: self.committer,
                                         phaseReporter: nil)
    }

    var cleanupQueue: ProviderSecretCleanup { cleanup }

    // MARK: Set (lease-bound)

    func saveSet(token: String,
                 route: RouteBinding,
                 envelopeRevision: ConfigRevision?) async -> ProviderSaveExecution {
        let lease: SaveIntentLease
        do {
            lease = try SecretSaveIntentVault.shared.consume(token: token,
                                                             route: route,
                                                             expectedSubject: .providerSave)
        } catch {
            return .failed(.init(error: SaveIntentConsumption.mapRejection(error),
                                 secretDisposition: nil,
                                 databaseRowWritten: false,
                                 phase: "lease",
                                 physicalSettlement: nil,
                                 physicalReceipt: nil,
                                 pendingReconciliation: false,
                                 leaseAdmissionCloseFailed: false))
        }
        let execution = await runCandidate(lease.candidateJSON,
                                           leaseSecret: lease.secret,
                                           leaseBaseRevision: lease.baseRevision,
                                           envelopeRevision: envelopeRevision,
                                           clearSecret: false)
        return execution.applyingLeaseClose(lease.close())
    }

    // MARK: Keep / Clear (envelope-bound, no secret bytes)

    func saveKeep(candidateJSON: Data,
                  envelopeRevision: ConfigRevision?) async -> ProviderSaveExecution {
        await runCandidate(candidateJSON,
                           leaseSecret: nil,
                           leaseBaseRevision: nil,
                           envelopeRevision: envelopeRevision,
                           clearSecret: false)
    }

    func saveClear(candidateJSON: Data,
                   envelopeRevision: ConfigRevision?) async -> ProviderSaveExecution {
        await runCandidate(candidateJSON,
                           leaseSecret: nil,
                           leaseBaseRevision: nil,
                           envelopeRevision: envelopeRevision,
                           clearSecret: true)
    }

    // MARK: Compact existing-row enabled/disabled metadata (Main decision
    // MAIN_PROVIDER_COMPACT_METADATA_DECISION_20261021)

    /// The CLOSED existing-row KEEP metadata variant of the SAME
    /// `config.provider.save` command: flips ONLY `is_enabled` (+ the
    /// original update/advance revision semantics) on the ACTUAL persisted
    /// provider row under the SAME per-provider `.save` ownership
    /// reservation and the SAME Root-owned owned-work lease the ordinary
    /// save chain takes. It never serializes model rows, never deserializes
    /// them across JNI, never reads or writes any secret, and never opens
    /// a second lock/DB/gateway path. Every other provider column
    /// (endpoint/headers/preset-relevant fields/secret_ref account string/
    /// region/flags/created_at) and every model row stays byte-identical:
    /// the durable write is a narrow three-column CAS in the ONE original
    /// writer transaction (ModelConfigurationStore mirror, same additive
    /// discipline as MC-R1). A pending physical reconciliation is REJECTED
    /// (`providerPendingReconciliation`), never bypassed. The reply is the
    /// ACTUAL committed advanced revision, never an optimistic toggle.
    func saveMetadataEnabled(providerID: UUID, isEnabled: Bool,
                             envelopeRevision: ConfigRevision?) async -> ProviderSaveExecution {
        func refusal(_ error: ConfigDomainError) -> ProviderSaveExecution {
            .failed(.init(error: error, secretDisposition: nil,
                          databaseRowWritten: false, phase: "binding",
                          physicalSettlement: nil, physicalReceipt: nil,
                          pendingReconciliation: false,
                          leaseAdmissionCloseFailed: false))
        }
        // Exact resource + version required: a metadata write without a
        // real CAS binding would be an optimistic toggle — refused.
        guard let revision = envelopeRevision else {
            return refusal(ConfigDomainError(code: .invalidEnvelope,
                                             reason: "providerMetadataRevisionMissing"))
        }
        guard revision.resourceID == "provider.\(providerID.uuidString)" else {
            return refusal(ConfigDomainError(code: .invalidEnvelope,
                                             reason: "revisionResourceMismatch"))
        }
        guard let expectedBase = Int64(revision.version), expectedBase >= 0 else {
            return refusal(ConfigDomainError(code: .invalidEnvelope,
                                             reason: "providerMetadataRevisionValue"))
        }
        // SAME per-provider save ownership (never a parallel lock): a
        // concurrent bundle save/cleanup on this provider conflicts; the
        // durable pending owner stays authoritative and is reconciled
        // through the real physical signal exactly like runCandidate.
        var ticket: ProviderOperationTicket?
        switch await ownership.beginOperation(providerID: providerID, kind: .save) {
        case .attached(let attached):
            ticket = attached
        case .conflict:
            return .failed(.init(error: ConfigDomainError(code: .duplicateInFlight,
                                                          reason: "providerOperationActive"),
                                 secretDisposition: nil,
                                 databaseRowWritten: false, phase: "ownership",
                                 physicalSettlement: nil, physicalReceipt: nil,
                                 pendingReconciliation: false,
                                 leaseAdmissionCloseFailed: false))
        case .capacityUnavailable:
            return .failed(.init(error: ConfigDomainError(
                code: .mailboxSaturated, reason: "providerOperationCapacityUnavailable"),
                                 secretDisposition: nil,
                                 databaseRowWritten: false, phase: "ownership",
                                 physicalSettlement: nil, physicalReceipt: nil,
                                 pendingReconciliation: false,
                                 leaseAdmissionCloseFailed: false))
        case .pendingReconciliation:
            _ = await reconcileProviderRecovery(providerID: providerID)
            if case .attached(let attached) = await ownership.beginOperation(
                providerID: providerID, kind: .save) {
                ticket = attached
            } else {
                return .failed(.init(error: ConfigDomainError(
                    code: .duplicateInFlight, reason: "providerPendingReconciliation"),
                                     secretDisposition: nil,
                                     databaseRowWritten: false, phase: "ownership",
                                     physicalSettlement: nil, physicalReceipt: nil,
                                     pendingReconciliation: true,
                                     leaseAdmissionCloseFailed: false))
            }
        }
        guard let ownedTicket = ticket else {
            return .failed(.init(error: ConfigDomainError(code: .runtimeUnavailable,
                                                          reason: "ownershipNotAttached"),
                                 secretDisposition: nil,
                                 databaseRowWritten: false, phase: "ownership",
                                 physicalSettlement: nil, physicalReceipt: nil,
                                 pendingReconciliation: false,
                                 leaseAdmissionCloseFailed: false))
        }
        let ownedLease: ConfigOwnedWorkLease
        switch ownedWork.begin(kind: .vaultMaintenance, ownerID: providerID.uuidString) {
        case .failure(let rejection):
            await ownership.endOperation(ownedTicket)
            return .failed(.init(error: Self.ownedWorkAttachError(rejection),
                                 secretDisposition: nil,
                                 databaseRowWritten: false, phase: "ownedWorkAttach",
                                 physicalSettlement: nil, physicalReceipt: nil,
                                 pendingReconciliation: false,
                                 leaseAdmissionCloseFailed: false))
        case .success(let lease):
            ownedLease = lease
        }
        // Act BEFORE releasing: every terminal path below settles the
        // lease and the exact ticket. There is no secret effect anywhere
        // on this path, so no physical-retention axis can exist; a DB
        // refusal is provably zero-mutation (single writer transaction).
        let execution = await runMetadata(providerID: providerID,
                                          isEnabled: isEnabled,
                                          expectedBase: expectedBase)
        ownedWork.settle(ownedLease)
        await ownership.endOperation(ownedTicket)
        return execution
    }

    private func runMetadata(providerID: UUID, isEnabled: Bool,
                             expectedBase: Int64) async -> ProviderSaveExecution {
        func refusal(_ error: ConfigDomainError, phase: String) -> ProviderSaveExecution {
            .failed(.init(error: error, secretDisposition: nil,
                          databaseRowWritten: false, phase: phase,
                          physicalSettlement: nil, physicalReceipt: nil,
                          pendingReconciliation: false,
                          leaseAdmissionCloseFailed: false))
        }
        let row: ProviderProfile?
        do {
            row = try await store.provider(id: providerID)
        } catch {
            return refusal(ConfigDomainError(code: .persistenceUnavailable,
                                             reason: "providerRowQueryFailed"),
                           phase: "binding")
        }
        guard let row else {
            return refusal(ConfigDomainError(code: .notFound,
                                             reason: "providerRowMissing"),
                           phase: "binding")
        }
        // Re-check the CAS binding against the ACTUAL row immediately
        // before the gated write (the durable transaction re-gates; this
        // keeps the honest phase attribution).
        guard row.syncRevision == expectedBase else {
            return refusal(ConfigDomainError(code: .staleRevision,
                                             reason: "providerMetadataEnvelopeRevision"),
                           phase: "binding")
        }
        guard row.syncRevision < Int64.max else {
            return refusal(ConfigDomainError(code: .staleRevision,
                                             reason: "providerRevisionExhausted"),
                           phase: "binding")
        }
        // Already at the requested state? The original service still
        // advances revision/time on an accepted write; the App pre-checks
        // the no-op, and a repeat here is an ordinary CAS-legal edit.
        do {
            let advanced = try await store.setProviderEnabled(
                providerID: providerID,
                enabled: isEnabled,
                expectedSyncRevision: expectedBase)
            return .committed(.init(providerID: providerID,
                                    canonicalModels: [],
                                    deletedModelIDs: [],
                                    disabledModelIDs: [],
                                    syncPending: false,
                                    syncError: nil,
                                    providerRevision: ConfigRevision.provider(
                                        id: providerID, syncRevision: advanced),
                                    // The metadata path never rewrites the
                                    // preset sidecar: its persisted state is
                                    // unchanged by definition, so reporting
                                    // "no pending sidecar stage" is honest.
                                    presetSidecarRecorded: true,
                                    writeIntentFinalized: true,
                                    leaseAdmissionCloseFailed: false,
                                    metadataOnly: true))
        } catch is ModelConfigurationRevisionConflict {
            // The durable same-writer CAS refused: NOTHING was mutated
            // (single transaction, gate before any change). Report the
            // typed stale revision — never an optimistic success.
            return refusal(ConfigDomainError(code: .staleRevision,
                                             reason: "providerMetadataCAS.expected\(expectedBase)"),
                           phase: "metadataCommit")
        } catch {
            return refusal(ConfigDomainError(code: .persistenceUnavailable,
                                             reason: "providerMetadataWrite"),
                           phase: "metadataCommit")
        }
    }

    // MARK: Shared chain

    /// `leaseSecret`/`leaseBaseRevision` are set ONLY on the Set path. The
    /// owned scope below is the ONLY place raw secret bytes exist outside
    /// the vault; it never escapes this method (draft.enteredAPIKey is the
    /// original in-memory operation form, request.apiKey is zero-touched
    /// by SQLite and handed to the gateway write, which copies then
    /// zeroizes its own payload).
    private func runCandidate(_ candidateJSON: Data,
                              leaseSecret: Data?,
                              leaseBaseRevision: SaveIntentBaseRevision?,
                              envelopeRevision: ConfigRevision?,
                              clearSecret: Bool) async -> ProviderSaveExecution {
        // Parse FIRST to learn the provider id (pure, no effect), then take
        // the `.save` ownership reservation BEFORE the first row read/write,
        // so the observation→CAS→secret→bundle chain runs with no interleaved
        // provider operation and no concurrent cleanup attempt (CV-R1).
        let parsed: ProviderSaveCandidate
        do {
            guard !candidateJSON.isEmpty else {
                return .failed(.init(error: ConfigDomainError(code: .invalidEnvelope,
                                                              reason: "emptyCandidate"),
                                     secretDisposition: nil, databaseRowWritten: false,
                                     phase: "binding", physicalSettlement: nil,
                                     physicalReceipt: nil, pendingReconciliation: false,
                                     leaseAdmissionCloseFailed: false))
            }
            guard candidateJSON.count <= 16_384 else {
                return .failed(.init(error: ConfigDomainError(code: .payloadTooLarge,
                                                              reason: "candidateTooLarge"),
                                     secretDisposition: nil, databaseRowWritten: false,
                                     phase: "binding", physicalSettlement: nil,
                                     physicalReceipt: nil, pendingReconciliation: false,
                                     leaseAdmissionCloseFailed: false))
            }
            let dictionary = try ConfigJSON.object(from: candidateJSON)
            parsed = try ProviderSaveCandidate.parse(dictionary)
        } catch let error as ConfigDomainError {
            return .failed(.init(error: error, secretDisposition: nil,
                                 databaseRowWritten: false, phase: "binding",
                                 physicalSettlement: nil, physicalReceipt: nil,
                                 pendingReconciliation: false,
                                 leaseAdmissionCloseFailed: false))
        } catch {
            return .failed(.init(error: ConfigDomainError(code: .invalidEnvelope,
                                                          reason: "candidateParse"),
                                 secretDisposition: nil,
                                 databaseRowWritten: false, phase: "binding",
                                 physicalSettlement: nil, physicalReceipt: nil,
                                 pendingReconciliation: false,
                                 leaseAdmissionCloseFailed: false))
        }
        // Large-profile staged reference: resolve the frozen immutable set
        // into typed models BEFORE the ownership reservation and long
        // before any DB/secret effect. Foreign/stale/expired/unsealed/
        // tampered refs and binding divergence refuse typed here (no
        // effect, no partial state); the resolved candidate then follows
        // the EXACT original chain. The Set lease already froze the ref +
        // digest inside the frozen candidate JSON, so the same token can
        // never resolve different bytes (Main direction C).
        var effective = parsed
        do {
            let stagedBase = leaseBaseRevision.map {
                ConfigRevision(resourceID: $0.resourceID, version: $0.version)
            } ?? envelopeRevision
            if let models = try ProviderModelSetConsumer.resolveIfReferenced(
                parsed,
                context: .init(providerID: parsed.providerID,
                               createIntent: parsed.createIntent,
                               baseRevision: stagedBase,
                               isDraftProbe: false)) {
                effective = parsed.withResolvedModels(models)
            }
        } catch let error as ConfigDomainError {
            return .failed(.init(error: error, secretDisposition: nil,
                                 databaseRowWritten: false, phase: "binding",
                                 physicalSettlement: nil, physicalReceipt: nil,
                                 pendingReconciliation: false,
                                 leaseAdmissionCloseFailed: false))
        } catch {
            return .failed(.init(error: ProviderModelSetConsumer.mapError(
                error as? ProviderModelSetError ?? .stageUnavailable),
                                 secretDisposition: nil,
                                 databaseRowWritten: false, phase: "binding",
                                 physicalSettlement: nil, physicalReceipt: nil,
                                 pendingReconciliation: false,
                                 leaseAdmissionCloseFailed: false))
        }
        // MC-R4: exact-ticket begin; a durable pending owner gets ONE
        // bounded reconciliation attempt (individual physical truth only)
        // before the typed refusal.
        var ticket: ProviderOperationTicket?
        switch await ownership.beginOperation(providerID: effective.providerID,
                                              kind: .save) {
        case .attached(let attached):
            ticket = attached
        case .conflict:
            return .failed(.init(error: ConfigDomainError(code: .duplicateInFlight,
                                                          reason: "providerOperationActive"),
                                 secretDisposition: nil,
                                 databaseRowWritten: false, phase: "ownership",
                                 physicalSettlement: nil, physicalReceipt: nil,
                                 pendingReconciliation: false,
                                 leaseAdmissionCloseFailed: false))
        case .capacityUnavailable:
            // MC-CAPACITY-1: bounded reservation refused BEFORE any effect
            // (the vault lease was NOT consumed yet at this point — the
            // consume happens in saveSet before runCandidate, so a Set
            // intent stays live for a fresh save-tap; nothing leaked).
            return .failed(.init(error: ConfigDomainError(
                code: .mailboxSaturated, reason: "providerOperationCapacityUnavailable"),
                                 secretDisposition: nil,
                                 databaseRowWritten: false, phase: "ownership",
                                 physicalSettlement: nil, physicalReceipt: nil,
                                 pendingReconciliation: false,
                                 leaseAdmissionCloseFailed: false))
        case .pendingReconciliation:
            _ = await reconcileProviderRecovery(providerID: parsed.providerID)
            if case .attached(let attached) = await ownership.beginOperation(
                providerID: parsed.providerID, kind: .save) {
                ticket = attached
            } else {
                return .failed(.init(error: ConfigDomainError(
                    code: .duplicateInFlight, reason: "providerPendingReconciliation"),
                                     secretDisposition: nil,
                                     databaseRowWritten: false, phase: "ownership",
                                     physicalSettlement: nil, physicalReceipt: nil,
                                     pendingReconciliation: true,
                                     leaseAdmissionCloseFailed: false))
            }
        }
        guard let ownedTicket = ticket else {
            // Unreachable: begin paths above all return or attach.
            return .failed(.init(error: ConfigDomainError(code: .runtimeUnavailable,
                                                          reason: "ownershipNotAttached"),
                                 secretDisposition: nil, databaseRowWritten: false,
                                 phase: "ownership", physicalSettlement: nil,
                                 physicalReceipt: nil, pendingReconciliation: false,
                                 leaseAdmissionCloseFailed: false))
        }
        // Acquire the ACTUAL runtime owned-work lease (kind .vaultMaintenance
        // for this secret effect + metadata write chain) BEFORE the first row
        // read, and hold it across the whole awaited gateway/SQLite chain.
        // Failure to attach means the runtime is not ready / is draining: the
        // save fails closed with NO effect and NO durable intent claimed —
        // never a fake "would have been fine" success (no default fake zero).
        let ownedLease: ConfigOwnedWorkLease
        switch ownedWork.begin(kind: .vaultMaintenance,
                               ownerID: parsed.providerID.uuidString) {
        case .success(let lease):
            ownedLease = lease
        case .failure(let rejection):
            await ownership.endOperation(ownedTicket)
            return .failed(.init(error: Self.ownedWorkAttachError(rejection),
                                 secretDisposition: nil,
                                 databaseRowWritten: false, phase: "ownedWorkAttach",
                                 physicalSettlement: nil, physicalReceipt: nil,
                                 pendingReconciliation: false,
                                 leaseAdmissionCloseFailed: false))
        }
        let execution = await runGuarded(effective,
                                         leaseSecret: leaseSecret,
                                         leaseBaseRevision: leaseBaseRevision,
                                         envelopeRevision: envelopeRevision,
                                         clearSecret: clearSecret)
        // MC-R4: settle the owner/registry lease ONLY when the awaited
        // effects are physically settled (neverExecuted / executionSettled,
        // or no secret effect happened at all). An unsettled physical
        // lifetime PARKS the exact ticket + retained lease + receipt.
        let requiresRetention: Bool
        var parkIntent: ProviderPendingIntent = .secretWrite
        switch execution {
        case .committed:
            requiresRetention = false
        case .failed(let failed):
            requiresRetention = failed.requiresOwnerRetention
            if clearSecret { parkIntent = .secretClear }
        case .cleared(let cleared):
            requiresRetention = cleared.requiresOwnerRetention
            parkIntent = .secretClear
        }
        if requiresRetention {
            let receipt: PhysicalOperationReceipt?
            switch execution {
            case .failed(let failed): receipt = failed.physicalReceipt
            case .cleared(let cleared): receipt = cleared.physicalReceipt
            case .committed: receipt = nil
            }
            // TRANSFER the transient per-flow witness into the pending
            // record and clear the transient slot: the pending record then
            // owns the exact observer until real settlement
            // (MC-OBSERVER-PENDING-OWNER; no stale per-provider retention).
            let witness = await secretStore.consumeWitness(providerID: parsed.providerID)
            let parked = await ownership.parkPending(
                ownedTicket,
                intent: parkIntent,
                receipt: receipt,
                lease: ownedLease,
                witness: witness)
            // MC-CAPACITY-1: the reservation was taken at begin, so the
            // exact-ticket park ALWAYS retains ticket + lease + receipt;
            // the lease and the gate are NOT released (honest "unsettled
            // owner retained", never a fake settle). The execution surfaces
            // the typed retention flag.
            _ = parked
            return execution.applyingOwnerRetention(true)
        }
        // Terminal flow (committed or settled-without-retention): release the
        // transient witness slot so completed distinct-provider operations
        // never retain old observer objects.
        _ = await secretStore.consumeWitness(providerID: parsed.providerID)
        ownedWork.settle(ownedLease)
        await ownership.endOperation(ownedTicket)
        return execution
    }

    /// Maps a real owned-work attach rejection onto a frozen wire refusal.
    /// `noAdmittedEpoch` ⇒ runtimeUnavailable (the trusted host has not bound
    /// a current epoch); registry rejections carry the actual facade code as
    /// the closed reason identifier (never a path/secret).
    static func ownedWorkAttachError(_ rejection: ConfigOwnedWorkLifecycle.BeginRejection)
        -> ConfigDomainError {
        switch rejection {
        case .noAdmittedEpoch:
            return ConfigDomainError(code: .runtimeUnavailable, reason: "noAdmittedRuntimeEpoch")
        case .invalidOwnerIdentity:
            return ConfigDomainError(code: .invalidEnvelope, reason: "ownedWorkInvalidOwner")
        case .rejected(let code):
            return ConfigDomainError(code: .runtimeUnavailable, reason: "ownedWorkRejected.\(code)")
        }
    }

    /// The reserved section. The ownership `.save` gate is already held by
    /// runCandidate across this whole call and released only afterwards.
    private func runGuarded(_ candidate: ProviderSaveCandidate,
                            leaseSecret: Data?,
                            leaseBaseRevision: SaveIntentBaseRevision?,
                            envelopeRevision: ConfigRevision?,
                            clearSecret: Bool) async -> ProviderSaveExecution {
        let preparation: Prepared
        do {
            preparation = try await prepare(candidate: candidate,
                                            leaseSecret: leaseSecret,
                                            leaseBaseRevision: leaseBaseRevision,
                                            envelopeRevision: envelopeRevision,
                                            clearSecret: clearSecret)
        } catch let error as ConfigDomainError {
            return .failed(.init(error: error, secretDisposition: nil,
                                 databaseRowWritten: false, phase: "binding",
                                 physicalSettlement: nil, physicalReceipt: nil,
                                 pendingReconciliation: false,
                                 leaseAdmissionCloseFailed: false))
        } catch {
            return .failed(.init(error: ConfigDomainError(code: .persistenceUnavailable,
                                                          reason: "bindingFailed"),
                                 secretDisposition: nil,
                                 databaseRowWritten: false, phase: "binding",
                                 physicalSettlement: nil, physicalReceipt: nil,
                                 pendingReconciliation: false,
                                 leaseAdmissionCloseFailed: false))
        }
        switch preparation {
        case .rejected(let error):
            return .failed(.init(error: error, secretDisposition: nil,
                                 databaseRowWritten: false, phase: "binding",
                                 physicalSettlement: nil, physicalReceipt: nil,
                                 pendingReconciliation: false,
                                 leaseAdmissionCloseFailed: false))
        case .invalid(let draft):
            switch draft.makeRequest() {
            case .success:
                // Unreachable: makeRequest is deterministic per snapshot.
                return .failed(.init(error: ConfigDomainError(code: .invalidEnvelope,
                                                              reason: "requestConstruction"),
                                     secretDisposition: nil,
                                     databaseRowWritten: false, phase: "validate",
                                     physicalSettlement: nil, physicalReceipt: nil,
                                     pendingReconciliation: false,
                                     leaseAdmissionCloseFailed: false))
            case .failure(let report):
                return .failed(.init(error: Self.validationError(report),
                                     secretDisposition: nil,
                                     databaseRowWritten: false, phase: "validate",
                                     physicalSettlement: nil, physicalReceipt: nil,
                                     pendingReconciliation: false,
                                     leaseAdmissionCloseFailed: false))
            }
        case .ready(let request, let oldAccount, let expectation):
            // MC-R1: stage the observed durable expectation (row-absent vs
            // revision-base) for the same-writer CAS in the committer.
            switch expectation {
            case .create:
                await committer.stageNextBundleExpectation(
                    providerID: request.profile.id,
                    expectation: .createExpectedAbsent)
                // MC-R4: a NEW provider records the durable recovery
                // intent BEFORE the first native write: committed-then-
                // bundlefail, postclaim outcomeUnknown, or process death
                // before metadata must never leave a silently orphaned
                // new-provider key (the drain reconciles it against the
                // live row and NEVER deletes a reference a row owns).
                if !clearSecret {
                    do {
                        try await cleanup.enqueue(.init(
                            providerID: request.profile.id,
                            account: ConfigSecretIdentity.providerAccount(
                                providerID: request.profile.id),
                            intent: .secretWrite))
                    } catch let error as ConfigDomainError {
                        await committer.clearNextBundleExpectation(providerID: request.profile.id)
                        return .failed(.init(error: error, secretDisposition: nil,
                                             databaseRowWritten: false,
                                             phase: "cleanupEnqueue",
                                             physicalSettlement: nil,
                                             physicalReceipt: nil,
                                             pendingReconciliation: false,
                                             leaseAdmissionCloseFailed: false))
                    } catch {
                        await committer.clearNextBundleExpectation(providerID: request.profile.id)
                        return .failed(.init(error: ConfigDomainError(
                            code: .persistenceUnavailable, reason: "cleanupLedgerWrite"),
                                             secretDisposition: nil,
                                             databaseRowWritten: false,
                                             phase: "cleanupEnqueue",
                                             physicalSettlement: nil,
                                             physicalReceipt: nil,
                                             pendingReconciliation: false,
                                             leaseAdmissionCloseFailed: false))
                    }
                }
            case .edit(let base):
                await committer.stageNextBundleExpectation(
                    providerID: request.profile.id,
                    expectation: .editAtRevision(base))
            }
            if clearSecret, let oldAccount {
                // Enqueue BEFORE the first destructive effect (the original
                // deletion-queue ordering pattern).
                do {
                    try await cleanup.enqueue(.init(providerID: request.profile.id,
                                                    account: oldAccount,
                                                    intent: .secretClear))
                } catch let error as ConfigDomainError {
                    await committer.clearNextBundleExpectation(providerID: request.profile.id)
                    return .failed(.init(error: error, secretDisposition: nil,
                                         databaseRowWritten: false,
                                         phase: "cleanupEnqueue",
                                         physicalSettlement: nil,
                                         physicalReceipt: nil,
                                         pendingReconciliation: false,
                                         leaseAdmissionCloseFailed: false))
                } catch {
                    await committer.clearNextBundleExpectation(providerID: request.profile.id)
                    return .failed(.init(error: ConfigDomainError(
                        code: .persistenceUnavailable, reason: "cleanupLedgerWrite"),
                                         secretDisposition: nil,
                                         databaseRowWritten: false,
                                         phase: "cleanupEnqueue",
                                         physicalSettlement: nil,
                                         physicalReceipt: nil,
                                         pendingReconciliation: false,
                                         leaseAdmissionCloseFailed: false))
                }
            }
            var execution = await runFrozen(request: request)
            // MC-R4: after a NEW-provider Set actually committed+readback-
            // verified, the durable `.secretWrite` intent is finalized via
            // compare-and-delete. A false return (should be impossible under
            // the held reservation) is reported honestly: the entry stays
            // and the drain's row-present branch never deletes a live
            // reference. job-2e38 honesty fix: a NEW-provider CLEAR never
            // recorded a `.secretWrite` entry at all (the enqueue is
            // conditional on !clearSecret above), so dequeuing/finalizing
            // is not applicable and the flag stays at its honest default
            // instead of a spurious false that would imply an unfinalized
            // live entry.
            if case .create = expectation, !clearSecret,
               case .committed(var committedValue) = execution {
                let finalized = (try? await cleanup.dequeueMatching(
                    providerID: request.profile.id,
                    intent: .secretWrite)) ?? false
                committedValue.writeIntentFinalized = finalized
                execution = .committed(committedValue)
            }
            // Clear post-processing ONLY when a secret actually existed
            // (oldAccount proven): the bundle committed WITHOUT a
            // reference; attempt the bounded reference delete. MC-R3: ONLY
            // the delete's own committed completion finalizes the entry —
            // pre-ticket validation rejections and authoritative non-commits
            // KEEP the entry (the drain re-resolves against the live row);
            // finalization is compare-and-delete (CV-R2). MC-R4: an
            // unsettled physical lifetime keeps the entry AND feeds the
            // retention decision downstream via the settlement fields.
            if clearSecret, let oldAccount,
               case .committed(let committed) = execution {
                try? await secretStore.bindAccount(oldAccount, providerID: request.profile.id)
                let assessment = await secretStore.deleteBoundSecret(providerID: request.profile.id)
                var finalized = false
                switch assessment.disposition {
                case .committed:
                    finalized = (try? await cleanup.dequeueMatching(providerID: request.profile.id,
                                                                    intent: .secretClear)) ?? false
                case .effectAbsent(let reason):
                    // MC-R3: NO finalization. "No effect from this attempt"
                    // is not "the secret is absent"; the entry stays for
                    // honest retry.
                    _ = reason
                case .outcomeUnknown:
                    break // entry stays; drain retries against the live row
                }
                await secretStore.releaseAccountBinding(providerID: request.profile.id)
                execution = .cleared(.init(providerID: request.profile.id,
                                            cleanupDisposition: assessment.disposition,
                                            cleanupQueuedForRetry: !finalized,
                                            physicalSettlement: assessment.settlement,
                                            physicalReceipt: assessment.receipt,
                                            pendingReconciliation: false,
                                            leaseAdmissionCloseFailed: committed.leaseAdmissionCloseFailed))
            }
            return execution
        }
    }

    private enum Prepared {
        case rejected(ConfigDomainError)
        case invalid(ProviderSaveDraft)
        /// request = frozen makeRequest output; oldAccount = the ACTUAL
        /// persisted account BEFORE this write (clear cleanup binding);
        /// expectation = what the durable CAS must observe: create (row
        /// absent — nil base) or edit at the observed revision.
        case ready(ProviderSaveRequest,
                   oldAccount: String?,
                   expectation: Expectation)
        enum Expectation: Sendable, Equatable {
            /// Row was ABSENT at the observed read (create CAS).
            case create
            /// Row existed at exactly this persisted revision (edit CAS).
            case edit(base: Int64)
        }
    }

    /// Pre-effect binding under the held `.save` reservation: sync
    /// normalization, the ACTUAL row read, account-ownership and revision
    /// CAS checks, secret decode and draft construction. NOTHING here
    /// touches the gateway or writes the database; every rejection is
    /// provably before effects. The reservation guarantees the row read,
    /// the CAS decision and the later bundle write see ONE stable
    /// interleaving window with no concurrent provider operation (CV-R1)
    /// and no timestamp participates in any decision (CV-R2).
    private func prepare(candidate: ProviderSaveCandidate,
                         leaseSecret: Data?,
                         leaseBaseRevision: SaveIntentBaseRevision?,
                         envelopeRevision: ConfigRevision?,
                         clearSecret: Bool) async throws -> Prepared {
        // sync normalization BEFORE any effect (contract syncSemantics):
        // ordinary saves carry false and persist effective false; an
        // explicit/imported sync-true request is refused typed.
        guard !candidate.syncEnabled else {
            return .rejected(ConfigDomainError(code: .unsupportedSyncRequest,
                                               reason: "androidLocalOnlySync"))
        }

        let current: ProviderProfile?
        do {
            current = try await store.provider(id: candidate.providerID)
        } catch {
            return .rejected(ConfigDomainError(code: .persistenceUnavailable,
                                               reason: "providerRowQueryFailed"))
        }

        // Account ownership over the ACTUAL persisted row (never the wire):
        // a persisted account that is neither nil nor the deterministic
        // provider.<uuid> is corruption — refuse all secret effects instead
        // of ever writing a foreign reference.
        if let account = current?.secretRef?.keychainAccount,
           account != ConfigSecretIdentity.providerAccount(providerID: candidate.providerID) {
            return .rejected(ConfigDomainError(code: .persistenceUnavailable,
                                               reason: "persistedAccountOwnership"))
        }

        if let envelopeRevision {
            guard envelopeRevision.resourceID == "provider.\(candidate.providerID.uuidString)" else {
                return .rejected(ConfigDomainError(code: .invalidEnvelope,
                                                   reason: "revisionResourceMismatch"))
            }
        }
        let oldAccount = current?.secretRef?.keychainAccount
        if let row = current {
            guard !candidate.createIntent else {
                return .rejected(ConfigDomainError(code: .invalidEnvelope, reason: "createConflict"))
            }
            // MC-R1: overflow refuses BEFORE any secret/DB effect (typed).
            guard row.syncRevision < Int64.max else {
                return .rejected(ConfigDomainError(code: .staleRevision,
                                                   reason: "providerRevisionExhausted"))
            }
            let actual = ConfigRevision.provider(id: row.id, syncRevision: row.syncRevision)
            if let envelopeRevision, envelopeRevision.version != actual.version {
                return .rejected(ConfigDomainError(code: .staleRevision,
                                                   reason: "providerEnvelopeRevision"))
            }
            if let leaseBaseRevision {
                guard leaseBaseRevision.resourceID == actual.resourceID,
                      leaseBaseRevision.version == actual.version else {
                    return .rejected(ConfigDomainError(code: .staleRevision,
                                                       reason: "providerLeaseBaseRevision"))
                }
            }
        } else {
            guard candidate.createIntent else {
                return .rejected(ConfigDomainError(code: .notFound, reason: "providerRowMissing"))
            }
            // New resource: explicit create intent only, never a fabricated
            // version. A lease base binding on a missing row may only be
            // the "expected absent" marker (version "0").
            if let leaseBaseRevision,
               leaseBaseRevision.resourceID == "provider.\(candidate.providerID.uuidString)",
               leaseBaseRevision.version != "0" {
                return .rejected(ConfigDomainError(code: .invalidEnvelope,
                                                   reason: "createIntentBaseRevisionDivergence"))
            }
            if let envelopeRevision, envelopeRevision.version != "0" {
                return .rejected(ConfigDomainError(code: .invalidEnvelope,
                                                   reason: "createIntentRevisionNonZero"))
            }
        }

        // Secret decode for Set (bounded, owned operation bytes only).
        var enteredAPIKey = ""
        if let leaseSecret {
            guard !leaseSecret.isEmpty else {
                return .rejected(ConfigDomainError(code: .invalidEnvelope,
                                                   reason: "emptySecretForSet"))
            }
            guard let decoded = String(data: leaseSecret, encoding: .utf8),
                  !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .rejected(ConfigDomainError(code: .invalidEnvelope,
                                                   reason: "secretNotBoundedText"))
            }
            enteredAPIKey = decoded
        }

        let draft = candidate.makeDraft(existingRow: current,
                                        enteredAPIKey: enteredAPIKey,
                                        dropExistingSecret: clearSecret)
        switch draft.makeRequest() {
        case .success(let request):
            let expectation: Prepared.Expectation = current == nil
                ? .create
                : .edit(base: current!.syncRevision)
            return .ready(request, oldAccount: oldAccount, expectation: expectation)
        case .failure:
            return .invalid(draft)
        }
    }

    /// Runs the ORIGINAL runner, then classifies. The bound account for the
    /// secret phase comes from the FROZEN request (makeRequest output),
    /// never re-derived from the wire.
    private func runFrozen(request: ProviderSaveRequest) async -> ProviderSaveExecution {
        let providerID = request.profile.id
        let account = request.profile.secretRef?.keychainAccount
            ?? ConfigSecretIdentity.providerAccount(providerID: providerID)
        do {
            try await secretStore.bindAccount(account, providerID: providerID)
        } catch let error as ConfigDomainError {
            await committer.clearNextBundleExpectation(providerID: providerID)
            return .failed(.init(error: error, secretDisposition: nil,
                                 databaseRowWritten: false, phase: "bind",
                                 physicalSettlement: nil, physicalReceipt: nil,
                                 pendingReconciliation: false,
                                 leaseAdmissionCloseFailed: false))
        } catch {
            await committer.clearNextBundleExpectation(providerID: providerID)
            return .failed(.init(error: ConfigDomainError(code: .invalidEnvelope,
                                                          reason: "bindAccountRejected"),
                                 secretDisposition: nil,
                                 databaseRowWritten: false, phase: "bind",
                                 physicalSettlement: nil, physicalReceipt: nil,
                                 pendingReconciliation: false,
                                 leaseAdmissionCloseFailed: false))
        }
        var execution: ProviderSaveExecution
        do {
            let result = try await runner.run(request)
            switch result {
            case .committed(let canonical, let syncPending, let syncError):
                let record = await committer.bundleRecord(providerID: providerID)
                execution = .committed(.init(
                    providerID: providerID,
                    canonicalModels: canonical,
                    deletedModelIDs: record?.deletedModelIDs ?? [],
                    disabledModelIDs: record?.disabledModelIDs ?? [],
                    syncPending: syncPending,
                    syncError: syncError,
                    // MC-R1: the PERSISTED advanced revision, never the
                    // frozen draft base.
                    providerRevision: ConfigRevision.provider(
                        id: providerID,
                        syncRevision: record?.persistedSyncRevision
                            ?? (request.profile.syncRevision + 1)),
                    presetSidecarRecorded: record?.presetSidecarRecorded ?? false,
                    // runGuarded stamps the create-path finalization after
                    // the awaited chain; edits/keeps are trivially done.
                    writeIntentFinalized: true,
                    leaseAdmissionCloseFailed: false
                ))
                _ = await secretStore.consumeTrail(providerID: providerID)
            }
        } catch let runError as ProviderSaveRunError {
            let state = await secretStore.writeState(providerID: providerID)
            let trail = await secretStore.consumeTrail(providerID: providerID)
            let disposition: SecretEffectDisposition?
            var settlement: PhysicalSettlement?
            var receipt: PhysicalOperationReceipt?
            if let trail {
                disposition = trail.disposition
                settlement = trail.settlement
                receipt = trail.receipt
            } else {
                switch state {
                case .attempted(let recorded), .cleared(let recorded):
                    disposition = recorded
                case .inFlight:
                    disposition = .outcomeUnknown(reason: "writeInFlight")
                case .notAttempted:
                    disposition = nil
                }
            }
            // MC-R1: the durable same-writer CAS rejection of the bundle
            // write is a TYPED stale revision, with honest partial-commit
            // facts (secret side from its own physical assessment; the row
            // was NOT written — the transaction gate mutates nothing).
            if let conflict = await committer.consumeRevisionConflict(providerID: providerID),
               case .localCommit = runError {
                let committedStage = await committer.consumeCommittedStage(providerID: providerID)
                execution = .failed(.init(
                    error: ConfigDomainError(
                        code: .staleRevision,
                        reason: "providerBundleCAS.expected\(conflict.expected)"
                            + Self.dispositionNote(disposition)),
                    secretDisposition: disposition,
                    databaseRowWritten: committedStage,
                    phase: runError.phase,
                    physicalSettlement: settlement,
                    physicalReceipt: receipt,
                    pendingReconciliation: false,
                    leaseAdmissionCloseFailed: false))
            } else {
                // MC-R1 honest databaseRowWritten: true ONLY when the
                // committer's durable stage evidence says the bundle
                // transaction ACTUALLY committed before the later stage
                // failed (never assumed).
                let committedStage = await committer.consumeCommittedStage(providerID: providerID)
                let databaseRowWritten: Bool
                switch runError {
                case .readbackMismatch:
                    databaseRowWritten = true          // row + secret in place
                case .localCommit:
                    databaseRowWritten = committedStage // one-tx rollback ⇒
                                                        // false; post-commit
                                                        // stage ⇒ true
                default:
                    databaseRowWritten = false
                }
                execution = .failed(.init(
                    error: Self.classify(runError: runError,
                                         disposition: disposition,
                                         databaseRowWritten: databaseRowWritten),
                    secretDisposition: disposition,
                    databaseRowWritten: databaseRowWritten,
                    phase: runError.phase,
                    physicalSettlement: settlement,
                    physicalReceipt: receipt,
                    pendingReconciliation: false,
                    leaseAdmissionCloseFailed: false))
            }
        } catch {
            let state = await secretStore.writeState(providerID: providerID)
            let trail = await secretStore.consumeTrail(providerID: providerID)
            var disposition: SecretEffectDisposition?
            var settlement: PhysicalSettlement?
            var receipt: PhysicalOperationReceipt?
            if let trail {
                disposition = trail.disposition
                settlement = trail.settlement
                receipt = trail.receipt
            }
            if disposition == nil {
                if case let .attempted(recorded) = state { disposition = recorded }
                if case let .cleared(recorded) = state { disposition = recorded }
            }
            execution = .failed(.init(error: ConfigDomainError(code: .runtimeUnavailable,
                                                               reason: "runnerThrewUntyped"),
                                      secretDisposition: disposition,
                                      databaseRowWritten: false,
                                      phase: "unknown",
                                      physicalSettlement: settlement,
                                      physicalReceipt: receipt,
                                      pendingReconciliation: false,
                                      leaseAdmissionCloseFailed: false))
        }
        await secretStore.releaseAccountBinding(providerID: providerID)
        await committer.clearNextBundleExpectation(providerID: providerID)

        return execution
    }

    // MARK: MC-R4 reconciliation (individual physical truth only)

    /// One bounded reconciliation pass for a provider's durable pending
    /// owner. Reads ONLY the individual mailbox physical signal for the
    /// stored receipt — never statsJSON, global counters, a reference
    /// re-read as "settlement", a timeout, or the durable entry itself.
    func reconcileProviderRecovery(providerID: UUID) async -> ProviderRecoveryOutcome {
        guard let pending = await ownership.pendingRecord(providerID: providerID) else {
            return .nothingPending
        }
        guard let recovery = await ownership.tryAcquireRecoveryLease(providerID: providerID) else {
            return .stillPending(reason: "recoveryAlreadyRunning")
        }
        // MC-OBSERVER-PENDING-OWNER: the OLD operation's truth is read
        // through the witness captured at its attempt time — never the
        // current registry (which may be removed or re-pointed by now).
        let snapshot = await secretStore.physicalSnapshot(of: pending.receipt,
                                                          witness: pending.witness)
        var settledReason: String?
        switch snapshot {
        case .neverDispatched(let reason):
            settledReason = "neverDispatched.\(reason.rawValue)"
        case .settled(let status):
            // The effect may still be UNKNOWN (statuses -11/-12/-14); the
            // PHYSICAL execution is finished. The owner gate releases; the
            // durable ledger entry stays for retry per its own rules —
            // caller outcome and physical settlement stay SEPARATE axes.
            settledReason = "executionSettled.\(status)"
        case .queued, .claimedOutstanding, .notRecorded:
            settledReason = nil
        }
        if let reason = settledReason {
            // Release the consumed terminal record from the bounded mailbox
            // ledger (metadata hygiene; refusal is harmless and honest).
            _ = await secretStore.resolvePhysical(pending.receipt,
                                                  witness: pending.witness)
            let detached = pending.lease.map { ownedWork.settle($0) } ?? true
            let settled = await ownership.settlePending(providerID: providerID,
                                                        ticket: pending.ticket)
            await ownership.releaseRecovery(recovery)
            return settled
                ? .settledNow(reason: "\(reason).leaseDetached=\(detached)")
                : .stillPending(reason: "pendingIdentityAdvanced")
        }
        await ownership.releaseRecovery(recovery)
        return .stillPending(reason: pending.receipt == nil
            ? "noIndividualReceipt"
            : "physicalOutstanding")
    }

    // MARK: Classification helpers

    static func validationError(_ report: ProviderConfigurationValidationReport) -> ConfigDomainError {
        // Carry the ORIGINAL closed identifiers only (field:problem:
        // messageKey). Message bodies/echo strings never enter the wire;
        // the UI maps messageKeys to localized copy.
        let problems = report.issues.map { issue in
            "\(issue.field.rawValue):\(issue.problem.rawValue):\(issue.messageKey)"
        }
        return ConfigDomainError(code: .invalidEnvelope,
                                 reason: "providerValidation[\(problems.prefix(8).joined(separator: ";"))]")
    }

    private static func dispositionNote(_ disposition: SecretEffectDisposition?) -> String {
        switch disposition {
        case .committed: return ".secretCommitted"
        case .outcomeUnknown(let reason): return ".secretUnknown.\(reason)"
        case .effectAbsent(let reason): return ".secretAbsent.\(reason)"
        case .none: return ".noSecretPhase"
        }
    }

    static func classify(runError: ProviderSaveRunError,
                         disposition: SecretEffectDisposition?,
                         databaseRowWritten: Bool = false) -> ConfigDomainError {
        switch runError {
        case .invalidRequest(let problems):
            // Revalidation gate (ProviderSaveRunner.swift:378-388): the
            // frozen request failed the canonical rules BEFORE any side
            // effect — nothing was written (contract "zero overwrite").
            return ConfigDomainError(
                code: .invalidEnvelope,
                reason: "runnerRevalidate[\(problems.map(\.rawValue).prefix(8).joined(separator: ","))]"
            )
        case .concurrentSaveRejected:
            return ConfigDomainError(code: .duplicateInFlight, reason: "providerSaveInFlight")
        case .credentialOrSync:
            switch disposition {
            case .outcomeUnknown(let reason):
                // C1: NEVER claim no-effect. Retry of the SAME deterministic
                // reference converges (original idempotence rule) — and the
                // owner gate stays retained until the physical truth settles
                // (MC-R4).
                return ConfigDomainError(code: .runtimeUnavailable,
                                         reason: "secretOutcomeUnknown.\(reason)")
            case .effectAbsent(let reason):
                if reason == "gatewayUnregistered" {
                    // Contract precondition: unregistered gateway refuses
                    // with needsConfiguration BEFORE secret/DB effects.
                    return ConfigDomainError(code: .needsConfiguration,
                                             reason: "secretGatewayUnregistered")
                }
                return ConfigDomainError(code: .runtimeUnavailable,
                                         reason: "credentialPhaseAbsent.\(reason)")
            case .committed:
                // The write committed but the phase failed afterwards (the
                // fault seam path); honest unknown-shape reporting.
                return ConfigDomainError(code: .runtimeUnavailable,
                                         reason: "credentialCommittedThenFailed")
            case .none:
                // setSync refused the sync request before any write
                // (AndroidProviderSecretStore.setSyncEnabled).
                return ConfigDomainError(code: .unsupportedSyncRequest,
                                         reason: "syncRefusedBeforeWrite")
            }
        case .localCommit:
            let secretNote: String
            switch disposition {
            case .committed:
                secretNote = ".secretCommittedOrphanRetryConverges"
            case .outcomeUnknown(let reason):
                secretNote = ".secretOutcomeUnknown.\(reason)"
            case .effectAbsent:
                secretNote = ".secretAbsent"
            case .none:
                secretNote = ".noSecretPhase"
            }
            // Documented cross-store partial state (contract
            // crossStoreHonesty): with databaseRowWritten false this is the
            // orphan-secret case (deterministic reference, NO DB row; the
            // retry converges); with true the bundle actually committed and
            // a LATER stage failed — the flag keeps the two honest.
            let stageNote = databaseRowWritten ? ".postCommitStage" : ""
            return ConfigDomainError(code: .persistenceUnavailable,
                                     reason: "localCommitFailed\(secretNote)\(stageNote)")
        case .readbackMismatch(let detail):
            // Row + secret are BOTH in place. The mismatch is NEVER
            // converted into a no-effect claim.
            let safe = SecretRedactor.redact(detail)
            let compact = safe.utf8.count <= 96 ? safe : "readbackMismatch"
            return ConfigDomainError(code: .persistenceUnavailable,
                                     reason: "readbackMismatch(\(compact))")
        }
    }
}

