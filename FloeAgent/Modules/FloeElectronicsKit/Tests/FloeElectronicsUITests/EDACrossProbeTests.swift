// SPDX-License-Identifier: MPL-2.0
import Foundation
import Darwin
import Testing
import FloeElectronicsCore
@testable import FloeElectronicsUI

@MainActor struct EDACrossProbeTests {
    private func fixture() -> EDAProject {
        var p = EDAProject(title: "Cross-probe identity")
        let symbol = EDASymbolDefinition(name: "Two units", pins: [
            .init(number: "1", position: .init(-3, 0), unit: 1),
            .init(number: "2", position: .init(3, 0), unit: 2)], graphics: [
                .rectangle(.init(-2, -2), .init(2, 2), width: 0.2)])
        let footprint = EDAFootprintDefinition(name: "Rotated", pads: [
            .init(number: "1", position: .init(4, 1), size: .init(10, 2), angle: 45, shape: .oval)],
            graphics: [.circle(center: .zero, radius: 3, width: 0.2)])
        let component = EDAComponent(symbolID: symbol.id, footprintID: footprint.id, reference: "U42")
        p.symbols = [symbol]; p.footprints = [footprint]; p.components = [component]
        p.sheets[0].name = "Control"
        p.sheets[0].symbols = [.init(componentID: component.id, unit: 1, position: .init(500, 400), angle: 90)]
        p.boards[0].name = "Main board"
        p.boards[0].footprints = [.init(definitionID: footprint.id, componentID: component.id,
            reference: "old reference is not identity", position: .init(90, -75), angle: 30, side: "B.Cu", locked: true)]
        return p
    }
    private func schematic(_ p: EDAProject, index: Int = 0) -> EDASelection {
        .init(context: .schematic(sheetID: p.sheets[index].id), objectIDs: [p.sheets[index].symbols[0].id])
    }
    private func board(_ p: EDAProject, index: Int = 0) -> EDASelection {
        .init(context: .board(boardID: p.boards[index].id), objectIDs: [p.boards[index].footprints[0].id])
    }
    private func root() throws -> URL {
        let base = ProcessInfo.processInfo.environment["FLOE_CROSS_PROBE_TEST_TEMP"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(UUID().uuidString)
    }
    private func bytes(_ root: URL) throws -> [String: Data] {
        let items = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        var result: [String: Data] = [:]
        for case let file as URL in items where (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
            result[String(file.path.dropFirst(root.path.count))] = try Data(contentsOf: file)
        }
        return result
    }

    @Test func stableComponentIdentityWinsOverReferencesAndListOrder() throws {
        var p = fixture(), wrong = p.boards[0].footprints[0]
        wrong.id = UUID(); wrong.componentID = UUID(); wrong.reference = p.components[0].reference
        p.boards[0].footprints.insert(wrong, at: 0)
        let forward = try EDACrossProbe.resolve(p, selection: schematic(p))
        #expect(forward.targets.count == 1)
        #expect(forward.targets[0].objectID == p.boards[0].footprints[1].id)
        #expect(forward.targets[0].componentID == p.components[0].id)
        #expect(forward.targets[0].context == .board(boardID: p.boards[0].id))
        let reverse = try EDACrossProbe.resolve(p, selection: .init(context: .board(boardID: p.boards[0].id), objectIDs: [p.boards[0].footprints[1].id]))
        #expect(reverse.targets.map(\.objectID) == p.sheets[0].symbols.map(\.id))
        #expect(reverse.targets[0].unit == 1)
    }

    @Test func everyBoardAndSymbolUnitIsExplicitAndAmbiguityNeverPicksTheFirst() async throws {
        var p = fixture()
        var sheet = p.sheets[0]; sheet.id = UUID(); sheet.name = "Other unit"
        sheet.symbols[0].id = UUID(); sheet.symbols[0].unit = 2; p.sheets.append(sheet)
        var physical = p.boards[0]; physical.id = UUID(); physical.name = "Second board"
        physical.footprints[0].id = UUID(); p.boards.append(physical)
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try await EDAProjectStore.create(root: dir, project: p), session = try await EDWorkbenchSession(store: store)
        session.selection = schematic(p)
        let request = try session.makeCrossProbeRequest(), before = try bytes(dir)
        #expect(Set(request.resolution.targets.map(\.context)) == Set(p.boards.map { .board(boardID: $0.id) }))
        await #expect(throws: EDACrossProbeError.chooseTarget) { try await session.crossProbe(request) }
        #expect(session.selection == schematic(p)); #expect(session.focusRequest == nil)
        await #expect(throws: EDACrossProbeError.invalidTarget) { try await session.crossProbe(request, targetID: "not a candidate") }
        let target = request.resolution.targets[1]
        try await session.crossProbe(request, targetID: target.id)
        #expect(session.selection == .init(context: target.context, objectIDs: [target.objectID]))
        let reverse = try session.makeCrossProbeRequest()
        #expect(Set(reverse.resolution.targets.map(\.unit)) == Set([1, 2]))
        let unit2 = try #require(reverse.resolution.targets.first { $0.unit == 2 })
        try await session.crossProbe(reverse, targetID: unit2.id)
        #expect(session.selection == schematic(p, index: 1))
        #expect(try bytes(dir) == before); #expect(!session.canUndo); #expect(session.revision == p.revision)
    }

    @Test func noCounterpartMissingLinkUnsynchronizedAssignmentAndVariantFailExplicitly() throws {
        var p = fixture()
        p.boards[0].footprints = []
        #expect(throws: EDACrossProbeError.noCounterpart) { try EDACrossProbe.resolve(p, selection: schematic(p)) }
        p = fixture(); p.boards[0].footprints[0].componentID = nil
        #expect(throws: EDACrossProbeError.noComponentLink) { try EDACrossProbe.resolve(p, selection: board(p)) }
        #expect(throws: EDACrossProbeError.noCounterpart) { try EDACrossProbe.resolve(p, selection: schematic(p)) }
        p = fixture(); p.boards[0].footprints[0].definitionID = UUID()
        #expect(throws: EDACrossProbeError.notSynchronized) { try EDACrossProbe.resolve(p, selection: board(p)) }
        #expect(throws: EDACrossProbeError.notSynchronized) { try EDACrossProbe.resolve(p, selection: schematic(p)) }
        p = fixture(); p.components[0].excludedVariants = ["DNP"]; p.variants.append("DNP")
        #expect(throws: EDACrossProbeError.excludedVariant) { try EDACrossProbe.resolve(p, selection: schematic(p), variant: "DNP") }
        #expect(throws: EDACrossProbeError.unknownVariant) { try EDACrossProbe.resolve(p, selection: schematic(p), variant: "unknown") }
        #expect(try EDACrossProbe.resolve(p, selection: schematic(p)).variant == nil)
        #expect(try EDACrossProbe.resolve(p, selection: schematic(p), variant: "Default").targets.count == 1)
        #expect(throws: EDACrossProbeError.selectOneComponent) { try EDACrossProbe.resolve(p, selection: .none) }
        #expect(!EDACrossProbe.isComponentSelection(p, selection: .init(context: .symbol(definitionID: p.symbols[0].id), objectIDs: [p.symbols[0].pins[0].id])))
    }

    @Test func excessiveTargetsAndGeometryRefuseInsteadOfTruncatingOrHangingNavigation() throws {
        var p = fixture()
        let existing = p.boards[0].footprints[0]
        p.boards[0].footprints = (0...EDACrossProbe.maximumTargets).map { _ in
            var copy = existing; copy.id = UUID(); return copy
        }
        #expect(throws: EDACrossProbeError.tooManyTargets) { try EDACrossProbe.resolve(p, selection: schematic(p)) }
        p = fixture()
        p.footprints[0].graphics = Array(repeating: .circle(center: .zero, radius: 1, width: 0.1), count: EDACrossProbe.maximumDisplayPoints / 4 + 1)
        #expect(throws: EDACrossProbeError.geometryBudget) { try EDACrossProbe.resolve(p, selection: schematic(p)) }
    }

    @Test func transformedPadAndCorrectUnitGeometryFitsOnScreen() throws {
        var p = fixture()
        p.symbols[0].pins.append(.init(number: "9", position: .init(5000, 0), unit: 2))
        let target = try #require(EDACrossProbe.resolve(p, selection: schematic(p)).targets.first)
        let projection = EDAProjection(bounds: target.bounds.rect, size: .init(width: 360, height: 240), center: target.bounds.center)
        let pad = p.footprints[0].pads[0], placed = p.boards[0].footprints[0]
        for point in [EDAPoint(-5,-1), .init(5,-1), .init(5,1), .init(-5,1)] {
            let q = projection.screen(placed.point(point.transformed(origin: pad.position, angle: pad.angle)))
            #expect(q.x >= 20 && q.x <= 340 && q.y >= 20 && q.y <= 220)
        }
        let back = try #require(EDACrossProbe.resolve(p, selection: board(p)).targets.first)
        #expect(back.unit == 1); #expect(back.bounds.rect.width < 30)
        let reverse = EDAProjection(bounds: back.bounds.rect, size: .init(width: 320, height: 200), center: back.bounds.center)
        let q = reverse.screen(p.sheets[0].symbols[0].position)
        #expect(q.x >= 20 && q.x <= 300 && q.y >= 20 && q.y <= 180)
    }

    @Test func largeSupportedGeometryStillFitsWhenTheExistingProjectionHitsItsScaleFloor() throws {
        var p = fixture()
        p.footprints[0].graphics = [.circle(center: .zero, radius: 100_000, width: 0.2)]
        let target = try #require(EDACrossProbe.resolve(p, selection: schematic(p)).targets.first)
        let size = CGSize(width: 160, height: 160)
        let viewport = EDACrossProbe.fittingViewport(target.bounds, size: size)
        let projection = EDAProjection(bounds: viewport.bounds.rect, size: size, center: viewport.center, zoom: viewport.zoom)
        for local in [EDAPoint(100_000, 0), .init(-100_000, 0), .init(0, 100_000), .init(0, -100_000)] {
            let point = projection.screen(p.boards[0].footprints[0].point(local))
            #expect(point.x >= 20 && point.x <= 140 && point.y >= 20 && point.y <= 140)
        }
    }

    @Test func locateAndReturnPreserveOriginalBytesUndoAndPriorPanZoom() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try await EDAProjectStore.create(root: dir, project: fixture()), session = try await EDWorkbenchSession(store: store)
        try await session.apply([.rename("one existing undo entry")])
        let source = session.project, before = try bytes(dir), selection = schematic(source)
        let context = try #require(selection.context)
        let viewport = EDACanvasViewport(bounds: .init(min: .init(-100,-70), max: .init(120,90)), center: .init(492,399), zoom: 8)
        session.rememberCanvasViewport(viewport, for: context); session.selection = selection
        var saved = 0, changed = 0; session.onSaved = { _ in saved += 1 }; session.onChange = { changed += 1 }
        let request = try session.makeCrossProbeRequest()
        let actual = try await session.crossProbe(request)
        #expect(session.focusRequest?.context == actual.context)
        #expect(session.focusRequest?.fitBounds == actual.bounds)
        #expect(session.canReturnFromCrossProbe)
        #expect(session.consumeFocusRequest(for: context) == nil)
        #expect(session.consumeFocusRequest(for: actual.context) != nil)
        #expect(session.consumeFocusRequest(for: actual.context) == nil)
        try await session.returnFromCrossProbe()
        #expect(session.selection == selection)
        #expect(session.focusRequest?.context == context)
        #expect(session.focusRequest?.viewport == viewport)
        #expect(session.focusRequest?.positionMillimetres == viewport.center)
        #expect(!session.canReturnFromCrossProbe)
        #expect(session.canUndo); #expect(!session.canRedo); #expect(!session.isDirty)
        #expect(session.project == source && saved == 0 && changed == 0)
        #expect(try bytes(dir) == before)
        #expect(try await store.load().project == source)
    }

