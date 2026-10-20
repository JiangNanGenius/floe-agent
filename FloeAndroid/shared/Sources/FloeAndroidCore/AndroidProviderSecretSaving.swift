// SPDX-License-Identifier: MPL-2.0
//
// RB2 — AndroidProviderSecretSaving: the ACTUAL Android implementation of the
// ORIGINAL FloeCore `ProviderSecretSaving` seam (FloeCore
// ProviderSaveRunner.swift:21-24) for the Android overlay, plus the typed
// pre-dispatch credential resolution used by reads/probes and the MC-R4
// physical-trail bookkeeping. REPAIR successor of job-d02beb16bd1840a9
// (private source candidate; NOT compiled, NOT executed; see REPORT.md).
//
// Repair delta over the parent:
// * MC-R4 (Main-authorized physical API): store/delete attempts routed
//   through a gateway that supports the INDIVIDUAL physical observation seam
//   (PhysicalObservingSecretGateway — the mailbox mirror) now (a) capture the
//   per-operation receipt delivered at queue-accept, (b) classify via
//   SecretPhysicalAssessor from the individual snapshot rather than the
//   error value alone, and (c) expose the trail + snapshot/resolve API the
//   executor/facade need to retain owner + registry lease until the REAL
//   host completion (never a timer, cancellation, or durable-record event).
//   Gateways WITHOUT the seam behave EXACTLY like the parent path
//   (conservative unknown; unobserved settlement → owner retention for
//   ambiguous outcomes only).
// * MC-R3 read fix inherited from the Models availability mapping
//   (invalidReference on a read is NOT secretMissing).
//
// Bound to ACTUAL reviewed source only:
// * Frozen fail-closed registry: CredentialBackend.swift:32-65
//   (SecretGatewayRegistry.shared.read/write/delete + isRegistered;
//   SecretGatewayError.needsConfiguration when unregistered — never a RAM
//   stub). This lane does NOT change the registry's existing CRUD; the
//   candidate mirror adds Main-authorized ADDITIVE forwarding only.
// * Canonical mapping (BOTH directions): SecretGatewayNaming
//   .opaqueReference(for:) = namespace "keychainAccount" + SHA-256 over the
//   original SecretReference.keychainAccount (CredentialBackend.swift:80-90).
//   The provider namespace stays the ORIGINAL keychainAccount domain — the
//   existing 71/C72 `ref:v1:` scheme, unrotated
//   (BRIDGE_V3_MAIN_DECISIONS credentialGatewayIdentityClarification
//   .existingReference). The MCP service domain org.floeagent.ios.mcp is
//   DISTINCT and is never merged here (MCP belongs to RB6).
// * Deterministic account rule: "provider.<uuid>" (KeychainSecretStore.swift
//   :230-239; minted by ProviderSaveRunner.swift:182-186 through
//   ProviderSaveDraft.makeRequest()).
// * Effect dispositions: MAIN_GATEWAY_EFFECT_DISPOSITION_CLARIFICATION_
//   20261019.json consumed together with SecretGatewayMailbox.swift
//   recordEffectLocked via the shared SecretDispositionClassifier, refined by
//   the individual physical truth when available.
// * Local-only sync: BRIDGE_V3_MAIN_DECISIONS.localSync + contract
//   credentialContract.syncDecision. Android has NO iCloud/CloudKit and NO
//   Android-account sync permission; `setSyncEnabled(true)` is refused typed
//   BEFORE any Keystore effect, and `false` is a provable no-op (the
//   effective persisted value travels with the ORIGINAL bundle save as
//   secretRef.synchronizable). The provider secret_sync Bool is NEVER
//   interpreted as another reference.
//
// Secret bytes cross ONLY this in-memory seam toward the frozen gateway. No
// secret copy is retained past the owned operation: storeSecret forwards the
// bytes and zeroizes its owned local copy in place. There is NO transient
// secret cache. The physical trail carries metadata ONLY (claim token, epoch,
// reference, kind, tracked) — never bytes.

import Foundation
import FloeCore

// MARK: - Gateway consumption seam (no frozen-source edits)

/// The typed CRUD surface RB2 needs from the frozen `SecretGatewayRegistry`.
/// Declared as a protocol so the facade binds the REAL registry in
/// production and qualification tests bind a synthetic gateway with call
/// counters. The members already exist on the frozen class
/// (CredentialBackend.swift:44-64) with identical signatures.
public protocol SecretGatewayServicing: Sendable {
    var isRegistered: Bool { get }
    func read(reference: String) async throws -> Data?
    func write(reference: String, value: Data) async throws
    func delete(reference: String) async throws
}

