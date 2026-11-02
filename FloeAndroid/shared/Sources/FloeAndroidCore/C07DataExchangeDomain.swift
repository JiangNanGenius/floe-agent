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
import FloeAndroidToolResults

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
    /// C08 App-owned Office recovery roots derived from the accepted runtime
    /// root. The host half (OfficeRecoveryArtifacts) is the authority for
    /// enumeration; this context only gives the rooted stream fixed roots:
    ///   <files>/OfficeInputs/working
    ///   <no_backup>/floe-office-outputs
    ///   <files>/OfficeInputs/restored
    let officeWorkingRoot: URL
    let officeOutputsRoot: URL
    let officeRestoredRoot: URL
    let database: DatabaseManager
    let workspaceStore: SQLiteWorkspaceStore
    let settingsStore: SQLiteSettingsStore
    let modelConfigurationStore: ModelConfigurationStore
    let projectLibrary: C01ProjectLibrary

    var toolResultsRoot: URL {
        artifactRoot.appendingPathComponent("ToolResults", isDirectory: true)
    }
    var restoredConfigRoot: URL {
        dataRoot.appendingPathComponent("RestoredConfig", isDirectory: true)
    }
    var restoredArtifactRoot: URL {
        dataRoot.appendingPathComponent("RestoredArtifacts", isDirectory: true)
    }
    var cadPreservedRoot: URL {
        artifactRoot.appendingPathComponent("CadPreserved", isDirectory: true)
    }

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
        // runtime root = <dataDir>/files/floe-runtime; the App-private data
        // directory is its grandparent. These names match the Kotlin
        // OfficePreviewController/OfficeRecoveryArtifacts roots exactly.
        let dataDirectory = URL(fileURLWithPath: root.path, isDirectory: true)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let officeInputs = dataDirectory.appendingPathComponent(
            "files/OfficeInputs", isDirectory: true)
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
            officeWorkingRoot: officeInputs.appendingPathComponent(
                "working", isDirectory: true),
            officeOutputsRoot: dataDirectory.appendingPathComponent(
                "no_backup/floe-office-outputs", isDirectory: true),
            officeRestoredRoot: officeInputs.appendingPathComponent(
                "restored", isDirectory: true),
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
                    officeDrafts: C08OfficeDraftCaptureRequest? = nil,
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
            includeRetainedProjects: includeRetainedProjects,
            officeDrafts: officeDrafts)
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
            // The staged archive bytes and the live project tree are both
            // streamed under explicit roots: intermediate project directories
            // are created owned (0700) from the opened project root and the
            // destination leaf is exclusively created and re-verified by
            // fstatat, so an ancestor/leaf swap can never redirect a project
            // write into another tree.
            try C07POSIX.writeExclusive(
                sourceRoot: file.stagedURL.deletingLastPathComponent(),
                sourceRelativePath: file.stagedURL.lastPathComponent,
                destinationRoot: root,
                destinationRelativePath: file.relativePath,
                expectedBytes: file.byteCount, expectedSHA256: file.sha256,
                mode: file.mode,
                createDestinationParents: true)
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
//
// Project-file restore writes go through the same descriptor-safe rooted
// stream as the archive builder: both sides are opened relative to explicit
// trusted roots with no-follow traversal, the source identity is fstat-gated
// before and after the stream, and the destination is exclusively created
// and re-verified by fstatat. A failure removes only the exact destination
// inode created by this call.

enum C07POSIX {
    static func writeExclusive(sourceRoot: URL,
                               sourceRelativePath: String,
                               destinationRoot: URL,
                               destinationRelativePath: String,
                               expectedBytes: Int64,
                               expectedSHA256: String,
                               mode: Int = 0o600,
                               createDestinationParents: Bool = false)
        throws
    {
        let result = try C07FileSystem.copyVerified(
            sourceRoot: sourceRoot,
            sourceRelativePath: sourceRelativePath,
            destinationRoot: destinationRoot,
            destinationRelativePath: destinationRelativePath,
            expectedSize: expectedBytes,
            mode: mode,
            createDestinationParents: createDestinationParents)
        guard result.byteCount == expectedBytes,
              result.sha256 == expectedSHA256 else {
            // copyVerified created the destination exclusively; it is our
            // inode and no pre-existing user file can be affected.
            C07FileSystem.removeIfPresent(
                destinationRoot.appendingPathComponent(destinationRelativePath))
            throw result.sha256 != expectedSHA256
                ? C07DataExchangeError.hashMismatch(destinationRelativePath)
                : C07DataExchangeError.sizeMismatch(destinationRelativePath)
        }
    }

