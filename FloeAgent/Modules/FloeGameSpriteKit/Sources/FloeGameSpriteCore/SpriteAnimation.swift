// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum SpriteAnimationError: Error, Equatable, Sendable {
    case emptySequence
    case invalidFrameRate(Double)
}

public struct SpriteAnimationSequence: Hashable, Sendable {
    public static let minimumFramesPerSecond = 1.0
    public static let maximumFramesPerSecond = 30.0

    public let frameIndices: [Int]
    public let framesPerSecond: Double

    public init(frameIndices: [Int], framesPerSecond: Double) throws {
        guard !frameIndices.isEmpty else { throw SpriteAnimationError.emptySequence }
        guard framesPerSecond.isFinite,
              framesPerSecond >= Self.minimumFramesPerSecond,
              framesPerSecond <= Self.maximumFramesPerSecond else {
            throw SpriteAnimationError.invalidFrameRate(framesPerSecond)
        }
        self.frameIndices = frameIndices
        self.framesPerSecond = framesPerSecond
    }

    public var frameDuration: TimeInterval { 1.0 / framesPerSecond }
    public var frameCount: Int { frameIndices.count }
    public var isAnimatable: Bool { frameIndices.count > 1 }

    public func frameIndex(atStep step: Int) -> Int? {
        guard !frameIndices.isEmpty else { return nil }
        let wrapped = ((step % frameIndices.count) + frameIndices.count) % frameIndices.count
        return frameIndices[wrapped]
    }
}
