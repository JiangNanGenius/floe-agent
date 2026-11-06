import XCTest
@testable import FloeNCProgram

final class NCProgramTests:XCTestCase {
    func testNeutralEncoderAndAllSmoothCurvesRoundTrip() throws {
        let program=try NCSamples.smooth(),text=NCCodec.encode(program)
        XCTAssertTrue(text.contains("G3"));XCTAssertTrue(text.contains("G5 "));XCTAssertTrue(text.contains("G5.1"));XCTAssertTrue(text.contains("G5.2"))
        let report=try NCVerification.roundTrip(program)
        XCTAssertTrue(report.passed);XCTAssertGreaterThan(report.sampledPoints,150)
        guard case .arc(_,let sweep,_) = program.motions[1].curve else { return XCTFail("Expected analytic helix") }
        XCTAssertEqual(sweep,4 * .pi,accuracy:1e-12)
        XCTAssertEqual(program.motions[1].end.z,4)
        guard case .nurbs(let controls,let weights,let knots,let order) = program.motions.last!.curve else { return XCTFail("NURBS lost") }
        XCTAssertEqual(controls.count,5);XCTAssertEqual(weights[2],1.5);XCTAssertEqual(knots.count,8);XCTAssertEqual(order,3)
    }
    func testPlaneHandednessAndSignedRadius() throws {
        for (plane,start,end,offset,mid) in [
            ("G17","X1 Y0 Z0","X0 Y1","I-1 J0",NCVector(sqrt(0.5),sqrt(0.5),0)),
            ("G18","X0 Y0 Z1","X1 Z0","K-1 I0",NCVector(sqrt(0.5),0,sqrt(0.5))),
            ("G19","X0 Y1 Z0","Y0 Z1","J-1 K0",NCVector(0,sqrt(0.5),sqrt(0.5)))
        ] {
            let p=try NCCodec.decode("G21 G90 \(plane)\nG0 \(start)\nG3 \(end) \(offset) F20")
            let points=try NCGeometry.sample(p)[1].samples
            let near=points.min { abs($0.parameter-0.5) < abs($1.parameter-0.5) }!.point
            XCTAssertLessThan((near-mid).length,0.08)
            guard case .arc(_,let sweep,_) = p.motions[1].curve else { return XCTFail() }
            XCTAssertEqual(sweep,.pi/2,accuracy:1e-10)
        }
        let short=try NCCodec.decode("G21\nG0 X1 Y0\nG3 X0 Y1 R1 F10")
        let long=try NCCodec.decode("G21\nG0 X1 Y0\nG3 X0 Y1 R-1 F10")
        if case .arc(_,let a,_) = short.motions[1].curve,case .arc(_,let b,_) = long.motions[1].curve {
            XCTAssertEqual(a,.pi/2,accuracy:1e-10);XCTAssertEqual(b,3 * .pi/2,accuracy:1e-10)
        } else { XCTFail() }
    }
    func testDiameterUnitsAndUnwrappedRotation() throws {
        let p=try NCCodec.decode("G20 G7 G18\nG0 X2 Y0 Z0 C0\nG3 X0 Z-1 I-1 K0 F4\nG91 G1 X2 C720\nS1200 M3\nM2")
        XCTAssertEqual(p.motions[0].end.x!,25.4,accuracy:1e-12)
        XCTAssertEqual(p.motions[1].end.x!,0,accuracy:1e-12)
        if case .arc(let center,let sweep,_) = p.motions[1].curve {
            XCTAssertEqual(center.x,0,accuracy:1e-12);XCTAssertEqual(sweep,.pi/2,accuracy:1e-10)
        } else { XCTFail() }
        XCTAssertEqual(p.motions[2].end.x!,25.4,accuracy:1e-12)
        XCTAssertEqual(p.finalPosition.c,720);XCTAssertEqual(p.motions[1].process.feed!,101.6,accuracy:1e-10)
        XCTAssertEqual(p.finalProcess.spindles[0]?.direction,.stopped)
        XCTAssertTrue(try NCVerification.roundTrip(p).passed)
        let absolute=try NCCodec.decode("G21 G18 G7 G90.1\nG0 X20 Z0\nG2 X0 Z-10 I0 K0 F10")
        XCTAssertEqual(absolute.motions[1].end.x,0)
    }
    func testCubicTangentContinuationAndQuadratic() throws {
        let p=try NCCodec.decode("G21\nG0 X0 Y0\nG5 X4 Y0 I1 J2 P-1 Q2 F10\nG5 X8 Y0 P-1 Q-2\nG5.1 X12 I2 J3")
        if case .bezier(let a) = p.motions[1].curve,case .bezier(let b) = p.motions[2].curve {
            XCTAssertEqual(a[3]-a[2],b[1]-b[0])
        } else { XCTFail() }
        XCTAssertTrue(try NCVerification.roundTrip(p).passed)
        XCTAssertThrowsError(try NCCodec.decode("G21\nG0 X0 Y0\nG5 X4 P-1 Q2 F10"))
    }
    func testRationalQuarterCircleAndTolerance() throws {
        let controls=[NCVector(1,0,0),NCVector(1,1,0),NCVector(0,1,0)]
        let p=try NCBuilder.program(start:controls[0],curves:[.nurbs(controls:controls,weights:[1,sqrt(0.5),1],knots:[0,0,0,1,1,1],order:3)],ends:[controls[2]],feedMMPerMinute:10)
        let samples=try NCGeometry.sample(p)[1].samples
        XCTAssertGreaterThan(samples.count,4)
        for sample in samples { XCTAssertEqual(hypot(sample.point.x,sample.point.y),1,accuracy:1e-12) }
        for pair in zip(samples,samples.dropFirst()) {
            let chordMid=(pair.0.point+pair.1.point)*0.5
            XCTAssertLessThanOrEqual(1-hypot(chordMid.x,chordMid.y),p.configuration.chordToleranceMM)
        }
    }
    func testRejectsInvalidGeometryAndUnsupportedSemantics() {
        for code in ["G21\nG0 X0 Y0\nG2 X1 Y0 R0.1 F10","G21\nG0 X1 Y0\nG2 I-1 J0 P0 F10",
                     "G21\nG0 X1 Y0\nG2 X1.1 Y0 I-1 J0 F10","G21\nG0 X1 Y0\nG2 R1 F10",
                     "G21 G81 X0 Y0 Z-5 R1 F20","G21 G43 H1","G21\nG0 X0\nX#1","G21\nG0 X0\nM123",
                     "G21\nG0 X0\nM2\nG0 X1","G20 G21\nG0 X0","G21\nG0 X0 X1","G21\nG0 X0\nG5.2 P1\nG5.3"] {
            XCTAssertThrowsError(try NCCodec.decode(code),code) { error in XCTAssertTrue(error is NCError) }
        }
    }
    func testUnknownInitialAxesAndBudgetsAndCancellation() throws {
        XCTAssertThrowsError(try NCCodec.decode("G0 X1"))
        XCTAssertThrowsError(try NCCodec.decode("G21 G91\nG0 X1"))
        XCTAssertThrowsError(try NCCodec.decode("G21\nG1 X1 F10"))
        let p=try NCCodec.decode("G21\nG0 X0 Y0\nG1 X1 F10")
        XCTAssertNil(p.finalPosition.z);XCTAssertEqual(try NCGeometry.sample(p)[0].samples.count,0)
        var config=NCConfiguration();config.maximumPoints=10
        XCTAssertThrowsError(try NCCodec.decode("G21\nG0 X1 Y0\nG2 I-1 J0 P8 F10",configuration:config))
        let token=NCCancellation();token.cancel()
        XCTAssertThrowsError(try NCCodec.decode("G21\nG0 X0",cancellation:token)) { XCTAssertTrue($0 is CancellationError) }
    }
    func testFeedSpindleEventsAndFileEnvelope() throws {
        let p=try NCCodec.decode("%\nG21 G93\nT4 M6\nG0 X0 Y0\nS500 $1 M4\nG1 X1 F2 M8\nG4 P0.5\nM1\nM5 $-1\nM30\n%")
        XCTAssertEqual(p.motions[1].process.spindles[1]?.direction,.counterclockwise)
        XCTAssertEqual(p.motions[1].process.feedMode,.inverseTime)
        XCTAssertTrue(p.events.contains { $0.kind == "dwell" && $0.value == 0.5 })
        XCTAssertTrue(p.events.contains { $0.kind == "tool-change" && $0.value == 4 })
        XCTAssertEqual(p.finalProcess.flood,false)
        XCTAssertTrue(try NCVerification.roundTrip(p).passed)
        XCTAssertThrowsError(try NCCodec.decode("G21 G93\nG0 X0\nG1 X1 F2\nX2"))
    }
    func testArchiveSourceIntegrityAndSaveReopen() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let url=directory.appendingPathComponent("smooth.floenc")
        let source=NCCodec.encode(try NCSamples.smooth())
        try NCArchive.save(source:source,configuration:.init(),to:url)
        let reopened=try NCArchive.open(url)
        XCTAssertEqual(reopened.source,source);XCTAssertTrue(try NCVerification.roundTrip(reopened.program).passed)
        var json=try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as! [String:Any]
        json["sha256"]=String(repeating:"0",count:64)
        try JSONSerialization.data(withJSONObject:json).write(to:url)
        XCTAssertThrowsError(try NCArchive.open(url))
    }
    func testNeutralBuilderRejectsDisconnectedOrLossySpline() throws {
        XCTAssertThrowsError(try NCBuilder.program(start:.init(0,0,0),curves:[.bezier(controls:[.init(1,0,0),.init(2,2,0),.init(3,0,0)])],ends:[.init(3,0,0)],feedMMPerMinute:10))
        let controls=[NCVector(0,0,0),.init(1,2,0),.init(2,0,0),.init(3,1,0)]
        XCTAssertThrowsError(try NCBuilder.program(start:controls[0],curves:[.nurbs(controls:controls,weights:[1,1,1,1],knots:[0,0,0,0.2,1,1,1],order:3)],ends:[controls[3]],feedMMPerMinute:10))
    }
    func testRationalMultipleSpansAgainstIndependentBasisEvaluation() throws {
        for order in 3...6 {
            let count=order+2
            let controls=(0..<count).map { NCVector(Double($0),sin(Double($0)),0) }
            let weights=(0..<count).map { 0.7+Double($0)*0.2 }
            let knots=NCGeometry.uniformKnots(controlCount:count,order:order)
            let program=try NCBuilder.program(start:controls[0],curves:[.nurbs(controls:controls,weights:weights,knots:knots,order:order)],ends:[controls.last!],feedMMPerMinute:10)
            func basis(_ i:Int,_ k:Int,_ t:Double)->Double {
                if k == 1 { return knots[i] <= t && t < knots[i+1] ? 1 : 0 }
                let a=knots[i+k-1]-knots[i],b=knots[i+k]-knots[i+1]
                return (a > 0 ? (t-knots[i])/a*basis(i,k-1,t) : 0)+(b > 0 ? (knots[i+k]-t)/b*basis(i+1,k-1,t) : 0)
            }
            for sample in try NCGeometry.sample(program)[1].samples where sample.parameter < 1 {
                var numerator=NCVector(0,0,0),denominator=0.0
                for i in 0..<count { let b=basis(i,order,sample.parameter)*weights[i];numerator=numerator+controls[i]*b;denominator += b }
                XCTAssertLessThan((sample.point-numerator*(1/denominator)).length,1e-10)
            }
        }
    }
    @MainActor func testEditingAndCancelFenceLateResultPublication() async throws {
        let session=NCLocalSession()
        let large="G21\nG0 X0 Y0 Z0\n"+String(repeating:"G1 X1 F10\n",count:10000)
        session.replaceSource(large);session.calculate()
        let current="G21\nG0 X0 Y0 Z0\nG1 X2 F10\n"
        session.replaceSource(current);session.calculate()
        for _ in 0..<100 { if !session.busy { break };try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertFalse(session.busy);XCTAssertNil(session.error);XCTAssertEqual(session.source,current)
        XCTAssertEqual(session.program?.finalPosition.x,2);XCTAssertEqual(session.report?.motions,2)
        session.replaceSource(large);session.calculate();session.cancel()
        try await Task.sleep(for:.milliseconds(30))
        XCTAssertFalse(session.busy);XCTAssertNil(session.program);XCTAssertNil(session.report)
    }
}
