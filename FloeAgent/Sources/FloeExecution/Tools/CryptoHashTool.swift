// FloeExecution — crypto.hash agent tool.
//
// Auditable hashing as a first-class capability instead of an informal
// Python hashlib fallback. Text input stays in the call; file input is
// resolved through the workspace guard like every other file tool.

import Foundation
import Crypto
import FloeCore
import FloeTools
import FloeWorkspace

/// Computes a cryptographic digest of text or a workspace file.
public struct CryptoHashTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var algorithm: String
        public var text: String?
        public var path: String?

        public init(algorithm: String, text: String? = nil, path: String? = nil) {
            self.algorithm = algorithm
            self.text = text
            self.path = path
        }
    }

    public static let name = "crypto.hash"
    public static let toolDescription =
        "Hash text or a workspace file with SHA-256, SHA-384, SHA-512, SHA-1 or MD5. Provide exactly one of text or path. SHA-1 and MD5 are for compatibility checks only, not security decisions. Prefer this over ad-hoc scripts when a digest must be verifiable later."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "algorithm": {"type": "string", "enum": ["sha256", "sha384", "sha512", "sha1", "md5"]},
        "text": {"type": "string", "description": "UTF-8 text to hash (max 1 MiB)"},
        "path": {"type": "string", "description": "Workspace-relative file to hash"}
      },
      "required": ["algorithm"],
      "additionalProperties": false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles]
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly

    public init() {}

    public func validate(_ args: Arguments) throws {
        let algorithm = args.algorithm.lowercased()
        guard ["sha256", "sha384", "sha512", "sha1", "md5"].contains(algorithm) else {
            throw FloeError.validationFailed("algorithm must be sha256, sha384, sha512, sha1 or md5")
        }
        switch (args.text, args.path) {
        case (.some, .some), (nil, nil):
            throw FloeError.validationFailed("Provide exactly one of text or path")
        default:
            break
        }
        if let text = args.text, text.utf8.count > 1_048_576 {
            throw FloeError.validationFailed("text exceeds the 1 MiB limit")
        }
        if let path = args.path {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~"),
                  !trimmed.split(separator: "/").contains("..") else {
                throw FloeError.validationFailed("path must be workspace-relative")
            }
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let data: Data
        let source: String
        if let text = args.text {
            data = Data(text.utf8)
            source = "text"
        } else if let path = args.path {
            guard let root = context.workspaceRootURL else {
                return Self.output("status=error error=No task workspace is available", exitStatus: 2)
            }
            do {
                try context.authorizeWorkspacePath(path)
                let url = try WorkspacePathGuard(rootURL: root).resolve(path)
                try WorkspacePathGuard(rootURL: root).assertReadableSize(url)
                data = try Data(contentsOf: url, options: [.mappedIfSafe])
                source = "path=\(path)"
            } catch {
                return Self.output("status=error error=\(error.localizedDescription)", exitStatus: 2)
            }
        } else {
            return Self.output("status=error error=Provide exactly one of text or path", exitStatus: 2)
        }
        let hex: String
        switch args.algorithm.lowercased() {
        case "sha512": hex = SHA512.hash(data: data).map { String(format: "%02x", $0) }.joined()
        case "sha384": hex = SHA384.hash(data: data).map { String(format: "%02x", $0) }.joined()
        case "sha1": hex = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
        case "md5": hex = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        default: hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return Self.output("status=ok algorithm=\(args.algorithm.lowercased()) source=\(source) bytes=\(data.count) digest=\(hex)", exitStatus: 0)
    }

    private static func output(_ text: String, exitStatus: Int32) -> ToolExecutionOutput {
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return ToolExecutionOutput(summary: text, fullOutputSHA256: digest, exitStatus: exitStatus)
    }
}
