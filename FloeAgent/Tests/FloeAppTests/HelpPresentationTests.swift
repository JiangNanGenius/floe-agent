// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeCore
@testable import FloeApp

@Suite("Help task and scene ownership", .serialized)
@MainActor
struct HelpPresentationTests {
    private let reference = HelpReference(version: "1.1.0", language: .english, articleID: "input.keyboard")

    @Test func requiresOneActiveHostAndTheExactCurrentRun() async {
        let coordinator = HelpPresentationCoordinator()
        let conversation = UUID(), run = UUID()
        let owner = HelpPresentationOwner(conversationID: conversation, runID: run, requestID: "missing")
        #expect(await coordinator.present(reference: reference, owner: owner).status == "deferred")
        let host = coordinator.registerHost(sceneID: "scene-a", currentConversationID: conversation,
                                            currentRunID: run, isActive: false)
        #expect(await coordinator.present(reference: reference, owner: owner).status == "deferred")
        coordinator.updateHost(host, currentConversationID: conversation, isActive: true)
        #expect(await coordinator.present(reference: reference, owner: owner).status == "deferred")
        coordinator.updateHost(host, currentConversationID: conversation, currentRunID: UUID(), isActive: true)
        #expect(await coordinator.present(reference: reference, owner: owner).status == "deferred")
        coordinator.updateHost(host, currentConversationID: conversation, currentRunID: run, isActive: true)
        let second = coordinator.registerHost(sceneID: "scene-b", currentConversationID: conversation,
                                              currentRunID: run, isActive: true)
        #expect(await coordinator.present(reference: reference, owner: owner).status == "deferred")
        coordinator.unregisterHost(second)
        #expect(coordinator.presentation == nil)
    }

    @Test func reportsPresentedOnlyAfterTheMatchingNativeAppearance() async throws {
        let coordinator = HelpPresentationCoordinator()
        let conversation = UUID(), run = UUID()
        let host = coordinator.registerHost(sceneID: "scene", currentConversationID: conversation,
                                            currentRunID: run, isActive: true)
        let owner = HelpPresentationOwner(conversationID: conversation, runID: run, requestID: "appear")
        var returned = false
        let task = Task {
            let receipt = await coordinator.present(reference: reference, owner: owner)
            returned = true
            return receipt
        }
        let panel = try await waitForPanel(coordinator)
        #expect(!returned)
        #expect(!panel.isVisible)
        coordinator.confirmVisible(presentationID: panel.id, hostID: UUID())
        coordinator.confirmVisible(presentationID: UUID(), hostID: host)
        #expect(coordinator.presentation?.isVisible == false)
        coordinator.confirmVisible(presentationID: panel.id, hostID: host)
        let receipt = await task.value
        #expect(receipt.status == "presented")
        #expect(receipt.reference == reference)
        #expect(coordinator.presentation?.isVisible == true)
        coordinator.dismiss(presentationID: panel.id, hostID: host)
        #expect(coordinator.presentation == nil)
        #expect(await coordinator.present(reference: reference, owner: owner).status == "cancelled")
        let modelRetry = HelpPresentationOwner(conversationID: conversation, runID: run, requestID: "new-call-after-close")
        #expect(await coordinator.present(reference: reference, owner: modelRetry).status == "cancelled")
        #expect(coordinator.presentFromUser(reference: reference, sceneID: "scene", currentConversationID: conversation))
        if let userPanel = coordinator.presentation {
            coordinator.dismiss(presentationID: userPanel.id, hostID: host)
        }
    }

