// FloeWorkspace — Read-only agent file tools.
// See docs/ARCHITECTURE_AGENT_WORKSPACE.md §6: listDirectory / readFile /
// searchFiles / inspectFileMetadata. All are non-side-effecting, resolve
// every path through WorkspacePathGuard, and enforce the output limits in
// the tool table. Host scope is rejected with `unsupportedScope` (P1 is
// local workspace only).

import Foundation
import Crypto
import FloeCore
import FloeModels
import FloeTools

/// Shared dependencies for the workspace file tools.
public struct WorkspaceToolEnvironment: Sendable {
    /// Supplies the current workspace root; nil means no workspace is open.
    public var rootProvider: @Sendable () -> URL?
    /// Maximum read size applied to every guard created from the root.
    public var maxReadBytes: Int
    /// Maximum write size applied to every guard created from the root.
    public var maxWriteBytes: Int

    public init(
        rootProvider: @escaping @Sendable () -> URL?,
        maxReadBytes: Int = 10 * 1024 * 1024,
        maxWriteBytes: Int = 4 * 1024 * 1024
    ) {
        self.rootProvider = rootProvider
        self.maxReadBytes = maxReadBytes
        self.maxWriteBytes = maxWriteBytes
    }

    /// Builds a file service for the current workspace root.
    public func makeService() throws -> WorkspaceFileService {
        guard let root = rootProvider() else {
            throw WorkspaceToolError.notFound("workspace (no workspace is currently open)")
        }
        let guardResolver = WorkspacePathGuard(
            rootURL: root,
            maxReadBytes: maxReadBytes,
            maxWriteBytes: maxWriteBytes
        )
        return WorkspaceFileService(guard: guardResolver)
    }
}

enum WorkspaceToolSupport {
    /// P1: workspace tools operate on the local workspace only.
    static func rejectHostScope(_ scope: ToolScope) throws {
        switch scope {
        case .local:
            return
        case .host(let id):
            throw WorkspaceToolError.unsupportedScope("host(\(id.uuidString))")
        case .hostPath(let hostID, let path):
            throw WorkspaceToolError.unsupportedScope("hostPath(\(hostID.uuidString), \(path))")
        }
    }

    static func output(_ summary: String) -> ToolExecutionOutput {
        ToolExecutionOutput(
            summary: summary,
            fullOutputSHA256: WorkspaceFileService.sha256Hex(of: Data(summary.utf8))
        )
    }
}

// MARK: - workspace.listDirectory

/// Lists one page (≤200 entries) of a workspace directory.
public struct WorkspaceListDirectoryTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var path: String
        public var pageToken: String?
        /// Present when the call is routed to a host scope; always rejected.
        public var scope: String?

        public init(path: String, pageToken: String? = nil, scope: String? = nil) {
            self.path = path
            self.pageToken = pageToken
            self.scope = scope
        }
    }

    public static let name = "workspace.listDirectory"
    public static let toolDescription =
        "List the contents of a workspace directory, one page (up to 200 entries) at a time. Pass nextPageToken back as pageToken to continue."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "path": {"type": "string", "description": "Workspace-relative directory path (use \".\" for the root)"},
        "pageToken": {"type": "string", "description": "Opaque cursor from a previous call"},
        "scope": {"type": "string", "description": "Execution scope; only the local workspace is supported"}
      },
      "required": ["path"],
      "additionalProperties": false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles]
    public static let isSideEffecting = false

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
        if let scope = args.scope, scope != "local" {
            throw WorkspaceToolError.unsupportedScope(scope)
        }
        let service = try environment.makeService()
        let page = try service.listDirectory(args.path, pageToken: args.pageToken, cancellation: context.cancellation)
        var lines = page.entries.map { entry in
            let kind = entry.isDirectory ? "dir" : "file"
            return "\(kind)\t\(entry.size)\t\(entry.relativePath)"
        }
        lines.insert("path=\(args.path) entries=\(page.entries.count)", at: 0)
        if let token = page.nextPageToken {
            lines.append("nextPageToken=\(token)")
        }
        return WorkspaceToolSupport.output(lines.joined(separator: "\n"))
    }
}

// MARK: - workspace.readFile

