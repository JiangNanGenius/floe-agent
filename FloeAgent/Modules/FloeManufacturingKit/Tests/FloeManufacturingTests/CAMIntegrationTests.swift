import XCTest
import FloeManufacturingParameters
@testable import FloeManufacturingCore

final class CAMIntegrationTests:XCTestCase {
    func testDisabledDraftPreservesSettingsWithoutBlockingOtherOperations() throws {
        var study = ManufacturingStudy.featureCAM()
        var parked = ManufacturingCAM.Operation(id:"parked-surface",name:"Await mesh",strategy:"surfaceRaster",toolID:"unassigned")
        parked.enabled = false; parked.depthMM = 2.75
        study.cam!.operations.append(parked)
        try study.validate()
        let input = try study.cam!.nativeInput()
        XCTAssertEqual(input.operations.last,parked)
        XCTAssertEqual(try JSONDecoder().decode(ManufacturingStudy.self,from:study.encoded()),study)
        study.cam!.operations[3].enabled = true
        XCTAssertThrowsError(try study.validate())
        var setup = TurningSetup(); setup.faceEnabled = false; setup.roughEnabled = false; setup.profileEnabled = false
        let saved = try ManufacturingStudy.shaft().applyingTurningSetup(setup,enabled:false)
        XCTAssertEqual(saved.configuredTurningSetup,setup)
        XCTAssertThrowsError(try saved.applyingTurningSetup(setup,enabled:true))
    }
    func testToolAndOperationOwnershipAndUnitBoundary() throws {
        var study = ManufacturingStudy.featureCAM()
        let toolID = study.cam!.tools[0].id, opID = study.cam!.operations[1].id
        var toolSet = study.parameterSnapshot(scope:.tool(toolID))
        toolSet.set("cam.tool.flutes",.integer(5))
        toolSet.set("vendor.tool.future",.object(["kept":.array([.integer(0),.null,.boolean(false)])]))
        study = try study.applyingParameters(toolSet,scope:.tool(toolID))
        var opSet = study.parameterSnapshot(scope:.operation(opID))
        opSet.set("cam.operation.cutting.toolSpindleRPM",.number(3000))
        opSet.set("vendor.operation.future",.string("not geometry"))
        study = try study.applyingParameters(opSet,scope:.operation(opID))
        let input = try XCTUnwrap(study.cam).nativeInput()
        XCTAssertEqual(input.operations[1].feedMMPerMinute,375,accuracy:1e-12)
        XCTAssertEqual(input.operations[1].plungeFeedMMPerMinute,80,"cut-feed conversion must not overwrite plunge")
        XCTAssertEqual(study.cam!.operations[0].feedMMPerMinute,200)
        XCTAssertNil(input.tools[0].parameters)
        XCTAssertNil(input.operations[1].parameters)
        XCTAssertNotNil(study.cam!.tools[0].parameters?.value("vendor.tool.future"))
        XCTAssertNil(study.cam!.tools[1].parameters?.value("vendor.tool.future"))
        XCTAssertEqual(try JSONDecoder().decode(ManufacturingStudy.self,from:study.encoded()),study)
        XCTAssertNotNil(study.cam!.operations[1].parameters?.value("vendor.operation.future"))
        XCTAssertNil(study.parameters?.value("cam.tool.flutes"))
        var invalid = study; invalid.cam!.tools[0].flutes = nil
        XCTAssertThrowsError(try invalid.validate())
    }
    func testActualOrderedCAMSharedMaterialTimingAndArchive() throws {
        let study = ManufacturingStudy.featureCAM()
        let artifact = try NativeManufacturingEngine().compute(study,control:.init())
        let reports = try XCTUnwrap(artifact.result.camReport)
        XCTAssertEqual(reports.map(\.operationID),["face-1","pocket-1","holes-1"])
        XCTAssertEqual(try XCTUnwrap(artifact.result.analyticInitialMM3),2560,accuracy:1e-9)
        XCTAssertGreaterThan(reports[0].removedMM3,0)
        XCTAssertGreaterThan(reports[1].removedMM3,0)
        XCTAssertGreaterThan(reports[2].removedMM3,0)
        XCTAssertEqual(reports[0].remainingMM3-reports[1].removedMM3,reports[1].remainingMM3,accuracy:0.01)
        XCTAssertEqual(reports[1].remainingMM3-reports[2].removedMM3,reports[2].remainingMM3,accuracy:0.01)
        let timeline = try XCTUnwrap(artifact.result.cuttingTimeline)
        XCTAssertEqual(timeline.formatVersion,2)
        XCTAssertTrue(timeline.excludedPathIndices.isEmpty)
        XCTAssertGreaterThan(timeline.totalSeconds,0)
        XCTAssertTrue(artifact.result.paths.contains { $0.moveType == "rapid" })
        XCTAssertTrue(artifact.result.paths.contains { $0.moveType == "retract" })
        let dwells = artifact.result.paths.filter { $0.moveType == "dwell" }
        XCTAssertEqual(dwells.count,2)
        XCTAssertEqual(dwells.reduce(0) { $0+($1.dwellSeconds ?? 0) },0.4,accuracy:1e-12)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let url = directory.appendingPathComponent("operations.floemanufacturing")
        try ManufacturingArchive.save(study:study,artifact:artifact,to:url)
        let reopened = try ManufacturingArchive.open(url)
        XCTAssertEqual(reopened.0,study); XCTAssertEqual(reopened.1,artifact)
        var corrupt = artifact.result; corrupt.camReport?.removeLast()
        XCTAssertThrowsError(try corrupt.validate(for:study))
        corrupt = artifact.result; corrupt.paths[0].toolID = "wrong-tool"
        XCTAssertThrowsError(try corrupt.validate(for:study))
    }
    func testToolAxisInterpolationHasBoundedAngularTravelAndRejectsAmbiguity() throws {
        let a = [1.0,0,0], b = [0.0,0,1]
        let quarter = try ToolAxisInterpolation.interpolate(a,b,fraction:0.25)
        XCTAssertEqual(quarter[0],cos(.pi/8),accuracy:1e-12)
        XCTAssertEqual(quarter[2],sin(.pi/8),accuracy:1e-12)
        XCTAssertThrowsError(try ToolAxisInterpolation.interpolate(a,[-1,0,0],fraction:0.5))
        XCTAssertThrowsError(try ToolAxisInterpolation.interpolate([0,0,0],b,fraction:0.5))
        XCTAssertThrowsError(try ToolAxisInterpolation.interpolate(a,b,fraction:.nan))
    }
    func testExplicitDwellAndPerPathRapidTiming() throws {
        let paths:[ManufacturingResult.Path] = [
            .init(kind:"cam-rapid",points:[[0,0,3],[10,0,3]],feedMMPerMinute:600,operationID:"hole",toolID:"drill",moveType:"rapid"),
            .init(kind:"cam-dwell",points:[[10,0,3]],operationID:"hole",toolID:"drill",moveType:"dwell",dwellSeconds:2.5),
            .init(kind:"cam-retract",points:[[10,0,3],[10,0,13]],feedMMPerMinute:300,operationID:"hole",toolID:"drill",moveType:"retract")
        ]
        let time = try CuttingTimeline.plan(paths:paths,turning:nil,legacyTurningFeed:120,maxSegments:100,includeCAM:true)
        XCTAssertEqual(time.totalSeconds,5.5,accuracy:1e-12)
        XCTAssertEqual(time.totalDistanceMM,20,accuracy:1e-12)
        let dwell = try time.sample(atSeconds:2)
        XCTAssertEqual(dwell.pointMM,[10,0,3]); XCTAssertEqual(dwell.feedMMPerMinute,0)
        XCTAssertEqual(try time.sample(atSeconds:5.5).pointMM,[10,0,13])
        var corrupt = time; corrupt.segments[1].dwellSeconds = 9
        XCTAssertThrowsError(try corrupt.validate(paths:paths))
    }
    func testTurningAndCAMUseTheSameRoundWorkpiece() throws {
        let study = ManufacturingStudy.turnMillCAM()
        let result = try NativeManufacturingEngine().compute(study,control:.init()).result
        let firstCAM = try XCTUnwrap(result.stages.firstIndex { $0.name == "cam-side-face" })
        XCTAssertGreaterThan(firstCAM,0)
        XCTAssertEqual(result.stages[firstCAM-1].name,"milling-slot")
        let reports = try XCTUnwrap(result.camReport)
        XCTAssertEqual(reports.map(\.operationID),["side-face","axial-hole"])
        XCTAssertGreaterThan(reports[0].removedMM3,0)
        XCTAssertGreaterThan(reports[1].removedMM3,0)
        XCTAssertEqual(result.stages[firstCAM-1].remainingMM3-reports[0].removedMM3,reports[0].remainingMM3,accuracy:0.01)
        XCTAssertEqual(result.remainingMM3,reports[1].remainingMM3,accuracy:0.01)
        XCTAssertTrue(result.paths.contains { $0.kind == "turning-profile" })
        XCTAssertTrue(result.paths.contains { $0.kind == "milling-slot" })
    }
    func testAllFiveHoleCyclesPreserveExplicitPlungeAndReturnRates() throws {
        for cycle in ["drill","counterBore","peck","chipBreak","bore"] {
            var study = ManufacturingStudy.featureCAM()
            var op = study.cam!.operations[2]
            op.cycle = cycle; op.holesUVMM = [[5,0]]
            study.cam!.operations = [op]
            let result = try NativeManufacturingEngine().compute(study,control:.init()).result
            XCTAssertGreaterThan(result.removedMM3,0,cycle)
            let plunges = result.paths.filter { $0.moveType == "plunge" }
            XCTAssertFalse(plunges.isEmpty,cycle)
            XCTAssertTrue(plunges.allSatisfy { $0.feedMMPerMinute == op.plungeFeedMMPerMinute },cycle)
            if cycle == "counterBore" { XCTAssertTrue(result.paths.contains { $0.moveType == "dwell" },cycle) }
            else { XCTAssertFalse(result.paths.contains { $0.moveType == "dwell" },cycle) }
            if cycle == "bore" { XCTAssertTrue(result.paths.contains { $0.moveType == "cut" && $0.feedMMPerMinute == op.feedMMPerMinute },cycle) }
        }
    }
    func testCAMFixtureCollisionBetweenExportedEndpoints() throws {
        var study = ManufacturingStudy.featureCAM()
        var tool = ManufacturingCAM.Tool.researchExample(id:"small-flat")
        tool.diameterMM = 0.04; tool.cuttingLengthMM = 1.5
        var op = ManufacturingCAM.Operation(id:"mid-contact",name:"Midpoint contact",strategy:"face",toolID:tool.id)
        op.frame.originMM = [0,0,8]; op.minUVMM = [-1,0]; op.maxUVMM = [1,0.1]
        op.stepOverMM = 0.1; op.depthMM = 1
        study.cam = .init(tools:[tool],operations:[op])
        study.fixtures = [.init(id:"between-endpoints",minMM:[0.098,-0.002,7.2],maxMM:[0.102,0.002,7.3])]
        let result = try NativeManufacturingEngine().compute(study,control:.init()).result
        for point in result.paths.flatMap(\.points) {
            XCTAssertGreaterThan(hypot(point[0]-0.1,point[1]),0.024,"fixture deliberately misses every exported endpoint")
        }
        XCTAssertTrue(result.collisions.contains { $0.component == "between-endpoints" && $0.toolPart == "cutter" && $0.state == "intersecting" },"actual interior samples must find the contact")
    }
    func testOperationIDContainingCancelDoesNotHideAnActualFailure() throws {
        var study = ManufacturingStudy.featureCAM()
        var op = study.cam!.operations[1]; op.id = "cancel-test"; op.radiusMM = 1
        study.cam!.operations = [op]
        do { _ = try NativeManufacturingEngine().compute(study,control:.init()); XCTFail("too-small pocket must fail") }
        catch ManufacturingError.native(let message) { XCTAssertTrue(message.contains("pocket too small")) }
        catch { XCTFail("operation identity must not turn an error into cancellation: \(error)") }
    }
    func testSurfaceInputAndUnsupportedOrBudgetResultsAreExplicit() throws {
        let engine = NativeManufacturingEngine()
        let surface = try engine.compute(.surfaceCAM(),control:.init())
        XCTAssertEqual(surface.result.camReport?.first?.strategy,"surfaceRaster")
        XCTAssertGreaterThan(surface.result.removedMM3,0)
        XCTAssertTrue(surface.result.paths.filter { $0.moveType == "cut" }.allSatisfy { $0.toolAxes?.count == $0.points.count })
        var study = ManufacturingStudy.featureCAM()
        study.budget.maxPoses = 2
        XCTAssertThrowsError(try engine.compute(study,control:.init()))
        study = .featureCAM(); study.budget.maxCollisionQueries = 1
        // The vise below the block is provably clear by broad phase: no Parry query is spent.
        let broadPhase = try engine.compute(study,control:.init())
        XCTAssertEqual(broadPhase.result.assemblyQueryCount,0)
        study.fixtures = [.init(id:"query-budget-contact",minMM:[-0.1,-0.1,7.2],maxMM:[0.1,0.1,7.6])]
        do { _ = try engine.compute(study,control:.init()); XCTFail("actual overlapping query must exhaust the budget") }
        catch ManufacturingError.native(let message) { XCTAssertTrue(message.contains("maxCollisionQueries")) }
        catch { XCTFail("expected an explicit collision budget error: \(error)") }
        study = .surfaceCAM(); study.cam!.partMesh = nil
        XCTAssertThrowsError(try engine.compute(study,control:.init()))
        study = .featureCAM(); study.turning.enabled = true
        XCTAssertThrowsError(try study.validate())
        let control = ComputationControl(); control.cancel()
        XCTAssertThrowsError(try engine.compute(.featureCAM(),control:control))
    }
    func testSelectedTurningReceiptAndDirectionalFeedTiming() throws {
        let engine = NativeManufacturingEngine()
        let study = ManufacturingStudy.selectedTurning()
        let artifact = try engine.compute(study,control:.init())
        XCTAssertNotNil(artifact.result.turningSetupReceipt)
        XCTAssertFalse(artifact.result.paths.contains { $0.kind == "turning-face" })
        XCTAssertTrue(artifact.result.paths.contains { $0.kind == "turning-rough" })
        for path in artifact.result.paths {
            let feed = try XCTUnwrap(path.feedMMPerMinute)
            for (a,b) in zip(path.points,path.points.dropFirst()) {
                let dx = abs(a[0]-b[0]), dz = abs(a[2]-b[2]), length = hypot(dx,dz)
                if length > 1e-7 {
                    XCTAssertLessThanOrEqual(feed*dx/length,80+1e-5)
                    XCTAssertLessThanOrEqual(feed*dz/length,160+1e-5)
                }
            }
        }
        var timed = study
        timed.turningCutting = .init(spindleMode:.fixedRPM,feedMode:.mmPerMinute,spindleRPM:900,surfaceSpeedMPerMinute:120,maxSpindleRPM:3000,feedMMPerRevolution:0.1)
        let result = try engine.compute(timed,control:.init()).result
        let expected = result.paths.reduce(0.0) { sum,path in
            sum+zip(path.points,path.points.dropFirst()).reduce(0.0) { value,ab in value+60*hypot(ab.0[0]-ab.1[0],ab.0[2]-ab.1[2])/path.feedMMPerMinute! }
        }
        XCTAssertEqual(try XCTUnwrap(result.cuttingTimeline).totalSeconds,expected,accuracy:1e-6)
        var corrupt = artifact.result; corrupt.turningSetupReceipt = nil
        XCTAssertThrowsError(try corrupt.validate(for:study))
        let disabled = try study.applyingTurningSetup(study.turningSetup!,enabled:false)
        XCTAssertNil(disabled.turningSetup)
        XCTAssertEqual(disabled.configuredTurningSetup,study.turningSetup)
    }
}
