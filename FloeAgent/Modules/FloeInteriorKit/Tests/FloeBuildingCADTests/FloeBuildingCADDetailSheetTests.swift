// SPDX-License-Identifier: MPL-2.0
// SOURCE_ONLY_UNTIL_COORDINATOR_NATIVE_WINDOW
#if os(iOS)
import XCTest
import Foundation
import FloeCAD
import FloeInteriorCore
@testable import FloeBuildingCAD

final class FloeBuildingCADDetailSheetTests: XCTestCase {
    private func manualValues(_ payload: [String: Any],
                              bindings: [FloeBuildingCADDimensionBinding])
        -> [String: Double] {
        let rows = payload["manualDimensions"] as? [[String: Any]] ?? []
        var result: [String: Double] = [:]
        for binding in bindings {
            guard let row = rows.first(where: {
                ($0["id"] as? String) == binding.dimensionID.uuidString
            }), let value = (row["value"] as? NSNumber)?.doubleValue else { continue }
            result[binding.role] = value
        }
        return result
    }

    @MainActor
    func testDetailSetHasRealInternalAssemblyAndExplodedPages() async throws {
        let (session, root) = try await FloeBuildingCADTestSupport.makeSession("detail-pages")
        defer { session.close(); try? FileManager.default.removeItem(at: root) }
        let recipe = FloeBuildingCADTestSupport.cabinetRecipe()
        let cabinet = try await session.createCabinet(recipe)
        let sheet = try await session.makeCombinationSheet(cabinet: cabinet)

        let details = try XCTUnwrap(sheet.detailSheets)
        XCTAssertEqual(details.count, 3)
        XCTAssertEqual(Set(details.map(\.role)),
                       Set(FloeBuildingCADDetailSheet.Role.allCases.map(\.rawValue)))
        let internalDetail = try XCTUnwrap(sheet.detailSheet(role: .internalElevation))
        let assemblyDetail = try XCTUnwrap(sheet.detailSheet(role: .assembly))
        let explodedDetail = try XCTUnwrap(sheet.detailSheet(role: .exploded))
        for detail in details {
            XCTAssertEqual(detail.cabinetID, cabinet.cabinetID)
            XCTAssertEqual(detail.documentScope, "verified-snapshot")
            XCTAssertNotNil(detail.snapshotRelativePath)
            XCTAssertNotNil(detail.snapshotIdentity)
            XCTAssertEqual(detail.sourceCabinetUpdatedAtIdentity?.modelSHA256,
                           cabinet.updatedAtIdentity.modelSHA256)
        }
        XCTAssertNotEqual(internalDetail.snapshotRelativePath,
                          assemblyDetail.snapshotRelativePath)
        XCTAssertEqual(assemblyDetail.snapshotRelativePath,
                       explodedDetail.snapshotRelativePath)

        let frontPanels = cabinet.panelBindings.filter { $0.role == "front" }
        let frontInstances = Set(frontPanels.map(\.instanceID))
        let panelInstances = Set(cabinet.panelBindings.map(\.instanceID))
        let nonFrontInstances = panelInstances.subtracting(frontInstances)
        XCTAssertEqual(frontPanels.count, 3)
        XCTAssertEqual(Set(internalDetail.excludedPanelIDs), Set(frontPanels.map(\.panelID)))
        XCTAssertEqual(Set(internalDetail.excludedPanelInstanceIDs), frontInstances)

        // Internal elevation: real 16-panel projection, explicit door exclusion.
        let internalDocument = try await session.openDetailPageDocument(internalDetail)
        defer { internalDocument.close() }
        let internalPayload = FloeBuildingCADTestSupport.pageGeometry(
            internalDocument, pageID: internalDetail.pageID)
        XCTAssertEqual(internalPayload["projectionComplete"] as? Bool, true)
        XCTAssertEqual(internalPayload["outputBlocked"] as? Bool, false)
        let internalViews = try XCTUnwrap(internalPayload["views"] as? [[String: Any]])
        XCTAssertEqual(internalViews.count, 3)
        for view in internalViews {
            XCTAssertEqual(view["instanceCount"] as? Int, nonFrontInstances.count)
            XCTAssertEqual(view["projectionComplete"] as? Bool, true)
            XCTAssertEqual(view["outputBlocked"] as? Bool, false)
            XCTAssertTrue((view["missingInstanceIDs"] as? [String] ?? ["missing"]).isEmpty)
        }
        XCTAssertEqual(FloeBuildingCADTestSupport.fingerprintInstanceIDs(internalPayload),
                       nonFrontInstances)
        XCTAssertTrue(FloeBuildingCADTestSupport.fingerprintInstanceIDs(internalPayload)
            .isDisjoint(with: frontInstances))
        let internalAuto = FloeBuildingCADTestSupport.autoValues(internalPayload)
        XCTAssertTrue(FloeBuildingCADTestSupport.hasValue(internalAuto, recipe.widthMM))
        XCTAssertTrue(FloeBuildingCADTestSupport.hasValue(internalAuto, recipe.heightMM))
        let internalManual = manualValues(
            internalPayload, bindings: internalDetail.dimensionBindings)
        let t = recipe.carcassMaterial.thicknessMM
        let bayCount = Double(recipe.bays.count)
        let bayWidth = (recipe.widthMM - 2 * t - (bayCount - 1) * t) / bayCount
        XCTAssertEqual(try XCTUnwrap(internalManual["internal-carcass-thickness"]),
                       t, accuracy: 0.02)
        XCTAssertEqual(internalManual.keys.filter { $0.hasPrefix("internal-bay-width-") }.count,
                       recipe.bays.count)
        for value in internalManual where value.key.hasPrefix("internal-bay-width-") {
            XCTAssertEqual(value.value, bayWidth, accuracy: 0.02)
        }
        for value in internalManual where value.key.hasPrefix("internal-bay-height-") {
            XCTAssertEqual(value.value, recipe.heightMM - 2 * t, accuracy: 0.02)
        }

        // Assembly page: all 19 installed panels.
        let assemblyDocument = try await session.openDetailPageDocument(assemblyDetail)
        defer { assemblyDocument.close() }
        let assemblyPayload = FloeBuildingCADTestSupport.pageGeometry(
            assemblyDocument, pageID: assemblyDetail.pageID)
        let assemblyViews = try XCTUnwrap(assemblyPayload["views"] as? [[String: Any]])
        XCTAssertEqual(assemblyViews.count, 4)
        for view in assemblyViews {
            XCTAssertEqual(view["instanceCount"] as? Int, 19)
            XCTAssertEqual(view["projectionComplete"] as? Bool, true)
        }
        XCTAssertEqual(FloeBuildingCADTestSupport.fingerprintInstanceIDs(assemblyPayload),
                       panelInstances)

        // Exploded page: a real named exploded view, all 19 instances.
        let explodedDocument = try await session.openDetailPageDocument(explodedDetail)
        defer { explodedDocument.close() }
        let explodedPayload = FloeBuildingCADTestSupport.pageGeometry(
            explodedDocument, pageID: explodedDetail.pageID)
        let explodedViews = try XCTUnwrap(explodedPayload["views"] as? [[String: Any]])
        XCTAssertEqual(explodedViews.count, 4)
        for view in explodedViews {
            XCTAssertEqual(view["instanceCount"] as? Int, 19)
            XCTAssertEqual(view["projectionComplete"] as? Bool, true)
        }
        let explodedRow = try XCTUnwrap(explodedPayload["explodedView"] as? [String: Any])
        XCTAssertEqual(explodedRow["found"] as? Bool, true)
        let explodedID = try XCTUnwrap(explodedDetail.explodedViewID)
        XCTAssertEqual(explodedRow["id"] as? String, explodedID.uuidString)
        let explodedPage = try XCTUnwrap(explodedPayload["page"] as? [String: Any])
        XCTAssertEqual(explodedPage["explodedViewID"] as? String, explodedID.uuidString)
        XCTAssertEqual(FloeBuildingCADTestSupport.fingerprintInstanceIDs(explodedPayload),
                       panelInstances)
    }

