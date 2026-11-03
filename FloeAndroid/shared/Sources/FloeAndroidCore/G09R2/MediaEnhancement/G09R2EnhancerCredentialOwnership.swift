// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 enhancer credential — ROOT-OWNED runtime binding
// (job-7951fc7bca9946bc, closing the PRIMARY_REJECTION counterexamples of
// job-c35cda51f6a94aa9).
//
// WHY THIS FILE EXISTS: the predecessor store proved "ownership" by string
// equality against ONE global account (`media.enhancement.superResolution`).
// The opaque gateway reference hashes ONLY `keychainAccount`, so two
// independent runtime roots whose (restored/malformed) settings rows carried
// the same allowed string resolved to the SAME Android credential — rootA
// and rootB could read/send/delete each other's key (zero distinguishing
// metadata, no owner/epoch proof). This binding replaces that with the
// ORIGINAL authorities:
//
//   * Metadata authority — the original FloePersistence.CredentialStore over
//     the root's ONE DatabaseManager. The enhancer credential is an ordinary
//     vault credential (`credential.<uuid>` account, record id == uuid,
//     `kind == .providerAPIKey`, `owner == .vault`) whose `origin` carries
//     the enhancer purpose marker. A settings row is usable ONLY when this
//     root's CredentialStore proves the record (cross-root rows fail here →
//     ZERO gateway effects). No ProviderProfile is fabricated; a string
//     label alone is never treated as metadata authority.
//   * Lifecycle authority — the admitted AndroidCredentialVault /
//     CredentialVaultOperationCoordinator + the real
//     RuntimeOwnedWorkRegistry port (`VaultOwnedWorkAttaching`). Mutations
//     serialize on the SHARED admitted coordinator's
//     `.enhancerConfiguration` account lease held across every await, with
//     the `.vaultMaintenance` receipt attached before the first durable
//     effect — the previous lane's process-wide NSLock gate is gone (it both
//     violated Swift 6 `NSLock` async availability and cloned an independent
//     lifecycle next to the real one).
//   * Rotation authority — immutable: a NEW owned account + reference is
//     minted/committed and the settings row is repointed LAST; the previous
//     reference is NEVER rewritten, so a settings-commit failure (even with
//     a failed cleanup) leaves the previous configuration AND credential
//     byte-identical. Orphan staged/retired references keep their durable
//     original `credential_deletion_queue` claims and settle through the
//     real restart drain.
import Foundation
import FloePersistence

// MARK: - Enhancer credential purpose (original CredentialRecord.origin)

/// The enhancer purpose as carried by the ORIGINAL `CredentialRecord.origin`
/// column — existing metadata, no schema change. The label is user-facing
/// and secret-free.
public enum G09R2EnhancerCredentialPurpose {
    /// Distinguishes the enhancer credential from every other vault record
    /// in the same root (`.vault` owner is shared by design; origin is the
    /// purpose discriminator).
    public static let origin = "floe.g09r2.enhancer.superResolution"
    /// User-facing, secret-free record label.
    public static let label = "Floe enhancer (super-resolution)"
    /// Lease key that serializes enhancer configuration mutations on the
    /// SHARED admitted coordinator. It is ONLY a coordination key — never a
    /// credential account, never a gateway reference, never persisted.
    public static let coordinationAccount = "media.enhancement.superResolution"
}

// MARK: - Runtime ownership resolution (typed, fail-closed)

/// Why the trusted runtime ownership context could not be resolved.
public enum G09R2EnhancerRuntimeRefusal: Error, Sendable, Equatable {
    /// The requested epoch is not the live admitted generation (root moved
    /// on, retirement in flight, or database drift).
    case staleGeneration
    /// The vault runtime admission refused (`.ownerMismatch`,
    /// `.rebindWhileOwned`, `.epochNotNewer`, …). Carries the exact
    /// reviewed lifecycle code; the operation fails closed BEFORE any
    /// durable side effect.
    case ownershipRejected(RuntimeFacadeCode)
}

/// The trusted ownership context for ONE enhancer configuration exchange.
/// Everything here comes from the ADMITTED runtime context (full owner
/// identity: exact normalized root path + full owner token + typed epoch) —
/// never a fingerprint, never model JSON, never a caller path.
public struct G09R2EnhancerRuntimeContext: Sendable {
    /// The admitted epoch this exchange is bound to.
    public let epoch: UInt64
    /// The SHARED coordinator every vault wrapper over this runtime context
    /// coordinates through (CV-R1: one gate set per admitted context).
    public let coordinator: CredentialVaultOperationCoordinator
    /// The REAL owned-work port (production:
    /// `RuntimeOwnedWorkRegistryAttachment.shared`; tests: a synthetic with
    /// the same contract).
    public let ownedWork: any VaultOwnedWorkAttaching
    /// The admitted vault over this runtime context (shares `coordinator`).
    /// Staging mint/commit/discard and credential retirement run through it.
    public let vault: AndroidCredentialVault

