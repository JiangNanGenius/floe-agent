// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeBiologyCore
import FloeBiologyEngine
@testable import FloeApp
#if canImport(UIKit)
import FloeCore
import FloePersistence
import FloeTools
#endif

@Suite("Biology native-original permanent deletion", .serialized)
struct BiologyPermanentDeletionTests: Sendable {
    private struct Fixture: Sendable {
        let root: URL
        let library: PersonalContentLibrary
        let store: BiologyProjectStore
        let record: PersonalContentRecord
        let entry: PersonalLibraryTrashEntry
        let reference: BiologyFileReference
        var projects: URL { root.appendingPathComponent("Biology/Projects") }
        var files: URL { root.appendingPathComponent("Biology/OriginalFiles") }
    }
    private func sandbox() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("biology-permanent-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url.resolvingSymlinksInPath()
    }
    private func fixture() async throws -> Fixture {
        let root = try sandbox(), id = UUID()
        let projects = root.appendingPathComponent("Biology/Projects"), files = root.appendingPathComponent("Biology/OriginalFiles")
        let library = PersonalContentLibrary(root: root.appendingPathComponent("Library"))
        let store = try BiologyProjectStore(root: projects, ownedFilesRoot: files)
        let created = try await store.createBound(id: id, title: "Owned biology")
        let source = root.appendingPathComponent("original-input.csv"); try Data("x,y\n1,2\n3,5\n".utf8).write(to: source)
        let environment = "native.local", namespace = BiologyProjectStore.digest(Data(environment.utf8))
        let nativeFiles = try BiologyWorkspaceFiles(root: files.appendingPathComponent(namespace), environmentID: environment, authorize: { context, _ in
            guard context.projectID == id else { throw BiologyError.invalid("Foreign fixture") }
        })
        let reference = try await nativeFiles.register(trustedSourceURL: source, fileName: "owned.csv", context: .init(projectID: id, owner: nil))
        let updated = try await store.update(id, expectedRevision: created.revision) {
            $0.assets = [.init(title: "Owned dataset", payload: .externalDataset("csv"), originalData: Data(), originalFormat: "csv", fileReference: reference)]
        }
        let record = try await library.create(kind: .biology, title: "Owned biology", id: id) { directory, originalID in
            try BiologyOriginalBinding(projectID: originalID).write(to: directory)
            try Data("owned wrapper".utf8).write(to: directory.appendingPathComponent("wrapper.bin"))
        }
        try await store.trash(id, expectedRevision: updated.revision)
        let entry = try await library.softDelete(record)
        return .init(root: root, library: library, store: store, record: record, entry: entry, reference: reference)
    }
    private func plan(_ f: Fixture, library: PersonalContentLibrary? = nil, store: BiologyProjectStore? = nil) async throws -> PersonalPermanentDeletePlan {
        let library = library ?? f.library, store = store ?? f.store
        let proposals = try await library.permanentDeletionProposals([f.entry])
        let values = try await BiologyLibraryPermanentDeletion.prepare(proposals, library: library, store: store)
        return try #require(values.first)
    }
    private func bytes(_ root: URL) throws -> [String: Data] {
        guard FileManager.default.fileExists(atPath: root.path), let items = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return [:] }
        var result: [String: Data] = [:]
        let base = (root.path as NSString).standardizingPath
        let prefix = base.hasSuffix("/") ? base : base + "/"
        for case let url as URL in items {
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if info.isRegularFile == true, info.isSymbolicLink != true {
                let path = (url.path as NSString).standardizingPath
                guard path.hasPrefix(prefix) else { throw PersonalContentError.outsideLibrary }
                result[String(path.dropFirst(prefix.count))] = try Data(contentsOf: url)
            }
        }
        return result
    }

    @Test func nativeHistoryAllOwnedNamespacesAndWrapperAreActuallyRemovedTogether() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let foreign = try await f.store.createBound(id: UUID(), title: "Unselected original")
        let otherEnvironment = "old-task-environment", otherNamespace = BiologyProjectStore.digest(Data(otherEnvironment.utf8))
        let historical = try BiologyWorkspaceFiles(root: f.files.appendingPathComponent(otherNamespace), environmentID: otherEnvironment, authorize: { _, _ in })
        _ = try await historical.register(trustedSourceURL: f.root.appendingPathComponent("original-input.csv"), fileName: "old-copy.csv", context: .init(projectID: f.record.id, owner: nil))
        let nativeBefore = try bytes(f.projects.appendingPathComponent(f.record.id.uuidString.lowercased()))
        #expect(nativeBefore.keys.contains("HEAD.json"), "Observed fixture keys: \(nativeBefore.keys.sorted())")
        #expect(nativeBefore.keys.filter { $0.hasPrefix("revisions/") }.count >= 3)
        let selected = try await plan(f)
        let biologyIdentity = try selected.biologyDeletionIdentity()
        #expect(selected.biologySources.count == 1 && biologyIdentity?.count == 64)
        let receipt = try await BiologyLibraryPermanentDeletion.remove(selected, library: f.library, store: f.store)
        #expect(receipt.removedEntryIDs == [f.entry.id])
        #expect(!FileManager.default.fileExists(atPath: f.projects.appendingPathComponent(f.record.id.uuidString.lowercased()).path))
        for environment in ["native.local", otherEnvironment] {
            let path = f.files.appendingPathComponent(BiologyProjectStore.digest(Data(environment.utf8))).appendingPathComponent(f.record.id.uuidString.lowercased())
            #expect(!FileManager.default.fileExists(atPath: path.path))
        }
        #expect(try await f.library.recentlyDeleted().isEmpty)
        #expect(try await f.store.deletedProjects().allSatisfy { $0.projectID != f.record.id })
        #expect(try await f.store.load(foreign.id).title == "Unselected original")
        await #expect(throws: Error.self) { _ = try await f.store.createBound(id: f.record.id, title: "Reuse") }
        #expect(try Data(contentsOf: f.root.appendingPathComponent("original-input.csv")) == Data("x,y\n1,2\n3,5\n".utf8))
    }

    @Test func legacyNativeTrashDirectoryUsesItsExactOriginalWithoutAWrapperOnlyFallback() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = f.record.id.uuidString.lowercased()
        // Recreate the existing pre-HEAD-flag trash representation using the
        // real revisioned store. Legacy originals may have deletedAt == nil.
        _ = try await f.store.restoreDeleted(id, projectID: f.record.id)
        let trashID = id + "-" + UUID().uuidString.lowercased()
        let original = f.projects.appendingPathComponent("Trash").appendingPathComponent(trashID)
        try FileManager.default.moveItem(at: f.projects.appendingPathComponent(id), to: original)
        let selected = try await plan(f)
        #expect(selected.biologySources.first?.native.trashID == trashID)
        _ = try await BiologyLibraryPermanentDeletion.remove(selected, library: f.library, store: f.store)
        #expect(!FileManager.default.fileExists(atPath: original.path))
        #expect(try await f.library.recentlyDeleted().isEmpty)
        #expect(try await f.store.deletedProjects().isEmpty)
        await #expect(throws: Error.self) { _ = try await f.store.restoreDeleted(trashID, projectID: f.record.id) }
    }

    @Test func nativeRevisionWorkerAndBindingChangesRejectBeforeAnyDeletion() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let selected = try await plan(f), native = try #require(selected.biologySources.first)
        let restored = try await f.store.restoreDeleted(native.native.trashID, projectID: f.record.id)
        try await f.store.trash(f.record.id, expectedRevision: restored.revision)
        let before = try bytes(f.root)
        await #expect(throws: Error.self) { _ = try await BiologyLibraryPermanentDeletion.remove(selected, library: f.library, store: f.store) }
        #expect(try bytes(f.root) == before)
        let current = try await plan(f)
        let active = BiologyRun(asset: .init(title: "Synthetic", payload: .externalDataset("csv"), originalData: Data(), originalFormat: "csv"),
            inputDigest: String(repeating: "a", count: 64), method: "synthetic", options: .object([:]), environmentID: "native.local", engineVersion: "fixture", owner: nil)
        _ = try await f.store.transactReceipt(f.record.id, expectedRevision: current.biologySources.first?.native.revision,
            identity: nil, includingDeleted: true) { value -> Bool in
                var uncertain = active; uncertain.status = .interrupted; uncertain.workerStopUnconfirmed = true
                value.runs.append(uncertain); return true
            }
        await #expect(throws: Error.self) { _ = try await plan(f) }
        #expect(try await f.library.recentlyDeleted().contains(f.entry))
        let other = try await fixture(); defer { try? FileManager.default.removeItem(at: other.root) }
        let frozen = try await plan(other)
        try BiologyOriginalBinding(projectID: UUID()).write(to: other.root.appendingPathComponent("Library").appendingPathComponent(other.record.relativePath))
        let rebound = try bytes(other.root)
        await #expect(throws: Error.self) { _ = try await BiologyLibraryPermanentDeletion.remove(frozen, library: other.library, store: other.store) }
        #expect(try bytes(other.root) == rebound)
    }

    @Test func nativePartialFailureReopensWithFencesAndCompletesOnlyAfterFreshSelection() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let selected = try await plan(f)
        await #expect(throws: PersonalPermanentDeleteError.incomplete) {
            _ = try await BiologyLibraryPermanentDeletion.remove(selected, library: f.library, store: f.store, nativeCheckpoint: { point in
                if case .removedNode = point { throw BiologyError.corrupt("Injected native I/O failure") }
            })
        }
        #expect(try await f.library.recentlyDeleted().contains(f.entry))
        await #expect(throws: Error.self) { try await f.library.restore(f.entry.id) }
        let library = PersonalContentLibrary(root: f.root.appendingPathComponent("Library"))
        let store = try BiologyProjectStore(root: f.projects, ownedFilesRoot: f.files)
        await #expect(throws: Error.self) { _ = try await store.restoreDeleted(f.record.id.uuidString.lowercased(), projectID: f.record.id) }
        await #expect(throws: Error.self) { _ = try await store.createBound(id: f.record.id, title: "Replacement") }
        let retry = try await plan(f, library: library, store: store)
        #expect(retry.identity != selected.identity && retry.cleanupPending)
        _ = try await BiologyLibraryPermanentDeletion.remove(retry, library: library, store: store)
        #expect(try await library.recentlyDeleted().isEmpty)
        #expect(try await store.hasPermanentDeletionRecord(projectID: f.record.id, transactionID: f.entry.id))
    }

    @Test func nativeCompletionAndWrapperIndexFailureRemainOneRecoverableTransaction() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let selected = try await plan(f)
        await #expect(throws: PersonalPermanentDeleteError.incomplete) {
            _ = try await BiologyLibraryPermanentDeletion.remove(selected, library: f.library, store: f.store, wrapperCheckpoint: { point in
                if case .beforeIndexCommit = point { throw PersonalContentError.storageUnavailable }
            })
        }
        let library = PersonalContentLibrary(root: f.root.appendingPathComponent("Library"))
        let store = try BiologyProjectStore(root: f.projects, ownedFilesRoot: f.files)
        let retry = try await plan(f, library: library, store: store)
        #expect(retry.biologySources.allSatisfy { $0.native.completed })
        #expect(retry.fileCount == 0 && retry.cleanupPending)
        _ = try await BiologyLibraryPermanentDeletion.remove(retry, library: library, store: store)
        #expect(try await library.recentlyDeleted().isEmpty)
    }

    @Test func preCommitCancellationRestoresBothSidesAndLateCancellationReportsActualRemoval() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let selected = try await plan(f), wrapper = f.root.appendingPathComponent("Library").appendingPathComponent(f.record.relativePath)
        let native = f.projects.appendingPathComponent(f.record.id.uuidString.lowercased())
        let wrapperBefore = try bytes(wrapper), nativeBefore = try bytes(native), filesBefore = try bytes(f.files)
        let early = Task {
            try await BiologyLibraryPermanentDeletion.remove(selected, library: f.library, store: f.store, nativeCheckpoint: { point in
                if case .beforeIrreversible = point { withUnsafeCurrentTask { $0?.cancel() } }
            })
        }
        await #expect(throws: CancellationError.self) { _ = try await early.value }
        #expect(try bytes(wrapper) == wrapperBefore && bytes(native) == nativeBefore && bytes(f.files) == filesBefore)
        #expect(try await f.library.permanentDeletionPendingIDs().isEmpty)
        #expect(try await !f.store.hasPermanentDeletionRecord(projectID: f.record.id, transactionID: f.entry.id))
        let next = try await plan(f)
        let late = Task {
            try await BiologyLibraryPermanentDeletion.remove(next, library: f.library, store: f.store, nativeCheckpoint: { point in
                if case .removedNode = point { withUnsafeCurrentTask { $0?.cancel() } }
            })
        }
        let receipt = try await late.value
        #expect(receipt.entryID == f.entry.id)
        #expect(try await f.library.recentlyDeleted().isEmpty)
    }

    @Test func folderSelectionPurgesEveryMatchedBiologyOriginalButPreservesOtherWork() async throws {
        let root = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let library = PersonalContentLibrary(root: root.appendingPathComponent("Library"))
        let store = try BiologyProjectStore(root: root.appendingPathComponent("Biology/Projects"), ownedFilesRoot: root.appendingPathComponent("Biology/OriginalFiles"))
        try await library.createFolder("Selected", in: [])
        var records: [PersonalContentRecord] = []
        for index in 0..<2 {
            let id = UUID(), native = try await store.createBound(id: id, title: "Bio \(index)")
            records.append(try await library.create(kind: .biology, title: native.title, in: ["Selected"], id: id) { directory, id in try BiologyOriginalBinding(projectID: id).write(to: directory) })
            try await store.trash(id, expectedRevision: native.revision)
        }
        let document = try await library.create(kind: .document, title: "Also selected", in: ["Selected"]) { directory, _ in try Data("owned".utf8).write(to: directory.appendingPathComponent("original.txt")) }
        let foreign = try await store.createBound(id: UUID(), title: "Not selected")
        let child = try await library.softDelete(records[0])
        let folders = try await library.folderSnapshots(in: []), folder = try #require(folders.first)
        let entry = try await library.softDeleteFolder(folder, expectedProjectIDs: Set(records.map(\.id) + [document.id]))
        let proposals = try await library.permanentDeletionProposals([entry, child])
        let plans = try await BiologyLibraryPermanentDeletion.prepare(proposals, library: library, store: store)
        let selected = try #require(plans.first); #expect(plans.count == 1 && selected.biologySources.count == 2)
        let receipt = try await BiologyLibraryPermanentDeletion.remove(selected, library: library, store: store)
        #expect(Set(receipt.removedEntryIDs) == [entry.id, child.id])
        #expect(try await library.recentlyDeleted().isEmpty)
        #expect(try await store.load(foreign.id).title == "Not selected")
    }

    @Test func nativePathReplacementAndNamespaceSymlinkCannotDeleteForeignData() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let outside = f.root.appendingPathComponent("outside"); try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let sentinel = outside.appendingPathComponent("keep.bin"); try Data("foreign data".utf8).write(to: sentinel)
        let namespace = f.files.appendingPathComponent(BiologyProjectStore.digest(Data("native.local".utf8)))
        let owned = namespace.appendingPathComponent(f.record.id.uuidString.lowercased())
        try FileManager.default.createSymbolicLink(at: owned.appendingPathComponent("external-link"), withDestinationURL: outside)
        let selected = try await plan(f)
        try FileManager.default.moveItem(at: namespace, to: f.root.appendingPathComponent("saved-namespace"))
        try FileManager.default.createSymbolicLink(at: namespace, withDestinationURL: outside)
        let before = try bytes(outside)
        await #expect(throws: Error.self) { _ = try await BiologyLibraryPermanentDeletion.remove(selected, library: f.library, store: f.store) }
        #expect(try bytes(outside) == before)
        try FileManager.default.removeItem(at: namespace)
        try FileManager.default.moveItem(at: f.root.appendingPathComponent("saved-namespace"), to: namespace)
        let next = try await plan(f)
        _ = try await BiologyLibraryPermanentDeletion.remove(next, library: f.library, store: f.store)
        #expect(try Data(contentsOf: sentinel) == Data("foreign data".utf8))
    }

    @Test func nativeFileFenceRejectsAnAuthorizedCopyThatResumesAfterDeletionStarted() async throws {
        let root = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("input"); try Data("owned input".utf8).write(to: source)
        let gate = BiologyPurgeAuthorizationGate(), id = UUID()
        let files = try BiologyWorkspaceFiles(root: root.appendingPathComponent("Files"), environmentID: "native.local", authorize: { _, _ in await gate.hold() })
        let copy = Task { try await files.register(trustedSourceURL: source, fileName: "owned.bin", context: .init(projectID: id, owner: nil)) }
        await gate.waitForStart(); await files.beginPermanentDeletion(projectID: id); await gate.release()
        await #expect(throws: Error.self) { _ = try await copy.value }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Files").appendingPathComponent(id.uuidString.lowercased()).path))
        #expect(try Data(contentsOf: source) == Data("owned input".utf8))
    }

    @Test func biologyCASFieldDoesNotReplaceRequiredIdentityOrAuthorizeOtherActions() throws {
        let valid: [String: Any] = ["action": "permanentlyDelete", "projectID": UUID().uuidString, "trashEntryID": UUID().uuidString,
            "expectedIdentity": String(repeating: "a", count: 64), "expectedPermanentIdentity": String(repeating: "b", count: 64), "expectedBiologyIdentity": String(repeating: "c", count: 64)]
        let input = try JSONDecoder().decode(StudioLibraryInput.self, from: JSONSerialization.data(withJSONObject: valid)); try input.validate()
        for key in ["projectID", "trashEntryID", "expectedIdentity", "expectedPermanentIdentity"] {
            var invalid = valid; invalid.removeValue(forKey: key)
            #expect(throws: Error.self) { try JSONDecoder().decode(StudioLibraryInput.self, from: JSONSerialization.data(withJSONObject: invalid)).validate() }
        }
        for action in ["list", "detail", "delete", "restore"] {
            var invalid = valid; invalid["action"] = action
            #expect(throws: Error.self) { try JSONDecoder().decode(StudioLibraryInput.self, from: JSONSerialization.data(withJSONObject: invalid)).validate() }
        }
    }
    #if canImport(UIKit)
    @Test @MainActor func actualNativeShareBorrowMustFinishBeforeTheFileFenceCanBegin() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await f.store.restoreDeleted(f.record.id.uuidString.lowercased(), projectID: f.record.id)
        try await f.library.restore(f.entry.id)
        let database = try DatabaseManager.inMemory(); try await database.migrate()
        let access = BiologyHostAccess(runs: SQLiteRunStore(database: database), conversations: SQLiteConversationStore(database: database),
            authority: try StudioDocumentAccess(root: f.root.appendingPathComponent("Authority")),
            libraryRoot: f.root.appendingPathComponent("Library"), library: { f.library })
        let files = BiologyHostFiles(root: f.files, access: access)
        let context = BiologyFileContext(projectID: f.record.id, owner: nil)
        let reference = try await files.register(trustedSourceURL: f.root.appendingPathComponent("original-input.csv"), fileName: "share.csv", context: context)
        let borrowed = try await files.prepareNativeExport(reference, context: context)
        do {
            try await files.beginPermanentDeletion([f.record.id])
            Issue.record("An active native share borrow was ignored")
        } catch PersonalFileActionError.closeFirst { }
        #expect(FileManager.default.fileExists(atPath: borrowed.url.path))
        let wrong = BiologyNativeFileExport(id: borrowed.id, projectID: borrowed.projectID, url: f.root.appendingPathComponent("wrong-share-path"))
        await files.finishNativeExport(wrong)
        do {
            try await files.beginPermanentDeletion([f.record.id])
            Issue.record("An active native share borrow was ignored")
        } catch PersonalFileActionError.closeFirst { }
        await files.finishNativeExport(borrowed)
        try await files.beginPermanentDeletion([f.record.id])
        await #expect(throws: Error.self) { _ = try await files.resolve(reference.id, context: context) }
        await files.endPermanentDeletion([f.record.id])
        #expect(try await files.resolve(reference.id, context: context) == reference)
    }
    @Test func biologyCASAlsoPinsTheExistingNativeStoreExtent() {
        let specs = TypedMutationContract.specs(for: "studio.library", arguments: ["action": "permanentlyDelete", "projectID": UUID().uuidString, "expectedBiologyIdentity": String(repeating: "a", count: 64)])
        #expect(Set(specs.compactMap(\.storeKey)) == [TypedMutationContract.nativeStudioLibraryStoreKey, TypedMutationContract.nativeBiologyStoreKey])
        let args: [String: Any] = ["action": "permanentlyDelete", "projectID": UUID().uuidString, "expectedBiologyIdentity": String(repeating: "a", count: 64)]
        let stores = [TypedMutationContract.nativeStudioLibraryStoreKey: "/owned/Library", TypedMutationContract.nativeBiologyStoreKey: "/owned/Biology"]
        let targets = TypedMutationContract.resolveMutableTargets(for: "studio.library", arguments: args, workspaceRootURL: nil, serviceStorePaths: stores)
        #expect(Set(targets?.map(\.path) ?? []) == ["/owned/Library", "/owned/Biology"])
        #expect(targets?.allSatisfy { $0.role == .sourceWrite } == true)
        #expect(TypedMutationContract.resolveMutableTargets(for: "studio.library", arguments: args, workspaceRootURL: nil,
            serviceStorePaths: [TypedMutationContract.nativeStudioLibraryStoreKey: "/owned/Library"]) == nil)

    }
    #endif
}
private actor BiologyPurgeAuthorizationGate {
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var starters: [CheckedContinuation<Void, Never>] = []
    func hold() async { started = true; for value in starters { value.resume() }; starters = []; await withCheckedContinuation { waiter = $0 } }
    func waitForStart() async { if !started { await withCheckedContinuation { starters.append($0) } } }
    func release() { waiter?.resume(); waiter = nil }
}
