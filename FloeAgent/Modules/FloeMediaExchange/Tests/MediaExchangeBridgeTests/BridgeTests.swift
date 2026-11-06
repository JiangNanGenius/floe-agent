import XCTest
import Foundation
import FloeWorkbench
import MediaExchangeCore
import MediaExchangeBridge

final class BridgeTests: XCTestCase {
    func testV2TimelineOTIORoundTrip() throws {
        let video = MediaAssetReference(kind: .video, relativePath: "a.mp4", originalName: "A", metadata: .init(audioTracks: 0))
        let music = MediaAssetReference(kind: .audio, relativePath: "a.wav", originalName: "M")
        var p = MediaProject(kind: .video, name: "Two tracks", canvas: .init(width: 320, height: 180, frameRate: 30_000.0 / 1_001), assets: [video, music])
        p.videoTimeline = .init(clips: [.init(assetID: video.id, trimStart: 1, trimEnd: 3)],
                               music: [.init(assetID: music.id, offsetSeconds: 0, trimStart: 0, lengthSeconds: 2)])
        var doc = try XCTUnwrap(try MediaPreparedUpgrade.upgrade(p).prepared)
        var upper = doc.trackGraph.tracks[0]
        upper.id = UUID(); upper.name = "Upper"; upper.clips[0].id = UUID()
        doc.trackGraph.tracks.append(upper)
        let sources = try [video.id: ExchangeMediaSource(externalURL: "file:///fixture/a.mp4"), music.id: ExchangeMediaSource(externalURL: "file:///fixture/a.wav")]
        let exported = try MediaPreparedExchangeBridge.exportTimeline(doc, sources: sources)
        let otio = try OTIOAdapter.export(exported)
        let reopened = try OTIOAdapter.importTimeline(otio).timeline
        let imported = try MediaPreparedExchangeBridge.importTimeline(reopened, canvas: p.canvas!,
                                        assets: [video.id.uuidString: video, music.id.uuidString: music])
        let restored = try XCTUnwrap(imported.project.prepared)
        XCTAssertEqual(restored.trackGraph.tracks.count, 3)
        XCTAssertEqual(restored.trackGraph.totalDurationSeconds, 2, accuracy: 0.000001)
        XCTAssertEqual(restored.trackGraph.frameRate, try .init(value: 30_000, timescale: 1_001))
        XCTAssertFalse(imported.originalTimeline.isEmpty)
        doc.trackGraph.tracks[0].clips[0].volume = 0.5
        XCTAssertThrowsError(try MediaPreparedExchangeBridge.exportTimeline(doc, sources: sources))
    }

    func testRasterLayersRoundTripKeepsLowAlphaAndOffsets() throws {
        let image = try RGBAImage(width: 2, height: 1, pixels: [200, 100, 50, 1, 40, 60, 80, 255])
        let input = PortableDocument(width: 32, height: 32, layers: [.init(name: "low alpha", image: image, left: 3, top: 5, opacity: 0.5)])
        let imported = try MediaPreparedExchangeBridge.importImage(input, name: "PSD")
        var decoded: [UUID: RGBAImage] = [:]
        for (id, data) in imported.pendingPNGs { decoded[id] = try PNGCodec.decode(data) }
        let output = try MediaPreparedExchangeBridge.exportImage(XCTUnwrap(imported.project.prepared), images: decoded)
        XCTAssertEqual(output, input)
    }
}
