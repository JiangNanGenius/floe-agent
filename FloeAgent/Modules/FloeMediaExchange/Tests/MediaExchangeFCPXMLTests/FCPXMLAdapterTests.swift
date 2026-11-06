// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import MediaExchangeCore
@testable import MediaExchangeFCPXML

enum FCPXMLFixture {
    static func timeline(withCaption: Bool = false) throws -> ExchangeTimeline {
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
            contentHash: "cccc",
            byteCount: 300
        )
        let captions = withCaption ? [
            ExchangeCaption(
                id: "caption-1",
                text: "Hello & <world>",
                language: "en",
                start: try ExchangeTime(value: 1, timescale: 2),
                duration: try ExchangeTime(value: 1, timescale: 2)
            )
        ] : []
        let clipA = ExchangeClip(
            id: "clip-A0",
            name: "A0",
            mediaID: videoA.id,
            start: .zero,
            duration: try ExchangeTime(value: 3, timescale: 1),
            markers: [
                ExchangeMarker(
                    id: "marker-A",
                    name: "Start",
                    start: try ExchangeTime(value: 1, timescale: 4)
                )
            ],
            captions: captions
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
            sourceStart: try ExchangeTime(value: 1, timescale: 1)
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
            id: "timeline-fcpxml",
            name: "FCPXML fixture",
            frameRate: try ExchangeFrameRate(numerator: 30000, denominator: 1001),
            tracks: [
                ExchangeTrack(id: "v0", kind: .video, name: "V1", items: [
                    .clip(clipA), .gap(gap), .clip(clipB)
                ]),
                ExchangeTrack(id: "v1", kind: .video, name: "V2", items: [.clip(overlay)]),
                ExchangeTrack(id: "a1", kind: .audio, name: "A1", items: [.clip(audioClip)])
            ],
            media: [videoA, videoB, audio],
            markers: [
                ExchangeMarker(
                    id: "timeline-marker",
                    name: "Cut",
                    start: try ExchangeTime(value: 2, timescale: 1)
                )
            ],
            sourceRevision: 9,
            metadata: ["width": "1920", "height": "1080"]
        )
    }
}

final class FCPXMLAdapterTests: XCTestCase {
    func testExportImportTwoVideoTracksAudioAndNTSC() throws {
        let timeline = try FCPXMLFixture.timeline()
        let xml = try FCPXMLAdapter.export(timeline)
        XCTAssertTrue(xml.contains("frameDuration=\"1001/30000s\""), xml)
        let result = try FCPXMLAdapter.importTimeline(xml)
        XCTAssertEqual(result.timeline.frameRate, try ExchangeFrameRate(numerator: 30000, denominator: 1001))
        XCTAssertEqual(result.timeline.tracks.count, 3)
        XCTAssertEqual(result.timeline.tracks.filter { $0.kind == .video }.count, 2)
        XCTAssertEqual(result.timeline.tracks.filter { $0.kind == .audio }.count, 1)
        let clips = result.timeline.allClips
        XCTAssertEqual(clips.count, 4)
        XCTAssertEqual(result.timeline.media.count, 3)
        XCTAssertEqual(Set(result.timeline.media.map(\.id)), ["audio", "videoA", "videoB"])
        let mediaA = try XCTUnwrap(result.timeline.media.first { $0.id == "videoA" })
        let mediaB = try XCTUnwrap(result.timeline.media.first { $0.id == "videoB" })
        XCTAssertEqual(mediaA.frameRate, try ExchangeFrameRate(numerator: 30000, denominator: 1001))
        XCTAssertEqual(mediaB.frameRate, try ExchangeFrameRate(numerator: 25, denominator: 1))
        let clipB = try XCTUnwrap(clips.first { $0.id == "clip-B0" })
        XCTAssertEqual(clipB.start, try ExchangeTime(value: 4, timescale: 1))
        XCTAssertEqual(clipB.duration, try ExchangeTime(value: 2, timescale: 1))
        XCTAssertEqual(clipB.sourceStart, try ExchangeTime(value: 1, timescale: 1))
        let primary = try XCTUnwrap(result.timeline.tracks.first { $0.kind == .video && $0.id == "v0" })
        XCTAssertTrue(primary.items.contains { $0.id == "gap-0" })
        XCTAssertEqual(result.report.unsupported.count, 0)
        XCTAssertEqual(result.timeline.markers.first?.name, "Cut")
        XCTAssertEqual(result.timeline.markers.first?.start, try ExchangeTime(value: 2, timescale: 1))
    }

