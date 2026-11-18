// Focused host-controller tests against a real authenticated control server.
//
// The fake helper signs its own challenge with an injected fixture key. The
// controller verifies and pins it before claiming. No Keychain, user Bridge,
// fixed listener or helper process is involved.

import CryptoKit
import Darwin
import Foundation
import FloeMacBridgeProtocol
import XCTest

private final class HostControllerServerState: @unchecked Sendable {
    private let lock = NSLock()
    private var challenged: Set<UUID> = []
    private var log: [BridgeControlKind] = []
    private var currentStatus: BridgeControlStatus
    var allowClaim = true

    init(status: BridgeControlStatus) { currentStatus = status }

    var status: BridgeControlStatus { lock.withLock { currentStatus } }
    func setStatus(_ status: BridgeControlStatus) { lock.withLock { currentStatus = status } }

    func record(_ kind: BridgeControlKind, connectionID: UUID) {
        lock.withLock {
            log.append(kind)
            if kind == .challenge { challenged.insert(connectionID) }
        }
    }

    func wasChallenged(_ connectionID: UUID) -> Bool {
        lock.withLock { challenged.contains(connectionID) }
    }

    var kinds: [BridgeControlKind] { lock.withLock { log } }
}

private final class HostControllerFixture {
    let root: URL
    let socketPath: String
    let token = "host-controller-fixture"
    let signingKey: Curve25519.Signing.PrivateKey
    let state: HostControllerServerState
    let server: BridgeControlServer

    init(label: String) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-host-controller-\(label)-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let socketPath = "/tmp/fhc-\(UUID().uuidString.prefix(12)).sock"
        let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x55, count: 32))
        let publicKey = signingKey.publicKey.rawRepresentation
        var status = BridgeControlStatus(
            state: "ready",
            pid: getpid(),
            parentPID: getppid(),
            storageRoot: root.path,
            workerHome: root.path,
            controlSocket: socketPath,
            identitySource: "test-fixture-persistent",
            identityPublicKeyBase64: publicKey.base64EncodedString(),
            identityFingerprintSHA256: BridgeControlCodec.fingerprint(publicKey),
            bundleIdentifier: "org.floeagent.mac.bridgecomponent",
            bundlePath: root.path
        )
        status.pendingConsents = [
            BridgeControlConsent(attemptID: "attempt-1", clientID: "client-1", displayName: "Fixture One",
                                 verification: "verification-1", receivedAt: "2026-11-16T00:00:00Z")
        ]
        status.pairingRevision = 7
        status.consent = status.pendingConsents.first
        let state = HostControllerServerState(status: status)
        let key = signingKey
        self.root = root
        self.socketPath = socketPath
        self.signingKey = signingKey
        self.state = state
        server = BridgeControlServer(socketPath: socketPath, token: token) { message, connectionID in
            state.record(message.kind, connectionID: connectionID)
            switch message.kind {
            case .challenge:
                guard let encoded = message.nonce, let nonce = Data(base64Encoded: encoded),
                      nonce.count == 32,
                      let signature = try? key.signature(for: BridgeControlCodec.identityChallenge(nonce)) else {
                    return BridgeControlMessage(kind: .reply, replyTo: message.id,
                                                error: "fixture challenge invalid")
                }
                return BridgeControlMessage(kind: .reply, replyTo: message.id,
                                            publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString(),
                                            signatureBase64: signature.base64EncodedString())
            case .claim:
                guard state.allowClaim, state.wasChallenged(connectionID) else {
                    return BridgeControlMessage(kind: .reply, replyTo: message.id,
                                                error: "fixture claim refused")
                }
                return BridgeControlMessage(kind: .reply, replyTo: message.id, status: state.status)
            case .status:
                return BridgeControlMessage(kind: .reply, replyTo: message.id, status: state.status)
            default:
                return BridgeControlMessage(kind: .reply, replyTo: message.id, status: state.status)
            }
        }
    }

    func start() throws { try server.start() }
    func stop() {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    func client() throws -> BridgeControlClient {
        try BridgeControlClient.connect(socketPath: socketPath, token: token, timeout: 2)
    }

    func status(revision: UInt64, consents: [BridgeControlConsent]) -> BridgeControlStatus {
        var value = state.status
        value.pairingRevision = revision
        value.pendingConsents = consents
        value.consent = consents.first
        return value
    }
}

@MainActor
final class BridgeHostControllerTests: XCTestCase {
    private func fixture(_ label: String) throws -> HostControllerFixture {
        try HostControllerFixture(label: label)
    }

    func testIdentityChallengeAndClaimPrecedeInstall() async throws {
        let fixture = try fixture("claim")
        defer { fixture.stop() }
        try fixture.start()
        let controller = BridgeComponentController(dataRoot: fixture.root)
        defer { controller.detachForTermination() }
        let client = try fixture.client()
        defer { client.close() }
        let installed = await controller.testClaimAndInstall(client, status: fixture.state.status)
        XCTAssertTrue(installed)
        XCTAssertEqual(controller.testSessionPin, fixture.signingKey.publicKey.rawRepresentation)
        XCTAssertEqual(fixture.state.kinds, [.challenge, .claim])
        XCTAssertEqual(controller.testPendingConsents.count, 1)
        XCTAssertEqual(controller.testPendingConsents.first?.attemptID, "attempt-1")
        XCTAssertEqual(controller.testPairingRevision, 7)
    }

