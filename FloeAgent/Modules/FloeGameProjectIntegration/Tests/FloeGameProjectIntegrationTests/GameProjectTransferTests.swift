// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
import FloeGameAuthoring
@testable import FloeGameProjectIntegration

@MainActor final class GameProjectTransferTests: XCTestCase {
    func testAllTwentyEnginesCopyExactFilesWithoutSharingOwnership() async throws {
        XCTAssertEqual(GameEngineID.allCases.count, 20)
        for engine in GameEngineID.allCases {
            let f = try await Fixture.make(sourceEngine: engine, destinationEngine: engine)
            defer { f.remove() }
            let preview = try await f.service.prepare(from: f.source, to: f.destination, mode: .importIntoEmptyProject)
            XCTAssertEqual(preview.engineHint, engine)
            XCTAssertEqual(preview.fileCount, 2)
            let receipt = try await f.service.commit(preview.id)
            XCTAssertEqual(receipt.project.owner, f.destination.context.owner)
            XCTAssertEqual(receipt.project.parent, f.destination.context.savedRevision)
            XCTAssertEqual(receipt.engineHint, engine)
            XCTAssertFalse(receipt.cleanupPending)
            let before = try await f.source.repository.open(f.source.context.projectID, owner: f.source.context.owner)
            XCTAssertEqual(before.revision, f.source.context.savedRevision)
            XCTAssertEqual(receipt.project.files, before.files)
            XCTAssertEqual(receipt.project.directories, before.directories)
            _ = try await f.source.repository.commit(before.projectID, owner: before.owner,
                expectedRevision: before.revision, changes: [.write(try GameRelativePath("main.txt"), Data("later source".utf8))])
            let copied = try await f.destination.repository.read(receipt.project.projectID,
                owner: receipt.project.owner, revision: receipt.project.revision, path: GameRelativePath("main.txt"))
            XCTAssertEqual(copied, Data("original".utf8))
        }
    }

    func testUpdatePreviewAndHistoryPreserveIndependentDestination() async throws {
        let f = try await Fixture.make(destinationContent: true); defer { f.remove() }
        let preview = try await f.service.prepare(from: f.source, to: f.destination, mode: .updateExistingCopy)
        XCTAssertEqual(preview.removedPaths.map(\.value), ["only-in-space.txt"])
        XCTAssertEqual(preview.modifiedPaths.map(\.value), ["main.txt"])
        let saved = try await f.service.commit(preview.id)
        let old = try await f.destination.repository.readHistorical(saved.project.projectID,
            owner: saved.project.owner, expectedRevision: saved.project.revision,
            historicalRevision: f.destination.context.savedRevision, path: GameRelativePath("main.txt"))
        XCTAssertEqual(old, Data("independent destination".utf8))
        XCTAssertFalse(saved.project.files.contains { $0.path.value == "only-in-space.txt" })
    }

    func testDestinationChangedAfterPreviewCannotBeOverwritten() async throws {
        let f = try await Fixture.make(); defer { f.remove() }
        let preview = try await f.service.prepare(from: f.source, to: f.destination, mode: .importIntoEmptyProject)
        let newer = try await f.destination.repository.commit(f.destination.context.projectID,
            owner: f.destination.context.owner, expectedRevision: f.destination.context.savedRevision,
            changes: [.write(try GameRelativePath("newer.txt"), Data([42]))])
        do { _ = try await f.service.commit(preview.id); XCTFail("Must retain the newer destination") }
        catch { }
        let actual = try await f.destination.repository.open(newer.projectID, owner: newer.owner)
        XCTAssertEqual(actual, newer)
    }

    func testSourceChangedAfterPreviewRequiresFreshExplicitSave() async throws {
        let f = try await Fixture.make(); defer { f.remove() }
        let preview = try await f.service.prepare(from: f.source, to: f.destination, mode: .importIntoEmptyProject)
        _ = try await f.source.repository.commit(f.source.context.projectID, owner: f.source.context.owner,
            expectedRevision: f.source.context.savedRevision, changes: [.write(try GameRelativePath("main.txt"), Data([4]))])
        do { _ = try await f.service.commit(preview.id); XCTFail("The preview no longer describes the current source") }
        catch { }
        let actual = try await f.destination.repository.open(f.destination.context.projectID, owner: f.destination.context.owner)
        XCTAssertEqual(actual.revision, f.destination.context.savedRevision)
        XCTAssertTrue(actual.files.isEmpty)
    }

