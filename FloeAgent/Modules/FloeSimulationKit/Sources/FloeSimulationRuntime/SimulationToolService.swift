import Foundation
import FloeSimulationCore
import FloeSimulationGeometry

public enum SimulationToolAccess: String, Codable, Sendable { case read, edit, run, cancel, export }
/// The App supplies its existing task/permission check. Imported configuration
/// and model text never create an authorization callback or permission grant.
public typealias SimulationToolAuthorizer = @Sendable (SimulationToolAccess, SimulationSourceRef, UUID) async throws -> Void
public struct SimulationToolContext: Codable, Equatable, Sendable {
    public var taskID: UUID
    public var source: SimulationSourceRef
    public var expectedGeneration: UInt64
    public init(taskID: UUID, source: SimulationSourceRef, expectedGeneration: UInt64) { self.taskID = taskID; self.source = source; self.expectedGeneration = expectedGeneration }
}
public struct SimulationToolFieldPage: Codable, Equatable, Sendable {
    public var resultID: UUID
    public var frameID: Int
    public var fieldID: String
    public var unit: String
    public var components: Int
    public var offset: Int
    public var totalValues: Int
    public var values: [Double]
    public var imaginaryValues: [Double]?
    public var source: SimulationSourceRef
    public var isStale: Bool
}

