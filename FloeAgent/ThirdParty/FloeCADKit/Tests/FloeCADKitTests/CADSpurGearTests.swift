import Foundation
import XCTest
import simd
@testable import FloeCAD

@MainActor
final class CADSpurGearTests: XCTestCase {
    private var directory: URL!
    private var documents: [FloeCADDocument]=[]
    override func setUp() async throws {
        directory=FileManager.default.temporaryDirectory.appendingPathComponent("SpurGears-\(UUID())")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    }
    override func tearDown() async throws {
        for d in documents { d.close() }
        if let directory { try FileManager.default.removeItem(at:directory) }
    }
    private func document() async throws -> FloeCADDocument {
        let d=try await FloeCADDocument.create(at:directory.appendingPathComponent("\(UUID()).floecad"),name:"Spur gear")
        documents.append(d);return d
    }
    private func run(_ d:FloeCADDocument,_ action:String,_ args:[String:Any]=[:]) throws -> [String:Any] {
        let r=CADParameterService(document:d).handle(action:action,args:args)
        XCTAssertEqual(r["ok"] as? Bool,true,"\(r)");return r
    }
    private func node(_ d:FloeCADDocument,_ reply:[String:Any]) throws -> FeatureNode {
        let id=try XCTUnwrap(UUID(uuidString:try XCTUnwrap(reply["feature_id"] as? String)))
        return try XCTUnwrap(d.session.document.features.node(FeatureID(raw:id)))
    }
    private func handle(_ d:FloeCADDocument,_ id:BodyID) throws -> BRepHandle {
        try XCTUnwrap(d.session.document.body(with:id)?.brep)
    }
    private func assertNative(_ h:BRepHandle,module:Double=2,teeth:Int=20,width:Double=8,bore:Double=10) throws {
        let p=module*Double(teeth)/2
        let actual=try OCCTKernel.spurGearMeasurements(h,pitchRadius:p)
        XCTAssertEqual(actual.teeth,teeth)
        XCTAssertEqual(actual.tipRadius,p+module,accuracy:1e-5)
        XCTAssertEqual(actual.rootRadius,p-1.25*module,accuracy:1e-5)
        XCTAssertEqual(actual.width,width,accuracy:1e-6)
        XCTAssertEqual(actual.boreRadius,bore/2,accuracy:1e-6)
        XCTAssertEqual(actual.meanPitchThickness,module*Double.pi/2,accuracy:0.003)
        XCTAssertEqual(actual.minPitchThickness,module*Double.pi/2,accuracy:0.003)
        XCTAssertEqual(actual.maxPitchThickness,module*Double.pi/2,accuracy:0.003)
        XCTAssertEqual(actual.pressureDegrees,20,accuracy:0.08)
        XCTAssertGreaterThanOrEqual(actual.polynomialCapEdges,teeth*2,"An all-line fallback is not a BRep involute approximation.")
        XCTAssertLessThanOrEqual(actual.maxNativeTolerance,1e-5)
        let health=OCCTKernel.healthReportDictionary(for:h,runBOPCheck:true)
        XCTAssertEqual(health["valid"] as? Bool,true,"\(health)")
        XCTAssertEqual((health["counts"] as? [String:Int])?["solids"],1)
        XCTAssertEqual(health["openFreeWires"] as? Int,0);XCTAssertEqual(health["closedFreeWires"] as? Int,0)
        let rootDisk=Double.pi*(pow(p-1.25*module,2)-pow(bore/2,2))*width
        let tipDisk=Double.pi*(pow(p+module,2)-pow(bore/2,2))*width
        XCTAssertGreaterThan(actual.volume,rootDisk);XCTAssertLessThan(actual.volume,tipDisk)
    }
    // Green's theorem: analytic involute integral plus independent circle
    // integration for the cq_gears root/tip. No requested volume or mesh data.
    private func referenceVolume(_ s:CADSpurGearSpec) -> Double {
        let alpha=20.0*Double.pi/180,rp=s.module.value*Double(s.teeth)/2,rb=rp*cos(alpha),ra=rp+s.module.value,rd=rp-1.25*s.module.value
        let upper=sqrt(pow(ra/rb,2)-1),lower=sqrt(max(0,pow(max(rb,rd)/rb,2)-1))
        let phase=Double.pi/(2*Double(s.teeth))+tan(alpha)-alpha,tau=2*Double.pi/Double(s.teeth)
        var start=lower
        if start==0 {
            start=min(upper*0.01,sqrt(s.maximumDeviation.value/(32*rb)))
            func displacement(_ u:Double)->Double { hypot(rb*(cos(u)+u*sin(u)-1),rb*(sin(u)-u*cos(u))) }
            while displacement(start)>s.maximumDeviation.value/8 { start/=2 }
        }
        let rr=rb*sqrt(1+start*start),phiRoot=phase-(start-atan(start)),phiTip=phase-(upper-atan(upper))
        let delta=tau/2-phiRoot
        let x=rr*cos(delta),y=rr*sin(delta),center=(rr*rr-rd*rd)/(2*(x-rd)),radius=abs(rd-center)
        let a=atan2(-y,x-center),b=atan2(y,x-center),mid=atan2(0.0,rd-center)
        func positive(_ a:Double)->Double { var r=a.truncatingRemainder(dividingBy:2*Double.pi);if r<0 { r+=2*Double.pi };return r }
        let ccw=positive(b-a),toMid=positive(mid-a),sweep=toMid<=ccw ? ccw : ccw-2*Double.pi
        let rootArea=center*y+radius*radius*sweep/2
        let involuteArea=rb*rb*(pow(upper,3)-pow(start,3))/3
        let tipArea=ra*ra*phiTip
        let area=Double(s.teeth)*(rootArea+involuteArea+tipArea)-Double.pi*pow(s.boreDiameter.value/2,2)
        return area*s.width.value
    }
    func testRealNativePitchCirclePressureDiametersVolumeAndClosedHealth() throws {
        let spec=CADSpurGearSpec(),definition=CADMechanicalDefinition(gear:spec)
        let output=try XCTUnwrap(CADMechanicalKernel.build(definition,placement:.identity).first)
        try assertNative(output.handle)
        XCTAssertEqual(OCCTKernel.volume(output.handle),referenceVolume(spec),accuracy:0.02)
    }
    func testNativeFlankWitnessesStayWithinAnalyticErrorBudgetAndArchiveIsReadOnly() throws {
        let spec=CADSpurGearSpec(),definition=CADMechanicalDefinition(gear:spec)
        let profile=try CADSpurGearProfile.build(spec,identity:definition.id)
        let output=try XCTUnwrap(CADMechanicalKernel.build(definition,placement:.identity).first)
        let archive=try XCTUnwrap(OCCTKernel.serialize(output.handle))
        let ordinals=Set(profile.firstToothFlankOrdinals)
        let actualFaces=Set(output.history.rows.filter {
            $0.inputOrdinal==0 && $0.inputKind == .edge && $0.relation == .generated && ordinals.contains($0.inputSubshape)
        }.map(\.resultFace))
        XCTAssertEqual(actualFaces.count,2*profile.flankSegments)
        let alpha=20.0*Double.pi/180,rp=20.0,rb=rp*cos(alpha),ra=22.0,rd=17.5
        let lower=max(sqrt(max(0,pow(max(rb,rd)/rb,2)-1)),0.05*sqrt(pow(ra/rb,2)-1)),upper=sqrt(pow(ra/rb,2)-1)
        var points:[SIMD3<Double>]=[]
        for i in 0...48 {
            let u=lower+(upper-lower)*Double(i)/48,r=rb*sqrt(1+u*u)
            let phi=Double.pi/40+tan(alpha)-alpha-u+atan(u)
            for sign in [-1.0,1.0] { points.append(SIMD3(r*cos(phi),sign*r*sin(phi),4)) }
        }
        let distances=try OCCTKernel.gearBoundaryDistances(output.handle,points:points,faces:actualFaces.sorted())
        let native=try OCCTKernel.spurGearMeasurements(output.handle,pitchRadius:20)
        XCTAssertLessThanOrEqual(try XCTUnwrap(distances.max()),profile.flankErrorBound+2*native.maxNativeTolerance+1e-8)
        XCTAssertLessThanOrEqual(profile.flankErrorBound+native.maxNativeTolerance,spec.maximumDeviation.value)
        XCTAssertLessThanOrEqual(profile.baseJoinDisplacement+native.maxNativeTolerance,spec.maximumDeviation.value)
        XCTAssertEqual(OCCTKernel.serialize(output.handle),archive,"Native geometry queries must own their input copy.")
    }
    func testSupportedBoundarySizesAndNoBoreProduceRealStandardToothGeometry() throws {
        for (module,teeth,width) in [(0.5,18,3.0),(0.5,160,6.0)] {
            var spec=CADSpurGearSpec();spec.module=Expr(value:module);spec.teeth=teeth;spec.width=Expr(value:width);spec.boreDiameter=Expr(value:0)
            let output=try XCTUnwrap(CADMechanicalKernel.build(.init(gear:spec),placement:.identity).first)
            try assertNative(output.handle,module:module,teeth:teeth,width:width,bore:0)
            XCTAssertEqual(OCCTKernel.volume(output.handle),referenceVolume(spec),accuracy:max(0.01,spec.maximumDeviation.value*Double(teeth)*width))
        }
    }
    func testParameterUpdateOneUndoSameIdentitySaveReopenAndContinueEditing() async throws {
        let d=try await document(),before=d.session.undoStack.undoCommands.count
        let created=try run(d,"gear.create"),feature=try node(d,created),id=try XCTUnwrap(feature.outputBodyIDs.first)
        guard case let .mechanical(original,_) = feature.kind else { return XCTFail("Missing gear history") }
        XCTAssertEqual(d.session.undoStack.undoCommands.count,before+1)
        let names=d.session.lastKernelNames[id]
        _=try run(d,"gear.update",["feature_id":feature.id.raw.uuidString,"changes":["width":12]])
        XCTAssertEqual(d.session.undoStack.undoCommands.count,before+2)
        XCTAssertEqual(try node(d,created).outputBodyIDs,[id]);XCTAssertEqual(d.session.lastKernelNames[id],names)
        try assertNative(handle(d,id),width:12)
        d.session.undo();try assertNative(handle(d,id))
        let saved=await d.save();XCTAssertTrue(saved.succeeded,saved.error ?? "")
        let url=d.url;d.close();let reopened=try await FloeCADDocument.open(at:url);documents.append(reopened)
        let loaded=try node(reopened,created)
        XCTAssertEqual(loaded.id,feature.id);XCTAssertEqual(loaded.outputBodyIDs,[id])
        guard case let .mechanical(after,_) = loaded.kind else { return XCTFail("Missing reopened intent") }
        XCTAssertEqual(after.id,original.id)
        _=try run(reopened,"update",["feature_id":feature.id.raw.uuidString,"changes":["teeth":24,"bore_diameter":12]])
        try assertNative(handle(reopened,id),teeth:24,bore:12)
        let inspected=try run(reopened,"gear.inspect",["feature_id":feature.id.raw.uuidString])
        XCTAssertEqual(inspected["analytic_involute"] as? Bool,false)
        XCTAssertEqual((inspected["measured_gear"] as? [String:Any])?["measured_teeth"] as? Int,24)
        XCTAssertEqual(CADDocumentFormat.requiredFormat(document:reopened.session.document),7)
    }
    func testRejectedUndercutNonIntegerAndStaleEditPreserveBRepHistoryAndRedo() async throws {
        let d=try await document(),created=try run(d,"gear.create"),feature=try node(d,created),id=try XCTUnwrap(feature.outputBodyIDs.first)
        _=try run(d,"gear.update",["feature_id":feature.id.raw.uuidString,"changes":["width":10]])
        d.session.undo();let archive=try XCTUnwrap(OCCTKernel.serialize(handle(d,id)))
        let undo=d.session.undoStack.undoCommands.count,redo=d.session.undoStack.redoCommands.count
        for changes:[String:Any] in [["teeth":12],["teeth":20.5],["module":0.1],["bore_diameter":100],["maximum_deviation":0],["helix_angle":15]] {
            let reply=CADParameterService(document:d).handle(action:"gear.update",args:["feature_id":feature.id.raw.uuidString,"changes":changes])
            XCTAssertEqual(reply["ok"] as? Bool,false,"\(reply)");XCTAssertEqual(reply["mutated"] as? Bool,false)
            if changes["teeth"] as? Int == 12 { XCTAssertTrue((reply["message"] as? String ?? "").contains("undercut")) }
            XCTAssertEqual(d.session.undoStack.undoCommands.count,undo);XCTAssertEqual(d.session.undoStack.redoCommands.count,redo)
            XCTAssertEqual(OCCTKernel.serialize(try handle(d,id)),archive)
        }
        let stale=CADParameterService(document:d).handle(action:"gear.update",args:["feature_id":feature.id.raw.uuidString,"changes":["width":9],"expected_change_count":-1])
        XCTAssertEqual(stale["error"] as? String,"stale_mechanical");XCTAssertEqual(OCCTKernel.serialize(try handle(d,id)),archive)
        d.session.redo();try assertNative(handle(d,id),width:10)
    }
    func testVariableFanoutUsesSameAuthorityAndFutureGearSemanticsStayOpaque() async throws {
        let d=try await document(),variable=try run(d,"variable.create",["name":"gearWidth","expression":"8"])
        let created=try run(d,"gear.create",["width":"gearWidth"]),feature=try node(d,created),id=try XCTUnwrap(feature.outputBodyIDs.first)
        let variableID=try XCTUnwrap((variable["variable"] as? [String:Any])?["id"] as? String)
        let undo=d.session.undoStack.undoCommands.count
        _=try run(d,"variable.update",["variable_id":variableID,"expression":"11"])
        XCTAssertEqual(d.session.undoStack.undoCommands.count,undo+1);try assertNative(handle(d,id),width:11)
        d.session.undo();try assertNative(handle(d,id))
        let bytes=try JSONEncoder().encode(feature.kind)
        func assess(_ bytes:Data) throws -> CADDocumentFormat.Assessment {
            try CADDocumentFormat.assess(planes:[],sketches:[],features:[CADFeatureRecord(featureID:feature.id.raw,orderIndex:0,
                name:feature.name,suppressed:false,kind:bytes,outputBodyIDs:try JSONEncoder().encode([id]))])
        }
        XCTAssertFalse(try assess(bytes).isOpaqueReadOnly);XCTAssertEqual(try assess(bytes).requiredVersion,7)
        let futureChanges:[(String,Any)]=[("version",2),("futureRootTrochoid",2),("basis","futureRackGeneratedV2")]
        for (key,value) in futureChanges {
            var object=try XCTUnwrap(JSONSerialization.jsonObject(with:bytes) as? [String:Any])
            var payload=try XCTUnwrap(object["mechanical"] as? [String:Any]),definition=try XCTUnwrap(payload["definition"] as? [String:Any])
            var gear=try XCTUnwrap(definition["gear"] as? [String:Any]);gear[key]=value
            definition["gear"]=gear;payload["definition"]=definition;object["mechanical"]=payload
            XCTAssertTrue(try assess(JSONSerialization.data(withJSONObject:object)).opaqueFeatures.contains(feature.id.raw))
        }
    }
    func testDirectMeshChangeCannotRetainAuthoredGearGrade() async throws {
        let d=try await document(),created=try run(d,"gear.create"),feature=try node(d,created),id=try XCTUnwrap(feature.outputBodyIDs.first)
        let original=try XCTUnwrap(d.session.document.body(with:id));var edited=original
        edited.render.positions=edited.render.positions.map { $0+SIMD3<Float>(1,0,0) }
        edited.edges=FeatureEdgeExtractor.edges(from:edited.render);edited.euclid=nil
        d.session.perform(ReplaceBodyCommand(title:"Direct mesh edit",before:original,after:edited))
        let reply=CADParameterService(document:d).handle(action:"gear.inspect",args:["feature_id":feature.id.raw.uuidString])
        XCTAssertEqual(reply["ok"] as? Bool,false)
        XCTAssertEqual(d.session.document.body(with:id)?.render,edited.render)
    }
}
