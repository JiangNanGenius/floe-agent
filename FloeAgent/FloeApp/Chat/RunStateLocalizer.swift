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
import FloeAgentRuntime

import FloeCore
/// Static mapping from state machine names (preparing, streamingModel,
/// …) to localized copy, semantic color and the loading flag.
enum RunStateLocalizer {

    /// Empty response content does not imply a model is running: a native
    /// workbench may be preparing its environment or executing a real tool.
    static func responseWaitingTitle(for stateName: String?) -> LocalizedStringKey {
        guard let stateName else { return "chat.reasoning_block_view.waiting_for_the_model" }
        switch stateName {
        case "preparing", "idle", "preparingToolCall", "reconnecting", "committingResults",
             "reviewingApproval", "verifying", "executingTool", "waitingApproval", "compacting", "waitingUser", "waitingUserQuestion", "waitingTool", "cancelling":
            return title(for: stateName)
        default:
            return "chat.reasoning_block_view.waiting_for_the_model"
        }
    }

    /// Localized title for a machine state name (§6.2 mapping table).
    /// Unknown names fall back to the honest "unknown" state instead of
    /// leaking raw machine text into the UI.
    static func title(for stateName: String) -> LocalizedStringKey {
        switch stateName {
        case "preparing", "idle": "state.preparing"
        case "streamingModel": "state.streaming"
        case "preparingToolCall": "state.preparing_tool_call"
        case "reconnecting": "state.reconnecting"
        case "committingResults": "state.committing_results"
        case "reviewingApproval": "chat.run_state_localizer.the_approval_model_is_reviewing"
        case "verifying": "state.verifying"
        case "executingTool": "state.executing_tool"
        case "waitingTool": LocalizedStringKey(FloeL10n.isChinese ? "等待中" : "Waiting")
        case "waitingNativeInput": LocalizedStringKey(FloeL10n.isChinese ? "准备就绪" : "Ready")
        case "waitingApproval": "state.waiting_approval"
        case "compacting": "chat.run_state_localizer.compacting_context"
        case "checkpointed", "paused": "state.paused"
        case "interrupted": LocalizedStringKey(FloeL10n.isChinese ? "已中断" : "Interrupted")
        case "noProgress", "blocked": "chat.run_state_localizer.task_blocked_action_needed"
        case "budgetLimited": "chat.run_state_localizer.the_set_budget_was_reached_you"
        case "truncated": "chat.run_state_localizer.output_unfinished_you_can_continue"
        case "waitingUser", "waitingUserQuestion": "chat.run_state_localizer.waiting_for_your_input"
        case "cancelled": "state.stopped"
        case "cancelling": "state.cancelling"
        case "completed": "state.round_ended"
        case "recoveryFailed": "state.recovery_failed"
        case "failed": "state.failed"
        default: "state.unknown"
        }
    }

    /// Semantic color for a machine state name (§6.2 mapping table).
    static func color(for stateName: String) -> Color {
        switch stateName {
        case "preparing", "idle", "waitingNativeInput", "streamingModel", "preparingToolCall", "reconnecting", "committingResults", "reviewingApproval", "executingTool", "verifying":
            FloeTheme.primary
        case "waitingTool", "waitingApproval", "waitingUser", "waitingUserQuestion", "compacting", "checkpointed", "paused", "interrupted", "blocked", "noProgress", "budgetLimited", "truncated":
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
        case "preparing", "streamingModel", "preparingToolCall", "reconnecting", "committingResults", "reviewingApproval", "executingTool", "cancelling", "compacting", "verifying":
            return true
        default:
            return false
        }
    }

    /// Whether the state name is terminal. `checkpointed` is a durable,
    /// non-running parked state (continue launches a fresh resume task), so
    /// persisted reads must treat it as terminal and stop the running/
    /// waiting affordances instead of leaving the composer in steering-only
    /// mode against a parked run.
    static func isTerminal(_ stateName: String) -> Bool {
        ["completed", "failed", "recoveryFailed", "interrupted", "cancelled", "noProgress", "budgetLimited", "truncated", "checkpointed"].contains(stateName)
    }

    /// A native workbench can hold an authorization run while awaiting input.
    /// Keep that run non-terminal without presenting a model Stop/queue action.
    static func isNonExecutingReady(_ stateName: String, hasLiveOwner: Bool) -> Bool {
        stateName == "waitingNativeInput"
            || (!hasLiveOwner && (stateName == "idle" || stateName == "unknown"))
    }

