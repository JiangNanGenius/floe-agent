// FloeApp — More tab view model.
//
// SPDX-License-Identifier: MPL-2.0
//
// Presentation state for the More tab: Runs history, Providers, Settings,
// and Diagnostics. Presentation state only.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloePersistence

/// View model for the More tab.
@MainActor
final class MoreViewModel: ObservableObject {

    /// All runs across conversations, newest first (Runs history).
    @Published private(set) var runs: [RunRecord] = []
    @Published private(set) var isLoading = false

    let center: ConversationCenter

    init(center: ConversationCenter) {
        self.center = center
    }

    var environment: AppEnvironment { center.environment }

    /// Loads the runs history across all conversations.
    func loadRuns() async {
        isLoading = true
        defer { isLoading = false }
        await center.reload()
        var all: [RunRecord] = []
        for conversation in center.conversations {
            let runs = (try? await environment.runStore.runs(conversationID: conversation.id)) ?? []
            all.append(contentsOf: runs)
        }
        runs = all.sorted { $0.startedAt > $1.startedAt }
    }
}
#endif
