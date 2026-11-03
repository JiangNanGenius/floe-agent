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
        "to": {"type": "string", "description": "New workspace-relative path (must not exist)"}
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
        let fromRoute = try await environment.networkRoute(path: args.from, context: context)
        let toRoute = try await environment.networkRoute(path: args.to, context: context)
        if let fromRoute, let toRoute {
            guard fromRoute.mount.id == toRoute.mount.id else {
                throw NetworkWorkspaceError(code: .unsupported, stage: "move", retryable: false, safeDetail: "Moving between different network mounts is not supported; copy then delete explicitly.")
            }
            let metadata = try await fromRoute.adapter.metadata(path: fromRoute.relativePath)
            try await fromRoute.adapter.move(from: fromRoute.relativePath, to: toRoute.relativePath, expectedEntityTag: metadata.entityTag)
            return WorkspaceToolSupport.output("moved=\(args.from) -> \(args.to) network=true")
        } else if fromRoute != nil || toRoute != nil {
            throw NetworkWorkspaceError(code: .unsupported, stage: "move", retryable: false, safeDetail: "Moving between local and network storage is not supported; use copy then delete explicitly.")
        }
        let service = try environment.makeService(context: context)
        try service.move(args.from, to: args.to, cancellation: context.cancellation)
        return WorkspaceToolSupport.output("moved=\(args.from) -> \(args.to)")
    }
}

// MARK: - workspace.deleteFile

/// Deletes a file or directory.
public struct WorkspaceDeleteFileTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var path: String
        public var recursive: Bool?
        public var scope: String?

        public init(path: String, recursive: Bool? = nil, scope: String? = nil) {
            self.path = path
            self.recursive = recursive
            self.scope = scope
        }
    }

    public static let name = "workspace.deleteFile"
    public static let toolDescription =
        "Delete a workspace file or directory. Non-empty directories require recursive=true. This cannot be undone."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "path": {"type": "string", "description": "Workspace-relative path to delete"},
        "recursive": {"type": "boolean", "description": "Set true to remove a non-empty directory and its contents"}
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
        if let route = try await environment.networkRoute(path: args.path, context: context) {
            let metadata = try await route.adapter.metadata(path: route.relativePath)
            if metadata.isDirectory, args.recursive == true {
                throw NetworkWorkspaceError(code: .unsupported, stage: "delete", retryable: false, safeDetail: "Recursive network deletion is intentionally unsupported; delete children explicitly.")
            }
            try await route.adapter.delete(path: route.relativePath, expectedEntityTag: metadata.entityTag)
            return WorkspaceToolSupport.output("deleted=\(args.path) recursive=false network=true")
        }
        let service = try environment.makeService(context: context)
        try service.delete(args.path, recursive: args.recursive ?? false, cancellation: context.cancellation)
        return WorkspaceToolSupport.output("deleted=\(args.path) recursive=\(args.recursive ?? false)")
    }
}

// MARK: - workspace.copyFile

/// Copies a file or directory within the workspace.
public struct WorkspaceCopyFileTool: AgentTool {
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

    public static let name = "workspace.copyFile"
    public static let toolDescription =
        "Copy a workspace file or directory to a new path. The destination must not already exist."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "from": {"type": "string", "description": "Current workspace-relative path"},
        "to": {"type": "string", "description": "New workspace-relative path (must not exist)"}
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
        let fromRoute = try await environment.networkRoute(path: args.from, context: context)
        let toRoute = try await environment.networkRoute(path: args.to, context: context)
        if let fromRoute, let toRoute {
            guard fromRoute.mount.id == toRoute.mount.id else {
                throw NetworkWorkspaceError(code: .unsupported, stage: "copy", retryable: false, safeDetail: "Copying between different network mounts is not supported.")
            }
            let data = try await fromRoute.adapter.read(path: fromRoute.relativePath, offset: 0, limit: environment.maxReadBytes)
            _ = try await toRoute.adapter.write(path: toRoute.relativePath, data: data, expectedEntityTag: nil)
            return WorkspaceToolSupport.output("copied=\(args.from) -> \(args.to) network=true")
        } else if fromRoute != nil || toRoute != nil {
            throw NetworkWorkspaceError(code: .unsupported, stage: "copy", retryable: false, safeDetail: "Use workspace.readFile/writeFile for an explicit bounded local/network transfer.")
        }
        let service = try environment.makeService(context: context)
        try service.copy(args.from, to: args.to, cancellation: context.cancellation)
        return WorkspaceToolSupport.output("copied=\(args.from) -> \(args.to)")
    }
}
