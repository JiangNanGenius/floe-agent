// SPDX-License-Identifier: MPL-2.0
//
// C07 manual data exchange — production source/sink adapters and job owner.
//
// UI -> settings page -> SAF picker -> this domain -> FloeAndroidDataExchange
// (manifest/staging/hash/journal) -> the ORIGINAL C01 project library,
// NotesStore and SQLiteSettingsStore. No second database, no second project
// registry, no live SQLite/WAL copy, no credential material.
//
// Restore always creates NEW identities (project UUID, note document IDs,
// notebook IDs) and never overwrites or deletes existing user data. Every
// mutation is preceded by a durable journal intent; a failure or process death
// rolls back reverse-order by exact marker/ID, retaining the original data.
import Foundation
import Crypto
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#endif
import GRDB
import FloeCore
import FloeModels
import FloePersistence
import FloeNotes
import FloeAndroidDataExchange

// MARK: - Wire

public enum C07DataExchangeWire {
    public static let version = 16
    public static let schema = "floe.data/16"
    public static let maximumRequestBytes = 65_536
    public static let maximumResponseBytes = 49_152
    public static let maximumChunkBytes = 24_576
    public static let maximumOwnerBytes = 128
    public static let maximumJobIDBytes = 64
    public static let maximumStageBytes: Int64 =
        C07DataExchangeLimits.maximumTotalBytes + C07DataExchangeLimits.freeSpaceHeadroom
    public static let formatVersion = C07DataExchangeLimits.backupFormatVersion
    public static let backupExtension = C07DataExchangeLimits.backupExtension
    public static let notesExtension = C07DataExchangeLimits.notesExtension
}

public struct C07ExchangeOwner: Sendable, Equatable {
    public let token: String
    public let nativeEpoch: UInt64

    public init(token: String, nativeEpoch: UInt64) throws {
        guard (8...C07DataExchangeWire.maximumOwnerBytes).contains(token.utf8.count),
              token.unicodeScalars.allSatisfy({
                  $0.value < 128 && !$0.properties.isWhitespace
                      && !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw C07DataExchangeError.invalidScope("ownerToken")
        }
        guard nativeEpoch > 0 else {
            throw C07DataExchangeError.invalidScope("ownerEpoch")
        }
        self.token = token
        self.nativeEpoch = nativeEpoch
    }

    public static func parse(_ value: Any?) throws -> C07ExchangeOwner {
        guard let object = value as? [String: Any],
              let token = object["token"] as? String,
              let number = object["nativeEpoch"] as? NSNumber else {
            throw C07DataExchangeError.invalidScope("owner")
        }
        let epoch = number.uint64Value
        guard number.doubleValue == Double(epoch) else {
            throw C07DataExchangeError.invalidScope("ownerEpoch")
        }
        return try C07ExchangeOwner(token: token, nativeEpoch: epoch)
    }
}

// MARK: - Trusted context

struct C07DataExchangeContext: Sendable {
    let epoch: UInt64
    let rootPath: String
    let artifactRoot: URL
    let dataRoot: URL
    let exportsRoot: URL
    let incomingRoot: URL
    let stagingRoot: URL
    let workRoot: URL
    let journalRoot: URL
    let notesRoot: URL
    let database: DatabaseManager
    let workspaceStore: SQLiteWorkspaceStore
    let settingsStore: SQLiteSettingsStore
    let modelConfigurationStore: ModelConfigurationStore
    let projectLibrary: C01ProjectLibrary

    static func make(owner: C07ExchangeOwner) throws -> C07DataExchangeContext {
        guard G02NativeRootEpoch.readback() == owner.nativeEpoch,
              let composition = G02RuntimeComposition.shared.installedComposition,
              composition.epoch == owner.nativeEpoch,
              // The bridge is already inside the trusted App process; the
              // random host token is not the native owner token. Root choice
              // therefore comes from the accepted generation alone (the same
              // trusted epoch readback as the Notes host), never a caller path.
              let root = AndroidRuntimeBootstrap.notesBinding(
                epoch: owner.nativeEpoch, ownerToken: nil) else {
            throw C07DataExchangeError.invalidScope("runtimeUnavailable")
        }
        let artifact = root.artifactStoreURL
        let data = artifact.appendingPathComponent("DataExchange", isDirectory: true)
        return C07DataExchangeContext(
            epoch: owner.nativeEpoch,
            rootPath: root.path,
            artifactRoot: artifact,
            dataRoot: data,
            exportsRoot: data.appendingPathComponent("Exports", isDirectory: true),
            incomingRoot: data.appendingPathComponent("Incoming", isDirectory: true),
            stagingRoot: data.appendingPathComponent("Staging", isDirectory: true),
            workRoot: data.appendingPathComponent("Work", isDirectory: true),
            journalRoot: data.appendingPathComponent("RestoreJournal", isDirectory: true),
            notesRoot: artifact.appendingPathComponent("Notes", isDirectory: true),
            database: composition.cluster.database,
            workspaceStore: composition.cluster.workspaceStore,
            settingsStore: composition.cluster.settingsStore,
            modelConfigurationStore: composition.cluster.modelConfigurationStore,
            projectLibrary: composition.projectLibrary)
    }
}

// MARK: - Live backup source

struct C07LiveSourceBuilder: Sendable {
    let context: C07DataExchangeContext
    let workRoot: URL

    func makeSource(includeRetainedProjects: Bool,
                    progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws
        -> C07BackupSource
    {
        try C07FileSystem.ensureDirectory(workRoot)
        var warnings: [String] = []
        let appSchema = DatabaseManager.currentSchemaVersion
        var projects: [C07SourceProject] = []

        // Managed C01 projects: the ONE original workspaces table, filtered
        // by the exact C01 managed-row predicate. This is a single consistent
        // read (no offset pagination that a concurrent rename could perturb);
        // there is no second project registry.
        let managed = (try await context.workspaceStore.workspaces())
            .filter { C01ProjectRootLayout.isManagedProject($0) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        var managedIDs = Set<UUID>()
        for row in managed {
            managedIDs.insert(row.id)
            let state = C01ProjectRootLayout.inspectProjectDirectory(
                rootPath: context.rootPath, projectID: row.id)
            switch state {
            case .available:
                projects.append(C07SourceProject(
                    projectID: row.id, name: row.name, origin: .managed,
                    createdAt: row.createdAt,
                    rootURL: URL(fileURLWithPath: C01ProjectRootLayout.projectDirectory(
                        rootPath: context.rootPath, projectID: row.id))))
            case .missing:
                projects.append(C07SourceProject(
                    projectID: row.id, name: row.name, origin: .managed,
                    createdAt: row.createdAt,
                    unavailableReason: "missing"))
            case .unsafe(let reason):
                projects.append(C07SourceProject(
                    projectID: row.id, name: row.name, origin: .managed,
                    createdAt: row.createdAt,
                    unavailableReason: "unsafe:\(reason)"))
            }
        }

        if includeRetainedProjects {
            let root = URL(fileURLWithPath: C01ProjectRootLayout.projectsDirectory(
                rootPath: context.rootPath))
            if let items = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]) {
                for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    let leaf = item.lastPathComponent
                    guard let id = UUID(uuidString: leaf), id.uuidString == leaf else {
                        warnings.append("retainedLeafIgnored")
                        continue
                    }
                    guard !managedIDs.contains(id) else { continue }
                    let values = try? item.resourceValues(
                        forKeys: Set<URLResourceKey>([
                            .isDirectoryKey, .isSymbolicLinkKey,
                        ]))
                    let attributes = (try? FileManager.default.attributesOfItem(
                        atPath: item.path)) ?? [:]
                    let mode = (attributes[.posixPermissions] as? NSNumber)?
                        .intValue ?? 0
                    guard values?.isDirectory == true,
                          values?.isSymbolicLink != true,
                          mode & 0o777 == 0o700 else {
                        warnings.append("retainedProjectUnsafe:\(leaf.prefix(8))")
                        continue
                    }
                    projects.append(C07SourceProject(
                        projectID: id,
                        name: "Retained project \(String(leaf.prefix(8)))",
                        origin: .retained,
                        rootURL: item))
                }
            }
        }

        // Notes: the real independent NotesStore snapshot. Only documents are
        // exported; trash count is declared, assistant threads/history are not
        // part of the portable document format.
        var notebooks: [C07NotebookRecord] = []
        var notes: [C07SourceNote] = []
        var failedNotes: [C07FailedNote] = []
        var trashed = 0
        let notesDB = context.notesRoot.appendingPathComponent("notes.sqlite")
        if FileManager.default.fileExists(atPath: notesDB.path) {
            do {
                let store = try NotesStore(root: context.notesRoot)
                let all = try await store.documents(includeTrash: true)
                trashed = all.filter { $0.deletedAt != nil }.count
                let active = all.filter { $0.deletedAt == nil }
                let books = try await store.notebooks()
                notebooks = books.map { C07NotebookRecord(notebookID: $0.id, title: $0.title) }
                let notesStage = workRoot.appendingPathComponent("notes", isDirectory: true)
                try C07FileSystem.ensureDirectory(notesStage)
                // A root Notes archive already carries its linked mind maps.
                // Exporting the linked document a second time as its own
                // package would duplicate it on restore. Linked maps are
                // skipped here and only exported standalone if their owning
                // root export failed and therefore did not cover them.
                let linkedIDs = Set(active.flatMap {
                    ($0.linkedMindMaps ?? []).map(\.documentID)
                })
                let roots = active.filter { !linkedIDs.contains($0.id) }
                var coveredLinks = Set<UUID>()
                for document in roots {
                    try Task.checkCancellation()
                    let outcome = try await exportOneNote(
                        document, store: store, stage: notesStage)
                    switch outcome {
                    case .exported(let note, let covered):
                        notes.append(note)
                        coveredLinks.formUnion(covered)
                    case .failed(let failure):
                        failedNotes.append(failure)
                    }
                    progress?(Int64(notes.count + failedNotes.count),
                              Int64(max(1, active.count)))
                }
                for document in active where linkedIDs.contains(document.id)
                    && !coveredLinks.contains(document.id) {
                    try Task.checkCancellation()
                    let outcome = try await exportOneNote(
                        document, store: store, stage: notesStage)
                    switch outcome {
                    case .exported(let note, let covered):
                        notes.append(note)
                        coveredLinks.formUnion(covered)
                    case .failed(let failure):
                        failedNotes.append(failure)
                    }
                    progress?(Int64(notes.count + failedNotes.count),
                              Int64(max(1, active.count)))
                }
            } catch {
                warnings.append("notesStoreUnavailable")
            }
        } else {
            warnings.append("notesStoreAbsent")
        }

        // Safe preferences only. Provider entries are display-only reminders
        // that carry no secretRef/header/base path and are never auto-created.
        var settings: [String: String] = [:]
        if let all = try? await context.settingsStore.allValues() {
            settings = C07SettingsPolicy.sanitize(all)
            if settings.count < all.count {
                warnings.append("settingsOmitted:\(all.count - settings.count)")
            }
        } else {
            warnings.append("settingsUnavailable")
        }
        var providerCatalog: [C07ProviderAdvisory] = []
        if let providers = try? await context.modelConfigurationStore.providers() {
            for provider in providers.prefix(64) {
                let models = (try? await context.modelConfigurationStore.models(
                    providerID: provider.id)) ?? []
                providerCatalog.append(C07ProviderAdvisory(
                    displayName: provider.displayName ?? provider.wireProtocol.rawValue,
                    wireProtocol: provider.wireProtocol.rawValue,
                    baseURLHost: provider.baseURL.host,
                    modelNames: models.prefix(64).map(\.displayName)))
            }
        } else {
            warnings.append("providerCatalogUnavailable")
        }

        if !failedNotes.isEmpty {
            warnings.append("notesFailed:\(failedNotes.count)")
        }
        let ownedData = try await C07OwnedDataSource.capture(
            context: context,
            workRoot: workRoot.appendingPathComponent("owned-data", isDirectory: true),
            includeRetainedProjects: includeRetainedProjects)
        warnings.append(contentsOf: ownedData.warnings)
        return C07BackupSource(
            appSchemaVersion: appSchema,
            projects: projects,
            notebooks: notebooks,
            notes: notes,
            trashedNotesExcluded: trashed,
            failedNotes: failedNotes,
            settingsValues: settings,
            providerCatalog: providerCatalog,
            ownedData: ownedData,
            warnings: warnings)
    }

    private enum NoteExportOutcome: Sendable {
        case exported(C07SourceNote, Set<UUID>)
        case failed(C07FailedNote)
    }

    private func exportOneNote(_ document: NoteDocument,
                              store: NotesStore,
                              stage: URL) async throws -> NoteExportOutcome {
        let url = stage.appendingPathComponent(
            "\(document.id.uuidString).\(C07DataExchangeLimits.notesExtension)")
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try await C07NotesPackage.export(
                document: document, store: store, to: url)
            return .exported(
                C07SourceNote(
                    documentID: document.id,
                    notebookID: document.notebookID,
                    title: document.title,
                    archiveURL: url),
                Set((document.linkedMindMaps ?? []).map(\.documentID)))
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as C07DataExchangeError {
            return .failed(C07FailedNote(
                documentID: document.id, title: document.title,
                reason: error.code))
        } catch {
            return .failed(C07FailedNote(
                documentID: document.id, title: document.title,
                reason: "exportFailed"))
        }
    }
}

// MARK: - Notes sink

actor C07NotesSink {
    private let root: URL
    private var store: NotesStore?

    init(root: URL) { self.root = root }

    private func liveStore() throws -> NotesStore {
        if let store { return store }
        do {
            let value = try NotesStore(root: root)
            store = value
            return value
        } catch {
            throw C07DataExchangeError.storageUnavailable("notesStore")
        }
    }

    func exportNote(documentID: UUID, expectedRevision: Int, to destination: URL) async throws {
        let store = try liveStore()
        do {
            let document = try await store.document(documentID)
            guard document.revision == expectedRevision, document.deletedAt == nil else {
                throw C07DataExchangeError.notFound
            }
            try await C07NotesPackage.export(document: document, store: store, to: destination)
        } catch let error as C07DataExchangeError {
            throw error
        } catch {
            throw C07DataExchangeError.notesArchive("export")
        }
    }

    func createNotebook(title: String) async throws -> UUID {
        let store = try liveStore()
        do {
            let notebook = try await store.createNotebook(title: title)
            return notebook.id
        }
        catch { throw C07DataExchangeError.storageUnavailable("notebookCreate") }
    }

    func renameNotebook(id: UUID, title: String) async throws {
        let store = try liveStore()
        do { try await store.renameNotebook(id, title: title) }
        catch { throw C07DataExchangeError.storageUnavailable("notebookRename") }
    }

    func deleteEmptyNotebook(id: UUID) async throws {
        let store = try liveStore()
        do { try await store.deleteNotebook(id) }
        catch NoteError.notFound { return }
        catch { throw C07DataExchangeError.rollbackFailed("notebookNotEmpty") }
    }

    func deleteEmptyNotebooks(markedTitle: String) async throws -> Int {
        let store = try liveStore()
        var removed = 0
        let books = try await store.notebooks()
        for book in books where book.title == markedTitle {
            do { try await store.deleteNotebook(book.id); removed += 1 }
            catch NoteError.notFound { continue }
        }
        return removed
    }

    func importNoteArchive(_ archive: C07ParsedNoteArchive,
                           notebookID: UUID?) async throws -> C07NoteImportReceipt {
        let store = try liveStore()
        var resourceMap: [UUID: UUID] = [:]
        for resource in archive.resources {
            if Task.isCancelled { throw CancellationError() }
            do {
                let id = try await store.importResource(
                    from: resource.stagedURL, mediaType: "application/octet-stream")
                resourceMap[resource.originalID] = id
            } catch {
                for id in resourceMap.values {
                    _ = try? await store.discardUnreferencedResource(id)
                }
                throw C07DataExchangeError.notesArchive("resourceImport")
            }
        }
        if Task.isCancelled { throw CancellationError() }
        let documentMap = archive.documentIDMap
        var documents: [NoteDocument] = []
        for plan in archive.documents {
            do {
                documents.append(try C07NoteRemap.remap(
                    document: plan.original,
                    newDocumentID: plan.newDocumentID,
                    newNotebookID: notebookID,
                    documentMap: documentMap,
                    resourceMap: resourceMap))
            } catch let error as C07DataExchangeError {
                throw error
            } catch {
                for id in resourceMap.values {
                    _ = try? await store.discardUnreferencedResource(id)
                }
                throw C07DataExchangeError.notesArchive("remap")
            }
        }
        if Task.isCancelled { throw CancellationError() }
        do {
            _ = try await store.createBundle(documents)
        } catch {
            for id in resourceMap.values {
                _ = try? await store.discardUnreferencedResource(id)
            }
            throw C07DataExchangeError.notesArchive("createBundle")
        }
        return C07NoteImportReceipt(
            documentIDs: documents.map(\.id),
            resourceCount: resourceMap.count)
    }

    func removeNotes(documentIDs: [UUID]) async throws {
        let store = try liveStore()
        for id in documentIDs {
            guard let document = try? await store.document(id) else { continue }
            var current = document
            if current.deletedAt == nil {
                do {
                    current = try await store.setTrashed(
                        id, expectedRevision: current.revision, trashed: true)
                } catch NoteError.notFound { continue }
                catch { throw C07DataExchangeError.rollbackFailed("noteTrash") }
            }
            do { try await store.permanentlyDelete(id, expectedRevision: current.revision) }
            catch NoteError.notFound { continue }
            catch { throw C07DataExchangeError.rollbackFailed("noteDelete") }
        }
        _ = try? await store.collectDeletedResources()
    }
}

