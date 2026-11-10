// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import CoreGraphics
import Testing
import FloeWorkbench
@testable import FloeApp

@Suite("M49 actual native source/color transaction",.serialized)
@MainActor struct MediaColorMatchSessionTests {
    @Test func modelMatchesActualLockedReferenceSavesAndClearsOnlyMatching() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-color-match-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Assets"),withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func png(_ offset: Int) throws -> Data {
            let width = 64,height = 48
            let pixels = (0..<width*height).flatMap { i -> [UInt8] in [UInt8(70+i%width+offset),UInt8(80+i/width+offset),UInt8(100+i%width+offset),255] }
            let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
            let image = try #require(CGImage(width: width,height: height,bitsPerComponent: 8,bitsPerPixel: 32,bytesPerRow: width*4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: .init(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,decode: nil,shouldInterpolate: false,intent: .defaultIntent))
            return try #require(WorkbenchPNG.encode(image))
        }
        let targetBytes = try png(0), referenceBytes = try png(15)
        let a = root.appendingPathComponent("Assets/target.png"),b = root.appendingPathComponent("Assets/reference.png")
        try targetBytes.write(to: a);try referenceBytes.write(to: b)
        let targetAsset = MediaAssetReference(kind: .image,relativePath: "Assets/target.png",originalName: "Target")
        let referenceAsset = MediaAssetReference(kind: .image,relativePath: "Assets/reference.png",originalName: "Reference")
        let project = MediaProject(kind: .video,name: "Color reference",canvas: .init(width: 64,height: 48,frameRate: 10))
        let store = MediaProjectStore(directory: root.appendingPathComponent("Projects")),coordinator = MediaPreparedCoordinator(store: store)
        try await store.save(project);_ = try await coordinator.upgradeDocument(id: project.id)
        let range = try MediaTimeRange(start: .seconds(0),duration: .seconds(1)), baseGrade = MediaVideoGrade(filterID: "CIPhotoEffectChrome")
        let targetClip = MediaPreparedClip(assetID: targetAsset.id,timelineRange: range,sourceRange: range,videoGrade: baseGrade)
        let referenceClip = MediaPreparedClip(assetID: referenceAsset.id,timelineRange: range,sourceRange: range)
        let targetTrack = MediaPreparedTrack(kind: .visual,name: "Target"),referenceTrack = MediaPreparedTrack(kind: .visual,name: "Reference")
        _ = try await coordinator.applyUserOperations([.init(action: .insertAsset(targetAsset)),.init(action: .insertAsset(referenceAsset)),
            .init(action: .insertTrack(track: targetTrack,index: nil)),.init(action: .insertTrack(track: referenceTrack,index: nil)),
            .init(action: .insertClip(trackID: targetTrack.id,clip: targetClip,index: nil)),.init(action: .insertClip(trackID: referenceTrack.id,clip: referenceClip,index: nil))],to: project.id)
        let beforeLock = try await coordinator.loadDocument(id: project.id)
        let reference = try #require(beforeLock.trackGraph.track(referenceTrack.id))
        _ = try await coordinator.applyUserOperations([.init(action: .updateTrackFlags(id: reference.id,expectedRevision: reference.revision,name: nil,isMuted: true,isLocked: true,volume: nil))],to: project.id)
        let session = try await MediaV2Session.open(projectID: project.id,root: root,store: store);defer { session.stopPlayback() }
        var input = MediaV2ToolInput();input.objectID = targetClip.id;input.property = referenceClip.id.uuidString;input.expectedRevision = session.document.revision
        input.number = 1;input.text = "color-and-contrast";input.start = 0;input.secondary = 0
        let receipt = try await session.performTool("video.color-match",input: input,actor: .model)
        #expect(receipt.colorMatch?.referenceClipID == referenceClip.id && receipt.groupID != nil)
        #expect(session.document.trackGraph.clip(id: targetClip.id)?.clip.videoGrade?.filterID == baseGrade.filterID)
        let saved = try await store.loadProject(id: project.id)
        #expect(saved?.prepared?.trackGraph.clip(id: targetClip.id)?.clip.videoGrade?.colorMatch == receipt.colorMatch)
        #expect(try Data(contentsOf: a) == targetBytes)
        #expect(try Data(contentsOf: b) == referenceBytes)
        input.flag = false;input.expectedRevision = session.document.revision
        _ = try await session.performTool("video.color-match",input: input,actor: .model)
        #expect(session.document.trackGraph.clip(id: targetClip.id)?.clip.videoGrade == baseGrade)
        #expect(session.document.trackGraph.track(referenceTrack.id)?.isLocked == true && !session.processingTool)
    }
}
#endif
