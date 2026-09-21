// FloeWorkspace — safe archive browsing for the app surfaces.
//
// The browser reuses the same `WorkspaceArchiveTool` execution path the agent
// uses, so every bound and protection stays in one place: entry/size limits,
// path-traversal and symlink rejection, no overwrites, and workspace-relative
// path validation. Nothing here depends on the Linux guest: zip, tar and 7z
// are read natively. Formats that do need the local runtime (compressed tar,
// single-file gzip/bzip2/xz, RAR) report that truthfully instead of failing
// with a generic error or silently routing run inside the guest.

import Foundation
import FloeCore
import FloeTools

public struct ArchiveBrowseEntry: Sendable, Hashable, Identifiable {
    public var path: String
    public var isDirectory: Bool
    public var size: Int64

    public var id: String { path }

    public init(path: String, isDirectory: Bool, size: Int64) {
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
    }
}

public struct ArchiveBrowseListing: Sendable, Equatable {
    public var format: String
    public var entries: [ArchiveBrowseEntry]
    /// True when the archive contains more entries than the bounded listing.
    public var truncated: Bool
    public var summary: String

    public init(format: String, entries: [ArchiveBrowseEntry], truncated: Bool, summary: String) {
        self.format = format
        self.entries = entries
        self.truncated = truncated
        self.summary = summary
    }
}

public enum ArchiveBrowseError: Error, LocalizedError, Equatable {
    /// The format cannot be browsed in-app, with the concrete reason.
    case unsupportedFormat(format: String, reason: String)
    case notFound(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let format, let reason):
            return "\(format) archives cannot be browsed here: \(reason)"
        case .notFound(let path):
            return "Archive not found: \(path)"
        case .failed(let reason):
            return reason
        }
    }
}

/// Reads archive structure and extracts one archive for preview.
public struct ArchiveBrowserService: Sendable {
    /// Container formats this surface reads natively (no Linux runtime).
    public static let nativeFormats: Set<String> = ["zip", "tar", "7z"]
    /// Formats that need the task environment's Linux guest Python bridge.
    public static let compressedFormats: Set<String> = ["tgz", "tbz2", "txz", "gz", "bz2", "xz"]
    /// RAR needs the app's signed decoder handler and is list/extract only.
    public static let rarFormats: Set<String> = ["rar"]

    private let environment: WorkspaceToolEnvironment

    public init(rootProvider: @escaping @Sendable () -> URL?) {
        self.environment = WorkspaceToolEnvironment(rootProvider: rootProvider)
    }

    /// The format inferred from the file name, matching the archive tool's
    /// own extension rules.
    public static func format(for relativePath: String) -> String? {
        let lower = relativePath.lowercased()
        if lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz") { return "tgz" }
        if lower.hasSuffix(".tar.bz2") || lower.hasSuffix(".tbz2") { return "tbz2" }
        if lower.hasSuffix(".tar.xz") || lower.hasSuffix(".txz") { return "txz" }
        let value = (relativePath as NSString).pathExtension.lowercased()
        return value.isEmpty ? nil : value
    }

    /// Lists archive entries without extracting anything.
    public func listing(relativePath: String, rootURL: URL, cancellation: CancellationToken) async throws -> ArchiveBrowseListing {
        guard let format = Self.format(for: relativePath) else {
            throw ArchiveBrowseError.unsupportedFormat(
                format: "unknown",
                reason: "the file name has no archive extension this app recognises"
            )
        }
        guard Self.nativeFormats.contains(format) else {
            throw Self.unsupported(format: format)
        }
        let output = try await run(
            arguments: .init(action: "list", source: relativePath),
            rootURL: rootURL,
            cancellation: cancellation
        )
        return Self.parseListing(output.summary, format: format)
    }

    /// Extracts a native archive into a new directory inside the workspace.
    /// The tool refuses to overwrite an existing destination, rejects
    /// traversal/symlink entries and enforces its entry/size limits.
    public func extract(
        relativePath: String,
        destinationDir: String,
        rootURL: URL,
        cancellation: CancellationToken
    ) async throws -> String {
        guard let format = Self.format(for: relativePath) else {
            throw ArchiveBrowseError.unsupportedFormat(
                format: "unknown",
                reason: "the file name has no archive extension this app recognises"
            )
        }
        guard Self.nativeFormats.contains(format) else {
            throw Self.unsupported(format: format)
        }
        let output = try await run(
            arguments: .init(action: "extract", source: relativePath, destinationDir: destinationDir),
            rootURL: rootURL,
            cancellation: cancellation
        )
        return output.summary
    }

    /// Truthful reason for a format this surface deliberately does not open.
    static func unsupported(format: String) -> ArchiveBrowseError {
        if Self.compressedFormats.contains(format) {
            return .unsupportedFormat(
                format: format,
                reason: "compressed archives are handled by the environment's Linux runtime, which this read-only browser does not start"
            )
        }
        if Self.rarFormats.contains(format) {
            return .unsupportedFormat(format: format, reason: "RAR archives require the app's signed decoder")
        }
        return .unsupportedFormat(format: format, reason: "this archive format is not supported")
    }

    // MARK: - internals

    private func run(
        arguments: WorkspaceArchiveTool.Arguments,
        rootURL: URL,
        cancellation: CancellationToken
    ) async throws -> ToolExecutionOutput {
        let tool = WorkspaceArchiveTool(environment: environment)
        let context = ToolContext(
            runID: UUID(),
            scope: .local,
            workspaceRootURL: rootURL,
            cancellation: cancellation
        )
        do {
            return try await tool.execute(arguments, context: context)
        } catch let error as WorkspaceToolError {
            switch error {
            case .notFound:
                throw ArchiveBrowseError.notFound(arguments.source)
            default:
                throw ArchiveBrowseError.failed(error.localizedDescription)
            }
        } catch let error as ArchiveBrowseError {
            throw error
        } catch {
            throw ArchiveBrowseError.failed(error.localizedDescription)
        }
    }

    /// Parses the archive tool's bounded listing text:
    /// `status=ok action=list [format=7z] source=… entries=N truncated=B`
    /// followed by `kind\tsize\tpath` rows.
    static func parseListing(_ text: String, format: String) -> ArchiveBrowseListing {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var entries: [ArchiveBrowseEntry] = []
        var truncated = false
        for line in lines.dropFirst() {
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }
            let kind = String(fields[0])
            let size = Int64(fields[1]) ?? 0
            let path = String(fields[2])
            guard !path.isEmpty else { continue }
            entries.append(ArchiveBrowseEntry(path: path, isDirectory: kind == "dir", size: size))
        }
        if let header = lines.first, header.contains("truncated=true") { truncated = true }
        return ArchiveBrowseListing(
            format: format,
            entries: entries,
            truncated: truncated,
            summary: lines.first ?? ""
        )
    }
}
