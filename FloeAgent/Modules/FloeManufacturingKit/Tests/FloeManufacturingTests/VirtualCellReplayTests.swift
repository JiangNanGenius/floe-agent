import XCTest
@testable import FloeManufacturingCore

final class VirtualCellReplayTests:XCTestCase {
    func testDualGripContinuityCarriageAndTurningToolMeridian() throws {
        let project = ManufacturingCellProject.demonstration(),artifact = try CellManufacturingEngine().compute(project)
        let replay = try VirtualCellReplay(project:project,artifact:artifact),transfer = try XCTUnwrap(artifact.schedule.transfers.first)
        let epsilon = 1e-7
        for boundary in [transfer.acquireSeconds,transfer.releaseSeconds] {
            let a = try replay.snapshot(at:boundary-epsilon),b = try replay.snapshot(at:boundary+epsilon)
            let p = try XCTUnwrap(a.workpieces.first { $0.id == "wp1" }),q = try XCTUnwrap(b.workpieces.first { $0.id == "wp1" })
            for (x,y) in zip(p.worldFromWorkpiece.translationMM,q.worldFromWorkpiece.translationMM) { XCTAssertEqual(x,y,accuracy:1e-4) }
            for (x,y) in zip(p.worldFromWorkpiece.rotation,q.worldFromWorkpiece.rotation) { XCTAssertEqual(x,y,accuracy:1e-3) }
        }
        let end = try replay.snapshot(at:replay.durationSeconds)
        XCTAssertEqual(end.workpieces.first { $0.id == "wp1" }?.worldFromWorkpiece.translationMM,[0,0,42])
        let front = try XCTUnwrap(artifact.schedule.steps.first { $0.stepID == "main-front-op" })
        let pose = try replay.snapshot(at:front.startSeconds+0.1),tool = try XCTUnwrap(pose.tools.first { $0.stepID == "main-front-op" })
        XCTAssertEqual(tool.worldTipMM[1],0,accuracy:1e-10)
        XCTAssertNotEqual(try XCTUnwrap(pose.spindles.first { $0.id == "main" }).wrappedPhaseDegrees,0)
        let duringGrip = try replay.snapshot(at:(transfer.acquireSeconds+transfer.releaseSeconds)/2)
        XCTAssertEqual(duringGrip.spindles.filter { $0.clampedWorkpieceID == "wp1" }.count,2)
        XCTAssertThrowsError(try replay.snapshot(at:.nan))
        XCTAssertThrowsError(try replay.snapshot(at:replay.durationSeconds+1))
    }
    func testUnwrappedCIndexRetainsMultipleTurnsAndSceneRejectsInvalidMesh() throws {
        var project = ManufacturingCellProject.demonstration()
        let last = project.cell.steps.filter { $0.channelID == "ch-main" }.map(\.order).max() ?? 0
        project.cell.steps.append(.init(id:"main-index-720",channelID:"ch-main",order:last+1,
            action:.spindle(.init(spindleID:"main",mode:.cIndex,cIndexDegrees:720,durationSeconds:1))))
        XCTAssertThrowsError(try project.validate()) // Unspecified machines keep the original single-turn contract.
        project.cell.spindles[0].cAxisTravelDegrees = [-720,1080]
        XCTAssertFalse(project.cell.spindles[0].containsCPosition(1081))
        let artifact = try CellManufacturingEngine().compute(project),replay = try VirtualCellReplay(project:project,artifact:artifact)
        let end = try replay.snapshot(at:replay.durationSeconds),spindle = try XCTUnwrap(end.spindles.first { $0.id == "main" })
        XCTAssertEqual(spindle.unwrappedPhaseDegrees,720);XCTAssertEqual(spindle.wrappedPhaseDegrees,0)
        var geometry = VirtualMachineSceneConfiguration.demonstration(for:project.cell)
        geometry.fixtures = [.init(id:"broken",shape:.init(type:.mesh,vertices:[[0,0,0],[1,0,0],[0,1,0]],triangles:[[0,1,999]]))]
        XCTAssertThrowsError(try geometry.validate(for:project.cell))
    }
}
