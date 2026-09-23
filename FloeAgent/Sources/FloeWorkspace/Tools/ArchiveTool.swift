// FloeWorkspace — workspace.archive agent tool.
//
// The tool is the single entry point for archives inside the task workspace.
// Container and compression work is native (see `ArchiveEngine`): zip, tar,
// tar.gz, tar.bz2 and tar.xz are created, listed and extracted on the host,
// and single-file gzip/bzip2/xz are compressed and decompressed there too.
// 7z and RAR are read-only, using SWCompression and the app's signed native
// decoder respectively. No archive operation starts or requires the Linux
// guest; the optional guest bridge is a separate, explicitly negotiated path.

import Foundation
import SWCompression
import FloeCore
import FloeTools

/// One read-only RAR request handled by the app-supplied signed decoder.
/// Kept as a narrow seam: the app target owns the CArchive framework, while
/// every other format is implemented in `FloeWorkspace` itself.
public struct ArchiveCompressedRequest: Sendable {
    public var action: String
    /// rar.
    public var format: String
    public var source: String
    public var destination: String?
    public var workspaceRoot: URL
    public var cancellation: CancellationToken
    /// Task environment that owns the request; nil only in tests without an
    /// environment.
    public var environmentID: String?

    public init(action: String, format: String, source: String, destination: String?, workspaceRoot: URL, cancellation: CancellationToken = CancellationToken(), environmentID: String? = nil) {
        self.action = action
        self.format = format
        self.source = source
        self.destination = destination
        self.workspaceRoot = workspaceRoot
        self.cancellation = cancellation
        self.environmentID = environmentID
    }
}

public typealias ArchiveCompressedHandler = @Sendable (ArchiveCompressedRequest) async throws -> String

