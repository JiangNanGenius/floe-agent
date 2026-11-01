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

    public init(record: C07ProjectRecord, files: [C07StagedProjectFile]) {
        self.record = record
        self.files = files
    }

    public var restoreSkipped: Bool { !record.warnings.isEmpty && record.files.isEmpty }
}

public struct C07RestorePlan: Sendable {
    public var manifest: C07BackupManifest
    public var manifestSHA256: String
    public var stagedRoot: URL
    public var projects: [C07StagedProject]
    public var notes: [C07ParsedNoteArchive]
    public var settingsValues: [String: String]
    /// v2 logical row graph + Canvas/media/attachment/receipt artifacts.
    public var ownedData: C07StagedOwnedData?
    public var warnings: [String]
    public var totalBytes: Int64

    public init(manifest: C07BackupManifest,
                manifestSHA256: String,
                stagedRoot: URL,
                projects: [C07StagedProject],
                notes: [C07ParsedNoteArchive],
                settingsValues: [String: String],
                ownedData: C07StagedOwnedData? = nil,
                warnings: [String],
                totalBytes: Int64) {
        self.manifest = manifest
        self.manifestSHA256 = manifestSHA256
        self.stagedRoot = stagedRoot
        self.projects = projects
        self.notes = notes
        self.settingsValues = settingsValues
        self.ownedData = ownedData
        self.warnings = warnings
        self.totalBytes = totalBytes
    }

