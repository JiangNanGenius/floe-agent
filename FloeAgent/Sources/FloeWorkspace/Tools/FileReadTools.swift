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
    public func makeService(context: ToolContext) throws -> WorkspaceFileService {
        let root = try rootURL(context: context)
        let guardResolver = WorkspacePathGuard(
            rootURL: root,
            maxReadBytes: maxReadBytes,
            maxWriteBytes: maxWriteBytes,
            mounts: WorkspaceMountRegistry.shared.mounts(for: root)
        )
        return WorkspaceFileService(guard: guardResolver)
    }

    public func rootURL(context: ToolContext) throws -> URL {
        guard let root = context.workspaceRootURL ?? rootProvider() else {
            throw WorkspaceToolError.notFound("workspace (no workspace is currently open)")
        }
        return root
    }

    public func networkRoute(
        path: String,
        context: ToolContext
    ) async throws -> NetworkWorkspaceMountRegistry.Route? {
        try await NetworkWorkspaceMountRegistry.shared.route(
            rootURL: rootURL(context: context),
            virtualPath: path
        )
    }

    public func networkMounts(context: ToolContext) async throws -> [NetworkWorkspaceMount] {
        await NetworkWorkspaceMountRegistry.shared.mounts(rootURL: try rootURL(context: context))
    }

    /// Direct UI/test access retains the legacy environment-root behavior.
    /// Agent executions use the context-bearing overload above.
    public func makeService() throws -> WorkspaceFileService {
        guard let root = rootProvider() else {
            throw WorkspaceToolError.notFound("workspace (no workspace is currently open)")
        }
        return WorkspaceFileService(guard: WorkspacePathGuard(
            rootURL: root,
            maxReadBytes: maxReadBytes,
            maxWriteBytes: maxWriteBytes,
            mounts: WorkspaceMountRegistry.shared.mounts(for: root)
        ))
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

    static func output(
        _ summary: String,
        artifacts: [ToolArtifactReference] = []
    ) -> ToolExecutionOutput {
        ToolExecutionOutput(
            summary: summary,
            fullOutputSHA256: WorkspaceFileService.sha256Hex(of: Data(summary.utf8)),
            artifacts: artifacts
        )
    }

    /// Persists a bounded, digest-addressed unified diff in Floe's own
    /// Application Support directory. The workspace itself is never used as
    /// an evidence store, so reviewing a change cannot modify user files.
    static func changeArtifact(diff: String, runID: UUID) throws -> ToolArtifactReference? {
        guard !diff.isEmpty else { return nil }
        let data = Data(diff.utf8)
        guard data.count <= 512 * 1024 else { return nil }
        let digest = WorkspaceFileService.sha256Hex(of: data)
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let relativeDirectory = "ChangeArtifacts/\(runID.uuidString)"
        let directory = support
            .appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent(relativeDirectory, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let name = "\(digest).diff"
        let url = directory.appendingPathComponent(name, isDirectory: false)
        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url, options: [.atomic])
        }
        return ToolArtifactReference(
            id: UUID(),
            relativePath: "\(relativeDirectory)/\(name)",
            mimeType: "text/x-diff",
            byteCount: data.count,
            sha256: digest
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
        "pageToken": {"type": "string", "description": "Opaque cursor from a previous call"}
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
        try WorkspaceToolSupport.rejectHostScope(context.scope)
        if let scope = args.scope, scope != "local" {
            throw WorkspaceToolError.unsupportedScope(scope)
        }
        try context.authorizeWorkspacePath(args.path)
        if args.path == "Network" || args.path == "Network/" {
            let mounts = try await environment.networkMounts(context: context)
            var lines = ["path=Network entries=\(mounts.count)"]
            lines += mounts.map { "dir\t0\tNetwork/\($0.name)" }
            return WorkspaceToolSupport.output(lines.joined(separator: "\n"))
        }
        if let route = try await environment.networkRoute(path: args.path, context: context) {
            let entries = try await route.adapter.list(path: route.relativePath)
            let offset = Int(args.pageToken ?? "0") ?? 0
            let end = min(entries.count, offset + WorkspaceFileService.pageSize)
            let page = offset < entries.count ? Array(entries[offset..<end]) : []
            var lines = page.map { entry in
                "\(entry.isDirectory ? "dir" : "file")\t\(entry.byteCount)\tNetwork/\(route.mount.name)/\(entry.path)"
            }
            lines.insert("path=\(args.path) entries=\(page.count) network=true", at: 0)
            if end < entries.count { lines.append("nextPageToken=\(end)") }
            return WorkspaceToolSupport.output(lines.joined(separator: "\n"))
        }
        let service = try environment.makeService(context: context)
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
        "limit": {"type": "integer", "description": "Maximum bytes to read; clamped to 65536"}
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
        try WorkspaceToolSupport.rejectHostScope(context.scope)
        if let scope = args.scope, scope != "local" {
            throw WorkspaceToolError.unsupportedScope(scope)
        }
        try context.authorizeWorkspacePath(args.path)
        if let route = try await environment.networkRoute(path: args.path, context: context) {
            let offset = args.offset ?? 0
            let limit = min(args.limit ?? WorkspaceFileService.readChunkBytes, WorkspaceFileService.readChunkBytes)
            let data = try await route.adapter.read(path: route.relativePath, offset: offset, limit: limit + 1)
            let truncated = data.count > limit
            let visible = truncated ? data.prefix(limit) : data[...]
            let text = String(decoding: visible, as: UTF8.self)
            let totalLines = text.reduce(into: 1) { if $1 == "\n" { $0 += 1 } }
            return WorkspaceToolSupport.output("path=\(args.path) offset=\(offset) truncated=\(truncated) totalLines=\(totalLines) network=true\n\(text)")
        }
        let service = try environment.makeService(context: context)
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
        "maxResults": {"type": "integer", "description": "Maximum hits; clamped to 100"}
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
        try WorkspaceToolSupport.rejectHostScope(context.scope)
        if let scope = args.scope, scope != "local" {
            throw WorkspaceToolError.unsupportedScope(scope)
        }
        try context.authorizeWorkspacePath(args.path ?? ".")
        if let requestedPath = args.path,
           let route = try await environment.networkRoute(path: requestedPath, context: context) {
            let limit = min(args.maxResults ?? WorkspaceFileService.maxSearchHits, WorkspaceFileService.maxSearchHits)
            let hits = try await searchNetwork(
                route: route,
                virtualRoot: requestedPath,
                query: args.query,
                maxResults: limit,
                cancellation: context.cancellation
            )
            return WorkspaceToolSupport.output(
                (["query=\(args.query) hits=\(hits.count) network=true"] + hits).joined(separator: "\n")
            )
        }
        let service = try environment.makeService(context: context)
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

    /// Network storage is intentionally searched as a virtual hierarchy. It is
    /// not mounted into the process filesystem, so symlinks and POSIX path
    /// assumptions can never escape the configured SMB/WebDAV root.
    private func searchNetwork(
        route: NetworkWorkspaceMountRegistry.Route,
        virtualRoot: String,
        query: String,
        maxResults: Int,
        cancellation: CancellationToken
    ) async throws -> [String] {
        let normalizedQuery = query.lowercased()
        var pending = [route.relativePath]
        var visited = 0
        var results: [String] = []

        while let path = pending.popLast(), results.count < maxResults {
            try cancellation.throwIfCancelled()
            guard visited < WorkspaceFileService.maxSearchFiles else {
                throw WorkspaceToolError.tooLarge(limit: WorkspaceFileService.maxSearchFiles)
            }
            visited += 1

            let metadata = try await route.adapter.metadata(path: path)
            if metadata.isDirectory {
                let children = try await route.adapter.list(path: path)
                pending.append(contentsOf: children.reversed().map(\.path))
                continue
            }
            guard metadata.byteCount <= 4 * 1_024 * 1_024 else { continue }
            let data = try await route.adapter.read(path: path, offset: 0, limit: Int(metadata.byteCount))
            guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else { continue }
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                where line.lowercased().contains(normalizedQuery) {
                let relativeSuffix = path.isEmpty ? "" : "/\(path)"
                let displayPath = virtualRoot.hasSuffix(relativeSuffix)
                    ? virtualRoot
                    : "\(route.mount.virtualRoot)\(relativeSuffix)"
                results.append("\(displayPath):\(index + 1): \(line.prefix(500))")
                if results.count >= maxResults { break }
            }
        }
        return results
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
        "path": {"type": "string", "description": "Workspace-relative path"}
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
        try WorkspaceToolSupport.rejectHostScope(context.scope)
        if let scope = args.scope, scope != "local" {
            throw WorkspaceToolError.unsupportedScope(scope)
        }
        try context.authorizeWorkspacePath(args.path)
        if let route = try await environment.networkRoute(path: args.path, context: context) {
            let metadata = try await route.adapter.metadata(path: route.relativePath)
            let summary = """
            path=\(args.path)
            isDirectory=\(metadata.isDirectory)
            size=\(metadata.byteCount)
            mtime=\(metadata.modifiedAt?.timeIntervalSince1970 ?? 0)
            uti=public.data
            entityTag=\(metadata.entityTag ?? "")
            isSymlink=false
            network=true
            """
            return WorkspaceToolSupport.output(summary)
        }
        let service = try environment.makeService(context: context)
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
