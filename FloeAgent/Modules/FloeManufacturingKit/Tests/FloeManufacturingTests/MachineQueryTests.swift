import XCTest
@testable import FloeManufacturingCore

final class MachineQueryTests:XCTestCase {
    func testNestedRotorsCannotUseCollapsedEndpointRadiusAsSamplingBound() throws {
        let axes = [MachineAxis(id:"A",kind:.revolute,axis:[0,0,1],limits:[0,360]),
                    MachineAxis(id:"B",kind:.revolute,parent:"A",originMM:[10,0,0],axis:[0,0,1],limits:[0,360])]
        let body = MachineBody(id:"folded-arm",attach:.init(axis:"B",frame:.init(originMM:[-10,0,0])),
                               shape:.init(type:.box,halfExtentsMM:[0.05,0.05,0.05]))
        let fixture = MachineBody(id:"remote-fixture",frame:.init(originMM:[100,0,0]),shape:.init(type:.box,halfExtentsMM:[1,1,1]))
        var request = MachineQueryRequest(chain:.init(axes:axes),bodies:[body],fixtures:[fixture],motions:[.rotary("A",from:0,to:360),.rotary("B",from:0,to:360)])
        request.budget.maxSamples = 1000;request.budget.sampleSpacingMM = 0.1;request.budget.maxRotationDegPerSample = 180
        // Centre collapses at both endpoints but unfolds to x=-20 halfway.
        // Endpoint radii would accept this budget despite larger interior speed.
        XCTAssertThrowsError(try NativeManufacturingEngine().machineQuery(request)) { error in
            XCTAssertTrue(error.localizedDescription.contains("cannot cover"),String(describing:error))
        }
    }
    func testIntermediateBodyCollisionAndSynchronizedAxesThroughCABI() throws {
        let engine = NativeManufacturingEngine()
        for synchronized in [false,true] {
            let request = MachineQueryRequest.midpointCollision(synchronized:synchronized)
            let result = try engine.machineQuery(request)
            let pair = try XCTUnwrap(result.pairs.first { $0.state == "intersecting" })
            XCTAssertTrue(result.hasInterference)
            XCTAssertGreaterThan(try XCTUnwrap(pair.firstTime),0)
            XCTAssertLessThan(try XCTUnwrap(pair.firstTime),1)
            XCTAssertGreaterThan(result.poses.count,3)
            XCTAssertEqual(try XCTUnwrap(result.poses.first?.bodies.first?.frame.originMM.last),5,accuracy:1e-6)
            XCTAssertEqual(try XCTUnwrap(result.poses.last?.bodies.first?.frame.originMM.last),synchronized ? 8 : 5,accuracy:1e-6)
        }
        var insufficient = MachineQueryRequest.midpointCollision()
        insufficient.budget.maxSamples = 1
        XCTAssertThrowsError(try engine.machineQuery(insufficient))
        let cancelled = ComputationControl(); cancelled.cancel()
        XCTAssertThrowsError(try engine.machineQuery(.midpointCollision(),control:cancelled))
    }
}
