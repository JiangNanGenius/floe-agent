import CryptoKit
import Darwin
import Foundation
import GRDB

// MARK: - Limits and progress

/// Bounds for a records snapshot. A snapshot is a byte-for-byte copy of the
/// project records database plus the immutable source/blob files it references;
/// these limits keep a malformed or unexpectedly large project from filling the
/// destination volume silently.
public struct ProjectRecordsSnapshotLimits: Sendable, Equatable {
    public var maxFileCount: Int
    public var maxTotalBytes: Int
    public var maxSingleFileBytes: Int
    public var copyChunkBytes: Int

    public init(
        maxFileCount: Int = 50_000,
        maxTotalBytes: Int = 4 * 1024 * 1024 * 1024,
        maxSingleFileBytes: Int = 1024 * 1024 * 1024,
        copyChunkBytes: Int = 1024 * 1024
    ) {
        self.maxFileCount = maxFileCount
        self.maxTotalBytes = maxTotalBytes
        self.maxSingleFileBytes = maxSingleFileBytes
        self.copyChunkBytes = copyChunkBytes
    }

    func validate() throws {
        guard maxFileCount > 0 else {
            throw ProjectRecordsSnapshotError.budgetExceeded("maxFileCount must be positive")
        }
        guard maxTotalBytes > 0, maxSingleFileBytes > 0, maxSingleFileBytes <= maxTotalBytes else {
            throw ProjectRecordsSnapshotError.budgetExceeded("byte limits must be positive and ordered")
        }
        guard copyChunkBytes >= 64 * 1024, copyChunkBytes <= 8 * 1024 * 1024 else {
            throw ProjectRecordsSnapshotError.budgetExceeded("copyChunkBytes must be 65536...8388608")
        }
    }
}

public struct ProjectRecordsSnapshotProgress: Sendable, Equatable {
    public enum Phase: String, Codable, Sendable {
        case database
        case blobs
        case verification
    }

    public let phase: Phase
    public let completedFiles: Int
    public let totalFiles: Int
    public let completedBytes: Int
    public let totalBytes: Int

    public init(
        phase: Phase,
        completedFiles: Int,
        totalFiles: Int,
        completedBytes: Int,
        totalBytes: Int
    ) {
        self.phase = phase
        self.completedFiles = completedFiles
        self.totalFiles = totalFiles
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
    }
}

// MARK: - Canonical file tree digest

public struct ProjectFileDigest: Codable, Sendable, Hashable {
    public let relativePath: String
    public let byteCount: Int
    public let sha256: String

