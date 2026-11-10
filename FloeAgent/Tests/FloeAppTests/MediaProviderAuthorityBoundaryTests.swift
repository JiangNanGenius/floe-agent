// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloeWorkbench
@testable import FloeApp

@Suite("Native media provider authority boundaries",.serialized)
@MainActor struct MediaProviderAuthorityBoundaryTests {
    @MainActor private final class Calls {
        var image=0,transcription=0,translation=0
        var count:Int { image+transcription+translation }
        var handlers:MediaV2ProviderBridge.Handlers {
            .init(available:{[.imageEditing,.transcription,.translation]},imageRoutes:{[]},
                editImage:{[self] _,_ in image+=1;return .init(imageData:Data([1]),modelTitle:"Unexpected mock call")},
                transcribeFile:{[self] _,_ in transcription+=1;return []},
                translateCaptions:{[self] _,_,_ in translation+=1;return []})
        }
    }
    @MainActor private struct Fixture {
        let root:URL
        let store:MediaProjectStore
        let session:MediaV2Session
        let layerID:UUID
        var file:URL { store.projectURL(id:session.id) }
    }
    private func fixture() async throws -> Fixture {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("provider-authority-\(UUID())")
        try FileManager.default.createDirectory(at:root.appendingPathComponent("Assets"),withIntermediateDirectories:true)
        let store=MediaProjectStore(directory:root.appendingPathComponent("Projects")),coordinator=MediaPreparedCoordinator(store:store)
        let project=MediaProject(kind:.image,name:"Authority fixture",canvas:.init(width:64,height:48))
        try await store.save(project);_ = try await coordinator.upgradeDocument(id:project.id)
        let layer=MediaPreparedLayer(name:"Source",content:.raster(.init(source:.solidColor("#886633"))))
        _ = try await coordinator.applyUserOperations([.init(action:.insertLayer(layer:layer,parentID:nil,index:nil))],to:project.id)
        let session=try await MediaV2Session.open(projectID:project.id,root:root,store:store)
        session.selectedLayerID=layer.id
        session.selection = .init(shapes:[.init(kind:.rectangle,points:[.init(x:0.2,y:0.2),.init(x:0.7,y:0.7)])])
        // Real local preparation succeeds; missing source/region cannot be
        // the reason that the provider call below is denied.
        let current=try #require(session.document.layer(layer.id))
        let image=try await session.renderedLayerImage(current,revision:session.document.revision)
        let selection=try #require(session.selection),reference=try MediaProviderEditPixels.prepareInpaint(image,selection:selection)
        #expect(!reference.sourcePNG.isEmpty && !reference.maskPNG.isEmpty && reference.width==64)
        #expect(!session.saving && !session.processingTool)
        return .init(root:root,store:store,session:session,layerID:layer.id)
    }
    private func input(_ f:Fixture) throws -> MediaV2ToolInput {
        var input=MediaV2ToolInput();input.objectID=f.layerID;input.expectedRevision=f.session.document.revision
        input.selectionFence=try StudioMediaObservation.media(f.session).selectionFence;input.text="Replace the selected color with blue"
        return input
    }
    @Test func modelWithoutAuthorityCannotSendEvenWithARealImageAndRegion() async throws {
        let f=try await fixture();defer { f.session.stopPlayback();try? FileManager.default.removeItem(at:f.root) }
        let before=try Data(contentsOf:f.file),calls=Calls(),input=try input(f)
        try await MediaV2ProviderBridge.withTemporaryHandlers(calls.handlers) {
            do { _ = try await f.session.performTool("image.inpaint",input:input,actor:.model);Issue.record("Model sent without native authority") }
            catch MediaPreparedCoreError.invalidOperation(_) { }
            #expect(calls.count==0 && !f.session.processingTool)
            #expect(try Data(contentsOf:f.file)==before)
        }
    }
    @Test func mismatchedCapabilityCannotBeReusedForImageEditing() async throws {
        let f=try await fixture();defer { f.session.stopPlayback();try? FileManager.default.removeItem(at:f.root) }
        // Use the real native user-action issuer, never a forged task context.
        let authority=try await MediaV2ProviderAuthority.userAction(session:f.session,capability:.translation)
        let before=try Data(contentsOf:f.file),calls=Calls(),input=try input(f)
        try await MediaV2ProviderBridge.withTemporaryHandlers(calls.handlers) {
            do { _ = try await f.session.performTool("image.inpaint",input:input,actor:.model,providerAuthority:authority);Issue.record("Wrong capability reused") }
            catch MediaPreparedCoreError.documentChanged { }
            #expect(calls.count==0 && !f.session.processingTool)
            #expect(try Data(contentsOf:f.file)==before)
        }
    }
    @Test func authorityForAnotherOriginalCannotTargetTheCurrentOriginal() async throws {
        let first=try await fixture(),second=try await fixture()
        defer { first.session.stopPlayback();second.session.stopPlayback();try? FileManager.default.removeItem(at:first.root);try? FileManager.default.removeItem(at:second.root) }
        let authority=try await MediaV2ProviderAuthority.userAction(session:second.session,capability:.imageEditing)
        let firstBytes=try Data(contentsOf:first.file),secondBytes=try Data(contentsOf:second.file),calls=Calls(),input=try input(first)
        try await MediaV2ProviderBridge.withTemporaryHandlers(calls.handlers) {
            do { _ = try await first.session.performTool("image.inpaint",input:input,actor:.model,providerAuthority:authority);Issue.record("Another original's authority reused") }
            catch MediaPreparedCoreError.documentChanged { }
            #expect(calls.count==0 && !first.session.processingTool)
            #expect(try Data(contentsOf:first.file)==firstBytes)
            #expect(try Data(contentsOf:second.file)==secondBytes)
        }
    }
    @Test func changedSavedRevisionIsRejectedEvenWhenTheNativeSessionStillHasItsOldRevision() async throws {
        let f=try await fixture();defer { f.session.stopPlayback();try? FileManager.default.removeItem(at:f.root) }
        let authority=try await MediaV2ProviderAuthority.userAction(session:f.session,capability:.imageEditing)
        let oldRevision=f.session.document.revision,oldLayer=try #require(f.session.document.layer(f.layerID))
        let other=MediaPreparedCoordinator(store:MediaProjectStore(directory:URL(fileURLWithPath:f.store.storeRootPath,isDirectory:true)))
        _ = try await other.applyUserOperations([.init(action:.updateLayerFlags(id:f.layerID,expectedRevision:oldLayer.revision,name:"Changed on disk",isVisible:nil,isLocked:nil,opacity:nil))],to:f.session.id)
        #expect(f.session.document.revision==oldRevision)
        #expect(try await f.store.loadProject(id:f.session.id)?.revision != oldRevision)
        let before=try Data(contentsOf:f.file),calls=Calls(),input=try input(f)
        try await MediaV2ProviderBridge.withTemporaryHandlers(calls.handlers) {
            do { _ = try await f.session.performTool("image.inpaint",input:input,actor:.model,providerAuthority:authority);Issue.record("Stale saved original authorized") }
            catch MediaPreparedCoreError.documentChanged { }
            #expect(calls.count==0 && !f.session.processingTool)
            #expect(try Data(contentsOf:f.file)==before)
        }
    }

