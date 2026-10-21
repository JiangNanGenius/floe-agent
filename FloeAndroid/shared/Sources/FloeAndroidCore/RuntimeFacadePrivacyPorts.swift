// SPDX-License-Identifier: MPL-2.0
//
// RuntimeFacadePrivacyPorts — typed REQUIRED owner ports for the G02 privacy
// clear lane.
//
// Composition authority: consume the REAL owners by name; never invent a
// second business database, permission store, provider gate or secret
// namespace. Production bindings are constructed in
// `G02PrivacyDomainExtension.swift` over the accepted generation:
//   * global launch admission fence / pending-launch quiescence —
//     `FacadeRunDomain` behind `G02RunPrivacyGlobalFence`;
//   * per-conversation deletion — the EXISTING
//     `ConversationDeletionLifecycle` (`RunDomainDeletionLifecycle`);
//   * provider reservation — the EXISTING `ProviderOperationOwning`
//     (`ProviderOperationCoordinatorRegistry` per DatabaseManager context);
//   * secret ordering — the accepted `SecretGatewayRegistry` plus the
//     ORIGINAL V11 `credential_deletion_queue` (no provider-cleanup ledger
//     reuse and no second namespace);
//   * grants — the ORIGINAL `SQLiteWorkspaceStore` and `ApprovalGrantStore`;
//   * P8 runtime-event suppression — the composition's REAL
//     `noteHistoryClearInFlight` flag consumed by the existing fence
//     provider (no separate dropper);
//   * root-owned operation lease — the REAL `RuntimeOwnedWorkRegistry`.
//
// Optional ports (credential drain, workspace cleaning) report truthful
// deferral when unbound. A REQUIRED port that is unbound refuses BEFORE the
// first effect; there is no noop success anywhere.
import Foundation
import FloeCore
import FloeModels
import FloePersistence
import FloeSecurity
import FloeAgentRuntime

// MARK: - Trusted native host confirmation

/// Opaque one-operation confirmation binding. It is created ONLY by the
/// privileged native store after a real user tap on the previewed action;
/// the model/App command path can present its token but can never mint it.
public struct PrivacyHostConfirmationBinding: Sendable, Equatable {
    public let operation: String
    public let action: String
    /// Trusted-root identity token (`sha256:<hex>` of the exact normalized
    /// app-private root; never the raw path).
    public let root: String
    public let epoch: UInt64
    /// The preview digest the user actually confirmed.
    public let previewDigest: String
    /// The trusted host invocation identity. The App passes the exact
    /// correlationID it will use for the resulting command, so a capability
    /// can never be "stolen" by a different command invocation that happens
    /// to share the same operation/action/digest tuple.
    public let invocationID: String

    public init(operation: String, action: String, root: String, epoch: UInt64,
                previewDigest: String, invocationID: String) {
        self.operation = operation
        self.action = action
        self.root = root
        self.epoch = epoch
        self.previewDigest = previewDigest
        self.invocationID = invocationID
    }
}

// MARK: - Global launch admission fence (REAL RB4 owner behind this port)

/// Exact privacy-lane port of the RB4 global admission fence. The fence is
/// an explicit operation-owned lifetime: released or committed exactly on
/// stale/error/cancel/success; a stale finish can never clear a newer fence;
/// refusal paths leave FUTURE ordinary launches usable once the real pending
/// work settled; no timer release and no detach of owned producers.
public protocol PrivacyGlobalAdmissionFencing: Sendable {
    func beginGlobalAdmissionFence(expectedEpoch: UInt64) async throws
        -> GlobalAdmissionFenceToken
    /// Real pending-launch quiescence: `.admitting`/`.prepared` launches
    /// reach their honest C0/C1 settlement before the snapshot claims the
    /// run set is stable. Never cancels anything.
    func awaitPendingLaunchesSettled(expectedEpoch: UInt64) async throws
    /// Exact-token settle. False for a stale/foreign token.
    func finishGlobalAdmissionFence(_ token: GlobalAdmissionFenceToken,
                                    committed: Bool) async -> Bool
}

// MARK: - Grant stores (both original layers)

/// In-memory approval grant snapshot + revocation. Production delegates to
/// the ACTUAL per-run runtime grants of this root/epoch's live services
/// (there is no second grant store). The snapshot throws typed when one
/// grant id carries conflicting ownership metadata; the snapshot engine's
/// g1/g2 bracket retries and then fails closed on unstable streams.
public protocol PrivacyInMemoryGrantStore: Sendable {
    func snapshotGrants() async throws -> [ApprovalGrant]
    func revokeGrant(id: UUID) async
}

