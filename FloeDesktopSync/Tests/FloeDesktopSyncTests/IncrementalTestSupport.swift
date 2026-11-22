import Foundation
import XCTest
@testable import FloeDesktopSync

enum IncrementalFixture {
    static func key(_ byte: UInt8 = 0x42) -> SyncProofKey {
        try! SyncProofKey(rawRepresentation: [UInt8](repeating: byte, count: 32))
    }

    static func authenticator(
        peers: [(DeviceID, String, SyncProofKey)]
    ) throws -> HMACIncrementalAuthenticator {
        try HMACIncrementalAuthenticator(
            peerKeys: peers.map {
                try HMACIncrementalAuthenticator.PeerKey(
                    peerDeviceID: $0.0,
                    keyID: $0.1,
                    key: $0.2
                )
            }
        )
    }

    /// Exercises snapshot staging/commit semantics without authentication.
    /// Public authentication paths have independent tests.
    @discardableResult
    static func establishSubscription(
        source: SyncStore,
        receiver: SyncStore,
        sourceID: DeviceID,
        scope: SnapshotScope,
        version: Int64 = 1
    ) async throws -> ChangeCursor {
        let snapshot = try await source.openSnapshot(scope: scope)
        let manifest = try await source.snapshotManifest(
            snapshot.snapshotID,
            subscriptionVersion: version
        )
        _ = try await receiver.beginSnapshotImportForTesting(
            peerDeviceID: sourceID,
            manifest: manifest,
            subscriptionVersion: version
        )
        for pageIndex in 0..<manifest.pageCount {
            let envelope = try await source.snapshotPageEnvelope(
                snapshot.snapshotID,
                manifest: manifest,
                pageIndex: pageIndex
            )
            _ = try await receiver.receiveSnapshotPageForTesting(
                peerDeviceID: sourceID,
                envelope: envelope
            )
        }
        _ = try await receiver.commitSnapshotImportForTesting(
            peerDeviceID: sourceID,
            snapshotID: snapshot.snapshotID
        )
        return snapshot.baseCursor
    }

    static func makeBatch(
        peer: DeviceID,
        receiver: DeviceID,
        scope: SnapshotScope,
        version: Int64 = 1,
        from: ChangeCursor,
        through: ChangeCursor,
        changes: [(Int64, SyncRecord)]
    ) throws -> IncrementalBatch {
        try IncrementalBatch(
            peerDeviceID: peer,
            receiverDeviceID: receiver,
            scope: scope,
            subscriptionVersion: version,
            fromCursor: from,
            throughCursor: through,
            changes: changes.map {
                IncrementalChange(
                    sourceCursor: try! ChangeCursor($0.0),
                    record: $0.1
                )
            }
        )
    }
}

struct IncrementalTestFailure: Error, Equatable {
    let label: String
}
