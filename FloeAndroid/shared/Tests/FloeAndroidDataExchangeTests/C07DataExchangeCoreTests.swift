// SPDX-License-Identifier: MPL-2.0
//
// C07 authored host tests. These run against the real ZIPFoundation archive
// writer/reader and real temporary files; no App, device, SAF provider, live
// database, credential, cloud service or model is touched.
import XCTest
import Foundation
import ZIPFoundation
import FloeNotes
@testable import FloeAndroidDataExchange

final class C07DataExchangeCoreTests: XCTestCase {
    private final class Fixture {
        let root: URL
        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("c07-exchange-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func write(_ path: String, _ data: Data) throws -> URL {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            return url
        }
        func project(_ id: UUID, files: [String: String]) throws -> URL {
            let dir = root.appendingPathComponent("projects/\(id.uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (path, value) in files {
                let url = dir.appendingPathComponent(path)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(value.utf8).write(to: url)
            }
            return dir
        }
        func destination(_ name: String) -> URL {
            root.appendingPathComponent(name)
        }
    }

    // MARK: - Fake sink

    private final class FakeSink: C07RestoreSink, @unchecked Sendable {
        struct State {
            var calls: [String] = []
            var projects: [String: UUID] = [:]
            var projectMarkers: [String] = []
            var notebooks: [UUID: String] = [:]
            var notes: [UUID] = []
            var settings: [String: String] = [:]
            var failWrite = false
            var existingSettings: Set<String> = []
        }
        private let lock = NSLock()
        private var storage = State()

        var state: State {
            lock.lock(); defer { lock.unlock() }
            return storage
        }

        func setFailWrite(_ value: Bool) {
            lock.lock(); storage.failWrite = value; lock.unlock()
        }
        func setExistingSetting(_ key: String) {
            lock.lock(); storage.existingSettings.insert(key); lock.unlock()
        }

        func createProject(markerName: String, origin: C07ProjectOrigin) async throws -> UUID {
            lock.lock(); defer { lock.unlock() }
            let id = UUID()
            storage.calls.append("createProject:\(origin.rawValue)")
            storage.projects[markerName] = id
            storage.projectMarkers.append(markerName)
            return id
        }

        func renameProject(id: UUID, to finalName: String) async throws {
            lock.lock(); storage.calls.append("renameProject:\(finalName)"); lock.unlock()
        }

        func writeProjectFiles(projectID: UUID,
                               directories: [String],
                               files: [C07StagedProjectFile]) async throws {
            lock.lock()
            let fail = storage.failWrite
            if !fail {
                storage.calls.append("writeProjectFiles:\(files.count)")
            }
            lock.unlock()
            if fail { throw C07DataExchangeError.storageUnavailable("seededWriteFailure") }
        }

        func deleteProject(id: UUID) async throws {
            lock.lock(); storage.calls.append("deleteProject"); lock.unlock()
        }

        func deleteProjects(markedName: String) async throws -> Int {
            lock.lock(); storage.calls.append("deleteProjects:\(markedName)")
            let count = storage.projects.removeValue(forKey: markedName) == nil ? 0 : 1
            lock.unlock()
            return count
        }

        func createNotebook(markerTitle: String) async throws -> UUID {
            lock.lock(); defer { lock.unlock() }
            let id = UUID()
            storage.calls.append("createNotebook")
            storage.notebooks[id] = markerTitle
            return id
        }

        func renameNotebook(id: UUID, to finalTitle: String) async throws {
            lock.lock(); storage.calls.append("renameNotebook:\(finalTitle)"); lock.unlock()
        }

        func deleteEmptyNotebook(id: UUID) async throws {
            lock.lock(); storage.calls.append("deleteEmptyNotebook"); lock.unlock()
        }

        func deleteEmptyNotebooks(markedTitle: String) async throws -> Int {
            lock.lock(); storage.calls.append("deleteEmptyNotebooks:\(markedTitle)"); lock.unlock()
            return 0
        }

