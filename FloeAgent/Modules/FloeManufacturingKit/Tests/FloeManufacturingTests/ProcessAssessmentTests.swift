import XCTest
@testable import FloeManufacturingCore

final class ProcessAssessmentTests: XCTestCase {
    func testCuttingPowerAndIdealFeedMarks() throws {
        var study = ManufacturingStudy.cuttingSpeedExample()
        study.turning.toolNoseRadiusMM = 0.4
        study.turningCutting?.surfaceSpeedMPerMinute = 140
        study.turningCutting?.feedMMPerRevolution = 0.1
        let request = TurningProcessRequirements(radiusMM:30,depthMM:5,specificCuttingForceNPerMM2:3610,efficiency:0.8,
                                                availableInputPowerKW:5,availableTorqueNM:50,maximumIdealCuspUM:3)
        let value = try TurningProcessAssessment.evaluate(study:study,requirements:request)
        XCTAssertEqual(value.tangentialForceN,1805,accuracy:1e-8)
        XCTAssertEqual(value.requiredInputPowerKW,5.2645833333,accuracy:1e-8)
        XCTAssertEqual(value.idealCuspHeightUM,3.1373033403,accuracy:1e-7)
        XCTAssertEqual(Set(value.exceededLimits),Set(["inputPowerKW","torqueNM","idealCuspUM"]))
        study.turningCutting?.feedMode = .mmPerMinute
        study.turning.feedMMPerMinute = value.rpm*0.05
        let slower = try TurningProcessAssessment.evaluate(study:study,requirements:request)
        XCTAssertEqual(slower.tangentialForceN,value.tangentialForceN/2,accuracy:1e-8)
        XCTAssertLessThan(slower.idealCuspHeightUM,value.idealCuspHeightUM/3.9)
    }
    func testInactiveRequirementsAndRareLimitsSurviveSavingInput() throws {
        var study = ManufacturingStudy.shaft()
        study.processRequirements = .init(availableTorqueNM:23.4,maximumIdealCuspUM:1.2)
        study.processAssessmentEnabled = false
        try study.validate()
        let reopened = try JSONDecoder().decode(ManufacturingStudy.self,from:study.encoded())
        XCTAssertEqual(reopened.processRequirements,study.processRequirements)
        XCTAssertFalse(reopened.isProcessAssessmentEnabled)
        study.processAssessmentEnabled = true
        XCTAssertThrowsError(try study.validate()) // No speed law may be invented.
    }
}
