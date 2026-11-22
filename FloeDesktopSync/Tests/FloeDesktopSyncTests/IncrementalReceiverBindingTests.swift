import Foundation
import XCTest
@testable import FloeDesktopSync

final class IncrementalReceiverBindingTests: XCTestCase {
    func testReceiverBindingRejectsReplayAndRelabelEvenWithSameKey() async throws {
        let sourceDB = try TestDatabase(), firstDB = try TestDatabase(), secondDB = try TestDatabase()
        addTeardownBlock { sourceDB.remove(); firstDB.remove(); secondDB.remove() }
        let sourceID = try TestIDs.device(701), firstID = try TestIDs.device(702)
        let secondID = try TestIDs.device(703), task = try TestIDs.task(704)
        let key = IncrementalFixture.key(0x72)
        let auth = try IncrementalFixture.authenticator(peers: [(sourceID, "source", key)])
        let source = try sourceDB.makeStore(deviceID: sourceID)
        let first = try firstDB.makeStore(deviceID: firstID, incrementalAuthenticator: auth)
        let second = try secondDB.makeStore(deviceID: secondID, incrementalAuthenticator: auth)
        let firstBase = try await IncrementalFixture.establishSubscription(source: source, receiver: first,
            sourceID: sourceID, scope: .task(task))
        let secondBase = try await IncrementalFixture.establishSubscription(source: source, receiver: second,
            sourceID: sourceID, scope: .task(task))
        XCTAssertEqual(firstBase, secondBase)
        _ = try await first.grantScopeAccess(peerDeviceID: sourceID, scope: .task(task))
        _ = try await second.grantScopeAccess(peerDeviceID: sourceID, scope: .task(task))
        _ = try await source.commitLocalRecord(try .test(entityID: TestIDs.entity(705), revision: 1,
                                                          originDeviceID: sourceID, taskID: task))
        let signed = try await source.nextIncrementalBatch(receiverDeviceID: firstID,
            scope: .task(task), subscriptionVersion: 1, after: firstBase).signed(keyID: "source", key: key)
        let wire = signed.wireJSON()
        let decoded = try IncrementalBatch(wireJSON: wire)
        XCTAssertEqual(decoded, signed)
        await XCTAssertThrowsSyncError(.incrementalAuthenticationFailed("batch is addressed to a different receiving device")) {
            try await second.applyAuthenticatedIncrementalBatch(decoded)
        }
        var relabeled = try XCTUnwrap(decoded.wireJSONValue().objectValue)
        relabeled["receiverDeviceID"] = .string(secondID.canonical)
        let forged = try IncrementalBatch(wireValue: .object(relabeled))
        XCTAssertNotEqual(forged.authenticationDigest(), signed.authenticationDigest())
        await XCTAssertThrowsSyncError(.incrementalAuthenticationFailed("proof tag does not verify")) {
            try await second.applyAuthenticatedIncrementalBatch(forged)
        }
        await XCTAssertEqualAsync({ try await second.recordCount() }, 0)
        let secondBefore = try await second.subscription(peerDeviceID: sourceID, scope: .task(task))
        XCTAssertEqual(secondBefore?.appliedCursor, secondBase)
        let firstResult = try await first.applyAuthenticatedIncrementalBatch(decoded)
        XCTAssertFalse(firstResult.isDuplicate)
        let secondSigned = try await source.nextIncrementalBatch(receiverDeviceID: secondID,
            scope: .task(task), subscriptionVersion: 1, after: secondBase).signed(keyID: "source", key: key)
        let secondResult = try await second.applyAuthenticatedIncrementalBatch(secondSigned)
        XCTAssertFalse(secondResult.isDuplicate)
        await first.close()
        let reopened = try firstDB.makeStore(deviceID: firstID, incrementalAuthenticator: auth)
        let replay = try await reopened.applyAuthenticatedIncrementalBatch(try IncrementalBatch(wireJSON: wire))
        XCTAssertTrue(replay.isDuplicate)
        XCTAssertEqual(replay.throughCursor, firstResult.throughCursor)
        await XCTAssertEqualAsync({ try await reopened.recordCount() }, 1)
        await reopened.close()
        await second.close()
        await source.close()
    }

    func testLegacyVersionAndMissingReceiverFailClosed() throws {
        let sender = try TestIDs.device(711), receiver = try TestIDs.device(712)
        let batch = try IncrementalBatch(peerDeviceID: sender, receiverDeviceID: receiver,
            scope: .all, subscriptionVersion: 1, fromCursor: .zero, throughCursor: .zero, changes: [])
        var wire = try XCTUnwrap(batch.wireJSONValue().objectValue)
        wire.removeValue(forKey: "receiverDeviceID")
        XCTAssertThrowsError(try IncrementalBatch(wireValue: .object(wire))) { error in
            XCTAssertEqual(error as? SyncStoreError, .incrementalBatchInvalid("batch fields are missing or mistyped"))
        }
        wire["receiverDeviceID"] = .string(receiver.canonical)
        wire["protocolMinor"] = .integer(0)
        XCTAssertThrowsError(try IncrementalBatch(wireValue: .object(wire))) { error in
            XCTAssertEqual(error as? SyncStoreError, .unsupportedProtocolVersion(major: 1, minor: 0))
        }
        XCTAssertThrowsError(try IncrementalBatch(protocolVersion: ProtocolVersion(major: 1, minor: 0),
            peerDeviceID: sender, receiverDeviceID: receiver, scope: .all, subscriptionVersion: 1,
            fromCursor: .zero, throughCursor: .zero, changes: []))
    }
}