    /// Compatibility entry for staged absolute URLs: the immediate parent of
    /// a caller-staged file is its fixed root. Never pass model-, archive-
    /// or UI-supplied paths here.
    static func writeExclusive(source: URL,
                               destination: URL,
                               expectedBytes: Int64,
                               expectedSHA256: String,
                               mode: Int = 0o600) throws {
        try writeExclusive(
            sourceRoot: source.deletingLastPathComponent(),
            sourceRelativePath: source.lastPathComponent,
            destinationRoot: destination.deletingLastPathComponent(),
            destinationRelativePath: destination.lastPathComponent,
            expectedBytes: expectedBytes,
            expectedSHA256: expectedSHA256,
            mode: mode,
            createDestinationParents: false)
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
    public var todoCount: Int?
    public var toolResultCount: Int?
    public var appArtifactCount: Int?
    public var captureFileCount: Int?
    public var configSectionCount: Int?
    public var mcpDefinitionCount: Int?
    public var omissionCount: Int?
    public var partial: Bool?
    public var restoredTodos: Int?
    public var restoredToolResults: Int?
    public var restoredAppArtifacts: Int?
    public var restoredCaptureFiles: Int?
    public var restoredCADPreserved: Int?
    public var restoredConfigSections: Int?
    public var restoredMCPDefinitions: Int?
    // 2026-11-02 user-data expansion counts (plan = export side,
    // restored* = commit side).
    public var memoryEntryCount: Int? = nil
    public var memoryCandidateCount: Int? = nil
    public var personalizationDocumentCount: Int? = nil
    public var personalizationCursorCount: Int? = nil
    public var checklistRevisionCount: Int? = nil
    public var skillCount: Int? = nil
    public var modelPreferenceCount: Int? = nil
    public var runDependencyCount: Int? = nil
    public var officeDraftCount: Int? = nil
    public var officeDraftBytes: Int64? = nil
    public var restoredMemoryEntries: Int? = nil
    public var restoredMemoryCandidates: Int? = nil
    public var restoredPersonalizationDocuments: Int? = nil
    public var restoredPersonalizationCursors: Int? = nil
    public var restoredChecklistRevisions: Int? = nil
    public var restoredSkills: Int? = nil
    public var restoredModelPreferences: Int? = nil
    public var restoredOfficeDrafts: Int? = nil
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
                     includeRetainedProjects: Bool,
                     officeDrafts: C08OfficeDraftCaptureRequest? = nil) -> UUID {
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
                    .makeSource(
                        includeRetainedProjects: includeRetainedProjects,
                        officeDrafts: officeDrafts
                    ) { done, total in
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

    func startTaskExport(context: C07DataExchangeContext, conversationID: UUID) -> UUID {
        let id = UUID()
        let destination = context.exportsRoot.appendingPathComponent("\(id.uuidString).jsonl")
        jobs[id] = Job(id: id, kind: "taskExport", phase: .building)
        jobs[id]?.task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                try await C08TaskTranscript.export(database: context.database, conversationID: conversationID, to: destination)
                let digest = try C07Digest.file(destination)
                await self.finishFileJob(id, url: destination, bytes: digest.byteCount, sha: digest.sha256, warnings: [], manifest: nil)
            } catch {
                C07FileSystem.removeIfPresent(destination)
                let code = error is CancellationError ? "cancelled" : (error as? C07DataExchangeError)?.code ?? "internal"
                await self.finishFailure(id, code: code)
            }
        }
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
            todoCount: job.plan?.ownedDataCounts.todos,
            toolResultCount: job.plan?.ownedDataCounts.toolResults,
            appArtifactCount: job.plan?.ownedDataCounts.appArtifacts,
            captureFileCount: job.plan?.ownedDataCounts.captureFiles,
            configSectionCount: job.plan?.ownedDataCounts.configSections,
            mcpDefinitionCount: job.plan?.ownedDataCounts.mcpDefinitions,
            omissionCount: job.plan?.ownedData?.manifest.omissions?.count
                ?? job.receipt?.omissions,
            partial: job.plan?.ownedData.map {
                ($0.manifest.completeness
                    ?? (($0.manifest.omissions?.isEmpty == false)
                        ? .partial : .complete)) == .partial
            } ?? job.receipt?.partial,
            restoredTodos: job.receipt?.todosRestored,
            restoredToolResults: job.receipt?.toolResultsRestored,
            restoredAppArtifacts: job.receipt?.appArtifactsRestored,
            restoredCaptureFiles: job.receipt?.captureFilesRestored,
            restoredCADPreserved: job.receipt?.cadPreservedRestored,
            restoredConfigSections: job.receipt?.configSectionsRestored,
            // The restore receipt is the commit marker; the durable plan
            // carries the typed MCP count that was actually inserted.
            restoredMCPDefinitions: job.receipt == nil
                ? nil : job.plan?.ownedDataCounts.mcpDefinitions,
            memoryEntryCount: job.plan?.ownedDataCounts.memoryEntries,
            memoryCandidateCount: job.plan?.ownedDataCounts.memoryCandidates,
            personalizationDocumentCount:
                job.plan?.ownedDataCounts.personalizationDocuments,
            personalizationCursorCount:
                job.plan?.ownedDataCounts.personalizationCursors,
            checklistRevisionCount: job.plan?.ownedDataCounts.checklistRevisions,
            skillCount: job.plan?.ownedDataCounts.skills,
            modelPreferenceCount: job.plan?.ownedDataCounts.modelPreferences,
            runDependencyCount: job.plan?.ownedDataCounts.runDependencies,
            officeDraftCount: job.plan?.ownedDataCounts.officeDrafts,
            officeDraftBytes: job.plan?.ownedDataCounts.officeDraftBytes,
            restoredMemoryEntries: job.receipt?.memoryEntriesRestored,
            restoredMemoryCandidates: job.receipt?.memoryCandidatesRestored,
            restoredPersonalizationDocuments:
                job.receipt?.personalizationDocumentsRestored,
            restoredPersonalizationCursors:
                job.receipt?.personalizationCursorsRestored,
            restoredChecklistRevisions: job.receipt?.checklistRevisionsRestored,
            restoredSkills: job.receipt?.skillsRestored,
            restoredModelPreferences: job.receipt?.modelPreferencesRestored,
            restoredOfficeDrafts: job.receipt?.officeDraftsRestored,
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
        guard var job = jobs[id], job.phase != .cancelled else {
            C07FileSystem.removeIfPresent(url)
            return
        }
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
    /// The existing App-owned artifact namespaces that carry durable user
    /// files. `Attachments` has its own role because the database owns its
    /// identity; every other namespace is captured path-for-path.
    static let appArtifactNamespaces: [String] = [
        "GeneratedImages", "BrowserArtifacts", "VNCArtifacts", "RDPArtifacts",
        "PresentationArtifacts", "ChangeArtifacts", "JobDownloads",
        "DesignRevisions", "RunOutputs",
    ]

    /// User-owned capture files outside the artifact root. They are restored
    /// into a read-only recovery area, never silently into a live capture
    /// library.
    static let captureAreas: [String] = [
        "packet-captures", "network-artifacts/pcap",
    ]

    static func capture(context: C07DataExchangeContext,
                        workRoot: URL,
                        includeRetainedProjects: Bool,
                        officeDrafts: C08OfficeDraftCaptureRequest? = nil) async throws
        -> C07SourceOwnedData
    {
        _ = includeRetainedProjects
        try C07FileSystem.ensureDirectory(workRoot)
        let tablesRoot = workRoot.appendingPathComponent("tables", isDirectory: true)
        try C07FileSystem.ensureDirectory(tablesRoot)
        let artifactStageRoot = workRoot.appendingPathComponent(
            "artifacts", isDirectory: true)
        try C07FileSystem.ensureDirectory(artifactStageRoot)
        var warnings: [String] = []
        var omissions = C07OmissionCollector()

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

        var collector = C07ArtifactCollector(stagingRoot: artifactStageRoot)
        warnings.append(contentsOf: try captureCanvasArtifacts(
            context: context, collector: &collector, omissions: &omissions,
            counts: &counts))
        warnings.append(contentsOf: try captureAttachmentArtifacts(
            context: context, tables: captured.tables,
            collector: &collector, omissions: &omissions, counts: &counts))
        warnings.append(contentsOf: try capturePrivateTaskArtifacts(
            context: context, workspaces: descriptors,
            collector: &collector, omissions: &omissions, counts: &counts))
        warnings.append(contentsOf: try captureMailReceipts(
            context: context, collector: &collector, omissions: &omissions,
            counts: &counts))
        warnings.append(contentsOf: try captureAppArtifacts(
            context: context, collector: &collector, omissions: &omissions,
            counts: &counts))
        warnings.append(contentsOf: try captureUserCaptureFiles(
            context: context, collector: &collector, omissions: &omissions,
            counts: &counts))

        var configs: [C07SourceConfigSection] = []
        warnings.append(contentsOf: try await captureConfigurations(
            context: context, captured: captured, workRoot: workRoot,
            configs: &configs, omissions: &omissions, counts: &counts))
        let toolResults = try await captureToolResults(
            context: context, captured: captured, workRoot: workRoot,
            omissions: &omissions, counts: &counts, warnings: &warnings)

        // C08 persisted Office recovery content. The App host enumerated and
        // byte-verified owned recovery artifacts; this side re-validates the
        // fixed root shape, streams the exact bytes through the rooted C07
        // copy, and folds in explicit omissions for anything unreadable or
        // changed during capture.
        let officeDraftSection = try C08OfficeDraftExchange.capture(
            request: officeDrafts,
            workingRoot: context.officeWorkingRoot,
            outputsRoot: context.officeOutputsRoot,
            restoredRoot: context.officeRestoredRoot,
            workRoot: workRoot,
            omissions: &omissions,
            counts: &counts,
            warnings: &warnings)

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
                    _ = try collector.appendFile(
                        sourceRoot: workRoot, source: metadataURL,
                        role: .environmentCheckpoint,
                        ownerID: environment.environmentID, containerID: nil,
                        logicalPath: "metadata.json",
                        expectedSHA256: nil, expectedByteCount: nil)
                    for file in environment.files {
                        do {
                            _ = try C07Path.validateRelative(file.relativePath)
                        } catch {
                            omissions.add("environmentCheckpoint",
                                          "\(environment.environmentID.uuidString)/\(file.relativePath)",
                                          "unsafePath")
                            continue
                        }
                        // Checkpoint bytes are produced and verified by the
                        // C01-owned port; the port's own directory is the
                        // fixed root for this staged copy.
                        _ = try collector.appendFile(
                            sourceRoot: file.url.deletingLastPathComponent(),
                            source: file.url, role: .environmentCheckpoint,
                            ownerID: environment.environmentID, containerID: nil,
                            logicalPath: file.relativePath,
                            expectedSHA256: file.sha256,
                            expectedByteCount: file.byteCount)
                    }
                }
                checkpointPort = "available"
                checkpointReason = nil
            } catch {
                checkpointPort = "unavailable"
                checkpointReason = "c01CheckpointExportFailed"
                warnings.append("environmentExportFailed")
                omissions.add("environmentCheckpoint", "c01",
                              "c01CheckpointExportFailed")
            }
        }

        counts.artifacts = collector.artifacts.count
        counts.artifactBytes = collector.artifacts.reduce(0) {
            $0 + $1.record.byteCount
        }
        counts.omissions = omissions.items.count
        counts.configSections = configs.count
        let excluded = C07ScopePolicy.excluded
        warnings.append(contentsOf: omissions.warnings)
        let source = C07SourceOwnedData(
            tables: captured.tables,
            workspaces: C07SourceWorkspaces(
                url: workspaceFile, count: descriptors.count),
            artifacts: collector.artifacts,
            toolResults: toolResults,
            configs: configs,
            officeDrafts: officeDraftSection,
            omissions: omissions.items,
            deduplicatedArtifacts: collector.deduplicated,
            counts: counts,
            excluded: excluded,
            linuxCheckpointPort: checkpointPort,
            linuxCheckpointReason: checkpointReason,
            warnings: warnings)
        // Final writer-side closure check over the staged bytes. The archive
        // builder repeats it; this makes a bad capture fail before a large
        // archive copy.
        _ = try C07OwnedDataClosure.validate(
            tables: source.tables.map {
                C07ClosureTable(name: $0.name, url: $0.url, rowCount: $0.rowCount)
            },
            artifacts: source.artifacts.map {
                C07ClosureArtifact(record: $0.record, url: $0.url)
            },
            toolResults: source.toolResults.map {
                C07ClosureToolResults(url: $0.url, section: $0.section)
            },
            configs: source.configs.map {
                C07ClosureConfig(section: $0.section, url: $0.url)
            },
            officeDrafts: source.officeDrafts.map {
                C07ClosureOfficeDrafts(
                    section: $0.section, catalog: $0.catalog,
                    metadataURL: $0.metadataURL, contents: $0.contents)
            },
            omissions: source.omissions)
        return source
    }

    // MARK: Table snapshot

    private struct CapturedTables {
        var tables: [C07SourceTable]
        var workspaces: [C07WorkspaceDescriptor]
        var counts: C07OwnedDataCounts
        var warnings: [String]
        var schemaVersion: Int
        var conversationIDs: [UUID]
        var toolCallCount: Int
        var hosts: C07RemoteHostConfigDocument?
        var invalidHostIDs: [String]
        var mailAccounts: C07MailAccountConfigDocument?
        var invalidMailIDs: [String]
    }

    private static func captureTables(database: DatabaseManager,
                                      directory: URL) async throws -> CapturedTables {
        try await database.reader { db in
            let schemaVersion = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
            // The static version and the live table set must be one coherent
            // schema. A half-migrated database is never labelled as a full
            // backup of a different schema.
            guard schemaVersion == DatabaseManager.currentSchemaVersion else {
                throw C07DataExchangeError.schemaMismatch(schemaVersion)
            }
        var tables: [C07SourceTable] = []
        var counts = C07OwnedDataCounts()
        var warnings: [String] = []
        var conversationIDs: [UUID] = []
        var toolCalls = 0
        var excludedConversationIDs = Set<String>()
        for policy in C07OwnedDataPolicy.tables {
                let exists = try db.tableExists(policy.name)
                if !exists {
                    if policy.optional {
                        warnings.append("tableUnavailable:\(policy.name)")
                        continue
                    }
                    if !policy.isExpected(at: schemaVersion) {
                        // Declared schema fact (for example calendar_todos
                        // before coordinated migration 52). No user data of
                        // that category exists on this schema.
                        warnings.append(
                            "tableNotInSchema:\(policy.name):\(schemaVersion)")
                        continue
                    }
                    throw C07DataExchangeError.schemaMismatch(schemaVersion)
                }
                let columns = Set(try db.columns(in: policy.name).map(\.name))
                guard policy.requiredColumns(at: schemaVersion)
                        .isSubset(of: columns) else {
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
                        table: policy.name, row: values,
                        excludedConversationIDs: excludedConversationIDs) else {
                        excludedRows += 1
                        if policy.name == "conversations",
                           let id = values["id"]?.stringValue {
                            excludedConversationIDs.insert(id)
                        }
                        continue
                    }
                    if policy.name == "conversations",
                       let idText: String = row["id"],
                       let id = UUID(uuidString: idText) {
                        conversationIDs.append(id)
                    }
                    if policy.name == "tool_calls" { toolCalls += 1 }
                    let exported = C07OwnedDataPolicy.exportedRow(
                        table: policy.name, row: values)
                    try writer.append(exported)
                }
                try writer.finish()
                if excludedRows > 0 {
                    warnings.append("rowsExcluded:\(policy.name):\(excludedRows)")
                }
                tables.append(C07SourceTable(
                    name: policy.name, url: url, rowCount: writer.rowCount))
                updateCounts(table: policy.name, rows: writer.rowCount,
                             counts: &counts)
            }
            let workspaces = try captureWorkspaces(db: db, warnings: &warnings)
            let hostConfig = try captureHosts(db: db, warnings: &warnings)
            let mailConfig = try captureMailAccountConfiguration(
                db: db, warnings: &warnings)
            return CapturedTables(
                tables: tables, workspaces: workspaces,
                counts: counts, warnings: warnings,
                schemaVersion: schemaVersion,
                conversationIDs: conversationIDs.sorted {
                    $0.uuidString < $1.uuidString
                },
                toolCallCount: toolCalls,
                hosts: hostConfig.document, invalidHostIDs: hostConfig.invalid,
                mailAccounts: mailConfig.document,
                invalidMailIDs: mailConfig.invalid)
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
        case "calendar_todos": counts.todos = rows
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
        case "memory_entries": counts.memoryEntries = rows
        case "memory_candidates": counts.memoryCandidates = rows
        case "personalization_documents":
            counts.personalizationDocuments = rows
        case "personalization_update_cursors":
            counts.personalizationCursors = rows
        case "task_checklist_revisions": counts.checklistRevisions = rows
        case "skills": counts.skills = rows
        case "model_preferences": counts.modelPreferences = rows
        case "run_dependencies": counts.runDependencies = rows
        default: break
        }
    }

    // MARK: Non-secret configuration snapshot (same DB read transaction)

    private static func captureHosts(
        db: Database,
        warnings: inout [String]
    ) throws -> (document: C07RemoteHostConfigDocument?, invalid: [String]) {
        guard try db.tableExists("hosts") else { return (nil, []) }
        let rows: [Row]
        do {
            rows = try Row.fetchAll(db, sql: """
                SELECT id, display_name, address, port, user, device_kind,
                       is_remote_execution_environment, jump_chain_json,
                       host_key_policy, allows_legacy_algorithms,
                       vnc_endpoints_json, auxiliary_connections_json
                FROM hosts ORDER BY id
                """)
        } catch {
            throw C07DataExchangeError.schemaMismatch(
                DatabaseManager.currentSchemaVersion)
        }
        var hosts: [C07RemoteHostConfig] = []
        var invalid: [String] = []
        for row in rows {
            guard let idText: String = row["id"],
                  let id = UUID(uuidString: idText) else {
                warnings.append("hostRowIgnored")
                continue
            }
            let jump = (row["jump_chain_json"] as String?)
                .flatMap(C07OwnedDataSource.jsonArrayCount) ?? 0
            let vnc = (row["vnc_endpoints_json"] as String?)
                .flatMap(C07OwnedDataSource.jsonArrayCount)
                ?? ((row["vnc_endpoint_json"] as String?) == nil ? 0 : 1)
            let aux = (row["auxiliary_connections_json"] as String?)
                .flatMap(C07OwnedDataSource.jsonArrayCount) ?? 0
            let displayName = Self.bounded(row["display_name"] as String?, 512)
            let address = Self.bounded(row["address"] as String?, 1_024)
            guard !displayName.isEmpty, !address.isEmpty else {
                invalid.append(idText)
                continue
            }
            hosts.append(C07RemoteHostConfig(
                id: id,
                displayName: displayName,
                address: address,
                port: min(65_535, max(1, (row["port"] as Int?) ?? 22)),
                user: Self.bounded(row["user"] as String?, 512),
                deviceKind: Self.bounded(row["device_kind"] as String?, 64),
                isRemoteExecutionEnvironment:
                    (row["is_remote_execution_environment"] as Bool?) ?? true,
                jumpHostCount: min(64, jump),
                vncEndpointCount: min(64, vnc),
                auxiliaryConnectionCount: min(64, aux),
                hostKeyPolicy: Self.hostKeyPolicy(
                    row["host_key_policy"] as String?),
                allowsLegacyAlgorithms:
                    (row["allows_legacy_algorithms"] as Bool?) ?? false))
        }
        guard !hosts.isEmpty else { return (nil, invalid) }
        let document = C07RemoteHostConfigDocument(hosts: hosts)
        try document.validate()
        return (document, invalid)
    }

    private static func captureMailAccountConfiguration(
        db: Database,
        warnings: inout [String]
    ) throws -> (document: C07MailAccountConfigDocument?, invalid: [String]) {
        guard try db.tableExists("mail_accounts") else { return (nil, []) }
        let rows: [Row]
        do {
            rows = try Row.fetchAll(db, sql: """
                SELECT id, address, display_name, incoming_protocol,
                       incoming_host, incoming_port, incoming_tls,
                       incoming_username, outgoing_host, outgoing_port,
                       outgoing_tls, outgoing_username
                FROM mail_accounts ORDER BY id
                """)
        } catch {
            throw C07DataExchangeError.schemaMismatch(
                DatabaseManager.currentSchemaVersion)
        }
        var accounts: [C07MailAccountConfig] = []
        var invalid: [String] = []
        for row in rows {
            guard let idText: String = row["id"],
                  let id = UUID(uuidString: idText) else {
                warnings.append("mailAccountRowIgnored")
                continue
            }
            let address = Self.bounded(row["address"] as String?, 1_024)
            let protocolName = Self.bounded(
                row["incoming_protocol"] as String?, 32)
            let incomingHost = Self.bounded(
                row["incoming_host"] as String?, 1_024)
            let outgoingHost = Self.bounded(
                row["outgoing_host"] as String?, 1_024)
            guard !address.isEmpty, !protocolName.isEmpty,
                  !incomingHost.isEmpty, !outgoingHost.isEmpty else {
                invalid.append(idText)
                continue
            }
            accounts.append(C07MailAccountConfig(
                id: id,
                address: address,
                displayName: Self.bounded(row["display_name"] as String?, 512),
                incomingProtocol: protocolName,
                incomingHost: incomingHost,
                incomingPort: min(65_535, max(1, (row["incoming_port"] as Int?) ?? 1)),
                incomingTLS: Self.bounded(row["incoming_tls"] as String?, 32),
                incomingUsername: Self.bounded(
                    row["incoming_username"] as String?, 512),
                outgoingHost: outgoingHost,
                outgoingPort: min(65_535, max(1, (row["outgoing_port"] as Int?) ?? 1)),
                outgoingTLS: Self.bounded(row["outgoing_tls"] as String?, 32),
                outgoingUsername: Self.bounded(
                    row["outgoing_username"] as String?, 512)))
        }
        guard !accounts.isEmpty else { return (nil, invalid) }
        let document = C07MailAccountConfigDocument(accounts: accounts)
        try document.validate()
        return (document, invalid)
    }

    private static func jsonArrayCount(_ raw: String) -> Int {
        guard let data = raw.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return 0 }
        return value.count
    }

    private static func hostKeyPolicy(_ raw: String?) -> String {
        switch raw {
        case "strict", "ask", "trustOnFirstUse": return raw ?? "trustOnFirstUse"
        default: return "trustOnFirstUse"
        }
    }

    private static func bounded(_ raw: String?, _ bytes: Int) -> String {
        guard let raw else { return "" }
        var value = raw.precomposedStringWithCanonicalMapping
        value = value.filter {
            $0.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
        }
        if value.utf8.count > bytes {
            value = ToolResultUTF8Fallback.prefix(value, maxBytes: bytes)
        }
        return value
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

    private static func captureCanvasArtifacts(
        context: C07DataExchangeContext,
        collector: inout C07ArtifactCollector,
        omissions: inout C07OmissionCollector,
        counts: inout C07OwnedDataCounts) throws -> [String]
    {
        var warnings: [String] = []
        let canvasDirectory = context.artifactRoot.appendingPathComponent(
            "Canvases", isDirectory: true)
        let items: [URL]
        do {
            items = try FileManager.default.contentsOfDirectory(
                at: canvasDirectory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles])
        } catch {
            // A directory that does not exist is simply empty. An existing
            // but unreadable canvas directory is an IO failure, never a
            // silent "no canvases" backup.
            if !FileManager.default.fileExists(atPath: canvasDirectory.path) {
                return warnings
            }
            throw C07DataExchangeError.storageUnavailable("canvasEnumerate")
        }
        for url in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where url.pathExtension.lowercased() == "json" {
            guard C07FileSystem.isRegularFile(url) else {
                omissions.add("canvasDocument",
                              url.deletingPathExtension().lastPathComponent,
                              "notRegularFile")
                continue
            }
            let data: Data
            do { data = try Data(contentsOf: url) }
            catch { throw C07DataExchangeError.storageUnavailable("canvasRead") }
            let references: C07CanvasReferences
            do { references = try C07CanvasGraph.scan(canvasData: data) }
            catch {
                omissions.add("canvasDocument",
                              url.deletingPathExtension().lastPathComponent,
                              "invalidCanvasJSON")
                continue
            }
            _ = try collector.appendData(
                data, role: .canvasProject, ownerID: references.canvasID,
                containerID: references.canvasID, logicalPath: "project.json")
            counts.canvasProjects += 1
            let materialsRoot = context.artifactRoot
                .appendingPathComponent("Materials", isDirectory: true)
            for name in references.materialNames.sorted() {
                let materialURL = materialsRoot.appendingPathComponent(name)
                if !FileManager.default.fileExists(atPath: materialURL.path) {
                    omissions.add("canvasMaterial",
                                  "\(references.canvasID.uuidString)/\(name)",
                                  "missing")
                    continue
                }
                _ = try collector.appendFile(
                    sourceRoot: materialsRoot, source: materialURL,
                    role: .canvasMaterial, ownerID: nil,
                    containerID: references.canvasID, logicalPath: name,
                    expectedSHA256: nil, expectedByteCount: nil)
            }
            var coveredMediaRoots = Set<String>()
            for childID in references.childProjectIDs.sorted(
                by: { $0.uuidString < $1.uuidString }) {
                let projectURL = context.artifactRoot
                    .appendingPathComponent("MediaProjects", isDirectory: true)
                    .appendingPathComponent("media-project-\(childID.uuidString).json")
                guard FileManager.default.fileExists(atPath: projectURL.path) else {
                    omissions.add("canvasChildProject",
                                  "\(references.canvasID.uuidString)/\(childID.uuidString)",
                                  "missing")
                    warnings.append("canvasChildMissing:\(childID.uuidString.prefix(8))")
                    continue
                }
                let projectData: Data
                do { projectData = try Data(contentsOf: projectURL) }
                catch { throw C07DataExchangeError.storageUnavailable("mediaRead") }
                let media: (projectID: UUID, ownerKind: String, ownerID: UUID?,
                            assetIDs: [UUID], assetPaths: [String],
                            taskWorkspacePath: String?)
                do { media = try C07CanvasGraph.scanMediaProject(data: projectData) }
                catch {
                    omissions.add("canvasChildProject",
                                  "\(references.canvasID.uuidString)/\(childID.uuidString)",
                                  "invalidMediaProject")
                    continue
                }
                guard media.projectID == childID else {
                    omissions.add("canvasChildProject",
                                  "\(references.canvasID.uuidString)/\(childID.uuidString)",
                                  "mediaIdentityMismatch")
                    continue
                }
                _ = try collector.appendData(
                    projectData, role: .canvasMediaProject, ownerID: childID,
                    containerID: references.canvasID,
                    logicalPath: "media-project-\(childID.uuidString).json")
                counts.mediaProjects += 1
                let mediaRoot = "WorkbenchRoot/\(childID.uuidString)"
                coveredMediaRoots.insert(mediaRoot)
                var seenAssetPaths = Set<String>()
                let childRoot = context.artifactRoot
                    .appendingPathComponent("WorkbenchRoot", isDirectory: true)
                    .appendingPathComponent(childID.uuidString, isDirectory: true)
                for assetPath in media.assetPaths.sorted() {
                    seenAssetPaths.insert(assetPath)
                    let assetInWorkbenchRoot = assetPath.hasPrefix("WorkbenchRoot/")
                    let assetRoot = assetInWorkbenchRoot
                        ? context.artifactRoot
                        : childRoot
                    let assetURL = assetRoot.appendingPathComponent(assetPath)
                    guard FileManager.default.fileExists(atPath: assetURL.path) else {
                        omissions.add(
                            "canvasAsset",
                            "\(references.canvasID.uuidString)/\(childID.uuidString)/\(assetPath)",
                            "missing")
                        continue
                    }
                    _ = try collector.appendFile(
                        sourceRoot: assetRoot, source: assetURL,
                        role: .canvasAsset, ownerID: childID,
                        containerID: references.canvasID,
                        logicalPath: assetPath,
                        expectedSHA256: nil, expectedByteCount: nil)
                    counts.mediaAssets += 1
                }
                // Durable app-owned files in the media project root that are
                // not merely referenced (for example Workbench/Exports).
                var childEnumeratorError: Error?
                if let enumerator = FileManager.default.enumerator(
                    at: childRoot,
                    includingPropertiesForKeys: [.isRegularFileKey,
                                                  .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles],
                    errorHandler: { _, error in
                        childEnumeratorError = error
                        return false
                    }) {
                    let rootPath = childRoot.standardizedFileURL.path
                    for case let fileURL as URL in enumerator {
                        if let childEnumeratorError {
                            throw C07DataExchangeError.storageUnavailable(
                                "mediaEnumerate")
                        }
                        let values: URLResourceValues
                        do {
                            values = try fileURL.resourceValues(
                                forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                        } catch {
                            throw C07DataExchangeError.storageUnavailable(
                                "mediaEnumerate")
                        }
                        if values.isSymbolicLink == true {
                            warnings.append("mediaSymlinkSkipped")
                            continue
                        }
                        guard values.isRegularFile == true else { continue }
                        let path = fileURL.standardizedFileURL.path
                        guard path.hasPrefix(rootPath + "/") else { continue }
                        let relative = String(path.dropFirst(rootPath.count + 1))
                        guard (try? C07Path.validateRelative(relative)) != nil,
                              seenAssetPaths.insert(relative).inserted else {
                            continue
                        }
                        _ = try collector.appendFile(
                            sourceRoot: childRoot, source: fileURL,
                            role: .canvasAsset,
                            ownerID: childID,
                            containerID: references.canvasID,
                            logicalPath: relative,
                            expectedSHA256: nil, expectedByteCount: nil)
                        counts.mediaAssets += 1
                    }
                } else if childEnumeratorError != nil {
                    throw C07DataExchangeError.storageUnavailable("mediaEnumerate")
                }
            }
            for path in references.nodeAssetPaths.sorted() {
                if coveredMediaRoots.contains(where: { path.hasPrefix($0 + "/") }) {
                    continue
                }
                let assetURL = context.artifactRoot.appendingPathComponent(path)
                if !FileManager.default.fileExists(atPath: assetURL.path) {
                    omissions.add("canvasNodeAsset",
                                  "\(references.canvasID.uuidString)/\(path)",
                                  "missing")
                    continue
                }
                _ = try collector.appendFile(
                    sourceRoot: context.artifactRoot, source: assetURL,
                    role: .canvasNodeAsset, ownerID: nil,
                    containerID: references.canvasID, logicalPath: path,
                    expectedSHA256: nil, expectedByteCount: nil)
            }
        }
        return warnings
    }

    private static func captureAttachmentArtifacts(
        context: C07DataExchangeContext, tables: [C07SourceTable],
        collector: inout C07ArtifactCollector,
        omissions: inout C07OmissionCollector,
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
            guard row["storage"]?.stringValue == "applicationSupport" else { return }
            guard let idText = row["id"]?.stringValue,
                  let attachmentID = UUID(uuidString: idText) else { return }
            guard let relative = row["relative_path"]?.stringValue,
                  !relative.isEmpty else {
                omissions.add("attachmentPath", attachmentID.uuidString,
                              "missingPath")
                return
            }
            guard (try? C07Path.validateRelative(relative)) != nil else {
                omissions.add("attachmentPath", attachmentID.uuidString,
                              "unsafePath")
                return
            }
            let url = attachmentsRoot.appendingPathComponent(relative)
                .standardizedFileURL
            guard url.path.hasPrefix(rootPath + "/") else {
                omissions.add("attachmentPath", attachmentID.uuidString,
                              "outsideRoot")
                return
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                omissions.add("attachmentBytes", attachmentID.uuidString,
                              "missing")
                warnings.append(
                    "attachmentBytesMissing:\(attachmentID.uuidString.prefix(8))")
                return
            }
            let expectedSize = row["byte_count"]?.integerValue
            let expectedDigest = row["sha256"]?.stringValue
            let digest: (sha256: String, byteCount: Int64)
            do {
                digest = try C07Digest.file(url, maximum:
                    C07OwnedDataLimits.maximumArtifactBytes)
            } catch {
                throw C07DataExchangeError.storageUnavailable("attachmentRead")
            }
            if let expectedSize, expectedSize > 0,
               digest.byteCount != expectedSize {
                // Bytes changed after the database row was written. Refuse a
                // mixed snapshot rather than carrying an inconsistent pair.
                throw C07DataExchangeError.storageUnavailable("sourceChanged")
            }
            if let expectedDigest, !expectedDigest.isEmpty,
               digest.sha256 != expectedDigest {
                throw C07DataExchangeError.storageUnavailable("sourceChanged")
            }
            _ = try collector.appendFile(
                sourceRoot: attachmentsRoot, source: url,
                role: .attachment, ownerID: attachmentID,
                containerID: nil, logicalPath: relative,
                expectedSHA256: digest.sha256,
                expectedByteCount: digest.byteCount)
        }
        return warnings
    }

    private static func capturePrivateTaskArtifacts(
        context: C07DataExchangeContext,
        workspaces: [C07WorkspaceDescriptor],
        collector: inout C07ArtifactCollector,
        omissions: inout C07OmissionCollector,
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
                            return UUID(uuidString: String(
                                path.dropFirst("PrivateTasks/".count)))
                        }) else {
                omissions.add("privateTaskRoot",
                              workspace.workspaceID.uuidString,
                              "ownerUnknown")
                continue
            }
            let root = tasksRoot.appendingPathComponent(
                conversationID.uuidString, isDirectory: true)
            guard C07FileSystem.isDirectory(root) else {
                omissions.add("privateTaskRoot", conversationID.uuidString,
                              "missing")
                warnings.append(
                    "privateTaskMissing:\(conversationID.uuidString.prefix(8))")
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
                throw C07DataExchangeError.storageUnavailable(
                    "privateTaskEnumerate")
            }
            for case let url as URL in enumerator {
                if Task.isCancelled { throw C07DataExchangeError.cancelled }
                if enumerationFailure != nil {
                    throw C07DataExchangeError.storageUnavailable(
                        "privateTaskEnumerate")
                }
                let values: URLResourceValues
                do {
                    values = try url.resourceValues(
                        forKeys: [.isRegularFileKey, .isDirectoryKey,
                                  .isSymbolicLinkKey, .fileSizeKey])
                } catch {
                    throw C07DataExchangeError.storageUnavailable(
                        "privateTaskEnumerate")
                }
                if values.isSymbolicLink == true {
                    warnings.append("privateTaskSymlinkSkipped")
                    continue
                }
                if values.isDirectory == true { continue }
                guard values.isRegularFile == true else { continue }
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(rootPath + "/") else { continue }
                let relative = String(path.dropFirst(rootPath.count + 1))
                guard (try? C07Path.validateRelative(relative)) != nil else {
                    omissions.add("privateTaskFile",
                                  "\(conversationID.uuidString)/\(relative)",
                                  "unsafePath")
                    continue
                }
                _ = try collector.appendFile(
                    sourceRoot: root, source: url,
                    role: .privateTaskFile,
                    ownerID: conversationID, containerID: nil,
                    logicalPath: relative,
                    expectedSHA256: nil, expectedByteCount: nil)
                counts.privateTaskFiles += 1
            }
            if enumerationFailure != nil {
                throw C07DataExchangeError.storageUnavailable(
                    "privateTaskEnumerate")
            }
        }
        return warnings
    }

    private static func captureMailReceipts(
        context: C07DataExchangeContext,
        collector: inout C07ArtifactCollector,
        omissions: inout C07OmissionCollector,
        counts: inout C07OwnedDataCounts) throws -> [String]
    {
        var warnings: [String] = []
        for area in ["MailMutations", "MailDelivery"] {
            let root = context.artifactRoot.appendingPathComponent(
                area, isDirectory: true)
            var enumerationFailure: Error?
            guard FileManager.default.fileExists(atPath: root.path) else {
                continue
            }
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey,
                                              .isSymbolicLinkKey],
                options: [.skipsHiddenFiles],
                errorHandler: { _, error in
                    enumerationFailure = error
                    return false
                }) else {
                throw C07DataExchangeError.storageUnavailable(
                    "mailReceiptEnumerate")
            }
            let rootPath = root.standardizedFileURL.path
            for case let url as URL in enumerator {
                if enumerationFailure != nil {
                    throw C07DataExchangeError.storageUnavailable(
                        "mailReceiptEnumerate")
                }
                let values: URLResourceValues
                do {
                    values = try url.resourceValues(
                        forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                } catch {
                    throw C07DataExchangeError.storageUnavailable(
                        "mailReceiptEnumerate")
                }
                guard values.isRegularFile == true,
                      values.isSymbolicLink != true,
                      url.pathExtension.lowercased() == "json" else { continue }
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(rootPath + "/") else { continue }
                let relative = String(path.dropFirst(rootPath.count + 1))
                let logical = "\(area)/\(relative)"
                guard (try? C07Path.validateRelative(logical)) != nil else {
                    omissions.add("mailReceipt", relative, "unsafePath")
                    continue
                }
                _ = try collector.appendFile(
                    sourceRoot: root, source: url,
                    role: .mailReceipt, ownerID: nil,
                    containerID: nil, logicalPath: logical,
                    expectedSHA256: nil, expectedByteCount: nil)
                counts.mailReceipts += 1
            }
        }
        return warnings
    }

    private static func captureAppArtifacts(
        context: C07DataExchangeContext,
        collector: inout C07ArtifactCollector,
        omissions: inout C07OmissionCollector,
        counts: inout C07OwnedDataCounts) throws -> [String]
    {
        var warnings: [String] = []
        for namespace in appArtifactNamespaces {
            let root = context.artifactRoot.appendingPathComponent(
                namespace, isDirectory: true)
            guard C07FileSystem.isDirectory(root) else { continue }
            let rootPath = root.standardizedFileURL.path
            var enumerationFailure: Error?
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey,
                                              .isSymbolicLinkKey],
                options: [.skipsHiddenFiles],
                errorHandler: { _, error in
                    enumerationFailure = error
                    return false
                }) else {
                throw C07DataExchangeError.storageUnavailable(
                    "appArtifactEnumerate")
            }
            for case let url as URL in enumerator {
                if Task.isCancelled { throw C07DataExchangeError.cancelled }
                if enumerationFailure != nil {
                    throw C07DataExchangeError.storageUnavailable(
                        "appArtifactEnumerate")
                }
                let values: URLResourceValues
                do {
                    values = try url.resourceValues(
                        forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                } catch {
                    throw C07DataExchangeError.storageUnavailable(
                        "appArtifactEnumerate")
                }
                if values.isSymbolicLink == true {
                    warnings.append("appArtifactSymlinkSkipped")
                    continue
                }
                guard values.isRegularFile == true else { continue }
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(rootPath + "/") else { continue }
                let relative = String(path.dropFirst(rootPath.count + 1))
                let logical = "\(namespace)/\(relative)"
                guard (try? C07Path.validateRelative(logical)) != nil else {
                    omissions.add("appArtifact", logical, "unsafePath")
                    continue
                }
                _ = try collector.appendFile(
                    sourceRoot: context.artifactRoot, source: url,
                    role: .appArtifact, ownerID: nil,
                    containerID: nil, logicalPath: logical,
                    expectedSHA256: nil, expectedByteCount: nil)
                counts.appArtifacts = (counts.appArtifacts ?? 0) + 1
            }
        }
        return warnings
    }

    private static func captureUserCaptureFiles(
        context: C07DataExchangeContext,
        collector: inout C07ArtifactCollector,
        omissions: inout C07OmissionCollector,
        counts: inout C07OwnedDataCounts) throws -> [String]
    {
        var warnings: [String] = []
        let appFilesRoot = URL(fileURLWithPath: context.rootPath,
                               isDirectory: true).deletingLastPathComponent()
        guard C07FileSystem.isDirectory(appFilesRoot) else { return warnings }
        for area in captureAreas {
            let root = appFilesRoot.appendingPathComponent(area, isDirectory: true)
            guard C07FileSystem.isDirectory(root) else { continue }
            let rootPath = root.standardizedFileURL.path
            var enumerationFailure: Error?
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey,
                                              .isSymbolicLinkKey],
                options: [.skipsHiddenFiles],
                errorHandler: { _, error in
                    enumerationFailure = error
                    return false
                }) else {
                throw C07DataExchangeError.storageUnavailable(
                    "captureEnumerate")
            }
            for case let url as URL in enumerator {
                if enumerationFailure != nil {
                    throw C07DataExchangeError.storageUnavailable(
                        "captureEnumerate")
                }
                let values: URLResourceValues
                do {
                    values = try url.resourceValues(
                        forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                } catch {
                    throw C07DataExchangeError.storageUnavailable(
                        "captureEnumerate")
                }
                if values.isSymbolicLink == true {
                    warnings.append("captureSymlinkSkipped")
                    continue
                }
                guard values.isRegularFile == true else { continue }
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(rootPath + "/") else { continue }
                let relative = String(path.dropFirst(rootPath.count + 1))
                let logical = "\(area)/\(relative)"
                guard (try? C07Path.validateRelative(logical)) != nil else {
                    omissions.add("captureFile", logical, "unsafePath")
                    continue
                }
                _ = try collector.appendFile(
                    sourceRoot: root, source: url,
                    role: .captureFile, ownerID: nil,
                    containerID: nil, logicalPath: logical,
                    expectedSHA256: nil, expectedByteCount: nil)
                counts.captureFiles = (counts.captureFiles ?? 0) + 1
            }
        }
        return warnings
    }

    // MARK: Config documents

    private static func captureConfigurations(
        context: C07DataExchangeContext,
        captured: CapturedTables,
        workRoot: URL,
        configs: inout [C07SourceConfigSection],
        omissions: inout C07OmissionCollector,
        counts: inout C07OwnedDataCounts) async throws -> [String]
    {
        var warnings: [String] = []
        let directory = workRoot.appendingPathComponent("config", isDirectory: true)
        try C07FileSystem.ensureDirectory(directory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        func write(_ data: Data, kind: C07OwnedConfigKind) throws {
            let url = directory.appendingPathComponent("\(kind.rawValue).json")
            do { try data.write(to: url) }
            catch { throw C07DataExchangeError.storageUnavailable("configWrite") }
            let digest = try C07Digest.file(
                url, maximum: C07OwnedDataLimits.maximumConfigBytes)
            configs.append(C07SourceConfigSection(
                section: C07OwnedConfigSection(
                    kind: kind, count: 0, byteCount: digest.byteCount,
                    sha256: digest.sha256),
                url: url))
        }

        for id in captured.invalidHostIDs {
            omissions.add("remoteHostConfiguration", id, "invalidStoredRow")
        }
        for id in captured.invalidMailIDs {
            omissions.add("mailAccountConfiguration", id, "invalidStoredRow")
        }
        if let hosts = captured.hosts {
            let data: Data
            do { data = try encoder.encode(hosts) }
            catch { throw C07DataExchangeError.storageUnavailable("hostEncode") }
            try write(data, kind: .remoteHosts)
        }

        // RDP endpoint metadata is a separate app file keyed by the ORIGINAL
        // host profile UUID. Password references and approved fingerprints
        // are never read into the package.
        let rdpURL = URL(fileURLWithPath: context.rootPath, isDirectory: true)
            .appendingPathComponent("Floe", isDirectory: true)
            .appendingPathComponent("RDP", isDirectory: true)
            .appendingPathComponent("endpoints-v1.json", isDirectory: false)
        if FileManager.default.fileExists(atPath: rdpURL.path) {
            if let parsed = try? readRDPConfiguration(rdpURL) {
                let hostIDs = Set(captured.hosts?.hosts.map(\.id) ?? [])
                var usable: [C07RDPEndpointConfig] = []
                for endpoint in parsed {
                    if hostIDs.contains(endpoint.profileID) {
                        usable.append(endpoint)
                    } else {
                        // A stale endpoint whose host profile was deleted
                        // cannot be restored meaningfully; declare it.
                        omissions.add(
                            "rdpEndpoint",
                            "\(endpoint.profileID.uuidString)/\(endpoint.id.uuidString)",
                            "hostProfileMissing")
                    }
                }
                if !usable.isEmpty {
                    let document = C07RDPConfigDocument(endpoints: usable)
                    let data: Data
                    do { data = try encoder.encode(document) }
                    catch {
                        throw C07DataExchangeError.storageUnavailable("rdpEncode")
                    }
                    try write(data, kind: .rdpEndpoints)
                }
            } else {
                omissions.add("rdpConfiguration", "endpoints-v1.json",
                              "invalidRDPStore")
                warnings.append("rdpConfigurationInvalid")
            }
        }

        if let mail = captured.mailAccounts {
            let data: Data
            do { data = try encoder.encode(mail) }
            catch { throw C07DataExchangeError.storageUnavailable("mailEncode") }
            try write(data, kind: .mailAccounts)
        }

        // MCP definitions live in the ORIGINAL
        // `floe.mcp.remoteServers.v1` settings row. They are projected into a
        // typed, credential-free document; the raw JSON is never archived.
        // A row that cannot be projected is declared as an omission rather
        // than silently copied or hidden behind a generic settings prefix.
        do {
            if let raw = try await context.settingsStore.value(
                forKey: C07MCPConfigurationExchange.settingsKey) {
                let exported = try C07MCPConfigurationExchange.export(raw: raw)
                for skip in exported.skipped {
                    omissions.add("mcpServerDefinition", skip.sourceID,
                                  skip.reason)
                }
                for name in exported.sanitizedNames {
                    warnings.append("mcpEndpointSanitized:\(name)")
                }
                if !exported.skipped.isEmpty {
                    warnings.append("mcpDefinitionsOmitted:\(exported.skipped.count)")
                }
                if !exported.document.servers.isEmpty {
                    let data: Data
                    do { data = try encoder.encode(exported.document) }
                    catch {
                        throw C07DataExchangeError.storageUnavailable(
                            "mcpEncode")
                    }
                    try write(data, kind: .mcpServers)
                    counts.mcpDefinitions = exported.document.servers.count
                }
            }
        } catch {
            omissions.add("mcpConfiguration",
                          "floe.mcp.remoteServers.v1",
                          "invalidStoredConfiguration")
            warnings.append("mcpConfigurationUnavailable")
        }

        // Fill in exact counts + enforce the raw secret-key gate once more.
        for index in configs.indices {
            let url = configs[index].url
            let data: Data
            do { data = try Data(contentsOf: url) }
            catch { throw C07DataExchangeError.storageUnavailable("configRead") }
            guard C07ConfigSafety.validate(
                data, kind: configs[index].section.kind) else {
                throw C07DataExchangeError.credentialExcluded(
                    configs[index].section.entry)
            }
            let count: Int
            switch configs[index].section.kind {
            case .remoteHosts:
                count = (try? JSONDecoder().decode(
                    C07RemoteHostConfigDocument.self, from: data))?.hosts.count ?? 0
            case .rdpEndpoints:
                count = (try? JSONDecoder().decode(
                    C07RDPConfigDocument.self, from: data))?.endpoints.count ?? 0
            case .mailAccounts:
                count = (try? JSONDecoder().decode(
                    C07MailAccountConfigDocument.self, from: data))?.accounts.count ?? 0
            case .mcpServers:
                count = (try? JSONDecoder().decode(
                    C07MCPConfigDocument.self, from: data))?.servers.count ?? 0
            }
            let digest = try C07Digest.file(
                url, maximum: C07OwnedDataLimits.maximumConfigBytes)
            configs[index] = C07SourceConfigSection(
                section: C07OwnedConfigSection(
                    kind: configs[index].section.kind,
                    count: count, byteCount: digest.byteCount,
                    sha256: digest.sha256),
                url: url)
        }
        return warnings
    }

    private static func readRDPConfiguration(
        _ url: URL
    ) throws -> [C07RDPEndpointConfig] {
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= 256 * 1_024 else {
            throw C07DataExchangeError.storageUnavailable("rdpStore")
        }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw C07DataExchangeError.storageUnavailable("rdpStore") }
        guard data.count <= 256 * 1_024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? Int, version == 1,
              let rawEndpoints = object["endpoints"] as? [[String: Any]],
              rawEndpoints.count <= 4_096 else {
            throw C07DataExchangeError.invalidManifest("rdpStore")
        }
        var result: [C07RDPEndpointConfig] = []
        var seen = Set<UUID>()
        for raw in rawEndpoints {
            guard let profileText = raw["profileID"] as? String,
                  let profileID = UUID(uuidString: profileText),
                  let idText = raw["id"] as? String,
                  let id = UUID(uuidString: idText),
                  seen.insert(id).inserted,
                  let host = raw["host"] as? String, !host.isEmpty,
                  host.utf8.count <= 1_024,
                  let portNumber = raw["port"] as? NSNumber,
                  (1...65_535).contains(portNumber.intValue) else {
                throw C07DataExchangeError.invalidManifest("rdpEndpoint")
            }
            let hasLogin = (raw["passwordRef"] as? [String: Any]) != nil
            result.append(C07RDPEndpointConfig(
                profileID: profileID, id: id,
                displayName: String(((raw["displayName"] as? String) ?? "")
                    .prefix(512)),
                host: host,
                port: portNumber.intValue,
                username: String(((raw["username"] as? String) ?? "")
                    .prefix(512)),
                domain: String(((raw["domain"] as? String) ?? "")
                    .prefix(256)),
                hasLogin: hasLogin))
        }
        return result
    }

    // MARK: Tool results

    private static func captureToolResults(
        context: C07DataExchangeContext,
        captured: CapturedTables,
        workRoot: URL,
        omissions: inout C07OmissionCollector,
        counts: inout C07OwnedDataCounts,
        warnings: inout [String]
    ) async throws -> C07SourceToolResultSection? {
        guard !captured.conversationIDs.isEmpty else { return nil }
        let store = ToolResultCaptureStore.shared(
            durableRoot: context.toolResultsRoot, caps: .durableStandard)
        let output = try ToolResultLineWriter(directory: workRoot)
        var records = 0
        var totalBytes: Int64 = 0
        var excludedLegacy = 0
        var excludedNonDurable = 0
        var excludedUnreadable = 0
        for conversationID in captured.conversationIDs {
            if Task.isCancelled { throw C07DataExchangeError.cancelled }
            let export = await ToolResultBackupExchange.export(
                store: store, storeRoot: context.toolResultsRoot,
                conversationID: conversationID)
            excludedLegacy += export.excludedLegacyCalls
            excludedNonDurable += export.excludedNonDurable
            excludedUnreadable += export.excludedUnreadable
            for record in export.records {
                if records >= C07OwnedDataLimits.maximumToolResults {
                    throw C07DataExchangeError.tooManyEntries
                }
                let line = try ToolResultBackupRecord.encodeLine(record)
                totalBytes += Int64(line.count)
                guard totalBytes <= C07OwnedDataLimits.maximumToolResultTotalBytes else {
                    throw C07DataExchangeError.totalTooLarge
                }
                try output.append(line)
                records += 1
            }
            if export.excludedUnreadable > 0 {
                omissions.add("toolResultRecord", conversationID.uuidString,
                              "unreadableDurableRecord")
            }
            if export.excludedNonDurable > 0 {
                omissions.add("toolResultRecord", conversationID.uuidString,
                              "memoryOnlyNotCarried")
                warnings.append(
                    "toolResultMemoryOnly:\(conversationID.uuidString.prefix(8))")
            }
        }
        guard records > 0 else { return nil }
        let file = try output.finish(
            at: workRoot.appendingPathComponent(
                C07OwnedDataPolicy.toolResultsEntry))
        counts.toolResults = records
        if captured.toolCallCount > records {
            excludedLegacy = captured.toolCallCount - records
        }
        let section = C07OwnedToolResultSection(
            count: records, byteCount: file.byteCount, sha256: file.sha256,
            excludedLegacyCalls: excludedLegacy,
            excludedNonDurable: excludedNonDurable,
            excludedUnreadable: excludedUnreadable)
        try section.validate()
        return C07SourceToolResultSection(
            section: section,
            url: workRoot.appendingPathComponent(
                C07OwnedDataPolicy.toolResultsEntry))
    }

    // MARK: Small helpers

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

