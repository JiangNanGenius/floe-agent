// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import CoreGraphics
@testable import FloeWorkbench

@Suite("M15 M16 M17 durable native edit plans",.serialized)
struct MediaNativeVectorEditTests {
    private struct Fixture { let root:URL;let coordinator:MediaPreparedCoordinator;let store:MediaProjectStore;let id:UUID;let text:UUID;let path:UUID;let other:UUID }
    private func fixture() async throws -> Fixture {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vector-plans-\(UUID())"),store=MediaProjectStore(directory:root.appendingPathComponent("Projects"))
        let coordinator=MediaPreparedCoordinator(store:store),project=MediaProject(kind:.image,name:"Vector edits",canvas:.init(width:320,height:200))
        try await store.save(project);_ = try await coordinator.upgradeDocument(id:project.id)
        let path=MediaPreparedLayer(name:"Path",content:.vectorPaths(.init(subpaths:[.init(points:[.init(point:.init(x:0.05,y:0.7),controlOut:.init(x:0.3,y:0.1)),.init(point:.init(x:0.95,y:0.5),controlIn:.init(x:0.7,y:0.1))])],fillColorHex:nil,strokeColorHex:"#FF0000",strokeWidth:2)))
        let text=MediaPreparedLayer(name:"Text",content:.text(.init(text:"Floe",fontSize:24,colorHex:"#3377DD")))
        let shape=MediaPreparedLayer(name:"Shape",content:.vectorPaths(.init(subpaths:[.init(points:[.init(point:.init(x:0.2,y:0.2)),.init(point:.init(x:0.6,y:0.2)),.init(point:.init(x:0.6,y:0.6)),.init(point:.init(x:0.2,y:0.6))],isClosed:true)])))
        _ = try await coordinator.applyUserOperations([path,text,shape].map{.init(action:.insertLayer(layer:$0,parentID:nil,index:nil))},to:project.id)
        return .init(root:root,coordinator:coordinator,store:store,id:project.id,text:text.id,path:path.id,other:shape.id)
    }
    private func cleanup(_ f:Fixture) { try? FileManager.default.removeItem(at:f.root) }
    @Test func booleanPlanPreservesThePrimaryStackPositionAndRestoresOriginalCurvesOnUndo() async throws {
        let f=try await fixture();defer { cleanup(f) }
        var doc=try await f.coordinator.loadDocument(id:f.id),other=try #require(doc.layer(f.other)),copy=other
        copy.id=UUID();copy.name="Primary";copy.transform.centerX=0.65;copy.opacity=0.6
        _ = try await f.coordinator.applyUserOperations([.init(action:.insertLayer(layer:copy,parentID:nil,index:nil))],to:f.id)
        doc=try await f.coordinator.loadDocument(id:f.id)
        let plan=try MediaNativeVectorEdits.boolean([other.id,copy.id],in:doc,operation:.union,primaryID:copy.id)
        #expect(throws:(any Error).self) { try MediaNativeVectorEdits.boolean([copy.id,copy.id],in:doc,operation:.union,primaryID:copy.id) }
        let edit=try await f.coordinator.applyUserOperations(plan.actions.map{.init(action:$0)},to:f.id)
        let combined=try await f.coordinator.loadDocument(id:f.id),newID=try #require(plan.selectedLayerID)
        #expect(combined.layers.map(\.id)==[f.path,f.text,newID] && combined.layer(newID)?.opacity==0.6)
        _ = try await f.coordinator.undoGroup(edit.groupID,in:f.id)
        let undone=try await f.coordinator.loadDocument(id:f.id)
        #expect(undone.layers.map(\.id)==doc.layers.map(\.id) && undone.layers.map(\.content)==doc.layers.map(\.content))
        _ = try await f.coordinator.redoGroup(edit.groupID,in:f.id)
        #expect(try await f.coordinator.loadDocument(id:f.id).layers.map(\.content)==combined.layers.map(\.content))
    }
    @Test func savedPathTextSurvivesSourcePathDeletionAndCanvasResizeAndStaysEditable() async throws {
        let f=try await fixture();defer { cleanup(f) }
        let before=try await f.coordinator.loadDocument(id:f.id),plan=try MediaNativeVectorEdits.pathText(f.text,in:before,pathSourceID:f.path,startOffset:10)
        _ = try await f.coordinator.applyUserOperations(plan.actions.map{.init(action:$0)},to:f.id)
        var doc=try await f.coordinator.loadDocument(id:f.id)
        let source=try #require(doc.layer(f.path))
        _ = try await f.coordinator.applyUserOperations([.init(action:.removeLayer(id:source.id,expectedRevision:source.revision))],to:f.id)
        doc=try await f.coordinator.loadDocument(id:f.id)
        _ = try await f.coordinator.applyUserOperations(MediaCanvasLayout.actions(doc,width:400,height:320,mode:.extendCanvas(anchor:.init(x:0.5,y:0.5))).map{.init(action:$0)},to:f.id)
        doc=try await f.coordinator.loadDocument(id:f.id)
        let revision=doc.revision,update=try MediaNativeVectorEdits.pathText(f.text,in:doc,pathSourceID:nil,text:"Floe AI",startOffset:15)
        let edit=try await f.coordinator.applyUserOperations(update.actions.map{.init(action:$0)},to:f.id)
        let reopened=try await MediaPreparedCoordinator(store:MediaProjectStore(directory:URL(fileURLWithPath:f.store.storeRootPath,isDirectory:true))).loadDocument(id:f.id)
        let content=try #require(reopened.layer(f.text))
        guard case .text(let text)=content.content else { Issue.record("Path text stopped being editable text");return }
        #expect(text.text=="Floe AI" && text.pathLayout?.sourceLayerID==f.path && reopened.layer(f.path)==nil && reopened.revision>revision)
        let image=try await WorkbenchImageRenderer().renderPrepared(reopened,canvas:.init(width:400,height:320),resolveAsset:{_ in nil})
        #expect(image.width==400 && image.height==320)
        _ = try await f.coordinator.undoGroup(edit.groupID,in:f.id)
        #expect(try await f.coordinator.loadDocument(id:f.id).layer(f.text)?.content==doc.layer(f.text)?.content)
    }
    @Test func realOutlinePlanIsSavedAsVectorAndUndoReturnsTheExactEditableText() async throws {
        let f=try await fixture();defer { cleanup(f) }
        let before=try await f.coordinator.loadDocument(id:f.id),plan=try MediaNativeVectorEdits.outline(f.text,in:before)
        let edit=try await f.coordinator.applyUserOperations(plan.actions.map{.init(action:$0)},to:f.id)
        let outlined=try await f.coordinator.loadDocument(id:f.id)
        #expect(outlined.layer(f.text)?.contentKind == .vectorPaths && outlined.layer(f.text)?.canvasSpace != nil)
        _ = try await f.coordinator.undoGroup(edit.groupID,in:f.id)
        #expect(try await f.coordinator.loadDocument(id:f.id).layer(f.text)?.content==before.layer(f.text)?.content)
        _ = try await f.coordinator.redoGroup(edit.groupID,in:f.id)
        #expect(try await f.coordinator.loadDocument(id:f.id).layer(f.text)?.content==outlined.layer(f.text)?.content)
    }
    @Test func completeModelGuidesUseOnlyActualShapeTextAndPathIDs() async throws {
        let f=try await fixture();defer { cleanup(f) }
        let doc=try await f.coordinator.loadDocument(id:f.id)
        let guides=try MediaPreparedToolInputGuide.make(document:doc,implementedToolIDs:["image.boolean","image.path-text","image.outline"])
        let path=try #require(guides.first{$0.toolID == "image.path-text"}),json=try #require(path.inputJSON)
        let data=try #require(JSONSerialization.jsonObject(with:Data(json.utf8)) as? [String:Any])
        #expect(data["objectID"] as? String == f.text.uuidString && data["property"] as? String == f.path.uuidString)
        #expect(guides.first{$0.toolID == "image.boolean"}?.inputJSON==nil)
        let outline=try #require(guides.first{$0.toolID == "image.outline"})
        #expect(outline.inputJSON != nil && outline.executionTool=="studio.media")
    }

    @Test func mismatchedPathTextCanvasFailsBeforeAnySave() async throws {
        let f=try await fixture();defer { cleanup(f) }
        let doc=try await f.coordinator.loadDocument(id:f.id),plan=try MediaNativeVectorEdits.pathText(f.text,in:doc,pathSourceID:f.path)
        _ = try await f.coordinator.applyUserOperations(plan.actions.map{.init(action:$0)},to:f.id)
        let current=try await f.coordinator.loadDocument(id:f.id),layer=try #require(current.layer(f.text))
        guard case .text(var text)=layer.content else { Issue.record("Missing text");return }
        text.pathLayout?.referenceCanvas.width+=1
        let before=try Data(contentsOf:f.store.projectURL(id:f.id))
        do { _ = try await f.coordinator.applyUserOperations([.init(action:.replaceLayerContent(id:layer.id,expectedRevision:layer.revision,content:.text(text)))],to:f.id);Issue.record("Mismatched path canvas saved") }
        catch MediaPreparedCoreError.invalidDocument(_) { }
        #expect(try Data(contentsOf:f.store.projectURL(id:f.id))==before)
    }

}
