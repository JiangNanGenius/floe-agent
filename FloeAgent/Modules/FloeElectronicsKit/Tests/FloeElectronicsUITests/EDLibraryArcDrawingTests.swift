// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeElectronicsCore
@testable import FloeElectronicsUI

@MainActor struct EDLibraryArcDrawingTests {
    private let fab = EDAGraphicLayerAssignment(layerID: "F.Fab", kind: .fabrication)
    private func fixture() -> EDAProject {
        var p = EDAProject(title: "Library arc from actual canvas plan")
        let footprint = EDAFootprintDefinition(name: "Arc outline", pads: [])
        p.footprints = [footprint]; p.symbols = [.init(name: "Arc symbol")]
        p.boards[0].footprints = [
            .init(definitionID: footprint.id, position: .init(20,20), angle: 30),
            .init(definitionID: footprint.id, position: .init(40,20), angle: 30, side: "B.Cu")]
        return p
    }
    private func draft(_ p: EDAProject, points: [EDAPoint] = [.zero, .init(5,0), .init(0,9)],
                       symbol: Bool = false) throws -> EDLibraryArcDraft {
        let context: EDADocumentContext = symbol ? .symbol(definitionID: p.symbols[0].id) : .footprint(definitionID: p.footprints[0].id)
        var result = try EDLibraryArcDraft(project: p, context: context)
        for point in points { try result.append(point) }
        return result
    }
    private func root() throws -> URL {
        let base = ProcessInfo.processInfo.environment["FLOE_ARC_TEST_TEMP"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(UUID().uuidString)
    }

    @Test func toolAndThreePointsProduceAnAnalyticArcWithVisibleDirectionAndFixedRadius() throws {
        let p = fixture()
        #expect(EDLibraryTool.symbolTools.contains(.arc) && EDLibraryTool.footprintTools.contains(.arc))
        let d = try draft(p)
        let ccw = try d.plan(clockwise: false, width: 0.2, layer: fab)
        let cw = try d.plan(clockwise: true, width: 0.35, layer: fab)
        #expect(ccw.graphic == .arc(center: .zero, radius: 5, start: 0, sweep: 90, width: 0.2))
        #expect(cw.graphic == .arc(center: .zero, radius: 5, start: 0, sweep: -270, width: 0.35))
        #expect(ccw.edits.count == 1 && ccw.graphicIndex == 0)
        let crossing = try draft(p, points: [.zero, .init(0,5), .init(9,0)])
        #expect(try crossing.plan(clockwise: true, width: 0.2, layer: fab).graphic == .arc(center: .zero, radius: 5, start: 90, sweep: -90, width: 0.2))
        let symbol = try draft(p, symbol: true).plan(clockwise: false, width: 0.2, layer: nil)
        #expect(symbol.graphic == ccw.graphic)
        let roundtrip = try JSONDecoder().decode(EDAGraphic.self, from: JSONEncoder().encode(ccw.graphic))
        #expect(roundtrip == ccw.graphic)
    }

    @Test func previewUndoCancelAndInvalidGeometryNeverInventAFullCircleOrSave() throws {
        let p = fixture()
        var d = try draft(p, points: [.zero])
        #expect(d.preview(toward: .init(5,0), clockwise: false, width: 0.2) == nil)
        #expect(throws: EDAError.self) { try d.append(.zero) }
        #expect(d.points == [.zero])
        try d.append(.init(5,0))
        let preview = d.preview(toward: .init(0,12), clockwise: false, width: 0.2)
        #expect(preview == .arc(center: .zero, radius: 5, start: 0, sweep: 90, width: 0.2))
        for point in [EDAPoint.zero, .init(99,0), .init(.nan,0), .init(0,.infinity), .init(100_001,0)] {
            #expect(throws: EDAError.self) { try d.append(point) }
        }
        #expect(d.points.count == 2 && !d.canFinish)
        try d.append(.init(0,5)); #expect(d.canFinish)
        for width in [-0.1, 0, Double.nan, Double.infinity] {
            #expect(throws: EDAError.self) { try d.plan(clockwise: false, width: width, layer: fab) }
        }
        #expect(throws: EDAError.self) { try d.plan(clockwise: false, width: 0.2, layer: nil) }
        d.undoLastPoint(); #expect(!d.canFinish && d.points.count == 2)
        d.cancel(); #expect(d.points.isEmpty && !d.canFinish)
        #expect(throws: EDAError.cancelled) { try d.plan(clockwise: false, width: 0.2, layer: fab) }
        #expect(p.footprints[0].graphics.isEmpty && p.revision == 0)
    }

    @Test func hitTestsTheActualSignedArcAndStrokeInsteadOfTheWholeCircle() {
        let arc = EDAGraphic.arc(center: .zero, radius: 5, start: 0, sweep: 90, width: 0.4)
        let definition = EDAFootprintDefinition(name: "Quarter arc", graphics: [arc])
        #expect(EDLibraryEditing.hitFootprint(definition, at: .init(-5,0), tolerance: 0.01) == nil)
        #expect(EDLibraryEditing.hitFootprint(definition, at: .init(0,-5), tolerance: 0.01) == nil)
        #expect(EDLibraryEditing.hitFootprint(definition, at: .init(5.15,0), tolerance: 0.01) == .graphic(0))
        #expect(EDLibraryEditing.hitFootprint(definition, at: .init(3,4), tolerance: 0.01) == .graphic(0))
        #expect(EDLibraryEditing.distance(.init(5.3,0), to: arc) > 0.09)
        let clockwise = EDAGraphic.arc(center: .zero, radius: 5, start: -170, sweep: -40, width: 0.2)
        let on = EDAPoint(5,0).transformed(origin: .zero, angle: 170)
        let off = EDAPoint(5,0).transformed(origin: .zero, angle: -140)
        #expect(EDLibraryEditing.distance(on, to: clockwise) < 1e-8)
        #expect(EDLibraryEditing.distance(off, to: clockwise) > 1)
    }

    @Test func graphicMoveDeleteAndAppendPreserveLayerIndicesAndLegacyUnknowns() throws {
        var p = fixture()
        p.footprints[0].graphics = [.line(.zero,.init(1,1),width: 0.2)]
        let plan = try draft(p).plan(clockwise: false, width: 0.2, layer: fab)
        var editor = try EDAEditingSession(project: p)
        try editor.apply(plan.edits, expectedRevision: 0)
        var definition = editor.project.footprints[0]
        #expect(definition.graphicLayers == [nil, fab])
        let translated = EDLibraryEditing.translated(plan.graphic, by: .init(10,-2))
        #expect(translated == .arc(center: .init(10,-2), radius: 5, start: 0, sweep: 90, width: 0.2))
        try EDAGraphicEditing.replace(at: 1, with: translated, graphics: &definition.graphics, layers: definition.graphicLayers)
        #expect(definition.graphicLayers == [nil, fab])
        try EDAGraphicEditing.remove(at: 0, graphics: &definition.graphics, layers: &definition.graphicLayers)
        #expect(definition.graphics == [translated] && definition.graphicLayers == [fab])
        // The old unassigned graphic is retained and cannot be laundered by
        // adding a newly assigned arc. Existing consumers keep their refusal.
        #expect(throws: EDAManufacturingFailure.self) {
            try EDAExchange.export(editor.project, format: .gerberTechnical, gerberLayers: ["F.Fab"])
        }
    }

