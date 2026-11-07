import Foundation
import FloeSimulationCore
import FloeSimulationPhysics
import FloeSimulationAnimation

/// An immutable transient view of the actual source. It is never saved as another model.
public struct SimulationSourceMesh: Sendable, Identifiable {
    public var id: String
    public var positionsMeters: [SimulationVector3]
    public var indices: [UInt32]
    public init(id:String,positionsMeters:[SimulationVector3],indices:[UInt32]) { self.id = id; self.positionsMeters = positionsMeters; self.indices = indices }
}

public extension SimulationWorkbenchModel {
    func useSourceMesh(_ objectID:String,asSoftBody:Bool = false,preserveVolume:Bool = false) async {
        guard !isClosed, sourceAvailable, !preparingSourceMesh,
              let input = sourceMeshes.first(where: { $0.id == objectID }) else { return }
        let source = document.source, studyID = selectedStudyID, original = selectedStudy
        preparingSourceMesh = true
        defer { preparingSourceMesh = false; sourceMeshTask = nil }
        let task = Task.detached(priority:.userInitiated) { try SimulationPhysicsMesh(vertices:input.positionsMeters,indices:input.indices) }
        sourceMeshTask = task
        do {
            let mesh = try await task.value
            guard !isClosed, sourceAvailable, document.source == source, selectedStudyID == studyID, selectedStudy == original else { throw SimulationError.staleSource }
            var config = physics
            if asSoftBody {
                var soft = try mesh.softBody(id:config.softBodies.first { $0.sourceObjectID == objectID }?.id ?? UUID(),sourceObjectID:objectID,preserveVolume:preserveVolume)
                soft.sourceGeometrySHA256 = source.contentSHA256
                if let prior = config.softBodies.first(where: { $0.sourceObjectID == objectID }) {
                    soft.particleMassKg = prior.particleMassKg; soft.particleRadiusMeters = prior.particleRadiusMeters
                    soft.naturalFrequencyHz = prior.naturalFrequencyHz; soft.dampingRatio = prior.dampingRatio
                    soft.pinnedIndices = prior.pinnedIndices.filter { Int($0) < soft.particleCount }
                }
                let removed = Set(config.bodies.filter { $0.sourceObjectID == objectID }.map(\.id))
                config.bodies.removeAll { removed.contains($0.id) }; config.joints.removeAll { removed.contains($0.firstBody) || removed.contains($0.secondBody) }
                config.softBodies.removeAll { $0.sourceObjectID == objectID }; config.softBodies.append(soft)
            } else {
                if let index = config.bodies.firstIndex(where: { $0.sourceObjectID == objectID }) {
                    let prior = config.bodies[index]
                    let kind:SimulationColliderKind = [.triangleMesh,.convexHull,.convexDecomposition].contains(prior.collider.kind) ? prior.collider.kind : (prior.motion == .dynamic ? .convexDecomposition:.triangleMesh)
                    let prepared = try mesh.rigidBody(id:prior.id,sourceObjectID:objectID,motion:prior.motion,collider:kind)
                    config.bodies[index].collider = prepared.collider; config.bodies[index].sourceGeometrySHA256 = source.contentSHA256
                } else {
                    var body = try mesh.rigidBody(sourceObjectID:objectID,motion:mesh.isClosed ? .dynamic:.fixed)
                    body.sourceGeometrySHA256 = source.contentSHA256; config.bodies.append(body)
                }
                config.softBodies.removeAll { $0.sourceObjectID == objectID }
            }
            writeConfiguration(config); clearError()
        } catch { recordSourceError(error) }
    }
    func bindSourceMesh(_ objectID:String) async {
        guard !isClosed, sourceAvailable, !preparingSourceMesh,
              let mesh = sourceMeshes.first(where: { $0.id == objectID }) else { return }
        let graph = animationGraph, source = document.source
        preparingSourceMesh = true
        defer { preparingSourceMesh = false; sourceBindingTask = nil }
        let task = Task.detached(priority:.userInitiated) { try SimulationAnimationMeshDeformer.bindNearest(positions:mesh.positionsMeters,sourceObjectID:objectID,bones:graph.bones) }
        sourceBindingTask = task
        do {
            let binding = try await task.value
            guard !isClosed, sourceAvailable, document.source == source, animationGraph == graph else { throw SimulationError.staleSource }
            var value = graph; var bindings = value.meshBindings ?? []
            bindings.removeAll { $0.sourceObjectID == objectID }; bindings.append(binding); value.meshBindings = bindings
            writeAnimationGraph(value); clearError()
        } catch { recordSourceError(error) }
    }
}
