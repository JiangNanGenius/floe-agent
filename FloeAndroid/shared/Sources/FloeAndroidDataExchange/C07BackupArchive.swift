// SPDX-License-Identifier: MPL-2.0
//
// `.floebackup` writer and strict reader.
//
// Write path: every source byte is copied into a private staging tree with a
// simultaneous SHA-256/size readback; the manifest is built from the staged
// records; the ZIP is written and then read back entry-by-entry before the
// final file is published. A failed export never leaves a destination file.
//
// Read path: entries stream into a private staging directory with duplicate,
// path, type, size, compression-ratio and digest checks BEFORE the manifest is
// trusted. The manifest must describe exactly the staged regular-file set.
// Restore inspection never touches live App storage.
import Foundation
import Crypto
import ZIPFoundation

public struct C07BuiltBackup: Sendable, Equatable {
    public var fileURL: URL
    public var manifest: C07BackupManifest
    public var byteCount: Int64
    public var sha256: String
    public var warnings: [String]
}

public struct C07StagedProjectFile: Sendable, Equatable {
    public var relativePath: String
    public var stagedURL: URL
    public var byteCount: Int64
    public var sha256: String
    public var mode: Int

    public init(relativePath: String, stagedURL: URL, byteCount: Int64,
                sha256: String, mode: Int = 0o644) {
        self.relativePath = relativePath
        self.stagedURL = stagedURL
        self.byteCount = byteCount
        self.sha256 = sha256
        self.mode = mode
    }
}

public struct C07StagedProject: Sendable, Equatable {
    public var record: C07ProjectRecord
    public var files: [C07StagedProjectFile]

    public var restoreSkipped: Bool { !record.warnings.isEmpty && record.files.isEmpty }
}

public struct C07RestorePlan: Sendable {
    public var manifest: C07BackupManifest
    public var manifestSHA256: String
    public var stagedRoot: URL
    public var projects: [C07StagedProject]
    public var notes: [C07ParsedNoteArchive]
    public var settingsValues: [String: String]
    public var warnings: [String]
    public var totalBytes: Int64

    public init(manifest: C07BackupManifest,
                manifestSHA256: String,
                stagedRoot: URL,
                projects: [C07StagedProject],
                notes: [C07ParsedNoteArchive],
                settingsValues: [String: String],
                warnings: [String],
                totalBytes: Int64) {
        self.manifest = manifest
        self.manifestSHA256 = manifestSHA256
        self.stagedRoot = stagedRoot
        self.projects = projects
        self.notes = notes
        self.settingsValues = settingsValues
        self.warnings = warnings
        self.totalBytes = totalBytes
    }

    public var noteDocumentCount: Int { notes.reduce(0) { $0 + $1.documents.count } }
    public var noteResourceCount: Int { notes.reduce(0) { $0 + $1.resources.count } }
    public var projectFileCount: Int { projects.reduce(0) { $0 + $1.files.count } }
    public var skippedProjectCount: Int { projects.filter(\.restoreSkipped).count }
}

// MARK: - Builder

/// Untrusted ZIP size fields are UInt64; an unchecked Int64 conversion traps.
/// Every entry size therefore passes this bounded conversion first.
func c07CheckedEntrySize(_ value: UInt64, _ path: String) throws -> Int64 {
    guard value <= UInt64(Int64.max) else {
        throw C07DataExchangeError.entryTooLarge(path)
    }
    return Int64(value)
}

public enum C07BackupBuilder {
    private struct EnumeratedProject {
        var directories: [String]
        var files: [(relativePath: String, url: URL, byteCount: Int64, mode: Int)]
    }

