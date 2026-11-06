// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI

/// Uses the ordinary persisted task runtime with its own conversation;
/// it never reuses a Notes conversation or a canvas editor's selection.
struct StudioAssistantView: View {
    let record: PersonalContentRecord
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var conversationID: UUID?
    @State private var diagnostic: String?

    var body: some View {
        NavigationStack {
            Group {
                if let conversationID {
                    ThreadDetailView(conversationID: conversationID, center: environment.conversationCenter,
                        embedded: true, documentAssistant: true)
                } else if let diagnostic {
                    ContentUnavailableView {
                        Label(IDELanguageRunText.t("助手暂未打开", "Unable to open assistant"), systemImage: "exclamationmark.triangle")
                    } description: { Text(diagnostic) } actions: {
                        Button(IDELanguageRunText.t("重试", "Retry")) { Task { await prepare() } }
                    }
                } else { ProgressView() }
            }
            .navigationTitle(IDELanguageRunText.t("作品助手", "Work assistant"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(IDELanguageRunText.t("完成", "Done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .task { await prepare() }
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
