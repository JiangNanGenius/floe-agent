import Foundation
import FloeBuildingRecords

public struct BuildingDirectorySnapshotProgress: Sendable, Equatable {
    public let completedFiles: Int
    public let totalFiles: Int

    public init(completedFiles: Int, totalFiles: Int) {
        self.completedFiles = completedFiles
        self.totalFiles = totalFiles
    }
}

/// A byte-for-byte copy of a caller-selected directory, made with bounded,
/// cancellable and read-back verified copies. It has no CAD semantics: the
/// integration owner reads the actual native storedIdentity from this snapshot.
public struct BuildingDirectorySnapshot: Sendable, Hashable {
    public let directoryURL: URL
    public let fileCount: Int
    public let totalByteCount: Int
    public let treeSHA256: String
    public let files: [ProjectFileDigest]

    init(
        directoryURL: URL,
        fileCount: Int,
        totalByteCount: Int,
        treeSHA256: String,
        files: [ProjectFileDigest]
    ) {
        self.directoryURL = directoryURL
        self.fileCount = fileCount
        self.totalByteCount = totalByteCount
        self.treeSHA256 = treeSHA256
        self.files = files
    }
}

extension BuildingProjectRepository {
    /// Freeze a directory (for example a still-auto-saving working .floecad
    /// directory) into a new private snapshot. The destination must not exist;
    /// the copy is made into a hidden sibling directory and only moved to the
    /// requested name after every file was copied and read back. Symlinks,
    /// special files, duplicate paths, budget overruns, cancellation and a
    /// source tree that changes during the copy are rejected.
    public static func captureDirectorySnapshot(
        source: URL,
        to destination: URL,
        limits: BuildingProjectLimits = BuildingProjectLimits(),
        cancellation: BuildingProjectCancellation? = nil,
        progress: (@Sendable (BuildingDirectorySnapshotProgress) -> Void)? = nil
    ) throws -> BuildingDirectorySnapshot {
        try limits.validate()
        if let cancellation { try cancellation.check() }
        guard source.isFileURL, destination.isFileURL else {
            throw BuildingProjectError.ioFailure("the source and destination must be file URLs")
        }
        let sourceRoot = source.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        guard BuildingProjectFileSystem.kind(of: sourceRoot) == .directory else {
            throw BuildingProjectError.ioFailure("the directory snapshot source is missing or not a directory")
        }
        let requested = destination.standardizedFileURL
        let leaf = requested.lastPathComponent
        guard !leaf.isEmpty, leaf != ".", leaf != "..", leaf != "/" else {
            throw BuildingProjectError.outputExists(destination.path)
        }
        let parent = requested.deletingLastPathComponent()
        let parentResolved = parent.resolvingSymlinksInPath().standardizedFileURL
        guard BuildingProjectFileSystem.kind(of: parentResolved) == .directory else {
            throw BuildingProjectError.ioFailure("the destination parent is missing or not a directory")
        }
        let finalDestination = parentResolved
            .appendingPathComponent(leaf, isDirectory: true)
            .standardizedFileURL
        guard !BuildingProjectPaths.isSameOrAncestor(sourceRoot, of: finalDestination),
              !BuildingProjectPaths.isSameOrAncestor(finalDestination, of: sourceRoot) else {
            throw BuildingProjectError.pathEscapesRoot(
                "the directory snapshot destination overlaps its source"
            )
        }
        guard BuildingProjectFileSystem.kind(of: finalDestination) == .missing else {
            throw BuildingProjectError.outputExists(finalDestination.path)
        }
        let temporary = parentResolved.appendingPathComponent(
            ".\(leaf).capture-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        guard BuildingProjectFileSystem.kind(of: temporary) == .missing else {
            throw BuildingProjectError.outputExists(temporary.path)
        }
        let isCancelled: @Sendable () -> Bool = { cancellation?.isCancelled ?? false }
        let inspected = try BuildingProjectFileSystem.inspectTree(
            root: sourceRoot,
            section: .cad,
            limits: limits,
            isCancelled: isCancelled
        )
        let totalFiles = inspected.count
        let totalBytes = inspected.reduce(0) { $0 + $1.byteCount }
        guard totalBytes <= limits.maxTotalBytes else {
            throw BuildingProjectError.budgetExceeded(
                "the directory snapshot is \(totalBytes) bytes; the limit is \(limits.maxTotalBytes)"
            )
        }
        progress?(BuildingDirectorySnapshotProgress(completedFiles: 0, totalFiles: totalFiles))

        var keep = false
        defer {
            if !keep {
                try? BuildingProjectFileSystem.removeTree(temporary)
            }
        }
        let records = try BuildingProjectFileSystem.copyTree(
            from: sourceRoot,
            to: temporary,
            section: .cad,
            inspected: inspected,
            limits: limits,
            isCancelled: isCancelled,
            progress: { completed in
                progress?(BuildingDirectorySnapshotProgress(
                    completedFiles: completed,
                    totalFiles: totalFiles
                ))
            }
        )
        let files = records
            .map {
                ProjectFileDigest(
                    relativePath: $0.relativePath,
                    byteCount: $0.byteCount,
                    sha256: $0.sha256
                )
            }
            .sorted { $0.relativePath < $1.relativePath }
        guard files.count == inspected.count else {
            throw BuildingProjectError.ioFailure("the directory snapshot file count changed")
        }
        let totalCopiedBytes = files.reduce(0) { $0 + $1.byteCount }
        guard totalCopiedBytes == totalBytes else {
            throw BuildingProjectError.ioFailure("the directory snapshot byte count changed")
        }
        let treeDigest = ProjectFileTreeDigest.digest(files)
        guard BuildingProjectFileSystem.kind(of: finalDestination) == .missing else {
            throw BuildingProjectError.outputExists(finalDestination.path)
        }
        do {
            try FileManager.default.moveItem(at: temporary, to: finalDestination)
        } catch {
            throw BuildingProjectError.ioFailure(
                "the directory snapshot could not be published: \(error)"
            )
        }
        BuildingProjectFileSystem.fsyncDirectory(parentResolved)
        keep = true
        return BuildingDirectorySnapshot(
            directoryURL: finalDestination,
            fileCount: files.count,
            totalByteCount: totalCopiedBytes,
            treeSHA256: treeDigest,
            files: files
        )
    }
}
