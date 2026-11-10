// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import CoreGraphics
import AVFoundation
@testable import FloeWorkbench

@Suite("M44-M47 non-destructive video grading", .serialized)
struct MediaVideoGradeTests {
    private func record(_ name: String,_ data: Data) throws {
        guard let path = ProcessInfo.processInfo.environment["FLOE_MEDIA_EXECUTION_EVIDENCE_DIR"] else { return }
        let root = URL(fileURLWithPath: path,isDirectory: true);try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        try data.write(to: root.appendingPathComponent(name),options: .atomic)
    }
    private func rgba(_ image: CGImage,_ x: Int,_ y: Int) throws -> [UInt8] {
        let bytes = try MediaNativeSelection.rgba(image).pixels,index = (y*image.width+x)*4
        return Array(bytes[index..<index+4])
    }
    private func render(_ grade: MediaVideoGrade, color: String = "#808080") async throws -> CGImage {
        let range = try PreparedVideoTimeRange(startSeconds: 0,durationSeconds: 0.1,timescale: 600),rate = try PreparedVideoFrameRate(numerator:30,denominator:1)
        let clip = PreparedVideoClip(id:UUID(),content:.graphic(.init(shape:.rectangle,width:1,height:1,fillColor:try .init(hex:color))),timelineRange:range,videoGrade:grade)
        let plan = try PreparedVideoPlan(id:.init(projectID:UUID(),revision:1),timeScale:600,frameRate:rate,duration:range.duration,canvas:.init(width:64,height:64),assets:[],visualTracks:[.init(id:UUID(),name:"Graded",clips:[clip])])
        return try await PreparedVideoFrameRenderer().renderFrame(plan:plan,frameIndex:0,settings:.init(width:64,height:64,frameRate:rate)).image
    }
    @Test func curveAndTonalWheelsProduceActualDifferentNativeFrames() async throws {
        let identity = try await render(.init()),base = try rgba(identity,32,32)
        let points: [ImageFreehandStroke.Point] = [.init(x:0,y:0),.init(x:0.25,y:0.5),.init(x:0.5,y:0.8),.init(x:0.75,y:0.9),.init(x:1,y:1)]
        let curve = try await render(.init(toneCurve:points)),bright = try rgba(curve,32,32)
        #expect(bright[0]>base[0]+40 && abs(Int(bright[0])-Int(bright[2]))<3)
        let settings = ImageColorBalance(midtones:.init(red:0.6,green:0,blue:-0.3),preserveLuminance:true)
        let wheels = try await render(.init(colorBalance:settings)),tinted = try rgba(wheels,32,32)
        #expect(Int(tinted[0])-Int(tinted[2])>35)
        let shadow = try await render(.init(colorBalance:.init(shadows:.init(red:0.7),preserveLuminance:false)),color:"#303030")
        let highlight = try await render(.init(colorBalance:.init(shadows:.init(red:0.7),preserveLuminance:false)),color:"#D0D0D0")
        #expect(Int(try rgba(shadow,32,32)[0])-0x30 > Int(try rgba(highlight,32,32)[0])-0xD0)
        try record("M44-curves.png",try #require(WorkbenchPNG.encode(curve)))
        try record("M45-tonal-wheels.png",try #require(WorkbenchPNG.encode(wheels)))
    }
    @Test func secondaryQualifierChangesOnlySelectedHueSaturationAndLightnessAndExports() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("secondary-\(UUID())");try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let colors: [[UInt8]] = [[255,0,0],[0,255,0],[0,0,255],[128,128,128],[140,115,115],[255,210,210]]
        var bytes = [UInt8](repeating:255,count:96*64*4)
        for y in 0..<64 { for x in 0..<96 { for c in 0..<3 { bytes[(y*96+x)*4+c] = colors[x/16][c] } } }
        let provider = try #require(CGDataProvider(data:Data(bytes) as CFData))
        let originalImage = try #require(CGImage(width:96,height:64,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:384,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:.init(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
        let source = root.appendingPathComponent("source.png");try #require(WorkbenchPNG.encode(originalImage)).write(to:source);let before = try Data(contentsOf:source)
        let q = MediaHSLSecondary(hueCenter:360,hueWidth:20,hueFeather:10,saturationMin:0.5,lightnessMin:0.2,lightnessMax:0.7,rangeFeather:0.02,hueShift:120)
        let range = try PreparedVideoTimeRange(startSeconds:0,durationSeconds:0.1,timescale:600),rate = try PreparedVideoFrameRate(numerator:30,denominator:1),assetID = UUID()
        let clip = PreparedVideoClip(id:UUID(),content:.image(assetID:assetID),timelineRange:range,sourceRange:range,videoGrade:.init(secondary:q))
        let plan = try PreparedVideoPlan(id:.init(projectID:UUID(),revision:1),timeScale:600,frameRate:rate,duration:range.duration,canvas:.init(width:96,height:64),assets:[.init(id:assetID,url:source,kind:.image)],visualTracks:[.init(id:UUID(),name:"Qualified",clips:[clip])])
        let settings = try PreparedVideoOutputSettings(width:96,height:64,frameRate:rate)
        let frame = try await PreparedVideoFrameRenderer().renderFrame(plan:plan,frameIndex:0,settings:settings)
        let selected = try rgba(frame.image,8,32);#expect(selected[1]>240 && selected[0]<15)
        for index in 1..<colors.count {
            let pixel = try rgba(frame.image,index*16+8,32)
            #expect((0..<3).allSatisfy { abs(Int(pixel[$0])-Int(colors[index][$0]))<=3 })
        }
        let url = root.appendingPathComponent("M46-secondary.mp4")
        _ = try await PreparedVideoExporter().renderWindow(plan:plan,window:.init(range:range,frameRate:rate),settings:settings,destination:url,overwrite:false,cancellation:.none,progress:{_ in})
        let decoded = try await AVAssetImageGenerator(asset:AVURLAsset(url:url)).image(at:.zero).image
        let exported = try rgba(decoded,8,32);#expect(exported[1]>220 && exported[0]<30)
        #expect(try Data(contentsOf:source)==before)
        try record("M46-qualified-hsl.png",try #require(WorkbenchPNG.encode(frame.image)));try record(url.lastPathComponent,Data(contentsOf:url))
    }
    @Test func actualCubeAndBuiltInLUTsAreAppliedToTheClipWithoutTouchingOriginal() async throws {
        let lut = try ImageColorLUT.parseCube("""
        TITLE "Red blue swap"
        LUT_3D_SIZE 2
        0 0 0
        0 0 1
        0 1 0
        0 1 1
        1 0 0
        1 0 1
        1 1 0
        1 1 1
        """)
        let cube = try await render(.init(colorLUT:lut,lutName:"red-blue.cube"),color:"#FF0000"),blue = try rgba(cube,32,32)
        #expect(blue[2]>245 && blue[0]<10)
        let mono = try await render(.init(filterID:"CIPhotoEffectMono"),color:"#CC4422"),gray = try rgba(mono,32,32)
        #expect(abs(Int(gray[0])-Int(gray[1]))<4 && abs(Int(gray[1])-Int(gray[2]))<4)
        try record("M47-native-cube.png",try #require(WorkbenchPNG.encode(cube)));try record("M47-native-preset.png",try #require(WorkbenchPNG.encode(mono)))
    }
    @Test func allGradeFieldsPersistProjectIntoNativePlanAndUndoRedoWithStrictNestedValidation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("grade-history-\(UUID())");defer { try? FileManager.default.removeItem(at:root) }
        let project = MediaProject(kind:.video,name:"Grade",canvas:.init(width:64,height:64,frameRate:30)),store = MediaProjectStore(directory:root),coordinator = MediaPreparedCoordinator(store:store)
        try await store.save(project);_ = try await coordinator.upgradeDocument(id:project.id)
        let asset = MediaAssetReference(kind:.image,relativePath:"original.png",originalName:"Original"),range = try MediaTimeRange(start:.init(value:0,timescale:600),duration:.init(value:600,timescale:600)),track = MediaPreparedTrack(kind:.visual,name:"Original")
        let clip = MediaPreparedClip(assetID:asset.id,timelineRange:range,sourceRange:range)
        _ = try await coordinator.applyUserOperations([.init(action:.insertAsset(asset)),.init(action:.insertTrack(track:track,index:nil)),.init(action:.insertClip(trackID:track.id,clip:clip,index:nil))],to:project.id)
        var next = try #require(try await coordinator.loadDocument(id:project.id).trackGraph.clip(id:clip.id)?.clip)
        next.videoGrade = .init(toneCurve:[.init(x:0,y:0),.init(x:0.25,y:0.3),.init(x:0.5,y:0.6),.init(x:0.75,y:0.85),.init(x:1,y:1)],colorBalance:.init(shadows:.init(blue:0.2)),secondary:.init(hueShift:15),filterID:"CIPhotoEffectChrome")
        let commit = try await coordinator.applyUserOperations([.init(action:.replaceClip(trackID:track.id,clipID:clip.id,expectedRevision:next.revision,clip:next))],to:project.id)
        let reopened = try await MediaPreparedCoordinator(store:MediaProjectStore(directory:root)).loadDocument(id:project.id)
        #expect(reopened.trackGraph.clip(id:clip.id)?.clip.videoGrade==next.videoGrade)
        let plan = try MediaPreparedVideoDocumentAdapter.resolve(reopened,assetURLs:[asset.id:root.appendingPathComponent("original.png")])
        #expect(plan.visualTracks[0].clips[0].videoGrade==next.videoGrade)
        _ = try await coordinator.undoGroup(commit.groupID,in:project.id);#expect(try await coordinator.loadDocument(id:project.id).trackGraph.clip(id:clip.id)?.clip.videoGrade==nil)
        _ = try await coordinator.redoGroup(commit.groupID,in:project.id);#expect(try await coordinator.loadDocument(id:project.id).trackGraph.clip(id:clip.id)?.clip.videoGrade==next.videoGrade)
        let partial = try JSONDecoder().decode(MediaVideoGrade.self,from:Data(#"{"secondary":{"hueShift":45}}"#.utf8))
        #expect(partial.secondary?.hueCenter==0 && partial.secondary?.saturationScale==1)
        do { _ = try JSONDecoder().decode(MediaVideoGrade.self,from:Data(#"{"secondary":{"hueShfit":45}}"#.utf8));Issue.record("Unknown qualifier field accepted") }
        catch DecodingError.dataCorrupted(let c) { #expect(c.codingPath.map(\.stringValue)==["secondary","hueShfit"]) }
        #expect(throws:(any Error).self) { try MediaHSLSecondary(saturationMin:0.9,saturationMax:0.2).validate() }
    }
}
