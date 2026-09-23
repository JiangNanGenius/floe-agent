// FloeWorkspace — native archive engine.
//
// One bounded implementation for every archive operation the workspace needs:
//
//   create     zip · tar · tar.gz · tar.bz2 · tar.xz
//   extract    zip · tar · tar.gz · tar.bz2 · tar.xz
//   list       zip · tar · tar.gz · tar.bz2 · tar.xz
//   decompress gzip · bzip2 · xz (single file)
//
// 7z/RAR stay read-only in their own paths. No operation needs the task
// environment's Linux runtime: the compressed formats are produced and read
// by `ArchiveCodecs` on the host.
//
// Shared policy (identical across formats, so a tool caller cannot get a
// weaker bound through one extension):
//   * entry cap and total-uncompressed cap from `ArchiveLimits`
//   * the compressed decoders enforce that cap *while decoding* (before a
//     produced chunk is appended) and poll cancellation on the same path, so
//     an expansion bomb fails with bounded memory instead of being buffered
//     and rejected afterwards; bzip2 decompression is refused entirely
//     because its one-shot decoder cannot be bounded before allocation
//   * sanitized entry names; absolute paths, `..`, control characters and
//     backslash smuggling are skipped and counted
//   * existing outputs are never overwritten; writes are staged beside the
//     destination and committed with a single rename
//   * symlinks are preserved only when the target stays inside the staged
//     output; hard links are recreated when their target was extracted
//   * POSIX mode/mtime are applied best effort and every metadata item the
//     format cannot carry (uid/gid/xattrs/ACLs/device nodes, pax globals) is
//     reported in the summary instead of being dropped silently
//   * free space at the destination volume is checked against the declared
//     size before writing
//   * cooperative cancellation is polled per entry and per chunk
//   * progress is reported as bytes and entries

import Foundation
import ZIPFoundation
import SWCompression
import FloeCore
import FloeTools

// MARK: - Public types

public enum ArchiveEngineError: Error, LocalizedError, Equatable, Sendable {
    /// The container/format is not one this engine implements.
    case unsupportedFormat(String)
    /// The destination volume does not have room for the declared output.
    case insufficientSpace(required: Int64, available: Int64)
    /// The archive output would be inside its own input tree.
    case outputInsideSource(String)
    /// Two entries map to the same output path (or a file/directory clash).
    case conflict(String)
    /// The source is malformed, truncated or fails a checksum.
    case corrupt(String)
    /// The operation needs an unbuffered path this format cannot provide.
    case resourceBound(String)
    /// A bounded resource (entries/bytes) was exceeded.
    case limitExceeded(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let format):
            return "Unsupported archive format: \(format)"
        case .insufficientSpace(let required, let available):
            return "Not enough free space for this archive operation (needs \(required) bytes, \(available) available)"
        case .outputInsideSource(let path):
            return "The archive output would be written inside its own input: \(path)"
        case .conflict(let detail):
            return "Archive entry conflict: \(detail)"
        case .corrupt(let detail):
            return "Archive is corrupt or truncated: \(detail)"
        case .resourceBound(let detail):
            return detail
        case .limitExceeded(let detail):
            return "Archive limit exceeded: \(detail)"
        }
    }
}

public struct ArchiveLimits: Sendable, Equatable {
    public var maxEntries: Int
    public var maxTotalBytes: Int64
    public var maxListedEntries: Int
    /// One-shot buffering cap for the bzip2 *creation* paths (SWCompression
    /// compresses in memory). bzip2 decompression is refused entirely: its
    /// one-shot decoder cannot be bounded before it allocates, and a
    /// compressed-size cap would not bound the expansion.
    public var oneShotBufferLimit: Int

    public init(
        maxEntries: Int = 5_000,
        maxTotalBytes: Int64 = 256 * 1_024 * 1_024,
        maxListedEntries: Int = 500,
        oneShotBufferLimit: Int = 256 * 1_024 * 1_024
    ) {
        self.maxEntries = maxEntries
        self.maxTotalBytes = maxTotalBytes
        self.maxListedEntries = maxListedEntries
        self.oneShotBufferLimit = oneShotBufferLimit
    }
}

public struct ArchiveProgress: Sendable, Equatable {
    public enum Phase: String, Sendable {
        case scanning
        case writing
        case reading
    }

    public var phase: Phase
    public var completedBytes: Int64
    public var totalBytes: Int64?
    public var completedEntries: Int

    public init(phase: Phase, completedBytes: Int64, totalBytes: Int64?, completedEntries: Int) {
        self.phase = phase
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.completedEntries = completedEntries
    }
}

public struct ArchiveListedEntry: Sendable, Equatable {
    public var path: String
    public var isDirectory: Bool
    public var size: Int64

    public init(path: String, isDirectory: Bool, size: Int64) {
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
    }
}

public struct ArchiveListing: Sendable, Equatable {
    public var entries: [ArchiveListedEntry]
    public var truncated: Bool

    public init(entries: [ArchiveListedEntry], truncated: Bool) {
        self.entries = entries
        self.truncated = truncated
    }
}

public struct ArchiveOperationSummary: Sendable, Equatable {
    public var action: String
    public var format: String
    public var entries: Int
    public var skipped: Int
    public var uncompressedBytes: Int64
    /// Symlinks preserved (their targets stayed inside the output).
    public var linksPreserved: Int
    public var linksSkipped: Int
    /// Metadata items the format cannot carry (reported, never silent).
    public var metadataNotices: [String]
    /// Human-readable notes about the execution path (e.g. bzip2 buffering).
    public var notes: [String]

    public init(
        action: String,
        format: String,
        entries: Int,
        skipped: Int,
        uncompressedBytes: Int64,
        linksPreserved: Int = 0,
        linksSkipped: Int = 0,
        metadataNotices: [String] = [],
        notes: [String] = []
    ) {
        self.action = action
        self.format = format
        self.entries = entries
        self.skipped = skipped
        self.uncompressedBytes = uncompressedBytes
        self.linksPreserved = linksPreserved
        self.linksSkipped = linksSkipped
        self.metadataNotices = metadataNotices
        self.notes = notes
    }

