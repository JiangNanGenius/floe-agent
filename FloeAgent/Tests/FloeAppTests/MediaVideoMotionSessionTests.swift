// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import CoreGraphics
import Testing
import FloeWorkbench
@testable import FloeApp

@Suite("M35 M36 native video tool transactions",.serialized)
@MainActor struct MediaVideoMotionSessionTests {
    @Test func actualSourceAnalysisUsesTheToolPathSavesReopensAndUndoesWithoutReplacingTheVideo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-video-motion-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Assets"),withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let width = 256,height = 192
        let pixels: [UInt8] = (0..<width*height).flatMap { index -> [UInt8] in
            let x = index%width,y = index/width
            if x>=48,x<104,y>=60,y<108 { return [255,UInt8((x*73+y*151)&127),40,255] }
            let v = UInt8((x*73+y*151+(x*y)%89)&127);return [v,v/2,v/3,255]
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(width: width,height: height,bitsPerComponent: 8,bitsPerPixel: 32,bytesPerRow: width*4,
            space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: .init(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,decode: nil,shouldInterpolate: false,intent: .defaultIntent))
        let png = root.appendingPathComponent("Assets/source.png")
        try #require(WorkbenchPNG.encode(image)).write(to: png)
        let rate = try PreparedVideoFrameRate(numerator: 10,denominator: 1), imageID = UUID()
        let full = try PreparedVideoTimeRange(start: .init(seconds: 0,timescale: 90000),duration: .init(seconds: 0.4,timescale: 90000))
        let frame = try PreparedVideoTimeRange(start: .init(seconds: 0,timescale: 90000),duration: .init(seconds: 0.1,timescale: 90000))
        let clips = try [0,4,-3,2].enumerated().map { index,offset in
            PreparedVideoClip(id: UUID(),content: .image(assetID: imageID),
                timelineRange: try .init(start: .init(seconds: Double(index)/10,timescale: 90000),duration: frame.duration),
                sourceRange: frame,transform: .init(centerX: 0.5+Double(offset)/256))
        }
        let plan = try PreparedVideoPlan(id: .init(projectID: UUID(),revision: 0),timeScale: 90000,frameRate: rate,duration: full.duration,
            canvas: .init(width: width,height: height),assets: [.init(id: imageID,url: png,kind: .image)],
            visualTracks: [.init(id: UUID(),name: "Source fixture",clips: clips)])
        let source = root.appendingPathComponent("Assets/source.mp4")
        _ = try await PreparedVideoExporter().renderWindow(plan: plan,window: .init(range: full,frameRate: rate),
            settings: .init(width: width,height: height,frameRate: rate),destination: source,overwrite: false,cancellation: .none,progress: { _ in })
        let sourceBytes = try Data(contentsOf: source), hash = try await MediaVideoMotionService.shared.contentHash(source)
        let project = MediaProject(kind: .video,name: "Native motion",canvas: .init(width: width,height: height,frameRate: 10))
        let store = MediaProjectStore(directory: root.appendingPathComponent("Projects")), coordinator = MediaPreparedCoordinator(store: store)
        try await store.save(project);_ = try await coordinator.upgradeDocument(id: project.id)
        let asset = MediaAssetReference(kind: .video,relativePath: "Assets/source.mp4",originalName: "Original",contentHash: hash,
            metadata: .init(width: width,height: height,durationSeconds: 0.4,frameRate: 10,audioTracks: 0))
        let range = try MediaTimeRange(start: .seconds(0),duration: .seconds(0.4)), track = MediaPreparedTrack(kind: .visual,name: "Source")
        let clip = MediaPreparedClip(assetID: asset.id,timelineRange: range,sourceRange: range)
        _ = try await coordinator.applyUserOperations([.init(action: .insertAsset(asset)),.init(action: .insertTrack(track: track,index: nil)),
            .init(action: .insertClip(trackID: track.id,clip: clip,index: nil))],to: project.id)
        let session = try await MediaV2Session.open(projectID: project.id,root: root,store: store)
        defer { session.stopPlayback() }
        session.select(track,clip: clip)
        var input = MediaV2ToolInput();input.objectID = clip.id;input.expectedRevision = session.document.revision
        input.points = [.init(x: 48.0/256,y: 60.0/192),.init(x: 104.0/256,y: 108.0/192)];input.number = 0.3;input.secondary = 10
        let tracking = try await session.performTool("video.tracking",input: input,actor: .model)
        let trackingGroup = try #require(tracking.groupID)
        #expect(tracking.tracking?.samples.contains { $0.state == .tracked } == true)
        #expect(session.document.assets == [asset] && !session.processingTool)
        input.points = nil;input.expectedRevision = session.document.revision;input.number = 0.6;input.secondary = 1;input.flag = true
        let stabilized = try await session.performTool("video.stabilize",input: input,actor: .model)
        let stabilizationGroup = try #require(stabilized.groupID)
        let saved = try await store.loadProject(id: project.id)
        #expect(saved?.prepared?.trackGraph.clip(id: clip.id)?.clip.stabilization == stabilized.stabilization)
        #expect(saved?.prepared?.trackGraph.clip(id: clip.id)?.clip.videoTracking == tracking.tracking)
        #expect(try Data(contentsOf: source) == sourceBytes)
        let before = try Data(contentsOf: store.projectURL(id: project.id));input.expectedRevision = nil
        do { _ = try await session.performTool("video.stabilize",input: input,actor: .model);Issue.record("Model analysis omitted revision") }
        catch MediaPreparedCoreError.documentChanged { }
        #expect(try Data(contentsOf: store.projectURL(id: project.id)) == before)
        _ = try await session.coordinator.undoGroup(stabilizationGroup,in: project.id)
        _ = try await session.coordinator.undoGroup(trackingGroup,in: project.id)
        let undone = try await session.coordinator.loadDocument(id: project.id)
        #expect(undone.trackGraph.clip(id: clip.id)?.clip.videoTracking == nil && undone.trackGraph.clip(id: clip.id)?.clip.stabilization == nil)
        #expect(try Data(contentsOf: source) == sourceBytes)
    }
    @Test func sourceFrameContractRetainsLegacyDefaultAndAcceptsOnlyOpaqueClipIdentity() throws {
        let legacy = try StudioFrameInput.decode(#"{"expectedRevision":4,"seconds":0,"maximumPixelSize":256}"#)
        #expect(legacy.sourceClipID == nil)
        let clipID = UUID(), text = "{\"expectedRevision\":4,\"sourceClipID\":\"\(clipID)\",\"seconds\":0.25}"
        #expect(try StudioFrameInput.decode(text).sourceClipID == clipID)
        #expect(throws: (any Error).self) { try StudioFrameInput.decode(#"{"expectedRevision":4,"sourcePath":"/tmp/source.mp4"}"#) }
    }
}
#endif