extension SecretGatewayRegistry: SecretGatewayServicing {}

// MARK: - Typed secret status

/// Read-side secret status. `configured` is PROVEN only by a bounded,
/// UTF-8-decodable secret. Transient backend states are `outcomeUnknown`
/// (never presented as missing, never as anonymous authority).
public enum ConfigSecretStatus: Sendable, Equatable, Error {
    case configured
    case unavailable(ConfigCredentialAvailability)
    case outcomeUnknown(reason: String)
}

/// Per-provider disposition bookkeeping recorded by the saving implementation
/// so the facade can classify a runner failure WITHOUT re-inspecting the
/// mailbox (which a caller cannot do honestly from a typed error alone).
/// Cleared at bind/release. The ORIGINAL runner's per-provider single-flight
/// (ProviderSaveRunner.swift:390-395) plus the facade's lease/ownership gate
/// guarantee at most one live disposition per provider.
public enum ProviderSecretWriteState: Sendable, Equatable {
    case notAttempted
    case inFlight
    case attempted(last: SecretEffectDisposition)
    case cleared(last: SecretEffectDisposition)
}

/// One trail: the LAST physical assessment for one provider attempt (effect
/// disposition + individual settlement + receipt). Owned by the saving actor
/// and consumed exactly once by the executor when deciding whether the
/// owner gate / registry lease may settle or must park (MC-R4).
///
/// `observer` (MC-OBSERVER-PENDING-OWNER, job-059dc09dd7bd48f1): the EXACT
/// observing gateway that minted this attempt's receipt, captured AT attempt
/// time. Runtime-only, never serialized: settling/acknowledging the pending
/// record later MUST go through this witness, not the mutable registry.
public struct ProviderSecretAttemptTrail: Sendable, Equatable {
    public let assessment: SecretEffectAssessment
    public let observer: (any PhysicalObservingSecretGateway)?
    init(assessment: SecretEffectAssessment,
         observer: (any PhysicalObservingSecretGateway)? = nil) {
        self.assessment = assessment
        self.observer = observer
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.assessment == rhs.assessment
    }
}

// MARK: - AndroidProviderSecretStore

