// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Source-time edits are descriptors. They never rewrite the imported asset.
/// A held frame silences its linked source audio, without changing mute flags.
public struct MediaSourcePlayback: Sendable, Codable, Hashable {
    public var isReversed: Bool
    /// Absolute seconds in the imported source, not timeline seconds.
    public var holdSeconds: Double?

    public init(isReversed: Bool = false, holdSeconds: Double? = nil) {
        self.isReversed = isReversed
        self.holdSeconds = holdSeconds
    }
}

public enum MediaSourcePlaybackMath {
    public static func sourceSeconds(sourceStart: Double, sourceDuration: Double,
                                     speed: Double, localTime: Double,
                                     playback: MediaSourcePlayback?, frameDuration: Double) throws -> Double {
        guard [sourceStart, sourceDuration, speed, localTime, frameDuration].allSatisfy(\.isFinite),
              sourceStart >= 0, sourceDuration > 0, speed > 0, localTime >= 0, frameDuration > 0 else {
            throw MediaPreparedCoreError.invalidOperation("invalid source playback range")
        }
        let end = sourceStart + sourceDuration
        if let hold = playback?.holdSeconds {
            guard hold.isFinite, hold >= sourceStart, hold < end else {
                throw MediaPreparedCoreError.invalidOperation("held frame lies outside the source trim")
            }
            return hold
        }
        let offset = localTime * speed
        guard offset <= sourceDuration + 0.000_01 else {
            throw MediaPreparedCoreError.invalidOperation("source playback extends beyond its trim")
        }
        if playback?.isReversed == true {
            // A video trim ends after its last sample. Start at that sample,
            // rather than asking the decoder for the exclusive source end.
            return max(sourceStart, end - min(frameDuration, sourceDuration) - offset)
        }
        return min(end, sourceStart + offset)
    }

    /// Timeline trimming preserves the source range direction. A held frame
    /// can be extended without reading outside the source or adding audio.
    public static func sourceTrim(sourceStart: Double, sourceDuration: Double, speed: Double,
                                  offset: Double, duration: Double, playback: MediaSourcePlayback?) throws -> (start: Double, duration: Double) {
        guard [sourceStart, sourceDuration, speed, offset, duration].allSatisfy(\.isFinite),
              sourceStart >= 0, sourceDuration > 0, speed > 0, duration > 0 else {
            throw MediaPreparedCoreError.invalidOperation("invalid timeline trim")
        }
        if playback?.holdSeconds != nil { return (sourceStart, sourceDuration) }
        let length = duration * speed
        let start = playback?.isReversed == true
            ? sourceStart + sourceDuration - (offset + duration) * speed
            : sourceStart + offset * speed
        guard start >= -0.000_01 else {
            throw MediaPreparedCoreError.invalidOperation("timeline trim extends before the source")
        }
        return (max(0, start), length)
    }
}
