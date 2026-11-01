// FloeIOSAutomation — serialized credential-record writes.
//
// Pairing and best-effort expiry refreshes can be re-entered across actor
// suspension points. This small actor serializes every store mutation and
// keeps a revision so a status/action refresh cannot overwrite a newer pairing
// that was saved while the refresh was in flight.

import Foundation

actor IOSBridgeCredentialWriter {
    private var revision: UInt64 = 0

    func currentRevision() -> UInt64 { revision }

    func savePairing(
        _ record: IOSBridgePairingRecord,
        handle: IOSBridgePairingHandle,
        store: any IOSBridgePairingStore
    ) async throws {
        try await store.save(record, for: handle)
        revision &+= 1
    }

    func restorePairing(
        _ record: IOSBridgePairingRecord,
        handle: IOSBridgePairingHandle,
        store: any IOSBridgePairingStore
    ) async {
        if (try? await store.save(record, for: handle)) != nil {
            revision &+= 1
        }
    }

    func deletePairing(
        handle: IOSBridgePairingHandle,
        store: any IOSBridgePairingStore
    ) async throws {
        try await store.delete(handle)
        revision &+= 1
    }

    /// Best-effort expiry refresh. Returns false when the revision changed
    /// (another writer saved a newer record) or the store refused the write.
    @discardableResult
    func touch(
        _ record: IOSBridgePairingRecord,
        expectedRevision: UInt64,
        handle: IOSBridgePairingHandle,
        store: any IOSBridgePairingStore
    ) async -> Bool {
        guard revision == expectedRevision else { return false }
        guard (try? await store.save(record, for: handle)) != nil else { return false }
        revision &+= 1
        return true
    }
}
