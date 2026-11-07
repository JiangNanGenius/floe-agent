import Foundation
import FloeSimulationCore
import FloeSimulationGeometry

/// JSON configuration stays an object on the AI boundary, rather than a
/// base64-encoded Data value. Decoding never creates execution authority.
public enum SimulationJSONValue: Codable, Equatable, Sendable {
    case object([String:Self]), array([Self]), string(String), number(Double), bool(Bool), null
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([Self].self) { self = .array(v) }
        else { self = .object(try c.decode([String:Self].self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}

public struct SimulationToolDefinition: Codable, Equatable, Sendable {
    public var name: String
    public var description: String
    public var access: SimulationToolAccess
    public var inputSchema: Data
}

public struct SimulationToolStudyInput: Codable, Sendable {
    public var id: UUID
    public var expectedRevision: UInt64?
    public var name: String
    public var kind: SimulationStudyKind
    public var meshID: UUID?
    public var materialAssignments: [String:UUID]
    public var configuration: SimulationJSONValue
    public init(id: UUID = UUID(), expectedRevision: UInt64? = nil, name: String, kind: SimulationStudyKind, meshID: UUID? = nil, materialAssignments: [String:UUID] = [:], configuration: SimulationJSONValue) {
        self.id = id; self.expectedRevision = expectedRevision; self.name = name; self.kind = kind; self.meshID = meshID; self.materialAssignments = materialAssignments; self.configuration = configuration
    }
}

public struct SimulationToolStudyInfo: Codable, Sendable {
    public var id: UUID
    public var revision: UInt64
    public var name: String
    public var kind: SimulationStudyKind
    public var meshID: UUID?
    public var materialAssignments: [String:UUID]
    public var configuration: SimulationJSONValue?
    init(_ study: SimulationStudy, includingConfiguration: Bool) throws {
        id = study.id; revision = study.revision; name = study.name; kind = study.kind; meshID = study.meshID; materialAssignments = study.materialAssignments
        configuration = includingConfiguration && !study.configuration.isEmpty ? try JSONDecoder().decode(SimulationJSONValue.self,from:study.configuration) : nil
    }
}

public struct SimulationToolWorkspaceOverview: Codable, Sendable {
    public var source: SimulationSourceRef
    public var generation: UInt64
    public var studies: [SimulationToolStudyInfo]
    public var materialIDs: [UUID]
    public var meshIDs: [UUID]
    public var resultIDs: [UUID]
}

public struct SimulationToolCommitReceipt: Codable, Sendable {
    public var source: SimulationSourceRef
    public var generation: UInt64
    public var studyRevisions: [String:UInt64]
    init(_ snapshot: SimulationWorkspaceSnapshot) {
        source = snapshot.document.source; generation = snapshot.generation
        studyRevisions = Dictionary(uniqueKeysWithValues:snapshot.document.studies.map { ($0.id.uuidString,$0.revision) })
    }
}

extension SimulationToolService {
    public func overview(_ context: SimulationToolContext) async throws -> SimulationToolWorkspaceOverview {
        let snapshot = try await checked(context,access:.read)
        return .init(source:snapshot.document.source,generation:snapshot.generation,studies:try snapshot.document.studies.map { try .init($0,includingConfiguration:false) },
                     materialIDs:snapshot.document.materials.map(\.id),meshIDs:snapshot.document.meshes.map(\.id),resultIDs:snapshot.document.resultIDs)
    }
    public func studyInfo(studyID: UUID, context: SimulationToolContext) async throws -> SimulationToolStudyInfo {
        let snapshot = try await checked(context,access:.read)
        guard let study = snapshot.document.studies.first(where:{ $0.id == studyID }) else { throw SimulationError.invalidInput("The study is missing.") }
        return try .init(study,includingConfiguration:true)
    }
    public func putStudyInput(_ input: SimulationToolStudyInput, context: SimulationToolContext) async throws -> SimulationWorkspaceSnapshot {
        let snapshot = try await checked(context,access:.edit)
        let old = snapshot.document.studies.first { $0.id == input.id }
        guard input.expectedRevision == old?.revision else { throw SimulationError.staleSource }
        guard case .object = input.configuration else { throw SimulationError.invalidInput("A study configuration must be a JSON object.") }
        var study = SimulationStudy(id:input.id,name:input.name,kind:input.kind,materialAssignments:input.materialAssignments)
        study.revision = old?.revision ?? 0; study.meshID = input.meshID
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        study.configuration = try encoder.encode(input.configuration)
        if old != nil { try study.touch() }
        // Keep the generation captured before encoding; a concurrent UI edit
        // is rejected at the shared workspace's commit boundary.
        var document = snapshot.document
        if let index = document.studies.firstIndex(where:{ $0.id == study.id }) { document.studies[index] = study }
        else { document.studies.append(study) }
        return try await workspace.commit(document,expectedGeneration:snapshot.generation)
    }

    /// The App binds these definitions to its existing catalog and permission
    /// service. Only installed backends are returned by capabilities.
    public func definitions(_ context: SimulationToolContext) async throws -> [SimulationToolDefinition] {
        _ = try await checked(context,access:.read)
        func definition(_ name: String, _ text: String, _ access: SimulationToolAccess, properties: [String:Any] = [:], required: [String] = []) throws -> SimulationToolDefinition {
            let schema: [String:Any] = ["type":"object","properties":properties,"required":required,"additionalProperties":false]
            return .init(name:name,description:text,access:access,inputSchema:try JSONSerialization.data(withJSONObject:schema,options:.sortedKeys))
        }
        let id: [String:Any] = ["type":"string","format":"uuid"]
        let nonnegative: [String:Any] = ["type":"integer","minimum":0]
        let study: [String:Any] = ["type":"object","properties":[
            "id":id,"expectedRevision":nonnegative,"name":["type":"string"],
            "kind":["type":"string","enum":SimulationStudyKind.allCases.map(\.rawValue)],"meshID":id,
            "materialAssignments":["type":"object","additionalProperties":id],"configuration":["type":"object"]],
            "required":["id","name","kind","materialAssignments","configuration"],"additionalProperties":false]
        var definitions = try [
            definition("simulation.read","Read current studies and generation before editing.",.read),
            definition("simulation.capabilities","List installed executable native simulation backends.",.read),
            definition("simulation.study.read","Read one study's JSON configuration and revision.",.read,properties:["studyID":id],required:["studyID"]),
            definition("simulation.study.put","Create or replace a study using the generation last read; existing studies require expectedRevision.",.edit,properties:["study":study,"expectedGeneration":nonnegative],required:["study","expectedGeneration"]),
            definition("simulation.materials","Read material definitions.",.read),
            definition("simulation.material.put","Create or update a material using SI properties and the generation last read.",.edit,properties:["material":["type":"object"],"expectedGeneration":nonnegative],required:["material","expectedGeneration"]),
            definition("simulation.run","Start the saved study revision and workspace generation last read.",.run,properties:["studyID":id,"expectedStudyRevision":nonnegative,"expectedGeneration":nonnegative,"backendID":["type":"string"]],required:["studyID","expectedStudyRevision","expectedGeneration"]),
            definition("simulation.mesh.info","Read material-region identities, stable source-face identities and SI bounds before assigning conditions.",.read,properties:["meshID":id,"boundaryOffset":nonnegative,"regionOffset":nonnegative,"limit":["type":"integer","minimum":1,"maximum":64]],required:["meshID"]),
            definition("simulation.jobs","Read simulation progress and result identities.",.read),
            definition("simulation.cancel","Cancel a workspace-owned simulation job.",.cancel,properties:["jobID":id],required:["jobID"]),
            definition("simulation.results","List saved results, including their source and study revisions.",.read),
            definition("simulation.result.info","Read a bounded page of result frame and field metadata.",.read,properties:["resultID":id,"frameOffset":nonnegative,"limit":["type":"integer","minimum":1,"maximum":64]],required:["resultID"]),
            definition("simulation.result.field","Read a bounded page of real and imaginary field values in SI units.",.read,properties:["resultID":id,"frameID":nonnegative,"fieldID":["type":"string"],"offset":nonnegative,"limit":["type":"integer","minimum":1,"maximum":4096]],required:["resultID","frameID","fieldID"]),
            definition("simulation.export","Export a saved result as CSV.",.export,properties:["resultID":id],required:["resultID"])
        ]
        if templatesProvider != nil { definitions.append(try definition("simulation.templates","Read full default configurations, SI property names and entity prototypes for installed backends.",.read)) }
        if meshing?.isAvailable == true {
            definitions += try [
                definition("simulation.mesh.generate","Generate a mesh from the current CAD snapshot and save it using the generation last read.",.run,properties:["studyID":id,"settings":["type":"object"],"expectedGeneration":nonnegative],required:["studyID","expectedGeneration"]),
                definition("simulation.mesh.jobs","Read meshing progress and saved mesh identities.",.read),
                definition("simulation.mesh.cancel","Cancel a workspace-owned native meshing job.",.cancel,properties:["jobID":id],required:["jobID"])
            ]
        }
        return definitions
    }

    /// Every branch calls the same authorized service used by native UI.
    /// The context comes from the App's task binding, never from arguments.
    public func invoke(name: String, arguments: Data, context: SimulationToolContext) async throws -> Data {
        guard arguments.count <= 8_000_000 else { throw SimulationError.resourceLimit("The simulation tool input is too large.") }
        let decoder = JSONDecoder(), encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        struct ID: Decodable { var studyID: UUID }
        struct Study: Decodable { var study: SimulationToolStudyInput; var expectedGeneration: UInt64 }
        struct Material: Decodable { var material: SimulationMaterial; var expectedGeneration: UInt64 }
        struct Mesh: Decodable { var studyID: UUID; var settings: SimulationMeshSettings?; var expectedGeneration: UInt64 }
        struct MeshInfo: Decodable { var meshID: UUID; var boundaryOffset: Int?; var regionOffset: Int?; var limit: Int? }
        struct Run: Decodable { var studyID: UUID; var expectedStudyRevision: UInt64; var backendID: String?; var expectedGeneration: UInt64 }
        struct Job: Decodable { var jobID: UUID }
        struct Result: Decodable { var resultID: UUID; var frameOffset: Int?; var limit: Int?; var frameID: Int?; var fieldID: String?; var offset: Int? }
        let output: Data
        func requireGeneration(_ generation: UInt64) throws { guard generation == context.expectedGeneration else { throw SimulationError.staleSource } }
        switch name {
        case "simulation.read": output = try encoder.encode(await overview(context))
        case "simulation.capabilities": output = try encoder.encode(await executableCapabilities(context))
        case "simulation.templates": output = try encoder.encode(await templates(context))
        case "simulation.study.read": output = try encoder.encode(await studyInfo(studyID:decoder.decode(ID.self,from:arguments).studyID,context:context))
        case "simulation.study.put":
            let input = try decoder.decode(Study.self,from:arguments); try requireGeneration(input.expectedGeneration)
            output = try encoder.encode(SimulationToolCommitReceipt(await putStudyInput(input.study,context:context)))
        case "simulation.materials": output = try encoder.encode(await read(context).document.materials)
        case "simulation.material.put":
            let input = try decoder.decode(Material.self,from:arguments); try requireGeneration(input.expectedGeneration)
            output = try encoder.encode(SimulationToolCommitReceipt(await putMaterial(input.material,context:context)))
        case "simulation.run":
            let input = try decoder.decode(Run.self,from:arguments)
            try requireGeneration(input.expectedGeneration)
            output = try encoder.encode(["jobID":await start(studyID:input.studyID,expectedStudyRevision:input.expectedStudyRevision,backendID:input.backendID,context:context)])
        case "simulation.jobs": output = try encoder.encode(await jobs(context))
        case "simulation.mesh.generate":
            let input = try decoder.decode(Mesh.self,from:arguments)
            try requireGeneration(input.expectedGeneration)
            output = try encoder.encode(["jobID":await generateMesh(studyID:input.studyID,settings:input.settings ?? .init(),context:context)])
        case "simulation.mesh.jobs": output = try encoder.encode(await meshJobs(context))
        case "simulation.mesh.info":
            let input = try decoder.decode(MeshInfo.self,from:arguments)
            output = try encoder.encode(await meshInfo(meshID:input.meshID,boundaryOffset:input.boundaryOffset ?? 0,regionOffset:input.regionOffset ?? 0,limit:input.limit ?? 32,context:context))
        case "simulation.mesh.cancel":
            try await cancelMesh(jobID:decoder.decode(Job.self,from:arguments).jobID,context:context)
            output = try encoder.encode(["cancellationRequested":true])
        case "simulation.cancel":
            try await cancel(jobID:decoder.decode(Job.self,from:arguments).jobID,context:context)
            output = try encoder.encode(["cancellationRequested":true])
        case "simulation.results": output = try encoder.encode(await savedResults(context))
        case "simulation.result.info":
            let input = try decoder.decode(Result.self,from:arguments)
            output = try encoder.encode(await resultInfo(resultID:input.resultID,frameOffset:input.frameOffset ?? 0,limit:input.limit ?? 16,context:context))
        case "simulation.result.field":
            let input = try decoder.decode(Result.self,from:arguments)
            guard let frame = input.frameID, let field = input.fieldID else { throw SimulationError.invalidInput("Choose a result frame and field.") }
            output = try encoder.encode(await self.field(resultID:input.resultID,frameID:frame,fieldID:field,offset:input.offset ?? 0,limit:input.limit ?? 1024,context:context))
        case "simulation.export": output = try encoder.encode(["url":await export(resultID:decoder.decode(Result.self,from:arguments).resultID,context:context)])
        default: throw SimulationError.unsupported("Unknown simulation command.")
        }
        guard output.count <= 96*1024 else { throw SimulationError.resourceLimit("Read a smaller result page.") }
        return output
    }
}
