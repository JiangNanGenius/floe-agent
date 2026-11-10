// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import FloeWorkbench

@Suite("Prepared media durable redo", .serialized)
struct MediaPreparedRedoTests {
    func fixture() -> MediaProject { .init(kind:.video,name:"History",canvas:.init(width:160,height:90,frameRate:30),videoTimeline:.init(captions:[.init(start:0,end:3,text:"Caption")])) }
    @Test func successiveSameObjectHistorySurvivesReopen() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("media-redo-\(UUID())")
        defer{try? FileManager.default.removeItem(at:root)}
        let store=MediaProjectStore(directory:root),project=fixture(),a=CaptionStyle(positionY:0.4),b=CaptionStyle(positionY:0.6)
        try await store.save(project)
        let c=MediaPreparedCoordinator(store:store);_=try await c.upgradeDocument(id:project.id)
        let first=try await c.applyUserOperations([.init(action:.setCaptionStyle(expectedRevision:0,style:a))],to:project.id)
        let second=try await c.applyUserOperations([.init(action:.setCaptionStyle(expectedRevision:1,style:b))],to:project.id)
        _=try await c.undoGroup(second.groupID,in:project.id)
        _=try await c.undoGroup(first.groupID,in:project.id)
        let reopened=MediaPreparedCoordinator(store:MediaProjectStore(directory:root))
        _=try await reopened.redoGroup(first.groupID,in:project.id)
        _=try await reopened.redoGroup(second.groupID,in:project.id)
        let result=try #require(try await store.loadProject(id:project.id))
        #expect(result.prepared?.trackGraph.captionStyle==b)
        #expect(result.preparedJournal?.nextUndo?.id==second.groupID)
        #expect(result.preparedJournal?.nextRedo==nil)
        try MediaPreparedIntegrity.validateEnvelope(result)
        _=try await reopened.undoGroup(second.groupID,in:project.id)
        #expect(try await store.loadProject(id:project.id)?.prepared?.trackGraph.captionStyle==a)
    }
    @Test func freshEditDiscardsRedoWithoutLosingDedupeOrTouchingDiskOnFailure() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("media-redo-branch-\(UUID())")
        defer{try? FileManager.default.removeItem(at:root)}
        let store=MediaProjectStore(directory:root),project=fixture(),c=MediaPreparedCoordinator(store:store)
        try await store.save(project);_=try await c.upgradeDocument(id:project.id)
        let operation=MediaPreparedOperation(action:.setCaptionStyle(expectedRevision:0,style:.init(positionY:0.4)))
        let first=try await c.applyUserOperations([operation],to:project.id)
        _=try await c.undoGroup(first.groupID,in:project.id)
        _=try await c.applyUserOperations([.init(action:.setCaptionStyle(expectedRevision:2,style:.init(positionY:0.7)))],to:project.id)
        let state=try #require(try await store.loadProject(id:project.id)),url=store.projectURL(id:project.id),bytes=try Data(contentsOf:url)
        #expect(state.preparedJournal?.entry(first.groupID)?.status == .discarded)
        #expect(state.preparedJournal?.operationIDs.contains(operation.id)==true)
        do{_=try await c.redoGroup(first.groupID,in:project.id);Issue.record("Abandoned branch was redone")}catch{#expect(error is MediaPreparedCoreError)}
        #expect(try Data(contentsOf:url)==bytes)
        do{_=try await c.applyUserOperations([operation],to:project.id);Issue.record("Abandoned operation ID was replayed")}catch{#expect(error is MediaPreparedCoreError)}
        #expect(try Data(contentsOf:url)==bytes)
    }
    @Test func structuralCreationAndMoveRestoreOrderWithoutOverwritingOtherObjects() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("media-redo-structure-\(UUID())")
        defer{try? FileManager.default.removeItem(at:root)}
        let store=MediaProjectStore(directory:root),p=MediaProject(kind:.image,name:"Layers",canvas:.init(width:64,height:64)),c=MediaPreparedCoordinator(store:store)
        try await store.save(p);_=try await c.upgradeDocument(id:p.id)
        let a=MediaPreparedLayer(name:"A",content:.strokes(.init())),b=MediaPreparedLayer(name:"B",content:.strokes(.init()))
        let create=try await c.applyUserOperations([.init(action:.insertLayer(layer:a,parentID:nil,index:nil)),.init(action:.insertLayer(layer:b,parentID:nil,index:nil))],to:p.id)
        _=try await c.undoGroup(create.groupID,in:p.id);_=try await c.redoGroup(create.groupID,in:p.id)
        var d=try await c.loadDocument(id:p.id)
        #expect(d.layers.map(\.id)==[a.id,b.id])
        let move=try await c.applyUserOperations([.init(action:.moveLayer(id:a.id,expectedRevision:d.layer(a.id)!.revision,parentID:nil,index:1))],to:p.id)
        d=try await c.loadDocument(id:p.id)
        _=try await c.applyUserOperations([.init(action:.updateLayerFlags(id:b.id,expectedRevision:d.layer(b.id)!.revision,name:"B edited",isVisible:nil,isLocked:nil,opacity:nil))],to:p.id)
        _=try await c.undoGroup(move.groupID,in:p.id);_=try await c.redoGroup(move.groupID,in:p.id)
        d=try await c.loadDocument(id:p.id)
        #expect(d.layers.map(\.id)==[b.id,a.id]);#expect(d.layer(b.id)?.name=="B edited")
    }
}
