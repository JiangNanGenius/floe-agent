// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import CoreGraphics
import CoreImage
@testable import FloeWorkbench

@Suite("M37-M40 native animation products", .serialized)
struct MediaAnimationTests {
    func time(_ value: Double) throws -> MediaRationalTime { try .init(value:Int64((value*90_000).rounded()),timescale:90_000) }
    func range(_ seconds: Double) throws -> MediaTimeRange { try .init(start:time(0),duration:time(seconds)) }
    func record(_ name: String,_ data: Data) throws {
        guard let dir = ProcessInfo.processInfo.environment["FLOE_MEDIA_EXECUTION_EVIDENCE_DIR"] else { return }
        let root = URL(fileURLWithPath:dir,isDirectory:true);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try data.write(to:root.appendingPathComponent(name),options:.atomic)
    }
    @Test func customTimingCurvesAndTrimKeepTheirActualFunction() throws {
        for interpolation in [MediaKeyframeInterpolation.easeIn,.easeOut,.cubicBezier] {
            let original = MediaKeyframeTrack(property:"opacity",keyframes:[
                .init(time:try time(0),value:.number(0),interpolation:interpolation,
                    curve:.init(control1:.init(x:0.8,y:0.1),control2:.init(x:0.9,y:0.2))),
                .init(time:try time(1),value:.number(1))])
            let full = try MediaAnimation.preparedTracks([original],timescale:90_000)[0]
            let sliced = try MediaAnimation.sliced([original],from:0.2,duration:0.6)
            let cut = try MediaAnimation.preparedTracks(sliced,timescale:90_000)[0]
            for index in 0...20 {
                let local = 0.6*Double(index)/20
                let a = try #require(try PreparedVideoFrameEvaluator.interpolate(track:full,at:.init(seconds:0.2+local,timescale:90_000)))
                let b = try #require(try PreparedVideoFrameEvaluator.interpolate(track:cut,at:.init(seconds:local,timescale:90_000)))
                #expect(abs(a-b)<0.000_1)
            }
            if interpolation == .cubicBezier {
                let middle = try #require(try PreparedVideoFrameEvaluator.interpolate(track:full,at:.init(seconds:0.5,timescale:90_000)))
                #expect(middle<0.3)
            }
        }
        #expect(throws:MediaPreparedCoreError.self) { try MediaCubicBezier(control1:.init(x:1.1,y:0)).validate() }
        let key = MediaKeyframe(time:try time(0),value:.number(1))
        #expect(try JSONDecoder().decode(MediaKeyframe.self,from:JSONEncoder().encode(key)).curve == nil)
    }
    @Test func drawnMotionPathRetainsVerticesAndRendersDifferentActualPositions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("motion-path-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer { try? FileManager.default.removeItem(at:root) }
        let ci = CIImage(color:.init(red:0,green:1,blue:0)).cropped(to:.init(x:0,y:0,width:32,height:32))
        let image = try #require(CIContext().createCGImage(ci,from:ci.extent)),source = root.appendingPathComponent("source.png")
        try #require(WorkbenchPNG.encode(image)).write(to:source)
        let asset = MediaAssetReference(kind:.image,relativePath:"source.png",originalName:"Source")
        var clip = MediaPreparedClip(assetID:asset.id,timelineRange:try range(1),sourceRange:try range(1),
            keyframeTracks:[.init(property:"scale",keyframes:[.init(time:try time(0),value:.number(0.2))])])
        let points: [ImageFreehandStroke.Point] = [.init(x:0.1,y:0.2),.init(x:0.9,y:0.2),.init(x:0.9,y:0.8)]
        clip.keyframeTracks = try MediaAnimation.motionPath(points,duration:1,in:clip)
        let x = try #require(clip.keyframeTracks.first {$0.property == "centerX"})
        #expect(x.keyframes.count == points.count && abs(x.keyframes[1].time.seconds-4.0/7.0)<0.000_02)
        let doc = MediaPreparedDocument(id:UUID(),kind:.video,name:"Path",canvas:.init(width:96,height:96),assets:[asset],
            trackGraph:.init(tracks:[.init(kind:.visual,name:"Path",clips:[clip])],frameRate:try time(30)))
        let plan = try MediaPreparedVideoDocumentAdapter.resolve(doc,assetURLs:[asset.id:source],includeAudio:false)
        let settings = try PreparedVideoOutputSettings(width:96,height:96,frameRate:plan.frameRate),renderer = PreparedVideoFrameRenderer()
        var centers: [(Double,Double)] = []
        for frameIndex in [Int64(0),Int64(29)] {
            let frame = try await renderer.renderFrame(plan:plan,frameIndex:frameIndex,settings:settings)
            let pixels = try MediaNativeSelection.rgba(frame.image).pixels
            var count = 0,totalX = 0.0,totalY = 0.0
            for i in stride(from:0,to:pixels.count,by:4) where Int(pixels[i+1])>Int(pixels[i])+100 {
                count += 1;totalX += Double(i/4%96);totalY += Double(i/4/96)
            }
            #expect(count>100);centers.append((totalX/Double(max(1,count)),totalY/Double(max(1,count))))
            try record("M38-frame-\(frameIndex).png",try #require(WorkbenchPNG.encode(frame.image)))
        }
        #expect(centers[1].0-centers[0].0>60 && abs(centers[1].1-centers[0].1)>40)
        // More than one vertex per frame remains distinct in the actual plan.
        let dense = (0..<120).map { ImageFreehandStroke.Point(x:Double($0)/120,y:0.5) }
        var fine = clip;fine.keyframeTracks = try MediaAnimation.motionPath(dense,duration:1,in:clip)
        var denseDoc = doc;denseDoc.trackGraph.tracks[0].clips = [fine]
        let densePlan = try MediaPreparedVideoDocumentAdapter.resolve(denseDoc,assetURLs:[asset.id:source],includeAudio:false)
        #expect(densePlan.visualTracks[0].clips[0].keyframes.first {$0.property == .centerX}?.keyframes.count == 120)
        #expect(throws:MediaPreparedCoreError.self) { try MediaAnimation.motionPath(Array(repeating:points[0],count:2),duration:1,in:clip) }
    }
    @Test func titlesAndAllSixPresetsRenderAndExportThroughTheNativePlan() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("motion-title-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer { try? FileManager.default.removeItem(at:root) }
        let clip = MediaPreparedClip(timelineRange:try range(1),sourceRange:try range(1),motionTitle:.init(text:"Floe",fontSize:24,colorHex:"#FF8800"))
        var document = MediaPreparedDocument(id:UUID(),kind:.video,name:"Title",canvas:.init(width:128,height:96),
            trackGraph:.init(tracks:[.init(kind:.visual,name:"Title",clips:[clip])],frameRate:try time(30)))
        let renderer = PreparedVideoFrameRenderer()
        let settings = try PreparedVideoOutputSettings(width:128,height:96,frameRate:.init(numerator:30,denominator:1))
        let original = try MediaPreparedVideoDocumentAdapter.resolve(document,assetURLs:[:])
        let plain = try await renderer.renderFrame(plan:original,frameIndex:3,settings:settings)
        let baseline = try #require(WorkbenchPNG.encode(plain.image))
        try record("M39-title.png",baseline)
        for preset in MediaAnimationPreset.allCases {
            var animated = clip;animated.keyframeTracks = try MediaAnimation.applying(preset,to:clip)
            document.trackGraph.tracks[0].clips = [animated];document.revision += 1
            let plan = try MediaPreparedVideoDocumentAdapter.resolve(document,assetURLs:[:])
            let frame = try await renderer.renderFrame(plan:plan,frameIndex:3,settings:settings)
            let png = try #require(WorkbenchPNG.encode(frame.image));#expect(png != baseline)
            try record("M40-\(preset.rawValue).png",png)
        }
        let plan = try MediaPreparedVideoDocumentAdapter.resolve(document,assetURLs:[:]),destination = root.appendingPathComponent("M39-title-motion.mp4")
        let window = try PreparedVideoFrameWindow(range:.init(startSeconds:0,durationSeconds:1,timescale:plan.timeScale),frameRate:plan.frameRate)
        let receipt = try await PreparedVideoExporter().renderWindow(plan:plan,window:window,settings:settings,destination:destination,
            overwrite:false,cancellation:.none,progress:{_ in})
        #expect(receipt.frameCount == 30 && receipt.byteCount>1000)
        try record(destination.lastPathComponent,Data(contentsOf:destination))
    }
    @Test func titleAndCurveDocumentsPersistAndUndoWithoutCreatingPlaceholderAssets() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("title-store-\(UUID())");defer { try? FileManager.default.removeItem(at:root) }
        let p = MediaProject(kind:.video,name:"Titles",canvas:.init(width:128,height:96,frameRate:30)),store = MediaProjectStore(directory:root),coordinator = MediaPreparedCoordinator(store:store)
        try await store.save(p);_ = try await coordinator.upgradeDocument(id:p.id)
        var clip = MediaPreparedClip(timelineRange:try range(2),sourceRange:try range(2),motionTitle:.init(text:"Title"))
        clip.keyframeTracks = [.init(property:"opacity",keyframes:[.init(time:try time(0),value:.number(0),interpolation:.cubicBezier,curve:.init(control1:.init(x:0.8,y:0.1),control2:.init(x:0.9,y:0.8))),.init(time:try time(2),value:.number(1))])]
        let track = MediaPreparedTrack(kind:.visual,name:"Title",clips:[clip])
        let create = try await coordinator.applyUserOperations([.init(action:.insertTrack(track:track,index:nil))],to:p.id)
        let reopened = try await MediaPreparedCoordinator(store:MediaProjectStore(directory:root)).loadDocument(id:p.id)
        #expect(reopened.assets.isEmpty && reopened.trackGraph.clip(id:clip.id)?.clip.motionTitle?.text == "Title")
        #expect(reopened.trackGraph.clip(id:clip.id)?.clip.keyframeTracks[0].keyframes[0].curve == clip.keyframeTracks[0].keyframes[0].curve)
        _ = try MediaPreparedVideoDocumentAdapter.resolve(reopened,assetURLs:[:])
        _ = try await coordinator.undoGroup(create.groupID,in:p.id)
        #expect(try await coordinator.loadDocument(id:p.id).trackGraph.tracks.isEmpty)
        _ = try await coordinator.redoGroup(create.groupID,in:p.id)
        #expect(try await coordinator.loadDocument(id:p.id).trackGraph.clip(id:clip.id)?.clip.motionTitle?.text == "Title")
    }
    @Test func initialTrackChildrenRejectUndoOverNewerEditsAndRedoInOrder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nested-track-history-\(UUID())");defer { try? FileManager.default.removeItem(at:root) }
        let p = MediaProject(kind:.video,name:"Nested history",canvas:.init(width:128,height:96,frameRate:30)),store = MediaProjectStore(directory:root),coordinator = MediaPreparedCoordinator(store:store)
        try await store.save(p);_ = try await coordinator.upgradeDocument(id:p.id)
        let a = MediaPreparedClip(timelineRange:try range(2),sourceRange:try range(2),motionTitle:.init(text:"A"))
        var b = a;b.id = UUID();b.timelineRange = try .init(start:time(2),duration:time(2));b.motionTitle?.text = "B"
        let track = MediaPreparedTrack(kind:.visual,name:"Nested",clips:[a,b])
        let create = try await coordinator.applyUserOperations([.init(action:.insertTrack(track:track,index:nil))],to:p.id)
        let current = try await coordinator.loadDocument(id:p.id)
        var edited = try #require(current.trackGraph.clip(id:a.id)?.clip);edited.motionTitle?.text = "Later"
        let edit = try await coordinator.applyUserOperations([.init(action:.replaceClip(trackID:track.id,clipID:a.id,expectedRevision:edited.revision,clip:edited))],to:p.id)
        let bytes = try Data(contentsOf:store.projectURL(id:p.id))
        do { _ = try await coordinator.undoGroup(create.groupID,in:p.id);Issue.record("Creation undo deleted an edited initial child") }
        catch { #expect(error is MediaPreparedCoreError) }
        #expect(try Data(contentsOf:store.projectURL(id:p.id)) == bytes)
        _ = try await coordinator.undoGroup(edit.groupID,in:p.id)
        _ = try await coordinator.undoGroup(create.groupID,in:p.id)
        #expect(try await coordinator.loadDocument(id:p.id).trackGraph.track(track.id) == nil)
        _ = try await coordinator.redoGroup(create.groupID,in:p.id)
        _ = try await coordinator.redoGroup(edit.groupID,in:p.id)
        let reopened = try await MediaPreparedCoordinator(store:MediaProjectStore(directory:root)).loadDocument(id:p.id)
        #expect(reopened.trackGraph.track(track.id)?.clips.map(\.id) == [a.id,b.id])
        #expect(reopened.trackGraph.clip(id:a.id)?.clip.motionTitle?.text == "Later")
    }
}