// MARK: - Artifact collection

/// Stages the exact bytes that will be copied into the archive. A staged copy
/// is what makes the canvas JSON and its parsed references the SAME bytes,
/// and it keeps a concurrent source change from producing a mixed snapshot:
/// a file that changes between digests fails the copy instead of silently
/// being carried twice.
private struct C07ArtifactCollector {
    let stagingRoot: URL
    private(set) var artifacts: [C07SourceArtifact] = []
    private var entries: [String: (sha256: String, byteCount: Int64)] = [:]
    private(set) var deduplicated = 0

    private func temporaryURL() -> URL {
        stagingRoot.appendingPathComponent(
            ".tmp-\(UUID().uuidString)", isDirectory: false)
    }

    private mutating func commit(_ temp: URL, entry: String,
                                 digest: (sha256: String, byteCount: Int64))
        throws -> URL
    {
        if artifacts.count >= C07OwnedDataLimits.maximumArtifacts {
            throw C07DataExchangeError.tooManyEntries
        }
        let key = C07Path.collisionKey(entry)
        if let existing = entries[key] {
            C07FileSystem.removeIfPresent(temp)
            guard existing.sha256 == digest.sha256,
                  existing.byteCount == digest.byteCount else {
                throw C07DataExchangeError.artifactCollision(entry)
            }
            deduplicated += 1
            throw C07ArtifactDuplicate()
        }
        entries[key] = digest
        let destination = stagingRoot.appendingPathComponent(entry)
        try C07FileSystem.ensureDirectory(destination.deletingLastPathComponent())
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            C07FileSystem.removeIfPresent(temp)
            throw C07DataExchangeError.artifactCollision(entry)
        }
        do { try FileManager.default.moveItem(at: temp, to: destination) }
        catch {
            C07FileSystem.removeIfPresent(temp)
            throw C07DataExchangeError.storageUnavailable("artifactStage")
        }
        return destination
    }

    mutating func appendData(
        _ data: Data, role: C07ArtifactRole, ownerID: UUID?,
        containerID: UUID?, logicalPath: String
    ) throws -> Bool {
        let entry = try C07ArtifactPath.entry(
            role: role, containerID: containerID, ownerID: ownerID,
            logicalPath: logicalPath)
        let digest = (sha256: C07Digest.sha256(data), byteCount: Int64(data.count))
        guard digest.byteCount <= C07OwnedDataLimits.maximumArtifactBytes else {
            throw C07DataExchangeError.entryTooLarge(entry)
        }
        let temp = temporaryURL()
        do { try data.write(to: temp) }
        catch { throw C07DataExchangeError.storageUnavailable("artifactStage") }
        do {
            let destination = try commit(temp, entry: entry, digest: digest)
            artifacts.append(C07SourceArtifact(
                record: C07ArtifactRecord(
                    role: role, ownerID: ownerID, containerID: containerID,
                    logicalPath: logicalPath, entry: entry,
                    byteCount: digest.byteCount, sha256: digest.sha256),
                url: destination))
            return true
        } catch is C07ArtifactDuplicate {
            return false
        }
    }

    mutating func appendFile(
        sourceRoot: URL, source: URL, role: C07ArtifactRole,
        ownerID: UUID?, containerID: UUID?, logicalPath: String,
        expectedSHA256: String?, expectedByteCount: Int64?
    ) throws -> Bool {
        let entry = try C07ArtifactPath.entry(
            role: role, containerID: containerID, ownerID: ownerID,
            logicalPath: logicalPath)
        guard C07FileSystem.isRegularFile(source) else {
            throw C07DataExchangeError.specialFileUnsupported(
                source.lastPathComponent)
        }
        // The stream is owned by the caller-fixed root: a symlink or
        // ancestor swap between enumeration and open is a typed refusal,
        // never a redirected read.
        let rootPath = sourceRoot.standardizedFileURL.path
        let sourcePath = source.standardizedFileURL.path
        guard sourcePath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/") else {
            throw C07DataExchangeError.unsafePath(sourcePath)
        }
        let sourceRelativePath = String(sourcePath.dropFirst(rootPath.count + (rootPath.hasSuffix("/") ? 0 : 1)))
        try C07Path.validateRelative(sourceRelativePath)
        let temp = temporaryURL()
        let copied: (sha256: String, byteCount: Int64)
        do {
            copied = try C07FileSystem.copyVerified(
                sourceRoot: sourceRoot,
                sourceRelativePath: sourceRelativePath,
                destinationRoot: stagingRoot,
                destinationRelativePath: temp.lastPathComponent,
                expectedSize: expectedByteCount,
                maximum: C07OwnedDataLimits.maximumArtifactBytes,
                createDestinationParents: false)
        } catch {
            C07FileSystem.removeIfPresent(temp)
            throw error
        }
        if let expectedSHA256, copied.sha256 != expectedSHA256 {
            C07FileSystem.removeIfPresent(temp)
            throw C07DataExchangeError.storageUnavailable("sourceChanged")
        }
        do {
            let destination = try commit(temp, entry: entry, digest: copied)
            artifacts.append(C07SourceArtifact(
                record: C07ArtifactRecord(
                    role: role, ownerID: ownerID, containerID: containerID,
                    logicalPath: logicalPath, entry: entry,
                    byteCount: copied.byteCount, sha256: copied.sha256),
                url: destination))
            return true
        } catch is C07ArtifactDuplicate {
            return false
        }
    }
}

