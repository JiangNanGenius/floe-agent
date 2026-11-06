import XCTest
import FloeManufacturingParameters
@testable import FloeManufacturingCore

final class ToolAssemblyTests: XCTestCase {
    func testTipFrameAndDistinctDiameterRadiusRoundTrip() throws {
        let assembly = MillingToolAssembly.demonstration(cuttingLengthMM:15)
        try assembly.validate(cuttingLengthMM:15)
        let data = try ManufacturingStudy.encoder.encode(assembly)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        XCTAssertEqual(json["shankDiameterMM"] as? Double,4)
        XCTAssertEqual((json["holderProfile"] as? [[Double]])?.first,[25,5])
        XCTAssertEqual(try JSONDecoder().decode(MillingToolAssembly.self,from:data),assembly)
        XCTAssertEqual(assembly.holderProfile[1].axialMM,assembly.holderProfile[2].axialMM,"a shoulder is not a duplicate point")
    }
    func testInvalidShapeAndBudgetDoNotBecomePartialSuccess() throws {
        var study = ManufacturingStudy.shaft(milled:true)
        let example = MillingToolAssembly.demonstration(cuttingLengthMM:15)
        for bad in [
            MillingToolAssembly(name:"bad",shankDiameterMM:0,holderProfile:example.holderProfile,clearanceMM:0.2),
            .init(name:"bad",shankDiameterMM:4,holderProfile:[.init(14,5),.init(20,5)],clearanceMM:0.2),
            .init(name:"bad",shankDiameterMM:4,holderProfile:[.init(25,5),.init(25,5)],clearanceMM:0.2),
            .init(name:"bad",shankDiameterMM:4,holderProfile:[.init(25,5),.init(35,5),.init(35,8)],clearanceMM:0.2),
            .init(name:"bad",shankDiameterMM:4,holderProfile:[.init(25,-1),.init(40,8)],clearanceMM:0.2)
        ] {
            study.millingAssembly = bad
            XCTAssertThrowsError(try study.validate())
        }
        study.millingAssembly = example; study.budget.maxCollisionQueries = 0
        XCTAssertThrowsError(try study.validate())
        study.budget.maxCollisionQueries = 500001
        XCTAssertThrowsError(try study.validate())
    }
    func testInactiveAssemblySettingsAreRetainedThenExplicitlyApplied() throws {
        let original = ManufacturingStudy.shaft(milled:true)
        var settings = original.parameterSnapshot()
        settings.set("millingAssembly.shankDiameterMM",.number(6))
        settings.set("budget.maxCollisionQueries",.integer(25000))
        settings.set("activeAssembly.vendorExtensions",.object(["fixtureNote":.array([.number(0),.integer(0),.null])]))
        let stored = try original.applyingParameters(settings)
        XCTAssertNil(stored.millingAssembly)
        XCTAssertEqual(stored.budget.maxCollisionQueries,25000,"the query budget also applies to cutter-only milling/A-C queries")
        XCTAssertEqual(stored.parameters?.value("millingAssembly.shankDiameterMM"),.number(6))
        var enabled = stored; enabled.millingAssembly = .demonstration(cuttingLengthMM:15)
        let applied = try enabled.applyingParameters(stored.parameterSnapshot())
        XCTAssertEqual(applied.millingAssembly?.shankDiameterMM,6)
        XCTAssertEqual(applied.budget.maxCollisionQueries,25000)
        XCTAssertNil(applied.parameters?.value("millingAssembly.shankDiameterMM"))
        XCTAssertEqual(applied.parameters?.value("activeAssembly.vendorExtensions"),settings.value("activeAssembly.vendorExtensions"))
    }
    func testLegacyInputIdentityHasNoNewOptionalFields() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource:"shaft-r1",withExtension:"json",subdirectory:"Fixtures"))
        let study = try JSONDecoder().decode(ManufacturingStudy.self,from:Data(contentsOf:url))
        try study.validate()
        XCTAssertNil(study.millingAssembly); XCTAssertNil(study.budget.maxCollisionQueries)
        XCTAssertEqual(try study.fingerprint(),"c3b0a169a8d4de515e641deba1a10f0cd826713e1684202805a6245426b02c0a")
    }
    func testNativeAssemblyReportsCoverageAndFindsHolderOnlyMidpathFixture() throws {
        var study = ManufacturingStudy.shaft(milled:true)
        study.milling.startZMM = 2; study.milling.endZMM = 36
        study.millingAssembly = .demonstration(cuttingLengthMM:15)
        study.fixtures = [.init(id:"holder-only",minMM:[35.5,-0.3,21.7],maxMM:[36.5,0.3,22.3])]
        let result = try NativeManufacturingEngine().compute(study,control:.init()).result
        XCTAssertNotNil(result.assemblyQueryCount)
        let holder = result.collisions.filter { $0.targetKind == "fixture" && $0.component == "holder-only" && $0.toolPart == "holder" }
        XCTAssertTrue(holder.contains { $0.state == "intersecting" },"the fixture is inside the midpath holder envelope")
        XCTAssertTrue(result.collisions.filter { $0.targetKind == "fixture" && $0.toolPart == "cutter" }.allSatisfy { $0.state == "clear" },"the cutting cylinder is well short of x35.5")
        XCTAssertTrue(holder.contains { ($0.firstPoseIndex ?? 0) > 0 })
    }
    func testNonCuttingShankCannotPassThroughRemainingMaterial() throws {
        var study = ManufacturingStudy.shaft(milled:true)
        study.milling.toolLengthMM = 0.5
        study.millingAssembly = .demonstration(cuttingLengthMM:0.5)
        let result = try NativeManufacturingEngine().compute(study,control:.init()).result
        let shank = result.collisions.filter { $0.targetKind == "stock" && $0.toolPart == "shank" }
        XCTAssertFalse(shank.isEmpty)
        XCTAssertTrue(shank.contains { $0.state == "intersecting" || $0.state == "uncertain" },"non-cutting contact must not be treated as removal or ignored")
    }
    func testPositiveCutterGapBelowRequiredClearanceIsReportedSeparately() throws {
        var study = ManufacturingStudy.shaft(milled:true)
        study.millingAssembly = .demonstration(cuttingLengthMM:15)
        study.millingAssembly?.clearanceMM = 0.5
        // Cutter radius2, axis+X, actual slot poses at Z=k+0.5. The box is
        // outside the cutter by0.25mm, inside its axial cutting span.
        study.fixtures = [.init(id:"small-gap",minMM:[10,2.25,22.45],maxMM:[11,2.35,22.55])]
        let result = try NativeManufacturingEngine().compute(study,control:.init()).result
        let cutter = try XCTUnwrap(result.collisions.first { $0.toolPart == "cutter" && $0.targetKind == "fixture" })
        XCTAssertEqual(cutter.state,"clearance",cutter.message)
        let gap = try XCTUnwrap(cutter.minimumGapLowerBoundMM)
        XCTAssertGreaterThan(gap,0); XCTAssertLessThan(gap,0.5)
    }
    func testAssemblyQueryBudgetRefusesWithoutSavingOverOldResult() throws {
        var study = ManufacturingStudy.shaft(milled:true)
        study.millingAssembly = .demonstration(cuttingLengthMM:15)
        study.fixtures = [.init(id:"query-work",minMM:[35.5,-0.3,21.7],maxMM:[36.5,0.3,22.3])]
        study.budget.maxCollisionQueries = 1
        XCTAssertThrowsError(try NativeManufacturingEngine().compute(study,control:.init())) { error in
            XCTAssertTrue(error.localizedDescription.lowercased().contains("budget"),error.localizedDescription)
        }
    }
    func testLegacyCutterOnlyResultCannotPretendAssemblyWasChecked() throws {
        var study = ManufacturingStudy.shaft(milled:true)
        let legacy = try NativeManufacturingEngine().compute(study,control:.init()).result
        study.millingAssembly = .demonstration(cuttingLengthMM:15)
        XCTAssertThrowsError(try legacy.validate(for:study))
    }
    func testACAssemblyUsesActualTiltedPoseCoverageAndPositiveCuttingDimensions() throws {
        var study = ManufacturingStudy.fiveAxis()
        study.millingAssembly = .demonstration(cuttingLengthMM:6)
        let result = try NativeManufacturingEngine().compute(study,control:.init()).result
        XCTAssertTrue(result.collisions.contains { $0.operation == "ac" && $0.toolPart == "holder" && $0.targetKind == "stock" })
        XCTAssertGreaterThan(result.assemblyQueryCount ?? 0,0)
        XCTAssertTrue(try XCTUnwrap(result.acPoses).contains { abs($0.axis[0]) > 0.1 || abs($0.axis[1]) > 0.1 })
        study.milling.toolRadiusMM = -1
        XCTAssertThrowsError(try study.validate())
    }
}
