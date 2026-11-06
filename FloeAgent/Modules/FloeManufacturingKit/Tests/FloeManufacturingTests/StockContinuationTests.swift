import XCTest
@testable import FloeManufacturingCore

final class StockContinuationTests: XCTestCase {
    // R10 source additions; execution is assigned to mainline qualification.
    func testDeclaredPlanesCannotChangeInsideTheSameRoundedGrid() throws {
        var study = ManufacturingStudy.shaft()
        study.turning.enabled = false
        study.stock.shape = "box"; study.stock.minMM = [0,0,0]; study.stock.maxMM = [2.2,2.2,2.2]
        study.stock.resolutionMM = 1
        let state = ManufacturingStockState(dimensions:[3,3,3],originMM:[0,0,0],resolutionMM:1,shape:"box",occupiedIndices:Array(0..<27),declaredMaxMM:[2.2,2.2,2.2])
        try state.validateFreshContinuation(for:study)
        var changed = study; changed.stock.maxMM = [2.4,2.2,2.2]
        XCTAssertThrowsError(try state.validate(for:changed))
        var renamed = state; renamed.declaredMaxMM = [2.4,2.2,2.2]
        XCTAssertThrowsError(try renamed.validateContinuation(from:state))
        var missing = state; missing.declaredMaxMM = nil
        XCTAssertThrowsError(try missing.validateContinuation(from:state))
        let reopened = try JSONDecoder().decode(ManufacturingStockState.self,from:ManufacturingStudy.encoder.encode(state))
        XCTAssertEqual(reopened,state)
    }

    func testLegacyArchiveReadDoesNotAuthorizeAnAmbiguousFreshContinuation() throws {
        var study = ManufacturingStudy.shaft()
        study.turning.enabled = false
        study.stock.shape = "box"; study.stock.minMM = [0,0,0]; study.stock.maxMM = [2.2,2.2,2.2]
        study.stock.resolutionMM = 1
        let legacy = ManufacturingStockState(dimensions:[3,3,3],originMM:[0,0,0],resolutionMM:1,shape:"box",occupiedIndices:Array(0..<27))
        try legacy.validate(for:study) // Keep historical saved results readable.
        try legacy.validateContinuation(from:legacy)
        XCTAssertThrowsError(try legacy.validateFreshContinuation(for:study))
        var forgedUpgrade = legacy; forgedUpgrade.declaredMaxMM = [2.2,2.2,2.2]
        XCTAssertThrowsError(try forgedUpgrade.validateContinuation(from:legacy))
        study.stock.maxMM = [3,3,3]
        try legacy.validateFreshContinuation(for:study)
        var alignedUpgrade = legacy; alignedUpgrade.declaredMaxMM = [3,3,3]
        try alignedUpgrade.validateContinuation(from:legacy)
    }

    func testMaterialCannotReturnAfterSpindleTransfer() throws {
        var study = ManufacturingStudy.shaft()
        study.turning.enabled = false
        study.stock.shape = "box"; study.stock.minMM = [0,0,0]; study.stock.maxMM = [2,2,2]
        study.stock.zMinMM = 0; study.stock.zMaxMM = 2; study.stock.resolutionMM = 1
        let original = ManufacturingStockState(dimensions:[2,2,2],originMM:[0,0,0],resolutionMM:1,shape:"box",occupiedIndices:Array(0..<8))
        var first = original; first.occupiedIndices.removeFirst(); first.removedCount = 1
        var next = first; next.occupiedIndices.removeLast(); next.removedCount = 2
        try next.validate(for:study); try next.validateContinuation(from:first)
        var forged = next; forged.occupiedIndices[0] = 0
        try forged.validate(for:study) // Valid volume alone does not prove continuity.
        XCTAssertThrowsError(try forged.validateContinuation(from:first))
        var changedGrid = next; changedGrid.originMM[2] = 10
        XCTAssertThrowsError(try changedGrid.validate(for:study))
        var empty = original; empty.occupiedIndices = []; empty.removedCount = 8
        try empty.validate(for:study); try empty.validateContinuation(from:next)
    }

    func testNativeContinuationUsesExactRemainingCells() throws {
        var study = ManufacturingStudy.shaft(milled:true)
        study.stock.resolutionMM = 2
        let engine = NativeManufacturingEngine()
        let first = try engine.compute(study,control:.init())
        let state = try XCTUnwrap(first.result.stockState)
        let second = try engine.compute(study,startingStock:state,control:.init())
        let end = try XCTUnwrap(second.result.stockState)
        XCTAssertEqual(second.startingStockSHA256,try state.fingerprint())
        XCTAssertEqual(second.result.initialMM3,first.result.remainingMM3,accuracy:1e-8)
        XCTAssertEqual(try XCTUnwrap(second.result.stages.first).remainingMM3,first.result.remainingMM3,accuracy:1e-8)
        XCTAssertEqual(end.occupiedIndices,state.occupiedIndices)
        XCTAssertEqual(second.result.removedMM3,0,accuracy:1e-8)
        try end.validateContinuation(from:state)
    }
    func testBacksideFacingCutsTheLowerEndWithoutResetOrUpperCapRemoval() throws {
        var front = ManufacturingStudy.shaft();front.stock.resolutionMM = 2
        let engine = NativeManufacturingEngine(),first = try engine.compute(front,control:.init())
        let start = try XCTUnwrap(first.result.stockState)
        var back = front;back.turningApproach = .negativeZ;back.profile[0].zMM = 2
        var face = TurningSetup();face.roughEnabled = false;face.profileEnabled = false
        back.turningSetup = face
        let result = try engine.compute(back,startingStock:start,control:.init())
        let end = try XCTUnwrap(result.result.stockState)
        let removed = Set(start.occupiedIndices).subtracting(end.occupiedIndices)
        XCTAssertFalse(removed.isEmpty)
        XCTAssertGreaterThan(result.result.removedMM3,0)
        let plane = start.dimensions[0]*start.dimensions[1]
        XCTAssertTrue(removed.allSatisfy { index in start.originMM[2]+(Double(index/plane)+0.5)*start.resolutionMM <= 2+1e-9 })
        try end.validateContinuation(from:start)
    }
}
