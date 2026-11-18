// Isolated controller/session regression. Test-only host dependencies below
// never inspect or contact the user's real Bridge.
import CryptoKit
import Darwin
import Foundation

struct BridgeEndpointInventory: Equatable, Sendable { var listening = false; var pid: Int32? = nil }
enum BridgeEndpointInspector { static func inspect() -> BridgeEndpointInventory { .init() } }
enum ModePreferenceStore { static var defaultRootURL: URL { FileManager.default.temporaryDirectory } }
enum UserBridgeGuard {
    static var realHomeDirectory: URL { FileManager.default.homeDirectoryForCurrentUser }
    static var userBridgeRoot: URL { realHomeDirectory.appendingPathComponent("Library/Application Support/Floe Bridge") }
}

private struct Failure: Error { let message: String }
private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw Failure(message: message) }
}

@main
private enum BridgeConnectionIdentityTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("floe-ipc-identity-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let socketPath = "/tmp/fid-\(UUID().uuidString.prefix(12)).sock"
        let signingKey = Curve25519.Signing.PrivateKey()
        let publicKey = signingKey.publicKey.rawRepresentation
        let status = BridgeControlStatus(state: "ready", pid: getpid(), parentPID: getppid(),
            storageRoot: root.path, workerHome: root.path, controlSocket: socketPath,
            identitySource: "fixture", identityPublicKeyBase64: publicKey.base64EncodedString(),
            identityFingerprintSHA256: BridgeControlCodec.fingerprint(publicKey))
        let server = BridgeControlServer(socketPath: socketPath, token: "fixture") { message, _ in
            if message.kind == .challenge, let encoded = message.nonce,
               let nonce = Data(base64Encoded: encoded),
               let signature = try? signingKey.signature(for: BridgeControlCodec.identityChallenge(nonce)) {
                return BridgeControlMessage(kind: .reply, replyTo: message.id,
                    publicKeyBase64: publicKey.base64EncodedString(), signatureBase64: signature.base64EncodedString())
            }
            return BridgeControlMessage(kind: .reply, replyTo: message.id, status: status)
        }
        try server.start()
        defer { server.stop() }
        let controller = BridgeComponentController(dataRoot: root)
        defer { controller.detachForTermination() }
        func candidate() throws -> BridgeControlClient {
            try BridgeControlClient.connect(socketPath: socketPath, token: "fixture", timeout: 1)
        }
        func verify(_ client: BridgeControlClient) async throws -> (Data, BridgeIdentityPin) {
            let nonce = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            let response = try await client.request(BridgeControlMessage(kind: .challenge, nonce: nonce.base64EncodedString()))
            guard let key = response.publicKeyBase64.flatMap({ Data(base64Encoded: $0) }),
                  let signature = response.signatureBase64.flatMap({ Data(base64Encoded: $0) }) else {
                throw Failure(message: "incomplete challenge")
            }
            let pin = try BridgeIdentityPinStore.verifyChallenge(publicKey: key, signature: signature,
                                                                  nonce: nonce, status: status, at: root)
            return (key, pin)
        }

        // The signature was valid, but a close before callback installation
        // must prevent the controller from publishing a ready session.
        let disconnected = try candidate()
        let priorVerification = try await verify(disconnected)
        disconnected.close()
        try require(!controller.testInstall(disconnected, verified: priorVerification, status: status),
                    "closed verified candidate became ready")
        try require(controller.testConnectionID == nil && controller.testSessionPin == nil,
                    "closed candidate installed state")

        let first = try candidate()
        let second = try candidate()
        let firstVerification = try await verify(first)
        let secondVerification = try await verify(second)
        async let one: Bool = controller.testInstall(first, verified: firstVerification, status: status)
        async let two: Bool = controller.testInstall(second, verified: secondVerification, status: status)
        let outcomes = await [one, two]
        try require(outcomes.filter { $0 }.count == 1, "same-generation candidates both installed")
        let old = outcomes[0] ? first : second
        let next = outcomes[0] ? second : first
        let nextVerification = outcomes[0] ? secondVerification : firstVerification
        try require(controller.testConnectionID == old.identity, "winning connection was not retained")
        old.close()
        controller.testDeliverEvent(BridgeControlEvent(kind: "shutdownRequested"), from: old.identity)
        guard case .ready = controller.state else { throw Failure(message: "closed connection delivered an event") }
        try require(controller.testInstall(next, verified: nextVerification, status: status), "replacement did not install")
        controller.testDeliverEvent(BridgeControlEvent(kind: "shutdownRequested"), from: old.identity)
        controller.testDeliverDisconnect(from: old.identity)
        try require(controller.testConnectionID == next.identity && controller.testSessionPin == publicKey,
                    "stale callback changed the new session")
        guard case .ready = controller.state else { throw Failure(message: "stale event changed ready state") }
        server.stop()
        for _ in 0..<100 {
            if controller.testSessionPin == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(controller.testSessionPin == nil, "current disconnect was not delivered")
        print("PASS: verified-then-disconnected candidate; concurrent same-generation installs; stale event/disconnect; current disconnect")
    }
}
