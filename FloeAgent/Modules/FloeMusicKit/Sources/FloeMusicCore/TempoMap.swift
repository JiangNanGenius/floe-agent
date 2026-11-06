import Foundation

/// Absolute sample position or duration at the project sample rate.
///
/// All timeline arithmetic in the music model is integer sample time; floating
/// point appears only as a documented, deterministic intermediate inside tempo
/// conversion and is always rounded and range-checked back to `Int64`.
public struct MusicSampleTime: Hashable, Sendable, Codable, Comparable {
    public let value: Int64
    public init(_ value: Int64) { self.value = value }

    public static func < (lhs: MusicSampleTime, rhs: MusicSampleTime) -> Bool {
        lhs.value < rhs.value
    }

    public static func + (lhs: MusicSampleTime, rhs: MusicSampleTime) throws -> MusicSampleTime {
        let (sum, overflow) = lhs.value.addingReportingOverflow(rhs.value)
        if overflow { throw MusicError.invalidSampleTime(reason: "sample time addition overflow") }
        return MusicSampleTime(sum)
    }

    public static func - (lhs: MusicSampleTime, rhs: MusicSampleTime) throws -> MusicSampleTime {
        let (diff, overflow) = lhs.value.subtractingReportingOverflow(rhs.value)
        if overflow || diff < 0 {
            throw MusicError.invalidSampleTime(reason: "sample time subtraction out of range")
        }
        return MusicSampleTime(diff)
    }

    public static func * (lhs: MusicSampleTime, rhs: Int64) throws -> MusicSampleTime {
        let (prod, overflow) = lhs.value.multipliedReportingOverflow(by: rhs)
        if overflow { throw MusicError.invalidSampleTime(reason: "sample time multiplication overflow") }
        return MusicSampleTime(prod)
    }
}

/// Musical ticks (PPQN, see `MusicTempoMap.ticksPerQuarter`).
public struct MusicTick: Hashable, Sendable, Codable, Comparable {
    public let value: Int64
    public init(_ value: Int64) { self.value = value }
    public static func < (lhs: MusicTick, rhs: MusicTick) -> Bool { lhs.value < rhs.value }
}

/// Tempo + time-signature segment. The first segment must start at tick 0;
/// later segments mark a tempo or meter change point.
public struct MusicTempoSegment: Sendable, Codable, Hashable {
    /// Tick at which this segment takes effect.
    public var startTick: MusicTick
    /// Beats per minute; fractional values allowed (e.g. 120.5).
    public var bpm: Double
    /// Time-signature numerator (beats per bar).
    public var beatsPerBar: Int
    /// Time-signature denominator; one of 1, 2, 4, 8, 16.
    public var beatUnit: Int

    public init(startTick: MusicTick, bpm: Double, beatsPerBar: Int, beatUnit: Int) throws {
        guard bpm.isFinite, bpm >= 20, bpm <= 999 else {
            throw MusicError.invalidTempoMap(reason: "bpm \(bpm) outside [20, 999]")
        }
        guard beatsPerBar >= 1, beatsPerBar <= 64 else {
            throw MusicError.invalidTempoMap(reason: "beatsPerBar \(beatsPerBar) outside [1, 64]")
        }
        guard [1, 2, 4, 8, 16].contains(beatUnit) else {
            throw MusicError.invalidTempoMap(reason: "beatUnit \(beatUnit) not in {1,2,4,8,16}")
        }
        self.startTick = startTick
        self.bpm = bpm
        self.beatsPerBar = beatsPerBar
        self.beatUnit = beatUnit
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let startTick = try c.decode(MusicTick.self, forKey: .startTick)
        let bpm = try c.decode(Double.self, forKey: .bpm)
        let beatsPerBar = try c.decode(Int.self, forKey: .beatsPerBar)
        let beatUnit = try c.decode(Int.self, forKey: .beatUnit)
        try self.init(startTick: startTick, bpm: bpm, beatsPerBar: beatsPerBar, beatUnit: beatUnit)
    }
}

