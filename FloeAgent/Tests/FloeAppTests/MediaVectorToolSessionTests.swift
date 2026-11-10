// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloeWorkbench
@testable import FloeApp

@Suite("Native vector and path text actual App tool chain",.serialized)
@MainActor struct MediaVectorToolSessionTests {
    @Test func booleanPathTextTextEditAndOutlineReachTheSavedOriginalThroughActualTools() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vector-tool-session-\(UUID())")
        defer { try? FileManager.default.removeItem(at:root) }
        let store=MediaProjectStore(directory:root.appendingPathComponent("Projects")),coordinator=MediaPreparedCoordinator(store:store)
        let project=MediaProject(kind:.image,name:"Native vector tools",canvas:.init(width:320,height:200));try await store.save(project)
        _ = try await coordinator.upgradeDocument(id:project.id)
        func shape(_ x:Double) -> MediaPreparedLayer {
            .init(name:"Shape",content:.vectorPaths(.init(subpaths:[.init(points:[.init(point:.init(x:x,y:0.2)),.init(point:.init(x:x+0.4,y:0.2)),.init(point:.init(x:x+0.4,y:0.7)),.init(point:.init(x:x,y:0.7))],isClosed:true)])))
        }
        let a=shape(0.1),b=shape(0.4),text=MediaPreparedLayer(name:"Text",content:.text(.init(text:"Floe",fontSize:20,colorHex:"#3366DD",fontName:"Menlo-Regular",tracking:1)))
        _ = try await coordinator.applyUserOperations([a,b,text].map{.init(action:.insertLayer(layer:$0,parentID:nil,index:nil))},to:project.id)
        let session=try await MediaV2Session.open(projectID:project.id,root:root,store:store)
        defer { session.stopPlayback() }
        session.multipleLayerSelection=true;session.selectedLayerIDs=[a.id,b.id]
        var combine=MediaV2ToolInput();combine.objectIDs=[a.id,b.id];combine.objectID=b.id;combine.property="union";combine.expectedRevision=session.document.revision
        _ = try await session.performTool("image.boolean",input:combine,actor:.user)
        let pathID=try #require(session.selectedLayerID)
        #expect(session.document.layers.count==2 && pathID != a.id && pathID != b.id)
        #expect(session.selectedLayerSet == [pathID] && session.selectedLayerIDs == [pathID])
        var path=MediaV2ToolInput();path.objectID=text.id;path.property=pathID.uuidString;path.expectedRevision=session.document.revision;path.number=10;path.secondary=2
        _ = try await session.performTool("image.path-text",input:path,actor:.user)
        var edit=MediaV2ToolInput();edit.objectID=text.id;edit.expectedRevision=session.document.revision;edit.text="AI";edit.number=22
        _ = try await session.performTool("image.text",input:edit,actor:.user)
        guard case .text(let editable)=session.document.layer(text.id)?.content else { Issue.record("Path text lost its editable source");return }
        #expect(editable.pathLayout?.sourceLayerID==pathID && editable.text=="AI" && editable.fontName=="Menlo-Regular" && editable.tracking==1)
        var outline=MediaV2ToolInput();outline.objectID=text.id;outline.expectedRevision=session.document.revision
        let result=try await session.performTool("image.outline",input:outline,actor:.user)
        #expect(result.groupID != nil && session.document.layer(text.id)?.contentKind == .vectorPaths && !session.processingTool)
        let reloaded=try await store.loadProject(id:project.id),saved=try #require(reloaded)
        #expect(saved.prepared?.layers.map(\.content)==session.document.layers.map(\.content))
        let image=try await WorkbenchImageRenderer().render(project:saved,canvas:.init(width:320,height:200),resolveAsset:{_ in nil})
        #expect(WorkbenchPNG.encode(image) != nil)
        let group=try #require(result.groupID)
        _ = try await session.coordinator.undoGroup(group,in:project.id)
        let restored=try await session.coordinator.loadDocument(id:project.id)
        #expect(restored.layer(text.id)?.content == .text(editable))
    }
}
#endif