private struct C07ArtifactDuplicate: Error {}

/// Exact, de-duplicated omission receipts. A repeated scope/subject is one
/// receipt, never an inflated count.
struct C07OmissionCollector {
    private(set) var items: [C07DataOmission] = []
    private var keys = Set<String>()
    var warnings: [String] {
        items.prefix(64).map { "omission:\($0.scope):\($0.reason)" }
    }

    mutating func add(_ scope: String, _ subject: String, _ reason: String) {
        add(C07DataOmission(scope: scope, subject: subject, reason: reason))
    }

    mutating func add(_ omission: C07DataOmission) {
        let key = "\(omission.scope)|\(omission.subject)"
        guard keys.insert(key).inserted else { return }
        guard items.count < C07OwnedDataLimits.maximumOmissions else { return }
        items.append(omission)
    }
}

/// Streaming line writer with a running SHA-256 (no whole-file buffering).
private final class ToolResultLineWriter {
    private let handle: FileHandle
    private let url: URL
    private var hasher = SHA256()
    private var count: Int64 = 0

    init(directory: URL) throws {
        try C07FileSystem.ensureDirectory(directory)
        url = directory.appendingPathComponent(
            ".tool-results-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw C07DataExchangeError.storageUnavailable("toolResultWrite")
        }
        do { handle = try FileHandle(forWritingTo: url) }
        catch { throw C07DataExchangeError.storageUnavailable("toolResultWrite") }
    }