/// Project tempo map: tick ↔ sample conversion through tempo and meter
/// changes, at a fixed project sample rate.
///
/// Conversion is integer-exact at segment boundaries by construction (each
/// segment stores its tick anchor; the sample anchor is derived by walking
/// prior segments). Within a segment the ratio `ticks * 60 * sampleRate /
/// (ticksPerQuarter * bpm)` is evaluated in `Double` and rounded half-away-
/// from-zero, with finite and `Int64` range checks. Decoders re-run the same
/// validation as the throwing initializers, so malformed persisted maps can
/// never enter the model.
public struct MusicTempoMap: Sendable, Codable, Hashable {
    public static let minTicksPerQuarter = 24
    public static let maxTicksPerQuarter = 15_360
    public static let minSampleRate = 8_000
    public static let maxSampleRate = 192_000

    public var ticksPerQuarter: Int
    public var sampleRate: Int
    /// Tempo/meter segments, sorted by strictly increasing `startTick`.
    public private(set) var segments: [MusicTempoSegment]

    public init(ticksPerQuarter: Int = 960, sampleRate: Int = 48_000,
                segments: [MusicTempoSegment]) throws {
        guard ticksPerQuarter >= Self.minTicksPerQuarter,
              ticksPerQuarter <= Self.maxTicksPerQuarter else {
            throw MusicError.invalidTempoMap(
                reason: "ticksPerQuarter \(ticksPerQuarter) outside [\(Self.minTicksPerQuarter), \(Self.maxTicksPerQuarter)]")
        }
        guard sampleRate >= Self.minSampleRate, sampleRate <= Self.maxSampleRate else {
            throw MusicError.invalidTempoMap(
                reason: "sampleRate \(sampleRate) outside [\(Self.minSampleRate), \(Self.maxSampleRate)]")
        }
        guard !segments.isEmpty else {
            throw MusicError.invalidTempoMap(reason: "at least one tempo segment is required")
        }
        guard segments[0].startTick.value == 0 else {
            throw MusicError.invalidTempoMap(reason: "first tempo segment must start at tick 0")
        }
        // Segments are mutable values; revalidate each one, not just ordering,
        // so a caller-mutated segment cannot slip through map construction.
        var previousTick: Int64 = -1
        for segment in segments {
            guard segment.startTick.value > previousTick else {
                throw MusicError.invalidTempoMap(reason: "tempo segments must have strictly increasing start ticks")
            }
            _ = try MusicTempoSegment(startTick: segment.startTick, bpm: segment.bpm,
                                      beatsPerBar: segment.beatsPerBar, beatUnit: segment.beatUnit)
            previousTick = segment.startTick.value
        }
        self.ticksPerQuarter = ticksPerQuarter
        self.sampleRate = sampleRate
        self.segments = segments
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tpq = try c.decode(Int.self, forKey: .ticksPerQuarter)
        let rate = try c.decode(Int.self, forKey: .sampleRate)
        let segs = try c.decode([MusicTempoSegment].self, forKey: .segments)
        try self.init(ticksPerQuarter: tpq, sampleRate: rate, segments: segs)
    }

    /// Sample position of the segment's tick anchor, derived by summing the
    /// exact sample lengths of all previous segments. Throws on overflow.
    public func segmentStartSample(_ index: Int) throws -> MusicSampleTime {
        guard segments.indices.contains(index) else {
            throw MusicError.invalidTempoMap(reason: "segment index \(index) out of range")
        }
        var sample = MusicSampleTime(0)
        for i in 0..<index {
            let seg = segments[i]
            let next = segments[i + 1]
            let ticks = next.startTick.value - seg.startTick.value
            sample = try MusicSampleTime(addingSegment(sample, ticks: ticks, bpm: seg.bpm))
        }
        return sample
    }