        func importNoteArchive(_ archive: C07ParsedNoteArchive,
                               notebookID: UUID?) async throws -> C07NoteImportReceipt {
            lock.lock(); defer { lock.unlock() }
            storage.calls.append("importNoteArchive:\(archive.documents.count)")
            storage.notes.append(contentsOf: archive.newDocumentIDs)
            return C07NoteImportReceipt(documentIDs: archive.newDocumentIDs,
                                        resourceCount: archive.resources.count)
        }

        func removeNotes(documentIDs: [UUID]) async throws {
            lock.lock()
            storage.calls.append("removeNotes:\(documentIDs.count)")
            storage.notes.removeAll { documentIDs.contains($0) }
            lock.unlock()
        }

        func insertSettingIfAbsent(key: String, json: String) async throws -> Bool {
            lock.lock(); defer { lock.unlock() }
            storage.calls.append("insertSetting:\(key)")
            if storage.existingSettings.contains(key) { return false }
            storage.settings[key] = json
            return true
        }

        func removeSettingIfExact(key: String, json: String) async throws {
            lock.lock()
            storage.calls.append("removeSetting:\(key)")
            if storage.settings[key] == json { storage.settings.removeValue(forKey: key) }
            lock.unlock()
        }

        func prepareOwnedData(_ staged: C07StagedOwnedData,
                              projectMap: [UUID: UUID],
                              restoreID: UUID,
                              journalRoot: URL) async throws -> C07PreparedOwnedData {
            throw C07DataExchangeError.unsupportedFeature("testSinkOwnedData")
        }

        func commitArtifacts(_ prepared: C07PreparedOwnedData) async throws
            -> C07ArtifactCommitReceipt {
            throw C07DataExchangeError.unsupportedFeature("testSinkArtifacts")
        }

        func commitOwnedData(_ prepared: C07PreparedOwnedData,
                             artifacts: C07ArtifactCommitReceipt) async throws
            -> C07OwnedDataCommitReceipt {
            throw C07DataExchangeError.unsupportedFeature("testSinkData")
        }

        func rollbackOwnedData(planURL: URL, planSHA256: String) async throws {}
    }

    // MARK: - Helpers

    private func makeNoteArchive(fixture: Fixture,
                                 mediaBytes: Data = Data("image-bytes".utf8))
        async throws -> (C07SourceNote, NotesStore)
    {
        let notesRoot = fixture.root.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notesRoot, withIntermediateDirectories: true)
        let store = try NotesStore(root: notesRoot)
        let source = try fixture.write("source/image.png", mediaBytes)
        let resource = try await store.importResource(
            from: source, mediaType: "image/png")
        var document = NoteDocument(kind: .notebook, title: "Trip notes")
        document.pages[0].elements.append(NoteElement(kind: .image, resourceID: resource))
        let created = try await store.create(document)
        let archive = fixture.root.appendingPathComponent("export/trip.floenote")
        try FileManager.default.createDirectory(
            at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await C07NotesPackage.export(document: created, store: store, to: archive)
        return (C07SourceNote(documentID: created.id, notebookID: created.notebookID,
                              title: created.title, archiveURL: archive), store)
    }

