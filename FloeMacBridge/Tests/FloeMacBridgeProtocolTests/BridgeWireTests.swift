import Foundation
import Testing
import CryptoKit
@testable import FloeMacBridgeProtocol

@Suite("Mac bridge request and response authentication")
struct BridgeWireTests {
    @Test("Changing command bytes invalidates a signed request")
    func tamperingIsRejected() throws {
        let key = Curve25519.Signing.PrivateKey()
        let body = BridgeRequestBody(clientKey: key.publicKey.rawRepresentation, method: "start", payload: ["command": .string("printf original")])
        var request = try BridgeRequest(body: body, key: key)
        try request.verify()
        request.body.payload["command"] = .string("printf replaced")
        #expect(throws: BridgeFailure.self) { try request.verify() }
    }
    @Test("Expired requests and wrong pinned companion identities fail closed")
    func replayAndPin() throws {
        let client = Curve25519.Signing.PrivateKey(), server = Curve25519.Signing.PrivateKey()
        var body = BridgeRequestBody(clientKey: client.publicKey.rawRepresentation, method: "ping", payload: [:])
        body.issuedAt -= 180_000
        let expired = try BridgeRequest(body: body, key: client)
        #expect(throws: BridgeFailure.self) { try expired.verify() }
        let reply = try BridgeResponse(body: BridgeResponseBody(id: body.id, serverKey: server.publicKey.rawRepresentation), key: server)
        #expect(throws: BridgeFailure.self) { try reply.verified(for: body, pinnedKey: client.publicKey.rawRepresentation) }
    }
    @Test("Response cannot be paired to another request")
    func requestPairing() throws {
        let key = Curve25519.Signing.PrivateKey()
        let first = BridgeRequestBody(clientKey: key.publicKey.rawRepresentation, method: "poll", payload: [:])
        let second = BridgeRequestBody(clientKey: key.publicKey.rawRepresentation, method: "poll", payload: [:])
        let reply = try BridgeResponse(body: BridgeResponseBody(id: first.id, serverKey: key.publicKey.rawRepresentation), key: key)
        #expect(throws: BridgeFailure.self) { try reply.verified(for: second, pinnedKey: key.publicKey.rawRepresentation) }
    }
    @Test("Pairing fingerprint binds both public identities and a fresh nonce")
    func fingerprintBinding() {
        let client = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let server = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let first = BridgeWire.pairingVerification(clientKey: client, serverKey: server, nonce: "first")
        #expect(first == BridgeWire.pairingVerification(clientKey: client, serverKey: server, nonce: "first"))
        #expect(first != BridgeWire.pairingVerification(clientKey: client, serverKey: server, nonce: "second"))
        #expect(first != BridgeWire.pairingVerification(clientKey: server, serverKey: client, nonce: "first"))
    }
    #if canImport(Darwin)
    @Test("A swapped destination parent cannot redirect a committed download")
    func symlinkCommitRefused() throws {
        let scratch = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let root = scratch.appendingPathComponent("root"), outside = scratch.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = scratch.appendingPathComponent("transfer")
        try Data("artifact".utf8).write(to: source)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("swapped"), withDestinationURL: outside)
        #expect(throws: (any Error).self) {
            try BridgeSafeFileSystem.commit(staged: source, relativePath: "swapped/output.txt", under: root, expectedSHA256: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("output.txt").path))
    }
    #endif

}
