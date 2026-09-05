import Foundation
import Testing
import Crypto
import FloeCore
import FloeTools
@testable import FloeExecution

@Suite("FloeExecution.CryptoHash")
struct CryptoHashToolTests {

    @Test("descriptor is read-only")
    func descriptorContract() {
        #expect(CryptoHashTool.name == "crypto.hash")
        #expect(!CryptoHashTool.isSideEffecting)
        #expect(CryptoHashTool.toolEffect == .readOnly)
    }

    @Test("registration wires catalog and runner")
    func registration() {
        let registry = ToolRunnerRegistry()
        registerExecutionTools(registry: registry)
        #expect(ToolCatalog.descriptor(named: "crypto.hash") != nil)
        #expect(registry.runner(named: "crypto.hash") != nil)
    }

    @Test("requires exactly one input and a known algorithm")
    func validation() {
        let tool = CryptoHashTool()
        #expect(throws: FloeError.self) { try tool.validate(.init(algorithm: "sha256")) }
        #expect(throws: FloeError.self) { try tool.validate(.init(algorithm: "sha256", text: "a", path: "b.txt")) }
        #expect(throws: FloeError.self) { try tool.validate(.init(algorithm: "crc32", text: "a")) }
        #expect(throws: FloeError.self) { try tool.validate(.init(algorithm: "sha256", path: "../escape")) }
        try! tool.validate(.init(algorithm: "sha256", text: "a"))
        try! tool.validate(.init(algorithm: "md5", path: "file.bin"))
    }

    @Test("text digests match swift-crypto for every algorithm")
    func textDigests() async throws {
        let tool = CryptoHashTool()
        let data = Data("floe".utf8)
        let expected: [String: String] = [
            "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            "sha384": SHA384.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            "sha512": SHA512.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            "sha1": Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            "md5": Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined(),
        ]
        for (algorithm, digest) in expected {
            let output = try await tool.execute(
                .init(algorithm: algorithm, text: "floe"),
                context: ToolContext(runID: UUID(), cancellation: CancellationToken())
            )
            #expect(output.exitStatus == 0)
            #expect(output.summary.contains("digest=\(digest)"))
        }
    }

    @Test("file hashing resolves through the workspace guard")
    func fileDigest() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-hash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data("archive-me".utf8)
        try payload.write(to: root.appendingPathComponent("a.bin"))
        let tool = CryptoHashTool()
        let context = ToolContext(runID: UUID(), workspaceRootURL: root, cancellation: CancellationToken())
        let output = try await tool.execute(.init(algorithm: "sha256", path: "a.bin"), context: context)
        #expect(output.exitStatus == 0)
        let expected = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        #expect(output.summary.contains("digest=\(expected)"))

        let traversal = try await tool.execute(.init(algorithm: "sha256", path: "../outside"), context: context)
        #expect(traversal.exitStatus == 2)
    }
}