    private func buildSource(fixture: Fixture,
                             projectID: UUID,
                             includeNotes: Bool = true,
                             settings: [String: String] = ["ui.theme": "\"dark\""])
        async throws -> (C07BackupSource, NotesStore?)
    {
        let projectRoot = try fixture.project(projectID, files: [
            "a.txt": "alpha",
            "nested/b.txt": "beta",
        ])
        try FileManager.default.createDirectory(
            at: projectRoot.appendingPathComponent("empty", isDirectory: true),
            withIntermediateDirectories: true)
        var notes: [C07SourceNote] = []
        var notebooks: [C07NotebookRecord] = []
        var store: NotesStore?
        if includeNotes {
            let made = try await makeNoteArchive(fixture: fixture)
            notes = [made.0]
            store = made.1
            let books = try await made.1.notebooks()
            notebooks = books.map {
                C07NotebookRecord(notebookID: $0.id, title: $0.title)
            }
        }
        let source = C07BackupSource(
            appSchemaVersion: 51,
            projects: [C07SourceProject(
                projectID: projectID, name: "Docs", origin: .managed,
                rootURL: projectRoot)],
            notebooks: notebooks,
            notes: notes,
            settingsValues: settings,
            providerCatalog: [C07ProviderAdvisory(
                displayName: "Example", wireProtocol: "openAI",
                baseURLHost: "example.com", modelNames: ["m1"])])
        return (source, store)
    }

    // MARK: - Tests

    func testBackupRoundTripAndNoDatabaseCopy() async throws {
        let fixture = try Fixture()
        let projectID = UUID()
        let (source, _) = try await buildSource(fixture: fixture, projectID: projectID)
        let destination = fixture.destination("roundtrip.floebackup")
        let built = try await C07BackupBuilder.build(
            source: source, destination: destination,
            stagingRoot: fixture.root.appendingPathComponent("staging", isDirectory: true))
        XCTAssertEqual(built.manifest.format, "floe.appbackup")
        XCTAssertEqual(built.manifest.scope.database, "none")
        XCTAssertEqual(built.manifest.projects.count, 1)
        XCTAssertEqual(built.manifest.projects[0].files.count, 2)
        XCTAssertTrue(built.manifest.projects[0].directories.contains("nested"))
        XCTAssertTrue(built.manifest.projects[0].directories.contains("empty"))
        XCTAssertEqual(built.manifest.notes.documents.count, 1)
        XCTAssertEqual(Set(built.manifest.settings.keys), Set(["ui.theme"]))
        XCTAssertTrue(built.warnings.isEmpty)

        let plan = try await C07BackupReader.inspect(
            archiveURL: destination,
            stagingRoot: fixture.root.appendingPathComponent("inspect", isDirectory: true),
            currentAppSchemaVersion: 51)
        XCTAssertEqual(plan.projects.count, 1)
        XCTAssertEqual(plan.projectFileCount, 2)
        XCTAssertEqual(plan.noteDocumentCount, 1)
        XCTAssertEqual(plan.noteResourceCount, 1)
        XCTAssertEqual(plan.settingsValues["ui.theme"], "\"dark\"")

        let sink = FakeSink()
        let receipt = try await C07RestoreEngine.commit(
            plan: plan, sink: sink,
            journalRoot: fixture.root.appendingPathComponent("journal", isDirectory: true))
        XCTAssertEqual(receipt.projectsRestored, 1)
        XCTAssertEqual(receipt.noteDocumentsRestored, 1)
        XCTAssertEqual(receipt.noteResourcesRestored, 1)
        XCTAssertEqual(receipt.settingsInserted, 1)
        XCTAssertEqual(sink.state.projects.count, 1)
        XCTAssertEqual(sink.state.notes.count, 1)
        XCTAssertEqual(sink.state.settings["ui.theme"], "\"dark\"")
        XCTAssertFalse(C07JournalReader.pending(in: fixture.root.appendingPathComponent("journal")).count > 0)
    }

    func testInspectionNeverCallsSinkBeforeCommit() async throws {
        let fixture = try Fixture()
        let (source, _) = try await buildSource(fixture: fixture, projectID: UUID(),
                                                includeNotes: false)
        let destination = fixture.destination("inspect-only.floebackup")
        _ = try await C07BackupBuilder.build(
            source: source, destination: destination,
            stagingRoot: fixture.root.appendingPathComponent("staging"))
        let plan = try await C07BackupReader.inspect(
            archiveURL: destination,
            stagingRoot: fixture.root.appendingPathComponent("inspect"),
            currentAppSchemaVersion: 51)
        let sink = FakeSink()
        XCTAssertTrue(sink.state.calls.isEmpty)
        _ = plan
        XCTAssertTrue(sink.state.calls.isEmpty)
    }

