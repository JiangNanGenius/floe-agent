// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 media enhancement — user-facing super-resolution backend
// configuration bound to the ORIGINAL root-owned credential vault
// (job-7951fc7bca9946bc root-owned proof + immutable rotation, kept;
// job-e5e786c723244725 replaces the remaining two-call staging with ONE
// original sealed secure-input -> native owned save exchange).
//
// OWNERSHIP MODEL (kept from the predecessor closure): the predecessor
// treated ONE global account string as "owned" and derived the gateway
// reference from it, so two independent runtime roots whose rows carried the
// same allowed string resolved to the SAME Android credential — rootA and
// rootB could read/send/delete each other's key. Here the settings row only
// REFERENCE-BINDS to a credential record that this root's ORIGINAL
// CredentialStore must prove:
//
//   * the enhancer credential is an ordinary vault credential
//     (`credential.<uuid>` account, record id == uuid, `.providerAPIKey`,
//     `.vault` owner) whose `origin` carries the enhancer purpose marker;
//   * EVERY read/send/save/clear/presence path resolves that record from
//     this root's metadata authority FIRST — a restored/malformed/foreign
//     row (including the legacy global string and forged `.pending.` shapes)
//     yields ZERO gateway effects and a typed `credentialAccountOwnership`
//     refusal; there is NO automatic adoption of the legacy global account;
//   * mutations serialize on the SHARED admitted coordinator's
//     `.enhancerConfiguration` lease with the real `.vaultMaintenance`
//     owned-work receipt (no cloned gate set);
//   * ROTATION IS IMMUTABLE: the ONE sealed ingress (`enhancerSave` subject
//     in the existing SecretSaveIntentVault) freezes the secret-free
//     candidate and the key bytes together at save-tap; the native save
//     consumes that lease and performs EXACTLY ONE original
//     `AndroidCredentialVault.capture` inside the runtime-owned mutation
//     lifetime, commits the row pointing at the NEW owned reference LAST,
//     and only then retires the previous credential through the ORIGINAL
//     vault delete. The previous reference is NEVER rewritten, so a
//     settings-commit failure (even with a failed cleanup) leaves the
//     previous configuration AND credential byte-identical; residual claims
//     keep durable original `credential_deletion_queue` rows that the real
//     restart drain settles with the real owned-work registry.
//
// The removed two-call staging adapter (`mintEnhancerStagingAccountID` /
// `commitEnhancerStagingAccount` / `discardEnhancerStagingAccount`) released
// its lease at mint — BEFORE the App host's late physical write — and its
// host-side blind cleanup could delete a LIVE key after a lost commit reply.
// The sealed ingress holds the key bytes in the ONE bounded vault slot from
// save-tap until the native consume, inside the owned-operation lifetime;
// the App host never writes or deletes a credential directly.
import Foundation
import FloePersistence

/// Typed store for the super-resolution backend configuration.
public struct G09R2EnhancerBackendConfigurationStore: Sendable {
    /// SettingsStore key (unchanged from the source-only predecessor).
    public static let settingsKey = "media.enhancement.superResolutionBackend"
    /// Fixed authenticated queue origin for the documented fal backend; the
    /// user configures only the credential, never a base URL.
    public static let queueBaseURL = URL(string: "https://queue.fal.run")!

    public enum ConfigurationError: Error, Sendable, Equatable {
        /// The endpoint id cannot produce canonical owner/alias request URLs.
        case invalidEndpointID
        /// The credential account is empty/oversized/non-ASCII-bounded.
        case invalidCredentialAccount
        /// The typed row cannot be persisted.
        case persistenceUnavailable
        /// No credential exists in the original store for the account; the
        /// App host must write the key before the row is persisted.
        case credentialMissing
        /// The account is well-formed but this root's ORIGINAL metadata
        /// authority does not prove an enhancer-owned credential record for
        /// it (e.g. `provider.<uuid>`, the legacy global string, or a
        /// foreign root's `credential.<uuid>` restored into this root's
        /// row). Refused BEFORE any gateway access.
        case credentialAccountOwnership
        /// The sealed ingress candidate does not match the submitted row
        /// (the frozen secret-free candidate is the immutable authority for
        /// the key it carries). Refused BEFORE any gateway access.
        case intentCandidateMismatch
        /// The new credential bytes could not be durably captured (gateway
        /// or metadata write failure); the previous configuration AND
        /// credential stay byte-identical.
        case credentialWriteFailed
        /// Revoke: the credential deletion failed; the durable cleanup
        /// intent remains in the original queue and the failure is reported
        /// truthfully.
        case credentialRevokeFailed