// MARK: - Live restore sink

struct C07LiveRestoreSink: C07RestoreSink, Sendable {
    let context: C07DataExchangeContext
    let notes: C07NotesSink

    func createProject(markerName: String, origin: C07ProjectOrigin) async throws -> UUID {
        do {
            let row = try await context.projectLibrary.create(name: markerName)
            return row.id
        } catch {
            throw C07DataExchangeError.storageUnavailable("projectCreate")
        }
    }

    func renameProject(id: UUID, to finalName: String) async throws {
        let name = Self.safeProjectName(finalName)
        do {
            let detail = try await context.projectLibrary.get(projectID: id)
            _ = try await context.projectLibrary.rename(
                projectID: id, name: name, expectedRevision: detail.project.revision)
        } catch {
            throw C07DataExchangeError.storageUnavailable("projectRename")
        }
    }

    func writeProjectFiles(projectID: UUID,
                           directories: [String],
                           files: [C07StagedProjectFile]) async throws {
        let state = C01ProjectRootLayout.inspectProjectDirectory(
            rootPath: context.rootPath, projectID: projectID)
        guard state == .available else {
            throw C07DataExchangeError.storageUnavailable("projectRoot")
        }
        let root = URL(fileURLWithPath: C01ProjectRootLayout.projectDirectory(
            rootPath: context.rootPath, projectID: projectID))
        let rootPath = root.standardizedFileURL.path
        for directory in directories.sorted(by: { depth($0) < depth($1) }) {
            try C07Path.validateRelative(directory)
            let url = root.appendingPathComponent(directory, isDirectory: true)
            guard contained(url, rootPath) else {
                throw C07DataExchangeError.unsafePath(directory)
            }
            do { try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true) }
            catch { throw C07DataExchangeError.storageUnavailable("mkdir") }
            let values = try url.resourceValues(
                forKeys: Set<URLResourceKey>([.isDirectoryKey, .isSymbolicLinkKey]))
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw C07DataExchangeError.symlinkUnsupported(directory)
            }
        }
        for file in files.sorted(by: { $0.relativePath < $1.relativePath }) {
            try C07Path.validateRelative(file.relativePath)
            let destination = root.appendingPathComponent(file.relativePath)
            guard contained(destination, rootPath) else {
                throw C07DataExchangeError.unsafePath(file.relativePath)
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try C07POSIX.writeExclusive(
                source: file.stagedURL, destination: destination,
                expectedBytes: file.byteCount, expectedSHA256: file.sha256,
                mode: file.mode)
        }
    }

    func deleteProject(id: UUID) async throws {
        do {
            let detail = try await context.projectLibrary.get(projectID: id)
            let receipt = try await context.projectLibrary.delete(
                projectID: id, expectedRevision: detail.project.revision,
                deleteRoot: true, stopActiveTasks: false)
            if receipt.rootRetained {
                _ = C01ProjectRootLayout.removeProjectDirectory(
                    rootPath: context.rootPath, projectID: id)
            }
        } catch C01ProjectError.notFound {
            return
        } catch {
            throw C07DataExchangeError.rollbackFailed("projectDelete")
        }
    }

    func deleteProjects(markedName: String) async throws -> Int {
        var removed = 0
        for _ in 0..<100 {
            let page = try await context.projectLibrary.list(limit: 100, offset: 0)
            let matches = page.filter { $0.name == markedName }
            if matches.isEmpty { break }
            for match in matches {
                try await deleteProject(id: match.id)
                removed += 1
            }
        }
        return removed
    }

    func createNotebook(markerTitle: String) async throws -> UUID {
        try await notes.createNotebook(title: markerTitle)
    }

    func renameNotebook(id: UUID, to finalTitle: String) async throws {
        try await notes.renameNotebook(id: id, title: Self.safeNotebookTitle(finalTitle))
    }

    func deleteEmptyNotebook(id: UUID) async throws {
        try await notes.deleteEmptyNotebook(id: id)
    }

    func deleteEmptyNotebooks(markedTitle: String) async throws -> Int {
        try await notes.deleteEmptyNotebooks(markedTitle: markedTitle)
    }

    func importNoteArchive(_ archive: C07ParsedNoteArchive,
                           notebookID: UUID?) async throws -> C07NoteImportReceipt {
        try await notes.importNoteArchive(archive, notebookID: notebookID)
    }

    func removeNotes(documentIDs: [UUID]) async throws {
        try await notes.removeNotes(documentIDs: documentIDs)
    }

    func insertSettingIfAbsent(key: String, json: String) async throws -> Bool {
        guard C07SettingsPolicy.isAllowedKey(key) else {
            throw C07DataExchangeError.invalidScope("settingKey")
        }
        do {
            return try await context.settingsStore.compareAndSetValue(
                json, forKey: key, expectedValue: nil)
        } catch {
            throw C07DataExchangeError.storageUnavailable("settingInsert")
        }
    }

    func removeSettingIfExact(key: String, json: String) async throws {
        guard C07SettingsPolicy.isAllowedKey(key) else { return }
        do {
            guard try await context.settingsStore.value(forKey: key) == json else { return }
            try await context.settingsStore.removeValue(forKey: key)
        } catch {
            throw C07DataExchangeError.rollbackFailed("settingRemove")
        }
    }

    private func contained(_ url: URL, _ rootPath: String) -> Bool {
        let path = url.standardizedFileURL.path
        return path.hasPrefix(rootPath + "/")
    }

    private func depth(_ path: String) -> Int {
        path.split(separator: "/").count
    }

    static func safeProjectName(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
        value = value.filter { character in
            character.unicodeScalars.allSatisfy {
                $0.value >= 0x20 && $0.value != 0x7F
            }
        }
        if value.isEmpty { value = "Restored project" }
        if value.count > 80 { value = String(value.prefix(80)) }
        return value
    }

    static func safeNotebookTitle(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.filter { character in
            character.unicodeScalars.allSatisfy {
                $0.value >= 0x20 && $0.value != 0x7F
            }
        }
        return value.isEmpty ? "Restored notebook" : value
    }
}

// MARK: - POSIX exclusive write

enum C07POSIX {
    static func writeExclusive(source: URL,
                               destination: URL,
                               expectedBytes: Int64,
                               expectedSHA256: String,
                               mode: Int = 0o600) throws {
        let path = destination.path
        let safeMode = mode & 0o777
        let fd = path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                 mode_t(S_IRUSR | S_IWUSR))
        }
        guard fd >= 0 else {
            throw C07DataExchangeError.storageUnavailable("exclusiveCreate")
        }
        if fchmod(fd, mode_t(safeMode)) != 0 {
            close(fd)
            C07FileSystem.removeIfPresent(destination)
            throw C07DataExchangeError.storageUnavailable("exclusiveMode")
        }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let input: FileHandle
        do { input = try FileHandle(forReadingFrom: source) }
        catch {
            try? output.close()
            C07FileSystem.removeIfPresent(destination)
            throw C07DataExchangeError.storageUnavailable("sourceOpen")
        }
        var hasher = SHA256()
        var count: Int64 = 0
        do {
            while let chunk = try input.read(upToCount: C07DataExchangeLimits.copyChunkBytes),
                  !chunk.isEmpty {
                if Task.isCancelled {
                    try? input.close()
                    try? output.close()
                    C07FileSystem.removeIfPresent(destination)
                    throw C07DataExchangeError.cancelled
                }
                count += Int64(chunk.count)
                guard count <= expectedBytes else {
                    throw C07DataExchangeError.sizeMismatch(destination.lastPathComponent)
                }
                hasher.update(data: chunk)
                try output.write(contentsOf: chunk)
            }
            try input.close()
            try output.synchronize()
            try output.close()
        } catch let error as C07DataExchangeError {
            try? input.close(); try? output.close()
            C07FileSystem.removeIfPresent(destination)
            throw error
        } catch {
            try? input.close(); try? output.close()
            C07FileSystem.removeIfPresent(destination)
            throw C07DataExchangeError.storageUnavailable("projectWrite")
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard count == expectedBytes, digest == expectedSHA256 else {
            C07FileSystem.removeIfPresent(destination)
            throw digest != expectedSHA256
                ? C07DataExchangeError.hashMismatch(destination.lastPathComponent)
                : C07DataExchangeError.sizeMismatch(destination.lastPathComponent)
        }
    }
}

// MARK: - Job owner

public struct C07JobStatus: Sendable, Equatable {
    public var jobID: UUID
    public var kind: String
    public var phase: String
    public var doneBytes: Int64
    public var totalBytes: Int64
    public var errorCode: String?
    public var warnings: [String]
    public var fileByteCount: Int64?
    public var fileSHA256: String?
    public var projectCount: Int?
    public var projectFileCount: Int?
    public var noteDocumentCount: Int?
    public var noteResourceCount: Int?
    public var notebookCount: Int?
    public var settingsKeyCount: Int?
    public var providerAdvisoryCount: Int?
    public var trashedNotesExcluded: Int?
    public var restoredProjects: Int?
    public var restoredNotes: Int?
    public var restoredNotebooks: Int?
    public var restoredSettings: Int?
    public var skippedProjects: Int?
    public var conversationCount: Int?
    public var messageCount: Int?
    public var runCount: Int?
    public var toolCallCount: Int?
    public var workspaceCount: Int?
    public var canvasProjectCount: Int?
    public var mediaProjectCount: Int?
    public var mediaAssetCount: Int?
    public var scheduleCount: Int?
    public var actionReceiptCount: Int?
    public var mailReceiptCount: Int?
    public var providerConfigCount: Int?
    public var executionEvidenceCount: Int?
    public var restoredConversations: Int?
    public var restoredMessages: Int?
    public var restoredRuns: Int?
    public var restoredToolCalls: Int?
    public var restoredWorkspaces: Int?
    public var restoredSchedules: Int?
    public var restoredProviders: Int?
    public var restoredCanvasProjects: Int?
    public var restoredMediaProjects: Int?
    public var restoredEvidenceRows: Int?
    public var canCommit: Bool
}