/// Persisted approval_grants deletion. Production is the ORIGINAL
/// `SQLiteWorkspaceStore` actor (`deleteGrant(id:)`); the snapshot engine
/// reads the rows inside its own reader transaction, so this port only owns
/// the destructive step.
public protocol PrivacyPersistedGrantStore: Sendable {
    func deleteGrant(id: UUID) async throws
}

// MARK: - Secret deletion ordering (accepted gateway + durable V11 queue)

/// Result of ONE provider secret deletion attempt.
public struct PrivacySecretDeletionOutcome: Sendable {
    /// True only when the physical deletion is authoritative: an observing
    /// gateway settled the exact claim, or the frozen CRUD success contract
    /// completed the delete. A cancellation while the physical claim is
    /// still outstanding is NOT settled.
    public var settled: Bool
    /// Bounded opaque reason when not settled.
    public var reason: String?
    /// True when a real physical claim may still land. The caller must keep
    /// the provider reservation and park it for reconciliation instead of
    /// releasing on the logical return.
    public var physicalOutstanding: Bool
    /// Exact mailbox receipt for this attempt, when observed.
    public var receipt: PhysicalOperationReceipt?
    /// The exact attempt-time observer that minted `receipt`. Never replaced
    /// by a later registry lookup.
    public var witness: (any PhysicalObservingSecretGateway)?

    public init(settled: Bool, reason: String? = nil,
                physicalOutstanding: Bool = false,
                receipt: PhysicalOperationReceipt? = nil,
                witness: (any PhysicalObservingSecretGateway)? = nil) {
        self.settled = settled
        self.reason = reason
        self.physicalOutstanding = physicalOutstanding
        self.receipt = receipt
        self.witness = witness
    }
}

/// The EXISTING config.provider.delete ordering, consumed verbatim:
/// pendingDeletion enqueue -> gateway.delete(reference) -> completeDeletion
/// | recordDeletionFailure (bootstrap drain replays the durable intent).
/// Actor/external calls — NEVER inside a DB writer closure.
public protocol PrivacySecretDeletionOrdering: Sendable {
    /// Registration truth of the product gateway. When unregistered and an
    /// enumerated provider holds a secret reference, the clear fails closed
    /// with needsConfiguration{gatewayUnregistered} BEFORE any mutation.
    func hasRegisteredGateway() async -> Bool
    /// Credential sub-summary truthfulness for privacy.summary.get:
    /// AVAILABLE only when the accepted product-UID gateway is actually
    /// registered; NEEDS_CONFIGURATION otherwise (source presence alone
    /// proves nothing).
    func credentialAvailability() async -> PrivacyCredentialAvailability
    /// Durable pendingDeletion intent in the ORIGINAL V11
    /// credential_deletion_queue. Returns this intent's `enqueued_at`
    /// generation so completion/recording can be conditional (a newer
    /// intent is never erased by a stale finalizer).
    func enqueuePendingDeletion(account: String,
                                synchronizable: Bool) async throws -> String
    /// Physical secret deletion through the registered gateway. Never
    /// reports success for an unregistered gateway.
    func deleteSecret(reference: String) async throws
        -> PrivacySecretDeletionOutcome
    /// Queue completion (exact row removed) after a confirmed delete.
    func completeDeletion(account: String, generation: String) async throws
    /// Queue retention + redacted last_error after a failed delete.
    func recordDeletionFailure(account: String, generation: String,
                               message: String) async throws
}

// MARK: - Provider operation ownership (REAL model-config coordinator)

/// The privacy lane reserves each enumerated provider through the SHARED
/// model-configuration operation coordinator. The reservation binds
/// provider/root context and is held across the real awaited gateway effects;
/// a newer Set cannot interleave even when the secret reference is
/// byte-identical.
public protocol PrivacyProviderOperationOwning: Sendable {
    func beginOperation(providerID: UUID,
                        kind: ProviderOperationKind) async
        -> ProviderOperationBeginOutcome
    func endOperation(_ ticket: ProviderOperationTicket) async
    /// Keep an EXACT unsettled physical owner: the ticket is converted to
    /// the durable pending owner with its receipt/witness so the model-config
    /// reconciler can settle it after REAL completion. Never a timeout drop.
    func parkPending(_ ticket: ProviderOperationTicket,
                     receipt: PhysicalOperationReceipt?,
                     witness: (any PhysicalObservingSecretGateway)?) async -> Bool
}

// MARK: - Root-owned operation lease

/// The REAL RB1 owned-work registry surface used to keep the accepted root
/// open until the clear operation truly settles. Attach happens BEFORE the
/// first signal; detach only at real completion, with the exact token.
public protocol PrivacyOwnedWorkOwning: Sendable {
    func attach(epoch: UInt64, kind: RuntimeOwnedWorkKind,
                ownerID: String) -> RuntimeOwnedWorkToken?
    func detach(_ token: RuntimeOwnedWorkToken) -> Bool
}