    func testClaimFailureDoesNotPublishASession() async throws {
        let fixture = try fixture("claim-failure")
        defer { fixture.stop() }
        try fixture.start()
        fixture.state.allowClaim = false
        let controller = BridgeComponentController(dataRoot: fixture.root)
        defer { controller.detachForTermination() }
        let client = try fixture.client()
        defer { client.close() }
        let installed = await controller.testClaimAndInstall(client, status: fixture.state.status)
        XCTAssertFalse(installed)
        XCTAssertNil(controller.testSessionPin)
        XCTAssertNil(controller.testConnectionID)
        XCTAssertEqual(fixture.state.kinds, [.challenge, .claim])
    }

    func testOlderConsentRevisionCannotResurrectARequest() async throws {
        let fixture = try fixture("revision")
        defer { fixture.stop() }
        try fixture.start()
        let controller = BridgeComponentController(dataRoot: fixture.root)
        defer { controller.detachForTermination() }
        let first = BridgeControlConsent(attemptID: "attempt-1", clientID: "client-1",
                                         displayName: "First", verification: "v1",
                                         receivedAt: "2026-11-16T00:00:00Z")
        let second = BridgeControlConsent(attemptID: "attempt-2", clientID: "client-2",
                                          displayName: "Second", verification: "v2",
                                          receivedAt: "2026-11-16T00:00:01Z")
        controller.testApplyStatus(fixture.status(revision: 5, consents: [first]))
        XCTAssertEqual(controller.testPendingConsents.map(\.attemptID), ["attempt-1"])
        controller.testApplyStatus(fixture.status(revision: 4, consents: [second]))
        XCTAssertEqual(controller.testPendingConsents.map(\.attemptID), ["attempt-1"])
        XCTAssertEqual(controller.testPairingRevision, 5)
        controller.testApplyStatus(fixture.status(revision: 6, consents: [second]))
        XCTAssertEqual(controller.testPendingConsents.map(\.attemptID), ["attempt-2"])
        XCTAssertEqual(controller.testPairingRevision, 6)
        controller.testApplyStatus(fixture.status(revision: 6, consents: []))
        XCTAssertTrue(controller.testPendingConsents.isEmpty)
        XCTAssertEqual(controller.testPairingRevision, 6)
    }

    func testEventRevisionIsFencedLikeStatus() async throws {
        let fixture = try fixture("event")
        defer { fixture.stop() }
        try fixture.start()
        let controller = BridgeComponentController(dataRoot: fixture.root)
        defer { controller.detachForTermination() }
        let client = try fixture.client()
        defer { client.close() }
        let installed = await controller.testClaimAndInstall(client, status: fixture.state.status)
        XCTAssertTrue(installed)
        let connectionID = try XCTUnwrap(controller.testConnectionID)
        let stale = BridgeControlConsent(attemptID: "stale", clientID: "stale-client",
                                         displayName: "Stale", verification: "stale-v",
                                         receivedAt: "2026-11-16T00:00:00Z")
        controller.testDeliverEvent(
            BridgeControlEvent(kind: "consentListChanged", consents: [stale], pairingRevision: 6),
            from: connectionID
        )
        XCTAssertEqual(controller.testPendingConsents.map(\.attemptID), ["attempt-1"])
        let fresh = BridgeControlConsent(attemptID: "fresh", clientID: "fresh-client",
                                         displayName: "Fresh", verification: "fresh-v",
                                         receivedAt: "2026-11-16T00:00:02Z")
        controller.testDeliverEvent(
            BridgeControlEvent(kind: "consentListChanged", consents: [fresh], pairingRevision: 9),
            from: connectionID
        )
        XCTAssertEqual(controller.testPendingConsents.map(\.attemptID), ["fresh"])
        XCTAssertEqual(controller.testPairingRevision, 9)
    }

    func testOlderHelperStatusDecodesWithoutNewFields() throws {
        var value = BridgeControlStatus(
            state: "ready",
            pid: 123,
            parentPID: 1,
            storageRoot: "fixture",
            workerHome: "fixture",
            controlSocket: "fixture",
            identitySource: "test-fixture-persistent"
        )
        value.consent = BridgeControlConsent(attemptID: "legacy", clientID: "legacy-client",
                                             displayName: "Legacy", verification: "legacy-v",
                                             receivedAt: "2026-11-16T00:00:00Z")
        let encoded = try JSONEncoder().encode(value)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in ["pendingConsents", "pairingRevision", "hostClaimed", "storeLockPath", "storeLockExclusive"] {
            object.removeValue(forKey: key)
        }
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(BridgeControlStatus.self, from: legacy)
        XCTAssertTrue(decoded.pendingConsents.isEmpty)
        XCTAssertEqual(decoded.pairingRevision, 0)
        XCTAssertFalse(decoded.hostClaimed)
        XCTAssertNil(decoded.storeLockPath)
        XCTAssertFalse(decoded.storeLockExclusive)
        XCTAssertEqual(decoded.consent?.clientID, "legacy-client")
    }
}
