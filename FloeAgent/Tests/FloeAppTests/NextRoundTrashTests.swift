// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
@testable import FloeApp

@Suite("Trash selection, preference and chemistry paths", .serialized)
@MainActor struct NextRoundTrashTests {
    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("next-round-trash-" + UUID().uuidString)
    }
    private func create(_ library: PersonalContentLibrary, in folders: [String] = []) async throws -> PersonalContentRecord {
        try await library.create(kind: .document, title: UUID().uuidString, in: folders) { directory, _ in
            try Data("original bytes".utf8).write(to: directory.appendingPathComponent("original.txt"))
        }
    }

    @Test func chemistryJournalPathSurvivesDirectoryCreationAndNestedWrites() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let before = try ChemistryWorkerFiles.child("ChemistryJobs", root: root)
        try FileManager.default.createDirectory(at: before, withIntermediateDirectories: true)
        let after = try ChemistryWorkerFiles.child("ChemistryJobs", root: root)
        #expect(before.path == after.path)
        try ChemistryWorkerFiles.write(Data("receipt".utf8), path: "attempt/receipt.json", root: after, limit: 1024)
        #expect(try ChemistryWorkerFiles.read(after.appendingPathComponent("attempt/receipt.json"), limit: 1024) == Data("receipt".utf8))
        #expect(try ChemistryWorkerFiles.child("ChemistryJobs", root: root).path == before.path)
    }

    @Test func chemistryPathStillRejectsInternalAliasesAndEscapes() throws {
        let root = root(), outside = self.root()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Real"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Alias"), withDestinationURL: root.appendingPathComponent("Real"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Outside"), withDestinationURL: outside)
        #expect(throws: (any Error).self) { try ChemistryWorkerFiles.child("Alias", root: root) }
        #expect(throws: (any Error).self) { try ChemistryWorkerFiles.child("Outside/receipt.json", root: root) }
        #expect(throws: (any Error).self) { try ChemistryWorkerFiles.child("../receipt.json", root: root) }
    }

    @Test func trashDefaultsOnAndPersistsAnExplicitOff() throws {
        let name = "next-round-trash-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(PersonalLibraryDeletionPreferences.usesTrash(in: defaults))
        defaults.set(false, forKey: PersonalLibraryDeletionPreferences.trashEnabledKey)
        #expect(!PersonalLibraryDeletionPreferences.usesTrash(in: defaults))
    }

    @Test func nativeDeletionUsesTheFrozenChoiceAndKeepsExistingTrash() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let library = PersonalContentLibrary(root: root)
        let retained = try await create(library), removed = try await create(library), untouched = try await create(library)
        try await PersonalLibraryFileActions.deleteFromFiles(.work(retained), usingTrash: true, environment: nil, library: library)
        let event = try #require(try await library.recentlyDeleted().first)
        try await PersonalLibraryFileActions.deleteFromFiles(.work(removed), usingTrash: false, environment: nil, library: library)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(removed.relativePath).path))
        #expect(try Data(contentsOf: root.appendingPathComponent(retained.relativePath).appendingPathComponent("original.txt")) == Data("original bytes".utf8))
        #expect(try await library.recentlyDeleted().map(\.id) == [event.id])
        #expect(try await library.resolve(untouched.id).record.id == untouched.id)
        try await PersonalLibraryFileActions.restore(event, environment: nil, library: library)
        #expect(try await library.resolve(retained.id).record.id == retained.id)
    }

    @Test func batchRestoreRestoresSelectedParentsBeforeIndependentlyDeletedChildren() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let library = PersonalContentLibrary(root: root)
        try await library.createFolder("Parent", in: [])
        let child = try await create(library, in: ["Parent"])
        let childEntry = try await library.softDelete(child)
        let folder = try #require(try await library.folderSnapshots(in: []).first)
        let parentEntry = try await library.softDeleteFolder(folder, expectedProjectIDs: [child.id])
        let result = await PersonalLibraryFileActions.restoreBatch([childEntry, parentEntry], environment: nil, library: library)
        #expect(result.failed.isEmpty)
        #expect(result.restored == [parentEntry.id, childEntry.id])
        #expect(try await library.resolve(child.id).record.id == child.id)
    }

    @Test func batchRestoreReportsOnlyTheStaleItemAndKeepsItsNewDeletion() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let library = PersonalContentLibrary(root: root)
        let first = try await create(library), second = try await create(library)
        let stale = try await library.softDelete(first), valid = try await library.softDelete(second)
        try await library.restore(stale.id)
        let current = try await library.softDelete(first)
        let result = await PersonalLibraryFileActions.restoreBatch([stale, valid], environment: nil, library: library)
        #expect(result.restored == [valid.id])
        #expect(result.failed.map { $0.entry.id } == [stale.id])
        #expect(try await library.recentlyDeleted().map(\.id) == [current.id])
    }

    @Test func selectAllDeletionPlanningSupportsMoreThanOneStorageBatch() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let library = PersonalContentLibrary(root: root)
        var entries: [PersonalLibraryTrashEntry] = []
        for _ in 0..<129 {
            let record = try await create(library)
            entries.append(try await library.softDelete(record))
        }
        let plans = try await PersonalLibraryFileActions.permanentDeletionPlans(entries, environment: nil, library: library)
        #expect(Set(plans.map(\.id)) == Set(entries.map(\.id)))
        #expect(plans.count == 129)
    }
}
#endif
