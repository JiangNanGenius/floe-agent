// SPDX-License-Identifier: MPL-2.0
// SOURCE_ONLY_UNTIL_COORDINATOR_NATIVE_WINDOW
#if os(iOS)
import XCTest
import Foundation
import FloeCAD
import FloeInteriorCore
@testable import FloeBuildingCAD

final class FloeBuildingCADExportTests: XCTestCase {
    @MainActor
    func testIndependentPDFSVGDXFAndNativeCopyDoNotWriteBack() async throws {
        let (session, root) = try await FloeBuildingCADTestSupport.makeSession("export-independent")
        defer { session.close(); try? FileManager.default.removeItem(at: root) }
        let binding = try await session.createCabinet(FloeBuildingCADTestSupport.cabinetRecipe())
        let sheet = try await session.makeCombinationSheet(cabinet: binding)
        let sourceIdentity = try session.currentIdentity()
        let output = root.appendingPathComponent("Delivery", isDirectory: true)
        let receipt = try await session.exportCabinetDeliverables(
            cabinet: binding, sheet: sheet, to: output)
        XCTAssertEqual(receipt.files.count, 4)
        XCTAssertEqual(Set(receipt.files.map(\.format)),
                       Set(["pdf", "svg", "dxf", "floecad-package"]))
        XCTAssertEqual(try XCTUnwrap(receipt.pageDocumentIdentity), sourceIdentity)
        XCTAssertEqual(receipt.sourceIdentity, sourceIdentity)
        for file in receipt.files {
            let url = output.appendingPathComponent(file.relativePath)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), file.relativePath)
            if file.format != "floecad-package" {
                let data = try Data(contentsOf: url)
                XCTAssertEqual(data.count, file.byteCount)
                XCTAssertEqual(FloeBuildingCADGeometry.sha256(data), file.sha256)
            }
        }
        let pdf = try Data(contentsOf: output.appendingPathComponent("CabinetCombination.pdf"))
        XCTAssertTrue(pdf.starts(with: Data("%PDF".utf8)))
        let svg = try String(contentsOf: output.appendingPathComponent("CabinetCombination.svg"))
        XCTAssertTrue(svg.contains("<svg"))
        let dxf = try String(contentsOf: output.appendingPathComponent("CabinetCombination.dxf"))
        XCTAssertTrue(dxf.contains("SECTION"))

        let copyURL = output.appendingPathComponent("Cabinet.native.floecad", isDirectory: true)
        let copy = try await FloeCADDocument.open(at: copyURL)
        defer { copy.close() }
        XCTAssertEqual(copy.summary().bodyCount, session.document.summary().bodyCount)
        let panel = try XCTUnwrap(binding.panelBindings.first)
        let moved = copy.execute([
            "op": "feature.transform",
            "args": ["bodyID": panel.bodyID.uuidString, "translation": [5, 0, 0]],
        ])
        XCTAssertTrue(moved.isOK, moved.message ?? "")
        let saved = await copy.save()
        XCTAssertTrue(saved.succeeded)
        XCTAssertEqual(try session.currentIdentity().modelSHA256, sourceIdentity.modelSHA256,
                       "Editing the independent native copy must not change the project source.")
        do {
            _ = try await session.exportCabinetDeliverables(
                cabinet: binding, sheet: sheet, to: output)
            XCTFail("An existing deliverable directory must not be overwritten.")
        } catch let error as FloeBuildingCADError {
            guard case .existingOutput = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }


    @MainActor
    func testManualNoteAndOrdinaryAnnotationSurviveSnapshotInPlaceRefresh() async throws {
        let (session, root) = try await FloeBuildingCADTestSupport.makeSession("annotation-refresh")
        defer { session.close(); try? FileManager.default.removeItem(at: root) }
        let cabinet = try await session.createCabinet(FloeBuildingCADTestSupport.cabinetRecipe())
        let cube = root.appendingPathComponent("cube.obj")
        try FloeBuildingCADTestSupport.syntheticCubeOBJ().write(to: cube, atomically: true, encoding: .utf8)
        var input = FloeBuildingCADTestSupport.syntheticCubeInput()
        input.sourceSHA256 = FloeBuildingCADGeometry.sha256(try Data(contentsOf: cube))
        _ = try await session.importFurniture(assetURL: cube, input: input)

        let manualNote = CabinetManualSheetNote(
            text: "Keep manual note",
            positionMM: CabinetPaperPoint(100, 150))
        let options = FloeBuildingCADSheetOptions(manualNotes: [manualNote])
        let sheet = try await session.makeCombinationSheet(cabinet: cabinet, options: options)
        XCTAssertEqual(sheet.documentScope, "verified-snapshot")

        let snapshot = try await session.openSheetSnapshot(sheet)
        let service = CADDrawingService(document: snapshot)
        let frontID = try XCTUnwrap(sheet.viewIDs["front"])
        let added = service.handle(action: "addAnnotation", args: [
            "pageID": sheet.pageID.uuidString,
            "viewID": frontID.uuidString,
            "text": "User annotation",
            "position": [30.0, 40.0],
            "heightMM": 4.0,
        ])
        XCTAssertEqual(added["ok"] as? Bool, true)
        let row = try XCTUnwrap(added["annotation"] as? [String: Any])
        let annotationID = try XCTUnwrap(UUID(uuidString: row["id"] as? String ?? ""))
        let saved = await snapshot.save()
        XCTAssertTrue(saved.succeeded)
        snapshot.close()

        var widened = FloeBuildingCADTestSupport.cabinetRecipe()
        widened.widthMM = 2600
        let update = try await session.updateCabinet(recipe: widened, binding: cabinet)
        XCTAssertTrue(update.sheetRefreshRequired)
        let refreshed = try await session.refreshCombinationSheet(
            cabinet: update.cabinet, sheet: sheet)
        XCTAssertEqual(refreshed.pageID, sheet.pageID,
                       "The preferred snapshot refresh must update the same page in place.")
        XCTAssertEqual(refreshed.viewIDs, sheet.viewIDs)
        XCTAssertEqual(refreshed.snapshotRelativePath, sheet.snapshotRelativePath)
        XCTAssertEqual(refreshed.manualNotes, [manualNote])

        let finalSnapshot = try await session.openSheetSnapshot(refreshed)
        defer { finalSnapshot.close() }
        let geometry = FloeBuildingCADTestSupport.pageGeometry(
            finalSnapshot, pageID: refreshed.pageID)
        let annotations = try XCTUnwrap(geometry["annotations"] as? [[String: Any]])
        let userRow = try XCTUnwrap(annotations.first { ($0["text"] as? String) == "User annotation" })
        XCTAssertEqual(userRow["id"] as? String, annotationID.uuidString)
        let local = try XCTUnwrap(FloeBuildingCADGeometry.doubleArray(userRow["localPosition"]))
        XCTAssertEqual(local[0], 30, accuracy: 0.01)
        XCTAssertEqual(local[1], 40, accuracy: 0.01)
        XCTAssertTrue(annotations.contains { ($0["text"] as? String) == "Keep manual note" })
        XCTAssertTrue(FloeBuildingCADTestSupport.hasValue(
            FloeBuildingCADTestSupport.autoValues(geometry), 2600))
    }


    @MainActor
    func testUnsafeSnapshotRefreshMigratesAnnotationAndKeepsOldSnapshot() async throws {
        let (session, root) = try await FloeBuildingCADTestSupport.makeSession("annotation-fallback")
        defer { session.close(); try? FileManager.default.removeItem(at: root) }
        let cabinet = try await session.createCabinet(FloeBuildingCADTestSupport.cabinetRecipe())
        let cube = root.appendingPathComponent("cube.obj")
        try FloeBuildingCADTestSupport.syntheticCubeOBJ().write(to: cube, atomically: true, encoding: .utf8)
        var input = FloeBuildingCADTestSupport.syntheticCubeInput()
        input.sourceSHA256 = FloeBuildingCADGeometry.sha256(try Data(contentsOf: cube))
        _ = try await session.importFurniture(assetURL: cube, input: input)
        let sheet = try await session.makeCombinationSheet(cabinet: cabinet)

        let snapshot = try await session.openSheetSnapshot(sheet)
        let service = CADDrawingService(document: snapshot)
        let frontID = try XCTUnwrap(sheet.viewIDs["front"])
        let added = service.handle(action: "addAnnotation", args: [
            "pageID": sheet.pageID.uuidString,
            "viewID": frontID.uuidString,
            "text": "Migrated annotation",
            "position": [22.0, 33.0],
            "heightMM": 3.5,
        ])
        let row = try XCTUnwrap(added["annotation"] as? [String: Any])
        let stableID = try XCTUnwrap(FloeBuildingCADGeometry.uuid(row["id"]))
        // Make the old snapshot unsafe for an in-place update by moving a
        // panel body. The manual annotation must still migrate to a new
        // snapshot and the old file must be retained.
        let panel = try XCTUnwrap(cabinet.panelBindings.first)
        let moved = snapshot.execute([
            "op": "feature.transform",
            "args": ["bodyID": panel.bodyID.uuidString, "translation": [12, 0, 0]],
        ])
        XCTAssertTrue(moved.isOK, moved.message ?? "")
        let saved = await snapshot.save()
        XCTAssertTrue(saved.succeeded)
        snapshot.close()
        let oldPath = try XCTUnwrap(sheet.snapshotRelativePath)
        let oldURL = try session.snapshotURL(for: oldPath)

        var widened = FloeBuildingCADTestSupport.cabinetRecipe()
        widened.widthMM = 2600
        let update = try await session.updateCabinet(recipe: widened, binding: cabinet)
        let refreshed = try await session.refreshCombinationSheet(
            cabinet: update.cabinet, sheet: sheet)
        XCTAssertNotEqual(refreshed.snapshotRelativePath, sheet.snapshotRelativePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldURL.path),
                      "The unsafe original snapshot must remain recoverable.")
        let migrated = try XCTUnwrap(refreshed.annotationBindings.first { $0.stableID == stableID })
        XCTAssertFalse(migrated.orphaned)
        XCTAssertNotNil(migrated.currentID)
        let newSnapshot = try await session.openSheetSnapshot(refreshed)
        defer { newSnapshot.close() }
        let geometry = FloeBuildingCADTestSupport.pageGeometry(
            newSnapshot, pageID: refreshed.pageID)
        let annotations = try XCTUnwrap(geometry["annotations"] as? [[String: Any]])
        let row2 = try XCTUnwrap(annotations.first { $0["id"] as? String == migrated.currentID?.uuidString })
        XCTAssertEqual(row2["text"] as? String, "Migrated annotation")
        let local = try XCTUnwrap(FloeBuildingCADGeometry.doubleArray(row2["localPosition"]))
        XCTAssertEqual(local[0], 22, accuracy: 0.01)
        XCTAssertEqual(local[1], 33, accuracy: 0.01)
    }

    @MainActor
    func testMixedProjectUsesInstanceScopedSnapshotAndRefresh() async throws {
        let (session, root) = try await FloeBuildingCADTestSupport.makeSession("export-mixed")
        defer { session.close(); try? FileManager.default.removeItem(at: root) }
        _ = try await session.createBuilding(FloeBuildingCADTestSupport.sharedWallSpec())
        let cabinet = try await session.createCabinet(FloeBuildingCADTestSupport.cabinetRecipe())
        let cube = root.appendingPathComponent("cube.obj")
        try FloeBuildingCADTestSupport.syntheticCubeOBJ().write(to: cube, atomically: true, encoding: .utf8)
        var furnitureInput = FloeBuildingCADTestSupport.syntheticCubeInput()
        furnitureInput.sourceSHA256 = FloeBuildingCADGeometry.sha256(try Data(contentsOf: cube))
        let furniture = try await session.importFurniture(assetURL: cube, input: furnitureInput)
        let allInstances = FloeBuildingCADTestSupport.assemblyInstanceIDs(session.document)
        XCTAssertTrue(allInstances.isSuperset(of: Set(cabinet.panelBindings.map(\.instanceID))))
        XCTAssertTrue(allInstances.isSuperset(of: Set(furniture.assemblyInstanceIDs)))
        let projectPageCount = session.document.summary().drawingPageCount

        let sheet = try await session.makeCombinationSheet(cabinet: cabinet)
        XCTAssertEqual(sheet.documentScope, "verified-snapshot")
        XCTAssertNotNil(sheet.snapshotRelativePath)
        XCTAssertEqual(Set(sheet.excludedAssemblyInstanceIDs), Set(furniture.assemblyInstanceIDs))
        XCTAssertEqual(session.document.summary().drawingPageCount, projectPageCount,
                       "A mixed-project cabinet page must not inject an unfiltered project page.")

        let snapshot = try await session.openSheetSnapshot(sheet)
        defer { snapshot.close() }
        let payload = FloeBuildingCADTestSupport.pageGeometry(snapshot, pageID: sheet.pageID)
        let views = try XCTUnwrap(payload["views"] as? [[String: Any]])
        XCTAssertEqual(views.count, 5)
        for view in views {
            XCTAssertEqual(view["instanceCount"] as? Int, 19)
            XCTAssertEqual(view["projectionComplete"] as? Bool, true)
            XCTAssertEqual(view["outputBlocked"] as? Bool, false)
        }
        XCTAssertEqual(FloeBuildingCADTestSupport.fingerprintInstanceIDs(payload),
                       Set(cabinet.panelBindings.map(\.instanceID)))
        XCTAssertTrue(Set(furniture.assemblyInstanceIDs).isDisjoint(
            with: FloeBuildingCADTestSupport.fingerprintInstanceIDs(payload)))
        XCTAssertTrue(FloeBuildingCADTestSupport.hasValue(
            FloeBuildingCADTestSupport.autoValues(payload), 2400))

        var widened = FloeBuildingCADTestSupport.cabinetRecipe()
        widened.widthMM = 2600
        let update = try await session.updateCabinet(recipe: widened, binding: cabinet)
        XCTAssertTrue(update.sheetRefreshRequired)
        let staleSheet = try XCTUnwrap(session.manifest.sheet(cabinetID: cabinet.cabinetID))
        let output = root.appendingPathComponent("MixedDelivery", isDirectory: true)
        do {
            _ = try await session.exportCabinetDeliverables(
                cabinet: update.cabinet, sheet: staleSheet, to: output)
            XCTFail("A stale snapshot sheet must not export as current.")
        } catch let error as FloeBuildingCADError {
            guard case .staleBinding = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let refreshed = try await session.refreshCombinationSheet(
            cabinet: update.cabinet, sheet: staleSheet)
        XCTAssertEqual(refreshed.documentScope, "verified-snapshot")
        let refreshedSnapshot = try await session.openSheetSnapshot(refreshed)
        defer { refreshedSnapshot.close() }
        let refreshedPayload = FloeBuildingCADTestSupport.pageGeometry(
            refreshedSnapshot, pageID: refreshed.pageID)
        let refreshedViews = try XCTUnwrap(refreshedPayload["views"] as? [[String: Any]])
        XCTAssertEqual(refreshedViews.count, 5)
        XCTAssertEqual(FloeBuildingCADTestSupport.fingerprintInstanceIDs(refreshedPayload),
                       Set(update.cabinet.panelBindings.map(\.instanceID)))
        let values = FloeBuildingCADTestSupport.autoValues(refreshedPayload)
        XCTAssertTrue(FloeBuildingCADTestSupport.hasValue(values, 2600))
        XCTAssertFalse(FloeBuildingCADTestSupport.hasValue(values, 2400))

        let manifest = try FloeBuildingCADTestSupport.manifestRoundtrip(session.manifest)
        session.close()
        let reopened = try await FloeBuildingCADSession.open(
            at: root.appendingPathComponent("Project.floecad"))
        defer { reopened.close() }
        try reopened.installManifest(manifest)
        let persistedSheet = try XCTUnwrap(reopened.manifest.sheet(cabinetID: cabinet.cabinetID))
        let persistedSnapshot = try await reopened.openSheetSnapshot(persistedSheet)
        defer { persistedSnapshot.close() }
        let persistedPayload = FloeBuildingCADTestSupport.pageGeometry(
            persistedSnapshot, pageID: persistedSheet.pageID)
        XCTAssertTrue(FloeBuildingCADTestSupport.hasValue(
            FloeBuildingCADTestSupport.autoValues(persistedPayload), 2600))

        let receipt = try await reopened.exportCabinetDeliverables(
            cabinet: update.cabinet, sheet: persistedSheet, to: output)
        XCTAssertTrue(receipt.scope.contains("verified-snapshot"))
        let projectInstances = FloeBuildingCADTestSupport.assemblyInstanceIDs(reopened.document)
        XCTAssertTrue(projectInstances.isSuperset(of: Set(furniture.assemblyInstanceIDs)))
        let copyURL = output.appendingPathComponent("Cabinet.native.floecad", isDirectory: true)
        let copy = try await FloeCADDocument.open(at: copyURL)
        defer { copy.close() }
        XCTAssertEqual(FloeBuildingCADTestSupport.assemblyInstanceIDs(copy),
                       Set(update.cabinet.panelBindings.map(\.instanceID)),
                       "The exported snapshot copy must contain only this cabinet's assembly instances.")
    }
}
#endif
