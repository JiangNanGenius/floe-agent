// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import simd
@testable import FloeCAD

@MainActor
final class CADVoxelRemeshTests: XCTestCase {
    private var directory: URL!
    private var documents: [FloeCADDocument] = []
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("VoxelScans-\(UUID())")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        CADVoxelRemeshKernel.clearCachedEvaluationsForTesting()
    }
    override func tearDown() async throws {
        CADVoxelRemeshService.testComputeProbe = nil; CADVoxelRemeshService.testBeforeCommitProbe = nil
        CADVoxelRemeshKernel.testCellQueryProbe = nil
        for doc in documents { doc.close() }
        CADVoxelRemeshKernel.clearCachedEvaluationsForTesting()
        if let directory { try FileManager.default.removeItem(at:directory) }
    }
    private func document() async throws -> FloeCADDocument {
        let doc = try await FloeCADDocument.create(at:directory.appendingPathComponent("\(UUID()).floecad"),name:"Uneven damaged scan")
        documents.append(doc); return doc
    }
    /// Five faces have two coarse triangles each. The top has a 16×16 grid,
    /// one missing triangle, random reversed triangles, a repeated coarse
    /// triangle and a degenerate triangle. All input normals are zero. The
    /// geometry is still a known [0,10]^3 cube with a sub-voxel hole. This is
    /// deliberately neither a clean uniformly tessellated fixture nor metadata.
    private func scan(openTop: Bool = false) throws -> RenderMesh {
        let cube = try CADPolygonCage.box(width:10,height:10,depth:10), points = cube.points
        var p: [SIMD3<Float>] = [], ids: [UInt32] = []
        func triangle(_ a: SIMD3<Double>,_ b: SIMD3<Double>,_ c: SIMD3<Double>,reverse: Bool) {
            let base = UInt32(p.count); p += [SIMD3<Float>(a),SIMD3<Float>(b),SIMD3<Float>(c)]
            ids += reverse ? [base,base+2,base+1] : [base,base+1,base+2]
        }
        for face in cube.faces {
            let normal = try cube.normal(face), top = normal.y > 0.99
            if top && openTop { continue }
            let v = face.vertices.map { points[$0]! }, n = top ? 16 : 1
            func q(_ x: Int,_ y: Int) -> SIMD3<Double> { v[0]+(v[1]-v[0])*Double(x)/Double(n)+(v[3]-v[0])*Double(y)/Double(n) }
            for y in 0..<n { for x in 0..<n {
                if !(top && x == 7 && y == 7) { triangle(q(x,y),q(x+1,y),q(x+1,y+1),reverse:(x+y)%11 == 0) }
                triangle(q(x,y),q(x+1,y+1),q(x,y+1),reverse:(x+y)%13 == 0)
            } }
        }
        ids += Array(ids.prefix(3)); ids += [0,0,0]
        return RenderMesh(positions:p,normals:Array(repeating:.zero,count:p.count),indices:ids,
                          texcoords:Array(repeating:[0.25,0.75],count:p.count))
    }
    private func definition(_ render: RenderMesh,size: Double = 1,limit: Double = 4) -> CADVoxelRemeshDefinition {
        .init(sourceBodyID:BodyID(),source:.init(render),voxelSizeMM:size,maxDeviationMM:limit)
    }
    @discardableResult private func add(_ doc: FloeCADDocument,_ render: RenderMesh,scale: Double = 1) -> Body {
        var placement = Transform3D.identity; placement.scale = scale
        let body = Body(id:BodyID(),name:"Original scan",transform:placement,render:render,
                        edges:.init(segments:[]),revision:doc.session.mintBodyRevision())
        doc.session.perform(AddBodyCommand(body:body,title:"Import scan")); return body
    }
    private func stored(_ doc: FloeCADDocument,_ body: BodyID) throws -> (FeatureNode,CADVoxelRemeshDefinition,Transform3D) {
        let node = try XCTUnwrap(doc.session.document.features.nodes.last { $0.outputBodyIDs.contains(body) })
        guard case let .voxelRemesh(definition,placement) = node.kind else { throw CADVoxelFailure.invalid("Expected reconstruction.") }
        return (node,definition,placement)
    }
    private func bodyID(_ result: [String: Any]) throws -> BodyID {
        BodyID(raw:try XCTUnwrap(UUID(uuidString:try XCTUnwrap(result["bodyID"] as? String))))
    }
    private func succeed(_ doc: FloeCADDocument,_ action: String,_ args: [String:Any]) async throws -> [String:Any] {
        let value = await CADMeshService(document:doc).handleAsync(action:action,args:args)
        XCTAssertEqual(value["ok"] as? Bool,true,"\(value)"); return value
    }
    func testDamagedUnevenScanRebuildsActualManifoldQuadsOutwardNormalsVolumeAndBoxDeviation() throws {
        let source = try scan(), spec = definition(source)
        let before = try XCTUnwrap(CADMeshIntegrity.inspect(source,shouldStop:{false}))
        XCTAssertGreaterThan(before.boundaryEdges,0); XCTAssertGreaterThan(before.nonManifoldEdges,0)
        XCTAssertGreaterThan(before.degenerateTriangles,0); XCTAssertTrue(before.inconsistentWinding)
        let areas = stride(from:0,to:source.indices.count-6,by:3).map { i -> Double in
            let a = SIMD3<Double>(source.positions[Int(source.indices[i])]), b = SIMD3<Double>(source.positions[Int(source.indices[i+1])]), c = SIMD3<Double>(source.positions[Int(source.indices[i+2])])
            return simd_length(simd_cross(b-a,c-a))/2
        }.filter { $0 > 0 }
        XCTAssertGreaterThan(try XCTUnwrap(areas.max()) / (try XCTUnwrap(areas.min())),200)
        let result = try CADVoxelRemeshKernel.evaluate(spec,scale:1)
        XCTAssertEqual(spec.source.render,source,"Immutable snapshot must include the actual bad normals and UVs.")
        XCTAssertFalse(result.outputIntegrity.unresolved)
        try result.cage.validate(limit:CADVoxelRemeshKernel.maxQuads)
        XCTAssertTrue(result.cage.faces.allSatisfy { $0.vertices.count == 4 })
        XCTAssertEqual(result.gridDimensions,[14,14,14]); XCTAssertEqual(result.solidCells,12*12*12)
        XCTAssertEqual(result.volumeMM3,1728,accuracy:1e-6)
        XCTAssertEqual(result.cage.vertices.count-result.cage.edges.count+result.cage.faces.count,2)
        XCTAssertNil(result.render.texcoords)
        // Independent distance to the mathematical box; not the kernel's BVH
        // certificate, triangle count, input winding or stored report.
        var measured = 0.0
        for (i,p) in result.render.positions.enumerated() {
            let q = SIMD3<Double>(p), outside = simd_max(SIMD3<Double>.zero,simd_max(-q,q-SIMD3<Double>(repeating:10)))
            let distance = simd_length(outside)
            measured = max(measured,distance)
            XCTAssertLessThanOrEqual(distance,sqrt(3)+1e-6)
            XCTAssertEqual(simd_length(result.render.normals[i]),1,accuracy:1e-6)
        }
        XCTAssertEqual(measured,sqrt(3),accuracy:1e-6)
        for t in 0..<result.render.triangleCount {
            let i = Array(result.render.indices[(t*3)..<(t*3+3)]).map(Int.init)
            let a = result.render.positions[i[0]], b = result.render.positions[i[1]], c = result.render.positions[i[2]]
            let n = simd_normalize(simd_cross(b-a,c-a))
            XCTAssertGreaterThan(simd_dot(n,(a+b+c)/3-SIMD3<Float>(repeating:5)),0)
            XCTAssertGreaterThan(simd_dot(n,result.render.normals[i[0]]),0.99999)
        }
        XCTAssertGreaterThanOrEqual(result.distanceUpperBoundMM,measured-1e-6)
        XCTAssertLessThanOrEqual(result.sampledDistanceMM,result.distanceUpperBoundMM)
        XCTAssertLessThanOrEqual(result.distanceUpperBoundMM,4)
    }
    func testWorldResolutionIsMeasuredAfterUniformPlacementScale() throws {
        let result = try CADVoxelRemeshKernel.evaluate(definition(scan(),size:2,limit:8),scale:2)
        XCTAssertEqual(result.gridDimensions,[14,14,14]); XCTAssertEqual(result.volumeMM3,1728*8,accuracy:1e-5)
        XCTAssertLessThanOrEqual(result.distanceUpperBoundMM,8)
        XCTAssertGreaterThan(result.sampledDistanceMM,1)
    }
    func testPreviewOneUndoSourcePreservedStableIDsColdReopenAndContinueResolutionEdit() async throws {
        let doc = try await document(), original = add(doc,try scan()), originalBytes = MeshBlob.encode(original.render)
        let count = doc.session.undoStack.undoCommands.count
        let preview = try await succeed(doc,"voxel.remesh",["bodyID":original.id.raw.uuidString,"voxelSize":1,"maxDeviation":4,"preview":true])
        XCTAssertEqual(doc.session.document.bodies.count,1); XCTAssertEqual(doc.session.undoStack.undoCommands.count,count)
        XCTAssertNotNil(preview["mesh"]); XCTAssertNotNil(preview["surfaceDistanceUpperBoundMM"])
        let done = try await succeed(doc,"voxel.remesh",["bodyID":original.id.raw.uuidString,"voxelSize":1,"maxDeviation":4,
            "expectedPreviewHash":try XCTUnwrap(preview["previewHash"]),"expectedRevision":try XCTUnwrap(preview["previewRevision"]),"expectedChangeCount":try XCTUnwrap(preview["previewChangeCount"])])
        let id = try bodyID(done), saved = try stored(doc,id), render = try XCTUnwrap(doc.session.document.body(with:id)?.render)
        XCTAssertEqual(doc.session.undoStack.undoCommands.count,count+1); XCTAssertEqual(doc.session.document.bodies.count,2)
        XCTAssertNil(doc.session.document.body(with:id)?.brep); XCTAssertNil(doc.session.document.body(with:id)?.surfaceBRep)
        XCTAssertEqual(MeshBlob.encode(try XCTUnwrap(doc.session.document.body(with:original.id)?.render)),originalBytes)
        doc.session.undo(); XCTAssertNil(doc.session.document.body(with:id)); XCTAssertEqual(doc.session.document.bodies.count,1)
        doc.session.redo(); XCTAssertEqual(doc.session.document.body(with:id)?.render,render)
        XCTAssertEqual(try stored(doc,id).0.id,saved.0.id)
        let save = await doc.save(); XCTAssertTrue(save.succeeded,save.error ?? ""); doc.close()
        CADVoxelRemeshKernel.clearCachedEvaluationsForTesting()
        let reopened = try await FloeCADDocument.open(at:doc.url); documents.append(reopened)
        let cold = try stored(reopened,id)
        XCTAssertEqual(cold.0.id,saved.0.id); XCTAssertEqual(cold.1,saved.1); XCTAssertEqual(reopened.session.document.body(with:id)?.render,render)
        XCTAssertEqual(MeshBlob.encode(try XCTUnwrap(reopened.session.document.body(with:original.id)?.render)),originalBytes)
        let inspect = try await succeed(reopened,"voxel.inspect",["bodyID":id.raw.uuidString])
        let updateCount = reopened.session.undoStack.undoCommands.count
        _ = try await succeed(reopened,"voxel.update",["bodyID":id.raw.uuidString,"definitionDigest":try XCTUnwrap(inspect["definitionDigest"]),"voxelSize":0.5,"maxDeviation":2])
        let changed = try stored(reopened,id)
        XCTAssertEqual(changed.0.id,saved.0.id); XCTAssertEqual(changed.1.id,saved.1.id); XCTAssertEqual(changed.1.source,saved.1.source)
        XCTAssertEqual(reopened.session.undoStack.undoCommands.count,updateCount+1)
        let evaluated = try CADVoxelRemeshKernel.evaluate(changed.1,scale:changed.2.scale)
        XCTAssertEqual(evaluated.volumeMM3,1331,accuracy:1e-6)
        XCTAssertLessThanOrEqual(evaluated.distanceUpperBoundMM,2)
        reopened.session.undo(); XCTAssertEqual(reopened.session.document.body(with:id)?.render,render)
        XCTAssertEqual(CADDocumentFormat.requiredFormat(document:reopened.session.document),7)
    }
    func testOpenScanPrecisionBudgetsAndDeviationRefuseWithoutReplacingOriginalOrRedo() async throws {
        let doc = try await document(), original = add(doc,try scan()), service = CADMeshService(document:doc)
        let done = try await succeed(doc,"voxel.remesh",["bodyID":original.id.raw.uuidString])
        let id = try bodyID(done); doc.session.undo()
        let count = doc.session.undoStack.undoCommands.count, bytes = MeshBlob.encode(original.render), epoch = doc.session.changeCount
        for fields: [String:Any] in [["voxelSize":0.001,"maxDeviation":0.004],["voxelSize":3,"maxDeviation":12],["voxelSize":1,"maxDeviation":1],["voxelSize":Double.nan]] {
            var args = fields; args["bodyID"] = original.id.raw.uuidString
            let refused = await service.handleAsync(action:"voxel.remesh",args:args)
            XCTAssertEqual(refused["ok"] as? Bool,false,"\(refused)"); XCTAssertEqual(refused["mutated"] as? Bool,false)
            XCTAssertEqual(doc.session.undoStack.undoCommands.count,count); XCTAssertTrue(doc.session.undoStack.canRedo)
            XCTAssertEqual(doc.session.changeCount,epoch); XCTAssertEqual(MeshBlob.encode(try XCTUnwrap(doc.session.document.body(with:original.id)?.render)),bytes)
        }
        XCTAssertThrowsError(try CADVoxelRemeshKernel.evaluate(definition(scan(openTop:true)),scale:1))
        doc.session.redo(); XCTAssertNotNil(doc.session.document.body(with:id))
    }
    func testCancellationInsideVoxelDistanceLoopDoesNotPublishPartialGeometry() throws {
        let gate = CounterStop(limit:800), source = try scan(), original = MeshBlob.encode(source)
        CADVoxelRemeshKernel.clearCachedEvaluationsForTesting()
        let token = CADMeshCancellation()
        CADVoxelRemeshKernel.testCellQueryProbe = { _ in if gate.stop() { token.cancel() } }
        defer { CADVoxelRemeshKernel.testCellQueryProbe = nil }
        XCTAssertThrowsError(try CADVoxelRemeshKernel.evaluate(definition(source),scale:1,cancelled:{token.isCancelled})) { error in
            XCTAssertEqual((error as? CADVoxelFailure)?.code,"cancelled")
        }
        XCTAssertGreaterThanOrEqual(gate.count,800)
        XCTAssertEqual(MeshBlob.encode(source),original)
        // A cancelled evaluation never seeds the completed-result cache.
        CADVoxelRemeshKernel.testCellQueryProbe = nil
        let result = try CADVoxelRemeshKernel.evaluate(definition(source),scale:1)
        XCTAssertEqual(result.volumeMM3,1728,accuracy:1e-6)
    }
    func testOffMainWorkerLateResultCannotOverwriteNewDocumentEpochOrClose() async throws {
        for close in [false,true] {
            let doc = try await document(), source = add(doc,try scan()), count = doc.session.undoStack.undoCommands.count
            let gate = WorkerGate(); CADVoxelRemeshService.testBeforeCommitProbe = { gate.pause() }
            let operation = Task { @MainActor in
                let result = await CADMeshService(document:doc).handleAsync(action:"voxel.remesh",args:["bodyID":source.id.raw.uuidString])
                return try JSONSerialization.data(withJSONObject:result)
            }
            let deadline = ContinuousClock.now.advanced(by:.seconds(30))
            while !gate.arrived && ContinuousClock.now < deadline { await Task.yield() }
            XCTAssertTrue(gate.arrived); XCTAssertFalse(gate.ranOnMain)
            if close { doc.close() }
            else { _ = add(doc,try scan()) }
            gate.release(); let bytes = try await operation.value
            let result = try XCTUnwrap(JSONSerialization.jsonObject(with:bytes) as? [String:Any])
            XCTAssertEqual(result["ok"] as? Bool,false,"\(result)")
            XCTAssertEqual(doc.session.undoStack.undoCommands.count,count + (close ? 0 : 1))
            XCTAssertFalse(doc.session.document.features.nodes.contains { if case .voxelRemesh = $0.kind { return true }; return false })
            CADVoxelRemeshService.testBeforeCommitProbe = nil
        }
    }
    func testCancelledServiceWorkerKeepsUndoRedoAndStalePreviewRefuses() async throws {
        let doc = try await document(), source = add(doc,try scan()), service = CADMeshService(document:doc)
        let preview = try await succeed(doc,"voxel.remesh",["bodyID":source.id.raw.uuidString,"preview":true])
        let gate = WorkerGate(); CADVoxelRemeshService.testBeforeCommitProbe = { gate.pause() }
        let count = doc.session.undoStack.undoCommands.count
        let operation = Task { @MainActor in
            let result = await service.handleAsync(action:"voxel.remesh",args:["bodyID":source.id.raw.uuidString])
            return try JSONSerialization.data(withJSONObject:result)
        }
        let deadline = ContinuousClock.now.advanced(by:.seconds(30))
        while !gate.arrived && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(gate.arrived); XCTAssertTrue(CADMeshService.cancelActiveOperation(for:doc))
        gate.release(); let bytes = try await operation.value
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with:bytes) as? [String:Any])
        XCTAssertEqual(result["error"] as? String,"cancelled"); XCTAssertEqual(doc.session.undoStack.undoCommands.count,count)
        CADVoxelRemeshService.testBeforeCommitProbe = nil
        _ = add(doc,try scan())
        let stale = await service.handleAsync(action:"voxel.remesh",args:["bodyID":source.id.raw.uuidString,
            "expectedPreviewHash":try XCTUnwrap(preview["previewHash"]),"expectedRevision":try XCTUnwrap(preview["previewRevision"]),"expectedChangeCount":try XCTUnwrap(preview["previewChangeCount"])])
        XCTAssertEqual(stale["ok"] as? Bool,false); XCTAssertEqual(doc.session.document.bodies.count,2)
    }
    func testOriginalSnapshotSurvivesSourceEditAndDirectOutputEditCannotClaimReconstruction() async throws {
        let doc = try await document(), source = add(doc,try scan())
        let done = try await succeed(doc,"voxel.remesh",["bodyID":source.id.raw.uuidString]), id = try bodyID(done)
        let old = try stored(doc,id)
        var moved = source; moved.render.positions = moved.render.positions.map { $0 + SIMD3<Float>(20,0,0) }
        doc.session.perform(ReplaceBodyCommand(title:"Edit original",before:source,after:moved))
        let inspect = try await succeed(doc,"voxel.inspect",["bodyID":id.raw.uuidString])
        _ = try await succeed(doc,"voxel.update",["bodyID":id.raw.uuidString,"definitionDigest":try XCTUnwrap(inspect["definitionDigest"]),"voxelSize":0.5,"maxDeviation":2])
        XCTAssertEqual(try stored(doc,id).1.source,old.1.source); XCTAssertEqual(doc.session.document.body(with:source.id)?.render,moved.render)
        let body = try XCTUnwrap(doc.session.document.body(with:id)); var edited = body
        edited.render.positions[0].x += 0.25
        doc.session.perform(ReplaceBodyCommand(title:"Direct mesh edit",before:body,after:edited))
        let count = doc.session.undoStack.undoCommands.count
        let refusal = await CADMeshService(document:doc).handleAsync(action:"voxel.inspect",args:["bodyID":id.raw.uuidString])
        XCTAssertEqual(refusal["ok"] as? Bool,false); XCTAssertEqual(doc.session.undoStack.undoCommands.count,count)
        XCTAssertEqual(doc.session.document.body(with:id)?.render,edited.render)
    }
    func testVersionAlgorithmAndUnknownFieldsStayOpaqueAtActualWriterFloor() throws {
        let spec = definition(try scan()), id = BodyID(), node = FeatureNode(name:"Reconstruction",kind:.voxelRemesh(definition:spec,placement:.identity),outputBodyIDs:[id])
        let data = try JSONEncoder().encode(node.kind)
        func assess(_ data: Data) throws -> CADDocumentFormat.Assessment {
            try CADDocumentFormat.assess(planes:[],sketches:[],features:[CADFeatureRecord(featureID:node.id.raw,orderIndex:0,name:node.name,suppressed:false,kind:data,outputBodyIDs:try JSONEncoder().encode([id]))])
        }
        XCTAssertEqual(try assess(data).requiredVersion,7); XCTAssertFalse(try assess(data).isOpaqueReadOnly)
        for (key,value): (String,Any) in [("version",2),("algorithm","future-adaptive-v2"),("projectionConstraints",["keepSharp":true])] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any]), payload = try XCTUnwrap(object["voxelRemesh"] as? [String:Any])
            var definition = try XCTUnwrap(payload["definition"] as? [String:Any]); definition[key] = value
            payload["definition"] = definition; object["voxelRemesh"] = payload
            XCTAssertTrue(try assess(JSONSerialization.data(withJSONObject:object)).opaqueFeatures.contains(node.id.raw))
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any]), payload = try XCTUnwrap(object["voxelRemesh"] as? [String:Any])
        var definition = try XCTUnwrap(payload["definition"] as? [String:Any]), source = try XCTUnwrap(definition["source"] as? [String:Any])
        source["futureScanConfidence"] = [0.5]; definition["source"] = source; payload["definition"] = definition; object["voxelRemesh"] = payload
        XCTAssertTrue(try assess(JSONSerialization.data(withJSONObject:object)).isOpaqueReadOnly)
    }
}

private nonisolated final class CounterStop: @unchecked Sendable {
    let lock = NSLock(), limit: Int
    private var value = 0
    init(limit: Int) { self.limit = limit }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func stop() -> Bool { lock.lock(); defer { lock.unlock() }; value += 1; return value >= limit }
}
private nonisolated final class WorkerGate: @unchecked Sendable {
    let lock = NSLock(), signal = DispatchSemaphore(value:0)
    private var seen = false, main = false
    var arrived: Bool { lock.lock(); defer { lock.unlock() }; return seen }
    var ranOnMain: Bool { lock.lock(); defer { lock.unlock() }; return main }
    func pause() {
        lock.lock(); seen = true; main = Thread.isMainThread; lock.unlock()
        _ = signal.wait(timeout:.now()+30)
    }
    func release() { signal.signal() }
}
