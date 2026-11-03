import XCTest
import simd
@testable import FloeCAD

@MainActor
final class CADAssemblyJointClosureTests: XCTestCase {
    private var directory: URL!
    private var document: FloeCADDocument!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CAD-Joint-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        document = try await FloeCADDocument.create(at: directory.appendingPathComponent("mechanism.floecad"), name: "Mechanism")
    }
    override func tearDown() async throws {
        document?.close()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func checked(_ reply: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)", file: file, line: line)
        guard reply["ok"] as? Bool == true else { throw NSError(domain: "CADJointFixture", code: 1) }
        return reply
    }
    private func command(_ op: String, _ args: [String: Any]) throws -> [String: Any] {
        let outcome = document.executeJSON(try JSONSerialization.data(withJSONObject: ["op": op, "args": args]))
        XCTAssertTrue(outcome.isOK, "\(outcome.message ?? "")")
        guard outcome.isOK else { throw NSError(domain: "CADJointCommand", code: 1) }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: outcome.payload) as? [String: Any])
    }
    private func box(width: Double = 10, depth: Double = 4, height: Double = 2) throws -> String {
        let sketch = try XCTUnwrap(command("sketch.create", ["name": "Part"])["sketchID"] as? String)
        _ = try command("sketch.addEntities", ["sketchID": sketch, "entities": [["kind": "rect", "min": [0,0], "max": [width,depth]]]])
        let reply = try command("feature.extrude", ["sketchID": sketch, "seedPoint": [width/2,depth/2], "distance": height])
        return try XCTUnwrap((reply["producedBodyIDs"] as? [String])?.first ?? (reply["changedBodyIDs"] as? [String])?.first)
    }
    private func call(_ action: String, _ args: [String: Any] = [:]) throws -> [String: Any] {
        try checked(CADAssemblyService(document: document).handle(action: action, args: args))
    }
    private func instance(_ body: String, _ name: String, _ position: [Double] = [0,0,0]) throws -> String {
        try XCTUnwrap(call("addInstance", ["bodyID": body, "name": name, "transform": ["position": position]])["id"] as? String)
    }
    private func assembly() throws -> CADAssembly { try CADAssembly.decode(from: document.session.document.assemblyData) }
    private func pose(_ id: String) throws -> CADTransform {
        try XCTUnwrap(assembly().instance(try XCTUnwrap(UUID(uuidString: id)))).transform
    }
    private func joint(_ kind: String, a: String, b: String, value: Double? = nil,
                       lower: Double = -90, upper: Double = 90,
                       point: [Double] = [0,0,0], axis: [Double] = [0,0,1]) throws -> String {
        var args: [String: Any] = ["kind": kind, "instanceA": a, "instanceB": b,
            "pointA": point, "pointB": [0.0,0,0], "directionA": axis, "directionB": axis,
            "lowerLimit": lower, "upperLimit": upper]
        if let value { args["value"] = value }
        return try XCTUnwrap(call("addConstraint", args)["id"] as? String)
    }
    private func mechanism() throws -> (String, String, String, String) {
        let body = try box()
        let base = try instance(body, "Base"), arm = try instance(body, "Arm"), carrier = try instance(body, "Carrier")
        _ = try call("addConstraint", ["kind":"fixed", "instanceA":base])
        let hinge = try joint("hinge", a: base, b: arm, value: 0)
        _ = try joint("slider", a: arm, b: carrier, value: 6, lower: 0, upper: 20,
                      point: [10,0,0], axis: [1,0,0])
        return (base, arm, carrier, hinge)
    }

    func testSingleHingeDrivePropagatesThreePartChainAndOneUndoReopen() async throws {
        let (base, arm, carrier, hinge) = try mechanism()
        let before = document.session.document.assemblyData
        let undo = document.session.undoStack.undoCommands.count
        let basePose = try pose(base)
        _ = try call("updateConstraint", ["id": hinge, "value":90])
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undo + 1)
        XCTAssertEqual(try pose(base), basePose)
        let actual = try pose(carrier).position
        XCTAssertEqual(actual.x, 0, accuracy: 1e-7); XCTAssertEqual(actual.y, 16, accuracy: 1e-7)
        XCTAssertEqual(actual.z, 0, accuracy: 1e-7)
        XCTAssertGreaterThan(simd_length(try pose(arm).rotation - SIMD4(0,0,0,1)), 0.1)
        let after = document.session.document.assemblyData
        document.session.undo(); XCTAssertEqual(document.session.document.assemblyData, before)
        document.session.redo(); XCTAssertEqual(document.session.document.assemblyData, after)
        let save = await document.save(); XCTAssertTrue(save.succeeded, save.error ?? "")
        document.close(); document = try await FloeCADDocument.open(at: document.url)
        XCTAssertEqual(try assembly().constraint(try XCTUnwrap(UUID(uuidString: hinge)))?.value, 90)
        XCTAssertEqual(try pose(carrier).position.y, 16, accuracy: 1e-7)
    }

    func testFreeSliderDragClampsLimitsAndInvalidDriveIsAtomic() throws {
        let body = try box(), base = try instance(body, "Base"), part = try instance(body, "Slide")
        _ = try call("addConstraint", ["kind":"fixed", "instanceA":base])
        let id = try joint("slider", a: base, b: part, lower: -5, upper: 12, axis: [1,0,0])
        _ = try call("setTransform", ["id":part, "transform":["position":[40,30,5]]])
        XCTAssertEqual(try pose(part).position.x, 12, accuracy: 1e-8)
        XCTAssertEqual(try pose(part).position.y, 0, accuracy: 1e-8)
        let bytes = document.session.document.assemblyData, count = document.session.changeCount
        let reply = CADAssemblyService(document: document).handle(action: "updateConstraint", args: ["id":id,"value":13])
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(document.session.document.assemblyData, bytes)
        XCTAssertEqual(document.session.changeCount, count)
        _ = try call("updateConstraint", ["id":id,"value":-4])
        XCTAssertEqual(try pose(part).position.x, -4, accuracy: 1e-8)
        _ = try call("updateConstraint", ["id":id,"value":NSNull()])
        XCTAssertNil(try assembly().constraint(try XCTUnwrap(UUID(uuidString:id)))?.value)
    }

    func testJointMathBothRolesSkewAxesAndSignedHalfTurns() throws {
        let a = CADTransform(position: SIMD3(3,8,2), rotation: simd_quatd(angle:0.7,axis:simd_normalize(SIMD3(1,2,3))).vector, scale: SIMD3(repeating:2))
        let b = CADTransform(position: SIMD3(-2,7,19), rotation: simd_quatd(angle:-1.1,axis:simd_normalize(SIMD3(2,1,4))).vector)
        for kind in [CADAssemblyConstraintKind.hinge, .slider] {
            for moveB in [true,false] {
                for value in [-180.0,-43,0,58,180] {
                    var c = CADAssemblyConstraint(kind:kind,instanceA:UUID(),instanceB:UUID(),pointA:SIMD3(3,2,1),directionA:SIMD3(0,1,0),pointB:SIMD3(1,3,2),directionB:SIMD3(1,0,0),value:value)
                    c.joint = CADAssemblyJointMath.make(a:a,b:b,axisA:c.directionA,axisB:c.directionB!,lower:-180,upper:180)
                    let next = try XCTUnwrap(CADAssemblyJointMath.project(c,a:a,b:b,moveB:moveB))
                    let aa = moveB ? a : next, bb = moveB ? next : b
                    XCTAssertLessThan(CADAssemblyJointMath.residual(c,a:aa,b:bb,scale:100),1e-6)
                    XCTAssertEqual(CADAssemblyJointMath.coordinate(c,a:aa,b:bb),value,accuracy:1e-7)
                }
            }
        }
    }

    func testActualMotionStudySolvesAndInspectsWithoutDocumentMutation() async throws {
        let (_, _, carrier, hinge) = try mechanism()
        let bytes = document.session.document.assemblyData, changes = document.session.changeCount
        let reply = try checked(await CADAssemblyService(document: document).handleAsync(action:"motionStudy",
            args:["id":hinge,"from":0,"to":90,"samples":3]))
        let frames = try XCTUnwrap(reply["frames"] as? [[String:Any]])
        XCTAssertEqual(frames.count,3)
        for frame in frames {
            let inspection = try XCTUnwrap(frame["interference"] as? [String:Any])
            XCTAssertEqual(inspection["processedPairCount"] as? Int,3)
            XCTAssertEqual(inspection["detailsComplete"] as? Bool,true)
            XCTAssertEqual(inspection["kernelExecutor"] as? String,"serialized-copy-off-main")
        }
        let travel = try XCTUnwrap((reply["travelMM"] as? [[String:Any]])?.first { $0["instanceID"] as? String == carrier }?["distance"] as? Double)
        XCTAssertEqual(travel,2 * 16 * 2 * sin(.pi/8),accuracy:1e-6)
        XCTAssertEqual(document.session.document.assemblyData,bytes)
        XCTAssertEqual(document.session.changeCount,changes)
    }

    func testCancelledMotionReturnsNoFramesAndPreservesDocument() async throws {
        let (_,_,_,hinge) = try mechanism()
        let before = document.session.document.assemblyData
        let task = Task { @MainActor in
            let reply = await CADAssemblyService(document: document).handleAsync(action:"motionStudy",args:["id":hinge,"from":0,"to":90,"samples":121])
            return try JSONSerialization.data(withJSONObject: reply)
        }
        task.cancel()
        let data = try await task.value
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String:Any])
        XCTAssertEqual(result["ok"] as? Bool,false)
        XCTAssertNil(result["frames"])
        XCTAssertEqual(document.session.document.assemblyData,before)
    }

    func testFutureJointAndBindingRemainOpaqueWithRawRowsPreserved() async throws {
        let (_,_,_,id) = try mechanism()
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(document.session.document.assemblyData)) as? [String:Any])
        var rows = try XCTUnwrap(raw["constraints"] as? [[String:Any]])
        let i = try XCTUnwrap(rows.firstIndex { $0["id"] as? String == id })
        rows[i]["joint"] = ["version":999,"futureMeaning":[1,2,3]];raw["constraints"] = rows
        let bytes = try JSONSerialization.data(withJSONObject:raw,options:.sortedKeys)
        document.session.perform(SetAssemblyDataCommand(before:document.session.document.assemblyData,after:bytes))
        let assessment = CADDocumentFormat.assemblyJointIntent(bytes)
        XCTAssertTrue(assessment.opaque);XCTAssertEqual(assessment.version,7)
        let refusal = CADAssemblyService(document:document).handle(action:"updateConstraint",args:["id":id,"value":30])
        XCTAssertEqual(refusal["ok"] as? Bool,false)
        XCTAssertEqual(document.session.document.assemblyData,bytes)
    }

    func testNativeHoleReferenceFollowsCenterAndRejectsAmbiguousName() async throws {
        let bodyID = try box(width:100,depth:60,height:10)
        let sketch = try XCTUnwrap(command("sketch.create",["name":"Bore"])["sketchID"] as? String)
        let added = try command("sketch.addEntities",["sketchID":sketch,"entities":[["kind":"circle","center":[50,30],"radius":4]]])
        let entity = try XCTUnwrap((added["entityIDs"] as? [String])?.first)
        _ = try command("feature.hole",["sketchID":sketch,"seedPoint":[50,30],"targetBodyID":bodyID,"type":"throughAll"])
        let id = try XCTUnwrap(UUID(uuidString:bodyID))
        let body = try XCTUnwrap(document.session.document.bodies.first { $0.id.raw == id })
        let brep = try XCTUnwrap(body.brep)
        let cylinder = try XCTUnwrap(OCCTKernel.faceInfo(brep).first {
            if case .cylindrical? = $0.signature?.kind { return true }; return false
        })
        let base = try instance(bodyID,"Base"), pin = try instance(bodyID,"Pin")
        _ = try call("addConstraint",["kind":"fixed","instanceA":base])
        let addedMate = try call("addConstraint",["kind":"coaxial","instanceA":base,"instanceB":pin,
            "faceA":["index":cylinder.index],"pointB":[0,0,0],"directionB":[cylinder.normal.x,cylinder.normal.y,cylinder.normal.z]])
        let mate = try XCTUnwrap(UUID(uuidString:try XCTUnwrap(addedMate["id"] as? String)))
        _ = try call("solve")
        let bound = try XCTUnwrap(assembly().constraint(mate)?.bindingA)
        let name = try XCTUnwrap(bound.face?.elementName)
        XCTAssertTrue(name.isStableFaceIdentity)
        let duplicated = [cylinder.index:name,cylinder.index+10_000:name]
        XCTAssertNil(CADAssemblyGeometryResolver.resolve(bound,source:body,
            document:document.session.document,names:duplicated))
        let before = document.session.document.assemblyData
        let undo = document.session.undoStack.undoCommands.count
        _ = try checked(CADParameterService(document:document).handle(action:"updateSketchEntity",
            args:["sketch_id":sketch,"entity_id":entity,"center":[60.0,35.0]]))
        XCTAssertEqual(document.session.undoStack.undoCommands.count,undo+1)
        let current = try XCTUnwrap(assembly().constraint(mate))
        XCTAssertEqual(current.bindingA,bound)
        XCTAssertNil(current.referenceFailure)
        let oldAxis = try XCTUnwrap(cylinder.axisPoint)
        XCTAssertGreaterThan(simd_length(current.pointA - oldAxis),1)
        let newBody = try XCTUnwrap(document.session.document.bodies.first { $0.id.raw == id })
        let reference = try XCTUnwrap(CADAssemblyGeometryResolver.resolve(bound,source:newBody,
            document:document.session.document,names:document.session.lastKernelNames[newBody.id] ?? [:]))
        XCTAssertLessThan(simd_length(current.pointA-reference.point),1e-7)
        let point = try pose(pin).position
        let axis = simd_normalize(current.directionA)
        let offset = point-current.pointA
        XCTAssertLessThan(simd_length(offset-simd_dot(offset,axis)*axis),1e-6)
        let after = document.session.document.assemblyData
        document.session.undo();XCTAssertEqual(document.session.document.assemblyData,before)
        document.session.redo();XCTAssertEqual(document.session.document.assemblyData,after)
        let save = await document.save();XCTAssertTrue(save.succeeded,save.error ?? "")
        document.close();document = try await FloeCADDocument.open(at:document.url)
        XCTAssertEqual(try assembly().constraint(mate)?.bindingA,bound)
        XCTAssertEqual(try assembly().constraint(mate)?.pointA,current.pointA)
    }

    func testExistingDatumPlaneMateFollowsOffsetThroughActualDatumService() async throws {
        let bodyID = try box(width:20,depth:12,height:5)
        let source = try XCTUnwrap(document.session.document.bodies.first { $0.id.raw.uuidString == bodyID })
        let faces = OCCTKernel.faceInfo(try XCTUnwrap(source.brep))
        let face = try XCTUnwrap(faces.first { $0.signature?.kind == .planar && document.session.lastKernelNames[source.id]?[$0.index]?.isStableFaceIdentity == true })
        let token = CADGeometryQueryGeneration(scope:"faces",bodyID:source.id.raw,documentRevision:document.revision,
            changeCount:document.session.changeCount,meshRevision:source.meshRevision).token
        let created = try checked(CADDatumService(document:document).handle(action:"datum.offsetPlane.create",
            args:["body_id":bodyID,"face_index":face.index,"query_token":token,"expression":"5"]))
        let planeID = try XCTUnwrap(created["plane_id"] as? String)
        let base = try instance(bodyID,"Ground"), moving = try instance(bodyID,"Mounted")
        _ = try call("addConstraint",["kind":"fixed","instanceA":base])
        let reference = try call("reference",["instanceID":base,"planeID":planeID])
        let direction = try XCTUnwrap(reference["direction"] as? [Double])
        let mate = try XCTUnwrap(call("addConstraint",["kind":"planarAlign","instanceA":base,"instanceB":moving,
            "referenceA":reference,"pointB":[0,0,0],"directionB":direction.map { -$0 }])["id"] as? String)
        _ = try call("solve")
        let before = document.session.document.assemblyData
        let position = try pose(moving).position
        _ = try checked(CADDatumService(document:document).handle(action:"datum.offsetPlane.update",
            args:["plane_id":planeID,"expression":"11","expected_expression":"5"]))
        let row = try XCTUnwrap(assembly().constraint(try XCTUnwrap(UUID(uuidString:mate))))
        XCTAssertNil(row.referenceFailure)
        XCTAssertEqual(row.bindingA?.planeID?.uuidString,planeID)
        let delta = try pose(moving).position-position
        XCTAssertEqual(simd_dot(delta,SIMD3(direction[0],direction[1],direction[2])),6,accuracy:1e-7)
        document.session.undo();XCTAssertEqual(document.session.document.assemblyData,before)
        document.session.redo()
        let save = await document.save();XCTAssertTrue(save.succeeded,save.error ?? "")
        document.close();document = try await FloeCADDocument.open(at:document.url)
        XCTAssertEqual(try assembly().constraint(try XCTUnwrap(UUID(uuidString:mate)))?.bindingA?.planeID?.uuidString,planeID)
    }
}