    @MainActor
    func testWidthChangeRefreshesEveryDetailPageAndKeepsManualContent() async throws {
        let (session, root) = try await FloeBuildingCADTestSupport.makeSession("detail-refresh")
        defer { session.close(); try? FileManager.default.removeItem(at: root) }
        let recipe = FloeBuildingCADTestSupport.cabinetRecipe()
        let cabinet = try await session.createCabinet(recipe)
        let sheet = try await session.makeCombinationSheet(cabinet: cabinet)
        let oldInternal = try XCTUnwrap(sheet.detailSheet(role: .internalElevation))
        let oldInternalURL = try session.snapshotURL(
            for: try XCTUnwrap(oldInternal.snapshotRelativePath))

        // The user moves a formal bay dimension and adds a note on the
        // internal page, then saves the snapshot.
        let internalDocument = try await session.openDetailPageDocument(oldInternal)
        let drawing = CADDrawingService(document: internalDocument)
        let firstBayDimension = try XCTUnwrap(oldInternal.dimensionBindings.first {
            $0.role.hasPrefix("internal-bay-width-")
        })
        let moved = drawing.handle(action: "updateDimension", args: [
            "pageID": oldInternal.pageID.uuidString,
            "dimensionID": firstBayDimension.dimensionID.uuidString,
            "textPosition": [77.0, 88.0],
            "text": "kept-bay",
        ])
        XCTAssertEqual(moved["ok"] as? Bool, true)
        let frontViewID = try XCTUnwrap(oldInternal.viewIDs["front"])
        let note = drawing.handle(action: "addAnnotation", args: [
            "pageID": oldInternal.pageID.uuidString,
            "viewID": frontViewID.uuidString,
            "text": "Keep detail note",
            "position": [20.0, 30.0],
            "heightMM": 3.5,
        ])
        XCTAssertEqual(note["ok"] as? Bool, true)
        let saved = await internalDocument.save()
        XCTAssertTrue(saved.succeeded)
        internalDocument.close()

        var widened = recipe
        widened.widthMM = 2600
        let update = try await session.updateCabinet(recipe: widened, binding: cabinet)
        let refreshed = try await session.refreshCombinationSheet(
            cabinet: update.cabinet, sheet: try XCTUnwrap(update.sheet))
        let newInternal = try XCTUnwrap(refreshed.detailSheet(role: .internalElevation))
        XCTAssertNotEqual(newInternal.snapshotRelativePath, oldInternal.snapshotRelativePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldInternalURL.path),
                      "The previous detail snapshot must be retained as recovery evidence.")