    func testStagedCorruptionDoesNotPublishDifferentBytes() async throws {
        let f = try await Fixture.make(); defer { f.remove() }
        let preview = try await f.service.prepare(from: f.source, to: f.destination, mode: .importIntoEmptyProject)
        let path = f.staging.appendingPathComponent(preview.id.uuidString.lowercased() + "/Source/main.txt")
        try Data("damaged".utf8).write(to: path)
        do { _ = try await f.service.commit(preview.id); XCTFail("Corrupted staging must not publish") }
        catch { XCTAssertEqual(error as? GameProjectError, .corruptStorage) }
        let actual = try await f.destination.repository.open(f.destination.context.projectID, owner: f.destination.context.owner)
        XCTAssertTrue(actual.files.isEmpty)
    }

    func testDuplicateCommitReturnsSameReceiptAndSingleRevision() async throws {
        let f = try await Fixture.make(); defer { f.remove() }
        let preview = try await f.service.prepare(from: f.source, to: f.destination, mode: .importIntoEmptyProject)
        let first = try await f.service.commit(preview.id)
        let second = try await f.service.commit(preview.id)
        XCTAssertEqual(first.project, second.project)
        let history = try await f.destination.repository.history(first.project.projectID, owner: first.project.owner)
        XCTAssertEqual(history.count, 2)
    }

    func testDifferentDeclaredEnginesRequireNewConversionProject() async throws {
        let f = try await Fixture.make(sourceEngine: .phaser, destinationEngine: .unity, destinationContent: true)
        defer { f.remove() }
        do {
            _ = try await f.service.prepare(from: f.source, to: f.destination, mode: .updateExistingCopy)
            XCTFail("Must not silently change the destination engine")
        } catch { XCTAssertEqual(error as? GameProjectTransferError, .engineChangeRequiresNewProject) }
    }