public actor C07DataExchangeDomain {
    public static let shared = C07DataExchangeDomain()

    private enum Phase: String {
        case building
        case inspecting
        case ready
        case committing
        case complete
        case failed
        case cancelled
    }

    private struct Job {
        var id: UUID
        var kind: String
        var phase: Phase
        var doneBytes: Int64 = 0
        var totalBytes: Int64 = 0
        var errorCode: String?
        var warnings: [String] = []
        var fileURL: URL?
        var fileByteCount: Int64?
        var fileSHA256: String?
        var plan: C07RestorePlan?
        var planRoot: URL?
        var uploadStageID: UUID?
        var receipt: C07RestoreReceipt?
        var task: Task<Void, Never>?
        var createdAt: Date = Date()
    }

    private struct UploadStage {
        var id: UUID
        var expected: Int64
        var received: Int64
        var url: URL
        var handle: FileHandle
        var committed: Bool
    }

    private var jobs: [UUID: Job] = [:]
    private var uploads: [UUID: UploadStage] = [:]
    private var preparedRoots = Set<String>()

    // MARK: Context / preparation

    func makeContext(owner: C07ExchangeOwner) throws -> C07DataExchangeContext {
        let context = try C07DataExchangeContext.make(owner: owner)
        if preparedRoots.insert(context.dataRoot.path).inserted {
            do { try prepare(context) }
            catch {
                preparedRoots.remove(context.dataRoot.path)
                throw error
            }
        } else {
            try ensureDirectories(context)
        }
        return context
    }

    private func ensureDirectories(_ context: C07DataExchangeContext) throws {
        for root in [context.dataRoot, context.exportsRoot, context.incomingRoot,
                     context.stagingRoot, context.workRoot, context.journalRoot] {
            try C07FileSystem.ensureDirectory(root)
        }
    }

    private func prepare(_ context: C07DataExchangeContext) throws {
        try ensureDirectories(context)
        // Only this process created these; journals are the durable exception.
        for root in [context.exportsRoot, context.incomingRoot,
                     context.stagingRoot, context.workRoot] {
            let items = (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])) ?? []
            for item in items {
                C07FileSystem.removeIfPresent(item)
            }
        }
    }

    // MARK: Backup / note export

    func startBackup(context: C07DataExchangeContext,
                     includeRetainedProjects: Bool) -> UUID {
        let id = UUID()
        let work = context.workRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        let destination = context.exportsRoot.appendingPathComponent(
            "\(id.uuidString).\(C07DataExchangeLimits.backupExtension)")
        jobs[id] = Job(id: id, kind: "backup", phase: .building)
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                try C07FileSystem.ensureDirectory(work)
                let source = try await C07LiveSourceBuilder(
                    context: context, workRoot: work)
                    .makeSource(includeRetainedProjects: includeRetainedProjects) {
                        done, total in
                        Task { await self.updateProgress(id, done: done, total: total) }
                    }
                let built = try await C07BackupBuilder.build(
                    source: source, destination: destination,
                    stagingRoot: work.appendingPathComponent("staging", isDirectory: true)
                ) { done, total in
                    Task { await self.updateProgress(id, done: done, total: total) }
                }
                C07FileSystem.removeIfPresent(work)
                await self.finishFileJob(
                    id, url: built.fileURL, bytes: built.byteCount,
                    sha: built.sha256, warnings: built.warnings,
                    manifest: built.manifest)
            } catch is CancellationError {
                C07FileSystem.removeIfPresent(destination)
                C07FileSystem.removeIfPresent(work)
                await self.finishFailure(id, code: "cancelled")
            } catch let error as C07DataExchangeError {
                C07FileSystem.removeIfPresent(destination)
                C07FileSystem.removeIfPresent(work)
                await self.finishFailure(id, code: error.code, reason: error.errorDescription)
            } catch {
                C07FileSystem.removeIfPresent(destination)
                C07FileSystem.removeIfPresent(work)
                await self.finishFailure(id, code: "internal")
            }
        }
        jobs[id]?.task = task
        return id
    }

    func startNoteExport(context: C07DataExchangeContext,
                         documentID: UUID,
                         expectedRevision: Int) -> UUID {
        let id = UUID()
        let work = context.workRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        let destination = context.exportsRoot.appendingPathComponent(
            "\(id.uuidString).\(C07DataExchangeLimits.notesExtension)")
        jobs[id] = Job(id: id, kind: "noteExport", phase: .building)
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                try C07FileSystem.ensureDirectory(work)
                let sink = C07NotesSink(root: context.notesRoot)
                try await sink.exportNote(
                    documentID: documentID,
                    expectedRevision: expectedRevision,
                    to: destination)
                let digest = try C07Digest.file(destination)
                C07FileSystem.removeIfPresent(work)
                await self.finishFileJob(
                    id, url: destination, bytes: digest.byteCount,
                    sha: digest.sha256, warnings: [], manifest: nil)
            } catch {
                C07FileSystem.removeIfPresent(destination)
                C07FileSystem.removeIfPresent(work)
                let code = (error as? C07DataExchangeError)?.code ?? "internal"
                await self.finishFailure(id, code: code)
            }
        }
        jobs[id]?.task = task
        return id
    }

    // MARK: Upload staging

    func stageBegin(context: C07DataExchangeContext, byteCount: Int64) throws -> UUID {
        guard byteCount > 0, byteCount <= C07DataExchangeWire.maximumStageBytes else {
            throw C07DataExchangeError.invalidScope("stageSize")
        }
        try C07FileSystem.ensureDirectory(context.incomingRoot)
        let id = UUID()
        let url = context.incomingRoot.appendingPathComponent("\(id.uuidString).upload")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw C07DataExchangeError.storageUnavailable("stageCreate")
        }
        let handle: FileHandle
        do { handle = try FileHandle(forWritingTo: url) }
        catch {
            C07FileSystem.removeIfPresent(url)
            throw C07DataExchangeError.storageUnavailable("stageOpen")
        }
        uploads[id] = UploadStage(
            id: id, expected: byteCount, received: 0,
            url: url, handle: handle, committed: false)
        return id
    }

    func stageAppend(stageID: UUID, data: Data) throws -> C07StageAppendResult {
        guard var stage = uploads[stageID] else {
            throw C07DataExchangeError.notFound
        }
        guard !stage.committed, !data.isEmpty,
              data.count <= C07DataExchangeWire.maximumChunkBytes else {
            throw C07DataExchangeError.invalidScope("stageChunk")
        }
        guard stage.received + Int64(data.count) <= stage.expected else {
            throw C07DataExchangeError.entryTooLarge("stage")
        }
        do { try stage.handle.write(contentsOf: data) }
        catch { throw C07DataExchangeError.storageUnavailable("stageWrite") }
        stage.received += Int64(data.count)
        uploads[stageID] = stage
        return C07StageAppendResult(receivedBytes: stage.received, totalBytes: stage.expected)
    }

    func stageCommit(stageID: UUID) throws -> URL {
        guard var stage = uploads[stageID] else {
            throw C07DataExchangeError.notFound
        }
        guard stage.received == stage.expected else {
            throw C07DataExchangeError.restoreIncomplete
        }
        do { try stage.handle.synchronize(); try stage.handle.close() }
        catch { throw C07DataExchangeError.storageUnavailable("stageCommit") }
        stage.committed = true
        uploads[stageID] = stage
        return stage.url
    }

    func stageAbort(stageID: UUID) {
        guard let stage = uploads.removeValue(forKey: stageID) else { return }
        try? stage.handle.close()
        C07FileSystem.removeIfPresent(stage.url)
    }

    // MARK: Restore inspect / commit

    func startRestoreInspect(context: C07DataExchangeContext,
                             stageID: UUID,
                             currentAppSchemaVersion: Int) throws -> UUID {
        guard let stage = uploads[stageID] else {
            throw C07DataExchangeError.notFound
        }
        guard stage.committed else {
            throw C07DataExchangeError.restoreIncomplete
        }
        let uploadURL = stage.url
        let id = UUID()
        jobs[id] = Job(id: id, kind: "restore", phase: .inspecting,
                       uploadStageID: stageID)
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let plan = try await C07BackupReader.inspect(
                    archiveURL: uploadURL,
                    stagingRoot: context.stagingRoot,
                    currentAppSchemaVersion: currentAppSchemaVersion
                ) { done, total in
                    Task { await self.updateProgress(id, done: done, total: total) }
                }
                await self.finishInspection(id, plan: plan)
            } catch let error as C07DataExchangeError {
                await self.finishFailure(id, code: error.code,
                                         reason: error.errorDescription)
            } catch {
                await self.finishFailure(id, code: "internal")
            }
        }
        jobs[id]?.task = task
        return id
    }

    /// Standalone `.floenote` import: parse the established iOS-format
    /// document package, then use the SAME journal/commit engine with an
    /// empty synthetic project/settings plan. This is not an app backup and
    /// never claims to restore projects or preferences.
    func startNoteImportInspect(context: C07DataExchangeContext,
                                stageID: UUID) throws -> UUID {
        guard let stage = uploads[stageID] else {
            throw C07DataExchangeError.notFound
        }
        guard stage.committed else {
            throw C07DataExchangeError.restoreIncomplete
        }
        let uploadURL = stage.url
        let id = UUID()
        let planRoot = context.stagingRoot.appendingPathComponent(
            "note-import-\(id.uuidString)", isDirectory: true)
        jobs[id] = Job(id: id, kind: "noteImport", phase: .inspecting,
                       uploadStageID: stageID)
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let parsed = try C07NotesPackage.parse(
                    archiveURL: uploadURL,
                    stagingRoot: planRoot,
                    expectedDocumentID: nil,
                    metadataTitle: "Imported note")
                let manifest = C07BackupManifest(
                    appSchemaVersion: DatabaseManager.currentSchemaVersion,
                    scope: C07BackupScope(excluded: C07ScopePolicy.excluded),
                    projects: [],
                    notes: C07NotesRecord(notebooks: [], documents: []),
                    settings: C07SettingsRecord(
                        entry: nil, byteCount: 0, sha256: nil,
                        keys: [], providerCatalog: []),
                    warnings: [])
                let digest = try C07Digest.file(uploadURL)
                let bytes = parsed.resources.reduce(Int64(0)) { $0 + $1.byteCount }
                let plan = C07RestorePlan(
                    manifest: manifest,
                    manifestSHA256: digest.sha256,
                    stagedRoot: planRoot,
                    projects: [],
                    notes: [parsed],
                    settingsValues: [:],
                    warnings: [],
                    totalBytes: bytes)
                await self.finishInspection(id, plan: plan)
            } catch let error as C07DataExchangeError {
                C07FileSystem.removeIfPresent(planRoot)
                await self.finishFailure(id, code: error.code,
                                         reason: error.errorDescription)
            } catch {
                C07FileSystem.removeIfPresent(planRoot)
                await self.finishFailure(id, code: "internal")
            }
        }
        jobs[id]?.task = task
        return id
    }

    func startRestoreCommit(context: C07DataExchangeContext,
                            jobID: UUID) throws -> UUID {
        guard var job = jobs[jobID],
              job.kind == "restore" || job.kind == "noteImport",
              let plan = job.plan else {
            throw C07DataExchangeError.notFound
        }
        if job.receipt != nil { return jobID }
        let sink = C07LiveRestoreSink(
            context: context, notes: C07NotesSink(root: context.notesRoot))
        job.phase = .committing
        jobs[jobID] = job
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let recovery = await C07RestoreRecovery.recover(
                journalRoot: context.journalRoot, sink: sink)
            if recovery.failedJournals > 0 {
                await self.finishFailure(
                    jobID, code: "restoreIncomplete",
                    reason: "recoveryFailed")
                return
            }
            do {
                let receipt = try await C07RestoreEngine.commit(
                    plan: plan, sink: sink, journalRoot: context.journalRoot
                ) { done, total in
                    Task { await self.updateProgress(jobID, done: Int64(done),
                                                     total: Int64(total)) }
                }
                await self.finishCommit(jobID, receipt: receipt)
            } catch {
                let code = (error as? C07DataExchangeError)?.code ?? "internal"
                await self.finishFailure(jobID, code: code,
                                         reason: error.localizedDescription)
            }
        }
        jobs[jobID]?.task = task
        return jobID
    }

    // MARK: Job access

    func status(jobID: UUID) throws -> C07JobStatus {
        guard let job = jobs[jobID] else { throw C07DataExchangeError.notFound }
        return C07JobStatus(
            jobID: job.id,
            kind: job.kind,
            phase: job.phase.rawValue,
            doneBytes: job.doneBytes,
            totalBytes: job.totalBytes,
            errorCode: job.errorCode,
            warnings: job.warnings,
            fileByteCount: job.fileByteCount,
            fileSHA256: job.fileSHA256,
            projectCount: job.plan?.projects.count,
            projectFileCount: job.plan?.projectFileCount,
            noteDocumentCount: job.plan?.noteDocumentCount,
            noteResourceCount: job.plan?.noteResourceCount,
            notebookCount: job.plan?.manifest.notes.notebooks.count,
            settingsKeyCount: job.plan?.settingsValues.count,
            providerAdvisoryCount: job.plan?.manifest.settings.providerCatalog.count,
            trashedNotesExcluded: job.plan?.manifest.notes.trashedDocumentsExcluded,
            restoredProjects: job.receipt?.projectsRestored,
            restoredNotes: job.receipt?.noteDocumentsRestored,
            restoredNotebooks: job.receipt?.notebooksRestored,
            restoredSettings: job.receipt?.settingsInserted,
            skippedProjects: job.receipt?.projectsSkipped ?? job.plan?.skippedProjectCount,
            conversationCount: job.plan?.ownedDataCounts.conversations,
            messageCount: job.plan?.ownedDataCounts.messages,
            runCount: job.plan?.ownedDataCounts.runs,
            toolCallCount: job.plan?.ownedDataCounts.toolCalls,
            workspaceCount: job.plan?.ownedDataCounts.workspaces,
            canvasProjectCount: job.plan?.ownedDataCounts.canvasProjects,
            mediaProjectCount: job.plan?.ownedDataCounts.mediaProjects,
            mediaAssetCount: job.plan?.ownedDataCounts.mediaAssets,
            scheduleCount: job.plan?.ownedDataCounts.schedules,
            actionReceiptCount: job.plan?.ownedDataCounts.actionReceipts,
            mailReceiptCount: job.plan?.ownedDataCounts.mailReceipts,
            providerConfigCount: job.plan?.ownedDataCounts.providers,
            executionEvidenceCount: {
                guard let counts = job.plan?.ownedDataCounts else { return nil }
                return counts.executionTargets
                    + counts.executionTargetMigrations
                    + counts.runExecutionPins
                    + counts.remoteCommandReceipts
            }(),
            restoredConversations: job.receipt?.conversationsRestored,
            restoredMessages: job.receipt?.messagesRestored,
            restoredRuns: job.receipt?.runsRestored,
            restoredToolCalls: job.receipt?.toolCallsRestored,
            restoredWorkspaces: job.receipt?.workspacesRestored,
            restoredSchedules: job.receipt?.schedulesRestored,
            restoredProviders: job.receipt?.providersRestored,
            restoredCanvasProjects: job.receipt?.canvasProjectsRestored,
            restoredMediaProjects: job.receipt?.mediaProjectsRestored,
            restoredEvidenceRows: job.receipt?.evidenceRowsRestored,
            canCommit: ((job.kind == "restore" || job.kind == "noteImport")
                && job.phase == .ready && job.plan != nil))
    }

    func read(jobID: UUID, offset: Int64, maxBytes: Int) throws
        -> C07JobReadResult
    {
        guard let job = jobs[jobID], let url = job.fileURL,
              job.phase == .ready || job.phase == .complete else {
            throw C07DataExchangeError.notFound
        }
        guard offset >= 0, maxBytes > 0,
              maxBytes <= C07DataExchangeWire.maximumChunkBytes else {
            throw C07DataExchangeError.invalidScope("readBounds")
        }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        let total = Int64(values?.fileSize ?? 0)
        guard offset <= total else {
            throw C07DataExchangeError.invalidScope("offset")
        }
        if offset == total {
            return C07JobReadResult(data: Data(), nextOffset: total,
                                    totalBytes: total, eof: true)
        }
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch { throw C07DataExchangeError.storageUnavailable("readOpen") }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(offset))
            guard let data = try handle.read(upToCount: maxBytes) else {
                return C07JobReadResult(data: Data(), nextOffset: total,
                                    totalBytes: total, eof: true)
            }
            let next = offset + Int64(data.count)
            return C07JobReadResult(data: data, nextOffset: next,
                                    totalBytes: total, eof: next >= total)
        } catch {
            throw C07DataExchangeError.storageUnavailable("read")
        }
    }

    func closeJob(jobID: UUID) {
        guard var job = jobs[jobID] else { return }
        job.task?.cancel()
        if let file = job.fileURL { C07FileSystem.removeIfPresent(file) }
        if let root = job.planRoot { C07FileSystem.removeIfPresent(root) }
        if let stageID = job.uploadStageID { stageAbort(stageID: stageID) }
        job.phase = .cancelled
        jobs.removeValue(forKey: jobID)
    }

    func cancel(jobID: UUID) {
        guard var job = jobs[jobID] else { return }
        job.task?.cancel()
        if let file = job.fileURL { C07FileSystem.removeIfPresent(file) }
        job.phase = .cancelled
        jobs[jobID] = job
    }

    func recoveryPending(context: C07DataExchangeContext) -> Int {
        C07RestoreRecovery.pendingCount(journalRoot: context.journalRoot)
    }

    func recover(context: C07DataExchangeContext) async -> C07RecoveryReport {
        let sink = C07LiveRestoreSink(
            context: context, notes: C07NotesSink(root: context.notesRoot))
        return await C07RestoreRecovery.recover(
            journalRoot: context.journalRoot, sink: sink)
    }

    // MARK: Job transitions

    private func updateProgress(_ id: UUID, done: Int64, total: Int64) {
        guard var job = jobs[id] else { return }
        job.doneBytes = max(0, done)
        job.totalBytes = max(0, total)
        jobs[id] = job
    }

    private func finishFileJob(_ id: UUID, url: URL, bytes: Int64, sha: String,
                               warnings: [String],
                               manifest: C07BackupManifest?) {
        guard var job = jobs[id] else { return }
        job.phase = .ready
        job.fileURL = url
        job.fileByteCount = bytes
        job.fileSHA256 = sha
        job.warnings = warnings
        job.doneBytes = bytes
        job.totalBytes = bytes
        if manifest != nil {
            job.totalBytes = bytes
            // Backup job metadata only; restore inspection creates the plan.
            job.plan = nil
        }
        jobs[id] = job
    }

    private func finishInspection(_ id: UUID, plan: C07RestorePlan) {
        guard var job = jobs[id] else { return }
        job.phase = .ready
        job.plan = plan
        job.planRoot = plan.stagedRoot
        job.warnings = plan.warnings
        job.doneBytes = plan.totalBytes
        job.totalBytes = plan.totalBytes
        if let stageID = job.uploadStageID { stageAbort(stageID: stageID) }
        job.uploadStageID = nil
        jobs[id] = job
    }

    private func finishCommit(_ id: UUID, receipt: C07RestoreReceipt) {
        guard var job = jobs[id] else { return }
        job.phase = .complete
        job.receipt = receipt
        job.warnings = receipt.warnings
        job.plan = nil
        if let root = job.planRoot { C07FileSystem.removeIfPresent(root) }
        job.planRoot = nil
        jobs[id] = job
    }

    private func finishFailure(_ id: UUID, code: String, reason: String? = nil) {
        guard var job = jobs[id] else { return }
        job.phase = .failed
        job.errorCode = code
        job.warnings.append(reason ?? code)
        jobs[id] = job
    }
}

// MARK: - Full owned-data source capture

/// Reads the logical App data graph from ONE GRDB read transaction and builds
/// the Canvas/media/attachment/receipt artifact graph. It never copies
/// `floe.sqlite`, `-wal`, `-shm` or a guest image.
struct C07OwnedDataSource {
    static func capture(context: C07DataExchangeContext,
                        workRoot: URL,
                        includeRetainedProjects: Bool) async throws
        -> C07SourceOwnedData
    {
        try C07FileSystem.ensureDirectory(workRoot)
        let tablesRoot = workRoot.appendingPathComponent("tables", isDirectory: true)
        try C07FileSystem.ensureDirectory(tablesRoot)
        var warnings: [String] = []

        let captured = try await captureTables(
            database: context.database, directory: tablesRoot)
        warnings.append(contentsOf: captured.warnings)
        var counts = captured.counts

        let workspaceFile = workRoot.appendingPathComponent("workspaces.json")
        let descriptors = captured.workspaces
        let workspaceData: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            workspaceData = try encoder.encode(descriptors)
        } catch {
            throw C07DataExchangeError.storageUnavailable("workspacesEncode")
        }
        do { try workspaceData.write(to: workspaceFile) }
        catch { throw C07DataExchangeError.storageUnavailable("workspacesWrite") }
        counts.workspaces = descriptors.count

        var artifacts: [C07SourceArtifact] = []
        var entries = Set<String>()
        warnings.append(contentsOf: try captureCanvasArtifacts(
            context: context, workRoot: workRoot,
            artifacts: &artifacts, entries: &entries, counts: &counts))
        warnings.append(contentsOf: try captureAttachmentArtifacts(
            context: context, tables: captured.tables,
            artifacts: &artifacts, entries: &entries, counts: &counts))
        warnings.append(contentsOf: try capturePrivateTaskArtifacts(
            context: context, workspaces: descriptors,
            artifacts: &artifacts, entries: &entries, counts: &counts))
        warnings.append(contentsOf: try captureMailReceipts(
            context: context, artifacts: &artifacts, entries: &entries,
            counts: &counts))

