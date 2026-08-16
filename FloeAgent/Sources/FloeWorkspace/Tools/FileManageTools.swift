// FloeWorkspace — Move / delete tools.
// See docs/ARCHITECTURE_AGENT_WORKSPACE.md §6: moveFile and deleteFile.
// Both paths pass through WorkspacePathGuard; delete is limited to files
// and empty directories and carries the `deletesFiles` risk label.

import Foundation
import FloeCore
import FloeModels
import FloeTools

// MARK: - workspace.moveFile

/// Moves (or renames) a file or directory within the workspace.
public struct WorkspaceMoveFileTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var from: String
        public var to: String
        public var scope: String?

        public init(from: String, to: String, scope: String? = nil) {
            self.from = from
            self.to = to
            self.scope = scope
        }
    }

    public static let name = "workspace.moveFile"
    public static let toolDescription =
        "Move or rename a workspace file or directory. Both paths must stay inside the workspace; the destination must not already exist."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "from": {"type": "string", "description": "Current workspace-relative path"},
        "to": {"type": "string", "description": "New workspace-relative path (must not exist)"},
        "scope": {"type": "string", "description": "Execution scope; only the local workspace is supported"}
      },
      "required": ["from", "to"],
      "additionalProperties": false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [.writesFiles]
    public static let isSideEffecting = true

    private let environment: WorkspaceToolEnvironment
    public init(environment: WorkspaceToolEnvironment) {
        self.environment = environment
    }

    public func validate(_ args: Arguments) throws {
        if args.from.trimmingCharacters(in: .whitespaces).isEmpty {
            throw WorkspaceToolError.invalidArguments("from must not be empty")
        }
        if args.to.trimmingCharacters(in: .whitespaces).isEmpty {
            throw WorkspaceToolError.invalidArguments("to must not be empty")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        try WorkspaceToolSupport.rejectHostScope(context.scope)
        if let scope = args.scope, scope != "local" {
            throw WorkspaceToolError.unsupportedScope(scope)
        }
        try context.authorizeWorkspacePath(args.from)
        try context.authorizeWorkspacePath(args.to)
        let service = try environment.makeService(context: context)
        try service.move(args.from, to: args.to, cancellation: context.cancellation)
        return WorkspaceToolSupport.output("moved=\(args.from) -> \(args.to)")
    }
}

// MARK: - workspace.deleteFile

/// Deletes a file or an empty directory.
public struct WorkspaceDeleteFileTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var path: String
        public var scope: String?

        public init(path: String, scope: String? = nil) {
            self.path = path
            self.scope = scope
        }
    }

    public static let name = "workspace.deleteFile"
    public static let toolDescription =
        "Delete a workspace file or an empty directory. Non-empty directories are refused; delete their contents first. This cannot be undone."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "path": {"type": "string", "description": "Workspace-relative path to delete"},
        "scope": {"type": "string", "description": "Execution scope; only the local workspace is supported"}
      },
      "required": ["path"],
      "additionalProperties": false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [.writesFiles, .deletesFiles]
    public static let isSideEffecting = true

    private let environment: WorkspaceToolEnvironment
    public init(environment: WorkspaceToolEnvironment) {
        self.environment = environment
    }

    public func validate(_ args: Arguments) throws {
        if args.path.trimmingCharacters(in: .whitespaces).isEmpty {
            throw WorkspaceToolError.invalidArguments("path must not be empty")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        try WorkspaceToolSupport.rejectHostScope(context.scope)
        if let scope = args.scope, scope != "local" {
            throw WorkspaceToolError.unsupportedScope(scope)
        }
        try context.authorizeWorkspacePath(args.path)
        let service = try environment.makeService(context: context)
        try service.delete(args.path, cancellation: context.cancellation)
        return WorkspaceToolSupport.output("deleted=\(args.path)")
    }
}