    /// Machine-readable single line: the same fields the archive tool always
    /// returned plus the honest extras.
    public func line(source: String, destination: String?) -> String {
        var parts = ["status=ok", "action=\(action)", "format=\(format)", "source=\(source)"]
        if let destination { parts.append("destination=\(destination)") }
        parts.append("entries=\(entries)")
        if skipped > 0 { parts.append("skipped=\(skipped)") }
        parts.append("uncompressedBytes=\(uncompressedBytes)")
        if linksPreserved > 0 { parts.append("links=\(linksPreserved)") }
        if linksSkipped > 0 { parts.append("linksSkipped=\(linksSkipped)") }
        for notice in metadataNotices {
            parts.append("metadata=\(notice)")
        }
        for note in notes {
            parts.append("note=\(note)")
        }
        return parts.joined(separator: " ")
    }
}

private enum ArchiveFormatGroups {
    static let containers: Set<String> = ["zip", "tar", "tgz", "tbz2", "txz"]
    static let singleFile: Set<String> = ["gz", "bz2", "xz"]
    static let uncompressedContainer: Set<String> = ["zip", "tar"]
}

// MARK: - Engine

public enum ArchiveEngine {
    /// Container formats this engine writes and reads.
    public static let containerFormats: Set<String> = ArchiveFormatGroups.containers
    /// Single-file compression formats.
    public static let singleFileFormats: Set<String> = ArchiveFormatGroups.singleFile
    public static let allFormats: Set<String> = containerFormats.union(singleFileFormats)

    public typealias ProgressHandler = @Sendable (ArchiveProgress) -> Void

    // MARK: create

    /// Creates `destination` from one or more sources (the workspace
    /// multi-select default is zip). Entry names are each source's own last
    /// path component, so one directory `project/` yields `project/...`.
    public static func create(
        format: String,
        sources: [URL],
        destination: URL,
        limits: ArchiveLimits = ArchiveLimits(),
        progress: ProgressHandler? = nil,
        cancellation: CancellationToken
    ) throws -> ArchiveOperationSummary {
        guard allFormats.contains(format) else {
            throw ArchiveEngineError.unsupportedFormat(format)
        }
        guard !sources.isEmpty else {
            throw ArchiveEngineError.corrupt("no input was selected")
        }
        let destinationURL = destination.standardizedFileURL
        for source in sources {
            try rejectSelfContainment(destination: destinationURL, source: source)
        }
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw ArchiveEngineError.conflict("destination already exists: \(destinationURL.lastPathComponent)")
        }
        let plan = try scan(sources: sources, format: format, limits: limits, progress: progress, cancellation: cancellation)
        try ArchiveDiskSpace.require(
            plan.requiredCreateBytes,
            at: destinationURL.deletingLastPathComponent(),
            cancelling: cancellation
        )