        var checkpointPort = "unavailable"
        var checkpointReason: String? = "c01CheckpointPortNotInstalled"
        if let port = C07LinuxCheckpointPortRegistry.installed,
           port.portVersion >= C07LinuxCheckpointWire.version {
            do {
                let exports = try await port.exportEnvironments()
                guard exports.count <= C07LinuxCheckpointWire.maximumEnvironments else {
                    throw C07DataExchangeError.tooManyEntries
                }
                for environment in exports {
                    let descriptor = C07LinuxEnvironmentDescriptor(
                        environmentID: environment.environmentID,
                        name: environment.name,
                        runtimeKind: environment.runtimeKind,
                        checkpointFormat: environment.checkpointFormat,
                        metadataJSON: environment.metadataJSON)
                    let metadataData: Data
                    do {
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.sortedKeys]
                        metadataData = try encoder.encode(descriptor)
                    } catch {
                        throw C07DataExchangeError.storageUnavailable(
                            "environmentDescriptor")
                    }
                    let metadataURL = workRoot.appendingPathComponent(
                        "env-\(environment.environmentID.uuidString)-metadata.json")
                    do { try metadataData.write(to: metadataURL) }
                    catch {
                        throw C07DataExchangeError.storageUnavailable(
                            "environmentDescriptorWrite")
                    }
                    appendArtifact(
                        role: .environmentCheckpoint,
                        ownerID: environment.environmentID,
                        containerID: nil,
                        logicalPath: "metadata.json",
                        sourceURL: metadataURL,
                        artifacts: &artifacts, entries: &entries, counts: &counts)
                    for file in environment.files {
                        do {
                            _ = try C07Path.validateRelative(file.relativePath)
                        } catch {
                            warnings.append("environmentPathRejected")
                            continue
                        }
                        appendArtifact(
                            role: .environmentCheckpoint,
                            ownerID: environment.environmentID,
                            containerID: nil,
                            logicalPath: file.relativePath,
                            sourceURL: file.url,
                            artifacts: &artifacts, entries: &entries,
                            counts: &counts)
                    }
                }
                checkpointPort = "available"
                checkpointReason = nil
            } catch {
                checkpointPort = "unavailable"
                checkpointReason = "c01CheckpointExportFailed"
                warnings.append("environmentExportFailed")
            }
        }

        let excluded = C07ScopePolicy.excluded
        counts.artifacts = artifacts.count
        counts.artifactBytes = artifacts.reduce(0) { $0 + $1.record.byteCount }
        _ = includeRetainedProjects
        return C07SourceOwnedData(
            tables: captured.tables,
            workspaces: C07SourceWorkspaces(
                url: workspaceFile, count: descriptors.count),
            artifacts: artifacts,
            counts: counts,
            excluded: excluded,
            linuxCheckpointPort: checkpointPort,
            linuxCheckpointReason: checkpointReason,
            warnings: warnings)
    }

    private struct CapturedTables {
        var tables: [C07SourceTable]
        var workspaces: [C07WorkspaceDescriptor]
        var counts: C07OwnedDataCounts
        var warnings: [String]
        var schemaVersion: Int
    }

    private static func captureTables(database: DatabaseManager,
                                      directory: URL) async throws -> CapturedTables {
        try await database.reader { db in
            let schemaVersion = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
            var tables: [C07SourceTable] = []
            var counts = C07OwnedDataCounts()
            var warnings: [String] = []
            for policy in C07OwnedDataPolicy.tables {
                let exists = try db.tableExists(policy.name)
                if !exists {
                    if policy.optional {
                        warnings.append("tableUnavailable:\(policy.name)")
                        continue
                    }
                    throw C07DataExchangeError.schemaMismatch(schemaVersion)
                }
                let columns = Set(try db.columns(in: policy.name).map(\.name))
                guard policy.requiredColumns.isSubset(of: columns) else {
                    throw C07DataExchangeError.schemaMismatch(schemaVersion)
                }
                let url = directory.appendingPathComponent(
                    "\(policy.name).jsonl")
                let writer = try C07RowStream.makeWriter(at: url)
                var excludedRows = 0
                let cursor = try Row.fetchCursor(
                    db, sql: "SELECT * FROM \"\(policy.name)\" ORDER BY rowid")
                while let row = try cursor.next() {
                    if Task.isCancelled { throw C07DataExchangeError.cancelled }
                    var values: C07DBRow = [:]
                    for column in row.columnNames {
                        let value: DatabaseValue = row[column]
                        values[column] = dbValue(value)
                    }
                    guard C07OwnedDataPolicy.shouldExportRow(
                        table: policy.name, row: values) else {
                        excludedRows += 1
                        continue
                    }
                    let exported = C07OwnedDataPolicy.exportedRow(
                        table: policy.name, row: values)
                    try writer.append(exported)
                }
                try writer.finish()
                if excludedRows > 0 {
                    warnings.append("rowsExcluded:\(policy.name):\(excludedRows)")
                }
                let digest = try C07Digest.file(url)
                tables.append(C07SourceTable(
                    name: policy.name, url: url, rowCount: writer.rowCount))
                updateCounts(table: policy.name, rows: writer.rowCount,
                             counts: &counts)
            }
            let workspaces = try captureWorkspaces(db: db, warnings: &warnings)
            return CapturedTables(
                tables: tables, workspaces: workspaces,
                counts: counts, warnings: warnings,
                schemaVersion: schemaVersion)
        }
    }

    private static func dbValue(_ value: DatabaseValue) -> C07DBValue {
        switch value.storage {
        case .null: return .null
        case .int64(let integer): return .int(integer)
        case .double(let real): return .double(real)
        case .string(let text): return .string(text)
        case .blob(let data): return .data(data)
        }
    }

    private static func updateCounts(table: String, rows: Int,
                                     counts: inout C07OwnedDataCounts) {
        switch table {
        case "conversations": counts.conversations = rows
        case "messages": counts.messages = rows
        case "message_parts": counts.messageParts = rows
        case "runs": counts.runs = rows
        case "tool_calls": counts.toolCalls = rows
        case "attachments": counts.attachments = rows
        case "task_schedules": counts.schedules = rows
        case "task_schedule_occurrences": counts.occurrences = rows
        case "providers": counts.providers = rows
        case "models": counts.models = rows
        case "task_execution_targets": counts.executionTargets = rows
        case "task_execution_target_migrations":
            counts.executionTargetMigrations = rows
        case "task_run_execution_targets": counts.runExecutionPins = rows
        case "task_remote_command_receipts": counts.remoteCommandReceipts = rows
        case "run_events", "run_usage", "run_errors", "child_run_entries",
             "goal_events":
            counts.actionReceipts += rows
        default: break
        }
    }

    // MARK: Workspace descriptors (same read transaction)

    private static func captureWorkspaces(db: Database,
                                          warnings: inout [String])
        -> [C07WorkspaceDescriptor]
    {
        let rows: [Row]
        do {
            rows = try Row.fetchAll(db, sql: """
                SELECT id, name, kind, internal_relative_path,
                       length(root_bookmark) AS bookmark_length,
                       created_at, updated_at
                FROM workspaces ORDER BY id
                """)
        } catch {
            return []
        }
        var links: [UUID: Set<UUID>] = [:]
        if let linkRows = try? Row.fetchAll(
            db, sql: "SELECT workspace_id, conversation_id FROM workspace_conversations") {
            for row in linkRows {
                guard let workspaceText: String = row["workspace_id"],
                      let conversationText: String = row["conversation_id"],
                      let workspaceID = UUID(uuidString: workspaceText),
                      let conversationID = UUID(uuidString: conversationText) else {
                    continue
                }
                links[workspaceID, default: []].insert(conversationID)
            }
        }
        if let ownerRows = try? Row.fetchAll(
            db, sql: """
                SELECT workspace_id, conversation_id
                FROM conversation_workspace_ownership
                """) {
            for row in ownerRows {
                guard let workspaceText: String = row["workspace_id"],
                      let conversationText: String = row["conversation_id"],
                      let workspaceID = UUID(uuidString: workspaceText),
                      let conversationID = UUID(uuidString: conversationText) else {
                    continue
                }
                links[workspaceID, default: []].insert(conversationID)
            }
        }
        var result: [C07WorkspaceDescriptor] = []
        for row in rows {
            guard let idText: String = row["id"],
                  let workspaceID = UUID(uuidString: idText) else { continue }
            let name: String = row["name"] ?? ""
            let kind: String = row["kind"] ?? "project"
            let internalPath: String? = row["internal_relative_path"]
            let bookmarkLength: Int64 = row["bookmark_length"] ?? 0
            let createdAt = parseDate(row["created_at"] as String?) ?? Date()
            let updatedAt = parseDate(row["updated_at"] as String?) ?? createdAt
            var conversations = Array(links[workspaceID] ?? []).sorted {
                $0.uuidString < $1.uuidString
            }
            if kind == "privateTask", conversations.isEmpty,
               let path = internalPath,
               path.hasPrefix("PrivateTasks/"),
               let conversationID = UUID(uuidString: String(
                    path.dropFirst("PrivateTasks/".count))) {
                conversations = [conversationID]
            }
            let mode: C07WorkspaceRestoreMode
            let requiresRegrant: Bool
            if kind == "project",
               bookmarkLength == 0,
               let path = internalPath,
               path == C01ProjectRootLayout.internalRelativePath(
                    projectID: workspaceID) {
                mode = .managedProject
                requiresRegrant = false
            } else if kind == "privateTask",
                      let path = internalPath,
                      path.hasPrefix("PrivateTasks/") {
                mode = .privateTask
                requiresRegrant = false
            } else {
                mode = .externalRegrant
                requiresRegrant = true
                warnings.append("workspaceRequiresRegrant:\(workspaceID.uuidString.prefix(8))")
            }
            result.append(C07WorkspaceDescriptor(
                workspaceID: workspaceID, name: name, kind: kind,
                internalRelativePath: internalPath, mode: mode,
                conversationIDs: conversations,
                createdAt: createdAt, updatedAt: updatedAt,
                requiresRegrant: requiresRegrant))
        }
        return result
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: raw)
    }

    // MARK: Artifact capture

    private static let maximumArtifactFileBytes: Int64 =
        C07OwnedDataLimits.maximumArtifactBytes

    private static func appendArtifact(role: C07ArtifactRole,
                                       ownerID: UUID?,
                                       containerID: UUID?,
                                       logicalPath: String,
                                       sourceURL: URL,
                                       artifacts: inout [C07SourceArtifact],
                                       entries: inout Set<String>,
                                       counts: inout C07OwnedDataCounts) {
        guard let entry = try? C07ArtifactPath.entry(
            role: role, containerID: containerID, ownerID: ownerID,
            logicalPath: logicalPath) else { return }
        guard entries.insert(C07Path.collisionKey(entry)).inserted else { return }
        guard C07FileSystem.isRegularFile(sourceURL) else { return }
        guard let digest = try? C07Digest.file(
            sourceURL, maximum: maximumArtifactFileBytes) else { return }
        artifacts.append(C07SourceArtifact(
            record: C07ArtifactRecord(
                role: role, ownerID: ownerID, containerID: containerID,
                logicalPath: logicalPath, entry: entry,
                byteCount: digest.byteCount, sha256: digest.sha256),
            url: sourceURL))
        counts.artifacts += 1
        counts.artifactBytes += digest.byteCount
    }

    private static func captureCanvasArtifacts(
        context: C07DataExchangeContext, workRoot: URL,
        artifacts: inout [C07SourceArtifact], entries: inout Set<String>,
        counts: inout C07OwnedDataCounts) throws -> [String]
    {
        _ = workRoot
        var warnings: [String] = []
        let canvasDirectory = context.artifactRoot.appendingPathComponent(
            "Canvases", isDirectory: true)
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: canvasDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]) else {
            return warnings
        }
        for url in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where url.pathExtension.lowercased() == "json" {
            guard C07FileSystem.isRegularFile(url) else { continue }
            let data: Data
            do { data = try Data(contentsOf: url) }
            catch { warnings.append("canvasUnreadable"); continue }
            let references: C07CanvasReferences
            do { references = try C07CanvasGraph.scan(canvasData: data) }
            catch {
                warnings.append("canvasInvalid:\(url.deletingPathExtension().lastPathComponent.prefix(8))")
                continue
            }
            appendArtifact(
                role: .canvasProject, ownerID: references.canvasID,
                containerID: references.canvasID, logicalPath: "project.json",
                sourceURL: url, artifacts: &artifacts, entries: &entries,
                counts: &counts)
            counts.canvasProjects += 1
            for name in references.materialNames {
                let materialURL = context.artifactRoot
                    .appendingPathComponent("Materials", isDirectory: true)
                    .appendingPathComponent(name)
                if C07FileSystem.isRegularFile(materialURL) {
                    appendArtifact(
                        role: .canvasMaterial, ownerID: nil,
                        containerID: references.canvasID, logicalPath: name,
                        sourceURL: materialURL, artifacts: &artifacts,
                        entries: &entries, counts: &counts)
                } else {
                    warnings.append("canvasMaterialMissing:\(name)")
                }
            }
            var coveredMediaRoots = Set<String>()
            for childID in references.childProjectIDs {
                let projectURL = context.artifactRoot
                    .appendingPathComponent("MediaProjects", isDirectory: true)
                    .appendingPathComponent("media-project-\(childID.uuidString).json")
                guard C07FileSystem.isRegularFile(projectURL) else {
                    warnings.append("canvasChildMissing:\(childID.uuidString.prefix(8))")
                    continue
                }
                let projectData: Data
                do { projectData = try Data(contentsOf: projectURL) }
                catch { warnings.append("canvasChildUnreadable"); continue }
                appendArtifact(
                    role: .canvasMediaProject, ownerID: childID,
                    containerID: references.canvasID,
                    logicalPath: "media-project-\(childID.uuidString).json",
                    sourceURL: projectURL, artifacts: &artifacts,
                    entries: &entries, counts: &counts)
                counts.mediaProjects += 1
                let mediaRoot = "WorkbenchRoot/\(childID.uuidString)"
                coveredMediaRoots.insert(mediaRoot)
                guard let media = try? C07CanvasGraph.scanMediaProject(
                    data: projectData) else {
                    warnings.append("canvasMediaInvalid:\(childID.uuidString.prefix(8))")
                    continue
                }
                var seenAssetPaths = Set<String>()
                let childRoot = context.artifactRoot
                    .appendingPathComponent("WorkbenchRoot", isDirectory: true)
                    .appendingPathComponent(childID.uuidString, isDirectory: true)
                for assetPath in media.assetPaths {
                    seenAssetPaths.insert(assetPath)
                    let assetURL = assetPath.hasPrefix("WorkbenchRoot/")
                        ? context.artifactRoot.appendingPathComponent(assetPath)
                        : childRoot.appendingPathComponent(assetPath)
                    if C07FileSystem.isRegularFile(assetURL) {
                        appendArtifact(
                            role: .canvasAsset, ownerID: childID,
                            containerID: references.canvasID,
                            logicalPath: assetPath, sourceURL: assetURL,
                            artifacts: &artifacts, entries: &entries,
                            counts: &counts)
                        counts.mediaAssets += 1
                    } else {
                        warnings.append("canvasAssetMissing:\(assetPath.prefix(40))")
                    }
                }
                // Durable app-owned files in the media project root that are
                // not merely referenced (for example Workbench/Exports).
                if let enumerator = FileManager.default.enumerator(
                    at: childRoot,
                    includingPropertiesForKeys: [.isRegularFileKey,
                                                  .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]) {
                    let rootPath = childRoot.standardizedFileURL.path
                    for case let fileURL as URL in enumerator {
                        let values = try? fileURL.resourceValues(
                            forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                        guard values?.isRegularFile == true,
                              values?.isSymbolicLink != true else { continue }
                        let path = fileURL.standardizedFileURL.path
                        guard path.hasPrefix(rootPath + "/") else { continue }
                        let relative = String(path.dropFirst(rootPath.count + 1))
                        guard (try? C07Path.validateRelative(relative)) != nil,
                              seenAssetPaths.insert(relative).inserted else {
                            continue
                        }
                        appendArtifact(
                            role: .canvasAsset, ownerID: childID,
                            containerID: references.canvasID,
                            logicalPath: relative, sourceURL: fileURL,
                            artifacts: &artifacts, entries: &entries,
                            counts: &counts)
                        counts.mediaAssets += 1
                    }
                }
            }
            for path in references.nodeAssetPaths {
                if coveredMediaRoots.contains(where: { path.hasPrefix($0 + "/") }) {
                    continue
                }
                let assetURL = context.artifactRoot
                    .appendingPathComponent(path)
                if C07FileSystem.isRegularFile(assetURL) {
                    appendArtifact(
                        role: .canvasNodeAsset, ownerID: nil,
                        containerID: references.canvasID, logicalPath: path,
                        sourceURL: assetURL, artifacts: &artifacts,
                        entries: &entries, counts: &counts)
                } else {
                    warnings.append("canvasNodeAssetMissing:\(path.prefix(40))")
                }
            }
        }
        return warnings
    }

    private static func captureAttachmentArtifacts(
        context: C07DataExchangeContext, tables: [C07SourceTable],
        artifacts: inout [C07SourceArtifact], entries: inout Set<String>,
        counts: inout C07OwnedDataCounts) throws -> [String]
    {
        guard let table = tables.first(where: { $0.name == "attachments" }) else {
            return []
        }
        var warnings: [String] = []
        let attachmentsRoot = URL(fileURLWithPath: context.rootPath,
                                  isDirectory: true)
            .appendingPathComponent("Attachments", isDirectory: true)
        let rootPath = attachmentsRoot.standardizedFileURL.path
        try C07RowStream.rows(in: table.url, table: "attachments") { row in
            guard row["storage"]?.stringValue == "applicationSupport",
                  let relative = row["relative_path"]?.stringValue,
                  !relative.isEmpty,
                  let idText = row["id"]?.stringValue,
                  let attachmentID = UUID(uuidString: idText) else { return }
            guard (try? C07Path.validateRelative(relative)) != nil else {
                warnings.append("attachmentPathRejected")
                return
            }
            let url = attachmentsRoot.appendingPathComponent(relative)
                .standardizedFileURL
            guard url.path.hasPrefix(rootPath + "/"),
                  C07FileSystem.isRegularFile(url) else {
                warnings.append("attachmentBytesMissing:\(attachmentID.uuidString.prefix(8))")
                return
            }
            if let expected = row["sha256"]?.stringValue, !expected.isEmpty,
               let actual = try? C07Digest.file(url),
               actual.sha256 != expected {
                warnings.append("attachmentDigestMismatch:\(attachmentID.uuidString.prefix(8))")
                return
            }
            appendArtifact(
                role: .attachment, ownerID: attachmentID, containerID: nil,
                logicalPath: relative, sourceURL: url,
                artifacts: &artifacts, entries: &entries, counts: &counts)
        }
        return warnings
    }

    private static func capturePrivateTaskArtifacts(
        context: C07DataExchangeContext,
        workspaces: [C07WorkspaceDescriptor],
        artifacts: inout [C07SourceArtifact], entries: inout Set<String>,
        counts: inout C07OwnedDataCounts) throws -> [String]
    {
        var warnings: [String] = []
        let tasksRoot = URL(fileURLWithPath: context.rootPath, isDirectory: true)
            .appendingPathComponent("Workspace", isDirectory: true)
            .appendingPathComponent("PrivateTasks", isDirectory: true)
        for workspace in workspaces where workspace.mode == .privateTask {
            guard let conversationID = workspace.conversationIDs.first
                    ?? workspace.internalRelativePath
                        .flatMap({ path -> UUID? in
                            guard path.hasPrefix("PrivateTasks/") else { return nil }
                            return UUID(uuidString: String(path.dropFirst("PrivateTasks/".count)))
                        }) else {
                warnings.append("privateTaskOwnerUnknown")
                continue
            }
            let root = tasksRoot.appendingPathComponent(
                conversationID.uuidString, isDirectory: true)
            guard C07FileSystem.isDirectory(root) else {
                warnings.append("privateTaskMissing:\(conversationID.uuidString.prefix(8))")
                continue
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
                warnings.append("privateTaskEnumerateFailed")
                continue
            }
            for case let url as URL in enumerator {
                if Task.isCancelled { throw C07DataExchangeError.cancelled }
                let values = try? url.resourceValues(
                    forKeys: [.isRegularFileKey, .isDirectoryKey,
                              .isSymbolicLinkKey, .fileSizeKey])
                if values?.isSymbolicLink == true {
                    warnings.append("privateTaskSymlinkSkipped")
                    continue
                }
                if values?.isDirectory == true { continue }
                guard values?.isRegularFile == true else { continue }
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(rootPath + "/") else { continue }
                let relative = String(path.dropFirst(rootPath.count + 1))
                guard (try? C07Path.validateRelative(relative)) != nil else {
                    warnings.append("privateTaskPathRejected")
                    continue
                }
                appendArtifact(
                    role: .privateTaskFile, ownerID: conversationID,
                    containerID: nil, logicalPath: relative, sourceURL: url,
                    artifacts: &artifacts, entries: &entries, counts: &counts)
                counts.privateTaskFiles += 1
            }
            if enumerationFailure != nil {
                warnings.append("privateTaskEnumeratePartial")
            }
        }
        return warnings
    }

    private static func captureMailReceipts(
        context: C07DataExchangeContext,
        artifacts: inout [C07SourceArtifact], entries: inout Set<String>,
        counts: inout C07OwnedDataCounts) throws -> [String]
    {
        var warnings: [String] = []
        for area in ["MailMutations", "MailDelivery"] {
            let root = context.artifactRoot.appendingPathComponent(
                area, isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey,
                                              .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]) else { continue }
            let rootPath = root.standardizedFileURL.path
            for case let url as URL in enumerator {
                let values = try? url.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values?.isRegularFile == true,
                      values?.isSymbolicLink != true,
                      url.pathExtension.lowercased() == "json" else { continue }
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(rootPath + "/") else { continue }
                let relative = String(path.dropFirst(rootPath.count + 1))
                let logical = "\(area)/\(relative)"
                guard (try? C07Path.validateRelative(logical)) != nil else {
                    warnings.append("mailReceiptPathRejected")
                    continue
                }
                appendArtifact(
                    role: .mailReceipt, ownerID: nil, containerID: nil,
                    logicalPath: logical, sourceURL: url,
                    artifacts: &artifacts, entries: &entries, counts: &counts)
                counts.mailReceipts += 1
            }
        }
        return warnings
    }
}

