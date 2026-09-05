// FloeWorkspace — File service shared by agent tools and the inspector.
// See docs/ARCHITECTURE_AGENT_WORKSPACE.md §3/§6: every operation resolves
// through `WorkspacePathGuard`, honors cooperative cancellation, and enforces
// the output limits in the §6 tool table (≤200 entries/page, ≤64 KiB reads,
// ≤100 search hits with ≤200-character context, mtime+sha256 write-conflict
// detection, unified-diff subset for patches).

import Foundation
import Crypto
import FloeCore
import FloeTools

/// One entry in a directory listing.
public struct FileNode: Sendable, Equatable {
    public var name: String
    public var relativePath: String
    public var isDirectory: Bool
    public var size: Int64

    public init(name: String, relativePath: String, isDirectory: Bool, size: Int64) {
        self.name = name
        self.relativePath = relativePath
        self.isDirectory = isDirectory
        self.size = size
    }
}

/// One page of a lazy directory listing.
public struct DirectoryPage: Sendable, Equatable {
    public var entries: [FileNode]
    /// Opaque cursor for the next page; nil when the listing is exhausted.
    public var nextPageToken: String?

    public init(entries: [FileNode], nextPageToken: String?) {
        self.entries = entries
        self.nextPageToken = nextPageToken
    }
}

/// Result of a bounded file read.
public struct FileContent: Sendable, Equatable {
    public var text: String
    /// True when the file continues past the returned window.
    public var truncated: Bool
    /// Total number of lines in the file (always reported, even when the
    /// window is truncated).
    public var totalLines: Int
    /// Byte offset of the returned window within the file.
    public var byteOffset: Int

    public init(text: String, truncated: Bool, totalLines: Int, byteOffset: Int) {
        self.text = text
        self.truncated = truncated
        self.totalLines = totalLines
        self.byteOffset = byteOffset
    }
}

/// One search hit with bounded context.
public struct SearchHit: Sendable, Equatable {
    public var relativePath: String
    public var lineNumber: Int
    /// Matching line trimmed to ≤200 characters.
    public var context: String

    public init(relativePath: String, lineNumber: Int, context: String) {
        self.relativePath = relativePath
        self.lineNumber = lineNumber
        self.context = context
    }
}

/// Outcome of a successful write.
public struct WriteOutcome: Sendable, Equatable {
    public var bytesWritten: Int
    public var sha256: String
    /// File modification date after the write (seconds since 1970).
    public var mtime: Double

    public init(bytesWritten: Int, sha256: String, mtime: Double) {
        self.bytesWritten = bytesWritten
        self.sha256 = sha256
        self.mtime = mtime
    }
}

/// Outcome of a successfully applied patch.
public struct PatchOutcome: Sendable, Equatable {
    public var hunksApplied: Int
    public var linesAdded: Int
    public var linesRemoved: Int
    public var sha256: String

    public init(hunksApplied: Int, linesAdded: Int, linesRemoved: Int, sha256: String) {
        self.hunksApplied = hunksApplied
        self.linesAdded = linesAdded
        self.linesRemoved = linesRemoved
        self.sha256 = sha256
    }
}

/// File metadata snapshot.
public struct WorkspaceFileMetadata: Sendable, Equatable {
    public var relativePath: String
    public var size: Int64
    /// Modification date, seconds since 1970.
    public var mtime: Double
    /// Uniform Type Identifier, best effort.
    public var uti: String
    public var sha256: String
    public var isSymlink: Bool
    public var isDirectory: Bool

    public init(
        relativePath: String,
        size: Int64,
        mtime: Double,
        uti: String,
        sha256: String,
        isSymlink: Bool,
        isDirectory: Bool
    ) {
        self.relativePath = relativePath
        self.size = size
        self.mtime = mtime
        self.uti = uti
        self.sha256 = sha256
        self.isSymlink = isSymlink
        self.isDirectory = isDirectory
    }
}

/// File operations confined to a workspace root. Shared by the agent file
/// tools (T04) and the file inspector (T05).
public struct WorkspaceFileService: Sendable {

