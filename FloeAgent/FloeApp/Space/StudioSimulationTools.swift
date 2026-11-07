// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloeTools
import FloeCAD
import FloeSimulationCore
import FloeSimulationRuntime
import FloeSimulationUI
import FloeSimulationAnimation

struct StudioSimulationTool: AgentTool {
    struct Arguments: Decodable, Sendable { let projectID: UUID; let command: String; let inputJSON: String? }
    static let name = "studio.simulation"
    static let readCommands: Set<String> = ["definitions","simulation.read","simulation.objects","simulation.capabilities","simulation.templates","simulation.study.read","simulation.materials","simulation.mesh.info","simulation.jobs","simulation.mesh.jobs","simulation.results","simulation.result.info","simulation.result.field","simulation.animation.read","simulation.animation.status","simulation.animation.exports","simulation.animation.source","simulation.animation.export.read"]
    static let writeCommands: Set<String> = ["simulation.study.put","simulation.material.put","simulation.run","simulation.mesh.generate","simulation.cancel","simulation.mesh.cancel","simulation.export","simulation.animation.put","simulation.animation.preview","simulation.animation.bake","simulation.animation.cancel","simulation.animation.mesh.bind","simulation.animation.mesh.use","simulation.animation.morph.put","simulation.animation.ragdoll","simulation.animation.source.import","simulation.animation.physics.attach"]
    static let toolDescription = "Use Simulation & Animation inside the bound CAD original. definitions returns installed commands and their JSON schemas; then read simulation.templates, simulation.read and simulation.mesh.info to obtain actual configurations, generation, region/face IDs and SI units. inputJSON is an ordinary JSON object string. All edits and starts carry expectedGeneration from the last read, and study updates also expectedRevision. Meshing always captures the current visible CAD parts; no path or replacement CAD geometry is accepted. run and mesh.generate return service-owned jobIDs; poll jobs/results, then read fields or export CSV. animation.read returns the shared animation graph; animation.put takes {expectedGeneration,graph}; preview takes {expectedGeneration}; bake accepts {expectedGeneration,format: animation.json|glb|mp4,framesPerSecond: 1...240 (MP4 <=60)}, use that saved graph and its explicit physicsResultID; mesh.use builds real rigid/cloth/volume colliders for objectID in the selected studyID; mesh.bind skins an object to existing bones; morph.put edits one named source vertex Morph; ragdoll creates actual bodies/joints; source.import imports the existing rig/active clip; physics.attach binds a saved resultID; exports lists checksummed project-owned files, export.read takes exportID, status reports progress and exported motion/GLB/MP4, cancel stops the shared bake. Results and files return to the same saved CAD work; no authoritative CAD placement is overwritten."
    static let parametersJSON: String = {
        let schema: [String:Any] = ["type":"object","properties":["projectID":["type":"string","format":"uuid"],"command":["type":"string","enum":Array(readCommands.union(writeCommands)).sorted()],"inputJSON":["type":"string","maxLength":524288]],"required":["projectID","command"],"additionalProperties":false]
        return String(decoding:try! JSONSerialization.data(withJSONObject:schema,options:.sortedKeys),as:UTF8.self)
    }()
    static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .internalState
    let coordinator: StudioCoordinator
    func validate(_ arguments: Arguments) throws {
        guard Self.readCommands.union(Self.writeCommands).contains(arguments.command),
              (arguments.inputJSON?.utf8.count ?? 0) <= 524_288,
              (try? JSONSerialization.jsonObject(with:Data((arguments.inputJSON ?? "{}").utf8))) is [String:Any] else {
            throw FloeError.validationFailed("Use a listed simulation command with an object inputJSON.")
        }
    }
    func execute(_ arguments: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(arguments)
        return try await coordinator.simulation(id:arguments.projectID,command:arguments.command,arguments:Data((arguments.inputJSON ?? "{}").utf8),context:context)
    }
}

