#if canImport(UIKit)
import Foundation
import CryptoKit
import FloeCore

/// A reviewed source project bundled with the App, not a Skill installation
/// or a runtime/permission grant. The creation flow consumes these bytes in
/// its resolved workspace and uses the existing jobs/service/MCP lifecycle.
enum MCPServiceTemplate {
    static let archiveName = "floe-mcp-node-http-1.0.1-source"
    private static let archiveDigest = "a92e47639640d302021d05fdc5b17b6e4643065539164f97790eebdbaea50512"
    private static let contractDigest = "76eea91e0d4b368d27783fdade209633df531c501a4f9ebf0d160e154a744034"

    /// Generation may extend source, never weaken the locked build/test contract.
    static let immutableProjectDigests: [String: String] = [
        "README.md": "d03b5d6085a4e108c53fc185c4c37cbac67b9dfb535c74a75f6a49792ffcd623",
        "contract.json": "76eea91e0d4b368d27783fdade209633df531c501a4f9ebf0d160e154a744034",
        "node-http/.gitignore": "b63ce42e2babc54a13558cf679f775191d18649bca9dc04072126ef50987e1a4",
        "node-http/package-lock.json": "e4565f56ecbff62f74e0a76046c022cc4738a5beb86f86a3d1815acc57077e75",
        "node-http/package.json": "fdd3fbde3ac608ba607df736bb272637b6b6701c00a1775570669089f698a975",
        "node-http/src/server.ts": "e1c67121be4db6f0fa759dda42b130ec09a307305167675ea75d69e7a52e1385",
        "node-http/tests/discovery.mjs": "3042e48d110db9d5b00781b3869266cd6b830710f1107ed24e3cf43bdd408d4b",
        "node-http/tests/http.test.mjs": "36583f7aa2297b4a52b7f38cfe914759c05617bfc0fc12398c0f6baf64306d71",
        "node-http/tsconfig.json": "aaa03b5ee9fbadcd0e73745e4ac6d01c2a3d153a1115bc9416eb8cda96f9b26c",
    ]

    struct Contract: Decodable, Sendable {
        struct Runtime: Decodable, Sendable {
            let os: String
            let node: String
            let guestExecutionVerified: Bool
            let architecture: String
        }
        struct SDK: Decodable, Sendable {
            let package: String
            let version: String
            let sourceCommit: String
            let license: String
        }
        struct Service: Decodable, Sendable {
            let owner: String
            let transport: String
            let sessionMode: String
            let mcpPath: String
            let healthPath: String
            let defaultHost: String
            let portSource: String
            let endpointSource: String
            let readyLogIsAcceptance: Bool
        }
        struct SmokeTest: Decodable, Sendable {
            let methods: [String]
            let tool: String
            let arguments: [String: String]
            let expectedStructuredContent: [String: String]
            let requiresRealNativeClient: Bool
            let automaticallyTestGeneratedSideEffects: Bool
        }
        let schemaVersion: Int
        let templateID: String
        let templateVersion: String
        let storefrontSkill: Bool
        let projectRoot: String
        let language: String
        let runtime: Runtime
        let sdk: SDK
        let commands: [String: [String]]
        let service: Service
        let smokeTest: SmokeTest
    }

    struct VerifiedPackage: Sendable {
        let archive: Data
        let contractBytes: Data
        let contract: Contract
    }

    static func load(bundle: Bundle = .main) throws -> VerifiedPackage {
        guard let archiveURL = bundle.url(forResource: archiveName, withExtension: "zip", subdirectory: "MCPTemplates"),
              let contractURL = bundle.url(forResource: "contract", withExtension: "json", subdirectory: "MCPTemplates") else {
            throw unavailable()
        }
        return try validate(archive: read(archiveURL, maximumBytes: 1_048_576),
                            contract: read(contractURL, maximumBytes: 65_536))
    }

    /// The fixed App-owned hashes bind both the source ZIP and the readable
    /// integration contract. An imported/generated project cannot replace
    /// these inputs or convert template readiness into guest/client evidence.
    static func validate(archive: Data, contract: Data) throws -> VerifiedPackage {
        guard !archive.isEmpty, archive.count <= 1_048_576,
              contract.count <= 65_536,
              digest(archive) == archiveDigest, digest(contract) == contractDigest else {
            throw unavailable()
        }
        let decoded: Contract
        do { decoded = try JSONDecoder().decode(Contract.self, from: contract) }
        catch { throw unavailable() }
        guard decoded.schemaVersion == 1, decoded.templateID == "floe.mcp.node-http",
              decoded.templateVersion == "1.0.1", !decoded.storefrontSkill,
              decoded.projectRoot == "node-http", decoded.runtime.os == "linux",
              decoded.sdk.package == "@modelcontextprotocol/sdk", decoded.sdk.version == "1.32.2",
              decoded.commands["start"] == ["node", "dist/server.js"],
              decoded.service.transport == "streamable-http",
              !decoded.service.readyLogIsAcceptance,
              decoded.smokeTest.tool == "service_status",
              decoded.smokeTest.requiresRealNativeClient,
              !decoded.smokeTest.automaticallyTestGeneratedSideEffects else {
            throw unavailable()
        }
        return VerifiedPackage(archive: archive, contractBytes: contract, contract: decoded)
    }

    private static func read(_ url: URL, maximumBytes: Int) throws -> Data {
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard let size, (1...maximumBytes).contains(size) else { throw unavailable() }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard (1...maximumBytes).contains(data.count) else { throw unavailable() }
            return data
        } catch { throw unavailable() }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func unavailable() -> FloeError {
        .invalidConfiguration(FloeL10n.l("skills.mcp.template_unavailable"))
    }
}
#endif
