#if os(macOS)
import Foundation
import Testing
import CryptoKit
import FloeMacBridgeProtocol
@testable import FloeMacBridgeApp

@MainActor
@Suite("Bridge pairing cancellation and retry", .serialized)
struct BridgePairingLifecycleTests {
    @Test("Cancellation releases consent and an old native approval cannot approve the retry")
    func cancellationFencesApproval() async throws {
        let base = ProcessInfo.processInfo.environment["FLOE_BRIDGE_TEST_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let root = base.appendingPathComponent("bridge-pairing-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = BridgeUpdateActivity()
        let server = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x51, count: 32))
        let client = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x52, count: 32))
        let service = try BridgeService(paths: BridgePaths(home: root), updateActivity: gate, signingKey: server)
        let clientID = BridgeWire.digest(client.publicKey.rawRepresentation)
        func call(_ method: String, _ nonce: String) async throws -> [String: BridgeValue] {
            let request = try BridgeRequest(body: BridgeRequestBody(clientKey: client.publicKey.rawRepresentation,
                method: method, payload: ["name": .string("Fixture"), "nonce": .string(nonce)]), key: client)
            let response = try await service.respondForDelivery(request)
            defer { service.finishDelivery(response.lease) }
            return try BridgeWire.decode(BridgeResponse.self, from: response.data)
                .verified(for: request.body, pinnedKey: server.publicKey.rawRepresentation)
        }
        func code(_ nonce: String) -> String {
            BridgeWire.pairingVerification(clientKey: client.publicKey.rawRepresentation,
                serverKey: server.publicKey.rawRepresentation, nonce: nonce)
        }
        let first = String(repeating: "a", count: 64), second = String(repeating: "b", count: 64)
        #expect(try await call("pair", first)["paired"] == .bool(false))
        #expect(gate.activityCount == 1)
        #expect(try await call("pairCancel", first)["cancelled"] == .bool(true))
        #expect(gate.activityCount == 0)
        #expect(try await call("pair", second)["paired"] == .bool(false))
        try await service.approve(clientID, verification: code(first), allow: true)
        #expect(try await call("pairStatus", second)["paired"] == .bool(false))
        #expect(await service.pairedClients().isEmpty)
        try await service.approve(clientID, verification: code(second), allow: true)
        #expect(try await call("pairStatus", second)["paired"] == .bool(true))
        #expect(gate.activityCount == 0)
    }

    @Test("Declining one attempt does not permanently reject the same client")
    func declinedAttemptCanRetry() async throws {
        let base = ProcessInfo.processInfo.environment["FLOE_BRIDGE_TEST_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let root = base.appendingPathComponent("bridge-pairing-decline-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = BridgeUpdateActivity()
        let server = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x61, count: 32))
        let client = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x62, count: 32))
        let service = try BridgeService(paths: BridgePaths(home: root), updateActivity: gate, signingKey: server)
        let first = String(repeating: "a", count: 64), second = String(repeating: "b", count: 64)
        func call(_ nonce: String) async throws -> [String: BridgeValue] {
            let request = try BridgeRequest(body: BridgeRequestBody(clientKey: client.publicKey.rawRepresentation,
                method: "pair", payload: ["nonce": .string(nonce)]), key: client)
            let response = try await service.respondForDelivery(request)
            defer { service.finishDelivery(response.lease) }
            return try BridgeWire.decode(BridgeResponse.self, from: response.data)
                .verified(for: request.body, pinnedKey: server.publicKey.rawRepresentation)
        }
        #expect(try await call(first)["paired"] == .bool(false))
        let code = BridgeWire.pairingVerification(clientKey: client.publicKey.rawRepresentation,
            serverKey: server.publicKey.rawRepresentation, nonce: first)
        try await service.approve(BridgeWire.digest(client.publicKey.rawRepresentation), verification: code, allow: false)
        do { _ = try await call(first); Issue.record("A declined attempt was accepted") } catch {}
        #expect(try await call(second)["paired"] == .bool(false))
        #expect(gate.activityCount == 1)
    }
}
#endif
