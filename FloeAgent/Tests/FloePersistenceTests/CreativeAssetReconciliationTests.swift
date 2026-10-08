// FloePersistenceTests — crash-safe reference reconciliation contracts.
//
// Covers the boundaries the delta journal alone cannot close:
//   * crash after the DB apply but before the journal checkpoint — the op
//     receipt (same transaction as the count update) makes a replayed op a
//     no-op instead of double-applying its delta;
//   * project commit before the queue checkpoint (journal lost/stale) — the
//     authoritative reachability guard refuses prune/delete for bytes any
//     persisted canvas project still reaches, even at reference_count == 0.
import Foundation
import Testing
import FloeCore
@testable import FloePersistence

@Suite("Creative asset reference reconciliation")
struct CreativeAssetReconciliationTests {
    private func makeStore(
        reachabilityGuard: (@Sendable (UUID) -> CanvasAssetReachability)? = nil
    ) async throws -> (DatabaseManager, CreativeAssetStore) {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        return (database, CreativeAssetStore(
            database: database, reachabilityGuard: reachabilityGuard))
    }

    private func seed(
        _ store: CreativeAssetStore,
        id: UUID,
        referenceCount: Int = 0
    ) async throws {
        try await store.save(CreativeAssetRecord(
            id: id,
            contentHash: "recon-\(id.uuidString)",
            kind: .document,
            displayName: "Drawing",
            mimeType: "image/vnd.dwg",
            localRelativePath: "Materials/\(id.uuidString).dwg",
            byteCount: 64,
            referenceCount: referenceCount))
    }

    @Test("migrated schema records idempotent op receipts")
    func migrationEnablesOpReceipts() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let version = try await database.userVersion()
        #expect(version >= 45)
        let store = CreativeAssetStore(database: database)
        let id = UUID()
        try await seed(store, id: id)
        try await store.applyReferenceOp(opID: "op-a", assetID: id, delta: 2)
        #expect(try await store.asset(id: id)?.referenceCount == 2)
    }

    @Test("crash after DB apply before journal checkpoint: replayed ops never double-apply")
    func replayedOpIsIdempotent() async throws {
        let (_, store) = try await makeStore()
        let id = UUID()
        try await seed(store, id: id)

        // Increment applied, then "crash" before the journal checkpoint:
        // the relaunch replays the same op id. The count must move once.
        try await store.applyReferenceOp(opID: "op-inc", assetID: id, delta: 1)
        try await store.applyReferenceOp(opID: "op-inc", assetID: id, delta: 1)
        #expect(try await store.asset(id: id)?.referenceCount == 1)

        // The dangerous direction: a replayed DECREMENT must never
        // double-apply into an under-count that pruning would trust.
        try await store.applyReferenceOp(opID: "op-dec", assetID: id, delta: -1)
        try await store.applyReferenceOp(opID: "op-dec", assetID: id, delta: -1)
        #expect(try await store.asset(id: id)?.referenceCount == 0)

        // A fresh op with a new id still applies normally.
        try await store.applyReferenceOp(opID: "op-inc-2", assetID: id, delta: 3)
        #expect(try await store.asset(id: id)?.referenceCount == 3)
    }

    @Test("project commit before queue checkpoint: reachable guard refuses prune at count zero")
    func reachabilityGuardBackstopsLostJournal() async throws {
        // The project file committed (fewer refs) but the journal died
        // before the decrement ever applied — or the increment was lost:
        // either way the count says 0 while the canvas still reaches it.
        let id = UUID()
        let (_, store) = try await makeStore(reachabilityGuard: { _ in .reachable })
        try await seed(store, id: id)
        #expect(try await store.asset(id: id)?.referenceCount == 0)

        await #expect(throws: (any Error).self) {
            _ = try await store.requestPermanentDeletion(assetID: id)
        }
        #expect(try await store.asset(id: id) != nil, "guarded asset must survive")

        // Guard reporting unreachable allows deletion.
        let (_, openStore) = try await makeStore(reachabilityGuard: { _ in .notReachable })
        try await seed(openStore, id: id)
        let path = try await openStore.requestPermanentDeletion(assetID: id)
        #expect(path == "Materials/\(id.uuidString).dwg")
        #expect(try await openStore.asset(id: id) == nil)
    }

    @Test("unknown reachability fails closed: unreadable canvas index retains the bytes")
    func unknownReachabilityRetains() async throws {
        let id = UUID()
        let (_, store) = try await makeStore(reachabilityGuard: { _ in .unknown })
        try await seed(store, id: id)
        await #expect(throws: (any Error).self) {
            _ = try await store.requestPermanentDeletion(assetID: id)
        }
        #expect(try await store.asset(id: id) != nil,
                "an unreadable index must never gamble on destructive pruning")
        // In-flight reconciliation bookkeeping also retains (conservative).
        let (_, inFlight) = try await makeStore(reachabilityGuard: { _ in .reachable })
        try await seed(inFlight, id: id)
        await #expect(throws: (any Error).self) {
            _ = try await inFlight.requestPermanentDeletion(assetID: id)
        }
        #expect(try await inFlight.asset(id: id) != nil)
    }
}