    public init(epoch: UInt64, coordinator: CredentialVaultOperationCoordinator,
                ownedWork: any VaultOwnedWorkAttaching, vault: AndroidCredentialVault) {
        self.epoch = epoch
        self.coordinator = coordinator
        self.ownedWork = ownedWork
        self.vault = vault
    }
}

/// Narrow port the store uses to obtain the trusted context per exchange.
/// Production resolves the ADMITTED runtime cluster; tests inject a
/// synthetic over the REAL coordinator/admission machinery.
public protocol G09R2EnhancerRuntimeOwnership: Sendable {
    func context(epoch: UInt64) async throws -> G09R2EnhancerRuntimeContext
}

// MARK: - Production composition

/// Production context factories over the admitted runtime cluster. The
/// vault join performs the REAL `CredentialVaultRuntimeAdmission.admit`
/// (full identity + one DatabaseManager): same identity + epoch + manager →
/// the SAME shared coordinator the rest of the graph coordinates through;
/// a drifted/stale epoch or a retired/admission-refused context throws the
/// typed refusal before any durable side effect.
public enum G09R2EnhancerRuntime {
    /// Bridge/host path: resolve the live cluster for `epoch` and admit.
    public static func context(epoch: UInt64) async throws
        -> G09R2EnhancerRuntimeContext {
        guard let cluster = await AndroidRuntimeBootstrap.creativeCluster(
            epoch: epoch) else {
            throw G09R2EnhancerRuntimeRefusal.staleGeneration
        }
        return try makeContext(cluster: cluster)
    }

    /// Service path: additionally require the live cluster's database to be
    /// the SAME physical manager the store was built over (never silently
    /// coordinate through a reopened/other-root manager).
    public static func context(
        epoch: UInt64, database: DatabaseManager
    ) async throws -> G09R2EnhancerRuntimeContext {
        guard let cluster = await AndroidRuntimeBootstrap.creativeCluster(
            epoch: epoch),
              ObjectIdentifier(cluster.database) == ObjectIdentifier(database) else {
            throw G09R2EnhancerRuntimeRefusal.staleGeneration
        }
        return try makeContext(cluster: cluster)
    }

    static func makeContext(cluster: G02OwnedStoreCluster) throws
        -> G09R2EnhancerRuntimeContext {
        let ownedWork = RuntimeOwnedWorkRegistryAttachment.shared
        // Join (or share) the admitted context. Any admission refusal maps
        // onto the typed ownership refusal.
        let vault: AndroidCredentialVault
        do {
            vault = try AndroidCredentialVault.joinRuntimeOwnership(
                database: cluster.database,
                identity: cluster.identity,
                ownedWork: ownedWork,
                gateway: SecretGatewayRegistryForwarder())
        } catch AndroidCredentialVaultError.ownershipAdmissionRejected(let code) {
            throw G09R2EnhancerRuntimeRefusal.ownershipRejected(code)
        } catch AndroidCredentialVaultError.ownedWorkAdmissionRejected(let code) {
            throw G09R2EnhancerRuntimeRefusal.ownershipRejected(code)
        } catch AndroidCredentialVaultError.ownedWorkAdmissionInvalidIdentity {
            throw G09R2EnhancerRuntimeRefusal.ownershipRejected(.invalidOwnerToken)
        }
        // The join just admitted (or joined) this exact identity + manager,
        // so this second admit is idempotent and hands over the SAME shared
        // coordinator instance for lease serialization.
        let admission = CredentialVaultRuntimeAdmission.admit(
            identity: cluster.identity, database: cluster.database)
        guard let coordinator = admission.coordinator else {
            throw G09R2EnhancerRuntimeRefusal.ownershipRejected(.internal)
        }
        return G09R2EnhancerRuntimeContext(
            epoch: cluster.identity.epoch,
            coordinator: coordinator,
            ownedWork: ownedWork,
            vault: vault)
    }
}

/// Database-bound production ownership port used by the configuration store.
public struct G09R2BootstrapEnhancerRuntimeOwnership: G09R2EnhancerRuntimeOwnership {
    public let database: DatabaseManager
    public init(database: DatabaseManager) { self.database = database }
    public func context(epoch: UInt64) async throws
        -> G09R2EnhancerRuntimeContext {
        try await G09R2EnhancerRuntime.context(epoch: epoch, database: database)
    }
}
