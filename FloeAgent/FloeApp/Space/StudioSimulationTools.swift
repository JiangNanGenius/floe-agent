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
    static let readCommands: Set<String> = ["definitions","simulation.read","simulation.objects","simulation.capabilities","simulation.templates","simulation.study.read","simulation.materials","simulation.mesh.info","simulation.jobs","simulation.mesh.jobs","simulation.results","simulation.result.info","simulation.result.field","simulation.animation.read","simulation.animation.status"]
    static let writeCommands: Set<String> = ["simulation.study.put","simulation.material.put","simulation.run","simulation.mesh.generate","simulation.cancel","simulation.mesh.cancel","simulation.export","simulation.animation.put","simulation.animation.preview","simulation.animation.bake","simulation.animation.cancel"]
    static let toolDescription = "Use Simulation & Animation inside the bound CAD original. definitions returns installed commands and their JSON schemas; then read simulation.templates, simulation.read and simulation.mesh.info to obtain actual configurations, generation, region/face IDs and SI units. inputJSON is an ordinary JSON object string. All edits and starts carry expectedGeneration from the last read, and study updates also expectedRevision. Meshing always captures the current visible CAD parts; no path or replacement CAD geometry is accepted. run and mesh.generate return service-owned jobIDs; poll jobs/results, then read fields or export CSV. animation.read returns the shared animation graph; animation.put takes {expectedGeneration,graph}; preview/bake take {expectedGeneration}, use that saved graph and its explicit physicsResultID; status reports progress and saved animation JSON, cancel stops the shared bake. Results and files return to the same saved CAD work; no authoritative CAD placement is overwritten."
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
                let schema: [String:Any] = ["type":"object","properties":["expectedGeneration":["type":"integer","minimum":0],"graph":["type":"object"]],"required": mutating && name != "simulation.animation.cancel" ? ["expectedGeneration"]:[],"additionalProperties":false]
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
        struct Input: Decodable { var expectedGeneration: UInt64?; var graph: SimulationAnimationGraph? }
        let input = try JSONDecoder().decode(Input.self,from:arguments)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        if command == "simulation.animation.read" {
            struct Read: Encodable { var generation: UInt64; var graph: SimulationAnimationGraph }
            let graph = try snapshot.document.animationGraphData.map { try JSONDecoder().decode(SimulationAnimationGraph.self,from:$0) } ?? .init(source:snapshot.document.source)
            return try encoder.encode(Read(generation:snapshot.generation,graph:graph))
        }
        if command == "simulation.animation.status" {
            struct Status: Encodable { var baking: Bool; var progress: SimulationProgress?; var file: URL?; var error: String? }
            let file = model.exportURL.flatMap { $0.lastPathComponent.hasSuffix(".animation.json") ? $0:nil }
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
        if let resultID = model.animationGraph.physicsResultID {
            try await model.loadSavedResults()
            guard let result = model.savedResults.first(where: { $0.id == resultID }) else { throw FloeError.validationFailed("The graph's physics result is missing.") }
            await model.showSavedResult(result)
        }
        guard await model.workspace.snapshot().generation == snapshot.generation, model.sourceAvailable else { throw SimulationError.staleSource }
        if command == "simulation.animation.preview" {
            model.previewAnimation()
            guard let pose = model.animationPose else { throw FloeError.validationFailed(model.errorDetails ?? "The animation could not be evaluated.") }
            return try encoder.encode(pose)
        }
        guard command == "simulation.animation.bake" else { throw PersonalContentError.invalidProject }
        await withTaskCancellationHandler { await model.bakeAnimation() } onCancel: { Task { @MainActor in model.cancelBake() } }
        guard let file = model.exportURL, model.errorDetails == nil else { throw FloeError.validationFailed(model.errorDetails ?? "The animation bake was cancelled.") }
        return try encoder.encode(["url":file])
    }
}
private struct SimulationAnimationCommit: Encodable { var generation: UInt64 }
#endif
