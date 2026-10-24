// FloeApp — A scene-bound, app-owned continuous voice presentation.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import FloeModels

private struct ContinuousVoiceWindowKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

private struct ContinuousVoiceActiveKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var continuousVoiceWindowID: String? {
        get { self[ContinuousVoiceWindowKey.self] }
        set { self[ContinuousVoiceWindowKey.self] = newValue }
    }

    var continuousVoiceActive: Bool {
        get { self[ContinuousVoiceActiveKey.self] }
        set { self[ContinuousVoiceActiveKey.self] = newValue }
    }
}

/// A launch request is RAM-only and bound to the window that the user tapped.
/// Home can defer creating a conversation until the first accepted utterance.
struct ContinuousVoiceRequest: Identifiable {
    let id = UUID()
    let windowID: String
    let conversationID: UUID?
    let modelID: UUID
    let workspaceID: UUID?
    let attachments: [AttachmentRef]
    let onConversationCreated: @MainActor (UUID) -> Void
    var onModelSelected: @MainActor (UUID) -> Void = { _ in }
    var draftOwnerID: UUID? = nil
    var onAttachmentsConsumed: @MainActor ([AttachmentRef]) -> Void = { _ in }
    var reasoningDraftOwnerID: UUID? = nil
    var preferredModeForNewConversation: AgentExecutionMode? = nil
}

struct ContinuousVoiceReturnedDraft: Identifiable {
    let id = UUID()
    let windowID: String
    let ownerID: UUID
    let text: String
    let attachments: [AttachmentRef]
}

/// One microphone owner across all app windows. The sheet is mounted at the
/// stable root, so a new Home conversation cannot dismiss its own presenter.
@MainActor
final class ContinuousVoicePresentation: ObservableObject {
    @Published private(set) var request: ContinuousVoiceRequest?
    @Published private(set) var activeConversationID: UUID?
    @Published private(set) var isRecording = false
    @Published private(set) var returnedDraft: ContinuousVoiceReturnedDraft?
    private var teardown: (@MainActor () -> Void)?

    var isPresented: Bool { request != nil }

    @discardableResult
    func present(_ request: ContinuousVoiceRequest) -> Bool {
        guard self.request == nil else { return false }
        activeConversationID = request.conversationID
        self.request = request
        return true
    }

    func installTeardown(for requestID: UUID, _ teardown: @escaping @MainActor () -> Void) {
        guard request?.id == requestID else {
            teardown()
            return
        }
        self.teardown = teardown
    }

    func setRecording(_ recording: Bool, for requestID: UUID) {
        guard request?.id == requestID else { return }
        isRecording = recording
    }

    func bindConversation(_ conversationID: UUID, for requestID: UUID) {
        guard request?.id == requestID else { return }
        activeConversationID = conversationID
    }

    func returnDraft(_ draft: ContinuousVoiceReturnedDraft) { returnedDraft = draft }

    func consumeReturnedDraft(_ id: UUID) {
        guard returnedDraft?.id == id else { return }
        returnedDraft = nil
    }

    func dismiss(_ requestID: UUID) {
        guard request?.id == requestID else { return }
        let stop = teardown
        teardown = nil
        isRecording = false
        activeConversationID = nil
        request = nil
        stop?()
    }
}

/// Only the originating scene presents the shared microphone owner. The
/// immutable captured request also fences a late interactive dismissal.
struct ContinuousVoiceRootModifier: ViewModifier {
    @ObservedObject var presentation: ContinuousVoicePresentation
    let environment: AppEnvironment
    let windowID: String

    func body(content: Content) -> some View {
        let eligible = presentation.request.flatMap { $0.windowID == windowID ? $0 : nil }
        let phone = UIDevice.current.userInterfaceIdiom == .phone
        let tabletRequest = Binding<ContinuousVoiceRequest?>(
            get: { phone ? nil : eligible },
            set: { value in
                if value == nil, let eligible { presentation.dismiss(eligible.id) }
            }
        )
        let phoneRequest = Binding<ContinuousVoiceRequest?>(
            get: { phone ? eligible : nil },
            set: { value in
                if value == nil, let eligible { presentation.dismiss(eligible.id) }
            }
        )
        content
            .environment(\.continuousVoiceActive, presentation.isPresented)
            .sheet(item: tabletRequest) { request in
                ContinuousVoiceSessionHost(
                    request: request, presentation: presentation, environment: environment
                )
                .frame(idealWidth: 640, idealHeight: 680)
                .presentationSizing(.page)
            }
            .fullScreenCover(item: phoneRequest) { request in
                ContinuousVoiceSessionHost(
                    request: request, presentation: presentation, environment: environment
                )
            }
    }
}
#endif
