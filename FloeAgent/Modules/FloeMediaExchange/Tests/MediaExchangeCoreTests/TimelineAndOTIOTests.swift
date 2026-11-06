// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import MediaExchangeCore

enum TimelineFixture {
    static func makeTimeline() throws -> ExchangeTimeline {
        let videoA = try ExchangeMediaReference(
            id: "videoA",
            kind: .video,
            name: "A.mov",
            source: try ExchangeMediaSource(packedRelativePath: "media/a.mov"),
            duration: try ExchangeTime(value: 10, timescale: 1),
            hasVideo: true,
            hasAudio: false,
            frameRate: try ExchangeFrameRate(numerator: 30000, denominator: 1001),
            contentHash: "aaaa",
            byteCount: 100
        )
        let videoB = try ExchangeMediaReference(
            id: "videoB",
            kind: .video,
            name: "B.mov",
            source: try ExchangeMediaSource(packedRelativePath: "media/b.mov"),
            duration: try ExchangeTime(value: 8, timescale: 1),
            hasVideo: true,
            hasAudio: false,
            frameRate: try ExchangeFrameRate(numerator: 25, denominator: 1),
            contentHash: "bbbb",
            byteCount: 200
        )
        let audio = try ExchangeMediaReference(
            id: "audio",
            kind: .audio,
            name: "mix.wav",
            source: try ExchangeMediaSource(externalURL: "file:///tmp/floe-mix.wav"),
            duration: try ExchangeTime(value: 10, timescale: 1),
            hasVideo: false,
            hasAudio: true,
            frameRate: nil,
            contentHash: "cccc",
            byteCount: 300
        )
        let clipA = ExchangeClip(
            id: "clip-A0",
            name: "A0",
            mediaID: videoA.id,
            start: .zero,
            duration: try ExchangeTime(value: 3, timescale: 1),
            sourceStart: .zero,
            markers: [
                ExchangeMarker(
                    id: "m1",
                    name: "Beat",
                    start: try ExchangeTime(value: 1, timescale: 1),
                    duration: .zero,
                    note: "marker"
                )
            ]
        )
        let gap = ExchangeGap(
            id: "gap-0",
            start: try ExchangeTime(value: 3, timescale: 1),
            duration: try ExchangeTime(value: 1, timescale: 1)
        )
        let clipB = ExchangeClip(
            id: "clip-B0",
            name: "B0",
            mediaID: videoB.id,
            start: try ExchangeTime(value: 4, timescale: 1),
            duration: try ExchangeTime(value: 2, timescale: 1),
            sourceStart: try ExchangeTime(value: 1, timescale: 1),
            retime: ExchangeRetime(rate: try ExchangeTime(value: 1, timescale: 2), preservesPitch: true)
        )
        let overlay = ExchangeClip(
            id: "clip-A1",
            name: "A1",
            mediaID: videoA.id,
            start: try ExchangeTime(value: 1, timescale: 1),
            duration: try ExchangeTime(value: 2, timescale: 1)
        )
        let audioClip = ExchangeClip(
            id: "clip-audio",
            name: "Mix",
            mediaID: audio.id,
            start: .zero,
            duration: try ExchangeTime(value: 5, timescale: 1)
        )
        return ExchangeTimeline(
            id: "timeline-1",
            name: "Two video tracks and audio",
            frameRate: try ExchangeFrameRate(numerator: 30000, denominator: 1001),
            globalStart: .zero,
            tracks: [
                ExchangeTrack(id: "v0", kind: .video, name: "V1", items: [
                    .clip(clipA), .gap(gap), .clip(clipB)
                ]),
                ExchangeTrack(id: "v1", kind: .video, name: "V2", items: [
                    .clip(overlay)
                ]),
                ExchangeTrack(id: "a1", kind: .audio, name: "A1", items: [
                    .clip(audioClip)
                ])
            ],
            media: [videoA, videoB, audio],
            markers: [
                ExchangeMarker(
                    id: "timeline-marker",
                    name: "Cut",
                    start: try ExchangeTime(value: 2, timescale: 1)
                )
            ],
            sourceRevision: 7,
            metadata: ["width": "1920", "height": "1080"]
        )
    }
}

