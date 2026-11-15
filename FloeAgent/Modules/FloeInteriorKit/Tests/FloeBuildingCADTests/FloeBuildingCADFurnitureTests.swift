// SPDX-License-Identifier: MPL-2.0
// SOURCE_ONLY_UNTIL_COORDINATOR_NATIVE_WINDOW
#if os(iOS)
import XCTest
import Foundation
import FloeCAD
import FloeInteriorCore
import FloeBuildingResources
@testable import FloeBuildingCAD

final class FloeBuildingCADFurnitureTests: XCTestCase {
    @MainActor
    func testSubdirectoryResourcesAndTwoSameBasenameTexturesStayDistinct() async throws {
        let (session, root) = try await FloeBuildingCADTestSupport.makeSession("furniture-textures")
        defer { session.close(); try? FileManager.default.removeItem(at: root) }
        let fixture = try FloeBuildingCADTestSupport.texturedFurnitureFixture(root: root)
        let binding = try await session.importFurniture(
            assetURL: fixture.primary, resources: fixture.resources, input: fixture.input)
        XCTAssertEqual(binding.dependencySHA256, fixture.input.dependencySHA256)
        XCTAssertFalse(binding.bodyIDs.isEmpty)
        XCTAssertEqual(binding.assemblyInstanceIDs.count, binding.bodyIDs.count)
        XCTAssertTrue(binding.nativeImportVerified)
        XCTAssertFalse(binding.physicalVerified)
        XCTAssertFalse(binding.manufacturingVerified)
        XCTAssertLessThanOrEqual(binding.sizingErrorMM, binding.maximumSizingErrorMM)
        XCTAssertFalse(binding.uniformApproximationUsed)
        XCTAssertEqual(binding.actualDimensionsMM.widthMM, 200, accuracy: 0.05)
        XCTAssertEqual(binding.actualDimensionsMM.depthMM, 200, accuracy: 0.05)
        XCTAssertEqual(binding.actualDimensionsMM.heightMM, 400, accuracy: 0.05)
        XCTAssertEqual(binding.nativeEnvelopeMinimum.count, 3)
        XCTAssertEqual(binding.nativeEnvelopeMaximum.count, 3)
        let materials = session.document.nativeQueryJSON(["scope": "materials", "limit": 50])
        let rows = (FloeBuildingCADGeometry.object(materials)?["rows"] as? [[String: Any]]) ?? []
        XCTAssertGreaterThanOrEqual(rows.count, 2,
            "Both same-basename textures in different directories must remain distinct materials.")

        let manifest = try FloeBuildingCADTestSupport.manifestRoundtrip(session.manifest)
        let bodyIDs = binding.bodyIDs
        let instanceIDs = binding.assemblyInstanceIDs
        session.close()
        let reopened = try await FloeBuildingCADSession.open(
            at: root.appendingPathComponent("Project.floecad"))
        defer { reopened.close() }
        try reopened.installManifest(manifest)
        let persisted = try XCTUnwrap(reopened.manifest.furniture(instanceID: fixture.input.instanceID))
        XCTAssertEqual(persisted.bodyIDs, bodyIDs)
        XCTAssertEqual(persisted.assemblyInstanceIDs, instanceIDs)
        try reopened.validateFurnitureBinding(persisted)
        XCTAssertEqual(FloeBuildingCADTestSupport.assemblyInstanceIDs(reopened.document).count,
                       instanceIDs.count)
    }