    @Test func staleRevisionChangedSelectionAndDifferentOwnerNeverJump() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try await EDAProjectStore.create(root: dir, project: fixture()), session = try await EDWorkbenchSession(store: store)
        session.selection = schematic(session.project)
        let request = try session.makeCrossProbeRequest(), other = try await EDWorkbenchSession(store: store)
        other.selection = session.selection
        await #expect(throws: EDACrossProbeError.ownerChanged) { try await other.crossProbe(request) }
        #expect(other.focusRequest == nil)
        session.selection = .none
        await #expect(throws: EDACrossProbeError.selectionChanged) { try await session.crossProbe(request) }
        session.selection = request.selection
        try await session.apply([.rename("new revision")])
        let before = try bytes(dir)
        await #expect(throws: EDACrossProbeError.sourceChanged) { try await session.crossProbe(request) }
        #expect(session.selection == request.selection && session.focusRequest == nil)
        #expect(try bytes(dir) == before)
    }

    @Test func externalOriginalChangeIsDetectedBeforeAdoptingSelection() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try await EDAProjectStore.create(root: dir, project: fixture()), session = try await EDWorkbenchSession(store: store)
        session.selection = schematic(session.project)
        let request = try session.makeCrossProbeRequest(), original = try await store.load()
        var external = original.project; external.revision += 1; external.title = "external CAS writer"
        _ = try await store.save(external, expectedRevision: original.project.revision, expectedDigest: original.digest)
        let before = try bytes(dir)
        await #expect(throws: EDACrossProbeError.sourceChanged) { try await session.crossProbe(request) }
        #expect(session.selection == request.selection && session.focusRequest == nil)
        #expect(!session.isDirty && !session.canUndo)
        #expect(try bytes(dir) == before)
    }

    @Test func closeAndCancellationWhileTheRealOriginalReadWaitsCannotJump() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try await EDAProjectStore.create(root: dir, project: fixture()), session = try await EDWorkbenchSession(store: store)
        session.selection = schematic(session.project)
        let request = try session.makeCrossProbeRequest(), before = try bytes(dir)
        let descriptor = Darwin.open(dir.appendingPathComponent(".floe-eda.lock").path, O_RDWR | O_NOFOLLOW)
        #expect(descriptor >= 0); defer { Darwin.close(descriptor) }
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        defer { flock(descriptor, LOCK_UN) }
        let waiting = Task { @MainActor in try await session.crossProbe(request) }
        try await Task.sleep(for: .milliseconds(30))
        #expect(session.focusRequest == nil)
        await session.close(); #expect(session.isClosed)
        flock(descriptor, LOCK_UN)
        await #expect(throws: EDAError.cancelled) { try await waiting.value }
        #expect(session.selection == .none && session.focusRequest == nil)
        #expect(try bytes(dir) == before)
        let reopened = try await EDWorkbenchSession(store: store); reopened.selection = schematic(reopened.project)
        let current = try reopened.makeCrossProbeRequest()
        let cancelled = Task { @MainActor in try await reopened.crossProbe(current) }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(reopened.selection == current.selection && reopened.focusRequest == nil)
        #expect(try bytes(dir) == before)
    }

    @Test func returnAfterARealEditRefusesAndViewportRestoreDoesNotReplayOldFocus() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try await EDAProjectStore.create(root: dir, project: fixture()), session = try await EDWorkbenchSession(store: store)
        session.selection = schematic(session.project)
        try await session.crossProbe(session.makeCrossProbeRequest())
        let selected = session.selection, oldFocus = session.focusRequest
        try await session.apply([.rename("new document")])
        #expect(!session.canReturnFromCrossProbe)
        let before = try bytes(dir)
        await #expect(throws: EDACrossProbeError.sourceChanged) { try await session.returnFromCrossProbe() }
        #expect(session.selection == selected && session.focusRequest == oldFocus)
        #expect(try bytes(dir) == before)
    }
}
