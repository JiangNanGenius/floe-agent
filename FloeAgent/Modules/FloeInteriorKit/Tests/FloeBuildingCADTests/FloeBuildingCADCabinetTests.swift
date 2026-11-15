// SPDX-License-Identifier: MPL-2.0
// SOURCE_ONLY_UNTIL_COORDINATOR_NATIVE_WINDOW
#if os(iOS)
import XCTest
import Foundation
import FloeCAD
import FloeInteriorCore
@testable import FloeBuildingCAD

final class FloeBuildingCADCabinetTests: XCTestCase {
    @MainActor
    func testNineteenPanelsSheetWidthUpdateAndReopen() async throws {
        let (session, root) = try await FloeBuildingCADTestSupport.makeSession("cabinet-sheet")
        defer { session.close(); try? FileManager.default.removeItem(at: root) }
        let recipe = FloeBuildingCADTestSupport.cabinetRecipe()
        let assembly = try CabinetBuilder.build(recipe)
        XCTAssertEqual(assembly.panels.count, 19)
        let binding = try await session.createCabinet(recipe)
        XCTAssertEqual(binding.panelBindings.count, 19)
        XCTAssertEqual(Set(binding.panelBindings.map(\.panelID)).count, 19)
        XCTAssertEqual(Set(binding.panelBindings.map(\.bodyID)).count, 19)
        XCTAssertEqual(Set(binding.panelBindings.map(\.instanceID)).count, 19)
        XCTAssertEqual(session.document.summary().bodyCount, 19)
        XCTAssertEqual(FloeBuildingCADTestSupport.assemblyInstanceIDs(session.document).count, 19)

        let sheet = try await session.makeCombinationSheet(cabinet: binding)
        XCTAssertEqual(sheet.documentScope, "project")
        XCTAssertEqual(session.document.summary().drawingPageCount, 1)
        var payload = FloeBuildingCADTestSupport.pageGeometry(session.document, pageID: sheet.pageID)
        XCTAssertEqual(payload["projectionComplete"] as? Bool, true)
        XCTAssertEqual(payload["outputBlocked"] as? Bool, false)
        let views = try XCTUnwrap(payload["views"] as? [[String: Any]])
        XCTAssertEqual(views.count, 5)
        for view in views {
            XCTAssertEqual(view["instanceCount"] as? Int, 19)
            XCTAssertEqual(view["projectionComplete"] as? Bool, true)
            XCTAssertEqual(view["outputBlocked"] as? Bool, false)
            XCTAssertTrue((view["missingInstanceIDs"] as? [String] ?? ["missing"]).isEmpty)
        }
        XCTAssertEqual(FloeBuildingCADTestSupport.fingerprintInstanceIDs(payload),
                       Set(binding.panelBindings.map(\.instanceID)))
        var auto = FloeBuildingCADTestSupport.autoValues(payload)
        XCTAssertTrue(FloeBuildingCADTestSupport.hasValue(auto, 2400))
        XCTAssertTrue(FloeBuildingCADTestSupport.hasValue(auto, 2100))
        XCTAssertTrue(FloeBuildingCADTestSupport.hasValue(auto, 620))
        var manual = FloeBuildingCADTestSupport.manualValues(payload, sheet: sheet)
        XCTAssertEqual(try XCTUnwrap(manual["carcass-depth"]), 600, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(manual["panel-thickness"]), 18, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(manual["shelf-thickness"]), 18, accuracy: 0.01)
        XCTAssertTrue(manual.keys.contains { $0.hasPrefix("clear-opening-") })

        // Move one cabinet-owned dimension and add a text override; the
        // width refresh must keep that manual layout.
        let dim = try XCTUnwrap(sheet.dimensionBindings.first { $0.role == "carcass-depth" })
        let drawing = CADDrawingService(document: session.document)
        let moved = drawing.handle(action: "updateDimension", args: [
            "pageID": sheet.pageID.uuidString,
            "dimensionID": dim.dimensionID.uuidString,
            "textPosition": [123.0, 45.0],
            "text": "kept-depth",
        ])
        XCTAssertEqual(moved["ok"] as? Bool, true)

        var widened = recipe
        widened.widthMM = 2600
        let result = try await session.updateCabinet(recipe: widened, binding: binding)
        XCTAssertEqual(result.cabinet.panelBindings.map(\.panelID),
                       binding.panelBindings.map(\.panelID))
        XCTAssertEqual(result.cabinet.panelBindings.map(\.bodyID),
                       binding.panelBindings.map(\.bodyID))
        XCTAssertEqual(result.cabinet.panelBindings.map(\.instanceID),
                       binding.panelBindings.map(\.instanceID))
        XCTAssertFalse(result.sheetRefreshRequired)
        let refreshed = try XCTUnwrap(result.sheet)
        payload = FloeBuildingCADTestSupport.pageGeometry(session.document, pageID: refreshed.pageID)
        auto = FloeBuildingCADTestSupport.autoValues(payload)
        XCTAssertTrue(FloeBuildingCADTestSupport.hasValue(auto, 2600))
        XCTAssertTrue(FloeBuildingCADTestSupport.hasValue(auto, 2100))
        XCTAssertTrue(FloeBuildingCADTestSupport.hasValue(auto, 620))
        XCTAssertFalse(FloeBuildingCADTestSupport.hasValue(auto, 2400))
        manual = FloeBuildingCADTestSupport.manualValues(payload, sheet: refreshed)
        XCTAssertEqual(try XCTUnwrap(manual["carcass-depth"]), 600, accuracy: 0.01)
        let kept = try XCTUnwrap(refreshed.dimensionBindings.first { $0.role == "carcass-depth" })
        XCTAssertEqual(kept.textPosition, [123, 45])
        XCTAssertEqual(kept.textOverride, "kept-depth")

        let manifest = try FloeBuildingCADTestSupport.manifestRoundtrip(session.manifest)
        session.close()
        let reopened = try await FloeBuildingCADSession.open(
            at: root.appendingPathComponent("Project.floecad"))
        defer { reopened.close() }
        try reopened.installManifest(manifest)
        try reopened.validateCabinetBinding(result.cabinet)
        let reopenedSheet = try XCTUnwrap(reopened.manifest.sheet(cabinetID: result.cabinet.cabinetID))
        let reopenedPayload = FloeBuildingCADTestSupport.pageGeometry(
            reopened.document, pageID: reopenedSheet.pageID)
        let reopenedAuto = FloeBuildingCADTestSupport.autoValues(reopenedPayload)
        XCTAssertTrue(FloeBuildingCADTestSupport.hasValue(reopenedAuto, 2600))
        XCTAssertTrue(FloeBuildingCADTestSupport.hasValue(reopenedAuto, 2100))
        XCTAssertTrue(FloeBuildingCADTestSupport.hasValue(reopenedAuto, 620))
        let reopenedManual = FloeBuildingCADTestSupport.manualValues(
            reopenedPayload, sheet: reopenedSheet)
        XCTAssertEqual(try XCTUnwrap(reopenedManual["carcass-depth"]), 600, accuracy: 0.01)
    }