    public init(relativePath: String, byteCount: Int, sha256: String) {
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

/// Deterministic digest over a set of relative paths, byte counts and hashes.
/// Sorting makes the value independent of filesystem enumeration order. The
/// same routine is used for records, CAD and editor metadata sections.
public enum ProjectFileTreeDigest {
    public static func digest(_ files: [ProjectFileDigest]) -> String {
        var hasher = SHA256()
        for file in files.sorted(by: { $0.relativePath < $1.relativePath }) {
            let line = "\(file.relativePath)\u{0}\(file.byteCount)\u{0}\(file.sha256)\n"
            hasher.update(data: Data(line.utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Snapshot value

/// A quiescent copy of one records revision.
///
/// `directoryURL` is a complete project container: it can be passed directly to
/// `ProjectRecordsStore.openProject(at:)`. Values are produced by
/// `ProjectRecordsStore.captureSnapshot(to:)` or
/// `ProjectRecordsSnapshot.load(from:)`; callers do not assemble one by hand.
public struct ProjectRecordsSnapshot: Sendable, Hashable {
    public let schemaVersion: Int
    public let directoryURL: URL
    public let projectID: ProjectID
    public let revision: Int
    public let databaseByteCount: Int
    public let blobCount: Int
    public let blobByteCount: Int
    public let fileCount: Int
    public let totalByteCount: Int
    public let treeSHA256: String
    public let createdAt: Date

    init(
        schemaVersion: Int = 1,
        directoryURL: URL,
        projectID: ProjectID,
        revision: Int,
        databaseByteCount: Int,
        blobCount: Int,
        blobByteCount: Int,
        fileCount: Int,
        totalByteCount: Int,
        treeSHA256: String,
        createdAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.directoryURL = directoryURL
        self.projectID = projectID
        self.revision = revision
        self.databaseByteCount = databaseByteCount
        self.blobCount = blobCount
        self.blobByteCount = blobByteCount
        self.fileCount = fileCount
        self.totalByteCount = totalByteCount
        self.treeSHA256 = treeSHA256
        self.createdAt = createdAt
    }

    /// Re-hash the snapshot on disk and compare it with the values captured when
    /// the snapshot was created. This detects an external edit, a replaced
    /// database file, a missing blob or an extra file.
    @discardableResult
    public func verifyIntegrity(
        limits: ProjectRecordsSnapshotLimits = ProjectRecordsSnapshotLimits()
    ) throws -> ProjectRecordsSnapshot {
        let loaded = try ProjectRecordsSnapshot.load(from: directoryURL, limits: limits)
        guard loaded.schemaVersion == schemaVersion,
              loaded.projectID == projectID,
              loaded.revision == revision,
              loaded.databaseByteCount == databaseByteCount,
              loaded.blobCount == blobCount,
              loaded.blobByteCount == blobByteCount,
              loaded.fileCount == fileCount,
              loaded.totalByteCount == totalByteCount,
              loaded.treeSHA256 == treeSHA256 else {
            throw ProjectRecordsSnapshotError.invalidSnapshot(
                "the snapshot no longer matches its captured revision, counts or tree digest"
            )
        }
        return loaded
    }

    /// Load and fully verify an existing quiescent snapshot directory. The
    /// directory must not contain SQLite WAL/journal sidecars; that is tested so
    /// a caller cannot present a live writer directory as a captured snapshot.
    public static func load(
        from directoryURL: URL,
        limits: ProjectRecordsSnapshotLimits = ProjectRecordsSnapshotLimits()
    ) throws -> ProjectRecordsSnapshot {
        try limits.validate()
        guard directoryURL.isFileURL else {
            throw ProjectRecordsSnapshotError.invalidDestination("the snapshot URL is not a file URL")
        }
        let requested = directoryURL.standardizedFileURL
        let root = requested.resolvingSymlinksInPath().standardizedFileURL
        guard SnapshotFileSystem.kind(of: root) == .directory else {
            throw ProjectRecordsSnapshotError.invalidSnapshot("the snapshot directory is missing or not a directory")
        }

        let databaseURL = root.appendingPathComponent(ProjectContainer.databaseRelativePath)
        guard SnapshotFileSystem.kind(of: databaseURL) == .regular else {
            throw ProjectRecordsSnapshotError.invalidSnapshot("the snapshot does not contain a regular records database")
        }
        let sidecars = ["-wal", "-shm", "-journal"].filter {
            SnapshotFileSystem.kind(of: URL(fileURLWithPath: databaseURL.path + $0)) != .missing
        }
        guard sidecars.isEmpty else {
            throw ProjectRecordsSnapshotError.snapshotNotQuiescent(
                sidecars.map { databaseURL.lastPathComponent + $0 }
            )
        }

        let files = try SnapshotFileSystem.scanFiles(
            root: root,
            limits: limits,
            isCancelled: { false }
        )
        try SnapshotFileSystem.validateSnapshotPaths(files, databaseRelativePath: ProjectContainer.databaseRelativePath)
        let database = try SnapshotFileSystem.readDatabase(at: databaseURL)
        let container = ProjectContainer(rootURL: root)
        var fileByPath: [String: SnapshotFile] = [:]
        for file in files {
            guard fileByPath[file.relativePath] == nil else {
                throw ProjectRecordsSnapshotError.invalidSnapshot(
                    "duplicate snapshot path \(file.relativePath)"
                )
            }
            fileByPath[file.relativePath] = file
        }

        var blobCount = 0
        var blobBytes = 0
        var knownBlobPaths: Set<String> = []
        for row in database.blobs {
            let sha256: String = row["sha256"]
            let byteLength: Int = row["byte_length"]
            let relativePath: String = row["relative_path"]
            let expectedPath: String
            do {
                expectedPath = try container.blobRelativePath(for: sha256)
            } catch {
                throw ProjectRecordsSnapshotError.corruptedBlob(sha256)
            }
            guard relativePath == expectedPath else {
                throw ProjectRecordsSnapshotError.corruptedBlob(sha256)
            }
            guard let file = fileByPath[relativePath] else {
                throw ProjectRecordsSnapshotError.missingBlob(sha256)
            }
            guard file.byteCount == byteLength, file.sha256 == sha256 else {
                throw ProjectRecordsSnapshotError.corruptedBlob(sha256)
            }
            knownBlobPaths.insert(relativePath)
            blobCount += 1
            blobBytes += byteLength
        }
        for file in files {
            if file.relativePath == ProjectContainer.databaseRelativePath {
                continue
            }
            if !knownBlobPaths.contains(file.relativePath) {
                throw ProjectRecordsSnapshotError.invalidSnapshot(
                    "the snapshot contains an unregistered blob at \(file.relativePath)"
                )
            }
        }

        let databaseBytes = try SnapshotFileSystem.fileSize(databaseURL)
        guard databaseBytes <= limits.maxSingleFileBytes else {
            throw ProjectRecordsSnapshotError.budgetExceeded(
                "records database is \(databaseBytes) bytes; the limit is \(limits.maxSingleFileBytes)"
            )
        }
        let totalBytes = files.reduce(0) { $0 + $1.byteCount }
        let treeDigest = ProjectFileTreeDigest.digest(files.map {
            ProjectFileDigest(relativePath: $0.relativePath, byteCount: $0.byteCount, sha256: $0.sha256)
        })
        let createdAt: Date
        if let attributes = try? FileManager.default.attributesOfItem(atPath: databaseURL.path),
           let value = attributes[.creationDate] as? Date {
            createdAt = value
        } else {
            createdAt = Date()
        }

        return ProjectRecordsSnapshot(
            schemaVersion: 1,
            directoryURL: root,
            projectID: database.projectID,
            revision: database.revision,
            databaseByteCount: databaseBytes,
            blobCount: blobCount,
            blobByteCount: blobBytes,
            fileCount: files.count,
            totalByteCount: totalBytes,
            treeSHA256: treeDigest,
            createdAt: createdAt
        )
    }
}

// MARK: - Errors

public enum ProjectRecordsSnapshotError: Error, Equatable, Sendable {
    case invalidDestination(String)
    case outputExists(URL)
    case destinationInsideSource
    case sourceInsideDestination
    case revisionMismatch(expected: Int, actual: Int)
    case projectMismatch
    case cancelled
    case budgetExceeded(String)
    case snapshotNotQuiescent([String])
    case missingBlob(String)
    case corruptedBlob(String)
    case invalidSnapshot(String)
    case databaseSnapshotFailed(String)
}

extension ProjectRecordsSnapshotError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidDestination(let reason):
            return "The snapshot destination is not usable: \(reason)"
        case .outputExists(let url):
            return "The snapshot destination already exists: \(url.lastPathComponent)"
        case .destinationInsideSource:
            return "The snapshot destination must not be inside the source project."
        case .sourceInsideDestination:
            return "The snapshot destination must not contain the source project."
        case .revisionMismatch(let expected, let actual):
            return "The records revision is \(actual); expected \(expected)."
        case .projectMismatch:
            return "The open records project does not match the requested project identity."
        case .cancelled:
            return "Snapshot capture was cancelled."
        case .budgetExceeded(let reason):
            return "The snapshot exceeds its budget: \(reason)"
        case .snapshotNotQuiescent(let files):
            return "The snapshot directory is not quiescent; sidecars: \(files.joined(separator: ", "))."
        case .missingBlob(let sha256):
            return "The snapshot is missing a source blob (\(sha256))."
        case .corruptedBlob(let sha256):
            return "The snapshot source blob does not match its digest (\(sha256))."
        case .invalidSnapshot(let reason):
            return "The records snapshot is invalid: \(reason)"
        case .databaseSnapshotFailed(let reason):
            return "The SQLite backup did not complete: \(reason)"
        }
    }
}

// MARK: - Capture

extension ProjectRecordsStore {
    /// Copy the current records project into a new, quiescent directory using
    /// SQLite's online backup API for the database and a verified byte copy for
    /// each immutable source blob. The destination must not exist; an existing
    /// file, directory or symlink is never overwritten. On failure the partial
    /// destination is removed.
    ///
    /// The returned revision is read back from the destination database, not
    /// inferred from the live connection, so the revision and copied bytes are
    /// from the same SQLite snapshot.
    @discardableResult
    public func captureSnapshot(
        to destinationURL: URL,
        projectID: ProjectID? = nil,
        expectedRevision: Int? = nil,
        limits: ProjectRecordsSnapshotLimits = ProjectRecordsSnapshotLimits(),
        isCancelled: @escaping @Sendable () -> Bool = { false },
        progress: (@Sendable (ProjectRecordsSnapshotProgress) -> Void)? = nil
    ) throws -> ProjectRecordsSnapshot {
        try limits.validate()
        if let projectID, projectID != self.projectID {
            throw ProjectRecordsSnapshotError.projectMismatch
        }
        if isCancelled() { throw ProjectRecordsSnapshotError.cancelled }

        let sourceRoot = container.rootURL
        let destination = try SnapshotFileSystem.resolveNewDirectory(
            destinationURL,
            sourceRoot: sourceRoot
        )
        if SnapshotFileSystem.kind(of: destination) != .missing {
            throw ProjectRecordsSnapshotError.outputExists(destination)
        }

        var keepDestination = false
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        defer {
            if !keepDestination {
                try? FileManager.default.removeItem(at: destination)
            }
        }

        let buildingDirectory = destination.appendingPathComponent(
            ProjectContainer.buildingDirectory,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: buildingDirectory, withIntermediateDirectories: true)
        let databaseURL = destination.appendingPathComponent(
            ProjectContainer.databaseRelativePath,
            isDirectory: false
        )

        let sourceState = try database.read { db -> ProjectRecordsStore.ProjectState in
            try ProjectRecordsStore.loadProjectState(db)
        }
        if let expectedRevision, sourceState.revision != expectedRevision {
            throw ProjectRecordsSnapshotError.revisionMismatch(
                expected: expectedRevision,
                actual: sourceState.revision
            )
        }
        let pageSize = try database.read { db in
            try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 4096
        }
        let pageCount = try database.read { db in
            try Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0
        }
        guard pageSize > 0, pageCount >= 0,
              pageSize <= limits.maxSingleFileBytes,
              pageCount <= limits.maxSingleFileBytes / pageSize else {
            throw ProjectRecordsSnapshotError.budgetExceeded(
                "the records database page count exceeds maxSingleFileBytes"
            )
        }
        let estimatedDatabaseBytes = pageCount * pageSize
        guard estimatedDatabaseBytes <= limits.maxSingleFileBytes else {
            throw ProjectRecordsSnapshotError.budgetExceeded(
                "the records database is approximately \(estimatedDatabaseBytes) bytes; the limit is \(limits.maxSingleFileBytes)"
            )
        }

        let destinationQueue = try DatabaseQueue(path: databaseURL.path)
        do {
            try database.backup(to: destinationQueue, pagesPerStep: 512) { backup in
                if isCancelled() { throw ProjectRecordsSnapshotError.cancelled }
                progress?(ProjectRecordsSnapshotProgress(
                    phase: .database,
                    completedFiles: backup.isCompleted ? 1 : 0,
                    totalFiles: 1,
                    completedBytes: min(backup.completedPageCount * pageSize, estimatedDatabaseBytes),
                    totalBytes: estimatedDatabaseBytes
                ))
            }
        } catch let error as ProjectRecordsSnapshotError {
            try? destinationQueue.close()
            throw error
        } catch {
            try? destinationQueue.close()
            if isCancelled() { throw ProjectRecordsSnapshotError.cancelled }
            throw ProjectRecordsSnapshotError.databaseSnapshotFailed(String(describing: error))
        }
        try destinationQueue.close()

        // Normalize the destination to a rollback-journal database. The online
        // backup may carry the source header's WAL format; a snapshot must be
        // readable without a -wal/-shm pair and must reopen through the normal
        // ProjectRecordsStore.openProject path.
        let normalizer = try DatabaseQueue(path: databaseURL.path)
        do {
            try normalizer.writeWithoutTransaction { db in
                _ = try Row.fetchOne(db, sql: "PRAGMA wal_checkpoint(TRUNCATE)")
                guard try String.fetchOne(db, sql: "PRAGMA journal_mode = DELETE") == "delete" else {
                    throw ProjectRecordsSnapshotError.databaseSnapshotFailed(
                        "the copied database did not enter rollback-journal mode"
                    )
                }
            }
            try normalizer.close()
        } catch {
            try? normalizer.close()
            throw ProjectRecordsSnapshotError.databaseSnapshotFailed(
                "the copied database could not be normalized: \(error)"
            )
        }
        try SnapshotFileSystem.removeClosedSnapshotSharedMemory(at: databaseURL)

        let copiedDatabaseBytes = try SnapshotFileSystem.fileSize(databaseURL)
        guard copiedDatabaseBytes <= limits.maxSingleFileBytes else {
            throw ProjectRecordsSnapshotError.budgetExceeded(
                "the copied records database is \(copiedDatabaseBytes) bytes; the limit is \(limits.maxSingleFileBytes)"
            )
        }
        let copiedDatabase = try SnapshotFileSystem.readDatabase(at: databaseURL)
        if let expectedRevision, copiedDatabase.revision != expectedRevision {
            throw ProjectRecordsSnapshotError.revisionMismatch(
                expected: expectedRevision,
                actual: copiedDatabase.revision
            )
        }

        let blobRows = copiedDatabase.blobs
        guard blobRows.count <= limits.maxFileCount - 1 else {
            throw ProjectRecordsSnapshotError.budgetExceeded(
                "the snapshot has more than \(limits.maxFileCount) files"
            )
        }
        var distinctShas: Set<String> = []
        var expectedBlobBytes = 0
        for row in blobRows {
            let sha: String = row["sha256"]
            let byteLength: Int = row["byte_length"]
            if distinctShas.insert(sha).inserted {
                guard byteLength >= 0, byteLength <= limits.maxSingleFileBytes else {
                    throw ProjectRecordsSnapshotError.budgetExceeded(
                        "source blob \(sha) has an invalid or oversized byte length"
                    )
                }
                expectedBlobBytes += byteLength
            } else {
                throw ProjectRecordsSnapshotError.invalidSnapshot("duplicate content_blob row \(sha)")
            }
        }
        guard copiedDatabaseBytes <= limits.maxTotalBytes,
              expectedBlobBytes <= limits.maxTotalBytes - copiedDatabaseBytes else {
            throw ProjectRecordsSnapshotError.budgetExceeded(
                "the snapshot exceeds maxTotalBytes \(limits.maxTotalBytes)"
            )
        }
        let totalFiles = blobRows.count + 1
        let totalBytes = copiedDatabaseBytes + expectedBlobBytes
        var completedFiles = 1
        var completedBytes = copiedDatabaseBytes
        progress?(ProjectRecordsSnapshotProgress(
            phase: .blobs,
            completedFiles: completedFiles,
            totalFiles: totalFiles,
            completedBytes: completedBytes,
            totalBytes: totalBytes
        ))

        if !blobRows.isEmpty {
            let blobDirectory = destination.appendingPathComponent(
                ProjectContainer.blobsDirectory,
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: blobDirectory, withIntermediateDirectories: true)
        }

        for row in blobRows {
            if isCancelled() { throw ProjectRecordsSnapshotError.cancelled }
            let sha: String = row["sha256"]
            let byteLength: Int = row["byte_length"]
            let relativePath: String = row["relative_path"]
            let expectedPath: String
            do {
                expectedPath = try container.blobRelativePath(for: sha)
            } catch {
                throw ProjectRecordsSnapshotError.corruptedBlob(sha)
            }
            guard relativePath == expectedPath else {
                throw ProjectRecordsSnapshotError.corruptedBlob(sha)
            }
            let sourceURL: URL
            do {
                sourceURL = try container.existingRegularFileURL(relativePath: relativePath)
            } catch ProjectFileError.missing {
                throw ProjectRecordsSnapshotError.missingBlob(sha)
            } catch {
                throw ProjectRecordsSnapshotError.corruptedBlob(sha)
            }
            let sourceBytes = try SnapshotFileSystem.fileSize(sourceURL)
            guard sourceBytes == byteLength else {
                throw ProjectRecordsSnapshotError.corruptedBlob(sha)
            }
            let destinationURL = destination.appendingPathComponent(relativePath, isDirectory: false)
            _ = try SnapshotFileSystem.copyFile(
                from: sourceURL,
                to: destinationURL,
                expectedByteCount: byteLength,
                expectedSHA256: sha,
                chunkBytes: limits.copyChunkBytes,
                isCancelled: isCancelled
            )
            completedFiles += 1
            completedBytes += byteLength
            progress?(ProjectRecordsSnapshotProgress(
                phase: .blobs,
                completedFiles: completedFiles,
                totalFiles: totalFiles,
                completedBytes: completedBytes,
                totalBytes: totalBytes
            ))
        }

        progress?(ProjectRecordsSnapshotProgress(
            phase: .verification,
            completedFiles: 0,
            totalFiles: totalFiles,
            completedBytes: 0,
            totalBytes: totalBytes
        ))
        if isCancelled() { throw ProjectRecordsSnapshotError.cancelled }
        let snapshot = try ProjectRecordsSnapshot.load(from: destination, limits: limits)
        guard snapshot.projectID == self.projectID else {
            throw ProjectRecordsSnapshotError.projectMismatch
        }
        if let expectedRevision, snapshot.revision != expectedRevision {
            throw ProjectRecordsSnapshotError.revisionMismatch(
                expected: expectedRevision,
                actual: snapshot.revision
            )
        }
        progress?(ProjectRecordsSnapshotProgress(
            phase: .verification,
            completedFiles: totalFiles,
            totalFiles: totalFiles,
            completedBytes: totalBytes,
            totalBytes: totalBytes
        ))
        keepDestination = true
        return snapshot
    }
}

// MARK: - Private filesystem helpers

private struct SnapshotFile {
    let relativePath: String
    let url: URL
    let byteCount: Int
    let sha256: String
}

private struct SnapshotDatabaseState {
    let projectID: ProjectID
    let revision: Int
    let blobs: [Row]
}

private enum SnapshotFileSystem {
    enum Kind {
        case missing
        case regular
        case directory
        case symbolicLink
        case other
    }

    static func kind(of url: URL) -> Kind {
        var info = stat()
        let result = url.path.withCString { lstat($0, &info) }
        guard result == 0 else {
            return errno == ENOENT || errno == ENOTDIR ? .missing : .other
        }
        let type = info.st_mode & S_IFMT
        if type == S_IFREG { return .regular }
        if type == S_IFDIR { return .directory }
        if type == S_IFLNK { return .symbolicLink }
        return .other
    }

    static func fileSize(_ url: URL) throws -> Int {
        var info = stat()
        let result = url.path.withCString { lstat($0, &info) }
        guard result == 0 else {
            throw ProjectRecordsSnapshotError.invalidSnapshot(
                "cannot read file attributes for \(url.lastPathComponent)"
            )
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw ProjectRecordsSnapshotError.invalidSnapshot(
                "\(url.lastPathComponent) is not a regular file"
            )
        }
        guard info.st_size >= 0, info.st_size <= Int64(Int.max) else {
            throw ProjectRecordsSnapshotError.invalidSnapshot(
                "\(url.lastPathComponent) has an invalid size"
            )
        }
        return Int(info.st_size)
    }

    /// Called only for this capture's new destination, after every writable
    /// connection has closed and SQLite confirmed DELETE journal mode. System
    /// SQLite can retain its derived -shm index after that mode transition.
    /// Never apply this cleanup to an arbitrary snapshot or the live source.
    static func removeClosedSnapshotSharedMemory(at databaseURL: URL) throws {
        let sharedMemory = URL(fileURLWithPath: databaseURL.path + "-shm")
        guard kind(of: sharedMemory) != .missing else { return }
        guard kind(of: databaseURL) == .regular,
              kind(of: sharedMemory) == .regular,
              kind(of: URL(fileURLWithPath: databaseURL.path + "-wal")) == .missing,
              kind(of: URL(fileURLWithPath: databaseURL.path + "-journal")) == .missing else {
            throw ProjectRecordsSnapshotError.databaseSnapshotFailed(
                "the copied database still has an active or invalid journal sidecar"
            )
        }
        let handle = try FileHandle(forReadingFrom: databaseURL)
        let header: Data?
        do {
            header = try handle.read(upToCount: 100)
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        guard let header, header.count >= 20,
              header.prefix(16) == Data("SQLite format 3\0".utf8),
              header[18] == 1, header[19] == 1 else {
            throw ProjectRecordsSnapshotError.databaseSnapshotFailed(
                "the copied database header is not in rollback-journal mode"
            )
        }
        try FileManager.default.removeItem(at: sharedMemory)
    }

    static func resolveNewDirectory(_ destinationURL: URL, sourceRoot: URL) throws -> URL {
        guard destinationURL.isFileURL else {
            throw ProjectRecordsSnapshotError.invalidDestination("the destination is not a file URL")
        }
        let standardized = destinationURL.standardizedFileURL
        let leaf = standardized.lastPathComponent
        guard !leaf.isEmpty, leaf != ".", leaf != "..", leaf != "/" else {
            throw ProjectRecordsSnapshotError.invalidDestination("the destination has no usable name")
        }
        let parent = standardized.deletingLastPathComponent()
        let resolvedParent = parent.resolvingSymlinksInPath().standardizedFileURL
        guard kind(of: resolvedParent) == .directory else {
            throw ProjectRecordsSnapshotError.invalidDestination("the destination parent is missing or not a directory")
        }
        let resolved = resolvedParent.appendingPathComponent(leaf, isDirectory: true).standardizedFileURL
        guard !isSameOrAncestor(sourceRoot, resolved) else {
            throw ProjectRecordsSnapshotError.destinationInsideSource
        }
        guard !isSameOrAncestor(resolved, sourceRoot) else {
            throw ProjectRecordsSnapshotError.sourceInsideDestination
        }
        return resolved
    }

    static func isSameOrAncestor(_ ancestor: URL, _ descendant: URL) -> Bool {
        let ancestorComponents = ancestor.standardizedFileURL.pathComponents
        let descendantComponents = descendant.standardizedFileURL.pathComponents
        guard descendantComponents.count >= ancestorComponents.count else { return false }
        return Array(descendantComponents.prefix(ancestorComponents.count)) == ancestorComponents
    }

    static func validateSnapshotPaths(_ files: [SnapshotFile], databaseRelativePath: String) throws {
        var databaseCount = 0
        for file in files {
            if file.relativePath == databaseRelativePath {
                databaseCount += 1
                continue
            }
            let components = file.relativePath
                .split(separator: "/", omittingEmptySubsequences: false)
                .map(String.init)
            guard components.count == 5,
                  components[0] == "Building",
                  components[1] == "Sources",
                  components[2] == "blobs",
                  components[3].count == 2,
                  components[4].count == 64 else {
                throw ProjectRecordsSnapshotError.invalidSnapshot(
                    "the snapshot contains an unexpected file at \(file.relativePath)"
                )
            }
            let prefix = String(components[3])
            let digest = String(components[4])
            guard prefix.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }),
                  digest.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }),
                  digest.hasPrefix(prefix) else {
                throw ProjectRecordsSnapshotError.invalidSnapshot(
                    "the snapshot contains an invalid content-addressed path at \(file.relativePath)"
                )
            }
        }
        guard databaseCount == 1 else {
            throw ProjectRecordsSnapshotError.invalidSnapshot("the snapshot must contain exactly one records database")
        }
    }

    static func scanFiles(
        root: URL,
        limits: ProjectRecordsSnapshotLimits,
        isCancelled: @Sendable () -> Bool
    ) throws -> [SnapshotFile] {
        var result: [SnapshotFile] = []
        var seenPaths: Set<String> = []
        var totalBytes = 0
        try walk(
            directory: root,
            prefix: "",
            depth: 0,
            limits: limits,
            isCancelled: isCancelled,
            result: &result,
            seenPaths: &seenPaths,
            totalBytes: &totalBytes
        )
        return result.sorted { $0.relativePath < $1.relativePath }
    }

    private static func walk(
        directory: URL,
        prefix: String,
        depth: Int,
        limits: ProjectRecordsSnapshotLimits,
        isCancelled: @Sendable () -> Bool,
        result: inout [SnapshotFile],
        seenPaths: inout Set<String>,
        totalBytes: inout Int
    ) throws {
        if isCancelled() { throw ProjectRecordsSnapshotError.cancelled }
        guard depth <= 64 else {
            throw ProjectRecordsSnapshotError.budgetExceeded("directory depth exceeds 64")
        }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        } catch {
            throw ProjectRecordsSnapshotError.invalidSnapshot(
                "cannot list \(directory.lastPathComponent)"
            )
        }
        for name in names {
            if isCancelled() { throw ProjectRecordsSnapshotError.cancelled }
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
                throw ProjectRecordsSnapshotError.invalidSnapshot("invalid file name in snapshot")
            }
            let relativePath = prefix.isEmpty ? name : prefix + "/" + name
            guard relativePath.utf8.count <= 1024 else {
                throw ProjectRecordsSnapshotError.budgetExceeded("a snapshot path is longer than 1024 bytes")
            }
            let child = directory.appendingPathComponent(name, isDirectory: false)
            switch kind(of: child) {
            case .directory:
                try walk(
                    directory: child,
                    prefix: relativePath,
                    depth: depth + 1,
                    limits: limits,
                    isCancelled: isCancelled,
                    result: &result,
                    seenPaths: &seenPaths,
                    totalBytes: &totalBytes
                )
            case .regular:
                guard result.count < limits.maxFileCount else {
                    throw ProjectRecordsSnapshotError.budgetExceeded(
                        "the snapshot has more than \(limits.maxFileCount) files"
                    )
                }
                let folded = relativePath.lowercased()
                guard seenPaths.insert(folded).inserted else {
                    throw ProjectRecordsSnapshotError.invalidSnapshot(
                        "duplicate snapshot path \(relativePath)"
                    )
                }
                let byteCount = try fileSize(child)
                guard byteCount <= limits.maxSingleFileBytes else {
                    throw ProjectRecordsSnapshotError.budgetExceeded(
                        "\(relativePath) is \(byteCount) bytes; the limit is \(limits.maxSingleFileBytes)"
                    )
                }
                guard totalBytes <= limits.maxTotalBytes - byteCount else {
                    throw ProjectRecordsSnapshotError.budgetExceeded(
                        "the snapshot exceeds maxTotalBytes \(limits.maxTotalBytes)"
                    )
                }
                totalBytes += byteCount
                let digest = try hashFile(
                    child,
                    chunkBytes: limits.copyChunkBytes,
                    isCancelled: isCancelled
                )
                result.append(SnapshotFile(
                    relativePath: relativePath,
                    url: child,
                    byteCount: digest.byteCount,
                    sha256: digest.sha256
                ))
            case .symbolicLink:
                throw ProjectRecordsSnapshotError.invalidSnapshot(
                    "the snapshot contains a symbolic link at \(relativePath)"
                )
            case .other:
                throw ProjectRecordsSnapshotError.invalidSnapshot(
                    "the snapshot contains a non-regular entry at \(relativePath)"
                )
            case .missing:
                throw ProjectRecordsSnapshotError.invalidSnapshot(
                    "a snapshot entry disappeared at \(relativePath)"
                )
            }
        }
    }

    static func hashFile(
        _ url: URL,
        chunkBytes: Int,
        isCancelled: @Sendable () -> Bool
    ) throws -> (sha256: String, byteCount: Int) {
        guard kind(of: url) == .regular else {
            throw ProjectRecordsSnapshotError.invalidSnapshot(
                "\(url.lastPathComponent) is not a regular file"
            )
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var total = 0
        while let chunk = try handle.read(upToCount: chunkBytes), !chunk.isEmpty {
            if isCancelled() { throw ProjectRecordsSnapshotError.cancelled }
            total += chunk.count
            hasher.update(data: chunk)
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), total)
    }

    static func copyFile(
        from source: URL,
        to destination: URL,
        expectedByteCount: Int,
        expectedSHA256: String,
        chunkBytes: Int,
        isCancelled: @Sendable () -> Bool
    ) throws -> (sha256: String, byteCount: Int) {
        if isCancelled() { throw ProjectRecordsSnapshotError.cancelled }
        guard expectedByteCount >= 0 else {
            throw ProjectRecordsSnapshotError.corruptedBlob(expectedSHA256)
        }
        guard kind(of: source) == .regular else {
            throw ProjectRecordsSnapshotError.corruptedBlob(expectedSHA256)
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard fileManager.createFile(
            atPath: destination.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw ProjectRecordsSnapshotError.invalidSnapshot(
                "cannot create \(destination.lastPathComponent)"
            )
        }
        let input = try FileHandle(forReadingFrom: source)
        var output: FileHandle?
        var completed = false
        defer {
            try? input.close()
            if let output {
                try? output.close()
            }
            if !completed {
                try? fileManager.removeItem(at: destination)
            }
        }
        let writer = try FileHandle(forWritingTo: destination)
        output = writer
        var hasher = SHA256()
        var total = 0
        while let chunk = try input.read(upToCount: chunkBytes), !chunk.isEmpty {
            if isCancelled() { throw ProjectRecordsSnapshotError.cancelled }
            total += chunk.count
            guard total <= expectedByteCount else {
                throw ProjectRecordsSnapshotError.corruptedBlob(expectedSHA256)
            }
            hasher.update(data: chunk)
            try writer.write(contentsOf: chunk)
        }
        guard total == expectedByteCount else {
            throw ProjectRecordsSnapshotError.corruptedBlob(expectedSHA256)
        }
        try writer.synchronize()
        try writer.close()
        output = nil
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == expectedSHA256 else {
            throw ProjectRecordsSnapshotError.corruptedBlob(expectedSHA256)
        }
        let readback = try hashFile(destination, chunkBytes: chunkBytes, isCancelled: isCancelled)
        guard readback.sha256 == digest, readback.byteCount == total else {
            throw ProjectRecordsSnapshotError.invalidSnapshot(
                "the copied blob did not read back with the same bytes"
            )
        }
        completed = true
        return (digest, total)
    }

    static func readDatabase(at url: URL) throws -> SnapshotDatabaseState {
        guard kind(of: url) == .regular else {
            throw ProjectRecordsSnapshotError.invalidSnapshot("the records database is missing")
        }
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        do {
            let state = try queue.read { db -> ProjectRecordsStore.ProjectState in
                try ProjectRecordsStore.loadProjectState(db)
            }
            let check = try queue.read { db in
                try String.fetchAll(db, sql: "PRAGMA quick_check")
            }
            guard check == ["ok"] else {
                throw ProjectRecordsSnapshotError.invalidSnapshot(
                    "the records database failed quick_check"
                )
            }
            let foreignKeyRows = try queue.read { db in
                try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
            }
            guard foreignKeyRows.isEmpty else {
                throw ProjectRecordsSnapshotError.invalidSnapshot(
                    "the records database has foreign key violations"
                )
            }
            let blobs = try queue.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                        SELECT sha256, byte_length, relative_path
                        FROM content_blob
                        ORDER BY sha256
                        """
                )
            }
            try queue.close()
            return SnapshotDatabaseState(
                projectID: state.id,
                revision: state.revision,
                blobs: blobs
            )
        } catch let error as ProjectRecordsSnapshotError {
            try? queue.close()
            throw error
        } catch {
            try? queue.close()
            throw ProjectRecordsSnapshotError.invalidSnapshot(String(describing: error))
        }
    }
}
