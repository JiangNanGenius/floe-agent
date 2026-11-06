// SPDX-License-Identifier: MPL-2.0
//
// Independent macOS qualification of the pinned OpenFCPXMLKit 3.3.15 commit.
// The library's public model is annotated macOS 26 only despite its iOS 26
// platform declaration; the cross-platform adapter is therefore native
// Foundation XML and this target proves the upstream parser/exporter behavior.

import XCTest

#if os(macOS)
import Foundation
import CoreMedia
import OpenFCPXMLKit
@testable import MediaExchangeCore
@testable import MediaExchangeFCPXML

@available(macOS 26.0, *)
final class OpenFCPXMLKitQualificationTests: XCTestCase {
    private func smallTimeline() throws -> ExchangeTimeline {
        let media = try ExchangeMediaReference(
            id: "video",
            kind: .video,
            name: "A.mov",
            source: try ExchangeMediaSource(packedRelativePath: "media/a.mov"),
            duration: try ExchangeTime(value: 5, timescale: 1),
            hasVideo: true,
            hasAudio: false,
            frameRate: try ExchangeFrameRate(numerator: 30000, denominator: 1001)
        )
        let clip = ExchangeClip(
            id: "clip",
            name: "A",
            mediaID: media.id,
            start: .zero,
            duration: try ExchangeTime(value: 5, timescale: 1)
        )
        return ExchangeTimeline(
            id: "openkit",
            name: "OpenKit",
            frameRate: try ExchangeFrameRate(numerator: 30000, denominator: 1001),
            tracks: [ExchangeTrack(id: "v0", kind: .video, name: "V1", items: [.clip(clip)])],
            media: [media]
        )
    }

    func testPinnedParserReadsNativeExportedFCPXML() throws {
        let xml = try FCPXMLAdapter.export(smallTimeline())
        let document = try FinalCutPro.FCPXML(fileContent: Data(xml.utf8))
        XCTAssertEqual(document.version.rawValue, "1.10")
        XCTAssertEqual(document.allProjects().count, 1)
        XCTAssertEqual(document.allTimelines().count, 1)
        XCTAssertEqual(document.allProjects().first?.name, "OpenKit")

        let parser = FCPXMLParser()
        let parsed = try parser.parse(Data(xml.utf8))
        XCTAssertTrue(parser.validate(parsed))
        XCTAssertEqual(parsed.rootElement()?.name, "fcpxml")
    }



    private func fullTimeline() throws -> ExchangeTimeline {
        let videoA = try ExchangeMediaReference(
            id: "videoA", kind: .video, name: "A.mov",
            source: try ExchangeMediaSource(packedRelativePath: "media/a.mov"),
            duration: try ExchangeTime(value: 10, timescale: 1),
            hasVideo: true, hasAudio: false,
            frameRate: try ExchangeFrameRate(numerator: 30000, denominator: 1001)
        )
        let videoB = try ExchangeMediaReference(
            id: "videoB", kind: .video, name: "B.mov",
            source: try ExchangeMediaSource(packedRelativePath: "media/b.mov"),
            duration: try ExchangeTime(value: 8, timescale: 1),
            hasVideo: true, hasAudio: false,
            frameRate: try ExchangeFrameRate(numerator: 25, denominator: 1)
        )
        let audio = try ExchangeMediaReference(
            id: "audio", kind: .audio, name: "mix.wav",
            source: try ExchangeMediaSource(externalURL: "file:///tmp/floe-mix.wav"),
            duration: try ExchangeTime(value: 10, timescale: 1),
            hasVideo: false, hasAudio: true
        )
        let caption = ExchangeCaption(
            id: "cap", text: "Hello", language: "en",
            start: try ExchangeTime(value: 1, timescale: 2),
            duration: try ExchangeTime(value: 1, timescale: 2)
        )
        let clipA = ExchangeClip(
            id: "A0", name: "A0", mediaID: "videoA", start: .zero,
            duration: try ExchangeTime(value: 3, timescale: 1),
            captions: [caption]
        )
        let gap = ExchangeGap(id: "g", start: try ExchangeTime(value: 3, timescale: 1), duration: try ExchangeTime(value: 1, timescale: 1))
        let clipB = ExchangeClip(id: "B0", name: "B0", mediaID: "videoB", start: try ExchangeTime(value: 4, timescale: 1), duration: try ExchangeTime(value: 2, timescale: 1))
        let overlay = ExchangeClip(id: "A1", name: "A1", mediaID: "videoA", start: try ExchangeTime(value: 1, timescale: 1), duration: try ExchangeTime(value: 2, timescale: 1))
        let audioClip = ExchangeClip(id: "MIX", name: "Mix", mediaID: "audio", start: .zero, duration: try ExchangeTime(value: 5, timescale: 1))
        return ExchangeTimeline(
            id: "full", name: "Full", frameRate: try ExchangeFrameRate(numerator: 30000, denominator: 1001),
            tracks: [
                ExchangeTrack(id: "v0", kind: .video, name: "V1", items: [.clip(clipA), .gap(gap), .clip(clipB)]),
                ExchangeTrack(id: "v1", kind: .video, name: "V2", items: [.clip(overlay)]),
                ExchangeTrack(id: "a1", kind: .audio, name: "A1", items: [.clip(audioClip)])
            ],
            media: [videoA, videoB, audio],
            markers: [ExchangeMarker(id: "tm", name: "Cut", start: try ExchangeTime(value: 2, timescale: 1))]
        )
    }

    func testNativeExportPassesPinnedDTDValidation() throws {
        let xml = try FCPXMLAdapter.export(smallTimeline())
        let service = FCPXMLService()
        let document = try service.parseFCPXML(from: Data(xml.utf8))
        let result = service.validateDocumentAgainstDTD(document, version: .v1_10)
        XCTAssertTrue(result.isValid, result.detailedDescription)
    }

    func testFullTimelinePassesPinnedDTDValidation() throws {
        let xml = try FCPXMLAdapter.export(fullTimeline())
        let service = FCPXMLService()
        let document = try service.parseFCPXML(from: Data(xml.utf8))
        let result = service.validateDocumentAgainstDTD(document, version: .v1_10)
        XCTAssertTrue(result.isValid, result.detailedDescription)
    }

    func testUpstreamExporterOutputIsAcceptedByNativeImporter() throws {
        let format = TimelineFormat(
            width: 1920,
            height: 1080,
            frameDuration: CMTime(value: 1001, timescale: 30000)
        )
        let asset = FCPXMLExportAsset(
            id: "r2",
            name: "A",
            src: URL(fileURLWithPath: "/tmp/floe-openkit-a.mov"),
            duration: CMTime(value: 5, timescale: 1),
            hasVideo: true,
            hasAudio: false
        )
        let clip = TimelineClip(
            name: "A",
            assetRef: "r2",
            offset: .zero,
            duration: CMTime(value: 5, timescale: 1),
            lane: 0
        )
        let timeline = Timeline(name: "OpenKit export", format: format, clips: [clip])
        let xml = try FCPXMLExporter(version: .v1_10).export(timeline: timeline, assets: [asset])
        XCTAssertTrue(xml.contains("frameDuration=\"1001/30000s\""), xml)
        let result = try FCPXMLAdapter.importTimeline(xml)
        XCTAssertEqual(result.timeline.allClips.count, 1)
        XCTAssertEqual(result.timeline.frameRate, try ExchangeFrameRate(numerator: 30000, denominator: 1001))
        XCTAssertEqual(result.timeline.name, "OpenKit export")
    }
}
#endif
