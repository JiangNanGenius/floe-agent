// FloeDocuments — document.createDocument agent tool.
//
// Creates a document in the workspace. Markdown and plain-text documents are
// written directly. Office creation is not advertised until a bundled,
// signed implementation exists; runtime package downloads are forbidden.

import Foundation
import Crypto
import FloeCore
import FloeTools
import FloeWorkspace

/// Creates a workspace document with initial content.
public struct DocumentCreateTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var name: String
        public var content: String

        public init(name: String, content: String) {
            self.name = name
            self.content = content
        }
    }

    public static let name = "document.createDocument"
    public static let toolDescription =
        "Create a Markdown (.md) document in the workspace. Prefer .md for notes, reports, and documents; use .txt only for content that must not contain Markdown formatting."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "name": {"type": "string", "description": "Workspace-relative filename (e.g. notes.md, report.txt)"},
        "content": {"type": "string", "description": "Initial document content (Markdown or plain text)"}
      },
      "required": ["name", "content"],
      "additionalProperties": false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [.writesFiles]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    static let maxNameBytes = 255
    static let maxContentBytes = 4 * 1024 * 1024

    private let rootProvider: @Sendable () -> URL?

    public init(rootProvider: @escaping @Sendable () -> URL?) {
        self.rootProvider = rootProvider
    }

    public func validate(_ args: Arguments) throws {
        let name = args.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw FloeError.validationFailed("name must not be empty") }
        guard name.utf8.count <= Self.maxNameBytes else {
            throw FloeError.validationFailed("name exceeds \(Self.maxNameBytes) bytes")
        }
        guard args.content.utf8.count <= Self.maxContentBytes else {
            throw FloeError.validationFailed("content exceeds \(Self.maxContentBytes) bytes")
        }
        let ext = (name as NSString).pathExtension.lowercased()
        guard ext == "md" || ext == "markdown" || ext == "txt" else {
            throw FloeError.validationFailed("document.createDocument supports only .md, .markdown, and .txt")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        guard let root = context.workspaceRootURL ?? rootProvider() else {
            return Self.output("status=error error=No workspace is open", exitStatus: 2)
        }
        do {
            try context.authorizeWorkspacePath(args.name)
            let service = WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root))
            _ = try service.createFile(
                args.name, content: args.content, cancellation: context.cancellation
            )
            return Self.output("created=\(args.name) bytes=\(args.content.utf8.count)", exitStatus: 0)
        } catch {
            return Self.output("status=error error=\(error.localizedDescription)", exitStatus: 2)
        }
    }

    private static func output(_ text: String, exitStatus: Int32) -> ToolExecutionOutput {
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return ToolExecutionOutput(summary: text, fullOutputSHA256: digest, exitStatus: exitStatus)
    }
}
