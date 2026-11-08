// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeElectronicsCore
@testable import FloeElectronicsUI

@MainActor struct EDInspectorSessionTests {
    private func fixture() -> EDAProject {
        var p = EDABuiltinLibrary.makeProject(title: "Owned inspector fixture")
        let definition = p.footprints.first!
        p.boards[0].footprints = [.init(definitionID: definition.id, reference: "R1", value: "10k", position: .init(12, 10))]
        p.boards[0].tracks = [.init(netID: "", width: 0.25, points: [.init(12, 10), .init(18, 12), .init(24, 12)])]
        p.boards[0].vias = [.init(netID: "", position: .init(24, 12))]
        p.boards[0].holes = [.init(position: .init(30, 20), diameter: 1.2)]
        p.boards[0].edgePlated = false
        p.boards[0].graphics = [.line(.init(3, 4), .init(5, 6), width: 0.1)]
        p.boards[0].graphicLayers = [.init(layerID: "F.Fab", kind: .fabrication)]
        p.boards[0].cutouts = [[.init(50, 50), .init(55, 50), .init(55, 55), .init(50, 55)]]
        return p
    }
    private func root() throws -> URL {
        let base = try #require(ProcessInfo.processInfo.environment["FLOE_INSPECTOR_TEST_TEMP"])
        return URL(fileURLWithPath: base).appendingPathComponent(UUID().uuidString)
    }

    @Test func dirtySameIdentityDraftRetainsInputUntilExplicitReload() {
        let original = EDATrack(netID: "", width: 0.25, points: [.zero, .init(2, 3)])
        var draft = EDInspectorDraft(original, revision: 8)
        draft.value.width = 0.5
        var external = original; external.width = 0.8
        draft.receive(external, revision: 9)
        #expect(draft.value.width == 0.5 && draft.baseline == original && draft.revision == 8)
        #expect(draft.isDirty && draft.needsReload)
        // Reverting one local field must not silently clear an established conflict.
        draft.value = original; draft.receive(external, revision: 9)
        #expect(draft.needsReload && draft.value == original && draft.revision == 8)
        draft.reload(external, revision: 9)
        #expect(!draft.isDirty && !draft.needsReload && draft.value == external && draft.revision == 9)
        var next = external; next.width = 0.9; draft.receive(next, revision: 10)
        #expect(draft.value == next && draft.revision == 10 && !draft.needsReload)
    }

    @Test func trackPropertiesSaveUndoRedoAndReopenWithoutReplacingBoardState() async throws {
        let initial = fixture(), directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await EDAProjectStore.create(root: directory, project: initial)
        let session = try await EDWorkbenchSession(store: store)
        var value = initial.boards[0].tracks[0]; value.width = 0.65; value.layer = "B.Cu"; value.points[1] = .init(19, 14)
        try await session.apply(EDInspectorEdits.track(value, boardID: initial.boards[0].id, project: session.project), expectedRevision: 0)
        var expected = initial.boards[0]; expected.tracks[0] = value
        #expect(try await store.load().project.boards[0] == expected)
        try await session.undo(expectedRevision: 1)
        #expect(session.project.boards[0] == initial.boards[0])
        try await session.redo(expectedRevision: 2)
        let reopened = try await EDWorkbenchSession(store: store)
        #expect(reopened.revision == 3 && reopened.project.boards[0] == expected)
        await reopened.close(); await session.close()
    }

    @Test func viaAndStraightSlotPropertiesPreserveIdentityAndOtherManufacturingValues() async throws {
        let initial = fixture(), directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await EDAProjectStore.create(root: directory, project: initial)
        let session = try await EDWorkbenchSession(store: store)
        var via = initial.boards[0].vias[0]; via.position = .init(22, 13); via.diameter = 0.9; via.drill = 0.4
        try await session.apply(EDInspectorEdits.via(via, boardID: initial.boards[0].id, project: session.project), expectedRevision: 0)
        var hole = initial.boards[0].holes[0]; hole.endPosition = .init(34, 20); hole.diameter = 1.8; hole.plated = true
        try await session.apply(EDInspectorEdits.hole(hole, boardID: initial.boards[0].id, project: session.project), expectedRevision: 1)
        var expected = initial.boards[0]; expected.vias[0] = via; expected.holes[0] = hole
        #expect(try await store.load().project.boards[0] == expected)
        try await session.undo(expectedRevision: 2)
        #expect(session.project.boards[0].holes == initial.boards[0].holes)
        #expect(session.project.boards[0].vias == [via])
        await session.close()
    }

