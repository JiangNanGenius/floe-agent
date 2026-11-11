// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Frozen loop region for the recording transport. A recording take freezes
/// its loop boundaries at the moment recording starts, so a later take can
/// never move the range. The transport clock itself stays monotonic; this
/// type maps a linear transport position to the musical position inside the
/// loop. Cross-boundary held notes and pedals are split by the host through
/// the trusted sample↔tick conversion (`MusicTempoMap`), not here.
public struct MusicLoopRange: Sendable, Codable, Hashable {
    /// Loop start in project samples. Recording starts exactly here.
    public let startSample: Int64
    /// Loop end (exclusive) in project samples.
    public let endSample: Int64

    /// Loops shorter than this are rejected: wrap reconciliation runs on the
    /// transport tick (device ≈20 ms, manual one render block), and a loop
    /// must survive at least one tick to stay observable and glitch-bounded.
    public static let minimumLengthSamples: Int64 = 4_096

    public var lengthSamples: Int64 { endSample - startSample }

    public init(startSample: Int64, endSample: Int64,
                minimumLength: Int64 = MusicLoopRange.minimumLengthSamples) throws {
        guard startSample >= 0 else {
            throw MusicError.invalidSampleTime(reason: "negative loop start")
        }
        guard endSample > startSample else {
            throw MusicError.invalidSampleTime(reason: "loop end must pass its start")
        }
        guard endSample - startSample >= minimumLength else {
            throw MusicError.invalidSampleTime(reason: "loop shorter than \(minimumLength) samples")
        }
        self.startSample = startSample
        self.endSample = endSample
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let start = try c.decode(Int64.self, forKey: .startSample)
        let end = try c.decode(Int64.self, forKey: .endSample)
        try self.init(startSample: start, endSample: end)
    }

    /// Musical position for a linear transport position. Recording starts at
    /// `startSample`, so positions from the start onwards wrap by
    /// `lengthSamples`; earlier positions (never produced by the transport)
    /// pass through unchanged.
    public func musicalPosition(linearSample: Int64) -> Int64 {
        guard linearSample > startSample else { return linearSample }
        let over = (linearSample - startSample) % lengthSamples
        // Exactly on a wrap boundary the previous pass has just ended and the
        // new pass begins at the loop start.
        return startSample + over
    }

    /// Number of fully crossed loop boundaries: 0 during the first pass, 1
    /// once the playhead has wrapped back to the loop start, and so on.
    public func passIndex(linearSample: Int64) -> Int64 {
        guard linearSample > startSample else { return 0 }
        return (linearSample - startSample) / lengthSamples
    }
}
