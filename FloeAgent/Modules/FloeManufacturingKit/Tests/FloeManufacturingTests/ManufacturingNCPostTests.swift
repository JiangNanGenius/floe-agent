import XCTest
import FloeManufacturingCore
import FloeManufacturingNC
import FloeNCProgram

final class ManufacturingNCPostTests:XCTestCase {
    func testActualCAMAndDiameterTurningExportEverySourceSegment() throws {
        for study in [ManufacturingStudy.featureCAM(),.cuttingSpeedExample()] {
            let artifact=try NativeManufacturingEngine().compute(study,control:.init())
            var options=ManufacturingNCOptions();options.turningDiameterProgramming=true;options.floodCoolant=true
            let output=try ManufacturingNCPost.generate(study:study,artifact:artifact,options:options)
            XCTAssertTrue(output.receipt.roundTrip.passed)
            XCTAssertEqual(output.receipt.sourcePaths.count,artifact.result.paths.count)
            XCTAssertFalse(output.receipt.addedMoves.isEmpty)
            XCTAssertEqual(output.source,NCCodec.encode(output.program))
            XCTAssertTrue(output.source.contains("T1 M6"));XCTAssertTrue(output.source.contains("M8"))
            XCTAssertTrue(output.source.contains("G61"),"True corners require explicit exact-path mode in this generic profile")
            XCTAssertEqual(output.receipt.sourceInputSHA256,artifact.inputSHA256)
            if study.turning.enabled {
                XCTAssertTrue(output.source.contains("G7"));XCTAssertTrue(output.source.contains("G96"));XCTAssertTrue(output.source.contains("G95"))
                XCTAssertTrue(output.receipt.operationsUsingFallbackRPM.isEmpty)
                XCTAssertTrue(output.program.motions.filter { !$0.rapid }.allSatisfy { $0.process.feedMode == .perRevolution })
            } else {
                XCTAssertEqual(output.receipt.tools.count,2)
                XCTAssertTrue(output.receipt.operationsUsingFallbackRPM.contains("face-1"))
                XCTAssertTrue(output.source.contains("G4 P0.2"))
            }
            var stale=study;stale.name += " changed"
            XCTAssertThrowsError(try ManufacturingNCPost.generate(study:stale,artifact:artifact))
            var invalid=options;invalid.toolNumbers=["a":1,"b":1]
            XCTAssertThrowsError(try ManufacturingNCPost.generate(study:study,artifact:artifact,options:invalid))
            let cancelled=NCCancellation();cancelled.cancel()
            XCTAssertThrowsError(try ManufacturingNCPost.generate(study:study,artifact:artifact,cancellation:cancelled))
        }
    }
}
