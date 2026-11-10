// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import CoreGraphics
import CoreImage
import AVFoundation
@testable import FloeWorkbench

@Suite(.serialized)
struct MediaVideoMotionTests {
    @Test func decodedVideoAnalysisPersistsUndoAndCorrectsPreviewAndActualMP4() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("motion-products-\(UUID())")
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let png = root.appendingPathComponent("texture.png")
        try #require(WorkbenchPNG.encode(textureImage(dx: 0,dy: 0))).write(to: png)
        let rate = try PreparedVideoFrameRate(numerator: 10,denominator: 1)
        let imageID = UUID(), videoID = UUID(), offsets = [0,6,-4,5,-3,4,0]
        let ranges = try offsets.indices.map { i in try PreparedVideoTimeRange(start: .init(seconds: Double(i)/10,timescale: 90000),duration: .init(seconds: 0.1,timescale: 90000)) }
        let sourceRange = try PreparedVideoTimeRange(start: .init(seconds: 0,timescale: 90000),duration: .init(seconds: 0.7,timescale: 90000))
        let imageRange = try PreparedVideoTimeRange(start: .init(seconds: 0,timescale: 90000),duration: .init(seconds: 0.1,timescale: 90000))
        let sourcePlan = try PreparedVideoPlan(id: .init(projectID: UUID(),revision: 0),timeScale: 90000,frameRate: rate,
            duration: sourceRange.duration,canvas: .init(width: 256,height: 192),assets: [.init(id: imageID,url: png,kind: .image)],
            visualTracks: [.init(id: UUID(),name: "Camera jitter fixture",clips: offsets.indices.map { i in
                .init(id: UUID(),content: .image(assetID: imageID),timelineRange: ranges[i],sourceRange: imageRange,
                      transform: .init(centerX: 0.5+Double(offsets[i])/256))
            })])
        let settings = try PreparedVideoOutputSettings(width: 256,height: 192,frameRate: rate)
        let url = root.appendingPathComponent("actual-jitter-source.mp4")
        _ = try await PreparedVideoExporter().renderWindow(plan: sourcePlan,window: .init(range: sourceRange,frameRate: rate),
            settings: settings,destination: url,overwrite: false,cancellation: .none,progress: { _ in })
        let originalBytes = try Data(contentsOf: url)
        let service = MediaVideoMotionService(), sourceHash = try await serviceHash(url)
        let project = MediaProject(kind: .video,name: "Tracked original",canvas: .init(width: 256,height: 192,frameRate: 30))
        let store = MediaProjectStore(directory: root.appendingPathComponent("store")), coordinator = MediaPreparedCoordinator(store: store)
        try await store.save(project); _ = try await coordinator.upgradeDocument(id: project.id)
        let asset = MediaAssetReference(id: videoID,kind: .video,relativePath: "original.mp4",originalName: "Original",
            contentHash: sourceHash,metadata: .init(width: 256,height: 192,durationSeconds: 0.7,frameRate: nil,audioTracks: 0))
        let range = try MediaTimeRange(start: .seconds(0),duration: .seconds(0.7))
        let track = MediaPreparedTrack(kind: .visual,name: "Camera"), original = MediaPreparedClip(assetID: videoID,timelineRange: range,sourceRange: range)
        _ = try await coordinator.applyUserOperations([.init(action: .insertAsset(asset)),.init(action: .insertTrack(track: track,index: nil)),
            .init(action: .insertClip(trackID: track.id,clip: original,index: nil))],to: project.id)
        let snapshot = try await coordinator.loadDocument(id: project.id)
        let request = MediaVideoMotionRequest(assetID: videoID,assetRevision: snapshot.assetRevisions?[videoID] ?? 0,expectedContentHash: sourceHash,
            startSeconds: 0,durationSeconds: 0.7,sampleRate: 10)
        let stabilization = try await service.stabilize(url: url,request: request,smoothingSeconds: 0.6,strength: 1,cropEdges: true)
        let tracking = try await service.track(url: url,request: request,region: .init(x: 48.0/256,y: 60.0/192,width: 56.0/256,height: 48.0/192))
        try record("M35-decoded-tracking.json",try JSONEncoder().encode(tracking))
        #expect(stabilization.samples.count == 7)
        #expect(tracking.samples.contains { $0.state == .tracked })
        for (sample,offset) in zip(stabilization.samples,offsets) { #expect(abs(sample.motionX*256-Double(offset))<2) }
        let frameBytes = try await service.inspectSource(url: url,sourceSeconds: 0.1,maximumPixelSize: 128,expectedContentHash: sourceHash)
        #expect(frameBytes.contentHash == sourceHash && frameBytes.width == 128 && frameBytes.height == 96)
        #expect(abs(frameBytes.actualSeconds-0.1) < 0.0001)
        try record("M35-model-upright-source.png",frameBytes.pngData)
        var next = try #require(try await coordinator.loadDocument(id: project.id).trackGraph.clip(id: original.id)?.clip)
        next.videoTracking = tracking; next.stabilization = stabilization
        let commit = try await coordinator.applyUserOperations([.init(action: .replaceClip(trackID: track.id,clipID: next.id,expectedRevision: next.revision,clip: next))],to: project.id)
        let reopened = try await MediaPreparedCoordinator(store: MediaProjectStore(directory: root.appendingPathComponent("store"))).loadDocument(id: project.id)
        #expect(reopened.trackGraph.clip(id: next.id)?.clip.videoTracking == tracking)
        #expect(reopened.trackGraph.clip(id: next.id)?.clip.stabilization == stabilization)
        let plan = try MediaPreparedVideoDocumentAdapter.resolve(reopened,assetURLs: [videoID: url],includeAudio: false)
        #expect(plan.visualTracks[0].clips[0].sourceFrameDuration == 0.1)
        let correctedSettings = try PreparedVideoOutputSettings(width: 256,height: 192,frameRate: plan.frameRate)
        let renderer = PreparedVideoFrameRenderer()
        var before: [Double] = [], after: [Double] = []
        for i in offsets.indices {
            let uncorrected = try await service.sourcePreview(url: url,sourceSeconds: Double(i)/10)
            before.append(try markerX(uncorrected.image))
            let corrected = try await renderer.renderFrame(plan: plan,at: .init(seconds: Double(i)/10,timescale: plan.timeScale),settings: correctedSettings)
            after.append(try markerX(corrected.image))
        }
        #expect(standardDeviation(after) < standardDeviation(before)*0.5)
        let output = root.appendingPathComponent("M36-stabilized-export.mp4")
        _ = try await PreparedVideoExporter().renderWindow(plan: plan,window: .init(range: sourceRange,frameRate: plan.frameRate),settings: correctedSettings,
            destination: output,overwrite: false,cancellation: .none,progress: { _ in })
        let decoded = try await AVAssetImageGenerator(asset: AVURLAsset(url: output)).image(at: CMTime(seconds: 0.1,preferredTimescale: 90000)).image
        #expect(abs(try markerX(decoded)-after[1]) < 1.5)
        #expect(try Data(contentsOf: url) == originalBytes)
        _ = try await coordinator.undoGroup(commit.groupID,in: project.id)
        let undone = try await coordinator.loadDocument(id: project.id)
        #expect(undone.trackGraph.clip(id: next.id)?.clip.videoTracking == nil)
        #expect(undone.trackGraph.clip(id: next.id)?.clip.stabilization == nil)
        _ = try await coordinator.redoGroup(commit.groupID,in: project.id)
        #expect(try await coordinator.loadDocument(id: project.id).trackGraph.clip(id: next.id)?.clip.stabilization == stabilization)
        var stale = reopened; stale.assetRevisions = [videoID: request.assetRevision+1]
        #expect(throws: (any Error).self) { try MediaPreparedVideoDocumentAdapter.resolve(stale,assetURLs: [videoID: url],includeAudio: false) }
        var wrongRequest = request; wrongRequest.expectedContentHash = String(repeating: "f",count: 64)
        await #expect(throws: (any Error).self) { try await service.stabilize(url: url,request: wrongRequest) }
        try record(url.lastPathComponent,originalBytes); try record(output.lastPathComponent,Data(contentsOf: output))
        try record("M35-tracking.json",try JSONEncoder().encode(tracking))
        try record("M36-stabilization.json",try JSONEncoder().encode(stabilization))
        try record("M36-measurements.json",try JSONSerialization.data(withJSONObject: ["beforeWhiteMarkerX":before,"afterWhiteMarkerX":after,
            "beforeStandardDeviation":standardDeviation(before),"afterStandardDeviation":standardDeviation(after)],options: [.prettyPrinted,.sortedKeys]))
    }

