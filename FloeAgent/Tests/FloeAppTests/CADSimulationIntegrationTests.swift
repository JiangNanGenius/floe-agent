// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import XCTest
import FloeCAD
import FloeCore
import FloeTools
import FloeSecurity
import FloePersistence
import FloeSimulationCore
import FloeSimulationRuntime
import FloeSimulationGeometry
import FloeSimulationFields
import FloeSimulationPhysics
import FloeSimulationAnimation
@testable import FloeApp

@MainActor final class CADSimulationIntegrationTests: XCTestCase {
    private func box(_ document: FloeCADDocument) throws {
        let sketch = document.execute(["op":"sketch.create","args":["name":"Simulation source"]])
        XCTAssertTrue(sketch.isOK,sketch.message ?? "")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with:sketch.payload) as? [String:Any])
        let id = try XCTUnwrap(payload["sketchID"] as? String)
        for command: [String:Any] in [
            ["op":"sketch.addEntities","args":["sketchID":id,"entities":[["kind":"rect","min":[0,0],"max":[20,20]]]]],
            ["op":"feature.extrude","args":["sketchID":id,"seedPoint":[10,10],"distance":20]]
        ] { let outcome = document.execute(command); XCTAssertTrue(outcome.isOK,outcome.message ?? "") }
    }
    func testActualCADCaptureNativeFieldsAndDisplayReturnToOriginal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("simulation03-"+UUID().uuidString)
        let cad = try await FloeCADDocument.create(at:root.appendingPathComponent("Document.floecad"),name:"Actual 20 mm cube")
        do {
            try box(cad)
            let entry = try await CADSimulationSessions.open(document:cad)
            let same = try await CADSimulationSessions.open(document:cad)
            XCTAssertTrue(entry === same)
            let source = entry.source, snapshot = try entry.snapshot(source)
            XCTAssertNotNil(snapshot.brep)
            let mesh = try await NativeSimulationMesher(driver:NetgenSimulationGeometryDriver()).mesh(snapshot,
                settings:.init(maximumSizeMeters:0.01,minimumSizeMeters:0.002),budget:.init(maximumNodes:10_000,maximumElements:40_000)) { _ in }
            let volume = mesh.elements.reduce(0.0) { value, element in
                let p = element.nodes.map { mesh.nodes[$0] }
                return value+abs((p[1]-p[0]).dot((p[2]-p[0]).cross(p[3]-p[0])))/6
            }
            XCTAssertEqual(volume,8e-6,accuracy:8e-11)
            let first = try XCTUnwrap(mesh.boundaries.first { $0.nodeIndices.allSatisfy { abs(mesh.nodes[$0].x) < 1e-8 } })
            let last = try XCTUnwrap(mesh.boundaries.first { $0.nodeIndices.allSatisfy { abs(mesh.nodes[$0].x-0.02) < 1e-8 } })
            var config = ElectromagneticSimulationConfiguration()
            config.boundaries = [.init(boundaryID:first.id,kind:.electricPotential),.init(boundaryID:last.id,kind:.electricPotential,value:.init(real:2))]
            let vacuum = SimulationMaterial(name:"Vacuum",properties:["relativePermittivity":1])
            let assignments = Dictionary(uniqueKeysWithValues:Set(mesh.elements.map(\.regionID)).map { ($0,vacuum.id) })
            var study = SimulationStudy(name:"CAD capacitor",kind:.electrostatic,materialAssignments:assignments); study.meshID = mesh.id; try study.setConfiguration(config)
            let request = SimulationRequest(source:source,study:study,mesh:mesh,materials:[vacuum])
            let result = try await MFEMSimulationDriver().solve(request) { _ in }
            let frame = try XCTUnwrap(result.frames.first), field = try XCTUnwrap(frame.fields.first { $0.id == "potential" })
            for (i,p) in mesh.nodes.enumerated() { XCTAssertEqual(field.values[i],100*p.x,accuracy:1e-5) }
            let display = try CADSimulationDisplayBuilder.make(geometry:entry.geometry,source:source,result:result,frame:frame,field:field,physics:entry.model.physics,pose:nil,deformation:1)
            XCTAssertFalse(display.surfaces.isEmpty); XCTAssertTrue(display.legend?.contains("V") == true)
            try await entry.model.archive.saveResult(result,request:request)
            let csv = try await entry.model.archive.exportCSV(result)
            XCTAssertTrue(try String(contentsOf:csv,encoding:.utf8).contains("potential"))
            let identity = try cad.simulationGeometry().contentSHA256
            XCTAssertEqual(identity,source.contentSHA256,"Analysis/display/export never write CAD geometry")
            // A configured initial pose is absolute. The renderer must not
            // subtract the edited initial translation or apply it twice.
            var physics = entry.model.physics
            let body = try XCTUnwrap(physics.bodies.first), cadBody = try XCTUnwrap(entry.geometry.bodies.first)
            physics.bodies[0].translation = .init(0.1,0.2,0.3)
            let q = sqrt(0.5); physics.bodies[0].rotation = .init(z:q,w:q)
            let poseFrame = SimulationResultFrame(id:0,timeSeconds:0,fields:[
                .init(id:"body_position",name:"Position",unit:"m",location:.global,components:3,values:[0.1,0.2,0.3]),
                .init(id:"body_visible",name:"Visible",unit:"1",location:.global,components:1,values:[1]),
                .init(id:"body_rotation",name:"Rotation",unit:"1",location:.global,components:4,values:[0,0,q,q])])
            let posed = SimulationResult(requestID:UUID(),source:source,studyID:study.id,backend:.init(id:"floe.rapier",version:"0.36.1",supportedStudies:[.rigidBody],isAvailable:true),frames:[poseFrame],diagnostics:["bodyIDs":body.id.uuidString,"bodySourceObjectIDs":String(decoding:try JSONEncoder().encode([body.sourceObjectID]),as:UTF8.self)])
            let moved = try CADSimulationDisplayBuilder.make(geometry:entry.geometry,source:source,result:posed,frame:poseFrame,field:nil,physics:physics,pose:nil,deformation:1)
            let firstPosition = try XCTUnwrap(moved.surfaces.first?.positionsMM.first)
            let raw = try XCTUnwrap(cadBody.positionsMM.first), origin = body.translation
            XCTAssertEqual(firstPosition.x,Float(1000*(0.1-(raw[1]*0.001-origin.y))),accuracy:1e-4)
            XCTAssertEqual(firstPosition.y,Float(1000*(0.2+(raw[0]*0.001-origin.x))),accuracy:1e-4)
            XCTAssertEqual(firstPosition.z,Float(1000*(0.3+(raw[2]*0.001-origin.z))),accuracy:1e-4)
            let graph = SimulationAnimationGraph(source:source,physicsResultID:posed.id,physicsBindings:[.init(targetID:body.sourceObjectID,bodyID:body.id)])
            let pose = try SimulationAnimationEvaluator.evaluate(graph,timeSeconds:0,physics:posed)
            let animated = try CADSimulationDisplayBuilder.make(geometry:entry.geometry,source:source,result:posed,frame:poseFrame,field:nil,physics:physics,pose:pose,deformation:1)
            XCTAssertEqual(animated.surfaces.first?.positionsMM,moved.surfaces.first?.positionsMM)
            try box(cad)
            XCTAssertFalse(entry.model.sourceAvailable,"The actual document callback fences immediately")
            XCTAssertThrowsError(try entry.requireCurrent(source))
            XCTAssertThrowsError(try FloeCAD3DBridge.shared.requireClosedForFileAction(at:root))
            entry.model.renameStudy("Preserved pending simulation settings")
            let closeOne = Task { @MainActor in try await CADSimulationSessions.close(document:cad) }
            let closeTwo = Task { @MainActor in try await CADSimulationSessions.close(document:cad) }
            try await closeOne.value; try await closeTwo.value
            let saved = try await entry.model.archive.readDocument()
            XCTAssertEqual(saved.studies.first?.name,"Preserved pending simulation settings")
            XCTAssertFalse(CADSimulationSessions.hasSession(under:root)); cad.close()
        } catch { try? await CADSimulationSessions.close(document:cad); cad.close(); try? FileManager.default.removeItem(at:root); throw error }
        try FileManager.default.removeItem(at:root)
    }

    private func call(_ name: String, _ arguments: [String:Any], _ context: ToolContext) async throws -> [String:Any] {
        let runner = try XCTUnwrap(ToolRunnerRegistry.shared.runner(named:name))
        let result = try await runner.execute(argumentsJSON:JSONSerialization.data(withJSONObject:arguments),context:context)
        return try XCTUnwrap(JSONSerialization.jsonObject(with:Data((result.capturedOutput ?? result.summary).utf8)) as? [String:Any])
    }
    func testRegisteredStudioSimulationOwnershipCASAndPhysicsAnimationExport() async throws {
        let environment = FloeAgentApp.liveEnvironment; try await environment.ensureDurableAutomationReady()
        let names = StudioCoordinator.names.union([StudioSimulationTool.name])
        var tasks: [UUID] = [], contexts: [ToolContext] = [], created: (UUID,FloeCADDocument)?
        do {
            for _ in 0..<2 {
                let id = UUID(), run = UUID(), now = Date(); tasks.append(id)
                try await environment.conversationStore.saveConversation(.init(id:id,title:"Simulation code contract",createdAt:now,updatedAt:now))
                _ = try await SQLiteWorkspaceStore(database:environment.database).ensureWorkspace(conversationID:id,title:"Simulation code contract")
                try await environment.conversationStore.setArchived(id:id,archived:true)
                try await environment.runStore.saveRun(.init(id:run,conversationID:id,state:"executing",goal:"Simulation code contract",startedAt:now))
                var context = ToolContext(runID:run,toolCallID:"simulation03-create",allowedToolNames:names,cancellation:CancellationToken(),conversationID:id)
                context.frozenEffectiveCatalogNames = names; context.approvalGrantID = UUID(); contexts.append(context)
            }
            let owner = contexts[0], foreign = contexts[1]
            let made = try await call("studio.create",["kind":"cad3D","title":"Simulation contract "+UUID().uuidString.prefix(8)],owner)
            let record = try XCTUnwrap(made["record"] as? [String:Any]), rawID = try XCTUnwrap(record["id"] as? String)
            let id = try XCTUnwrap(UUID(uuidString:rawID)), location = try await PersonalContentService.shared.library().resolve(id)
            let cad = try await PersonalCADSessions.open(id:id,directory:location.url); created = (id,cad); try box(cad)
            func invoke(_ command: String, _ input: [String:Any] = [:], _ context: ToolContext? = nil) async throws -> [String:Any] {
                try await call(StudioSimulationTool.name,["projectID":rawID,"command":command,"inputJSON":String(decoding:JSONSerialization.data(withJSONObject:input),as:UTF8.self)],context ?? owner)
            }
            do { _ = try await invoke("simulation.read",[:],foreign); XCTFail("Foreign project access") } catch {}
            var temporary = owner; temporary.temporaryReadOnly = true
            do { _ = try await invoke("simulation.read",[:],temporary); XCTFail("Temporary chat access") } catch {}
            let stateReceipt = try await invoke("simulation.read")
            let state = try XCTUnwrap(stateReceipt["output"] as? [String:Any])
            let generation = try XCTUnwrap(state["generation"] as? Int)
            let entry = try await CADSimulationSessions.open(document:cad,directory:location.url.appendingPathComponent("Simulation"),ownerID:id)
            XCTAssertEqual(entry.source.documentID,id,"A managed original keeps identity when its folder moves")
            let before = try cad.simulationGeometry().contentSHA256
            let definitionsReceipt = try await invoke("definitions")
            let definitions = try XCTUnwrap(definitionsReceipt["output"] as? [[String:Any]])
            XCTAssertTrue(definitions.contains { $0["name"] as? String == "simulation.run" && $0["inputSchema"] is [String:Any] })
            let initial = await entry.model.workspace.snapshot()
            var study = try XCTUnwrap(initial.document.studies.first)
            let previousRevision = study.revision
            var physics = try study.configuration(as:PhysicsSimulationConfiguration.self)
            physics.time.durationSeconds = 0.04; physics.time.stepSeconds = 0.005; physics.time.outputIntervalSeconds = 0.01
            try study.setConfiguration(physics)
            let config = try JSONSerialization.jsonObject(with:study.configuration)
            let put: [String:Any] = ["expectedGeneration":generation,"study":["id":study.id.uuidString,"name":study.name,"kind":study.kind.rawValue,"materialAssignments":[:],"configuration":config,"expectedRevision":previousRevision]]
            _ = try await invoke("simulation.study.put",put)
            do { _ = try await invoke("simulation.study.put",put); XCTFail("Stale generation overwrote state") } catch {}
            let current = await entry.model.workspace.snapshot(), savedStudy = try XCTUnwrap(current.document.studies.first)
            _ = try await invoke("simulation.run",["studyID":savedStudy.id.uuidString,"expectedStudyRevision":savedStudy.revision,"expectedGeneration":current.generation])
            for _ in 0..<300 {
                if await entry.model.coordinator.snapshots().first?.status.isTerminal == true { break }
                try await Task.sleep(for:.milliseconds(10))
            }
            let jobs = await entry.model.coordinator.snapshots()
            let job = try XCTUnwrap(jobs.first)
            XCTAssertEqual(job.status,.completed)
            let resultID = try XCTUnwrap(job.resultID)
            let exportReceipt = try await invoke("simulation.export",["resultID":resultID.uuidString])
            let exported = try XCTUnwrap(exportReceipt["output"] as? [String:Any])
            XCTAssertNotNil(exported["url"])
            let animationReceipt = try await invoke("simulation.animation.read")
            let read = try XCTUnwrap(animationReceipt["output"] as? [String:Any])
            var graph = try JSONDecoder().decode(SimulationAnimationGraph.self,from:JSONSerialization.data(withJSONObject:try XCTUnwrap(read["graph"])))
            graph.durationSeconds = 0.04; graph.physicsResultID = resultID
            let bodyID = try XCTUnwrap(physics.bodies.first?.id)
            graph.physicsBindings = [.init(targetID:bodyID.uuidString.lowercased(),bodyID:bodyID)]
            let graphObject = try JSONSerialization.jsonObject(with:JSONEncoder().encode(graph))
            _ = try await invoke("simulation.animation.put",["expectedGeneration":current.generation,"graph":graphObject])
            let animationGeneration = await entry.model.workspace.snapshot().generation
            let bakeReceipt = try await invoke("simulation.animation.bake",["expectedGeneration":animationGeneration])
            let baked = try XCTUnwrap(bakeReceipt["output"] as? [String:Any])
            XCTAssertTrue((baked["url"] as? String)?.hasSuffix(".animation.json") == true)
            do { _ = try await invoke("simulation.unknown"); XCTFail("Unknown command accepted") } catch {}
            XCTAssertEqual(try cad.simulationGeometry().contentSHA256,before)
            try await CADSimulationSessions.close(document:cad); cad.close()
            let library = try await PersonalContentService.shared.library()
            let folder = "Simulation move fixture "+String(UUID().uuidString.prefix(8))
            try await library.createFolder(folder,in:[])
            let beforeMove = try await library.resolve(id).record
            _ = try await library.move(id,to:[folder],expectedRelativePath:beforeMove.relativePath)
            let moved = try await library.resolve(id)
            let movedCAD = try await PersonalCADSessions.open(id:id,directory:moved.url); created = (id,movedCAD)
            let movedEntry = try await CADSimulationSessions.open(document:movedCAD,directory:moved.url.appendingPathComponent("Simulation"),ownerID:id)
            XCTAssertEqual(movedEntry.source.documentID,id)
            XCTAssertEqual(movedEntry.source,current.document.source,"Moving an unchanged original must preserve its source revision and digest")
            let restoredResults = try await movedEntry.model.archive.savedResults()
            XCTAssertEqual(try XCTUnwrap(restoredResults.first { $0.id == resultID }).source,movedEntry.source)
            let afterMoveReceipt = try await invoke("simulation.results")
            let afterMoveResults = try JSONDecoder().decode([SimulationSavedResult].self,from:JSONSerialization.data(withJSONObject:try XCTUnwrap(afterMoveReceipt["output"])))
            XCTAssertEqual(try XCTUnwrap(afterMoveResults.first { $0.id == resultID }).source,movedEntry.source)
            try await CADSimulationSessions.close(document:movedCAD); movedCAD.close()
            let freshRecord = try await PersonalContentService.shared.library().resolve(id).record
            _ = try await PersonalContentService.shared.library().softDelete(freshRecord)
            created = nil
        } catch {
            if let (_,cad) = created { try? await CADSimulationSessions.close(document:cad); cad.close() }
            for id in tasks { try? await environment.conversationStore.deleteConversation(id:id) }
            throw error
        }
        for id in tasks { try await environment.conversationStore.deleteConversation(id:id) }
    }
    func testSimulationCommandPolicyHasBoundedReadAndWriteCoverage() throws {
        let project = UUID().uuidString
        for command in StudioSimulationTool.readCommands {
            let input: [String:Any] = ["projectID":project,"command":command]
            XCTAssertEqual(OrdinaryDocumentActionProfile.role(forToolName:StudioSimulationTool.name,arguments:input),.readOnly)
            XCTAssertTrue(TypedMutationContract.specs(for:StudioSimulationTool.name,arguments:input).isEmpty)
        }
        for command in StudioSimulationTool.writeCommands {
            let input: [String:Any] = ["projectID":project,"command":command,"inputJSON":"{}"]
            XCTAssertNil(OrdinaryDocumentActionProfile.role(forToolName:StudioSimulationTool.name,arguments:input))
            XCTAssertEqual(TypedMutationContract.specs(for:StudioSimulationTool.name,arguments:input).count,1)
        }
        for command in ["simulation.unknown","exec.shell","studio.*"] {
            let input: [String:Any] = ["projectID":project,"command":command]
            XCTAssertNil(OrdinaryDocumentActionProfile.role(forToolName:StudioSimulationTool.name,arguments:input))
            XCTAssertTrue(TypedMutationContract.specs(for:StudioSimulationTool.name,arguments:input).isEmpty)
        }
    }
}
#endif
