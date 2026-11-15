// SPDX-License-Identifier: MPL-2.0
// SOURCE_ONLY_UNTIL_COORDINATOR_NATIVE_WINDOW
#if os(iOS)
import XCTest
import Foundation
import FloeCAD
import FloeInteriorCore
@testable import FloeBuildingCAD

final class FloeBuildingCADDetailExportTests: XCTestCase {
    @MainActor
    func testCabinetDetailSetPublishesEveryPageAndBothNativeProjects() async throws {
        let (session, root) = try await FloeBuildingCADTestSupport.makeSession("detail-export")
        defer { session.close(); try? FileManager.default.removeItem(at: root) }
        let recipe = FloeBuildingCADTestSupport.cabinetRecipe()
        let cabinet = try await session.createCabinet(recipe)
        let sheet = try await session.makeCombinationSheet(cabinet: cabinet)
        let output = root.appendingPathComponent("DetailDelivery", isDirectory: true)
        let sourceIdentity = try session.currentIdentity()
        let receipt = try await session.exportCabinetDetailSet(
            cabinet: cabinet, sheet: sheet, to: output)

        XCTAssertEqual(receipt.scope, "cabinet-detail-set")
        XCTAssertEqual(receipt.files.count, 14,
                       "Four pages x PDF/SVG/DXF plus two native projects.")
        XCTAssertEqual(Set(receipt.files.map(\.role)),
                       Set(["main", "internal-elevation", "assembly", "exploded",
                            "native-3d", "native-2d"]))
        XCTAssertEqual(receipt.native2D?.sourcePageID, sheet.pageID)
        XCTAssertGreaterThan(receipt.native2D?.entityCount ?? 0, 0)
        let pageRoles = Set((receipt.pages ?? []).map(\.role))
        XCTAssertEqual(pageRoles,
                       Set(["main", "internal-elevation", "assembly", "exploded"]))
        let internalPage = try XCTUnwrap(receipt.pages?.first {
            $0.role == "internal-elevation"
        })
        let frontInstances = Set(cabinet.panelBindings
            .filter { $0.role == "front" }
            .map(\.instanceID))
        XCTAssertEqual(Set(internalPage.excludedPanelInstanceIDs), frontInstances)

        for file in receipt.files where file.format != "floecad-package" {
            let url = output.appendingPathComponent(file.relativePath)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), file.relativePath)
            let data = try Data(contentsOf: url)
            XCTAssertEqual(data.count, file.byteCount)
            XCTAssertEqual(FloeBuildingCADGeometry.sha256(data), file.sha256)
        }
        for base in ["CabinetCombination", "CabinetInternalElevation",
                     "CabinetAssembly", "CabinetExploded"] {
            for format in ["pdf", "svg", "dxf"] {
                let url = output.appendingPathComponent("\(base).\(format)")
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                              "\(base).\(format) is missing")
            }
        }
        let pdf = try Data(contentsOf: output.appendingPathComponent("CabinetInternalElevation.pdf"))
        XCTAssertTrue(pdf.starts(with: Data("%PDF".utf8)))
        let dxf = try String(contentsOf: output.appendingPathComponent("CabinetExploded.dxf"))
        XCTAssertTrue(dxf.contains("SECTION"))

        let native2DURL = output.appendingPathComponent("Cabinet.native2d.floecad",
                                                       isDirectory: true)
        let native2D = try await FloeCADDocument.open(at: native2DURL)
        XCTAssertEqual(native2D.summary().sketchCount,
                       receipt.native2D?.sketchIDs.count)
        XCTAssertGreaterThan(native2D.summary().sketchCount, 0)
        native2D.close()

        let native3DURL = output.appendingPathComponent("Cabinet.native3d.floecad",
                                                       isDirectory: true)
        let native3D = try await FloeCADDocument.open(at: native3DURL)
        let panel = try XCTUnwrap(cabinet.panelBindings.first)
        let moved = native3D.execute([
            "op": "feature.transform",
            "args": ["bodyID": panel.bodyID.uuidString, "translation": [5, 0, 0]],
        ])
        XCTAssertTrue(moved.isOK, moved.message ?? "")
        let saved = await native3D.save()
        XCTAssertTrue(saved.succeeded)
        native3D.close()
        XCTAssertEqual(try session.currentIdentity().modelSHA256,
                       sourceIdentity.modelSHA256,
                       "Editing a published native copy must not write the project source.")
        XCTAssertTrue(receipt.unsupported.contains {
            $0.contains("manufacturingVerified is false")
        })
    }

    #if DEBUG
    @MainActor
    func testFailedDetailExportDoesNotPublishPartialFiles() async throws {
        let (session, root) = try await FloeBuildingCADTestSupport.makeSession("detail-export-failure")
        defer {
            FloeBuildingCADSession.testMutationFailure = nil
            session.close()
            try? FileManager.default.removeItem(at: root)
        }
        let cabinet = try await session.createCabinet(FloeBuildingCADTestSupport.cabinetRecipe())
        let sheet = try await session.makeCombinationSheet(cabinet: cabinet)
        let output = root.appendingPathComponent("FailureDelivery", isDirectory: true)
        FloeBuildingCADSession.testMutationFailure = { name in
            if name == "detailExport.afterVectorFiles" {
                throw FloeBuildingCADError.invalidInput("injected detail export failure")
            }
        }
        do {
            _ = try await session.exportCabinetDetailSet(
                cabinet: cabinet, sheet: sheet, to: output)
            XCTFail("The injected failure must abort the detail export.")
        } catch let error as FloeBuildingCADError {
            guard case .invalidInput = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path),
                       "A failed export must not publish a partial deliverable directory.")
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let staging = entries.filter { $0.hasPrefix(".FailureDelivery.staging-") }
        XCTAssertEqual(staging.count, 1)
        let stagingName = try XCTUnwrap(staging.first)
        let marker = root.appendingPathComponent(stagingName)
            .appendingPathComponent("INCOMPLETE.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path),
            "A failed export must leave recoverable staging with an INCOMPLETE marker.")

        FloeBuildingCADSession.testMutationFailure = nil
        let receipt = try await session.exportCabinetDetailSet(
            cabinet: cabinet, sheet: sheet, to: output)
        XCTAssertEqual(receipt.files.count, 14)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }
    #endif

    #if DEBUG
    @MainActor
    func testCancelledDetailExportDoesNotPublishPartialFiles() async throws {
        let (session, root) = try await FloeBuildingCADTestSupport.makeSession("detail-export-cancel")
        defer {
            FloeBuildingCADSession.testMutationFailure = nil
            session.close()
            try? FileManager.default.removeItem(at: root)
        }
        let cabinet = try await session.createCabinet(FloeBuildingCADTestSupport.cabinetRecipe())
        let sheet = try await session.makeCombinationSheet(cabinet: cabinet)
        let output = root.appendingPathComponent("CancelledDelivery", isDirectory: true)
        FloeBuildingCADSession.testMutationFailure = { name in
            if name == "detailExport.beforePublish" { throw CancellationError() }
        }
        do {
            _ = try await session.exportCabinetDetailSet(
                cabinet: cabinet, sheet: sheet, to: output)
            XCTFail("The injected cancellation must abort the detail export.")
        } catch let error as FloeBuildingCADError {
            guard case .cancelled = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let staging = entries.filter { $0.hasPrefix(".CancelledDelivery.staging-") }
        XCTAssertEqual(staging.count, 1)
        let marker = root.appendingPathComponent(try XCTUnwrap(staging.first))
            .appendingPathComponent("INCOMPLETE.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }
    #endif

    @MainActor
    func testWholeProjectNeedsAnExplicitPageForNative2DAndExportsNative3D() async throws {
        let (session, root) = try await FloeBuildingCADTestSupport.makeSession("whole-project")
        defer { session.close(); try? FileManager.default.removeItem(at: root) }
        let cabinet = try await session.createCabinet(FloeBuildingCADTestSupport.cabinetRecipe())
        let sheet = try await session.makeCombinationSheet(cabinet: cabinet)
        let sourceIdentity = try session.currentIdentity()

        let noPageOutput = root.appendingPathComponent("WholeProject", isDirectory: true)
        let noPage = try await session.exportProjectDeliverables(to: noPageOutput)
        XCTAssertEqual(noPage.scope, "whole-project")
        XCTAssertEqual(noPage.files.count, 1)
        XCTAssertEqual(noPage.files.first?.role, "whole-project-native-3d")
        let codes = Set((noPage.unsupportedOperations ?? []).map(\.code))
        XCTAssertTrue(codes.contains("whole_project_native2d_requires_page"))
        XCTAssertTrue(codes.contains("whole_project_vector_requires_page"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: noPageOutput.appendingPathComponent("CabinetCombination.pdf").path),
            "A whole-project export must not silently fall back to a cabinet page.")

        let native3DURL = noPageOutput.appendingPathComponent("Project.native3d.floecad",
                                                             isDirectory: true)
        let native3D = try await FloeCADDocument.open(at: native3DURL)
        let panel = try XCTUnwrap(cabinet.panelBindings.first)
        let moved = native3D.execute([
            "op": "feature.transform",
            "args": ["bodyID": panel.bodyID.uuidString, "translation": [5, 0, 0]],
        ])
        XCTAssertTrue(moved.isOK, moved.message ?? "")
        let saved = await native3D.save()
        XCTAssertTrue(saved.succeeded)
        native3D.close()
        XCTAssertEqual(try session.currentIdentity().modelSHA256,
                       sourceIdentity.modelSHA256)

        let pageOutput = root.appendingPathComponent("WholeProjectPage", isDirectory: true)
        var options = FloeBuildingCADDetailExportOptions()
        options.projectPageID = sheet.pageID
        let withPage = try await session.exportProjectDeliverables(
            to: pageOutput, options: options)
        XCTAssertEqual(Set(withPage.files.map(\.role)),
                       Set(["whole-project-native-3d", "whole-project-page",
                            "whole-project-native-2d"]))
        for format in ["pdf", "svg", "dxf"] {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: pageOutput.appendingPathComponent("ProjectPage.\(format)").path))
        }
        let native2DURL = pageOutput.appendingPathComponent("Project.native2d.floecad",
                                                            isDirectory: true)
        let native2D = try await FloeCADDocument.open(at: native2DURL)
        defer { native2D.close() }
        XCTAssertGreaterThan(native2D.summary().sketchCount, 0)
        XCTAssertEqual(withPage.pages?.first?.pageID, sheet.pageID)
        XCTAssertEqual(try session.currentIdentity().modelSHA256,
                       sourceIdentity.modelSHA256)
    }
}
#endif
