import Foundation
import Testing
import FloeSimulationCore
import FloeSimulationPhysics

private func m04source() -> SimulationSourceRef { .init(projectID:UUID(),documentID:UUID(),revision:1,contentSHA256:String(repeating:"b",count:64)) }
private func m04solve(_ configuration:PhysicsSimulationConfiguration) async throws -> SimulationResult {
    var study = SimulationStudy(name:"Mesh physics",kind:.rigidBody); try study.setConfiguration(configuration)
    return try await RapierSimulationBackend().solve(.init(source:m04source(),study:study)) { _ in }
}
private func m04frameMesh() throws -> SimulationPhysicsMesh {
    let triangles:[UInt32] = [0,2,1,0,3,2,4,5,6,4,6,7,0,1,5,0,5,4,3,7,6,3,6,2,1,2,6,1,6,5,0,4,7,0,7,3]
    var vertices:[SimulationVector3] = [], indices:[UInt32] = []
    for x in [-0.75,0.75] {
        let start = UInt32(vertices.count)
        vertices += [.init(x-0.25,-0.15,-0.25),.init(x+0.25,-0.15,-0.25),.init(x+0.25,0.15,-0.25),.init(x-0.25,0.15,-0.25),.init(x-0.25,-0.15,0.25),.init(x+0.25,-0.15,0.25),.init(x+0.25,0.15,0.25),.init(x-0.25,0.15,0.25)]
        indices += triangles.map { $0+start }
    }
    return try .init(vertices:vertices,indices:indices)
}
@Test func mesh04ConcaveDynamicColliderPreservesTheGap() async throws {
    let mesh = try m04frameMesh(); #expect(mesh.isClosed)
    var frame = try mesh.rigidBody(sourceObjectID:"frame"); frame.massKg = 1000
    #expect(frame.collider.kind == .convexDecomposition)
    var ball = SimulationPhysicsBody(sourceObjectID:"ball"); ball.collider.kind = .sphere; ball.collider.radius = 0.1
    ball.translation = .init(0,1,0); ball.velocity = .init(0,-4,0); ball.restitution = 0
    var scene = PhysicsSimulationConfiguration(); scene.gravity = .zero; scene.bodies = [frame,ball]
    scene.time.durationSeconds = 0.5; scene.time.stepSeconds = 0.005; scene.time.outputIntervalSeconds = 0.05
    let actual = try await m04solve(scene)
    let position = try #require(actual.frames.last?.fields.first { $0.id == "body_position" })
    #expect(abs(position.values[4]+1) < 0.02)
    scene.bodies[0].collider.kind = .convexHull
    let hull = try await m04solve(scene)
    let filled = try #require(hull.frames.last?.fields.first { $0.id == "body_position" })
    #expect(filled.values[4] > 0,"The control convex hull fills the gap; decomposition must not")
}
@Test func mesh04OpenTriangleMeshCollidesAsFixedSurface() async throws {
    let mesh = try SimulationPhysicsMesh(vertices:[.init(-2,0,-2),.init(2,0,-2),.init(2,0,2),.init(-2,0,2)],indices:[0,2,1,0,3,2])
    #expect(!mesh.isClosed)
    let floor = try mesh.rigidBody(sourceObjectID:"floor",motion:.fixed)
    var ball = SimulationPhysicsBody(sourceObjectID:"ball"); ball.translation = .init(0,1,0); ball.collider.kind = .sphere; ball.collider.radius = 0.1; ball.restitution = 0
    var scene = PhysicsSimulationConfiguration(); scene.bodies = [floor,ball]; scene.time.durationSeconds = 0.8
    let result = try await m04solve(scene)
    let position = try #require(result.frames.last?.fields.first { $0.id == "body_position" })
    #expect(position.values[4] > 0.07 && position.values[4] < 0.15)
}
@Test func mesh04ImportedClothWeldsSeamsAndRetainsSourceMapping() async throws {
    let source:[SimulationVector3] = [.init(-1,1,0),.init(1,1,0),.init(1,1,1),.init(-1,1,1),.init(-1,1,0),.init(1,1,1)]
    let mesh = try SimulationPhysicsMesh(vertices:source,indices:[0,1,2,4,5,3])
    #expect(mesh.vertices.count == 4); #expect(mesh.sourceVertexToParticle == [0,1,2,3,0,2])
    var cloth = try mesh.softBody(sourceObjectID:"imported-cloth"); cloth.pinnedIndices = [0,1]
    var scene = PhysicsSimulationConfiguration(); scene.softBodies = [cloth]; scene.time.durationSeconds = 0.15
    let result = try await m04solve(scene), field = try #require(result.frames.last?.fields.first { $0.id.hasPrefix("soft/") })
    #expect(field.values.count == 12); #expect(abs(field.values[1]-1) < 1e-10); #expect(abs(field.values[4]-1) < 1e-10)
    #expect(field.values[7] < 0.999); #expect(source[2].y == 1)
    let raw = try #require(result.diagnostics["soft/"+cloth.id.uuidString+"/sourceVertexToParticle"])
    #expect(try JSONDecoder().decode([UInt32].self,from:Data(raw.utf8)) == mesh.sourceVertexToParticle)
}
@Test func mesh04RefusesMalformedOrStaleMeshBeforeNativeSolve() throws {
    #expect(throws:(any Error).self) { try SimulationPhysicsMesh(vertices:[.zero,.init(1,0,0),.init(2,0,0)],indices:[0,1,2]) }
    #expect(throws:(any Error).self) { try SimulationPhysicsMesh(vertices:[.zero,.init(1,0,0),.init(0,1,0)],indices:[0,1,9]) }
    let mesh = try m04frameMesh(); var body = try mesh.rigidBody(sourceObjectID:"source")
    body.sourceGeometrySHA256 = String(repeating:"c",count:64)
    var scene = PhysicsSimulationConfiguration(); scene.bodies = [body]
    var study = SimulationStudy(name:"Stale",kind:.rigidBody); try study.setConfiguration(scene)
    #expect(throws:(any Error).self) { try RapierSimulationBackend().validate(.init(source:m04source(),study:study)) }
    let legacy = SimulationPhysicsSoftBody(sourceObjectID:"legacy",kind:.cloth)
    let decoded = try JSONDecoder().decode(SimulationPhysicsSoftBody.self,from:JSONEncoder().encode(legacy))
    #expect(decoded.meshVertices == nil); #expect(decoded.particleCount == 100)
}
