import XCTest
@testable import FloeManufacturingCore

final class ManufacturingTests: XCTestCase {
    func testRadiusContractAndShoulders() throws {
        let study = ManufacturingStudy.shaft()
        try study.validate()
        let decoded = try JSONDecoder().decode(ManufacturingStudy.self,from:study.encoded())
        XCTAssertEqual(decoded.profile[0].radiusMM,10)
        XCTAssertEqual(decoded.profile[1].zMM,decoded.profile[2].zMM)
        XCTAssertEqual(decoded,study)
        var diameterAsRadius = study; diameterAsRadius.profile[0].radiusMM = 20
        XCTAssertThrowsError(try diameterAsRadius.validate())
    }
    func testBudgetAndNonfiniteInputRejectWithoutChangingInput() throws {
        var study = ManufacturingStudy.shaft(); study.stock.resolutionMM = 0.1
        let original = try study.encoded()
        XCTAssertThrowsError(try study.validate()); XCTAssertEqual(try study.encoded(),original)
        study = .shaft(); study.turning.stepOverMM = 0
        XCTAssertThrowsError(try study.validate())
        study = .shaft(); study.profile[0].radiusMM = .nan
        XCTAssertThrowsError(try study.validate())
        study = .shaft(); study.turning.toolNoseRadiusMM = 1.2
        XCTAssertThrowsError(try study.validate(),"unsupported nose geometry must not be silently ignored")
    }
    func testActualNativeTurningThenMillingShareStockAndReplay() throws {
        let engine = NativeManufacturingEngine()
        let turned = try engine.compute(.shaft(),control:.init())
        let milled = try engine.compute(.shaft(milled:true),control:.init())
        XCTAssertGreaterThan(turned.result.removedMM3,0)
        XCTAssertLessThan(milled.result.remainingMM3,turned.result.remainingMM3)
        XCTAssertGreaterThan(milled.result.paths.count,0)
        XCTAssertGreaterThan(milled.result.frames?.count ?? 0,1)
        XCTAssertEqual(milled.result.stages.reduce(0) { $0+$1.removedMM3 },milled.result.removedMM3,accuracy:1e-6,"phase removals must sum to total removal in the same volume representation")
        XCTAssertTrue(milled.result.collisions.allSatisfy { ["clear","intersecting","uncertain"].contains($0.state) })
        let stl = try ManufacturingArchive.stl(milled.result)
        XCTAssertEqual(stl.count,84+50*milled.result.triangles.count)
    }
    func testPhysicalRotaryTravelIsNotShortened() throws {
        let motion = ManufacturingStudy.ACMotion(start:[7,0,10,30,179],end:[7,0,10,30,-179],toolLengthMM:6,steps:8)
        let poses = try NativeManufacturingEngine().acMotion(motion)
        XCTAssertEqual(poses.count,9)
        XCTAssertEqual(poses.first!.joints[4],179,accuracy:1e-8)
        XCTAssertEqual(poses.last!.joints[4],-179,accuracy:1e-8)
        XCTAssertEqual(poses[4].joints[4],0,accuracy:1e-8)
        XCTAssertTrue(poses.allSatisfy { abs($0.axis.reduce(0) { $0+$1*$1 }-1) < 1e-5 })
    }
    func testUnreachablePhysicalGaugePositionRejects() throws {
        let motion = ManufacturingStudy.ACMotion(start:[10_000,0,10,30,0],end:[10_001,0,10,30,1],toolLengthMM:6,steps:8)
        XCTAssertThrowsError(try NativeManufacturingEngine().acMotion(motion))
    }
    func testNonCuttingMotionPreservesVoxelStockVolume() throws {
        var study = ManufacturingStudy.fiveAxis()
        study.acMotion = .init(start:[0,0,100,30,0],end:[1,0,100,35,2],toolLengthMM:40,steps:8)
        let result = try NativeManufacturingEngine().compute(study,control:.init()).result
        XCTAssertEqual(result.removedMM3,0,accuracy:1e-9)
        XCTAssertEqual(result.remainingMM3,result.initialMM3,accuracy:1e-9)
    }
    func testStockBoundaryMeshHasPairedEdges() throws {
        let result = try NativeManufacturingEngine().compute(.fiveAxis(),control:.init()).result
        var edges = [String:Int]()
        for t in result.triangles {
            for i in 0..<3 {
                let a = min(t[i],t[(i+1)%3]), b = max(t[i],t[(i+1)%3])
                edges["\(a):\(b)",default:0] += 1
            }
        }
        XCTAssertTrue(edges.values.allSatisfy { $0 == 2 },"stock-domain boundaries must be closed by the native generator")
    }
    func testMidpathFixtureDoesNotBecomeFalseClearance() throws {
        let engine = NativeManufacturingEngine()
        var study = ManufacturingStudy.shaft(milled:true)
        let baseline = try engine.compute(study,control:.init()).result
        let segments = baseline.paths.filter { $0.kind.lowercased().contains("mill") || $0.kind.lowercased().contains("slot") }.flatMap { path in zip(path.points,path.points.dropFirst()).map { ($0.0,$0.1) } }
        guard let segment = segments.max(by:{ distance($0.0,$0.1) < distance($1.0,$1.1) }) else { return XCTFail("actual milling path missing") }
        let midpoint = zip(segment.0,segment.1).map { ($0.0+$0.1)/2 }
        study.fixtures = [.init(id:"midpath-obstacle",minMM:midpoint.map { $0-0.1 },maxMM:midpoint.map { $0+0.1 })]
        let checked = try engine.compute(study,control:.init()).result
        XCTAssertFalse(checked.collisions.isEmpty)
        XCTAssertTrue(checked.collisions.contains { $0.state == "intersecting" || $0.state == "uncertain" },"midpath obstacle cannot be reported as clear")
    }
    func testNativeCancellationAfterObservedProgressDoesNotReturnArtifact() throws {
        let trigger = CancelTrigger()
        let control = ComputationControl { fraction,_ in if fraction > 0 { trigger.fire() } }
        trigger.install(control)
        var study = ManufacturingStudy.shaft(milled:true); study.turning.enabled = false
        XCTAssertThrowsError(try NativeManufacturingEngine().compute(study,control:control)) { error in
            guard case ManufacturingError.cancelled = error else { return XCTFail("unexpected error: \(error)") }
        }
        XCTAssertTrue(trigger.observed)
    }
    func testAssemblyCollisionPhaseCancellationDoesNotReturnArtifact() throws {
        let trigger = CancelTrigger()
        let control = ComputationControl { _,phase in if phase.contains("assembly") { trigger.fire() } }
        trigger.install(control)
        XCTAssertThrowsError(try NativeManufacturingEngine().compute(.holderInterference(),control:control)) { error in
            guard case ManufacturingError.cancelled = error else { return XCTFail("unexpected error: \(error)") }
        }
        XCTAssertTrue(trigger.observed,"the new collision phase must reach the cancellation callback")
    }
    func testAtomicArchiveReopenTamperAndStaleSavePreservesSavedBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let study = ManufacturingStudy.shaft(), artifact = try NativeManufacturingEngine().compute(study,control:.init())
        let path = directory.appendingPathComponent("study.floemanufacturing")
        try ManufacturingArchive.save(study:study,artifact:artifact,to:path)
        let original = try Data(contentsOf:path)
        let (restored,reopened) = try ManufacturingArchive.open(path)
        XCTAssertEqual(restored,study); XCTAssertEqual(reopened,artifact)
        var changed = study; changed.turning.allowanceMM += 0.1
        XCTAssertThrowsError(try ManufacturingArchive.save(study:changed,artifact:artifact,to:path))
        XCTAssertEqual(try Data(contentsOf:path),original)
        var json = try JSONSerialization.jsonObject(with:original) as! [String:Any]
        var a = json["artifact"] as! [String:Any]; a["elapsedSeconds"] = 999; json["artifact"] = a
        try JSONSerialization.data(withJSONObject:json).write(to:path,options:.atomic)
        XCTAssertThrowsError(try ManufacturingArchive.open(path))
    }
    func testServiceRejectsLateResultAfterCancellation() async throws {
        let study = ManufacturingStudy.shaft()
        let native = try NativeManufacturingEngine().compute(study,control:.init())
        let service = ManufacturingService(engine:LateEngine(artifact:native))
        let task = Task { try await service.calculate(study) }
        try await Task.sleep(for:.milliseconds(10)); task.cancel()
        do { _ = try await task.value; XCTFail("late native result accepted") }
        catch {
            if error is CancellationError {} else if case ManufacturingError.cancelled = error {} else { XCTFail("unexpected rejection: \(error)") }
        }
        let count = await service.activeCount
        XCTAssertEqual(count,0)
    }
}

private func distance(_ a:[Double],_ b:[Double]) -> Double { zip(a,b).reduce(0) { $0+pow($1.0-$1.1,2) } }

private final class CancelTrigger: @unchecked Sendable {
    private let lock = NSLock()
    private weak var control: ComputationControl?
    private var didObserve = false
    var observed: Bool { lock.withLock { didObserve } }
    func install(_ control:ComputationControl) { lock.withLock { self.control = control } }
    func fire() { let current = lock.withLock { didObserve = true; return control }; current?.cancel() }
}
private struct LateEngine: ManufacturingComputing {
    var artifact: ManufacturingArtifact
    func compute(_ study:ManufacturingStudy,control:ComputationControl) throws -> ManufacturingArtifact {
        Thread.sleep(forTimeInterval:0.08)
        return artifact // Deliberately ignores cancellation to exercise the service fence.
    }
}
