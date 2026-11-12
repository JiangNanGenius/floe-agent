// SPDX-License-Identifier: MPL-2.0
import XCTest
import SwiftUI
import FloeElectronicsCore
@testable import FloeElectronicsUI

final class EDWorkbenchLayoutTests: XCTestCase {
    func testWidthClassesUseConcreteThresholds() {
        XCTAssertEqual(EDWorkbenchLayout(width: 430, horizontalSizeClass: .compact).widthClass, .compact)
        XCTAssertEqual(EDWorkbenchLayout(width: 899, horizontalSizeClass: .regular).widthClass, .compact)
        XCTAssertEqual(EDWorkbenchLayout(width: 900, horizontalSizeClass: .regular).widthClass, .regular)
        XCTAssertEqual(EDWorkbenchLayout(width: 1_179, horizontalSizeClass: .regular).widthClass, .regular)
        XCTAssertEqual(EDWorkbenchLayout(width: 1_180, horizontalSizeClass: .regular).widthClass, .wide)
        XCTAssertEqual(EDWorkbenchLayout(width: 1_366, horizontalSizeClass: .regular).widthClass, .wide)
        // A compact split view never turns into side panels merely because it
        // is wide on screen.
        XCTAssertEqual(EDWorkbenchLayout(width: 1_366, horizontalSizeClass: .compact).widthClass, .compact)
        XCTAssertEqual(EDWorkbenchLayout(width: .nan, horizontalSizeClass: nil).width, 0)
        XCTAssertEqual(EDWorkbenchLayout(width: -100, horizontalSizeClass: nil).width, 0)
    }