/// Creates, extracts and lists archives inside the workspace.
public struct WorkspaceArchiveTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var action: String
        public var source: String
        public var destinationDir: String?
        public var destinationFile: String?
        /// Internal resolved path; not a model parameter or legacy alias.
        fileprivate var destination: String? { destinationDir ?? destinationFile }
        /// Archive format; inferred from the source/destination extension when
        /// it is absent.
        public var format: String?
        /// Present when the call is routed to a host scope; always rejected.
        public var scope: String?

        public init(action: String, source: String, destinationDir: String? = nil, destinationFile: String? = nil, format: String? = nil, scope: String? = nil) {
            self.action = action
            self.source = source
            self.destinationDir = destinationDir
            self.destinationFile = destinationFile
            self.format = format
            self.scope = scope
        }
    }

    public static let name = "workspace.archive"
    public static let toolDescription =
        "Archive operations inside the workspace. create writes a new archive to destinationFile (zip/tar/tar.gz/tar.bz2/tar.xz from one file or directory, or gzip/bzip2/xz for a single file). extract writes zip/tar/tar.gz/tar.bz2/tar.xz/7z/rar entries into a new destinationDir, or decompresses gzip/bzip2/xz into destinationFile. Pass exactly the matching field; list accepts neither. Everything is native and bounded; existing outputs are never overwritten, traversal/symlink escapes and self-inclusion are refused, and the summary reports skipped entries plus metadata the format cannot carry. RAR list/extract uses the app's signed native decoder and rejects encrypted, multipart or unsupported variants. Old destination calls must be replanned, not replayed."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "action": {"type": "string", "enum": ["create", "extract", "list"]},
        "source": {"type": "string", "description": "Workspace-relative source: file/directory to pack (create) or archive to read (extract/list)"},
        "destinationDir": {"type": "string", "description": "New output directory, only for extracting zip/tar/7z/rar/tar.gz/tar.bz2/tar.xz containers"},
        "destinationFile": {"type": "string", "description": "New output file, for create or extracting single-file gzip/bzip2/xz"},
        "format": {"type": "string", "enum": ["zip", "tar", "tgz", "tbz2", "txz", "gz", "bz2", "xz", "7z", "rar"], "description": "Archive format; defaults to the destination/source extension"}
      },
      "required": ["action", "source"],
      "additionalProperties": false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles, .writesFiles]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    static let limits = ArchiveLimits()

    private let environment: WorkspaceToolEnvironment
    private let compressedHandler: ArchiveCompressedHandler?
    /// Optional byte/entry progress sink for app surfaces; the agent runtime
    /// leaves it nil.
    private let progress: ArchiveEngine.ProgressHandler?

    public init(
        environment: WorkspaceToolEnvironment,
        compressedHandler: ArchiveCompressedHandler? = nil,
        progress: ArchiveEngine.ProgressHandler? = nil
    ) {
        self.environment = environment
        self.compressedHandler = compressedHandler
        self.progress = progress
    }

    public func validate(_ args: Arguments) throws {
        guard ["create", "extract", "list"].contains(args.action) else {
            throw WorkspaceToolError.invalidArguments("action must be create, extract or list")
        }
        guard args.destinationDir == nil || args.destinationFile == nil else {
            throw WorkspaceToolError.invalidArguments("Pass only destinationDir or destinationFile, never both")
        }
        for path in [args.source, args.destinationDir, args.destinationFile].compactMap({ $0 }) {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~"),
                  !trimmed.split(separator: "/").contains("..") else {
                throw WorkspaceToolError.invalidArguments("paths must be workspace-relative")
            }
        }
        if args.action != "list",
           args.destination?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            throw WorkspaceToolError.invalidArguments("Use destinationDir for container extraction or destinationFile for create/single-file decompression; replan old destination calls")
        }
        if let format = args.format,
           !["zip", "tar", "tgz", "tbz2", "txz", "gz", "bz2", "xz", "7z", "rar"].contains(format) {
            throw WorkspaceToolError.invalidArguments("format must be zip, tar, tgz, tbz2, txz, gz, bz2, xz or 7z")
        }
        let resolved = try format(for: args)
        guard !(args.action == "create" && ["rar", "7z"].contains(resolved)) else {
            throw WorkspaceToolError.invalidArguments("RAR and 7z are list/extract only")
        }
        if args.action == "list" {
            guard args.destination == nil else { throw WorkspaceToolError.invalidArguments("list does not accept an output destination") }
        } else {
            let writesFile = args.action == "create" || ["gz", "bz2", "xz"].contains(resolved)
            guard writesFile ? args.destinationFile != nil : args.destinationDir != nil else {
                throw WorkspaceToolError.invalidArguments(writesFile ? "This operation requires destinationFile" : "Container extraction requires destinationDir")
            }
            if writesFile, args.destinationFile?.hasSuffix("/") == true {
                throw WorkspaceToolError.invalidArguments("destinationFile must name a file, not a directory")
            }
        }
    }

    /// Resolves the archive format from the explicit parameter or extension.
    private func format(for args: Arguments) throws -> String {
        if let format = args.format { return format }
        let reference = args.action == "create" ? (args.destination ?? "") : args.source
        let lower = reference.lowercased()
        if lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz") { return "tgz" }
        if lower.hasSuffix(".tar.bz2") || lower.hasSuffix(".tbz2") { return "tbz2" }
        if lower.hasSuffix(".tar.xz") || lower.hasSuffix(".txz") { return "txz" }
        switch (reference as NSString).pathExtension.lowercased() {
        case "tar": return "tar"
        case "zip": return "zip"
        case "gz": return "gz"
        case "bz2": return "bz2"
        case "xz": return "xz"
        case "7z": return "7z"
        case "rar": return "rar"
        default:
            throw WorkspaceToolError.invalidArguments(
                "Cannot infer the archive format from \(reference); pass format explicitly " +
                "(zip, tar, tgz, tbz2, txz, gz, bz2, xz or 7z)."
            )
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        try validate(args)
        try WorkspaceToolSupport.rejectHostScope(context.scope)
        if let scope = args.scope, scope != "local" {
            throw WorkspaceToolError.unsupportedScope(scope)
        }
        try context.authorizeWorkspacePath(args.source)
        if let destination = args.destination { try context.authorizeWorkspacePath(destination) }
        let service = try environment.makeService(context: context)
        let guarder = service.guardResolver
        let sourceURL = try guarder.resolve(args.source)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw WorkspaceToolError.notFound(args.source)
        }
        let resolvedFormat = try format(for: args)
        if resolvedFormat == "7z" {
            guard args.action != "create" else {
                throw WorkspaceToolError.invalidArguments("7z is extract/list only; create supports zip, tar and the compressed tar variants")
            }
            switch args.action {
            case "extract":
                return try extract7z(args, context: context, guarder: guarder, sourceURL: sourceURL)
            default:
                return try list7z(args, sourceURL: sourceURL)
            }
        }
        if resolvedFormat == "rar" {
            guard let compressedHandler else { throw WorkspaceToolError.invalidArguments("RAR requires the app's signed native archive decoder") }
            let summary = try await compressedHandler(ArchiveCompressedRequest(action: args.action, format: "rar",
                source: args.source, destination: args.destination, workspaceRoot: guarder.rootURL, cancellation: context.cancellation,
                environmentID: context.environment?.id))
            return WorkspaceToolSupport.output(summary)
        }
        if ["gz", "bz2", "xz"].contains(resolvedFormat), args.action == "list" {
            throw WorkspaceToolError.invalidArguments("\(resolvedFormat) is a single-file compression format; list applies to zip/tar/7z/tar.gz/tar.bz2/tar.xz")
        }
        return try runNative(
            args,
            format: resolvedFormat,
            context: context,
            guarder: guarder,
            sourceURL: sourceURL
        )
    }

    // MARK: - native engine dispatch

    private func runNative(
        _ args: Arguments,
        format: String,
        context: ToolContext,
        guarder: WorkspacePathGuard,
        sourceURL: URL
    ) throws -> ToolExecutionOutput {
        switch args.action {
        case "list":
            let listing = try ArchiveEngine.list(
                format: format,
                source: sourceURL,
                limits: Self.limits,
                cancellation: context.cancellation
            )
            return WorkspaceToolSupport.output(Self.listingText(listing, format: format, source: args.source))
        case "create":
            let destination = args.destination!
            let destinationURL = try guarder.resolve(destination)
            try guarder.assertWritable(destinationURL)
            let summary = try ArchiveEngine.create(
                format: format,
                sources: [sourceURL],
                destination: destinationURL,
                limits: Self.limits,
                progress: progress,
                cancellation: context.cancellation
            )
            return WorkspaceToolSupport.output(summary.line(source: args.source, destination: destination))
        default:
            let destination = args.destination!
            let destinationURL = try guarder.resolve(destination)
            try guarder.assertWritable(destinationURL)
            if ArchiveEngine.singleFileFormats.contains(format) {
                let summary = try ArchiveEngine.decompress(
                    format: format,
                    source: sourceURL,
                    destination: destinationURL,
                    limits: Self.limits,
                    progress: progress,
                    cancellation: context.cancellation
                )
                return WorkspaceToolSupport.output(summary.line(source: args.source, destination: destination))
            }
            let summary = try ArchiveEngine.extract(
                format: format,
                source: sourceURL,
                destination: destinationURL,
                limits: Self.limits,
                progress: progress,
                cancellation: context.cancellation
            )
            return WorkspaceToolSupport.output(summary.line(source: args.source, destination: destination))
        }
    }

    /// The bounded listing text the browser and the agent both consume:
    /// `status=ok action=list format=… source=… entries=N truncated=B` then
    /// `kind\tsize\tpath` rows.
    static func listingText(_ listing: ArchiveListing, format: String, source: String) -> String {
        var lines = ["status=ok action=list format=\(format) source=\(source) entries=\(listing.entries.count) truncated=\(listing.truncated)"]
        for entry in listing.entries {
            lines.append("\(entry.isDirectory ? "dir" : "file")\t\(entry.size)\t\(entry.path)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 7z extract / list (SWCompression, read-only)

    private func extract7z(
        _ args: Arguments,
        context: ToolContext,
        guarder: WorkspacePathGuard,
        sourceURL: URL
    ) throws -> ToolExecutionOutput {
        let destination = args.destination!
        try context.authorizeWorkspacePath(destination)
        let destinationURL = try guarder.resolve(destination)
        try guarder.assertWritable(destinationURL)
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw WorkspaceToolError.alreadyExists(destination)
        }
        let data = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        let entries: [SevenZipEntry]
        do {
            entries = try SevenZipContainer.open(container: data)
        } catch {
            throw WorkspaceToolError.invalidArguments("source is not a readable 7z archive")
        }
        var extracted = 0
        var skipped = 0
        var totalBytes: UInt64 = 0
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        for entry in entries where entry.info.type == .regular {
            try context.cancellation.throwIfCancelled()
            guard extracted < Self.limits.maxEntries else {
                throw WorkspaceToolError.tooLarge(limit: Self.limits.maxEntries)
            }
            let name = entry.info.name
            let components = name.split(separator: "/", omittingEmptySubsequences: true)
            if let baseName = components.last, baseName.hasPrefix("._") {
                continue
            }
            guard !name.hasPrefix("/"), !name.hasPrefix("~"),
                  !components.contains(".."), !components.isEmpty,
                  !name.contains("\\") else {
                skipped += 1
                continue
            }
            totalBytes += UInt64(entry.info.size ?? 0)
            guard totalBytes <= UInt64(Self.limits.maxTotalBytes) else {
                throw WorkspaceToolError.tooLarge(limit: Int(Self.limits.maxTotalBytes))
            }
            let target = destinationURL.appendingPathComponent(name)
            guard target.path.hasPrefix(destinationURL.path + "/") else {
                skipped += 1
                continue
            }
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard let contents = entry.data else {
                skipped += 1
                continue
            }
            try contents.write(to: target, options: [.atomic])
            extracted += 1
        }
        return WorkspaceToolSupport.output(
            "status=ok action=extract format=7z source=\(args.source) destination=\(destination) entries=\(extracted) skipped=\(skipped) uncompressedBytes=\(totalBytes)"
        )
    }

    private func list7z(_ args: Arguments, sourceURL: URL) throws -> ToolExecutionOutput {
        let data = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        let entries: [SevenZipEntry]
        do {
            entries = try SevenZipContainer.open(container: data)
        } catch {
            throw WorkspaceToolError.invalidArguments("source is not a readable 7z archive")
        }
        var listing = ArchiveListing(entries: [], truncated: false)
        for entry in entries {
            if listing.entries.count >= Self.limits.maxListedEntries {
                listing.truncated = true
                break
            }
            listing.entries.append(ArchiveListedEntry(
                path: entry.info.name,
                isDirectory: entry.info.type == .directory,
                size: Int64(entry.info.size ?? 0)
            ))
        }
        return WorkspaceToolSupport.output(Self.listingText(listing, format: "7z", source: args.source))
    }
}
