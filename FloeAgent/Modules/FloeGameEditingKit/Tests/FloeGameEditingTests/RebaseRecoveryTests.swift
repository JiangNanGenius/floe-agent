// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeGameCore
@testable import FloeGameEditingCore

@Suite("Retained rebase and deletion decisions")
struct RebaseRecoveryTests {
    @MainActor private func fixture(_ name: String) async throws -> (FileGameProjectRepository, GameEditingSession, GameRelativePath) {
        let (_, repository) = try TestSupport.makeRepository(name: name)
        let id = UUID(), empty = try await repository.createProject(projectID: id, owner: TestSupport.owner, title: "Recovery")
        let path = try GameRelativePath("loose.txt")
        _ = try await repository.commit(id, owner: TestSupport.owner, expectedRevision: empty.revision,
                                       changes: [.write(path, Data("original".utf8))])
        return (repository, try await GameEditingSession.open(repository: repository, projectID: id,
            owner: TestSupport.owner, adapter: GameUnknownEditingAdapter(engine: .phaser)), path)
    }
    @MainActor private func conflictAfterExternal(_ repository: FileGameProjectRepository, _ session: GameEditingSession,
                                                 changes: [GameFileChange]) async throws {
        _ = try await repository.commit(session.projectID, owner: session.owner,
                                        expectedRevision: session.expectedRevision, changes: changes)
        do { _ = try await session.save(); Issue.record("external change must conflict") }
        catch let error as GameProjectError { guard case .conflict = error else { throw error } }
        try await session.reloadForRebase()
    }

    @Test("A local deletion cannot erase a newer IDE edit without a decision")
    @MainActor func localDeleteKeepsTheirs() async throws {
        let (repository, session, path) = try await fixture("local-delete-theirs")
        try await session.apply(.remove(path: path, before: Data("original".utf8), referenceUpdates: [], summary: .init("Delete", "删除")))
        try await conflictAfterExternal(repository, session, changes: [.write(path, Data("new IDE edit".utf8))])
        #expect(session.fileConflicts[path]?.localDeletion == true)
        do { _ = try await session.save(); Issue.record("unreviewed deletion must not save") } catch is GameEditIssue { }
        try session.resolveConflict(at: path, .keepTheirs)
        let saved = try await session.save()
        let actual = try await repository.read(session.projectID, owner: session.owner, revision: saved.revision, path: path)
        #expect(actual == Data("new IDE edit".utf8))
        #expect(!session.removedPaths.contains(path))
    }

    @Test("Accepting an external deletion does not recreate an empty file")
    @MainActor func remoteDeletionStaysDeleted() async throws {
        let (repository, session, path) = try await fixture("remote-delete")
        try await session.replaceAsset(at: path, with: Data("local edit".utf8))
        try await conflictAfterExternal(repository, session, changes: [.remove(path)])
        #expect(session.fileConflicts[path]?.remoteDeletion == true)
        try session.resolveConflict(at: path, .keepTheirs)
        let saved = try await session.save()
        #expect(!saved.files.contains { $0.path == path })
        #expect(!session.documentExists(at: path))
    }

    @Test("Explicitly retaining a deletion survives another reopen and removes the file")
    @MainActor func retainedDeletionReopens() async throws {
        let (repository, session, path) = try await fixture("retain-delete")
        try await session.apply(.remove(path: path, before: Data("original".utf8), referenceUpdates: [], summary: .init("Delete", "删除")))
        try await conflictAfterExternal(repository, session, changes: [.write(path, Data("new IDE edit".utf8))])
        try session.resolveConflict(at: path, .keepMine)
        let reopened = try await GameEditingSession.open(repository: repository, projectID: session.projectID,
            owner: session.owner, adapter: session.adapter)
        #expect(reopened.pendingDraft != nil)
        try await reopened.recoverDraft()
        #expect(reopened.fileConflicts.isEmpty)
        #expect(reopened.removedPaths.contains(path))
        let saved = try await reopened.save()
        #expect(!saved.files.contains { $0.path == path })
    }

    @Test("Nonconflicting new files survive rebase and crash while clean cached bytes refresh")
    @MainActor func rebaseRetainsNewFilesAndRefreshesCache() async throws {
        let (repository, session, path) = try await fixture("nonconflict-retained")
        try await session.replaceAsset(at: path, with: Data("saved once".utf8))
        _ = try await session.save()
        _ = try await session.importAssets([("new.txt", Data("unsaved new file".utf8))])
        try await conflictAfterExternal(repository, session, changes: [.write(path, Data("updated IDE bytes".utf8))])
        #expect(session.fileConflicts.isEmpty)
        #expect(try await session.documentBytes(at: path) == Data("updated IDE bytes".utf8))
        let reopened = try await GameEditingSession.open(repository: repository, projectID: session.projectID,
            owner: session.owner, adapter: session.adapter)
        #expect(reopened.pendingDraft != nil)
        try await reopened.recoverDraft()
        #expect(reopened.fileConflicts.isEmpty)
        #expect(try await reopened.documentBytes(at: GameRelativePath("new.txt")) == Data("unsaved new file".utf8))
        let saved = try await reopened.save()
        #expect(saved.files.contains { $0.path.value == "new.txt" })
    }

    @Test("Undoing the final dirty edit cannot resurrect an obsolete draft later")
    @MainActor func undoCleanClearsObsoleteDraft() async throws {
        let (repository, session, path) = try await fixture("undo-clean")
        try await session.replaceAsset(at: path, with: Data("discarded by undo".utf8))
        try await session.undo()
        #expect(!session.isDirty)
        let reopened = try await GameEditingSession.open(repository: repository, projectID: session.projectID,
            owner: session.owner, adapter: session.adapter)
        #expect(reopened.pendingDraft == nil)
        #expect(try await reopened.documentBytes(at: path) == Data("original".utf8))
    }
}
