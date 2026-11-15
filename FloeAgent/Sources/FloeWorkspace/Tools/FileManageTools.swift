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
            let moved: NetworkWorkspaceFileMetadata?
            if metadata.entityTag?.isEmpty == false { moved = metadata }
            else { moved = try? await toRoute.adapter.metadata(path: toRoute.relativePath) }
            let paths = WorkspaceFileChangeEvidence.paths(WorkspaceFileChangeEvidence.networkPath(toRoute),
                from: WorkspaceFileChangeEvidence.networkPath(fromRoute), kind: moved.map { $0.isDirectory ? "directory" : "file" })
            return WorkspaceToolSupport.output("moved=\(args.from) -> \(args.to) network=true" + paths)
        } else if fromRoute != nil || toRoute != nil {
            throw NetworkWorkspaceError(code: .unsupported, stage: "move", retryable: false, safeDetail: "Moving between local and network storage is not supported; use copy then delete explicitly.")
        }
        let service = try environment.makeService(context: context)
        return try service.managedFileOutput("moved=\(args.from) -> \(args.to)", from: args.from, path: args.to) {
            try service.move(args.from, to: args.to, cancellation: context.cancellation)
        }
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
            let summary = "deleted=\(args.path) recursive=false network=true"
            // WebDAV accepts HTTP 202. Acknowledgment alone doesn't establish
            // that this path has disappeared. Optional readback cannot turn
            // an already accepted delete into a retryable mutation.
            if route.mount.transport == .webDAV {
                do {
                    _ = try await route.adapter.metadata(path: route.relativePath)
                    return WorkspaceToolSupport.output(summary + " paths={}")
                } catch let error as NetworkWorkspaceError where error.code == .notFound {
                    // The server confirms absence.
                } catch { return WorkspaceToolSupport.output(summary + " paths={}") }
            }
            return WorkspaceToolSupport.output(summary + WorkspaceFileChangeEvidence.paths(
                WorkspaceFileChangeEvidence.networkPath(route), kind: metadata.isDirectory ? "directory" : "file"))
        }
        let service = try environment.makeService(context: context)
        return try service.managedFileOutput("deleted=\(args.path) recursive=\(args.recursive ?? false)", path: args.path) {
            try service.delete(args.path, recursive: args.recursive ?? false, cancellation: context.cancellation)
        }
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
            return try await copyNetwork(args, from: fromRoute, to: toRoute, context: context)
        } else if fromRoute != nil || toRoute != nil {
            throw NetworkWorkspaceError(code: .unsupported, stage: "copy", retryable: false, safeDetail: "Use workspace.readFile/writeFile for an explicit bounded local/network transfer.")
        }
        let service = try environment.makeService(context: context)
        return try service.managedFileOutput("copied=\(args.from) -> \(args.to)", from: args.from, path: args.to) {
            try service.copy(args.from, to: args.to, cancellation: context.cancellation)
        }
    }

    func copyNetwork(_ args: Arguments, from fromRoute: NetworkWorkspaceMountRegistry.Route,
                     to toRoute: NetworkWorkspaceMountRegistry.Route, context: ToolContext) async throws -> ToolExecutionOutput {
        guard fromRoute.mount.id == toRoute.mount.id else {
            throw NetworkWorkspaceError(code: .unsupported, stage: "copy", retryable: false, safeDetail: "Copying between different network mounts is not supported.")
        }
        let source = try await fromRoute.adapter.metadataForCopy(path: fromRoute.relativePath)
        guard !source.isDirectory else { throw WorkspaceToolError.isDirectory(args.from) }
        guard source.byteCount >= 0 else {
            throw WorkspaceToolError.invalidArguments("The source file has no confirmed byte length")
        }
        let limit = min(environment.maxReadBytes, environment.maxWriteBytes)
        guard source.byteCount <= limit else { throw WorkspaceToolError.tooLarge(limit: limit) }
        // A one-byte range on an empty resource verifies that the server has
        // no bytes. When the read budget itself is zero, the confirmed
        // empty length is checked again below without requesting a byte.
        let readLimit = min(environment.maxReadBytes, max(1, Int(source.byteCount)))
        let data = readLimit == 0 ? Data() : try await fromRoute.adapter.read(path: fromRoute.relativePath, offset: 0, limit: readLimit)
        guard data.count == source.byteCount else {
            throw WorkspaceToolError.invalidArguments("Incomplete source file; refresh it before copying")
        }
        if !data.isEmpty, source.entityTag?.isEmpty != false, source.modifiedAt == nil {
            let verified = try await fromRoute.adapter.read(path: fromRoute.relativePath, offset: 0, limit: readLimit)
            guard verified == data else { throw WorkspaceToolError.conflict(expected: "stable source file", actual: "source changed") }
        }
        let current = try await fromRoute.adapter.metadataForCopy(path: fromRoute.relativePath)
        guard current == source else { throw WorkspaceToolError.conflict(expected: "stable source file", actual: "source changed") }
        try context.cancellation.throwIfCancelled()
        try Task.checkCancellation()
        let copied = try await toRoute.adapter.write(path: toRoute.relativePath, data: data, expectedEntityTag: nil)
        guard !copied.isDirectory, copied.byteCount == data.count else {
            var output = WorkspaceToolSupport.output("Cannot confirm the completed copy. Inspect the destination before retrying.")
            output.outcomeUnknown = true
            return output
        }
        let summary = "copied=\(args.from) -> \(args.to) network=true"
        let paths = WorkspaceFileChangeEvidence.paths(WorkspaceFileChangeEvidence.networkPath(toRoute),
            from: WorkspaceFileChangeEvidence.networkPath(fromRoute), kind: "file", change: .saved)
        return WorkspaceToolSupport.output(summary + paths)
    }
}
