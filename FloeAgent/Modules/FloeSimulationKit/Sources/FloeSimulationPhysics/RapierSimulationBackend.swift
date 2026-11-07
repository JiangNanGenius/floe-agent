import Foundation
import FloeSimulationCore
#if canImport(FloeRapierNative)
import FloeRapierNative
#endif

public struct RapierSimulationBackend: SimulationBackend {
    public init() {}
    public var descriptor: SimulationBackendDescriptor {
        #if canImport(FloeRapierNative)
        .init(id: "floe.rapier", version: String(cString: floe_physics_version()), supportedStudies: [.rigidBody,.skeletalPhysics,.cloth,.rope,.softBody], isAvailable: true)
        #else
        .init(id: "floe.rapier", version: "0.36.1", supportedStudies: [.rigidBody,.skeletalPhysics,.cloth,.rope,.softBody], isAvailable: false, unavailableReason: "The Rapier native artifact is not linked in this host.")
        #endif
    }
    public func validate(_ request: SimulationRequest) throws {
        try request.validate()
        try request.study.configuration(as: PhysicsSimulationConfiguration.self).validate(budget: request.budget)
        guard descriptor.isAvailable else { throw SimulationError.backendUnavailable(descriptor.unavailableReason ?? descriptor.id) }
        guard descriptor.supportedStudies.contains(request.study.kind) else { throw SimulationError.unsupported(request.study.kind.rawValue) }
    }
    public func solve(_ request: SimulationRequest, progress: @escaping SimulationProgressHandler) async throws -> SimulationResult {
        try validate(request); try Task.checkCancellation()
        #if canImport(FloeRapierNative)
        let configuration = try request.study.configuration(as: PhysicsSimulationConfiguration.self)
        let callbacks = PhysicsCallbackContext(progress: progress)
        let opaque = Unmanaged.passRetained(callbacks).toOpaque()
        defer { Unmanaged<PhysicsCallbackContext>.fromOpaque(opaque).release() }
        let output: PhysicsOutput = try await withTaskCancellationHandler {
            try request.study.configuration.withUnsafeBytes { bytes in
                let buffer = floe_physics_run(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, request.budget.maximumResultValues,
                    { context in guard let context else { return 1 }; return Unmanaged<PhysicsCallbackContext>.fromOpaque(context).takeUnretainedValue().isCancelled ? 1 : 0 },
                    { context, step, total in guard let context else { return }; let callback = Unmanaged<PhysicsCallbackContext>.fromOpaque(context).takeUnretainedValue(); Task { await callback.progress(.init(stage: "simulating", completed: Int(step), total: Int(total))) } }, opaque)
                defer { floe_physics_buffer_free(buffer) }
                guard buffer.status != 2 else { throw SimulationError.cancelled }
                guard let pointer = buffer.data, buffer.length > 0, buffer.length <= 512_000_000 else { throw SimulationError.solverFailure("Invalid native physics response.") }
                let data = Data(bytes: pointer, count: buffer.length)
                guard buffer.status == 0 else { throw SimulationError.solverFailure((try? JSONDecoder().decode(PhysicsError.self, from: data).error) ?? "Native physics failed.") }
                return try JSONDecoder().decode(PhysicsOutput.self, from: data)
            }
        } onCancel: { callbacks.cancel() }
        try Task.checkCancellation()
        let bodyIDs = configuration.bodies.map(\.id), softIDs = configuration.softBodies.map(\.id)
        var diagnostics = ["bodyIDs":bodyIDs.map(\.uuidString).joined(separator: ","), "seed":String(output.seed), "stepSeconds":String(configuration.time.stepSeconds)]
        diagnostics["bodySourceObjectIDs"] = String(decoding:try JSONEncoder().encode(configuration.bodies.map(\.sourceObjectID)),as:UTF8.self)
        guard output.softTopology.map(\.id) == softIDs else { throw SimulationError.solverFailure("Soft-body topology identities do not match the scene.") }
        for topology in output.softTopology { diagnostics["soft/"+topology.id.uuidString+"/triangles"] = String(data:try JSONEncoder().encode(topology.triangles),encoding:.utf8) }
        let frames = try output.frames.enumerated().map { index, frame -> SimulationResultFrame in
            guard frame.bodies.map(\.id) == bodyIDs, frame.softBodies.map(\.id) == softIDs else { throw SimulationError.solverFailure("Native physics object identities do not match the scene.") }
            var fields: [SimulationResultField] = []
            if !frame.bodies.isEmpty {
                fields += [
                    .init(id: "body_position", name: "Position", unit: "m", location: .global, components: 3, values: frame.bodies.flatMap { [$0.translation.x,$0.translation.y,$0.translation.z] }),
                    .init(id: "body_rotation", name: "Rotation", unit: "1", location: .global, components: 4, values: frame.bodies.flatMap { [$0.rotation.x,$0.rotation.y,$0.rotation.z,$0.rotation.w] }),
                    .init(id: "body_visible", name: "Visible", unit: "1", location: .global, components: 1, values: frame.bodies.map { $0.visible ? 1 : 0 }),
                    .init(id: "body_velocity", name: "Velocity", unit: "m/s", location: .global, components: 3, values: frame.bodies.flatMap { [$0.velocity.x,$0.velocity.y,$0.velocity.z] }),
                    .init(id: "body_angular_velocity", name: "Angular velocity", unit: "rad/s", location: .global, components: 3, values: frame.bodies.flatMap { [$0.angularVelocity.x,$0.angularVelocity.y,$0.angularVelocity.z] })]
            }
            for soft in frame.softBodies {
                let id = "soft/" + soft.id.uuidString
                fields.append(.init(id: id, name: "Soft body vertices", unit: "m", location: .global, components: 3, values: soft.vertices.flatMap { [$0.x,$0.y,$0.z] }))
            }
            diagnostics["contacts/\(index)"] = String(data: try JSONEncoder().encode(frame.contacts), encoding: .utf8)
            return .init(id: index, timeSeconds: frame.timeSeconds, fields: fields)
        }
        guard output.seed == configuration.seed, output.version == descriptor.version else { throw SimulationError.solverFailure("The native cache version or seed is incompatible.") }
        let result = SimulationResult(requestID: request.id, source: request.source, studyID: request.study.id, studyRevision: request.study.revision, backend: descriptor, frames: frames, diagnostics: diagnostics)
        try result.validate(for: request); return result
        #else
        throw SimulationError.backendUnavailable(descriptor.id)
        #endif
    }
}

#if canImport(FloeRapierNative)
private final class PhysicsCallbackContext: @unchecked Sendable {
    // The only mutable state crosses a synchronous C callback boundary under this lock.
    private let lock = NSLock()
    private var cancelled = false
    let progress: SimulationProgressHandler
    init(progress: @escaping SimulationProgressHandler) { self.progress = progress }
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}
private struct PhysicsError: Decodable { var error: String }
private struct PhysicsOutput: Decodable { var version: String; var seed: UInt64; var softTopology: [PhysicsSoftTopology]; var frames: [PhysicsFrame] }
private struct PhysicsFrame: Decodable { var timeSeconds: Double; var bodies: [PhysicsBodyPose]; var softBodies: [PhysicsSoftPose]; var contacts: [[Int]] }
private struct PhysicsBodyPose: Decodable { var id: UUID; var translation: SimulationVector3; var rotation: SimulationQuaternion; var velocity: SimulationVector3; var angularVelocity: SimulationVector3; var visible: Bool }
private struct PhysicsSoftPose: Decodable { var id: UUID; var vertices: [SimulationVector3]; var topologyVersion: UInt32 }
private struct PhysicsSoftTopology: Decodable { var id: UUID; var triangles: [[UInt32]] }
#endif
