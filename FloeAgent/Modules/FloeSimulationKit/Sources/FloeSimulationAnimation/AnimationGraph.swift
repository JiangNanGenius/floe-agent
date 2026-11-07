import Foundation
import FloeSimulationCore

public struct SimulationAnimationTransform: Codable, Equatable, Sendable {
    public var translation: SimulationVector3
    public var rotation: SimulationQuaternion
    public var scale: SimulationVector3
    public init(translation: SimulationVector3 = .zero, rotation: SimulationQuaternion = .identity, scale: SimulationVector3 = .init(1,1,1)) { self.translation = translation; self.rotation = rotation; self.scale = scale }
    public static let identity = Self()
}
public struct SimulationAnimationKey: Codable, Equatable, Sendable {
    public var timeSeconds: Double
    public var transform: SimulationAnimationTransform
    public init(timeSeconds: Double, transform: SimulationAnimationTransform) { self.timeSeconds = timeSeconds; self.transform = transform }
}
public struct SimulationAnimationTrack: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// Object, bone or camera identity in the host's stable namespace.
    public var targetID: String
    public var keys: [SimulationAnimationKey]
    public init(id: UUID = UUID(), targetID: String, keys: [SimulationAnimationKey]) { self.id = id; self.targetID = targetID; self.keys = keys }
}
public struct SimulationAnimationLayer: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var weight: Double
    public var additive: Bool
    public var tracks: [SimulationAnimationTrack]
    public init(id: UUID = UUID(), weight: Double = 1, additive: Bool = false, tracks: [SimulationAnimationTrack] = []) { self.id = id; self.weight = weight; self.additive = additive; self.tracks = tracks }
}
public struct SimulationAnimationBone: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var parentID: String?
    public var restLocal: SimulationAnimationTransform
    public init(id: String, parentID: String? = nil, restLocal: SimulationAnimationTransform = .identity) { self.id = id; self.parentID = parentID; self.restLocal = restLocal }
}
public enum SimulationAnimationControl: String, Codable, Sendable, CaseIterable { case keyframed, dynamic, driven }
public struct SimulationAnimationPhysicsBinding: Codable, Equatable, Sendable {
    public var targetID: String
    public var bodyID: UUID
    public var control: SimulationAnimationControl
    public var weight: Double
    public var bodyFromTarget: SimulationAnimationTransform
    public init(targetID: String, bodyID: UUID, control: SimulationAnimationControl = .dynamic, weight: Double = 1, bodyFromTarget: SimulationAnimationTransform = .identity) { self.targetID = targetID; self.bodyID = bodyID; self.control = control; self.weight = weight; self.bodyFromTarget = bodyFromTarget }
}
public struct SimulationAnimationIKChain: Codable, Equatable, Sendable {
    public var rootID: String
    public var middleID: String
    public var endID: String
    public var targetMeters: SimulationVector3
    public var poleMeters: SimulationVector3
    public var weight: Double
    public init(rootID: String, middleID: String, endID: String, targetMeters: SimulationVector3, poleMeters: SimulationVector3, weight: Double = 1) { self.rootID = rootID; self.middleID = middleID; self.endID = endID; self.targetMeters = targetMeters; self.poleMeters = poleMeters; self.weight = weight }
}
public struct SimulationMorphTrack: Codable, Equatable, Sendable {
    public var targetID: String
    public var timesSeconds: [Double]
    public var weights: [[Double]]
    public init(targetID: String, timesSeconds: [Double], weights: [[Double]]) { self.targetID = targetID; self.timesSeconds = timesSeconds; self.weights = weights }
}
public struct SimulationAnimationCameraProjection:Codable,Equatable,Sendable {
    public var verticalFOVDegrees:Double
    public var orthographicHeightMeters:Double?
    public init(verticalFOVDegrees:Double = 60,orthographicHeightMeters:Double? = nil) { self.verticalFOVDegrees = verticalFOVDegrees; self.orthographicHeightMeters = orthographicHeightMeters }
}
public struct SimulationAnimationCameraKey:Codable,Equatable,Sendable {
    public var timeSeconds:Double
    public var projection:SimulationAnimationCameraProjection
    public init(timeSeconds:Double,projection:SimulationAnimationCameraProjection) { self.timeSeconds = timeSeconds; self.projection = projection }
}
public struct SimulationAnimationGraph: Codable, Equatable, Sendable {
    public var source: SimulationSourceRef
    public var durationSeconds: Double
    public var layers: [SimulationAnimationLayer]
    public var bones: [SimulationAnimationBone]
    public var ikChains: [SimulationAnimationIKChain]
    public var morphTracks: [SimulationMorphTrack]
    public var physicsResultID: UUID?
    public var physicsBindings: [SimulationAnimationPhysicsBinding]
    public var meshBindings: [SimulationAnimationMeshBinding]?
    public var cameraKeys:[SimulationAnimationCameraKey]?
    public init(source: SimulationSourceRef, durationSeconds: Double = 1, layers: [SimulationAnimationLayer] = [], bones: [SimulationAnimationBone] = [], ikChains: [SimulationAnimationIKChain] = [], morphTracks: [SimulationMorphTrack] = [], physicsResultID: UUID? = nil, physicsBindings: [SimulationAnimationPhysicsBinding] = []) {
        self.source = source; self.durationSeconds = durationSeconds; self.layers = layers; self.bones = bones; self.ikChains = ikChains; self.morphTracks = morphTracks; self.physicsResultID = physicsResultID; self.physicsBindings = physicsBindings
    }
    /// Fits every authored clock to the actual cache endpoint, including
    /// sub-ulp differences from accumulated physics timesteps.
    public mutating func fitDuration(to duration:Double) throws {
        try validate()
        guard duration.isFinite,duration>0,duration<=600 else { throw SimulationError.invalidInput("Choose a positive animation duration of at most ten minutes.") }
        let originalDuration = durationSeconds
        func time(_ value:Double) -> Double {
            if value == originalDuration { return duration }
            return min(duration,max(0,(value/originalDuration)*duration))
        }
        var fitted = self
        for layer in fitted.layers.indices { for track in fitted.layers[layer].tracks.indices {
            for key in fitted.layers[layer].tracks[track].keys.indices { fitted.layers[layer].tracks[track].keys[key].timeSeconds = time(fitted.layers[layer].tracks[track].keys[key].timeSeconds) }
        } }
        for index in fitted.morphTracks.indices { fitted.morphTracks[index].timesSeconds = fitted.morphTracks[index].timesSeconds.map(time) }
        fitted.cameraKeys = fitted.cameraKeys?.map { var key = $0; key.timeSeconds = time(key.timeSeconds); return key }
        fitted.durationSeconds = duration
        try fitted.validate(); self = fitted
    }
    public func validate() throws {
        try source.validate()
        guard durationSeconds.isFinite, durationSeconds > 0, durationSeconds <= 600, bones.count <= 4096, layers.count <= 64, Set(bones.map(\.id)).count == bones.count else { throw SimulationError.invalidInput("Invalid animation duration, layer or bone budget.") }
        func transformIsValid(_ value: SimulationAnimationTransform) -> Bool {
            let q = value.rotation
            return value.translation.isFinite && value.scale.isFinite && min(value.scale.x,value.scale.y,value.scale.z) > 0 && q.isFinite && abs(q.x*q.x+q.y*q.y+q.z*q.z+q.w*q.w-1) < 1e-6
        }
        var visited = Set<String>()
        for bone in bones {
            guard !bone.id.isEmpty, transformIsValid(bone.restLocal), bone.parentID.map({ visited.contains($0) }) ?? true else { throw SimulationError.invalidInput("Bones must have valid transforms and follow their parent in hierarchy order.") }
            visited.insert(bone.id)
        }
        if let meshBindings {
            guard meshBindings.count <= 256, Set(meshBindings.map(\.sourceObjectID)).count == meshBindings.count else { throw SimulationError.invalidInput("Duplicate or over-budget animated Mesh bindings.") }
            for binding in meshBindings { try binding.validate(boneIDs:visited) }
        }
        var keys = 0
        for layer in layers {
            guard layer.weight.isFinite, (0...1).contains(layer.weight), Set(layer.tracks.map(\.targetID)).count == layer.tracks.count else { throw SimulationError.invalidInput("Invalid animation layer or duplicate target.") }
            for track in layer.tracks {
                keys += track.keys.count
                guard !track.targetID.isEmpty, !track.keys.isEmpty, track.keys.allSatisfy({ $0.timeSeconds.isFinite && (0...durationSeconds).contains($0.timeSeconds) && transformIsValid($0.transform) }), zip(track.keys,track.keys.dropFirst()).allSatisfy({ $0.timeSeconds < $1.timeSeconds }) else { throw SimulationError.invalidInput("Animation keys need ordered times and valid transforms.") }
            }
        }
        guard keys <= 1_000_000, Set(physicsBindings.map(\.targetID)).count == physicsBindings.count,
              physicsBindings.allSatisfy({ !$0.targetID.isEmpty && $0.weight.isFinite && (0...1).contains($0.weight) && transformIsValid($0.bodyFromTarget) }) else { throw SimulationError.invalidInput("Invalid animation key budget or physics bindings.") }
        for chain in ikChains {
            guard let middle = bones.first(where: { $0.id == chain.middleID }), let end = bones.first(where: { $0.id == chain.endID }),
                  middle.parentID == chain.rootID, end.parentID == chain.middleID, chain.targetMeters.isFinite, chain.poleMeters.isFinite, chain.weight.isFinite, (0...1).contains(chain.weight) else { throw SimulationError.invalidInput("IK requires a consecutive three-bone chain and valid target.") }
        }
        for morph in morphTracks {
            guard !morph.timesSeconds.isEmpty, morph.timesSeconds.count == morph.weights.count, morph.timesSeconds.allSatisfy({ $0.isFinite && (0...durationSeconds).contains($0) }),
                  zip(morph.timesSeconds,morph.timesSeconds.dropFirst()).allSatisfy({ $0 < $1 }), let count = morph.weights.first?.count, count > 0,
                  morph.weights.allSatisfy({ $0.count == count && $0.allSatisfy(\.isFinite) }) else { throw SimulationError.invalidInput("Invalid Morph time or weight array.") }
        }
        if let cameraKeys {
            guard cameraKeys.count <= 1_000_000, !cameraKeys.isEmpty,
                  zip(cameraKeys,cameraKeys.dropFirst()).allSatisfy({ $0.timeSeconds < $1.timeSeconds }),
                  cameraKeys.allSatisfy({ key in
                      key.timeSeconds.isFinite && (0...durationSeconds).contains(key.timeSeconds) && key.projection.verticalFOVDegrees.isFinite && (5...170).contains(key.projection.verticalFOVDegrees)
                        && (key.projection.orthographicHeightMeters.map { $0.isFinite && $0 > 0 } ?? true)
                        && (key.projection.orthographicHeightMeters == nil) == (cameraKeys[0].projection.orthographicHeightMeters == nil)
                  }) else { throw SimulationError.invalidInput("Use ordered camera keys with a consistent projection and valid lens settings.") }
        }
    }
}

public struct SimulationAnimationPose: Codable, Equatable, Sendable {
    public var timeSeconds: Double
    public var objects: [String: SimulationAnimationTransform]
    public var localBones: [String: SimulationAnimationTransform]
    public var worldBones: [String: SimulationAnimationTransform]
    public var morphWeights: [String: [Double]]
    public var softVertices: [String: [SimulationVector3]]
    public var hiddenObjects: Set<String>
    public var cameraProjection:SimulationAnimationCameraProjection? = nil
}