    @Test func motionGuideUsesThisActualVideoAndRequiresSourceObservationBeforeChoosingROI() throws {
        let id = UUID(), range = try MediaTimeRange(start: .seconds(0),duration: .seconds(1))
        let asset = MediaAssetReference(id: id,kind: .video,relativePath: "video.mp4",originalName: "Video")
        let clip = MediaPreparedClip(assetID: id,timelineRange: range,sourceRange: range)
        var project = MediaProject(kind: .video,name: "Guide",canvas: .init(width: 256,height: 192,frameRate: 30))
        project.assets = [asset]
        var doc = try MediaPreparedUpgrade.document(from: project)
        doc.trackGraph.tracks = [.init(kind: .visual,name: "Video",clips: [clip])]
        let result = try MediaPreparedToolInputGuide.make(document: doc,implementedToolIDs: ["video.tracking","video.stabilize"])
        #expect(result.count == 2)
        for entry in result {
            let data = try #require(entry.inputJSON?.data(using: .utf8))
            let input = try #require(JSONSerialization.jsonObject(with: data) as? [String:Any])
            #expect(input["objectID"] as? String == clip.id.uuidString)
            #expect(input["expectedRevision"] as? String == String(doc.revision))
        }
        let tracking = try #require(result.first { $0.toolID == "video.tracking" })
        #expect(tracking.guidance.contains("sourceClipID") && tracking.guidance.contains("never infer"))
    }

