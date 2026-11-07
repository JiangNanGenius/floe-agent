// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
@testable import FloeApp

@Suite("Personal Files multi-selection and batch deletion", .serialized)
@MainActor
struct SpaceLibraryBatchTests {
    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("files-batch-" + UUID().uuidString)
    }
    private func create(_ library: PersonalContentLibrary, title: String, folders: [String] = []) async throws -> PersonalContentRecord {
        try await library.create(kind: .document, title: title, in: folders) { directory, _ in
            try Data("Original bytes for \(title)".utf8).write(to: directory.appendingPathComponent("original.txt"))
        }
    }

    @Test func selectAllReplacesTheVisibleScopeAndRefreshKeepsOnlyOneIdentity() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let library = PersonalContentLibrary(root: root)
        let first = try await create(library, title: "First"), second = try await create(library, title: "Second")
        var selection = PersonalLibrarySelectionModel()
        selection.begin(with: .work(first))
        selection.selectAll([.work(second)])
        #expect(!selection.isSelected(.work(first)) && selection.isSelected(.work(second)))
        try await library.markChanged(second.id, title: "Renamed")
        let refreshed = try await library.resolve(second.id).record
        #expect(selection.isSelected(.work(refreshed)))
        selection.toggle(.work(refreshed))
        #expect(selection.isEmpty)
        selection.selectAll([.work(second), .work(refreshed)])
        #expect(selection.effectiveSelection().count == 1)
        selection.cancel()
        #expect(!selection.isSelecting && selection.isEmpty)
    }

    @Test func folderSelectionAbsorbsOnlyItsDescendantsAndCanBeNarrowed() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let library = PersonalContentLibrary(root: root)
        try await library.createFolder("A", in: [])
        try await library.createFolder("AB", in: [])
        let child = try await create(library, title: "Child", folders: ["A"])
        let sibling = try await create(library, title: "Sibling", folders: ["AB"])
        let folder = try #require(try await library.folderSnapshots(in: []).first { $0.name == "A" })
        var selection = PersonalLibrarySelectionModel()
        selection.begin()
        selection.selectAll([.folder(folder), .work(child), .work(child), .work(sibling)])
        #expect(selection.effectiveSelection().count == 2)
        #expect(selection.isSelected(.work(child)))
        selection.toggle(.work(child))
        #expect(!selection.isSelected(.folder(folder)))
        #expect(Set(selection.effectiveSelection().map(\.id)) == Set([PersonalLibrarySelectionItem.work(child).id, PersonalLibrarySelectionItem.work(sibling).id]))
    }

    @Test func batchReusesGuardsAndRetainsBusyAndChangedOriginalsWhileDeletingOthers() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let library = PersonalContentLibrary(root: root)
        let deletable = try await create(library, title: "Delete")
        let busy = try await create(library, title: "Open editor")
        let changed = try await create(library, title: "Old selection")
        let busyURL = try await library.resolve(busy.id).url
        let lease = try PersonalLibraryFileActions.acquireUse(id: busy.id, directory: busyURL, libraryRoot: root)
        defer { lease.release() }
        try await library.markChanged(changed.id, title: "Current selection")
        let result = await PersonalLibraryFileActions.deleteBatch([.work(deletable), .work(busy), .work(changed)], environment: nil, library: library)
        #expect(result.deleted.map(\.id) == [PersonalLibrarySelectionItem.work(deletable).id])
        #expect(Set(result.failed.map { $0.item.id }) == Set([PersonalLibrarySelectionItem.work(busy).id, PersonalLibrarySelectionItem.work(changed).id]))
        let visible = try await library.records()
        #expect(Set(visible.map(\.id)) == Set([busy.id, changed.id]))
        let event = try #require(try await library.recentlyDeleted().first)
        try await library.restore(event.id)
        let restored = try await library.resolve(deletable.id)
        #expect(try String(contentsOf: restored.url.appendingPathComponent("original.txt"), encoding: .utf8) == "Original bytes for Delete")
    }

    @Test func batchFolderDeletionDoesNotDoubleVisitAChildAndRestoresTheWholeOriginal() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let library = PersonalContentLibrary(root: root)
        try await library.createFolder("A", in: [])
        let child = try await create(library, title: "Child", folders: ["A"])
        let folder = try #require(try await library.folderSnapshots(in: []).first)
        let result = await PersonalLibraryFileActions.deleteBatch([.folder(folder), .work(child)], environment: nil, library: library)
        #expect(result.deleted.count == 1 && result.failed.isEmpty)
        #expect(try await library.records().isEmpty)
        let events = try await library.recentlyDeleted()
        #expect(events.count == 1)
        try await library.restore(try #require(events.first).id)
        #expect(try await library.resolve(child.id).record.id == child.id)
    }
}
#endif