    deinit { try? handle.close(); try? FileManager.default.removeItem(at: url) }

    func append(_ data: Data) throws {
        do { try handle.write(contentsOf: data) }
        catch { throw C07DataExchangeError.storageUnavailable("toolResultWrite") }
        hasher.update(data: data)
        count += Int64(data.count)
    }

    func finish(at destination: URL) throws -> (byteCount: Int64, sha256: String) {
        do {
            try handle.synchronize()
            try handle.close()
        } catch {
            throw C07DataExchangeError.storageUnavailable("toolResultWrite")
        }
        try C07FileSystem.ensureDirectory(destination.deletingLastPathComponent())
        do { try FileManager.default.moveItem(at: url, to: destination) }
        catch { throw C07DataExchangeError.storageUnavailable("toolResultWrite") }
        let sha = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (count, sha)
    }
}

enum ToolResultUTF8Fallback {
    static func prefix(_ text: String, maxBytes: Int) -> String {
        guard maxBytes > 0, text.utf8.count > maxBytes else { return text }
        var bytes = Array(text.utf8.prefix(maxBytes))
        while !bytes.isEmpty {
            if let value = String(bytes: bytes, encoding: .utf8) { return value }
            bytes.removeLast()
        }
        return ""
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
                   !policy.preservePrimary,
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

        // Archive-only configuration identities. No host/mail row, trust pin
        // or credential is recreated; the restored document is a read-only
        // recovery record with remapped ids.
        var remoteHostIDs: [String: String] = [:]
        var mailAccountIDs: [String: String] = [:]
        var mcpServerIDs: [String: String] = [:]
        var configEntries: [String] = []
        var mcpServersRowExisted: Bool?
        do {
            mcpServersRowExisted = (try await context.settingsStore.value(
                forKey: C07MCPConfigurationExchange.settingsKey)) != nil
        } catch {
            // Unknown absence must not authorize deleting the row on rollback.
            mcpServersRowExisted = nil
        }
        let orderedConfigs = staged.configs.sorted {
            configOrder($0.section.kind) < configOrder($1.section.kind)
        }
        for config in orderedConfigs {
            let data: Data
            do { data = try Data(contentsOf: config.url) }
            catch { throw C07DataExchangeError.storageUnavailable("configRead") }
            guard C07ConfigSafety.validate(
                data, kind: config.section.kind) else {
                throw C07DataExchangeError.credentialExcluded(
                    config.section.entry)
            }
            switch config.section.kind {
            case .mcpServers:
                let document: C07MCPConfigDocument
                do { document = try JSONDecoder().decode(
                    C07MCPConfigDocument.self, from: data) }
                catch { throw C07DataExchangeError.invalidManifest("mcpDecode") }
                try document.validate()
                guard document.servers.count == config.section.count else {
                    throw C07DataExchangeError.invalidManifest("mcpCount")
                }
                for server in document.servers {
                    let old = server.sourceID.uuidString
                    let new = UUID().uuidString
                    try mapping.insert(.mcpServer, old: old, new: new)
                    mcpServerIDs[old] = new
                }
                // The live merge happens in commitOwnedData; no read-only
                // config document is produced for MCP definitions.
                continue
            case .remoteHosts:
                let document: C07RemoteHostConfigDocument
                do { document = try JSONDecoder().decode(
                    C07RemoteHostConfigDocument.self, from: data) }
                catch { throw C07DataExchangeError.invalidManifest("remoteHostDecode") }
                try document.validate()
                guard document.hosts.count == config.section.count else {
                    throw C07DataExchangeError.invalidManifest("remoteHostCount")
                }
                for host in document.hosts {
                    let old = host.id.uuidString
                    let new = UUID().uuidString
                    try mapping.insert(.remoteHost, old: old, new: new)
                    remoteHostIDs[old] = new
                }
            case .rdpEndpoints:
                let document: C07RDPConfigDocument
                do { document = try JSONDecoder().decode(
                    C07RDPConfigDocument.self, from: data) }
                catch { throw C07DataExchangeError.invalidManifest("rdpDecode") }
                try document.validate()
                guard document.endpoints.count == config.section.count else {
                    throw C07DataExchangeError.invalidManifest("rdpCount")
                }
                for endpoint in document.endpoints
                where remoteHostIDs[endpoint.profileID.uuidString] == nil {
                    throw C07DataExchangeError.referenceMissing(
                        "rdpHostProfile:\(endpoint.profileID.uuidString)")
                }
            case .mailAccounts:
                let document: C07MailAccountConfigDocument
                do { document = try JSONDecoder().decode(
                    C07MailAccountConfigDocument.self, from: data) }
                catch { throw C07DataExchangeError.invalidManifest("mailDecode") }
                try document.validate()
                guard document.accounts.count == config.section.count else {
                    throw C07DataExchangeError.invalidManifest("mailCount")
                }
                for account in document.accounts {
                    let old = account.id.uuidString
                    let new = UUID().uuidString
                    try mapping.insert(.mailAccount, old: old, new: new)
                    mailAccountIDs[old] = new
                }
            }
            configEntries.append(config.section.entry)
        }
        if !configEntries.isEmpty {
            recordRoot(context.restoredConfigRoot.appendingPathComponent(
                restoreID.uuidString, isDirectory: true))
        }

        // Retained tool results: allocate the exact new run/call identities
        // and their derived refs before any capture happens. The durable plan
        // records the mapping for rollback and for the checkpoint rewrite.
        var toolResultEntries: [C07ToolResultPlanEntry] = []
        var toolResultTaskIDs: [UUID] = []
        var toolResultTaskSet = Set<UUID>()
        func mappedToolID(_ kind: C07IDKind, _ raw: String) -> String? {
            mapping.newID(kind, old: raw)
                ?? mapping.newID(kind, old: raw.lowercased())
                ?? mapping.newID(kind, old: raw.uppercased())
        }
        if let toolResults = staged.toolResults {
            try C07PlainJSONLines.readLines(
                toolResults.url, label: "toolResults",
                maximumRows: C07OwnedDataLimits.maximumToolResults,
                maximumRowBytes: C07OwnedDataLimits.maximumToolResultRowBytes
            ) { line in
                let record = try ToolResultBackupRecord.decodeLine(line)
                try record.validate()
                guard let newTaskText = mappedToolID(
                        .conversation, record.taskID.uuidString),
                      let newTask = UUID(uuidString: newTaskText) else {
                    throw C07DataExchangeError.referenceMissing(
                        "toolResultTask:\(record.taskID.uuidString)")
                }
                let newRunText = mappedToolID(
                    .run, record.runID.uuidString)
                    ?? mappedToolID(.childRun, record.runID.uuidString)
                guard let newRunText, let newRun = UUID(uuidString: newRunText) else {
                    throw C07DataExchangeError.referenceMissing(
                        "toolResultRun:\(record.runID.uuidString)")
                }
                let newCall: String
                if let mapped = mappedToolID(.toolCall, record.callID) {
                    newCall = mapped
                } else if UUID(uuidString: record.callID) != nil,
                          (mappedToolID(.childRun, record.runID.uuidString) != nil
                            || mappedToolID(.run, record.runID.uuidString) != nil) {
                    // A child entry or an App build that keeps call ids only
                    // in run_events has no tool_calls row. Allocated ids are
                    // inserted into the map so every JSON reference is
                    // rewritten to the same new identity.
                    let fresh = UUID().uuidString
                    try mapping.insert(.toolCall, old: record.callID,
                                       new: fresh)
                    newCall = fresh
                } else {
                    throw C07DataExchangeError.referenceMissing(
                        "toolResultCall:\(record.callID.prefix(16))")
                }
                let ref = ToolResultCaptureStore.reference(
                    runID: newRun, callID: newCall)
                toolResultEntries.append(C07ToolResultPlanEntry(
                    oldTaskID: record.taskID, oldRunID: record.runID,
                    oldCallID: record.callID, newTaskID: newTask,
                    newRunID: newRun, newCallID: newCall, newRef: ref,
                    byteCount: record.byteCount, sha256: record.sha256,
                    originalDigest: record.originalDigest,
                    retentionTruncated: record.retentionTruncated,
                    executionReportedTruncation:
                        record.executionReportedTruncation))
                if toolResultTaskSet.insert(newTask).inserted {
                    toolResultTaskIDs.append(newTask)
                }
            }
            for task in toolResultTaskIDs {
                recordRoot(context.toolResultsRoot.appendingPathComponent(
                    task.uuidString, isDirectory: true))
            }
        }

        // App-owned artifact destinations. Exact-path reuse is a legitimate
        // de-duplication only when the bytes match; a different file at the
        // same path is a collision. Capture files and opaque CAD bytes are
        // restored into read-only recovery roots, never into a live library.
        for artifact in staged.artifacts {
            switch artifact.record.role {
            case .appArtifact:
                let rewritten = C07IDRewrite.rewritePath(
                    artifact.record.logicalPath, mapping: mapping)
                guard appArtifactNamespacesContain(rewritten) else {
                    throw C07DataExchangeError.unsafePath(rewritten)
                }
                let destination = artifactRoot.appendingPathComponent(rewritten)
                if FileManager.default.fileExists(atPath: destination.path) {
                    guard let digest = try? C07Digest.file(destination),
                          digest.byteCount == artifact.record.byteCount,
                          digest.sha256 == artifact.record.sha256 else {
                        throw C07DataExchangeError.artifactCollision(rewritten)
                    }
                } else {
                    recordRoot(destination)
                }
            case .captureFile:
                let destination = context.restoredArtifactRoot
                    .appendingPathComponent(restoreID.uuidString, isDirectory: true)
                    .appendingPathComponent(artifact.record.logicalPath)
                if FileManager.default.fileExists(atPath: destination.path) {
                    throw C07DataExchangeError.artifactCollision(
                        artifact.record.logicalPath)
                }
                recordRoot(destination)
            case .canvasCADDraft, .canvasCADRevision, .canvasNativeCAD:
                guard let oldCanvas = artifact.record.containerID,
                      let newCanvas = mapping.newID(
                        .canvas, old: oldCanvas.uuidString) else {
                    throw C07DataExchangeError.referenceMissing("canvasCADOwner")
                }
                let kind: String
                switch artifact.record.role {
                case .canvasCADDraft: kind = "drafts"
                case .canvasCADRevision: kind = "revisions"
                default: kind = "native"
                }
                let destination = artifactRoot
                    .appendingPathComponent("CadPreserved", isDirectory: true)
                    .appendingPathComponent(newCanvas, isDirectory: true)
                    .appendingPathComponent(kind, isDirectory: true)
                    .appendingPathComponent(artifact.record.logicalPath)
                if FileManager.default.fileExists(atPath: destination.path) {
                    throw C07DataExchangeError.artifactCollision(
                        artifact.record.logicalPath)
                }
                recordRoot(destination)
            case .configuration:
                throw C07DataExchangeError.unsupportedFeature(
                    "configurationArtifact")
            default:
                break
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

        // C08 fresh restored Office document identities. The plan names every
        // new document and the ONE new App-owned restore directory BEFORE any
        // file is written; rollback removes only that exact directory.
        var officeDraftPlan: [C07OfficeDraftPlanEntry] = []
        if let drafts = staged.officeDrafts {
            try drafts.section.validate()
            try drafts.catalog.validate()
            guard drafts.catalog.records.count == drafts.section.count else {
                throw C07DataExchangeError.invalidManifest("officeDraftCount")
            }
            let restoreRoot = context.officeRestoredRoot.appendingPathComponent(
                restoreID.uuidString, isDirectory: true)
            if FileManager.default.fileExists(atPath: restoreRoot.path) {
                throw C07DataExchangeError.artifactCollision("officeDraftRoot")
            }
            var documented = Set<UUID>()
            for record in drafts.catalog.records {
                let documentID = UUID()
                guard documented.insert(documentID).inserted else {
                    throw C07DataExchangeError.duplicateIdentity("officeDraft")
                }
                officeDraftPlan.append(C07OfficeDraftPlanEntry(
                    documentID: documentID,
                    sourceEntry: record.entry,
                    displayName: record.displayName,
                    format: record.format,
                    kind: record.kind,
                    byteCount: record.byteCount,
                    sha256: record.sha256))
            }
            recordRoot(restoreRoot)
        }

        // Exact live-id collision check for every root identity.
        try await verifyNoRootCollisions(mapping: mapping)

        // Durable pre-restore snapshots for rollback-exact adapter merges:
        // the singleton model_preferences row and the exact set of
        // personalization cursor keys this restore is allowed to insert.
        let previousPreferences = try await context.database.reader { db in
            try Row.fetchOne(
                db, sql: "SELECT * FROM model_preferences WHERE id = 'default'"
            ).map { row in
                var values: C07DBRow = [:]
                for column in row.columnNames {
                    values[column] = C07UserDataAdapters.dbValue(row[column])
                }
                return values
            }
        }
        var cursorKeysToInsert: [String] = []
        let existingCursorKeys: Set<String> = try await context.database.reader { db in
            let rows = try Row.fetchAll(
                db, sql: "SELECT kind, workspace_key FROM personalization_update_cursors")
            return Set(rows.map { row in
                let kind = (row["kind"] as String?) ?? ""
                let key = (row["workspace_key"] as String?) ?? ""
                return "\(kind)|\(key)"
            })
        }
        if let cursorTable = staged.tables.first(where: {
            $0.record.name == "personalization_update_cursors"
        }) {
            try C07RowStream.rows(
                in: cursorTable.url, table: "personalization_update_cursors"
            ) { row in
                guard let kind = row["kind"]?.stringValue, !kind.isEmpty else {
                    return
                }
                let oldWorkspace = row["workspace_id"]?.stringValue
                let newWorkspace = oldWorkspace.flatMap {
                    mapping.newID(.workspace, old: $0)
                }
                let key = "\(kind)|\(newWorkspace ?? "")"
                if !existingCursorKeys.contains(key) {
                    cursorKeysToInsert.append(key)
                }
            }
        }

        let plan = C07OwnedDataRestorePlanFile(
            restoreID: restoreID,
            idMap: mapping,
            artifactRoots: artifactRoots,
            attachmentPaths: attachmentPaths,
            workspaceIDs: createdWorkspaceIDs,
            environmentIDs: environmentIDs.isEmpty ? nil : environmentIDs,
            environmentIdentityMap: environmentIdentityMap.isEmpty
                ? nil : environmentIdentityMap,
            toolResultEntries: toolResultEntries.isEmpty
                ? nil : toolResultEntries,
            toolResultTaskIDs: toolResultTaskIDs.isEmpty
                ? nil : toolResultTaskIDs,
            remoteHostIDs: remoteHostIDs.isEmpty ? nil : remoteHostIDs,
            mailAccountIDs: mailAccountIDs.isEmpty ? nil : mailAccountIDs,
            configEntries: configEntries.isEmpty ? nil : configEntries,
            mcpServerIDs: mcpServerIDs.isEmpty ? nil : mcpServerIDs,
            mcpServersRowExisted: mcpServerIDs.isEmpty
                ? nil : mcpServersRowExisted,
            previousModelPreferences: previousPreferences,
            personalizationCursorKeys: cursorKeysToInsert.isEmpty
                ? nil : Array(Set(cursorKeysToInsert)).sorted(),
            officeDrafts: officeDraftPlan.isEmpty ? nil : officeDraftPlan,
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
            ("calendar_todos", "id", .todo),
            ("providers", "id", .provider),
            ("models", "id", .model),
        ]
        try await context.database.reader { db in
            for (table, column, kind) in checks {
                guard try db.tableExists(table) else { continue }
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
        var appArtifacts = 0
        var captureFiles = 0
        var cadPreservedFiles = 0
        var toolResults = 0
        var configSections = 0

        func noteCreated(_ url: URL) {
            let path = url.standardizedFileURL.path
            if !createdRoots.contains(path) { createdRoots.append(path) }
        }

        func copyFile(_ source: URL, to destination: URL, under root: URL,
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
            // Destination containment is re-derived from the trusted root;
            // the stream itself is descriptor-relative and no-follow, so an
            // archive-supplied logical path can never redirect the write
            // through a planted symlink ancestor.
            let rootPath = root.standardizedFileURL.path
            let destinationPath = destination.standardizedFileURL.path
            guard destinationPath.hasPrefix(rootPath + "/") else {
                throw C07DataExchangeError.unsafePath(destinationPath)
            }
            let relative = String(destinationPath.dropFirst(rootPath.count + 1))
            try C07Path.validateRelative(relative)
            try C07FileSystem.copyVerified(
                sourceRoot: source.deletingLastPathComponent(),
                sourceRelativePath: source.lastPathComponent,
                destinationRoot: root,
                destinationRelativePath: relative,
                expectedSize: record.byteCount,
                maximum: C07OwnedDataLimits.maximumArtifactBytes,
                mode: record.mode ?? 0o600,
                createDestinationParents: true)
            noteCreated(destination)
            return true
        }

        func writeData(_ data: Data, to destination: URL, under root: URL,
                       mode: Int) throws {
            let rootPath = root.standardizedFileURL.path
            let destinationPath = destination.standardizedFileURL.path
            guard destinationPath.hasPrefix(rootPath + "/") else {
                throw C07DataExchangeError.unsafePath(destinationPath)
            }
            let relative = String(destinationPath.dropFirst(rootPath.count + 1))
            try C07Path.validateRelative(relative)
            try C07RootedFileIO.writeFile(
                data, destinationRoot: root,
                destinationRelativePath: relative,
                mode: mode,
                createDestinationParents: true)
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
            try writeData(rewritten, to: destination, under: canvasesRoot,
                          mode: 0o600)
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
            try writeData(rewritten, to: destination, under: mediaProjectsRoot,
                          mode: 0o600)
            noteCreated(destination)
            mediaProjects += 1
        }

        for artifact in staged.artifacts where artifact.record.role == .canvasMaterial {
            guard let canvasOwner = artifact.record.containerID else { continue }
            let map = materialMap(for: canvasOwner)
            let newName = map[artifact.record.logicalPath] ?? artifact.record.logicalPath
            let destination = materialsRoot.appendingPathComponent(newName)
            _ = try copyFile(artifact.url, to: destination,
                             under: materialsRoot, record: artifact.record)
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
            let assetRoot = artifact.record.logicalPath.hasPrefix("WorkbenchRoot/")
                ? artifactRoot
                : workbenchRoot.appendingPathComponent(newText, isDirectory: true)
            _ = try copyFile(artifact.url, to: destination,
                             under: assetRoot, record: artifact.record)
            mediaAssets += 1
        }

        for artifact in staged.artifacts where artifact.record.role == .canvasNodeAsset {
            let rewritten = C07IDRewrite.rewritePath(
                artifact.record.logicalPath, mapping: plan.idMap)
            let destination = artifactRoot.appendingPathComponent(rewritten)
            _ = try copyFile(artifact.url, to: destination,
                             under: artifactRoot, record: artifact.record)
        }

        for artifact in staged.artifacts where artifact.record.role == .attachment {
            guard let oldID = artifact.record.ownerID,
                  let relative = plan.attachmentPaths[oldID.uuidString] else {
                throw C07DataExchangeError.referenceMissing("attachmentPath")
            }
            let destination = attachmentsRoot.appendingPathComponent(relative)
            _ = try copyFile(artifact.url, to: destination,
                             under: attachmentsRoot, record: artifact.record)
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
            _ = try copyFile(artifact.url, to: destination,
                             under: privateTasksRoot, record: artifact.record)
            privateTaskFiles += 1
        }

        for artifact in staged.artifacts where artifact.record.role == .mailReceipt {
            let destination = mailReceiptRoot
                .appendingPathComponent(artifact.record.logicalPath)
            _ = try copyFile(artifact.url, to: destination,
                             under: mailReceiptRoot, record: artifact.record)
            mailReceipts += 1
        }

        // Durable app-owned artifact namespaces. RunOutputs paths carry a
        // run UUID and are remapped; every destination is re-contained.
        for artifact in staged.artifacts where artifact.record.role == .appArtifact {
            let rewritten = C07IDRewrite.rewritePath(
                artifact.record.logicalPath, mapping: plan.idMap)
            guard appArtifactNamespacesContain(rewritten) else {
                throw C07DataExchangeError.unsafePath(rewritten)
            }
            let destination = artifactRoot.appendingPathComponent(rewritten)
            _ = try copyFile(artifact.url, to: destination,
                             under: artifactRoot, record: artifact.record)
            appArtifacts += 1
        }

        // User-owned capture files are recovered read-only, never injected
        // into the live capture library.
        for artifact in staged.artifacts where artifact.record.role == .captureFile {
            let destination = context.restoredArtifactRoot
                .appendingPathComponent(plan.restoreID.uuidString,
                                        isDirectory: true)
                .appendingPathComponent(artifact.record.logicalPath)
            _ = try copyFile(artifact.url, to: destination,
                             under: context.restoredArtifactRoot,
                             record: artifact.record)
            captureFiles += 1
        }

        // Opaque donor CAD sections: preserved read-only. Android has no CAD
        // editing kernel and never pretends these bytes are editable.
        for artifact in staged.artifacts where
            artifact.record.role == .canvasCADDraft
                || artifact.record.role == .canvasCADRevision
                || artifact.record.role == .canvasNativeCAD {
            guard let oldCanvas = artifact.record.containerID,
                  let newCanvas = plan.idMap.newID(
                    .canvas, old: oldCanvas.uuidString) else {
                throw C07DataExchangeError.referenceMissing("canvasCADOwner")
            }
            let kind: String
            switch artifact.record.role {
            case .canvasCADDraft: kind = "drafts"
            case .canvasCADRevision: kind = "revisions"
            default: kind = "native"
            }
            let destination = context.cadPreservedRoot
                .appendingPathComponent(newCanvas, isDirectory: true)
                .appendingPathComponent(kind, isDirectory: true)
                .appendingPathComponent(artifact.record.logicalPath)
            var readOnly = artifact.record
            readOnly.mode = 0o444
            _ = try copyFile(artifact.url, to: destination,
                             under: context.cadPreservedRoot, record: readOnly)
            cadPreservedFiles += 1
        }

        // Retained tool results: recreate them through the REAL result
        // engine under the plan's new identities and verify a read-back.
        if let entries = plan.toolResultEntries, !entries.isEmpty {
            guard let toolResultsSection = staged.toolResults else {
                throw C07DataExchangeError.invalidManifest("toolResultsMissing")
            }
            var byTask: [UUID: [(C07ToolResultPlanEntry, ToolResultBackupRecord)]] = [:]
            var index: [String: C07ToolResultPlanEntry] = [:]
            for entry in entries {
                index["\(entry.oldRunID.uuidString)|\(entry.oldCallID)"] = entry
            }
            var seen = Set<String>()
            try C07PlainJSONLines.readLines(
                toolResultsSection.url, label: "toolResults",
                maximumRows: C07OwnedDataLimits.maximumToolResults,
                maximumRowBytes: C07OwnedDataLimits.maximumToolResultRowBytes
            ) { line in
                let record = try ToolResultBackupRecord.decodeLine(line)
                try record.validate()
                let key = "\(record.runID.uuidString)|\(record.callID)"
                guard let entry = index[key] else {
                    throw C07DataExchangeError.referenceMissing("toolResultPlan")
                }
                guard seen.insert(key).inserted else {
                    throw C07DataExchangeError.duplicateIdentity("toolResultPlan")
                }
                byTask[entry.newTaskID, default: []].append((entry, record))
            }
            guard seen.count == entries.count else {
                throw C07DataExchangeError.referenceMissing("toolResultPlanCount")
            }
            let store = ToolResultCaptureStore.shared(
                durableRoot: context.toolResultsRoot, caps: .durableStandard)
            for (taskID, pairs) in byTask.sorted(by: {
                $0.key.uuidString < $1.key.uuidString
            }) {
                var runMap: [UUID: UUID] = [:]
                var callMap: [String: String] = [:]
                for (entry, _) in pairs {
                    runMap[entry.oldRunID] = entry.newRunID
                    callMap[entry.oldCallID] = entry.newCallID
                }
                let restored = try await ToolResultBackupExchange.restore(
                    records: pairs.map(\.1), store: store,
                    destinationTaskID: taskID,
                    runMap: runMap, callMap: callMap)
                let verified = try await ToolResultBackupExchange.verifyReadback(
                    receipts: restored, store: store,
                    conversationID: taskID)
                guard verified.count == pairs.count else {
                    throw C07DataExchangeError.storageUnavailable(
                        "toolResultVerify")
                }
                for receipt in verified {
                    guard let entry = pairs.first(where: {
                        $0.0.newCallID == receipt.callID
                    })?.0,
                          entry.newRef == receipt.ref,
                          entry.sha256 == receipt.sha256 else {
                        throw C07DataExchangeError.storageUnavailable(
                            "toolResultIdentity")
                    }
                }
                noteCreated(context.toolResultsRoot.appendingPathComponent(
                    taskID.uuidString, isDirectory: true))
                toolResults += verified.count
            }
        }

        // Non-secret configuration recovery record. Hosts/mail identities are
        // remapped; credential refs and trust pins are absent. The document
        // is read-only and never applied to a live authorization table.
        if let configEntries = plan.configEntries, !configEntries.isEmpty {
            let destinationRoot = context.restoredConfigRoot
                .appendingPathComponent(plan.restoreID.uuidString,
                                        isDirectory: true)
            try ensureOwnedDirectory(destinationRoot)
            for config in staged.configs {
                let data: Data
                do { data = try Data(contentsOf: config.url) }
                catch { throw C07DataExchangeError.storageUnavailable("configRead") }
                guard C07ConfigSafety.validate(
                    data, kind: config.section.kind) else {
                    throw C07DataExchangeError.credentialExcluded(
                        config.section.entry)
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let output: Data
                switch config.section.kind {
                case .mcpServers:
                    // Live definitions are merged into the original store by
                    // commitOwnedData; an orphaned read-only copy is not the
                    // restore consumer.
                    continue
                case .remoteHosts:
                    let document = try JSONDecoder().decode(
                        C07RemoteHostConfigDocument.self, from: data)
                    var hosts: [C07RemoteHostConfig] = []
                    for host in document.hosts {
                        guard let newText = plan.remoteHostIDs?[
                            host.id.uuidString] else {
                            throw C07DataExchangeError.referenceMissing(
                                "remoteHostIdentity")
                        }
                        var copy = host
                        copy.id = UUID(uuidString: newText) ?? host.id
                        hosts.append(copy)
                    }
                    do { output = try encoder.encode(
                        C07RemoteHostConfigDocument(hosts: hosts)) }
                    catch { throw C07DataExchangeError.storageUnavailable("hostEncode") }
                case .rdpEndpoints:
                    let document = try JSONDecoder().decode(
                        C07RDPConfigDocument.self, from: data)
                    var endpoints: [C07RDPEndpointConfig] = []
                    for endpoint in document.endpoints {
                        guard let newProfile = plan.remoteHostIDs?[
                            endpoint.profileID.uuidString] else {
                            throw C07DataExchangeError.referenceMissing(
                                "rdpHostIdentity")
                        }
                        var copy = endpoint
                        copy.profileID = UUID(uuidString: newProfile)
                            ?? endpoint.profileID
                        copy.id = UUID(uuidString: C07IDDerivation.fresh(
                            restoreID: plan.restoreID, table: "rdpEndpoint",
                            old: endpoint.id.uuidString)) ?? endpoint.id
                        endpoints.append(copy)
                    }
                    do { output = try encoder.encode(
                        C07RDPConfigDocument(endpoints: endpoints)) }
                    catch { throw C07DataExchangeError.storageUnavailable("rdpEncode") }
                case .mailAccounts:
                    let document = try JSONDecoder().decode(
                        C07MailAccountConfigDocument.self, from: data)
                    var accounts: [C07MailAccountConfig] = []
                    for account in document.accounts {
                        guard let newText = plan.mailAccountIDs?[
                            account.id.uuidString] else {
                            throw C07DataExchangeError.referenceMissing(
                                "mailAccountIdentity")
                        }
                        var copy = account
                        copy.id = UUID(uuidString: newText) ?? account.id
                        accounts.append(copy)
                    }
                    do { output = try encoder.encode(
                        C07MailAccountConfigDocument(accounts: accounts)) }
                    catch { throw C07DataExchangeError.storageUnavailable("mailEncode") }
                }
                let destination = destinationRoot.appendingPathComponent(
                    "\(config.section.kind.rawValue).json")
                try writeData(output, to: destination, under: destinationRoot,
                              mode: 0o444)
                noteCreated(destination)
                configSections += 1
            }
            // Exact recovery receipt: source->new identity and the explicit
            // "re-authenticate / fresh trust" requirement.
            let receipt: [String: Any] = [
                "format": "floe.restoredconfig",
                "formatVersion": 1,
                "remoteHostIDs": plan.remoteHostIDs ?? [:],
                "mailAccountIDs": plan.mailAccountIDs ?? [:],
                "requiresReauthentication": true,
                "requiresFreshTrust": true,
                "sections": configEntries.sorted(),
            ]
            if let data = try? JSONSerialization.data(
                withJSONObject: receipt, options: [.sortedKeys]) {
                let url = destinationRoot.appendingPathComponent(
                    "restore-manifest.json")
                try writeData(data, to: url, under: destinationRoot, mode: 0o444)
                noteCreated(url)
            }
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

        // C08 retained Office recovery content: fresh App-owned files and a
        // fresh manifest below the ONE restore directory already named by the
        // durable plan. Nothing old (journal/session/grant/URI) is restored.
        let officeDrafts = try C08OfficeDraftExchange.commitRestoredDocuments(
            entries: plan.officeDrafts ?? [],
            staged: staged.officeDrafts,
            restoreRoot: context.officeRestoredRoot.appendingPathComponent(
                plan.restoreID.uuidString, isDirectory: true),
            restoreID: plan.restoreID)
        if !officeDrafts.roots.isEmpty {
            for root in officeDrafts.roots { noteCreated(root) }
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
            appArtifacts: appArtifacts,
            captureFiles: captureFiles,
            cadPreservedFiles: cadPreservedFiles,
            toolResults: toolResults,
            configSections: configSections,
            officeDrafts: officeDrafts.count,
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

        // Decode the typed MCP section before the writer transaction. The
        // merge itself reads the CURRENT settings row inside that transaction
        // so a concurrent local edit is preserved.
        var mcpDefinitions: [C07MCPServerDefinition] = []
        if let section = staged.configs.first(where: {
            $0.section.kind == .mcpServers
        }) {
            let data: Data
            do { data = try Data(contentsOf: section.url) }
            catch { throw C07DataExchangeError.storageUnavailable("mcpRead") }
            guard let document = try? JSONDecoder().decode(
                C07MCPConfigDocument.self, from: data) else {
                throw C07DataExchangeError.invalidManifest("mcpDecode")
            }
            try document.validate()
            guard document.servers.count == section.section.count else {
                throw C07DataExchangeError.invalidManifest("mcpCount")
            }
            mcpDefinitions = document.servers
        }

        let definitionsToRestore = mcpDefinitions
        let outcome: (C07OwnedDataCommitReceipt, [String])
        outcome = try await context.database.writer {
            db -> (C07OwnedDataCommitReceipt, [String]) in
            var warnings = plan.warnings
            var receipt = C07OwnedDataCommitReceipt()
            // 0. MCP definitions: fresh IDs, disabled, unbound. This is the
            //    ORIGINAL `floe.mcp.remoteServers.v1` row, never a parallel
            //    store. Only the exact inserted definitions change.
            if !definitionsToRestore.isEmpty {
                guard let identities = plan.mcpServerIDs,
                      identities.count == definitionsToRestore.count else {
                    throw C07DataExchangeError.referenceMissing(
                        "mcpServerIdentities")
                }
                let key = C07MCPConfigurationExchange.settingsKey
                let currentRaw = try String.fetchOne(
                    db,
                    sql: "SELECT value_json FROM app_settings WHERE key = ?",
                    arguments: [key])
                let merged = try C07MCPConfigurationExchange.merge(
                    currentRaw: currentRaw,
                    definitions: definitionsToRestore,
                    newIDs: identities)
                guard let newRaw = merged.raw else {
                    throw C07DataExchangeError.invalidManifest("mcpMerge")
                }
                try db.execute(
                    sql: """
                        INSERT INTO app_settings (key, value_json, updated_at)
                        VALUES (?, ?, ?)
                        ON CONFLICT(key) DO UPDATE SET
                            value_json = excluded.value_json,
                            updated_at = excluded.updated_at
                        """,
                    arguments: [key, newRaw, now])
                receipt.mcpDefinitions = definitionsToRestore.count
                if definitionsToRestore.contains(where: {
                    $0.requiresEndpointReconfiguration
                }) {
                    warnings.append("mcpDefinitionEndpointSanitized")
                }
                if definitionsToRestore.contains(where: {
                    $0.transport == .stdio
                }) {
                    warnings.append("mcpDefinitionsRequireEnvironmentBinding")
                }
                if definitionsToRestore.contains(where: {
                    $0.authentication != "none"
                }) {
                    warnings.append("mcpDefinitionsRequireCredentials")
                }
            }
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
                guard policy.requiredColumns(
                    at: staged.manifest.sourceAppSchemaVersion)
                    .isSubset(of: schemaColumns) else {
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
                    } else if policy.preservePrimary {
                        // Singleton/preference rows keep their fixed key
                        // verbatim ('default', personalization kind); it is
                        // structural identity, not a remappable id.
                        values[policy.primaryColumn] = row[policy.primaryColumn]
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
                    // tool_calls keeps a plain-text output summary on some
                    // builds; rewrite its structured ref to the new identity.
                    if table.record.name == "tool_calls",
                       let summary = values["output_summary"]?.stringValue {
                        values["output_summary"] = .string(
                            C07ToolResultReceipt.rewriteSummary(
                                summary,
                                oldRunID: row["run_id"]?.stringValue,
                                oldCallID: oldPrimary,
                                entries: plan.toolResultEntries ?? []))
                    }
                    // Tool-result checkpoint summaries: replace the OLD
                    // capture ref with the restored ref (or an explicit
                    // unavailable marker) before the generic UUID rewrite.
                    if values["kind"]?.stringValue == "toolResult",
                       let payload = values["payload_json"]?.stringValue,
                       table.record.name == "run_events"
                        || table.record.name == "child_run_entries" {
                        let oldRun = table.record.name == "child_run_entries"
                            ? row["child_run_id"]?.stringValue
                            : row["run_id"]?.stringValue
                        values["payload_json"] = .string(
                            try C07ToolResultReceipt.rewrite(
                                payload, oldRunID: oldRun, oldCallID: nil,
                                entries: plan.toolResultEntries ?? []))
                    }
                    for column in policy.jsonIDColumns {
                        if let value = values[column] {
                            values[column] = try C07IDRewrite.rewriteJSONColumn(
                                value, mapping: plan.idMap)
                        }
                    }
                    // User-data rows with target-dependent commit semantics
                    // (singleton merges, revision renumbering, name-conflict
                    // rules) are committed by the adapter inside this same
                    // writer transaction, after the identical normalization
                    // and reference mapping as every other live row.
                    if C07UserDataAdapters.isAdapterOwned(table.record.name) {
                        try C07UserDataAdapters.commitRow(
                            table: table.record.name, values: values,
                            restoreID: plan.restoreID, db: db,
                            receipt: &receipt, warnings: &warnings)
                        rowsInserted += 1
                        return
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
                if !C07UserDataAdapters.isAdapterOwned(table.record.name) {
                    updateReceipt(table: table.record.name, rows: rowsInserted,
                                  receipt: &receipt)
                }
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
        let declaredPartial = (staged.manifest.completeness
            ?? ((staged.manifest.omissions?.isEmpty == false)
                ? .partial : .complete)) == .partial
        receipt.partial = declaredPartial
        receipt.omissions = staged.manifest.omissions?.count ?? 0
        if receipt.partial {
            receipt.warnings.append("restorePartialPackage")
        }
        if let entries = plan.officeDrafts, !entries.isEmpty {
            try C08OfficeDraftExchange.markRestoreCommitted(
                restoreRoot: context.officeRestoredRoot.appendingPathComponent(
                    plan.restoreID.uuidString, isDirectory: true),
                restoreID: plan.restoreID)
        }
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
        case "calendar_todos": receipt.todos = rows
        case "providers": receipt.providers = rows
        case "models": receipt.models = rows
        case "memory_entries": receipt.memoryEntries = rows
        case "memory_candidates": receipt.memoryCandidates = rows
        case "task_checklist_revisions": receipt.checklistRevisions = rows
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
        let todos = map.allNewIDs(.todo)
        let memoryEntries = map.allNewIDs(.memoryEntry)
        let memoryCandidates = map.allNewIDs(.memoryCandidate)
        let personalizationDocuments = map.allNewIDs(.personalizationDocument)
        let skills = map.allNewIDs(.skill)

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
            if try db.tableExists("calendar_todos") {
                for chunk in todos.chunked(max: 400) {
                    try c07DeleteWhereIn(db, table: "calendar_todos",
                                         column: "id", values: chunk)
                }
            }
            // Expanded user-data rows: exact new identities only. Rows whose
            // owner conversation/workspace is also restored were already
            // removed by the cascades above; these chunked deletes cover the
            // detached (origin-only) rows and the reference-only tables.
            if try db.tableExists("memory_entries") {
                for chunk in memoryEntries.chunked(max: 400) {
                    try c07DeleteWhereIn(db, table: "memory_entries",
                                         column: "id", values: chunk)
                }
            }
            if try db.tableExists("memory_candidates") {
                for chunk in memoryCandidates.chunked(max: 400) {
                    try c07DeleteWhereIn(db, table: "memory_candidates",
                                         column: "id", values: chunk)
                }
            }
            if try db.tableExists("personalization_documents") {
                for chunk in personalizationDocuments.chunked(max: 400) {
                    try c07DeleteWhereIn(db, table: "personalization_documents",
                                         column: "id", values: chunk)
                }
            }
            if try db.tableExists("skills") {
                for chunk in skills.chunked(max: 400) {
                    try c07DeleteWhereIn(db, table: "skills",
                                         column: "id", values: chunk)
                }
            }
            // Adapter merges: restore the exact pre-restore singleton
            // preferences, or remove the row this restore created.
            if try db.tableExists("model_preferences") {
                if let previous = plan.previousModelPreferences {
                    try db.execute(
                        sql: "DELETE FROM model_preferences WHERE id = 'default'")
                    try C07UserDataAdapters.insert(
                        "model_preferences", previous, into: db)
                } else if (plan.counts.modelPreferences ?? 0) > 0 {
                    try db.execute(
                        sql: "DELETE FROM model_preferences WHERE id = 'default'")
                }
            }
            if try db.tableExists("personalization_update_cursors"),
               let keys = plan.personalizationCursorKeys {
                for raw in keys {
                    let parts = raw.split(
                        separator: "|", maxSplits: 1,
                        omittingEmptySubsequences: false).map(String.init)
                    guard parts.count == 2 else { continue }
                    try db.execute(
                        sql: """
                            DELETE FROM personalization_update_cursors
                            WHERE kind = ? AND workspace_key = ?
                            """,
                        arguments: [parts[0], parts[1]])
                }
            }
            // MCP definitions: remove exactly the fresh IDs this restore
            // inserted. A concurrent local server remains untouched. The
            // row is deleted only when it did not exist before the restore
            // and nothing else remains.
            if let rawIDs = plan.mcpServerIDs, !rawIDs.isEmpty {
                let ids = Set(rawIDs.values.compactMap { UUID(uuidString: $0) })
                let key = C07MCPConfigurationExchange.settingsKey
                let currentRaw = try String.fetchOne(
                    db,
                    sql: "SELECT value_json FROM app_settings WHERE key = ?",
                    arguments: [key])
                let removed: String?
                do {
                    removed = try C07MCPConfigurationExchange.removing(
                        ids: ids,
                        fromRaw: currentRaw,
                        removeRowWhenEmpty: plan.mcpServersRowExisted == false)
                } catch {
                    throw C07DataExchangeError.rollbackFailed(
                        "mcpServerRollback")
                }
                if let removed {
                    try db.execute(
                        sql: """
                            INSERT INTO app_settings (key, value_json, updated_at)
                            VALUES (?, ?, ?)
                            ON CONFLICT(key) DO UPDATE SET
                                value_json = excluded.value_json,
                                updated_at = excluded.updated_at
                            """,
                        arguments: [key, removed, c07DateString(Date())])
                } else if currentRaw != nil {
                    try db.execute(
                        sql: "DELETE FROM app_settings WHERE key = ?",
                        arguments: [key])
                }
            }
        }

        // Exact artifact roots only. Each path must sit under one of the
        // app-private roots that this restore may create.
        var allowed = [
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
            context.toolResultsRoot.path,
            context.restoredConfigRoot.path,
            context.restoredArtifactRoot.path,
            context.cadPreservedRoot.path,
            context.officeRestoredRoot.path,
        ]
        for namespace in C07OwnedDataSource.appArtifactNamespaces {
            allowed.append(context.artifactRoot.appendingPathComponent(
                namespace).path)
        }
        if let taskIDs = plan.toolResultTaskIDs, !taskIDs.isEmpty {
            let store = ToolResultCaptureStore.shared(
                durableRoot: context.toolResultsRoot, caps: .durableStandard)
            _ = await ToolResultBackupExchange.rollback(
                conversationIDs: taskIDs, store: store)
        }
        // Deepest first: a listed directory that contains another listed path
        // must not be removed before the child.
        let orderedRoots = plan.artifactRoots.sorted {
            $0.split(separator: "/").count > $1.split(separator: "/").count
        }
        for raw in orderedRoots {
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

func configOrder(_ kind: C07OwnedConfigKind) -> Int {
    switch kind {
    case .remoteHosts: return 0
    case .mailAccounts: return 1
    case .rdpEndpoints: return 2
    case .mcpServers: return 3
    }
}

func appArtifactNamespacesContain(_ logicalPath: String) -> Bool {
    let components = logicalPath.split(separator: "/", omittingEmptySubsequences: false)
    guard let first = components.first else { return false }
    return C07OwnedDataSource.appArtifactNamespaces.contains(String(first))
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
                let copiedDocument = try C07FileSystem.copyVerified(
                    sourceRoot: uploadURL.deletingLastPathComponent(),
                    sourceRelativePath: uploadURL.lastPathComponent,
                    destinationRoot: planRoot,
                    destinationRelativePath: stagedURL.lastPathComponent,
                    expectedSize: validated.byteCount)
                guard copiedDocument.sha256 == validated.sha256 else {
                    throw C07DataExchangeError.documentPackage("sourceChangedDuringCopy")
                }
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
        // Opaque donor CAD sections are preserved read-only. Android cannot
        // edit them, but refusing them (the previous behavior) silently lost
        // user data from an otherwise valid donor package.
        var cadWarnings: [String] = []
        for file in staged.preservedCAD where file.kind == .native
            && file.logicalPath.hasSuffix("/manifest.json") {
            // Reuse the C04 read-only native package contract for a bounded
            // sanity check. A malformed package is still preserved byte for
            // byte; the warning only prevents presenting it as editable.
            if let data = try? Data(contentsOf: file.url),
               (try? C04FloecadPackage.parseManifest(data)) == nil {
                cadWarnings.append("canvasCADNativeUnreadable")
            }
        }
        for file in staged.preservedCAD {
            let role: C07ArtifactRole
            switch file.kind {
            case .draftDescriptor, .draftDrawing: role = .canvasCADDraft
            case .revision: role = .canvasCADRevision
            case .native: role = .canvasNativeCAD
            }
            try add(role: role, ownerID: nil,
                    containerID: manifest.canvasID,
                    logicalPath: file.logicalPath, url: file.url,
                    byteCount: file.byteCount, sha256: file.sha256)
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
            } + (staged.manifest.missingCADRevisionAssets ?? []).map {
                "canvasCADRevisionMissing:\($0.prefix(40))"
            } + (staged.manifest.missingNativeCADPackages ?? []).map {
                "canvasNativeCADMissing:\($0.prefix(40))"
            } + (staged.preservedCAD.isEmpty ? [] : ["canvasCADPreservedReadOnly"])
              + cadWarnings,
            totalBytes: staged.totalBytes)
    }
}