// MARK: - Full owned-data restore sink

extension C07LiveRestoreSink {
    func prepareOwnedData(_ staged: C07StagedOwnedData,
                          projectMap: [UUID: UUID],
                          restoreID: UUID,
                          journalRoot: URL) async throws -> C07PreparedOwnedData {
        var mapping = C07IDMap()
        var warnings = staged.manifest.warnings
        var counts = staged.manifest.counts
        var createdWorkspaceIDs: [String] = []

        // Workspace identities. Managed projects already received a new C01
        // identity; every other row is a NEW row, never an overwrite.
        for workspace in staged.workspaces {
            switch workspace.mode {
            case .managedProject, .retainedProject:
                if let newID = projectMap[workspace.workspaceID] {
                    try mapping.insert(.workspace,
                                       old: workspace.workspaceID.uuidString,
                                       new: newID.uuidString)
                } else {
                    warnings.append("workspaceProjectSkipped:\(workspace.workspaceID.uuidString.prefix(8))")
                }
            case .privateTask, .externalRegrant:
                let newID = UUID().uuidString
                try mapping.insert(.workspace,
                                   old: workspace.workspaceID.uuidString,
                                   new: newID)
                createdWorkspaceIDs.append(newID)
            }
        }

        // Pass 1: allocate every live identity and validate reference closure
        // before any file or row is written. Evidence tables are validated
        // and retained, but their primary keys never enter a live table.
        for table in staged.tables {
            guard let policy = C07OwnedDataPolicy.policy(for: table.record.name) else {
                throw C07DataExchangeError.invalidManifest(
                    "ownedTable:\(table.record.name)")
            }
            try C07RowStream.rows(
                in: table.url, table: table.record.name
            ) { row in
                guard let primary = row[policy.primaryColumn]?.stringValue,
                      !primary.isEmpty else {
                    throw C07DataExchangeError.invalidManifest(
                        "primary:\(table.record.name)")
                }
                if policy.disposition == .live,
                   !policy.freshPrimary,
                   policy.primaryKind != .executionEvidence,
                   mapping.newID(policy.primaryKind, old: primary) == nil {
                    try mapping.insert(
                        policy.primaryKind, old: primary,
                        new: UUID().uuidString)
                }
                for (column, kind) in policy.references {
                    guard let reference = row[column]?.stringValue,
                          !reference.isEmpty else {
                        throw C07DataExchangeError.referenceMissing(
                            "\(table.record.name).\(column)")
                    }
                    if mapping.newID(kind, old: reference) == nil {
                        throw C07DataExchangeError.referenceMissing(
                            "\(table.record.name).\(column):\(reference.prefix(8))")
                    }
                }
            }
        }

        // Canvas/media identities and filesystem collision checks. The same
        // deterministic destination rules are applied again at commit.
        var artifactRoots: [String] = []
        var artifactRootSet = Set<String>()
        var attachmentPaths: [String: String] = [:]
        var environmentIDs: [UUID] = []
        var environmentIdentityMap: [String: String] = [:]
        var environmentExports: [C07LinuxEnvironmentExport] = []

        for artifact in staged.artifacts where artifact.record.role == .canvasProject {
            let data: Data
            do { data = try Data(contentsOf: artifact.url) }
            catch { throw C07DataExchangeError.storageUnavailable("canvasRead") }
            let references = try C07CanvasGraph.scan(canvasData: data)
            guard references.canvasID == artifact.record.ownerID else {
                throw C07DataExchangeError.invalidManifest("canvasOwner")
            }
            if mapping.newID(.canvas, old: references.canvasID.uuidString) == nil {
                try mapping.insert(.canvas,
                                   old: references.canvasID.uuidString,
                                   new: UUID().uuidString)
            }
            for childID in references.childProjectIDs {
                if mapping.newID(.mediaProject, old: childID.uuidString) == nil {
                    try mapping.insert(.mediaProject,
                                       old: childID.uuidString,
                                       new: UUID().uuidString)
                }
            }
        }
        for artifact in staged.artifacts where artifact.record.role == .canvasMediaProject {
            guard let oldID = artifact.record.ownerID else {
                throw C07DataExchangeError.invalidManifest("mediaOwner")
            }
            if mapping.newID(.mediaProject, old: oldID.uuidString) == nil {
                try mapping.insert(.mediaProject, old: oldID.uuidString,
                                   new: UUID().uuidString)
            }
        }

        let artifactRoot = context.artifactRoot
        let acceptedRoot = URL(fileURLWithPath: context.rootPath, isDirectory: true)
        let materialsRoot = artifactRoot.appendingPathComponent("Materials", isDirectory: true)
        let canvasesRoot = artifactRoot.appendingPathComponent("Canvases", isDirectory: true)
        let mediaProjectsRoot = artifactRoot.appendingPathComponent(
            "MediaProjects", isDirectory: true)
        let workbenchRoot = artifactRoot.appendingPathComponent(
            "WorkbenchRoot", isDirectory: true)
        let attachmentsRoot = acceptedRoot.appendingPathComponent(
            "Attachments", isDirectory: true)
        let privateTasksRoot = acceptedRoot.appendingPathComponent(
            "Workspace", isDirectory: true)
            .appendingPathComponent("PrivateTasks", isDirectory: true)
        let mailReceiptRoot = context.dataRoot.appendingPathComponent(
            "RestoredReceipts", isDirectory: true)
            .appendingPathComponent("Mail", isDirectory: true)
            .appendingPathComponent(restoreID.uuidString, isDirectory: true)
        let evidenceRoot = context.dataRoot.appendingPathComponent(
            "RestoredReceipts", isDirectory: true)
            .appendingPathComponent("Execution", isDirectory: true)
            .appendingPathComponent(restoreID.uuidString, isDirectory: true)

        func recordRoot(_ url: URL) {
            let path = url.standardizedFileURL.path
            if artifactRootSet.insert(path).inserted {
                artifactRoots.append(path)
            }
        }

        // Material names: reuse an identical existing file; otherwise use a
        // content-suffixed name and rewrite the canvas JSON reference.
        let canvasIDs = mapping.allNewIDs(.canvas)
        for canvasIDText in canvasIDs {
            guard let canvasID = UUID(uuidString: canvasIDText),
                  let projectArtifact = staged.artifacts.first(where: {
                      $0.record.role == .canvasProject
                          && $0.record.ownerID?.uuidString == mapping.oldID(
                            .canvas, new: canvasIDText)
                  }) else { continue }
            var materialMap: [String: String] = [:]
            for artifact in staged.artifacts where artifact.record.role == .canvasMaterial
                && artifact.record.containerID?.uuidString == projectArtifact.record.ownerID?.uuidString {
                let oldName = artifact.record.logicalPath
                let destination = materialsRoot.appendingPathComponent(oldName)
                if C07FileSystem.isRegularFile(destination) {
                    if let digest = try? C07Digest.file(destination),
                       digest.byteCount == artifact.record.byteCount,
                       digest.sha256 == artifact.record.sha256 {
                        materialMap[oldName] = oldName
                        continue
                    }
                    let newName = contentSuffixedName(
                        oldName, sha256: artifact.record.sha256)
                    materialMap[oldName] = newName
                    let newDestination = materialsRoot.appendingPathComponent(newName)
                    if FileManager.default.fileExists(atPath: newDestination.path) {
                        throw C07DataExchangeError.artifactCollision(newName)
                    }
                    recordRoot(newDestination)
                } else {
                    materialMap[oldName] = oldName
                    recordRoot(destination)
                }
            }
            var pathMap: [String: String] = [:]
            for artifact in staged.artifacts where artifact.record.role == .canvasMediaProject
                && artifact.record.containerID?.uuidString == projectArtifact.record.ownerID?.uuidString {
                guard let oldID = artifact.record.ownerID,
                      let newIDText = mapping.newID(.mediaProject, old: oldID.uuidString),
                      let newID = UUID(uuidString: newIDText) else { continue }
                let projectDestination = mediaProjectsRoot.appendingPathComponent(
                    "media-project-\(newID.uuidString).json")
                if FileManager.default.fileExists(atPath: projectDestination.path) {
                    throw C07DataExchangeError.artifactCollision(
                        projectDestination.lastPathComponent)
                }
                recordRoot(projectDestination)
                let oldRoot = "WorkbenchRoot/\(oldID.uuidString)"
                let newRoot = "WorkbenchRoot/\(newID.uuidString)"
                pathMap[oldRoot] = newRoot
                let mediaRoot = workbenchRoot.appendingPathComponent(
                    newID.uuidString, isDirectory: true)
                if FileManager.default.fileExists(atPath: mediaRoot.path) {
                    throw C07DataExchangeError.artifactCollision(
                        mediaRoot.lastPathComponent)
                }
                recordRoot(mediaRoot)
                for asset in staged.artifacts where asset.record.role == .canvasAsset
                    && asset.record.ownerID == oldID {
                    let relative = asset.record.logicalPath
                    let destination: URL
                    if relative.hasPrefix("WorkbenchRoot/") {
                        let rewritten = C07IDRewrite.rewritePath(
                            relative, mapping: mapping)
                        destination = artifactRoot.appendingPathComponent(rewritten)
                    } else {
                        destination = mediaRoot.appendingPathComponent(relative)
                    }
                    if FileManager.default.fileExists(atPath: destination.path) {
                        throw C07DataExchangeError.artifactCollision(
                            destination.lastPathComponent)
                    }
                    recordRoot(destination)
                }
            }
            // Orphan child asset (no child media project binding) is kept
            // under the restored canvas root instead of being dropped.
            for asset in staged.artifacts where asset.record.role == .canvasAsset {
                guard let owner = asset.record.ownerID,
                      mapping.newID(.mediaProject, old: owner.uuidString) == nil,
                      let canvasText = mapping.newID(
                        .canvas, old: owner.uuidString) else { continue }
                let destination: URL
                if asset.record.logicalPath.hasPrefix("WorkbenchRoot/") {
                    destination = artifactRoot.appendingPathComponent(
                        C07IDRewrite.rewritePath(
                            asset.record.logicalPath, mapping: mapping))
                } else {
                    destination = workbenchRoot
                        .appendingPathComponent(canvasText, isDirectory: true)
                        .appendingPathComponent(asset.record.logicalPath)
                }
                if FileManager.default.fileExists(atPath: destination.path) {
                    throw C07DataExchangeError.artifactCollision(
                        destination.lastPathComponent)
                }
                recordRoot(destination)
            }
            for artifact in staged.artifacts where artifact.record.role == .canvasNodeAsset
                && artifact.record.containerID?.uuidString == projectArtifact.record.ownerID?.uuidString {
                let rewritten = C07IDRewrite.rewritePath(
                    artifact.record.logicalPath, mapping: mapping)
                let destination = artifactRoot.appendingPathComponent(rewritten)
                if FileManager.default.fileExists(atPath: destination.path) {
                    if let digest = try? C07Digest.file(destination),
                       digest.byteCount == artifact.record.byteCount,
                       digest.sha256 == artifact.record.sha256 {
                        continue
                    }
                    throw C07DataExchangeError.artifactCollision(
                        destination.lastPathComponent)
                }
                recordRoot(destination)
            }
            _ = pathMap
            let canvasDestination = canvasesRoot.appendingPathComponent(
                "\(canvasID.uuidString).json")
            if FileManager.default.fileExists(atPath: canvasDestination.path) {
                throw C07DataExchangeError.artifactCollision(
                    canvasDestination.lastPathComponent)
            }
            recordRoot(canvasDestination)
        }

        for artifact in staged.artifacts where artifact.record.role == .attachment {
            guard let oldID = artifact.record.ownerID,
                  let newIDText = mapping.newID(.attachment, old: oldID.uuidString) else {
                throw C07DataExchangeError.referenceMissing("attachment")
            }
            let basename = safeArtifactName(
                (artifact.record.logicalPath as NSString).lastPathComponent)
            let relative = "\(newIDText)/\(basename)"
            let destination = attachmentsRoot.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: destination.path) {
                throw C07DataExchangeError.artifactCollision(relative)
            }
            attachmentPaths[oldID.uuidString] = relative
            recordRoot(destination.deletingLastPathComponent())
        }

        for artifact in staged.artifacts where artifact.record.role == .privateTaskFile {
            guard let oldConversation = artifact.record.ownerID,
                  let newConversation = mapping.newID(
                    .conversation, old: oldConversation.uuidString) else {
                throw C07DataExchangeError.referenceMissing("privateTaskOwner")
            }
            let destination = privateTasksRoot
                .appendingPathComponent(newConversation, isDirectory: true)
                .appendingPathComponent(artifact.record.logicalPath)
            if FileManager.default.fileExists(atPath: destination.path) {
                throw C07DataExchangeError.artifactCollision(
                    destination.lastPathComponent)
            }
            recordRoot(destination)
        }
        if staged.artifacts.contains(where: { $0.record.role == .mailReceipt }) {
            if FileManager.default.fileExists(atPath: mailReceiptRoot.path) {
                throw C07DataExchangeError.artifactCollision("mailReceiptRoot")
            }
            recordRoot(mailReceiptRoot)
            counts.mailReceipts = staged.artifacts.filter {
                $0.record.role == .mailReceipt
            }.count
        }
        if staged.tables.contains(where: {
            C07OwnedDataPolicy.policy(for: $0.record.name)?.disposition
                == .evidenceArchive
        }) {
            if FileManager.default.fileExists(atPath: evidenceRoot.path) {
                throw C07DataExchangeError.artifactCollision("evidenceRoot")
            }
            recordRoot(evidenceRoot)
        }

