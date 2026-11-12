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

/// Creates a new file; fails when the target already exists unless
/// `overwrite=true` is passed.
public struct WorkspaceCreateFileTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var path: String
        public var content: String
        /// Replace the existing file at `path` instead of failing.
        public var overwrite: Bool?
        public var scope: String?

        public init(path: String, content: String, overwrite: Bool? = nil, scope: String? = nil) {
            self.path = path
            self.content = content
            self.overwrite = overwrite
            self.scope = scope
        }
    }

    public static let name = "workspace.createFile"
    public static let toolDescription =
        "Create a new plain-text workspace file of any UTF-8 text type: TXT, CSV/TSV, Markdown, source code, scripts, HTML/CSS/JS, JSON/YAML/XML, LaTeX, configuration, or an extensionless/unknown-extension file. Fails without overwriting when the file already exists; pass overwrite=true to replace the existing file, or use writeFile for updates. Parent directories are created automatically for local/mounted workspace targets. For long text, create a new draft with empty content, append bounded chunks with the previous returned SHA as expectedSHA256, then use workspace.writeFile(sourcePath, expectedSourceSHA256) to finalize without resending the document. Keep the draft until final verification."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "path": {"type": "string", "description": "Workspace-relative path for the new plain-text file; any UTF-8 text extension, or no extension"},
        "content": {"type": "string", "description": "Full UTF-8 text content"},
        "overwrite": {"type": "boolean", "description": "Replace the file when it already exists (default false)"}
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
            var expectedEntityTag: String?
            var priorMetadata: NetworkWorkspaceFileMetadata?
            do {
                let metadata = try await route.adapter.metadata(path: route.relativePath)
                guard args.overwrite == true else {
                    throw WorkspaceToolError.alreadyExistsOverwritable(args.path)
                }
                expectedEntityTag = metadata.entityTag
                priorMetadata = metadata
            } catch let error as NetworkWorkspaceError where error.code == .notFound {
                // Expected for create-only semantics.
            }
            var baseline: String?
            if let priorMetadata, priorMetadata.byteCount >= 0, priorMetadata.byteCount <= environment.maxReadBytes,
               priorMetadata.entityTag?.isEmpty == false {
                do {
                    let previous = try await route.adapter.read(path: route.relativePath, offset: 0, limit: environment.maxReadBytes)
                    let after = try await route.adapter.metadata(path: route.relativePath)
                    baseline = WorkspaceFileChangeEvidence.remoteBaseline(bytes: previous, before: priorMetadata, after: after)
                } catch {
                    // Optional comparison failure is visible in its saved-file preview.
                    // Cancellation cannot be converted into permission to write.
                    try context.cancellation.throwIfCancelled()
                    try Task.checkCancellation()
                }
            }
            let data = Data(args.content.utf8)
            let result = try await route.adapter.write(path: route.relativePath, data: data, expectedEntityTag: expectedEntityTag)
            return WorkspaceFileChangeEvidence.savedOutput("created=\(args.path) bytes=\(data.count) sha256=\(WorkspaceFileService.sha256Hex(of: data)) mtime=\(result.modifiedAt?.timeIntervalSince1970 ?? 0) network=true",
                original: baseline, modified: args.content, path: args.path, runID: context.runID)
        }
        let service = try environment.makeService(context: context)
        let (outcome, prior) = try service.createFileWithChangeBaseline(args.path, content: args.content,
            overwrite: args.overwrite == true, cancellation: context.cancellation)
        return WorkspaceFileChangeEvidence.savedOutput(
            "created=\(args.path) bytes=\(outcome.bytesWritten) sha256=\(outcome.sha256) mtime=\(outcome.mtime)",
            original: prior, modified: args.content, path: args.path, runID: context.runID)
    }
}

// MARK: - workspace.writeFile