final class TimelineAndOTIOTests: XCTestCase {
    func testTimelineValidationAndDuration() throws {
        let timeline = try TimelineFixture.makeTimeline()
        try timeline.validate()
        XCTAssertEqual(timeline.duration, try ExchangeTime(value: 6, timescale: 1))
        XCTAssertEqual(timeline.allClips.count, 4)
    }

    func testOTIORoundTripTwoVideoTracksAudioNTSCAndMixedFrameRates() throws {
        let timeline = try TimelineFixture.makeTimeline()
        let data = try OTIOAdapter.export(timeline)
        let result = try OTIOAdapter.importTimeline(data)
        XCTAssertEqual(result.timeline.frameRate, try ExchangeFrameRate(numerator: 30000, denominator: 1001))
        XCTAssertEqual(result.timeline.tracks.count, 3)
        XCTAssertEqual(result.timeline.tracks.map(\.kind), [.video, .video, .audio])
        XCTAssertEqual(result.timeline.sourceRevision, 7)
        XCTAssertEqual(result.timeline.tracks[0].items.count, 3)
        XCTAssertEqual(result.timeline.tracks[0].items[1].id, "gap-0")
        let clips = result.timeline.allClips
        XCTAssertEqual(clips.count, 4)
        let clipB = try XCTUnwrap(clips.first { $0.id == "clip-B0" })
        XCTAssertEqual(clipB.start, try ExchangeTime(value: 4, timescale: 1))
        XCTAssertEqual(clipB.duration, try ExchangeTime(value: 2, timescale: 1))
        XCTAssertEqual(clipB.sourceStart, try ExchangeTime(value: 1, timescale: 1))
        XCTAssertEqual(clipB.retime?.rate, try ExchangeTime(value: 1, timescale: 2))
        let mediaA = try XCTUnwrap(result.timeline.media.first { $0.id == "videoA" })
        let mediaB = try XCTUnwrap(result.timeline.media.first { $0.id == "videoB" })
        XCTAssertEqual(mediaA.frameRate, try ExchangeFrameRate(numerator: 30000, denominator: 1001))
        XCTAssertEqual(mediaB.frameRate, try ExchangeFrameRate(numerator: 25, denominator: 1))
        XCTAssertEqual(result.timeline.markers.first?.start, try ExchangeTime(value: 2, timescale: 1))
        XCTAssertEqual(result.timeline.tracks[0].items.compactMap { item -> ExchangeClip? in
            if case let .clip(clip) = item { return clip }
            return nil
        }.first?.markers.first?.name, "Beat")
        XCTAssertTrue(result.report.unsupported.isEmpty)
    }


    func testOTIOInsertsAnExplicitGapForAnImplicitTimelineGap() throws {
        var timeline = try TimelineFixture.makeTimeline()
        let first = ExchangeClip(
            id: "first",
            name: "first",
            mediaID: "videoA",
            start: .zero,
            duration: try ExchangeTime(value: 1, timescale: 1)
        )
        let second = ExchangeClip(
            id: "second",
            name: "second",
            mediaID: "videoA",
            start: try ExchangeTime(value: 3, timescale: 1),
            duration: try ExchangeTime(value: 1, timescale: 1)
        )
        timeline.tracks[0].items = [.clip(first), .clip(second)]
        let data = try OTIOAdapter.export(timeline)
        let result = try OTIOAdapter.importTimeline(data)
        XCTAssertEqual(result.timeline.tracks[0].items.count, 3)
        XCTAssertEqual(result.timeline.tracks[0].items[1].duration, try ExchangeTime(value: 2, timescale: 1))
        XCTAssertEqual(try XCTUnwrap(result.timeline.allClips.first { $0.id == "second" }).start, try ExchangeTime(value: 3, timescale: 1))
    }

