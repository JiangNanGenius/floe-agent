import Foundation
import FloeSimulationCore

public struct SimulationToolBoundaryInfo: Codable, Sendable {
    public var id: String
    public var sourceEntityID: String
    public var nodeCount: Int
    public var facetCount: Int
    public var minimumMeters: SimulationVector3
    public var maximumMeters: SimulationVector3
}
public struct SimulationToolRegionInfo: Codable, Sendable {
    public var id: String
    public var elementCount: Int
    public var elementKinds: [SimulationElementKind]
}
public struct SimulationToolMeshInfo: Codable, Sendable {
    public var id: UUID
    public var source: SimulationSourceRef
    public var nodeCount: Int
    public var elementCount: Int
    public var totalRegions: Int
    public var regionOffset: Int
    public var regions: [SimulationToolRegionInfo]
    public var totalBoundaries: Int
    public var boundaryOffset: Int
    public var boundaries: [SimulationToolBoundaryInfo]
}
public struct SimulationToolStudyTemplate: Codable, Sendable {
    public var kind: SimulationStudyKind
    public var name: String
    public var configuration: SimulationJSONValue
    public var materialPropertyUnits: [String:String]
    public var prototypes: [String:SimulationJSONValue]
    public init(kind: SimulationStudyKind, name: String, configuration: SimulationJSONValue, materialPropertyUnits: [String:String] = [:], prototypes: [String:SimulationJSONValue] = [:]) {
        self.kind = kind; self.name = name; self.configuration = configuration; self.materialPropertyUnits = materialPropertyUnits; self.prototypes = prototypes
    }
}
public typealias SimulationToolTemplatesProvider = @Sendable () throws -> [SimulationToolStudyTemplate]

extension SimulationToolService {
    public func templates(_ context: SimulationToolContext) async throws -> [SimulationToolStudyTemplate] {
        _ = try await checked(context,access:.read)
        let kinds = Set(await coordinator.capabilities().filter(\.isAvailable).flatMap(\.supportedStudies))
        return try templatesProvider?().filter { kinds.contains($0.kind) } ?? []
    }
    public func meshInfo(meshID: UUID, boundaryOffset: Int = 0, regionOffset: Int = 0, limit: Int = 32, context: SimulationToolContext) async throws -> SimulationToolMeshInfo {
        let snapshot = try await checked(context,access:.read)
        guard let mesh = snapshot.document.meshes.first(where:{ $0.id == meshID }) else { throw SimulationError.invalidInput("The mesh is missing from this workspace.") }
        try mesh.validate()
        guard mesh.source == context.source else { throw SimulationError.staleSource }
        guard boundaryOffset >= 0, regionOffset >= 0, (1...64).contains(limit) else { throw SimulationError.invalidInput("Invalid mesh metadata page.") }
        var counts: [String:Int] = [:], kinds: [String:Set<SimulationElementKind>] = [:]
        for element in mesh.elements { counts[element.regionID,default:0] += 1; kinds[element.regionID,default:[]].insert(element.kind) }
        let ids = counts.keys.sorted(), boundaries = mesh.boundaries.sorted { $0.id < $1.id }
        guard boundaryOffset <= boundaries.count, regionOffset <= ids.count else { throw SimulationError.invalidInput("The requested mesh metadata page is missing.") }
        let selectedRegions = ids[regionOffset..<min(ids.count,regionOffset+limit)].map { id in
            SimulationToolRegionInfo(id:id,elementCount:counts[id]!,elementKinds:SimulationElementKind.allCases.filter { kinds[id]!.contains($0) })
        }
        let selectedBoundaries = boundaries[boundaryOffset..<min(boundaries.count,boundaryOffset+limit)].map { boundary in
            let points = boundary.nodeIndices.map { mesh.nodes[$0] }
            let lo = points.reduce(SimulationVector3(.infinity,.infinity,.infinity)) { .init(min($0.x,$1.x),min($0.y,$1.y),min($0.z,$1.z)) }
            let hi = points.reduce(SimulationVector3(-.infinity,-.infinity,-.infinity)) { .init(max($0.x,$1.x),max($0.y,$1.y),max($0.z,$1.z)) }
            return SimulationToolBoundaryInfo(id:boundary.id,sourceEntityID:boundary.sourceEntityID,nodeCount:points.count,facetCount:boundary.facets?.count ?? 0,minimumMeters:points.isEmpty ? .zero : lo,maximumMeters:points.isEmpty ? .zero : hi)
        }
        return .init(id:mesh.id,source:mesh.source,nodeCount:mesh.nodes.count,elementCount:mesh.elements.count,totalRegions:ids.count,regionOffset:regionOffset,regions:selectedRegions,totalBoundaries:boundaries.count,boundaryOffset:boundaryOffset,boundaries:selectedBoundaries)
    }
}