        // Linux environments: C01 allocates identities WITHOUT mutating, so
        // the durable plan can name them before import.
        let environmentArtifacts = staged.artifacts.filter {
            $0.record.role == .environmentCheckpoint
        }
        if !environmentArtifacts.isEmpty {
            guard let port = C07LinuxCheckpointPortRegistry.installed,
                  port.portVersion >= C07LinuxCheckpointWire.version else {
                throw C07DataExchangeError.unsupportedFeature(
                    "linuxCheckpointPort")
            }
            var grouped: [UUID: (descriptor: C07LinuxEnvironmentDescriptor?,
                                 files: [C07LinuxCheckpointFileSource])] = [:]
            for artifact in environmentArtifacts {
                guard let owner = artifact.record.ownerID else { continue }
                var entry = grouped[owner] ?? (nil, [])
                if artifact.record.logicalPath == "metadata.json" {
                    let data: Data
                    do { data = try Data(contentsOf: artifact.url) }
                    catch { throw C07DataExchangeError.storageUnavailable(
                        "environmentMetadata") }
                    let decoder = JSONDecoder()
                    entry.descriptor = try? decoder.decode(
                        C07LinuxEnvironmentDescriptor.self, from: data)
                } else {
                    entry.files.append(C07LinuxCheckpointFileSource(
                        relativePath: artifact.record.logicalPath,
                        url: artifact.url,
                        byteCount: artifact.record.byteCount,
                        sha256: artifact.record.sha256))
                }
                grouped[owner] = entry
            }
            for (owner, entry) in grouped.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                guard let descriptor = entry.descriptor,
                      descriptor.environmentID == owner else {
                    throw C07DataExchangeError.invalidManifest(
                        "environmentDescriptor")
                }
                environmentExports.append(C07LinuxEnvironmentExport(
                    environmentID: owner, name: descriptor.name,
                    runtimeKind: descriptor.runtimeKind,
                    checkpointFormat: descriptor.checkpointFormat,
                    metadataJSON: descriptor.metadataJSON,
                    files: entry.files))
            }
            let identityMap = try await port.planEnvironmentIdentities(
                environmentExports)
            guard identityMap.count == environmentExports.count else {
                throw C07DataExchangeError.unsupportedFeature(
                    "linuxCheckpointIdentities")
            }
            for export in environmentExports {
                guard let newText = identityMap[export.environmentID.uuidString],
                      let newID = UUID(uuidString: newText) else {
                    throw C07DataExchangeError.unsupportedFeature(
                        "linuxCheckpointIdentity")
                }
                environmentIDs.append(newID)
                environmentIdentityMap[export.environmentID.uuidString] = newText
            }
        }

        // Exact live-id collision check for every root identity.
        try await verifyNoRootCollisions(mapping: mapping)

        let plan = C07OwnedDataRestorePlanFile(
            restoreID: restoreID,
            idMap: mapping,
            artifactRoots: artifactRoots,
            attachmentPaths: attachmentPaths,
            workspaceIDs: createdWorkspaceIDs,
            environmentIDs: environmentIDs.isEmpty ? nil : environmentIDs,
            environmentIdentityMap: environmentIdentityMap.isEmpty
                ? nil : environmentIdentityMap,
            counts: counts,
            warnings: warnings)
        let written = try C07DurablePlan.write(plan, root: journalRoot)
        return C07PreparedOwnedData(
            plan: plan, planURL: written.url, planSHA256: written.sha256,
            staged: staged)
    }

    private func verifyNoRootCollisions(mapping: C07IDMap) async throws {
        let checks: [(String, String, C07IDKind)] = [
            ("conversations", "id", .conversation),
            ("workspaces", "id", .workspace),
            ("task_schedules", "id", .schedule),
            ("providers", "id", .provider),
            ("models", "id", .model),
        ]
        try await context.database.reader { db in
            for (table, column, kind) in checks {
                let ids = mapping.allNewIDs(kind)
                for chunk in ids.chunked(max: 400) {
                    let placeholders = Array(repeating: "?", count: chunk.count)
                        .joined(separator: ",")
                    let sql = "SELECT 1 FROM \"\(table)\" WHERE \"\(column)\" IN (\(placeholders)) LIMIT 1"
                    let arguments = StatementArguments(chunk.map { $0 as String? })
                    if try Bool.fetchOne(db, sql: sql, arguments: arguments) == true {
                        throw C07DataExchangeError.duplicateIdentity(kind.rawValue)
                    }
                }
            }
        }
    }
}

// MARK: - Artifact commit

extension C07LiveRestoreSink {
    func commitArtifacts(_ prepared: C07PreparedOwnedData) async throws
        -> C07ArtifactCommitReceipt {
        let plan = prepared.plan
        let staged = prepared.staged
        let artifactRoot = context.artifactRoot
        let acceptedRoot = URL(fileURLWithPath: context.rootPath, isDirectory: true)
        let materialsRoot = artifactRoot.appendingPathComponent("Materials", isDirectory: true)
        let canvasesRoot = artifactRoot.appendingPathComponent("Canvases", isDirectory: true)
        let mediaProjectsRoot = artifactRoot.appendingPathComponent(
            "MediaProjects", isDirectory: true)
        let workbenchRoot = artifactRoot.appendingPathComponent(
            "WorkbenchRoot", isDirectory: true)
        let attachmentsRoot = acceptedRoot.appendingPathComponent(
            "Attachments", isDirectory: true)
        let privateTasksRoot = acceptedRoot.appendingPathComponent(
            "Workspace", isDirectory: true)
            .appendingPathComponent("PrivateTasks", isDirectory: true)
        let mailReceiptRoot = context.dataRoot.appendingPathComponent(
            "RestoredReceipts", isDirectory: true)
            .appendingPathComponent("Mail", isDirectory: true)
            .appendingPathComponent(plan.restoreID.uuidString, isDirectory: true)
        let evidenceRoot = context.dataRoot.appendingPathComponent(
            "RestoredReceipts", isDirectory: true)
            .appendingPathComponent("Execution", isDirectory: true)
            .appendingPathComponent(plan.restoreID.uuidString, isDirectory: true)

        var createdRoots: [String] = []
        var warnings = plan.warnings
        var canvasProjects = 0
        var mediaProjects = 0
        var mediaAssets = 0
        var privateTaskFiles = 0
        var mailReceipts = 0

        func noteCreated(_ url: URL) {
            let path = url.standardizedFileURL.path
            if !createdRoots.contains(path) { createdRoots.append(path) }
        }

        func copyFile(_ source: URL, to destination: URL,
                      record: C07ArtifactRecord) throws -> Bool {
            if FileManager.default.fileExists(atPath: destination.path) {
                if let digest = try? C07Digest.file(destination),
                   digest.byteCount == record.byteCount,
                   digest.sha256 == record.sha256 {
                    return false
                }
                throw C07DataExchangeError.artifactCollision(
                    destination.lastPathComponent)
            }
            try ensureOwnedDirectory(destination.deletingLastPathComponent())
            try C07POSIX.writeExclusive(
                source: source, destination: destination,
                expectedBytes: record.byteCount,
                expectedSHA256: record.sha256,
                mode: record.mode ?? 0o600)
            noteCreated(destination)
            return true
        }

        func materialMap(for canvasOwner: UUID) -> [String: String] {
            var map: [String: String] = [:]
            for artifact in staged.artifacts where
                artifact.record.role == .canvasMaterial
                    && artifact.record.containerID == canvasOwner {
                let oldName = artifact.record.logicalPath
                let existing = materialsRoot.appendingPathComponent(oldName)
                if C07FileSystem.isRegularFile(existing),
                   let digest = try? C07Digest.file(existing),
                   digest.byteCount == artifact.record.byteCount,
                   digest.sha256 == artifact.record.sha256 {
                    map[oldName] = oldName
                } else if C07FileSystem.isRegularFile(existing) {
                    map[oldName] = contentSuffixedName(
                        oldName, sha256: artifact.record.sha256)
                } else {
                    map[oldName] = oldName
                }
            }
            return map
        }

        func pathMap(for canvasOwner: UUID) -> [String: String] {
            var map: [String: String] = [:]
            for artifact in staged.artifacts where
                artifact.record.role == .canvasMediaProject
                    && artifact.record.containerID == canvasOwner {
                guard let oldID = artifact.record.ownerID,
                      let newText = plan.idMap.newID(
                        .mediaProject, old: oldID.uuidString) else { continue }
                let oldRoot = "WorkbenchRoot/\(oldID.uuidString)"
                let newRoot = "WorkbenchRoot/\(newText)"
                map[oldRoot] = newRoot
                for asset in staged.artifacts where
                    asset.record.role == .canvasAsset
                        && asset.record.ownerID == oldID
                        && asset.record.logicalPath.hasPrefix("WorkbenchRoot/") {
                    map[asset.record.logicalPath] = C07IDRewrite.rewritePath(
                        asset.record.logicalPath, mapping: plan.idMap)
                }
            }
            return map
        }

        // Canvas documents. Every identity is remapped; no old UUID remains
        // in an ownership field.
        for artifact in staged.artifacts where artifact.record.role == .canvasProject {
            guard let oldOwner = artifact.record.ownerID,
                  let newText = plan.idMap.newID(
                    .canvas, old: oldOwner.uuidString),
                  let newID = UUID(uuidString: newText) else {
                throw C07DataExchangeError.referenceMissing("canvas")
            }
            let data: Data
            do { data = try Data(contentsOf: artifact.url) }
            catch { throw C07DataExchangeError.storageUnavailable("canvasRead") }
            let rewritten = try C07CanvasGraph.rewriteJSON(
                data: data, mapping: plan.idMap,
                materialMap: materialMap(for: oldOwner),
                pathMap: pathMap(for: oldOwner),
                taskWorkspacePath: nil)
            let destination = canvasesRoot.appendingPathComponent(
                "\(newID.uuidString).json")
            try ensureOwnedDirectory(canvasesRoot)
            try writeExclusiveData(rewritten, destination: destination)
            noteCreated(destination)
            canvasProjects += 1
        }

        // Child media projects and their asset bytes.
        for artifact in staged.artifacts where artifact.record.role == .canvasMediaProject {
            guard let oldID = artifact.record.ownerID,
                  let newText = plan.idMap.newID(
                    .mediaProject, old: oldID.uuidString),
                  let newID = UUID(uuidString: newText) else {
                throw C07DataExchangeError.referenceMissing("mediaProject")
            }
            let mediaRoot = workbenchRoot.appendingPathComponent(
                newID.uuidString, isDirectory: true)
            let data: Data
            do { data = try Data(contentsOf: artifact.url) }
            catch { throw C07DataExchangeError.storageUnavailable("mediaRead") }
            var map: [String: String] = [
                "WorkbenchRoot/\(oldID.uuidString)":
                    "WorkbenchRoot/\(newID.uuidString)",
            ]
            for asset in staged.artifacts where
                asset.record.role == .canvasAsset && asset.record.ownerID == oldID {
                if asset.record.logicalPath.hasPrefix("WorkbenchRoot/") {
                    map[asset.record.logicalPath] = C07IDRewrite.rewritePath(
                        asset.record.logicalPath, mapping: plan.idMap)
                }
            }
            let rewritten = try C07CanvasGraph.rewriteJSON(
                data: data, mapping: plan.idMap, materialMap: [:],
                pathMap: map, taskWorkspacePath: mediaRoot.path)
            let destination = mediaProjectsRoot.appendingPathComponent(
                "media-project-\(newID.uuidString).json")
            try ensureOwnedDirectory(mediaProjectsRoot)
            try writeExclusiveData(rewritten, destination: destination)
            noteCreated(destination)
            mediaProjects += 1
        }

        for artifact in staged.artifacts where artifact.record.role == .canvasMaterial {
            guard let canvasOwner = artifact.record.containerID else { continue }
            let map = materialMap(for: canvasOwner)
            let newName = map[artifact.record.logicalPath] ?? artifact.record.logicalPath
            let destination = materialsRoot.appendingPathComponent(newName)
            _ = try copyFile(artifact.url, to: destination, record: artifact.record)
        }

        for artifact in staged.artifacts where artifact.record.role == .canvasAsset {
            guard let oldID = artifact.record.ownerID,
                  let newText = plan.idMap.newID(
                    .mediaProject, old: oldID.uuidString)
                    ?? plan.idMap.newID(.canvas, old: oldID.uuidString) else {
                throw C07DataExchangeError.referenceMissing("mediaAsset")
            }
            let destination: URL
            if artifact.record.logicalPath.hasPrefix("WorkbenchRoot/") {
                let rewritten = C07IDRewrite.rewritePath(
                    artifact.record.logicalPath, mapping: plan.idMap)
                destination = artifactRoot.appendingPathComponent(rewritten)
            } else {
                destination = workbenchRoot
                    .appendingPathComponent(newText, isDirectory: true)
                    .appendingPathComponent(artifact.record.logicalPath)
            }
            _ = try copyFile(artifact.url, to: destination, record: artifact.record)
            mediaAssets += 1
        }

        for artifact in staged.artifacts where artifact.record.role == .canvasNodeAsset {
            let rewritten = C07IDRewrite.rewritePath(
                artifact.record.logicalPath, mapping: plan.idMap)
            let destination = artifactRoot.appendingPathComponent(rewritten)
            _ = try copyFile(artifact.url, to: destination, record: artifact.record)
        }

        for artifact in staged.artifacts where artifact.record.role == .attachment {
            guard let oldID = artifact.record.ownerID,
                  let relative = plan.attachmentPaths[oldID.uuidString] else {
                throw C07DataExchangeError.referenceMissing("attachmentPath")
            }
            let destination = attachmentsRoot.appendingPathComponent(relative)
            _ = try copyFile(artifact.url, to: destination, record: artifact.record)
        }

        for artifact in staged.artifacts where artifact.record.role == .privateTaskFile {
            guard let oldConversation = artifact.record.ownerID,
                  let newConversation = plan.idMap.newID(
                    .conversation, old: oldConversation.uuidString) else {
                throw C07DataExchangeError.referenceMissing("privateTaskOwner")
            }
            let destination = privateTasksRoot
                .appendingPathComponent(newConversation, isDirectory: true)
                .appendingPathComponent(artifact.record.logicalPath)
            _ = try copyFile(artifact.url, to: destination, record: artifact.record)
            privateTaskFiles += 1
        }

        for artifact in staged.artifacts where artifact.record.role == .mailReceipt {
            let destination = mailReceiptRoot
                .appendingPathComponent(artifact.record.logicalPath)
            _ = try copyFile(artifact.url, to: destination, record: artifact.record)
            mailReceipts += 1
        }

        // Execution-target/pin/receipt evidence is retained as a read-only
        // archive. It is NEVER inserted into the live authorization tables.
        var evidenceRows = 0
        for table in staged.tables {
            guard let policy = C07OwnedDataPolicy.policy(for: table.record.name),
                  policy.disposition == .evidenceArchive else { continue }
            try ensureOwnedDirectory(evidenceRoot)
            let destination = evidenceRoot.appendingPathComponent(
                "\(table.record.name).jsonl")
            let writer = try C07RowStream.makeWriter(at: destination)
            try C07RowStream.rows(in: table.url, table: table.record.name) { row in
                var archived = row
                for (column, value) in row {
                    if policy.jsonIDColumns.contains(column) {
                        archived[column] = try C07IDRewrite.rewriteJSONColumn(
                            value, mapping: plan.idMap)
                    } else if value.kind == .text, let text = value.text {
                        archived[column] = .string(
                            C07IDRewrite.rewrite(text, mapping: plan.idMap))
                    }
                }
                try writer.append(archived)
                evidenceRows += 1
            }
            try writer.finish()
            noteCreated(destination)
        }

        // Linux environments are imported by the C01-owned port with the
        // identities already journaled in the plan.
        let environmentArtifacts = staged.artifacts.filter {
            $0.record.role == .environmentCheckpoint
        }
        if !environmentArtifacts.isEmpty {
            guard let port = C07LinuxCheckpointPortRegistry.installed,
                  port.portVersion >= C07LinuxCheckpointWire.version,
                  let identityMap = plan.environmentIdentityMap else {
                throw C07DataExchangeError.unsupportedFeature(
                    "linuxCheckpointPort")
            }
            var grouped: [UUID: (descriptor: C07LinuxEnvironmentDescriptor?,
                                 files: [C07LinuxCheckpointFileSource])] = [:]
            for artifact in environmentArtifacts {
                guard let owner = artifact.record.ownerID else { continue }
                var entry = grouped[owner] ?? (nil, [])
                if artifact.record.logicalPath == "metadata.json" {
                    let data: Data
                    do { data = try Data(contentsOf: artifact.url) }
                    catch { throw C07DataExchangeError.storageUnavailable(
                        "environmentMetadata") }
                    entry.descriptor = try? JSONDecoder().decode(
                        C07LinuxEnvironmentDescriptor.self, from: data)
                } else {
                    entry.files.append(C07LinuxCheckpointFileSource(
                        relativePath: artifact.record.logicalPath,
                        url: artifact.url,
                        byteCount: artifact.record.byteCount,
                        sha256: artifact.record.sha256))
                }
                grouped[owner] = entry
            }
            var exports: [C07LinuxEnvironmentExport] = []
            var stagedFiles: [String: URL] = [:]
            for (owner, entry) in grouped.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                guard let descriptor = entry.descriptor,
                      descriptor.environmentID == owner else {
                    throw C07DataExchangeError.invalidManifest(
                        "environmentDescriptor")
                }
                exports.append(C07LinuxEnvironmentExport(
                    environmentID: owner, name: descriptor.name,
                    runtimeKind: descriptor.runtimeKind,
                    checkpointFormat: descriptor.checkpointFormat,
                    metadataJSON: descriptor.metadataJSON,
                    files: entry.files))
                for file in entry.files {
                    stagedFiles["\(owner.uuidString)/\(file.relativePath)"] = file.url
                }
            }
            try await port.importEnvironments(
                exports, stagedFiles: stagedFiles, identityMap: identityMap)
        }

