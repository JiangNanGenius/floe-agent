// FloeWorkspace — Exact plain-text append/replace tools.
//
// These were previously registered as compatibility-only aliases even though
// the runtime prompt already directed ordinary plain-text work to them. They
// are now first-class model-facing tools; the filename is retained so the
// existing target membership and build inputs stay stable.

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
    public static let toolDescription = "Append UTF-8 text to any existing plain-text workspace file: source code, scripts, HTML/CSS/JS, JSON/YAML/CSV, LaTeX, TXT, configuration, or an extensionless/unknown-extension file. Preserves the complete original bytes (including a UTF-8 BOM and CRLF newlines) and rejects concurrent edits and binary input. For long text, append bounded chunks to a new draft; always pass the previous returned SHA as expectedSHA256. Repeating a chunk with the SAME expectedSHA256 conflicts without appending twice. Never replace that precondition merely to retry. Finalize with workspace.writeFile(sourcePath, expectedSourceSHA256). Prefer this native tool over Linux for plain text."
    public static let parametersJSON = #"{"type":"object","properties":{"path":{"type":"string","description":"Workspace-relative path to an existing UTF-8 text file"},"content":{"type":"string","description":"Exact UTF-8 text to append"},"expectedSHA256":{"type":"string","description":"SHA of the complete file BEFORE this mutation; required for safe chunk retries, never advance it when resending the same chunk"}},"required":["path","content"],"additionalProperties":false}"#
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
    public static let toolDescription = "Replace exact text in any UTF-8 plain-text workspace file: source code, scripts, HTML/CSS/JS, JSON/YAML/CSV, LaTeX, TXT, configuration, or an extensionless/unknown-extension file. Use the complete old text of a range. Requires exactly expectedOccurrences matches (default 1); mismatches, binary input and concurrent edits leave the file untouched; BOM/CRLF bytes outside the replaced range are preserved."
    public static let parametersJSON = #"{"type":"object","properties":{"path":{"type":"string","description":"Workspace-relative path to an existing UTF-8 text file"},"oldText":{"type":"string","minLength":1,"description":"Exact existing text to replace; include enough context to identify the intended range"},"newText":{"type":"string","description":"Replacement text"},"expectedOccurrences":{"type":"integer","minimum":1,"description":"Exact number of matches required (default 1)"},"expectedSHA256":{"type":"string","description":"SHA of the complete file BEFORE this mutation; required for safe chunk retries, never advance it when resending the same chunk"}},"required":["path","oldText","newText"],"additionalProperties":false}"#
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
                throw WorkspaceToolError.invalidArguments(WorkspaceEditRecoveryHint.mismatch(
                    original: original, oldText: args.oldText, newText: args.newText,
                    expected: args.expectedOccurrences ?? 1, actual: parts.count - 1
                ))
            }
            return parts.joined(separator: args.newText)
        }
    }
}
