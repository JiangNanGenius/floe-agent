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
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey,
                                              .posixPermissionsKey],
                options: [.skipsHiddenFiles]) {
                for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    let leaf = item.lastPathComponent
                    guard let id = UUID(uuidString: leaf), id.uuidString == leaf else {
                        warnings.append("retainedLeafIgnored")
                        continue
                    }
                    guard !managedIDs.contains(id) else { continue }
                    let values = try? item.resourceValues(forKeys: [
                        .isDirectoryKey, .isSymbolicLinkKey, .posixPermissionsKey,
                    ])
                    guard values?.isDirectory == true, values?.isSymbolicLink != true,
                          (values?.posixPermissions ?? 0) & 0o777 == 0o700 else {
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
        return C07BackupSource(
            appSchemaVersion: appSchema,
            projects: projects,
            notebooks: notebooks,
            notes: notes,
            trashedNotesExcluded: trashed,
            failedNotes: failedNotes,
            settingsValues: settings,
            providerCatalog: providerCatalog,
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
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
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
