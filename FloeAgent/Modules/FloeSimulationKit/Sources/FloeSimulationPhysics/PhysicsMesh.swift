import Foundation
import FloeSimulationCore

/// A collision/deformation input, never a replacement for the authored render Mesh.
public struct SimulationPhysicsMesh: Sendable {
    public var vertices: [SimulationVector3]
    public var triangles: [[UInt32]]
    public var sourceVertexToParticle: [UInt32]
    public var center: SimulationVector3
    public var isClosed: Bool

    private struct Edge: Hashable {
        var a: UInt32; var b: UInt32
        init(_ a: UInt32,_ b: UInt32) { self.a = min(a,b); self.b = max(a,b) }
    }
    public init(vertices: [SimulationVector3], indices: [UInt32], budget: SimulationBudget = .init()) throws {
        guard !vertices.isEmpty, vertices.count <= budget.maximumNodes,
              !indices.isEmpty, indices.count.isMultiple(of:3), indices.count/3 <= budget.maximumElements,
              vertices.allSatisfy(\.isFinite), indices.allSatisfy({ Int($0) < vertices.count }) else { throw SimulationError.invalidInput("Use a finite indexed triangle Mesh within the scene budget.") }
        var lookup: [SimulationVector3:UInt32] = [:], welded: [SimulationVector3] = [], mapping: [UInt32] = []
        for (i,p) in vertices.enumerated() {
            if i & 4095 == 0 { try Task.checkCancellation() }
            if let index = lookup[p] { mapping.append(index) }
            else { let index = UInt32(welded.count); lookup[p] = index; mapping.append(index); welded.append(p) }
        }
        let triangles = stride(from:0,to:indices.count,by:3).map { [mapping[Int(indices[$0])],mapping[Int(indices[$0+1])],mapping[Int(indices[$0+2])]] }
        try Self.validate(vertices:welded,triangles:triangles,budget:budget)
        self.vertices = welded; self.triangles = triangles; sourceVertexToParticle = mapping
        center = vertices.reduce(.zero,+)/Double(vertices.count)
        isClosed = Self.closed(triangles)
    }
    public static func validate(vertices:[SimulationVector3],triangles:[[UInt32]],budget:SimulationBudget,requireClosed:Bool = false) throws {
        guard vertices.count >= 3, vertices.count <= budget.maximumNodes, vertices.allSatisfy(\.isFinite),
              !triangles.isEmpty, triangles.count <= budget.maximumElements else { throw SimulationError.invalidInput("The Mesh has missing or over-budget geometry.") }
        var used = Set<UInt32>()
        for (i,triangle) in triangles.enumerated() {
            if i & 4095 == 0 { try Task.checkCancellation() }
            guard triangle.count == 3, Set(triangle).count == 3, triangle.allSatisfy({ Int($0) < vertices.count }) else { throw SimulationError.invalidInput("The Mesh has invalid triangle indices.") }
            let a = vertices[Int(triangle[0])], b = vertices[Int(triangle[1])], c = vertices[Int(triangle[2])]
            let area = (b-a).cross(c-a).length
            guard area.isFinite, area > 1e-18 else { throw SimulationError.invalidInput("Remove zero-area Mesh triangles before simulation.") }
            used.formUnion(triangle)
        }
        guard used.count == vertices.count else { throw SimulationError.invalidInput("Remove unused Mesh vertices before simulation.") }
        if requireClosed, !closed(triangles) { throw SimulationError.invalidInput("Dynamic volume collision and volume preservation need a closed, consistently oriented Mesh. Use a fixed triangle collider or cloth for an open surface.") }
    }
    private static func closed(_ triangles:[[UInt32]]) -> Bool {
        var edges: [Edge:(count:Int,direction:Int)] = [:]
        for triangle in triangles {
            for i in 0..<3 {
                let a = triangle[i], b = triangle[(i+1)%3], edge = Edge(a,b)
                var value = edges[edge] ?? (0,0); value.count += 1; value.direction += a < b ? 1:-1; edges[edge] = value
            }
        }
        return !edges.isEmpty && edges.values.allSatisfy { $0.count == 2 && $0.direction == 0 }
    }
    public func rigidBody(id:UUID = UUID(),sourceObjectID:String,motion:SimulationBodyMotion = .dynamic,collider:SimulationColliderKind? = nil) throws -> SimulationPhysicsBody {
        let kind = collider ?? (motion == .dynamic ? .convexDecomposition:.triangleMesh)
        guard [.convexHull,.convexDecomposition,.triangleMesh].contains(kind) else { throw SimulationError.invalidInput("Choose a Mesh collider.") }
        if motion == .dynamic, kind == .triangleMesh { throw SimulationError.invalidInput("Use convex decomposition for a dynamic Mesh.") }
        if kind == .convexDecomposition, !isClosed { throw SimulationError.invalidInput("Use a fixed triangle collider or cloth for an open Mesh.") }
        var body = SimulationPhysicsBody(id:id,sourceObjectID:sourceObjectID)
        body.motion = motion; body.translation = center; body.collider.kind = kind
        body.collider.vertices = vertices.map { $0-center }; body.collider.triangles = triangles
        return body
    }
    public func softBody(id:UUID = UUID(),sourceObjectID:String,preserveVolume:Bool = false) throws -> SimulationPhysicsSoftBody {
        guard !preserveVolume || isClosed else { throw SimulationError.invalidInput("Volume preservation needs a closed Mesh.") }
        var body = SimulationPhysicsSoftBody(id:id,sourceObjectID:sourceObjectID,kind:.mesh)
        body.meshVertices = vertices; body.meshTriangles = triangles; body.sourceVertexToParticle = sourceVertexToParticle
        body.preserveVolume = preserveVolume; body.shapeMatching = preserveVolume
        return body
    }
}
