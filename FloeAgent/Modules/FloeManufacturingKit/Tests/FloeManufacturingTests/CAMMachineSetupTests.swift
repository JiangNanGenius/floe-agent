// SPDX-License-Identifier: MPL-2.0
import XCTest
@testable import FloeManufacturingCore

final class CAMMachineSetupTests: XCTestCase {
    func testEmptyCADSetupIsADraftUntilToolsAndOperationsAreAssigned() throws {
        var study = ManufacturingStudy.featureCAM()
        study.cam = .init(tools:[],operations:[])
        try study.validate(requireOperations:false)
        XCTAssertThrowsError(try study.validate(),"A mesh-only draft is not an executable operation.")
        var operation = ManufacturingCAM.Operation(id:"new-face",name:"Face",strategy:"face",toolID:"selected-mill")
        operation.frame.originMM = [0,0,8]
        study.cam?.operations = [operation]
        XCTAssertThrowsError(try study.validate(requireOperations:false),"An actual operation still needs an assigned tool.")
        study.cam?.tools = [.researchExample(id:"selected-mill")]
        let result = try NativeManufacturingEngine().compute(study,control:.init())
        XCTAssertGreaterThan(result.result.removedMM3,0)
    }
    func testSelectedMillingSetupExecutesAndSurvivesNativeArchive() throws {
        let initial = ManufacturingStudy.featureCAM()
        let frame = ManufacturingCAM.Frame(originMM: [0,0,8])
        let study = try initial.applyingMachineSetup(.init(kind: .milling3Axis, coordinateFrame: frame))
        XCTAssertFalse(study.turning.enabled)
        XCTAssertTrue(try XCTUnwrap(study.cam).operations.allSatisfy { $0.frame == frame && $0.acSeed == nil })
        let artifact = try NativeManufacturingEngine().compute(study, control: .init())
        XCTAssertGreaterThan(artifact.result.removedMM3, 0)
        XCTAssertEqual(artifact.result.camReport?.count, 3)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("machine-setup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("setup.floemanufacturing")
        try ManufacturingArchive.save(study: study, artifact: artifact, to: url)
        let restored = try ManufacturingArchive.open(url)
        XCTAssertEqual(restored.0.machineSetup, study.machineSetup)
        XCTAssertEqual(restored.0.cam, study.cam)
        XCTAssertEqual(restored.1, artifact)
    }

    func testLatheSelectionProjectsStoredInsertIntoActualNativeReceipt() throws {
        var initial = ManufacturingStudy.turnMillCAM()
        var insert = TurningSetup()
        insert.insertShape = "V"; insert.insertRotationDegrees = 35
        // This is how older documents parked typed settings in metadata.
        initial = try initial.applyingTurningSetup(insert, enabled: false)
        XCTAssertNil(initial.turningSetup)
        let study = try initial.applyingMachineSetup(.init(kind: .lathe))
        XCTAssertEqual(study.turningSetup, insert)
        XCTAssertTrue(try XCTUnwrap(study.cam).operations.allSatisfy { !$0.enabled })
        XCTAssertEqual(study.cam?.tools, initial.cam?.tools)
        XCTAssertEqual(study.source, initial.source)
        let artifact = try NativeManufacturingEngine().compute(study, control: .init())
        let receipt = try XCTUnwrap(artifact.result.turningSetupReceipt)
        XCTAssertEqual(receipt.applied, insert)
        XCTAssertGreaterThan(receipt.toolProfile.count, 3)
        XCTAssertGreaterThan(artifact.result.removedMM3, 0)
    }
}