/// Actor implementation of the ORIGINAL `ProviderSecretSaving` protocol +
/// the facade-side typed resolution/status/delete/physical-trail API.
///
/// `storeSecret(_:scopeProviderID:)` writes under the ACTUAL bound account
/// for that provider (the save executor binds the frozen current row's
/// account — `provider.<uuid>` for anything this backend creates or created;
/// a migrated legacy row keeps its own persisted `secretRef.keychainAccount`,
/// which is still the ONLY account this store may touch for that id).
/// Unbound ids fail closed typed: a command can never steer a write toward a
/// foreign namespace member (approval-model, host.*, credential.* or another
/// provider's account).
public actor AndroidProviderSecretStore {
    private let gateway: any SecretGatewayServicing
    private var boundAccounts: [UUID: String] = [:]
    private var writeStates: [UUID: ProviderSecretWriteState] = [:]
    private var trails: [UUID: ProviderSecretAttemptTrail] = [:]
    /// Runtime-only witness map: the observer that minted the CURRENT flow's
    /// receipt, keyed by provider. Survives `releaseAccountBinding` (park may
    /// follow it) and is replaced only when a NEW flow binds. Bounded by the
    /// provider reservation; carries no secret bytes and is never persisted.
    private var lastObservers: [UUID: any PhysicalObservingSecretGateway] = [:]
    /// Test/qualification-only fault seam (internal init; never reachable
    /// from the production initializer). Runs AFTER the real gateway write
    /// succeeds so injected failures prove post-write partial-commit states
    /// with the committed write itself still evidenced by the fake gateway.
    /// The seam is ASYNC so a controlled test can drive a real concurrent
    /// DatabaseManager.writer interleaving between the secret write and the
    /// durable bundle CAS (MC-R1 partial-commit proof) without any
    /// production path being involved.
    let faultSeam: (@Sendable (_ reference: String, _ byteCount: Int) async throws -> Void)?

    public init(gateway: any SecretGatewayServicing) {
        self.gateway = gateway
        self.faultSeam = nil
    }

    init(gateway: any SecretGatewayServicing,
         faultSeam: (@Sendable (String, Int) async throws -> Void)?) {
        self.gateway = gateway
        self.faultSeam = faultSeam
    }

    private var observedGateway: (any PhysicalObservingSecretGateway)? {
        PhysicalObservationResolver.observer(for: gateway)
    }

    /// Whether the CURRENTLY BOUND gateway exposes the individual physical
    /// seam — a point-in-time capability snapshot for diagnostics/UI only,
    /// NEVER a per-attempt authority. The actual observation decision is
    /// made per attempt inside `performAttemptImpl` (MC-CAPACITY-2).
    public func supportsPhysicalObservation() -> Bool {
        observedGateway != nil
    }

    // MARK: Account binding (facade-owned lifecycle)

    /// Bind the ACTUAL persisted account for one save/clear flow.
    /// Deterministic ownership is enforced here: the ONLY account this store
    /// may use for a provider id is `provider.<uuid>` — the same rule the
    /// ORIGINAL backend used on every platform (KeychainSecretStore.swift
    /// :230-239 + ProviderSaveRunner.swift:184), so even migrated rows carry
    /// it. A persisted row whose `secret_ref_account` differs is a corruption
    /// signal: the facade refuses all secret effects for that provider
    /// (typed persistenceUnavailable) rather than ever writing a foreign
    /// namespace member (approval-model, host.*, credential.* or another
    /// provider's account). Rebasing the same value is idempotent; a
    /// DIFFERENT value while a flow is live is refused (duplicateInFlight).
    func bindAccount(_ account: String, providerID: UUID) throws {
        if account != ConfigSecretIdentity.providerAccount(providerID: providerID) {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "accountOwnershipMismatch")
        }
        if let existing = boundAccounts[providerID], existing != account {
            throw ConfigDomainError(code: .duplicateInFlight, reason: "accountRebindConflict")
        }
        boundAccounts[providerID] = account
        writeStates[providerID] = .notAttempted
        trails[providerID] = nil
        // A NEW flow rebinds the account: any witness from an older flow is
        // no longer authoritative for this provider.
        lastObservers[providerID] = nil
    }

    func boundAccount(providerID: UUID) -> String? {
        boundAccounts[providerID]
    }

    func releaseAccountBinding(providerID: UUID) {
        boundAccounts[providerID] = nil
        writeStates[providerID] = nil
        // The TRAIL intentionally survives: the executor reads it after the
        // awaited chain threw (that is its consumer), then clears it via
        // consumeTrail. Re-binding a different flow resets it.
    }

    func writeState(providerID: UUID) -> ProviderSecretWriteState {
        writeStates[providerID] ?? .notAttempted
    }

    /// Read + clear the last physical assessment trail (executor-owned).
    func consumeTrail(providerID: UUID) -> SecretEffectAssessment? {
        let trail = trails[providerID]
        trails[providerID] = nil
        return trail?.assessment
    }

    /// Consume + CLEAR the transient per-provider witness slot. Terminal
    /// flows call this once at their end; the pending-handoff path calls it
    /// while TRANSFERRING the observer into the durable-in-memory pending
    /// record (the record then owns the only reference until real
    /// settlement). Bounded by the provider reservation and never persisted.
    @discardableResult
    func consumeWitness(providerID: UUID) -> (any PhysicalObservingSecretGateway)? {
        lastObservers.removeValue(forKey: providerID)
    }

    // MARK: Typed resolution BEFORE network dispatch

    /// Typed credential resolution (contract credentialResolution.rule):
    /// `.apiKey` only from a real bounded secret; `.anonymousAuthorized`
    /// ONLY for an explicitly configured/supported no-auth style — the
    /// ORIGINAL rules: `ProviderConnectionIdentity.authStyle(for:)` ==
    /// "none" (FloeCore ProviderConfigurationValidation.swift:258-264, the
    /// local kind; the factory's AuthStyle.none preset at
    /// ProviderAdapterFactory.swift:175) — otherwise `.unavailable{reason}`.
    /// A missing secretRef or a LAN/self-hosted endpoint NEVER produces
    /// silent anonymous fallback. Android performs NO on-device inference:
    /// resolution is gateway-only and never launches a native runtime.
    /// MC-R3: a pre-ticket invalidReference refusal is NOT secretMissing —
    /// it fails closed (never anonymous, never "missing" that invites an
    /// overwrite).
    func resolve(provider: ProviderProfile) async -> ProviderCredentialResolution {
        let authStyle = ProviderConfigurationValidation.ProviderConnectionIdentity.authStyle(for: provider.kind)
        if authStyle == "none" {
            return .anonymousAuthorized
        }
        guard let reference = provider.secretRef else {
            return .unavailable(.secretMissing)
        }
        guard gateway.isRegistered else {
            return .unavailable(.gatewayUnregistered)
        }
        let opaqueReference = ConfigSecretIdentity.providerOpaqueReference(for: reference)
        do {
            guard let bytes = try await gateway.read(reference: opaqueReference) else {
                // Authoritative read miss (the store itself answered
                // "no record"): the ONE honest secretMissing channel here.
                return .unavailable(.secretMissing)
            }
            guard let key = String(data: bytes, encoding: .utf8), !key.isEmpty else {
                // The ORIGINAL save path wrote key.data(using: .utf8)
                // (ProviderSaveRunner.swift:408-411); undecodable/empty bytes
                // are an invalidated record, never a silent anonymous pass.
                return .unavailable(.secretInvalidated)
            }
            return .apiKey(key)
        } catch {
            if let availability = ConfigCredentialAvailability.from(gatewayError: error) {
                return .unavailable(availability)
            }
            // Transient backend states cannot PROVE availability either way:
            // fail closed as secretLocked (never anonymous, never "missing"
            // that would invite an overwrite).
            return .unavailable(.secretLocked)
        }
    }

    /// Direct typed status for one deterministic reference (credential
    /// presence view). Uses the SAME single canonical mapping as the write
    /// path (contract canonicalReferenceMapping.rule: ONE mapping function
    /// for BOTH directions).
    func secretStatus(account: String) async -> ConfigSecretStatus {
        guard gateway.isRegistered else {
            return .unavailable(.gatewayUnregistered)
        }
        let reference = ConfigSecretIdentity.providerOpaqueReference(
            for: ConfigSecretIdentity.providerSecretReference(account: account,
                                                              synchronizable: false))
        do {
            guard let bytes = try await gateway.read(reference: reference) else {
                return .unavailable(.secretMissing)
            }
            guard String(data: bytes, encoding: .utf8) != nil else {
                return .unavailable(.secretInvalidated)
            }
            return .configured
        } catch {
            if let availability = ConfigCredentialAvailability.from(gatewayError: error) {
                return .unavailable(availability)
            }
            return .outcomeUnknown(reason: "gatewayTransient")
        }
    }

    // MARK: Owned clear/delete

    /// Deletes the secret under the BOUND reference with the honest
    /// C0/C1/physical-disposition contract. Returns the FULL assessment so
    /// the facade/executor can (a) keep the deterministic cleanup queue
    /// without ever claiming deletion from uncertainty (MC-R3) and (b)
    /// release OR park the owner gate/registry lease from the INDIVIDUAL
    /// physical truth (MC-R4) — never from the error string alone.
    func deleteBoundSecret(providerID: UUID) async -> SecretEffectAssessment {
        guard let account = boundAccounts[providerID] else {
            return SecretEffectAssessment(disposition: .effectAbsent(reason: "accountUnbound"),
                                          settlement: .neverExecuted(reason: "accountUnbound"),
                                          receipt: nil)
        }
        let reference = ConfigSecretIdentity.providerOpaqueReference(
            for: ConfigSecretIdentity.providerSecretReference(account: account,
                                                              synchronizable: false))
        writeStates[providerID] = .cleared(last: .outcomeUnknown(reason: "inFlight"))
        let trail = await performAttemptImpl(kind: .delete, reference: reference,
                                             value: nil)
        writeStates[providerID] = .cleared(last: trail.assessment.disposition)
        trails[providerID] = trail
        lastObservers[providerID] = trail.observer
        return trail.assessment
    }

    /// Shared observed/unobserved CRUD attempt with physical classification.
    /// The observed path captures the individual receipt at queue-accept
    /// and classifies failures from the per-operation snapshot; the
    /// unobserved path degrades to EXACTLY the parent conservative rules.
    ///
    /// MC-CAPACITY-2 (registry replacement race): observation support is
    /// resolved PER ATTEMPT inside this method (`observedGateway` is read
    /// anew for every attempt), never from a stale prior capability boolean.
    /// A gateway replaced mid-lifetime simply classifies this attempt as
    /// unobserved with the conservative baseline; the unobserved fallback
    /// NEVER classifies a nil receipt as "never queued" (that proof exists
    /// only on the observed path, where the mailbox itself refused before
    /// queue-accept — e.g. physical-ledger saturation). MC-CAPACITY-2 also
    /// guarantees an observed publish either delivers the queue-accept
    /// receipt atomically or refuses BEFORE queue/dispatch, so a nil receipt
    /// here genuinely proves no dispatch for THIS attempt.
    private func performAttemptImpl(kind: PhysicalOperationKind,
                                    reference: String,
                                    value: Data?) async -> ProviderSecretAttemptTrail {
        let capture = ReceiptCapture()
        let observed = observedGateway
        do {
            if let observed {
                switch kind {
                case .write:
                    try await observed.writeObserved(reference: reference,
                                                     value: value ?? Data()) { receipt in
                        capture.set(receipt)
                    }
                case .delete:
                    try await observed.deleteObserved(reference: reference) { receipt in
                        capture.set(receipt)
                    }
                case .read:
                    _ = try await observed.readObserved(reference: reference) { receipt in
                        capture.set(receipt)
                    }
                }
            } else {
                switch kind {
                case .write:
                    try await gateway.write(reference: reference, value: value ?? Data())
                case .delete:
                    try await gateway.delete(reference: reference)
                case .read:
                    _ = try await gateway.read(reference: reference)
                }
            }
            // Success is the authoritative completion channel: the caller
            // continuation resumes ONLY from mailbox complete() with a
            // GWS-7-valid positive status, so a returned success IS the
            // terminal event for THIS operation (execution settled). The
            // individual record (when present) supplies the exact status.
            var settlement: PhysicalSettlement = .executionSettled(
                status: kind == .write ? 3 : (kind == .delete ? 4 : 1))
            if let receipt = capture.receipt, let observed {
                let snapshot = observed.physicalSnapshot(claim: receipt.claim)
                if case .settled(let status) = snapshot {
                    settlement = .executionSettled(status: status)
                }
                _ = observed.resolvePhysical(claim: receipt.claim)
            }
            return ProviderSecretAttemptTrail(
                assessment: SecretEffectAssessment(disposition: .committed,
                                                   settlement: settlement,
                                                   receipt: capture.receipt),
                observer: observed)
        } catch {
            let snapshot: PhysicalOperationSnapshot
            if let receipt = capture.receipt, let observed {
                snapshot = observed.physicalSnapshot(claim: receipt.claim)
            } else {
                snapshot = .notRecorded
            }
            return ProviderSecretAttemptTrail(
                assessment: SecretPhysicalAssessor.assess(error: error,
                                                          receipt: capture.receipt,
                                                          snapshot: snapshot,
                                                          supportsObservation: observed != nil),
                observer: observed)
        }
    }

    /// Web-search credential read for the resolver: bounded read under the
    /// web-search namespace, decoding the ORIGINAL WebSearchCredential JSON
    /// shape, with the same availability honesty. The decoded values are
    /// returned to the caller (the service needs them in memory) and are
    /// NEVER persisted/serialized by RB2 outside the gateway.
    func webSearchCredential(reference: String) async -> Result<Data, ConfigSecretStatus> {
        guard gateway.isRegistered else {
            return .failure(.unavailable(.gatewayUnregistered))
        }
        do {
            guard let bytes = try await gateway.read(reference: reference) else {
                return .failure(.unavailable(.secretMissing))
            }
            guard bytes.count <= ConfigWebSearchLimits.maximumCredentialBytes else {
                return .failure(.unavailable(.secretInvalidated))
            }
            return .success(bytes)
        } catch {
            if let availability = ConfigCredentialAvailability.from(gatewayError: error) {
                return .failure(.unavailable(availability))
            }
            return .failure(.outcomeUnknown(reason: "gatewayTransient"))
        }
    }

    // MARK: MC-R4 reconcile helpers (metadata-only)

    /// Individual physical truth for a receipt stored in a PENDING record.
    /// ONLY the witness captured at that attempt may report it
    /// (MC-OBSERVER-PENDING-OWNER). A receipt whose original witness is
    /// missing is honest `.notRecorded`: it must never inspect the CURRENT
    /// registry, where a replacement gateway could expose an unrelated
    /// operation with a colliding claim token. Fresh attempts do not use this
    /// helper; they query their locally captured observer directly.
    func physicalSnapshot(of receipt: PhysicalOperationReceipt?,
                          witness: (any PhysicalObservingSecretGateway)?)
        -> PhysicalOperationSnapshot {
        guard let receipt, let observed = witness else { return .notRecorded }
        return observed.physicalSnapshot(claim: receipt.claim)
    }

    /// Release a consumed terminal record from the bounded mailbox ledger.
    /// ONLY the pending record's original witness may acknowledge it; with a
    /// missing witness (or no receipt) nothing is acknowledged through any
    /// other gateway. Refusal while outstanding is unchanged.
    @discardableResult
    func resolvePhysical(_ receipt: PhysicalOperationReceipt?,
                         witness: (any PhysicalObservingSecretGateway)?) -> Bool {
        guard let receipt else { return true }
        guard let observed = witness else { return false }
        return observed.resolvePhysical(claim: receipt.claim)
    }
}