    @Test func singleLayerPixelEditSavesWhileSingleLayerMergeStillRefuses() async throws {
        let f=try await fixture();defer { f.session.stopPlayback();try? FileManager.default.removeItem(at:f.root) }
        let before=try Data(contentsOf:f.file),revision=f.session.document.revision
        do {
            _ = try await f.session.mergeLayers([f.layerID],actor:.user)
            Issue.record("Single-layer selection was accepted as a merge")
        } catch WorkbenchImageError.unsupportedSource(_) { }
        #expect(try Data(contentsOf:f.file)==before)
        let oldLayer=try #require(f.session.document.layer(f.layerID))
        let oldImage=try await f.session.renderedLayerImage(oldLayer,revision:revision)
        var edit=try input(f);edit.points=[.init(x:0,y:0.5),.init(x:1,y:0.5)]
        edit.color="#0000FF";edit.text="#FFFFFF";edit.number=1
        let receipt=try await f.session.performTool("image.gradient",input:edit,actor:.user)
        #expect(receipt.revision>revision && !receipt.selectionOnly)
        #expect(f.session.document.layers.count==1 && !f.session.processingTool)
        let newLayer=try #require(f.session.document.layer(f.layerID))
        let newImage=try await f.session.renderedLayerImage(newLayer,revision:f.session.document.revision)
        #expect(try MediaProviderEditPixels.pixelDigestInput(oldImage) != MediaProviderEditPixels.pixelDigestInput(newImage))
        let reloaded=try await f.store.loadProject(id:f.session.id)
        let saved=try #require(reloaded)
        #expect(saved.prepared?.layer(f.layerID)?.content==newLayer.content)
        #expect(try Data(contentsOf:f.file) != before)
    }

}
#endif