        let newDocument = try await session.openDetailPageDocument(newInternal)
        defer { newDocument.close() }
        let payload = FloeBuildingCADTestSupport.pageGeometry(
            newDocument, pageID: newInternal.pageID)
        let auto = FloeBuildingCADTestSupport.autoValues(payload)
        XCTAssertTrue(FloeBuildingCADTestSupport.hasValue(auto, 2600))
        XCTAssertFalse(FloeBuildingCADTestSupport.hasValue(auto, 2400))
        let manual = manualValues(payload, bindings: newInternal.dimensionBindings)
        let t = recipe.carcassMaterial.thicknessMM
        let newBayWidth = (2600 - 2 * t - Double(recipe.bays.count - 1) * t)
            / Double(recipe.bays.count)
        for value in manual where value.key.hasPrefix("internal-bay-width-") {
            XCTAssertEqual(value.value, newBayWidth, accuracy: 0.02)
        }
        let kept = try XCTUnwrap(newInternal.dimensionBindings.first {
            $0.role == firstBayDimension.role
        })
        XCTAssertEqual(kept.textPosition, [77, 88])
        XCTAssertEqual(kept.textOverride, "kept-bay")

        let annotations = payload["annotations"] as? [[String: Any]] ?? []
        let preserved = annotations.first {
            ($0["text"] as? String) == "Keep detail note"
        }
        let preservedRow = try XCTUnwrap(preserved)
        let position = try XCTUnwrap(FloeBuildingCADGeometry.doubleArray(
            preservedRow["localPosition"] ?? preservedRow["position"]))
        XCTAssertEqual(position.count, 2)
        XCTAssertEqual(position[0], 20, accuracy: 0.01)
        XCTAssertEqual(position[1], 30, accuracy: 0.01)

        // The assembly and exploded pages were rebuilt from the new geometry.
        let assembly = try XCTUnwrap(refreshed.detailSheet(role: .assembly))
        let assemblyDocument = try await session.openDetailPageDocument(assembly)
        defer { assemblyDocument.close() }
        let assemblyPayload = FloeBuildingCADTestSupport.pageGeometry(
            assemblyDocument, pageID: assembly.pageID)
        XCTAssertTrue(FloeBuildingCADTestSupport.hasValue(
            FloeBuildingCADTestSupport.autoValues(assemblyPayload), 2600))
        XCTAssertEqual(FloeBuildingCADTestSupport.fingerprintInstanceIDs(assemblyPayload),
                       Set(update.cabinet.panelBindings.map(\.instanceID)))
        let exploded = try XCTUnwrap(refreshed.detailSheet(role: .exploded))
        let explodedDocument = try await session.openDetailPageDocument(exploded)
        defer { explodedDocument.close() }
        let explodedPayload = FloeBuildingCADTestSupport.pageGeometry(
            explodedDocument, pageID: exploded.pageID)
        XCTAssertEqual((explodedPayload["explodedView"] as? [String: Any])?["found"] as? Bool,
                       true)

        // The additive detail fields survive a manifest encode/decode cycle.
        let manifest = try FloeBuildingCADTestSupport.manifestRoundtrip(session.manifest)
        session.close()
        let reopened = try await FloeBuildingCADSession.open(
            at: root.appendingPathComponent("Project.floecad"))
        defer { reopened.close() }
        try reopened.installManifest(manifest)
        let persistedSheet = try XCTUnwrap(
            reopened.manifest.sheet(cabinetID: update.cabinet.cabinetID))
        XCTAssertEqual(persistedSheet.detailSheets?.count, 3)
        let persistedInternal = try XCTUnwrap(
            persistedSheet.detailSheet(role: .internalElevation))
        let persistedDocument = try await reopened.openDetailPageDocument(persistedInternal)
        defer { persistedDocument.close() }
        let persistedPayload = FloeBuildingCADTestSupport.pageGeometry(
            persistedDocument, pageID: persistedInternal.pageID)
        XCTAssertTrue(FloeBuildingCADTestSupport.hasValue(
            FloeBuildingCADTestSupport.autoValues(persistedPayload), 2600))
    }
}
#endif
