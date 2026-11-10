import XCTest
import Foundation
import FloeElectronicsCore
@testable import FloeElectronicsUI

@MainActor final class EDLibraryUIControllerTests: XCTestCase {
    private func root() throws -> URL {
        let base = ProcessInfo.processInfo.environment["FLOE_EDA_LIBRARY_PROOF_DIR"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory.appendingPathComponent("FloeElectronicsLibraryTests")
        let root = base.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    func testActualBundledPackagesSearchReadPlaceSaveReopenAndRecentShareOneOriginal() async throws {
        let root = try root(), store = try EDALibraryStore(root: root.appendingPathComponent("Libraries")), library = EDLibraryController(store: store)
        let catalog = try await library.prepare()
        XCTAssertEqual(catalog.entries.count, 47); XCTAssertEqual(Set(catalog.entries.map(\.part.category)).count, 12)
        let result = try catalog.search(.init(text: "2N7002", limit: 20)), entry = try XCTUnwrap(result.entries.first)
        XCTAssertEqual(result.total, 1); XCTAssertEqual(entry.part.pinMap?.pinToPads["1"], ["1"])
        let snapshot = try await library.snapshot(entry.reference)
        XCTAssertFalse(snapshot.originalSources?.isEmpty ?? true)
        let original = EDAProject(title: "Real library original"), projects = try await EDAProjectStore.create(root: root.appendingPathComponent("Original"), project: original)
        let session = try await EDWorkbenchSession(store: projects); session.library = library
        let context = EDADocumentContext.schematic(sheetID: original.sheets[0].id)
        let receipt = try await session.placeLibrary(.init(snapshot: snapshot), context: context, position: .init(10, 20), expectedRevision: 0)
        let saved = try await projects.load()
        XCTAssertEqual(saved.project.revision, 1); XCTAssertEqual(saved.project.components.first?.id, receipt.componentID)
        XCTAssertEqual(try EDALibraryProject.snapshot(receipt.snapshotSHA256, in: saved.project).part.parameters["PartNumber"], "2N7002")
        XCTAssertEqual(library.catalog.preferences.recent.first, EDALibraryPreferences.key(packageID: snapshot.packageID, partID: snapshot.part.id))
        let reopened = try await EDWorkbenchSession(store: projects); XCTAssertEqual(reopened.project, saved.project)
        let closed = await session.flushForClose(), reopenedClosed = await reopened.flushForClose(); XCTAssertTrue(closed); XCTAssertTrue(reopenedClosed)
    }
    func testNativeSchematicAndBoardKeepOneComponentValueAndUndoTheSameSavedOriginal() async throws {
        let root = try root(), library = EDLibraryController(store: try EDALibraryStore(root: root.appendingPathComponent("Library")))
        let catalog = try await library.prepare(), entry = try XCTUnwrap(try catalog.search(.init(text: "2N7002")).entries.first)
        let snapshot = try await library.snapshot(entry.reference), project = EDAProject(title: "Linked original")
        let store = try await EDAProjectStore.create(root: root.appendingPathComponent("Project"), project: project), session = try await EDWorkbenchSession(store: store)
        session.library = library
        let symbol = try await session.placeLibrary(.init(snapshot: snapshot), context: .schematic(sheetID: project.sheets[0].id), position: .zero, expectedRevision: 0)
        _ = try await session.placeLibrary(.init(snapshot: snapshot, existingComponentID: symbol.componentID), context: .board(boardID: project.boards[0].id), position: .init(10, 10), expectedRevision: 1)
        let saved = try await store.load(); XCTAssertEqual(saved.project.components.count, 1)
        XCTAssertEqual(saved.project.boards[0].footprints[0].componentID, symbol.componentID)
        XCTAssertEqual(saved.project.boards[0].footprints[0].value, saved.project.components[0].value)
        try await session.undo(expectedRevision: 2)
        let undone = try await store.load(); XCTAssertTrue(undone.project.boards[0].footprints.isEmpty); XCTAssertEqual(undone.project.components.count, 1)
    }
    func testImportedIndependentPartsCanBeExplicitlyAssociatedPlacedAndReadBack() async throws {
        let root = try root(), store = try EDALibraryStore(root: root.appendingPathComponent("Libraries")), library = EDLibraryController(store: store)
        let catalog = try await library.prepare(), bundled = try XCTUnwrap(try catalog.search(.init(text: "2N7002")).entries.first)
        let bytes = try await library.snapshot(bundled.reference)
        let preview = try EDALibraryImport.inspect(files: XCTUnwrap(bytes.originalSources), title: "Imported independent KiCad files")
        _ = try await store.install(XCTUnwrap(preview.package)); try await library.refresh()
        let source = try XCTUnwrap(library.catalog.entries.first { $0.part.kind == .symbol && $0.part.name == "2N7002" })
        let footprint = try XCTUnwrap(library.catalog.entries.first { $0.part.kind == .footprint && $0.part.name == "SOT-23" })
        let entry = try await library.associate(symbol: source.reference, footprint: footprint.reference,
            map: .init(pinToPads: ["1": ["1"], "2": ["2"], "3": ["3"]]), name: "Explicit user combination")
        XCTAssertTrue(entry.reference.packageID.hasPrefix("user.association.")); XCTAssertEqual(entry.part.kind, .generic)
        XCTAssertEqual(entry.part.parameters["PartNumber"], ""); XCTAssertTrue(entry.part.supportsBoundPCB)
        let snapshot = try await library.snapshot(entry.reference), original = EDAProject(title: "Association original")
        let projects = try await EDAProjectStore.create(root: root.appendingPathComponent("Project"), project: original), session = try await EDWorkbenchSession(store: projects)
        session.library = library
        let placed = try await session.placeLibrary(.init(snapshot: snapshot), context: .schematic(sheetID: original.sheets[0].id), position: .zero, expectedRevision: 0)
        let saved = try await projects.load()
        XCTAssertEqual(try EDALibraryProject.snapshot(placed.snapshotSHA256, in: saved.project), snapshot)
        XCTAssertEqual(library.catalog.preferences.recent.first, EDALibraryPreferences.key(packageID: snapshot.packageID, partID: snapshot.part.id))
        let index = try await store.inventory()
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: index.installed.filter { $0.packageID.hasPrefix(EDALibraryContent.packagePrefix) }.map { ($0.packageID, $0.version) }), EDALibraryContent.builtInVersions)
    }
    func testLibraryFavoritesAndPinnedPartSurviveControllerRecreationWithoutChangingDesign() async throws {
        let root = try root(), store = try EDALibraryStore(root: root), library = EDLibraryController(store: store)
        let catalog = try await library.prepare(), entry = try XCTUnwrap(try catalog.search(.init(text: "Arduino_Nano_v3.x")).entries.first)
        try await store.setFavorite(packageID: entry.reference.packageID, partID: entry.reference.partID, enabled: true)
        let next = EDLibraryController(store: try EDALibraryStore(root: root)), loaded = try await next.prepare()
        XCTAssertEqual(loaded.entries.count, 47); XCTAssertTrue(next.isFavorite(entry))
        let snapshot = try await next.snapshot(entry.reference); XCTAssertTrue(snapshot.part.supportsBoundPCB)
        XCTAssertEqual(snapshot.part.pinCount, Set(snapshot.part.footprint?.pads.map(\.number) ?? []).count)
    }
}
