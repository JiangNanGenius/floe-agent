import Foundation
import XCTest
@testable import FloeDesktopSync

final class SnapshotAuthenticationTests: XCTestCase {
    func testRevocationAndRegrantFenceOldIncrementalProof() async throws {
        let sourceDB = try TestDatabase(), receiverDB = try TestDatabase()
        addTeardownBlock { sourceDB.remove(); receiverDB.remove() }
        let sourceID = try TestIDs.device(251), receiverID = try TestIDs.device(252)
        let task = try TestIDs.task(253), key = IncrementalFixture.key(0x62)
        let source = try sourceDB.makeStore(deviceID: sourceID)
        let receiver = try receiverDB.makeStore(deviceID: receiverID, incrementalAuthenticator:
            IncrementalFixture.authenticator(peers: [(sourceID, "source", key)]))
        let base = try await IncrementalFixture.establishSubscription(source: source, receiver: receiver,
            sourceID: sourceID, scope: .task(task))
        _ = try await receiver.grantScopeAccess(peerDeviceID: sourceID, scope: .task(task))
        _ = try await source.commitLocalRecord(try .test(entityID: TestIDs.entity(254), revision: 1,
                                                          originDeviceID: sourceID, taskID: task))
        let batch = try await source.nextIncrementalBatch(receiverDeviceID: receiverID, scope: .task(task), subscriptionVersion: 1, after: base)
        let signed = try batch.signed(keyID: "source", key: key)
        _ = try await receiver.revokeScopeAccess(peerDeviceID: sourceID, scope: .task(task))
        _ = try await receiver.grantScopeAccess(peerDeviceID: sourceID, scope: .task(task))
        do { _ = try await receiver.applyAuthenticatedIncrementalBatch(signed); XCTFail("Old batch survived regrant") } catch { }
        let current = try await receiver.subscription(peerDeviceID: sourceID, scope: .task(task))
        XCTAssertGreaterThan(try XCTUnwrap(current?.version), 1)
        XCTAssertEqual(current?.established, false)
        await XCTAssertEqualAsync({ try await receiver.recordCount() }, 0)
        await source.close()
        await receiver.close()
    }

    func testResetFencesAuthenticatedStagingAndOldProof() async throws {
        let sourceDB = try TestDatabase(), receiverDB = try TestDatabase()
        addTeardownBlock { sourceDB.remove(); receiverDB.remove() }
        let sourceID = try TestIDs.device(241), receiverID = try TestIDs.device(242)
        let task = try TestIDs.task(243), key = IncrementalFixture.key(0x61)
        let source = try sourceDB.makeStore(deviceID: sourceID)
        let receiver = try receiverDB.makeStore(deviceID: receiverID)
        _ = try await source.commitLocalRecord(try .test(entityID: TestIDs.entity(244), revision: 1,
                                                          originDeviceID: sourceID, taskID: task))
        let snapshot = try await source.openSnapshot(scope: .task(task))
        let manifest = try await source.snapshotManifest(snapshot.snapshotID)
        let signed = try manifest.signedForSnapshot(receiverDeviceID: receiverID, keyID: "source", key: key)
        _ = try await receiver.grantScopeAccess(peerDeviceID: sourceID, scope: .task(task))
        await XCTAssertThrowsSyncError(.snapshotImportUnverified) {
            try await receiver.beginAuthenticatedSnapshotImport(signed)
        }
        await receiver.installSnapshotAuthenticator(try HMACSnapshotAuthenticator(peerKeys: [
            .init(peerDeviceID: sourceID, keyID: "source", key: key)
        ]))
        _ = try await receiver.beginAuthenticatedSnapshotImport(signed)
        let page = try await source.snapshotPageEnvelope(snapshot.snapshotID, manifest: manifest, pageIndex: 0)
        _ = try await receiver.resetSubscription(peerDeviceID: sourceID, scope: .task(task), version: 2)
        do { _ = try await receiver.receiveAuthenticatedSnapshotPage(signed, envelope: page); XCTFail("Old page crossed reset") } catch { }
        do { _ = try await receiver.commitAuthenticatedSnapshotImport(signed); XCTFail("Old commit crossed reset") } catch { }
        do { _ = try await receiver.beginAuthenticatedSnapshotImport(signed); XCTFail("Old manifest crossed reset") } catch { }
        await XCTAssertEqualAsync({ try await receiver.recordCount() }, 0)
        let current = try await receiver.subscription(peerDeviceID: sourceID, scope: .task(task))
        XCTAssertEqual(current?.version, 2)
        XCTAssertEqual(current?.established, false)
        await source.close()
        await receiver.close()
    }