    @Test func cancellationBeforeAndDuringPresentationFencesLateCallbacks() async throws {
        let coordinator = HelpPresentationCoordinator()
        let conversation = UUID(), run = UUID()
        let host = coordinator.registerHost(sceneID: "scene", currentConversationID: conversation,
                                            currentRunID: run, isActive: true)
        let early = HelpPresentationOwner(conversationID: conversation, runID: run, requestID: "early")
        coordinator.cancel(owner: early)
        #expect(await coordinator.present(reference: reference, owner: early).status == "cancelled")
        let owner = HelpPresentationOwner(conversationID: conversation, runID: run, requestID: "during")
        let task = Task { await coordinator.present(reference: reference, owner: owner) }
        let panel = try await waitForPanel(coordinator)
        task.cancel()
        // Native appearance can arrive before the queued main-actor cleanup.
        coordinator.confirmVisible(presentationID: panel.id, hostID: host)
        #expect(await task.value.status == "cancelled")
        coordinator.confirmVisible(presentationID: panel.id, hostID: host)
        #expect(coordinator.presentation == nil)
        #expect(await coordinator.present(reference: reference, owner: owner).status == "cancelled")
    }

    @Test func switchingAwayAndBackCannotReviveAnOldRun() async throws {
        let coordinator = HelpPresentationCoordinator()
        let conversation = UUID(), run = UUID()
        let host = coordinator.registerHost(sceneID: "scene", currentConversationID: conversation,
                                            currentRunID: run, isActive: true)
        let owner = HelpPresentationOwner(conversationID: conversation, runID: run, requestID: "navigation")
        let task = Task { await coordinator.present(reference: reference, owner: owner) }
        let panel = try await waitForPanel(coordinator)
        coordinator.updateHost(host, currentConversationID: UUID(), currentRunID: UUID(), isActive: true)
        #expect(await task.value.status == "cancelled")
        coordinator.updateHost(host, currentConversationID: conversation, currentRunID: run, isActive: true)
        coordinator.confirmVisible(presentationID: panel.id, hostID: host)
        let late = HelpPresentationOwner(conversationID: conversation, runID: run, requestID: "late-new-call")
        #expect(await coordinator.present(reference: reference, owner: late).status == "cancelled")
        #expect(coordinator.presentation == nil)
    }

    @Test func backgroundDefersPendingHelpWithoutAQueuedReopening() async throws {
        let coordinator = HelpPresentationCoordinator()
        let conversation = UUID(), run = UUID()
        let host = coordinator.registerHost(sceneID: "scene", currentConversationID: conversation,
                                            currentRunID: run, isActive: true)
        let owner = HelpPresentationOwner(conversationID: conversation, runID: run, requestID: "background")
        let task = Task { await coordinator.present(reference: reference, owner: owner) }
        let panel = try await waitForPanel(coordinator)
        coordinator.updateHost(host, currentConversationID: conversation, currentRunID: run, isActive: false)
        #expect(await task.value.status == "deferred")
        coordinator.updateHost(host, currentConversationID: conversation, currentRunID: run, isActive: true)
        coordinator.confirmVisible(presentationID: panel.id, hostID: host)
        #expect(coordinator.presentation == nil)
        #expect(await coordinator.present(reference: reference, owner: owner).status == "cancelled")
    }

    @Test func completedVisiblePanelSurvivesBackgroundAndRunCompletion() async throws {
        let coordinator = HelpPresentationCoordinator()
        let conversation = UUID(), run = UUID()
        let host = coordinator.registerHost(sceneID: "scene", currentConversationID: conversation,
                                            currentRunID: run, isActive: true)
        let owner = HelpPresentationOwner(conversationID: conversation, runID: run, requestID: "visible")
        let task = Task { await coordinator.present(reference: reference, owner: owner) }
        let panel = try await waitForPanel(coordinator)
        coordinator.confirmVisible(presentationID: panel.id, hostID: host)
        #expect(await task.value.status == "presented")
        coordinator.updateHost(host, currentConversationID: conversation, isActive: false)
        #expect(coordinator.presentation?.id == panel.id)
        #expect(await coordinator.present(reference: reference, owner: owner).status == "deferred")
        coordinator.updateHost(host, currentConversationID: conversation, isActive: true)
        #expect(coordinator.presentation?.id == panel.id)
        coordinator.dismiss(presentationID: panel.id, hostID: host)
    }

