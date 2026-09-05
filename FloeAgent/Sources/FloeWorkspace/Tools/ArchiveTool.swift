// FloeWorkspace — workspace.archive agent tool.
//
// First-class zip capability: create, extract and list archives inside the
// task workspace. Extraction is bounded (entry count, total bytes, entry-name
// sanitization) so a hostile archive cannot escape the workspace or fill the
// device.

import Foundation
import ZIPFoundation
import FloeCore
import FloeTools

/// Creates, extracts and lists zip archives inside the workspace.
public struct WorkspaceArchiveTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var action: String
        public var source: String
        public var destination: String?
        /// Present when the call is routed to a host scope; always rejected.
        public var scope: String?

        public init(action: String, source: String, destination: String? = nil, scope: String? = nil) {
            self.action = action
            self.source = source
            self.destination = destination
            self.scope = scope
        }
    }

    public static let name = "workspace.archive"
    public static let toolDescription =
        "Zip operations inside the workspace. action=create packs one file or directory into a new .zip at destination; action=extract unpacks a .zip into a new destination directory (entry count and total size are capped, unsafe entry names are skipped); action=list shows archive entries. Existing destinations are never overwritten."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "action": {"type": "string", "enum": ["create", "extract", "list"]},
        "source": {"type": "string", "description": "Workspace-relative source: file/directory to pack (create) or .zip to read (extract/list)"},
        "destination": {"type": "string", "description": "Workspace-relative output .zip (create) or output directory (extract); required for create and extract"}
      },
      "required": ["action", "source"],
      "additionalProperties": false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles, .writesFiles]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    private static let maxEntries = 5_000
    private static let maxTotalUncompressedBytes = 256 * 1_024 * 1_024
    private static let maxListedEntries = 500

    private let environment: WorkspaceToolEnvironment
    public init(environment: WorkspaceToolEnvironment) {
        self.environment = environment
    }

    public func validate(_ args: Arguments) throws {
        guard ["create", "extract", "list"].contains(args.action) else {
            throw WorkspaceToolError.invalidArguments("action must be create, extract or list")
        }
        for path in [args.source, args.destination].compactMap({ $0 }) {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~"),
                  !trimmed.split(separator: "/").contains("..") else {
                throw WorkspaceToolError.invalidArguments("paths must be workspace-relative")
            }
        }
        if args.action != "list",
           args.destination?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            throw WorkspaceToolError.invalidArguments("destination is required for create and extract")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        try WorkspaceToolSupport.rejectHostScope(context.scope)
        if let scope = args.scope, scope != "local" {
            throw WorkspaceToolError.unsupportedScope(scope)
        }
        try context.authorizeWorkspacePath(args.source)
        let service = try environment.makeService(context: context)
        let guarder = service.guardResolver
        let sourceURL = try guarder.resolve(args.source)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw WorkspaceToolError.notFound(args.source)
        }
        switch args.action {
        case "create":
            return try create(args, context: context, guarder: guarder, sourceURL: sourceURL)
        case "extract":
            return try extract(args, context: context, guarder: guarder, sourceURL: sourceURL)
        default:
            return try list(args, sourceURL: sourceURL)
        }
    }

    // MARK: - create

    private func create(
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
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory)
        let temporary = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let archive = Archive(url: temporary, accessMode: .create) else {
            throw FloeError.internalError("Could not create the archive")
        }
        var entryCount = 0
        var totalBytes: Int64 = 0
        if isDirectory.boolValue {
            let base = sourceURL.deletingLastPathComponent()
            let basePath = base.path
            let sourceName = sourceURL.lastPathComponent
            func relativePath(for item: URL) -> String {
                let itemPath = item.path
                if itemPath.hasPrefix(basePath + "/") {
                    return String(itemPath.dropFirst(basePath.count + 1))
                }
                // macOS temp roots differ by symlink resolution (/var vs
                // /private/var). Re-anchor on the source directory name so
                // entry names always stay workspace-relative.
                let marker = "/" + sourceName + "/"
                if let range = itemPath.range(of: marker, options: .backwards) {
                    return sourceName + "/" + itemPath[range.upperBound...]
                }
                return item.lastPathComponent
            }
            guard let enumerator = FileManager.default.enumerator(
                at: sourceURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { throw WorkspaceToolError.notFound(args.source) }
            for case let item as URL in enumerator {
                try context.cancellation.throwIfCancelled()
                let values = try item.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
                let relative = relativePath(for: item)
                if values.isDirectory == true {
                    try archive.addEntry(
                        with: relative + "/",
                        fileURL: item,
                        compressionMethod: .none
                    )
                    continue
                }
                guard values.isRegularFile == true else { continue }
                guard entryCount < Self.maxEntries else {
                    throw WorkspaceToolError.tooLarge(limit: Self.maxEntries)
                }
                let size = Int64((try item.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
                totalBytes += size
                guard totalBytes <= Int64(Self.maxTotalUncompressedBytes) else {
                    throw WorkspaceToolError.tooLarge(limit: Self.maxTotalUncompressedBytes)
                }
                try archive.addEntry(
                    with: relative,
                    fileURL: item,
                    compressionMethod: .deflate
                )
                entryCount += 1
            }
        } else {
            let size = Int64((try sourceURL.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
            guard size <= Int64(Self.maxTotalUncompressedBytes) else {
                throw WorkspaceToolError.tooLarge(limit: Self.maxTotalUncompressedBytes)
            }
            try archive.addEntry(
                with: sourceURL.lastPathComponent,
                fileURL: sourceURL,
                compressionMethod: .deflate
            )
            entryCount = 1
            totalBytes = size
        }
        try FileManager.default.moveItem(at: temporary, to: destinationURL)
        return WorkspaceToolSupport.output(
            "status=ok action=create source=\(args.source) destination=\(destination) entries=\(entryCount) uncompressedBytes=\(totalBytes)"
        )
    }

    // MARK: - extract

    private func extract(
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
        guard let archive = Archive(url: sourceURL, accessMode: .read) else {
            throw WorkspaceToolError.invalidArguments("source is not a readable zip archive")
        }
        var extracted = 0
        var skipped = 0
        var totalBytes: UInt64 = 0
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        for entry in archive {
            try context.cancellation.throwIfCancelled()
            // Directory entries are structural: file extraction recreates the
            // tree, and only files count toward the reported total.
            guard entry.type == .file else { continue }
            guard extracted < Self.maxEntries else {
                throw WorkspaceToolError.tooLarge(limit: Self.maxEntries)
            }
            // Never let an entry escape the destination or touch absolute paths.
            let name = entry.path
            let components = name.split(separator: "/", omittingEmptySubsequences: true)
            guard !name.hasPrefix("/"), !name.hasPrefix("~"),
                  !components.contains(".."), !components.isEmpty else {
                skipped += 1
                continue
            }
            totalBytes += entry.uncompressedSize
            guard totalBytes <= UInt64(Self.maxTotalUncompressedBytes) else {
                throw WorkspaceToolError.tooLarge(limit: Self.maxTotalUncompressedBytes)
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
            _ = try archive.extract(entry, to: target)
            extracted += 1
        }
        return WorkspaceToolSupport.output(
            "status=ok action=extract source=\(args.source) destination=\(destination) entries=\(extracted) skipped=\(skipped) uncompressedBytes=\(totalBytes)"
        )
    }

    // MARK: - list

    private func list(_ args: Arguments, sourceURL: URL) throws -> ToolExecutionOutput {
        guard let archive = Archive(url: sourceURL, accessMode: .read) else {
            throw WorkspaceToolError.invalidArguments("source is not a readable zip archive")
        }
        var lines = ["status=ok action=list source=\(args.source)"]
        var count = 0
        var truncated = false
        for entry in archive {
            if count >= Self.maxListedEntries { truncated = true; break }
            lines.append("\(entry.type == .directory ? "dir" : "file")\t\(entry.uncompressedSize)\t\(entry.path)")
            count += 1
        }
        lines[0] += " entries=\(count) truncated=\(truncated)"
        return WorkspaceToolSupport.output(lines.joined(separator: "\n"))
    }
}
