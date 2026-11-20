// SPDX-License-Identifier: MPL-2.0

import FloeAgentRuntime
import FloeCore
import SwiftUI

/// View-only dismissal identity. A new revision or another conversation is
/// a different card; this value has no plan/Goal persistence or authority.
struct ThreadPlanConfirmationPresentationKey: Hashable {
    let conversationID: UUID
    let planID: UUID
    let revision: Int

    init(_ plan: PlanDraft) {
        conversationID = plan.conversationID
        planID = plan.id
        revision = plan.revision
    }
}

struct ThreadPlanReview: View {
    let plan: PlanDraft
    let isAccepting: Bool
    var actionsDisabled = false
    let onDismiss: () -> Void
    #if FLOE_UNIFIED_MAC && FLOE_MAC_HOST_SMOKE
    var onCloseFrame: ((CGRect) -> Void)? = nil
    var onNormalActionFrame: ((CGRect) -> Void)? = nil
    #endif
    let onExecute: (PlanExecutionRecommendation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Label("plan.title", systemImage: "list.bullet.clipboard").font(.headline)
                Spacer()
                Text(plan.status == .ready
                    ? planReviewText("等待确认", "Awaiting confirmation")
                    : planReviewText("待完善", "In preparation"))
                    .font(.caption).foregroundStyle(.secondary)
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(.body.weight(.medium))
                        .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(planReviewText("关闭计划卡片", "Close plan card"))
                .accessibilityIdentifier("thread.plan.close")
                #if FLOE_UNIFIED_MAC && FLOE_MAC_HOST_SMOKE
                .background(MacWorkbenchButtonFrameReader { frame in onCloseFrame?(frame) })
                #endif
            }
            Text(plan.title).font(.subheadline).lineLimit(2)
            if let recommendation = plan.executionRecommendation {
                Label(
                    recommendation == .goal
                        ? "chat.thread_detail_view.suggest_converting_to_goal"
                        : "chat.thread_detail_view.recommend_normal_execution",
                    systemImage: recommendation == .goal ? "target" : "play.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if let reason = plan.recommendationReason, !reason.isEmpty {
                    Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            DisclosureGroup(planReviewText("计划详情", "Plan details")) {
                ScrollView {
                    ThreadPlanDetails(plan: plan)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 230)
                .textSelection(.enabled)
            }
            if plan.status == .ready && plan.isDecisionComplete {
                HStack {
                    Button("chat.thread_detail_view.execute_on_the_normal_plan") { onExecute(.normal) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("thread.plan.executeNormal")
                        #if FLOE_UNIFIED_MAC && FLOE_MAC_HOST_SMOKE
                        .background(MacWorkbenchButtonFrameReader { frame in onNormalActionFrame?(frame) })
                        #endif
                    Button("chat.thread_detail_view.convert_to_goal") { onExecute(.goal) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("thread.plan.executeGoal")
                    if isAccepting { ProgressView().controlSize(.small) }
                }
                .disabled(isAccepting || actionsDisabled)
            }
        }
        .padding(12)
        .background(FloeTheme.groupedSurface)
        .accessibilityElement(children: .contain)
    }
}

private struct ThreadPlanDetails: View {
    let plan: PlanDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !plan.summary.isEmpty { Text(plan.summary).foregroundStyle(.secondary) }
            ForEach(plan.sections.sorted { $0.order < $1.order }) { section in
                VStack(alignment: .leading, spacing: 4) {
                    Text(section.title).font(.subheadline.weight(.semibold))
                    Text(section.body).font(.subheadline)
                }
            }
            if !plan.acceptanceCriteria.isEmpty {
                Text(planReviewText("验收", "Acceptance")).font(.subheadline.weight(.semibold))
                ForEach(plan.acceptanceCriteria) { criterion in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(criterion.text).font(.subheadline)
                        Text(criterion.verification).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(plan.assumptions) { assumption in
                Label(assumption.text, systemImage: "checkmark.circle").font(.caption)
            }
            ForEach(plan.risks) { risk in
                VStack(alignment: .leading, spacing: 3) {
                    Text(risk.text).font(.caption.weight(.medium))
                    if let mitigation = risk.mitigation { Text(mitigation).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }
}

struct ConfirmedPlanMessageCard: View {
    let snapshot: PlanConfirmationSnapshot
    var onRetryStart: (() -> Void)? = nil
    @State private var expanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: 28)
            VStack(alignment: .leading, spacing: 10) {
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        ThreadPlanDetails(plan: snapshot.plan)
                    }
                    .padding(.top, 8)
                    .textSelection(.enabled)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Label(snapshot.execution == .goal
                            ? planReviewText("已确认计划 · 转为目标", "Plan confirmed · Goal")
                            : planReviewText("已确认计划", "Plan confirmed"),
                              systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        Text(snapshot.plan.title).font(.body.weight(.semibold)).lineLimit(2)
                    }
                }
                if let onRetryStart {
                    Button(action: onRetryStart) {
                        Label(planReviewText("重试启动", "Retry start"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("thread.plan.retryStart")
                }
            }
            .padding(12)
            .frame(maxWidth: 680, alignment: .leading)
            .background(FloeTheme.groupedSurface, in: RoundedRectangle(cornerRadius: 16))
            .accessibilityIdentifier("thread.plan.confirmedHistory")
        }
    }
}

private func planReviewText(_ zh: String, _ en: String) -> String {
    FloeL10n.isChinese ? zh : en
}

struct GoalBuilderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var objective = ""
    @State private var criteria = ""
    @State private var blockers = ""
    @State private var stops = ""
    @State private var isSubmitting = false
    @State private var hasSubmitted = false
    let goal: ConversationGoal?
    let errorMessage: String?
    let onCreate: @MainActor (String, [String], [String], [String]) async -> Bool

    init(goal: ConversationGoal? = nil, errorMessage: String?,
        onCreate: @escaping @MainActor (String, [String], [String], [String]) async -> Bool) {
        self.goal = goal; self.errorMessage = errorMessage; self.onCreate = onCreate
        _objective = State(initialValue: goal?.objective ?? "")
        _criteria = State(initialValue: goal?.acceptanceCriteria.map(\.text).joined(separator: "\n") ?? "")
        _blockers = State(initialValue: goal?.blockingConditions?.joined(separator: "\n") ?? "")
        _stops = State(initialValue: goal?.stoppingConditions?.joined(separator: "\n") ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("chat.thread_detail_view.final_goal") {
                    TextEditor(text: $objective).frame(minHeight: 90)
                }
                Section("chat.thread_detail_view.acceptance_criteria_one_per_line") {
                    TextEditor(text: $criteria).frame(minHeight: 80)
                }
                Section("chat.thread_detail_view.blocking_conditions_one_per_line") {
                    TextEditor(text: $blockers).frame(minHeight: 80)
                }
                Section("chat.thread_detail_view.stop_conditions_one_per_line") {
                    TextEditor(text: $stops).frame(minHeight: 80)
                }
                if goal != nil {
                    Section {
                        Text(planReviewText("保存修改会暂停后续推进，本轮按原目标继续执行。已有进度和结果会保留，可在目标条重新启用后续推进。",
                            "Saving pauses future advancement. This round keeps its original objective. Progress and results are retained; Resume re-enables future advancement."))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if hasSubmitted, let errorMessage {
                    Text(errorMessage).font(.callout).foregroundStyle(.red)
                        .accessibilityIdentifier("goal.builder.error")
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .disabled(isSubmitting)
            .navigationTitle(goal == nil ? String(localized: "chat.thread_detail_view.set_goal") : planReviewText("编辑目标", "Edit goal"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("workspace.workspace_canvas_view.cancel") { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(goal == nil ? String(localized: "chat.thread_detail_view.create_and_start") : String(localized: "workspace.workspace_canvas_view.save")) {
                        isSubmitting = true
                        hasSubmitted = true
                        Task {
                            let created = await onCreate(objective, lines(criteria), lines(blockers), lines(stops))
                            isSubmitting = false
                            if created { dismiss() }
                        }
                    }
                    .disabled(isSubmitting || objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("goal.builder.create")
                }
            }
        }
        .interactiveDismissDisabled(isSubmitting)
    }

    private func lines(_ value: String) -> [String] {
        value.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
