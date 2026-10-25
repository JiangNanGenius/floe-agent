#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeSkills
@testable import FloeApp

@Suite("Bundled MCP service template")
struct MCPServiceTemplateTests {
    @Test("The actual App bundle carries the pinned source and safe verification contract")
    func bundledContract() throws {
        let package = try MCPServiceTemplate.load()
        #expect(package.contract.templateID == "floe.mcp.node-http")
        #expect(package.contract.templateVersion == "1.0.1")
        #expect(package.contract.sdk.version == "1.32.2")
        #expect(!package.contract.runtime.guestExecutionVerified)
        #expect(package.contract.smokeTest.tool == "service_status")
        #expect(package.contract.smokeTest.requiresRealNativeClient)
        #expect(!package.contract.service.readyLogIsAcceptance)
        #expect(!package.contract.smokeTest.automaticallyTestGeneratedSideEffects)
    }

    @Test("Pinned project inputs match the actual archive bytes consumed by creation")
    func immutableProjectInputs() throws {
        let package = try MCPServiceTemplate.load()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-template-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try SignedContentArchive.extract(package.archive, at: root,
            limits: .init(maximumEntries: 32, maximumFileBytes: 262_144, maximumTotalBytes: 1_048_576),
            allowedTopLevel: ["README.md", "contract.json", "node-http"])
        #expect(MCPServiceTemplate.immutableProjectDigests["node-http/src/tools.ts"] == nil)
        #expect(Set(files.keys).subtracting(MCPServiceTemplate.immutableProjectDigests.keys) == ["node-http/src/tools.ts"])
        for (path, expected) in MCPServiceTemplate.immutableProjectDigests {
            let bytes = try #require(files[path])
            #expect(FloeDigest.sha256Hex(bytes) == expected)
        }
    }

    @Test("Modified source bytes are rejected before workspace creation or execution")
    func alteredSource() throws {
        let package = try MCPServiceTemplate.load()
        var bytes = package.archive
        bytes[0] ^= 1
        #expect(throws: (any Error).self) {
            _ = try MCPServiceTemplate.validate(archive: bytes, contract: package.contractBytes)
        }
    }

    @Test("An altered smoke-test contract cannot request generated tool side effects")
    func alteredContract() throws {
        let package = try MCPServiceTemplate.load()
        var object = try #require(JSONSerialization.jsonObject(with: package.contractBytes) as? [String: Any])
        var test = try #require(object["smokeTest"] as? [String: Any])
        test["tool"] = "unreviewed_mutation"
        object["smokeTest"] = test
        let bytes = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) {
            _ = try MCPServiceTemplate.validate(archive: package.archive, contract: bytes)
        }
    }

    @Test("Missing or empty package bytes do not appear ready")
    func emptyPackage() {
        #expect(throws: (any Error).self) {
            _ = try MCPServiceTemplate.validate(archive: Data(), contract: Data())
        }
    }
}
#endif
