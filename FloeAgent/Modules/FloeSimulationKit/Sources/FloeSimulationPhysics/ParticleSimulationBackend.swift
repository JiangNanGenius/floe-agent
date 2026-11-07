import Foundation
import CryptoKit
import FloeSimulationCore

public struct SimulationParticleEmitter: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var origin = SimulationVector3.zero
    public var halfExtents = SimulationVector3(0.1,0.1,0.1)
    public var velocity = SimulationVector3(0,2,0)
    public var velocitySpread = SimulationVector3(0.2,0.2,0.2)
    public var startSeconds = 0.0
    public var endSeconds = 1.0
    public var particlesPerSecond = 100.0
    public var burstCount = 0
    public var lifetimeSeconds = 2.0
    public var massKg = 0.001
    public var radiusMeters = 0.005
    public var dragPerSecond = 0.1
    public var restitution = 0.2
    public init(id: UUID = UUID()) { self.id = id }
}
public struct ParticleSimulationConfiguration: Codable, Equatable, Sendable {
    public var emitters: [SimulationParticleEmitter] = []
    public var collisionBodies: [SimulationPhysicsBody] = []
    public var forceFields: [SimulationPhysicsForceField] = []
    public var gravity = SimulationVector3(0,-9.81,0)
    public var seed: UInt64 = 1
    public var time = SimulationTimeSettings()
    public init() {}
    public func physicsConfiguration(budget: SimulationBudget) throws -> PhysicsSimulationConfiguration {
        try time.validate(maximumSteps:budget.maximumIterations)
        guard !emitters.isEmpty, emitters.count <= 128, Set(emitters.map(\.id)).count == emitters.count else { throw SimulationError.invalidInput("Add unique particle emitters within the scene budget.") }
        var random = ParticleRandom(state:seed), configuration = PhysicsSimulationConfiguration()
        configuration.bodies = collisionBodies; configuration.forceFields = forceFields; configuration.gravity = gravity; configuration.time = time; configuration.seed = seed
        for emitter in emitters {
            guard emitter.origin.isFinite, emitter.halfExtents.isFinite, min(emitter.halfExtents.x,emitter.halfExtents.y,emitter.halfExtents.z) >= 0,
                  emitter.velocity.isFinite, emitter.velocitySpread.isFinite, min(emitter.velocitySpread.x,emitter.velocitySpread.y,emitter.velocitySpread.z) >= 0,
                  emitter.startSeconds.isFinite, emitter.startSeconds >= 0, emitter.endSeconds.isFinite, emitter.endSeconds >= emitter.startSeconds, emitter.endSeconds <= time.durationSeconds,
                  emitter.particlesPerSecond.isFinite, emitter.particlesPerSecond >= 0, emitter.particlesPerSecond <= 10_000,
                  (0...4096).contains(emitter.burstCount), [emitter.lifetimeSeconds,emitter.massKg,emitter.radiusMeters].allSatisfy({ $0.isFinite && $0 > 0 }), emitter.dragPerSecond.isFinite, emitter.dragPerSecond >= 0,
                  emitter.restitution.isFinite, (0...1).contains(emitter.restitution) else { throw SimulationError.invalidInput("Invalid particle emitter extent, emission, lifetime or material.") }
            let continuous = Int(floor((emitter.endSeconds-emitter.startSeconds)*emitter.particlesPerSecond))
            guard continuous+emitter.burstCount > 0, continuous+emitter.burstCount <= 4096-configuration.bodies.count else { throw SimulationError.resourceLimit("The particle scene exceeds its body budget.") }
            for index in 0..<(continuous+emitter.burstCount) {
                let hash = Array(SHA256.hash(data:Data("\(seed)/\(emitter.id.uuidString)/\(index)".utf8)))
                let id = UUID(uuid:(hash[0],hash[1],hash[2],hash[3],hash[4],hash[5],hash[6],hash[7],hash[8],hash[9],hash[10],hash[11],hash[12],hash[13],hash[14],hash[15]))
                var body = SimulationPhysicsBody(id:id,sourceObjectID:"particle/"+emitter.id.uuidString+"/\(index)")
                body.translation = emitter.origin + .init(random.signed()*emitter.halfExtents.x,random.signed()*emitter.halfExtents.y,random.signed()*emitter.halfExtents.z)
                body.velocity = emitter.velocity + .init(random.signed()*emitter.velocitySpread.x,random.signed()*emitter.velocitySpread.y,random.signed()*emitter.velocitySpread.z)
                let birth = index < emitter.burstCount ? emitter.startSeconds : emitter.startSeconds+Double(index-emitter.burstCount)/max(1e-12,emitter.particlesPerSecond)
                body.activationTimeSeconds = min(time.durationSeconds,(birth/time.stepSeconds).rounded(.up)*time.stepSeconds)
                body.lifetimeSeconds = emitter.lifetimeSeconds; body.massKg = emitter.massKg; body.linearDamping = emitter.dragPerSecond; body.restitution = emitter.restitution
                body.collider = .init(kind:.sphere); body.collider.radius = emitter.radiusMeters
                configuration.bodies.append(body)
            }
        }
        try configuration.validate(budget:budget); return configuration
    }
}
private struct ParticleRandom {
    var state: UInt64
    mutating func signed() -> Double {
        state &+= 0x9E3779B97F4A7C15; var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9; value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        value ^= value >> 31
        return Double(value >> 11)/Double(UInt64(1)<<53)*2-1
    }
}
public struct ParticleSimulationBackend: SimulationBackend {
    private let physics = RapierSimulationBackend()
    public init() {}
    public var descriptor: SimulationBackendDescriptor { .init(id:"floe.particles",version:physics.descriptor.version+"/emitter1",supportedStudies:[.particles],isAvailable:physics.descriptor.isAvailable,unavailableReason:physics.descriptor.unavailableReason) }
    public func validate(_ request: SimulationRequest) throws {
        try request.validate()
        guard request.study.kind == .particles else { throw SimulationError.unsupported(request.study.kind.rawValue) }
        _ = try request.study.configuration(as:ParticleSimulationConfiguration.self).physicsConfiguration(budget:request.budget)
        guard descriptor.isAvailable else { throw SimulationError.backendUnavailable(descriptor.unavailableReason ?? descriptor.id) }
    }
    public func solve(_ request: SimulationRequest, progress: @escaping SimulationProgressHandler) async throws -> SimulationResult {
        try validate(request)
        let scene = try request.study.configuration(as:ParticleSimulationConfiguration.self).physicsConfiguration(budget:request.budget)
        var adapted = request; adapted.study.kind = .rigidBody; try adapted.study.setConfiguration(scene); adapted.study.revision = request.study.revision
        var result = try await physics.solve(adapted,progress:progress); result.backend = descriptor
        result.diagnostics["particleEmitterCount"] = String(try request.study.configuration(as:ParticleSimulationConfiguration.self).emitters.count)
        try result.validate(for:request); return result
    }
}
