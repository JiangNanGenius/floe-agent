// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeElectronicsCore
@testable import FloeElectronicsUI

/// Behavior behind the symbol/footprint library canvases: shape construction,
/// hit testing, numbering, localization and the session save/undo/CAS path.
@MainActor final class EDLibraryEditingTests: XCTestCase {
    private func temporary() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("floe-eda-library-" + UUID().uuidString) }

    func testShapeHelpersProduceOnlyValidGraphics() {
        let a = EDAPoint(-2.54, -1.27), b = EDAPoint(2.54, 1.27)
        XCTAssertEqual(EDLibraryEditing.lineShape(from: a, to: b), .line(a, b, width: 0.2))
        XCTAssertEqual(EDLibraryEditing.rectangleShape(from: a, to: b), .rectangle(a, b, width: 0.2))
        XCTAssertEqual(EDLibraryEditing.circleShape(from: .zero, to: EDAPoint(3, 4)), .circle(center: .zero, radius: 5, width: 0.2))
        XCTAssertEqual(EDLibraryEditing.circleShape(from: .zero, to: .zero), nil)
        XCTAssertEqual(EDLibraryEditing.circleShape(from: .zero, to: EDAPoint(0.001, 0)), nil)
        XCTAssertEqual(EDLibraryEditing.lineShape(from: a, to: a), nil)
        XCTAssertEqual(EDLibraryEditing.rectangleShape(from: a, to: a), nil)
        XCTAssertEqual(EDLibraryEditing.lineShape(from: a, to: b, stroke: 0), nil)
    }

    func testTranslatedMovesEveryGraphicKind() {
        let delta = EDAPoint(1.5, -2.5)
        let graphics: [EDAGraphic] = [
            .line(.init(0, 0), .init(1, 1), width: 0.2),
            .rectangle(.init(0, 0), .init(2, 2), width: 0.2),
            .circle(center: .zero, radius: 3, width: 0.2),
            .arc(center: .zero, radius: 3, start: 0, sweep: 90, width: 0.2),
            .text("A", position: .init(1, 2), height: 1.8, angle: 0),
            .dimension(.init(0, 0), .init(4, 0), offset: 1)
        ]
        for graphic in graphics {
            switch (graphic, EDLibraryEditing.translated(graphic, by: delta)) {
            case let (.line(a, b, w), .line(a2, b2, w2)):
                XCTAssertEqual(a + delta, a2); XCTAssertEqual(b + delta, b2); XCTAssertEqual(w, w2)
            case let (.rectangle(a, b, w), .rectangle(a2, b2, w2)):
                XCTAssertEqual(a + delta, a2); XCTAssertEqual(b + delta, b2); XCTAssertEqual(w, w2)
            case let (.circle(c, r, w), .circle(c2, r2, w2)):
                XCTAssertEqual(c + delta, c2); XCTAssertEqual(r, r2); XCTAssertEqual(w, w2)
            case let (.arc(c, r, s, sw, w), .arc(c2, r2, s2, sw2, w2)):
                XCTAssertEqual(c + delta, c2); XCTAssertEqual(r, r2); XCTAssertEqual(s, s2); XCTAssertEqual(sw, sw2); XCTAssertEqual(w, w2)
            case let (.text(v, p, h, an), .text(v2, p2, h2, an2)):
                XCTAssertEqual(v, v2); XCTAssertEqual(p + delta, p2); XCTAssertEqual(h, h2); XCTAssertEqual(an, an2)
            case let (.dimension(a, b, o), .dimension(a2, b2, o2)):
                XCTAssertEqual(a + delta, a2); XCTAssertEqual(b + delta, b2); XCTAssertEqual(o, o2)
            default: XCTFail("Unexpected translated graphic")
            }
        }
    }

    func testHitTestingFindsPinsPadsAndNearestGraphic() {
        let pin = EDAPin(number: "1", position: .init(0, 0))
        let symbol = EDASymbolDefinition(name: "S", pins: [pin], graphics: [.line(.init(10, 0), .init(20, 0), width: 0.2)])
        XCTAssertEqual(EDLibraryEditing.hitSymbol(symbol, at: .init(0.5, 0), tolerance: 1), .pin(pin.id))
        XCTAssertEqual(EDLibraryEditing.hitSymbol(symbol, at: .init(15, 0.4), tolerance: 1), .graphic(0))
        XCTAssertEqual(EDLibraryEditing.hitSymbol(symbol, at: .init(15, 6), tolerance: 1), nil)
        XCTAssertEqual(EDLibraryEditing.hitSymbol(symbol, at: .init(0.5, 0), tolerance: 0.25), nil)

        let pad = EDAPad(number: "1", position: .init(0, 0))
        let footprint = EDAFootprintDefinition(name: "F", pads: [pad], graphics: [.rectangle(.init(-5, -5), .init(5, 5), width: 0.15)])
        XCTAssertEqual(EDLibraryEditing.hitFootprint(footprint, at: .init(0.4, 0), tolerance: 1), .pad(pad.id))
        XCTAssertEqual(EDLibraryEditing.hitFootprint(footprint, at: .init(5, 0.4), tolerance: 1), .graphic(0))
        XCTAssertEqual(EDLibraryEditing.hitFootprint(footprint, at: .init(9, 9), tolerance: 1), nil)
    }

    func testAutomaticNumberingSkipsUsedValues() {
        let pins = [EDAPin(number: "1", position: .zero), EDAPin(number: "2", position: .zero), EDAPin(number: "10", position: .zero)]
        XCTAssertEqual(EDLibraryEditing.nextPinNumber(pins), "3")
        XCTAssertEqual(EDLibraryEditing.nextPinNumber([]), "1")
        let pads = [EDAPad(number: "1", position: .zero), EDAPad(number: "3", position: .zero)]
        XCTAssertEqual(EDLibraryEditing.nextPadNumber(pads), "2")
        XCTAssertEqual(EDLibraryEditing.nextPadNumber([]), "1")
    }

    func testLocalizedTitlesCoverAllModelCases() {
        for type in EDAPinType.allCases {
            let title = edaPinTypeTitle(type)
            XCTAssertFalse(title.isEmpty, "Pin type \(type.rawValue) lacks a title")
            XCTAssertNotEqual(title, type.rawValue, "Pin type \(type.rawValue) leaks its raw label")
        }
        for shape in EDAPadShape.allCases {
            let title = edaPadShapeTitle(shape)
            XCTAssertFalse(title.isEmpty, "Pad shape \(shape.rawValue) lacks a title")
            XCTAssertNotEqual(title, shape.rawValue, "Pad shape \(shape.rawValue) leaks its raw label")
        }
        let graphics: [EDAGraphic] = [.line(.zero, .init(1, 0), width: 0.2), .rectangle(.zero, .init(1, 1), width: 0.2),
                                      .circle(center: .zero, radius: 1, width: 0.2), .arc(center: .zero, radius: 1, start: 0, sweep: 90, width: 0.2),
                                      .text("T", position: .zero, height: 1.8, angle: 0), .dimension(.zero, .init(1, 0), offset: 0)]
        for graphic in graphics {
            XCTAssertFalse(edaGraphicKindTitle(graphic).isEmpty)
            XCTAssertTrue(edaGraphicSummary(graphic).contains("mm"), "Summary for \(graphic) carries no unit")
        }
    }

    func testSymbolDefinitionEditsSaveUndoReopenThroughSession() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try await EDAProjectStore.create(root: root, project: EDABuiltinLibrary.makeProject(title: "Library"))
        let session = try await EDWorkbenchSession(store: store)
        let original = try XCTUnwrap(session.project.symbols.first)
        let addedPin = EDAPin(number: EDLibraryEditing.nextPinNumber(original.pins), position: .init(0, 5.08))
        var edited = original
        edited.pins.append(addedPin)
        edited.graphics.append(.circle(center: .zero, radius: 3, width: 0.2))
        try await session.apply([.putSymbol(edited)], expectedRevision: 0)
        XCTAssertEqual(session.project.symbols.first(where: { $0.id == original.id })?.pins.count, original.pins.count + 1)
        XCTAssertFalse(session.isDirty)

        try await session.undo(expectedRevision: 1)
        XCTAssertEqual(session.project.symbols.first(where: { $0.id == original.id }), original)
        try await session.redo(expectedRevision: 2)
        XCTAssertEqual(session.project.symbols.first(where: { $0.id == original.id })?.pins.last?.id, addedPin.id)

        let reopened = try await EDWorkbenchSession(store: store)
        let persisted = try XCTUnwrap(reopened.project.symbols.first(where: { $0.id == original.id }))
        XCTAssertEqual(persisted.pins.last?.id, addedPin.id)
        XCTAssertEqual(persisted.graphics.last, .circle(center: .zero, radius: 3, width: 0.2))
    }

    func testFootprintPadAndGraphicEditsPersistAndStayValid() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try await EDAProjectStore.create(root: root, project: EDABuiltinLibrary.makeProject(title: "Footprints"))
        let session = try await EDWorkbenchSession(store: store)
        let original = try XCTUnwrap(session.project.footprints.first)
        var edited = original
        let pad = EDAPad(number: EDLibraryEditing.nextPadNumber(original.pads), position: .init(1.27, 0))
        edited.pads.append(pad)
        edited.graphics.removeAll()
        try await session.apply([.putFootprintDefinition(edited)], expectedRevision: 0)
        XCTAssertFalse(session.isDirty)

        var removed = edited
        removed.pads.removeAll { $0.id == pad.id }
        try await session.apply([.putFootprintDefinition(removed)], expectedRevision: 1)
        let reopened = try await EDWorkbenchSession(store: store)
        XCTAssertEqual(reopened.project.footprints.first(where: { $0.id == original.id })?.pads.map(\.id), original.pads.map(\.id))
        XCTAssertEqual(reopened.project.footprints.first(where: { $0.id == original.id })?.graphics.count, 0)
    }

    func testStaleDefinitionEditKeepsProposalAndReportsConflict() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try await EDAProjectStore.create(root: root, project: EDABuiltinLibrary.makeProject(title: "CAS"))
        let first = try await EDWorkbenchSession(store: store), second = try await EDWorkbenchSession(store: store)
        let symbol = try XCTUnwrap(first.project.symbols.first)
        var proposal = symbol; proposal.pins.append(.init(number: "99", position: .zero))
        try await first.apply([.putSymbol(proposal)], expectedRevision: 0)
        do {
            try await second.apply([.putSymbol(proposal)], expectedRevision: 0)
            XCTFail("Concurrent definition overwrite accepted")
        } catch EDAError.staleRevision {}
        XCTAssertTrue(second.conflictWithOriginal)
        XCTAssertEqual(second.project.symbols.first(where: { $0.id == symbol.id })?.pins.last?.number, "99")
        let stored = try await store.load()
        XCTAssertEqual(stored.project.symbols.first(where: { $0.id == symbol.id })?.pins.count, symbol.pins.count + 1)
    }
}
