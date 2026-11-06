import XCTest
@testable import FloeManufacturingCore

final class VirtualMachineIntegrationTests:XCTestCase {
    func testSourceBoundVirtualMachineArchiveAndPoseQueries() throws {
        var project = VirtualMachineProject.demonstration();project.traceSamples = 3;project.collisionFractions = [0]
        let cell = try CellManufacturingEngine().compute(project.cell),result = try VirtualMachineEngine().compute(project,reusing:cell)
        XCTAssertEqual(result.trace.count,3);XCTAssertEqual(result.drives.count,1)
        XCTAssertEqual(result.collisions.count,1);XCTAssertFalse(result.collisions[0].result.pairs.isEmpty)
        let replay = try VirtualCellReplay(project:project.cell,artifact:cell),snapshot = try replay.snapshot(at:replay.durationSeconds)
        let scene = try VirtualMachineSceneBuilder.build(configuration:project.scene,project:project.cell,artifact:cell,snapshot:snapshot)
        XCTAssertFalse(scene.bodies.contains { $0.id == "workpiece:wp2" },"an unlocated ejected part must not remain as a ghost collision body")
        var catcher = project.scene
        catcher.ejectedPartPlacements["wp2"] = .init(rotation:CellRigidTransform.identity.rotation,translationMM:[200,0,0])
        let located = try VirtualMachineSceneBuilder.build(configuration:catcher,project:project.cell,artifact:cell,snapshot:snapshot)
        XCTAssertEqual(located.bodies.first { $0.id == "workpiece:wp2" }?.frame.translationMM,[200,0,0])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("virtual-machine-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let file = folder.appendingPathComponent("result.floetwin")
        try VirtualMachineArchive.save(project:project,artifact:result,to:file)
        let (input,output) = try VirtualMachineArchive.open(file)
        XCTAssertEqual(try ResearchArchive.digest(input),try ResearchArchive.digest(project))
        XCTAssertEqual(try ResearchArchive.digest(output),try ResearchArchive.digest(result))
        var stale = project;stale.scene.spindles[0].chuckRadiusMM += 1
        XCTAssertThrowsError(try VirtualMachineArchive.save(project:stale,artifact:result,to:file))
        var tampered = result;tampered.trace[0].spindles[0].unwrappedPhaseDegrees += 360
        XCTAssertThrowsError(try tampered.validate(for:project))
        let legacy = folder.appendingPathComponent("same-cell.floecell")
        try ManufacturingCellArchive.save(project:project.cell,artifact:cell,to:legacy)
        XCTAssertEqual(try ManufacturingCellArchive.open(legacy).1.inputSHA256,cell.inputSHA256)
    }
}