        let staging = try stagingURL(for: destinationURL)
        defer { try? FileManager.default.removeItem(at: staging) }
        var summary: ArchiveOperationSummary
        switch format {
        case "zip":
            summary = try writeZip(plan: plan, staging: staging, limits: limits, progress: progress, cancellation: cancellation)
        case "tar":
            summary = try writeStreamingTar(plan: plan, compressor: nil, staging: staging, limits: limits, progress: progress, cancellation: cancellation)
        case "tgz":
            summary = try writeStreamingTar(plan: plan, compressor: .gzip, staging: staging, limits: limits, progress: progress, cancellation: cancellation)
        case "txz":
            summary = try writeStreamingTar(plan: plan, compressor: .xz, staging: staging, limits: limits, progress: progress, cancellation: cancellation)
        case "tbz2":
            summary = try writeBufferedTar(plan: plan, staging: staging, limits: limits, progress: progress, cancellation: cancellation)
        default: // gz · bz2 · xz: one file, not a container
            summary = try writeSingleFileCompressed(plan: plan, format: format, staging: staging, limits: limits, progress: progress, cancellation: cancellation)
        }
        // Sidecars skipped during the scan are part of the honest report.
        summary.skipped += plan.skippedNoise
        try commit(staging: staging, to: destinationURL)
        return summary
    }

    // MARK: extract

    public static func extract(
        format: String,
        source: URL,
        destination: URL,
        limits: ArchiveLimits = ArchiveLimits(),
        progress: ProgressHandler? = nil,
        cancellation: CancellationToken
    ) throws -> ArchiveOperationSummary {
        guard containerFormats.contains(format) else {
            if singleFileFormats.contains(format) {
                throw ArchiveEngineError.unsupportedFormat("\(format) is a single-file compression format; use decompress")
            }
            throw ArchiveEngineError.unsupportedFormat(format)
        }
        let destinationURL = destination.standardizedFileURL
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw ArchiveEngineError.conflict("destination already exists: \(destinationURL.lastPathComponent)")
        }
        let staging = try stagingURL(for: destinationURL)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)

        let summary: ArchiveOperationSummary
        do {
            switch format {
            case "zip":
                summary = try extractZip(source: source, staging: staging, limits: limits, progress: progress, cancellation: cancellation)
            default:
                summary = try extractTar(format: format, source: source, staging: staging, limits: limits, progress: progress, cancellation: cancellation)
            }
            try commit(staging: staging, to: destinationURL)
        } catch {
            throw Self.mappedArchivalError(error)
        }
        return summary
    }

    // MARK: list

    public static func list(
        format: String,
        source: URL,
        limits: ArchiveLimits = ArchiveLimits(),
        cancellation: CancellationToken
    ) throws -> ArchiveListing {
        try cancellation.throwIfCancelled()
        do {
            switch format {
            case "zip":
                return try listZip(source: source, limits: limits, cancellation: cancellation)
            case "tar", "tgz", "tbz2", "txz":
                return try listTar(format: format, source: source, limits: limits, cancellation: cancellation)
            case "gz", "bz2", "xz":
                // A single-file format has exactly one logical entry: the
                // decompressed payload. The name strips the compression suffix.
                return ArchiveListing(
                    entries: [ArchiveListedEntry(
                        path: Self.decompressedName(for: source.lastPathComponent, format: format),
                        isDirectory: false,
                        size: 0
                    )],
                    truncated: false
                )
            default:
                throw ArchiveEngineError.unsupportedFormat(format)
            }
        } catch {
            throw Self.mappedArchivalError(error)
        }
    }

    // MARK: decompress (single file)

    public static func decompress(
        format: String,
        source: URL,
        destination: URL,
        limits: ArchiveLimits = ArchiveLimits(),
        progress: ProgressHandler? = nil,
        cancellation: CancellationToken
    ) throws -> ArchiveOperationSummary {
        guard singleFileFormats.contains(format) else {
            throw ArchiveEngineError.unsupportedFormat("\(format) is not a single-file compression format")
        }
        let destinationURL = destination.standardizedFileURL
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw ArchiveEngineError.conflict("destination already exists: \(destinationURL.lastPathComponent)")
        }
        let staging = try stagingURL(for: destinationURL)
        defer { try? FileManager.default.removeItem(at: staging) }

        let sink = try FileByteSink(url: staging)
        var written: Int64 = 0
        let available = ArchiveDiskSpace.availableBytes(at: destinationURL.deletingLastPathComponent())
        let sourceSize = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) }
        try ArchiveDiskSpace.require(
            min(limits.maxTotalBytes, sourceSize ?? limits.maxTotalBytes),
            at: destinationURL.deletingLastPathComponent(),
            cancelling: cancellation
        )
        // The decoder enforces this budget *before* it hands a produced chunk
        // over, so a compressed bomb is refused with bounded memory instead of
        // being materialized and rejected afterwards.
        let budget = ArchiveDecodeBudget(maxOutputBytes: limits.maxTotalBytes, cancellation: cancellation)

        func emit(_ data: Data) throws {
            written += Int64(data.count)
            guard written <= limits.maxTotalBytes else {
                throw ArchiveEngineError.limitExceeded("decompressed output exceeds \(limits.maxTotalBytes) bytes")
            }
            if let available, written > available {
                throw ArchiveEngineError.insufficientSpace(required: written, available: available)
            }
            try sink.write(data)
            progress?(ArchiveProgress(phase: .reading, completedBytes: written, totalBytes: nil, completedEntries: 1))
        }

        do {
            switch format {
            case "gz":
                let decoded = try GzipDecodingSource(url: source, budget: budget)
                try pipe(source: decoded, emit: emit, cancellation: cancellation)
            case "xz":
                let verified = try VerifiedXZSource(source: FileByteSource(url: source), budget: budget)
                try pipe(source: verified, emit: emit, cancellation: cancellation)
            default:
                throw ArchiveEngineError.resourceBound(Bzip2Codec.decompressionUnsupported)
            }
            try sink.close()
        } catch {
            throw Self.mappedArchivalError(error)
        }
        try commit(staging: staging, to: destinationURL)
        return ArchiveOperationSummary(
            action: "decompress",
            format: format,
            entries: 1,
            skipped: 0,
            uncompressedBytes: written,
            metadataNotices: [],
            notes: []
        )
    }

    /// `notes.txt.gz` -> `notes.txt`; `archive.gz` -> `archive`.
    public static func decompressedName(for fileName: String, format: String) -> String {
        let suffix = "." + format
        guard fileName.lowercased().hasSuffix(suffix) else { return fileName + ".uncompressed" }
        let stem = String(fileName.dropLast(suffix.count))
        return stem.isEmpty ? "uncompressed" : stem
    }

    // MARK: - planning

    struct PlannedItem {
        var url: URL
        var entryName: String
        var isDirectory: Bool
        var isSymlink: Bool
        var linkTarget: String?
        var size: Int64
        var mode: Int
        var mtime: Date
    }

    struct Plan {
        var items: [PlannedItem]
        var totalBytes: Int64
        var requiredCreateBytes: Int64
        /// macOS AppleDouble sidecars (`._name`) found while scanning; they are
        /// resource-fork noise, never content, and are counted in the summary.
        var skippedNoise: Int
        var notes: [String]
    }

    private static func scan(
        sources: [URL],
        format: String,
        limits: ArchiveLimits,
        progress: ProgressHandler?,
        cancellation: CancellationToken
    ) throws -> Plan {
        var items: [PlannedItem] = []
        var total: Int64 = 0
        var names: Set<String> = []
        var skippedNoise = 0

        for source in sources {
            let sourceURL = source.standardizedFileURL.resolvingSymlinksInPath()
            let rootName = sourceURL.lastPathComponent
            guard !rootName.isEmpty, rootName != "/" else {
                throw ArchiveEngineError.corrupt("cannot derive an entry name from \(source.path)")
            }
            guard names.insert(rootName).inserted else {
                throw ArchiveEngineError.conflict("two selected items are both named \(rootName)")
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else {
                throw ArchiveEngineError.corrupt("input does not exist: \(source.lastPathComponent)")
            }
            if isDirectory.boolValue {
                items.append(try plannedItem(url: sourceURL, entryName: rootName, limits: limits, cancellation: cancellation))
                guard let enumerator = FileManager.default.enumerator(
                    at: sourceURL,
                    includingPropertiesForKeys: [
                        .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
                        .contentModificationDateKey
                    ],
                    options: []
                ) else {
                    throw ArchiveEngineError.corrupt("cannot enumerate \(source.lastPathComponent)")
                }
                for case let item as URL in enumerator {
                    try cancellation.throwIfCancelled()
                    if item.lastPathComponent.hasPrefix("._") {
                        // AppleDouble resource-fork sidecar: metadata noise,
                        // reported through the summary instead of archived.
                        skippedNoise += 1
                        continue
                    }
                    let relative = Self.relativeName(of: item.path, basePath: sourceURL.deletingLastPathComponent().path, sourceName: rootName)
                    let planned = try plannedItem(url: item, entryName: relative, limits: limits, cancellation: cancellation)
                    if !planned.isDirectory && !planned.isSymlink {
                        total += planned.size
                        guard total <= limits.maxTotalBytes else {
                            throw ArchiveEngineError.limitExceeded("expanded input exceeds \(limits.maxTotalBytes) bytes")
                        }
                    }
                    items.append(planned)
                    if items.count > limits.maxEntries {
                        throw ArchiveEngineError.limitExceeded("input has more than \(limits.maxEntries) entries")
                    }
                }
            } else {
                let planned = try plannedItem(url: sourceURL, entryName: rootName, limits: limits, cancellation: cancellation)
                total += planned.size
                guard total <= limits.maxTotalBytes else {
                    throw ArchiveEngineError.limitExceeded("expanded input exceeds \(limits.maxTotalBytes) bytes")
                }
                items.append(planned)
            }
            progress?(ArchiveProgress(phase: .scanning, completedBytes: total, totalBytes: nil, completedEntries: items.count))
        }

        // Uncompressed containers need room for roughly the whole payload;
        // compressed formats are checked against a smaller compression
        // estimate so a device that can hold the input can always produce a
        // compressed archive of it.
        let required = ArchiveFormatGroups.uncompressedContainer.contains(format)
            ? total
            : min(total, 32 * 1_024 * 1_024)
        return Plan(items: items, totalBytes: total, requiredCreateBytes: required, skippedNoise: skippedNoise, notes: [])
    }

    private static func plannedItem(
        url: URL,
        entryName: String,
        limits: ArchiveLimits,
        cancellation: CancellationToken
    ) throws -> PlannedItem {
        try cancellation.throwIfCancelled()
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
            .contentModificationDateKey
        ])
        let isSymlink = values.isSymbolicLink == true
        let isDirectory = values.isDirectory == true && !isSymlink
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let mode = (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? (isDirectory ? 0o755 : 0o644)
        let mtime = values.contentModificationDate ?? Date()
        var linkTarget: String?
        if isSymlink {
            linkTarget = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        }
        var size: Int64 = 0
        if !isDirectory && !isSymlink {
            size = Int64(values.fileSize ?? 0)
            guard size <= limits.maxTotalBytes else {
                throw ArchiveEngineError.limitExceeded("single input exceeds \(limits.maxTotalBytes) bytes")
            }
        }
        return PlannedItem(
            url: url,
            entryName: entryName,
            isDirectory: isDirectory,
            isSymlink: isSymlink,
            linkTarget: linkTarget,
            size: size,
            mode: mode,
            mtime: mtime
        )
    }

    // MARK: - zip

    private static func writeZip(
        plan: Plan,
        staging: URL,
        limits: ArchiveLimits,
        progress: ProgressHandler?,
        cancellation: CancellationToken
    ) throws -> ArchiveOperationSummary {
        let archive: ZIPFoundation.Archive
        do {
            archive = try ZIPFoundation.Archive(url: staging, accessMode: .create)
        } catch {
            throw ArchiveEngineError.corrupt("could not create the zip archive: \(error)")
        }
        var entries = 0
        var written: Int64 = 0
        var links = 0
        var linksSkipped = 0
        var skipped = 0
        for item in plan.items {
            try cancellation.throwIfCancelled()
            let nsProgress = TokenProgress(token: cancellation)
            do {
                if item.isSymlink {
                    guard item.linkTarget != nil else {
                        skipped += 1
                        continue
                    }
                    try archive.addEntry(with: item.entryName, fileURL: item.url, compressionMethod: .none, progress: nsProgress)
                    links += 1
                    continue
                }
                if item.isDirectory {
                    try archive.addEntry(with: item.entryName, fileURL: item.url, compressionMethod: .none, progress: nsProgress)
                    continue
                }
                guard entries < limits.maxEntries else {
                    throw ArchiveEngineError.limitExceeded("more than \(limits.maxEntries) entries")
                }
                try archive.addEntry(with: item.entryName, fileURL: item.url, compressionMethod: .deflate, progress: nsProgress)
                entries += 1
                written += item.size
                progress?(ArchiveProgress(phase: .writing, completedBytes: written, totalBytes: plan.totalBytes, completedEntries: entries))
            } catch let error as ZIPFoundation.Archive.ArchiveError where error == .cancelledOperation {
                throw FloeError.cancelled
            } catch let error as ZIPFoundation.Archive.ArchiveError {
                throw ArchiveEngineError.corrupt("zip write failed: \(error)")
            }
        }
        // zip cannot carry hard links, device nodes, uid/gid or xattrs.
        var notices = ["zipCarriesModeMtimeOnly", "uidGidNotPreserved"]
        if plan.items.contains(where: { $0.isSymlink }) { notices.append("zipSymlinksUnixOnly") }
        if linksSkipped > 0 { notices.append("unwritableLinksSkipped") }
        return ArchiveOperationSummary(
            action: "create",
            format: "zip",
            entries: entries,
            skipped: skipped,
            uncompressedBytes: written,
            linksPreserved: links,
            linksSkipped: linksSkipped,
            metadataNotices: notices
        )
    }

    private static func extractZip(
        source: URL,
        staging: URL,
        limits: ArchiveLimits,
        progress: ProgressHandler?,
        cancellation: CancellationToken
    ) throws -> ArchiveOperationSummary {
        let archive: ZIPFoundation.Archive
        do {
            archive = try ZIPFoundation.Archive(url: source, accessMode: .read)
        } catch {
            throw ArchiveEngineError.corrupt("source is not a readable zip archive")
        }
        var entries = 0
        var skipped = 0
        var links = 0
        var linksSkipped = 0
        var unsupportedMetadata = 0
        var total: Int64 = 0
        var duplicate: Set<String> = []
        var directories: [(URL, Int, Date?)] = []
        let available = ArchiveDiskSpace.availableBytes(at: staging)
        for entry in archive {
            try cancellation.throwIfCancelled()
            guard let name = try safeEntryName(entry.path, isDirectory: entry.type == .directory) else {
                skipped += 1
                continue
            }
            switch entry.type {
            case .directory:
                let target = staging.appendingPathComponent(name, isDirectory: true)
                guard isContained(target, in: staging), duplicate.insert(name.lowercased() + "/").inserted else {
                    skipped += 1
                    continue
                }
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                directories.append((
                    target,
                    Int((entry.fileAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o755),
                    entry.fileAttributes[.modificationDate] as? Date
                ))
            case .symlink:
                guard entries < limits.maxEntries else {
                    throw ArchiveEngineError.limitExceeded("more than \(limits.maxEntries) entries")
                }
                let target = staging.appendingPathComponent(name)
                guard isContained(target, in: staging), duplicate.insert(name.lowercased()).inserted else {
                    skipped += 1
                    continue
                }
                let linkData = try readZipEntry(entry, archive: archive, limit: 4096)
                guard let linkTarget = String(data: linkData, encoding: .utf8),
                      isSafeLinkTarget(linkTarget, relativeTo: target.deletingLastPathComponent(), root: staging) else {
                    linksSkipped += 1
                    skipped += 1
                    continue
                }
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: linkTarget)
                links += 1
            case .file:
                guard entries < limits.maxEntries else {
                    throw ArchiveEngineError.limitExceeded("more than \(limits.maxEntries) entries")
                }
                total += Int64(entry.uncompressedSize)
                guard total <= limits.maxTotalBytes else {
                    throw ArchiveEngineError.limitExceeded("expanded output exceeds \(limits.maxTotalBytes) bytes")
                }
                if let available, total > available {
                    throw ArchiveEngineError.insufficientSpace(required: total, available: available)
                }
                let target = staging.appendingPathComponent(name)
                guard isContained(target, in: staging), duplicate.insert(name.lowercased()).inserted else {
                    skipped += 1
                    continue
                }
                guard !FileManager.default.fileExists(atPath: target.path) else {
                    throw ArchiveEngineError.conflict("two entries map to \(name)")
                }
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let nsProgress = TokenProgress(token: cancellation)
                do {
                    _ = try archive.extract(entry, to: target, skipCRC32: false, progress: nsProgress)
                } catch let error as ZIPFoundation.Archive.ArchiveError where error == .cancelledOperation {
                    throw FloeError.cancelled
                } catch let error as ZIPFoundation.Archive.ArchiveError {
                    throw ArchiveEngineError.corrupt("zip entry \(name) failed: \(error)")
                }
                applyMode(entry.fileAttributes[.posixPermissions] as? NSNumber, to: target)
                if let date = entry.fileAttributes[.modificationDate] as? Date {
                    try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: target.path)
                }
                entries += 1
                progress?(ArchiveProgress(phase: .reading, completedBytes: total, totalBytes: nil, completedEntries: entries))
            @unknown default:
                unsupportedMetadata += 1
                skipped += 1
            }
        }
        for (url, mode, date) in directories.reversed() {
            applyMode(NSNumber(value: mode), to: url)
            if let date { try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path) }
        }
        var notices = ["zipCarriesModeMtimeOnly"]
        if unsupportedMetadata > 0 { notices.append("unsupportedZipEntrySkipped") }
        return ArchiveOperationSummary(
            action: "extract",
            format: "zip",
            entries: entries,
            skipped: skipped,
            uncompressedBytes: total,
            linksPreserved: links,
            linksSkipped: linksSkipped,
            metadataNotices: notices
        )
    }

    private static func readZipEntry(_ entry: ZIPFoundation.Entry, archive: ZIPFoundation.Archive, limit: Int) throws -> Data {
        guard Int64(entry.uncompressedSize) <= Int64(limit) else {
            throw ArchiveEngineError.limitExceeded("zip entry is too large to inspect")
        }
        var data = Data()
        _ = try archive.extract(entry, skipCRC32: false) { chunk in
            data.append(chunk)
        }
        return data
    }

    private static func listZip(source: URL, limits: ArchiveLimits, cancellation: CancellationToken) throws -> ArchiveListing {
        let archive: ZIPFoundation.Archive
        do {
            archive = try ZIPFoundation.Archive(url: source, accessMode: .read)
        } catch {
            throw ArchiveEngineError.corrupt("source is not a readable zip archive")
        }
        var entries: [ArchiveListedEntry] = []
        var truncated = false
        for entry in archive {
            try cancellation.throwIfCancelled()
            if entries.count >= limits.maxListedEntries {
                truncated = true
                break
            }
            entries.append(ArchiveListedEntry(
                path: entry.path,
                isDirectory: entry.type == .directory,
                size: entry.type == .directory ? 0 : Int64(entry.uncompressedSize)
            ))
        }
        return ArchiveListing(entries: entries, truncated: truncated)
    }

    // MARK: - tar (streaming)

    private enum TarCompressor {
        case gzip
        case xz
    }

    private static func writeStreamingTar(
        plan: Plan,
        compressor: TarCompressor?,
        staging: URL,
        limits: ArchiveLimits,
        progress: ProgressHandler?,
        cancellation: CancellationToken
    ) throws -> ArchiveOperationSummary {
        let fileSink = try FileByteSink(url: staging)
        var gzipSink: GzipByteSink?
        var xzSink: XZByteSink?
        switch compressor {
        case .gzip:
            gzipSink = try GzipByteSink(sink: fileSink)
        case .xz:
            xzSink = try XZByteSink(sink: fileSink)
        case nil:
            break
        }
        let sink: ArchiveByteSink
        if let gzipSink {
            sink = gzipSink
        } else if let xzSink {
            sink = xzSink
        } else {
            sink = fileSink
        }
        var writer = TarStreamWriter(sink: sink)
        var summary = try tarWriteItems(plan: plan, writer: &writer, limits: limits, progress: progress, cancellation: cancellation)
        try writer.finish()
        if let gzipSink { try gzipSink.finish() }
        if let xzSink { try xzSink.finish() }
        try fileSink.close()
        summary.format = compressor == .gzip ? "tgz" : (compressor == .xz ? "txz" : "tar")
        return summary
    }

    /// gzip/bzip2/xz compress exactly one regular file into one output file.
    private static func writeSingleFileCompressed(
        plan: Plan,
        format: String,
        staging: URL,
        limits: ArchiveLimits,
        progress: ProgressHandler?,
        cancellation: CancellationToken
    ) throws -> ArchiveOperationSummary {
        guard plan.items.count == 1, let item = plan.items.first,
              !item.isDirectory, !item.isSymlink else {
            throw ArchiveEngineError.unsupportedFormat("\(format) compresses a single file; use zip/tar for multiple items")
        }
        let fileSink = try FileByteSink(url: staging)
        defer { try? fileSink.close() }
        let source = try FileByteSource(url: item.url)
        var written: Int64 = 0
        var notes: [String] = []

        func pump(_ sink: ArchiveByteSink) throws {
            while let chunk = try source.read(max: 256 * 1_024), !chunk.isEmpty {
                try cancellation.throwIfCancelled()
                try sink.write(chunk)
                written += Int64(chunk.count)
                progress?(ArchiveProgress(phase: .writing, completedBytes: written, totalBytes: item.size, completedEntries: 1))
            }
        }

        switch format {
        case "gz":
            let sink = try GzipByteSink(sink: fileSink)
            try pump(sink)
            try sink.finish()
        case "xz":
            let sink = try XZByteSink(sink: fileSink)
            try pump(sink)
            try sink.finish()
        default: // bz2
            var raw = Data()
            while let chunk = try source.read(max: 256 * 1_024), !chunk.isEmpty {
                try cancellation.throwIfCancelled()
                raw.append(chunk)
                guard raw.count <= limits.oneShotBufferLimit else {
                    throw ArchiveEngineError.limitExceeded("bzip2 cannot buffer inputs over \(limits.oneShotBufferLimit) bytes")
                }
            }
            let compressed = try Bzip2Codec.compress(raw, limit: limits.oneShotBufferLimit)
            try fileSink.write(compressed)
            written = Int64(raw.count)
            notes.append("bzip2Buffered")
        }
        return ArchiveOperationSummary(
            action: "create",
            format: format,
            entries: 1,
            skipped: 0,
            uncompressedBytes: written,
            metadataNotices: ["compressionCarriesNoMetadata"],
            notes: notes
        )
    }

    private static func writeBufferedTar(
        plan: Plan,
        staging: URL,
        limits: ArchiveLimits,
        progress: ProgressHandler?,
        cancellation: CancellationToken
    ) throws -> ArchiveOperationSummary {        let buffer = DataByteSink()
        var writer = TarStreamWriter(sink: buffer)
        var summary = try tarWriteItems(plan: plan, writer: &writer, limits: limits, progress: progress, cancellation: cancellation)
        try writer.finish()
        let compressed = try Bzip2Codec.compress(buffer.data, limit: limits.oneShotBufferLimit)
        try compressed.write(to: staging, options: .atomic)
        summary.format = "tbz2"
        summary.notes.append("bzip2Buffered")
        return summary
    }

    private static func tarWriteItems(
        plan: Plan,
        writer: inout TarStreamWriter,
        limits: ArchiveLimits,
        progress: ProgressHandler?,
        cancellation: CancellationToken
    ) throws -> ArchiveOperationSummary {
        var entries = 0
        var written: Int64 = 0
        var links = 0
        var linksSkipped = 0
        var skipped = 0
        for item in plan.items {
            try cancellation.throwIfCancelled()
            if item.isDirectory {
                try writer.addDirectory(name: item.entryName, mode: item.mode, mtime: item.mtime)
                continue
            }
            if item.isSymlink {
                guard let target = item.linkTarget else {
                    skipped += 1
                    continue
                }
                try writer.addSymlink(name: item.entryName, target: target, mode: item.mode, mtime: item.mtime)
                links += 1
                continue
            }
            guard entries < limits.maxEntries else {
                throw ArchiveEngineError.limitExceeded("more than \(limits.maxEntries) entries")
            }
            let itemURL = item.url
            try writer.addFile(
                name: item.entryName,
                size: item.size,
                mode: item.mode,
                mtime: item.mtime,
                onChunk: { chunk in
                    try cancellation.throwIfCancelled()
                    written += Int64(chunk.count)
                    progress?(ArchiveProgress(phase: .writing, completedBytes: written, totalBytes: plan.totalBytes, completedEntries: entries))
                },
                from: { try FileByteSource(url: itemURL) }
            )
            entries += 1
        }
        return ArchiveOperationSummary(
            action: "create",
            format: "tar",
            entries: entries,
            skipped: skipped,
            uncompressedBytes: written,
            linksPreserved: links,
            linksSkipped: linksSkipped,
            metadataNotices: ["tarCarriesModeMtimeSymlinks", "uidGidNotPreserved", "xattrsACLsNotCarried"]
        )
    }

    private static func extractTar(
        format: String,
        source: URL,
        staging: URL,
        limits: ArchiveLimits,
        progress: ProgressHandler?,
        cancellation: CancellationToken
    ) throws -> ArchiveOperationSummary {
        let budget = ArchiveDecodeBudget(maxOutputBytes: tarStreamBudget(limits), cancellation: cancellation)
        let reader: TarStreamReader
        let checkCancellation: () throws -> Void = { try cancellation.throwIfCancelled() }
        switch format {
        case "tgz":
            reader = try TarStreamReader(
                source: try GzipDecodingSource(url: source, budget: budget),
                checkCancellation: checkCancellation
            )
        case "txz":
            reader = try TarStreamReader(
                source: try VerifiedXZSource(source: FileByteSource(url: source), budget: budget),
                checkCancellation: checkCancellation
            )
        case "tbz2":
            throw ArchiveEngineError.resourceBound(Bzip2Codec.decompressionUnsupported)
        default:
            reader = try TarStreamReader(source: FileByteSource(url: source), checkCancellation: checkCancellation)
        }
        var entries = 0
        var skipped = 0
        var links = 0
        var linksSkipped = 0
        var unsupportedEntries = 0
        var total: Int64 = 0
        var duplicate: Set<String> = []
        var directories: [(URL, Int, Int)] = []
        let available = ArchiveDiskSpace.availableBytes(at: staging)

        while let header = try reader.next() {
            try cancellation.throwIfCancelled()
            switch header.kind {
            case .paxHeader, .gnuLongName, .gnuLongLink:
                try reader.skipPayload()
                continue
            case .unknown:
                unsupportedEntries += 1
                skipped += 1
                try reader.skipPayload()
                continue
            case .directory:
                guard var name = try safeEntryName(header.name, isDirectory: true) else {
                    skipped += 1
                    try reader.skipPayload()
                    continue
                }
                name = name.hasSuffix("/") ? String(name.dropLast()) : name
                guard !name.isEmpty else {
                    skipped += 1
                    try reader.skipPayload()
                    continue
                }
                let target = staging.appendingPathComponent(name, isDirectory: true)
                guard isContained(target, in: staging), duplicate.insert(name.lowercased() + "/").inserted else {
                    skipped += 1
                    try reader.skipPayload()
                    continue
                }
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                directories.append((target, header.mode, header.mtime))
                try reader.skipPayload()
            case .symlink:
                guard let name = try safeEntryName(header.name, isDirectory: false) else {
                    skipped += 1
                    try reader.skipPayload()
                    continue
                }
                let target = staging.appendingPathComponent(name)
                guard isContained(target, in: staging), duplicate.insert(name.lowercased()).inserted else {
                    skipped += 1
                    try reader.skipPayload()
                    continue
                }
                guard let linkTarget = header.linkTarget,
                      isSafeLinkTarget(linkTarget, relativeTo: target.deletingLastPathComponent(), root: staging) else {
                    linksSkipped += 1
                    skipped += 1
                    try reader.skipPayload()
                    continue
                }
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: linkTarget)
                links += 1
                try reader.skipPayload()
            case .hardlink:
                guard let name = try safeEntryName(header.name, isDirectory: false),
                      let linkTarget = header.linkTarget else {
                    skipped += 1
                    try reader.skipPayload()
                    continue
                }
                let target = staging.appendingPathComponent(name)
                let sourceTarget = staging.appendingPathComponent(linkTarget)
                guard isContained(target, in: staging), isContained(sourceTarget, in: staging),
                      duplicate.insert(name.lowercased()).inserted else {
                    skipped += 1
                    try reader.skipPayload()
                    continue
                }
                try reader.skipPayload()
                guard FileManager.default.fileExists(atPath: sourceTarget.path) else {
                    linksSkipped += 1
                    skipped += 1
                    continue
                }
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                do {
                    try FileManager.default.linkItem(at: sourceTarget, to: target)
                    links += 1
                } catch {
                    linksSkipped += 1
                    skipped += 1
                }
            case .file:
                guard entries < limits.maxEntries else {
                    throw ArchiveEngineError.limitExceeded("more than \(limits.maxEntries) entries")
                }
                guard let name = try safeEntryName(header.name, isDirectory: false) else {
                    skipped += 1
                    try reader.skipPayload()
                    continue
                }
                // A crafted header can declare a size near Int64.max; add with
                // overflow detection so a malformed archive cannot trap.
                let (newTotal, overflowed) = total.addingReportingOverflow(header.size)
                guard !overflowed, newTotal <= limits.maxTotalBytes else {
                    throw ArchiveEngineError.limitExceeded("expanded output exceeds \(limits.maxTotalBytes) bytes")
                }
                total = newTotal
                if let available, total > available {
                    throw ArchiveEngineError.insufficientSpace(required: total, available: available)
                }
                let target = staging.appendingPathComponent(name)
                guard isContained(target, in: staging), duplicate.insert(name.lowercased()).inserted else {
                    skipped += 1
                    try reader.skipPayload()
                    continue
                }
                guard !FileManager.default.fileExists(atPath: target.path) else {
                    throw ArchiveEngineError.conflict("two entries map to \(name)")
                }
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let sink = try FileByteSink(url: target)
                var remaining = header.size
                while remaining > 0 {
                    let chunk = try reader.readPayload(max: Int(min(remaining, 256 * 1_024)))
                    guard !chunk.isEmpty else { throw ArchiveEngineError.corrupt("tar entry \(name) is truncated") }
                    try cancellation.throwIfCancelled()
                    try sink.write(chunk)
                    remaining -= Int64(chunk.count)
                }
                try reader.finishPayload()
                try sink.close()
                applyMode(NSNumber(value: header.mode), to: target)
                if header.mtime > 0 {
                    try? FileManager.default.setAttributes(
                        [.modificationDate: Date(timeIntervalSince1970: TimeInterval(header.mtime))],
                        ofItemAtPath: target.path
                    )
                }
                entries += 1
                progress?(ArchiveProgress(phase: .reading, completedBytes: total, totalBytes: nil, completedEntries: entries))
            }
        }
        for (url, mode, mtime) in directories.reversed() {
            applyMode(NSNumber(value: mode), to: url)
            if mtime > 0 {
                try? FileManager.default.setAttributes(
                    [.modificationDate: Date(timeIntervalSince1970: TimeInterval(mtime))],
                    ofItemAtPath: url.path
                )
            }
        }
        var notices = ["tarCarriesModeMtimeSymlinks", "uidGidNotPreserved"]
        if unsupportedEntries > 0 { notices.append("unsupportedTarEntrySkipped") }
        if reader.sawGlobalPaxHeader { notices.append("globalPaxHeaderRecordsIgnored") }
        return ArchiveOperationSummary(
            action: "extract",
            format: format,
            entries: entries,
            skipped: skipped,
            uncompressedBytes: total,
            linksPreserved: links,
            linksSkipped: linksSkipped,
            metadataNotices: notices,
            notes: []
        )
    }

    private static func listTar(
        format: String,
        source: URL,
        limits: ArchiveLimits,
        cancellation: CancellationToken
    ) throws -> ArchiveListing {
        let budget = ArchiveDecodeBudget(maxOutputBytes: tarStreamBudget(limits), cancellation: cancellation)
        let checkCancellation: () throws -> Void = { try cancellation.throwIfCancelled() }
        let reader: TarStreamReader
        switch format {
        case "tgz":
            reader = try TarStreamReader(
                source: try GzipDecodingSource(url: source, budget: budget),
                checkCancellation: checkCancellation
            )
        case "txz":
            reader = try TarStreamReader(
                source: try VerifiedXZSource(source: FileByteSource(url: source), budget: budget),
                checkCancellation: checkCancellation
            )
        case "tbz2":
            throw ArchiveEngineError.resourceBound(Bzip2Codec.decompressionUnsupported)
        default:
            reader = try TarStreamReader(source: FileByteSource(url: source), checkCancellation: checkCancellation)
        }
        var entries: [ArchiveListedEntry] = []
        var truncated = false
        while let header = try reader.next() {
            try cancellation.throwIfCancelled()
            if header.kind == .paxHeader || header.kind == .gnuLongName || header.kind == .gnuLongLink {
                try reader.skipPayload()
                continue
            }
            try reader.skipPayload()
            if entries.count >= limits.maxListedEntries {
                truncated = true
                break
            }
            entries.append(ArchiveListedEntry(
                path: header.name,
                isDirectory: header.kind == .directory,
                size: header.kind == .file ? header.size : 0
            ))
        }
        return ArchiveListing(entries: entries, truncated: truncated)
    }

    // MARK: - helpers

    /// Copies a byte source through the progress/cancel hooks.
    private static func pipe(
        source: ArchiveByteSource,
        emit: (Data) throws -> Void,
        cancellation: CancellationToken
    ) throws {
        while let chunk = try source.read(max: 256 * 1_024), !chunk.isEmpty {
            try cancellation.throwIfCancelled()
            try emit(chunk)
        }
    }

    /// The decode budget for a tar *container* stream. The tar framing
    /// (512-byte headers, padding, pax records, end marker) sits on top of the
    /// file payloads, so the decompressed-stream cap gets a fixed allowance;
    /// the file payload bytes themselves stay capped by `maxTotalBytes` inside
    /// the extraction loop.
    static func tarStreamBudget(_ limits: ArchiveLimits) -> Int64 {
        // Saturating arithmetic: `ArchiveLimits` is caller-supplied, so the
        // budget computation must not be able to overflow or trap.
        let entries = Int64(min(max(limits.maxEntries, 0), 1_000_000))
        let base = min(max(limits.maxTotalBytes, 0), Int64.max - 2 * 1_024 * 1_024 * 1_024)
        return base + entries * 1_024 + 1_024 * 1_024
    }

    /// Maps codec/tar layer failures onto the engine's public error surface.
    /// Engine errors and cancellation pass through unchanged.
    static func mappedArchivalError(_ error: Error) -> Error {
        if error is ArchiveEngineError || error is FloeError { return error }
        if let codec = error as? ArchiveCodecError {
            switch codec {
            case .limitExceeded(let detail):
                return ArchiveEngineError.limitExceeded(detail)
            case .corrupt(let detail):
                return ArchiveEngineError.corrupt(detail)
            case .unsupported(let detail), .codecUnavailable(let detail):
                return ArchiveEngineError.resourceBound(detail)
            }
        }
        if let tar = error as? TarStreamError {
            switch tar {
            case .malformed(let detail), .truncated(let detail):
                return ArchiveEngineError.corrupt(detail)
            case .nameTooLong(let name):
                return ArchiveEngineError.corrupt("tar entry name is too long: \(name)")
            case .checksumMismatch:
                return ArchiveEngineError.corrupt("tar header checksum mismatch")
            }
        }
        return error
    }

    /// `project/a.txt` for the enumerator item under `project`, robust to
    /// /var vs /private/var temp-root differences.
    static func relativeName(of itemPath: String, basePath: String, sourceName: String) -> String {
        if itemPath.hasPrefix(basePath + "/") {
            return String(itemPath.dropFirst(basePath.count + 1))
        }
        let marker = "/" + sourceName + "/"
        if let range = itemPath.range(of: marker, options: .backwards) {
            return sourceName + "/" + itemPath[range.upperBound...]
        }
        return URL(fileURLWithPath: itemPath).lastPathComponent
    }

    /// Sanitizes one entry name. Returns nil when the entry must be skipped:
    /// absolute paths, `~`, `..`, colon/backslash smuggling, control
    /// characters and AppleDouble sidecars are all rejected.
    static func safeEntryName(_ raw: String, isDirectory: Bool) throws -> String? {
        let normalized = raw.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty,
              !normalized.hasPrefix("/"),
              !normalized.hasPrefix("~"),
              !normalized.contains(":"),
              !normalized.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        var parts: [String] = []
        for component in normalized.split(separator: "/", omittingEmptySubsequences: true) {
            let piece = String(component)
            if piece == "." { continue }
            guard piece != ".." else { return nil }
            parts.append(piece)
        }
        guard !parts.isEmpty else { return nil }
        if let base = parts.last, base.hasPrefix("._") { return nil }
        let name = parts.joined(separator: "/")
        return isDirectory ? name + "/" : name
    }

    static func isContained(_ candidate: URL, in root: URL) -> Bool {
        let base = root.standardizedFileURL.path
        let path = candidate.standardizedFileURL.path
        return path.hasPrefix(base + "/")
    }

    /// A symlink is preserved only when its target resolves inside the
    /// extraction root (no absolute targets, no `..` escapes).
    static func isSafeLinkTarget(_ target: String, relativeTo directory: URL, root: URL) -> Bool {
        guard !target.isEmpty, !target.hasPrefix("/"), !target.hasPrefix("~"), !target.contains(":") else {
            return false
        }
        let resolved = directory.appendingPathComponent(target).standardizedFileURL
        return isContained(resolved, in: root)
    }

    static func applyMode(_ permissions: NSNumber?, to url: URL) {
        guard let permissions else { return }
        let mode = mode_t(permissions.intValue & 0o7777)
        guard mode != 0 else { return }
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: url.path)
    }

    static func rejectSelfContainment(destination: URL, source: URL) throws {
        let sourcePath = source.standardizedFileURL.path
        let destinationPath = destination.standardizedFileURL.path
        if destinationPath == sourcePath || destinationPath.hasPrefix(sourcePath + "/") {
            throw ArchiveEngineError.outputInsideSource(destinationPath)
        }
    }

    /// Staging file/directory beside the destination so the final commit is a
    /// same-volume rename and a failure never leaves a partial output.
    static func stagingURL(for destination: URL) throws -> URL {
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".floe-archive-\(UUID().uuidString).partial")
        try? FileManager.default.removeItem(at: staging)
        return staging
    }

    static func commit(staging: URL, to destination: URL) throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ArchiveEngineError.conflict("destination already exists: \(destination.lastPathComponent)")
        }
        try FileManager.default.moveItem(at: staging, to: destination)
    }
}

