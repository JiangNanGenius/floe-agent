// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI

struct FontDesignAssistantRoute: Identifiable { let id: UUID }

/// The Settings button prepares this real saved task in the service before
/// presentation. Reconstructing this sheet never rebinds or recreates access.
struct FontDesignAssistantView: View {
    let conversationID: UUID
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ThreadDetailView(conversationID: conversationID, center: environment.conversationCenter,
                embedded: true, documentAssistant: true, ownsNavigationTitle: false)
                .navigationTitle(FontDesignText.t("字体助手", "Typeface assistant"))
                .toolbar { ToolbarItem(placement: .confirmationAction) {
                    Button(FontDesignText.t("完成", "Done")) { dismiss() }
                } }
        }.presentationDetents([.large])
    }
}
#endif
