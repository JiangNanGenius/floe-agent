// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import CoreGraphics
import CryptoKit
import Testing
import FloeWorkbench
@testable import FloeApp

@Suite("M32 original-scoped native compound tools",.serialized)
@MainActor struct MediaCompoundSessionTests {
    @Test func strictTypedClipSelectionAndCompoundScopeDoNotAliasImageObjectIDs() throws {
        let clip=UUID(),compound=UUID()
        let text="{\"expectedRevision\":7,\"clipIDs\":[\"\(clip)\"],\"compoundID\":\"\(compound)\"}"
        let input=try JSONDecoder().decode(MediaV2ToolInput.self,from:Data(text.utf8))
        #expect(input.clipIDs == [clip] && input.compoundID == compound && input.objectIDs == nil)
        #expect(throws:(any Error).self) { try JSONDecoder().decode(MediaV2ToolInput.self,from:Data("{\"clipIDs\":\"\(clip)\"}".utf8)) }
        #expect(throws:(any Error).self) { try JSONDecoder().decode(MediaV2ToolInput.self,from:Data("{\"scopeProjectID\":\"\(compound)\"}".utf8)) }
    }
    @Test func actualNativeCreateScopeToolRefreshAndReopenStayInSameOriginal() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("M32-App-\(UUID())",isDirectory:true)
        try FileManager.default.createDirectory(at:root.appendingPathComponent("Assets"),withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let context=try #require(CGContext(data:nil,width:64,height:64,bitsPerComponent:8,bytesPerRow:64*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red:1,green:0,blue:0,alpha:1));context.fill(.init(x:16,y:16,width:32,height:32))
        let image=try #require(context.makeImage())
        let png=try #require(WorkbenchPNG.encode(image))
        let path=root.appendingPathComponent("Assets/source.png");try png.write(to:path)
        let hash=SHA256.hash(data:png).map{String(format:"%02x",$0)}.joined()
        let source=MediaAssetReference(kind:.image,relativePath:"Assets/source.png",originalName:"Source.png",byteCount:Int64(png.count),contentHash:hash,metadata:.init(width:64,height:64,hasAlpha:true))
        let range=try MediaTimeRange(start:.seconds(0),duration:.seconds(0.4))
        let clip=MediaPreparedClip(assetID:source.id,timelineRange:range,sourceRange:range)
        let track=MediaPreparedTrack(kind:.visual,name:"Original",clips:[clip]),canvas=MediaCanvas(width:64,height:64,frameRate:15),id=UUID()
        let document=MediaPreparedDocument(id:id,kind:.video,name:"Native compound",canvas:canvas,assets:[source],trackGraph:.init(tracks:[track],frameRate:try .init(value:15,timescale:1)))
        let project=MediaProject(schemaVersion:2,id:id,kind:.video,name:document.name,canvas:canvas,assets:[source],prepared:document,preparedJournal:.init())
        let store=MediaProjectStore(directory:root.appendingPathComponent("Projects"));try await store.save(project)
        let coordinator=MediaPreparedCoordinator(store:store)
        let session=MediaV2Session(project:project,root:root,store:store,coordinator:coordinator)
        defer { session.stopPlayback() }
        var canonicalCommit:MediaProject?
        session.onCommit={canonicalCommit=$0}
        var create=MediaV2ToolInput();create.expectedRevision=0;create.clipIDs=[clip.id];create.property="create"
        let receipt=try await session.performTool("video.nest",input:create,actor:.model)
        let anchor=try #require(receipt.compound?.compoundID)
        #expect(session.document.schemaVersion == 3 && session.id == id)
        let inner=try await session.compoundSession(anchor,preview:false)
        #expect(inner.id == id && inner.compoundScopeID == anchor && inner.document.trackGraph.clip(id:clip.id) != nil)
        var edit=MediaV2ToolInput();edit.compoundID=anchor;edit.objectID=clip.id;edit.expectedRevision=session.document.revision;edit.number=2
        _ = try await session.performTool("video.speed",input:edit,actor:.model)
        #expect(try MediaPreparedCompounds.source(clipID:anchor,in:session.document).trackGraph.clip(id:clip.id)?.clip.speed == 2)
        #expect(canonicalCommit?.id == id && canonicalCommit?.prepared?.trackGraph.clip(id:anchor)?.clip.compound != nil)
        var update=MediaV2ToolInput();update.expectedRevision=session.document.revision;update.property="refresh";update.objectID=anchor
        _ = try await session.performTool("video.nest",input:update,actor:.model)
        let reopened=try await MediaPreparedCoordinator(store:MediaProjectStore(directory:root.appendingPathComponent("Projects"))).loadDocument(id:id)
        #expect(try MediaPreparedCompounds.isProxyCurrent(clipID:anchor,in:reopened))
        #expect(try Data(contentsOf:path) == png)
        #expect(try await store.listProjects().count == 1)
    }
}
#endif
