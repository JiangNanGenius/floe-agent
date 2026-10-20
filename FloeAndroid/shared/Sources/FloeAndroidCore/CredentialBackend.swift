// RB2-REPAIR PRIVATE CANDIDATE MIRROR (job-ffa06be4f2d34ac4, 2026-10-19).
// Preimage: FloeAndroid/shared/Sources/FloeAndroidCore/CredentialBackend.swift
// SHA-256 e485fb99bae1bcfb15cc830b2034305e862b23880e7f9f47cec5f4781182c1e6 —
// byte-identical baseline. Main-authorized 2026-10-19
// (MAIN_GATEWAY_PHYSICAL_LIFETIME_API_GAP_20261019.json) ADDITIVE delta ONLY:
// the new PhysicalObservingSecretGateway types/protocol and the registry's
// forwarding conformance. Existing protocol members, the registry's CRUD
// behavior, error cases, the deterministic namespace/reference mapping and
// the C/JNI ABI are unchanged. NO live/root write; future Main serialized
// publication applies the narrow delta patch onto CURRENT bytes.
// SPDX-License-Identifier: MPL-2.0
// SPDX-License-Identifier: MPL-2.0
import Foundation
import Crypto
import FloeCore

/// Fail-closed Android secret backend seam.
///
/// Main architecture decision #5: the Android overlay EXCLUDES the original
/// KeychainStore.swift entirely (its non-Security branch is a process-wide
/// RAM store). Secrets live only behind the frozen Kotlin `CredentialStore`
/// suspend API in Main's `:core:credentials` module; this Swift side owns the
/// typed gateway protocol, its registration state and the deterministic
/// namespace/reference mapping. With no registered gateway every caller gets
/// NEEDS_CONFIGURATION — there is no memory fallback anywhere, and this lane
/// never reads, writes or stores real secrets.
public protocol AndroidSecretGateway: Sendable {
    /// Opaque reference from `SecretGatewayNaming.opaqueReference`.
    func read(reference: String) async throws -> Data?
    func write(reference: String, value: Data) async throws
    func delete(reference: String) async throws
}

public enum SecretGatewayError: Error, Equatable, Sendable {
    /// Fail-closed result when no gateway is registered (never a RAM stub).
    case needsConfiguration
}

/// Registration state for the JNI Keystore gateway. Registration happens only
/// from host app startup code (later package P2 once `:core:credentials`
/// integration lands); model JSON, imported content and tool output can never
/// register a gateway.
public final class SecretGatewayRegistry: @unchecked Sendable {
    public static let shared = SecretGatewayRegistry()
    private let lock = NSLock()
    private var gateway: (any AndroidSecretGateway)?

    private func snapshotGateway() -> (any AndroidSecretGateway)? {
        lock.lock(); defer { lock.unlock() }
        return gateway
    }
    private func setGateway(_ value: (any AndroidSecretGateway)?) {
        lock.lock(); gateway = value; lock.unlock()
    }
    public func register(_ gateway: any AndroidSecretGateway) { setGateway(gateway) }
    public func unregister() { setGateway(nil) }
    public var isRegistered: Bool { snapshotGateway() != nil }

    /// CRUD passthrough that FAILS CLOSED without a registered gateway.
    /// Secret bytes cross this seam in-memory only while a real backend is
    /// attached; nothing here persists or caches them. The NSLock section is
    /// synchronous (`snapshotGateway`); async context restrictions are
    /// respected.
    public func read(reference: String) async throws -> Data? {
        guard let gateway = snapshotGateway() else { throw SecretGatewayError.needsConfiguration }
        return try await gateway.read(reference: reference)
    }
    public func write(reference: String, value: Data) async throws {
        guard let gateway = snapshotGateway() else { throw SecretGatewayError.needsConfiguration }
        try await gateway.write(reference: reference, value: value)
    }
    public func delete(reference: String) async throws {
        guard let gateway = snapshotGateway() else { throw SecretGatewayError.needsConfiguration }
        try await gateway.delete(reference: reference)
    }
}

// MARK: - RB2-REPAIR additive registry forwarding (Main-authorized 2026-10-19)

/// The declared conformance must live in THIS file: forwarding needs the
/// registry's private snapshotGateway(). Existing CRUD members and behavior
/// are untouched; when the registered gateway does NOT support observation
/// the observed calls degrade to the EXACT existing CRUD path and no receipt
/// is delivered (callers stay on the conservative rules — never a fake
/// physical signal).
extension SecretGatewayRegistry: PhysicalObservingSecretGateway {
    /// Whether physical observation forwards to the currently registered
    /// gateway. A registry state check, not a settlement signal.
    public var supportsPhysicalObservation: Bool {
        snapshotGateway() as? (any PhysicalObservingSecretGateway) != nil
    }

