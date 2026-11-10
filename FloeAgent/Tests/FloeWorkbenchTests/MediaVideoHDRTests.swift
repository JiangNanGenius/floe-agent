// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import CoreGraphics
import CoreImage
import CoreMedia
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
@testable import FloeWorkbench

@Suite(.serialized)
struct MediaVideoHDRTests {
    @Test func videoProfileUsesExistingCanvasCASAndJournalWithoutChangingDimensionsOrLegacyDefaults() async throws {
        let root = try directory();defer { try? FileManager.default.removeItem(at: root) }
        let project = MediaProject(kind: .video,name: "Managed color",canvas: .init(width: 128,height: 96,frameRate: 10))
        let store = MediaProjectStore(directory: root),coordinator = MediaPreparedCoordinator(store: store)
        try await store.save(project);_ = try await coordinator.upgradeDocument(id: project.id)
        let asset = MediaAssetReference(kind: .image,relativePath: "source.png",originalName: "Original")
        let range = try MediaTimeRange(start: .seconds(0),duration: .seconds(0.3)),track = MediaPreparedTrack(kind: .visual,name: "Original")
        let clip = MediaPreparedClip(assetID: asset.id,timelineRange: range,sourceRange: range)
        _ = try await coordinator.applyUserOperations([.init(action: .insertAsset(asset)),.init(action: .insertTrack(track: track,index: nil)),
            .init(action: .insertClip(trackID: track.id,clip: clip,index: nil))],to: project.id)
        let baseline = try await coordinator.loadDocument(id: project.id)
        let legacyPlan = try MediaPreparedVideoDocumentAdapter.resolve(baseline,assetURLs: [asset.id:root.appendingPathComponent("source.png")],includeAudio: false)
        let settings = try PreparedVideoOutputSettings(width: 128,height: 96,frameRate: legacyPlan.frameRate)
        #expect(settings.colorProfile == nil && settings.identity == "128x96@10/1:h264:0.9000")
        let oldJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacyPlan)) as? [String:Any])
        #expect(oldJSON["colorProfile"] == nil)
        let commit = try await coordinator.applyUserOperations([.init(action: .setVideoColorProfile(expectedRevision: baseline.canvasRevision ?? 0,profile: .rec2020HLG))],to: project.id)
        let reopened = try await MediaPreparedCoordinator(store: MediaProjectStore(directory: root)).loadDocument(id: project.id)
        #expect(reopened.canvas?.width == 128 && reopened.canvas?.height == 96 && reopened.canvas?.frameRate == 10)
        #expect(reopened.canvas?.videoColorProfile == .rec2020HLG && (reopened.canvasRevision ?? 0) > (baseline.canvasRevision ?? 0))
        #expect(reopened.assets == baseline.assets && reopened.trackGraph == baseline.trackGraph)
        let hdrPlan = try MediaPreparedVideoDocumentAdapter.resolve(reopened,assetURLs: [asset.id:root.appendingPathComponent("source.png")],includeAudio: false)
        #expect(try JSONDecoder().decode(PreparedVideoPlan.self,from: JSONEncoder().encode(hdrPlan)).colorProfile == .rec2020HLG)
        #expect(PreparedVideoPlanDiffer.diff(from: legacyPlan,to: hdrPlan).requiresFullInvalidation)
        _ = try await coordinator.undoGroup(commit.groupID,in: project.id)
        #expect(try await coordinator.loadDocument(id: project.id).canvas?.videoColorProfile == nil)
        _ = try await coordinator.redoGroup(commit.groupID,in: project.id)
        #expect(try await coordinator.loadDocument(id: project.id).canvas?.videoColorProfile == .rec2020HLG)
        let saved = try #require(try await store.loadProject(id: project.id)), bytes = try Data(contentsOf: store.projectURL(id: project.id))
        var unjournaled = saved;unjournaled.revision += 1;unjournaled.canvas?.videoColorProfile = .rec2020PQ
        unjournaled.prepared?.revision = unjournaled.revision;unjournaled.prepared?.canvas = unjournaled.canvas
        let changedGeneration = (unjournaled.prepared?.canvasRevision ?? 0)+1
        unjournaled.prepared?.canvasRevision = changedGeneration
        await #expect(throws: (any Error).self) { try await store.save(unjournaled) }
        #expect(try Data(contentsOf: store.projectURL(id: project.id)) == bytes)
    }

    @Test func actualHLGAndPQPreserveHDRPixelsAndEncodeRealTenBitHEVC() async throws {
        let root = try directory();defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("HDR-source.tiff")
        try hdrTIFF().write(to: source)
        let original = try Data(contentsOf: source)
        let decodedSource = try #require(CGImageSourceCreateWithURL(source as CFURL,nil))
        let sourceImage = try #require(CGImageSourceCreateImageAtIndex(decodedSource,0,nil))
        let sourceLevels = try linearLevels(sourceImage)
        #expect(try await MediaVideoColorProfileDetector.shared.detect(url: source,kind: .image) == .rec2020HLG)
        #expect(sourceImage.bitsPerComponent >= 16 && sourceLevels[3]/sourceLevels[2] > 2)
        for profile in [MediaVideoColorProfile.rec2020HLG,.rec2020PQ] {
            let plan = try plan(source: source,profile: profile), settings = try PreparedVideoOutputSettings(width: 128,height: 96,frameRate: plan.frameRate,codec: .hevc,colorProfile: profile)
            let renderer = PreparedVideoFrameRenderer(), frame = try await renderer.renderFrame(plan: plan,frameIndex: 0,settings: settings)
            #expect(frame.image.bitsPerComponent == 16 && frame.image.bitmapInfo.contains(.floatComponents))
            let frameColorSpace = try #require(frame.image.colorSpace)
            #expect(CGColorSpaceUsesITUR_2100TF(frameColorSpace))
            let rendered = try linearLevels(frame.image)
            #expect(rendered[3]/rendered[2] > 2)
            #expect(abs(rendered[3]/rendered[2]-sourceLevels[3]/sourceLevels[2]) < 0.5)
            let url = root.appendingPathComponent("M50-\(profile.rawValue).mp4")
            let window = try PreparedVideoFrameWindow(range: .init(start: .init(seconds: 0,timescale: plan.timeScale),duration: plan.duration),frameRate: plan.frameRate)
            _ = try await PreparedVideoExporter().renderWindow(plan: plan,window: window,settings: settings,destination: url,overwrite: false,cancellation: .none,progress: { _ in })
            let asset = AVURLAsset(url: url), track = try #require(try await asset.loadTracks(withMediaType: .video).first)
            let format = try #require(try await track.load(.formatDescriptions).first)
            try MediaVideoColorProfile.validateEncoded(profile,description: format)
            #expect(MediaVideoColorProfile.encodedBitDepth(format) == 10)
            let generator = AVAssetImageGenerator(asset: asset);generator.dynamicRangePolicy = .matchSource
            let output = try await generator.image(at: .zero).image
            let exported = try linearLevels(output)
            #expect(exported[3]/exported[2] > 2)
            #expect(abs(exported[3]/exported[2]-rendered[3]/rendered[2]) < 0.7)
            let reimported = try self.plan(source: url,profile: profile,kind: .video)
            let videoFrame = try await renderer.renderFrame(plan: reimported,frameIndex: 0,settings: settings)
            let reimportedLevels = try linearLevels(videoFrame.image)
            #expect(reimportedLevels[3]/reimportedLevels[2] > 2)
            #expect(try await MediaVideoColorProfileDetector.shared.detect(url: url,kind: .video) == profile)
            #expect(try Data(contentsOf: source) == original)
            try record(url.lastPathComponent,Data(contentsOf: url))
            if profile == .rec2020HLG {
                let imageAsset = MediaAssetReference(kind: .image,relativePath: "HDR-source.tiff",originalName: "HDR source")
                var carrier = MediaProject(kind: .video,name: "HDR delivery",canvas: .init(width: 128,height: 96,frameRate: 10,videoColorProfile: profile))
                carrier.assets = [imageAsset]
                var document = try MediaPreparedUpgrade.document(from: carrier)
                let range = try MediaTimeRange(start: .seconds(0),duration: .seconds(0.3))
                document.trackGraph.tracks = [.init(kind: .visual,name: "HDR source",clips: [.init(assetID: imageAsset.id,timelineRange: range,sourceRange: range)])]
                let stitched = root.appendingPathComponent("M50-HLG-final-delivery.mp4")
                _ = try await MediaPreparedVideoDelivery().export(document: document,assetURLs: [imageAsset.id:source],options: .init(codec: .hevc,width: 128,height: 96,frameRate: 10),destination: stitched)
                let finalAsset = AVURLAsset(url: stitched), finalTrack = try #require(try await finalAsset.loadTracks(withMediaType: .video).first)
                let finalFormat = try #require(try await finalTrack.load(.formatDescriptions).first)
                try MediaVideoColorProfile.validateEncoded(profile,description: finalFormat)
                try record(stitched.lastPathComponent,Data(contentsOf: stitched))
            }
            try record("M50-\(profile.rawValue)-measurements.json",try JSONSerialization.data(withJSONObject: ["sourceLinearLevels":sourceLevels,
                "renderedLinearLevels":rendered,"exportedLinearLevels":exported,"encodedBits":MediaVideoColorProfile.encodedBitDepth(format) ?? 0],options: [.prettyPrinted,.sortedKeys]))
        }
        try record("HDR-source.tiff",original)
    }

    @Test func explicitRec709ConvertsAndTagsTheActualSDRPixelAndExportPath() async throws {
        let root = try directory();defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("HDR-source.tiff");try hdrTIFF().write(to: source)
        let plan = try plan(source: source,profile: .rec709),settings = try PreparedVideoOutputSettings(width: 128,height: 96,frameRate: plan.frameRate,colorProfile: .rec709)
        let frame = try await PreparedVideoFrameRenderer().renderFrame(plan: plan,frameIndex: 0,settings: settings)
        #expect(frame.image.bitsPerComponent == 8 && !frame.image.bitmapInfo.contains(.floatComponents))
        let output = root.appendingPathComponent("M50-explicit-Rec709.mp4"),window = try PreparedVideoFrameWindow(range: .init(start: .init(seconds: 0,timescale: plan.timeScale),duration: plan.duration),frameRate: plan.frameRate)
        _ = try await PreparedVideoExporter().renderWindow(plan: plan,window: window,settings: settings,destination: output,overwrite: false,cancellation: .none,progress: { _ in })
        let asset = AVURLAsset(url: output), track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let description = try #require(try await track.load(.formatDescriptions).first)
        try MediaVideoColorProfile.validateEncoded(.rec709,description: description)
        try record(output.lastPathComponent,Data(contentsOf: output))
    }

    @Test func modelProfileExampleNeedsNoInventedClipAndUsesTheActualDocumentRevision() throws {
        let project = MediaProject(kind: .video,name: "Color settings",canvas: .init(width: 128,height: 96,frameRate: 10))
        let doc = try MediaPreparedUpgrade.document(from: project)
        let examples = try MediaPreparedToolInputGuide.make(document: doc,implementedToolIDs: ["video.hdr"])
        #expect(examples.count == 1 && examples[0].requiresSelectionFence == false)
        let text = try #require(examples[0].inputJSON), fields = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String:Any])
        #expect(fields["objectID"] == nil && fields["expectedRevision"] as? String == String(doc.revision))
        #expect(fields["property"] as? String == "rec2020HLG")
    }

    @Test func incompatibleCodecOrCancellationNeverReplacesAnExistingDestination() async throws {
        let root = try directory();defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("HDR-source.tiff");try hdrTIFF().write(to: source)
        let plan = try plan(source: source,profile: .rec2020HLG)
        let destination = root.appendingPathComponent("keep-existing.mp4"), previous = Data("prior successful output".utf8)
        try previous.write(to: destination)
        let bad = try PreparedVideoOutputSettings(width: 128,height: 96,frameRate: plan.frameRate,codec: .h264,colorProfile: .rec2020HLG)
        let window = try PreparedVideoFrameWindow(range: .init(start: .init(seconds: 0,timescale: plan.timeScale),duration: plan.duration),frameRate: plan.frameRate)
        await #expect(throws: (any Error).self) { try await PreparedVideoExporter().renderWindow(plan: plan,window: window,settings: bad,
            destination: destination,overwrite: true,cancellation: .none,progress: { _ in }) }
        #expect(try Data(contentsOf: destination) == previous)
        let cancelled = PreparedVideoCancellation();cancelled.cancel()
        let good = try PreparedVideoOutputSettings(width: 128,height: 96,frameRate: plan.frameRate,codec: .hevc,colorProfile: .rec2020HLG)
        await #expect(throws: (any Error).self) { try await PreparedVideoExporter().renderWindow(plan: plan,window: window,settings: good,
            destination: destination,overwrite: true,cancellation: cancelled,progress: { _ in }) }
        #expect(try Data(contentsOf: destination) == previous)
    }

    private func plan(source: URL,profile: MediaVideoColorProfile,kind: PreparedVideoAssetKind = .image) throws -> PreparedVideoPlan {
        let rate = try PreparedVideoFrameRate(numerator: 10,denominator: 1), range = try PreparedVideoTimeRange(start: .init(seconds: 0,timescale: 90000),duration: .init(seconds: 0.3,timescale: 90000)), id = UUID()
        return try .init(id: .init(projectID: UUID(),revision: 0),timeScale: 90000,frameRate: rate,duration: range.duration,
            canvas: .init(width: 128,height: 96),assets: [.init(id: id,url: source,kind: kind)],
            visualTracks: [.init(id: UUID(),name: "HDR source",clips: [.init(id: UUID(),content: kind == .video ? .video(assetID: id) : .image(assetID: id),timelineRange: range,sourceRange: range)])],colorProfile: profile)
    }
    private func hdrTIFF() throws -> Data {
        let levels: [Float16] = [0.25,0.5,0.75,1], width = 128,height = 96
        var values = [Float16]();values.reserveCapacity(width*height*4)
        for _ in 0..<height { for x in 0..<width { let v = levels[x/32];values.append(contentsOf: [v,v,v,1]) } }
        let data = values.withUnsafeBytes { Data($0) }
        let provider = try #require(CGDataProvider(data: data as CFData))
        let image = try #require(CGImage(width: width,height: height,bitsPerComponent: 16,bitsPerPixel: 64,bytesPerRow: width*8,
            space: MediaVideoColorProfile.rec2020HLG.colorSpace(),bitmapInfo: [.floatComponents,.byteOrder16Little,CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)],
            provider: provider,decode: nil,shouldInterpolate: false,intent: .defaultIntent))
        let result = NSMutableData(), destination = try #require(CGImageDestinationCreateWithData(result,UTType.tiff.identifier as CFString,1,nil))
        CGImageDestinationAddImage(destination,image,nil);#expect(CGImageDestinationFinalize(destination))
        return result as Data
    }
    private func linearLevels(_ image: CGImage) throws -> [Double] {
        var result = [Float](repeating: 0,count: image.width*image.height*4)
        result.withUnsafeMutableBytes { bytes in
            CIContext(options: [.cacheIntermediates:false]).render(CIImage(cgImage: image),toBitmap: bytes.baseAddress!,rowBytes: image.width*16,
                bounds: CGRect(x: 0,y: 0,width: image.width,height: image.height),format: .RGBAf,colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!)
        }
        return (0..<4).map { i in Double(result[((image.height/2)*image.width+(i*image.width/4+image.width/8))*4]) }
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("native-HDR-\(UUID())")
        try FileManager.default.createDirectory(at: url,withIntermediateDirectories: true);return url
    }
    private func record(_ name: String,_ data: Data) throws {
        if let directory = ProcessInfo.processInfo.environment["FLOE_MEDIA_HDR_PRODUCTS"] {
            let root = URL(fileURLWithPath: directory);try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
            try data.write(to: root.appendingPathComponent(name))
        }
    }
}
