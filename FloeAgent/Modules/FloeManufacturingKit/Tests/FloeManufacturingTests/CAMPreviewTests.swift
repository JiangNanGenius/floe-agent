import XCTest
@testable import FloeManufacturingCore

final class CAMPreviewTests:XCTestCase {
    func testFreshLatheHasCircularBlankAndActualInsertAtTheToolTip() throws {
        let study = ManufacturingStudy.turnMillCAM(),artifact = try NativeManufacturingEngine().compute(study,control:.init())
        let initial = try XCTUnwrap(artifact.result.frames?.first { $0.name == "initial" })
        let ring = initial.vertices.filter { hypot($0[0],$0[1])>1e-8 }
        XCTAssertGreaterThanOrEqual(ring.count,256)
        for point in ring { XCTAssertEqual(hypot(point[0],point[1]),study.stock.radiusMM,accuracy:1e-8) }
        let exactDisplay = ManufacturingDisplaySurface.mesh(initial.vertices,triangles:initial.triangles,cellSizeMM:study.stock.resolutionMM)
        XCTAssertTrue(exactDisplay.circularRings)
        XCTAssertEqual(exactDisplay.vertices,initial.vertices,"planar caps and circular rings must not be bowed by voxel fairing")
        XCTAssertEqual(exactDisplay.refinementPasses,0)
        let program = try CAMPreviewProgram(source:.study(study,artifact)),frame = try program.frame(at:1)
        let tool = try XCTUnwrap(frame.tools.first),pose = try XCTUnwrap(tool.displayFrame)
        XCTAssertEqual(tool.insertSetup?.insertShape,"D")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(tool.insertOutline).count,3)
        XCTAssertEqual(pose.translationMM,tool.tipMM)
        XCTAssertEqual(tool.rpm,900)
        XCTAssertGreaterThan(try XCTUnwrap(tool.phaseDegrees),360)
        XCTAssertEqual(frame.latheStockRadiusMM,12)
        XCTAssertEqual(frame.machine?.kind,.lathe)
        let displayed = ManufacturingDisplaySurface.mesh(artifact.result.vertices,triangles:artifact.result.triangles,cellSizeMM:study.stock.resolutionMM)
        let normals = ManufacturingDisplaySurface.normals(displayed.vertices,triangles:displayed.triangles,cellSizeMM:study.stock.resolutionMM,smoothing:true)
        let dots = displayed.vertices.indices.compactMap { i -> Double? in
            let p = displayed.vertices[i],n = normals[i],r = hypot(p[0],p[1])
            guard p[2]>3,p[2]<10,p[0] < -6,r>9 else { return nil }
            return (p[0]*n[0]+p[1]*n[1])/r
        }
        XCTAssertGreaterThan(dots.count,100)
        XCTAssertGreaterThan(dots.reduce(0,+)/Double(dots.count),0.985,"round uncut side must shade as a round surface, independent of long grid triangles")
    }
    func testCurrentStudyIdentityTimedTCPAndOperationNavigation() throws {
        var study = ManufacturingStudy.cuttingSpeedExample();study.name = "user-current-part"
        let result = try NativeManufacturingEngine().compute(study,control:.init()),program = try CAMPreviewProgram(source:.study(study,result))
        XCTAssertEqual(program.name,"user-current-part")
        XCTAssertEqual(program.metric,.seconds)
        let timeline = try XCTUnwrap(result.result.cuttingTimeline),t = timeline.totalSeconds*0.37
        let exact = try timeline.sample(atSeconds:t),frame = try program.frame(at:t),tool = try XCTUnwrap(frame.tools.first)
        XCTAssertEqual(tool.tipMM,exact.pointMM)
        XCTAssertEqual(tool.feedMMPerMinute,exact.feedMMPerMinute)
        XCTAssertEqual(program.paths.count,result.result.paths.count,"do not invent connectors")
        XCTAssertEqual(program.paths.flatMap(\.pointsMM),result.result.paths.flatMap(\.points))
        let chapter = try XCTUnwrap(program.chapters.first { ($0.end ?? 0)>($0.start ?? 0) })
        let range = try XCTUnwrap(chapter.start)...XCTUnwrap(chapter.end)
        XCTAssertGreaterThan(program.nextBoundary(from:range.lowerBound,forward:true,within:range),range.lowerBound)
        XCTAssertLessThanOrEqual(program.nextBoundary(from:range.upperBound,forward:true,within:range),range.upperBound)
        XCTAssertEqual(program.nextBoundary(from:range.lowerBound,forward:false,within:range),range.lowerBound)
        XCTAssertThrowsError(try program.frame(at:.nan))
        var changed = study;changed.stock.radiusMM += 1
        XCTAssertThrowsError(try CAMPreviewProgram(source:.study(changed,result)))
        let untimed = ManufacturingStudy.shaft(),untimedResult = try NativeManufacturingEngine().compute(untimed,control:.init())
        XCTAssertEqual(try CAMPreviewProgram(source:.study(untimed,untimedResult)).metric,.distance)
    }
    func testPerRevolutionPhaseUsesRadiusCoordinatesWithoutDiameterConversion() throws {
        var study = ManufacturingStudy.cuttingSpeedExample()
        study.turningCutting?.feedMode = .mmPerRevolution
        let artifact = try NativeManufacturingEngine().compute(study,control:.init()),program = try CAMPreviewProgram(source:.study(study,artifact))
        let timeline = try XCTUnwrap(artifact.result.cuttingTimeline),time = timeline.totalSeconds*0.4
        let sample = try timeline.sample(atSeconds:time),segment = timeline.segments[sample.segmentIndex]
        let feed = try XCTUnwrap(segment.feedMMPerRevolution)
        let distance = sqrt(zip(segment.startPointMM,sample.pointMM).reduce(0.0) { $0+pow($1.0-$1.1,2) })
        let before = timeline.segments.prefix(sample.segmentIndex).reduce(0.0) { $0+360*$1.lengthMM/($1.feedMMPerRevolution ?? feed) }
        let tool = try XCTUnwrap(program.frame(at:time).tools.first)
        XCTAssertEqual(try XCTUnwrap(tool.phaseDegrees),before+360*distance/feed,accuracy:1e-6)
        XCTAssertEqual(tool.tipMM,sample.pointMM)
        XCTAssertGreaterThan(try XCTUnwrap(tool.phaseDegrees),360)
    }
    func testFiveAxisUntimedGeometryRetainsAxesAndUnwrappedJoints() throws {
        let study = ManufacturingStudy.fiveAxis(),artifact = try NativeManufacturingEngine().compute(study,control:.init())
        let program = try CAMPreviewProgram(source:.study(study,artifact))
        XCTAssertEqual(program.metric,.distance)
        let poses = try XCTUnwrap(artifact.result.acPoses);XCTAssertFalse(poses.isEmpty)
        let end = try XCTUnwrap(program.frame(at:program.extent).tools.first)
        for (a,b) in zip(end.axis,try XCTUnwrap(poses.last).axis) { XCTAssertEqual(a,b,accuracy:1e-7) }
        XCTAssertEqual(end.joints,poses.last?.joints)
        XCTAssertNil(end.rpm)
        XCTAssertTrue(program.warnings.contains { $0.contains("not machining time") })
        let machine = try XCTUnwrap(program.frame(at:program.extent).machine)
        XCTAssertEqual(machine.kind,.acTableTable)
        let placed = machine.worldFromWorkpiece.applied(to:end.tipMM)
        let gauge = try XCTUnwrap(end.joints)
        for (a,b) in zip(placed,[gauge[0],gauge[1],gauge[2]-study.acMotion!.toolLengthMM]) { XCTAssertEqual(a,b,accuracy:1e-6) }
        let axisEnd = machine.worldFromWorkpiece.applied(to:end.axis),zero = machine.worldFromWorkpiece.applied(to:[0,0,0])
        for (a,b) in zip(zip(axisEnd,zero).map({ $0-$1 }),[0.0,0,1]) { XCTAssertEqual(a,b,accuracy:1e-6) }
        XCTAssertEqual(machine.joints,end.joints,"the physical table keeps the supplied unwrapped joints")
    }
    func testThreeAxisPreviewKeepsZVerticalAndDoesNotInventATurningSpindle() throws {
        let study = ManufacturingStudy.featureCAM(),artifact = try NativeManufacturingEngine().compute(study,control:.init())
        let program = try CAMPreviewProgram(source:.study(study,artifact)),frame = try program.frame(at:program.extent*0.2)
        XCTAssertFalse(frame.latheStock)
        XCTAssertEqual(frame.machine?.kind,.vertical3Axis)
        XCTAssertEqual(frame.machine?.worldFromWorkpiece,.identity)
        XCTAssertNil(frame.machine?.joints)
        XCTAssertEqual(frame.machine?.stockMinMM,study.stock.bounds.min)
        XCTAssertEqual(frame.tools.first?.axis,[0,0,1])
    }
    func testCellReuseWorldFramesAndTransferWithoutRecomputingCAM() throws {
        let project = VirtualMachineProject.demonstration(),artifact = try CellManufacturingEngine().compute(project.cell)
        let program = try CAMPreviewProgram(source:.cell(project,artifact)),replay = try VirtualCellReplay(project:project.cell,artifact:artifact)
        let front = try XCTUnwrap(artifact.schedule.steps.first { $0.stepID == "main-front-op" })
        let time = front.startSeconds+0.1,frame = try program.frame(at:time),snapshot = try replay.snapshot(at:time)
        for tool in snapshot.tools {
            let observed = try XCTUnwrap(frame.tools.first { $0.id == tool.stepID })
            for (a,b) in zip(observed.tipMM,tool.worldTipMM) { XCTAssertEqual(a,b,accuracy:1e-8) }
            for (a,b) in zip(observed.axis,tool.worldAxis) { XCTAssertEqual(a,b,accuracy:1e-8) }
        }
        XCTAssertEqual(program.paths.count,artifact.jobs.reduce(0) { $0+$1.artifact.result.paths.count })
        let transfer = try XCTUnwrap(artifact.schedule.transfers.first)
        let at = try program.frame(at:transfer.acquireSeconds)
        XCTAssertTrue(at.scene.bodies.contains { $0.role == "chuck" })
        XCTAssertTrue(program.chapters.contains { $0.name == "transfer" })
        let control = ComputationControl();control.cancel()
        XCTAssertThrowsError(try CAMPreviewProgram(source:.cell(project,artifact),control:control))
    }
    func testPortablePreviewPreservesMachineSetupViewStateAndSourceBinding() throws {
        var project = VirtualMachineProject.demonstration();project.scene.spindles[0].housingRadiusMM = 37
        let artifact = try CellManufacturingEngine().compute(project.cell),source = CAMPreviewSource.cell(project,artifact)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cam-preview-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let url = folder.appendingPathComponent("saved.floepreview"),state = Data("{\"position\":42.25}".utf8)
        try CAMPreviewArchive.save(source:source,viewState:state,to:url)
        let intact = try Data(contentsOf:url),cancelled = ComputationControl();cancelled.cancel()
        XCTAssertThrowsError(try CAMPreviewArchive.save(source:source,viewState:state,to:url,control:cancelled))
        XCTAssertEqual(try Data(contentsOf:url),intact)
        let opened = try CAMPreviewArchive.open(url)
        XCTAssertEqual(opened.viewState,state)
        guard case .cell(let restored,let result) = opened.source else { return XCTFail("cell source lost") }
        XCTAssertEqual(restored.scene.spindles[0].housingRadiusMM,37)
        XCTAssertEqual(result.inputSHA256,artifact.inputSHA256)
        XCTAssertEqual(try CAMPreviewProgram(source:source).sourceKey,try CAMPreviewProgram(source:opened.source).sourceKey)
        XCTAssertThrowsError(try CAMPreviewArchive.save(source:source,viewState:Data(repeating:0,count:32_769),to:url))
        var bytes = try Data(contentsOf:url)
        let original = String(decoding:bytes,as:UTF8.self)
        let text = original.replacingOccurrences(of:"\"housingRadiusMM\":37",with:"\"housingRadiusMM\":38")
        XCTAssertNotEqual(original,text)
        bytes = Data(text.utf8);try bytes.write(to:url)
        XCTAssertThrowsError(try CAMPreviewArchive.open(url))
    }
}