    func testSidePanelsLeaveAConcreteCanvasBudget() {
        let wide = EDWorkbenchLayout(width: 1_366, horizontalSizeClass: .regular)
        XCTAssertTrue(wide.canShowSideNavigator)
        XCTAssertTrue(wide.canShowInspector)
        let fullBudget = wide.canvasBudget(showingNavigator: true, showingInspector: true)
        XCTAssertEqual(fullBudget, 1_366 - 52 - 1 - 204 - 1 - 280 - 1, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(fullBudget, EDWorkbenchLayout.minimumCanvasWidth)
        XCTAssertTrue(wide.sideInspectorKeepsCanvas(showingNavigator: true))

        let regular = EDWorkbenchLayout(width: 1_024, horizontalSizeClass: .regular)
        XCTAssertFalse(regular.canShowSideNavigator)
        XCTAssertTrue(regular.canShowInspector)
        XCTAssertEqual(regular.canvasBudget(showingNavigator: false, showingInspector: true),
                       1_024 - 52 - 1 - 280 - 1, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(regular.canvasBudget(showingNavigator: false, showingInspector: true),
                                    EDWorkbenchLayout.minimumCanvasWidth)

        let threshold = EDWorkbenchLayout(width: 900, horizontalSizeClass: .regular)
        XCTAssertEqual(threshold.canvasBudget(showingNavigator: false, showingInspector: true),
                       900 - 52 - 1 - 280 - 1, accuracy: 0.001)
        XCTAssertTrue(threshold.sideInspectorKeepsCanvas(showingNavigator: false))

        let compact = EDWorkbenchLayout(width: 899, horizontalSizeClass: .regular)
        XCTAssertTrue(compact.isCompact)
        XCTAssertFalse(compact.canShowInspector)
        XCTAssertFalse(compact.canShowSideNavigator)
        // Compact layouts never subtract a side surface; the tool row moves
        // above the canvas rather than stealing its width.
        XCTAssertEqual(compact.canvasBudget(showingNavigator: true, showingInspector: true), 899, accuracy: 0.001)
        XCTAssertFalse(compact.sideInspectorKeepsCanvas(showingNavigator: false))
    }

    func testToolCatalogKeepsEveryExistingCanvasTool() {
        XCTAssertEqual(EDToolCatalog.canvasGroups(for: .board).flatMap { $0 }, EDCanvasTool.boardTools)
        XCTAssertEqual(EDToolCatalog.canvasGroups(for: .schematic).flatMap { $0 }, EDCanvasTool.schematicTools)
        XCTAssertEqual(EDToolCatalog.libraryTools(for: .symbols), EDLibraryTool.symbolTools)
        XCTAssertEqual(EDToolCatalog.libraryTools(for: .footprints), EDLibraryTool.footprintTools)
        XCTAssertTrue(EDToolCatalog.canvasGroups(for: .checks).isEmpty)
        XCTAssertTrue(EDToolCatalog.libraryTools(for: .board).isEmpty)
        for groups in [EDToolCatalog.canvasGroups(for: .board), EDToolCatalog.canvasGroups(for: .schematic)] {
            let flat = groups.flatMap { $0 }
            XCTAssertEqual(Set(flat).count, flat.count)
        }
    }

    func testZoomClampMatchesTheCanvasContract() {
        XCTAssertEqual(EDCanvasZoom.clamped(0), EDCanvasZoom.minimum, accuracy: 0.0001)
        XCTAssertEqual(EDCanvasZoom.clamped(-10), EDCanvasZoom.minimum, accuracy: 0.0001)
        XCTAssertEqual(EDCanvasZoom.clamped(1), 1, accuracy: 0.0001)
        XCTAssertEqual(EDCanvasZoom.clamped(10_000), EDCanvasZoom.maximum, accuracy: 0.0001)
        XCTAssertEqual(EDCanvasZoom.clamped(.nan), 1, accuracy: 0.0001)
        XCTAssertEqual(EDCanvasZoom.clamped(.infinity), 1, accuracy: 0.0001)
    }

    @MainActor
    func testInspectorDraftStoreSurvivesRecreatedInspectorPresentation() {
        let store = EDInspectorDraftStore()
        let projectID = UUID(), boardID = UUID(), trackID = UUID()
        let key = EDInspectorDraftKey(projectID: projectID, context: .board(boardID: boardID),
                                      objectID: trackID, valueType: "EDATrack")
        let original = EDATrack(netID: "A", width: 0.25, points: [.zero, .init(10, 0)])
        let first = store.binding(for: key, initial: EDInspectorDraft(original, revision: 7))
        let revisionBeforeEdit = store.revision
        first.wrappedValue.value.width = 0.5
        XCTAssertGreaterThan(store.revision, revisionBeforeEdit)
        XCTAssertTrue(first.wrappedValue.isDirty)

        // Removing the inline inspector and constructing the compact sheet
        // editor again asks the same store for the same selected object key.
        let recreated = store.binding(for: key, initial: EDInspectorDraft(original, revision: 7))
        XCTAssertEqual(recreated.wrappedValue.value.width, 0.5)
        XCTAssertEqual(recreated.wrappedValue.baseline, original)
        XCTAssertEqual(recreated.wrappedValue.revision, 7)
        XCTAssertTrue(recreated.wrappedValue.isDirty)

        // A changed original must retain the unapplied edit and mark conflict;
        // the store never auto-applies or silently discards it.
        recreated.wrappedValue.receive(original, revision: 8)
        XCTAssertTrue(recreated.wrappedValue.needsReload)
        XCTAssertEqual(recreated.wrappedValue.value.width, 0.5)
    }

    @MainActor
    func testInspectorDraftStoreIsBoundedAndUsesTheInjectedEnvironment() {
        let store = EDInspectorDraftStore(capacity: 2)
        let projectID = UUID(), boardID = UUID()
        let original = EDATrack(netID: "A", width: 0.25, points: [.zero, .init(10, 0)])
        func key(_ suffix: Int) -> EDInspectorDraftKey {
            .init(projectID: projectID, context: .board(boardID: boardID),
                  objectID: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!,
                  valueType: "EDATrack")
        }
        let firstKey = key(1), secondKey = key(2), thirdKey = key(3)
        let first = store.binding(for: firstKey, initial: EDInspectorDraft(original, revision: 1))
        first.wrappedValue.value.width = 0.75
        _ = store.binding(for: secondKey, initial: EDInspectorDraft(original, revision: 1))
        _ = store.binding(for: thirdKey, initial: EDInspectorDraft(original, revision: 1))
        XCTAssertEqual(store.count, 2)
        // First entry was evicted rather than growing without a bound.
        let firstAgain = store.binding(for: firstKey, initial: EDInspectorDraft(original, revision: 1))
        XCTAssertEqual(firstAgain.wrappedValue.value.width, 0.25)
        XCTAssertFalse(firstAgain.wrappedValue.isDirty)

        var environment = EnvironmentValues()
        environment.edInspectorDraftStore = store
        XCTAssertTrue(environment.edInspectorDraftStore === store)

        store.removeAll()
        XCTAssertEqual(store.count, 0)
    }

    @MainActor
    func testRemoteLibraryCallbackIsOptionalAndStored() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("floe-eda-workbench-ui-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await EDAProjectStore.create(root: root, project: EDABuiltinLibrary.makeProject(title: "UI callback"))
        let session = try await EDWorkbenchSession(store: store)
        var invoked = false
        let withCallback = EDWorkbenchView(session: session, onRemoteLibrary: { invoked = true })
        withCallback.onRemoteLibrary?()
        XCTAssertTrue(invoked)
        let legacy = EDWorkbenchView(session: session)
        XCTAssertNil(legacy.onRemoteLibrary)
        let closed = await session.flushForClose()
        XCTAssertTrue(closed)
    }
}