    func testRetainedProjectRestoresThroughNewExplicitOwnership() async throws {
        let fixture = try Fixture()
        let projectID = UUID()
        let root = try fixture.project(projectID, files: ["keep.txt": "orphan bytes"])
        let source = C07BackupSource(
            appSchemaVersion: 51,
            projects: [C07SourceProject(
                projectID: projectID, name: "Retained project", origin: .retained,
                rootURL: root)],
            notebooks: [], notes: [])
        let destination = fixture.destination("retained.floebackup")
        let built = try await C07BackupBuilder.build(
            source: source, destination: destination,
            stagingRoot: fixture.root.appendingPathComponent("stage"))
        XCTAssertEqual(built.manifest.projects.first?.origin, .retained)
        let plan = try await C07BackupReader.inspect(
            archiveURL: destination,
            stagingRoot: fixture.root.appendingPathComponent("inspect"),
            currentAppSchemaVersion: 51)
        let sink = FakeSink()
        _ = try await C07RestoreEngine.commit(
            plan: plan, sink: sink,
            journalRoot: fixture.root.appendingPathComponent("journal"))
        XCTAssertTrue(sink.state.calls.contains("createProject:retained"))
    }

    func testWriteFailureRollsBackCreatedProject() async throws {
        let fixture = try Fixture()
        let (source, _) = try await buildSource(fixture: fixture, projectID: UUID(),
                                                includeNotes: false)
        let destination = fixture.destination("failure.floebackup")
        _ = try await C07BackupBuilder.build(
            source: source, destination: destination,
            stagingRoot: fixture.root.appendingPathComponent("staging"))
        let plan = try await C07BackupReader.inspect(
            archiveURL: destination,
            stagingRoot: fixture.root.appendingPathComponent("inspect"),
            currentAppSchemaVersion: 51)
        let sink = FakeSink()
        sink.setFailWrite(true)
        do {
            _ = try await C07RestoreEngine.commit(
                plan: plan, sink: sink,
                journalRoot: fixture.root.appendingPathComponent("journal"))
            XCTFail("seeded write failure must fail the restore")
        } catch {
            XCTAssertEqual((error as? C07DataExchangeError)?.code, "storageUnavailable")
        }
        XCTAssertTrue(sink.state.calls.contains("deleteProject"))
        let pending = C07JournalReader.pending(in: fixture.root.appendingPathComponent("journal"))
        XCTAssertTrue(pending.isEmpty)
    }

    func testExistingSettingIsNotOverwritten() async throws {
        let fixture = try Fixture()
        let (source, _) = try await buildSource(fixture: fixture, projectID: UUID(),
                                                includeNotes: false)
        let destination = fixture.destination("settings.floebackup")
        _ = try await C07BackupBuilder.build(
            source: source, destination: destination,
            stagingRoot: fixture.root.appendingPathComponent("staging"))
        let plan = try await C07BackupReader.inspect(
            archiveURL: destination,
            stagingRoot: fixture.root.appendingPathComponent("inspect"),
            currentAppSchemaVersion: 51)
        let sink = FakeSink()
        sink.setExistingSetting("ui.theme")
        let receipt = try await C07RestoreEngine.commit(
            plan: plan, sink: sink,
            journalRoot: fixture.root.appendingPathComponent("journal"))
        XCTAssertEqual(receipt.settingsSkipped, 1)
        XCTAssertNil(sink.state.settings["ui.theme"])
    }

