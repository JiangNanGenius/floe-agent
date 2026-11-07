import Foundation
import FloeSimulationCore

public struct SimulationMeshSettings: Codable, Equatable, Sendable {
    public var maximumSizeMeters: Double
    public var minimumSizeMeters: Double
    public var growthRate: Double
    public var curvatureRefinement: Bool
    public var localSizes: [String: Double]
    public init(maximumSizeMeters: Double = 0.005, minimumSizeMeters: Double = 0.0001, growthRate: Double = 0.3, curvatureRefinement: Bool = true, localSizes: [String: Double] = [:]) {
        self.maximumSizeMeters = maximumSizeMeters; self.minimumSizeMeters = minimumSizeMeters; self.growthRate = growthRate; self.curvatureRefinement = curvatureRefinement; self.localSizes = localSizes
    }
    public func validate() throws {
        guard maximumSizeMeters.isFinite, minimumSizeMeters.isFinite, minimumSizeMeters > 0, maximumSizeMeters >= minimumSizeMeters,
              growthRate.isFinite, growthRate > 0, growthRate <= 1,
              localSizes.values.allSatisfy({ $0.isFinite && $0 >= minimumSizeMeters && $0 <= maximumSizeMeters }) else { throw SimulationError.invalidInput("Invalid mesh sizes, growth rate or local refinement.") }
    }
}

public protocol SimulationGeometryDriver: Sendable {
    var isAvailable: Bool { get }
    func generate(_ geometry: SimulationGeometrySnapshot, settings: SimulationMeshSettings, budget: SimulationBudget, progress: @escaping SimulationProgressHandler) async throws -> SimulationMesh
}

public struct NativeSimulationMesher: Sendable {
    private let driver: (any SimulationGeometryDriver)?
    public init(driver: (any SimulationGeometryDriver)? = nil) { self.driver = driver }
    public var isAvailable: Bool { driver?.isAvailable == true }
    public func mesh(_ geometry: SimulationGeometrySnapshot, settings: SimulationMeshSettings, budget: SimulationBudget, progress: @escaping SimulationProgressHandler) async throws -> SimulationMesh {
        try geometry.validate(); try settings.validate(); try budget.validate()
        guard geometry.sourceLengthToMeters.isFinite, geometry.sourceLengthToMeters > 0, geometry.brep != nil || geometry.surface != nil else { throw SimulationError.invalidInput("A tagged CAD solid or closed surface snapshot is required.") }
        guard let driver, driver.isAvailable else { throw SimulationError.backendUnavailable("The Netgen/OCCT meshing artifact is not linked in this host.") }
        try Task.checkCancellation()
        let mesh = try await driver.generate(geometry, settings: settings, budget: budget, progress: progress)
        try Task.checkCancellation(); try mesh.validate()
        guard mesh.source == geometry.source else { throw SimulationError.staleSource }
        guard mesh.nodes.count <= budget.maximumNodes, mesh.elements.count <= budget.maximumElements else { throw SimulationError.resourceLimit("The generated mesh exceeds this study's budget.") }
        return mesh
    }
}

public struct SimulationSurfaceFace: Equatable, Sendable {
    public var elementIndex: Int
    public var localFace: Int
    public var nodes: [Int]
    public var outwardNormal: SimulationVector3
    public var areaSquareMeters: Double
}

public enum SimulationMeshTopology {
    /// Rejects nonmanifold volume faces and keeps oriented source connectivity.
    public static func exteriorFaces(_ mesh: SimulationMesh) throws -> [SimulationSurfaceFace] {
        try mesh.validate()
        guard mesh.elements.allSatisfy({ $0.kind == .tetrahedron4 }) else { throw SimulationError.unsupported("Exterior tetrahedron faces are required for this conversion.") }
        var incidence: [[Int]: [SimulationSurfaceFace]] = [:]
        for (elementIndex, element) in mesh.elements.enumerated() {
            for localFace in 0..<4 {
                var indices = element.nodes.enumerated().filter { $0.offset != localFace }.map(\.element)
                let a = mesh.nodes[indices[0]], b = mesh.nodes[indices[1]], c = mesh.nodes[indices[2]]
                var normal = (b-a).cross(c-a)
                if normal.dot(mesh.nodes[element.nodes[localFace]] - a) > 0 { indices.swapAt(1,2); normal = -normal }
                guard normal.length > 0 else { throw SimulationError.invalidInput("A surface face is degenerate.") }
                incidence[indices.sorted(), default: []].append(.init(elementIndex: elementIndex, localFace: localFace, nodes: indices, outwardNormal: normal / normal.length, areaSquareMeters: normal.length / 2))
            }
        }
        guard incidence.values.allSatisfy({ $0.count <= 2 }) else { throw SimulationError.invalidInput("The volume mesh is nonmanifold.") }
        return incidence.values.filter { $0.count == 1 }.compactMap(\.first).sorted { $0.elementIndex == $1.elementIndex ? $0.localFace < $1.localFace : $0.elementIndex < $1.elementIndex }
    }
}