    /// Directory listing page size.
    public static let pageSize = 200
    /// Maximum bytes returned by a single `readFile` call (64 KiB).
    public static let readChunkBytes = 64 * 1024
    /// Maximum search hits per query.
    public static let maxSearchHits = 100
    /// Maximum context characters per search hit.
    public static let maxHitContextCharacters = 200
    /// Hard bounds for hostile or exceptionally large File Provider trees.
    public static let maxDirectoryEntries = 5_000
    public static let maxSearchFiles = 10_000
    /// Directories pruned during search (VCS internals, build products).
    private static let searchSkipDirectories: Set<String> = [
        ".git", ".svn", ".hg", "node_modules", ".build", "DerivedData", ".swiftpm"
    ]

    public let guardResolver: WorkspacePathGuard

    /// `FileManager` is not Sendable; the shared instance is documented as
    /// safe to call from any thread (we never set a delegate), so we access
    /// it through this computed property instead of a stored one.
    private var fileManager: FileManager { FileManager.default }

    public init(guard guardResolver: WorkspacePathGuard) {
        self.guardResolver = guardResolver
    }

    // MARK: - Listing

    /// Lists a directory one page at a time (lazy loading). Directories sort
    /// before files; both are ordered by localized name. Optional filters are
    /// applied before pagination so page tokens stay consistent.
    public func listDirectory(
        _ path: String,
        pageToken: String?,
        nameContains: String? = nil,
        includeDirectories: Bool = true,
        includeFiles: Bool = true,
        cancellation: CancellationToken? = nil
    ) throws -> DirectoryPage {
        try cancellation?.throwIfCancelled()
        let url = try guardResolver.resolve(path)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw WorkspaceToolError.notFound(path)
        }
        guard isDirectory.boolValue else {
            throw WorkspaceToolError.invalidArguments("path is not a directory: \(path)")
        }

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            throw WorkspaceToolError.notFound(path)
        }
        var names: [String] = []
        names.reserveCapacity(min(Self.maxDirectoryEntries, Self.pageSize * 2))
        for case let child as URL in enumerator {
            try cancellation?.throwIfCancelled()
            guard names.count < Self.maxDirectoryEntries else {
                throw WorkspaceToolError.tooLarge(limit: Self.maxDirectoryEntries)
            }
            names.append(child.lastPathComponent)
        }
        names.sort { $0.localizedStandardCompare($1) == .orderedAscending }

        if let nameContains {
            let needle = nameContains.trimmingCharacters(in: .whitespacesAndNewlines)
            if !needle.isEmpty {
                names = names.filter { $0.range(of: needle, options: .caseInsensitive) != nil }
            }
        }
        if !includeDirectories || !includeFiles {
            names = names.filter { name in
                let child = url.appendingPathComponent(name)
                let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return isDirectory ? includeDirectories : includeFiles
            }
        }

        let startIndex = Self.decodePageToken(pageToken, count: names.count)
        let endIndex = min(startIndex + Self.pageSize, names.count)

        var entries: [FileNode] = []
        entries.reserveCapacity(endIndex - startIndex)
        let baseRelative = Self.normalizedRelativePath(path)
        for name in names[startIndex..<endIndex] {
            try cancellation?.throwIfCancelled()
            let child = url.appendingPathComponent(name)
            let childIsDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let size = (try? fileManager.attributesOfItem(atPath: child.path)[.size] as? NSNumber)?
                .int64Value ?? 0
            let relative = baseRelative.isEmpty ? name : baseRelative + "/" + name
            entries.append(FileNode(name: name, relativePath: relative, isDirectory: childIsDirectory, size: size))
        }
        entries.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        let nextToken = endIndex < names.count ? String(endIndex) : nil
        return DirectoryPage(entries: entries, nextPageToken: nextToken)
    }

    // MARK: - Reading

    /// Reads up to `readChunkBytes` from `path`, starting at byte `offset`
    /// (0-based, clamped to the file size). Returns a truncation flag and
    /// the file's total line count.
    public func readFile(
        _ path: String,
        byteOffset: Int = 0,
        cancellation: CancellationToken? = nil
    ) throws -> FileContent {
        try cancellation?.throwIfCancelled()
        let url = try guardResolver.resolve(path)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw WorkspaceToolError.notFound(path)
        }
        guard !isDirectory.boolValue else {
            throw WorkspaceToolError.isDirectory(path)
        }
        try guardResolver.assertReadableSize(url)

        let data = try Data(floeContentsOf: url)
        let clampedOffset = max(0, min(byteOffset, data.count))
        let end = min(clampedOffset + Self.readChunkBytes, data.count)
        let slice = data[clampedOffset..<end]
        let truncated = end < data.count

        let whole = String(decoding: data, as: UTF8.self)
        let totalLines = Self.lineCount(of: whole)
        let text = String(decoding: slice, as: UTF8.self)
        return FileContent(text: text, truncated: truncated, totalLines: totalLines, byteOffset: clampedOffset)
    }

    /// Reads a complete UTF-8-compatible text file for interactive editing.
    ///
    /// Agent reads stay chunked at 64 KiB, but an editor must never save a
    /// truncated window over the original file. Editable files therefore use
    /// the stricter of the workspace read and write limits and fail closed
    /// when the complete contents cannot be loaded and saved safely.
    public func readFileForEditing(
        _ path: String,
        cancellation: CancellationToken? = nil
    ) throws -> FileContent {
        try cancellation?.throwIfCancelled()
        let url = try guardResolver.resolve(path)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw WorkspaceToolError.notFound(path)
        }
        guard !isDirectory.boolValue else {
            throw WorkspaceToolError.isDirectory(path)
        }
        try guardResolver.assertReadableSize(url)

        let data = try Data(floeContentsOf: url)
        guard data.count <= guardResolver.maxWriteBytes else {
            throw WorkspaceToolError.tooLarge(limit: guardResolver.maxWriteBytes)
        }
        guard Self.looksLikeText(data) else {
            throw WorkspaceToolError.invalidArguments("file is not editable text: \(path)")
        }

        let text = try WorkspaceTextEdit.decode(data)
        return FileContent(
            text: text,
            truncated: false,
            totalLines: Self.lineCount(of: text),
            byteOffset: 0
        )
    }

    // MARK: - Search

    /// Case-insensitive substring search over file and directory *names*
    /// beneath `path` (defaults to the root). Returns at most `maxResults`
    /// relative paths; directories carry a trailing "/".
    public func searchFileNames(
        query: String,
        in path: String = "",
        maxResults: Int = WorkspaceFileService.maxSearchHits,
        cancellation: CancellationToken? = nil
    ) throws -> [String] {
        try cancellation?.throwIfCancelled()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WorkspaceToolError.invalidArguments("query must not be empty")
        }
        let startURL = path.isEmpty
            ? guardResolver.rootURL
            : try guardResolver.resolve(path)
        var startIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: startURL.path, isDirectory: &startIsDirectory) else {
            throw WorkspaceToolError.notFound(path)
        }
        let cappedResults = max(1, min(maxResults, Self.maxSearchHits))
        let basePath = guardResolver.rootURL.path
        var hits: [String] = []

        if !startIsDirectory.boolValue {
            if startURL.lastPathComponent.range(of: trimmed, options: .caseInsensitive) != nil {
                hits.append(Self.relativePath(of: startURL.path, under: basePath))
            }
            return hits
        }
        guard let enumerator = fileManager.enumerator(
            at: startURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var visited = 0
        for case let url as URL in enumerator {
            try cancellation?.throwIfCancelled()
            visited += 1
            guard visited <= Self.maxSearchFiles else {
                throw WorkspaceToolError.tooLarge(limit: Self.maxSearchFiles)
            }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            let isDirectory = values.isDirectory == true
            if isDirectory, Self.searchSkipDirectories.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            guard isDirectory || values.isRegularFile == true else { continue }
            guard !guardResolver.isSecretPath(url) else { continue }
            guard url.lastPathComponent.range(of: trimmed, options: .caseInsensitive) != nil else { continue }
            var relative = Self.relativePath(of: url.path, under: basePath)
            if isDirectory, !relative.hasSuffix("/") { relative += "/" }
            hits.append(relative)
            if hits.count >= cappedResults { break }
        }
        return hits
    }

    /// Case-insensitive substring search over text files beneath `path`
    /// (defaults to the root). Returns at most `maxSearchHits` hits; each
    /// hit's context is trimmed to `maxHitContextCharacters`.
    public func search(
        query: String,
        in path: String = "",
        maxResults: Int = WorkspaceFileService.maxSearchHits,
        cancellation: CancellationToken? = nil
    ) throws -> [SearchHit] {
        try cancellation?.throwIfCancelled()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WorkspaceToolError.invalidArguments("query must not be empty")
        }
        let startURL = path.isEmpty
            ? guardResolver.rootURL
            : try guardResolver.resolve(path)
        var startIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: startURL.path, isDirectory: &startIsDirectory) else {
            throw WorkspaceToolError.notFound(path)
        }

        let cappedResults = max(1, min(maxResults, Self.maxSearchHits))
        var hits: [SearchHit] = []
        let basePath = guardResolver.rootURL.path

        let files = startIsDirectory.boolValue
            ? try enumerateTextFiles(under: startURL, cancellation: cancellation)
            : [startURL]
        for file in files {
            try cancellation?.throwIfCancelled()
            if hits.count >= cappedResults { break }
            guard !guardResolver.isSecretPath(file) else { continue }
            guard let size = (try? fileManager.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?
                .intValue, size <= guardResolver.maxReadBytes else { continue }
            guard let data = try? Data(contentsOf: file) else { continue }
            guard Self.looksLikeText(data) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            let relative = Self.relativePath(of: file.path, under: basePath)
            var lineNumber = 0
            for line in text.components(separatedBy: .newlines) {
                lineNumber += 1
                if hits.count >= cappedResults { break }
                guard line.range(of: trimmed, options: .caseInsensitive) != nil else { continue }
                let context = String(line.prefix(Self.maxHitContextCharacters))
                hits.append(SearchHit(relativePath: relative, lineNumber: lineNumber, context: context))
            }
        }
        return hits
    }

    // MARK: - Writing

    /// Creates a new file, failing when the target already exists.
    @discardableResult
    public func createFile(
        _ path: String,
        content: String,
        cancellation: CancellationToken? = nil
    ) throws -> WriteOutcome {
        try cancellation?.throwIfCancelled()
        let url = try guardResolver.resolve(path)
        guard !fileManager.fileExists(atPath: url.path) else {
            throw WorkspaceToolError.alreadyExists(path)
        }
        return try performWrite(url, path: path, content: content)
    }

    /// Creates a directory (and any missing intermediate parents). Fails when
    /// a file already exists at the target path.
    public func createDirectory(
        _ path: String,
        cancellation: CancellationToken? = nil
    ) throws {
        try cancellation?.throwIfCancelled()
        let url = try guardResolver.resolve(path)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                throw WorkspaceToolError.alreadyExists(path)
            }
            throw WorkspaceToolError.invalidArguments("A file already exists at \(path)")
        }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Writes `content` to `path` with optimistic-concurrency checking.
    ///
    /// When `expectedMtime`/`expectedSHA256` are provided and the file
    /// exists, both must match the current on-disk state; a mismatch throws
    /// `.conflict` and nothing is overwritten. When the file does not exist,
    /// the expectations must be absent (creating through `writeFile` with a
    /// stale expectation is a conflict).
    @discardableResult
    public func writeFile(
        _ path: String,
        content: String,
        expectedMtime: Double? = nil,
        expectedSHA256: String? = nil,
        cancellation: CancellationToken? = nil
    ) throws -> WriteOutcome {
        try cancellation?.throwIfCancelled()
        let url = try guardResolver.resolve(path)
        let exists = fileManager.fileExists(atPath: url.path)
        if exists {
            if expectedMtime != nil || expectedSHA256 != nil {
                let actualMtime = (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)?
                    .timeIntervalSince1970 ?? 0
                let actualSHA = Self.sha256Hex(of: (try? Data(contentsOf: url)) ?? Data())
                if let expectedMtime, abs(actualMtime - expectedMtime) > 1.0 {
                    throw WorkspaceToolError.conflict(
                        expected: "mtime \(expectedMtime)", actual: "mtime \(actualMtime)"
                    )
                }
                if let expectedSHA256, actualSHA.lowercased() != expectedSHA256.lowercased() {
                    throw WorkspaceToolError.conflict(
                        expected: "sha256 \(expectedSHA256)", actual: "sha256 \(actualSHA)"
                    )
                }
            }
        } else if expectedMtime != nil || expectedSHA256 != nil {
            throw WorkspaceToolError.conflict(
                expected: "existing file", actual: "missing file"
            )
        }
        return try performWrite(url, path: path, content: content)
    }

    // MARK: - Patch

    /// Applies a standard unified diff (single-file subset) to `path`.
    /// Hunks are applied sequentially; if any hunk fails, nothing is written.
    /// Multi-file patches are rejected up front.
    @discardableResult
    public func applyPatch(
        _ path: String,
        patch: String,
        cancellation: CancellationToken? = nil
    ) throws -> PatchOutcome {
        try cancellation?.throwIfCancelled()
        let url = try guardResolver.resolve(path)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw WorkspaceToolError.notFound(path)
        }
        guard !isDirectory.boolValue else {
            throw WorkspaceToolError.isDirectory(path)
        }
        try guardResolver.assertReadableSize(url)

        let hunks = try Self.parseUnifiedDiff(patch)
        let originalData = try Data(floeContentsOf: url)
        let original = try WorkspaceTextEdit.decode(originalData)
        var lines = original.components(separatedBy: "\n")

        var applied = 0
        var added = 0
        var removed = 0
        // Adjust subsequent hunk positions by the net growth of earlier ones.
        var lineDelta = 0
        for hunk in hunks {
            try cancellation?.throwIfCancelled()
            let (zeroBased, startUnderflow) = hunk.oldStart.subtractingReportingOverflow(1)
            let (startIndex, startOverflow) = zeroBased.addingReportingOverflow(lineDelta)
            let (endIndex, endOverflow) = startIndex.addingReportingOverflow(hunk.oldLines.count)
            guard !startUnderflow, !startOverflow, !endOverflow,
                  startIndex >= 0, endIndex <= lines.count else {
                throw WorkspaceToolError.invalidPatch(
                    "hunk @@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@ is out of range"
                )
            }
            let window = Array(lines[startIndex..<endIndex])
            guard window == hunk.oldLines else {
                throw WorkspaceToolError.invalidPatch(
                    "context mismatch near line \(hunk.oldStart); file contents do not match the patch"
                )
            }
            lines.replaceSubrange(startIndex..<endIndex, with: hunk.newLines)
            let delta = hunk.newLines.count - hunk.oldLines.count
            let (nextDelta, deltaOverflow) = lineDelta.addingReportingOverflow(delta)
            guard !deltaOverflow else {
                throw WorkspaceToolError.invalidPatch("hunk line delta overflow")
            }
            lineDelta = nextDelta
            applied += 1
            added += hunk.addedCount
            removed += hunk.removedCount
        }

        let patched = lines.joined(separator: "\n")
        let outcome = try performWrite(url, path: path, content: patched)
        return PatchOutcome(
            hunksApplied: applied,
            linesAdded: added,
            linesRemoved: removed,
            sha256: outcome.sha256
        )
    }

    // MARK: - Move / Delete

    /// Moves a file or directory. Both paths are resolved through the guard.
    public func move(
        _ from: String,
        to: String,
        cancellation: CancellationToken? = nil
    ) throws {
        try cancellation?.throwIfCancelled()
        let source = try guardResolver.resolve(from)
        try rejectWorkspaceRootMutation(source, operation: "move")
        guard fileManager.fileExists(atPath: source.path) else {
            throw WorkspaceToolError.notFound(from)
        }
        let destination = try guardResolver.resolve(to)
        try rejectDescendantDestination(source: source, destination: destination, operation: "move")
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw WorkspaceToolError.alreadyExists(to)
        }
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        try fileManager.moveItem(at: source, to: destination)
    }

    /// Copies a file or directory (recursively) within the workspace.
    public func copy(
        _ from: String,
        to: String,
        cancellation: CancellationToken? = nil
    ) throws {
        try cancellation?.throwIfCancelled()
        let source = try guardResolver.resolve(from)
        try rejectWorkspaceRootMutation(source, operation: "copy")
        guard fileManager.fileExists(atPath: source.path) else {
            throw WorkspaceToolError.notFound(from)
        }
        let destination = try guardResolver.resolve(to)
        try rejectDescendantDestination(source: source, destination: destination, operation: "copy")
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw WorkspaceToolError.alreadyExists(to)
        }
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        try fileManager.copyItem(at: source, to: destination)
    }

    /// Deletes a file or directory. Non-empty directories are only removed
    /// when `recursive` is true; otherwise they are refused so a stray path
    /// cannot wipe a subtree silently.
    public func delete(
        _ path: String,
        recursive: Bool = false,
        cancellation: CancellationToken? = nil
    ) throws {
        try cancellation?.throwIfCancelled()
        let url = try guardResolver.resolve(path)
        try rejectWorkspaceRootMutation(url, operation: "delete")
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw WorkspaceToolError.notFound(path)
        }
        if isDirectory.boolValue && !recursive {
            let children = try fileManager.contentsOfDirectory(atPath: url.path)
            guard children.isEmpty else {
                throw WorkspaceToolError.invalidArguments(
                    "directory is not empty; use recursive delete to remove it: \(path)"
                )
            }
        }
        try fileManager.removeItem(at: url)
    }

    private func rejectWorkspaceRootMutation(_ url: URL, operation: String) throws {
        guard url.standardizedFileURL != guardResolver.rootURL.standardizedFileURL else {
            throw WorkspaceToolError.invalidArguments(
                "The workspace root cannot be the target of \(operation)"
            )
        }
    }

    private func rejectDescendantDestination(
        source: URL,
        destination: URL,
        operation: String
    ) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }
        let sourcePath = source.standardizedFileURL.path
        let destinationPath = destination.standardizedFileURL.path
        guard !destinationPath.hasPrefix(sourcePath + "/") else {
            throw WorkspaceToolError.invalidArguments(
                "A directory cannot be the destination of its own \(operation)"
            )
        }
    }

    // MARK: - Metadata

    /// Returns size/mtime/UTI/sha256/symlink metadata for a path.
    public func metadata(_ path: String) throws -> WorkspaceFileMetadata {
        let url = try guardResolver.resolve(path)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw WorkspaceToolError.notFound(path)
        }
        try guardResolver.assertReadableSize(url)
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let isSymlink = (attributes[.type] as? FileAttributeType) == .typeSymbolicLink
        let uti = (try? url.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier)
            ?? Self.fallbackUTI(for: url)
        let sha: String
        if isDirectory.boolValue {
            sha = ""
        } else {
            sha = Self.sha256Hex(of: (try? Data(contentsOf: url)) ?? Data())
        }
        return WorkspaceFileMetadata(
            relativePath: Self.normalizedRelativePath(path),
            size: size,
            mtime: mtime,
            uti: uti,
            sha256: sha,
            isSymlink: isSymlink,
            isDirectory: isDirectory.boolValue
        )
    }

    // MARK: - Diff

    /// Generates a standard unified diff between two texts (context 3).
    /// Pure function; no file access.
    public func diff(original: String, modified: String, label: String = "file") -> String {
        let oldLines = original.components(separatedBy: "\n")
        let newLines = modified.components(separatedBy: "\n")
        let hunks = Self.diffHunks(old: oldLines, new: newLines, context: 3)
        guard !hunks.isEmpty else { return "" }
        var out = "--- a/\(label)\n+++ b/\(label)\n"
        for hunk in hunks {
            out += "@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@\n"
            for line in hunk.body { out += line + "\n" }
        }
        return out
    }

    // MARK: - Private helpers

    private func performWrite(_ url: URL, path: String, content: String) throws -> WriteOutcome {
        let data = Data(content.utf8)
        try guardResolver.assertWritableSize(bytes: data.count)
        try guardResolver.assertWritable(url)
        let parent = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        let mtime = (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? Date().timeIntervalSince1970
        return WriteOutcome(bytesWritten: data.count, sha256: Self.sha256Hex(of: data), mtime: mtime)
    }

    private func enumerateTextFiles(under root: URL, cancellation: CancellationToken?) throws -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            try cancellation?.throwIfCancelled()
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values.isDirectory == true {
                if Self.searchSkipDirectories.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true else { continue }
            guard !guardResolver.isSecretPath(url) else { continue }
            guard files.count < Self.maxSearchFiles else {
                throw WorkspaceToolError.tooLarge(limit: Self.maxSearchFiles)
            }
            files.append(url)
        }
        return files
    }

    static func lineCount(of text: String) -> Int {
        if text.isEmpty { return 0 }
        var count = 1
        for character in text where character == "\n" { count += 1 }
        if text.hasSuffix("\n") { count -= 1 }
        return count
    }

    static func looksLikeText(_ data: Data) -> Bool {
        let sample = data.prefix(1024)
        return !sample.contains(0)
    }

    static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func normalizedRelativePath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != "." else { return "" }
        return (trimmed as NSString).standardizingPath
    }

    static func relativePath(of path: String, under base: String) -> String {
        guard path.hasPrefix(base + "/") else { return path }
        return String(path.dropFirst(base.count + 1))
    }

    private static func decodePageToken(_ token: String?, count: Int) -> Int {
        guard let token, let index = Int(token) else { return 0 }
        return max(0, min(index, count))
    }

    private static func fallbackUTI(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "txt", "md", "markdown": return "public.plain-text"
        case "json": return "public.json"
        case "swift", "py", "js", "ts", "c", "h", "cpp": return "public.source-code"
        case "html", "htm": return "public.html"
        case "png": return "public.png"
        case "jpg", "jpeg": return "public.jpeg"
        case "pdf": return "com.adobe.pdf"
        default: return "public.data"
        }
    }

    // MARK: - Unified diff parsing / generation

    struct DiffHunk: Sendable, Equatable {
        var oldStart: Int
        var oldCount: Int
        var newStart: Int
        var newCount: Int
        /// Lines expected in the file (context + removals, in order).
        var oldLines: [String]
        /// Replacement lines (context + additions, in order).
        var newLines: [String]
        var addedCount: Int
        var removedCount: Int
        /// Raw body lines for re-emission (diff generation only).
        var body: [String]
    }

    /// Parses a unified diff into hunks for one file. Multi-file patches
    /// (more than one `--- `/`+++ ` pair, or `diff --git` headers) throw
    /// `.invalidPatch`.
    static func parseUnifiedDiff(_ patch: String) throws -> [DiffHunk] {
        let lines = patch.components(separatedBy: "\n")
        var hunks: [DiffHunk] = []
        var index = 0
        var sawFileHeader = 0

        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("diff --git") {
                throw WorkspaceToolError.invalidPatch(
                    "multi-file patches are not supported; apply one file per call"
                )
            }
            if line.hasPrefix("--- ") {
                sawFileHeader += 1
                if sawFileHeader > 1 {
                    throw WorkspaceToolError.invalidPatch(
                        "multi-file patches are not supported; apply one file per call"
                    )
                }
                index += 1
                if index < lines.count, lines[index].hasPrefix("+++ ") {
                    index += 1
                }
                continue
            }
            if line.hasPrefix("@@") {
                let (hunk, consumed) = try parseHunk(Array(lines[index...]))
                hunks.append(hunk)
                index += consumed
                continue
            }
            index += 1
        }
        guard !hunks.isEmpty else {
            throw WorkspaceToolError.invalidPatch("no hunks found")
        }
        return hunks
    }

    private static func parseHunk(_ lines: [String]) throws -> (DiffHunk, Int) {
        guard let header = lines.first else {
            throw WorkspaceToolError.invalidPatch("truncated hunk")
        }
        // @@ -oldStart,oldCount +newStart,newCount @@
        let pattern = #"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: header, range: NSRange(header.startIndex..., in: header)
              ),
              let oldStartRange = Range(match.range(at: 1), in: header),
              let newStartRange = Range(match.range(at: 3), in: header),
              let oldStart = Int(header[oldStartRange]),
              let newStart = Int(header[newStartRange])
        else {
            throw WorkspaceToolError.invalidPatch("malformed hunk header: \(header)")
        }
        let oldCount = match.range(at: 2).location != NSNotFound
            ? Range(match.range(at: 2), in: header).flatMap { Int(header[$0]) } ?? 1
            : 1
        let newCount = match.range(at: 4).location != NSNotFound
            ? Range(match.range(at: 4), in: header).flatMap { Int(header[$0]) } ?? 1
            : 1

        var oldLines: [String] = []
        var newLines: [String] = []
        var added = 0
        var removed = 0
        var consumed = 1
        var seenOld = 0
        var seenNew = 0
        var bodyIndex = 1
        while bodyIndex < lines.count, seenOld < oldCount || seenNew < newCount {
            let line = lines[bodyIndex]
            if line.hasPrefix(#"\ "#) {
                // "\ No newline at end of file" marker: skip.
                bodyIndex += 1
                consumed += 1
                continue
            }
            guard let marker = line.first, marker == " " || marker == "-" || marker == "+" else {
                break
            }
            let content = String(line.dropFirst())
            switch marker {
            case " ":
                oldLines.append(content)
                newLines.append(content)
                seenOld += 1
                seenNew += 1
            case "-":
                oldLines.append(content)
                removed += 1
                seenOld += 1
            default: // "+"
                newLines.append(content)
                added += 1
                seenNew += 1
            }
            bodyIndex += 1
            consumed += 1
        }
        guard seenOld == oldCount, seenNew == newCount else {
            throw WorkspaceToolError.invalidPatch(
                "hunk truncated: expected -\(oldCount)/+\(newCount) lines, saw -\(seenOld)/+\(seenNew)"
            )
        }
        return (
            DiffHunk(
                oldStart: oldStart,
                oldCount: oldCount,
                newStart: newStart,
                newCount: newCount,
                oldLines: oldLines,
                newLines: newLines,
                addedCount: added,
                removedCount: removed,
                body: []
            ),
            consumed
        )
    }

    /// Myers-free diff: computes hunks by longest-common-subsequence over
    /// lines. Workspace files are bounded by the guard's size caps, so an
    /// O(n·m) LCS is acceptable and far simpler than Myers.
    static func diffHunks(old: [String], new: [String], context: Int) -> [DiffHunk] {
        let edits = lcsEdits(old: old, new: new)
        guard !edits.isEmpty else { return [] }
        return groupEdits(edits, old: old, new: new, context: context)
    }

    /// One atomic edit step from the LCS backtrace.
    private enum Edit: Equatable {
        case keep(Int)   // index into old
        case remove(Int) // index into old
        case add(Int)    // index into new
    }

    private static func lcsEdits(old: [String], new: [String]) -> [Edit] {
        let n = old.count
        let m = new.count
        guard n > 0, m > 0 else {
            var edits: [Edit] = old.indices.map { .remove($0) }
            edits.append(contentsOf: new.indices.map { .add($0) })
            return edits
        }
        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                if old[i] == new[j] {
                    table[i][j] = table[i + 1][j + 1] + 1
                } else {
                    table[i][j] = max(table[i + 1][j], table[i][j + 1])
                }
            }
        }
        var edits: [Edit] = []
        var i = 0
        var j = 0
        while i < n, j < m {
            if old[i] == new[j] {
                edits.append(.keep(i))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                edits.append(.remove(i))
                i += 1
            } else {
                edits.append(.add(j))
                j += 1
            }
        }
        while i < n { edits.append(.remove(i)); i += 1 }
        while j < m { edits.append(.add(j)); j += 1 }
        return edits
    }

    private static func groupEdits(
        _ edits: [Edit], old: [String], new: [String], context: Int
    ) -> [DiffHunk] {
        // Find change regions, then expand by context and merge overlaps.
        var regions: [(start: Int, end: Int)] = [] // edit indices [start, end)
        var cursor = 0
        while cursor < edits.count {
            switch edits[cursor] {
            case .keep:
                cursor += 1
            case .remove, .add:
                let start = cursor
                while cursor < edits.count {
                    if case .keep = edits[cursor] { break }
                    cursor += 1
                }
                regions.append((start, cursor))
            }
        }
        guard !regions.isEmpty else { return [] }

        let expanded: [(start: Int, end: Int)] = regions.map {
            (max(0, $0.start - context), min(edits.count, $0.end + context))
        }
        var merged: [(start: Int, end: Int)] = []
        for region in expanded {
            if let last = merged.last, region.start <= last.end {
                merged[merged.count - 1].end = max(last.end, region.end)
            } else {
                merged.append(region)
            }
        }

        return merged.map { region in
            var body: [String] = []
            var oldStart = 0
            var newStart = 0
            var oldCount = 0
            var newCount = 0
            var oldCursor = 0
            var newCursor = 0
            for (index, edit) in edits.enumerated() {
                if index < region.start {
                    switch edit {
                    case .keep: oldCursor += 1; newCursor += 1
                    case .remove: oldCursor += 1
                    case .add: newCursor += 1
                    }
                    continue
                }
                if index >= region.end { break }
                if index == region.start {
                    oldStart = oldCursor + 1
                    newStart = newCursor + 1
                }
                switch edit {
                case .keep(let oldIndex):
                    body.append(" " + old[oldIndex])
                    oldCursor += 1; newCursor += 1
                    oldCount += 1; newCount += 1
                case .remove(let oldIndex):
                    body.append("-" + old[oldIndex])
                    oldCursor += 1
                    oldCount += 1
                case .add(let newIndex):
                    body.append("+" + new[newIndex])
                    newCursor += 1
                    newCount += 1
                }
            }
            // oldCount/newCount of zero means "insertion/deletion at start";
            // unified diff then counts position from 0.
            if oldCount == 0 { oldStart = max(0, oldStart - 1) }
            if newCount == 0 { newStart = max(0, newStart - 1) }
            return DiffHunk(
                oldStart: oldStart,
                oldCount: oldCount,
                newStart: newStart,
                newCount: newCount,
                oldLines: [],
                newLines: [],
                addedCount: 0,
                removedCount: 0,
                body: body
            )
        }
    }
}