    @Test func unavailableContentAndRunCancellationDoNotOpenAPanel() async {
        let coordinator = HelpPresentationCoordinator()
        let conversation = UUID(), run = UUID()
        coordinator.registerHost(sceneID: "scene", currentConversationID: conversation,
                                 currentRunID: run, isActive: true, canRead: { _ in false })
        let owner = HelpPresentationOwner(conversationID: conversation, runID: run, requestID: "missing-version")
        #expect(await coordinator.present(reference: reference, owner: owner).status == "unavailable")
        coordinator.cancel(runID: run)
        let late = HelpPresentationOwner(conversationID: conversation, runID: run, requestID: "after-cancel")
        #expect(await coordinator.present(reference: reference, owner: late).status == "cancelled")
        #expect(coordinator.presentation == nil)
    }

    @Test func userCitationRequiresTheExplicitSceneButDoesNotRequireALiveRun() {
        let coordinator = HelpPresentationCoordinator()
        let conversation = UUID()
        let host = coordinator.registerHost(sceneID: "scene", currentConversationID: conversation, isActive: true)
        #expect(!coordinator.presentFromUser(reference: reference, sceneID: "other", currentConversationID: conversation))
        #expect(!coordinator.presentFromUser(reference: reference, sceneID: "scene", currentConversationID: UUID()))
        #expect(coordinator.presentFromUser(reference: reference, sceneID: "scene", currentConversationID: conversation))
        #expect(coordinator.presentation?.isUserInitiated == true)
        if let panel = coordinator.presentation {
            coordinator.confirmVisible(presentationID: panel.id, hostID: host)
            #expect(coordinator.presentation?.isVisible == true)
            coordinator.dismiss(presentationID: panel.id, hostID: host)
        }
    }

    @Test func failedNativePresentationTimesOutAndRetiresTheRequest() async {
        let coordinator = HelpPresentationCoordinator(appearanceTimeout: .milliseconds(5))
        let conversation = UUID(), run = UUID()
        coordinator.registerHost(sceneID: "scene", currentConversationID: conversation,
                                 currentRunID: run, isActive: true)
        let owner = HelpPresentationOwner(conversationID: conversation, runID: run, requestID: "timeout")
        #expect(await coordinator.present(reference: reference, owner: owner).status == "deferred")
        #expect(coordinator.presentation == nil)
        #expect(await coordinator.present(reference: reference, owner: owner).status == "cancelled")
    }

    @Test func wideLayoutNeedsAnExactVisibleAnswerAnchor() async throws {
        let coordinator = HelpPresentationCoordinator()
        let conversation = UUID(), run = UUID()
        let host = coordinator.registerHost(sceneID: "wide", currentConversationID: conversation,
            currentRunID: run, isActive: true, prefersPopover: true)
        let owner = HelpPresentationOwner(conversationID: conversation, runID: run, requestID: "wide")
        #expect(await coordinator.present(reference: reference, owner: owner).status == "deferred")
        let oldAnswer = try registerAnchor(coordinator, sceneID: "wide", conversationID: conversation,
            runID: UUID(), isVisible: { true })
        let wrongScene = try registerAnchor(coordinator, sceneID: "other", conversationID: conversation,
            runID: run, isVisible: { true })
        let hidden = try registerAnchor(coordinator, sceneID: "wide", conversationID: conversation,
            runID: run, isVisible: { false })
        #expect(await coordinator.present(reference: reference, owner: owner).status == "deferred")
        let real = try registerAnchor(coordinator, sceneID: "wide", conversationID: conversation,
            runID: run, isVisible: { true })
        let task = Task { await coordinator.present(reference: reference, owner: owner) }
        let panel = try await waitForPanel(coordinator)
        #expect(panel.layout == .popover)
        #expect(panel.anchorID == real)
        #expect(coordinator.presentation(forAnchor: real)?.id == panel.id)
        #expect(coordinator.presentation(forAnchor: wrongScene) == nil)
        coordinator.confirmVisible(presentationID: panel.id, hostID: host)
        #expect(await task.value.status == "presented")
        coordinator.dismiss(presentationID: panel.id, hostID: host)
        for id in [oldAnswer, wrongScene, hidden, real] { coordinator.unregisterAnswerAnchor(id) }
    }

