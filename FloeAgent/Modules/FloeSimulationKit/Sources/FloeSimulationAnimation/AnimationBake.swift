import Foundation
import CryptoKit
import FloeSimulationCore

public struct SimulationAnimationBake: Codable, Equatable, Sendable {
    public var source: SimulationSourceRef
    public var graphSHA256: String
    public var physicsResultID: UUID?
    public var framesPerSecond: Int
    public var frames: [SimulationAnimationPose]
}
public enum SimulationAnimationBaker {
    public static func bake(_ graph: SimulationAnimationGraph, physics: SimulationResult? = nil, framesPerSecond: Int = 30, maximumValues: Int = 10_000_000, progress: @escaping SimulationProgressHandler) async throws -> SimulationAnimationBake {
        try graph.validate()
        guard (1...240).contains(framesPerSecond), maximumValues > 0 else { throw SimulationError.invalidInput("Invalid animation frame rate or bake budget.") }
        let count = Int(ceil(graph.durationSeconds * Double(framesPerSecond)))+1
        let targets = Set(graph.layers.flatMap(\.tracks).map(\.targetID) + graph.physicsBindings.map(\.targetID)).count
        let morphCount = graph.morphTracks.reduce(0) { $0+($1.weights.first?.count ?? 0) }
        let perFrame = max(1,targets*10 + graph.bones.count*20 + morphCount + (physics?.frames.first?.fields.filter { $0.id.hasPrefix("soft/") }.reduce(0) { $0+$1.values.count } ?? 0))
        guard count <= maximumValues/perFrame else { throw SimulationError.resourceLimit("The animation bake exceeds its result budget.") }
        var poses: [SimulationAnimationPose] = []
        for frame in 0..<count {
            try Task.checkCancellation()
            let time = min(Double(frame)/Double(framesPerSecond),graph.durationSeconds)
            poses.append(try SimulationAnimationEvaluator.evaluate(graph,timeSeconds:time,physics:physics))
            if frame % 8 == 0 || frame == count-1 { await progress(.init(stage:"baking",completed:frame+1,total:count)) }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data:try encoder.encode(graph)).map { String(format:"%02x",$0) }.joined()
        return .init(source:graph.source,graphSHA256:digest,physicsResultID:physics?.id,framesPerSecond:framesPerSecond,frames:poses)
    }
}
