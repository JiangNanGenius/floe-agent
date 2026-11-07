// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI

/// One persisted work conversation; presentation never chooses a read/edit mode.
struct StudioAssistantView: View {
    let record: PersonalContentRecord
    var onClose: (() -> Void)? = nil
    var embedded = false
    var showsMeetingHelp = true
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var conversationID: UUID?
    @State private var diagnostic: String?

    var body: some View {
        Group {
            if embedded {
                assistantContent
            } else {
                NavigationStack {
                    assistantContent
                        .navigationTitle(title + " · " + record.title)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(IDELanguageRunText.t("完成", "Done")) {
                                    if let onClose { onClose() } else { dismiss() }
                                }
                            }
                        }
                }
            }
        }
        .presentationDetents([.large])
        .task { await prepare() }
    }
    private var title: String {
        record.kind == .meeting ? IDELanguageRunText.t("会议助手", "Meeting assistant")
            : IDELanguageRunText.t("作品助手", "Work assistant")
    }
    private var assistantContent: some View {
        VStack(spacing: 0) {
            if record.kind == .meeting && showsMeetingHelp {
                Text(IDELanguageRunText.t("可回答会议问题、整理笔记和待办", "Ask about the meeting or organize notes and to-dos"))
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            }
            Group {
                if let conversationID {
                    ThreadDetailView(conversationID: conversationID, center: environment.conversationCenter,
                        embedded: true, documentAssistant: true, ownsNavigationTitle: false)
                } else if let diagnostic {
                    ContentUnavailableView {
                        Label(IDELanguageRunText.t("助手暂未打开", "Unable to open assistant"), systemImage: "exclamationmark.triangle")
                    } description: { Text(diagnostic) } actions: {
                        Button(IDELanguageRunText.t("重试", "Retry")) { Task { await prepare() } }
                    }
                } else { ProgressView() }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("studio.assistant.content")
    }
    @MainActor private func prepare() async {
        diagnostic = nil
        do {
            let id = try await environment.studioCoordinator.assistant(for: record)
            try Task.checkCancellation()
            conversationID = id
        } catch is CancellationError { }
        catch { diagnostic = error.localizedDescription }
    }
}
#endif
