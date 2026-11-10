// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import CoreGraphics
import AVFoundation
@testable import FloeWorkbench

@Suite("M33 M34 native video composition",.serialized)
struct MediaVideoCompositeTests {
    func record(_ name:String,_ data:Data) throws {
        guard let dir = ProcessInfo.processInfo.environment["FLOE_MEDIA_EXECUTION_EVIDENCE_DIR"] else { return }
        let root = URL(fileURLWithPath:dir,isDirectory:true);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try data.write(to:root.appendingPathComponent(name),options:.atomic)
    }
    @Test func chromaMatteRevealsBackgroundAndPreservesSubjectAlphaInPreviewAndMP4() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chroma-key-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer { try? FileManager.default.removeItem(at:root) }
        var bytes = [UInt8](repeating:0,count:64*64*4)
        for y in 0..<64 { for x in 0..<64 { let i = (y*64+x)*4
            if x<32 { bytes[i+1] = 255;bytes[i+3] = 255 }
            else { bytes[i] = 128;bytes[i+3] = 128 }
        } }
        let provider = try #require(CGDataProvider(data:Data(bytes) as CFData))
        let image = try #require(CGImage(width:64,height:64,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:256,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:.init(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
        let source = root.appendingPathComponent("original.png");try #require(WorkbenchPNG.encode(image)).write(to:source)
        let original = try Data(contentsOf:source),id = UUID(),range = try PreparedVideoTimeRange(startSeconds:0,durationSeconds:0.1,timescale:600)
        let rate = try PreparedVideoFrameRate(numerator:30,denominator:1),settings = try PreparedVideoOutputSettings(width:64,height:64,frameRate:rate)
        let foreground = PreparedVideoClip(id:UUID(),content:.image(assetID:id),timelineRange:range,sourceRange:range,chromaKey:.init())
        let plan = try PreparedVideoPlan(id:.init(projectID:UUID(),revision:1),timeScale:600,frameRate:rate,duration:range.duration,
            canvas:.init(width:64,height:64,backgroundColor:try .init(hex:"#0000FF")),assets:[.init(id:id,url:source,kind:.image)],visualTracks:[.init(id:UUID(),name:"Keyed",clips:[foreground])])
        let frame = try await PreparedVideoFrameRenderer().renderFrame(plan:plan,frameIndex:0,settings:settings)
        let pixels = try MediaNativeSelection.rgba(frame.image).pixels,a = (32*64+16)*4,b = (32*64+48)*4
        #expect(pixels[a+2]>240 && pixels[a+1]<20 && pixels[a]<20)
        #expect((110...145).contains(pixels[b]) && (110...145).contains(pixels[b+2]))
        try record("M33-keyed-preview.png",try #require(WorkbenchPNG.encode(frame.image)))
        let destination = root.appendingPathComponent("M33-keyed.mp4")
        let receipt = try await PreparedVideoExporter().renderWindow(plan:plan,window:.init(range:range,frameRate:rate),settings:settings,destination:destination,overwrite:false,cancellation:.none,progress:{_ in})
        #expect(receipt.frameCount == 3)
        let decoded = try await AVAssetImageGenerator(asset:AVURLAsset(url:destination)).image(at:.zero).image
        let output = try MediaNativeSelection.rgba(decoded).pixels
        try record("M33-exported-decoded.png",try #require(WorkbenchPNG.encode(decoded)))
        try record("M33-pixel-comparison.json",try JSONSerialization.data(withJSONObject:[
            "previewSize":[frame.image.width,frame.image.height],"decodedSize":[decoded.width,decoded.height],
            "previewBlue":Array(pixels[a..<a+4]),"decodedBlue":Array(output[a..<a+4]),
            "previewSubject":Array(pixels[b..<b+4]),"decodedSubject":Array(output[b..<b+4])
        ],options:[.prettyPrinted,.sortedKeys]))
        #expect(output[a+2]>220 && output[a+1]<30)
        #expect((0..<3).allSatisfy { abs(Int(output[b+$0])-Int(pixels[b+$0])) <= 15 })
        try record(destination.lastPathComponent,Data(contentsOf:destination))
        #expect(try Data(contentsOf:source) == original)
    }
    @Test func blendModesAndZeroOpacityProduceRealExpectedFrames() async throws {
        let range = try PreparedVideoTimeRange(startSeconds:0,durationSeconds:1,timescale:600),rate = try PreparedVideoFrameRate(numerator:30,denominator:1)
        let settings = try PreparedVideoOutputSettings(width:32,height:32,frameRate:rate)
        var samples:[MediaVideoBlendMode:[UInt8]] = [:]
        for mode in MediaVideoBlendMode.allCases {
            let clip = PreparedVideoClip(id:UUID(),content:.graphic(.init(shape:.rectangle,width:1,height:1,fillColor:try .init(hex:"#990000"))),timelineRange:range,blendMode:mode)
            let plan = try PreparedVideoPlan(id:.init(projectID:UUID(),revision:1),timeScale:600,frameRate:rate,duration:range.duration,
                canvas:.init(width:32,height:32,backgroundColor:try .init(hex:"#0000CC")),assets:[],visualTracks:[.init(id:UUID(),name:"Blend",clips:[clip])])
            let frame = try await PreparedVideoFrameRenderer().renderFrame(plan:plan,frameIndex:0,settings:settings)
            let rgba = try MediaNativeSelection.rgba(frame.image).pixels
            samples[mode] = Array(rgba[(16*32+16)*4..<(16*32+16)*4+4])
            try record("M34-\(mode.rawValue).png",try #require(WorkbenchPNG.encode(frame.image)))
        }
        #expect(samples[.normal]![0]>130 && samples[.normal]![2]<10)
        #expect(samples[.multiply]![0]<10 && samples[.multiply]![2]<10)
        #expect(samples[.screen]![0]>130 && samples[.screen]![2]>180)
        let invisible = PreparedVideoClip(id:UUID(),content:.graphic(.init(shape:.rectangle,width:1,height:1,fillColor:.white)),timelineRange:range,opacity:0)
        let plan = try PreparedVideoPlan(id:.init(projectID:UUID(),revision:1),timeScale:600,frameRate:rate,duration:range.duration,canvas:.init(width:32,height:32),assets:[],visualTracks:[.init(id:UUID(),name:"Intentional zero",clips:[invisible])])
        let black = try await PreparedVideoFrameRenderer().renderFrame(plan:plan,frameIndex:0,settings:settings)
        let rgba = try MediaNativeSelection.rgba(black.image).pixels
        #expect(rgba[0] == 0 && rgba[1] == 0 && rgba[2] == 0)
    }
    @Test func chromaAndBlendPersistUndoAndStrictPartialParametersDecode() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("composite-history-\(UUID())");defer { try? FileManager.default.removeItem(at:root) }
        let p = MediaProject(kind:.video,name:"Composite",canvas:.init(width:32,height:32,frameRate:30)),store = MediaProjectStore(directory:root),coordinator = MediaPreparedCoordinator(store:store)
        try await store.save(p);_ = try await coordinator.upgradeDocument(id:p.id)
        let asset = MediaAssetReference(kind:.image,relativePath:"source.png",originalName:"Source")
        let range = try MediaTimeRange(start:.init(value:0,timescale:600),duration:.init(value:600,timescale:600))
        let clip = MediaPreparedClip(assetID:asset.id,timelineRange:range,sourceRange:range),track = MediaPreparedTrack(kind:.visual,name:"Visual")
        _ = try await coordinator.applyUserOperations([.init(action:.insertAsset(asset)),.init(action:.insertTrack(track:track,index:nil)),.init(action:.insertClip(trackID:track.id,clip:clip,index:nil))],to:p.id)
        var edited = try #require(try await coordinator.loadDocument(id:p.id).trackGraph.clip(id:clip.id)?.clip)
        edited.chromaKey = .init();edited.blendMode = .screen;edited.visualOpacity = 0.5
        let commit = try await coordinator.applyUserOperations([.init(action:.replaceClip(trackID:track.id,clipID:clip.id,expectedRevision:edited.revision,clip:edited))],to:p.id)
        let reopened = try await MediaPreparedCoordinator(store:MediaProjectStore(directory:root)).loadDocument(id:p.id)
        #expect(reopened.trackGraph.clip(id:clip.id)?.clip.chromaKey == edited.chromaKey && reopened.trackGraph.clip(id:clip.id)?.clip.visualOpacity == 0.5)
        let plan = try MediaPreparedVideoDocumentAdapter.resolve(reopened,assetURLs:[asset.id:root.appendingPathComponent("source.png")])
        #expect(plan.visualTracks[0].clips[0].blendMode == .screen && plan.visualTracks[0].clips[0].opacity == 0.5)
        _ = try await coordinator.undoGroup(commit.groupID,in:p.id)
        #expect(try await coordinator.loadDocument(id:p.id).trackGraph.clip(id:clip.id)?.clip.chromaKey == nil)
        _ = try await coordinator.redoGroup(commit.groupID,in:p.id)
        #expect(try await coordinator.loadDocument(id:p.id).trackGraph.clip(id:clip.id)?.clip.chromaKey == edited.chromaKey)
        let partial = try JSONDecoder().decode(MediaVideoChromaKey.self,from:Data(##"{"colorHex":"#00FF00","tolerance":0.12}"##.utf8))
        #expect(partial.softness == 0.12 && partial.spillSuppression == 0.5)
        do { _ = try JSONDecoder().decode(MediaVideoChromaKey.self,from:Data(#"{"tolerence":0.1}"#.utf8));Issue.record("Unknown chroma field accepted") }
        catch DecodingError.dataCorrupted(let context) { #expect(context.codingPath.map(\.stringValue) == ["tolerence"]) }
    }
}
