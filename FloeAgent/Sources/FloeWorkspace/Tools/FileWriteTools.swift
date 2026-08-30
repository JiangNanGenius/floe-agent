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
        "Create a new workspace file with the given content. Fails without overwriting when the file already exists; use writeFile for updates. Prefer the .md extension for documents, notes, and reports; use a different extension only when the caller explicitly requires a specific format."
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
        if let route = try await environment.networkRoute(path: args.path, context: context) {
            do {
                _ = try await route.adapter.metadata(path: route.relativePath)
                throw WorkspaceToolError.alreadyExists(args.path)
            } catch let error as NetworkWorkspaceError where error.code == .notFound {
                // Expected for create-only semantics.
            }
            let data = Data(args.content.utf8)
            let result = try await route.adapter.write(path: route.relativePath, data: data, expectedEntityTag: nil)
            return WorkspaceToolSupport.output("created=\(args.path) bytes=\(data.count) sha256=\(WorkspaceFileService.sha256Hex(of: data)) mtime=\(result.modifiedAt?.timeIntervalSince1970 ?? 0) network=true")
        }
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
        if let route = try await environment.networkRoute(path: args.path, context: context) {
            let previous = try await route.adapter.read(path: route.relativePath, offset: 0, limit: environment.maxReadBytes)
            if let expectedSHA256 = args.expectedSHA256,
               WorkspaceFileService.sha256Hex(of: previous) != expectedSHA256 {
                throw WorkspaceToolError.conflict(expected: expectedSHA256, actual: WorkspaceFileService.sha256Hex(of: previous))
            }
            let metadata = try await route.adapter.metadata(path: route.relativePath)
            if let expectedMtime = args.expectedMtime,
               abs((metadata.modifiedAt?.timeIntervalSince1970 ?? 0) - expectedMtime) > 0.001 {
                throw WorkspaceToolError.conflict(expected: String(expectedMtime), actual: String(metadata.modifiedAt?.timeIntervalSince1970 ?? 0))
            }
            let data = Data(args.content.utf8)
            let result = try await route.adapter.write(path: route.relativePath, data: data, expectedEntityTag: metadata.entityTag)
            let diff = String(decoding: previous, as: UTF8.self)
            let localService = try environment.makeService(context: context)
            let artifact = try WorkspaceToolSupport.changeArtifact(
                diff: localService.diff(original: diff, modified: args.content, label: args.path),
                runID: context.runID
            )
            return WorkspaceToolSupport.output(
                "written=\(args.path) bytes=\(data.count) sha256=\(WorkspaceFileService.sha256Hex(of: data)) mtime=\(result.modifiedAt?.timeIntervalSince1970 ?? 0) network=true",
                artifacts: artifact.map { [$0] } ?? []
            )
        }
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
        if let route = try await environment.networkRoute(path: args.path, context: context) {
            // Reuse the exact, already-tested unified-diff engine against an
            // isolated temporary file, then upload the resulting bytes with
            // the remote entity tag as the conflict precondition.
            let metadata = try await route.adapter.metadata(path: route.relativePath)
            let original = try await route.adapter.read(path: route.relativePath, offset: 0, limit: environment.maxReadBytes)
            let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporaryRoot) }
            let temporaryFile = temporaryRoot.appendingPathComponent("remote.txt")
            try original.write(to: temporaryFile, options: .atomic)
            let temporaryService = WorkspaceFileService(guard: WorkspacePathGuard(rootURL: temporaryRoot, maxReadBytes: environment.maxReadBytes, maxWriteBytes: environment.maxWriteBytes))
            let outcome = try temporaryService.applyPatch("remote.txt", patch: args.patch, cancellation: context.cancellation)
            let updated = try Data(contentsOf: temporaryFile)
            _ = try await route.adapter.write(path: route.relativePath, data: updated, expectedEntityTag: metadata.entityTag)
            let artifact = try WorkspaceToolSupport.changeArtifact(diff: args.patch, runID: context.runID)
            return WorkspaceToolSupport.output(
                "patched=\(args.path) hunks=\(outcome.hunksApplied) added=\(outcome.linesAdded) removed=\(outcome.linesRemoved) sha256=\(outcome.sha256) network=true",
                artifacts: artifact.map { [$0] } ?? []
            )
        }
        let service = try environment.makeService(context: context)
        let outcome = try service.applyPatch(args.path, patch: args.patch, cancellation: context.cancellation)
        let artifact = try WorkspaceToolSupport.changeArtifact(diff: args.patch, runID: context.runID)
        return WorkspaceToolSupport.output(
            "patched=\(args.path) hunks=\(outcome.hunksApplied) added=\(outcome.linesAdded) removed=\(outcome.linesRemoved) sha256=\(outcome.sha256)",
            artifacts: artifact.map { [$0] } ?? []
        )
    }
}

// MARK: - workspace.createDirectory

/// Creates a new directory (and any missing parent directories).
public struct WorkspaceCreateDirectoryTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var path: String
        public var scope: String?

        public init(path: String, scope: String? = nil) {
            self.path = path
            self.scope = scope
        }
    }

    public static let name = "workspace.createDirectory"
    public static let toolDescription =
        "Create a new directory (and any missing parent directories) in the workspace. Fails when a file already exists at the path."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "path": {"type": "string", "description": "Workspace-relative directory path to create"},
        "scope": {"type": "string", "description": "Execution scope; only the local workspace is supported"}
      },
      "required": ["path"],
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
        if let route = try await environment.networkRoute(path: args.path, context: context) {
            try await route.adapter.createDirectory(path: route.relativePath)
            return WorkspaceToolSupport.output("created=\(args.path) network=true")
        }
        let service = try environment.makeService(context: context)
        try service.createDirectory(args.path, cancellation: context.cancellation)
        return WorkspaceToolSupport.output("created=\(args.path)")
    }
}