    @Test func trackedOverlayUsesSourceTimeThroughReverseSpeedAndLegacyClipsStillDecode() throws {
        let source = origin(duration: 0.3), samples = [0.0,0.1,0.2].map { t in MediaVideoTrackingSample(sourceSeconds: t,
            region: .init(x: 0.1+t,y: 0.2,width: 0.2,height: 0.2),confidence: 1,state: t == 0 ? .seed : .tracked) }
        let range = try MediaTimeRange(start: .seconds(0),duration: .seconds(0.15))
        let sr = try MediaTimeRange(start: .seconds(0),duration: .seconds(0.3))
        var clip = MediaPreparedClip(assetID: source.assetID,timelineRange: range,sourceRange: sr,speed: 2,sourcePlayback: .init(isReversed: true))
        clip.videoTracking = .init(source: source,minimumConfidence: 0.3,samples: samples)
        let start = try #require(try MediaVideoMotionMath.trackingCorners(clip: clip,canvas: .init(width: 256,height: 192),timelineSeconds: 0))
        #expect(abs(start[0].x-0.3)<0.00001)
        let end = try #require(try MediaVideoMotionMath.trackingCorners(clip: clip,canvas: .init(width: 256,height: 192),timelineSeconds: 0.1))
        #expect(abs(end[0].x-0.1)<0.00001)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(clip)) as? [String:Any])
        json.removeValue(forKey: "videoTracking");json.removeValue(forKey: "stabilization")
        let old = try JSONDecoder().decode(MediaPreparedClip.self,from: JSONSerialization.data(withJSONObject: json))
        #expect(old.videoTracking == nil && old.stabilization == nil)
    }

