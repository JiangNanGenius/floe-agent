// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import FloeApp

@Suite("Personal Library permanent deletion", .serialized)
struct LibraryPermanentDeletionTests {
    private func location() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("library-purge-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false); return url
    }
    private func create(_ library: PersonalContentLibrary, title: String = "Owned fixture", folders: [String] = [], kind: PersonalContentKind = .document) async throws -> PersonalContentRecord {
        try await library.create(kind: kind, title: title, in: folders) { directory, _ in
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("Assets"), withIntermediateDirectories: false)
            try Data("owned source\0fixture".utf8).write(to: directory.appendingPathComponent("Assets/source.bin"))
            try Data("undo+revision+receipt".utf8).write(to: directory.appendingPathComponent("history.json"))
        }
    }
    private func firstPlan(_ library: PersonalContentLibrary, _ entry: PersonalLibraryTrashEntry) async throws -> PersonalPermanentDeletePlan {
        let plans = try await library.permanentDeletionPlans([entry]); return try #require(plans.first)
    }
    private func payload(_ root: URL) throws -> [String: Data] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return [:] }
        var result: [String: Data] = [:]
        for case let url as URL in enumerator {
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if info.isRegularFile == true, info.isSymbolicLink != true { result[String(url.path.dropFirst(root.path.count + 1))] = try Data(contentsOf: url) }
        }
        return result
    }
    @Test func softDeletePreservesBytesThenPermanentDeletionRemovesOriginalAndIndex() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let library = PersonalContentLibrary(root: root), record = try await create(library)
        let original = root.appendingPathComponent(record.relativePath)
        let before = try payload(original), entry = try await library.softDelete(record)
        #expect(try payload(original) == before)
        let plan = try await firstPlan(library, entry), result = try await library.permanentlyDelete(plan)
        #expect(result.removedEntryIDs == [entry.id]); #expect(result.projectIDs == [record.id])
        #expect(!FileManager.default.fileExists(atPath: original.path))
        #expect(try await PersonalContentLibrary(root: root).recentlyDeleted().isEmpty)
        #expect(try await library.records(includingDeleted: true).isEmpty)
    }
    @Test func legacyTombstoneHasFreshConfirmationIdentityAndRestoreStillWorks() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let library = PersonalContentLibrary(root: root), record = try await create(library)
        var entry = try await library.softDelete(record)
        var state = try PersonalLibraryTrashStore.read(root: root); state.entries[0].resourceIdentity = nil
        try PersonalLibraryTrashStore.write(state, root: root); entry.resourceIdentity = nil
        let plan = try await firstPlan(library, entry)
        #expect(plan.identity.count == 64 && !plan.cleanupPending)
        try await library.restore(entry.id)
        #expect(try await library.resolve(record.id).record.id == record.id)
        await #expect(throws: Error.self) { _ = try await library.permanentlyDelete(plan) }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(record.relativePath).path))
    }
    @Test func replacedDirectoryAndNewContentRejectBeforeAnyPurgeWrite() async throws {
        let root = try location(), backup = try location(); defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: backup) }
        let library = PersonalContentLibrary(root: root), record = try await create(library)
        let entry = try await library.softDelete(record), plan = try await firstPlan(library, entry)
        let original = root.appendingPathComponent(record.relativePath)
        try Data("unconfirmed new source".utf8).write(to: original.appendingPathComponent("new.bin"))
        let before = try payload(root)
        await #expect(throws: Error.self) { _ = try await library.permanentlyDelete(plan) }
        #expect(try payload(root) == before)
        try FileManager.default.moveItem(at: original, to: backup.appendingPathComponent("saved"))
        try FileManager.default.copyItem(at: backup.appendingPathComponent("saved"), to: original)
        let replacement = try payload(root)
        await #expect(throws: Error.self) { _ = try await library.permanentDeletionPlans([entry]) }
        #expect(try payload(root) == replacement)
    }
    @Test func restoredThenRedeletedEntryCannotReuseOldConfirmation() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let library = PersonalContentLibrary(root: root), record = try await create(library)
        let old = try await library.softDelete(record), plan = try await firstPlan(library, old)
        try await library.restore(old.id); let new = try await library.softDelete(record)
        await #expect(throws: Error.self) { _ = try await library.permanentlyDelete(plan) }
        #expect(try await library.recentlyDeleted().map(\.id) == [new.id])
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(record.relativePath).path))
    }
    @Test func selectedFolderAbsorbsChildTombstoneButPreservesUnselectedPrefix() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let library = PersonalContentLibrary(root: root)
        try await library.createFolder("A", in: []); try await library.createFolder("AB", in: [])
        let child = try await create(library, folders: ["A"]), outside = try await create(library, folders: ["AB"])
        let childEntry = try await library.softDelete(child)
        let folder = try #require(try await library.folderSnapshots(in: []).first { $0.name == "A" })
        let parent = try await library.softDeleteFolder(folder, expectedProjectIDs: [child.id])
        let plans = try await library.permanentDeletionPlans([childEntry, parent])
        #expect(plans.count == 1)
        let plan = try #require(plans.first), receipt = try await library.permanentlyDelete(plan)
        #expect(Set(receipt.removedEntryIDs) == [childEntry.id, parent.id])
        #expect(try await library.resolve(outside.id).record.id == outside.id)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("A").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("AB").path))
    }
    @Test func folderWithUnrecognizedOriginalCannotBypassLifecycleProtection() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let library = PersonalContentLibrary(root: root); try await library.createFolder("Owned folder", in: [])
        let record = try await create(library, folders: ["Owned folder"])
        let folders = try await library.folderSnapshots(in: []), folder = try #require(folders.first)
        let entry = try await library.softDeleteFolder(folder, expectedProjectIDs: [record.id])
        try Data("broken descriptor".utf8).write(to: root.appendingPathComponent(record.relativePath).appendingPathComponent("FloeProject.json"))
        let before = try payload(root)
        await #expect(throws: PersonalContentError.invalidProject) { _ = try await library.permanentDeletionPlans([entry]) }
        #expect(try payload(root) == before)
        #expect(try await library.recentlyDeleted().contains(entry))
    }
    @Test func leafSymlinkUnlinksOnlyLinkAndAncestorSymlinkCannotEscapeLibrary() async throws {
        let root = try location(), outside = try location(); defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let sentinel = outside.appendingPathComponent("keep.bin"); try Data("outside unchanged".utf8).write(to: sentinel)
        let library = PersonalContentLibrary(root: root), record = try await create(library)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(record.relativePath).appendingPathComponent("Assets/foreign"), withDestinationURL: outside)
        let entry = try await library.softDelete(record), plan = try await firstPlan(library, entry)
        _ = try await library.permanentlyDelete(plan)
        #expect(try Data(contentsOf: sentinel) == Data("outside unchanged".utf8))
        try await library.createFolder("A", in: [])
        let nested = try await create(library, folders: ["A"]), nestedEntry = try await library.softDelete(nested)
        let nestedPlan = try await firstPlan(library, nestedEntry)
        try FileManager.default.moveItem(at: root.appendingPathComponent("A"), to: root.appendingPathComponent(".saved-A"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("A"), withDestinationURL: outside)
        await #expect(throws: Error.self) { _ = try await library.permanentlyDelete(nestedPlan) }
        #expect(try Data(contentsOf: sentinel) == Data("outside unchanged".utf8))
    }
    @Test func partialPhysicalFailureRetainsJournalAndRetriesWithNewSnapshot() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let library = PersonalContentLibrary(root: root), record = try await create(library)
        let entry = try await library.softDelete(record), plan = try await firstPlan(library, entry)
        await #expect(throws: PersonalPermanentDeleteError.incomplete) {
            _ = try await library.permanentlyDelete(plan) { point in
                if case .removedNode = point { throw PersonalContentError.storageUnavailable }
            }
        }
        #expect(try await library.recentlyDeleted().contains(entry))
        #expect(try await library.permanentDeletionPendingIDs() == [entry.id])
        await #expect(throws: PersonalPermanentDeleteError.incomplete) { try await library.restore(entry.id) }
        let reopened = PersonalContentLibrary(root: root), retry = try await firstPlan(reopened, entry)
        #expect(retry.cleanupPending)
        _ = try await reopened.permanentlyDelete(retry)
        #expect(try await reopened.recentlyDeleted().isEmpty)
        #expect(try await reopened.permanentDeletionPendingIDs().isEmpty)
    }
    @Test func restartBeforeStagingKeepsOriginalRestorableAndRetryable() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let library = PersonalContentLibrary(root: root), record = try await create(library)
        let entry = try await library.softDelete(record), plan = try await firstPlan(library, entry)
        let journal = root.appendingPathComponent(".FloeLibraryPurge-" + entry.id.uuidString + ".json")
        let captured = root.appendingPathComponent(".captured-real-journal")
        await #expect(throws: PersonalContentError.storageUnavailable) {
            _ = try await library.permanentlyDelete(plan) { point in
                if case .beforeIrreversible = point {
                    // Capture the actual committed journal, then let the real
                    // pre-commit failure restore the original. Reinstalling
                    // those exact bytes recreates exit between journal/rename.
                    try Data(contentsOf: journal).write(to: captured)
                    throw PersonalContentError.storageUnavailable
                }
            }
        }
        let bytes = try Data(contentsOf: captured); try FileManager.default.removeItem(at: captured)
        try bytes.write(to: journal)
        let reopened = PersonalContentLibrary(root: root), retry = try await firstPlan(reopened, entry)
        #expect(retry.cleanupPending)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(record.relativePath).path))
        // The pre-stage intent removed no body bytes and must not prevent the
        // ordinary Restore path after restart.
        try await reopened.restore(entry.id)
        #expect(try await reopened.resolve(record.id).record.id == record.id)
        #expect(!FileManager.default.fileExists(atPath: journal.path))
        let again = try await reopened.softDelete(record), next = try await firstPlan(reopened, again)
        _ = try await reopened.permanentlyDelete(next)
        #expect(try await reopened.recentlyDeleted().isEmpty)
    }
    @Test func indexCommitFailureKeepsExactRetryRecordEvenWhenBytesAreAlreadyRemoved() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let library = PersonalContentLibrary(root: root), record = try await create(library)
        let entry = try await library.softDelete(record), plan = try await firstPlan(library, entry)
        await #expect(throws: PersonalPermanentDeleteError.incomplete) {
            _ = try await library.permanentlyDelete(plan) { point in
                if case .beforeIndexCommit = point { throw PersonalContentError.storageUnavailable }
            }
        }
        #expect(try await library.recentlyDeleted().contains(entry))
        let retry = try await firstPlan(PersonalContentLibrary(root: root), entry)
        #expect(retry.cleanupPending && retry.fileCount == 0)
        _ = try await library.permanentlyDelete(retry)
        #expect(try await library.recentlyDeleted().isEmpty)
    }
    @Test func cancellationBeforeCommitRollsBackAndAfterCommitReportsActualRemoval() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let library = PersonalContentLibrary(root: root), record = try await create(library)
        let entry = try await library.softDelete(record), plan = try await firstPlan(library, entry), before = try payload(root)
        let early = Task {
            try await library.permanentlyDelete(plan) { point in
                if case .beforeIrreversible = point { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: CancellationError.self) { _ = try await early.value }
        #expect(try payload(root) == before)
        #expect(try await library.permanentDeletionPendingIDs().isEmpty)
        let next = try await firstPlan(library, entry)
        let late = Task {
            try await library.permanentlyDelete(next) { point in
                if case .removedNode = point { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        let receipt = try await late.value
        #expect(receipt.entryID == entry.id)
        #expect(try await library.recentlyDeleted().isEmpty)
    }
    @Test func biologyWrapperIsNeverMisreportedAsDeletingItsSeparateNativeOriginal() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let library = PersonalContentLibrary(root: root), record = try await create(library, kind: .biology)
        let entry = try await library.softDelete(record), before = try payload(root)
        await #expect(throws: PersonalPermanentDeleteError.unsupportedOriginal) { _ = try await library.permanentDeletionPlans([entry]) }
        #expect(try payload(root) == before)
        try await library.restore(entry.id)
        #expect(try await library.resolve(record.id).record.id == record.id)
    }
    #if canImport(UIKit)
    @Test @MainActor func selectedBatchKeepsBusyAndUnselectedEntriesAndCanRetry() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let library = PersonalContentLibrary(root: root)
        let busy = try await create(library, title: "Busy"), ready = try await create(library, title: "Ready"), unselected = try await create(library, title: "Unselected")
        let use = try PersonalLibraryFileActions.acquireUse(id: busy.id, directory: root.appendingPathComponent(busy.relativePath), libraryRoot: root)
        defer { use.release() }
        let first = try await library.softDelete(busy), second = try await library.softDelete(ready), untouched = try await library.softDelete(unselected)
        let plans = try await library.permanentDeletionPlans([first, second])
        let result = await PersonalLibraryFileActions.permanentlyDeleteBatch(plans, environment: nil, library: library)
        #expect(result.deleted.map(\.entryID) == [second.id])
        #expect(result.failed.map(\.entryID) == [first.id])
        #expect(Set(try await library.recentlyDeleted().map(\.id)) == [first.id, untouched.id])
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(unselected.relativePath).path))
        use.release()
        let retry = try await library.permanentDeletionPlans([first])
        let finished = await PersonalLibraryFileActions.permanentlyDeleteBatch(retry, environment: nil, library: library)
        #expect(finished.failed.isEmpty && finished.deleted.count == 1)
        #expect(try await library.recentlyDeleted().map(\.id) == [untouched.id])
    }
    @Test @MainActor func actualUsageLeaseBlocksPermanentDeletionUntilReleased() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let library = PersonalContentLibrary(root: root), record = try await create(library)
        let use = try PersonalLibraryFileActions.acquireUse(id: record.id, directory: root.appendingPathComponent(record.relativePath), libraryRoot: root)
        let entry = try await library.softDelete(record), plan = try await firstPlan(library, entry)
        var refusedActiveUse = false
        do { _ = try await PersonalLibraryFileActions.permanentlyDelete(plan, environment: nil, library: library) }
        catch PersonalFileActionError.closeFirst { refusedActiveUse = true }
        catch { Issue.record("The active usage lease must specifically refuse with closeFirst") }
        #expect(refusedActiveUse)
        use.release()
        _ = try await PersonalLibraryFileActions.permanentlyDelete(plan, environment: nil, library: library)
        #expect(try await library.recentlyDeleted().isEmpty)
    }
    #endif
}
