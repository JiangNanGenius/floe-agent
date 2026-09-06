import Foundation
import Testing
import FloeCore
import FloeTools
@testable import FloeExecution

@Suite("FloeExecution.CryptoCipher")
struct CryptoCipherToolTests {

    private final class FakeKeyStore: CryptoCipherKeyStore, @unchecked Sendable {
        var items: [String: Data] = [:]
        func store(account: String, secret: Data) throws { items[account] = secret }
        func read(account: String) throws -> Data {
            guard let value = items[account] else { throw FloeError.notFound(account) }
            return value
        }
        func delete(account: String) throws { items.removeValue(forKey: account) }
    }

    private func makeTool() -> (CryptoCipherTool, FakeKeyStore) {
        let store = FakeKeyStore()
        return (CryptoCipherTool(keychain: store), store)
    }

    @Test("descriptor requires credentials access")
    func descriptorContract() {
        #expect(CryptoCipherTool.name == "crypto.cipher")
        #expect(CryptoCipherTool.isSideEffecting)
        #expect(CryptoCipherTool.riskLabels.contains(.accessesCredentials))
    }

    @Test("validation enforces actions, names and input exclusivity")
    func validation() {
        let (tool, _) = makeTool()
        #expect(throws: FloeError.self) { try tool.validate(.init(action: "burn")) }
        #expect(throws: FloeError.self) { try tool.validate(.init(action: "encrypt", name: "Bad_Name")) }
        #expect(throws: FloeError.self) { try tool.validate(.init(action: "encrypt", name: "k")) }
        #expect(throws: FloeError.self) { try tool.validate(.init(action: "encrypt", name: "k", text: "a", path: "b")) }
        #expect(throws: FloeError.self) { try tool.validate(.init(action: "verify", name: "k", text: "a", signature: "zz")) }
        try! tool.validate(.init(action: "listKeys"))
        try! tool.validate(.init(action: "encrypt", name: "main-key", text: "a"))
    }

    @Test("AES-256-GCM encrypt/decrypt round-trips text and rejects wrong keys")
    func aesRoundTrip() async throws {
        let (tool, _) = makeTool()
        let context = ToolContext(runID: UUID(), cancellation: CancellationToken())
        _ = try await tool.execute(.init(action: "generateKey", name: "main", kind: "aes256"), context: context)
        let encrypted = try await tool.execute(.init(action: "encrypt", name: "main", text: "机密 payload"), context: context)
        #expect(encrypted.exitStatus == 0)
        let base64 = encrypted.summary.replacingOccurrences(of: "status=ok action=encrypt result=", with: "")
        #expect(!base64.contains("机密"))

        let decrypted = try await tool.execute(.init(action: "decrypt", name: "main", text: base64), context: context)
        #expect(decrypted.exitStatus == 0)
        #expect(decrypted.summary.contains("机密 payload"))

        _ = try await tool.execute(.init(action: "generateKey", name: "other", kind: "aes256"), context: context)
        let wrong = try await tool.execute(.init(action: "decrypt", name: "other", text: base64), context: context)
        #expect(wrong.exitStatus == 2)
    }

    @Test("Ed25519 sign/verify accepts the right key and rejects others")
    func ed25519SignVerify() async throws {
        let (tool, _) = makeTool()
        let context = ToolContext(runID: UUID(), cancellation: CancellationToken())
        _ = try await tool.execute(.init(action: "generateKey", name: "sig", kind: "ed25519"), context: context)
        let signed = try await tool.execute(.init(action: "sign", name: "sig", text: "document v1"), context: context)
        let signature = signed.summary.components(separatedBy: "signature=").last ?? ""

        let valid = try await tool.execute(
            .init(action: "verify", name: "sig", text: "document v1", signature: signature),
            context: context
        )
        #expect(valid.summary.contains("valid=true"))
        let tampered = try await tool.execute(
            .init(action: "verify", name: "sig", text: "document v2", signature: signature),
            context: context
        )
        #expect(tampered.summary.contains("valid=false"))
    }

    @Test("generateKey refuses silent rotation and deleteKey removes")
    func keyLifecycle() async throws {
        let (tool, _) = makeTool()
        let context = ToolContext(runID: UUID(), cancellation: CancellationToken())
        _ = try await tool.execute(.init(action: "generateKey", name: "k1"), context: context)
        let duplicate = try await tool.execute(.init(action: "generateKey", name: "k1"), context: context)
        #expect(duplicate.exitStatus == 2)
        _ = try await tool.execute(.init(action: "deleteKey", name: "k1"), context: context)
        let gone = try await tool.execute(.init(action: "encrypt", name: "k1", text: "x"), context: context)
        #expect(gone.exitStatus == 2)
    }

    @Test("cloudWorkspace schemas stay closed and carry only consumed fields")
    func cloudWorkspaceSchemas() throws {
        let tools: [(String, String, [String], [String])] = [
            // (name, schema, mustContain, mustNotContain)
            ("cloudWorkspace.list", CloudWorkspaceListTool.parametersJSON, ["hostID", "path", "port"], ["contentBase64"]),
            ("cloudWorkspace.read", CloudWorkspaceReadTool.parametersJSON, ["hostID", "path", "port"], ["contentBase64"]),
            ("cloudWorkspace.createDirectory", CloudWorkspaceCreateDirectoryTool.parametersJSON, ["hostID", "path", "port"], ["contentBase64"]),
            ("cloudWorkspace.write", CloudWorkspaceWriteTool.parametersJSON, ["contentBase64"], []),
            ("cloudWorkspace.gitStatus", CloudWorkspaceGitStatusTool.parametersJSON, ["workspaceID"], ["message", "name", "path"]),
            ("cloudWorkspace.gitDiff", CloudWorkspaceGitDiffTool.parametersJSON, ["workspaceID", "path"], ["message", "name"]),
            ("cloudWorkspace.gitLog", CloudWorkspaceGitLogTool.parametersJSON, ["workspaceID"], ["message", "name", "path"]),
            ("cloudWorkspace.gitFetch", CloudWorkspaceGitFetchTool.parametersJSON, ["workspaceID"], ["message", "name", "path"]),
            ("cloudWorkspace.gitStage", CloudWorkspaceGitStageTool.parametersJSON, ["workspaceID", "path"], ["message", "name"]),
            ("cloudWorkspace.gitInitialize", CloudWorkspaceGitInitializeTool.parametersJSON, ["workspaceID"], ["message", "name", "path"]),
            ("cloudWorkspace.gitPull", CloudWorkspaceGitPullTool.parametersJSON, ["workspaceID"], ["message", "name", "path"]),
            ("cloudWorkspace.gitPush", CloudWorkspaceGitPushTool.parametersJSON, ["workspaceID"], ["message", "name", "path"]),
            ("cloudWorkspace.gitCommit", CloudWorkspaceGitCommitTool.parametersJSON, ["workspaceID", "message"], ["name", "path"]),
        ]
        for (name, schema, required, banned) in tools {
            let parsed = try? JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any]
            #expect(parsed != nil, Comment(rawValue: "\(name) schema=\(schema)"))
            guard let object = parsed else { continue }
            #expect(object["additionalProperties"] as? Bool == false)
            let properties = try #require(object["properties"] as? [String: Any])
            for field in required { #expect(properties[field] != nil) }
            for field in banned { #expect(properties[field] == nil) }
            _ = name
        }
        // gitCommit's message is required.
        let commit = try #require(try JSONSerialization.jsonObject(with: Data(CloudWorkspaceGitCommitTool.parametersJSON.utf8)) as? [String: Any])
        #expect(commit["required"] as? [String] == ["workspaceID", "message"])
    }
}
