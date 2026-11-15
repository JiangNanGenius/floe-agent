// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeGameSpriteCore

@Suite("Frame animation sequences")
struct SpriteAnimationTests {
    @Test("Sequence rejects empty frames and out-of-range speed")
    func validation() throws {
        do {
            _ = try SpriteAnimationSequence(frameIndices: [], framesPerSecond: 8)
            Issue.record("Empty sequence must not be valid")
        } catch let error as SpriteAnimationError {
            #expect(error == .emptySequence)
        }
        do {
            _ = try SpriteAnimationSequence(frameIndices: [0, 1], framesPerSecond: 0)
            Issue.record("Zero fps must not be valid")
        } catch let error as SpriteAnimationError {
            #expect(error == .invalidFrameRate(0))
        }
        do {
            _ = try SpriteAnimationSequence(frameIndices: [0, 1], framesPerSecond: 31)
            Issue.record("31 fps must not be valid")
        } catch let error as SpriteAnimationError {
            #expect(error == .invalidFrameRate(31))
        }
    }

    @Test("Frame stepping wraps in both directions")
    func stepping() throws {
        let sequence = try SpriteAnimationSequence(frameIndices: [3, 4, 5], framesPerSecond: 12)
        #expect(sequence.frameCount == 3)
        #expect(sequence.isAnimatable)
        #expect(sequence.frameIndex(atStep: 0) == 3)
        #expect(sequence.frameIndex(atStep: 1) == 4)
        #expect(sequence.frameIndex(atStep: 2) == 5)
        #expect(sequence.frameIndex(atStep: 3) == 3)
        #expect(sequence.frameIndex(atStep: -1) == 5)
        #expect(abs(sequence.frameDuration - 1.0 / 12.0) < 0.000_001)
    }

    @Test("A single-frame sequence is valid but not animatable")
    func singleFrame() throws {
        let sequence = try SpriteAnimationSequence(frameIndices: [7], framesPerSecond: 8)
        #expect(sequence.isAnimatable == false)
        #expect(sequence.frameIndex(atStep: 99) == 7)
    }
}