    @Test func actualVisionTracksTexturedObjectAndReportsLossWithoutReacquiring() throws {
        let tracker = try MediaVideoObjectTracker(region: .init(x: 48.0/256, y: 60.0/192, width: 56.0/256, height: 48.0/192), minimumConfidence: 0.3)
        var samples: [MediaVideoTrackingSample] = []
        for i in 0..<7 {
            let image = try objectImage(offset: i*4, hidden: false)
            samples.append(try tracker.consume(image, sourceSeconds: Double(i)/10, last: false, cancellation: .none))
        }
        #expect(samples[0].state == .seed)
        let last = try #require(samples.last), region = try #require(last.region)
        #expect(last.state == .tracked)
        #expect(abs(region.x-(48+24)/256.0) < 0.035)
        #expect(abs(region.y-60.0/192) < 0.035)
        #expect(last.confidence >= 0.3)
        // Hard loss is not manufactured into a continuing path. A deliberately
        // strict threshold forces the request's real low-confidence branch.
        let strict = try MediaVideoObjectTracker(region: .init(x: 0.1875, y: 0.3125, width: 0.21875, height: 0.25), minimumConfidence: 0.95)
        _ = try strict.consume(objectImage(offset: 0, hidden: false), sourceSeconds: 0, last: false, cancellation: .none)
        let blank = try image(width: 256, height: 192) { _,_ in [0,0,0,255] }
        let lost = try strict.consume(blank, sourceSeconds: 0.1, last: false, cancellation: .none)
        #expect(lost.state == .lost && lost.region == nil)
        let remainsLost = try strict.consume(objectImage(offset: 0, hidden: false), sourceSeconds: 0.2, last: true, cancellation: .none)
        #expect(remainsLost.state == .lost && remainsLost.region == nil)
        try record("M35-object-last.png", try #require(WorkbenchPNG.encode(objectImage(offset: 24, hidden: false))))
    }

    @Test func actualVisionRegistrationHasCorrectDirectionAndStabilizationMovesRealPixels() throws {
        let tracker = MediaVideoTranslationTracker(), offsets = [0,6,-4,5,-3,4,0]
        var measured: [MediaVideoStabilizationSample] = []
        for (i,offset) in offsets.enumerated() {
            measured.append(try tracker.consume(textureImage(dx: offset, dy: 0), sourceSeconds: Double(i)/10, cancellation: .none))
        }
        for (sample, offset) in zip(measured,offsets) { #expect(abs(sample.motionX*256-Double(offset)) < 1.5) }
        let source = origin(duration: 0.7)
        let stabilization = try MediaVideoMotionMath.stabilize(source: source, measured: measured, smoothingSeconds: 0.6, strength: 1, cropEdges: false)
        let rendered = try #require(CIContext().createCGImage(stabilization.apply(to: CIImage(cgImage: textureImage(dx: 6, dy: 0)), sourceSeconds: 0.1), from: CGRect(x: 0,y: 0,width: 256,height: 192)))
        let x = try markerX(rendered)
        #expect(abs(x-128) < 3)
        let corrected = stabilization.samples.map { $0.motionX+$0.correctionX }
        #expect(standardDeviation(corrected) < standardDeviation(measured.map(\.motionX))*0.3)
        try record("M36-source-jittered.png",try #require(WorkbenchPNG.encode(textureImage(dx: 6,dy: 0))))
        try record("M36-real-stabilized.png",try #require(WorkbenchPNG.encode(rendered)))
    }

    @Test func sourceTimeTrackingLossCropBoundsAndCancellationAreExplicit() throws {
        let source = origin(duration: 0.3), samples: [MediaVideoTrackingSample] = [
            .init(sourceSeconds: 0,region: .init(x: 0.1,y: 0.2,width: 0.2,height: 0.2),confidence: 1,state: .seed),
            .init(sourceSeconds: 0.1,region: .init(x: 0.2,y: 0.2,width: 0.2,height: 0.2),confidence: 0.8,state: .tracked),
            .init(sourceSeconds: 0.2,region: nil,confidence: 0.1,state: .lost)]
        let tracking = MediaVideoTracking(source: source,minimumConfidence: 0.3,samples: samples)
        try tracking.validate()
        let halfway = try #require(tracking.observation(at: 0.05)?.region)
        #expect(abs(halfway.x-0.15) < 0.00001)
        #expect(tracking.observation(at: 0.15)?.state == .lost)
        #expect(tracking.observation(at: 1) == nil)
        let measured = [0.0,0.03,-0.02].enumerated().map { MediaVideoStabilizationSample(sourceSeconds: Double($0.offset)/10,motionX: $0.element,motionY: 0) }
        let cropped = try MediaVideoMotionMath.stabilize(source: source,measured: measured,smoothingSeconds: 0.6,strength: 1,cropEdges: true)
        #expect(cropped.cropScale > 1.05)
        try cropped.validate()
        #expect(throws: (any Error).self) { try cropped.correction(at: 2) }
        let cancellation = PreparedVideoCancellation(); cancellation.cancel()
        #expect(throws: (any Error).self) { try MediaVideoTranslationTracker().consume(textureImage(dx: 0,dy: 0),sourceSeconds: 0,cancellation: cancellation) }
        var invalid = cropped; invalid.samples[1].sourceSeconds = 0
        #expect(throws: (any Error).self) { try invalid.validate() }
    }

    private func serviceHash(_ url: URL) async throws -> String { try await MediaVideoMotionService.shared.contentHash(url) }
    private func origin(duration: Double, id: UUID = UUID(), hash: String = String(repeating: "a",count: 64)) -> MediaVideoMotionSource {
        .init(assetID: id,assetRevision: 0,contentHash: hash,startSeconds: 0,durationSeconds: duration,frameDuration: 0.1,width: 256,height: 192)
    }
    private func image(width: Int,height: Int,pixel: (Int,Int)->[UInt8]) throws -> CGImage {
        var pixels = [UInt8](); pixels.reserveCapacity(width*height*4)
        for y in 0..<height { for x in 0..<width { pixels.append(contentsOf: pixel(x,y)) } }
        let data = Data(pixels) as CFData
        return try #require(CGImage(width: width,height: height,bitsPerComponent: 8,bitsPerPixel: 32,bytesPerRow: width*4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: data)!,decode: nil,shouldInterpolate: false,intent: .defaultIntent))
    }
    private func objectImage(offset: Int, hidden: Bool) throws -> CGImage {
        try image(width: 256,height: 192) { x,y in
            if !hidden,x >= 48+offset,x < 104+offset,y >= 60,y < 108 {
                let value = UInt8(((x-offset)*73+y*151) & 127)
                return [255, value, 40, 255]
            }
            let value = UInt8((x*7+y*13) & 31); return [value,value,value,255]
        }
    }
    private func textureImage(dx: Int,dy: Int) throws -> CGImage {
        try image(width: 256,height: 192) { xx,yy in
            let x = xx-dx,y = yy-dy
            if x<0 || y<0 || x>=256 || y>=192 { return [0,0,0,255] }
            if abs(x-128)<5 && abs(y-96)<10 { return [255,255,255,255] }
            if x>=48,x<104,y>=60,y<108 { return [255,UInt8((x*73+y*151) & 127),40,255] }
            let value = UInt8((x*73+y*151+(x*y)%89) & 127); return [value,UInt8(Int(value)/2),UInt8(Int(value)/3),255]
        }
    }
    private func markerX(_ image: CGImage) throws -> Double {
        var data = [UInt8](repeating: 0,count: image.width*image.height*4)
        let count: (Double,Double) = try data.withUnsafeMutableBytes { bytes in
            let ctx = try #require(CGContext(data: bytes.baseAddress,width: image.width,height: image.height,bitsPerComponent: 8,bytesPerRow: image.width*4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(image,in: CGRect(x: 0,y: 0,width: image.width,height: image.height))
            var total = 0.0,sum = 0.0
            for y in 0..<image.height { for x in 0..<image.width { let i = (y*image.width+x)*4
                if bytes[i]>220 && bytes[i+1]>220 && bytes[i+2]>220 { total += 1;sum += Double(x) }
            } }
            return (sum,total)
        }
        #expect(count.1>20);return count.0/max(1,count.1)
    }
    private func standardDeviation(_ values: [Double]) -> Double {
        let mean = values.reduce(0,+)/Double(values.count)
        return sqrt(values.reduce(0) { $0+pow($1-mean,2) }/Double(values.count))
    }
    private func record(_ name: String,_ data: Data) throws {
        if let path = ProcessInfo.processInfo.environment["FLOE_MEDIA_MOTION_PRODUCTS"] {
            let root = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
            try data.write(to: root.appendingPathComponent(name))
        }
    }
}
