import Foundation
import FloeSimulationCore

public enum SimulationBodyMotion: String, Codable, Sendable, CaseIterable { case fixed, dynamic, kinematic }
public enum SimulationColliderKind: String, Codable, Sendable, CaseIterable { case sphere, box, capsule, convexHull, triangleMesh, convexDecomposition }
public struct SimulationCollider: Codable, Equatable, Sendable {
    public var kind: SimulationColliderKind = .box
    public var halfExtents = SimulationVector3(0.5,0.5,0.5)
    public var radius = 0.5
    public var halfHeight = 0.5
    public var vertices: [SimulationVector3] = []
    public var triangles: [[UInt32]] = []
    public init(kind: SimulationColliderKind = .box) { self.kind = kind }
}
public struct SimulationKinematicKey: Codable, Equatable, Sendable {
    public var timeSeconds: Double
    public var translation: SimulationVector3
    public var rotation: SimulationQuaternion
    public init(timeSeconds: Double, translation: SimulationVector3, rotation: SimulationQuaternion = .identity) { self.timeSeconds = timeSeconds; self.translation = translation; self.rotation = rotation }
}
public struct SimulationPhysicsBody: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var sourceObjectID: String
    public var motion: SimulationBodyMotion = .dynamic
    public var translation = SimulationVector3.zero
    public var rotation = SimulationQuaternion.identity
    public var velocity = SimulationVector3.zero
    public var angularVelocity = SimulationVector3.zero
    public var massKg = 1.0
    public var centerOfMassMeters = SimulationVector3.zero
    public var principalInertiaKgSquareMeters: SimulationVector3?
    public var inertiaOrientation = SimulationQuaternion.identity
    public var friction = 0.5
    public var restitution = 0.1
    public var linearDamping = 0.0
    public var angularDamping = 0.0
    public var activationTimeSeconds = 0.0
    public var lifetimeSeconds: Double?
    public var collider = SimulationCollider()
    public var kinematicKeys: [SimulationKinematicKey] = []
    public var sourceGeometrySHA256: String?
    public init(id: UUID = UUID(), sourceObjectID: String) { self.id = id; self.sourceObjectID = sourceObjectID }
}
public enum SimulationPhysicsJointKind: String, Codable, Sendable, CaseIterable { case fixed, spherical, revolute, prismatic, spring }
public struct SimulationPhysicsJoint: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var kind: SimulationPhysicsJointKind
    public var firstBody: UUID
    public var secondBody: UUID
    public var firstAnchor = SimulationVector3.zero
    public var secondAnchor = SimulationVector3.zero
    public var axis = SimulationVector3(0,1,0)
    public var limits: [Double] = []
    public var motorVelocity = 0.0
    public var motorForce = 0.0
    public var restLengthMeters = 1.0
    public var stiffness = 100.0
    public var damping = 1.0
    public init(id: UUID = UUID(), kind: SimulationPhysicsJointKind, firstBody: UUID, secondBody: UUID) { self.id = id; self.kind = kind; self.firstBody = firstBody; self.secondBody = secondBody }
}
public enum SimulationSoftBodyKind: String, Codable, Sendable, CaseIterable { case rope, cloth, volume, mesh }
public struct SimulationPhysicsSoftBody: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var sourceObjectID: String
    public var kind: SimulationSoftBodyKind
    public var origin = SimulationVector3(0,2,0)
    public var end = SimulationVector3(1,2,0)
    public var du = SimulationVector3(0.1,0,0)
    public var dv = SimulationVector3(0,0,0.1)
    public var halfExtents = SimulationVector3(0.5,0.5,0.5)
    public var dimensions = [10,10,4]
    public var pinnedIndices: [UInt32] = []
    public var particleMassKg = 0.01
    public var particleRadiusMeters = 0.005
    public var naturalFrequencyHz = 30.0
    public var dampingRatio = 1.0
    public var linearDamping = 0.1
    public var friction = 0.5
    public var selfCollision = false
    /// Optional additions keep previously saved regular-lattice scenes readable.
    public var meshVertices: [SimulationVector3]?
    public var meshTriangles: [[UInt32]]?
    public var sourceVertexToParticle: [UInt32]?
    public var shapeMatching: Bool?
    public var preserveVolume: Bool?
    public var sourceGeometrySHA256: String?
    public init(id: UUID = UUID(), sourceObjectID: String, kind: SimulationSoftBodyKind) { self.id = id; self.sourceObjectID = sourceObjectID; self.kind = kind }
    public var particleCount: Int {
        if kind == .mesh { return meshVertices?.count ?? 0 }
        guard dimensions.count == 3, dimensions.allSatisfy({ $0 >= 2 && $0 <= 256 }) else { return 0 }
        switch kind { case .rope: return dimensions[0]; case .cloth: return dimensions[0] * dimensions[1]; case .volume: return dimensions[0] * dimensions[1] * dimensions[2]; case .mesh: return 0 }
    }
}
public struct PhysicsSimulationConfiguration: Codable, Equatable, Sendable {
    public var bodies: [SimulationPhysicsBody] = []
    public var joints: [SimulationPhysicsJoint] = []
    public var softBodies: [SimulationPhysicsSoftBody] = []
    public var forceFields: [SimulationPhysicsForceField] = []
    public var gravity = SimulationVector3(0,-9.81,0)
    public var time = SimulationTimeSettings()
    public var seed: UInt64 = 1
    public init() {}
    public func validate(budget: SimulationBudget) throws {
        try budget.validate(); try time.validate(maximumSteps: budget.maximumIterations)
        guard gravity.isFinite, bodies.count <= 4096, forceFields.count <= 128, !bodies.isEmpty || !softBodies.isEmpty,
              Set(bodies.map(\.id)).count == bodies.count, Set(softBodies.map(\.id)).count == softBodies.count,
              Set(joints.map(\.id)).count == joints.count, joints.count <= 8192, softBodies.count <= 128 else { throw SimulationError.invalidInput("Invalid physics identities, gravity or object budget.") }
        func validRotation(_ q: SimulationQuaternion) -> Bool { q.isFinite && abs(q.x*q.x + q.y*q.y + q.z*q.z + q.w*q.w - 1) < 1e-6 }
        for body in bodies {
            guard !body.sourceObjectID.isEmpty, body.translation.isFinite, validRotation(body.rotation), body.velocity.isFinite, body.angularVelocity.isFinite,
                  body.massKg.isFinite, body.massKg > 0, body.friction.isFinite, body.friction >= 0, body.restitution.isFinite, (0...1).contains(body.restitution),
                  body.linearDamping.isFinite, body.linearDamping >= 0, body.angularDamping.isFinite, body.angularDamping >= 0,
                  body.activationTimeSeconds.isFinite, body.activationTimeSeconds >= 0, body.activationTimeSeconds <= time.durationSeconds,
                  body.lifetimeSeconds.map({ $0.isFinite && $0 > 0 }) ?? true else { throw SimulationError.invalidInput("Invalid rigid-body pose, mass, lifetime or material.") }
            let shape = body.collider
            guard body.centerOfMassMeters.isFinite, validRotation(body.inertiaOrientation), body.centerOfMassMeters == .zero || body.principalInertiaKgSquareMeters != nil else { throw SimulationError.invalidInput("A custom center of mass needs explicit principal inertia.") }
            if let inertia = body.principalInertiaKgSquareMeters {
                guard inertia.isFinite, min(inertia.x,inertia.y,inertia.z) > 0, inertia.x+inertia.y >= inertia.z, inertia.x+inertia.z >= inertia.y, inertia.y+inertia.z >= inertia.x else { throw SimulationError.invalidInput("Principal inertia must be positive and physically consistent.") }
            }
            switch shape.kind {
            case .sphere: guard shape.radius.isFinite, shape.radius > 0 else { throw SimulationError.invalidInput("Set a positive sphere radius.") }
            case .box: guard shape.halfExtents.isFinite, min(shape.halfExtents.x,shape.halfExtents.y,shape.halfExtents.z) > 0 else { throw SimulationError.invalidInput("Set positive box extents.") }
            case .capsule: guard shape.radius.isFinite, shape.radius > 0, shape.halfHeight.isFinite, shape.halfHeight > 0 else { throw SimulationError.invalidInput("Set positive capsule dimensions.") }
            case .convexHull, .triangleMesh, .convexDecomposition:
                guard shape.vertices.count >= (shape.kind == .triangleMesh ? 3:4), shape.vertices.count <= budget.maximumNodes, shape.vertices.allSatisfy(\.isFinite) else { throw SimulationError.invalidInput("Invalid collider vertices.") }
                if shape.kind != .convexHull {
                    guard shape.kind != .triangleMesh || body.motion != .dynamic else { throw SimulationError.invalidInput("Use convex decomposition for a dynamic Mesh, or choose a fixed/kinematic triangle collider.") }
                    try SimulationPhysicsMesh.validate(vertices:shape.vertices,triangles:shape.triangles,budget:budget,requireClosed:shape.kind == .convexDecomposition)
                    if shape.kind == .convexDecomposition, shape.triangles.count > 50_000 { throw SimulationError.resourceLimit("Simplify the collision mesh to 50,000 triangles or use a fixed triangle collider.") }
                }
            }
            guard body.kinematicKeys.isEmpty || body.motion == .kinematic else { throw SimulationError.invalidInput("Kinematic keys require a kinematic body.") }
            guard body.kinematicKeys.allSatisfy({ $0.timeSeconds.isFinite && $0.timeSeconds >= 0 && $0.timeSeconds <= time.durationSeconds && $0.translation.isFinite && validRotation($0.rotation) }),
                  zip(body.kinematicKeys,body.kinematicKeys.dropFirst()).allSatisfy({ $0.timeSeconds < $1.timeSeconds }) else { throw SimulationError.invalidInput("Kinematic keys must have ordered times and valid poses.") }
        }
        let ids = Set(bodies.map(\.id))
        for field in forceFields {
            guard field.acceleration.isFinite, field.center.isFinite, field.axis.isFinite, field.axis.length > 0, field.strength.isFinite,
                  field.softeningRadiusMeters.isFinite, field.softeningRadiusMeters > 0, Set(field.bodyIDs).isSubset(of:ids) else { throw SimulationError.invalidInput("Invalid force field or target bodies.") }
        }
        for joint in joints {
            guard ids.contains(joint.firstBody), ids.contains(joint.secondBody), joint.firstBody != joint.secondBody, joint.firstAnchor.isFinite, joint.secondAnchor.isFinite,
                  joint.axis.isFinite, joint.axis.length > 0, joint.limits.isEmpty || (joint.limits.count == 2 && joint.limits.allSatisfy(\.isFinite) && joint.limits[0] <= joint.limits[1]),
                  joint.motorVelocity.isFinite, joint.motorForce.isFinite, joint.motorForce >= 0, joint.restLengthMeters.isFinite, joint.restLengthMeters >= 0, joint.stiffness.isFinite, joint.stiffness > 0, joint.damping.isFinite, joint.damping >= 0 else { throw SimulationError.invalidInput("Invalid joint endpoints, limits or drive.") }
        }
        var particles = 0
        for soft in softBodies {
            guard soft.particleCount > 0, soft.particleCount <= budget.maximumNodes, soft.origin.isFinite, soft.end.isFinite, soft.du.isFinite, soft.dv.isFinite, soft.halfExtents.isFinite,
                  [soft.particleMassKg,soft.particleRadiusMeters,soft.naturalFrequencyHz].allSatisfy({ $0.isFinite && $0 > 0 }),
                  [soft.dampingRatio,soft.linearDamping,soft.friction].allSatisfy({ $0.isFinite && $0 >= 0 }), soft.pinnedIndices.allSatisfy({ Int($0) < soft.particleCount }) else { throw SimulationError.invalidInput("Invalid soft-body lattice, material or pinned particles.") }
            if soft.kind == .mesh {
                let vertices = soft.meshVertices ?? [], triangles = soft.meshTriangles ?? []
                try SimulationPhysicsMesh.validate(vertices:vertices,triangles:triangles,budget:budget,requireClosed:soft.preserveVolume == true)
                if let mapping = soft.sourceVertexToParticle {
                    guard !mapping.isEmpty, mapping.count <= budget.maximumNodes, mapping.allSatisfy({ Int($0) < vertices.count }) else { throw SimulationError.invalidInput("The source Mesh vertex mapping is invalid.") }
                }
            }
            particles += soft.particleCount
        }
        guard particles <= budget.maximumNodes else { throw SimulationError.resourceLimit("Soft-body particles exceed the node budget.") }
        let samples = ceil(time.durationSeconds / time.outputIntervalSeconds) + 2
        guard samples * Double(bodies.count * 14 + particles * 3) <= Double(budget.maximumResultValues) else { throw SimulationError.resourceLimit("Reduce output frequency or scene size to fit the cache budget.") }
    }
}

public enum SimulationForceFieldKind: String, Codable, Sendable, CaseIterable { case uniform, pointAttractor, vortex }
public struct SimulationPhysicsForceField: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var kind: SimulationForceFieldKind
    public var acceleration = SimulationVector3.zero
    public var center = SimulationVector3.zero
    public var axis = SimulationVector3(0,1,0)
    public var strength = 1.0
    public var softeningRadiusMeters = 0.01
    public var bodyIDs: [UUID] = []
    public var affectsSoftBodies = true
    public init(id: UUID = UUID(), kind: SimulationForceFieldKind = .uniform) { self.id = id; self.kind = kind }
}