        return C07ArtifactCommitReceipt(
            createdRoots: createdRoots,
            attachmentPaths: plan.attachmentPaths,
            canvasProjects: canvasProjects,
            mediaProjects: mediaProjects,
            mediaAssets: mediaAssets,
            privateTaskFiles: privateTaskFiles,
            mailReceipts: mailReceipts,
            evidenceRows: evidenceRows,
            warnings: warnings)
    }

    private func ensureOwnedDirectory(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            let values = try? url.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true,
                  values?.isSymbolicLink != true else {
                throw C07DataExchangeError.artifactCollision(
                    url.lastPathComponent)
            }
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            throw C07DataExchangeError.storageUnavailable("mkdir")
        }
    }

    private func writeExclusiveData(_ data: Data, destination: URL,
                                    mode: Int = 0o600) throws {
        let path = destination.path
        let fd = path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                 mode_t(S_IRUSR | S_IWUSR))
        }
        guard fd >= 0 else {
            throw C07DataExchangeError.artifactCollision(
                destination.lastPathComponent)
        }
        if fchmod(fd, mode_t(mode & 0o777)) != 0 {
            close(fd)
            C07FileSystem.removeIfPresent(destination)
            throw C07DataExchangeError.storageUnavailable("mode")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            C07FileSystem.removeIfPresent(destination)
            throw C07DataExchangeError.storageUnavailable("write")
        }
    }

    private func safeArtifactName(_ raw: String) -> String {
        var value = raw.precomposedStringWithCanonicalMapping
        value = value.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
        value = value.filter { character in
            character.unicodeScalars.allSatisfy {
                $0.value >= 0x20 && $0.value != 0x7F
            }
        }
        if value.isEmpty { value = "attachment" }
        if value.count > 200 { value = String(value.suffix(200)) }
        return value
    }

    private func contentSuffixedName(_ name: String, sha256: String) -> String {
        let url = URL(fileURLWithPath: name)
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        let suffix = String(sha256.prefix(8))
        return ext.isEmpty ? "\(base)-\(suffix)" : "\(base)-\(suffix).\(ext)"
    }
}

// MARK: - Database graph commit

extension C07LiveRestoreSink {
    func commitOwnedData(_ prepared: C07PreparedOwnedData,
                         artifacts: C07ArtifactCommitReceipt) async throws
        -> C07OwnedDataCommitReceipt {
        let plan = prepared.plan
        let staged = prepared.staged
        let now = c07DateString(Date())

        let outcome: (C07OwnedDataCommitReceipt, [String])
        outcome = try await context.database.writer {
            db -> (C07OwnedDataCommitReceipt, [String]) in
            var warnings = plan.warnings
            var receipt = C07OwnedDataCommitReceipt()
            // 1. New workspace rows for private-task and external roots.
            //    Managed/retained projects already exist from the C01 restore.
            for descriptor in staged.workspaces {
                switch descriptor.mode {
                case .managedProject, .retainedProject:
                    if let mapped = plan.idMap.newID(
                        .workspace, old: descriptor.workspaceID.uuidString) {
                        _ = mapped
                    }
                case .privateTask, .externalRegrant:
                    guard let newText = plan.idMap.newID(
                        .workspace, old: descriptor.workspaceID.uuidString),
                          let newID = UUID(uuidString: newText) else {
                        throw C07DataExchangeError.referenceMissing(
                            "workspaceIdentity")
                    }
                    let isPrivate = descriptor.mode == .privateTask
                    var internalPath: String?
                    var kind = "project"
                    if isPrivate {
                        guard let oldConversationText =
                                descriptor.conversationIDs.first?.uuidString,
                              let newConversation = plan.idMap.newID(
                                .conversation, old: oldConversationText) else {
                            warnings.append("privateTaskConversationMissing")
                            continue
                        }
                        kind = "privateTask"
                        internalPath = "PrivateTasks/\(newConversation)"
                    }
                    try db.execute(
                        sql: """
                            INSERT INTO workspaces (
                                id, name, root_bookmark, last_opened_at,
                                active_target_kind, active_target_host_id,
                                inspector_state_json, instructions_rel_path,
                                created_at, updated_at, kind,
                                internal_relative_path
                            ) VALUES (?, ?, ?, NULL, 'local', NULL, '{}',
                                      NULL, ?, ?, ?, ?)
                            """,
                        arguments: [
                            newID.uuidString, descriptor.name, Data(),
                            c07DateString(descriptor.createdAt),
                            c07DateString(descriptor.updatedAt),
                            kind, internalPath,
                        ])
                    receipt.workspaces += 1
                }
            }

            // 2. Live rows in dependency order. Evidence tables are skipped
            //    here: they were archived read-only by commitArtifacts.
            for table in staged.tables {
                guard let policy = C07OwnedDataPolicy.policy(for: table.record.name),
                      policy.disposition == .live else { continue }
                let schemaColumns = Set(
                    try db.columns(in: table.record.name).map(\.name))
                guard policy.requiredColumns.isSubset(of: schemaColumns) else {
                    throw C07DataExchangeError.schemaMismatch(
                        staged.manifest.sourceAppSchemaVersion)
                }
                var statements: [String: Statement] = [:]
                var rowsInserted = 0
                try C07RowStream.rows(
                    in: table.url, table: table.record.name
                ) { row in
                    if Task.isCancelled { throw C07DataExchangeError.cancelled }
                    let oldPrimary = row[policy.primaryColumn]?.stringValue ?? ""
                    guard !oldPrimary.isEmpty else {
                        throw C07DataExchangeError.invalidManifest(
                            "primary:\(table.record.name)")
                    }
                    var values = C07OwnedDataPolicy.restoredRow(
                        table: table.record.name, row: row)
                    // Primary identity.
                    if policy.freshPrimary {
                        values[policy.primaryColumn] = .string(
                            C07IDDerivation.fresh(
                                restoreID: plan.restoreID,
                                table: table.record.name,
                                old: oldPrimary))
                    } else if let mapped = plan.idMap.newID(
                        policy.primaryKind, old: oldPrimary) {
                        values[policy.primaryColumn] = .string(mapped)
                    } else if policy.primaryKind != .executionEvidence {
                        throw C07DataExchangeError.referenceMissing(
                            "\(table.record.name).\(policy.primaryColumn)")
                    }
                    // Required and optional references.
                    for (column, kind) in policy.references {
                        guard let old = row[column]?.stringValue,
                              !old.isEmpty else {
                            throw C07DataExchangeError.referenceMissing(
                                "\(table.record.name).\(column)")
                        }
                        guard let mapped = plan.idMap.newID(kind, old: old) else {
                            throw C07DataExchangeError.referenceMissing(
                                "\(table.record.name).\(column)")
                        }
                        values[column] = .string(mapped)
                    }
                    for (column, kind) in policy.optionalReferences {
                        if let old = row[column]?.stringValue, !old.isEmpty {
                            if let mapped = plan.idMap.newID(kind, old: old) {
                                values[column] = .string(mapped)
                            } else {
                                values[column] = .null
                            }
                        } else {
                            values[column] = .null
                        }
                    }
                    for column in policy.jsonIDColumns {
                        if let value = values[column] {
                            values[column] = try C07IDRewrite.rewriteJSONColumn(
                                value, mapping: plan.idMap)
                        }
                    }
                    // Attachment bytes become an app-private new path. No
                    // bookmark/token is transplanted.
                    if table.record.name == "attachments" {
                        let originalStorage = row["storage"]?.stringValue ?? "none"
                        if originalStorage == "applicationSupport" {
                            if let relative = plan.attachmentPaths[oldPrimary] {
                                values["storage"] = .string("applicationSupport")
                                values["relative_path"] = .string(relative)
                            } else {
                                values["storage"] = .string("none")
                                values["relative_path"] = .null
                                values["byte_count"] = .int(0)
                                values["sha256"] = .string("")
                                warnings.append(
                                    "attachmentBytesUnavailable:\(oldPrimary.prefix(8))")
                            }
                        } else {
                            values["storage"] = .string("none")
                            values["relative_path"] = .null
                        }
                        values["url_bookmark"] = .null
                    }
                    // Drop columns not present in the current schema (older
                    // archive on a narrowed schema); required columns were
                    // checked above.
                    let columns = values.keys.filter {
                        schemaColumns.contains($0) && c07SafeIdentifier($0)
                    }.sorted()
                    guard !columns.isEmpty else {
                        throw C07DataExchangeError.schemaMismatch(
                            staged.manifest.sourceAppSchemaVersion)
                    }
                    let key = columns.joined(separator: ",")
                    let statement: Statement
                    if let cached = statements[key] {
                        statement = cached
                    } else {
                        let placeholders = Array(
                            repeating: "?", count: columns.count
                        ).joined(separator: ",")
                        let quoted = columns.map { "\"\($0)\"" }
                            .joined(separator: ",")
                        statement = try db.cachedStatement(
                            sql: "INSERT INTO \"\(table.record.name)\" (\(quoted)) VALUES (\(placeholders))")
                        statements[key] = statement
                    }
                    let arguments = StatementArguments(columns.map {
                        c07DatabaseValue(values[$0] ?? .null)
                    })
                    try statement.execute(arguments: arguments)
                    rowsInserted += 1
                }
                updateReceipt(table: table.record.name, rows: rowsInserted,
                              receipt: &receipt)
            }

            // 3. Workspace links. Ownership is the canonical relation; the
            //    legacy workspace_conversations row is preserved as well.
            for descriptor in staged.workspaces {
                guard let workspaceID = plan.idMap.newID(
                    .workspace, old: descriptor.workspaceID.uuidString) else {
                    continue
                }
                let linkedConversations = descriptor.mode == .privateTask
                    ? Array(descriptor.conversationIDs.prefix(1))
                    : descriptor.conversationIDs
                for conversation in linkedConversations {
                    guard let newConversation = plan.idMap.newID(
                        .conversation, old: conversation.uuidString) else {
                        continue
                    }
                    try db.execute(
                        sql: """
                            INSERT OR IGNORE INTO workspace_conversations
                                (workspace_id, conversation_id, created_at)
                            VALUES (?, ?, ?)
                            """,
                        arguments: [workspaceID, newConversation, now])
                    if descriptor.mode == .privateTask
                        || descriptor.mode == .managedProject
                        || descriptor.mode == .retainedProject {
                        try db.execute(
                            sql: """
                                INSERT OR IGNORE INTO
                                    conversation_workspace_ownership
                                    (conversation_id, workspace_id, assigned_at)
                                VALUES (?, ?, ?)
                                """,
                            arguments: [newConversation, workspaceID, now])
                    }
                }
            }
            if receipt.conversations > 0 {
                // Restored tasks intentionally have no live target row. The
                // user must choose/confirm a target before the first
                // executable tool; a historical pin is never authorization.
                warnings.append("restoredTasksRequireTargetSelection")
            }
            return (receipt, warnings)
        }
        var receipt = outcome.0
        receipt.warnings = outcome.1
        receipt.evidenceRows = artifacts.evidenceRows
        return receipt
    }

    private func updateReceipt(table: String, rows: Int,
                               receipt: inout C07OwnedDataCommitReceipt) {
        switch table {
        case "conversations": receipt.conversations = rows
        case "messages": receipt.messages = rows
        case "runs": receipt.runs = rows
        case "tool_calls": receipt.toolCalls = rows
        case "attachments": receipt.attachments = rows
        case "task_schedules": receipt.schedules = rows
        case "providers": receipt.providers = rows
        case "models": receipt.models = rows
        default: break
        }
    }

    // MARK: Rollback

    func rollbackOwnedData(planURL: URL, planSHA256: String) async throws {
        let data: Data
        do { data = try Data(contentsOf: planURL) }
        catch { throw C07DataExchangeError.rollbackFailed("planMissing") }
        guard C07Digest.sha256(data) == planSHA256 else {
            throw C07DataExchangeError.rollbackFailed("planDigest")
        }
        let plan: C07OwnedDataRestorePlanFile
        do { plan = try C07OwnedDataRestorePlanFile.decode(data) }
        catch { throw C07DataExchangeError.rollbackFailed("planDecode") }

        let map = plan.idMap
        let conversations = map.allNewIDs(.conversation)
        let runs = map.allNewIDs(.run)
        let workspaces = map.allNewIDs(.workspace)
        let schedules = map.allNewIDs(.schedule)
        let occurrences = map.allNewIDs(.occurrence)
        let childRuns = map.allNewIDs(.childRun)
        let providers = map.allNewIDs(.provider)
        let models = map.allNewIDs(.model)

        try await context.database.writer { db in
            for chunk in conversations.chunked(max: 400) {
                try c07DeleteWhereIn(db, table: "workspace_conversations",
                                     column: "conversation_id", values: chunk)
                try c07DeleteWhereIn(db, table: "conversation_workspace_ownership",
                                     column: "conversation_id", values: chunk)
                try c07DeleteWhereIn(db, table: "task_schedule_occurrences",
                                     column: "conversation_id", values: chunk)
                try c07DeleteWhereIn(db, table: "child_runs",
                                     column: "conversation_id", values: chunk)
                try c07DeleteWhereIn(db, table: "conversations",
                                     column: "id", values: chunk)
            }
            for chunk in runs.chunked(max: 400) {
                try c07DeleteWhereIn(db, table: "run_relations",
                                     column: "parent_run_id", values: chunk)
                try c07DeleteWhereIn(db, table: "run_relations",
                                     column: "child_run_id", values: chunk)
                try c07DeleteWhereIn(db, table: "task_schedule_occurrences",
                                     column: "run_id", values: chunk)
                try c07DeleteWhereIn(db, table: "child_runs",
                                     column: "root_run_id", values: chunk)
                try c07DeleteWhereIn(db, table: "child_runs",
                                     column: "parent_run_id", values: chunk)
                try c07DeleteWhereIn(db, table: "runs", column: "id",
                                     values: chunk)
            }
            for chunk in childRuns.chunked(max: 400) {
                try c07DeleteWhereIn(db, table: "child_run_entries",
                                     column: "child_run_id", values: chunk)
                try c07DeleteWhereIn(db, table: "child_runs", column: "id",
                                     values: chunk)
            }
            for chunk in occurrences.chunked(max: 400) {
                try c07DeleteWhereIn(db, table: "task_schedule_occurrences",
                                     column: "id", values: chunk)
            }
            for chunk in schedules.chunked(max: 400) {
                try c07DeleteWhereIn(db, table: "task_schedule_occurrences",
                                     column: "schedule_id", values: chunk)
                try c07DeleteWhereIn(db, table: "task_schedules", column: "id",
                                     values: chunk)
            }
            for chunk in workspaces.chunked(max: 400) {
                try c07DeleteWhereIn(db, table: "workspace_conversations",
                                     column: "workspace_id", values: chunk)
                try c07DeleteWhereIn(db, table: "conversation_workspace_ownership",
                                     column: "workspace_id", values: chunk)
                try c07DeleteWhereIn(db, table: "workspaces", column: "id",
                                     values: chunk)
            }
            for chunk in providers.chunked(max: 400) {
                try c07DeleteWhereIn(db, table: "models", column: "provider_id",
                                     values: chunk)
                try c07DeleteWhereIn(db, table: "providers", column: "id",
                                     values: chunk)
            }
            for chunk in models.chunked(max: 400) {
                try c07DeleteWhereIn(db, table: "models", column: "id",
                                     values: chunk)
            }
        }

        // Exact artifact roots only. Each path must sit under one of the
        // app-private roots that this restore may create.
        let allowed = [
            context.artifactRoot.appendingPathComponent("Canvases").path,
            context.artifactRoot.appendingPathComponent("Materials").path,
            context.artifactRoot.appendingPathComponent("MediaProjects").path,
            context.artifactRoot.appendingPathComponent("WorkbenchRoot").path,
            URL(fileURLWithPath: context.rootPath, isDirectory: true)
                .appendingPathComponent("Attachments").path,
            URL(fileURLWithPath: context.rootPath, isDirectory: true)
                .appendingPathComponent("Workspace")
                .appendingPathComponent("PrivateTasks").path,
            context.dataRoot.appendingPathComponent("RestoredReceipts").path,
        ]
        for raw in plan.artifactRoots {
            let path = URL(fileURLWithPath: raw).standardizedFileURL.path
            guard allowed.contains(where: { path.hasPrefix($0 + "/") }) else {
                throw C07DataExchangeError.rollbackFailed("artifactRoot")
            }
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let values = try? URL(fileURLWithPath: path)
                .resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values?.isSymbolicLink != true else {
                throw C07DataExchangeError.rollbackFailed("artifactSymlink")
            }
            do { try FileManager.default.removeItem(atPath: path) }
            catch { throw C07DataExchangeError.rollbackFailed("artifactRemove") }
        }

        if let environmentIDs = plan.environmentIDs, !environmentIDs.isEmpty {
            guard let port = C07LinuxCheckpointPortRegistry.installed,
                  port.portVersion >= C07LinuxCheckpointWire.version else {
                throw C07DataExchangeError.rollbackFailed("environmentPort")
            }
            try await port.rollbackEnvironments(ids: environmentIDs)
        }
    }
}