    @Test func threePointCommitUsesOneCASUndoAndReopensExactNativeGeometry() async throws {
        let p = fixture(), dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try await EDAProjectStore.create(root: dir, project: p), session = try await EDWorkbenchSession(store: store)
        let plan = try draft(p).plan(clockwise: false, width: 0.2, layer: fab)
        let before = try await store.load(); var saved = 0; session.onSaved = { _ in saved += 1 }
        #expect(session.project == p && !session.canUndo && before.project.footprints[0].graphics.isEmpty)
        try await plan.apply(to: session)
        #expect(session.revision == 1 && saved == 1 && session.canUndo && !session.isDirty)
        let reopened = try await EDWorkbenchSession(store: store)
        #expect(reopened.project == session.project)
        #expect(reopened.project.footprints[0].graphics == [plan.graphic] && reopened.project.footprints[0].graphicLayers == [fab])
        await #expect(throws: EDAError.staleRevision(expected: 0, actual: 1)) { try await plan.apply(to: session) }
        #expect(saved == 1)
        try await session.undo(expectedRevision: 1)
        #expect(session.project.footprints[0].graphics.isEmpty && !session.canUndo)
        try await session.redo(expectedRevision: 2)
        #expect(session.project.footprints[0].graphics == [plan.graphic] && session.project.footprints[0].graphicLayers == [fab])
        #expect(try await store.load().project == session.project)
    }

