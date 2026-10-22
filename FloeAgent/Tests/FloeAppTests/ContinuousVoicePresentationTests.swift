#if canImport(UIKit)
import Foundation
import Testing
@testable import FloeApp

@MainActor
struct ContinuousVoicePresentationTests {
    private func request(window: String = "one") -> ContinuousVoiceRequest {
        ContinuousVoiceRequest(
            windowID: window, conversationID: nil, modelID: UUID(),
            workspaceID: nil, attachments: [], onConversationCreated: { _ in }
        )
    }

    @Test func twoWindowsCannotOwnOneMicrophoneAndLateDismissCannotCloseNewOwner() {
        let presenter = ContinuousVoicePresentation()
        let first = request()
        let second = request(window: "two")
        #expect(presenter.present(first))
        #expect(!presenter.present(second))
        var firstStops = 0
        presenter.installTeardown(for: first.id) { firstStops += 1 }
        presenter.dismiss(first.id)
        #expect(firstStops == 1)
        #expect(presenter.present(second))
        presenter.setRecording(true, for: second.id)
        presenter.dismiss(first.id)
        #expect(presenter.request?.id == second.id)
        #expect(presenter.isRecording)
    }

    @Test func latePreparationIsImmediatelyTornDownAndCannotBindAnotherConversation() {
        let presenter = ContinuousVoicePresentation()
        let first = request()
        let second = request()
        #expect(presenter.present(first))
        presenter.dismiss(first.id)
        #expect(presenter.present(second))
        let currentConversation = UUID()
        presenter.bindConversation(currentConversation, for: second.id)
        var oldPreparationStopped = false
        presenter.installTeardown(for: first.id) { oldPreparationStopped = true }
        presenter.bindConversation(UUID(), for: first.id)
        presenter.setRecording(true, for: first.id)
        #expect(oldPreparationStopped)
        #expect(presenter.activeConversationID == currentConversation)
        #expect(!presenter.isRecording)
    }
    @Test func lateDraftAcknowledgementCannotClearANewerReturnedDraft() {
        let presenter = ContinuousVoicePresentation()
        let first = ContinuousVoiceReturnedDraft(windowID: "one", ownerID: UUID(), text: "first", attachments: [])
        let next = ContinuousVoiceReturnedDraft(windowID: "one", ownerID: UUID(), text: "next", attachments: [])
        presenter.returnDraft(first)
        presenter.returnDraft(next)
        presenter.consumeReturnedDraft(first.id)
        #expect(presenter.returnedDraft?.id == next.id)
        presenter.consumeReturnedDraft(next.id)
        #expect(presenter.returnedDraft == nil)
    }

}
#endif
