// FloeApp — Settings/Data Management one-tap entry for Linux cache cleanup.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

struct LinuxCacheCleanupSettingsSection: View {
    let environment: AppEnvironment
    let conversationCenter: ConversationCenter

    @EnvironmentObject private var router: AppRouter
    @State private var isStarting = false
    @State private var errorMessage: String?

    var body: some View {
        Section {
            Button {
                Task { await begin() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "shippingbox.and.arrow.backward")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(LinuxCacheCleanupText.entryTitle)
                        Text(LinuxCacheCleanupText.entryDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if isStarting { ProgressView() }
                }
                .frame(minHeight: FloeTheme.minimumTarget)
            }
            .disabled(isStarting)
            .accessibilityIdentifier("dataManagement.cleanLinuxCache")

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text(LinuxCacheCleanupText.entryTitle)
        } footer: {
            Text(LinuxCacheCleanupText.sectionFooter)
        }
    }

    private func begin() async {
        guard !isStarting else { return }
        isStarting = true
        errorMessage = nil
        defer { isStarting = false }
        do {
            let result = try await LinuxCacheCleanupEntryPoint.start(
                environment: environment,
                conversationCenter: conversationCenter
            )
            // The conversation and, for the model path, the run were already
            // committed before this call returns. Dismiss Settings first so
            // the ordinary workbench is visible; late callbacks cannot steal
            // focus because router selection points at this exact task.
            router.presentedSettings = false
            router.openConversation(result.conversationID, runID: result.runID)
        } catch {
            errorMessage = LinuxCacheCleanupText.prepareFailed + error.localizedDescription
        }
    }
}
#endif
