// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
@testable import FloeBuildingAnalysis

final class BuildingAnalysisTests: XCTestCase {
    private func ies(_ rows:[[Double]]=[[100,100,100]],angles:[Double]=[0],multiplier:Double=1,units:Int=2)->String {
        """
        IESNA:LM-63-2002
        [TEST] SYNTHETIC; NOT A MANUFACTURER FILE
        TILT=NONE
        1 -1 \(multiplier) 3 \(angles.count) 1 \(units) 0.1 0.2 0.05
        1 1 12
        0 90 180
        \(angles.map{String($0)}.joined(separator:" "))
        \(rows.map{$0.map{String($0)}.joined(separator:" ")}.joined(separator:"\n"))
        """
    }
    private func profile() throws -> IESPhotometry { try IESPhotometryParser.parse(ies()) }
    private func request() throws -> LightingAnalysisRequest {
        .init(projectRevision:1,luminaires:[.init(id:"L1",positionM:.init(0,0,2),photometry:try profile())],
              workplane:.init(originM:.init(0,0,0),widthM:1,heightM:1,columns:2,rows:2))
    }

    func testAbsoluteCandelaIsNotNormalized() throws {
        let input=ies([[100,50,0]],multiplier:2)
        let result=try IESPhotometryParser.parse(input)
        XCTAssertEqual(result.peakCandela,200)
        XCTAssertEqual(try result.intensityCD(verticalDegrees:90,horizontalDegrees:0),100)
        XCTAssertEqual(result.sourceSHA256,BuildingAnalysisFingerprint.dataHash(Data(input.utf8)))
    }
    func testModernSourceMetadataDoesNotScaleCandela() throws {
        let modern=ies().replacingOccurrences(of:"1 1 12",with:"1 7 12")
            .replacingOccurrences(of:"IESNA:LM-63-2002",with:"IES:LM-63-2019")
        XCTAssertEqual(try IESPhotometryParser.parse(modern).peakCandela,100)
        let legacy=ies().replacingOccurrences(of:"1 1 12",with:"1 2 12")
            .replacingOccurrences(of:"IESNA:LM-63-2002",with:"IESNA91")
        XCTAssertEqual(try IESPhotometryParser.parse(legacy).peakCandela,200)
        XCTAssertThrowsError(try IESPhotometryParser.parse(ies([[-100,100,100]],multiplier:0)))
    }
    func testQuarterSymmetryAndInterpolation() throws {
        let p=try IESPhotometryParser.parse(ies([[100,100,100],[40,40,40]],angles:[0,90]))
        for angle in [45.0,135,225,315] {
            XCTAssertEqual(try p.intensityCD(verticalDegrees:30,horizontalDegrees:angle),70,accuracy:1e-10)
        }
        XCTAssertEqual(try p.intensityCD(verticalDegrees:0,horizontalDegrees:-45),70,accuracy:1e-10)
        XCTAssertEqual(try p.intensityCD(verticalDegrees:181,horizontalDegrees:0),0)
    }
    func testC90SymmetryKeepsOrientation() throws {
        let p=try IESPhotometryParser.parse(ies([[20,20,20],[80,80,80],[40,40,40]],angles:[90,180,270]))
        XCTAssertEqual(try p.intensityCD(verticalDegrees:20,horizontalDegrees:0),80)
        XCTAssertEqual(try p.intensityCD(verticalDegrees:20,horizontalDegrees:90),20)
        XCTAssertEqual(try p.intensityCD(verticalDegrees:20,horizontalDegrees:270),40)
    }
    func testAsymmetricMissingWrapAndFeet() throws {
        let p=try IESPhotometryParser.parse(ies([[10,10,10],[20,20,20],[30,30,30],[40,40,40]],angles:[0,90,180,270],units:1))
        XCTAssertEqual(p.horizontalAngles,[0,90,180,270,360])
        XCTAssertEqual(try p.intensityCD(verticalDegrees:30,horizontalDegrees:315),25)
        XCTAssertEqual(p.declaredDimensionsM.x,0.03048,accuracy:1e-12)
        let reopened=try JSONDecoder().decode(IESPhotometry.self,from:JSONEncoder().encode(p))
        XCTAssertEqual(reopened,p)
        XCTAssertEqual(try reopened.intensityCD(verticalDegrees:30,horizontalDegrees:315),25)
    }
    func testMalformedAndUnsupportedInputsAreRejected() throws {
        XCTAssertThrowsError(try IESPhotometryParser.parse(ies().replacingOccurrences(of:"TILT=NONE",with:"TILT=INCLUDE")))
        XCTAssertThrowsError(try IESPhotometryParser.parse(ies().replacingOccurrences(of:"1 2 0.1",with:"2 2 0.1")))
        XCTAssertThrowsError(try IESPhotometryParser.parse(ies()+" 99"))
        XCTAssertThrowsError(try IESPhotometryParser.parse(ies().replacingOccurrences(of:"0 90 180",with:"0 90 80")))
        let nonfinite=ies([[Double.nan,100,100]])
        XCTAssertNotEqual(nonfinite,ies(),"The invalid fixture must differ from the valid decimal-formatted fixture")
        XCTAssertThrowsError(try IESPhotometryParser.parse(nonfinite))
        XCTAssertThrowsError(try IESPhotometryParser.parse(ies(),maximumBytes:10))
        XCTAssertThrowsError(try IESPhotometryParser.parse(ies([[1,1,1],[2,2,2]],angles:[0,45])))
    }
    func testDirectLuxHasCorrectDistanceCosineAndScale() throws {
        let input=try request(),result=try DirectLightingSolver.solve(input)
        XCTAssertEqual(result.samples[0].lux,25,accuracy:1e-10)
        XCTAssertEqual(result.samples[3].lux,200/(6*sqrt(6)),accuracy:1e-10)
        var dimmed=input;dimmed.luminaires[0].outputScale=0.4
        let smaller=try DirectLightingSolver.solve(dimmed)
        XCTAssertEqual(smaller.samples[0].lux,10,accuracy:1e-10)
        XCTAssertTrue(try result.isStale(for:dimmed))
        XCTAssertFalse(try result.isStale(for:input))
        XCTAssertTrue(result.csv().contains("illuminance_lux"))
    }
    func testIndependentLightsSumAndOpaqueShadow() throws {
        var input=try request()
        input.luminaires.append(.init(id:"L2",positionM:.init(0,0,2),photometry:try profile()))
        XCTAssertEqual(try DirectLightingSolver.solve(input).samples[0].lux,50,accuracy:1e-10)
        input.opaqueBoxes=[.init(id:"box",minimumM:.init(-0.1,-0.1,0.5),maximumM:.init(0.1,0.1,1.5))]
        let shadow=try DirectLightingSolver.solve(input)
        XCTAssertEqual(shadow.samples[0].lux,0)
        XCTAssertGreaterThan(shadow.samples[3].lux,0)
    }
    func testLightingBudgetCancellationAndInvalidFrames() throws {
        let input=try request()
        XCTAssertThrowsError(try DirectLightingSolver.solve(input,maximumCells:3))
        XCTAssertThrowsError(try DirectLightingSolver.solve(input,cancelled:{true}))
        var invalid=input;invalid.workplane.up=invalid.workplane.right
        XCTAssertThrowsError(try DirectLightingSolver.solve(invalid))
        invalid=input;invalid.luminaires[0].c0Direction=invalid.luminaires[0].aim
        XCTAssertThrowsError(try DirectLightingSolver.solve(invalid))
        invalid=input;invalid.luminaires[0].positionM = .init(0,0,0)
        XCTAssertThrowsError(try DirectLightingSolver.solve(invalid))
        invalid=input;invalid.luminaires.append(invalid.luminaires[0])
        XCTAssertThrowsError(try DirectLightingSolver.solve(invalid))
    }
    func testLightingResultSnapshotRoundTrip() throws {
        let result=try DirectLightingSolver.solve(request())
        let copy=try JSONDecoder().decode(LightingAnalysisResult.self,from:JSONEncoder().encode(result))
        XCTAssertEqual(copy,result)
        XCTAssertEqual(result.scope,"preliminary-direct-illuminance")
        XCTAssertTrue(result.limitations.contains("no interreflection"))
    }
    private func thermal() -> HVACDesignLoadRequest {
        .init(roomID:"room-kitchen",projectRevision:3,mode:.heating,indoorC:20,outdoorC:0,
            envelope:[.init(id:"wall",areaM2:10,transmittanceWPerM2K:0.5,evidenceID:"synthetic-wall-U")],
            outdoorAirM3PerS:0.01,airDensityKgPerM3:1.2,airHeatCapacityJPerKgK:1000,
            internalSensibleW:20,solarSensibleW:0,explicitLatentW:0,conditionsEvidenceID:"synthetic-design-condition")
    }
    func testSuppliedConditionThermalUnitsAndModes() throws {
        let input=thermal(),heating=try HVACDesignLoadCalculator.calculate(input)
        XCTAssertEqual(heating.transmissionW,100,accuracy:1e-10)
        XCTAssertEqual(heating.outdoorAirSensibleW,240,accuracy:1e-10)
        XCTAssertEqual(heating.totalW,320,accuracy:1e-10)
        var cooling=input;cooling.mode = .cooling;cooling.outdoorC=40;cooling.explicitLatentW=50
        XCTAssertEqual(try HVACDesignLoadCalculator.calculate(cooling).totalW,410,accuracy:1e-10)
        XCTAssertTrue(try heating.isStale(for:cooling))
        XCTAssertFalse(try heating.isStale(for:input))
    }
    func testMissingThermalEvidenceAndNonfiniteValuesFail() throws {
        var input=thermal();input.conditionsEvidenceID=""
        XCTAssertThrowsError(try HVACDesignLoadCalculator.calculate(input))
        input=thermal();input.envelope[0].evidenceID=""
        XCTAssertThrowsError(try HVACDesignLoadCalculator.calculate(input))
        input=thermal();input.outdoorAirM3PerS = .nan
        XCTAssertThrowsError(try HVACDesignLoadCalculator.calculate(input))
        input=thermal();input.envelope.append(input.envelope[0])
        XCTAssertThrowsError(try HVACDesignLoadCalculator.calculate(input))
    }
}
