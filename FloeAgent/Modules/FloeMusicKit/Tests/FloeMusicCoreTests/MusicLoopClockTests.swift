// SPDX-License-Identifier: MPL-2.0
import XCTest
@testable import FloeMusicCore

/// Pure math of the frozen recording loop: linear transport position to
/// musical position, pass counting and validation. Tempo conversion stays
/// with MusicTempoMap; these tests pin the sample-level contract the
/// transport and the capture stamps rely on.
final class MusicLoopClockTests: XCTestCase {
    private let loop = try! MusicLoopRange(startSample: 48_000, endSample: 48_000 + 96_000) // [1 s, 3 s)

    func testMusicalPositionWrapsInsideFrozenRegion() {
        XCTAssertEqual(loop.musicalPosition(linearSample: 48_000), 48_000)
        XCTAssertEqual(loop.musicalPosition(linearSample: 143_999), 143_999)
        XCTAssertEqual(loop.musicalPosition(linearSample: 144_000), 48_000)
        XCTAssertEqual(loop.musicalPosition(linearSample: 144_001), 48_001)
        XCTAssertEqual(loop.musicalPosition(linearSample: 240_000), 48_000) // two full passes
        XCTAssertEqual(loop.musicalPosition(linearSample: 240_123), 48_123)
    }

    func testPassIndexCountsCrossedBoundaries() {
        XCTAssertEqual(loop.passIndex(linearSample: 48_000), 0)
        XCTAssertEqual(loop.passIndex(linearSample: 143_999), 0)
        XCTAssertEqual(loop.passIndex(linearSample: 144_000), 1)
        XCTAssertEqual(loop.passIndex(linearSample: 239_999), 1)
        XCTAssertEqual(loop.passIndex(linearSample: 240_000), 2)
        XCTAssertEqual(loop.passIndex(linearSample: 10_000_000), (10_000_000 - 48_000) / 96_000)
    }

    func testPositionsBeforeStartPassThrough() {
        XCTAssertEqual(loop.musicalPosition(linearSample: 0), 0)
        XCTAssertEqual(loop.passIndex(linearSample: 0), 0)
    }

    func testValidationRejectsDegenerateRegions() {
        XCTAssertThrowsError(try MusicLoopRange(startSample: -1, endSample: 48_000))
        XCTAssertThrowsError(try MusicLoopRange(startSample: 48_000, endSample: 48_000))
        XCTAssertThrowsError(try MusicLoopRange(startSample: 48_000, endSample: 48_001))
        XCTAssertNoThrow(try MusicLoopRange(startSample: 48_000, endSample: 48_000 + MusicLoopRange.minimumLengthSamples))
    }

    func testTickConversionAcrossLoopBoundaryUsesTempoMap() throws {
        // A tempo change inside the loop region must convert through the
        // trusted map exactly; the loop itself never re-interprets ticks.
        let map = try MusicTempoMap(ticksPerQuarter: 960, sampleRate: 48_000, segments: [
            try MusicTempoSegment(startTick: MusicTick(0), bpm: 120, beatsPerBar: 4, beatUnit: 4),
            try MusicTempoSegment(startTick: MusicTick(1_920), bpm: 60, beatsPerBar: 4, beatUnit: 4),
        ])
        // Tick 1_920 at 120 bpm = 1 s = 48_000 samples.
        XCTAssertEqual(try map.sample(atTick: MusicTick(1_920)).value, 48_000)
        let loopEndTick = try map.tick(atSample: MusicSampleTime(144_000)).value
        XCTAssertEqual(loopEndTick, 3_840) // 0.5 s at 120 bpm (960) + 2 s at 60 bpm (1_920) from tick 960
        // The frozen region [48_000, 144_000) spans exactly those ticks.
        let startTick = try map.tick(atSample: MusicSampleTime(loop.startSample)).value
        XCTAssertEqual(loopEndTick - startTick, 2_880 - 960)
    }

    func testCodableRoundTripRevalidates() throws {
        let bytes = try JSONEncoder().encode(loop)
        let decoded = try JSONDecoder().decode(MusicLoopRange.self, from: bytes)
        XCTAssertEqual(decoded, loop)
        let corrupt = try JSONEncoder().encode(["startSample": 5, "endSample": 3] as [String: Int64])
        XCTAssertThrowsError(try JSONDecoder().decode(MusicLoopRange.self, from: corrupt))
    }
}
