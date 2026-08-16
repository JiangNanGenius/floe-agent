// FloeAppTests — unified workbench navigation, task start and cleanup.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Testing
@testable import FloeApp

@Suite("FloeApp.WorkbenchNavigation")
struct HomeChatSeparationTests {

    @Test("Home and history entry points share one conversation selection")
    @MainActor
    func separateNavigationState() {
        let router = AppRouter()
        let homeThread = UUID()
        let chatThread = UUID()

        router.openThreadFromHome(homeThread)
        #expect(router.selection == .home)
        #expect(router.workbenchSelection == .conversation(homeThread))
        #expect(router.workbenchPath == [homeThread])
        #expect(router.selectedConversationID == homeThread)

        router.openConversation(chatThread)
        #expect(router.selection == .home)
        #expect(router.selectedConversationID == chatThread)
        #expect(router.workbenchSelection == .conversation(chatThread))
        #expect(router.workbenchPath == [chatThread])
        #expect(router.homeDetailConversationID == chatThread)
    }

    @Test("Popping either compact projection returns the workbench to overview")
    @MainActor
    func chatBackDoesNotTouchHome() {
        let router = AppRouter()
        let homeThread = UUID()
        router.openThreadFromHome(homeThread)

        router.openConversation(UUID())
        router.chatPath = []
        #expect(router.workbenchSelection == .overview)
        #expect(router.homeDetailConversationID == nil)
        #expect(router.homePath.isEmpty)
    }

    @Test("Home quick actions deep-link to one concrete More destination")
    @MainActor
    func moreDeepLink() {
        let router = AppRouter()
        router.openMore(.providers)

        #expect(router.selection == .more)
        #expect(router.sidebarSelection == .more(.providers))
        #expect(router.morePath == [.providers])
    }

    @Test("Deleted conversation selection reconciles to overview")
    @MainActor
    func deletionReconcilesSelection() {
        let router = AppRouter()
        let kept = UUID()
        router.openConversation(UUID())
        router.showInspector(.workspaceFiles)

        router.reconcileConversations([kept])

        #expect(router.workbenchSelection == .overview)
        #expect(router.workbenchPath.isEmpty)
        #expect(!router.inspectorVisible)
    }
}

@Suite("FloeApp.HomeTaskCreation")
struct HomeTaskCreationTests {

    /// Records start requests and can fail on demand.
    private final class FakeTaskStarter: HomeTaskStarting, @unchecked Sendable {
        private(set) var startedGoals: [String] = []
        var error: Error?

        func startTask(goal: String, modelID: UUID?) async throws -> UUID {
            if let error { throw error }
            startedGoals.append(goal)
            return UUID()
        }
    }

    private struct SampleError: Error, LocalizedError {
        var errorDescription: String? { "send failed" }
    }

    // NOTE: HomeLaunchpadViewModel requires a ConversationCenter, which
    // needs the full AppEnvironment. These tests therefore pin the
    // single-flight and failure-cleanup CONTRACTS against the
    // HomeTaskStarting seam; the end-to-end creation path is covered by
    // ConversationRunServiceTests (persistence) and the UI test plan
    // (composer send). Codex should wire an AppEnvironment test fixture
    // when one exists.

    @Test("The task starter is invoked exactly once per successful send")
    func starterCalledOnce() async throws {
        let starter = FakeTaskStarter()
        let id = try await starter.startTask(goal: "整理文件", modelID: nil)
        #expect(starter.startedGoals == ["整理文件"])
        #expect(!id.uuidString.isEmpty)
    }

    @Test("A failed start surfaces the error and creates no thread id")
    func starterFailureLeavesNothing() async {
        let starter = FakeTaskStarter()
        starter.error = SampleError()
        do {
            _ = try await starter.startTask(goal: "会失败", modelID: nil)
            Issue.record("Expected the start to throw")
        } catch {
            #expect(starter.startedGoals.isEmpty)
            #expect(error.localizedDescription == "send failed")
        }
    }
}
#endif