    @Test func ambiguousAndDisappearingAnchorsCannotClaimPresentation() async throws {
        let coordinator = HelpPresentationCoordinator()
        let conversation = UUID(), run = UUID()
        let host = coordinator.registerHost(sceneID: "wide", currentConversationID: conversation,
            currentRunID: run, isActive: true, prefersPopover: true)
        let owner = HelpPresentationOwner(conversationID: conversation, runID: run, requestID: "moving")
        var visible = true
        let first = try registerAnchor(coordinator, sceneID: "wide", conversationID: conversation,
            runID: run, isVisible: { visible })
        let duplicate = try registerAnchor(coordinator, sceneID: "wide", conversationID: conversation,
            runID: run, isVisible: { true })
        #expect(await coordinator.present(reference: reference, owner: owner).status == "deferred")
        coordinator.unregisterAnswerAnchor(duplicate)
        let task = Task { await coordinator.present(reference: reference, owner: owner) }
        let panel = try await waitForPanel(coordinator)
        visible = false
        coordinator.confirmVisible(presentationID: panel.id, hostID: host)
        #expect(coordinator.presentation?.isVisible == false)
        coordinator.unregisterAnswerAnchor(first)
        #expect(await task.value.status == "cancelled")
        coordinator.confirmVisible(presentationID: panel.id, hostID: host)
        #expect(coordinator.presentation == nil)
    }

    @Test func compactUsesTheTaskSheetAndHistoricalUserClicksCanUseTheirOwnAnchor() async throws {
        let coordinator = HelpPresentationCoordinator()
        let conversation = UUID(), run = UUID()
        let host = coordinator.registerHost(sceneID: "scene", currentConversationID: conversation,
            currentRunID: run, isActive: true)
        let anchor = try registerAnchor(coordinator, sceneID: "scene", conversationID: conversation,
            runID: UUID(), isVisible: { true })
        let owner = HelpPresentationOwner(conversationID: conversation, runID: run, requestID: "compact")
        let task = Task { await coordinator.present(reference: reference, owner: owner) }
        let panel = try await waitForPanel(coordinator)
        #expect(panel.layout == .sheet)
        #expect(panel.anchorID == nil)
        coordinator.confirmVisible(presentationID: panel.id, hostID: host)
        #expect(await task.value.status == "presented")
        coordinator.dismiss(presentationID: panel.id, hostID: host)
        coordinator.updateHost(host, currentConversationID: conversation, currentRunID: run,
                               isActive: true, prefersPopover: true)
        #expect(coordinator.presentFromUser(reference: reference, sceneID: "scene", currentConversationID: conversation,
                                           preferredAnchorID: anchor))
        #expect(coordinator.presentation?.layout == .popover)
        #expect(coordinator.presentation?.anchorID == anchor)
        if let current = coordinator.presentation {
            coordinator.dismiss(presentationID: current.id, hostID: host)
        }
        coordinator.unregisterAnswerAnchor(anchor)
    }

    private func registerAnchor(_ coordinator: HelpPresentationCoordinator, sceneID: String,
                                conversationID: UUID, runID: UUID?,
                                isVisible: @escaping @MainActor () -> Bool) throws -> UUID {
        // Do not ask the macro to decompose an actor-isolated closure parameter.
        let candidate = coordinator.registerAnswerAnchor(sceneID: sceneID, conversationID: conversationID,
            runID: runID, reference: reference, isVisible: isVisible)
        return try #require(candidate)
    }

    private func waitForPanel(_ coordinator: HelpPresentationCoordinator) async throws -> HelpPresentation {
        for _ in 0..<100 {
            if let panel = coordinator.presentation { return panel }
            await Task.yield()
        }
        return try #require(coordinator.presentation)
    }
}