    /// Builds one validated backup. `destination` must not exist. The caller
    /// owns `stagingRoot`; a unique child is created and removed here.
    public static func build(
        source: C07BackupSource,
        destination: URL,
        stagingRoot: URL,
        progress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws -> C07BuiltBackup {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw C07DataExchangeError.storageUnavailable("destinationExists")
        }
        try C07FileSystem.ensureDirectory(stagingRoot)
        let staging = stagingRoot.appendingPathComponent(
            "backup-\(UUID().uuidString)", isDirectory: true)
        try C07FileSystem.ensureDirectory(staging)
        defer { C07FileSystem.removeIfPresent(staging) }

        guard source.projects.count <= C07DataExchangeLimits.maximumProjects,
              source.notes.count <= C07DataExchangeLimits.maximumNoteDocuments,
              source.notebooks.count <= C07DataExchangeLimits.maximumNotebooks else {
            throw C07DataExchangeError.tooManyEntries
        }
        let notebookIDs = Set(source.notebooks.map(\.notebookID))
        guard source.projects.allSatisfy({
                  !$0.name.isEmpty
                      && $0.name.utf8.count <= C07DataExchangeLimits.maximumProjectNameBytes
              }),
              notebookIDs.count == source.notebooks.count,
              Set(source.notes.map(\.documentID)).count == source.notes.count,
              source.providerCatalog.count <= 64,
              source.notebooks.allSatisfy({
                  !$0.title.isEmpty
                      && $0.title.utf8.count <= C07DataExchangeLimits.maximumNotebookTitleBytes
              }),
              source.notes.allSatisfy({
                  !$0.title.isEmpty
                      && $0.title.utf8.count <= C07DataExchangeLimits.maximumNoteTitleBytes
                      && ($0.notebookID.map { notebookIDs.contains($0) } ?? true)
              }) else {
            throw C07DataExchangeError.invalidManifest("notesCatalog")
        }
        var warnings = source.warnings
        var projectRecords: [C07ProjectRecord] = []
        var totalEstimate: Int64 = 0
        var seenProjectIDs = Set<UUID>()
        var archivePaths = Set<String>()
        var totalFileCount = 0
        var totalCopyBytes: Int64 = 0

        // Enumerate first so the progress total is real and unsafe roots can
        // be declared without copying a partial project.
        var enumerated: [(C07SourceProject, EnumeratedProject)] = []
        for project in source.projects {
            guard seenProjectIDs.insert(project.projectID).inserted else {
                throw C07DataExchangeError.invalidManifest("duplicateProject")
            }
            if let reason = project.unavailableReason {
                projectRecords.append(C07ProjectRecord(
                    projectID: project.projectID, name: project.name,
                    origin: project.origin, createdAt: project.createdAt,
                    warnings: ["projectUnavailable:\(reason)"]))
                warnings.append("projectUnavailable:\(project.name)")
                continue
            }
            guard let root = project.rootURL else {
                projectRecords.append(C07ProjectRecord(
                    projectID: project.projectID, name: project.name,
                    origin: project.origin, createdAt: project.createdAt,
                    warnings: ["projectRootMissing"]))
                warnings.append("projectRootMissing:\(project.name)")
                continue
            }
            do {
                let value = try enumerateProject(root: root)
                enumerated.append((project, value))
                totalEstimate += value.files.reduce(0) { $0 + $1.byteCount }
            } catch let error as C07DataExchangeError {
                projectRecords.append(C07ProjectRecord(
                    projectID: project.projectID, name: project.name,
                    origin: project.origin, createdAt: project.createdAt,
                    warnings: ["projectRejected:\(error.code)"]))
                warnings.append("projectRejected:\(project.name):\(error.code)")
            }
        }

        let settingsValues = C07SettingsPolicy.sanitize(source.settingsValues)
        let omittedSettings = source.settingsValues.count - settingsValues.count
        if omittedSettings > 0 {
            warnings.append("settingsOmitted:\(omittedSettings)")
        }
        let settingsData: Data? = settingsValues.isEmpty ? nil : try encodeSettings(settingsValues)
        if let settingsData {
            totalEstimate += Int64(settingsData.count)
        }
        for note in source.notes {
            if let digest = try? C07Digest.file(note.archiveURL) {
                totalEstimate += digest.byteCount
            }
        }
        let estimatedTotal = totalEstimate
        let projected = estimatedTotal > Int64.max / 2
            ? Int64.max : estimatedTotal * 2
        try C07FileSystem.requireFreeSpace(at: stagingRoot, bytes: projected)
        var done: Int64 = 0
        progress?(0, estimatedTotal)

        // Project payloads.
        for (project, value) in enumerated {
            var records: [C07ProjectFileRecord] = []
            for file in value.files {
                let archivePath = C07Path.archivePath(
                    origin: project.origin,
                    projectID: project.projectID,
                    relativePath: file.relativePath)
                guard archivePaths.insert(C07Path.collisionKey(archivePath)).inserted else {
                    throw C07DataExchangeError.caseCollision(archivePath)
                }
                totalFileCount += 1
                guard totalFileCount <= C07DataExchangeLimits.maximumEntries else {
                    throw C07DataExchangeError.tooManyEntries
                }
                let stagedURL = staging.appendingPathComponent(archivePath)
                try C07FileSystem.ensureDirectory(stagedURL.deletingLastPathComponent())
                let result = try C07FileSystem.copyVerified(
                    source: file.url, destination: stagedURL,
                    expectedSize: file.byteCount)
                totalCopyBytes += result.byteCount
                guard totalCopyBytes <= C07DataExchangeLimits.maximumTotalBytes else {
                    throw C07DataExchangeError.totalTooLarge
                }
                records.append(C07ProjectFileRecord(
                    relativePath: file.relativePath,
                    byteCount: result.byteCount,
                    sha256: result.sha256,
                    mode: file.mode))
                done += result.byteCount
                progress?(done, estimatedTotal)
            }
            projectRecords.append(C07ProjectRecord(
                projectID: project.projectID, name: project.name,
                origin: project.origin, createdAt: project.createdAt,
                files: records, directories: value.directories))
        }

        // Portable Notes archives (already produced by NotesArchive).
        var noteRecords: [C07NoteDocumentRecord] = []
        var noteFailures = source.failedNotes
        for note in source.notes {
            let archivePath = C07Path.noteArchivePath(documentID: note.documentID)
            guard archivePaths.insert(C07Path.collisionKey(archivePath)).inserted else {
                throw C07DataExchangeError.caseCollision(archivePath)
            }
            totalFileCount += 1
            guard totalFileCount <= C07DataExchangeLimits.maximumEntries else {
                throw C07DataExchangeError.tooManyEntries
            }
            let stagedURL = staging.appendingPathComponent(archivePath)
            try C07FileSystem.ensureDirectory(stagedURL.deletingLastPathComponent())
            do {
                let digest = try C07Digest.file(
                    note.archiveURL, maximum: C07DataExchangeLimits.maximumNoteArchiveBytes)
                let copied = try C07FileSystem.copyVerified(
                    source: note.archiveURL, destination: stagedURL,
                    expectedSize: digest.byteCount,
                    maximum: C07DataExchangeLimits.maximumNoteArchiveBytes)
                // Validate the nested iOS-format document package before it
                // becomes part of a backup that claims to be restorable. The
                // validation tree stays OUTSIDE the staging tree so it can
                // never leak into the manifest/archive entry set.
                let validation = staging.deletingLastPathComponent()
                    .appendingPathComponent(
                        ".note-validation-\(UUID().uuidString)", isDirectory: true)
                do {
                    _ = try C07NotesPackage.parse(
                        archiveURL: stagedURL,
                        stagingRoot: validation,
                        expectedDocumentID: note.documentID,
                        metadataTitle: note.title)
                    C07FileSystem.removeIfPresent(validation)
                } catch {
                    C07FileSystem.removeIfPresent(validation)
                    throw error
                }
                totalCopyBytes += copied.byteCount
                guard totalCopyBytes <= C07DataExchangeLimits.maximumTotalBytes else {
                    throw C07DataExchangeError.totalTooLarge
                }
                noteRecords.append(C07NoteDocumentRecord(
                    documentID: note.documentID, notebookID: note.notebookID,
                    title: note.title, byteCount: copied.byteCount,
                    sha256: copied.sha256))
                done += copied.byteCount
                progress?(done, estimatedTotal)
            } catch let error as C07DataExchangeError {
                C07FileSystem.removeIfPresent(stagedURL)
                noteFailures.append(C07FailedNote(
                    documentID: note.documentID, title: note.title,
                    reason: error.code))
                warnings.append("noteRejected:\(note.documentID.uuidString):\(error.code)")
            }
        }
        let notes = C07NotesRecord(
            notebooks: source.notebooks,
            documents: noteRecords,
            trashedDocumentsExcluded: source.trashedNotesExcluded,
            failedDocuments: noteFailures)

        // Safe preferences.
        var settingsRecord = C07SettingsRecord(
            entry: nil, byteCount: 0, sha256: nil, keys: [],
            providerCatalog: source.providerCatalog)
        if let settingsData {
            let stagedURL = staging.appendingPathComponent(C07Path.settingsArchivePath)
            try C07FileSystem.ensureDirectory(stagedURL.deletingLastPathComponent())
            try settingsData.write(to: stagedURL)
            let copied = try C07Digest.file(stagedURL)
            totalCopyBytes += copied.byteCount
            guard totalCopyBytes <= C07DataExchangeLimits.maximumTotalBytes else {
                throw C07DataExchangeError.totalTooLarge
            }
            settingsRecord = C07SettingsRecord(
                entry: C07Path.settingsArchivePath,
                byteCount: copied.byteCount, sha256: copied.sha256,
                keys: settingsValues.keys.sorted(),
                providerCatalog: source.providerCatalog)
            done += copied.byteCount
            progress?(done, estimatedTotal)
        }

        let manifest = C07BackupManifest(
            createdAt: source.createdAt,
            appSchemaVersion: source.appSchemaVersion,
            scope: C07BackupScope(excluded: C07ScopePolicy.excluded),
            projects: projectRecords,
            notes: notes,
            settings: settingsRecord,
            warnings: warnings)
        try C07ScopePolicy.validate(manifest.scope)
        let manifestData = try manifest.encoded()
        guard manifestData.count <= C07DataExchangeLimits.maximumManifestBytes else {
            throw C07DataExchangeError.entryTooLarge(C07Path.manifestArchivePath)
        }
        let manifestURL = staging.appendingPathComponent(C07Path.manifestArchivePath)
        try manifestData.write(to: manifestURL)

        // The staging tree and the ZIP coexist; both are bounded.
        let stagedBytes = try directoryByteCount(staging)
        guard stagedBytes + Int64(manifestData.count)
                <= C07DataExchangeLimits.maximumTotalBytes else {
            throw C07DataExchangeError.totalTooLarge
        }
        try C07FileSystem.requireFreeSpace(
            at: stagingRoot, bytes: stagedBytes + Int64(manifestData.count))
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).partial")
        defer { C07FileSystem.removeIfPresent(temporary) }
        try await writeArchive(from: staging, to: temporary, progress: progress,
                               total: estimatedTotal, done: done)
        let verified = try verifyArchive(temporary, manifest: manifest,
                                         manifestData: manifestData)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return C07BuiltBackup(fileURL: destination, manifest: manifest,
                              byteCount: verified.byteCount, sha256: verified.sha256,
                              warnings: warnings)
    }

    private static func enumerateProject(root: URL) throws -> EnumeratedProject {
        let values = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true else {
            throw C07DataExchangeError.symlinkUnsupported(root.lastPathComponent)
        }
        let rootPath = root.standardizedFileURL.path
        var enumerationFailure: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey,
                                          .isSymbolicLinkKey, .fileSizeKey,
                                          .posixPermissionsKey],
            options: [],
            errorHandler: { _, error in
                enumerationFailure = error
                return false
            }) else {
            throw C07DataExchangeError.storageUnavailable("enumerateProject")
        }
        var directories: [String] = []
        var files: [(String, URL, Int64)] = []
        var seen = Set<String>()
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let relative = relativePath(rootPath: rootPath, url: url)
            try C07Path.validateRelative(relative)
            guard seen.insert(C07Path.collisionKey(relative)).inserted else {
                throw C07DataExchangeError.caseCollision(relative)
            }
            let resource = try url.resourceValues(forKeys: [
                .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
                .fileSizeKey, .posixPermissionsKey,
            ])
            if resource.isSymbolicLink == true {
                throw C07DataExchangeError.symlinkUnsupported(relative)
            }
            if resource.isDirectory == true {
                directories.append(relative)
            } else if resource.isRegularFile == true {
                let size = Int64(resource.fileSize ?? 0)
                guard size >= 0, size <= C07DataExchangeLimits.maximumEntryBytes else {
                    throw C07DataExchangeError.entryTooLarge(relative)
                }
                let mode = Int(resource.posixPermissions ?? 0o644) & 0o777
                files.append((relativePath: relative, url: url, byteCount: size, mode: mode))
            } else {
                throw C07DataExchangeError.specialFileUnsupported(relative)
            }
        }
        if enumerationFailure != nil {
            throw C07DataExchangeError.storageUnavailable("enumerateProject")
        }
        files.sort { $0.0 < $1.0 }
        directories.sort()
        return EnumeratedProject(directories: directories, files: files)
    }

    private static func relativePath(rootPath: String, url: URL) -> String {
        let path = url.standardizedFileURL.path
        if path == rootPath { return "" }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return String(path.dropFirst(prefix.count))
    }

    private static func encodeSettings(_ values: [String: String]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(values),
              data.count <= Int(C07DataExchangeLimits.maximumSettingsBytes),
              values.keys.allSatisfy(C07SettingsPolicy.isAllowedKey) else {
            throw C07DataExchangeError.invalidScope("settings")
        }
        return data
    }

    private static func directoryByteCount(_ root: URL) throws -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: []) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.fileSize ?? 0)
            guard total <= C07DataExchangeLimits.maximumTotalBytes else {
                throw C07DataExchangeError.totalTooLarge
            }
        }
        return total
    }

    private static func writeArchive(
        from root: URL,
        to destination: URL,
        progress: (@Sendable (Int64, Int64) -> Void)?,
        total: Int64,
        done base: Int64
    ) async throws {
        let archive: Archive
        do { archive = try Archive(url: destination, accessMode: .create) }
        catch { throw C07DataExchangeError.storageUnavailable("createArchive") }
        var entries: [(archivePath: String, url: URL, size: Int64)] = []
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: []) else {
            throw C07DataExchangeError.storageUnavailable("enumerateStaging")
        }
        let rootPath = root.standardizedFileURL.path
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey])
            let relative = relativePath(rootPath: rootPath, url: url)
            guard !relative.isEmpty else { continue }
            if values?.isDirectory == true {
                // Directories are implicit in the manifest's directory list;
                // the ZIP stays a regular-file-only package.
                continue
            }
            guard values?.isRegularFile == true else {
                throw C07DataExchangeError.specialFileUnsupported(relative)
            }
            entries.append((relative, url, Int64(values?.fileSize ?? 0)))
        }
        entries.sort { $0.archivePath < $1.archivePath }
        var written: Int64 = 0
        for entry in entries {
            let handle: FileHandle
            do { handle = try FileHandle(forReadingFrom: entry.url) }
            catch { throw C07DataExchangeError.storageUnavailable("openStaged") }
            let compression: CompressionMethod =
                entry.archivePath == C07Path.manifestArchivePath
                    || entry.archivePath == C07Path.settingsArchivePath
                ? .deflate : .none
            do {
                try archive.addEntry(
                    with: entry.archivePath, type: .file,
                    uncompressedSize: entry.size,
                    compressionMethod: compression) { position, size in
                        try Task.checkCancellation()
                        try handle.seek(toOffset: UInt64(position))
                        return try handle.read(upToCount: size) ?? Data()
                    }
                try? handle.close()
            } catch is CancellationError {
                try? handle.close()
                throw C07DataExchangeError.cancelled
            } catch {
                try? handle.close()
                throw C07DataExchangeError.storageUnavailable("writeArchive")
            }
            written += entry.size
            progress?(base + written, total)
            if written > C07DataExchangeLimits.maximumTotalBytes {
                throw C07DataExchangeError.totalTooLarge
            }
        }
    }

    private static func verifyArchive(
        _ url: URL,
        manifest: C07BackupManifest,
        manifestData: Data
    ) throws -> (byteCount: Int64, sha256: String) {
        let archive: Archive
        do { archive = try Archive(url: url, accessMode: .read) }
        catch { throw C07DataExchangeError.corruptArchive("open") }
        let expected = try expectedArchivePaths(manifest)
        var seen = Set<String>()
        var total: Int64 = 0
        for entry in archive {
            guard entry.type == .file else { continue }
            let path: String
            do { path = try C07Path.validateRelative(entry.path) }
            catch { throw C07DataExchangeError.unsafePath(entry.path) }
            guard expected.contains(path) else {
                throw C07DataExchangeError.invalidManifest("extraEntry:\(path)")
            }
            guard seen.insert(path).inserted else {
                throw C07DataExchangeError.duplicateEntry(path)
            }
            let size = try c07CheckedEntrySize(entry.uncompressedSize, entry.path)
            guard size >= 0, size <= C07DataExchangeLimits.maximumEntryBytes else {
                throw C07DataExchangeError.entryTooLarge(path)
            }
            total += size
            guard total <= C07DataExchangeLimits.maximumTotalBytes else {
                throw C07DataExchangeError.totalTooLarge
            }
            var hasher = SHA256Box()
            var readback: Int64 = 0
            do {
                _ = try archive.extract(entry, skipCRC32: false) { chunk in
                    readback += Int64(chunk.count)
                    hasher.update(chunk)
                }
            } catch { throw C07DataExchangeError.corruptArchive("extract:\(path)") }
            guard readback == size else {
                throw C07DataExchangeError.sizeMismatch(path)
            }
            let readbackHash = hasher.finalize()
            if path == C07Path.manifestArchivePath {
                guard readbackHash == C07Digest.sha256(manifestData),
                      readback == Int64(manifestData.count) else {
                    throw C07DataExchangeError.hashMismatch(path)
                }
            } else {
                let expectedHash = expectedHash(for: path, manifest: manifest)
                guard readbackHash == expectedHash else {
                    throw C07DataExchangeError.hashMismatch(path)
                }
            }
        }
        guard seen == expected else {
            throw C07DataExchangeError.invalidManifest("missingEntries")
        }
        let digest = try C07Digest.file(url)
        return (digest.byteCount, digest.sha256)
    }

    private static func expectedArchivePaths(_ manifest: C07BackupManifest) throws -> Set<String> {
        var paths = Set<String>()
        for project in manifest.projects {
            for file in project.files {
                paths.insert(C07Path.archivePath(
                    origin: project.origin, projectID: project.projectID,
                    relativePath: file.relativePath))
            }
        }
        for doc in manifest.notes.documents {
            paths.insert(C07Path.noteArchivePath(documentID: doc.documentID))
        }
        if let entry = manifest.settings.entry {
            guard entry == C07Path.settingsArchivePath else {
                throw C07DataExchangeError.invalidManifest("settingsEntry")
            }
            paths.insert(entry)
        }
        paths.insert(C07Path.manifestArchivePath)
        return paths
    }

    private static func expectedHash(for path: String, manifest: C07BackupManifest) -> String {
        for project in manifest.projects {
            for file in project.files where
                C07Path.archivePath(origin: project.origin,
                                    projectID: project.projectID,
                                    relativePath: file.relativePath) == path {
                return file.sha256
            }
        }
        for doc in manifest.notes.documents where
            C07Path.noteArchivePath(documentID: doc.documentID) == path {
            return doc.sha256
        }
        if path == C07Path.settingsArchivePath {
            return manifest.settings.sha256 ?? ""
        }
        return ""
    }
}

