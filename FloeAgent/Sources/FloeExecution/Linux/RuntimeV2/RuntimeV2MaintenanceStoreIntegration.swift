// FloeExecution — RuntimeV2Store participation in the fixed-domain maintenance
// authority.
//
// The lookup is by the store's ACTUAL layout root on every operation, never
// cached at init. A store constructed later (or a second store instance) still
// sees the process's registered legacy coordinator, so per-actor serialization
// is not mistaken for cross-instance exclusion. Stores on the production
// `arm64-v1` root and the resident ARM64 path have no registration and are
// deliberately unaffected.

import Foundation

extension RuntimeV2Store {
    /// Shared use of the registered legacy domain for one operation. nil means
    /// this store's layout root is not a registered maintenance domain.
    nonisolated func acquireMaintenanceSharedUse(
        owner: String, purpose: String
    ) async throws -> RuntimeV2MaintenanceSharedUse? {
        guard let coordinator = RuntimeV2MaintenanceRegistry.coordinator(forLayoutRoot: layout.root) else {
            return nil
        }
        return try await coordinator.acquireSharedUse(owner: owner, purpose: purpose)
    }

    /// Store-operation wrapper that retains the claim through the complete
    /// body (including all awaits, IO, commit and recovery cleanup) and releases
    /// it only after the body settles.
    nonisolated func withMaintenanceSharedUse<T: Sendable>(
        owner: String, purpose: String, _ body: @Sendable () async throws -> T
    ) async throws -> T {
        let nativeUse = try layout.beginNativeRecoveryUse()
        defer { nativeUse?.release() }
        let claim = try await acquireMaintenanceSharedUse(owner: owner, purpose: purpose)
        do {
            let value = try await body()
            await claim?.release()
            return value
        } catch {
            await claim?.release()
            throw error
        }
    }
}