    public var noteDocumentCount: Int { notes.reduce(0) { $0 + $1.documents.count } }
    public var noteResourceCount: Int { notes.reduce(0) { $0 + $1.resources.count } }
    public var projectFileCount: Int { projects.reduce(0) { $0 + $1.files.count } }
    public var skippedProjectCount: Int { projects.filter(\.restoreSkipped).count }
    public var ownedDataCounts: C07OwnedDataCounts {
        ownedData?.manifest.counts ?? C07OwnedDataCounts()
    }
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
        if let owned = source.ownedData {
            for table in owned.tables {
                guard let size = (try? table.url.resourceValues(
                    forKeys: [.fileSizeKey]))?.fileSize else {
                    throw C07DataExchangeError.storageUnavailable("tableStat")
                }
                totalEstimate += Int64(size)
            }
            if let workspaces = owned.workspaces {
                guard let size = (try? workspaces.url.resourceValues(
                    forKeys: [.fileSizeKey]))?.fileSize else {
                    throw C07DataExchangeError.storageUnavailable("workspacesStat")
                }
                totalEstimate += Int64(size)
            }
            for artifact in owned.artifacts {
                totalEstimate += artifact.record.byteCount
            }
            totalEstimate += 1_048_576
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

        // v2 logical row graph and app-owned artifact graph.
        var dataManifestRef: C07EntryReference?
        var artifactCatalogRef: C07EntryReference?
        if let owned = source.ownedData {
            let tableNames = owned.tables.map(\.name)
            guard Set(tableNames).count == tableNames.count,
                  C07OwnedDataPolicy.mandatoryTableNames.isSubset(of: Set(tableNames)),
                  owned.tables.count <= C07OwnedDataLimits.maximumTables else {
                throw C07DataExchangeError.invalidManifest("ownedTableSet")
            }
            var tableRecords: [C07OwnedTableRecord] = []
            for table in owned.tables {
                guard let policy = C07OwnedDataPolicy.policy(for: table.name) else {
                    throw C07DataExchangeError.invalidManifest("ownedTable:\(table.name)")
                }
                _ = policy
                let entry = c07OwnedTableEntry(table.name)
                guard archivePaths.insert(C07Path.collisionKey(entry)).inserted else {
                    throw C07DataExchangeError.caseCollision(entry)
                }
                totalFileCount += 1
                guard totalFileCount <= C07DataExchangeLimits.maximumEntries else {
                    throw C07DataExchangeError.tooManyEntries
                }
                var countedRows = 0
                try C07RowStream.rows(in: table.url, table: table.name) { row in
                    guard C07OwnedDataPolicy.shouldExportRow(
                        table: table.name, row: row) else {
                        throw C07DataExchangeError.invalidManifest(
                            "rowNotExportable:\(table.name)")
                    }
                    countedRows += 1
                }
                guard countedRows == table.rowCount else {
                    throw C07DataExchangeError.invalidManifest(
                        "rowCount:\(table.name)")
                }
                let stagedURL = staging.appendingPathComponent(entry)
                try C07FileSystem.ensureDirectory(stagedURL.deletingLastPathComponent())
                let copied = try C07FileSystem.copyVerified(
                    source: table.url, destination: stagedURL)
                totalCopyBytes += copied.byteCount
                guard totalCopyBytes <= C07DataExchangeLimits.maximumTotalBytes else {
                    throw C07DataExchangeError.totalTooLarge
                }
                tableRecords.append(C07OwnedTableRecord(
                    name: table.name, entry: entry,
                    rowCount: countedRows, byteCount: copied.byteCount,
                    sha256: copied.sha256))
                done += copied.byteCount
                progress?(done, estimatedTotal)
            }
            guard let workspaces = owned.workspaces else {
                throw C07DataExchangeError.invalidManifest("workspacesMissing")
            }
            let workspaceEntry = C07OwnedDataLimits.workspacesEntry
            guard archivePaths.insert(C07Path.collisionKey(workspaceEntry)).inserted else {
                throw C07DataExchangeError.caseCollision(workspaceEntry)
            }
            totalFileCount += 1
            guard totalFileCount <= C07DataExchangeLimits.maximumEntries else {
                throw C07DataExchangeError.tooManyEntries
            }
            let stagedWorkspaces = staging.appendingPathComponent(workspaceEntry)
            try C07FileSystem.ensureDirectory(stagedWorkspaces.deletingLastPathComponent())
            let workspaceCopy = try C07FileSystem.copyVerified(
                source: workspaces.url, destination: stagedWorkspaces,
                maximum: C07OwnedDataLimits.maximumWorkspaceBytes)
            let workspaceData: Data
            do { workspaceData = try Data(contentsOf: stagedWorkspaces) }
            catch { throw C07DataExchangeError.storageUnavailable("workspacesRead") }
            let descriptors: [C07WorkspaceDescriptor]
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                descriptors = try decoder.decode(
                    [C07WorkspaceDescriptor].self, from: workspaceData)
            } catch {
                throw C07DataExchangeError.invalidManifest("workspacesDecode")
            }
            guard descriptors.count == workspaces.count,
                  descriptors.count <= C07OwnedDataLimits.maximumWorkspaces else {
                throw C07DataExchangeError.invalidManifest("workspacesCount")
            }
            var countedArtifacts: [C07ArtifactRecord] = []
            for artifact in owned.artifacts {
                let record = artifact.record
                let expectedEntry = try C07ArtifactPath.entry(
                    role: record.role, containerID: record.containerID,
                    ownerID: record.ownerID, logicalPath: record.logicalPath)
                guard expectedEntry == record.entry,
                      record.entry.hasPrefix(
                        C07OwnedDataLimits.artifactDirectory + "/") else {
                    throw C07DataExchangeError.invalidManifest(
                        "artifactEntry:\(record.entry)")
                }
                guard archivePaths.insert(
                    C07Path.collisionKey(record.entry)).inserted else {
                    throw C07DataExchangeError.caseCollision(record.entry)
                }
                totalFileCount += 1
                guard totalFileCount <= C07DataExchangeLimits.maximumEntries else {
                    throw C07DataExchangeError.tooManyEntries
                }
                let stagedURL = staging.appendingPathComponent(record.entry)
                try C07FileSystem.ensureDirectory(stagedURL.deletingLastPathComponent())
                let copied = try C07FileSystem.copyVerified(
                    source: artifact.url, destination: stagedURL,
                    maximum: C07OwnedDataLimits.maximumArtifactBytes)
                guard copied.byteCount == record.byteCount,
                      copied.sha256 == record.sha256 else {
                    throw C07DataExchangeError.hashMismatch(record.entry)
                }
                totalCopyBytes += copied.byteCount
                guard totalCopyBytes <= C07DataExchangeLimits.maximumTotalBytes else {
                    throw C07DataExchangeError.totalTooLarge
                }
                countedArtifacts.append(record)
                done += copied.byteCount
                progress?(done, estimatedTotal)
            }
            let catalog = C07ArtifactCatalog(records: countedArtifacts)
            try catalog.validate()
            let catalogData = try catalog.encoded()
            let catalogEntry = "\(C07OwnedDataLimits.artifactDirectory)/manifest.json"
            guard archivePaths.insert(C07Path.collisionKey(catalogEntry)).inserted else {
                throw C07DataExchangeError.caseCollision(catalogEntry)
            }
            totalFileCount += 1
            let catalogURL = staging.appendingPathComponent(catalogEntry)
            try C07FileSystem.ensureDirectory(catalogURL.deletingLastPathComponent())
            try catalogData.write(to: catalogURL)
            let catalogDigest = try C07Digest.file(catalogURL)
            artifactCatalogRef = C07EntryReference(
                entry: catalogEntry, byteCount: catalogDigest.byteCount,
                sha256: catalogDigest.sha256)
            totalCopyBytes += catalogDigest.byteCount
            done += catalogDigest.byteCount

            var counts = owned.counts
            counts.artifacts = countedArtifacts.count
            counts.artifactBytes = countedArtifacts.reduce(0) { $0 + $1.byteCount }
            let dataManifest = C07OwnedDataManifest(
                createdAt: source.createdAt,
                sourceAppSchemaVersion: source.appSchemaVersion,
                tables: tableRecords,
                workspaceCount: descriptors.count,
                workspaceByteCount: workspaceCopy.byteCount,
                workspaceSHA256: workspaceCopy.sha256,
                counts: counts,
                excluded: owned.excluded,
                linuxCheckpointPort: owned.linuxCheckpointPort,
                linuxCheckpointReason: owned.linuxCheckpointReason,
                warnings: owned.warnings)
            try dataManifest.validate()
            let dataManifestData = try dataManifest.encoded()
            guard archivePaths.insert(
                C07Path.collisionKey(C07OwnedDataLimits.manifestEntry)).inserted else {
                throw C07DataExchangeError.caseCollision(C07OwnedDataLimits.manifestEntry)
            }
            totalFileCount += 1
            let dataManifestURL = staging.appendingPathComponent(
                C07OwnedDataLimits.manifestEntry)
            try C07FileSystem.ensureDirectory(
                dataManifestURL.deletingLastPathComponent())
            try dataManifestData.write(to: dataManifestURL)
            let dataDigest = try C07Digest.file(dataManifestURL)
            dataManifestRef = C07EntryReference(
                entry: C07OwnedDataLimits.manifestEntry,
                byteCount: dataDigest.byteCount, sha256: dataDigest.sha256)
            totalCopyBytes += dataDigest.byteCount
            done += dataDigest.byteCount
            warnings.append(contentsOf: owned.warnings)
        }
        let isFullData = dataManifestRef != nil
        let manifest = C07BackupManifest(
            formatVersion: isFullData ? 2 : 1,
            createdAt: source.createdAt,
            appSchemaVersion: source.appSchemaVersion,
            scope: isFullData
                ? C07BackupScope(
                    excluded: C07ScopePolicy.excluded,
                    databaseMode: "logicalRows")
                : C07BackupScope(
                    included: C07BackupScope.legacyIncludedIDs,
                    excluded: C07ScopePolicy.excluded,
                    databaseMode: nil),
            projects: projectRecords,
            notes: notes,
            settings: settingsRecord,
            dataManifest: dataManifestRef,
            artifactCatalog: artifactCatalogRef,
            warnings: warnings)
        try C07ScopePolicy.validate(
            manifest.scope, formatVersion: manifest.formatVersion)
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
        let verified = try verifyArchive(
            temporary, manifest: manifest, manifestData: manifestData,
            staging: staging)
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
                                          .isSymbolicLinkKey, .fileSizeKey],
            options: [],
            errorHandler: { _, error in
                enumerationFailure = error
                return false
            }) else {
            throw C07DataExchangeError.storageUnavailable("enumerateProject")
        }
        var directories: [String] = []
        var files: [(relativePath: String, url: URL, byteCount: Int64,
                     mode: Int)] = []
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
                .fileSizeKey,
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
                let attributes = try? FileManager.default.attributesOfItem(
                    atPath: url.path)
                let mode = Int((attributes?[.posixPermissions] as? NSNumber)?
                    .intValue ?? 0o644) & 0o777
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
        while let url = enumerator.nextObject() as? URL {
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
        manifestData: Data,
        staging: URL
    ) throws -> (byteCount: Int64, sha256: String) {
        let archive: Archive
        do { archive = try Archive(url: url, accessMode: .read) }
        catch { throw C07DataExchangeError.corruptArchive("open") }
        let expected = try expectedArchivePaths(manifest, staging: staging)
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
                let expectedHash = expectedHash(
                    for: path, manifest: manifest, staging: staging)
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

    private static func expectedArchivePaths(
        _ manifest: C07BackupManifest, staging: URL
    ) throws -> Set<String> {
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
        if let ref = manifest.dataManifest {
            paths.insert(ref.entry)
            guard ref.entry == C07OwnedDataLimits.manifestEntry else {
                throw C07DataExchangeError.invalidManifest("dataManifestEntry")
            }
            let data = try Data(contentsOf: staging.appendingPathComponent(ref.entry))
            let dataManifest = try C07OwnedDataManifest.decode(data)
            try dataManifest.validate()
            paths.insert(dataManifest.workspacesEntry)
            for table in dataManifest.tables { paths.insert(table.entry) }
        } else if manifest.formatVersion >= 2 {
            throw C07DataExchangeError.invalidManifest("dataManifestMissing")
        }
        if let ref = manifest.artifactCatalog {
            paths.insert(ref.entry)
            guard ref.entry == "\(C07OwnedDataLimits.artifactDirectory)/manifest.json" else {
                throw C07DataExchangeError.invalidManifest("artifactCatalogEntry")
            }
            let data = try Data(contentsOf: staging.appendingPathComponent(ref.entry))
            let catalog = try C07ArtifactCatalog.decode(data)
            try catalog.validate()
            for record in catalog.records { paths.insert(record.entry) }
        } else if manifest.formatVersion >= 2 {
            throw C07DataExchangeError.invalidManifest("artifactCatalogMissing")
        }
        paths.insert(C07Path.manifestArchivePath)
        return paths
    }

    private static func expectedHash(
        for path: String, manifest: C07BackupManifest, staging: URL
    ) -> String {
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
        if let ref = manifest.dataManifest, path == ref.entry {
            return ref.sha256
        }
        if let ref = manifest.artifactCatalog, path == ref.entry {
            return ref.sha256
        }
        if let ref = manifest.dataManifest,
           let data = try? Data(contentsOf: staging.appendingPathComponent(ref.entry)),
           let dataManifest = try? C07OwnedDataManifest.decode(data) {
            if path == dataManifest.workspacesEntry {
                return dataManifest.workspaceSHA256
            }
            for table in dataManifest.tables where table.entry == path {
                return table.sha256
            }
        }
        if let ref = manifest.artifactCatalog,
           let data = try? Data(contentsOf: staging.appendingPathComponent(ref.entry)),
           let catalog = try? C07ArtifactCatalog.decode(data) {
            for record in catalog.records where record.entry == path {
                return record.sha256
            }
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
        guard manifest.formatVersion >= C07DataExchangeLimits.legacyBackupFormatVersion,
              manifest.formatVersion <= C07DataExchangeLimits.backupFormatVersion else {
            throw C07DataExchangeError.unsupportedVersion(manifest.formatVersion)
        }
        guard manifest.appSchemaVersion > 0,
              manifest.appSchemaVersion <= currentAppSchemaVersion else {
            throw C07DataExchangeError.unsupportedVersion(manifest.appSchemaVersion)
        }
        try C07ScopePolicy.validate(
            manifest.scope, formatVersion: manifest.formatVersion)

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

        // v2 owned-data graph. The data manifest and artifact catalog are
        // themselves hashed entries; their referenced table/artifact entries
        // must match both the catalog record and the staged bytes.
        var ownedData: C07StagedOwnedData?
        if manifest.formatVersion >= 2 {
            guard let dataRef = manifest.dataManifest,
                  let catalogRef = manifest.artifactCatalog,
                  let dataURL = staged[dataRef.entry],
                  sizes[dataRef.entry] == dataRef.byteCount,
                  hashes[dataRef.entry] == dataRef.sha256,
                  dataRef.entry == C07OwnedDataLimits.manifestEntry else {
                throw C07DataExchangeError.invalidManifest("dataManifest")
            }
            guard let catalogURL = staged[catalogRef.entry],
                  sizes[catalogRef.entry] == catalogRef.byteCount,
                  hashes[catalogRef.entry] == catalogRef.sha256,
                  catalogRef.entry == "\(C07OwnedDataLimits.artifactDirectory)/manifest.json" else {
                throw C07DataExchangeError.invalidManifest("artifactCatalog")
            }
            let dataManifest: C07OwnedDataManifest
            let catalog: C07ArtifactCatalog
            do {
                dataManifest = try C07OwnedDataManifest.decode(
                    Data(contentsOf: dataURL))
                try dataManifest.validate()
                catalog = try C07ArtifactCatalog.decode(
                    Data(contentsOf: catalogURL))
                try catalog.validate()
            } catch let error as C07DataExchangeError {
                throw error
            } catch {
                throw C07DataExchangeError.invalidManifest("ownedDataRead")
            }
            guard dataManifest.sourceAppSchemaVersion == manifest.appSchemaVersion else {
                throw C07DataExchangeError.invalidManifest("dataSchemaVersion")
            }
            guard let workspacesURL = staged[dataManifest.workspacesEntry],
                  sizes[dataManifest.workspacesEntry] == dataManifest.workspaceByteCount,
                  hashes[dataManifest.workspacesEntry] == dataManifest.workspaceSHA256 else {
                throw C07DataExchangeError.invalidManifest("workspacesEntry")
            }
            let workspaceData: Data
            do { workspaceData = try Data(contentsOf: workspacesURL) }
            catch { throw C07DataExchangeError.storageUnavailable("workspacesRead") }
            let descriptors: [C07WorkspaceDescriptor]
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                descriptors = try decoder.decode(
                    [C07WorkspaceDescriptor].self, from: workspaceData)
            } catch {
                throw C07DataExchangeError.invalidManifest("workspacesDecode")
            }
            guard descriptors.count == dataManifest.workspaceCount,
                  descriptors.count <= C07OwnedDataLimits.maximumWorkspaces else {
                throw C07DataExchangeError.invalidManifest("workspacesCount")
            }
            var stagedTables: [C07StagedTable] = []
            var ownedBytes: Int64 = 0
            for table in dataManifest.tables {
                guard let policy = C07OwnedDataPolicy.policy(for: table.name),
                      let url = staged[table.entry],
                      sizes[table.entry] == table.byteCount,
                      hashes[table.entry] == table.sha256 else {
                    throw C07DataExchangeError.invalidManifest(
                        "ownedTable:\(table.name)")
                }
                var countedRows = 0
                try C07RowStream.rows(in: url, table: table.name) { row in
                    guard policy.requiredColumns.isSubset(of: Set(row.keys)),
                          C07OwnedDataPolicy.shouldExportRow(
                            table: table.name, row: row) else {
                        throw C07DataExchangeError.invalidManifest(
                            "rowShape:\(table.name)")
                    }
                    countedRows += 1
                }
                guard countedRows == table.rowCount else {
                    throw C07DataExchangeError.invalidManifest(
                        "rowCount:\(table.name)")
                }
                ownedBytes += table.byteCount
                stagedTables.append(C07StagedTable(record: table, url: url))
                expectedPaths.insert(table.entry)
            }
            let missingMandatory = C07OwnedDataPolicy.mandatoryTableNames
                .subtracting(dataManifest.tables.map(\.name))
            guard missingMandatory.isEmpty else {
                throw C07DataExchangeError.invalidManifest("ownedTablesMissing")
            }
            var stagedArtifacts: [C07StagedArtifact] = []
            for record in catalog.records {
                guard let url = staged[record.entry],
                      sizes[record.entry] == record.byteCount,
                      hashes[record.entry] == record.sha256 else {
                    throw C07DataExchangeError.invalidManifest(
                        "artifact:\(record.entry)")
                }
                ownedBytes += record.byteCount
                stagedArtifacts.append(C07StagedArtifact(record: record, url: url))
                expectedPaths.insert(record.entry)
            }
            guard stagedArtifacts.count == dataManifest.counts.artifacts else {
                throw C07DataExchangeError.invalidManifest("artifactCount")
            }
            expectedPaths.insert(dataManifest.workspacesEntry)
            expectedPaths.insert(dataRef.entry)
            expectedPaths.insert(catalogRef.entry)
            warnings.append(contentsOf: dataManifest.warnings)
            ownedData = C07StagedOwnedData(
                manifest: dataManifest,
                manifestSHA256: dataRef.sha256,
                tables: stagedTables,
                workspaces: descriptors,
                artifacts: stagedArtifacts,
                totalBytes: ownedBytes)
        } else {
            guard manifest.dataManifest == nil,
                  manifest.artifactCatalog == nil else {
                throw C07DataExchangeError.invalidManifest("legacyDataSection")
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
            + nestedNoteBytes + (ownedData?.totalBytes ?? 0)
            + C07DataExchangeLimits.freeSpaceHeadroom
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
            ownedData: ownedData,
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