    func testEquivalentKeysCannotBeBoundToDifferentPeersAcrossProtocols() async throws {
        let sourceDB = try TestDatabase(), receiverDB = try TestDatabase()
        addTeardownBlock { sourceDB.remove(); receiverDB.remove() }
        let sourceID = try TestIDs.device(231), otherID = try TestIDs.device(232)
        let receiverID = try TestIDs.device(233), task = try TestIDs.task(234)
        let shared = IncrementalFixture.key(0x55)
        let source = try sourceDB.makeStore(deviceID: sourceID)
        let receiver = try receiverDB.makeStore(deviceID: receiverID, incrementalAuthenticator:
            IncrementalFixture.authenticator(peers: [(otherID, "incremental-other", shared)]))
        await receiver.installSnapshotAuthenticator(try HMACSnapshotAuthenticator(peerKeys: [
            .init(peerDeviceID: sourceID, keyID: "snapshot-source", key: shared)
        ]))
        _ = try await receiver.grantScopeAccess(peerDeviceID: sourceID, scope: .task(task))
        let snapshot = try await source.openSnapshot(scope: .task(task))
        let manifest = try await source.snapshotManifest(snapshot.snapshotID)
        let signed = try manifest.signedForSnapshot(receiverDeviceID: receiverID, keyID: "snapshot-source", key: shared)
        do { _ = try await receiver.beginAuthenticatedSnapshotImport(signed); XCTFail("Cross-protocol shared key was accepted") } catch { }
        let subscription = try await receiver.subscription(peerDeviceID: sourceID, scope: .task(task))
        XCTAssertNil(subscription)
        await source.close()
        await receiver.close()
    }

    func testAuthenticatedSnapshotRequiresGrantAndAuthenticatesEachStage() async throws {
        let sourceDB = try TestDatabase(), receiverDB = try TestDatabase()
        addTeardownBlock { sourceDB.remove(); receiverDB.remove() }
        let sourceID = try TestIDs.device(201), receiverID = try TestIDs.device(202)
        let otherID = try TestIDs.device(203), task = try TestIDs.task(204)
        let key = IncrementalFixture.key(0x11)
        let source = try sourceDB.makeStore(deviceID: sourceID)
        let receiver = try receiverDB.makeStore(deviceID: receiverID)
        let auth = try HMACSnapshotAuthenticator(peerKeys: [
            .init(peerDeviceID: sourceID, keyID: "source", key: key)
        ])
        await receiver.installSnapshotAuthenticator(auth)
        _ = try await source.commitLocalRecord(try .test(entityID: TestIDs.entity(205), revision: 1,
                                                          originDeviceID: sourceID, taskID: task))
        let snapshot = try await source.openSnapshot(scope: .task(task))
        let manifest = try await source.snapshotManifest(snapshot.snapshotID)
        let signed = try manifest.signedForSnapshot(receiverDeviceID: receiverID, keyID: "source", key: key)
        let wrongDestination = try manifest.signedForSnapshot(receiverDeviceID: otherID, keyID: "source", key: key)
        do {
            _ = try await receiver.beginAuthenticatedSnapshotImport(signed)
            XCTFail("A valid proof without local scope authorization must not start")
        } catch { }
        _ = try await receiver.grantScopeAccess(peerDeviceID: sourceID, scope: .task(task))
        do {
            _ = try await receiver.beginAuthenticatedSnapshotImport(wrongDestination)
            XCTFail("A proof addressed to another receiver must not start")
        } catch { }
        _ = try await receiver.beginAuthenticatedSnapshotImport(signed)
        let page = try await source.snapshotPageEnvelope(snapshot.snapshotID, manifest: manifest, pageIndex: 0)
        do {
            _ = try await receiver.receiveAuthenticatedSnapshotPage(wrongDestination, envelope: page)
            XCTFail("A page must not be accepted under a different receiver proof")
        } catch { }
        _ = try await receiver.receiveAuthenticatedSnapshotPage(signed, envelope: page)
        _ = try await receiver.revokeScopeAccess(peerDeviceID: sourceID, scope: .task(task))
        do {
            _ = try await receiver.receiveAuthenticatedSnapshotPage(signed, envelope: page)
            XCTFail("Revocation must fence page retransmission")
        } catch { }
        do {
            _ = try await receiver.commitAuthenticatedSnapshotImport(signed)
            XCTFail("Revoked scope must not commit staged data")
        } catch { }
        await XCTAssertEqualAsync({ try await receiver.recordCount() }, 0)
        _ = try await receiver.grantScopeAccess(peerDeviceID: sourceID, scope: .task(task))
        do {
            _ = try await receiver.beginAuthenticatedSnapshotImport(signed)
            XCTFail("The old authorization generation must not return after regrant")
        } catch { }
        let subscription = try await receiver.subscription(peerDeviceID: sourceID, scope: .task(task))
        let nextVersion = try XCTUnwrap(subscription?.version)
        XCTAssertGreaterThan(nextVersion, 1)
        XCTAssertEqual(subscription?.established, false)
        let newSnapshot = try await source.openSnapshot(scope: .task(task))
        let newManifest = try await source.snapshotManifest(newSnapshot.snapshotID, subscriptionVersion: nextVersion)
        let newSigned = try newManifest.signedForSnapshot(receiverDeviceID: receiverID, keyID: "source", key: key)
        _ = try await receiver.beginAuthenticatedSnapshotImport(newSigned)
        let newPage = try await source.snapshotPageEnvelope(newSnapshot.snapshotID, manifest: newManifest, pageIndex: 0)
        _ = try await receiver.receiveAuthenticatedSnapshotPage(newSigned, envelope: newPage)
        _ = try await receiver.receiveAuthenticatedSnapshotPage(newSigned, envelope: newPage)
        let committed = try await receiver.commitAuthenticatedSnapshotImport(newSigned)
        XCTAssertFalse(committed.isDuplicate)
        let duplicate = try await receiver.commitAuthenticatedSnapshotImport(newSigned)
        XCTAssertTrue(duplicate.isDuplicate)
        await XCTAssertEqualAsync({ try await receiver.recordCount() }, 1)
        await source.close()
        await receiver.close()
        let reopened = try receiverDB.makeStore(deviceID: receiverID)
        await reopened.installSnapshotAuthenticator(auth)
        let replayAfterRestart = try await reopened.commitAuthenticatedSnapshotImport(newSigned)
        XCTAssertTrue(replayAfterRestart.isDuplicate)
        await reopened.close()
    }

