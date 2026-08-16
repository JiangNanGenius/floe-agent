// FloeWorkspace — Side-effecting write tools.
// See docs/ARCHITECTURE_AGENT_WORKSPACE.md §6: createFile / writeFile /
// applyPatch. All are side-effecting (approval-gated upstream), resolve
// through WorkspacePathGuard, enforce write size caps, and implement
// mtime+sha256 conflict detection. Patch application is all-or-nothing.

import Foundation
import FloeCore
import FloeModels
import FloeTools

// MARK: - workspace.createFile

/// Creates a new file; fails when the target already exists.
public struct WorkspaceCreateFileTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var path: String
        public var content: String
        public var scope: String?

        public init(path: String, content: String, scope: String? = nil) {
            self.path = path
            self.content = content
            self.scope = scope
        }
    }

    public static let name = "workspace.createFile"
    public static let toolDescription =
        "Create a new workspace file with the given content. Fails without overwriting when the file already exists; use writeFile for updates."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "path": {"type": "string", "description": "Workspace-relative path for the new file"},
        "content": {"type": "string", "description": "Full file content (UTF-8)"},
        "scope": {"type": "string", "description": "Execution scope; only the local workspace is supported"}
      },
      "required": ["path", "content"],
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
        let outcome = try service.createFile(args.path, content: args.content, cancellation: context.cancellation)
        let diff = service.diff(original: "", modified: args.content, label: args.path)
        let artifact = try WorkspaceToolSupport.changeArtifact(diff: diff, runID: context.runID)
        return WorkspaceToolSupport.output(
            "created=\(args.path) bytes=\(outcome.bytesWritten) sha256=\(outcome.sha256) mtime=\(outcome.mtime)",
            artifacts: artifact.map { [$0] } ?? []
        )
    }
}

// MARK: - workspace.writeFile

/// Overwrites a file with optimistic mtime+sha256 conflict detection.
public struct WorkspaceWriteFileTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var path: String
        public var content: String
        /// Modification time (seconds since 1970) the caller last observed;
        /// combined with expectedSHA256 for conflict detection.
        public var expectedMtime: Double?
        public var expectedSHA256: String?
        public var scope: String?

        public init(
            path: String,
            content: String,
            expectedMtime: Double? = nil,
            expectedSHA256: String? = nil,
            scope: String? = nil
        ) {
            self.path = path
            self.content = content
            self.expectedMtime = expectedMtime
            self.expectedSHA256 = expectedSHA256
            self.scope = scope
        }
    }

    public static let name = "workspace.writeFile"
    public static let toolDescription =
        "Overwrite a workspace file. Pass expectedMtime/expectedSHA256 from inspectFileMetadata to detect external edits; conflicts fail without overwriting."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "path": {"type": "string", "description": "Workspace-relative file path"},
        "content": {"type": "string", "description": "New full file content (UTF-8)"},
        "expectedMtime": {"type": "number", "description": "mtime (seconds since 1970) last observed by the caller"},
        "expectedSHA256": {"type": "string", "description": "sha256 of the content last observed by the caller"},
        "scope": {"type": "string", "description": "Execution scope; only the local workspace is supported"}
      },
      "required": ["path", "content"],
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
        if args.path.trimmingCharacters(in: .whitespaces).isEmpty {
            throw WorkspaceToolError.invalidArguments("path must not be empty")
        }
        if let mtime = args.expectedMtime, mtime < 0 {
            throw WorkspaceToolError.invalidArguments("expectedMtime must be >= 0")
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
        let prior = try? service.readFile(args.path, cancellation: context.cancellation)
        let outcome = try service.writeFile(
            args.path,
            content: args.content,
            expectedMtime: args.expectedMtime,
            expectedSHA256: args.expectedSHA256,
            cancellation: context.cancellation
        )
        let diff: String
        if let prior, !prior.truncated {
            diff = service.diff(original: prior.text, modified: args.content, label: args.path)
        } else {
            diff = ""
        }
        let artifact = try WorkspaceToolSupport.changeArtifact(diff: diff, runID: context.runID)
        return WorkspaceToolSupport.output(
            "written=\(args.path) bytes=\(outcome.bytesWritten) sha256=\(outcome.sha256) mtime=\(outcome.mtime)",
            artifacts: artifact.map { [$0] } ?? []
        )
    }
}

// MARK: - workspace.applyPatch

/// Applies a single-file unified diff; failure leaves the file untouched.
public struct WorkspaceApplyPatchTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var path: String
        /// Standard unified diff (`diff -u` subset, single file).
        public var patch: String
        public var scope: String?

        public init(path: String, patch: String, scope: String? = nil) {
            self.path = path
            self.patch = patch
            self.scope = scope
        }
    }

    public static let name = "workspace.applyPatch"
    public static let toolDescription =
        "Apply a single-file unified diff to a workspace file. Hunks apply sequentially; if any hunk fails, the file is left untouched. Multi-file patches are rejected."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "path": {"type": "string", "description": "Workspace-relative file path to patch"},
        "patch": {"type": "string", "description": "Unified diff (diff -u subset) for this one file"},
        "scope": {"type": "string", "description": "Execution scope; only the local workspace is supported"}
      },
      "required": ["path", "patch"],
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
        if args.path.trimmingCharacters(in: .whitespaces).isEmpty {
            throw WorkspaceToolError.invalidArguments("path must not be empty")
        }
        if args.patch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw WorkspaceToolError.invalidArguments("patch must not be empty")
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
        let outcome = try service.applyPatch(args.path, patch: args.patch, cancellation: context.cancellation)
        let artifact = try WorkspaceToolSupport.changeArtifact(diff: args.patch, runID: context.runID)
        return WorkspaceToolSupport.output(
            "patched=\(args.path) hunks=\(outcome.hunksApplied) added=\(outcome.linesAdded) removed=\(outcome.linesRemoved) sha256=\(outcome.sha256)",
            artifacts: artifact.map { [$0] } ?? []
        )
    }
}
