// FloeApp — Machine state → localized title / color / loading flag.
//
// SPDX-License-Identifier: MPL-2.0
//
// The ONLY mapping from run state machine names to presentation (see
// ARCHITECTURE §6.2). Views must not interpret state names themselves.
// Rule of record: an `error` event or a `failed` state must immediately
// end the loading state — `isLoading(stateName:hasError:)` is the sole
// decision function.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloePersistence

/// Static mapping from state machine names (preparing, streamingModel,
/// …) to localized copy, semantic color and the loading flag.
enum RunStateLocalizer {

    /// Localized title for a machine state name (§6.2 mapping table).
    /// Unknown names fall back to the honest "unknown" state instead of
    /// leaking raw machine text into the UI.
    static func title(for stateName: String) -> LocalizedStringKey {
        switch stateName {
        case "preparing", "idle": "state.preparing"
        case "streamingModel": "state.streaming"
        case "reconnecting": "state.reconnecting"
        case "committingResults": "state.committing_results"
        case "reviewingApproval": "审批模型正在审核…"
        case "verifying": "state.verifying"
        case "executingTool": "state.executing_tool"
        case "waitingApproval": "state.waiting_approval"
        case "compacting": "正在压缩上下文"
        case "checkpointed", "paused", "interrupted": "state.paused"
        case "noProgress", "blocked": "任务受阻，需处理"
        case "budgetLimited": "已达到所设预算，可继续"
        case "truncated": "输出未完成，可继续"
        case "waitingUser": "等待你的输入"
        case "cancelled": "state.stopped"
        case "cancelling": "state.cancelling"
        case "completed": "state.completed"
        case "recoveryFailed": "state.recovery_failed"
        case "failed": "state.failed"
        default: "state.unknown"
        }
    }

    /// Semantic color for a machine state name (§6.2 mapping table).
    static func color(for stateName: String) -> Color {
        switch stateName {
        case "preparing", "idle", "streamingModel", "reconnecting", "committingResults", "reviewingApproval", "executingTool", "verifying":
            FloeTheme.primary
        case "waitingApproval", "waitingUser", "compacting", "checkpointed", "paused", "interrupted", "blocked", "noProgress", "budgetLimited", "truncated":
            FloeTheme.pending
        case "cancelling", "recoveryFailed", "failed":
            FloeTheme.destructive
        case "completed":
            FloeTheme.success
        default:
            FloeTheme.unknown
        }
    }

    /// Whether the run should present an in-progress affordance.
    ///
    /// Rule (§6.2): any error event or the failed state ends the loading
    /// state immediately; waitingApproval and paused-like states show a
    /// static (non-spinning) affordance; terminal states never load.
    static func isLoading(stateName: String, hasError: Bool) -> Bool {
        if hasError { return false }
        switch stateName {
        case "preparing", "streamingModel", "reconnecting", "committingResults", "reviewingApproval", "executingTool", "cancelling", "compacting", "verifying":
            return true
        default:
            return false
        }
    }

    /// Whether the state name is terminal (completed or failed).
    static func isTerminal(_ stateName: String) -> Bool {
        ["completed", "failed", "recoveryFailed", "interrupted", "cancelled", "noProgress", "budgetLimited", "truncated"].contains(stateName)
    }

    static func attentionSymbol(for stateName: String) -> String? {
        switch stateName {
        case "failed", "recoveryFailed": "exclamationmark.circle.fill"
        case "paused", "interrupted", "checkpointed", "blocked", "noProgress", "budgetLimited", "truncated", "waitingApproval", "waitingUser": "exclamationmark.triangle.fill"
        default: nil
        }
    }

    /// Localized, user-comprehensible title for a terminal stop reason.
    /// Internal wire names (endTurn, maxTokens, …) never reach the UI.
    static func terminalTitle(stopReason: String) -> LocalizedStringKey {
        switch stopReason {
        case "endTurn", "completed", "stop":
            "state.completed"
        case "cancelled":
            "state.stopped"
        case "maxTokens", "length":
            "state.truncated"
        case "budgetLimited", "noProgress":
            "任务未完成，可继续"
        case "toolUse":
            "state.completed"
        default:
            "state.completed"
        }
    }
}

/// Both sidebar and history list observe the run owner directly. AppEnvironment
/// being ObservableObject does not forward changes from its child centers.
struct ConversationActivityBadge: View {
    let conversationID: UUID
    @ObservedObject var center: ConversationCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var persistedState: String?

    private var liveRun: FloePersistence.RunRecord? {
        center.activeRuns.values.filter { $0.conversationID == conversationID }.max { $0.startedAt < $1.startedAt }
    }
    private var state: String? { liveRun?.state ?? persistedState }
    private var refreshKey: String {
        let updated = center.conversations.first { $0.id == conversationID }?.updatedAt.timeIntervalSince1970 ?? 0
        return "\(liveRun?.id.uuidString ?? "idle"):\(updated):\(center.goalPresentationRevision)"
    }

    var body: some View {
        Group {
            if let state {
                if RunStateLocalizer.isLoading(stateName: state, hasError: false) {
                    if reduceMotion { Image(systemName: "hourglass") }
                    else { ProgressView().controlSize(.mini) }
                } else if let symbol = RunStateLocalizer.attentionSymbol(for: state) {
                    Image(systemName: symbol)
                } else if state == "completed" {
                    Image(systemName: "checkmark.circle")
                }
            }
        }
        .font(.caption)
        .foregroundStyle(RunStateLocalizer.color(for: state ?? "unknown"))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: state)
        .accessibilityLabel(Text(RunStateLocalizer.title(for: state ?? "unknown")))
        .accessibilityIdentifier("task.status.\(conversationID.uuidString).\(state ?? "none")")
        .task(id: refreshKey) {
            guard liveRun == nil else { return }
            guard let run = await center.latestRun(conversationID: conversationID) else { return }
            var projected = run.state
            if run.state == "completed",
               let events = try? await center.environment.runStore.recentEvents(runID: run.id, limit: 1),
               let terminal = events.last, terminal.kind == .terminal,
               let payload = try? JSONDecoder().decode([String: String].self, from: Data(terminal.payloadJSON.utf8)),
               let reason = payload["stopReason"], ["noProgress", "budgetLimited", "maxTokens"].contains(reason) {
                projected = reason == "maxTokens" ? "truncated" : reason
            }
            if let goals = try? await center.environment.intelligenceStore.goals(conversationID: conversationID),
               let goal = goals.first {
                if goal.status == .blocked { projected = "blocked" }
                else if goal.status == .budgetLimited { projected = "budgetLimited" }
                else if goal.status == .waitingUser { projected = "waitingUser" }
                else if goal.status == .waitingApproval { projected = "waitingApproval" }
            }
            guard !Task.isCancelled else { return }
            persistedState = projected
        }
    }
}
#endif