    static func attentionSymbol(for stateName: String) -> String? {
        switch stateName {
        case "failed", "recoveryFailed": "exclamationmark.circle.fill"
        case "paused": "pause.circle.fill"
        case "waitingUser", "waitingUserQuestion": "questionmark.circle.fill"
        case "waitingApproval": "hand.raised.circle.fill"
        case "interrupted", "checkpointed", "blocked", "noProgress", "budgetLimited", "truncated": "exclamationmark.triangle.fill"
        default: nil
        }
    }

    /// Localized, user-comprehensible title for a terminal stop reason.
    /// Internal wire names (endTurn, maxTokens, …) never reach the UI.
    static func terminalTitle(stopReason: String) -> LocalizedStringKey {
        switch stopReason {
        case "endTurn", "completed", "stop":
            "state.round_ended"
        case "cancelled":
            "state.stopped"
        case "maxTokens", "length":
            "state.truncated"
        case "budgetLimited", "noProgress":"chat.run_state_localizer.task_unfinished_you_can_continue"
        case "toolUse":
            "state.round_ended"
        default:
            "state.unknown"
        }
    }
}

/// A presentation only: it cannot launch/resume a run or grant ownership.
struct ConversationActivityPresentation: Equatable {
    let runID: UUID
    let state: String
    let detail: String?
    let refreshKey: String

    var symbol: String? {
        RunStateLocalizer.attentionSymbol(for: state)
            ?? (state == "completed" ? "checkmark.circle" : state == "waitingTool" ? "clock" : state == "cancelled" ? "stop.circle" : nil)
    }
    var showsTitle: Bool { state != "completed" && symbol != nil }

    static func project(conversationID: UUID, isOrdinary: Bool,
                        snapshot: ConversationActivitySnapshot?, live: RunRecord?) -> Self? {
        guard isOrdinary else { return nil }
        let persisted = snapshot?.conversationID == conversationID ? snapshot?.run : nil
        let live = live?.conversationID == conversationID ? live : nil
        let useLive = live.map { value in
            guard let persisted else { return true }
            return value.id == persisted.id || value.startedAt > persisted.startedAt
                || (value.startedAt == persisted.startedAt && value.id.uuidString < persisted.id.uuidString)
        } ?? false
        guard let id = useLive ? live?.id : persisted?.id,
              var state = useLive ? live?.state : persisted?.state else { return nil }
        // A new live launch never borrows the previous run's error or Goal.
        let bound = persisted?.id == id ? persisted : nil
        if let bound, let live, useLive, bound.endedAt != nil,
           RunStateLocalizer.isTerminal(bound.state), !RunStateLocalizer.isTerminal(live.state), live.state != "preparing" {
            state = bound.state
        }
        if state == "completed" {
            switch bound?.stopReason {
            case "maxTokens", "length": state = "truncated"
            case "noProgress", "budgetLimited": state = bound!.stopReason!
            case "cancelled": state = "cancelled"
            default: break
            }
        }
        // Only this run's explicit goal_id can affect the row. Unrelated
        // historical Goals, including goals.first, have no authority here.
        if bound?.goalStatus == "paused" { state = "paused" }
        else if !["failed", "recoveryFailed", "cancelled", "interrupted"].contains(state),
                let goalState = bound?.goalStatus,
                ["blocked", "noProgress", "budgetLimited", "waitingUser", "waitingApproval", "interrupted"].contains(goalState) {
            state = goalState
        }
        if !RunStateLocalizer.isTerminal(state), state != "paused", bound?.pendingQuestionID != nil {
            state = "waitingUserQuestion"
        }
        if state == "checkpointed", bound?.statusReason?.hasPrefix(FloeAgentRuntime.dependencyWaitReasonPrefix) == true {
            state = "waitingTool" // Existing W11 durable dependency wait, not a user recovery/failure.
        }
        if !["completed", "cancelled", "paused", "waitingTool", "waitingApproval", "waitingUser", "waitingUserQuestion", "checkpointed", "blocked", "noProgress", "budgetLimited", "truncated", "interrupted"].contains(state),
           bound?.signalKind == "error", (!useLive || live?.state == bound?.state) {
            state = "failed"
        }
        let detail: String?
        if ["failed", "recoveryFailed", "interrupted"].contains(state) {
            detail = (bound?.signalMessage ?? bound?.lastError).map {
                String($0.split(whereSeparator: { $0.isNewline }).joined(separator: " ").prefix(500))
            }
        } else { detail = nil }
        let key = "\(id):\(state):\(bound?.eventSequence ?? 0):\(bound?.goalVersion ?? ""):\(bound?.pendingQuestionID ?? ""):\(snapshot?.conversationVersion ?? 0)"
        return .init(runID: id, state: state, detail: detail, refreshKey: key)
    }
}

