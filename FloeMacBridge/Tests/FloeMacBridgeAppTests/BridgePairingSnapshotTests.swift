#if os(macOS)
import CryptoKit
import Foundation
import Testing
import FloeMacBridgeProtocol
@testable import FloeMacBridgeApp

private final class PairingSnapshotLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [BridgeService.PairingSnapshot] = []

    func append(_ snapshot: BridgeService.PairingSnapshot) {
        lock.withLock { values.append(snapshot) }
    }

    var snapshots: [BridgeService.PairingSnapshot] {
        lock.withLock { values }
    }
}

private final class ScriptedPairWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: Int
    private(set) var writes: [Data] = []

    init(failures: Int) { self.failures = failures }

    func write(_ data: Data) throws {
        let fail: Bool = lock.withLock {
            if failures > 0 { failures -= 1; return true }
            writes.append(data)
            return false
        }
        if fail { throw BridgeFailure.remote("fixture write failure") }
    }

    var writeCount: Int { lock.withLock { writes.count } }
}

@MainActor
@Suite("Bridge pairing snapshot and exact decisions", .serialized)
struct BridgePairingSnapshotTests {
    private func temporaryRoot(_ label: String) -> URL {
        let base = ProcessInfo.processInfo.environment["FLOE_BRIDGE_TEST_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("bridge-pairing-\(label)-\(UUID())")
    }

    private func request(_ service: BridgeService, client: Curve25519.Signing.PrivateKey,
                         serverKey: Data, method: String, nonce: String,
                         name: String = "Fixture") async throws -> [String: BridgeValue] {
        let body = BridgeRequestBody(clientKey: client.publicKey.rawRepresentation,
                                     method: method,
                                     payload: ["name": .string(name), "nonce": .string(nonce)])
        let request = try BridgeRequest(body: body, key: client)
        let delivery = try await service.respondForDelivery(request)
        defer { service.finishDelivery(delivery.lease) }
        return try BridgeWire.decode(BridgeResponse.self, from: delivery.data)
            .verified(for: body, pinnedKey: serverKey)
    }

    private func nonce(_ character: Character) -> String {
        String(repeating: String(character), count: 64)
    }

    @Test("four clients remain ordered and a fifth request is refused")
    func orderedBoundedSnapshot() async throws {
        let root = temporaryRoot("ordered")
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = BridgeUpdateActivity()
        let server = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x71, count: 32))
        let service = try BridgeService(paths: BridgePaths(home: root), updateActivity: gate, signingKey: server)
        let log = PairingSnapshotLog()
        _ = await service.setPairingObserver { log.append($0) }
        var clients: [Curve25519.Signing.PrivateKey] = []
        for index in 0..<4 {
            let client = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: UInt8(0x20 + index), count: 32))
            clients.append(client)
            let nonceValue = nonce(Character(UnicodeScalar(0x61 + index)!))
            let result = try await request(service, client: client, serverKey: server.publicKey.rawRepresentation,
                                           method: "pair", nonce: nonceValue)
            #expect(result["paired"] == .bool(false))
        }
        var snapshot = await service.pairingSnapshot()
        #expect(snapshot.pending.count == 4)
        #expect(gate.activityCount == 4)
        #expect(Set(snapshot.pending.map(\.attemptID)).count == 4)
        #expect(Set(snapshot.pending.map(\.sequence)).count == 4)
        #expect(snapshot.pending.map(\.sequence) == snapshot.pending.map(\.sequence).sorted())
        for (index, attempt) in snapshot.pending.enumerated() {
            #expect(attempt.clientID == BridgeWire.digest(clients[index].publicKey.rawRepresentation))
            #expect(attempt.displayName == "Fixture")
            #expect(attempt.verification == BridgeWire.pairingVerification(
                clientKey: clients[index].publicKey.rawRepresentation,
                serverKey: server.publicKey.rawRepresentation,
                nonce: nonce(Character(UnicodeScalar(0x61 + index)!))
            ))
        }
        let fifth = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x25, count: 32))
        do {
            _ = try await request(service, client: fifth, serverKey: server.publicKey.rawRepresentation,
                                  method: "pair", nonce: nonce("z"))
            Issue.record("A fifth pending request was admitted")
        } catch { }
        snapshot = await service.pairingSnapshot()
        #expect(snapshot.pending.count == 4)
        #expect(gate.activityCount == 4)
        let snapshots = log.snapshots
        #expect(snapshots.count >= 4)
        #expect(zip(snapshots, snapshots.dropFirst()).allSatisfy { $0.revision < $1.revision })
        #expect(snapshots.last?.revision == snapshot.revision)
    }

    @Test("cancel removes the exact request and an old approval cannot approve the retry")
    func cancelThenStaleApproval() async throws {
        let root = temporaryRoot("cancel")
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = BridgeUpdateActivity()
        let server = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x72, count: 32))
        let client = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x32, count: 32))
        let service = try BridgeService(paths: BridgePaths(home: root), updateActivity: gate, signingKey: server)
        let firstNonce = nonce("a"), secondNonce = nonce("b")
        #expect(try await request(service, client: client, serverKey: server.publicKey.rawRepresentation,
                                  method: "pair", nonce: firstNonce)["paired"] == .bool(false))
        var snapshot = await service.pairingSnapshot()
        let firstAttempt = try #require(snapshot.pending.first)
        #expect(gate.activityCount == 1)
        _ = try await request(service, client: client, serverKey: server.publicKey.rawRepresentation,
                              method: "pairCancel", nonce: firstNonce)
        snapshot = await service.pairingSnapshot()
        #expect(snapshot.pending.isEmpty)
        #expect(gate.activityCount == 0)
        #expect(try await service.decide(attemptID: firstAttempt.attemptID,
                                         verification: firstAttempt.verification, allow: true) == false)
        #expect(await service.pairedClients().isEmpty)
        #expect(try await request(service, client: client, serverKey: server.publicKey.rawRepresentation,
                                  method: "pair", nonce: secondNonce)["paired"] == .bool(false))
        snapshot = await service.pairingSnapshot()
        let secondAttempt = try #require(snapshot.pending.first)
        #expect(secondAttempt.attemptID != firstAttempt.attemptID)
        #expect(try await service.decide(attemptID: firstAttempt.attemptID,
                                         verification: firstAttempt.verification, allow: true) == false)
        #expect(await service.pairedClients().isEmpty)
        #expect(try await service.decide(attemptID: secondAttempt.attemptID,
                                         verification: secondAttempt.verification, allow: true) == true)
        #expect(await service.pairedClients().count == 1)
        #expect(gate.activityCount == 0)
        #expect(try await request(service, client: client, serverKey: server.publicKey.rawRepresentation,
                                  method: "pairStatus", nonce: secondNonce)["paired"] == .bool(true))
    }

    @Test("a persistence failure keeps the exact request and consent lease")
    func writeFailurePreservesPending() async throws {
        let root = temporaryRoot("write-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = BridgeUpdateActivity()
        let server = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x73, count: 32))
        let client = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x33, count: 32))
        let writer = ScriptedPairWriter(failures: 1)
        let service = try BridgeService(paths: BridgePaths(home: root), updateActivity: gate,
                                        signingKey: server, pairStoreWriter: { try writer.write($0) })
        #expect(try await request(service, client: client, serverKey: server.publicKey.rawRepresentation,
                                  method: "pair", nonce: nonce("c"))["paired"] == .bool(false))
        var snapshot = await service.pairingSnapshot()
        let attempt = try #require(snapshot.pending.first)
        do {
            _ = try await service.decide(attemptID: attempt.attemptID, verification: attempt.verification, allow: true)
            Issue.record("Failed pairing write was reported as success")
        } catch { }
        snapshot = await service.pairingSnapshot()
        #expect(snapshot.pending.count == 1)
        #expect(snapshot.pending.first?.attemptID == attempt.attemptID)
        #expect(gate.activityCount == 1)
        #expect(await service.pairedClients().isEmpty)
        #expect(writer.writeCount == 0)
        #expect(try await service.decide(attemptID: attempt.attemptID, verification: attempt.verification, allow: true) == true)
        #expect(gate.activityCount == 0)
        #expect(await service.pairedClients().count == 1)
        #expect(writer.writeCount == 1)
    }

    @Test("declining one client does not remove or approve another")
    func declineIsExact() async throws {
        let root = temporaryRoot("decline")
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = BridgeUpdateActivity()
        let server = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x74, count: 32))
        let first = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x34, count: 32))
        let second = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x35, count: 32))
        let service = try BridgeService(paths: BridgePaths(home: root), updateActivity: gate, signingKey: server)
        for (client, nonceValue) in [(first, nonce("d")), (second, nonce("e"))] {
            #expect(try await request(service, client: client, serverKey: server.publicKey.rawRepresentation,
                                      method: "pair", nonce: nonceValue)["paired"] == .bool(false))
        }
        let snapshot = await service.pairingSnapshot()
        #expect(snapshot.pending.count == 2)
        let firstAttempt = try #require(snapshot.pending.first {
            $0.clientID == BridgeWire.digest(first.publicKey.rawRepresentation)
        })
        #expect(try await service.decide(attemptID: firstAttempt.attemptID,
                                         verification: firstAttempt.verification, allow: false) == true)
        let after = await service.pairingSnapshot()
        #expect(after.pending.count == 1)
        #expect(after.pending.first?.clientID == BridgeWire.digest(second.publicKey.rawRepresentation))
        #expect(gate.activityCount == 1)
        #expect(await service.pairedClients().isEmpty)
        do {
            _ = try await request(service, client: first, serverKey: server.publicKey.rawRepresentation,
                                  method: "pairStatus", nonce: nonce("d"))
            Issue.record("Declined attempt was accepted")
        } catch { }
    }

    @Test("revoke removes a current pending request and its consent lease")
    func revokePending() async throws {
        let root = temporaryRoot("revoke")
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = BridgeUpdateActivity()
        let server = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x75, count: 32))
        let client = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x36, count: 32))
        let service = try BridgeService(paths: BridgePaths(home: root), updateActivity: gate, signingKey: server)
        #expect(try await request(service, client: client, serverKey: server.publicKey.rawRepresentation,
                                  method: "pair", nonce: nonce("f"))["paired"] == .bool(false))
        #expect(gate.activityCount == 1)
        try await service.revoke(BridgeWire.digest(client.publicKey.rawRepresentation))
        #expect(await service.pairingSnapshot().pending.isEmpty)
        #expect(gate.activityCount == 0)
    }

    @Test("a repeated nonce and code cannot revive an old standalone decision")
    func sameNonceRequiresFreshAttempt() async throws {
        let root = temporaryRoot("same-nonce")
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = BridgeUpdateActivity()
        let server = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x75, count: 32))
        let client = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x35, count: 32))
        let service = try BridgeService(paths: BridgePaths(home: root), updateActivity: gate, signingKey: server)
        let repeated = nonce("s")
        #expect(try await request(service, client: client, serverKey: server.publicKey.rawRepresentation,
                                  method: "pair", nonce: repeated)["paired"] == .bool(false))
        let old = try #require(await service.pairingSnapshot().pending.first)
        _ = try await request(service, client: client, serverKey: server.publicKey.rawRepresentation,
                              method: "pairCancel", nonce: repeated)
        #expect(try await request(service, client: client, serverKey: server.publicKey.rawRepresentation,
                                  method: "pair", nonce: repeated)["paired"] == .bool(false))
        let current = try #require(await service.pairingSnapshot().pending.first)
        #expect(current.attemptID != old.attemptID)
        #expect(current.verification == old.verification)
        #expect(try await service.approve(old.clientID, attemptID: "", verification: old.verification, allow: true) == false)
        #expect(try await service.approve(old.clientID, attemptID: old.attemptID, verification: old.verification, allow: true) == false)
        #expect(await service.pairedClients().isEmpty)
        #expect(await service.pairingSnapshot().pending.first?.attemptID == current.attemptID)
        #expect(try await service.approve(current.clientID, attemptID: current.attemptID, verification: current.verification, allow: true))
        #expect(await service.pairedClients().count == 1)
        #expect(gate.activityCount == 0)
    }

    @Test("the standalone consent callback still receives the exact attempt")
    func standaloneConsentCompatibility() async throws {
        let root = temporaryRoot("standalone")
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = BridgeUpdateActivity()
        let server = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x76, count: 32))
        let client = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x37, count: 32))
        let service = try BridgeService(paths: BridgePaths(home: root), updateActivity: gate, signingKey: server)
        final class CallbackValue: @unchecked Sendable { var text: (String, String, String, String)? }
        let value = CallbackValue()
        await service.setConsent { id, name, verification, attemptID in
            value.text = (id, name, verification, attemptID)
        }
        #expect(try await request(service, client: client, serverKey: server.publicKey.rawRepresentation,
                                  method: "pair", nonce: nonce("g"), name: "Standalone Fixture")["paired"] == .bool(false))
        let consentDeadline = Date().addingTimeInterval(2)
        while Date() < consentDeadline, value.text == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let text = try #require(value.text)
        #expect(text.0 == BridgeWire.digest(client.publicKey.rawRepresentation))
        #expect(text.1 == "Standalone Fixture")
        #expect(try await service.approve(text.0, attemptID: text.3, verification: text.2, allow: true))
        #expect(await service.pairedClients().count == 1)
        #expect(gate.activityCount == 0)
    }
}
#endif
