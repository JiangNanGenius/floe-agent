// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloeWorkbench
@testable import FloeApp

@Suite("Native media example payloads",.serialized)
@MainActor struct MediaToolInputGuideTests {
    @Test func newMediaExamplesDecodeAgainstTheActualAppToolContract() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("media-tool-guides-\(UUID())")
        defer { try? FileManager.default.removeItem(at:root) }
        let store=MediaProjectStore(directory:root),coordinator=MediaPreparedCoordinator(store:store)
        for kind in [MediaProjectKind.image,.video] {
            let project=MediaProject(kind:kind,name:"Guide",canvas:.init(width:64,height:48,frameRate:kind == .video ? 30:nil))
            try await store.save(project);_ = try await coordinator.upgradeDocument(id:project.id)
            if kind == .image {
                let layer=MediaPreparedLayer(name:"Source",content:.raster(.init(source:.solidColor("#808080"))))
                let square=MediaVectorPath(subpaths:[.init(points:[.init(point:.init(x:0.1,y:0.1)),.init(point:.init(x:0.7,y:0.1)),.init(point:.init(x:0.7,y:0.7)),.init(point:.init(x:0.1,y:0.7))],isClosed:true)],fillColorHex:"#0088FF")
                let first=MediaPreparedLayer(name:"First filled shape",content:.vectorPaths(square))
                let second=MediaPreparedLayer(name:"Second filled shape",content:.vectorPaths(square))
                let text=MediaPreparedLayer(name:"Editable text",content:.text(.init(text:"Hi",fontSize:8)))
                _ = try await coordinator.applyUserOperations([layer,first,second,text].map{.init(action:.insertLayer(layer:$0,parentID:nil,index:nil))},to:project.id)
            } else {
                let image=MediaAssetReference(kind:.video,relativePath:"Assets/source.mov",originalName:"Source"),audio=MediaAssetReference(kind:.audio,relativePath:"Assets/source.wav",originalName:"Source audio")
                let range=try MediaTimeRange(start:.seconds(0),duration:.seconds(3))
                let visual=MediaPreparedTrack(kind:.visual,name:"Visual",clips:[.init(assetID:image.id,timelineRange:range,sourceRange:range)])
                let reference=MediaPreparedTrack(kind:.visual,name:"Reference shot",clips:[.init(assetID:image.id,timelineRange:range,sourceRange:range)])
                let sound=MediaPreparedTrack(kind:.audio,name:"Audio",clips:[.init(assetID:audio.id,timelineRange:range,sourceRange:range)])
                let narration=MediaPreparedTrack(kind:.audio,name:"Narration",clips:[.init(assetID:audio.id,timelineRange:range,sourceRange:range)])
                let captions=MediaPreparedTrack(kind:.caption,name:"Caption",clips:[.init(timelineRange:range,sourceRange:range,captionText:"Hello",captionSource:.manual)])
                _ = try await coordinator.applyUserOperations([.init(action:.insertAsset(image)),.init(action:.insertAsset(audio)),.init(action:.insertTrack(track:visual,index:nil)),.init(action:.insertTrack(track:reference,index:nil)),.init(action:.insertTrack(track:sound,index:nil)),.init(action:.insertTrack(track:narration,index:nil)),.init(action:.insertTrack(track:captions,index:nil))],to:project.id)
            }
            let document=try await coordinator.loadDocument(id:project.id)
            let examples=try MediaPreparedToolInputGuide.make(document:document,implementedToolIDs:MediaV2Session.localToolIDs.union(MediaV2Session.providerToolIDs),selectionFence:String(repeating:"a",count:64),hasImageRegion:true)
            #expect(!examples.isEmpty)
            for example in examples {
                let json=try #require(example.inputJSON)
                let decoded=try StudioMediaToolContract.decode(json)
                #expect(decoded.expectedRevision == document.revision)
                if let object=decoded.objectID {
                    #expect(document.layer(object) != nil || document.trackGraph.clip(id:object) != nil || document.trackGraph.track(object) != nil)
                }
            }
            let missing=try MediaPreparedToolInputGuide.make(document:document,implementedToolIDs:MediaV2Session.localToolIDs,selectionFence:nil)
            #expect(missing.filter(\.requiresSelectionFence).allSatisfy{$0.inputJSON == nil && $0.unavailableReason != nil})
        }
    }

    @Test func colorMatchingWithoutADistinctReferenceHasNoRunnableExample() throws {
        let range=try MediaTimeRange(start:.seconds(0),duration:.seconds(3))
        let asset=MediaAssetReference(kind:.video,relativePath:"Assets/source.mov",originalName:"Source")
        let track=MediaPreparedTrack(kind:.visual,name:"Only shot",clips:[.init(assetID:asset.id,timelineRange:range,sourceRange:range)])
        var document=MediaPreparedDocument(id:UUID(),kind:.video,name:"Missing reference",assets:[asset])
        document.trackGraph.tracks=[track]
        let examples=try MediaPreparedToolInputGuide.make(document:document,implementedToolIDs:["video.color-match"],selectionFence:nil)
        let unavailable=try #require(examples.first{$0.toolID=="video.color-match"})
        #expect(unavailable.inputJSON==nil && unavailable.unavailableReason?.isEmpty==false)
    }

    @Test func duckingWithoutADistinctNarrationHasNoRunnableExample() throws {
        let range=try MediaTimeRange(start:.seconds(0),duration:.seconds(3))
        let asset=MediaAssetReference(kind:.audio,relativePath:"Assets/music.wav",originalName:"Music")
        let track=MediaPreparedTrack(kind:.audio,name:"Music",clips:[.init(assetID:asset.id,timelineRange:range,sourceRange:range)])
        var document=MediaPreparedDocument(id:UUID(),kind:.video,name:"Missing narration",assets:[asset])
        document.trackGraph.tracks=[track]
        let examples=try MediaPreparedToolInputGuide.make(document:document,implementedToolIDs:["video.duck"],selectionFence:nil)
        let unavailable=try #require(examples.first{$0.toolID=="video.duck"})
        #expect(unavailable.inputJSON==nil && unavailable.unavailableReason?.isEmpty==false)
    }
}
#endif