    func testNewImportDoesNotReplacePopulatedDestinationAndDiscardRemovesOwnJob() async throws {
        let full = try await Fixture.make(destinationContent: true); defer { full.remove() }
        do {
            _ = try await full.service.prepare(from: full.source, to: full.destination, mode: .importIntoEmptyProject)
            XCTFail("Import follows creation of an empty project")
        } catch { XCTAssertEqual(error as? GameProjectError, .importDestinationNotEmpty) }
        let f = try await Fixture.make(); defer { f.remove() }
        let preview = try await f.service.prepare(from: f.source, to: f.destination, mode: .importIntoEmptyProject)
        try await f.service.discard(preview.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.staging.appendingPathComponent(preview.id.uuidString.lowercased()).path))
        do { _ = try await f.service.commit(preview.id); XCTFail("A discarded copy cannot commit") }
        catch { XCTAssertEqual(error as? GameProjectTransferError, .unknownTransfer) }
    }

    func testPostCommitPresentationFailureReturnsRecoverableCompletedReceipt() async throws {
        let f = try await Fixture.make(); defer { f.remove() }
        await f.destinationContexts.failAfterCommit()
        let preview = try await f.service.prepare(from: f.source, to: f.destination, mode: .importIntoEmptyProject)
        let receipt = try await f.service.commit(preview.id)
        XCTAssertTrue(receipt.requiresReopen)
        let saved = try await f.destination.repository.open(receipt.project.projectID, owner: receipt.project.owner)
        XCTAssertEqual(saved, receipt.project)
        let recorded = await f.service.receipt(for: preview.id)
        XCTAssertEqual(recorded?.project.revision, saved.revision)
    }

    func testLastSpaceDestinationPersistsWithoutSharingSourceOwner() async throws {
        let f = try await Fixture.make(); defer { f.remove() }
        let preview = try await f.service.prepare(from: f.source, to: f.destination, mode: .importIntoEmptyProject)
        let receipt = try await f.service.commit(preview.id)
        let link = try GameProjectCopyLink(source: f.source.context, receipt: receipt)
        let suite = "game-copy-tests." + UUID().uuidString
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = try GameProjectCopyLinkStore(suiteName: suite)
        let saved = try await store.save(link, for: f.source.context, expected: nil)
        XCTAssertTrue(saved)
        let reopened = try GameProjectCopyLinkStore(suiteName: suite)
        let readback = try await reopened.link(for: f.source.context)
        XCTAssertEqual(readback, link)
        let anotherOwner = try GameProjectContext(projectID: f.source.context.projectID,
            owner: .conversation(conversationID: UUID(), workspaceID: UUID()), rootURL: f.source.context.rootURL,
            savedRevision: f.source.context.savedRevision)
        let unrelated = try await reopened.link(for: anotherOwner)
        XCTAssertNil(unrelated)
        let actual = try await f.destination.repository.open(receipt.project.projectID, owner: receipt.project.owner)
        XCTAssertEqual(actual.revision, receipt.project.revision)
    }

    func testLatePreferenceUpdateCannotReplaceNewerChoice() async throws {
        let f = try await Fixture.make(); defer { f.remove() }
        let preview = try await f.service.prepare(from: f.source, to: f.destination, mode: .importIntoEmptyProject)
        let first = try await f.service.commit(preview.id)
        let firstLink = try GameProjectCopyLink(source: f.source.context, receipt: first)
        let updatedContext = try GameProjectContext(projectID: first.project.projectID, owner: first.project.owner,
            rootURL: f.destination.context.rootURL, savedRevision: first.project.revision)
        let destination = GameProjectTransferEndpoint(context: updatedContext, repository: f.destination.repository,
                                                      contexts: f.destinationContexts)
        let nextPreview = try await f.service.prepare(from: f.source, to: destination, mode: .updateExistingCopy)
        let next = try await f.service.commit(nextPreview.id)
        let nextLink = try GameProjectCopyLink(source: f.source.context, receipt: next)
        let suite = "game-copy-tests." + UUID().uuidString
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = try GameProjectCopyLinkStore(suiteName: suite)
        let initial = try await store.save(firstLink, for: f.source.context, expected: nil)
        XCTAssertTrue(initial)
        let stale = try await store.save(nextLink, for: f.source.context, expected: nil)
        XCTAssertFalse(stale)
        let current = try await store.save(nextLink, for: f.source.context, expected: firstLink)
        XCTAssertTrue(current)
        let staleForget = try await store.forget(for: f.source.context, expected: firstLink)
        XCTAssertFalse(staleForget)
        let final = try await store.link(for: f.source.context)
        XCTAssertEqual(final, nextLink)
    }

    func testCleanupFailureDoesNotRepeatCompletedCommitAndCanBeRetried() async throws {
        let f = try await Fixture.make(); defer { f.remove() }
        let removal = FailingOnceRemoval()
        let service = try GameProjectTransferService(stagingDirectory: f.staging,
            removeOwnedDirectory: { try removal.remove($0) })
        let preview = try await service.prepare(from: f.source, to: f.destination, mode: .importIntoEmptyProject)
        let committed = try await service.commit(preview.id)
        XCTAssertTrue(committed.cleanupPending)
        let repeated = try await service.commit(preview.id)
        XCTAssertEqual(repeated.project.revision, committed.project.revision)
        let pending = await service.pendingCleanupIDs()
        XCTAssertEqual(pending, [preview.id])
        let cleaned = try await service.retryCleanup(preview.id)
        XCTAssertEqual(cleaned?.project.revision, committed.project.revision)
        XCTAssertEqual(cleaned?.cleanupPending, false)
        let remaining = await service.pendingCleanupIDs()
        XCTAssertTrue(remaining.isEmpty)
        let history = try await f.destination.repository.history(committed.project.projectID, owner: committed.project.owner)
        XCTAssertEqual(history.count, 2)
    }
}

/// Only the filesystem removal is injected; repositories and transfer bytes are real.
private final class FailingOnceRemoval: @unchecked Sendable {
    private let lock = NSLock()
    private var failed = false
    func remove(_ url: URL) throws {
        lock.lock()
        if !failed { failed = true; lock.unlock(); throw CocoaError(.fileWriteNoPermission) }
        lock.unlock()
        try FileManager.default.removeItem(at: url)
    }
}