        /// Closed wire vocabulary for the bridge reply.
        public var wireCode: String {
            switch self {
            case .invalidEndpointID: return "enhancerInvalidEndpoint"
            case .invalidCredentialAccount: return "enhancerInvalidAccount"
            case .persistenceUnavailable: return "enhancerStoreUnavailable"
            case .credentialMissing: return "enhancerCredentialMissing"
            case .credentialAccountOwnership: return "enhancerCredentialOwnership"
            case .intentCandidateMismatch: return "enhancerIntentMismatch"
            case .credentialWriteFailed: return "enhancerCredentialWriteFailed"
            case .credentialRevokeFailed: return "enhancerRevokeFailed"
            }
        }
    }

    private let settings: any SettingsStore
    /// The ORIGINAL metadata authority over this root's ONE database. A
    /// record here (not any string shape) is what makes an account owned.
    private let records: CredentialStore
    /// Trusted runtime ownership resolution (admitted vault context).
    private let runtime: any G09R2EnhancerRuntimeOwnership
    private let gatewayRead: @Sendable (String) async throws -> Data?
    private let gatewayWrite: @Sendable (String, Data) async throws -> Void
    private let gatewayDelete: @Sendable (String) async throws -> Void

    public init(database: DatabaseManager,
                gatewayRead: @escaping @Sendable (String) async throws -> Data? =
                    { reference in
                        guard SecretGatewayRegistry.shared.isRegistered else {
                            throw ConfigurationError.persistenceUnavailable
                        }
                        return try await SecretGatewayRegistry.shared.read(reference: reference)
                    },
                gatewayWrite: @escaping @Sendable (String, Data) async throws -> Void =
                    { reference, value in
                        guard SecretGatewayRegistry.shared.isRegistered else {
                            throw ConfigurationError.persistenceUnavailable
                        }
                        try await SecretGatewayRegistry.shared.write(
                            reference: reference, value: value)
                    },
                gatewayDelete: @escaping @Sendable (String) async throws -> Void =
                    { reference in
                        guard SecretGatewayRegistry.shared.isRegistered else {
                            throw ConfigurationError.persistenceUnavailable
                        }
                        try await SecretGatewayRegistry.shared.delete(reference: reference)
                    }) {
        self.init(settings: SQLiteSettingsStore(database: database),
                  records: CredentialStore(database: database),
                  runtime: G09R2BootstrapEnhancerRuntimeOwnership(database: database),
                  gatewayRead: gatewayRead,
                  gatewayWrite: gatewayWrite,
                  gatewayDelete: gatewayDelete)
    }

    /// Test/host seam: injects any `SettingsStore`, the ORIGINAL
    /// `CredentialStore`, and a runtime-ownership port (focused tests use
    /// the REAL coordinator/admission machinery with a synthetic owned-work
    /// port and a synthetic gated gateway).
    init(settings: any SettingsStore,
         records: CredentialStore,
         runtime: any G09R2EnhancerRuntimeOwnership,
         gatewayRead: @escaping @Sendable (String) async throws -> Data?,
         gatewayWrite: @escaping @Sendable (String, Data) async throws -> Void,
         gatewayDelete: @escaping @Sendable (String) async throws -> Void) {
        self.settings = settings
        self.records = records
        self.runtime = runtime
        self.gatewayRead = gatewayRead
        self.gatewayWrite = gatewayWrite
        self.gatewayDelete = gatewayDelete
    }

    // MARK: - Credential-account ownership (metadata authority)