    public func readObserved(reference: String,
                             onQueued: (@Sendable (PhysicalOperationReceipt) -> Void)?)
        async throws -> Data?
    {
        guard let gateway = snapshotGateway() else { throw SecretGatewayError.needsConfiguration }
        if let observed = gateway as? any PhysicalObservingSecretGateway {
            return try await observed.readObserved(reference: reference, onQueued: onQueued)
        }
        return try await gateway.read(reference: reference)
    }

    public func writeObserved(reference: String, value: Data,
                              onQueued: (@Sendable (PhysicalOperationReceipt) -> Void)?)
        async throws
    {
        guard let gateway = snapshotGateway() else { throw SecretGatewayError.needsConfiguration }
        if let observed = gateway as? any PhysicalObservingSecretGateway {
            try await observed.writeObserved(reference: reference, value: value,
                                             onQueued: onQueued)
            return
        }
        try await gateway.write(reference: reference, value: value)
    }

    public func deleteObserved(reference: String,
                               onQueued: (@Sendable (PhysicalOperationReceipt) -> Void)?)
        async throws
    {
        guard let gateway = snapshotGateway() else { throw SecretGatewayError.needsConfiguration }
        if let observed = gateway as? any PhysicalObservingSecretGateway {
            try await observed.deleteObserved(reference: reference, onQueued: onQueued)
            return
        }
        try await gateway.delete(reference: reference)
    }

    public func physicalSnapshot(claim: Int64) -> PhysicalOperationSnapshot {
        guard let observed = snapshotGateway() as? any PhysicalObservingSecretGateway else {
            return .notRecorded
        }
        return observed.physicalSnapshot(claim: claim)
    }

    public func resolvePhysical(claim: Int64) -> Bool {
        guard let observed = snapshotGateway() as? any PhysicalObservingSecretGateway else {
            return true
        }
        return observed.resolvePhysical(claim: claim)
    }

    public func awaitPhysicalSettlement(claim: Int64) async -> PhysicalOperationSnapshot {
        guard let observed = snapshotGateway() as? any PhysicalObservingSecretGateway else {
            return .notRecorded
        }
        return await observed.awaitPhysicalSettlement(claim: claim)
    }
}

// MARK: - RB2-REPAIR additive: per-operation physical lifetime API
// (Main-authorized 2026-10-19; MC-R4 closure). The existing
// AndroidSecretGateway/SecretGatewayRegistry CRUD surface is UNCHANGED; this
// seam lets an owned operation observe ITS OWN physical backend truth (an
// individual claim's completion/never-dispatch) instead of inferring
// settlement from statsJSON, global counters, re-reads, timeouts or durable
// intent. MailboxSecretGateway implements it in SecretGatewayMailbox.swift;
// the registry forwards only when the registered gateway supports it — an
// unsupported gateway yields the exact existing CRUD path with NO receipt,
// which callers must treat as honest non-evidence.

public enum PhysicalOperationKind: Sendable, Equatable {
    case read
    case write
    case delete
}

/// Identity of ONE physical backend operation. `claim` is the mailbox ticket
/// token — an opaque host-side handle, not model authority. `tracked ==
/// false` means the bounded record could not be retained: honest untracked,
/// never a fake settlement. Carries no secret and no plaintext.
public struct PhysicalOperationReceipt: Sendable, Equatable {
    public let claim: Int64
    public let epoch: UInt64
    public let reference: String
    public let kind: PhysicalOperationKind
    public let tracked: Bool

    public init(claim: Int64, epoch: UInt64, reference: String,
                kind: PhysicalOperationKind, tracked: Bool) {
        self.claim = claim
        self.epoch = epoch
        self.reference = reference
        self.kind = kind
        self.tracked = tracked
    }
}

/// Provable never-dispatch terminations: the ticket left the mailbox before
/// any poller could claim it (the claim→store launch segment on the frozen
/// dispatcher is one non-suspending segment, so queue removal structurally
/// means the store NEVER saw this operation).
public enum PhysicalNeverDispatchedReason: String, Sendable, Equatable {
    case cancelledBeforeClaim
    case replacedBeforeClaim
    case closedBeforeClaim
    case watchdogDrainedQueued
}

public enum PhysicalOperationSnapshot: Sendable, Equatable {
    /// No physical proof for this claim (never queued / capacity-untracked /
    /// consumer-resolved / mailbox reset). Honest non-evidence.
    case notRecorded
    /// Queued, not yet claimed (dispatchable window).
    case queued
    /// Claimed; the real host completion has NOT yet arrived — execution may
    /// still mutate the backend.
    case claimedOutstanding
    /// The real host completion arrived exactly once (statuses 1..4 / -1..-16
    /// per the frozen mailbox terminal protocol; the caller classifies EFFECT
    /// from the same authoritative table used by the mailbox itself).
    case settled(status: Int32)
    /// Provably never reached any poller/store.
    case neverDispatched(reason: PhysicalNeverDispatchedReason)
}

