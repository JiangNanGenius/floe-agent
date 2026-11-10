// SPDX-License-Identifier: MPL-2.0
#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// Only a real document-level navigation action reads this gate. Transient
/// sheets, embedded node editors, tab switches and onDisappear never do.
struct DocumentAssistantLeaveIntent: Sendable {
    let authorize: @MainActor @Sendable () async -> Bool
}
private struct DocumentAssistantLeaveIntentKey: EnvironmentKey {
    static let defaultValue: DocumentAssistantLeaveIntent? = nil
}
extension EnvironmentValues {
    var documentAssistantLeaveIntent: DocumentAssistantLeaveIntent? {
        get { self[DocumentAssistantLeaveIntentKey.self] }
        set { self[DocumentAssistantLeaveIntentKey.self] = newValue }
    }
}

private struct DocumentAssistantLeaveSheet: View {
    @ObservedObject var coordinator: DocumentAssistantLeaveCoordinator
    let prompt: DocumentAssistantLeaveCoordinator.Prompt
    @State private var remember = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(IDELanguageRunText.t("助手还在处理这份文档。离开后要如何继续？",
                        "The assistant is still working on this document. What should happen when you leave?"))
                    Text(prompt.snapshot.title).foregroundStyle(.secondary).lineLimit(2)
                }
                Section {
                    Button(IDELanguageRunText.t("继续运行", "Continue running")) {
                        coordinator.choose(requestID: prompt.id, .continueInBackground, remember: remember)
                    }.accessibilityIdentifier("document.assistant.leave.continue")
                    Button(IDELanguageRunText.t("停止当前任务", "Stop current work"), role: .destructive) {
                        coordinator.choose(requestID: prompt.id, .stopCurrentWork, remember: remember)
                    }.accessibilityIdentifier("document.assistant.leave.stop")
                    Button(IDELanguageRunText.t("取消离开", "Stay here"), role: .cancel) {
                        coordinator.choose(requestID: prompt.id, .cancelNavigation)
                    }.accessibilityIdentifier("document.assistant.leave.cancel")
                }
                Section {
                    Toggle(IDELanguageRunText.t("记住选择", "Remember my choice"), isOn: $remember)
                } footer: {
                    Text(IDELanguageRunText.t("可在设置的“文档助手”中更改。已保存的内容和聊天记录会保留。",
                        "Change this later in Settings under Document assistant. Saved content and conversation history are kept."))
                }
            }
            .navigationTitle(IDELanguageRunText.t("离开文档", "Leave document"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled()
    }
}

private struct DocumentAssistantLeavePresentation: ViewModifier {
    @ObservedObject var coordinator: DocumentAssistantLeaveCoordinator
    var enabled: Bool
    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(get: { enabled ? coordinator.prompt : nil }, set: { value in
                if value == nil, enabled, let prompt = coordinator.prompt {
                    coordinator.choose(requestID: prompt.id, .cancelNavigation)
                }
            })) { prompt in
                DocumentAssistantLeaveSheet(coordinator: coordinator, prompt: prompt)
            }
            .overlay(alignment: .bottom) {
                if enabled, coordinator.isStopping {
                    HStack {
                        ProgressView()
                        Text(IDELanguageRunText.t("正在停止当前任务…", "Stopping current work…"))
                    }
                    .padding().background(.regularMaterial, in: Capsule())
                    .padding().accessibilityIdentifier("document.assistant.leave.stopping")
                }
            }
            .alert(IDELanguageRunText.t("任务仍在停止", "Work is still stopping"), isPresented: Binding(
                get: { enabled && coordinator.failure == .stillStopping },
                set: { if !$0 { coordinator.clearFailure() } })) {
                    Button(IDELanguageRunText.t("好", "OK")) { coordinator.clearFailure() }
                } message: {
                    Text(IDELanguageRunText.t("请稍后再试。文档和已保存的修改仍保留。",
                        "Try again shortly. Your document and saved changes are kept."))
                }
    }
}
extension View {
    func documentAssistantLeavePresentation(_ coordinator: DocumentAssistantLeaveCoordinator,
                                            enabled: Bool = true) -> some View {
        modifier(DocumentAssistantLeavePresentation(coordinator: coordinator, enabled: enabled))
    }
}
#endif
