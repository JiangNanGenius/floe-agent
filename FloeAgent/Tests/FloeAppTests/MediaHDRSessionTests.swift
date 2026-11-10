// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
import FloeWorkbench
@testable import FloeApp

@Suite("M50 native project color contract",.serialized)
@MainActor struct MediaHDRSessionTests {
    @Test func modelSetsAndClearsProjectColorThroughTheExistingSavedCanvasAndUndo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-HDR-policy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaProjectStore(directory: root.appendingPathComponent("Projects")),project = MediaProject(kind: .video,name: "HDR policy",canvas: .init(width: 128,height: 96,frameRate: 10))
        try await store.save(project)
        let setup = MediaPreparedCoordinator(store: store);_ = try await setup.upgradeDocument(id: project.id)
        let session = try await MediaV2Session.open(projectID: project.id,root: root,store: store);defer { session.stopPlayback() }
        var input = MediaV2ToolInput();input.expectedRevision = session.document.revision;input.property = "rec2020HLG"
        let receipt = try await session.performTool("video.hdr",input: input,actor: .model)
        #expect(receipt.colorProfile == .rec2020HLG && session.document.canvas?.videoColorProfile == .rec2020HLG)
        #expect(session.project.canvas == session.document.canvas && session.document.canvas?.width == 128 && session.document.canvas?.frameRate == 10)
        let saved = try await store.loadProject(id: project.id)
        #expect(saved?.canvas?.videoColorProfile == .rec2020HLG && saved?.prepared?.canvas == saved?.canvas)
        let group = try #require(receipt.groupID)
        _ = try await session.coordinator.undoGroup(group,in: project.id);try await session.reload()
        #expect(session.document.canvas?.videoColorProfile == nil)
        _ = try await session.coordinator.redoGroup(group,in: project.id);try await session.reload()
        #expect(session.document.canvas?.videoColorProfile == .rec2020HLG)
        input.flag = false;input.expectedRevision = session.document.revision
        _ = try await session.performTool("video.hdr",input: input,actor: .model)
        #expect(session.document.canvas?.videoColorProfile == nil && !session.processingTool)
        let before = try Data(contentsOf: store.projectURL(id: project.id));input.flag = nil;input.expectedRevision = nil
        do { _ = try await session.performTool("video.hdr",input: input,actor: .model);Issue.record("Model omitted color-setting revision") }
        catch MediaPreparedCoreError.documentChanged { }
        #expect(try Data(contentsOf: store.projectURL(id: project.id)) == before)
    }

    @Test func matchSourceReadsActualHDRImageMetadataAndPreservesOriginalBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-HDR-detect-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Assets"),withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let width = 64,height = 48, values = [Float16](repeating: 0.75,count: width*height*4)
        var pixels = values
        for i in stride(from: 3,to: pixels.count,by: 4) { pixels[i] = 1 }
        let bytes = pixels.withUnsafeBytes { Data($0) }, provider = try #require(CGDataProvider(data: bytes as CFData))
        let space = try MediaVideoColorProfile.rec2020HLG.colorSpace()
        let image = try #require(CGImage(width: width,height: height,bitsPerComponent: 16,bitsPerPixel: 64,bytesPerRow: width*8,space: space,
            bitmapInfo: [.floatComponents,.byteOrder16Little,CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)],provider: provider,
            decode: nil,shouldInterpolate: false,intent: .defaultIntent))
        let tiff = NSMutableData(), destination = try #require(CGImageDestinationCreateWithData(tiff,UTType.tiff.identifier as CFString,1,nil))
        CGImageDestinationAddImage(destination,image,nil);#expect(CGImageDestinationFinalize(destination))
        let original = tiff as Data, url = root.appendingPathComponent("Assets/actual-source.tiff");try original.write(to: url)
        let project = MediaProject(kind: .video,name: "Source color",canvas: .init(width: width,height: height,frameRate: 10))
        let store = MediaProjectStore(directory: root.appendingPathComponent("Projects")),coordinator = MediaPreparedCoordinator(store: store)
        try await store.save(project);_ = try await coordinator.upgradeDocument(id: project.id)
        let asset = MediaAssetReference(kind: .image,relativePath: "Assets/actual-source.tiff",originalName: "Actual source")
        let track = MediaPreparedTrack(kind: .visual,name: "Source"),range = try MediaTimeRange(start: .seconds(0),duration: .seconds(0.3))
        let clip = MediaPreparedClip(assetID: asset.id,timelineRange: range,sourceRange: range)
        _ = try await coordinator.applyUserOperations([.init(action: .insertAsset(asset)),.init(action: .insertTrack(track: track,index: nil)),
            .init(action: .insertClip(trackID: track.id,clip: clip,index: nil))],to: project.id)
        let session = try await MediaV2Session.open(projectID: project.id,root: root,store: store);defer { session.stopPlayback() }
        var input = MediaV2ToolInput();input.objectID = clip.id;input.expectedRevision = session.document.revision;input.property = "source"
        let receipt = try await session.performTool("video.hdr",input: input,actor: .model)
        #expect(receipt.colorProfile == .rec2020HLG && session.document.canvas?.videoColorProfile == .rec2020HLG)
        #expect(try Data(contentsOf: url) == original)
    }
}
#endif
