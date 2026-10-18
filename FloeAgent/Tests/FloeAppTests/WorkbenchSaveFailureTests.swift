// FloeAppTests — Workbench save-failure closure.
//
// Fault injection (read-only store directory, held/released autosave seam)
// pins the live lifecycle contract: a failed close/switch keeps the project,
// preview-adjacent editing state, undo history and error available; a clean
// close never touches a read-only volume; stale autosaves and late tool
// callbacks can neither roll back a newer durable revision nor replace newer
// in-memory edits; an explicitly confirmed discard drops only this session's
// unsaved state. No source file, saved project or other asset is deleted.
//
// Filters: -only-testing:FloeAppTests/WorkbenchSaveFailureTests

#if canImport(UIKit)
import Foundation
import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import FloeCore
import FloeWorkbench
@testable import FloeApp

@Suite("FloeApp.Workbench save failure closure")
@MainActor
struct WorkbenchSaveFailureTests {
    // MARK: - Fixtures

    private struct Environment {
        var root: URL
        var storeDirectory: URL
        var source: URL

        var storeRoot: URL { storeDirectory }
    }

    private func makePNG(at url: URL, width: Int = 64, height: Int = 64) throws {
        let context = try #require(CGContext(data: nil, width: width, height: height,
                                             bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    private func makeEnvironment() throws -> Environment {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-workbench-save-\(UUID().uuidString)", isDirectory: true)
        let store = root.appendingPathComponent("MediaProjects", isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source-\(UUID().uuidString).png")
        try makePNG(at: source)
        return Environment(root: root, storeDirectory: store, source: source)
    }

    /// Restores write access before deleting the isolated fixture tree.
    private func cleanUp(_ environment: Environment) {
        try? setWritable(true, at: environment.storeDirectory)
        try? FileManager.default.removeItem(at: environment.root)
    }

    private func makeCenter(_ environment: Environment) -> WorkbenchCenter {
        let bridge = WorkbenchAIBridge(
            isAvailable: { true },
            imageModels: { [] },
            videoModels: { [] },
            generateImages: { _, _, _, _, _ in [] },
            submitVideo: { _, _, _, _, _ in UUID() },
            refreshJob: { jobID in
                WorkbenchAIJobInfo(id: jobID, state: "running", progress: nil, message: nil,
                                   isActive: true, isWaitStopped: false, modelName: "")
            },
            cancelJob: { _ in },
            jobs: { _ in [] },
            deliverResult: { _ in throw FloeError.notFound("no result") },
            costNote: { _ in "" })
        return WorkbenchCenter(rootProvider: { environment.root }, bridge: bridge,
                               mediaProjectStoreDirectory: environment.storeDirectory)
    }

    private func setWritable(_ writable: Bool, at directory: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: writable ? 0o755 : 0o555],
            ofItemAtPath: directory.path)
    }

    private func projectFile(_ id: UUID, in environment: Environment) -> URL {
        environment.storeDirectory
            .appendingPathComponent("media-project-\(id.uuidString.lowercased()).json")
    }

