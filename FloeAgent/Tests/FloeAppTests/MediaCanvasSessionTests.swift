// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloeWorkbench
@testable import FloeApp

@Suite("Saved image canvas tools",.serialized)
@MainActor struct MediaCanvasSessionTests {
    @Test func resizeRebasesSelectionAndSubsequentPixelEditClearsTheOldLayoutSpace() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("canvas-session-\(UUID())")
        defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root.appendingPathComponent("Assets"),withIntermediateDirectories:true)
        let store=MediaProjectStore(directory:root.appendingPathComponent("Projects")),coordinator=MediaPreparedCoordinator(store:store)
        let project=MediaProject(kind:.image,name:"Canvas tools",canvas:.init(width:64,height:48))
        try await store.save(project);_ = try await coordinator.upgradeDocument(id:project.id)
        let layer=MediaPreparedLayer(name:"Source",content:.raster(.init(source:.solidColor("#668844"))))
        _ = try await coordinator.applyUserOperations([.init(action:.insertLayer(layer:layer,parentID:nil,index:nil))],to:project.id)
        let session=try await MediaV2Session.open(projectID:project.id,root:root,store:store)
        defer { session.stopPlayback() }
        session.selectedLayerID=layer.id
        session.selection = .init(shapes:[.init(kind:.rectangle,points:[.init(x:0.1,y:0.1),.init(x:0.4,y:0.4)])])
        var dimensions=MediaV2ToolInput();dimensions.expectedRevision=session.document.revision;dimensions.number=128;dimensions.secondary=96;dimensions.points=[.init(x:0,y:0)]
        let canvas=try await session.performTool("image.canvas-size",input:dimensions)
        #expect(canvas.groupID != nil && session.document.canvas?.width==128 && session.document.layer(layer.id)?.canvasSpace != nil)
        let mask=try #require(session.selection?.bitmap)
        #expect(mask.alpha[10*128+10]>200 && mask.alpha[70*128+80]==0)
        var paint=MediaV2ToolInput();paint.objectID=layer.id;paint.expectedRevision=session.document.revision;paint.points=[.init(x:0,y:0),.init(x:1,y:1)];paint.color="#FF0000";paint.text="#0000FF";paint.number=1
        let result=try await session.performTool("image.gradient",input:paint)
        let edited=try #require(session.document.layer(layer.id))
        #expect(result.groupID != nil && edited.canvasSpace==nil && edited.transform == .init())
        let image=try await session.renderedLayerImage(edited,revision:session.document.revision)
        #expect(image.width==128 && image.height==96)
        let reopened=try #require(try await store.loadProject(id:project.id))
        #expect(reopened.prepared?.canvas?.width==128 && reopened.prepared?.layer(layer.id)?.canvasSpace==nil)
    }
}
#endif