    func testCaptionsRoundTripAndAreCounted() throws {
        let timeline = try FCPXMLFixture.timeline(withCaption: true)
        let xml = try FCPXMLAdapter.export(timeline)
        let result = try FCPXMLAdapter.importTimeline(xml)
        XCTAssertEqual(result.report.captionsImported, 1)
        let clip = try XCTUnwrap(result.timeline.allClips.first { $0.id == "clip-A0" })
        let caption = try XCTUnwrap(clip.captions.first)
        XCTAssertEqual(caption.text, "Hello & <world>")
        XCTAssertEqual(caption.language, "en")
        XCTAssertEqual(caption.duration, try ExchangeTime(value: 1, timescale: 2))
    }

    func testUnsupportedEffectIsReportedAndExportRefusesToDropIt() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <fcpxml version="1.10">
          <resources>
            <format id="r1" name="FFVideoFormat1080p2997" frameDuration="1001/30000s" width="1920" height="1080"/>
            <asset id="a1" name="A" duration="10s" hasVideo="1" hasAudio="1" format="r1">
              <media-rep kind="original-media" src="media/a.mov"/>
            </asset>
          </resources>
          <library><event name="E"><project name="P"><sequence format="r1" duration="10s" tcStart="0s" tcFormat="NDF">
            <spine><asset-clip ref="a1" offset="0s" duration="3s">
              <filter-video ref="r9" name="Blur"/>
            </asset-clip></spine>
          </sequence></project></event></library>
        </fcpxml>
        """
        let result = try FCPXMLAdapter.importTimeline(xml)
        XCTAssertEqual(result.report.effectsReported, 1)
        XCTAssertEqual(result.report.unsupported.first?.name, "filter-video")
        let clip = try XCTUnwrap(result.timeline.allClips.first)
        XCTAssertEqual(clip.effects.first?.support, .reported)
        XCTAssertTrue(clip.effects.first?.rawRepresentation?.contains("filter-video") ?? false)
        XCTAssertThrowsError(try FCPXMLAdapter.export(result.timeline)) { error in
            guard case FCPXMLAdapterError.unsupportedEffect = error else {
                return XCTFail("expected unsupportedEffect, got \(error)")
            }
        }
    }

    func testUnsafeXMLAndTraversalAreRejected() throws {
        let timeline = try FCPXMLFixture.timeline()
        let xml = try FCPXMLAdapter.export(timeline)
        let doctype = "<?xml version=\"1.0\"?><!DOCTYPE fcpxml [<!ENTITY xxe SYSTEM \"file:///etc/passwd\">]>" + xml
        XCTAssertThrowsError(try FCPXMLAdapter.importTimeline(doctype))
        XCTAssertThrowsError(try ExchangeMediaSource(packedRelativePath: "../media/a.mov"))
        XCTAssertThrowsError(try ExchangeMediaSource(packedRelativePath: "/media/a.mov"))
    }

    func testMissingMediaIsReportedWithPackageRoot() throws {
        let timeline = try FCPXMLFixture.timeline()
        let xml = try FCPXMLAdapter.export(timeline)
        let root = try FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-fcpxml-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try FCPXMLAdapter.importTimeline(xml, packageRoot: root)
        XCTAssertEqual(Set(result.report.missingMedia), ["audio", "videoA", "videoB"])
    }

    func testUnsupportedSpineElementIsReportedNotDropped() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <fcpxml version="1.10">
          <resources>
            <format id="r1" frameDuration="1/25s" width="1920" height="1080"/>
            <asset id="a1" name="A" duration="5s" hasVideo="1" hasAudio="0" format="r1">
              <media-rep kind="original-media" src="media/a.mov"/>
            </asset>
          </resources>
          <project name="P"><sequence format="r1" duration="5s"><spine>
            <title name="Title">Text</title>
            <asset-clip ref="a1" offset="0s" duration="5s"/>
          </spine></sequence></project>
        </fcpxml>
        """
        let result = try FCPXMLAdapter.importTimeline(xml)
        XCTAssertTrue(result.report.unsupported.contains { $0.name == "title" })
        XCTAssertEqual(result.timeline.allClips.count, 1)
    }
}