extension StudioCoordinator {
    func simulation(id: UUID, command: String, arguments: Data, context: ToolContext) async throws -> ToolExecutionOutput {
        let editing = StudioSimulationTool.writeCommands.contains(command)
        let location = try await location(id,context:context,editing:editing,allowedNames:[StudioSimulationTool.name])
        guard location.record.kind == .cad3D || location.record.kind == .cad2D else { throw PersonalContentError.invalidProject }
        if editing, context.approvalGrantID == nil { throw FloeError.validationFailed("The task's existing approval grant is required for this operation.") }
        let lease = try PersonalLibraryFileActions.acquireUse(id:id,directory:location.url)
        defer { lease.release() }
        let cad = try await PersonalCADSessions.open(id:id,directory:location.url)
        let entry = try await CADSimulationSessions.open(document:cad,directory:location.url.appendingPathComponent("Simulation",isDirectory:true),ownerID:id)
        let model = entry.model!
        let snapshot = await model.workspace.snapshot()
        let taskID = try await conversation(context,allowedNames:[StudioSimulationTool.name])
        let authority: SimulationToolAuthorizer = { [weak self, weak entry] access, source, task in
            guard let self else { throw SimulationError.staleSource }
            let currentTask = try await self.conversation(context,allowedNames:[StudioSimulationTool.name])
            guard currentTask == task, source.projectID == id else { throw SimulationError.staleSource }
            let mutation = access != .read
            _ = try await self.location(id,context:context,editing:mutation,allowedNames:[StudioSimulationTool.name])
            try await MainActor.run {
                guard let entry else { throw SimulationError.staleSource }
                if mutation, context.approvalGrantID == nil { throw FloeError.validationFailed("A task approval grant is required.") }
                try entry.requireCurrent(source)
            }
        }
        let tools = SimulationWorkbenchFactory.tools(for:model,authorize:authority)
        let bound = SimulationToolContext(taskID:taskID,source:snapshot.document.source,expectedGeneration:snapshot.generation)
        let output: Data
        if command == "definitions" {
            struct Definition: Encodable { var name: String; var description: String; var inputSchema: SimulationJSONValue }
            var definitions = try await tools.definitions(bound).map { value in
                Definition(name:value.name,description:value.description,inputSchema:try JSONDecoder().decode(SimulationJSONValue.self,from:value.inputSchema))
            }
            let objectSchema: [String:Any] = ["type":"object","properties":["offset":["type":"integer","minimum":0],"limit":["type":"integer","minimum":1,"maximum":64]],"additionalProperties":false]
            definitions.append(.init(name:"simulation.objects",description:"Read a page of actual CAD object IDs, names and rest transforms in SI units before authoring physics/animation bindings.",inputSchema:try JSONDecoder().decode(SimulationJSONValue.self,from:JSONSerialization.data(withJSONObject:objectSchema))))
            for name in Self.animationCommands {
                let mutating = StudioSimulationTool.writeCommands.contains(name)
                var properties:[String:Any] = ["expectedGeneration":["type":"integer","minimum":0]]
                var required = mutating && name != "simulation.animation.cancel" ? ["expectedGeneration"]:[]
                switch name {
                case "simulation.animation.put": properties["graph"] = ["type":"object"]; required.append("graph")
                case "simulation.animation.bake": properties["format"] = ["type":"string","enum":["animation.json","glb","mp4"]]; properties["framesPerSecond"] = ["type":"integer","minimum":1,"maximum":240]
                case "simulation.animation.mesh.bind": properties["objectID"] = ["type":"string"]; required.append("objectID")
                case "simulation.animation.mesh.use": properties["objectID"] = ["type":"string"]; properties["studyID"] = ["type":"string","format":"uuid"]; properties["mode"] = ["type":"string","enum":["rigid","cloth","volume"]]; required += ["objectID","studyID","mode"]
                case "simulation.animation.morph.put":
                    properties["objectID"] = ["type":"string"]; properties["name"] = ["type":"string"]; properties["vertexIndex"] = ["type":"integer","minimum":0]; properties["offsetMeters"] = ["type":"object","properties":["x":["type":"number"],"y":["type":"number"],"z":["type":"number"]],"required":["x","y","z"],"additionalProperties":false]; properties["startWeight"] = ["type":"number"]; properties["endWeight"] = ["type":"number"]; required += ["objectID","name","vertexIndex","offsetMeters"]
                case "simulation.animation.ragdoll": properties["pinRoot"] = ["type":"boolean"]
                case "simulation.animation.physics.attach": properties["resultID"] = ["type":"string","format":"uuid"]; required.append("resultID")
                case "simulation.animation.export.read": properties["exportID"] = ["type":"string","format":"uuid"]; required.append("exportID")
                default: break
                }
                let schema:[String:Any] = ["type":"object","properties":properties,"required":required,"additionalProperties":false]
                definitions.append(.init(name:name,description:StudioSimulationTool.toolDescription,inputSchema:try JSONDecoder().decode(SimulationJSONValue.self,from:JSONSerialization.data(withJSONObject:schema))))
            }
            output = try JSONEncoder().encode(definitions)
        }
        else if command == "simulation.objects" {
            try await authority(.read,bound.source,taskID)
            struct Input: Decodable { var offset: Int?; var limit: Int? }
            struct Page: Encodable { var source: SimulationSourceRef; var generation: UInt64; var offset: Int; var total: Int; var nextOffset: Int?; var objects: [SimulationSourceObject] }
            let input = try JSONDecoder().decode(Input.self,from:arguments), offset = input.offset ?? 0, limit = input.limit ?? 32
            guard offset >= 0, offset <= model.sourceObjects.count, (1...64).contains(limit) else { throw SimulationError.invalidInput("Use a valid CAD object page.") }
            let end = min(offset+limit,model.sourceObjects.count)
            output = try JSONEncoder().encode(Page(source:bound.source,generation:bound.expectedGeneration,offset:offset,total:model.sourceObjects.count,nextOffset:end < model.sourceObjects.count ? end:nil,objects:Array(model.sourceObjects[offset..<end])))
        }
        else if command.hasPrefix("simulation.animation.") {
            try await authority(editing ? .edit : .read,bound.source,taskID)
            output = try await simulationAnimation(command:command,arguments:arguments,model:model,snapshot:snapshot)
        } else { output = try await tools.invoke(name:command,arguments:arguments,context:bound) }
        try context.cancellation.throwIfCancelled()
        if editing {
            try await PersonalContentService.shared.library().markChanged(id)
            NotificationCenter.default.post(name:.floeStudioDocumentDidChange,object:id)
        }
        struct Receipt: Encodable { let projectID: UUID; let output: SimulationJSONValue }
        return try StudioToolOutput.make(Receipt(projectID:id,output:JSONDecoder().decode(SimulationJSONValue.self,from:output)))
    }
    private static var animationCommands: [String] { StudioSimulationTool.readCommands.union(StudioSimulationTool.writeCommands).filter { $0.hasPrefix("simulation.animation.") }.sorted() }
    private func simulationAnimation(command: String, arguments: Data, model: SimulationWorkbenchModel, snapshot: SimulationWorkspaceSnapshot) async throws -> Data {
        struct Input: Decodable {
            var expectedGeneration:UInt64?; var graph:SimulationAnimationGraph?
            var format:SimulationAnimationExportFormat?; var framesPerSecond:Int?
            var objectID:String?; var studyID:UUID?; var mode:String?
            var name:String?; var vertexIndex:Int?; var offsetMeters:SimulationVector3?; var startWeight:Double?; var endWeight:Double?
            var pinRoot:Bool?; var resultID:UUID?; var exportID:UUID?
        }
        let input = try JSONDecoder().decode(Input.self,from:arguments)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        if command == "simulation.animation.read" {
            struct Read: Encodable { var generation: UInt64; var graph: SimulationAnimationGraph }
            let graph = try snapshot.document.animationGraphData.map { try JSONDecoder().decode(SimulationAnimationGraph.self,from:$0) } ?? .init(source:snapshot.document.source)
            return try encoder.encode(Read(generation:snapshot.generation,graph:graph))
        }
        if command == "simulation.animation.source" {
            struct Source:Encodable { var graph:SimulationAnimationGraph?; var message:String? }
            return try encoder.encode(Source(graph:model.sourceAnimationGraph,message:model.sourceAnimationMessage))
        }
        if command == "simulation.animation.exports" { return try encoder.encode(await model.archive.savedAnimationExports(source:snapshot.document.source)) }
        if command == "simulation.animation.export.read" {
            guard let id = input.exportID else { throw SimulationError.invalidInput("Choose a saved exportID.") }
            return try encoder.encode(["url":await model.archive.animationExportURL(id:id,source:snapshot.document.source)])
        }
        if command == "simulation.animation.status" {
            struct Status: Encodable { var baking: Bool; var progress: SimulationProgress?; var file: URL?; var error: String? }
            let file = model.exportURL
            return try encoder.encode(Status(baking:model.baking,progress:model.bakeProgress,file:file,error:model.errorDetails))
        }
        if command == "simulation.animation.cancel" { model.cancelBake(); return Data(#"{"cancellationRequested":true}"#.utf8) }
        guard input.expectedGeneration == snapshot.generation else { throw SimulationError.staleSource }
        if command == "simulation.animation.put" {
            guard let graph = input.graph, graph.source == snapshot.document.source else { throw SimulationError.staleSource }
            try graph.validate()
            var candidate = snapshot.document; candidate.animationGraphData = try encoder.encode(graph)
            let committed = try await model.workspace.commit(candidate,expectedGeneration:snapshot.generation)
            return try encoder.encode(SimulationAnimationCommit(generation:committed.generation))
        }
        guard !model.hasUnsavedChanges, !model.baking else { throw FloeError.validationFailed("Save the open simulation edits and wait for any active bake first.") }
        await model.reopen()
        guard await model.workspace.snapshot().generation == snapshot.generation, model.document.source == snapshot.document.source else { throw SimulationError.staleSource }
        if command == "simulation.animation.mesh.bind" {
            guard let id = input.objectID else { throw SimulationError.invalidInput("Choose an objectID from simulation.objects.") }
            await model.bindSourceMesh(id)
        } else if command == "simulation.animation.mesh.use" {
            guard let id = input.objectID,let studyID = input.studyID,let mode = input.mode,["rigid","cloth","volume"].contains(mode),
                  snapshot.document.studies.contains(where: { $0.id == studyID && [.rigidBody,.softBody].contains($0.kind) }) else { throw SimulationError.invalidInput("Choose a rigid/soft studyID, source objectID and mode.") }
            model.selectedStudyID = studyID
            await model.useSourceMesh(id,asSoftBody:mode != "rigid",preserveVolume:mode == "volume")
        } else if command == "simulation.animation.morph.put" {
            guard let id = input.objectID,let name = input.name,let index = input.vertexIndex,let delta = input.offsetMeters else { throw SimulationError.invalidInput("Supply objectID, Morph name, vertexIndex and offsetMeters.") }
            model.setMeshMorph(objectID:id,name:name,vertexIndex:index,offset:delta,startWeight:input.startWeight ?? 0,endWeight:input.endWeight ?? 1)
        } else if command == "simulation.animation.ragdoll" { model.createRagdoll(pinRoot:input.pinRoot ?? false) }
        else if command == "simulation.animation.source.import" {
            guard model.sourceAnimationGraph != nil else { throw SimulationError.invalidInput(model.sourceAnimationMessage ?? "This model has no existing rig or active clip.") }
            model.importSourceAnimation()
        }
        if ["simulation.animation.mesh.bind","simulation.animation.mesh.use","simulation.animation.morph.put","simulation.animation.ragdoll","simulation.animation.source.import"].contains(command) {
            guard model.errorDetails == nil,model.hasUnsavedChanges,await model.save() else { throw FloeError.validationFailed(model.errorDetails ?? "The animation edit was not saved.") }
            return try encoder.encode(SimulationAnimationCommit(generation:await model.workspace.snapshot().generation))
        }
        if let resultID = command == "simulation.animation.physics.attach" ? input.resultID:model.animationGraph.physicsResultID {
            try await model.loadSavedResults()
            guard let result = model.savedResults.first(where: { $0.id == resultID }) else { throw FloeError.validationFailed("The graph's physics result is missing.") }
            await model.showSavedResult(result)
        }
        if command == "simulation.animation.physics.attach" {
            guard input.resultID != nil,model.result != nil else { throw SimulationError.invalidInput("Choose a saved physics resultID.") }
            model.attachCurrentPhysicsCache()
            guard model.hasUnsavedChanges,await model.save() else { throw FloeError.validationFailed(model.errorDetails ?? "The physics cache could not be attached.") }
            return try encoder.encode(SimulationAnimationCommit(generation:await model.workspace.snapshot().generation))
        }
        guard await model.workspace.snapshot().generation == snapshot.generation, model.sourceAvailable else { throw SimulationError.staleSource }
        if command == "simulation.animation.preview" {
            model.previewAnimation()
            guard let pose = model.animationPose else { throw FloeError.validationFailed(model.errorDetails ?? "The animation could not be evaluated.") }
            return try encoder.encode(pose)
        }
        guard command == "simulation.animation.bake" else { throw PersonalContentError.invalidProject }
        await withTaskCancellationHandler { await model.bakeAnimation(format:input.format ?? .motionJSON,framesPerSecond:input.framesPerSecond ?? 30) } onCancel: { Task { @MainActor in model.cancelBake() } }
        guard let file = model.exportURL, model.errorDetails == nil else { throw FloeError.validationFailed(model.errorDetails ?? "The animation bake was cancelled.") }
        // Loading the first physics cache can save its result ID while baking.
        // Return that committed generation so the next edit uses the current CAS.
        struct Bake: Encodable { var generation:UInt64; var url:URL }
        return try encoder.encode(Bake(generation:await model.workspace.snapshot().generation,url:file))
    }
}
private struct SimulationAnimationCommit: Encodable { var generation: UInt64 }
#endif