// MARK: - Small helpers

func c07DatabaseValue(_ value: C07DBValue) -> DatabaseValue {
    switch value.kind {
    case .null: return .null
    case .integer: return (value.integer ?? 0).databaseValue
    case .real: return (value.real ?? 0).databaseValue
    case .text: return (value.text ?? "").databaseValue
    case .blob: return (value.blob ?? Data()).databaseValue
    }
}

func c07SafeIdentifier(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 128 else { return false }
    return value.unicodeScalars.allSatisfy {
        ($0.value >= 0x30 && $0.value <= 0x39)
            || ($0.value >= 0x41 && $0.value <= 0x5A)
            || ($0.value >= 0x61 && $0.value <= 0x7A)
            || $0.value == 0x5F
    }
}

func c07DeleteWhereIn(_ db: Database, table: String, column: String,
                      values: [String]) throws {
    guard !values.isEmpty else { return }
    let placeholders = Array(repeating: "?", count: values.count)
        .joined(separator: ",")
    try db.execute(
        sql: "DELETE FROM \"\(table)\" WHERE \"\(column)\" IN (\(placeholders))",
        arguments: StatementArguments(values.map { $0 as String? }))
}

func c07SafeArtifactName(_ raw: String) -> String {
    var value = raw.precomposedStringWithCanonicalMapping
    value = value.replacingOccurrences(of: "/", with: "-")
        .replacingOccurrences(of: "\\", with: "-")
    value = value.filter { character in
        character.unicodeScalars.allSatisfy {
            $0.value >= 0x20 && $0.value != 0x7F
        }
    }
    if value.isEmpty { value = "document" }
    if value.count > 200 { value = String(value.suffix(200)) }
    return value
}

func c07DateString(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

extension Array {
    func chunked(max: Int) -> [[Element]] {
        guard max > 0, !isEmpty else { return [] }
        var result: [[Element]] = []
        var index = startIndex
        while index < endIndex {
            let end = self.index(index, offsetBy: max, limitedBy: endIndex) ?? endIndex
            result.append(Array(self[index..<end]))
            index = end
        }
        return result
    }
}

// MARK: - Document package jobs (Canvas / DOCX / PDF)

extension C07DataExchangeDomain {
    func startCanvasExport(context: C07DataExchangeContext,
                           canvasID: UUID) -> UUID {
        let id = UUID()
        let work = context.workRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        let destination = context.exportsRoot.appendingPathComponent(
            "\(id.uuidString).\(C07DocumentPackageLimits.canvasExtension)")
        jobs[id] = Job(id: id, kind: "canvasExport", phase: .building)
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                try C07FileSystem.ensureDirectory(work)
                let source = try C07CanvasSourceBuilder.make(
                    context: context, canvasID: canvasID, workRoot: work)
                let built = try await C07CanvasPackage.build(
                    source: source, destination: destination,
                    stagingRoot: work.appendingPathComponent("staging", isDirectory: true))
                C07FileSystem.removeIfPresent(work)
                await self.finishFileJob(
                    id, url: built.fileURL, bytes: built.byteCount,
                    sha: built.sha256, warnings: [], manifest: nil)
            } catch is CancellationError {
                C07FileSystem.removeIfPresent(destination)
                C07FileSystem.removeIfPresent(work)
                await self.finishFailure(id, code: "cancelled")
            } catch let error as C07DataExchangeError {
                C07FileSystem.removeIfPresent(destination)
                C07FileSystem.removeIfPresent(work)
                await self.finishFailure(id, code: error.code,
                                         reason: error.errorDescription)
            } catch {
                C07FileSystem.removeIfPresent(destination)
                C07FileSystem.removeIfPresent(work)
                await self.finishFailure(id, code: "internal")
            }
        }
        jobs[id]?.task = task
        return id
    }

    func startCanvasImportInspect(context: C07DataExchangeContext,
                                  stageID: UUID) throws -> UUID {
        guard let stage = uploads[stageID], stage.committed else {
            throw C07DataExchangeError.notFound
        }
        let uploadURL = stage.url
        let id = UUID()
        let planRoot = context.stagingRoot.appendingPathComponent(
            "canvas-import-\(id.uuidString)", isDirectory: true)
        jobs[id] = Job(id: id, kind: "canvasImport", phase: .inspecting,
                       uploadStageID: stageID)
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let staged = try C07CanvasPackage.inspect(
                    archiveURL: uploadURL, stagingRoot: planRoot)
                let plan = try C07CanvasImportPlan.make(
                    staged: staged, currentAppSchemaVersion:
                        DatabaseManager.currentSchemaVersion)
                await self.finishInspection(id, plan: plan)
            } catch let error as C07DataExchangeError {
                C07FileSystem.removeIfPresent(planRoot)
                await self.finishFailure(id, code: error.code,
                                         reason: error.errorDescription)
            } catch {
                C07FileSystem.removeIfPresent(planRoot)
                await self.finishFailure(id, code: "internal")
            }
        }
        jobs[id]?.task = task
        return id
    }

    func startDocumentImportInspect(context: C07DataExchangeContext,
                                    stageID: UUID,
                                    displayName: String) throws -> UUID {
        guard let stage = uploads[stageID], stage.committed else {
            throw C07DataExchangeError.notFound
        }
        let uploadURL = stage.url
        let id = UUID()
        let planRoot = context.stagingRoot.appendingPathComponent(
            "document-import-\(id.uuidString)", isDirectory: true)
        jobs[id] = Job(id: id, kind: "documentImport", phase: .inspecting,
                       uploadStageID: stageID)
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                try C07FileSystem.ensureDirectory(planRoot)
                let validated = try C07PortableDocumentInspector.inspect(
                    fileURL: uploadURL, displayName: displayName)
                let stagedURL = planRoot.appendingPathComponent(
                    c07SafeArtifactName(validated.displayName))
                try C07FileSystem.copyVerified(
                    source: uploadURL, destination: stagedURL,
                    expectedSize: validated.byteCount)
                let record = C07ProjectRecord(
                    projectID: UUID(),
                    name: "Imported \(validated.displayName)",
                    origin: .managed,
                    createdAt: Date(),
                    files: [C07ProjectFileRecord(
                        relativePath: c07SafeArtifactName(validated.displayName),
                        byteCount: validated.byteCount,
                        sha256: validated.sha256,
                        mode: 0o600)],
                    directories: [])
                let staged = C07StagedProject(
                    record: record,
                    files: [C07StagedProjectFile(
                        relativePath: record.files[0].relativePath,
                        stagedURL: stagedURL,
                        byteCount: validated.byteCount,
                        sha256: validated.sha256,
                        mode: 0o600)])
                let manifest = C07BackupManifest(
                    appSchemaVersion: DatabaseManager.currentSchemaVersion,
                    scope: C07BackupScope(
                        excluded: C07ScopePolicy.excluded,
                        databaseMode: "logicalRows"),
                    projects: [],
                    notes: C07NotesRecord(notebooks: [], documents: []),
                    settings: C07SettingsRecord(
                        entry: nil, byteCount: 0, sha256: nil,
                        keys: [], providerCatalog: []),
                    warnings: [])
                let plan = C07RestorePlan(
                    manifest: manifest,
                    manifestSHA256: C07Digest.sha256(Data(validated.displayName.utf8)),
                    stagedRoot: planRoot,
                    projects: [staged],
                    notes: [],
                    settingsValues: [:],
                    ownedData: nil,
                    warnings: ["documentKind:\(validated.kind.rawValue)"],
                    totalBytes: validated.byteCount)
                await self.finishInspection(id, plan: plan)
            } catch let error as C07DataExchangeError {
                C07FileSystem.removeIfPresent(planRoot)
                await self.finishFailure(id, code: error.code,
                                         reason: error.errorDescription)
            } catch {
                C07FileSystem.removeIfPresent(planRoot)
                await self.finishFailure(id, code: "internal")
            }
        }
        jobs[id]?.task = task
        return id
    }
}

enum C07CanvasSourceBuilder {
    static func make(context: C07DataExchangeContext,
                     canvasID: UUID,
                     workRoot: URL) throws -> C07CanvasSource {
        _ = workRoot
        let canvasURL = context.artifactRoot
            .appendingPathComponent("Canvases", isDirectory: true)
            .appendingPathComponent("\(canvasID.uuidString).json")
        guard C07FileSystem.isRegularFile(canvasURL) else {
            throw C07DataExchangeError.notFound
        }
        let data: Data
        do { data = try Data(contentsOf: canvasURL) }
        catch { throw C07DataExchangeError.storageUnavailable("canvasRead") }
        let references = try C07CanvasGraph.scan(canvasData: data)
        guard references.canvasID == canvasID else {
            throw C07DataExchangeError.documentPackage("canvasIdentity")
        }
        var children: [UUID: URL] = [:]
        var assets: [String: URL] = [:]
        var missingChildren: [UUID] = []
        var missingAssets: [String] = []
        var coveredRoots = Set<String>()
        for childID in references.childProjectIDs {
            let url = context.artifactRoot
                .appendingPathComponent("MediaProjects", isDirectory: true)
                .appendingPathComponent("media-project-\(childID.uuidString).json")
            guard C07FileSystem.isRegularFile(url) else {
                missingChildren.append(childID)
                continue
            }
            children[childID] = url
            coveredRoots.insert("WorkbenchRoot/\(childID.uuidString)")
            let projectData: Data
            do { projectData = try Data(contentsOf: url) }
            catch { missingChildren.append(childID); continue }
            guard let media = try? C07CanvasGraph.scanMediaProject(
                data: projectData) else {
                missingChildren.append(childID)
                continue
            }
            for assetPath in media.assetPaths {
                let assetURL = assetPath.hasPrefix("WorkbenchRoot/")
                    ? context.artifactRoot.appendingPathComponent(assetPath)
                    : context.artifactRoot
                        .appendingPathComponent("WorkbenchRoot", isDirectory: true)
                        .appendingPathComponent(childID.uuidString, isDirectory: true)
                        .appendingPathComponent(assetPath)
                if C07FileSystem.isRegularFile(assetURL) {
                    assets[assetPath] = assetURL
                } else {
                    missingAssets.append(assetPath)
                }
            }
        }
        var materials: [String: URL] = [:]
        for name in references.materialNames {
            let url = context.artifactRoot
                .appendingPathComponent("Materials", isDirectory: true)
                .appendingPathComponent(name)
            if C07FileSystem.isRegularFile(url) {
                materials[name] = url
            }
        }
        var nodeAssets: [String: URL] = [:]
        for path in references.nodeAssetPaths {
            if coveredRoots.contains(where: { path.hasPrefix($0 + "/") }) {
                continue
            }
            let url = context.artifactRoot.appendingPathComponent(path)
            if C07FileSystem.isRegularFile(url) { nodeAssets[path] = url }
        }
        return C07CanvasSource(
            canvasURL: canvasURL, childProjects: children,
            materials: materials, assets: assets, nodeAssets: nodeAssets,
            missingChildProjects: missingChildren,
            missingAssets: missingAssets,
            missingNodeAssets: [])
    }
}

enum C07CanvasImportPlan {
    static func make(staged: C07StagedCanvasImport,
                     currentAppSchemaVersion: Int) throws -> C07RestorePlan {
        let manifest = staged.manifest
        var artifacts: [C07StagedArtifact] = []
        func add(role: C07ArtifactRole, ownerID: UUID?, containerID: UUID?,
                 logicalPath: String, url: URL, byteCount: Int64, sha256: String) throws {
            let entry = try C07ArtifactPath.entry(
                role: role, containerID: containerID, ownerID: ownerID,
                logicalPath: logicalPath)
            artifacts.append(C07StagedArtifact(
                record: C07ArtifactRecord(
                    role: role, ownerID: ownerID, containerID: containerID,
                    logicalPath: logicalPath, entry: entry,
                    byteCount: byteCount, sha256: sha256),
                url: url))
        }
        let canvasBytes = try C07Digest.file(staged.canvasURL)
        try add(role: .canvasProject, ownerID: manifest.canvasID,
                containerID: manifest.canvasID, logicalPath: "project.json",
                url: staged.canvasURL, byteCount: canvasBytes.byteCount,
                sha256: canvasBytes.sha256)
        for child in manifest.childProjects {
            guard let url = staged.childProjects[child.projectID] else { continue }
            try add(role: .canvasMediaProject, ownerID: child.projectID,
                    containerID: manifest.canvasID,
                    logicalPath: "media-project-\(child.projectID.uuidString).json",
                    url: url, byteCount: child.byteCount, sha256: child.sha256)
        }
        for material in manifest.materials {
            guard let url = staged.materials[material.fileName] else { continue }
            try add(role: .canvasMaterial, ownerID: nil,
                    containerID: manifest.canvasID,
                    logicalPath: material.fileName, url: url,
                    byteCount: material.byteCount, sha256: material.sha256)
        }
        // Child asset → owner is the child project whose JSON references it.
        var ownerByPath: [String: UUID] = [:]
        for child in manifest.childProjects {
            guard let url = staged.childProjects[child.projectID],
                  let data = try? Data(contentsOf: url),
                  let media = try? C07CanvasGraph.scanMediaProject(data: data) else {
                continue
            }
            for path in media.assetPaths { ownerByPath[path] = child.projectID }
        }
        for asset in manifest.assets {
            guard let url = staged.assets[asset.relativePath] else { continue }
            // A donor package always binds child assets to a child project.
            // If a package omits that binding, keep the bytes under the
            // restored canvas root instead of dropping the resource.
            let owner = ownerByPath[asset.relativePath]
                ?? manifest.childProjects.first?.projectID
                ?? manifest.canvasID
            try add(role: .canvasAsset,
                    ownerID: owner,
                    containerID: manifest.canvasID,
                    logicalPath: asset.relativePath, url: url,
                    byteCount: asset.byteCount, sha256: asset.sha256)
        }
        for asset in manifest.externalNodeAssets {
            guard let url = staged.nodeAssets[asset.relativePath] else { continue }
            try add(role: .canvasNodeAsset, ownerID: nil,
                    containerID: manifest.canvasID,
                    logicalPath: asset.relativePath, url: url,
                    byteCount: asset.byteCount, sha256: asset.sha256)
        }
        let counts = C07OwnedDataCounts(
            canvasProjects: 1,
            mediaProjects: manifest.childProjects.count,
            mediaAssets: manifest.assets.count,
            artifacts: artifacts.count,
            artifactBytes: artifacts.reduce(0) { $0 + $1.record.byteCount })
        let dataManifest = C07OwnedDataManifest(
            createdAt: Date(),
            sourceAppSchemaVersion: currentAppSchemaVersion,
            tables: [],
            workspaceCount: 0,
            workspaceByteCount: 0,
            workspaceSHA256: C07Digest.sha256(Data("[]".utf8)),
            counts: counts,
            excluded: C07ScopePolicy.excluded,
            linuxCheckpointPort: "unavailable",
            linuxCheckpointReason: "canvasDocumentPackage",
            warnings: [])
        let owned = C07StagedOwnedData(
            manifest: dataManifest,
            manifestSHA256: staged.manifestSHA256,
            tables: [],
            workspaces: [],
            artifacts: artifacts,
            totalBytes: staged.totalBytes)
        let backupManifest = C07BackupManifest(
            appSchemaVersion: currentAppSchemaVersion,
            scope: C07BackupScope(
                excluded: C07ScopePolicy.excluded,
                databaseMode: "logicalRows"),
            projects: [],
            notes: C07NotesRecord(notebooks: [], documents: []),
            settings: C07SettingsRecord(
                entry: nil, byteCount: 0, sha256: nil,
                keys: [], providerCatalog: []),
            warnings: ["documentKind:canvas"])
        return C07RestorePlan(
            manifest: backupManifest,
            manifestSHA256: staged.manifestSHA256,
            stagedRoot: staged.stagedRoot,
            projects: [],
            notes: [],
            settingsValues: [:],
            ownedData: owned,
            warnings: staged.manifest.missingChildProjects.map {
                "canvasChildMissing:\($0.uuidString.prefix(8))"
            } + staged.manifest.missingAssets.map {
                "canvasAssetMissing:\($0.prefix(40))"
            },
            totalBytes: staged.totalBytes)
    }
}
