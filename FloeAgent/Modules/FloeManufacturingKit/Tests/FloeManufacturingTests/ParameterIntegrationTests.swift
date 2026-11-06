import XCTest
import FloeManufacturingParameters
@testable import FloeManufacturingCore

final class ParameterIntegrationTests: XCTestCase {
    private let catalog = ManufacturingParameterCatalog.standard
    func testEveryAdvertisedNativeBindingHasAnActualTypedField() throws {
        var study = ManufacturingStudy.fiveAxis()
        study.millingAssembly = .demonstration(cuttingLengthMM:study.milling.toolLengthMM)
        study.turningCutting = .researchExample
        study.turningSetup = .init()
        study.stock.minMM = study.stock.bounds.min; study.stock.maxMM = study.stock.bounds.max
        study.cam = ManufacturingStudy.featureCAM().cam
        study.cam!.tools[0].tipAngleDegrees = 118; study.cam!.tools[0].gaugeLengthMM = 50
        study.cam!.tools[0].assembly = .demonstration(cuttingLengthMM:study.cam!.tools[0].cuttingLengthMM)
        study.cam!.operations[0].cutting = .init(mode:"perTooth",toolSpindleRPM:2000,feedPerToothMM:0.025,feedPerRevolutionMM:0.1)
        study.cam!.operations[0].acSeed = [0,0,50,0,0]
        for descriptor in catalog.parameters where descriptor.support == .previewUsed {
            guard let key = descriptor.binding else { XCTFail("preview parameter has no binding: \(descriptor.id)"); continue }
            let scope:ManufacturingParameterScope = key.hasPrefix("camTool.") ? .tool(study.cam!.tools[0].id) : key.hasPrefix("camOperation.") ? .operation(study.cam!.operations[0].id) : .study
            XCTAssertNotNil(study.boundParameter(key,scope:scope),"unimplemented binding: \(key)")
        }
        for study in [ManufacturingStudy.shaft(),.shaft(milled:true),.fiveAxis()] {
            let snapshot = study.parameterSnapshot()
            let applied = try study.applyingParameters(snapshot)
            XCTAssertEqual(applied.parameterSnapshot(),snapshot)
        }
    }
    func testAdvancedDepthAffectsNativeRemovalAndBasicEditRemainsAuthoritative() throws {
        let original = ManufacturingStudy.shaft(milled:true)
        let descriptor = try XCTUnwrap(catalog.parameters.first { $0.binding == "milling.depthMM" })
        var set = original.parameterSnapshot(); set.set(descriptor.id,.number(1))
        var changed = try original.applyingParameters(set)
        XCTAssertEqual(changed.milling.depthMM,1)
        XCTAssertNil(changed.parameters?.value(descriptor.id),"active values must not get a second conflicting storage owner")
        let engine = NativeManufacturingEngine()
        let before = try engine.compute(original,control:.init())
        let after = try engine.compute(changed,control:.init())
        XCTAssertGreaterThan(after.result.remainingMM3,before.result.remainingMM3)
        changed.milling.depthMM = 1.5
        XCTAssertEqual(changed.parameterSnapshot().value(descriptor.id),.number(1.5))
        XCTAssertThrowsError(try ManufacturingArchive.save(study:changed,artifact:after,to:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
    }
    func testRareAndUnknownNestedConfigurationSurvivesNativeCalculationAndArchive() throws {
        let base = ManufacturingStudy.shaft()
        let rare = try XCTUnwrap(catalog.parameters.first { $0.rare && $0.support == .configurationOnly && $0.kind == .string })
        let unknown:ManufacturingParameterValue = .object([
            "future":.array([.integer(0),.number(0),.null,.boolean(false)]),
            "vendor":.object(["setting":.string("preserve me")])
        ])
        var set = base.parameterSnapshot()
        set.set(rare.id,.string("qualification-rare-setting")); set.set("vendor.extension.future",unknown)
        let study = try base.applyingParameters(set)
        let engine = NativeManufacturingEngine()
        let baseline = try engine.compute(base,control:.init())
        let artifact = try engine.compute(study,control:.init())
        XCTAssertNotEqual(artifact.inputSHA256,baseline.inputSHA256)
        XCTAssertEqual(artifact.result.vertices,baseline.result.vertices)
        XCTAssertEqual(artifact.result.paths,baseline.result.paths,"stored configuration must not pretend to alter cutting")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let url = directory.appendingPathComponent("rare.floemanufacturing")
        try ManufacturingArchive.save(study:study,artifact:artifact,to:url)
        let (reopened,_) = try ManufacturingArchive.open(url)
        XCTAssertEqual(reopened.parameters?.value(rare.id),.string("qualification-rare-setting"))
        XCTAssertEqual(reopened.parameters?.value("vendor.extension.future"),unknown)
        XCTAssertEqual(try JSONDecoder().decode(ManufacturingStudy.self,from:study.encoded()),study)
    }
    func testConflictingBoundValueIsRejectedInsteadOfSilentlyIgnored() throws {
        var study = ManufacturingStudy.shaft()
        let descriptor = try XCTUnwrap(catalog.parameters.first { $0.binding == "stock.radiusMM" })
        var set = ManufacturingParameterSet(); set.set(descriptor.id,.number(13))
        study.parameters = set
        XCTAssertThrowsError(try study.validate())
    }
}