public actor SimulationToolService {
    let workspace: SimulationWorkspaceStore
    let coordinator: SimulationCoordinator
    let archive: SimulationArchiveStore
    let meshing: SimulationMeshingService?
    let templatesProvider: SimulationToolTemplatesProvider?
    private let authorize: SimulationToolAuthorizer
    public init(workspace: SimulationWorkspaceStore, coordinator: SimulationCoordinator, archive: SimulationArchiveStore, meshing: SimulationMeshingService? = nil, templates: SimulationToolTemplatesProvider? = nil, authorize: @escaping SimulationToolAuthorizer) {
        self.workspace = workspace; self.coordinator = coordinator; self.archive = archive; self.authorize = authorize
        self.meshing = meshing
        self.templatesProvider = templates
    }
    public func read(_ context: SimulationToolContext) async throws -> SimulationWorkspaceSnapshot { try await checked(context,access:.read) }
    public func generateMesh(studyID: UUID, settings: SimulationMeshSettings, budget: SimulationBudget = .init(), context: SimulationToolContext) async throws -> UUID {
        _ = try await checked(context,access:.run); _ = try await checked(context,access:.edit)
        guard let meshing else { throw SimulationError.backendUnavailable("The CAD geometry provider is unavailable.") }
        return try await meshing.start(studyID:studyID,source:context.source,expectedGeneration:context.expectedGeneration,settings:settings,budget:budget)
    }
    public func meshJobs(_ context: SimulationToolContext) async throws -> [SimulationMeshJobSnapshot] {
        _ = try await checked(context,access:.read)
        return await meshing?.snapshots().filter { $0.source.projectID == context.source.projectID && $0.source.documentID == context.source.documentID } ?? []
    }
    public func cancelMesh(jobID: UUID, context: SimulationToolContext) async throws {
        _ = try await checked(context,access:.cancel)
        guard let meshing, await meshing.snapshots().contains(where:{ $0.id == jobID && $0.source.projectID == context.source.projectID && $0.source.documentID == context.source.documentID }) else { throw SimulationError.invalidInput("This mesh job belongs to another workspace.") }
        await meshing.cancel(jobID)
    }
    public func executableCapabilities(_ context: SimulationToolContext) async throws -> [SimulationBackendDescriptor] {
        _ = try await checked(context,access:.read); return await coordinator.capabilities().filter(\.isAvailable)
    }
    public func putStudy(_ study: SimulationStudy, context: SimulationToolContext) async throws -> SimulationWorkspaceSnapshot {
        var snapshot = try await checked(context,access:.edit)
        if let index = snapshot.document.studies.firstIndex(where:{ $0.id == study.id }) {
            guard study.revision > snapshot.document.studies[index].revision else { throw SimulationError.staleSource }
            snapshot.document.studies[index] = study
        } else { snapshot.document.studies.append(study) }
        return try await workspace.commit(snapshot.document,expectedGeneration:snapshot.generation)
    }
    public func putMaterial(_ material: SimulationMaterial, context: SimulationToolContext) async throws -> SimulationWorkspaceSnapshot {
        var snapshot = try await checked(context,access:.edit)
        if let index = snapshot.document.materials.firstIndex(where:{ $0.id == material.id }) { snapshot.document.materials[index] = material }
        else { snapshot.document.materials.append(material) }
        for index in snapshot.document.studies.indices where snapshot.document.usesMaterial(material.id,in:snapshot.document.studies[index]) { try snapshot.document.studies[index].touch() }
        return try await workspace.commit(snapshot.document,expectedGeneration:snapshot.generation)
    }
    public func putMesh(_ mesh: SimulationMesh, studyID: UUID, context: SimulationToolContext) async throws -> SimulationWorkspaceSnapshot {
        var snapshot = try await checked(context,access:.edit)
        try mesh.validate(); guard mesh.source == context.source, let index = snapshot.document.studies.firstIndex(where:{ $0.id == studyID }) else { throw SimulationError.staleSource }
        snapshot.document.meshes.removeAll { $0.id == mesh.id }; snapshot.document.meshes.append(mesh)
        snapshot.document.studies[index].meshID = mesh.id
        for affected in snapshot.document.studies.indices where snapshot.document.studies[affected].meshID == mesh.id { try snapshot.document.studies[affected].touch() }
        return try await workspace.commit(snapshot.document,expectedGeneration:snapshot.generation)
    }
    public func start(studyID: UUID, expectedStudyRevision: UInt64, backendID: String? = nil, budget: SimulationBudget = .init(), context: SimulationToolContext) async throws -> UUID {
        let snapshot = try await checked(context,access:.run)
        guard let study = snapshot.document.studies.first(where:{ $0.id == studyID }), study.revision == expectedStudyRevision else { throw SimulationError.staleSource }
        return try await workspace.start(studyID:studyID,expectedStudyRevision:study.revision,expectedGeneration:snapshot.generation,backendID:backendID,budget:budget)
    }
    public func jobs(_ context: SimulationToolContext) async throws -> [SimulationJobSnapshot] {
        _ = try await checked(context,access:.read)
        return await coordinator.snapshots().filter { $0.source.projectID == context.source.projectID && $0.source.documentID == context.source.documentID }
    }
    public func cancel(jobID: UUID, context: SimulationToolContext) async throws {
        _ = try await checked(context,access:.cancel)
        guard await coordinator.snapshots().contains(where:{ $0.id == jobID && $0.source.projectID == context.source.projectID && $0.source.documentID == context.source.documentID }) else { throw SimulationError.invalidInput("This job belongs to another workspace.") }
        await coordinator.cancel(jobID)
    }
    public func field(resultID: UUID, frameID: Int, fieldID: String, offset: Int = 0, limit: Int = 1024, context: SimulationToolContext) async throws -> SimulationToolFieldPage {
        let snapshot = try await checked(context,access:.read)
        guard offset >= 0, limit > 0, limit <= 4096 else { throw SimulationError.invalidInput("Invalid result page offset or limit.") }
        let result = try await ownedResult(resultID,source:context.source)
        guard let frame = result.frames.first(where:{ $0.id == frameID }), let field = frame.fields.first(where:{ $0.id == fieldID }), offset <= field.values.count else { throw SimulationError.invalidInput("The requested result field or page is missing.") }
        let end = min(field.values.count,offset+limit)
        let current = snapshot.document.studies.first { $0.id == result.studyID }
        return .init(resultID:resultID,frameID:frameID,fieldID:fieldID,unit:field.unit,components:field.components,offset:offset,totalValues:field.values.count,values:Array(field.values[offset..<end]),imaginaryValues:field.imaginaryValues.map { Array($0[offset..<end]) },source:result.source,isStale:result.source != snapshot.document.source || result.studyRevision != current?.revision)
    }
    public func export(resultID: UUID, context: SimulationToolContext) async throws -> URL {
        _ = try await checked(context,access:.export)
        let result = try await ownedResult(resultID,source:context.source)
        return try await archive.exportCSV(result)
    }
    func checked(_ context: SimulationToolContext, access: SimulationToolAccess) async throws -> SimulationWorkspaceSnapshot {
        try context.source.validate()
        try await authorize(access,context.source,context.taskID)
        try await workspace.requireOpen()
        let snapshot = await workspace.snapshot()
        guard context.expectedGeneration == snapshot.generation, context.source == snapshot.document.source else { throw SimulationError.staleSource }
        return snapshot
    }
    func ownedResult(_ id: UUID, source: SimulationSourceRef) async throws -> SimulationResult {
        let result = try await coordinator.result(id)
        guard result.source.projectID == source.projectID, result.source.documentID == source.documentID else { throw SimulationError.invalidInput("This result belongs to another workspace.") }
        return result
    }
}
