// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeGit

/// Root-owned read adapter for the ONE existing Kotlin GitHub credential.
/// There is no Keychain fallback, token cache, metadata row or second vault.
/// A caller's cancellation does not cancel the physical-read owner task.
final class G04GitCredentialLease: GitHubCredentialLeasing, @unchecked Sendable {
    enum Failure: Error, Sendable { case retired, gatewayUnavailable, workRefused, invalidToken, settlementUnknown }
    private let epoch: UInt64
    private let current: @Sendable () -> Bool
    private let observer: @Sendable () -> (any PhysicalObservingSecretGateway)?
    private let owned: any VaultOwnedWorkAttaching
    static let reference = SecretGatewayNaming.opaqueReference(
        namespace: GitHubCredentialStore.service, account: GitHubCredentialStore.account)

    convenience init(epoch: UInt64, installed: G02InstalledComposition) {
        self.init(epoch: epoch, current: {
            G02NativeRootEpoch.readback() == epoch &&
                G02RuntimeComposition.shared.installedComposition === installed
        }, observer: { SecretGatewayRegistry.shared.currentPhysicalObserver() },
           owned: RuntimeOwnedWorkRegistryAttachment.shared)
    }

    /// Injection is internal for deterministic component tests. Production
    /// always uses the accepted installed composition constructor above.
    init(epoch: UInt64, current: @escaping @Sendable () -> Bool,
         observer: @escaping @Sendable () -> (any PhysicalObservingSecretGateway)?,
         owned: any VaultOwnedWorkAttaching) {
        self.epoch = epoch; self.current = current; self.observer = observer; self.owned = owned
    }

    func leasedToken() async throws -> String? {
        try Task.checkCancellation()
        guard epoch > 0, current() else { throw Failure.retired }
        // Freeze the underlying observer for THIS attempt, not the mutable
        // registry's advertised protocol conformance. A replaced registry
        // cannot change the provenance of an already-queued physical read.
        guard let observer = observer() else { throw Failure.gatewayUnavailable }
        Self.pending.reconcile(epoch: epoch)
        let ownerID = "g04-git-secret:\(UUID().uuidString)"
        let receipt: String
        switch owned.attachVaultMaintenance(epoch: epoch, ownerID: ownerID) {
        case .attached(let value): receipt = value
        case .rejected, .invalidIdentity: throw Failure.workRefused
        }
        let scope = Scope(epoch: epoch, ownerID: ownerID, receipt: receipt, owned: owned)
        let capture = Capture()
        let current = current
        // The uncancelled owner task spans the REAL gateway completion and
        // error-path physical settlement. No timeout or UI lifetime detaches
        // this original registry token while its read may still execute.
        let reader = Task.detached { () async throws -> Data? in
            guard current() else { scope.finish(); throw Failure.retired }
            do {
                let bytes = try await observer.readObserved(reference: Self.reference) { capture.set($0) }
                // Existing MC-CAPACITY-2/GWS-7 contract: success resumes only
                // from the valid host complete() channel, including nil for
                // not-found. It is individual physical completion evidence.
                if let observed = capture.get() { _ = observer.resolvePhysical(claim: observed.claim) }
                scope.finish()
                return bytes
            } catch {
                guard let observed = capture.get() else {
                    // Observed publish atomically delivers a receipt or
                    // refuses BEFORE queue/dispatch (same qualified seam).
                    scope.finish()
                    throw error
                }
                let snapshot = await observer.awaitPhysicalSettlement(claim: observed.claim)
                switch snapshot {
                case .settled, .neverDispatched:
                    _ = observer.resolvePhysical(claim: observed.claim)
                    scope.finish()
                    throw error
                case .notRecorded, .queued, .claimedOutstanding:
                    // Uncertainty cannot become a fabricated drain. Retain
                    // the exact real scope for event-driven reconciliation;
                    // local Git remains independent of this remote-only read.
                    Self.pending.retain(scope, observer: observer, physical: observed)
                    throw Failure.settlementUnknown
                }
            }
        }
        var bytes = try await reader.value
        defer { if bytes != nil { bytes!.resetBytes(in: 0..<bytes!.count) } }
        try Task.checkCancellation()
        guard current() else { throw Failure.retired }
        guard let value = bytes else { return nil }
        guard (20...512).contains(value.count), value.allSatisfy({ (33...126).contains($0) }),
              let token = String(data: value, encoding: .utf8) else { throw Failure.invalidToken }
        return token
    }

    static func reconcilePending(epoch: UInt64) { pending.reconcile(epoch: epoch) }

    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var value: PhysicalOperationReceipt?
        func set(_ receipt: PhysicalOperationReceipt) { lock.withLock { value = receipt } }
        func get() -> PhysicalOperationReceipt? { lock.withLock { value } }
    }

    private final class Scope: @unchecked Sendable {
        let epoch: UInt64
        let receipt: String
        private let ownerID: String
        private let owned: any VaultOwnedWorkAttaching
        private let lock = NSLock()
        private var finished = false
        init(epoch: UInt64, ownerID: String, receipt: String, owned: any VaultOwnedWorkAttaching) {
            self.epoch = epoch; self.ownerID = ownerID; self.receipt = receipt; self.owned = owned
        }
        func finish() {
            let shouldFinish = lock.withLock { () -> Bool in
                guard !finished else { return false }
                finished = true
                return true
            }
            if shouldFinish { _ = owned.detachVaultMaintenance(receipt: receipt, epoch: epoch, ownerID: ownerID) }
        }
    }

    /// References only, over the original registry's exact tokens. This is
    /// not another authority/count or a credential store; no bytes are kept.
    private final class Pending: @unchecked Sendable {
        private struct Entry {
            let scope: Scope
            let observer: any PhysicalObservingSecretGateway
            let physical: PhysicalOperationReceipt
        }
        private let lock = NSLock()
        private var entries: [String: Entry] = [:]
        func retain(_ scope: Scope, observer: any PhysicalObservingSecretGateway,
                    physical: PhysicalOperationReceipt) {
            lock.withLock { entries[scope.receipt] = Entry(scope: scope, observer: observer, physical: physical) }
        }
        func reconcile(epoch: UInt64) {
            let candidates = lock.withLock { entries.values.filter { $0.scope.epoch == epoch } }
            for entry in candidates {
                switch entry.observer.physicalSnapshot(claim: entry.physical.claim) {
                case .settled, .neverDispatched:
                    let removed = lock.withLock { entries.removeValue(forKey: entry.scope.receipt) }
                    if let removed {
                        _ = removed.observer.resolvePhysical(claim: removed.physical.claim)
                        removed.scope.finish()
                    }
                case .notRecorded, .queued, .claimedOutstanding: break
                }
            }
        }
    }
    private static let pending = Pending()
}