    /// Parses the vault-minted enhancer account shape `credential.<uuid>`
    /// (record id == uuid). This is a SYMMETRY/shape check only — ownership
    /// itself is always proven by `ownedRecord(for:)` against the ORIGINAL
    /// `CredentialStore`. The predecessor's global-string equality and
    /// `.pending.` staged shapes are gone: a forged pending string is not a
    /// minted capability and is refused before any effect.
    public static func parseOwnedCredentialID(_ account: String) -> UUID? {
        let prefix = "credential."
        guard account.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(account.dropFirst(prefix.count)))
    }

    /// Proves — from THIS root's original metadata authority — that
    /// `account` is the live enhancer credential. Absence, a database read
    /// failure, or any metadata mismatch (wrong kind/owner/origin, account
    /// not bound to the record) is a typed refusal; callers that read
    /// presence convert it to `false`/`nil` with ZERO gateway effects.
    private func ownedRecord(for account: String) async throws -> CredentialRecord {
        guard let id = Self.parseOwnedCredentialID(account) else {
            throw ConfigurationError.credentialAccountOwnership
        }
        let record: CredentialRecord?
        do {
            record = try await records.record(id: id)
        } catch {
            throw ConfigurationError.persistenceUnavailable
        }
        guard let record,
              record.keychainAccount == account,
              record.kind == .providerAPIKey,
              record.owner == .vault,
              record.origin == G09R2EnhancerCredentialPurpose.origin else {
            throw ConfigurationError.credentialAccountOwnership
        }
        return record
    }

    // MARK: - Reference derivation

    /// Opaque reference for one credential account, exactly matching
    /// `SecretGatewayNaming.opaqueReference(namespace:account:)` — the same
    /// reference the App-side `AndroidKeystoreCredentialStore` is addressed
    /// with for every native secret. Callers must have proven ownership via
    /// `ownedRecord(for:)` first.
    public static func opaqueReference(for credentialAccount: String) -> String {
        SecretGatewayNaming.opaqueReference(
            namespace: "keychainAccount", account: credentialAccount)
    }

    // MARK: - Load / presence / resolution (ownership first, then gateway)

    public func load() async throws -> G09R2EnhancerBackendConfiguration? {
        try await settings.value(
            forKey: Self.settingsKey,
            as: G09R2EnhancerBackendConfiguration.self)
    }

    /// True when a non-empty credential exists for the configuration's
    /// account. Ownership is proven from the original metadata BEFORE the
    /// gateway is touched; the bytes are checked and discarded.
    public func credentialConfigured(_ configuration: G09R2EnhancerBackendConfiguration)
        async -> Bool {
        guard configuration.legacyProviderProfileID == nil else { return false }
        guard let record = try? await ownedRecord(for: configuration.credentialAccount)
        else { return false }
        guard let data = try? await gatewayRead(
            Self.opaqueReference(for: record.keychainAccount)),
            !data.isEmpty else { return false }
        return true
    }

    /// Resolved credential bytes for the fal transport; nil when the
    /// configuration is absent, legacy, unproven, or the credential is
    /// missing (no gateway access for unowned rows: this service can never
    /// send another root's or another provider's secret).
    public func credential(for configuration: G09R2EnhancerBackendConfiguration)
        async -> String? {
        guard configuration.legacyProviderProfileID == nil else { return nil }
        guard let record = try? await ownedRecord(for: configuration.credentialAccount)
        else { return nil }
        guard let data = try? await gatewayRead(
            Self.opaqueReference(for: record.keychainAccount)),
            !data.isEmpty,
            let key = String(data: data, encoding: .utf8),
            !key.isEmpty else { return nil }
        return key
    }

    // MARK: - Owned mutation serialization (shared coordinator, not a gate)

    /// Acquires the enhancer coordination-account lease on the SHARED
    /// admitted coordinator and attaches the REAL owned-work receipt BEFORE
    /// any durable side effect. The lease is the scoped operation token:
    /// every effect below re-checks `isCurrent`, and the retirement fence of
    /// the admission context refuses a root rebind while this mutation is
    /// live — a stale caller can never touch a newer owner.
    private static func beginMutation(
        on context: G09R2EnhancerRuntimeContext
    ) async throws -> (lease: VaultAccountLease, receipt: String) {
        let lease: VaultAccountLease
        do {
            lease = try await context.coordinator.acquireAccount(
                G09R2EnhancerCredentialPurpose.coordinationAccount,
                kind: .enhancerConfiguration)
        } catch let error as CredentialVaultCoordinationError {
            // FIFO waiters never surface operationInFlight; a cancelled
            // waiter maps onto plain cancellation.
            switch error {
            case .cancelledWhileWaiting, .operationInFlight:
                throw CancellationError()
            }
        }
        do {
            let receipt = try attachOwnedWork(on: context)
            return (lease, receipt)
        } catch {
            context.coordinator.release(lease)
            throw error
        }
    }

    private static func attachOwnedWork(
        on context: G09R2EnhancerRuntimeContext
    ) throws -> String {
        switch context.ownedWork.attachVaultMaintenance(
            epoch: context.epoch, ownerID: context.coordinator.ownerID) {
        case .attached(let receipt):
            return receipt
        case .rejected(let code):
            throw G09R2EnhancerRuntimeRefusal.ownershipRejected(code)
        case .invalidIdentity:
            throw G09R2EnhancerRuntimeRefusal.ownershipRejected(.invalidOwnerToken)
        }
    }

    private static func endMutation(
        _ context: G09R2EnhancerRuntimeContext,
        receipt: String, lease: VaultAccountLease
    ) {
        _ = context.ownedWork.detachVaultMaintenance(
            receipt: receipt, epoch: context.epoch,
            ownerID: context.coordinator.ownerID)
        context.coordinator.release(lease)
    }

    // MARK: - Save (ONE sealed ingress -> ONE native owned capture)

    /// Persists the typed row. Two shapes:
    ///
    /// * `intentLease == nil` — display-name/endpoint-only edit: the
    ///   current row must exist and be root-owned; the credential bytes are
    ///   left untouched (refuses `credentialMissing` otherwise).
    /// * `intentLease != nil` — key rotation or first key configuration
    ///   through the ORIGINAL sealed secure ingress: the lease is the typed
    ///   one-shot authority produced by `SecretSaveIntentVault.consume(
    ///   token:route:expectedSubject:.enhancerSave)`. Its frozen candidate
    ///   (the secret-free row projection) and its key bytes were captured in
    ///   ONE bounded vault slot at save-tap. This path calls the EXISTING
    ///   `AndroidCredentialVault.capture(kind:.providerAPIKey owner:.vault
    ///   origin:<enhancer purpose>)` ONCE inside the shared coordinator's
    ///   runtime-owned mutation lifetime, revalidates the accepted-root
    ///   fence, persists the row pointing at the NEW immutable owned
    ///   reference LAST, and only then retires the previous credential
    ///   through the ORIGINAL vault delete. Any failure before the row
    ///   persist durably retires the just-captured credential, leaving the
    ///   previous configuration AND credential byte-identical; residual
    ///   cleanup settles through the durable original deletion queue and
    ///   the restart drain. The lease is closed (candidate/secret zeroized,
    ///   vault admission released) only at actual settlement.
    ///
    /// `epoch` pins the exchange to one admitted runtime generation; a root
    /// switch refuses typed (`G09R2EnhancerRuntimeRefusal`) before any
    /// durable side effect, and the live coordinator lease holds the
    /// retirement fence for the whole mutation.
    public func save(
        _ configuration: G09R2EnhancerBackendConfiguration,
        intentLease: SaveIntentLease? = nil,
        epoch: UInt64,
        commitValidation: (@Sendable () async throws -> Void)? = nil
    ) async throws {
        // Function scope: early validation/admission failures also retire the
        // consumed memory lease; an if-scoped defer would close it too soon.
        defer { _ = intentLease?.close() }
        guard G09R2FalSuperResolutionBackend.parsedEndpoint(configuration.endpointID) != nil
        else { throw ConfigurationError.invalidEndpointID }
        let context = try await runtime.context(epoch: epoch)
        let (mutationLease, receipt) = try await Self.beginMutation(on: context)
        defer { Self.endMutation(context, receipt: receipt, lease: mutationLease) }
        // The CURRENT row (if any): only a PROVEN owned credential is
        // retired during rotation. An unproven/stale/legacy row is
        // overwritten by the new one — it is never gateway-accessed, so it
        // can never make the rotation touch a foreign credential. A
        // metadata-READ error is propagated (never collapsed into "no
        // previous"): silently abandoning a live previous credential would
        // leave it referenced-or-live without its retirement.
        let existing: G09R2EnhancerBackendConfiguration?
        do {
            existing = try await load()
        } catch {
            throw ConfigurationError.persistenceUnavailable
        }
        var previousID: UUID?
        if let existing, existing.legacyProviderProfileID == nil,
           let id = Self.parseOwnedCredentialID(existing.credentialAccount) {
            let record: CredentialRecord?
            do {
                record = try await records.record(id: id)
            } catch {
                throw ConfigurationError.persistenceUnavailable
            }
            if let record,
               record.keychainAccount == existing.credentialAccount,
               record.kind == .providerAPIKey,
               record.owner == .vault,
               record.origin == G09R2EnhancerCredentialPurpose.origin {
                previousID = id
            }
        }

        if let intentLease {
            // 1) Exact-subject binding: only the dedicated closed enhancer
            //    ingress can drive this path (the vault consume enforces it;
            //    this is the defensive truth at the effect boundary).
            guard intentLease.subject == .enhancerSave else {
                throw ConfigurationError.credentialAccountOwnership
            }
            // 2) The frozen secret-free candidate is the immutable authority
            //    for the key it carries; it must match the submitted row.
            let candidate = try Self.parseFrozenCandidate(intentLease.candidateJSON)
            guard candidate.endpointID == configuration.endpointID,
                  candidate.displayName == configuration.displayName else {
                throw ConfigurationError.intentCandidateMismatch
            }
            // 3) The key bytes come ONLY from the sealed lease (never from
            //    JSON, never from a host-placed staged reference).
            guard let secret = intentLease.secret, !secret.isEmpty else {
                throw ConfigurationError.credentialMissing
            }
            guard context.coordinator.isCurrent(mutationLease) else {
                throw CancellationError()
            }

            // 4) ONE original vault capture inside the runtime-owned mutation
            //    lifetime: fresh immutable owned account; secret first, then
            //    metadata, durable claim finalized under the live-metadata
            //    guard. The previous reference is NEVER rewritten.
            let newID = UUID()
            do {
                _ = try await context.vault.capture(
                    secret,
                    kind: .providerAPIKey,
                    owner: .vault,
                    label: G09R2EnhancerCredentialPurpose.label,
                    id: newID,
                    origin: G09R2EnhancerCredentialPurpose.origin)
            } catch {
                throw ConfigurationError.credentialWriteFailed
            }
            // 5) Accepted-root fence at the commit point: the row must not
            //    become durable under a root that has already moved on.
            do {
                try await commitValidation?()
            } catch {
                // Fence failure: retire the just-captured credential through
                // the ORIGINAL delete (its durable queue fallback keeps any
                // residual recoverable). The previous row + credential were
                // never touched.
                _ = try? await context.vault.delete(CredentialHandle(id: newID))
                throw error
            }
            guard context.coordinator.isCurrent(mutationLease) else {
                _ = try? await context.vault.delete(CredentialHandle(id: newID))
                throw CancellationError()
            }
            // 6) The typed row commits LAST, pointing at the NEW immutable
            //    owned reference.
            let row = G09R2EnhancerBackendConfiguration(
                displayName: configuration.displayName,
                endpointID: configuration.endpointID,
                credentialAccount: Self.account(for: newID))
            do {
                try await settings.setValue(row, forKey: Self.settingsKey)
            } catch {
                _ = try? await context.vault.delete(CredentialHandle(id: newID))
                throw ConfigurationError.persistenceUnavailable
            }
            // 7) Rotation retirement AFTER the row points at the new
            //    credential. The previous reference was never rewritten, so
            //    a failure here cannot corrupt the now-live configuration;
            //    the original vault delete enqueues the durable cleanup
            //    intent and any residual settles through the restart drain
            //    (which can never delete the newer live reference — its
            //    decision table revalidates live metadata under the claim
            //    row).
            if let previousID, previousID != newID {
                _ = try? await context.vault.delete(CredentialHandle(id: previousID))
            }
        } else {
            guard let existing else {
                throw ConfigurationError.credentialMissing
            }
            guard existing.legacyProviderProfileID == nil else {
                throw ConfigurationError.invalidCredentialAccount
            }
            let record = try await ownedRecord(for: existing.credentialAccount)
            let liveReference = Self.opaqueReference(for: record.keychainAccount)
            guard let data = try? await gatewayRead(liveReference), !data.isEmpty else {
                throw ConfigurationError.credentialMissing
            }
            do {
                try await commitValidation?()
            } catch {
                throw error
            }
            guard context.coordinator.isCurrent(mutationLease) else {
                throw CancellationError()
            }
            let row = G09R2EnhancerBackendConfiguration(
                displayName: configuration.displayName,
                endpointID: configuration.endpointID,
                credentialAccount: existing.credentialAccount)
            do {
                try await settings.setValue(row, forKey: Self.settingsKey)
            } catch {
                throw ConfigurationError.persistenceUnavailable
            }
        }
    }

    // MARK: - Sealed candidate (closed, secret-free)

    /// The frozen enhancer candidate carried by the sealed ingress lease.
    /// Closed shape: exactly the secret-free row projection, bound at
    /// save-tap to the key bytes in the same vault slot.
    private struct FrozenEnhancerCandidate: Equatable {
        let displayName: String?
        let endpointID: String
    }

    /// Closed enhancer editor identity: the route-admission subject id and
    /// the frozen candidate id. This is the ONE enhancer settings editor
    /// identity (never a credential account, never gateway-addressed).
    static var enhancerEditorID: String {
        G09R2EnhancerCredentialPurpose.coordinationAccount
    }

    /// The `credential.<uuid>` account for one captured record id, exactly
    /// the shape `parseOwnedCredentialID` proves.
    static func account(for id: UUID) -> String {
        "credential.\(id.uuidString)"
    }

    /// Parses + validates the frozen secret-free candidate. Refuses typed
    /// (`intentCandidateMismatch`) before any gateway access on any shape
    /// deviation: the closed key set, the exact editor identity, a bounded
    /// display name and a parseable endpoint.
    private static func parseFrozenCandidate(_ data: Data) throws
        -> FrozenEnhancerCandidate {
        guard let object = (try? JSONSerialization.jsonObject(with: data))
                as? [String: Any],
              Set(object.keys).isSubset(of: ["id", "displayName", "endpointID"]),
              object["id"] as? String == enhancerEditorID,
              let endpointID = object["endpointID"] as? String,
              !endpointID.isEmpty,
              G09R2FalSuperResolutionBackend.parsedEndpoint(endpointID) != nil
        else { throw ConfigurationError.intentCandidateMismatch }
        let displayName = object["displayName"] as? String
        if let displayName, displayName.utf8.count > 256 {
            throw ConfigurationError.intentCandidateMismatch
        }
        return FrozenEnhancerCandidate(
            displayName: displayName, endpointID: endpointID)
    }

    // MARK: - Clear (truthful revoke through the original retirement)

    /// Revokes the configuration. Gateway effects happen ONLY when this
    /// root's original metadata proves the live credential record: it is
    /// then retired through the ORIGINAL vault delete FIRST (metadata
    /// delete enqueues the durable cleanup intent; the targeted gateway
    /// delete + conditional completion run under the vault's own account
    /// lease), and only a completed cleanup removes the row. An incomplete
    /// cleanup is reported truthfully via `credentialRevokeFailed` with the
    /// row preserved for retry; the restart drain settles the original
    /// claim, after which the retry removes the row WITHOUT any gateway
    /// access (the credential is then provably retired under the
    /// supported-writer envelope). A row whose account is NOT proven
    /// (foreign/credential-shaped without metadata, legacy global string,
    /// or legacy provider reference) is removed with ZERO gateway effects —
    /// an unproven account string can never cause this service to touch a
    /// secret.
    public func clear(epoch: UInt64) async throws {
        let context = try await runtime.context(epoch: epoch)
        let (lease, receipt) = try await Self.beginMutation(on: context)
        defer { Self.endMutation(context, receipt: receipt, lease: lease) }

        let existing: G09R2EnhancerBackendConfiguration?
        do {
            existing = try await load()
        } catch {
            throw ConfigurationError.persistenceUnavailable
        }
        guard let existing else { return }
        guard context.coordinator.isCurrent(lease) else {
            throw CancellationError()
        }
        if let liveID = Self.parseOwnedCredentialID(existing.credentialAccount) {
            let record: CredentialRecord?
            do {
                record = try await records.record(id: liveID)
            } catch {
                throw ConfigurationError.persistenceUnavailable
            }
            if let record,
               record.keychainAccount == existing.credentialAccount,
               record.kind == .providerAPIKey,
               record.owner == .vault,
               record.origin == G09R2EnhancerCredentialPurpose.origin {
                do {
                    let outcome = try await context.vault.delete(
                        CredentialHandle(id: liveID))
                    let cleanup = outcome.secretCleanup
                    if cleanup != .completed {
                        // Durably intent-queued but not proven complete
                        // (physical erase still pending, e.g. an immediate
                        // retry BEFORE the deletion-queue drain): keep the
                        // row so the user can retry; the restart drain
                        // settles the queue, after which the retry removes
                        // the row without any gateway access.
                        throw ConfigurationError.credentialRevokeFailed
                    }
                } catch let error as ConfigurationError {
                    throw error
                } catch let error as AndroidCredentialVaultError {
                    // The original delete could not produce an outcome.
                    // A METADATA store failure is propagated as a store
                    // error (the retirement did not durably happen — never
                    // reported as credential-erased success while this root
                    // still holds the outstanding claim); every other
                    // failure is an incomplete cleanup reported truthfully
                    // with the row preserved for retry/drain.
                    switch error {
                    case .metadataDeleteFailed:
                        throw ConfigurationError.persistenceUnavailable
                    default:
                        throw ConfigurationError.credentialRevokeFailed
                    }
                } catch {
                    throw ConfigurationError.credentialRevokeFailed
                }
            }
            // Unproven credential-shaped row: removed below with ZERO
            // gateway access.
        }
        // Non-credential shapes (legacy global string, `provider.*`, any
        // garbage): no reference derived, no gateway effect; the row is
        // simply removed.
        guard context.coordinator.isCurrent(lease) else {
            throw CancellationError()
        }
        do {
            try await settings.removeValue(forKey: Self.settingsKey)
        } catch {
            throw ConfigurationError.persistenceUnavailable
        }
    }

    /// Erases the credential bytes for an explicitly proven account (host
    /// and test seams). Ownership is proven from the original metadata
    /// BEFORE the gateway delete; an absent reference is a no-op success, a
    /// gateway failure is reported. Production revocation flows through
    /// `clear(epoch:)`; this helper intentionally performs no settings-row
    /// or record mutation.
    public func eraseCredential(account: String) async throws {
        _ = try await ownedRecord(for: account)
        do {
            try await gatewayDelete(Self.opaqueReference(for: account))
        } catch {
            throw ConfigurationError.credentialRevokeFailed
        }
    }

    // MARK: - Validation

    /// Bounded keychain-account shape (mirrors the provider credential
    /// account discipline: printable, bounded, no whitespace/control). This
    /// is the outer shape check only; enhancer OWNERSHIP is the stricter
    /// metadata proof in `ownedRecord(for:)`.
    public static func isValidCredentialAccount(_ account: String) -> Bool {
        !account.isEmpty && account.utf8.count <= 128
            && account.unicodeScalars.allSatisfy {
                $0.value >= 33 && $0.value <= 126
            }
    }
}
