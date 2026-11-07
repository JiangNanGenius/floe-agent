import XCTest
@testable import FloeManufacturingCore

final class CAMMaterialReplayTests:XCTestCase {
    func testTurningProgressiveRemovalAndRewindMatchTheExecutionResult() throws {
        let study = ManufacturingStudy.cuttingSpeedExample()
        let artifact = try NativeManufacturingEngine().compute(study,control:.init())
        let program = try CAMPreviewProgram(source:.study(study,artifact))
        let initial = try program.frame(at:0)
        let middle = try program.frame(at:program.extent*0.4)
        let later = try program.frame(at:program.extent*0.7)
        let end = try program.frame(at:program.extent)
        XCTAssertTrue(initial.progressiveMaterial)
        XCTAssertGreaterThan(try XCTUnwrap(initial.remainingMM3),try XCTUnwrap(middle.remainingMM3))
        XCTAssertGreaterThan(try XCTUnwrap(middle.remainingMM3),try XCTUnwrap(later.remainingMM3))
        XCTAssertEqual(try XCTUnwrap(end.remainingMM3),artifact.result.remainingMM3,accuracy:1e-8)
        let rewind = try program.frame(at:program.extent*0.4)
        XCTAssertEqual(rewind.remainingMM3,middle.remainingMM3)
        XCTAssertEqual(rewind.scene.bodies.first { $0.role == "stock" }?.shape.vertices,middle.scene.bodies.first { $0.role == "stock" }?.shape.vertices)
        XCTAssertEqual(middle.materialResolutionMM,study.stock.resolutionMM)
    }
    func testMillingAndTurnMillEndStatesMatchRealNativeOccupancy() throws {
        for study in [ManufacturingStudy.featureCAM(),.shaft(milled:true),.fiveAxis(),.selectedTurning(),.turnMillCAM()] {
            let artifact = try NativeManufacturingEngine().compute(study,control:.init())
            let program = try CAMPreviewProgram(source:.study(study,artifact))
            let frame = try program.frame(at:program.extent)
            XCTAssertTrue(frame.progressiveMaterial,study.name)
            XCTAssertEqual(try XCTUnwrap(frame.remainingMM3),artifact.result.remainingMM3,accuracy:1e-8,study.name)
        }
    }
    func testPartialCutMaterialAndTCPUseTheSameSourceSegment() throws {
        let study = ManufacturingStudy.featureCAM()
        let artifact = try NativeManufacturingEngine().compute(study,control:.init())
        let program = try CAMPreviewProgram(source:.study(study,artifact))
        let path = try XCTUnwrap(program.paths.first { $0.kind == "cam-cut" && ($0.end ?? 0)>($0.start ?? 0) })
        let a = try XCTUnwrap(path.start),b = try XCTUnwrap(path.end)
        let before = try program.frame(at:a),half = try program.frame(at:(a+b)/2),after = try program.frame(at:b)
        XCTAssertLessThanOrEqual(try XCTUnwrap(half.remainingMM3),try XCTUnwrap(before.remainingMM3))
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(half.remainingMM3),try XCTUnwrap(after.remainingMM3))
        let timeline = try XCTUnwrap(artifact.result.cuttingTimeline)
        XCTAssertEqual(half.tools.first?.tipMM,try timeline.sample(atSeconds:(a+b)/2).pointMM)
        let cancelled = ComputationControl();cancelled.cancel()
        XCTAssertThrowsError(try program.frame(at:(a+b)/2,control:cancelled))
    }
    func testRoundAndRhombicInsertsRetainTheirGeometryAndFlatCaps() throws {
        var study = ManufacturingStudy.selectedTurning()
        for shape in ["R","D","C","V"] {
            study.turningSetup?.insertShape = shape
            study.turningSetup?.insertRotationDegrees = 23
            let artifact = try NativeManufacturingEngine().compute(study,control:.init())
            let receipt = try XCTUnwrap(artifact.result.turningSetupReceipt)
            let outline = receipt.toolProfile
            let mesh = try XCTUnwrap(ManufacturingDisplaySurface.extrudedOutline(outline,bottom:-1,top:0))
            XCTAssertTrue(mesh.vertices.allSatisfy { vertex in outline.contains { abs($0[0]-vertex[0])<1e-8 && abs($0[1]-vertex[2])<1e-8 } })
            let capNormals = zip(mesh.vertices,mesh.normals).filter { abs(abs($0.1[1])-1)<1e-9 }
            XCTAssertGreaterThan(capNormals.count,0)
            if shape == "R" {
                let a = 23*Double.pi/180,center = [-sin(a)*receipt.applied.insertEdgeLengthMM/2,cos(a)*receipt.applied.insertEdgeLengthMM/2]
                for point in outline { XCTAssertEqual(hypot(point[0]-center[0],point[1]-center[1]),receipt.applied.insertEdgeLengthMM/2,accuracy:1e-5) }
            } else { XCTAssertEqual(Set(outline.map { $0.map { String(format:"%.5f",$0) }.joined(separator:",") }).count,4) }
        }
    }
}