/// An actual explicit geometry primitive for qualification and user-created boxes.
/// It is never used as an approximation of an arbitrary imported CAD body.
public enum SimulationBoxMesher {
    public static func generate(source: SimulationSourceRef, minimum: SimulationVector3 = .zero, maximum: SimulationVector3, divisions: [Int] = [1,1,1], regionID: String = "body", budget: SimulationBudget = .init()) throws -> SimulationMesh {
        try source.validate(); try budget.validate()
        guard minimum.isFinite, maximum.isFinite, maximum.x > minimum.x, maximum.y > minimum.y, maximum.z > minimum.z,
              divisions.count == 3, divisions.allSatisfy({ $0 > 0 && $0 <= 256 }) else { throw SimulationError.invalidInput("Invalid box dimensions or subdivisions.") }
        let nx = divisions[0], ny = divisions[1], nz = divisions[2]
        guard (nx+1)*(ny+1)*(nz+1) <= budget.maximumNodes, nx*ny*nz*6 <= budget.maximumElements else { throw SimulationError.resourceLimit("The box mesh exceeds its node or element budget.") }
        func index(_ i: Int, _ j: Int, _ k: Int) -> Int { (k * (ny+1) + j) * (nx+1) + i }
        var nodes: [SimulationVector3] = [], elements: [SimulationElement] = [], boundaryNodes: [String:[Int]] = [:]
        for k in 0...nz { for j in 0...ny { for i in 0...nx {
            let n = nodes.count
            nodes.append(.init(minimum.x + (maximum.x-minimum.x)*Double(i)/Double(nx), minimum.y + (maximum.y-minimum.y)*Double(j)/Double(ny), minimum.z + (maximum.z-minimum.z)*Double(k)/Double(nz)))
            for (selected, name) in [(i==0,"xmin"),(i==nx,"xmax"),(j==0,"ymin"),(j==ny,"ymax"),(k==0,"zmin"),(k==nz,"zmax")] where selected { boundaryNodes[name, default: []].append(n) }
        } } }
        let pattern = [[0,1,3,7],[0,3,2,7],[0,2,6,7],[0,6,4,7],[0,4,5,7],[0,5,1,7]]
        for k in 0..<nz { for j in 0..<ny { for i in 0..<nx {
            let corners = [index(i,j,k),index(i+1,j,k),index(i,j+1,k),index(i+1,j+1,k),index(i,j,k+1),index(i+1,j,k+1),index(i,j+1,k+1),index(i+1,j+1,k+1)]
            for tetrahedron in pattern {
                var connectivity = tetrahedron.map { corners[$0] }
                let a = nodes[connectivity[0]], b = nodes[connectivity[1]], c = nodes[connectivity[2]], d = nodes[connectivity[3]]
                if (b-a).dot((c-a).cross(d-a)) < 0 { connectivity.swapAt(1,2) }
                elements.append(.init(kind: .tetrahedron4, nodes: connectivity, regionID: regionID))
            }
        } } }
        let boundaries = boundaryNodes.keys.sorted().map { SimulationBoundary(id: $0, sourceEntityID: "box/" + $0, nodeIndices: boundaryNodes[$0]!) }
        var mesh = SimulationMesh(source: source, nodes: nodes, elements: elements, boundaries: boundaries)
        let exterior = try SimulationMeshTopology.exteriorFaces(mesh)
        for index in mesh.boundaries.indices {
            let nodes = Set(mesh.boundaries[index].nodeIndices)
            mesh.boundaries[index].facets = exterior.filter { $0.nodes.allSatisfy { nodes.contains($0) } }.map { .init(elementIndex:$0.elementIndex,localFace:$0.localFace) }
        }
        try mesh.validate(); return mesh
    }
}