    @Test func cancelClosedAndStaleSourceRejectWhileRealCASFailureRetainsTheLocalProposal() async throws {
        let p = fixture(), dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try await EDAProjectStore.create(root: dir, project: p), session = try await EDWorkbenchSession(store: store)
        let plan = try draft(p).plan(clockwise: false, width: 0.2, layer: fab)
        var sameRevision = p; sameRevision.title = "changed source"
        #expect(throws: EDAError.self) { try plan.validateSource(sameRevision) }
        let cancelled = Task { @MainActor in try await plan.apply(to: session) }; cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try await store.load().project == p && !session.canUndo)
        await session.close()
        await #expect(throws: EDAError.cancelled) { try await plan.apply(to: session) }
        let current = try await EDWorkbenchSession(store: store), before = try await store.load()
        var external = before.project; external.title = "external writer"; external.revision += 1
        let saved = try await store.save(external, expectedRevision: 0, expectedDigest: before.digest)
        await #expect(throws: EDAError.staleRevision(expected: 0, actual: 1)) { try await plan.apply(to: current) }
        #expect(try await store.load() == saved)
        #expect(current.conflictWithOriginal && current.isDirty && current.canUndo)
        #expect(current.project.footprints[0].graphics == [plan.graphic])
    }

    @Test func realSavedArcReachesGerberG02G03AndDRCReportsItsActualCoverage() async throws {
        let p = fixture(), dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try await EDAProjectStore.create(root: dir, project: p), session = try await EDWorkbenchSession(store: store)
        try await draft(p).plan(clockwise: false, width: 0.2, layer: fab).apply(to: session)
        let saved = try await store.load()
        let bundle = try await session.export(format: .gerberTechnical, boardID: p.boards[0].id, variant: "Default", gerberLayers: ["F.Fab","B.Fab"])
        let core = try EDAExchange.export(saved.project, format: .gerberTechnical, boardID: p.boards[0].id, gerberLayers: ["F.Fab","B.Fab"])
        #expect(bundle.files == core.files)
        let top = try #require(bundle.files.first { $0.name == "AssemblyOutline-Top.gbr" })
        let bottom = try #require(bundle.files.first { $0.name == "AssemblyOutline-Bot.gbr" })
        let topText = String(decoding: top.data, as: UTF8.self), bottomText = String(decoding: bottom.data, as: UTF8.self)
        #expect(topText.contains("G03*\n") && topText.contains("X24330127Y22500000D02*"))
        #expect(topText.contains("X17500000Y24330127I-4330127J-2500000D01*"))
        #expect(bottomText.contains("G02*\n") && bottomText.contains("X35669873Y17500000D02*"))
        #expect(bottomText.contains("X37500000Y24330127I4330127J2500000D01*"))
        #expect(!topText.contains("<svg") && !bottomText.contains("<svg"))
        let report = try EDADRC.check(saved.project, boardID: p.boards[0].id)
        #expect(!report.issues.contains { $0.code == "copper_graphic_unsupported" || $0.code == "graphic_layer_unspecified" })
        #expect(report.excludedChecks.contains("mask_paste_silkscreen_courtyard") && report.excludedChecks.contains("arcs_slots_custom_padstacks_and_net_ties"))
        var copper = saved.project
        copper.footprints[0].graphicLayers = [.init(layerID: "F.Cu", kind: .copper)]
        #expect(try EDADRC.check(copper, boardID: p.boards[0].id).issues.contains { $0.code == "copper_graphic_unsupported" })
        #expect(throws: EDAManufacturingFailure.self) { try EDAExchange.export(copper, format: .gerber) }
        #expect(try await store.load() == saved)
        if let path = ProcessInfo.processInfo.environment["FLOE_ARC_GOLDEN_ROOT"] {
            let output = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            for file in bundle.files { try file.data.write(to: output.appendingPathComponent(file.name)) }
            try Data(contentsOf: store.root.appendingPathComponent("project.json")).write(to: output.appendingPathComponent("source.json"))
            try JSONEncoder().encode(report).write(to: output.appendingPathComponent("drc.json"))
        }
    }
}
