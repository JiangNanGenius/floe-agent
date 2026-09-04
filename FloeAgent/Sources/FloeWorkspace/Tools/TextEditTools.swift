import Foundation
import FloeCore
import FloeTools

/// Shared read/modify/write path: never applies a transformation to a partial
/// read, and binds the write to the exact bytes used by the transformation.
enum WorkspaceTextEdit {
    static func apply(
        path: String, expectedSHA256: String?, environment: WorkspaceToolEnvironment,
        context: ToolContext, transform: (String) throws -> String
    ) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        try WorkspaceToolSupport.rejectHostScope(context.scope)
        try context.authorizeWorkspacePath(path)
        let service = try environment.makeService(context: context)
        if let route = try await environment.networkRoute(path: path, context: context) {
            let metadata = try await route.adapter.metadata(path: route.relativePath)
            guard !metadata.isDirectory else { throw WorkspaceToolError.isDirectory(path) }
            guard metadata.byteCount <= environment.maxWriteBytes else {
                throw WorkspaceToolError.tooLarge(limit: environment.maxWriteBytes)
            }
            let bytes = try await route.adapter.read(path: route.relativePath, offset: 0, limit: environment.maxWriteBytes + 1)
            guard bytes.count == metadata.byteCount else {
                throw WorkspaceToolError.invalidArguments("Incomplete read; refresh the file before editing")
            }
            let original = try decode(bytes)
            let digest = WorkspaceFileService.sha256Hex(of: bytes)
            try check(expectedSHA256, actual: digest)
            let updated = try transform(original)
            let data = Data(updated.utf8)
            guard data.count <= environment.maxWriteBytes else {
                throw WorkspaceToolError.tooLarge(limit: environment.maxWriteBytes)
            }
            guard let entityTag = metadata.entityTag else {
                throw WorkspaceToolError.invalidArguments("Remote server has no revision token; exact edits require conditional writes")
            }
            _ = try await route.adapter.write(path: route.relativePath, data: data, expectedEntityTag: entityTag)
            return WorkspaceToolSupport.output("edited=\(path) bytes=\(data.count) sha256=\(WorkspaceFileService.sha256Hex(of: data)) network=true")
        }
        let original = try service.readFileForEditing(path, cancellation: context.cancellation).text
        let digest = WorkspaceFileService.sha256Hex(of: Data(original.utf8))
        try check(expectedSHA256, actual: digest)
        let updated = try transform(original)
        let outcome = try service.writeFile(path, content: updated, expectedSHA256: digest, cancellation: context.cancellation)
        let artifact = try WorkspaceToolSupport.changeArtifact(
            diff: service.diff(original: original, modified: updated, label: path), runID: context.runID
        )
        return WorkspaceToolSupport.output(
            "edited=\(path) bytes=\(outcome.bytesWritten) sha256=\(outcome.sha256) mtime=\(outcome.mtime)",
            artifacts: artifact.map { [$0] } ?? []
        )
    }

    static func decode(_ data: Data) throws -> String {
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            throw WorkspaceToolError.invalidArguments("Expected a UTF-8 text file; use a dedicated document or media tool for binary files")
        }
        return text
    }

    static func check(_ expected: String?, actual: String) throws {
        if let expected, expected.lowercased() != actual {
            throw WorkspaceToolError.conflict(expected: expected, actual: actual)
        }
    }
}

public struct WorkspaceAppendFileTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var path: String
        public var content: String
        public var expectedSHA256: String?
        public init(path: String, content: String, expectedSHA256: String? = nil) {
            self.path = path; self.content = content; self.expectedSHA256 = expectedSHA256
        }
    }
    public static let name = "workspace.appendFile"
    public static let toolDescription = "Append UTF-8 text to an existing workspace text file, including HTML, Python, source, configuration and Markdown. Preserves the complete original file and rejects concurrent edits and binary input."
    public static let parametersJSON = #"{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"},"expectedSHA256":{"type":"string"}},"required":["path","content"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.writesFiles]
    public static let isSideEffecting = true
    private let environment: WorkspaceToolEnvironment
    public init(environment: WorkspaceToolEnvironment) { self.environment = environment }
    public func validate(_ args: Arguments) throws {
        guard !args.path.isEmpty else { throw WorkspaceToolError.invalidArguments("path is required") }
    }
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await WorkspaceTextEdit.apply(path: args.path, expectedSHA256: args.expectedSHA256, environment: environment, context: context) { $0 + args.content }
    }
}

public struct WorkspaceReplaceTextTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var path: String
        public var oldText: String
        public var newText: String
        public var expectedOccurrences: Int?
        public var expectedSHA256: String?
        public init(path: String, oldText: String, newText: String, expectedOccurrences: Int? = nil, expectedSHA256: String? = nil) {
            self.path = path; self.oldText = oldText; self.newText = newText
            self.expectedOccurrences = expectedOccurrences; self.expectedSHA256 = expectedSHA256
        }
    }
    public static let name = "workspace.replaceText"
    public static let toolDescription = "Replace exact text in any UTF-8 workspace file (HTML, Python, source, config, Markdown). Use the complete old text of a range. Requires exactly expectedOccurrences matches (default 1); mismatches and concurrent edits leave the file untouched."
    public static let parametersJSON = #"{"type":"object","properties":{"path":{"type":"string"},"oldText":{"type":"string","minLength":1},"newText":{"type":"string"},"expectedOccurrences":{"type":"integer","minimum":1},"expectedSHA256":{"type":"string"}},"required":["path","oldText","newText"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.writesFiles]
    public static let isSideEffecting = true
    private let environment: WorkspaceToolEnvironment
    public init(environment: WorkspaceToolEnvironment) { self.environment = environment }
    public func validate(_ args: Arguments) throws {
        guard !args.path.isEmpty, !args.oldText.isEmpty, (args.expectedOccurrences ?? 1) > 0 else {
            throw WorkspaceToolError.invalidArguments("path, nonempty oldText and positive expectedOccurrences are required")
        }
    }
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await WorkspaceTextEdit.apply(path: args.path, expectedSHA256: args.expectedSHA256, environment: environment, context: context) { original in
            let parts = original.components(separatedBy: args.oldText)
            guard parts.count - 1 == (args.expectedOccurrences ?? 1) else {
                throw WorkspaceToolError.invalidArguments("Expected \(args.expectedOccurrences ?? 1) exact matches; found \(parts.count - 1). Read the file and provide an unambiguous range.")
            }
            return parts.joined(separator: args.newText)
        }
    }
}