    private func diskProject(_ id: UUID, in environment: Environment) throws -> MediaProject {
        let data = try Data(contentsOf: projectFile(id, in: environment))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MediaProject.self, from: data)
    }

    private func writeSyntheticProject(name: String, in environment: Environment) throws -> UUID {
        let project = MediaProject(kind: .image, name: name,
                                   canvas: MediaCanvas(width: 320, height: 200))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(project).write(to: projectFile(project.id, in: environment))
        return project.id
    }

    private func openImageProject(_ center: WorkbenchCenter,
                                  _ environment: Environment) async throws -> UUID {
        #expect(await center.startImageProject(sourceURL: environment.source,
                                               owner: .standalone))
        let project = try #require(center.project)
        return project.id
    }

    private func setOpacity(_ center: WorkbenchCenter, _ opacity: Double) -> Bool {
        guard let layerID = center.project?.imageLayers.first(where: { $0.kind == .image })?.id else {
            return false
        }
        return center.apply(.updateLayer(id: layerID, transform: nil, opacity: opacity,
                                         isHidden: nil, isLocked: nil, adjustment: nil,
                                         text: nil, crop: .unchanged))
    }

    // MARK: - Close / retry

    @Test func failedCloseKeepsEditsAndRetryPersistsThem() async throws {
        let environment = try makeEnvironment()
        defer { cleanUp(environment) }
        let center = makeCenter(environment)
        center.autosaveDelayForTesting = .seconds(60)
        let id = try await openImageProject(center, environment)
        let initial = try diskProject(id, in: environment)

        #expect(setOpacity(center, 0.42))
        let editedRevision = try #require(center.project?.revision)
        #expect(editedRevision > initial.revision)
        // Held debounce: the edit exists only in memory right now.
        let durableBefore = try diskProject(id, in: environment)
        #expect(durableBefore.revision == initial.revision)

        try setWritable(false, at: environment.storeDirectory)
        #expect(await center.closeProject() == false,
                "a close whose flush failed must report failure")

        // The editing session survives with its edits and an actionable error.
        #expect(center.project?.revision == editedRevision)
        #expect(center.unsavedChanges)
        #expect(center.saveError != nil)
        // The previous document is intact and decodable.
        let durableDuringFailure = try diskProject(id, in: environment)
        #expect(durableDuringFailure.revision == initial.revision)
        #expect(abs(durableDuringFailure.imageLayers[0].opacity - 1) < 0.0001)

        // Restore storage: the same Close action retries and succeeds.
        try setWritable(true, at: environment.storeDirectory)
        #expect(await center.closeProject() == true)
        #expect(center.project == nil)
        #expect(!center.unsavedChanges)
        let durableAfterRetry = try diskProject(id, in: environment)
        #expect(durableAfterRetry.revision == editedRevision)
        #expect(abs(durableAfterRetry.imageLayers[0].opacity - 0.42) < 0.0001)
    }

    @Test func editAcceptedDuringCloseFlushIsFlushedBeforeTeardown() async throws {
        let environment = try makeEnvironment()
        defer { cleanUp(environment) }
        let center = makeCenter(environment)
        center.autosaveDelayForTesting = .seconds(60)
        let id = try await openImageProject(center, environment)
        #expect(setOpacity(center, 0.4))

        // Hold the explicit flush at the store boundary, accept a newer edit
        // while it awaits the disk, then release. The close may only succeed
        // once that newer active revision is durable too.
        var gateContinuation: CheckedContinuation<Void, Never>?
        var gateReached = false
        center.saveGateForTesting = {
            gateReached = true
            await withCheckedContinuation { gateContinuation = $0 }
        }
        let closeTask = Task { await center.closeProject() }
        var spins = 0
        while !gateReached, spins < 100_000 {
            spins += 1
            await Task.yield()
        }
        #expect(gateReached, "the explicit close flush must reach the store boundary")

        #expect(setOpacity(center, 0.9), "the editor stays usable during a flush")
        let liveRevision = try #require(center.project?.revision)
        center.saveGateForTesting = nil
        gateContinuation?.resume()
        gateContinuation = nil

        #expect(await closeTask.value == true)
        #expect(center.project == nil)
        let durable = try diskProject(id, in: environment)
        #expect(durable.revision == liveRevision,
                "close must flush the revision accepted during the flush")
        #expect(abs(durable.imageLayers[0].opacity - 0.9) < 0.0001)
    }

    @Test func staleCloseDoesNotTearDownAReplacementSession() async throws {
        let environment = try makeEnvironment()
        defer { cleanUp(environment) }
        let center = makeCenter(environment)
        center.autosaveDelayForTesting = .seconds(60)
        let firstID = try await openImageProject(center, environment)
        #expect(setOpacity(center, 0.4))
        let otherID = try writeSyntheticProject(name: "Replacement", in: environment)

        // Hold only the FIRST explicit write at the store boundary.
        var gateHits = 0
        var gateContinuation: CheckedContinuation<Void, Never>?
        center.saveGateForTesting = {
            gateHits += 1
            if gateHits == 1 {
                await withCheckedContinuation { gateContinuation = $0 }
            }
        }
        let staleClose = Task { await center.closeProject() }
        var spins = 0
        while gateHits == 0, spins < 100_000 {
            spins += 1
            await Task.yield()
        }
        #expect(gateHits == 1, "the first close must reach the store boundary")

        // A second entry replaces the session while the close awaits: it
        // flushes the draft and opens the other project.
        #expect(await center.openProject(id: otherID) == true)
        #expect(center.project?.id == otherID)

        // Release the stale close; it must not clear the replacement session.
        center.saveGateForTesting = nil
        gateContinuation?.resume()
        gateContinuation = nil
        #expect(await staleClose.value == false,
                "a close whose session was replaced cannot report success")
        #expect(center.project?.id == otherID,
                "a stale close must never tear down a newer session")
        #expect(!center.unsavedChanges)
        #expect(center.saveError == nil)

        // The draft was flushed by the entry that actually closed it.
        let durableFirst = try diskProject(firstID, in: environment)
        #expect(abs(durableFirst.imageLayers[0].opacity - 0.4) < 0.0001)

        // The replacement session still owns a working save path: the stale
        // callback must not have cleared its pending-write handle.
        #expect(center.apply(.setCanvas(width: 500, height: 400, frameRate: nil)))
        #expect(await center.saveNow() == true)
        let durableSecond = try diskProject(otherID, in: environment)
        #expect(durableSecond.canvas?.width == 500)
        #expect(await center.closeProject() == true)
    }

    @Test func cleanCloseDoesNotWriteToReadOnlyStore() async throws {
        let environment = try makeEnvironment()
        defer { cleanUp(environment) }
        let center = makeCenter(environment)
        center.autosaveDelayForTesting = .seconds(60)
        let id = try await openImageProject(center, environment)
        let durableBefore = try diskProject(id, in: environment)
        #expect(!center.unsavedChanges)

        try setWritable(false, at: environment.storeDirectory)
        #expect(await center.closeProject() == true,
                "an unchanged session must close without a meaningless write")
        #expect(center.project == nil)
        #expect(center.saveError == nil)
        try setWritable(true, at: environment.storeDirectory)
        let durableAfter = try diskProject(id, in: environment)
        #expect(durableAfter.revision == durableBefore.revision)
    }

    @Test func failedInitialSaveKeepsSourceAndReportsRetry() async throws {
        let environment = try makeEnvironment()
        defer { cleanUp(environment) }
        try setWritable(false, at: environment.storeDirectory)
        let center = makeCenter(environment)

        #expect(await center.startImageProject(sourceURL: environment.source,
                                               owner: .standalone) == false)
        #expect(center.project == nil, "no phantom project may open after a failed initial save")
        #expect(center.alert != nil, "the bootstrap surface needs an actionable error")
        #expect(FileManager.default.fileExists(atPath: environment.source.path),
                "the entrance-owned source file is never removed by a failed project save")
        try setWritable(true, at: environment.storeDirectory)
    }

    // MARK: - Switch / open

    @Test func failedOpenKeepsCurrentProjectAndEdits() async throws {
        let environment = try makeEnvironment()
        defer { cleanUp(environment) }
        let center = makeCenter(environment)
        center.autosaveDelayForTesting = .seconds(60)
        let currentID = try await openImageProject(center, environment)
        #expect(setOpacity(center, 0.33))
        let editedRevision = try #require(center.project?.revision)
        let otherID = try writeSyntheticProject(name: "Second", in: environment)

        try setWritable(false, at: environment.storeDirectory)
        #expect(await center.openProject(id: otherID) == false,
                "a switch whose flush failed must stop before loading the target")
        #expect(center.project?.id == currentID)
        #expect(center.project?.revision == editedRevision)
        #expect(center.unsavedChanges)
        #expect(center.saveError != nil)

        try setWritable(true, at: environment.storeDirectory)
        #expect(await center.openProject(id: otherID) == true)
        #expect(center.project?.id == otherID)
        #expect(center.project?.name == "Second")
        #expect(!center.unsavedChanges)
        #expect(center.saveError == nil)
    }

    // MARK: - Interleavings

    @Test func pendingAutosaveCannotRollBackANewerToolRevision() async throws {
        let environment = try makeEnvironment()
        defer { cleanUp(environment) }
        let center = makeCenter(environment)
        center.autosaveDelayForTesting = .zero
        let id = try await openImageProject(center, environment)

        // Land a durable base through the ordinary autosave path.
        #expect(setOpacity(center, 0.5))
        await center.waitForPendingSave()
        let durableBase = try #require(center.savedRevision)
        #expect(!center.unsavedChanges)

        // The tool loads the live draft and applies its proposal (R+1).
        var toolDocument = try #require(center.project)
        try MediaTransactions.apply(.setCanvas(width: 800, height: 600, frameRate: nil),
                                    to: &toolDocument)
        let toolRevision = toolDocument.revision
        #expect(toolRevision == durableBase + 1)

        // While the tool awaits the disk the user accepts a new edit that
        // lands at the same numeric revision with different content; the
        // debounced write is held out of the way.
        center.autosaveDelayForTesting = .seconds(60)
        #expect(setOpacity(center, 0.6))
        let uiRevision = try #require(center.project?.revision)
        #expect(uiRevision == toolRevision, "different content at the same revision")

        // The tool's write lands against the base it loaded.
        try await center.persistProject(toolDocument, expectedRevision: durableBase)

        // A late tool callback never replaces the newer in-memory draft …
        #expect(center.project?.revision == uiRevision)
        #expect(abs((center.project?.imageLayers[0].opacity ?? 0) - 0.6) < 0.0001)
        #expect(center.unsavedChanges, "a durable tool revision is not this draft's save")
        // … and the durable base advances so nothing can regress the disk.
        #expect(center.savedRevision == toolRevision)
        let durableAfterTool = try diskProject(id, in: environment)
        #expect(durableAfterTool.revision == toolRevision)
        #expect(durableAfterTool.canvas?.width == 800)
        #expect(abs(durableAfterTool.imageLayers[0].opacity - 0.5) < 0.0001)

        // Releasing the held autosave cannot claim the tool revision for the
        // user's different content: explicit conflict, no write.
        center.autosaveDelayForTesting = .zero
        center.reorderLayers(to: center.project?.imageLayers.map(\.id) ?? [])
        await center.waitForPendingSave()
        #expect(center.saveError != nil)
        let durableAfterAutosave = try diskProject(id, in: environment)
        #expect(durableAfterAutosave.revision == toolRevision,
                "the stale autosave must not overwrite the newer tool revision")
        #expect(durableAfterAutosave.canvas?.width == 800)
        #expect(center.project?.revision == uiRevision)
        #expect(abs((center.project?.imageLayers[0].opacity ?? 0) - 0.6) < 0.0001)

        // An explicit flush reports the conflict and keeps the dirty draft.
        #expect(await center.closeProject() == false)
        #expect(center.project != nil)
        #expect(center.unsavedChanges)
        #expect(center.saveError != nil)
        let durableAfterFailedClose = try diskProject(id, in: environment)
        #expect(durableAfterFailedClose.revision == toolRevision)

        // Recovery: a further edit advances past the tool revision and saves
        // the draft intact (undo/redo/discard stay available throughout).
        #expect(setOpacity(center, 0.7))
        #expect(await center.saveNow() == true)
        #expect(center.project?.revision == toolRevision + 1)
        let durableAfterRecovery = try diskProject(id, in: environment)
        #expect(durableAfterRecovery.revision == toolRevision + 1)
        #expect(abs(durableAfterRecovery.imageLayers[0].opacity - 0.7) < 0.0001)
        #expect(!center.unsavedChanges)
        #expect(await center.closeProject() == true)
    }

    @Test func equalRevisionDriftIsNotTreatedAsSaved() async throws {
        let environment = try makeEnvironment()
        defer { cleanUp(environment) }
        let center = makeCenter(environment)
        center.autosaveDelayForTesting = .seconds(60)
        let id = try await openImageProject(center, environment)
        let durableBase = try #require(center.savedRevision)

        #expect(setOpacity(center, 0.25))
        let uiRevision = try #require(center.project?.revision)

        // Another producer writes a DIFFERENT document at the same revision
        // (for example a second session or a conflicting automation).
        let externalStore = MediaProjectStore(directory: environment.storeDirectory)
        var external = try #require(center.project)
        external.name = "Externally changed"
        try await externalStore.save(external, expectedRevision: durableBase)
        let durableExternal = try diskProject(id, in: environment)
        #expect(durableExternal.revision == uiRevision)
        #expect(durableExternal.name == "Externally changed")

        // Equal revision but different content is not "already saved".
        #expect(await center.saveNow() == false)
        #expect(center.unsavedChanges)
        #expect(center.saveError != nil)
        #expect(center.savedRevision == durableBase)
        #expect(center.project?.name != "Externally changed")
        let durableAfterFailure = try diskProject(id, in: environment)
        #expect(durableAfterFailure.revision == uiRevision)
        #expect(durableAfterFailure.name == "Externally changed",
                "a conflicting local write must not replace the durable document")
        await center.discardChangesAndClose()
    }

    // MARK: - Undo / redo and discard

    @Test func undoAndRedoSaveAsNewRevisions() async throws {
        let environment = try makeEnvironment()
        defer { cleanUp(environment) }
        let center = makeCenter(environment)
        center.autosaveDelayForTesting = .zero
        let id = try await openImageProject(center, environment)

        #expect(setOpacity(center, 0.4))
        await center.waitForPendingSave()
        let edited = try #require(center.project?.revision)

        center.undo()
        let undone = try #require(center.project?.revision)
        #expect(undone == edited + 1, "undo advances instead of reusing a revision")
        #expect(await center.saveNow() == true)
        let durableUndo = try diskProject(id, in: environment)
        #expect(durableUndo.revision == undone)
        #expect(abs(durableUndo.imageLayers[0].opacity - 1) < 0.0001)

        center.redo()
        let redone = try #require(center.project?.revision)
        #expect(redone == undone + 1)
        #expect(await center.saveNow() == true)
        let durableRedo = try diskProject(id, in: environment)
        #expect(durableRedo.revision == redone)
        #expect(abs(durableRedo.imageLayers[0].opacity - 0.4) < 0.0001)
        #expect(await center.closeProject() == true)
    }

    @Test func saveRetryPreservesCompleteDurableContent() async throws {
        let environment = try makeEnvironment()
        defer { cleanUp(environment) }
        let center = makeCenter(environment)
        center.autosaveDelayForTesting = .seconds(60)
        let id = try await openImageProject(center, environment)
        #expect(setOpacity(center, 0.42))
        let draft = try #require(center.project)
        let expected = try MediaProjectStore.canonicalContentData(draft)

        try setWritable(false, at: environment.storeDirectory)
        #expect(await center.closeProject() == false)
        #expect(center.project?.id == id)
        #expect(center.unsavedChanges)
        try setWritable(true, at: environment.storeDirectory)
        #expect(await center.closeProject() == true)
        #expect(center.project == nil)
        #expect(!center.unsavedChanges)

        let reloaded = try diskProject(id, in: environment)
        #expect(try MediaProjectStore.canonicalContentData(reloaded) == expected,
                "retry must preserve the entire durable draft, including history and assets")
    }

    @Test func confirmedDiscardDropsOnlyThisSessionsUnsavedEdits() async throws {
        let environment = try makeEnvironment()
        defer { cleanUp(environment) }
        let center = makeCenter(environment)
        center.autosaveDelayForTesting = .seconds(60)
        let id = try await openImageProject(center, environment)
        let durableBytes = try Data(contentsOf: projectFile(id, in: environment))
        let assetDirectory = environment.root.appendingPathComponent("Workbench/Assets")
        let assetCountBefore = (try? FileManager.default.contentsOfDirectory(
            at: assetDirectory, includingPropertiesForKeys: nil).count) ?? 0

        #expect(setOpacity(center, 0.65))
        try setWritable(false, at: environment.storeDirectory)
        #expect(await center.closeProject() == false)
        #expect(center.saveError != nil)

        // The user confirms discard from the editor's own action.
        #expect(await center.discardChangesAndClose())
        #expect(center.project == nil)
        #expect(!center.unsavedChanges)
        #expect(center.saveError == nil)

        try setWritable(true, at: environment.storeDirectory)
        let durableAfterDiscard = try Data(contentsOf: projectFile(id, in: environment))
        #expect(durableAfterDiscard == durableBytes,
                "discard must not rewrite or delete the saved project document")
        #expect(FileManager.default.fileExists(atPath: environment.source.path))
        let assetCountAfter = (try? FileManager.default.contentsOfDirectory(
            at: assetDirectory, includingPropertiesForKeys: nil).count) ?? 0
        #expect(assetCountAfter == assetCountBefore,
                "discard keeps imported source assets that already belong to the project")
    }
}
#endif