// MARK: - Reader

public enum C07BackupReader {
    /// Extracts and fully validates a backup into a private stage. No live
    /// App store, project, note, setting or file is touched.
    public static func inspect(
        archiveURL: URL,
        stagingRoot: URL,
        currentAppSchemaVersion: Int,
        progress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws -> C07RestorePlan {
        try C07FileSystem.ensureDirectory(stagingRoot)
        let stage = stagingRoot.appendingPathComponent(
            "restore-\(UUID().uuidString)", isDirectory: true)
        try C07FileSystem.ensureDirectory(stage)
        var keepStage = false
        defer { if !keepStage { C07FileSystem.removeIfPresent(stage) } }

        let archive: Archive
        do { archive = try Archive(url: archiveURL, accessMode: .read) }
        catch { throw C07DataExchangeError.corruptArchive("open") }

        let entriesRoot = stage.appendingPathComponent("entries", isDirectory: true)
        try C07FileSystem.ensureDirectory(entriesRoot)
        var staged: [String: URL] = [:]
        var sizes: [String: Int64] = [:]
        var hashes: [String: String] = [:]
        var total: Int64 = 0
        var count = 0
        var estimatedTotal: Int64 = 0

        // First pass only records sizes for a real progress total, with the
        // same entry/total bounds applied before any byte is written.
        var firstPassCount = 0
        for entry in archive where entry.type == .file {
            firstPassCount += 1
            guard firstPassCount <= C07DataExchangeLimits.maximumEntries else {
                throw C07DataExchangeError.tooManyEntries
            }
            let size = try c07CheckedEntrySize(entry.uncompressedSize, entry.path)
            guard size >= 0, size <= C07DataExchangeLimits.maximumEntryBytes else {
                throw C07DataExchangeError.entryTooLarge(entry.path)
            }
            estimatedTotal += size
            guard estimatedTotal <= C07DataExchangeLimits.maximumTotalBytes else {
                throw C07DataExchangeError.totalTooLarge
            }
        }
        if let available = C07FileSystem.availableBytes(at: stagingRoot),
           available < estimatedTotal + C07DataExchangeLimits.freeSpaceHeadroom {
            throw C07DataExchangeError.freeSpaceInsufficient(
                required: estimatedTotal + C07DataExchangeLimits.freeSpaceHeadroom,
                available: available)
        }
        progress?(0, estimatedTotal)

        for entry in archive {
            let path: String
            if entry.type == .directory {
                var directoryPath = entry.path
                while directoryPath.hasSuffix("/") { directoryPath.removeLast() }
                do { _ = try C07Path.validateRelative(directoryPath) }
                catch { throw C07DataExchangeError.unsafePath(entry.path) }
                continue
            }
            guard entry.type == .file else {
                throw C07DataExchangeError.symlinkUnsupported(entry.path)
            }
            count += 1
            guard count <= C07DataExchangeLimits.maximumEntries else {
                throw C07DataExchangeError.tooManyEntries
            }
            do { path = try C07Path.validateRelative(entry.path) }
            catch { throw C07DataExchangeError.unsafePath(entry.path) }
            guard staged[path] == nil else {
                throw C07DataExchangeError.duplicateEntry(path)
            }
            let size = try c07CheckedEntrySize(entry.uncompressedSize, entry.path)
            guard size >= 0, size <= C07DataExchangeLimits.maximumEntryBytes else {
                throw C07DataExchangeError.entryTooLarge(path)
            }
            if size > C07DataExchangeLimits.compressionRatioProbeBytes {
                let compressed = try c07CheckedEntrySize(entry.compressedSize, path)
                if compressed > 0 {
                    let ratio = Double(size) / Double(compressed)
                    guard ratio <= C07DataExchangeLimits.maximumCompressionRatio else {
                        throw C07DataExchangeError.corruptArchive("compressionRatio")
                    }
                }
            }
            total += size
            guard total <= C07DataExchangeLimits.maximumTotalBytes else {
                throw C07DataExchangeError.totalTooLarge
            }
            let stagedURL = entriesRoot.appendingPathComponent("entry-\(staged.count).bin")
            guard FileManager.default.createFile(atPath: stagedURL.path, contents: nil) else {
                throw C07DataExchangeError.storageUnavailable("stageCreate")
            }
            let handle: FileHandle
            do { handle = try FileHandle(forWritingTo: stagedURL) }
            catch { throw C07DataExchangeError.storageUnavailable("stageOpen") }
            var hasher = SHA256Box()
            var readback: Int64 = 0
            do {
                _ = try archive.extract(entry, skipCRC32: false) { chunk in
                    if Task.isCancelled { throw C07DataExchangeError.cancelled }
                    readback += Int64(chunk.count)
                    guard readback <= size else {
                        throw C07DataExchangeError.sizeMismatch(path)
                    }
                    hasher.update(chunk)
                    try handle.write(contentsOf: chunk)
                }
                try handle.close()
            } catch is CancellationError {
                try? handle.close()
                throw CancellationError()
            } catch let error as C07DataExchangeError {
                try? handle.close()
                throw error
            } catch {
                try? handle.close()
                throw C07DataExchangeError.corruptArchive("extract:\(path)")
            }
            guard readback == size else {
                throw C07DataExchangeError.sizeMismatch(path)
            }
            staged[path] = stagedURL
            sizes[path] = size
            hashes[path] = hasher.finalize()
            progress?(total, estimatedTotal)
        }

        guard let manifestURL = staged[C07Path.manifestArchivePath],
              let manifestSize = sizes[C07Path.manifestArchivePath],
              manifestSize <= C07DataExchangeLimits.maximumManifestBytes,
              let manifestBytes = try? Data(contentsOf: manifestURL) else {
            throw C07DataExchangeError.invalidManifest("manifestMissing")
        }
        let manifest = try C07BackupManifest.decode(manifestBytes)
        guard manifest.format == C07DataExchangeLimits.backupFormat else {
            throw C07DataExchangeError.unsupportedFormat(manifest.format)
        }
        guard manifest.formatVersion == C07DataExchangeLimits.backupFormatVersion else {
            throw C07DataExchangeError.unsupportedVersion(manifest.formatVersion)
        }
        guard manifest.appSchemaVersion > 0,
              manifest.appSchemaVersion <= currentAppSchemaVersion else {
            throw C07DataExchangeError.unsupportedVersion(manifest.appSchemaVersion)
        }
        try C07ScopePolicy.validate(manifest.scope)

        // Validate the manifest before parsing nested content.
        guard manifest.projects.count <= C07DataExchangeLimits.maximumProjects,
              manifest.settings.providerCatalog.count <= 64 else {
            throw C07DataExchangeError.tooManyEntries
        }
        var expectedPaths = Set<String>()
        var projectIDs = Set<UUID>()
        var globalPaths = Set<String>()
        var globalFileEntries = 0
        var stagedProjects: [C07StagedProject] = []
        var warnings = manifest.warnings
        for project in manifest.projects {
            guard projectIDs.insert(project.projectID).inserted else {
                throw C07DataExchangeError.invalidManifest("duplicateProject")
            }
            guard !project.name.isEmpty,
                  project.name.utf8.count <= C07DataExchangeLimits.maximumProjectNameBytes else {
                throw C07DataExchangeError.invalidManifest("projectName")
            }
            guard project.origin == .managed || project.origin == .retained else {
                throw C07DataExchangeError.invalidManifest("projectOrigin")
            }
            guard project.files.count <= C07DataExchangeLimits.maximumEntries else {
                throw C07DataExchangeError.tooManyEntries
            }
            var directoryKeys = Set<String>()
            for directory in project.directories {
                do { _ = try C07Path.validateRelative(directory) }
                catch { throw C07DataExchangeError.unsafePath(directory) }
                guard directoryKeys.insert(C07Path.collisionKey(directory)).inserted else {
                    throw C07DataExchangeError.caseCollision(directory)
                }
            }
            var fileKeys = Set<String>()
            var stagedFiles: [C07StagedProjectFile] = []
            for file in project.files {
                do { _ = try C07Path.validateRelative(file.relativePath) }
                catch { throw C07DataExchangeError.unsafePath(file.relativePath) }
                let key = C07Path.collisionKey(file.relativePath)
                guard fileKeys.insert(key).inserted else {
                    throw C07DataExchangeError.caseCollision(file.relativePath)
                }
                globalFileEntries += 1
                guard globalFileEntries <= C07DataExchangeLimits.maximumEntries else {
                    throw C07DataExchangeError.tooManyEntries
                }
                let archivePath = C07Path.archivePath(
                    origin: project.origin, projectID: project.projectID,
                    relativePath: file.relativePath)
                guard globalPaths.insert(C07Path.collisionKey(archivePath)).inserted else {
                    throw C07DataExchangeError.caseCollision(archivePath)
                }
                guard let stagedURL = staged[archivePath] else {
                    throw C07DataExchangeError.invalidManifest("missingEntry")
                }
                guard sizes[archivePath] == file.byteCount,
                      hashes[archivePath] == file.sha256 else {
                    throw C07DataExchangeError.hashMismatch(file.relativePath)
                }
                guard C07SHA256Hex.isSHA256(file.sha256) else {
                    throw C07DataExchangeError.invalidManifest("projectHash")
                }
                let mode = file.mode ?? 0o644
                guard mode >= 0o400, mode <= 0o777 else {
                    throw C07DataExchangeError.invalidManifest("projectMode")
                }
                expectedPaths.insert(archivePath)
                stagedFiles.append(C07StagedProjectFile(
                    relativePath: file.relativePath, stagedURL: stagedURL,
                    byteCount: file.byteCount, sha256: file.sha256,
                    mode: mode))
            }
            stagedProjects.append(C07StagedProject(
                record: project,
                files: stagedFiles.sorted { $0.relativePath < $1.relativePath }))
        }

        // Notes records.
        var notebookIDs = Set<UUID>()
        for notebook in manifest.notes.notebooks {
            guard notebookIDs.insert(notebook.notebookID).inserted else {
                throw C07DataExchangeError.invalidManifest("duplicateNotebook")
            }
            guard !notebook.title.isEmpty,
                  notebook.title.utf8.count <= C07DataExchangeLimits.maximumNotebookTitleBytes else {
                throw C07DataExchangeError.invalidManifest("notebookTitle")
            }
        }
        guard manifest.notes.notebooks.count <= C07DataExchangeLimits.maximumNotebooks,
              manifest.notes.documents.count <= C07DataExchangeLimits.maximumNoteDocuments else {
            throw C07DataExchangeError.tooManyEntries
        }
        var documentIDs = Set<UUID>()
        for document in manifest.notes.documents {
            globalFileEntries += 1
            guard globalFileEntries <= C07DataExchangeLimits.maximumEntries else {
                throw C07DataExchangeError.tooManyEntries
            }
            guard documentIDs.insert(document.documentID).inserted else {
                throw C07DataExchangeError.invalidManifest("duplicateNote")
            }
            if let notebookID = document.notebookID {
                guard notebookIDs.contains(notebookID) else {
                    throw C07DataExchangeError.invalidManifest("notebookReference")
                }
            }
            guard !document.title.isEmpty,
                  document.title.utf8.count <= C07DataExchangeLimits.maximumNoteTitleBytes else {
                throw C07DataExchangeError.invalidManifest("noteTitle")
            }
            let path = C07Path.noteArchivePath(documentID: document.documentID)
            guard let stagedURL = staged[path] else {
                throw C07DataExchangeError.invalidManifest("missingNote")
            }
            guard sizes[path] == document.byteCount,
                  hashes[path] == document.sha256,
                  C07SHA256Hex.isSHA256(document.sha256) else {
                throw C07DataExchangeError.hashMismatch(path)
            }
            guard document.byteCount <= C07DataExchangeLimits.maximumNoteArchiveBytes else {
                throw C07DataExchangeError.entryTooLarge(path)
            }
            _ = stagedURL
            guard globalPaths.insert(C07Path.collisionKey(path)).inserted else {
                throw C07DataExchangeError.caseCollision(path)
            }
            expectedPaths.insert(path)
        }

        // Settings record.
        var settingsValues: [String: String] = [:]
        if let entry = manifest.settings.entry {
            guard entry == C07Path.settingsArchivePath,
                  let stagedURL = staged[entry] else {
                throw C07DataExchangeError.invalidManifest("settingsEntry")
            }
            guard sizes[entry] == manifest.settings.byteCount,
                  hashes[entry] == manifest.settings.sha256,
                  C07SHA256Hex.isSHA256(manifest.settings.sha256 ?? "") else {
                throw C07DataExchangeError.hashMismatch(entry)
            }
            guard manifest.settings.byteCount <= C07DataExchangeLimits.maximumSettingsBytes else {
                throw C07DataExchangeError.entryTooLarge(entry)
            }
            let data: Data
            do { data = try Data(contentsOf: stagedURL) }
            catch { throw C07DataExchangeError.storageUnavailable("settingsRead") }
            let decoded: [String: String]
            do { decoded = try JSONDecoder().decode([String: String].self, from: data) }
            catch { throw C07DataExchangeError.invalidManifest("settingsDecode") }
            guard Set(decoded.keys) == Set(manifest.settings.keys),
                  decoded.keys.allSatisfy(C07SettingsPolicy.isAllowedKey),
                  decoded.values.allSatisfy({ $0.utf8.count <= 65_536 }) else {
                throw C07DataExchangeError.invalidScope("settingsKeys")
            }
            settingsValues = decoded
            if globalPaths.contains(C07Path.collisionKey(entry)) {
                throw C07DataExchangeError.caseCollision(entry)
            }
            globalPaths.insert(C07Path.collisionKey(entry))
            expectedPaths.insert(entry)
        } else {
            guard manifest.settings.keys.isEmpty,
                  manifest.settings.byteCount == 0,
                  manifest.settings.sha256 == nil else {
                throw C07DataExchangeError.invalidManifest("settingsShape")
            }
        }

        expectedPaths.insert(C07Path.manifestArchivePath)
        let stagedFilePaths = Set(staged.keys)
        guard stagedFilePaths == expectedPaths else {
            throw C07DataExchangeError.invalidManifest("entrySet")
        }

        // Nested note resources are extracted a second time under the stage;
        // reserve that additional bounded space before parsing.
        let nestedNoteBytes = manifest.notes.documents.reduce(Int64(0)) {
            $0 + $1.byteCount
        }
        let liveProjectBytes = manifest.projects.reduce(Int64(0)) { partial, project in
            partial + project.files.reduce(Int64(0)) { $0 + $1.byteCount }
        }
        let restoreBytes = total + nestedNoteBytes + liveProjectBytes
            + nestedNoteBytes + C07DataExchangeLimits.freeSpaceHeadroom
        if let available = C07FileSystem.availableBytes(at: stagingRoot),
           available < restoreBytes {
            throw C07DataExchangeError.freeSpaceInsufficient(
                required: restoreBytes, available: available)
        }
        // Deep-parse every nested iOS Notes archive. New identities are
        // allocated here so a later journal intent can name them before any
        // live document is created.
        var parsedNotes: [C07ParsedNoteArchive] = []
        for document in manifest.notes.documents {
            let path = C07Path.noteArchivePath(documentID: document.documentID)
            guard let stagedURL = staged[path] else {
                throw C07DataExchangeError.invalidManifest("missingNote")
            }
            do {
                let parsed = try C07NotesPackage.parse(
                    archiveURL: stagedURL,
                    stagingRoot: stage.appendingPathComponent("notes", isDirectory: true),
                    expectedDocumentID: document.documentID,
                    metadataTitle: document.title)
                parsedNotes.append(parsed)
            } catch let error as C07DataExchangeError {
                throw error
            } catch {
                throw C07DataExchangeError.notesArchive("parse")
            }
        }

        let requiredFree = total + C07DataExchangeLimits.freeSpaceHeadroom
        if let available = C07FileSystem.availableBytes(at: stagingRoot),
           available < requiredFree {
            throw C07DataExchangeError.freeSpaceInsufficient(
                required: requiredFree, available: available)
        }

        keepStage = true
        return C07RestorePlan(
            manifest: manifest,
            manifestSHA256: C07Digest.sha256(manifestBytes),
            stagedRoot: stage,
            projects: stagedProjects,
            notes: parsedNotes,
            settingsValues: settingsValues,
            warnings: warnings,
            totalBytes: total)
    }
}

// MARK: - Small helpers

struct C07SHA256Hex {
    static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}

/// Local hash box because Crypto's SHA256 value type is a struct that cannot
/// be mutated inside an escaping closure directly.
final class SHA256Box {
    private var hasher = SHA256()
    func update(_ data: Data) { hasher.update(data: data) }
    func finalize() -> String {
        hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
