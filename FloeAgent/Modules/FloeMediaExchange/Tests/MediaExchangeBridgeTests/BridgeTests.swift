import XCTest
import Foundation
import FloeWorkbench
import MediaExchangeCore
import MediaExchangeBridge

final class BridgeTests: XCTestCase {
    func testPassThroughBlendsAndNonadjacentClipsAreExplicitlyRefused() throws {
        let pixel = try RGBAImage(width: 1, height: 1, pixels: [100, 200, 40, 255])
        let unsafe = PortableDocument(width: 16, height: 16, layers: [
            .init(name: "Backdrop", image: pixel), .init(name: "Pass through", image: pixel, blendMode: "pass through", group: true),
            .init(name: "Multiply", image: pixel, blendMode: "multiply", depth: 1)
        ])
        XCTAssertThrowsError(try MediaPreparedExchangeBridge.importImage(unsafe, name: "Unsupported"))
        var document = try XCTUnwrap(MediaPreparedExchangeBridge.importImage(.init(width: 16, height: 16, layers: [
            .init(name: "A", image: pixel), .init(name: "B", image: pixel), .init(name: "C", image: pixel)
        ]), name: "Clipping").project.prepared)
        document.layers[2].clip = .init(baseLayerID: document.layers[0].id)
        var images: [UUID: RGBAImage] = [:]
        for asset in document.assets { images[asset.id] = pixel }
        XCTAssertThrowsError(try MediaPreparedExchangeBridge.exportImage(document, images: images))
    }

    func testGroupsMasksAndBlendLayersRemainCanonicalAndPersist() throws {
        let clear = try RGBAImage(width: 1, height: 1, pixels: [0, 0, 0, 0])
        let pixels = try RGBAImage(width: 2, height: 1, pixels: [200, 100, 50, 1, 40, 60, 80, 255])
        let mask = PortableMask(image: try .init(width: 1, height: 1, pixels: [128, 128, 128, 255]), left: 0, top: 0, defaultColor: 255)
        let input = PortableDocument(width: 32, height: 32, layers: [
            .init(name: "Group", image: clear, blendMode: "multiply", mask: mask, group: true),
            .init(name: "Photo", image: pixels, left: 3, top: 5, opacity: 0.5, blendMode: "multiply", mask: mask, depth: 1)
        ])
        let result = try MediaPreparedExchangeBridge.importImage(input, name: "Layered")
        let document = try XCTUnwrap(result.project.prepared)
        XCTAssertEqual(document.layers.filter { $0.contentKind == .group }.count, 3)
        XCTAssertEqual(document.layers.filter { $0.mask != nil }.count, 2)
        let group = try XCTUnwrap(document.layers.first { $0.name == "Group" })
        guard case .group(let groupContent) = group.content else { return XCTFail("group was flattened") }
        XCTAssertEqual(groupContent.blendMode, "multiply")
        XCTAssertNotNil(group.mask, "group blending and its mask must remain on the same compositing boundary")
        let raster = try XCTUnwrap(document.layers.first { $0.contentKind == .raster })
        XCTAssertEqual(raster.transform.scale, 1.0 / 16, accuracy: 0.000001)
        let restored = try JSONDecoder().decode(MediaProject.self, from: JSONEncoder().encode(result.project))
        try MediaPreparedIntegrity.validateEnvelope(restored)
        XCTAssertEqual(restored.prepared, result.project.prepared)
        XCTAssertEqual(try result.pendingPNGs.values.map { try PNGCodec.decode($0) }.first, pixels)
    }

    func testClippingChainKeepsTheSameBaseAndTextStaysEditable() throws {
        let pixel = try RGBAImage(width: 1, height: 1, pixels: [100, 200, 40, 255])
        let input = PortableDocument(width: 32, height: 32, layers: [
            .init(name: "Base", image: pixel), .init(name: "Clip 1", image: pixel, clipping: true),
            .init(name: "Clip 2", image: pixel, clipping: true),
            .init(name: "Text", image: pixel, text: .init(text: "Floe", fontName: "Helvetica", fontSize: 12, colorHex: "#FFFFFF"))
        ])
        let document = try XCTUnwrap(MediaPreparedExchangeBridge.importImage(input, name: "Clips").project.prepared)
        let base = document.layers[0].id
        XCTAssertEqual(document.layers[1].clip?.baseLayerID, base)
        XCTAssertEqual(document.layers[2].clip?.baseLayerID, base)
        guard case .text(let text) = document.layers[3].content else { return XCTFail("text was rasterized") }
        XCTAssertEqual(text.text, "Floe")
    }

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
