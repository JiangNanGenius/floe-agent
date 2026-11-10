// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import CoreGraphics
import CoreImage
import ImageIO
@testable import FloeWorkbench

@Suite("Provider media pixel and caption boundaries",.serialized)
struct MediaProviderPixelsAndCaptionsTests {
    private func image(_ color: CIColor) throws -> CGImage {
        let space = try #require(CGColorSpace(name:CGColorSpace.sRGB))
        return try #require(CIContext(options:[.workingColorSpace:space,.outputColorSpace:space]).createCGImage(CIImage(color:color).cropped(to:.init(x:0,y:0,width:64,height:48)),from:.init(x:0,y:0,width:64,height:48),format:.RGBA8,colorSpace:space))
    }
    private func record(_ name: String,_ data: Data) throws {
        guard let dir=ProcessInfo.processInfo.environment["FLOE_MEDIA_EXECUTION_EVIDENCE_DIR"] else { return }
        let root=URL(fileURLWithPath:dir,isDirectory:true);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);try data.write(to:root.appendingPathComponent(name),options:.atomic)
    }
    @Test func actualProviderMaskProtectsOutsidePixelsAndPreservesSelectionHoles() throws {
        let source=try image(CIColor(red:0.8,green:0.2,blue:0.1,alpha:0.7)),original=try #require(WorkbenchPNG.encode(source))
        let alpha=Data((0..<64*48).map { index -> UInt8 in
            let x=index%64,y=index/64;return x>=10 && x<30 && y>=6 && y<24 && !(x>=15 && x<20 && y>=10 && y<15) ? 255:0
        })
        let region=ImageSelection(bitmap:try .init(width:64,height:48,alpha:alpha)),reference=try MediaProviderEditPixels.prepareInpaint(source,selection:region)
        let mask=try MediaProviderEditPixels.decode(reference.maskPNG),raster=try MediaNativeSelection.rgba(mask).pixels
        #expect(raster[3]==255 && raster[(8*64+12)*4+3]==0 && raster[(12*64+17)*4+3]==255)
        let generated=try #require(WorkbenchPNG.encode(image(CIColor(red:0,green:0,blue:1))))
        let output=try MediaProviderEditPixels.compositeInpaint(generated,over:source,selection:region)
        let before=try MediaNativeSelection.rgba(source).pixels,after=try MediaNativeSelection.rgba(output).pixels
        for index in alpha.indices where alpha[index]==0 { #expect(Array(before[index*4..<index*4+4])==Array(after[index*4..<index*4+4])) }
        #expect(after[(8*64+12)*4+2]>245 && after[(8*64+12)*4+3]==255)
        #expect(try WorkbenchPNG.encode(source)==original)
        try record("M24-edit-mask.png",reference.maskPNG);try record("M24-composited-selection.png",try #require(WorkbenchPNG.encode(output)))
    }
    @Test func providerEXIFOrientationIsNormalizedBeforeCompositing() throws {
        let source=try image(CIColor(red:1,green:0,blue:0)),data=NSMutableData()
        let destination=try #require(CGImageDestinationCreateWithData(data,"public.jpeg" as CFString,1,nil))
        CGImageDestinationAddImage(destination,source,[kCGImagePropertyOrientation:6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let result=try MediaProviderEditPixels.decode(data as Data)
        #expect(result.width==source.height && result.height==source.width)
    }
    @Test func invalidOrCancelledProviderPixelsFailBeforeProducingAnOutput() async throws {
        let source=try image(CIColor(red:1,green:0,blue:0)),empty=ImageSelection(bitmap:try .init(width:64,height:48,alpha:Data(count:64*48)))
        #expect(throws:(any Error).self) { try MediaProviderEditPixels.prepareInpaint(source,selection:empty) }
        #expect(throws:(any Error).self) { try MediaProviderEditPixels.decode(Data("not an image".utf8)) }
        let task=Task { try await Task.sleep(for:.milliseconds(5));return try MediaProviderEditPixels.prepareInpaint(source,selection:.init(inverted:true)) };task.cancel()
        await #expect(throws:CancellationError.self) { try await task.value }
    }
    @Test func transcriptionTimesMapThroughSourceTrimAndSpeedAndRejectWrongPlayback() throws {
        let timeline=try MediaTimeRange(start:.seconds(10),duration:.seconds(3)),sourceRange=try MediaTimeRange(start:.seconds(20),duration:.seconds(6))
        let source=MediaPreparedClip(timelineRange:timeline,sourceRange:sourceRange,speed:2)
        let segments=[MediaTimedTranscriptSegment(start:0,end:1,text:"First"),.init(start:4,end:6.1,text:"Last")]
        let clips=try MediaCaptionTransformation.transcribedClips(segments,source:source)
        #expect(clips[0].timelineRange.startSeconds==10 && clips[0].timelineRange.durationSeconds==0.5)
        #expect(clips[1].timelineRange.startSeconds==12 && clips[1].timelineRange.endSeconds==13)
        #expect(clips.allSatisfy{$0.captionSource == .transcription})
        var reversed=source;reversed.sourcePlayback = .init(isReversed:true)
        #expect(throws:(any Error).self) { try MediaCaptionTransformation.transcribedClips(segments,source:reversed) }
        #expect(throws:(any Error).self) { try MediaCaptionTransformation.transcribedClips([.init(start:0,end:9,text:"Invalid")],source:source) }
        try record("M41-retimed-captions.json",try JSONEncoder().encode(clips))
    }
    @Test func translationMatchesExactSourceIDsKeepsTimingAndPersistsAsANewUndoableTrack() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("provider-captions-\(UUID())");defer { try? FileManager.default.removeItem(at:root) }
        let store=MediaProjectStore(directory:root),project=MediaProject(kind:.video,name:"Captions",canvas:.init(width:64,height:48,frameRate:30)),coordinator=MediaPreparedCoordinator(store:store)
        try await store.save(project);_ = try await coordinator.upgradeDocument(id:project.id)
        let ranges=[try MediaTimeRange(start:.seconds(1),duration:.seconds(1)),try MediaTimeRange(start:.seconds(4),duration:.seconds(2))]
        let originals=ranges.enumerated().map { index,range in MediaPreparedClip(timelineRange:range,sourceRange:range,captionText:index==0 ? "Hello":"World",captionSource:.manual) }
        let source=MediaPreparedTrack(kind:.caption,name:"Original",clips:originals)
        _ = try await coordinator.applyUserOperations([.init(action:.insertTrack(track:source,index:nil))],to:project.id)
        let savedOriginals=try #require(try await coordinator.loadDocument(id:project.id).trackGraph.track(source.id)?.clips)
        let values=[MediaTranslatedCaption(sourceID:originals[1].id,text:"世界"),.init(sourceID:originals[0].id,text:"你好")]
        let clips=try MediaCaptionTransformation.translatedClips(values,source:savedOriginals,language:"简体中文")
        #expect(clips.map(\.captionText)==["你好","世界"] && clips.map(\.timelineRange)==ranges)
        #expect(clips.map(\.sourceCaptionID)==originals.map(\.id) && Set(clips.map(\.id)).isDisjoint(with:Set(originals.map(\.id))))
        let translated=MediaPreparedTrack(kind:.caption,name:"Translation",clips:clips)
        let edit=try await coordinator.applyUserOperations([.init(action:.insertTrack(track:translated,index:nil))],to:project.id)
        let reopened=try await MediaPreparedCoordinator(store:MediaProjectStore(directory:root)).loadDocument(id:project.id)
        #expect(reopened.trackGraph.track(source.id)?.clips==savedOriginals)
        #expect(reopened.trackGraph.track(translated.id)?.clips.map(\.captionLanguage)==["简体中文","简体中文"])
        _ = try await coordinator.undoGroup(edit.groupID,in:project.id);#expect(try await coordinator.loadDocument(id:project.id).trackGraph.track(translated.id)==nil)
        _ = try await coordinator.redoGroup(edit.groupID,in:project.id);#expect(try await coordinator.loadDocument(id:project.id).trackGraph.track(translated.id)?.clips.map(\.captionText)==["你好","世界"])
        #expect(throws:(any Error).self) { try MediaCaptionTransformation.translatedClips([values[0],values[0]],source:originals,language:"English") }
        #expect(throws:(any Error).self) { try MediaCaptionTransformation.translatedClips([.init(sourceID:UUID(),text:"Injected"),values[1]],source:originals,language:"English") }
        try record("M43-translated-captions.json",try JSONEncoder().encode(clips))
    }
    @Test func inpaintRejectsWrongCanvasShapeInsteadOfStretchingAndKeepsOriginalBytes() throws {
        let original=try image(CIColor(red:1,green:0,blue:0)),before=try #require(WorkbenchPNG.encode(original))
        let square=try #require(CIContext().createCGImage(CIImage(color:CIColor(red:0,green:0,blue:1)).cropped(to:.init(x:0,y:0,width:48,height:48)),from:.init(x:0,y:0,width:48,height:48)))
        let data=try #require(WorkbenchPNG.encode(square))
        #expect(throws:(any Error).self) { try MediaProviderEditPixels.compositeInpaint(data,over:original,selection:.init(inverted:true)) }
        #expect(WorkbenchPNG.encode(original)==before)
    }

}