    func testSettingsPolicyExcludesSecrets() {
        let values = [
            "ui.theme": "\"dark\"",
            "provider.apiKey": "\"sk-secret\"",
            "github.token": "\"ghp_secret\"",
            "editor.fontSize": "14",
            "notes.view.zoom": "1.2",
            "mail.password": "\"pw\"",
        ]
        let safe = C07SettingsPolicy.sanitize(values)
        XCTAssertEqual(Set(safe.keys), Set(["ui.theme", "editor.fontSize", "notes.view.zoom"]))
        XCTAssertFalse(C07SettingsPolicy.isAllowedKey("provider.apiKey"))
        XCTAssertFalse(C07SettingsPolicy.isAllowedKey("session.cookie"))
    }

    func testScopeDeclaresExcludedSecretsAndDatabase() throws {
        let manifest = C07BackupManifest(
            appSchemaVersion: 51,
            scope: C07BackupScope(excluded: C07ScopePolicy.excluded),
            projects: [], notes: C07NotesRecord(notebooks: [], documents: []),
            settings: C07SettingsRecord(entry: nil, byteCount: 0, sha256: nil,
                                        keys: [], providerCatalog: []))
        try C07ScopePolicy.validate(manifest.scope)
        let ids = Set(manifest.scope.excluded.map(\.id))
        for required in ["credentials", "deviceKeys", "sessionSecrets", "cookies",
                         "appDatabase", "approvalGrants"] {
            XCTAssertTrue(ids.contains(required), required)
        }
        XCTAssertEqual(manifest.scope.database, "none")
    }

    // MARK: - Hostile archives

    private func makeZip(_ url: URL,
                         entries: [(path: String, data: Data, type: Entry.EntryType)])
        throws
    {
        let archive = try Archive(url: url, accessMode: .create)
        for entry in entries {
            try archive.addEntry(
                with: entry.path, type: entry.type,
                uncompressedSize: Int64(entry.data.count),
                compressionMethod: .deflate) { position, size in
                    let start = Int(position)
                    return entry.data.subdata(in: start..<min(start + size, entry.data.count))
                }
        }
    }

    func testTraversalDuplicateAndSymlinkEntriesAreRejected() async throws {
        let fixture = try Fixture()
        let cases: [(String, [(path: String, data: Data, type: Entry.EntryType)])] = [
            ("traversal.zip", [("../escape", Data("x".utf8), .file)]),
            ("duplicate.zip", [
                ("manifest.json", Data("{}".utf8), .file),
                ("manifest.json", Data("{}".utf8), .file),
            ]),
            ("symlink.zip", [("link", Data("target".utf8), .symlink)]),
        ]
        for (name, entries) in cases {
            let url = fixture.destination(name)
            try makeZip(url, entries: entries)
            do {
                _ = try await C07BackupReader.inspect(
                    archiveURL: url,
                    stagingRoot: fixture.root.appendingPathComponent("stage-\(name)"),
                    currentAppSchemaVersion: 51)
                XCTFail("\(name) must be rejected")
            } catch let error as C07DataExchangeError {
                switch error {
                case .unsafePath, .duplicateEntry, .symlinkUnsupported, .corruptArchive,
                     .invalidManifest:
                    break
                default:
                    XCTFail("unexpected rejection for \(name): \(error)")
                }
            }
        }
    }

    func testZipBombRatioIsRejected() async throws {
        let fixture = try Fixture()
        let url = fixture.destination("bomb.zip")
        let zeroes = Data(repeating: 0, count: 3 * 1_024 * 1_024)
        try makeZip(url, entries: [("manifest.json", zeroes, .file)])
        do {
            _ = try await C07BackupReader.inspect(
                archiveURL: url,
                stagingRoot: fixture.root.appendingPathComponent("bomb-stage"),
                currentAppSchemaVersion: 51)
            XCTFail("compression ratio bomb must be rejected")
        } catch let error as C07DataExchangeError {
            if case .corruptArchive = error { return }
            XCTFail("expected corruptArchive, got \(error)")
        }
    }