    func testCrossPeerForgedProofCannotAdvanceEmptySnapshot() async throws {
        let sourceDB = try TestDatabase(), receiverDB = try TestDatabase()
        addTeardownBlock { sourceDB.remove(); receiverDB.remove() }
        let sourceID = try TestIDs.device(221), attackerID = try TestIDs.device(222)
        let receiverID = try TestIDs.device(223), task = try TestIDs.task(224)
        let sourceKey = IncrementalFixture.key(0x31), attackerKey = IncrementalFixture.key(0x32)
        let source = try sourceDB.makeStore(deviceID: sourceID)
        let receiver = try receiverDB.makeStore(deviceID: receiverID)
        await receiver.installSnapshotAuthenticator(try HMACSnapshotAuthenticator(peerKeys: [
            .init(peerDeviceID: sourceID, keyID: "source", key: sourceKey),
            .init(peerDeviceID: attackerID, keyID: "attacker", key: attackerKey)
        ]))
        _ = try await receiver.grantScopeAccess(peerDeviceID: sourceID, scope: .task(task))
        let snapshot = try await source.openSnapshot(scope: .task(task))
        let manifest = try await source.snapshotManifest(snapshot.snapshotID)
        let forged = try manifest.signedForSnapshot(receiverDeviceID: receiverID, keyID: "attacker", key: attackerKey)
        do { _ = try await receiver.beginAuthenticatedSnapshotImport(forged); XCTFail("Another peer forged the origin") } catch { }
        let subscription = try await receiver.subscription(peerDeviceID: sourceID, scope: .task(task))
        XCTAssertNil(subscription)
        await source.close()
        await receiver.close()
    }

    func testOldEntryPointsRejectEvenSelfConsistentEmptyManifest() async throws {
        let sourceDB = try TestDatabase(), receiverDB = try TestDatabase()
        addTeardownBlock { sourceDB.remove(); receiverDB.remove() }
        let sourceID = try TestIDs.device(211), receiverID = try TestIDs.device(212)
        let task = try TestIDs.task(213)
        let source = try sourceDB.makeStore(deviceID: sourceID)
        let receiver = try receiverDB.makeStore(deviceID: receiverID)
        let snapshot = try await source.openSnapshot(scope: .task(task))
        let manifest = try await source.snapshotManifest(snapshot.snapshotID)
        await XCTAssertThrowsSyncError(.snapshotImportUnverified) {
            try await receiver.beginSnapshotImport(peerDeviceID: sourceID, manifest: manifest, subscriptionVersion: 1)
        }
        await XCTAssertThrowsSyncError(.snapshotImportUnverified) {
            try await receiver.commitSnapshotImport(peerDeviceID: sourceID, snapshotID: snapshot.snapshotID)
        }
        let subscription = try await receiver.subscription(peerDeviceID: sourceID, scope: .task(task))
        XCTAssertNil(subscription)
        await source.close()
        await receiver.close()
    }
}
