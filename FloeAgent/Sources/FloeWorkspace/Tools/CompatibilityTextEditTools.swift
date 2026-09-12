import Foundation
import FloeCore
import FloeTools

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