    @MainActor
    func testBasenameFallbackAndResourceEscapeAreRejectedWithoutWrites() async throws {
        let (session, root) = try await FloeBuildingCADTestSupport.makeSession("furniture-refusal")
        defer { session.close(); try? FileManager.default.removeItem(at: root) }
        let fixture = try FloeBuildingCADTestSupport.texturedFurnitureFixture(root: root)
        let before = session.document.summary()
        let basenameOnly = FloeBuildingCADFurnitureResources(
            rootURL: root,
            dependencyFiles: ["wood.png": fixture.resources.dependencyFiles["Textures/a/wood.png"]!])
        do {
            _ = try await session.importFurniture(
                assetURL: fixture.primary, resources: basenameOnly, input: fixture.input)
            XCTFail("A basename-only mapping must not satisfy full source-relative dependency keys.")
        } catch let error as FloeBuildingCADError {
            guard case .missingAssetDependency = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(session.document.summary().bodyCount, before.bodyCount)
        XCTAssertEqual(FloeBuildingCADTestSupport.assemblyInstanceIDs(session.document), [])

        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let escaping = FloeBuildingCADFurnitureResources(
            rootURL: root,
            dependencyFiles: ["Textures/c/wood.png": outside])
        do {
            _ = try await session.importFurniture(
                assetURL: fixture.primary, resources: escaping, input: fixture.input)
            XCTFail("A dependency URL outside the resource root must be rejected.")
        } catch let error as FloeBuildingCADError {
            guard case .invalidInput = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(session.document.summary().bodyCount, before.bodyCount)
    }

#if DEBUG
    @MainActor
    func testFurnitureImportFailureRollsBackBodiesAndInstances() async throws {
        let (session, root) = try await FloeBuildingCADTestSupport.makeSession("furniture-rollback")
        defer { session.close(); try? FileManager.default.removeItem(at: root) }
        let primary = root.appendingPathComponent("cube.obj")
        try FloeBuildingCADTestSupport.syntheticCubeOBJ().write(to: primary, atomically: true, encoding: .utf8)
        var input = FloeBuildingCADTestSupport.syntheticCubeInput()
        input.sourceSHA256 = FloeBuildingCADGeometry.sha256(try Data(contentsOf: primary))
        let before = session.document.summary()
        defer { FloeBuildingCADSession.testMutationFailure = nil }
        FloeBuildingCADSession.testMutationFailure = { name in
            if name == "furniture.afterApply" {
                throw FloeBuildingCADError.invalidInput("injected furniture failure")
            }
        }
        do {
            _ = try await session.importFurniture(assetURL: primary, input: input)
            XCTFail("The injected furniture failure must abort.")
        } catch let error as FloeBuildingCADError {
            guard case .invalidInput = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(session.document.summary().bodyCount, before.bodyCount)
        XCTAssertEqual(session.document.summary().featureCount, before.featureCount)
        XCTAssertEqual(FloeBuildingCADTestSupport.assemblyInstanceIDs(session.document), [])
        FloeBuildingCADSession.testMutationFailure = nil
        let binding = try await session.importFurniture(assetURL: primary, input: input)
        XCTAssertFalse(binding.bodyIDs.isEmpty)
        try session.validateFurnitureBinding(binding)
    }
#endif

    @MainActor
    func testRealPinnedCC0ArmchairUsesReportedUniformApproximation() async throws {
        let assetDir=try BuildingResourceCatalog.starterArmchairDirectory()
        let primary = assetDir.appendingPathComponent("armchair.obj")
        let mtl = assetDir.appendingPathComponent("armchair.mtl")
        XCTAssertTrue(FileManager.default.fileExists(atPath:primary.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:mtl.path))
        let (session, root) = try await FloeBuildingCADTestSupport.makeSession("furniture-armchair")
        defer { session.close(); try? FileManager.default.removeItem(at: root) }
        let input = FurniturePlacementInput(
            instanceID: UUID(), roomID: nil,
            assetID: "Blend Swap CC-0#armchair", assetVersion: "1.9.3",
            sourceSHA256: "4da2ca4ee1b573dfd5feaee4b689794a362f8da6df2f89adb79886c4ab8cd0ce",
            dependencySHA256: [
                "armchair.mtl": "84bc77ecd7fff853255c51c5022707814e8a588dc53cb22be5db63b74e445223",
            ],
            sourceBounds: .init(minimum: .init(-32.007305, 0.141129, -42.7187),
                                maximum: .init(33.058857, 115.15596, 25.961786)),
            orientation: .cadYUp,
            sizing: .catalogDimensions(.init(widthMM: 594, depthMM: 627, heightMM: 1050),
                                       allowNonUniformScaling: true),
            pose: .init(planXMM: 1200, planYMM: 900, floorElevationMM: 0,
                        elevationAboveFloorMM: 0, yawDegrees: 17,
                        anchor: .bottomCenter))
        let resources = FloeBuildingCADFurnitureResources(
            rootURL: assetDir, dependencyFiles: ["armchair.mtl": mtl])
        let binding = try await session.importFurniture(
            assetURL: primary, resources: resources, input: input, maximumSizingErrorMM: 0.1)
        XCTAssertNil(binding.placementPlan.sourceMillimetresPerUnit)
        XCTAssertEqual(binding.placementPlan.sizeBasis, "catalog-declared-size")
        XCTAssertTrue(binding.uniformApproximationUsed,
                      "The native uniform fit must be reported as an approximation, not a strict three-axis fit.")
        XCTAssertLessThanOrEqual(binding.sizingErrorMM, 0.1)
        XCTAssertEqual(binding.actualDimensionsMM.widthMM, 594, accuracy: 0.1)
        XCTAssertEqual(binding.actualDimensionsMM.depthMM, 627, accuracy: 0.1)
        XCTAssertEqual(binding.actualDimensionsMM.heightMM, 1050, accuracy: 0.1)
        XCTAssertFalse(binding.manufacturingVerified)
        XCTAssertFalse(binding.physicalVerified)
        try session.validateFurnitureBinding(binding)

        let manifest = try FloeBuildingCADTestSupport.manifestRoundtrip(session.manifest)
        session.close()
        let reopened = try await FloeBuildingCADSession.open(
            at: root.appendingPathComponent("Project.floecad"))
        defer { reopened.close() }
        try reopened.installManifest(manifest)
        let persisted = try XCTUnwrap(reopened.manifest.furniture(instanceID: input.instanceID))
        try reopened.validateFurnitureBinding(persisted)
    }
}
#endif
