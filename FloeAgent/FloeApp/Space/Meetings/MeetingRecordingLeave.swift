// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import Combine

/// Invoked only by genuine editor navigation. Covering sheets, backgrounding
/// and view reconstruction do not ask, stop capture or release its worker.
@MainActor final class MeetingRecordingLeaveCoordinator: ObservableObject {
    enum Choice: Sendable { case continueRecording, stopAndLeave, cancel }
    struct Prompt: Identifiable { let id: UUID; let title: String }
    @Published private(set) var prompt: Prompt?
    @Published private(set) var isStopping = false
    private var reply: CheckedContinuation<Choice, Never>?
    private var request: UUID?

    func authorize(session: MeetingProjectSession, isStillCurrent: @escaping @MainActor () -> Bool) async -> Bool {
        guard request == nil, !Task.isCancelled, isStillCurrent() else { return false }
        guard session.hasRecordingToLeave else { return true }
        let token = session.recordingDepartureIdentity, id = UUID()
        request = id
        defer { if request == id { request = nil; prompt = nil; reply = nil; isStopping = false } }
        let choice = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                reply = continuation; prompt = Prompt(id: id, title: session.meeting.title)
            }
        } onCancel: { Task { @MainActor [weak self] in self?.choose(id: id, .cancel) } }
        guard !Task.isCancelled, isStillCurrent(), session.recordingDepartureIdentity == token else { return false }
        switch choice {
        case .cancel: return false
        case .continueRecording:
            // The retained project session/service, not this presentation,
            // owns the same recorder, original and ASR/diarization workers.
            return true
        case .stopAndLeave:
            isStopping = true
            let stopped = await session.stopRecordingForDeparture(expectedIntent: token)
            return stopped && !Task.isCancelled && isStillCurrent()
        }
    }
    func choose(id: UUID, _ choice: Choice) {
        guard request == id, prompt?.id == id, let continuation = reply else { return }
        reply = nil; prompt = nil; continuation.resume(returning: choice)
    }
    func cancel() { if let request { choose(id: request, .cancel) } }
}

private struct MeetingRecordingLeavePresentation: ViewModifier {
    @ObservedObject var coordinator: MeetingRecordingLeaveCoordinator
    func body(content: Content) -> some View {
        content
            .alert(IDELanguageRunText.t("离开录音界面", "Leave the recording"), isPresented: Binding(
                get: { coordinator.prompt != nil },
                set: { _ in })) {
                    if let prompt = coordinator.prompt {
                        Button(IDELanguageRunText.t("继续录音", "Continue recording")) { coordinator.choose(id: prompt.id, .continueRecording) }
                        Button(IDELanguageRunText.t("停止并离开", "Stop and leave"), role: .destructive) { coordinator.choose(id: prompt.id, .stopAndLeave) }
                        Button(IDELanguageRunText.t("取消", "Cancel"), role: .cancel) { coordinator.choose(id: prompt.id, .cancel) }
                    }
                } message: {
                    Text(IDELanguageRunText.t("录音仍在进行。继续录音会保留后台录音；停止后会先保存最后一段。", "Recording is still in progress. Continue keeps recording in the background. Stopping saves the final audio before leaving."))
                }
            .overlay(alignment: .bottom) {
                if coordinator.isStopping {
                    Text(IDELanguageRunText.t("正在保存最后一段录音…", "Saving the final audio…"))
                        .padding().background(.regularMaterial, in: Capsule()).padding()
                }
            }
    }
}
extension View {
    func meetingRecordingLeavePresentation(_ coordinator: MeetingRecordingLeaveCoordinator) -> some View {
        modifier(MeetingRecordingLeavePresentation(coordinator: coordinator))
    }
}
#endif
