import XCTest
import FloeManufacturingParameters
@testable import FloeManufacturingCore

final class CuttingIntegrationTests: XCTestCase {
    func testDisabledSpeedSettingsArePreservedAndDoNotAutoEnable() throws {
        var config = TurningCuttingParameters.researchExample
        config.maxSpindleRPM = 1600; config.feedMMPerRevolution = 0.07
        var original = ManufacturingStudy.shaft()
        var extras = ManufacturingParameterSet()
        extras.set("vendor.future",.object(["unknown":.array([.null,.integer(0),.number(0)])]))
        original.parameters = extras
        let disabled = try original.applyingTurningCutting(config,enabled:false)
        XCTAssertNil(disabled.turningCutting)
        XCTAssertEqual(disabled.configuredTurningCutting,config)
        let restored = try JSONDecoder().decode(ManufacturingStudy.self,from:disabled.encoded())
        XCTAssertNil(restored.turningCutting)
        let enabled = try restored.applyingTurningCutting(restored.configuredTurningCutting,enabled:true)
        XCTAssertEqual(enabled.turningCutting,config)
        XCTAssertNil(enabled.parameters?.value("machine.spindle.maxRPM"))
        XCTAssertEqual(enabled.parameters?.value("vendor.future"),extras.value("vendor.future"))
        var advanced = enabled.parameterSnapshot()
        advanced.set("machine.spindle.maxRPM",.number(1300))
        advanced.set("feeds.cutting.mmPerRevolution",.number(0.08))
        let edited = try enabled.applyingParameters(advanced)
        XCTAssertEqual(edited.turningCutting?.maxSpindleRPM,1300)
        XCTAssertEqual(edited.turningCutting?.feedMMPerRevolution,0.08)
    }

    func testActualNativePathsAreTimedWithoutChangingMaterialAndArchiveRejectsTampering() throws {
        let engine = NativeManufacturingEngine()
        let legacy = ManufacturingStudy.shaft()
        let baseline = try engine.compute(legacy,control:.init())
        var study = legacy
        study.turningCutting = .researchExample
        let artifact = try engine.compute(study,control:.init())
        let timeline = try XCTUnwrap(artifact.result.cuttingTimeline)
        XCTAssertGreaterThan(timeline.totalSeconds,0)
        XCTAssertFalse(timeline.segments.isEmpty)
        XCTAssertEqual(artifact.result.vertices,baseline.result.vertices)
        XCTAssertEqual(artifact.result.triangles,baseline.result.triangles)
        XCTAssertEqual(artifact.result.stages,baseline.result.stages)
        XCTAssertEqual(artifact.result.collisions,baseline.result.collisions)
        XCTAssertEqual(artifact.result.paths.map(\.points),baseline.result.paths.map(\.points))
        XCTAssertTrue(artifact.result.paths.allSatisfy { $0.feedMMPerMinute == nil })
        let export = try XCTUnwrap(try JSONSerialization.jsonObject(with:ManufacturingArchive.toolpath(artifact.result)) as? [String:Any])
        XCTAssertEqual(export["formatVersion"] as? Int,2)
        XCTAssertNotNil(export["cuttingTimeline"])
        XCTAssertTrue(try JSONSerialization.jsonObject(with:ManufacturingArchive.toolpath(baseline.result)) is [Any])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let url = directory.appendingPathComponent("speed.floemanufacturing")
        try ManufacturingArchive.save(study:study,artifact:artifact,to:url)
        let (savedStudy,savedArtifact) = try ManufacturingArchive.open(url)
        XCTAssertEqual(savedStudy,study); XCTAssertEqual(savedArtifact,artifact)
        var corrupt = artifact
        corrupt.result.cuttingTimeline?.totalSeconds += 1
        XCTAssertThrowsError(try corrupt.result.validate(for:study))
        XCTAssertThrowsError(try ManufacturingArchive.save(study:study,artifact:corrupt,to:url))
        let untouched = try ManufacturingArchive.open(url)
        XCTAssertEqual(untouched.1,artifact)
        study.turningCutting?.maxSpindleRPM = 1000
        let slower = try engine.compute(study,control:.init())
        XCTAssertGreaterThan(try XCTUnwrap(slower.result.cuttingTimeline).totalSeconds,timeline.totalSeconds)
        XCTAssertThrowsError(try artifact.result.validate(for:study))
    }
}
