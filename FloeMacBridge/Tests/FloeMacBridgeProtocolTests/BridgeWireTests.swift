import Foundation
import Testing
import CryptoKit
@testable import FloeMacBridgeProtocol

@Suite("Mac bridge request and response authentication")
struct BridgeWireTests {
    @Test("Only an authenticated unsupported wire version is incompatible")
    func versionRequiresAuthenticIdentity() throws {
        let client = Curve25519.Signing.PrivateKey(), server = Curve25519.Signing.PrivateKey()
        var request = BridgeRequestBody(clientKey: client.publicKey.rawRepresentation, method: "ping", payload: [:])
        request.version = BridgeWire.version + 1
        let signedRequest = try BridgeRequest(body: request, key: client)
        do { try signedRequest.verify(); Issue.record("Unsupported wire accepted") }
        catch BridgeFailure.incompatible { }
        request.version = BridgeWire.version
        var body = BridgeResponseBody(id: request.id, serverKey: server.publicKey.rawRepresentation, result: ["appVersion": .string("1.1.3")])
        // Marketing version is ordinary payload data, never compared to wire1.
        let healthy = try BridgeResponse(body: body, key: server)
        #expect(try healthy.verified(for: request, pinnedKey: server.publicKey.rawRepresentation)["appVersion"]?.string == "1.1.3")
        body.version += 1
        let unsupported = try BridgeResponse(body: body, key: server)
        do { _ = try unsupported.verified(for: request, pinnedKey: server.publicKey.rawRepresentation); Issue.record("Unsupported wire accepted") }
        catch BridgeFailure.incompatible { }
        do { _ = try unsupported.verified(for: request, pinnedKey: client.publicKey.rawRepresentation); Issue.record("Wrong pin accepted") }
        catch BridgeFailure.authentication { }
        var tampered = unsupported; tampered.body.version += 1
        do { _ = try tampered.verified(for: request, pinnedKey: server.publicKey.rawRepresentation); Issue.record("Tampered version accepted") }
        catch BridgeFailure.authentication { }
    }
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
    @Test("A link in the frozen root's ancestry cannot redirect a download")
    func ancestorLinkCommitRefused() throws {
        let scratch = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let parent = scratch.appendingPathComponent("parent"), outside = scratch.appendingPathComponent("outside")
        let root = parent.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside.appendingPathComponent("workspace"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = scratch.appendingPathComponent("transfer")
        try Data("artifact".utf8).write(to: source)
        try FileManager.default.moveItem(at: parent, to: scratch.appendingPathComponent("original"))
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outside)
        #expect(throws: (any Error).self) {
            try BridgeSafeFileSystem.commit(staged: source, relativePath: "output.txt", under: root, expectedSHA256: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("workspace/output.txt").path))
    }
    @Test("Workspace commits retain digest conflict and recovery guarantees")
    func workspaceCommitAndRecovery() throws {
        let scratch = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let root = scratch.appendingPathComponent("workspace"), recovery = scratch.appendingPathComponent("recovery")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = scratch.appendingPathComponent("transfer"), initial = Data("original".utf8), updated = Data("updated".utf8)
        try initial.write(to: source)
        try BridgeSafeFileSystem.commit(staged: source, relativePath: "nested/output.txt", under: root, expectedSHA256: nil)
        try updated.write(to: source)
        #expect(throws: (any Error).self) {
            try BridgeSafeFileSystem.commit(staged: source, relativePath: "nested/output.txt", under: root, expectedSHA256: BridgeWire.digest(updated))
        }
        #expect(try Data(contentsOf: root.appendingPathComponent("nested/output.txt")) == initial)
        try BridgeSafeFileSystem.commit(staged: source, relativePath: "nested/output.txt", under: root, expectedSHA256: BridgeWire.digest(initial))
        try BridgeSafeFileSystem.moveToRecovery(relativePath: "nested/output.txt", under: root, expectedSHA256: BridgeWire.digest(updated), recoveryRoot: recovery)
        #expect(try Data(contentsOf: recovery.appendingPathComponent("output.txt")) == updated)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("nested/output.txt").path))
    }
    #endif

}