    /// Exact sample length of `ticks` ticks at `bpm` under this map's rate and
    /// PPQN. Rounds half-away-from-zero; throws on non-finite or overflow.
    private func addingSegment(_ base: MusicSampleTime, ticks: Int64, bpm: Double) throws -> Int64 {
        guard ticks >= 0 else {
            throw MusicError.invalidTempoMap(reason: "negative tick span")
        }
        let numerator = Double(ticks) * 60.0 * Double(sampleRate)
        let denominator = Double(ticksPerQuarter) * bpm
        let exact = numerator / denominator
        guard exact.isFinite, exact <= 9.0e18 else {
            throw MusicError.invalidSampleTime(reason: "tempo conversion overflow for \(ticks) ticks at \(bpm) bpm")
        }
        let value = Int64(exact.rounded(.toNearestOrAwayFromZero))
        let (sum, overflow) = base.value.addingReportingOverflow(value)
        if overflow {
            throw MusicError.invalidSampleTime(reason: "sample time addition overflow in tempo conversion")
        }
        return sum
    }

    /// Index of the segment governing `tick`.
    public func segmentIndex(atTick tick: MusicTick) throws -> Int {
        guard tick.value >= 0 else {
            throw MusicError.invalidTempoMap(reason: "negative tick")
        }
        var index = 0
        for i in segments.indices where segments[i].startTick.value <= tick.value {
            index = i
        }
        return index
    }

    /// Convert a tick position to a sample position through tempo changes.
    public func sample(atTick tick: MusicTick) throws -> MusicSampleTime {
        let index = try segmentIndex(atTick: tick)
        let seg = segments[index]
        let base = try segmentStartSample(index)
        return try MusicSampleTime(addingSegment(base, ticks: tick.value - seg.startTick.value, bpm: seg.bpm))
    }

    /// Convert a sample position back to ticks through tempo changes.
    /// Inverse of `sample(atTick:)`; rounding follows the same rule.
    public func tick(atSample sample: MusicSampleTime) throws -> MusicTick {
        guard sample.value >= 0 else {
            throw MusicError.invalidTempoMap(reason: "negative sample")
        }
        var index = 0
        for i in segments.indices {
            if try segmentStartSample(i).value <= sample.value { index = i } else { break }
        }
        let seg = segments[index]
        let base = try segmentStartSample(index)
        let spanSamples = try sample - base
        let numerator = Double(spanSamples.value) * Double(ticksPerQuarter) * seg.bpm
        let denominator = 60.0 * Double(sampleRate)
        let exact = numerator / denominator
        guard exact.isFinite, exact <= 9.0e18 else {
            throw MusicError.invalidSampleTime(reason: "tempo conversion overflow for sample \(sample.value)")
        }
        let ticks = Int64(exact.rounded(.toNearestOrAwayFromZero))
        let (result, overflow) = seg.startTick.value.addingReportingOverflow(ticks)
        guard !overflow else { throw MusicError.invalidSampleTime(reason: "sample-to-tick overflow") }
        return MusicTick(result)
    }

    /// Return a new map with a tempo/meter change inserted at `tick`.
    /// An existing segment starting exactly at `tick` is replaced.
    public func changingTempo(atTick tick: MusicTick, bpm: Double,
                              beatsPerBar: Int, beatUnit: Int) throws -> MusicTempoMap {
        guard tick.value > 0 else {
            // Replacing the anchor segment keeps tick 0 anchored; allowed but
            // must keep the invariant that segment 0 starts at tick 0.
            let newSeg = try MusicTempoSegment(startTick: MusicTick(0), bpm: bpm,
                                               beatsPerBar: beatsPerBar, beatUnit: beatUnit)
            var segs = segments
            if segs.count > 1 {
                segs[0] = newSeg
            } else {
                segs = [newSeg]
            }
            return try MusicTempoMap(ticksPerQuarter: ticksPerQuarter, sampleRate: sampleRate, segments: segs)
        }
        let newSeg = try MusicTempoSegment(startTick: tick, bpm: bpm,
                                           beatsPerBar: beatsPerBar, beatUnit: beatUnit)
        var segs = segments.filter { $0.startTick.value != tick.value }
        segs.append(newSeg)
        segs.sort { $0.startTick.value < $1.startTick.value }
        return try MusicTempoMap(ticksPerQuarter: ticksPerQuarter, sampleRate: sampleRate, segments: segs)
    }
}