public protocol PhysicalObservingSecretGateway: Sendable {
    /// `onQueued` fires OUTSIDE the mailbox lock exactly once when (and if)
    /// the ticket is queued-accepted, delivering the individual receipt.
    func readObserved(reference: String,
                      onQueued: (@Sendable (PhysicalOperationReceipt) -> Void)?) async throws -> Data?
    func writeObserved(reference: String, value: Data,
                       onQueued: (@Sendable (PhysicalOperationReceipt) -> Void)?) async throws
    func deleteObserved(reference: String,
                        onQueued: (@Sendable (PhysicalOperationReceipt) -> Void)?) async throws
    /// Synchronous individual physical truth for one claim.
    func physicalSnapshot(claim: Int64) -> PhysicalOperationSnapshot
    /// Consumer release; refuses while the record is still outstanding.
    func resolvePhysical(claim: Int64) -> Bool
    /// Actual-settlement subscription: awaits ONLY terminal individual truth
    /// (settled/neverDispatched) or `.notRecorded`; never a manufactured
    /// timeout, never a global counter. Caller cancellation returns the
    /// current snapshot honestly (owners/callers decide the retention).
    func awaitPhysicalSettlement(claim: Int64) async -> PhysicalOperationSnapshot
}

// MARK: - Per-attempt observation resolution (MC-CAPACITY-2)

/// A mutable gateway REGISTRY can be re-pointed between a capability probe
/// and the actual CRUD. Main (2026-10-19) requires observation support to be
/// a property of the gateway bound FOR ONE ATTEMPT, never a previously read
/// capability bit: a non-observing replacement must make the consumer take
/// the conservative CRUD path, so a nil receipt is never mis-classified as
/// structural never-dispatch.
public protocol PhysicalObservationResolving: Sendable {
    /// The ACTUAL underlying observing gateway at this instant, or nil.
    func currentPhysicalObserver() -> (any PhysicalObservingSecretGateway)?
}

extension SecretGatewayRegistry: PhysicalObservationResolving {
    public func currentPhysicalObserver() -> (any PhysicalObservingSecretGateway)? {
        snapshotGateway() as? any PhysicalObservingSecretGateway
    }
}

enum PhysicalObservationResolver {
    /// Resolve the observing seam for THIS attempt. A directly-bound
    /// observing gateway is used as-is; a registry-backed service resolves
    /// its CURRENT underlying gateway (the registry itself conforms to
    /// `PhysicalObservingSecretGateway` as a forwarding shim, so a plain cast
    /// on the registry would wrongly claim observation survives replacement).
    static func observer(for gateway: any SecretGatewayServicing)
        -> (any PhysicalObservingSecretGateway)?
    {
        if let resolving = gateway as? any PhysicalObservationResolving {
            return resolving.currentPhysicalObserver()
        }
        return gateway as? any PhysicalObservingSecretGateway
    }
}

/// Deterministic opaque-reference mapping for the future Swift↔JNI gateway:
/// original service/namespace + `SecretReference.keychainAccount` metadata
/// hashes into a bounded ASCII reference. Unicode display/account identity is
/// NOT dropped — it fully participates in the hash input; only the wire form
/// becomes ASCII-safe. This is a component reference rule, not an authority
/// grant. The original `ProviderSaveRunner` validated-snapshot → secret →
/// commit → readback order stays the save-flow authority for the later binder.
public enum SecretGatewayNaming {
    /// Versioned prefix keeps reference identity unambiguous if the rule
    /// rotates later.
    public static let scheme = "floe-android-secret:v1"
    private static let separator = "\u{1F}"

    public static func opaqueReference(namespace: String, account: String) -> String {
        let input = Data("\(scheme)\(separator)\(namespace)\(separator)\(account)".utf8)
        let digest = SHA256.hash(data: input)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "ref:v1:\(hex)"
    }

    /// Maps the original iOS `SecretReference` into the gateway namespace.
    public static func opaqueReference(for reference: SecretReference) -> String {
        opaqueReference(namespace: "keychainAccount", account: reference.keychainAccount)
    }

    /// Bounded ASCII check used by tests and the future binder.
    public static func isBoundedASCII(_ reference: String) -> Bool {
        reference.count <= 80 && reference.unicodeScalars.allSatisfy {
            $0.isASCII && !$0.properties.isWhitespace
        }
    }
}