    @MainActor
    func testManualPanelEditMissingBodyAndInvalidFingerprintAreRefused() async throws {
        let (session, root) = try await FloeBuildingCADTestSupport.makeSession("cabinet-refusal")
        defer { session.close(); try? FileManager.default.removeItem(at: root) }
        let recipe = FloeBuildingCADTestSupport.cabinetRecipe()
        let binding = try await session.createCabinet(recipe)
        let beforeSummary = session.document.summary()
        let beforeInstances = FloeBuildingCADTestSupport.assemblyInstanceIDs(session.document)

        let panel = try XCTUnwrap(binding.panelBindings.first)
        let move = session.document.execute([
            "op": "feature.transform",
            "args": ["bodyID": panel.bodyID.uuidString, "translation": [10, 0, 0]],
        ])
        XCTAssertTrue(move.isOK, move.message ?? "")
        var width = recipe.widthMM - 50
        do {
            _ = try await session.updateCabinet(recipe: { var value = recipe; value.widthMM = width; return value }(),
                                                binding: binding)
            XCTFail("A manually moved panel must refuse the update.")
        } catch let error as FloeBuildingCADError {
            guard case .externalModification = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(session.document.summary().bodyCount, beforeSummary.bodyCount)
        XCTAssertEqual(FloeBuildingCADTestSupport.assemblyInstanceIDs(session.document), beforeInstances)
        let undo = CADParameterService(document: session.document).handle(action: "undo", args: [:])
        XCTAssertEqual(undo["ok"] as? Bool, true)
        try session.validateCabinetBinding(binding)

        var invalid = binding
        invalid.scheduleFingerprint = String(repeating: "0", count: 64)
        do {
            _ = try await session.updateCabinet(recipe: recipe, binding: invalid)
            XCTFail("A mismatched schedule fingerprint must be refused.")
        } catch let error as FloeBuildingCADError {
            guard case .invalidBinding = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        var missing = binding
        missing.panelBindings[0].bodyID = UUID()
        do {
            _ = try await session.updateCabinet(recipe: recipe, binding: missing)
            XCTFail("A binding with a lost body must be refused.")
        } catch let error as FloeBuildingCADError {
            guard case .externalModification = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(session.document.summary().bodyCount, beforeSummary.bodyCount)
    }

#if DEBUG
    @MainActor
    func testFailedCabinetUpdateRestoresOwnWritesAndKeepsPriorUndoHistory() async throws {
        let (session, root) = try await FloeBuildingCADTestSupport.makeSession("cabinet-rollback")
        defer { session.close(); try? FileManager.default.removeItem(at: root) }
        let recipe = FloeBuildingCADTestSupport.cabinetRecipe()
        let binding = try await session.createCabinet(recipe)
        _ = try await session.createBuilding(FloeBuildingCADTestSupport.sharedWallSpec())
        let beforeSummary = session.document.summary()
        let beforeInstances = FloeBuildingCADTestSupport.assemblyInstanceIDs(session.document)
        let beforeBuilding = try session.building()
        XCTAssertNotNil(beforeBuilding)

        FloeBuildingCADSession.testMutationFailure = { name in
            if name == "cabinet.update.afterFirstPanel" {
                throw FloeBuildingCADError.invalidInput("injected cabinet update failure")
            }
        }
        defer { FloeBuildingCADSession.testMutationFailure = nil }
        var widened = recipe
        widened.widthMM = 2600
        do {
            _ = try await session.updateCabinet(recipe: widened, binding: binding)
            XCTFail("The injected failure must abort the update.")
        } catch let error as FloeBuildingCADError {
            guard case .invalidInput = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(session.document.summary().bodyCount, beforeSummary.bodyCount)
        XCTAssertEqual(session.document.summary().featureCount, beforeSummary.featureCount)
        XCTAssertEqual(session.document.summary().drawingPageCount, beforeSummary.drawingPageCount)
        XCTAssertEqual(FloeBuildingCADTestSupport.assemblyInstanceIDs(session.document), beforeInstances)
        XCTAssertEqual(try session.building(), beforeBuilding)
        try session.validateCabinetBinding(binding)

        // The user's building transaction is still the newest undo entry.
        // Undo must remove that user edit, not one of the bridge's partial
        // panel updates (which would invalidate the cabinet binding).
        let undo = CADParameterService(document: session.document).handle(action: "undo", args: [:])
        XCTAssertEqual(undo["ok"] as? Bool, true)
        let buildingAfterUndo = try session.building()
        XCTAssertNil(buildingAfterUndo)
        try session.validateCabinetBinding(binding)
    }
#endif


#if DEBUG
    @MainActor
    func testInterleavedExternalWriteDuringSaveIsPreservedAndReportsRollbackFailed() async throws {
        let (session, root) = try await FloeBuildingCADTestSupport.makeSession("cabinet-interleave")
        defer { session.close(); try? FileManager.default.removeItem(at: root) }
        let recipe = FloeBuildingCADTestSupport.cabinetRecipe()
        let binding = try await session.createCabinet(recipe)
        _ = try await session.createBuilding(FloeBuildingCADTestSupport.sharedWallSpec())
        let building = try XCTUnwrap(try session.building())
        let wall = try XCTUnwrap(building.elements.first { $0.kind == .wall })
        let before = session.document.summary()
        session.document.saveSuspensionForTesting = {
            let reply = session.document.execute([
                "op": "feature.transform",
                "args": ["bodyID": wall.bodyID.uuidString, "translation": [0, 0, 10]],
            ])
            XCTAssertTrue(reply.isOK, reply.message ?? "")
        }
        defer { session.document.saveSuspensionForTesting = nil }
        var widened = recipe
        widened.widthMM = 2600
        do {
            _ = try await session.updateCabinet(recipe: widened, binding: binding)
            XCTFail("An external write during the save must not be rolled back silently.")
        } catch let error as FloeBuildingCADError {
            guard case .rollbackFailed(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("interleaved") || message.contains("preserved"), message)
        }
        let after = session.document.summary()
        XCTAssertEqual(try XCTUnwrap(try session.building()), building,
                       "The pre-existing user building must not be removed by the bridge rollback.")
        XCTAssertGreaterThan(after.featureCount, before.featureCount,
                             "The user's external transform feature must remain live.")
        let features = session.document.nativeQueryJSON(["scope": "features", "limit": 500])
        let rows = (FloeBuildingCADGeometry.object(features)?["rows"] as? [[String: Any]]) ?? []
        XCTAssertTrue(rows.contains { ($0["kind"] as? String) == "transform" })
    }
#endif

#if DEBUG
    @MainActor
    func testFailedCabinetCreateAndSheetCreateRollbackAllOwnWrites() async throws {
        let (session, root) = try await FloeBuildingCADTestSupport.makeSession("create-rollback")
        defer { session.close(); try? FileManager.default.removeItem(at: root) }
        let before = session.document.summary()
        defer { FloeBuildingCADSession.testMutationFailure = nil }
        FloeBuildingCADSession.testMutationFailure = { name in
            if name == "cabinet.create.afterFirstPanel" {
                throw FloeBuildingCADError.invalidInput("injected create failure")
            }
        }
        do {
            _ = try await session.createCabinet(FloeBuildingCADTestSupport.cabinetRecipe())
            XCTFail("The injected create failure must abort.")
        } catch let error as FloeBuildingCADError {
            guard case .invalidInput = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(session.document.summary().bodyCount, before.bodyCount)
        XCTAssertEqual(session.document.summary().featureCount, before.featureCount)
        XCTAssertEqual(FloeBuildingCADTestSupport.assemblyInstanceIDs(session.document), [])
        FloeBuildingCADSession.testMutationFailure = nil
        let binding = try await session.createCabinet(FloeBuildingCADTestSupport.cabinetRecipe())

        FloeBuildingCADSession.testMutationFailure = { name in
            if name == "sheet.project.afterPage" {
                throw FloeBuildingCADError.invalidInput("injected sheet failure")
            }
        }
        do {
            _ = try await session.makeCombinationSheet(cabinet: binding)
            XCTFail("The injected sheet failure must abort.")
        } catch let error as FloeBuildingCADError {
            guard case .invalidInput = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(session.document.summary().drawingPageCount, 0)
        FloeBuildingCADSession.testMutationFailure = nil
        let sheet = try await session.makeCombinationSheet(cabinet: binding)
        XCTAssertEqual(session.document.summary().drawingPageCount, 1)
        XCTAssertEqual(sheet.documentScope, "project")
    }
#endif
}
#endif