/// Reads only bounded current-run facts from the existing database reader.
/// No whole-thread subscriptions, polling or parallel notification service.
struct ConversationActivityBadge: View {
    let conversationID: UUID
    @ObservedObject var center: ConversationCenter
    var onOpen: (@MainActor (UUID) -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var snapshot: ConversationActivitySnapshot?
    @State private var ordinaryAuthority = false
    @State private var observationID = UUID()

    private var listedAsOrdinary: Bool {
        center.conversations.first { $0.id == conversationID }?.isVisibleInOrdinaryList == true
    }
    private var liveRun: RunRecord? {
        center.activeRuns.values.filter { $0.conversationID == conversationID }.max {
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            return $0.id.uuidString > $1.id.uuidString
        }
    }
    private var activity: ConversationActivityPresentation? {
        .project(conversationID: conversationID, isOrdinary: listedAsOrdinary && ordinaryAuthority,
                 snapshot: snapshot, live: liveRun)
    }
    private var observationKey: String {
        "\(conversationID):\(listedAsOrdinary):\(scenePhase == .active):\(liveRun?.id.uuidString ?? ""):\(liveRun?.state ?? ""):\(center.goalPresentationRevision)"
    }
    private var openHint: String {
        FloeL10n.isChinese ? "打开对话查看原因、回复或继续" : "Open the conversation for details, to reply or continue"
    }

    var body: some View {
        Group {
            if let activity {
                if let onOpen, activity.showsTitle {
                    Button {
                        guard listedAsOrdinary && ordinaryAuthority else { return }
                        onOpen(activity.runID)
                    } label: {
                        marker(activity).frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                    }
                    .buttonStyle(.borderless)
                        .accessibilityHint(Text(openHint))
                        .help(activity.detail ?? openHint)
                } else { marker(activity) }
            }
        }
        .font(.caption)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: activity?.refreshKey)
        .accessibilityIdentifier("task.status.\(conversationID.uuidString).\(activity?.state ?? "none")")
        .task(id: observationKey) {
            let token = UUID(); observationID = token
            ordinaryAuthority = false; snapshot = nil
            guard listedAsOrdinary, scenePhase == .active else { return }
            do {
                let values = try await ConversationActivityStore(database: center.environment.database)
                    .observation(conversationID: conversationID)
                for try await next in values {
                    guard !Task.isCancelled, observationID == token else { return }
                    // Reuse the canonical predicate, including editorOwnership;
                    // title/workspace/status cannot make a document task ordinary.
                    let record = try await center.environment.conversationStore.conversation(id: conversationID)
                    guard !Task.isCancelled, observationID == token else { return }
                    ordinaryAuthority = record?.isVisibleInOrdinaryList == true
                    snapshot = ordinaryAuthority ? next : nil
                }
            } catch {
                guard observationID == token, !Task.isCancelled else { return }
                ordinaryAuthority = false; snapshot = nil // No run/read proof never leaves an old error/checkmark behind.
            }
        }
    }

    @ViewBuilder private func marker(_ activity: ConversationActivityPresentation) -> some View {
        HStack(spacing: 4) {
            if RunStateLocalizer.isLoading(stateName: activity.state, hasError: false) {
                if reduceMotion { Image(systemName: "hourglass").accessibilityHidden(true) }
                else { ProgressView().controlSize(.mini).accessibilityHidden(true) }
            } else if let symbol = activity.symbol {
                Image(systemName: symbol).accessibilityHidden(true)
                if activity.showsTitle { Text(RunStateLocalizer.title(for: activity.state)).lineLimit(1) }
            }
        }
        .foregroundStyle(RunStateLocalizer.color(for: activity.state))
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(RunStateLocalizer.title(for: activity.state))
                            + Text(activity.detail.map { ": " + $0 } ?? ""))
    }
}
#endif