// MARK: - Disk space

enum ArchiveDiskSpace {
    static func availableBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    static func require(_ required: Int64, at url: URL, cancelling cancellation: CancellationToken) throws {
        try cancellation.throwIfCancelled()
        guard required > 0 else { return }
        guard let available = availableBytes(at: url) else { return }
        guard available >= required else {
            throw ArchiveEngineError.insufficientSpace(required: required, available: available)
        }
    }
}

// MARK: - Progress bridge

/// Reflects a `CancellationToken` into the `Progress` object ZIPFoundation
/// polls, so cancelling the token aborts an in-flight zip entry.
final class TokenProgress: Progress, @unchecked Sendable {
    private let token: CancellationToken

    init(token: CancellationToken) {
        self.token = token
        super.init(parent: nil, userInfo: nil)
        self.totalUnitCount = 0
    }

    override var isCancelled: Bool { token.isCancelled }
}

// MARK: - Compressing sinks

/// Wraps a byte sink in a gzip writer (tar.gz streaming).
final class GzipByteSink: ArchiveByteSink {
    private let writer: GzipArchiveWriter

    init(sink: ArchiveByteSink) throws {
        self.writer = try GzipArchiveWriter { try sink.write($0) }
    }

    func write(_ data: Data) throws {
        try writer.write(data)
    }

    func finish() throws {
        try writer.finish()
    }
}

/// Wraps a byte sink in an xz writer (tar.xz streaming).
final class XZByteSink: ArchiveByteSink {
    private let writer: XZArchiveWriter

    init(sink: ArchiveByteSink) throws {
        self.writer = try XZArchiveWriter { try sink.write($0) }
    }

    func write(_ data: Data) throws {
        try writer.write(data)
    }

    func finish() throws {
        try writer.finish()
    }
}
