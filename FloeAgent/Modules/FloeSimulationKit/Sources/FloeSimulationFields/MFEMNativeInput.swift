import Foundation
import FloeSimulationCore
import FloeSimulationGeometry

struct MFEMNativeInput {
    var mesh: SimulationMesh
    var coordinates: [Double]
    var tetrahedra: [Int32]
    var regionIDs: [String]
    var regions: [Int32]
    var triangles: [Int32]
    var boundaryIDs: [String]
    var boundaries: [Int32]

    init(_ request: SimulationRequest, boundaryIDs selectedIDs: [String]) throws {
        guard let mesh = request.mesh else { throw SimulationError.invalidInput("Create a volume mesh first.") }
        guard mesh.elements.allSatisfy({ $0.kind == .tetrahedron4 }) else { throw SimulationError.unsupported("This field artifact requires tetrahedral volume elements.") }
        guard mesh.nodes.count <= 200_000, mesh.elements.count <= 1_000_000 else { throw SimulationError.resourceLimit("The mesh exceeds the native field budget.") }
        self.mesh = mesh
        coordinates = mesh.nodes.flatMap { [$0.x,$0.y,$0.z] }; tetrahedra = mesh.elements.flatMap { $0.nodes.map(Int32.init) }
        regionIDs = Set(mesh.elements.map(\.regionID)).sorted()
        let regionLookup = Dictionary(uniqueKeysWithValues:regionIDs.enumerated().map { ($0.element,Int32($0.offset)) })
        regions = mesh.elements.map { regionLookup[$0.regionID]! }
        let exterior = try SimulationMeshTopology.exteriorFaces(mesh)
        let known = Set(exterior.map { SimulationBoundaryFacet(elementIndex:$0.elementIndex,localFace:$0.localFace) })
        var attributes: [SimulationBoundaryFacet:Int32] = [:]
        boundaryIDs = selectedIDs.sorted()
        for (index,id) in boundaryIDs.enumerated() {
            guard let boundary = mesh.boundaries.first(where:{ $0.id == id }) else { throw SimulationError.invalidInput("A selected field boundary is missing.") }
            let facets: [SimulationBoundaryFacet]
            if let exact = boundary.facets, !exact.isEmpty { facets = exact }
            else {
                let nodes = Set(boundary.nodeIndices)
                facets = exterior.filter { $0.nodes.allSatisfy { nodes.contains($0) } }.map { .init(elementIndex:$0.elementIndex,localFace:$0.localFace) }
            }
            guard !facets.isEmpty, facets.allSatisfy({ known.contains($0) }) else { throw SimulationError.invalidInput("A field boundary must refer to exterior volume facets.") }
            for facet in facets {
                guard attributes[facet] == nil else { throw SimulationError.invalidInput("Field conditions overlap on the same volume face.") }
                attributes[facet] = Int32(index)
            }
        }
        var unassigned = "__floe_unassigned__"
        while boundaryIDs.contains(unassigned) { unassigned += "_" }
        let unassignedIndex = Int32(boundaryIDs.count); boundaryIDs.append(unassigned)
        triangles = exterior.flatMap { $0.nodes.map(Int32.init) }
        boundaries = exterior.map { attributes[.init(elementIndex:$0.elementIndex,localFace:$0.localFace)] ?? unassignedIndex }
    }

    static func validateElectrodes(_ configuration: ElectromagneticSimulationConfiguration, mesh: SimulationMesh) throws {
        var potentials: [Int:Double] = [:]
        for boundary in configuration.boundaries where boundary.kind == .electricPotential || boundary.kind == .perfectElectric {
            let value = boundary.kind == .perfectElectric ? 0 : boundary.value.real
            for node in try SimulationSelection.boundary(boundary.boundaryID).resolveNodes(in:mesh) {
                if let old = potentials[node], abs(old-value) > max(1,abs(old),abs(value))*1e-12 { throw SimulationError.invalidInput("Two prescribed potentials conflict at a shared mesh node.") }
                potentials[node] = value
            }
        }
    }
}
