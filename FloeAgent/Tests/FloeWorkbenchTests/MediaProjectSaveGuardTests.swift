// FloeWorkbench — Durable write guard tests.
//
// The workbench persists from several producers (UI autosave, explicit save,
// model tool commits). These cases pin the store-level boundary they all share:
// a stale revision can never replace a newer document, and an equal revision
// with different content is a conflict rather than an idempotent save, so a
// late callback can neither roll back a newer revision nor pretend an edit is
// durable. Undo/redo legitimately advance the revision and stay writable.

import Foundation
import Testing
import FloeCore
@testable import FloeWorkbench

@Suite("Media project durable write guard")
struct MediaProjectSaveGuardTests {
    private func imageProject(name: String = "Guard") -> MediaProject {
        var project = MediaProject(kind: .image, name: name,
                                   canvas: MediaCanvas(width: 640, height: 480))
        let asset = MediaAssetReference(kind: .image, relativePath: "assets/base.png",
                                        originalName: "base.png")
        project.assets = [asset]
        project.sourceAssetID = asset.id
        project.imageLayers = [ImageLayer(kind: .image, name: "Base", assetID: asset.id)]
        return project
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-save-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func staleRevisionCannotOverwriteNewerDocument() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MediaProjectStore(directory: directory)

        let base = imageProject()
        try await store.save(base)
        var newer = base
        try MediaTransactions.apply(.setCanvas(width: 320, height: 240, frameRate: nil), to: &newer)
        try await store.save(newer)

        await #expect(throws: FloeError.self) {
            // Older snapshot without a transaction base: still a regression.
            try await store.save(base)
        }
        await #expect(throws: FloeError.self) {
            try await store.save(base, expectedRevision: base.revision)
        }

        let onDisk = try #require(try await store.loadProject(id: base.id))
        #expect(onDisk.revision == newer.revision)
        #expect(onDisk.canvas?.width == 320)
    }

    @Test func equalRevisionDifferentContentIsAConflict() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MediaProjectStore(directory: directory)

        let base = imageProject()
        try await store.save(base)

        var divergent = base
        divergent.name = "Diverged"
        await #expect(throws: FloeError.self) {
            // No transaction base, same revision, different content.
            try await store.save(divergent)
        }
        await #expect(throws: FloeError.self) {
            // Even a matching explicit base revision does not make a
            // same-revision content conflict idempotent.
            try await store.save(divergent, expectedRevision: base.revision)
        }

        let onDisk = try #require(try await store.loadProject(id: base.id))
        #expect(onDisk.name == base.name)
    }

    @Test func equalRevisionIdenticalContentIsIdempotent() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MediaProjectStore(directory: directory)

        let base = imageProject()
        try await store.save(base)
        // Re-saving the exact same state must not be reported as a conflict.
        try await store.save(base)

        // A load/re-save cycle (recovery warnings are recomputed on load)
        // is the same durable revision.
        let loaded = try #require(try await store.loadProject(id: base.id))
        try await store.save(loaded)

        let onDisk = try #require(try await store.loadProject(id: base.id))
        #expect(onDisk.revision == base.revision)
    }

    @Test func explicitBaseRevisionStillRequiresLatestDocument() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MediaProjectStore(directory: directory)

        let base = imageProject()
        try await store.save(base)
        var advanced = base
        try MediaTransactions.apply(.setCanvas(width: 800, height: 600, frameRate: nil), to: &advanced)
        try await store.save(advanced)
        var next = advanced
        try MediaTransactions.apply(.setCanvas(width: 1024, height: 768, frameRate: nil), to: &next)

        await #expect(throws: FloeError.self) {
            // The caller's base is stale even though the incoming revision is
            // newer than the document.
            try await store.save(next, expectedRevision: base.revision)
        }
        let onDisk = try #require(try await store.loadProject(id: base.id))
        #expect(onDisk.revision == advanced.revision)
    }

    @Test func undoAndRedoAdvanceTheRevisionAndStayWritable() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MediaProjectStore(directory: directory)

        var project = imageProject()
        let layerID = project.imageLayers[0].id
        try MediaTransactions.apply(.updateLayer(id: layerID, transform: nil, opacity: 0.42,
                                                 isHidden: nil, isLocked: nil, adjustment: nil,
                                                 text: nil, crop: .unchanged), to: &project)
        try await store.save(project)
        let savedRevision = project.revision

        #expect(MediaTransactions.undo(&project))
        #expect(project.revision == savedRevision + 1,
                "undo must advance the revision instead of reusing a saved one")
        try await store.save(project, expectedRevision: savedRevision)
        let afterUndo = try #require(try await store.loadProject(id: project.id))
        #expect(afterUndo.revision == project.revision)
        #expect(abs(afterUndo.imageLayers[0].opacity - 1) < 0.0001)

        #expect(MediaTransactions.redo(&project))
        #expect(project.revision == savedRevision + 2)
        try await store.save(project, expectedRevision: savedRevision + 1)
        let afterRedo = try #require(try await store.loadProject(id: project.id))
        #expect(afterRedo.revision == project.revision)
        #expect(abs(afterRedo.imageLayers[0].opacity - 0.42) < 0.0001)
    }

    @Test func missingBaseDocumentIsAConflict() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MediaProjectStore(directory: directory)

        var project = imageProject()
        try await store.save(project)
        let base = project.revision
        let file = store.projectURL(id: project.id)
        try MediaTransactions.apply(.setCanvas(width: 800, height: 600, frameRate: nil), to: &project)
        try FileManager.default.removeItem(at: file)

        await #expect(throws: FloeError.self) {
            // A caller with a loaded base must never silently recreate a
            // deleted document.
            try await store.save(project, expectedRevision: base)
        }
        #expect(!FileManager.default.fileExists(atPath: file.path),
                "the failed CAS write must not recreate the deleted document")

        // A brand-new project (no base) still persists normally.
        let fresh = imageProject(name: "Fresh")
        try await store.save(fresh, expectedRevision: nil)
        #expect(FileManager.default.fileExists(atPath: store.projectURL(id: fresh.id).path))
    }

    @Test func canonicalProjectionIsDeterministicAndDateNormalized() throws {
        var project = imageProject()
        let fractional = Date(timeIntervalSinceReferenceDate: 814_026_832.919_999)
        project.createdAt = fractional
        project.updatedAt = fractional
        project.recoveryWarnings = ["computed on load"]

        let first = try MediaProjectStore.canonicalContentData(project)
        let second = try MediaProjectStore.canonicalContentData(project)
        #expect(first == second,
                "the same document must canonicalize to identical bytes every time")

        var normalized = project
        normalized.createdAt = Date(timeIntervalSinceReferenceDate: 814_026_832.0)
        normalized.updatedAt = Date(timeIntervalSinceReferenceDate: 814_026_832.0)
        normalized.recoveryWarnings = []
        let normalizedData = try MediaProjectStore.canonicalContentData(normalized)
        #expect(first == normalizedData,
                "sub-second date precision and load-derived warnings must not change durable identity")
    }

    @Test func canonicalProjectionMatchesReloadedDocument() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MediaProjectStore(directory: directory)

        var project = imageProject()
        let fractional = Date(timeIntervalSinceReferenceDate: 814_026_832.919_999)
        project.createdAt = fractional
        project.updatedAt = fractional
        try await store.save(project)

        let reloaded = try #require(try await store.loadProject(id: project.id))
        let liveBytes = try MediaProjectStore.canonicalContentData(project)
        let diskBytes = try MediaProjectStore.canonicalContentData(reloaded)
        #expect(liveBytes == diskBytes,
                "a live draft and the document it just wrote must share durable identity")

        // Re-saving that live draft at the same revision is idempotent, not a
        // same-revision conflict: the center's dirty check relies on this.
        try await store.save(project, expectedRevision: project.revision)
    }

    @Test func forkAndNewDocumentsAreNotBlockedByTheParentRevision() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MediaProjectStore(directory: directory)

        let base = imageProject()
        try await store.save(base)
        let fork = try await store.forkProject(id: base.id)
        #expect(fork.id != base.id)
        #expect(fork.parentProjectID == base.id)

        let onDiskFork = try #require(try await store.loadProject(id: fork.id))
        #expect(onDiskFork.parentProjectID == base.id)
        let onDiskParent = try #require(try await store.loadProject(id: base.id))
        #expect(onDiskParent.revision == base.revision)
    }
}
