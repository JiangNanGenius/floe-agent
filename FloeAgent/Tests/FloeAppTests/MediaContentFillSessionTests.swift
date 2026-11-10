// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import CoreGraphics
import FloeWorkbench
@testable import FloeApp

@Suite("M21 M23 actual native image tool persistence",.serialized)
@MainActor struct MediaContentFillSessionTests {
    @Test func actualObjectRemovalSavesAPNGKeepsTheOriginalAndUndoRestoresIt() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("content-fill-session-\(UUID())")
        defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root.appendingPathComponent("Assets"),withIntermediateDirectories:true)
        let w=96,h=64
        var pixels=(0..<w*h).flatMap{index->[UInt8] in [UInt8(20+(index%w)*2),UInt8(30+(index/w)*2),80,255]},alpha=[UInt8](repeating:0,count:w*h)
        for y in 24..<40 { for x in 40..<56 { let i=y*w+x;pixels.replaceSubrange(i*4..<i*4+4,with:[255,0,0,255]);alpha[i]=255 } }
        let provider=try #require(CGDataProvider(data:Data(pixels) as CFData))
        let image=try #require(CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:.init(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
        let bytes=try #require(WorkbenchPNG.encode(image)),source=root.appendingPathComponent("Assets/source.png");try bytes.write(to:source)
        let store=MediaProjectStore(directory:root.appendingPathComponent("Projects")),coordinator=MediaPreparedCoordinator(store:store),project=MediaProject(kind:.image,name:"Content fill",canvas:.init(width:w,height:h))
        try await store.save(project);_ = try await coordinator.upgradeDocument(id:project.id)
        let asset=MediaAssetReference(kind:.image,relativePath:"Assets/source.png",originalName:"Source"),layer=MediaPreparedLayer(name:"Photo",content:.raster(.init(source:.asset(asset.id))))
        _ = try await coordinator.applyUserOperations([.init(action:.insertAsset(asset)),.init(action:.insertLayer(layer:layer,parentID:nil,index:nil))],to:project.id)
        let session=try await MediaV2Session.open(projectID:project.id,root:root,store:store)
        defer { session.stopPlayback() }
        session.selectedLayerID=layer.id;session.selection = .init(bitmap:try .init(width:w,height:h,alpha:Data(alpha)))
        var input=MediaV2ToolInput();input.objectID=layer.id;input.expectedRevision=session.document.revision;input.property="adaptive";input.secondary=1;input.number=0;input.flag=true
        let receipt=try await session.performTool("image.remove",input:input,actor:.user)
        #expect(receipt.groupID != nil && session.document.assets.count==2 && !session.processingTool)
        let originalBytes=try Data(contentsOf:source)
        #expect(session.document.layer(layer.id)?.content != layer.content && originalBytes==bytes)
        let saved=try await store.loadProject(id:project.id)
        #expect(saved?.prepared?.layer(layer.id)?.content==session.document.layer(layer.id)?.content)
        let before=try Data(contentsOf:store.projectURL(id:project.id))
        session.selection=nil;input.expectedRevision=session.document.revision
        do { _ = try await session.performTool("image.content-fill",input:input,actor:.model);Issue.record("Unfenced missing selection was accepted") }
        catch MediaV2CommandError.missingSelection { }
        #expect(try Data(contentsOf:store.projectURL(id:project.id))==before && !session.processingTool)
        let group=try #require(receipt.groupID)
        _ = try await session.coordinator.undoGroup(group,in:project.id)
        #expect(try await session.coordinator.loadDocument(id:project.id).layer(layer.id)?.content==layer.content)
        #expect(try Data(contentsOf:source)==bytes)
    }
}
#endif
