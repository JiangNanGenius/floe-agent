// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
@testable import FloeApp

@Suite("Personal Files recoverable deletion", .serialized)
struct PersonalLibraryTrashTests {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("personal-trash-" + UUID().uuidString) }
    private func create(_ library: PersonalContentLibrary, kind: PersonalContentKind = .document, folders: [String] = []) async throws -> PersonalContentRecord {
        try await library.create(kind: kind, title: kind.rawValue, in: folders) { directory, id in
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("Assets"), withIntermediateDirectories: false)
            try Data("original \(id)\n中\0".utf8).write(to: directory.appendingPathComponent("Assets/original.bin"))
            try Data("undo+revision+receipt".utf8).write(to: directory.appendingPathComponent("history.json"))
        }
    }
    private func files(_ directory: URL) throws -> [String: Data] {
        let paths = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]))
        var result: [String: Data] = [:]
        for case let file as URL in paths where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[String(file.path.dropFirst(directory.path.count + 1))] = try Data(contentsOf: file)
        }
        return result
    }

    @Test func allWorkKindsHideWithoutChangingOriginalBytesAndRestoreTheSameIdentity() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let library = PersonalContentLibrary(root: root)
        for kind in PersonalContentKind.allCases {
            let original = try await create(library, kind: kind)
            let location = try await library.resolve(original.id).url
            let before = try files(location)
            let event = try await library.softDelete(original)
            #expect(try await library.records().allSatisfy { $0.id != original.id })
            #expect(try await library.records(includingDeleted: true).first { $0.id == original.id }?.deletedAt != nil)
            do { _ = try await library.resolve(original.id); Issue.record("Deleted original resolved") }
            catch PersonalContentError.deleted { }
            do {
                _ = try await library.create(kind: kind, title: "Must not resurrect", id: original.id) { _, _ in Issue.record("Deleted identity reached prepare") }
                Issue.record("Deleted identity reused")
            } catch PersonalContentError.deleted { }
            #expect(try files(location) == before)
            let reopened = PersonalContentLibrary(root: root)
            #expect(try await reopened.recentlyDeleted().contains { $0.id == event.id && $0.projectID == original.id })
            try await reopened.restore(event.id)
            let restored = try await reopened.resolve(original.id)
            #expect(restored.record.id == original.id)
            #expect(restored.url == location)
            #expect(restored.record.deletedAt == nil)
            #expect(try files(location) == before)
        }
    }

    @Test func aFolderTombstoneHidesItsSubtreeBlocksWritesAndPreservesSeparateChildDeletion() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let library = PersonalContentLibrary(root: root)
        try await library.createFolder("A", in: [])
        try await library.createFolder("Nested", in: ["A"])
        try await library.createFolder("AB", in: [])
        let child = try await create(library, folders: ["A", "Nested"])
        let separate = try await create(library, kind: .canvas, folders: ["A"])
        let outside = try await create(library, folders: ["AB"])
        let separateEvent = try await library.softDelete(separate)
        let selected = try #require(try await library.folderSnapshots(in: []).first { $0.name == "A" })
        let event = try await library.softDeleteFolder(selected, expectedProjectIDs: [child.id, separate.id])
        #expect(try await library.records().map(\.id) == [outside.id])
        #expect(try await library.folders(in: []) == ["AB"])
        do { _ = try await library.resolve(child.id); Issue.record("Folder descendant resolved") }
        catch PersonalContentError.deleted { }
        do { try await library.createFolder("New", in: ["A"]); Issue.record("Write entered deleted folder") }
        catch PersonalContentError.deleted { }
        do {
            _ = try await create(library, folders: ["A", "Nested"]); Issue.record("Create entered deleted subtree")
        } catch PersonalContentError.deleted { }
        do { try await library.restore(separateEvent.id); Issue.record("Child restored under a deleted parent") }
        catch PersonalContentError.restoreParentFirst { }
        try await PersonalContentLibrary(root: root).restore(event.id)
        #expect(try await library.resolve(child.id).record.id == child.id)
        do { _ = try await library.resolve(separate.id); Issue.record("Parent restore removed separate child deletion") }
        catch PersonalContentError.deleted { }
        try await library.restore(separateEvent.id)
        #expect(try await library.resolve(separate.id).record.id == separate.id)
    }

    @Test func staleSelectionsAndOldRestoreEventsCannotAffectANewerOriginalState() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let library = PersonalContentLibrary(root: root), record = try await create(library)
        var stale = record; stale.relativePath = "another.floeproject"
        do { _ = try await library.softDelete(stale); Issue.record("Stale path accepted") }
        catch PersonalContentError.changedDocument { }
        stale = record; stale.kind = .diagram
        do { _ = try await library.softDelete(stale); Issue.record("Stale kind accepted") }
        catch PersonalContentError.changedDocument { }
        stale = record; stale.modifiedAt = record.modifiedAt.addingTimeInterval(-1)
        do { _ = try await library.softDelete(stale); Issue.record("Stale version accepted") }
        catch PersonalContentError.changedDocument { }
        let first = try await library.softDelete(record)
        try await library.restore(first.id)
        let second = try await library.softDelete(record)
        do { try await library.restore(first.id); Issue.record("Old restore event revived newer deletion") }
        catch PersonalContentError.changedDocument { }
        #expect(try await library.recentlyDeleted().map(\.id) == [second.id])
        do { try await library.markChanged(record.id); Issue.record("Metadata wrote a deleted original") }
        catch PersonalContentError.deleted { }
    }

    @Test func folderSelectionRejectsNewChildrenReplacementTraversalRootAndExternalSymlinks() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let library = PersonalContentLibrary(root: root)
        try await library.createFolder("A", in: [])
        let selection = try #require(try await library.folderSnapshots(in: []).first)
        let added = try await create(library, folders: ["A"])
        do { _ = try await library.softDeleteFolder(selection, expectedProjectIDs: []); Issue.record("Unseen child accepted") }
        catch PersonalContentError.changedDocument { }
        #expect(try await library.resolve(added.id).record.id == added.id)
        try FileManager.default.moveItem(at: root.appendingPathComponent("A"), to: root.appendingPathComponent("Backup"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("A"), withIntermediateDirectories: false)
        do { _ = try await library.softDeleteFolder(selection, expectedProjectIDs: []); Issue.record("Replacement folder accepted") }
        catch PersonalContentError.changedDocument { }
        for invalid in [[], [".."], ["A", "..", "Backup"], ["/outside"]] {
            await #expect(throws: PersonalContentError.self) {
                _ = try await library.softDeleteFolder(.init(components: invalid, resourceIdentity: "stale"), expectedProjectIDs: [])
            }
        }
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try Data("outside remains".utf8).write(to: outside.appendingPathComponent("preserved"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Alias"), withDestinationURL: outside)
        await #expect(throws: PersonalContentError.self) {
            _ = try await library.softDeleteFolder(.init(components: ["Alias"], resourceIdentity: "stale"), expectedProjectIDs: [])
        }
        #expect(try String(contentsOf: outside.appendingPathComponent("preserved"), encoding: .utf8) == "outside remains")
        #expect(try await library.recentlyDeleted().isEmpty)
    }

    @Test func preparationCannotPublishIntoAFolderDeletedWhileAwaiting() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let library = PersonalContentLibrary(root: root), gate = PersonalTrashPreparationGate(), id = UUID()
        try await library.createFolder("A", in: [])
        let selection = try #require(try await library.folderSnapshots(in: []).first)
        let creation = Task {
            try await library.create(kind: .document, title: "In flight", in: ["A"], id: id) { directory, _ in
                try Data("recover this partial original".utf8).write(to: directory.appendingPathComponent("original.bin"))
                await gate.startAndWait()
            }
        }
        await gate.waitUntilStarted()
        _ = try await library.softDeleteFolder(selection, expectedProjectIDs: [])
        await gate.release()
        do { _ = try await creation.value; Issue.record("In-flight create published under tombstone") }
        catch PersonalContentError.deleted { }
        let recovered = try #require(try await library.records().first { $0.id == id })
        #expect(recovered.needsRecovery)
        #expect(!recovered.folders.starts(with: ["A"]))
        #expect(try Data(contentsOf: root.appendingPathComponent(recovered.relativePath).appendingPathComponent("original.bin")) == Data("recover this partial original".utf8))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("A/In flight.floeproject").path))
    }

    @Test @MainActor func folderActionProtectsAnOpenDescendantWithoutBlockingAnUnrelatedPrefix() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let library = PersonalContentLibrary(root: root)
        try await library.createFolder("A", in: [])
        try await library.createFolder("AB", in: [])
        let inside = try await create(library, folders: ["A"]), outside = try await create(library, folders: ["AB"])
        let folder = try #require(try await library.folderSnapshots(in: []).first { $0.name == "A" })
        let insideUse = try PersonalLibraryFileActions.acquireUse(id: inside.id, directory: try await library.resolve(inside.id).url, libraryRoot: root)
        let outsideUse = try PersonalLibraryFileActions.acquireUse(id: outside.id, directory: try await library.resolve(outside.id).url, libraryRoot: root)
        defer { insideUse.release(); outsideUse.release() }
        do {
            try await PersonalLibraryFileActions.deleteFolder(folder, environment: nil, library: library)
            Issue.record("Open descendant was hidden")
        } catch PersonalFileActionError.closeFirst { }
        insideUse.release()
        try await PersonalLibraryFileActions.deleteFolder(folder, environment: nil, library: library)
        #expect(try await library.records().map(\.id) == [outside.id])
        let event = try #require(try await library.recentlyDeleted().first)
        try await library.restore(event.id)
        #expect(try await library.resolve(inside.id).record.id == inside.id)
    }

    @Test @MainActor func cancelledFileActionKeepsOriginalVisibleAndReleasesItsBarrier() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let library = PersonalContentLibrary(root: root), record = try await create(library)
        let action = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try await PersonalLibraryFileActions.delete(record, environment: nil, library: library)
        }
        do { try await action.value; Issue.record("Cancelled deletion completed") }
        catch is CancellationError { }
        #expect(try await library.recentlyDeleted().isEmpty)
        let location = try await library.resolve(record.id)
        let use = try PersonalLibraryFileActions.acquireUse(id: record.id, directory: location.url, libraryRoot: root)
        use.release()
    }

    @Test @MainActor func usageTokensBlockDeletionUntilEveryOwnerHasReleasedAndBlockDeletedReopen() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let library = PersonalContentLibrary(root: root), record = try await create(library)
        let url = try await library.resolve(record.id).url
        let first = try PersonalLibraryFileActions.acquireUse(id: record.id, directory: url, libraryRoot: root)
        let second = try PersonalLibraryFileActions.acquireUse(id: record.id, directory: url, libraryRoot: root)
        first.release(); first.release()
        do {
            try await PersonalLibraryFileActions.delete(record, environment: nil, library: library)
            Issue.record("A second live owner was ignored")
        } catch PersonalFileActionError.closeFirst { }
        second.release()
        try await PersonalLibraryFileActions.delete(record, environment: nil, library: library)
        #expect(try await library.records().isEmpty)
        #expect(throws: PersonalContentError.self) {
            _ = try PersonalLibraryFileActions.acquireUse(id: record.id, directory: url, libraryRoot: root)
        }
        let event = try #require(try await library.recentlyDeleted().first)
        try await library.restore(event.id)
        let restored = try PersonalLibraryFileActions.acquireUse(id: record.id, directory: url, libraryRoot: root)
        restored.release()
        #expect(try await library.resolve(record.id).url == url)
    }
}

private actor PersonalTrashPreparationGate {
    private var started = false
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var pending: CheckedContinuation<Void, Never>?
    func startAndWait() async {
        started = true; startedWaiter?.resume(); startedWaiter = nil
        await withCheckedContinuation { pending = $0 }
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }
    func release() { pending?.resume(); pending = nil }
}
#endif
