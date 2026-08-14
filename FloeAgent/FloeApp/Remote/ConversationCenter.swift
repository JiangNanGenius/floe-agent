// FloeApp — Conversation coordinator (app-level seam).
//
// SPDX-License-Identifier: MPL-2.0
//
// Owns the conversation list and, eventually (T02), live
// ConversationRunService instances keyed by run. Views bind only to this
// center, never to stores or runtimes directly. T01 ships the compile-clean
// shell; T02 fills in run orchestration, approvals, retry and model switch.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeModels
import FloePersistence

/// Coordinates conversations and agent runs for the UI layer.
@MainActor
final class ConversationCenter: ObservableObject {

    /// Conversations in deterministic recency order. Empty until T02 wires
    /// loading from `ConversationStore`.
    @Published private(set) var conversations: [ConversationRecord] = []

    /// Live runs keyed by run ID. Populated by T02.
    @Published private(set) var activeRuns: [UUID: RunRecord] = [:]

    let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }
}
#endif