/// Reads up to 64 KiB of a workspace file with truncation reporting.
public struct WorkspaceReadFileTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var path: String
        /// Byte offset into the file (0-based); defaults to 0.
        public var offset: Int?
        /// Byte cap for this read; clamped to 64 KiB.
        public var limit: Int?
        public var scope: String?

        public init(path: String, offset: Int? = nil, limit: Int? = nil, scope: String? = nil) {
            self.path = path
            self.offset = offset
            self.limit = limit
            self.scope = scope
        }
    }

    public static let name = "workspace.readFile"
    public static let toolDescription =
        "Read up to 64 KiB of a workspace file. When the file is larger, the result is marked truncated and reports total line count; continue with offset."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "path": {"type": "string", "description": "Workspace-relative file path"},
        "offset": {"type": "integer", "description": "Byte offset to start reading at (0-based)"},
        "limit": {"type": "integer", "description": "Maximum bytes to read; clamped to 65536"},
        "scope": {"type": "string", "description": "Execution scope; only the local workspace is supported"}
      },
      "required": ["path"],
      "additionalProperties": false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles]
    public static let isSideEffecting = false

    private let environment: WorkspaceToolEnvironment
    public init(environment: WorkspaceToolEnvironment) {
        self.environment = environment
    }

    public func validate(_ args: Arguments) throws {
        if args.path.trimmingCharacters(in: .whitespaces).isEmpty {
            throw WorkspaceToolError.invalidArguments("path must not be empty")
        }
        if let offset = args.offset, offset < 0 {
            throw WorkspaceToolError.invalidArguments("offset must be >= 0")
        }
        if let limit = args.limit, limit <= 0 {
            throw WorkspaceToolError.invalidArguments("limit must be > 0")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        if let scope = args.scope, scope != "local" {
            throw WorkspaceToolError.unsupportedScope(scope)
        }
        let service = try environment.makeService()
        let content = try service.readFile(
            args.path,
            byteOffset: args.offset ?? 0,
            cancellation: context.cancellation
        )
        // Honor a caller-supplied limit below the service chunk size.
        let limit = args.limit ?? WorkspaceFileService.readChunkBytes
        var text = content.text
        var truncated = content.truncated
        if limit < WorkspaceFileService.readChunkBytes {
            let bytes = Data(text.utf8)
            if bytes.count > limit {
                text = String(decoding: bytes.prefix(limit), as: UTF8.self)
                truncated = true
            }
        }
        var summary = "path=\(args.path) offset=\(content.byteOffset) truncated=\(truncated) totalLines=\(content.totalLines)\n"
        summary += text
        return WorkspaceToolSupport.output(summary)
    }
}

// MARK: - workspace.searchFiles

/// Case-insensitive substring search over workspace text files.
public struct WorkspaceSearchFilesTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var query: String
        public var path: String?
        public var maxResults: Int?
        public var scope: String?

        public init(query: String, path: String? = nil, maxResults: Int? = nil, scope: String? = nil) {
            self.query = query
            self.path = path
            self.maxResults = maxResults
            self.scope = scope
        }
    }

    public static let name = "workspace.searchFiles"
    public static let toolDescription =
        "Search workspace text files for a case-insensitive substring. Returns up to 100 hits with path, line number and a short context line."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "query": {"type": "string", "description": "Substring to search for (case-insensitive)"},
        "path": {"type": "string", "description": "Workspace-relative directory or file to search; defaults to the root"},
        "maxResults": {"type": "integer", "description": "Maximum hits; clamped to 100"},
        "scope": {"type": "string", "description": "Execution scope; only the local workspace is supported"}
      },
      "required": ["query"],
      "additionalProperties": false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles]
    public static let isSideEffecting = false

    private let environment: WorkspaceToolEnvironment
    public init(environment: WorkspaceToolEnvironment) {
        self.environment = environment
    }

    public func validate(_ args: Arguments) throws {
        if args.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw WorkspaceToolError.invalidArguments("query must not be empty")
        }
        if let maxResults = args.maxResults, maxResults <= 0 {
            throw WorkspaceToolError.invalidArguments("maxResults must be > 0")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        if let scope = args.scope, scope != "local" {
            throw WorkspaceToolError.unsupportedScope(scope)
        }
        let service = try environment.makeService()
        let hits = try service.search(
            query: args.query,
            in: args.path ?? "",
            maxResults: args.maxResults ?? WorkspaceFileService.maxSearchHits,
            cancellation: context.cancellation
        )
        var lines = ["query=\(args.query) hits=\(hits.count)"]
        for hit in hits {
            lines.append("\(hit.relativePath):\(hit.lineNumber): \(hit.context)")
        }
        return WorkspaceToolSupport.output(lines.joined(separator: "\n"))
    }
}

// MARK: - workspace.inspectFileMetadata

/// Reports size/mtime/UTI/sha256/symlink metadata for one path.
public struct WorkspaceInspectMetadataTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var path: String
        public var scope: String?

        public init(path: String, scope: String? = nil) {
            self.path = path
            self.scope = scope
        }
    }

    public static let name = "workspace.inspectFileMetadata"
    public static let toolDescription =
        "Inspect a workspace file or directory: size, modification time, UTI, sha256 and whether it is a symbolic link."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "path": {"type": "string", "description": "Workspace-relative path"},
        "scope": {"type": "string", "description": "Execution scope; only the local workspace is supported"}
      },
      "required": ["path"],
      "additionalProperties": false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles]
    public static let isSideEffecting = false

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
        if let scope = args.scope, scope != "local" {
            throw WorkspaceToolError.unsupportedScope(scope)
        }
        let service = try environment.makeService()
        let metadata = try service.metadata(args.path)
        let summary = """
        path=\(metadata.relativePath)
        isDirectory=\(metadata.isDirectory)
        size=\(metadata.size)
        mtime=\(metadata.mtime)
        uti=\(metadata.uti)
        sha256=\(metadata.sha256)
        isSymlink=\(metadata.isSymlink)
        """
        return WorkspaceToolSupport.output(summary)
    }
}
