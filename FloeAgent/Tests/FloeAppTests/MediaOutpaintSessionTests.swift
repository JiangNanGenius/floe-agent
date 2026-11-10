// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import CoreImage
import FloeWorkbench
@testable import FloeApp

@Suite("Saved native outpaint transactions",.serialized)
@MainActor struct MediaOutpaintSessionTests {
    @MainActor private final class Calls { var images=0 }
    @MainActor private struct Fixture {
        let root:URL
        let store:MediaProjectStore
        let session:MediaV2Session
        let layerID:UUID
    }
    private func fixture() async throws -> Fixture {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("outpaint-session-\(UUID())")
        try FileManager.default.createDirectory(at:root.appendingPathComponent("Assets"),withIntermediateDirectories:true)
        let store=MediaProjectStore(directory:root.appendingPathComponent("Projects")),coordinator=MediaPreparedCoordinator(store:store)
        let project=MediaProject(kind:.image,name:"Outpaint",canvas:.init(width:64,height:48));try await store.save(project)
        _ = try await coordinator.upgradeDocument(id:project.id)
        let layer=MediaPreparedLayer(name:"Original source",content:.raster(.init(source:.solidColor("#AA442280"))))
        _ = try await coordinator.applyUserOperations([.init(action:.insertLayer(layer:layer,parentID:nil,index:nil))],to:project.id)
        let inserted=try await coordinator.loadDocument(id:project.id),current=try #require(inserted.layer(layer.id))
        _ = try await coordinator.applyUserOperations([.init(action:.updateLayerFlags(id:layer.id,expectedRevision:current.revision,name:nil,isVisible:nil,isLocked:true,opacity:nil))],to:project.id)
        let session=try await MediaV2Session.open(projectID:project.id,root:root,store:store)
        session.selectedLayerID=layer.id
        session.selection = .init(shapes:[.init(kind:.rectangle,points:[.init(x:0.2,y:0.2),.init(x:0.5,y:0.5)])])
        return .init(root:root,store:store,session:session,layerID:layer.id)
    }
    private func input(_ f:Fixture) -> MediaV2ToolInput {
        var value=MediaV2ToolInput();value.expectedRevision=f.session.document.revision;value.number=96;value.secondary=80
        value.points=[.init(x:0.5,y:0.5)];value.text="Extend the surrounding blue sky"
        return value
    }
    private func handlers(_ calls:Calls,wrongShape:Bool=false) -> MediaV2ProviderBridge.Handlers {
        .init(available:{[.imageEditing]},imageRoutes:{[]},editImage:{request,authority in
            calls.images+=1
            #expect(request.width==96 && request.height==80)
            let mask=try MediaProviderEditPixels.decode(request.maskPNG)
            #expect(mask.width==96 && mask.height==80 && !request.sourcePNG.isEmpty)
            try await authority.authorize(capability:.imageEditing,projectID:authority.projectID,revision:authority.revision)
            let extent=CGRect(x:0,y:0,width:wrongShape ? 64:96,height:wrongShape ? 64:80)
            let cg=try #require(CIContext().createCGImage(CIImage(color:CIColor(red:0,green:0,blue:1)).cropped(to:extent),from:extent))
            let data=try #require(WorkbenchPNG.encode(cg))
            return .init(imageData:data,modelTitle:"Local fixture pixels")
        },transcribeFile:{_,_ in throw MediaV2CommandError.unavailable},translateCaptions:{_,_,_ in throw MediaV2CommandError.unavailable})
    }
    @Test func explicitUserExpansionAddsMarginsAndRetainsTheLockedOriginalLayer() async throws {
        let f=try await fixture();defer { f.session.stopPlayback();try? FileManager.default.removeItem(at:f.root) }
        let before=f.session.document,old=try #require(before.layer(f.layerID)),calls=Calls()
        try await MediaV2ProviderBridge.withTemporaryHandlers(handlers(calls)) {
            let receipt=try await f.session.performTool("image.outpaint",input:input(f),actor:.user)
            #expect(calls.images==1 && receipt.groupID != nil && f.session.document.canvas?.width==96 && f.session.document.canvas?.height==80)
            #expect(f.session.document.layers.count==2 && f.session.document.layers.last?.id==old.id)
            #expect(f.session.document.layer(old.id)?.content==old.content && f.session.document.layer(old.id)?.isLocked==true)
            #expect(!f.session.processingTool && !f.session.canvasLayoutInProgress)
            let reloaded=try await f.store.loadProject(id:f.session.id),saved=try #require(reloaded)
            #expect(saved.prepared?.layers.map(\.content)==f.session.document.layers.map(\.content))
            let assets=try f.session.resolvedAssets()
            let output=try await WorkbenchImageRenderer().render(project:saved,canvas:.init(width:96,height:80),resolveAsset:{assets[$0]})
            #expect(output.width==96 && output.height==80 && WorkbenchPNG.encode(output) != nil)
            let coordinator=MediaPreparedCoordinator(store:f.store),group=try #require(receipt.groupID)
            _ = try await coordinator.undoGroup(group,in:f.session.id)
            let undone=try await coordinator.loadDocument(id:f.session.id)
            #expect(undone.canvas==before.canvas && undone.layers.map(\.content)==before.layers.map(\.content) && undone.layer(old.id)?.isLocked==true)
        }
    }
    @Test func wrongProviderShapeCannotSaveOrLeaveStagedAssets() async throws {
        let f=try await fixture();defer { f.session.stopPlayback();try? FileManager.default.removeItem(at:f.root) }
        let file=f.store.projectURL(id:f.session.id),before=try Data(contentsOf:file),assets=f.root.appendingPathComponent("Assets")
        let files=try FileManager.default.contentsOfDirectory(atPath:assets.path).sorted(),calls=Calls()
        try await MediaV2ProviderBridge.withTemporaryHandlers(handlers(calls,wrongShape:true)) {
            do { _ = try await f.session.performTool("image.outpaint",input:input(f),actor:.user);Issue.record("Wrong-shape provider result was saved") }
            catch MediaPreparedCoreError.invalidOperation(_) { }
            #expect(calls.images==1 && !f.session.processingTool && !f.session.canvasLayoutInProgress)
            #expect(try Data(contentsOf:file)==before)
            #expect(try FileManager.default.contentsOfDirectory(atPath:assets.path).sorted()==files)
        }
    }
}
#endif
