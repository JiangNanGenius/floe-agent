import XCTest
import FloeCAD
import FloeSimulationCore
import FloeSimulationGeometry
import FloeSimulationPhysics
import FloeSimulationFields
import FloeSimulationAnimation
import FloeSimulationRuntime
import FloeSimulationUI

@MainActor final class MeshAnimationCodeChecks:XCTestCase {
    func testImportedMeshPhysicsFieldsAnimationAndExportsSurviveProjectMove() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mesh-animation04-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let project = root.appendingPathComponent("Original.floeproject"), sourceURL = project.appendingPathComponent("Document.floecad")
        let cad = try await FloeCADDocument.create(at:sourceURL,name:"Imported Mesh")
        defer { cad.close() }
        let obj = """
        o MeshCube
        v 0 0 0
        v 20 0 0
        v 20 20 0
        v 0 20 0
        v 0 0 20
        v 20 0 20
        v 20 20 20
        v 0 20 20
        f 1 4 3 2
        f 5 6 7 8
        f 1 5 8 4
        f 2 3 7 6
        f 1 2 6 5
        f 4 8 7 3
        """
        let imported = cad.nativeImportData(Data(obj.utf8),format:"obj",fileName:"MeshCube.obj",unitScale:1)
        XCTAssertTrue(imported.isOK,imported.message ?? "")
        let geometry = try cad.simulationGeometry(), part = try XCTUnwrap(geometry.bodies.first)
        XCTAssertNil(part.brep,"This must exercise the imported Mesh path, not an OCCT primitive")
        let before = geometry.contentSHA256
        let source = SimulationSourceRef(projectID:UUID(),documentID:UUID(),revision:0,contentSHA256:before)
        let input = try SimulationPhysicsMesh(vertices:part.positionsMM.map { .init($0[0]*0.001,$0[1]*0.001,$0[2]*0.001) },indices:part.indices)
        XCTAssertTrue(input.isClosed)
        let elements = input.triangles.map { SimulationElement(kind:.triangle3,nodes:$0.map(Int.init),regionID:part.id.uuidString.lowercased()) }
        let boundaries = part.faces.filter { !$0.triangles.isEmpty }.map { face in
            let triangles = face.triangles.filter { elements.indices.contains($0) }
            return SimulationBoundary(id:face.id,sourceEntityID:face.id,nodeIndices:Array(Set(triangles.flatMap { elements[$0].nodes })).sorted(),facets:triangles.map { .init(elementIndex:$0) })
        }
        let surface = SimulationMesh(source:source,nodes:input.vertices,elements:elements,boundaries:boundaries)
        let mesh = try await NativeSimulationMesher(driver:NetgenSimulationGeometryDriver()).mesh(.init(source:source,surface:surface),settings:.init(maximumSizeMeters:0.01,minimumSizeMeters:0.002),budget:.init(maximumNodes:10_000,maximumElements:40_000)) { _ in }
        let volume = mesh.elements.reduce(0.0) { value,element in
            let p = element.nodes.map { mesh.nodes[$0] }; return value+abs((p[1]-p[0]).dot((p[2]-p[0]).cross(p[3]-p[0])))/6
        }
        XCTAssertEqual(volume,8e-6,accuracy:8e-11)
        let first = try XCTUnwrap(mesh.boundaries.first { $0.nodeIndices.allSatisfy { abs(mesh.nodes[$0].x) < 1e-8 } })
        let last = try XCTUnwrap(mesh.boundaries.first { $0.nodeIndices.allSatisfy { abs(mesh.nodes[$0].x-0.02) < 1e-8 } })
        var electrical = ElectromagneticSimulationConfiguration()
        electrical.boundaries = [.init(boundaryID:first.id,kind:.electricPotential),.init(boundaryID:last.id,kind:.electricPotential,value:.init(real:2))]
        let vacuum = SimulationMaterial(name:"Vacuum",properties:["relativePermittivity":1])
        var fieldStudy = SimulationStudy(name:"Imported Mesh field",kind:.electrostatic,materialAssignments:Dictionary(uniqueKeysWithValues:Set(mesh.elements.map(\.regionID)).map { ($0,vacuum.id) }))
        fieldStudy.meshID = mesh.id; try fieldStudy.setConfiguration(electrical)
        let field = try await MFEMSimulationDriver().solve(.init(source:source,study:fieldStudy,mesh:mesh,materials:[vacuum])) { _ in }
        let potential = try XCTUnwrap(field.frames.first?.fields.first { $0.id == "potential" })
        for (index,p) in mesh.nodes.enumerated() { XCTAssertEqual(potential.values[index],100*p.x,accuracy:1e-5) }
        var body = try input.rigidBody(id:part.id,sourceObjectID:part.id.uuidString.lowercased()); body.velocity = .init(0.1,0,0); body.sourceGeometrySHA256 = before
        var physics = PhysicsSimulationConfiguration(); physics.gravity = .zero; physics.bodies = [body]
        physics.time.durationSeconds = 0.1; physics.time.stepSeconds = 0.005; physics.time.outputIntervalSeconds = 0.025
        var study = SimulationStudy(name:"Mesh motion",kind:.rigidBody); try study.setConfiguration(physics)
        let result = try await RapierSimulationBackend().solve(.init(source:source,study:study)) { _ in }
        let graph = SimulationAnimationGraph(source:source,durationSeconds:0.1,physicsResultID:result.id,physicsBindings:[.init(targetID:body.sourceObjectID,bodyID:body.id)])
        let base = try cad.simulationGLBSource(expectedGeometrySHA256:before)
        let targets = base.targets.map { SimulationGLBTarget(sourceObjectID:$0.objectID,nodeIndex:$0.nodeIndex,originMeters:.init($0.originMM[0]*0.001,$0.originMM[1]*0.001,$0.originMM[2]*0.001)) }
        let store = try SimulationArchiveStore(directory:project.appendingPathComponent("Simulation"))
        var workspace = SimulationWorkspaceDocument(source:source,studies:[study]); workspace.animationGraphData = try JSONEncoder().encode(graph)
        let model = SimulationWorkbenchModel(document:workspace,coordinator:.init(archive:store),archive:store)
        let graphBake = try await SimulationAnimationBaker.bake(graph,physics:result,framesPerSecond:20) { _ in }
        let pose = try XCTUnwrap(graphBake.frames.last)
        let display = try CADSimulationDisplayBuilder.make(geometry:geometry,source:source,result:result,frame:nil,field:nil,physics:physics,pose:pose,deformation:1,graph:graph)
        let displayed = try XCTUnwrap(display.surfaces.first?.positionsMM.first)
        XCTAssertEqual(Double(displayed.x),part.positionsMM[0][0]+10,accuracy:1e-4)
        try await store.saveResult(result,request:.init(id:result.requestID,source:source,study:study))
        // Use the real model lifecycle, format callback and project-owned staging.
        model.animationExportHandler = { request in
            try await CADSimulationAnimationExport.write(request,document:cad,geometry:geometry)
        }
        // A model normally loads this cache through its coordinator/archive.
        let savedResults = try await store.savedResults()
        await model.showSavedResult(try XCTUnwrap(savedResults.first))
        await model.bakeAnimation(format:.glb,framesPerSecond:20)
        XCTAssertNil(model.errorDetails)
        let glb = try XCTUnwrap(model.exportURL), glbID = try XCTUnwrap(model.savedAnimationExports.first?.id)
        let glbBytes = try Data(contentsOf:glb)
        let glbAttachment = XCTAttachment(data:glbBytes,uniformTypeIdentifier:"org.khronos.glb"); glbAttachment.name = "Imported-Mesh-motion.glb"; glbAttachment.lifetime = .keepAlways; add(glbAttachment)
        await model.bakeAnimation(format:.mp4,framesPerSecond:20)
        XCTAssertNil(model.errorDetails)
        let video = try XCTUnwrap(model.exportURL), bytes = try Data(contentsOf:video)
        XCTAssertTrue(video.lastPathComponent.hasSuffix(".mp4")); XCTAssertGreaterThan(bytes.count,100)
        let videoAttachment = XCTAttachment(data:bytes,uniformTypeIdentifier:"public.mpeg-4"); videoAttachment.name = "Imported-Mesh-motion.mp4"; videoAttachment.lifetime = .keepAlways; add(videoAttachment)
        XCTAssertEqual(try cad.simulationGeometry().contentSHA256,before)
        await model.close(); let saved = await cad.save(); XCTAssertNil(saved.error); cad.close()
        let moved = root.appendingPathComponent("Moved.floeproject")
        try FileManager.default.moveItem(at:project,to:moved)
        let reopened = try await FloeCADDocument.open(at:moved.appendingPathComponent("Document.floecad"))
        defer { reopened.close() }
        XCTAssertEqual(try reopened.simulationGeometry().contentSHA256,before)
        let movedArchive = try SimulationArchiveStore(directory:moved.appendingPathComponent("Simulation"))
        let records = try await movedArchive.savedAnimationExports(source:source)
        XCTAssertEqual(records.count,2)
        let restoredGLB = try await movedArchive.animationExportURL(id:glbID,source:source)
        XCTAssertEqual(try Data(contentsOf:restoredGLB),glbBytes)
        reopened.close()
    }
}