private actor RepositoryContexts: GameAuthoringContextHost {
    let repository: FileGameProjectRepository
    let projectID: UUID
    let owner: GameProjectOwner
    let root: URL
    private var failAfterSave = false
    init(repository: FileGameProjectRepository, projectID: UUID, owner: GameProjectOwner, root: URL) {
        self.repository = repository; self.projectID = projectID; self.owner = owner; self.root = root
    }
    func currentContext(for context: GameProjectContext) async throws -> GameProjectContext {
        guard context.projectID == projectID, context.owner == owner, context.rootURL == root else { throw GameProjectError.invalidContext }
        let saved = try await repository.open(projectID, owner: owner)
        return try GameProjectContext(projectID: projectID, owner: owner, rootURL: root, savedRevision: saved.revision)
    }
    func failAfterCommit() { failAfterSave = true }
    func contextAfterCommit(_ project: GameStoredProject, previous: GameProjectContext) async throws -> GameProjectContext {
        if failAfterSave { throw GameProjectError.rootUnavailable }
        return try await currentContext(for: previous)
    }
}

private struct Fixture: Sendable {
    let root: URL
    let staging: URL
    let source: GameProjectTransferEndpoint
    let destination: GameProjectTransferEndpoint
    let destinationContexts: RepositoryContexts
    let service: GameProjectTransferService

    static func make(sourceEngine: GameEngineID? = .phaser, destinationEngine: GameEngineID? = .phaser,
                     destinationContent: Bool = false) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("game-copy-" + UUID().uuidString, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let sourceRoot = root.appendingPathComponent("ChatFiles", isDirectory: true)
        let destinationRoot = root.appendingPathComponent("SpaceFiles", isDirectory: true)
        let staging = root.appendingPathComponent("TransferJobs", isDirectory: true)
        for url in [sourceRoot, destinationRoot, staging, sourceRoot.appendingPathComponent("Empty", isDirectory: true)] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try Data("original".utf8).write(to: sourceRoot.appendingPathComponent("main.txt"))
        try Data([0, 255, 4, 0]).write(to: sourceRoot.appendingPathComponent(".unknown-binary"))
        let sourceRepo = try FileGameProjectRepository(directory: root.appendingPathComponent("ChatHistory"))
        let destinationRepo = try FileGameProjectRepository(directory: root.appendingPathComponent("SpaceHistory"))
        let sourceID = UUID(), destinationID = UUID()
        let sourceOwner = GameProjectOwner.conversation(conversationID: UUID(), workspaceID: UUID())
        let destinationOwner = GameProjectOwner.space(recordID: destinationID)
        let emptySource = try await sourceRepo.createProject(projectID: sourceID, owner: sourceOwner, title: "Chat game", engine: sourceEngine)
        let source = try await sourceRepo.importContents(from: sourceRoot, into: sourceID, owner: sourceOwner, expectedRevision: emptySource.revision)
        var destination = try await destinationRepo.createProject(projectID: destinationID, owner: destinationOwner, title: "Space game", engine: destinationEngine)
        if destinationContent {
            destination = try await destinationRepo.commit(destinationID, owner: destinationOwner,
                expectedRevision: destination.revision, changes: [
                    .write(try GameRelativePath("main.txt"), Data("independent destination".utf8)),
                    .write(try GameRelativePath("only-in-space.txt"), Data([3]))])
        }
        let sourceContexts = RepositoryContexts(repository: sourceRepo, projectID: sourceID, owner: sourceOwner, root: sourceRoot)
        let destinationContexts = RepositoryContexts(repository: destinationRepo, projectID: destinationID, owner: destinationOwner, root: destinationRoot)
        return try .init(root: root, staging: staging,
            source: .init(context: GameProjectContext(projectID: sourceID, owner: sourceOwner, rootURL: sourceRoot, savedRevision: source.revision),
                repository: sourceRepo, contexts: sourceContexts),
            destination: .init(context: GameProjectContext(projectID: destinationID, owner: destinationOwner, rootURL: destinationRoot, savedRevision: destination.revision),
                repository: destinationRepo, contexts: destinationContexts),
            destinationContexts: destinationContexts, service: GameProjectTransferService(stagingDirectory: staging))
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