    @Test func lockedTrackAndFootprintDeletionCannotBeBypassedByAnUnsavedUnlock() async throws {
        var initial = fixture(); initial.boards[0].tracks[0].locked = true; initial.boards[0].footprints[0].locked = true
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await EDAProjectStore.create(root: directory, project: initial)
        let session = try await EDWorkbenchSession(store: store), boardID = initial.boards[0].id
        for id in [initial.boards[0].tracks[0].id, initial.boards[0].footprints[0].id] {
            #expect(throws: EDAError.readOnly) { try EDInspectorEdits.deleteBoardObject(id, boardID: boardID, project: session.project) }
            do { try await session.apply([.removeBoardObject(board: boardID, object: id)], expectedRevision: 0); Issue.record("Locked object was removed") }
            catch { #expect(error as? EDAError == .readOnly) }
        }
        #expect(try await store.load().project == initial)
        var unlocked = initial.boards[0].tracks[0]; unlocked.locked = false
        try await session.apply(EDInspectorEdits.track(unlocked, boardID: boardID, project: session.project), expectedRevision: 0)
        try await session.apply(EDInspectorEdits.deleteBoardObject(unlocked.id, boardID: boardID, project: session.project), expectedRevision: 1)
        #expect(session.project.boards[0].tracks.isEmpty && session.project.boards[0].footprints[0].locked)
        await session.close()
    }

    @Test func missingSelectionOrWrongBoardCannotRecreateOrEditAnotherObject() async throws {
        let initial = fixture(), directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await EDAProjectStore.create(root: directory, project: initial)
        let session = try await EDWorkbenchSession(store: store)
        var removed = initial.boards[0].tracks[0]; removed.id = UUID()
        #expect(throws: (any Error).self) { try EDInspectorEdits.track(removed, boardID: initial.boards[0].id, project: session.project) }
        #expect(throws: (any Error).self) { try EDInspectorEdits.via(initial.boards[0].vias[0], boardID: UUID(), project: session.project) }
        #expect(throws: (any Error).self) { try EDInspectorEdits.hole(initial.boards[0].holes[0], boardID: UUID(), project: session.project) }
        #expect(try await store.load().project == initial && session.revision == 0)
        await session.close()
    }

    @Test func externalWriterCASPreservesDirtyDraftAndReloadReadsActualOriginal() async throws {
        let initial = fixture(), directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await EDAProjectStore.create(root: directory, project: initial)
        let a = try await EDWorkbenchSession(store: store), b = try await EDWorkbenchSession(store: store)
        var draft = EDInspectorDraft(a.project.boards[0].tracks[0], revision: a.revision); draft.value.width = 0.55
        var other = b.project.boards[0].tracks[0]; other.width = 0.75
        try await b.apply(EDInspectorEdits.track(other, boardID: initial.boards[0].id, project: b.project), expectedRevision: 0)
        do { try await a.apply(EDInspectorEdits.track(draft.value, boardID: initial.boards[0].id, project: a.project), expectedRevision: draft.revision); Issue.record("Stale property write succeeded") }
        catch { #expect(a.conflictWithOriginal && a.isDirty) }
        draft.reject()
        #expect(draft.value.width == 0.55 && draft.needsReload && draft.revision == 0)
        #expect(try await store.load().project.boards[0].tracks[0].width == 0.75)
        try await a.refresh(discardChanges: true)
        draft.reload(a.project.boards[0].tracks[0], revision: a.revision)
        #expect(draft.value.width == 0.75 && !draft.isDirty && !draft.needsReload && draft.revision == 1)
        draft.value.width = 0.6
        try await a.apply(EDInspectorEdits.track(draft.value, boardID: initial.boards[0].id, project: a.project), expectedRevision: draft.revision)
        #expect(try await store.load().project.boards[0].tracks[0].width == 0.6)
        await a.close(); await b.close()
    }

    @Test func libraryPinPadAndGraphicLayerEditsUseExistingSaveAndUndo() async throws {
        let initial = fixture(), directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await EDAProjectStore.create(root: directory, project: initial)
        let session = try await EDWorkbenchSession(store: store)
        var symbol = initial.symbols[0]; symbol.pins[0].position = .init(-7, 3); symbol.pins[0].unit = 0; symbol.pins[0].type = .powerInput
        var footprint = initial.footprints[0]; footprint.pads[0].position = .init(-3, 2); footprint.pads[0].size = .init(2, 3)
        footprint.pads[0].angle = 37; footprint.pads[0].shape = .oval; footprint.pads[0].drill = 0.7; footprint.pads[0].drillPlated = true
        footprint.pads[0].layers = ["F.Cu", "B.Cu"]
        let operations = try EDInspectorEdits.symbolDefinition(symbol, project: session.project) + EDInspectorEdits.footprintDefinition(footprint, project: session.project)
        try await session.apply(operations, expectedRevision: 0)
        let actual = try await store.load().project
        #expect(actual.symbols[0] == symbol && actual.footprints[0] == footprint)
        #expect(actual.footprints[0].graphicLayers == initial.footprints[0].graphicLayers)
        #expect(actual.boards == initial.boards)
        try await session.undo(expectedRevision: 1)
        #expect(session.project.symbols == initial.symbols && session.project.footprints == initial.footprints)
        await session.close()
    }

    @Test func boardSettingsRetainAllUntouchedGeometryAndGraphicAssignments() async throws {
        let initial = fixture(), directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await EDAProjectStore.create(root: directory, project: initial)
        let session = try await EDWorkbenchSession(store: store)
        var draft = EDInspectorDraft(initial.boards[0], revision: session.revision)
        draft.value.name = "Updated board"; draft.value.boardEdgeClearance = 0.4; draft.value.edgePlated = true
        draft.value.layers[0].thickness = 0.07
        try await session.apply(EDInspectorEdits.board(draft.value, project: session.project), expectedRevision: draft.revision)
        let actual = try await store.load().project.boards[0]
        #expect(actual == draft.value)
        #expect(actual.holes == initial.boards[0].holes && actual.cutouts == initial.boards[0].cutouts)
        #expect(actual.graphics == initial.boards[0].graphics && actual.graphicLayers == initial.boards[0].graphicLayers)
        #expect(actual.tracks == initial.boards[0].tracks && actual.footprints == initial.boards[0].footprints && actual.netClasses == initial.boards[0].netClasses)
        await session.close()
    }

    @Test func componentAndFootprintTransformsSaveWithoutLosingSourceMetadata() async throws {
        var initial = fixture()
        let component = EDAComponent(symbolID: initial.symbols[0].id, reference: "U1", value: "Controller", fields: ["manufacturer": "QA"], excludedVariants: ["Prototype"])
        let placement = EDASymbolPlacement(componentID: component.id, position: .init(4, 5))
        initial.components = [component]; initial.sheets[0].symbols = [placement]
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await EDAProjectStore.create(root: directory, project: initial), session = try await EDWorkbenchSession(store: store)
        var part = try #require(EDComponentInspectorValue.read(session.project, sheetID: initial.sheets[0].id, placementID: placement.id))
        part.component.value = "MCU"; part.placement.position = .init(7, 9); part.placement.angle = 90; part.placement.mirrored = true
        try await session.apply(EDInspectorEdits.component(part, sheetID: initial.sheets[0].id, project: session.project), expectedRevision: 0)
        var footprint = initial.boards[0].footprints[0]; footprint.angle = 270; footprint.side = "B.Cu"
        try await session.apply(EDInspectorEdits.footprint(footprint, boardID: initial.boards[0].id, project: session.project), expectedRevision: 1)
        let actual = try await store.load().project
        #expect(actual.components[0].fields == component.fields && actual.components[0].excludedVariants == component.excludedVariants)
        #expect(actual.sheets[0].symbols[0] == part.placement && actual.boards[0].footprints == [footprint])
        await session.close()
    }

    @Test func previewUsesRealTransformedGeometryAndNeverChangesSource() throws {
        let project = fixture(); var value = project.boards[0].footprints[0]
        value.position = .init(123, 45); value.angle = 90; value.side = "B.Cu"
        let scene = try #require(EDInspectorPreviewScene.footprint(value, boardID: project.boards[0].id, project: project))
        #expect(scene.project.boards[0].footprints == [value])
        #expect(scene.project.footprints == project.footprints && scene.project.boards[0].outline.isEmpty)
        let definition = try #require(project.footprints.first(where: { $0.id == value.definitionID }))
        for pad in definition.pads {
            let point = value.point(pad.position)
            #expect(scene.bounds.contains(CGPoint(x: point.x, y: point.y)))
        }
        let hole = EDAHole(position: .init(5, 10), diameter: 1.2, endPosition: .init(30, 10))
        let slot = EDInspectorPreviewScene.hole(hole, boardID: project.boards[0].id, project: project)
        #expect(slot.project.boards[0].holes == [hole] && slot.bounds.contains(CGPoint(x: 30, y: 10)))
        #expect(project.boards[0].footprints[0].position == .init(12, 10) && project.revision == 0)
    }
}