    func testOTIOUnsupportedEffectIsReportedAndPreserved() throws {
        var timeline = try TimelineFixture.makeTimeline()
        let raw = #"{"OTIO_SCHEMA":"Blur.1","name":"Blur","blur_amount":3}"#
        timeline.tracks[0].items[0] = .clip(
            ExchangeClip(
                id: "clip-A0",
                name: "A0",
                mediaID: "videoA",
                start: .zero,
                duration: try ExchangeTime(value: 3, timescale: 1),
                effects: [
                    ExchangeEffect(name: "Blur", kind: "Blur.1", support: .reported, rawRepresentation: raw)
                ]
            )
        )
        let data = try OTIOAdapter.export(timeline)
        let result = try OTIOAdapter.importTimeline(data)
        XCTAssertEqual(result.report.unsupported.count, 1)
        XCTAssertEqual(result.report.effectsReported, 1)
        XCTAssertTrue(result.report.unsupported[0].rawRepresentation?.contains("Blur") ?? false)
        let clip = try XCTUnwrap(result.timeline.allClips.first { $0.id == "clip-A0" })
        XCTAssertEqual(clip.effects.first?.support, .reported)
        XCTAssertTrue(clip.effects.first?.rawRepresentation?.contains("Blur") ?? false)
    }

    func testOTIORejectsUnrepresentableEffectAndCaptions() throws {
        var timeline = try TimelineFixture.makeTimeline()
        timeline.tracks[0].items[0] = .clip(
            ExchangeClip(
                id: "clip-A0",
                name: "A0",
                mediaID: "videoA",
                start: .zero,
                duration: try ExchangeTime(value: 3, timescale: 1),
                effects: [ExchangeEffect(name: "Broken", kind: "Broken.1", support: .reported)]
            )
        )
        XCTAssertThrowsError(try OTIOAdapter.export(timeline))

        var supported = try TimelineFixture.makeTimeline()
        supported.tracks[0].items[0] = .clip(
            ExchangeClip(
                id: "clip-A0",
                name: "A0",
                mediaID: "videoA",
                start: .zero,
                duration: try ExchangeTime(value: 3, timescale: 1),
                effects: [ExchangeEffect(name: "Mapped", kind: "Mapped.1", support: .supported)]
            )
        )
        XCTAssertThrowsError(try OTIOAdapter.export(supported), "supported but unmapped effects must not be dropped")

        var captioned = try TimelineFixture.makeTimeline()
        captioned.tracks[0].items[0] = .clip(
            ExchangeClip(
                id: "clip-A0",
                name: "A0",
                mediaID: "videoA",
                start: .zero,
                duration: try ExchangeTime(value: 3, timescale: 1),
                captions: [
                    ExchangeCaption(
                        id: "c1",
                        text: "Hello",
                        language: "en",
                        start: .zero,
                        duration: try ExchangeTime(value: 1, timescale: 1)
                    )
                ]
            )
        )
        XCTAssertThrowsError(try OTIOAdapter.export(captioned))
    }

    func testOTIOMissingMediaAndTraversalRejection() throws {
        let timeline = try TimelineFixture.makeTimeline()
        let data = try OTIOAdapter.export(timeline)
        let root = try TestSupport.temporaryDirectory("otio-missing")
        defer { TestSupport.remove(root) }
        let result = try OTIOAdapter.importTimeline(data, packageRoot: root)
        XCTAssertEqual(Set(result.report.missingMedia), ["audio", "videoA", "videoB"])
        XCTAssertThrowsError(try ExchangeMediaSource(packedRelativePath: "../escape.mov"))
        XCTAssertThrowsError(try ExchangeMediaSource(packedRelativePath: "/absolute.mov"))
        XCTAssertThrowsError(try ExchangeMediaSource(externalURL: "relative/path.mov"))
    }

    func testOTIORejectsUnknownRootSchemaAndMalformedJSON() throws {
        XCTAssertThrowsError(try OTIOAdapter.importTimeline(Data("{}".utf8)))
        XCTAssertThrowsError(try OTIOAdapter.importTimeline(Data("not json".utf8)))
    }
}