/// Overwrites a file with optimistic mtime+sha256 conflict detection.
public struct WorkspaceWriteFileTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var path: String
        public var content: String?
        public var expectedMtime: Double?
        public var expectedSHA256: String?
        public var scope: String?
        /// Local/mounted workspace draft, authorized independently from path.
        public var sourcePath: String?
        public var expectedSourceSHA256: String?

        public init(path: String, content: String? = nil, expectedMtime: Double? = nil,
                    expectedSHA256: String? = nil, scope: String? = nil,
                    sourcePath: String? = nil, expectedSourceSHA256: String? = nil) {
            self.path = path; self.content = content
            self.expectedMtime = expectedMtime; self.expectedSHA256 = expectedSHA256
            self.scope = scope; self.sourcePath = sourcePath
            self.expectedSourceSHA256 = expectedSourceSHA256
        }
    }

    public static let name = "workspace.writeFile"
    public static let toolDescription =
        "Write any UTF-8 plain-text workspace file natively: source code, scripts, HTML/CSS/JS, JSON/YAML/CSV, LaTeX, TXT, configuration, or an extensionless/unknown-extension file. Supply exactly one of content or sourcePath. The commit preserves the exact UTF-8 bytes supplied, including a leading BOM and the original CRLF/LF newlines; local writes are atomic. For a long document, create a new draft, append bounded chunks with the previous SHA as expectedSHA256, then finalize using sourcePath and its final expectedSourceSHA256; no Linux or giant JSON body is needed. sourcePath is a local/mounted workspace text file and remains unchanged. Source finalization is create-only without a target precondition; for an existing target pass its observed expectedSHA256/expectedMtime. Conflicts and pre-commit cancellation leave the target untouched. saved=true means do not repeat the write even if preview=unavailable."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "path": {"type": "string", "description": "Workspace-relative target path for any plain-text file"},
        "content": {"type": "string", "description": "New full UTF-8 text; omit when sourcePath is supplied"},
        "sourcePath": {"type": "string", "description": "Existing local/mounted workspace text draft of any text type; mutually exclusive with content; never deleted"},
        "expectedSourceSHA256": {"type": "string", "pattern": "^[A-Fa-f0-9]{64}$", "description": "Required with sourcePath: exact final SHA returned by append/metadata"},
        "expectedMtime": {"type": "number", "description": "Observed target mtime in seconds since 1970"},
        "expectedSHA256": {"type": "string", "description": "Observed target SHA; stale values fail without overwrite"}
      },
      "required": ["path"],
      "additionalProperties": false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles, .writesFiles]
    public static let isSideEffecting = true
    private let environment: WorkspaceToolEnvironment
    public init(environment: WorkspaceToolEnvironment) { self.environment = environment }

    public func validate(_ args: Arguments) throws {
        guard !args.path.trimmingCharacters(in: .whitespaces).isEmpty,
              (args.content != nil) != (args.sourcePath != nil) else {
            throw WorkspaceToolError.invalidArguments("path and exactly one of content or sourcePath are required")
        }
        if let mtime = args.expectedMtime, !mtime.isFinite || mtime < 0 {
            throw WorkspaceToolError.invalidArguments("expectedMtime must be finite and >= 0")
        }
        if let source = args.sourcePath {
            guard !source.trimmingCharacters(in: .whitespaces).isEmpty,
                  let digest = args.expectedSourceSHA256, digest.utf8.count == 64,
                  digest.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
                throw WorkspaceToolError.invalidArguments("sourcePath requires its complete 64-digit expectedSourceSHA256")
            }
        } else if args.expectedSourceSHA256 != nil {
            throw WorkspaceToolError.invalidArguments("expectedSourceSHA256 requires sourcePath")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args)
        try context.cancellation.throwIfCancelled()
        try Task.checkCancellation()
        try WorkspaceToolSupport.rejectHostScope(context.scope)
        if let scope = args.scope, scope != "local" { throw WorkspaceToolError.unsupportedScope(scope) }
        try context.authorizeWorkspacePath(args.path)
        if let source = args.sourcePath {
            try context.authorizeWorkspacePath(source)
            guard try await environment.networkRoute(path: source, context: context) == nil else {
                throw WorkspaceToolError.invalidArguments("sourcePath finalization requires a local/mounted workspace text file; keep the network original and use a verified local draft")
            }
        }
        let service = try environment.makeService(context: context)
        if let route = try await environment.networkRoute(path: args.path, context: context) {
            let content: String
            if let source = args.sourcePath, let expected = args.expectedSourceSHA256 {
                content = try service.verifiedSourceText(source, expectedSHA256: expected, cancellation: context.cancellation)
            } else if let inline = args.content { content = inline }
            else { throw WorkspaceToolError.invalidArguments("Missing text source") }
            let data = Data(content.utf8)
            guard data.count <= environment.maxWriteBytes else { throw WorkspaceToolError.tooLarge(limit: environment.maxWriteBytes) }
            // This adapter exposes conditional update, not atomic create-if-absent.
            // Metadata notFound therefore remains an explicit failure; the draft survives.
            let before = try await route.adapter.metadata(path: route.relativePath)
            let previous = try await route.adapter.read(path: route.relativePath, offset: 0, limit: environment.maxReadBytes)
            let metadata = try await route.adapter.metadata(path: route.relativePath)
            if args.sourcePath != nil || args.expectedSHA256 != nil {
                guard before == metadata, previous.count == metadata.byteCount else {
                    throw WorkspaceToolError.conflict(expected: "complete unchanged target", actual: "remote target changed or read was incomplete")
                }
            }
            if args.sourcePath != nil {
                guard metadata.entityTag?.isEmpty == false,
                      args.expectedSHA256 != nil || args.expectedMtime != nil else {
                    throw WorkspaceToolError.invalidArguments("Remote draft finalization needs a server revision token and an observed target precondition")
                }
            }
            if let expected = args.expectedSHA256 {
                try WorkspaceTextEdit.check(expected, actual: WorkspaceFileService.sha256Hex(of: previous))
            }
            if let expectedMtime = args.expectedMtime,
               abs((metadata.modifiedAt?.timeIntervalSince1970 ?? 0) - expectedMtime) > 0.001 {
                throw WorkspaceToolError.conflict(expected: String(expectedMtime), actual: String(metadata.modifiedAt?.timeIntervalSince1970 ?? 0))
            }
            if let source = args.sourcePath, let expected = args.expectedSourceSHA256 {
                _ = try service.verifiedSourceText(source, expectedSHA256: expected, cancellation: context.cancellation)
            }
            try context.cancellation.throwIfCancelled()
            try Task.checkCancellation()
            let result = try await route.adapter.write(path: route.relativePath, data: data, expectedEntityTag: metadata.entityTag)
            let baseline = WorkspaceFileChangeEvidence.remoteBaseline(bytes: previous, before: before, after: metadata)
            return WorkspaceFileChangeEvidence.savedOutput(
                "written=\(args.path) bytes=\(data.count) sha256=\(WorkspaceFileService.sha256Hex(of: data)) mtime=\(result.modifiedAt?.timeIntervalSince1970 ?? 0) network=true",
                original: baseline, modified: content, path: args.path, runID: context.runID)
        }
        let outcome: WriteOutcome
        let prior: String?
        let content: String
        if let source = args.sourcePath, let expected = args.expectedSourceSHA256 {
            (outcome, prior, content) = try service.writeFileFromSourceWithChangeBaseline(
                args.path, sourcePath: source, expectedSourceSHA256: expected,
                expectedMtime: args.expectedMtime, expectedSHA256: args.expectedSHA256,
                cancellation: context.cancellation)
        } else if let inline = args.content {
            content = inline
            (outcome, prior) = try service.writeFileWithChangeBaseline(args.path, content: inline,
                expectedMtime: args.expectedMtime, expectedSHA256: args.expectedSHA256, cancellation: context.cancellation)
        } else { throw WorkspaceToolError.invalidArguments("Missing text source") }
        return WorkspaceFileChangeEvidence.savedOutput(
            "written=\(args.path) bytes=\(outcome.bytesWritten) sha256=\(outcome.sha256) mtime=\(outcome.mtime)",
            original: prior, modified: content, path: args.path, runID: context.runID)
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
        "Apply a single-file unified diff to any UTF-8 plain-text workspace file: code, scripts, HTML/CSS/JS, JSON/YAML/CSV, LaTeX, TXT, configuration, or an extensionless/unknown-extension file. Hunks apply sequentially; if any hunk fails, the file is left untouched. Multi-file patches are rejected. BOM and CRLF bytes are preserved when the hunk context matches them."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "path": {"type": "string", "description": "Workspace-relative plain-text file path to patch"},
        "patch": {"type": "string", "description": "Unified diff (diff -u subset) for this one file; context must match the file's BOM/CRLF bytes"}
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
            guard metadata.byteCount == original.count else {
                throw WorkspaceToolError.invalidArguments("Incomplete read; refresh the file before editing")
            }
            let leasedRoot = try await StorageCleanupLeaseCenter.shared.makeLeasedScratch(purpose: "workspace")
            let temporaryRoot = leasedRoot.url
            defer {
                try? FileManager.default.removeItem(at: temporaryRoot)
                leasedRoot.lease.release()
            }
            let temporaryFile = temporaryRoot.appendingPathComponent("remote.txt")
            try original.write(to: temporaryFile, options: .atomic)
            let temporaryService = WorkspaceFileService(guard: WorkspacePathGuard(rootURL: temporaryRoot, maxReadBytes: environment.maxReadBytes, maxWriteBytes: environment.maxWriteBytes))
            let outcome = try temporaryService.applyPatch("remote.txt", patch: args.patch, cancellation: context.cancellation)
            let updated = try Data(contentsOf: temporaryFile)
            _ = try await route.adapter.write(path: route.relativePath, data: updated, expectedEntityTag: metadata.entityTag)
            return WorkspaceFileChangeEvidence.savedOutput(
                "patched=\(args.path) hunks=\(outcome.hunksApplied) added=\(outcome.linesAdded) removed=\(outcome.linesRemoved) sha256=\(outcome.sha256) network=true") {
                try WorkspaceToolSupport.changeArtifact(diff: args.patch, runID: context.runID).map { [$0] } ?? []
            }
        }
        let service = try environment.makeService(context: context)
        let outcome = try service.applyPatch(args.path, patch: args.patch, cancellation: context.cancellation)
        return WorkspaceFileChangeEvidence.savedOutput(
            "patched=\(args.path) hunks=\(outcome.hunksApplied) added=\(outcome.linesAdded) removed=\(outcome.linesRemoved) sha256=\(outcome.sha256)") {
            try WorkspaceToolSupport.changeArtifact(diff: args.patch, runID: context.runID).map { [$0] } ?? []
        }
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
        "path": {"type": "string", "description": "Workspace-relative directory path to create"}
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
