// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
@testable import FloeApp

@Suite("Explicit work URL launch navigation", .serialized)
@MainActor struct WorkURLLaunchRoutingTests {
    @Test func coldWorkEntryRemainsInSpaceWhenLaunchMaintenanceFinishesLater()throws{
        let router=AppRouter(),id=UUID()
        #expect(try FloeAppEntryRoute.parse(FloeAppEntryRoute.work(id).url) == .work(id))
        // The resolved library work branch uses this same existing route.
        router.openMore(.notes)
        router.reconcileInitialNavigation()
        #expect(router.selection == .more);#expect(router.sidebarSelection == .more(.notes));#expect(router.morePath==[.notes])
        #expect(router.workbenchSelection == .newTask(workspaceID:nil))
    }
    @Test func aColdLaunchWithoutAnExplicitTargetStillStartsNewTask(){
        let router=AppRouter();router.reconcileInitialNavigation()
        #expect(router.selection == .home);#expect(router.sidebarSelection == .workbench(.newTask(workspaceID:nil)))
        #expect(router.workbenchSelection == .newTask(workspaceID:nil));#expect(router.morePath.isEmpty);#expect(!router.inspectorVisible)
    }
    @Test func conversationTargetAndTaskInspectorOwnershipRemainUnchanged(){
        let router=AppRouter(),task=UUID()
        router.openConversation(task);router.showInspector(.workspaceFiles);router.reconcileInitialNavigation()
        #expect(router.selectedConversationID==task);#expect(router.workbenchPath==[task]);#expect(router.inspectorRoute?.conversationID==task)
        #expect(router.sidebarSelection == .workbench(.conversation(task)))
    }
    @Test func existingWorkKindsKeepTheirRecordAndSceneThroughTheSameSpaceRequest()throws{
        let selectedTask=UUID(),now=Date(timeIntervalSince1970:1_700_000_000)
        for kind in [PersonalContentKind.latex,.cad2D,.cad3D,.electronics]{
            let router=AppRouter();router.openConversation(selectedTask)
            let record=PersonalContentRecord(id:UUID(),kind:kind,title:"Synthetic original",createdAt:now,modifiedAt:now,folders:["Owned"],relativePath:"Synthetic/Original")
            let request=StudioOpenRequest(record:record,sceneID:"origin-scene")
            #expect(try FloeAppEntryRoute.parse(FloeAppEntryRoute.work(record.id).url) == .work(record.id))
            router.openMore(.notes);router.reconcileInitialNavigation()
            #expect(request.record==record && request.sceneID=="origin-scene")
            #expect(router.sidebarSelection == .more(.notes));#expect(router.selectedConversationID==selectedTask)
            // This request still grants no file/execution authority: actual
            // PersonalContentEditor/LaTeX session admission remains separate.
        }
    }
    @Test func navigationLeaveAndWrongSceneStillFenceLateSourceDelivery(){
        let router=AppRouter(),task=UUID(),registry=DocumentIntakeRoutingRegistry()
        router.openConversation(task)
        registry.setActive(true,sceneID:"a")
        let source=DocumentIntakeRouteSnapshot(router:router),event=UUID()
        registry.capture(source,sceneID:"a",eventID:event)
        router.openMore(.notes)
        let late=DocumentIntakePresentation(id:event,kind:.floeNote,documentID:UUID(),canvasID:nil,title:"Synthetic",sceneID:"a")
        #expect(!registry.canPresent(late,currentRoute:DocumentIntakeRouteSnapshot(router:router)))
        let foreign=UUID();registry.capture(source,sceneID:"a",eventID:foreign)
        #expect(!registry.canPresent(.init(id:foreign,kind:.floeNote,documentID:UUID(),canvasID:nil,title:"Synthetic",sceneID:"b"),currentRoute:source))
        #expect(router.workbenchSelection == .conversation(task))
        // A launch marker never replays the old More destination after the
        // user explicitly leaves it. Existing sidebar leave observers still
        // see the real content change and retain temporary-chat cancellation.
        let workspace=UUID();router.startNewTask(workspaceID:workspace)
        router.reconcileInitialNavigation()
        #expect(router.selection == .home);#expect(router.sidebarSelection == .workbench(.newTask(workspaceID:workspace)))
        #expect(router.workbenchSelection == .newTask(workspaceID:workspace))
    }
}
#endif
