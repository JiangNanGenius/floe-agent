// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloeManufacturingCore
@testable import FloeManufacturingUI

/// Controlled suspension never runs an engine or touches an external device.
/// Intentionally ignores cancellation so the actual model must fence late data.
private actor PendingCellRead {
    private var continuation:CheckedContinuation<CellWorkbenchLoadedDocument,Error>?
    private var started:CheckedContinuation<Void,Never>?
    func load() async throws -> CellWorkbenchLoadedDocument {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation;started?.resume();started = nil
        }
    }
    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish(_ value:CellWorkbenchLoadedDocument) { continuation?.resume(returning:value);continuation = nil }
}

@Suite("Saved cell presentation and editor generation",.serialized)
@MainActor struct CellSavedResultPresentationTests {
    @Test func genuineSavedResultIsExplicitlyOpenedAndFailureOrCancelPreservesCurrentResult() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cell-saved-ui-\(UUID())")
        defer { try? FileManager.default.removeItem(at:root) }
        let model = CellWorkbenchModel(project:.demonstration(),directory:root)
        model.refreshSavedResultAvailability()
        #expect(model.savedResultAvailability == .missing && model.artifact == nil)
        #expect(!FileManager.default.fileExists(atPath:root.path),"Presence checks never create a default result or directory")
        var project = ManufacturingCellProject.demonstration();project.cell.name = "Actual saved program"
        var artifact = try CellManufacturingEngine().compute(project)
        artifact.elapsedSeconds = 932.125 // Stored metadata, not a recalculated value.
        let file = root.appendingPathComponent("latest.floecell")
        try ManufacturingCellArchive.save(project:project,artifact:artifact,to:file)
        let bytes = try Data(contentsOf:file)
        model.refreshSavedResultAvailability()
        #expect(model.savedResultAvailability == .available && model.artifact == nil)
        let opening = try #require(model.reopen(model.savedOpenRequest()))
        await opening.value
        let actual = try #require(model.artifact)
        #expect(model.project == project && !model.hasUnsavedChanges && !model.busy)
        #expect(actual.elapsedSeconds == 932.125 && actual.schedule.totalSeconds == artifact.schedule.totalSeconds)
        #expect(actual.jobs.count == artifact.jobs.count && actual.schedule.transfers.count == artifact.schedule.transfers.count)
        #expect(actual.finalStock == artifact.finalStock)
        #expect(try Data(contentsOf:file) == bytes)
        let actualDigest = try ResearchArchive.digest(actual)
        try Data("bad archive".utf8).write(to:file,options:.atomic)
        let failed = try #require(model.reopen(model.savedOpenRequest()))
        await failed.value
        let retained = try #require(model.artifact)
        #expect(model.project == project)
        #expect(try ResearchArchive.digest(retained) == actualDigest)
        #expect(model.savedResultAvailability == .unavailable && !model.busy)
        #expect(try Data(contentsOf:file) == Data("bad archive".utf8),"A failed open never repairs or replaces the saved original")
        try bytes.write(to:file,options:.atomic)

        // Start with the same genuinely validated archive, then suspend a new
        // read. Cancelling keeps the current result; late data cannot install.
        let gate = PendingCellRead(),loaded = CellWorkbenchLoadedDocument(project:project,artifact:actual)
        let retaining = CellWorkbenchModel(project:project,directory:root,archiveLoader:{ source in
            if source.url.lastPathComponent == "first.floecell" { return loaded }
            return try await gate.load()
        })
        let first = try #require(retaining.load(root.appendingPathComponent("first.floecell")));await first.value
        let held = try #require(retaining.reopen(retaining.savedOpenRequest()))
        await gate.waitUntilStarted()
        retaining.cancel()
        #expect(!retaining.busy && retaining.artifact?.elapsedSeconds == 932.125 && retaining.project == project)
        var other = project;other.cell.name = "Late unrelated program"
        await gate.finish(.init(project:other,artifact:nil));await held.value
        #expect(retaining.project == project && retaining.artifact?.elapsedSeconds == 932.125)
        #expect(try Data(contentsOf:file) == bytes)
    }

    @Test func editorChangesAndStaleConfirmationRejectLateProgramReplacement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cell-editor-fence-\(UUID())")
        let initial = ManufacturingCellProject.demonstration(),gate = PendingCellRead()
        let model = CellWorkbenchModel(project:initial,directory:root,archiveLoader:{ _ in try await gate.load() })
        let oldConfirmation = model.savedOpenRequest()
        let held = try #require(model.load(root.appendingPathComponent("selected.json")))
        await gate.waitUntilStarted()
        var edited = initial;edited.cell.name = "Keep these current edits"
        model.project = edited // The actual property observer fences all editor tabs.
        #expect(!model.busy && model.hasUnsavedChanges)
        await gate.finish(.init(project:initial,artifact:nil));await held.value
        #expect(model.project == edited && model.artifact == nil)
        #expect(model.reopen(oldConfirmation) == nil,"A confirmation for an older program cannot replace new edits")
        #expect(model.project == edited && !model.busy)
        #expect(!FileManager.default.fileExists(atPath:root.path))
    }
}
#endif
