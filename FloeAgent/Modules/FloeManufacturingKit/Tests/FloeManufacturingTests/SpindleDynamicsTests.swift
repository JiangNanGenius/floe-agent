import XCTest
@testable import FloeManufacturingCore

final class SpindleDynamicsTests:XCTestCase {
    private func request(initial:Double,target:Double)->SpindleDriveRequest {
        .init(configuration:.init(inertiaKgM2:0.1,maxRPM:6000,motoringTorqueNM:2,brakingTorqueNM:2,motoringPowerKW:1000,brakingPowerKW:1000),initialRPM:initial,targetRPM:target)
    }
    func testConstantTorqueMatchesAnalyticTimeAngleAndEnergy() throws {
        let input = request(initial:0,target:100),result = try SpindleDriveSolver.solve(input)
        let omega = 100*Double.pi/30,time = 0.1*omega/2
        XCTAssertEqual(result.termination,.targetReached)
        XCTAssertEqual(result.elapsedSeconds,time,accuracy:1e-9)
        XCTAssertEqual(result.finalPhaseDegrees,0.5*omega*time*180/Double.pi,accuracy:1e-7)
        XCTAssertEqual(result.driveMechanicalWorkJ,0.5*0.1*omega*omega,accuracy:1e-8)
        XCTAssertEqual(result.energyBalanceResidualJ,0,accuracy:1e-8)
        try result.validate(for:input)
    }
    func testBrakingReversalAndRegenerationHaveCorrectSigns() throws {
        var braking = request(initial:600,target:0);braking.configuration.regenerationEfficiency = 0.5
        let result = try SpindleDriveSolver.solve(braking),kinetic = 0.5*0.1*pow(600*Double.pi/30,2)
        XCTAssertEqual(result.termination,.targetReached);XCTAssertEqual(result.finalRPM,0,accuracy:1e-8)
        XCTAssertEqual(result.regeneratedElectricalJ,kinetic*0.5,accuracy:1e-6)
        XCTAssertEqual(result.electricalInputJ,0,accuracy:1e-8)
        let reverse = try SpindleDriveSolver.solve(request(initial:600,target:-600))
        XCTAssertEqual(reverse.termination,.targetReached);XCTAssertEqual(reverse.finalRPM,-600,accuracy:1e-8)
        XCTAssertEqual(reverse.finalPhaseDegrees,0,accuracy:1e-5)
        XCTAssertEqual(reverse.energyBalanceResidualJ,0,accuracy:1e-6)
    }
    func testPowerLimitAndOpposingLoadAreNotFakedAsReached() throws {
        var input = request(initial:0,target:1000);input.configuration.motoringPowerKW = 0.1;input.maxDurationSeconds = 30
        let limited = try SpindleDriveSolver.solve(input)
        XCTAssertTrue(limited.powerLimited);XCTAssertEqual(limited.termination,.targetReached)
        XCTAssertLessThanOrEqual(limited.samples.map { abs($0.mechanicalPowerKW) }.max() ?? 0,0.1001)
        var stalled = request(initial:0,target:100);stalled.configuration.motoringTorqueNM = 0;stalled.configuration.loadTorqueNM = 1;stalled.maxDurationSeconds = 0.1
        let result = try SpindleDriveSolver.solve(stalled)
        XCTAssertEqual(result.termination,.timeLimit);XCTAssertEqual(result.finalRPM,0);XCTAssertEqual(result.finalPhaseDegrees,0)
    }
    func testBudgetCancellationAndExtremeFiniteInputsFailExplicitly() throws {
        var input = request(initial:0,target:100);input.maxSteps = 1
        XCTAssertEqual(try SpindleDriveSolver.solve(input).termination,.stepLimit)
        input.maxSamples = 2;input.maxSteps = 1000;input.sampleEverySteps = 1
        XCTAssertThrowsError(try SpindleDriveSolver.solve(input))
        input = request(initial:0,target:100);input.configuration.inertiaKgM2 = 1e200
        XCTAssertThrowsError(try SpindleDriveSolver.solve(input))
        let cancelled = ComputationControl();cancelled.cancel()
        XCTAssertThrowsError(try SpindleDriveSolver.solve(request(initial:0,target:100),control:cancelled))
    }
    func testZeroMotionPreservesExplicitPhaseAndSpeedExactly() throws {
        var input = request(initial:123.45,target:123.45);input.initialPhaseDegrees = 1_000_000.125
        let result = try SpindleDriveSolver.solve(input)
        XCTAssertEqual(result.steps,0);XCTAssertEqual(result.finalPhaseDegrees,input.initialPhaseDegrees)
        XCTAssertEqual(result.finalRPM,input.initialRPM);XCTAssertEqual(result.samples.count,1)
        try result.validate(for:input)
    }
}