// MARK: - ProviderSecretSaving conformance (the ORIGINAL protocol)

extension AndroidProviderSecretStore: ProviderSecretSaving {
    /// Local-only Android: `false` is a provable no-op success (the effective
    /// persisted value travels with the ORIGINAL save path as
    /// `secretRef.synchronizable`; ordinary saves persist effective false);
    /// `true` is refused TYPED before any Keystore effect
    /// (BRIDGE_V3_MAIN_DECISIONS.localSync). An ordinary false save never
    /// throws, so there is also no fake per-save sync error.
    public func setSyncEnabled(_ enabled: Bool, for providerID: UUID) async throws {
        guard enabled == false else {
            throw ConfigDomainError(code: .unsupportedSyncRequest,
                                    reason: "androidLocalOnlySync")
        }
        // No side effect by design; the bind gate still applies (an unbound
        // provider cannot reach the secret phase through this seam).
        guard boundAccounts[providerID] != nil else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "accountUnbound")
        }
    }

    /// Writes the operation-owned bytes through the frozen gateway. No
    /// retention, no cache: the owned local copy is zeroized in place when
    /// this returns; after the call only the gateway/backend holds the bytes.
    public func storeSecret(_ secret: Data, scopeProviderID: UUID) async throws {
        guard let account = boundAccounts[scopeProviderID] else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "accountUnbound")
        }
        let reference = ConfigSecretIdentity.providerOpaqueReference(
            for: ConfigSecretIdentity.providerSecretReference(account: account,
                                                              synchronizable: false))
        writeStates[scopeProviderID] = .attempted(last: .outcomeUnknown(reason: "inFlight"))
        var owned = secret
        defer {
            if owned.count > 0 { owned.resetBytes(in: 0..<owned.count) }
        }
        let trail = await performAttemptImpl(kind: .write, reference: reference,
                                             value: owned)
        let assessment = trail.assessment
        // The witness is recorded BEFORE the disposition branches: the
        // failing path throws, and the parked pending owner below still needs
        // the exact attempt observer to settle/ACK later
        // (MC-OBSERVER-PENDING-OWNER).
        lastObservers[scopeProviderID] = trail.observer
        switch assessment.disposition {
        case .committed:
            writeStates[scopeProviderID] = .attempted(last: .committed)
            trails[scopeProviderID] = trail
        case .effectAbsent, .outcomeUnknown:
            writeStates[scopeProviderID] = .attempted(last: assessment.disposition)
            trails[scopeProviderID] = trail
            // CV-R4: the caller-side typed error must reach the ORIGINAL
            // runner unchanged (its phase classification depends on the
            // throw), so the failure is rethrown as the assessment's basis.
            throw ProviderSecretStoreError(assessment: assessment)
        }
        // Fault seam runs AFTER the real gateway write so tests can inject a
        // post-write phase failure (partial-commit evidence) or a REAL
        // concurrent DatabaseManager.writer interleaving (MC-R1) while the
        // committed write stays proven by the injected fake gateway.
        if case .committed = assessment.disposition, let faultSeam {
            try await faultSeam(reference, owned.count)
        }
    }
}

/// Typed rethrow carrier: preserves the assessment while the ORIGINAL runner
/// maps the credential-phase failure (ProviderSaveRunner.swift:412-416). The
/// executor reads the trail (consumeTrail) for the honest classification;
/// the runner's phase attribution stays frozen.
struct ProviderSecretStoreError: Error, Sendable {
    let assessment: SecretEffectAssessment
}