    func testNewerFormatAndAppSchemaAreRejected() async throws {
        let fixture = try Fixture()
        let versionURL = fixture.destination("new-format.zip")
        let manifest = C07BackupManifest(
            formatVersion: 3, appSchemaVersion: 51,
            scope: C07BackupScope(excluded: C07ScopePolicy.excluded),
            projects: [], notes: C07NotesRecord(notebooks: [], documents: []),
            settings: C07SettingsRecord(entry: nil, byteCount: 0, sha256: nil,
                                        keys: [], providerCatalog: []))
        try makeZip(versionURL, entries: [("manifest.json", try manifest.encoded(), .file)])
        do {
            _ = try await C07BackupReader.inspect(
                archiveURL: versionURL,
                stagingRoot: fixture.root.appendingPathComponent("version-stage"),
                currentAppSchemaVersion: 51)
            XCTFail("newer format must be rejected")
        } catch let error as C07DataExchangeError {
            if case .unsupportedVersion = error { } else {
                XCTFail("expected unsupportedVersion, got \(error)")
            }
        }

        let schemaURL = fixture.destination("new-schema.zip")
        let newer = C07BackupManifest(
            appSchemaVersion: 999,
            scope: C07BackupScope(excluded: C07ScopePolicy.excluded),
            projects: [], notes: C07NotesRecord(notebooks: [], documents: []),
            settings: C07SettingsRecord(entry: nil, byteCount: 0, sha256: nil,
                                        keys: [], providerCatalog: []))
        try makeZip(schemaURL, entries: [("manifest.json", try newer.encoded(), .file)])
        do {
            _ = try await C07BackupReader.inspect(
                archiveURL: schemaURL,
                stagingRoot: fixture.root.appendingPathComponent("schema-stage"),
                currentAppSchemaVersion: 51)
            XCTFail("newer app schema must be rejected")
        } catch let error as C07DataExchangeError {
            if case .unsupportedVersion = error { } else {
                XCTFail("expected unsupportedVersion, got \(error)")
            }
        }
    }

    // MARK: - Journal / recovery

    func testRecoveryRollsBackIntentWithoutReceiptAndIsIdempotent() async throws {
        let fixture = try Fixture()
        let journalRoot = fixture.root.appendingPathComponent("journal", isDirectory: true)
        let journal = try C07RestoreJournal(root: journalRoot)
        let marker = "Floe restore \(journal.restoreID.uuidString.prefix(8))"
        try journal.append(kind: .begin)
        try journal.append(kind: .intent, operation: .project, marker: marker,
                           finalName: "Docs")
        journal.close()
        XCTAssertEqual(C07RestoreRecovery.pendingCount(journalRoot: journalRoot), 1)

        let sink = FakeSink()
        let report = await C07RestoreRecovery.recover(
            journalRoot: journalRoot, sink: sink)
        XCTAssertEqual(report.recoveredJournals, 1)
        XCTAssertEqual(report.failedJournals, 0)
        XCTAssertTrue(sink.state.calls.contains("deleteProjects:\(marker)"))
        XCTAssertEqual(C07RestoreRecovery.pendingCount(journalRoot: journalRoot), 0)

        let again = await C07RestoreRecovery.recover(
            journalRoot: journalRoot, sink: sink)
        XCTAssertEqual(again.recoveredJournals, 0)
    }

    func testRecoveryDeletesExactNotesIdentities() async throws {
        let fixture = try Fixture()
        let journalRoot = fixture.root.appendingPathComponent("journal", isDirectory: true)
        let journal = try C07RestoreJournal(root: journalRoot)
        let ids = [UUID(), UUID()]
        try journal.append(kind: .intent, operation: .notes, documentIDs: ids)
        try journal.append(kind: .notesCreated, operation: .notes, documentIDs: ids)
        journal.close()
        let sink = FakeSink()
        let report = await C07RestoreRecovery.recover(
            journalRoot: journalRoot, sink: sink)
        XCTAssertEqual(report.recoveredJournals, 1)
        XCTAssertTrue(sink.state.calls.contains("removeNotes:2"))
    }
}
