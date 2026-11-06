import XCTest
@testable import FloeMusicCore

@MainActor
final class TempoMapTests: XCTestCase {
    func testConstantTempoSampleConversion() throws {
        let map = try MusicTempoMap(ticksPerQuarter: 960, sampleRate: 48_000,
                                    segments: [try MusicTempoSegment(startTick: MusicTick(0), bpm: 120,
                                                                     beatsPerBar: 4, beatUnit: 4)])
        // One quarter note at 120 bpm, 48 kHz = 0.5 s = 24 000 samples.
        XCTAssertEqual(try map.sample(atTick: MusicTick(960)).value, 24_000)
        // One bar (4 beats) = 96 000 samples.
        XCTAssertEqual(try map.sample(atTick: MusicTick(4 * 960)).value, 96_000)
        // Tick 0 anchors at sample 0.
        XCTAssertEqual(try map.sample(atTick: MusicTick(0)).value, 0)
    }

    func testTempoChangeConversionWalksSegments() throws {
        // 120 bpm for 960 ticks (1 quarter = 24 000 samples), then 60 bpm.
        let map = try MusicTempoMap(ticksPerQuarter: 960, sampleRate: 48_000,
                                    segments: [
                                        try MusicTempoSegment(startTick: MusicTick(0), bpm: 120,
                                                              beatsPerBar: 4, beatUnit: 4),
                                        try MusicTempoSegment(startTick: MusicTick(960), bpm: 60,
                                                              beatsPerBar: 3, beatUnit: 4),
                                    ])
        // Segment boundary is exact: 24 000 samples.
        XCTAssertEqual(try map.sample(atTick: MusicTick(960)).value, 24_000)
        // One quarter at 60 bpm = 48 000 samples.
        XCTAssertEqual(try map.sample(atTick: MusicTick(1_920)).value, 24_000 + 48_000)
        // Meter change point is consistent backwards.
        XCTAssertEqual(try map.tick(atSample: MusicSampleTime(24_000)).value, 960)
        XCTAssertEqual(try map.tick(atSample: MusicSampleTime(24_000 + 48_000)).value, 1_920)
    }

    func testFractionalBpmRoundsDeterministically() throws {
        let map = try MusicTempoMap(ticksPerQuarter: 960, sampleRate: 44_100,
                                    segments: [try MusicTempoSegment(startTick: MusicTick(0), bpm: 100.5,
                                                                     beatsPerBar: 4, beatUnit: 4)])
        // 960 ticks * 60 * 44100 / (960 * 100.5) = 26328.358... -> 26328.
        let sample = try map.sample(atTick: MusicTick(960))
        XCTAssertEqual(sample.value, 26_328)
        // Round trip stays within documented rounding.
        let tick = try map.tick(atSample: sample)
        XCTAssertEqual(tick.value, 960)
    }

    func testOverflowThrows() throws {
        let map = try MusicTempoMap(ticksPerQuarter: 960, sampleRate: 48_000,
                                    segments: [try MusicTempoSegment(startTick: MusicTick(0), bpm: 20,
                                                                     beatsPerBar: 4, beatUnit: 4)])
        XCTAssertThrowsError(try map.sample(atTick: MusicTick(Int64.max / 2))) { error in
            guard case MusicError.invalidSampleTime = error else {
                return XCTFail("expected invalidSampleTime, got \(error)")
            }
        }
    }

    func testMutatedSegmentRejectedByMapRevalidation() throws {
        // Public mutation after construction must be caught by map
        // construction/validation, not trusted.
        var segments = [try MusicTempoSegment(startTick: MusicTick(0), bpm: 120,
                                              beatsPerBar: 4, beatUnit: 4)]
        segments[0].bpm = .nan
        XCTAssertThrowsError(try MusicTempoMap(ticksPerQuarter: 960, sampleRate: 48_000,
                                               segments: segments)) { error in
            guard case MusicError.invalidTempoMap = error else {
                return XCTFail("expected invalidTempoMap, got \(error)")
            }
        }
        segments[0].bpm = 120
        segments[0].beatUnit = 3
        XCTAssertThrowsError(try MusicTempoMap(ticksPerQuarter: 960, sampleRate: 48_000,
                                               segments: segments)) { error in
            guard case MusicError.invalidTempoMap = error else {
                return XCTFail("expected invalidTempoMap, got \(error)")
            }
        }
    }

    func testMapFieldBounds() throws {
        let segment = [try MusicTempoSegment(startTick: MusicTick(0), bpm: 120,
                                             beatsPerBar: 4, beatUnit: 4)]
        XCTAssertThrowsError(try MusicTempoMap(ticksPerQuarter: 1, sampleRate: 48_000, segments: segment))
        XCTAssertThrowsError(try MusicTempoMap(ticksPerQuarter: 960, sampleRate: 1_000, segments: segment))
        // Unsorted and empty segment lists are rejected.
        let later = try MusicTempoSegment(startTick: MusicTick(960), bpm: 90, beatsPerBar: 4, beatUnit: 4)
        XCTAssertThrowsError(try MusicTempoMap(ticksPerQuarter: 960, sampleRate: 48_000,
                                               segments: [later, segment[0]]))
        XCTAssertThrowsError(try MusicTempoMap(ticksPerQuarter: 960, sampleRate: 48_000, segments: []))
    }
}
