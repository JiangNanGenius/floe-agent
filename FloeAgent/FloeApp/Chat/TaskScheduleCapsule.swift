// FloeApp — linked-schedule pill and shared schedule presentation.
//
// SPDX-License-Identifier: MPL-2.0
//
// The pill appears under a conversation's navigation bar ONLY when a plan is
// genuinely linked to that conversation: by its trusted `originConversationID`
// or by an occurrence whose real `conversation_id` is this chat. A title never
// decides linkage, and an unbound/pre-v57 plan stays invisible here. The pill
// is replaced by the in-chat find bar while find is active, so the thread never
// stacks two top rows.
//
// Every value is durable truth: the nearest real `nextExpectedAt`, the
// automatic run ordinal derived from ACTUAL started automatic occurrences
// (explicit manual runs excluded), and the count of other linked plans. A
// paused plan reads "Paused"; an after-success plan reads "Waiting for upstream
// run" instead of inventing a countdown.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloeModels
import FloePersistence

// MARK: - Presentation model

struct TaskScheduleLinkedSummary: Identifiable, Equatable {
    let id: UUID
    var title: String
    var isEnabled: Bool
    var cadence: TaskScheduleCadence
    var nextExpectedAt: Date?
    /// Automatic occurrences that ACTUALLY started (explicit manual Run-now
    /// rows excluded). The next automatic run is `automaticRunsStarted + 1`.
    var automaticRunsStarted: Int
    var originConversationID: UUID?

    var isEventDriven: Bool { cadence == .afterSuccess }
    var automaticOrdinal: Int { automaticRunsStarted + 1 }
}

struct TaskScheduleCapsuleState: Equatable {
    var scheduleID: UUID
    var title: String
    var isEnabled: Bool
    var isEventDriven: Bool
    var nextRun: Date?
    var automaticOrdinal: Int
    /// Other plans linked to the same conversation (never extra pills).
    var otherLinkedCount: Int
}

enum TaskSchedulePresentation {
    static func summaries(
        records: [TaskScheduleRecord],
        automaticStartedCounts: [UUID: Int]
    ) -> [TaskScheduleLinkedSummary] {
        records.map { record in
            TaskScheduleLinkedSummary(
                id: record.id,
                title: record.title,
                isEnabled: record.isEnabled,
                cadence: record.cadence,
                nextExpectedAt: record.nextExpectedAt,
                automaticRunsStarted: automaticStartedCounts[record.id] ?? 0,
                originConversationID: record.originConversationID
            )
        }
    }

    /// The one pill for a conversation. Prefers the nearest enabled clocked
    /// plan; falls back to an enabled event-driven plan, then to the most
    /// recently edited paused/disabled plan so its detail stays reachable
    /// without pretending it will run.
    static func capsule(
        from summaries: [TaskScheduleLinkedSummary],
        now: Date
    ) -> TaskScheduleCapsuleState? {
        guard !summaries.isEmpty else { return nil }
        let enabled = summaries.filter(\.isEnabled)
        let clocked = enabled
            .filter { !$0.isEventDriven && $0.nextExpectedAt != nil }
            .sorted { lhs, rhs in
                guard let left = lhs.nextExpectedAt, let right = rhs.nextExpectedAt else {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                if left != right { return left < right }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        let chosen = clocked.first
            ?? enabled.first(where: \.isEventDriven)
            ?? summaries.first
        guard let chosen else { return nil }
        return TaskScheduleCapsuleState(
            scheduleID: chosen.id,
            title: chosen.title,
            isEnabled: chosen.isEnabled,
            isEventDriven: chosen.isEventDriven,
            nextRun: chosen.isEventDriven ? nil : chosen.nextExpectedAt,
            automaticOrdinal: chosen.automaticOrdinal,
            otherLinkedCount: max(0, summaries.count - 1)
        )
    }

    /// Ordinal per started AUTOMATIC occurrence, using the real total (not
    /// just the rows a UI history query returned): the newest started
    /// automatic row is `totalStarted`, older ones count down. Manual and
    /// not-yet-started rows get no entry.
    static func automaticOrdinals(
        occurrences: [TaskScheduleOccurrence],
        totalStartedAutomatic: Int
    ) -> [UUID: Int] {
        let started = occurrences
            .filter { $0.isAutomatic && $0.startedAt != nil }
            .sorted { lhs, rhs in
                let left = lhs.startedAt ?? lhs.scheduledFor
                let right = rhs.startedAt ?? rhs.scheduledFor
                if left != right { return left < right }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        var result: [UUID: Int] = [:]
        var ordinal = max(started.count, totalStartedAutomatic)
        for occurrence in started.reversed() {
            result[occurrence.id] = ordinal
            ordinal -= 1
        }
        return result
    }

    /// A manual occurrence is always labeled as manual and never given an
    /// automatic ordinal; an automatic row is numbered from its own position
    /// in the chronological automatic sequence the caller computed.
    static func occurrenceLabel(
        _ occurrence: TaskScheduleOccurrence,
        automaticOrdinal: Int? = nil
    ) -> String {
        if occurrence.isManualRun {
            return ScheduleCopy.localized(
                "schedule.occurrence.manual", zh: "手动运行", en: "Manual run")
        }
        if let automaticOrdinal, automaticOrdinal > 0 {
            return ScheduleCopy.localized(
                "schedule.occurrence.automatic",
                zh: "自动第 \(automaticOrdinal) 次",
                en: "Automatic run \(automaticOrdinal)"
            )
        }
        return ScheduleCopy.localized(
            "schedule.occurrence.automatic_run", zh: "自动运行", en: "Automatic run")
    }
}

enum ScheduleCopy {
    static func localized(_ key: String, zh: String, en: String) -> String {
        ChatBilingualCatalog.localized(key: key, en: en, zh: zh)
    }

    static var paused: String {
        localized("schedule.status.paused", zh: "已暂停", en: "Paused")
    }
    static var active: String {
        localized("schedule.status.active", zh: "已启用", en: "Active")
    }
    static var waitingUpstream: String {
        localized(
            "schedule.status.waiting_upstream",
            zh: "等待上游任务成功",
            en: "Waiting for upstream run"
        )
    }
    static var noNextRun: String {
        localized("schedule.status.no_next_run", zh: "没有下次运行", en: "No next run")
    }
    static var dueNow: String {
        localized("schedule.status.due_now", zh: "即将运行", en: "Due now")
    }
    static func nextRun(_ date: Date) -> String {
        localized(
            "schedule.next_run",
            zh: "下次 \(date.formatted(date: .abbreviated, time: .shortened))",
            en: "Next \(date.formatted(date: .abbreviated, time: .shortened))"
        )
    }
    static func ordinal(_ value: Int) -> String {
        localized("schedule.ordinal", zh: "自动第 \(value) 次", en: "Automatic run \(value)")
    }
    static func completedRuns(_ value: Int) -> String {
        localized("schedule.completed_runs", zh: "已完成 \(value) 次", en: "Automatic runs \(value)")
    }
    static func others(_ count: Int) -> String {
        localized("schedule.others", zh: "另有 \(count) 个计划", en: "\(count) more scheduled")
    }
    static var runNow: String {
        localized("schedule.action.run_now", zh: "立即运行", en: "Run now")
    }
    static var skipNext: String {
        localized("schedule.action.skip_next", zh: "跳过下一次", en: "Skip next")
    }
    static var cancelFuture: String {
        localized("schedule.action.cancel_future", zh: "取消后续运行", en: "Cancel future runs")
    }
    static var edit: String {
        localized("schedule.action.edit", zh: "编辑", en: "Edit")
    }
    static var detail: String {
        localized("schedule.action.detail", zh: "计划详情", en: "Plan details")
    }
    static var history: String {
        localized("schedule.history", zh: "执行历史", en: "Run history")
    }
    static var prompt: String {
        localized("schedule.prompt", zh: "任务内容", en: "Task")
    }
    static var timing: String {
        localized("schedule.timing", zh: "时间", en: "Timing")
    }
    static var bindings: String {
        localized("schedule.bindings", zh: "绑定", en: "Bindings")
    }
    static var timezone: String {
        localized("schedule.timezone", zh: "时区", en: "Time zone")
    }
    static var notLinked: String {
        localized("schedule.not_linked", zh: "未关联对话", en: "Not linked to a chat")
    }
    static var linkedChat: String {
        localized("schedule.linked_chat", zh: "来自此对话", en: "Linked to this chat")
    }
    static var cancelFutureNote: String {
        localized(
            "schedule.cancel_future.note",
            zh: "将停止后续自动运行并保留记录与历史。正在运行的任务请用它自己的停止按钮。",
            en: "Stops future automatic runs and keeps the record and history. A running task keeps its own Stop."
        )
    }
    static func cadence(_ record: TaskScheduleRecord) -> String {
        switch record.cadence {
        case .once:
            return localized("schedule.cadence.once", zh: "一次", en: "One time")
        case .daily:
            return localized("schedule.cadence.daily", zh: "每天", en: "Daily")
        case .weekly:
            return localized("schedule.cadence.weekly", zh: "每周", en: "Weekly")
        case .interval:
            let seconds = max(60, record.intervalSeconds ?? 3_600)
            if seconds % 3_600 == 0 {
                let hours = seconds / 3_600
                return localized(
                    "schedule.cadence.hours", zh: "每 \(hours) 小时", en: "Every \(hours) hours")
            }
            let minutes = max(1, seconds / 60)
            return localized(
                "schedule.cadence.minutes", zh: "每 \(minutes) 分钟", en: "Every \(minutes) minutes")
        case .afterSuccess:
            return localized(
                "schedule.cadence.after_success",
                zh: "上游成功之后", en: "After a successful run")
        }
    }
    static func occurrenceState(_ state: TaskScheduleOccurrenceState) -> String {
        switch state {
        case .pending:
            return localized("schedule.state.pending", zh: "待执行", en: "Pending")
        case .claimed, .running:
            return localized("schedule.state.running", zh: "运行中", en: "Running")
        case .completed:
            return localized("schedule.state.completed", zh: "已完成", en: "Completed")
        case .failed:
            return localized("schedule.state.failed", zh: "失败", en: "Failed")
        case .cancelled:
            return localized("schedule.state.cancelled", zh: "已取消", en: "Cancelled")
        case .skipped:
            return localized("schedule.state.skipped", zh: "已跳过", en: "Skipped")
        case .interrupted:
            return localized("schedule.state.interrupted", zh: "已中断", en: "Interrupted")
        }
    }
}

/// Identifies the one schedule detail sheet opened from a chat pill or the
/// task center.
struct ScheduleDetailRequest: Identifiable, Equatable {
    let id = UUID()
    let scheduleID: UUID
}

// MARK: - Shared commands (real store / real coordinator; no second executor)

@MainActor
enum TaskScheduleCommands {
    /// Explicit extra execution through the coordinator's shared
    /// claim→revalidate→launch→receipt route. It never advances the planned
    /// next run (the store records a manual start).
    static func runNow(
        scheduleID: UUID,
        environment: AppEnvironment
    ) async throws -> BackgroundRunCoordinator.FloeSelectedScheduleRunReceipt {
        try await environment.backgroundRunCoordinator.runScheduleNow(scheduleID: scheduleID)
    }

    static func skipNext(
        scheduleID: UUID,
        environment: AppEnvironment
    ) async throws -> TaskScheduleSkipResult? {
        let store = SQLiteTaskScheduleStore(database: environment.database)
        let result = try await store.skipNext(id: scheduleID, at: Date())
        // Reconcile the shared reminder/Live-Activity projection through the
        // ordinary pass. Skipping launches nothing.
        await environment.backgroundRunCoordinator.runDueSchedulesNow()
        return result
    }

    /// "Cancel future runs" is a PAUSE with history retained: the durable
    /// record stays, pending instances are cancelled by the store, and the
    /// currently running task keeps its own Stop.
    static func cancelFuture(
        scheduleID: UUID,
        environment: AppEnvironment
    ) async throws {
        let store = SQLiteTaskScheduleStore(database: environment.database)
        try await store.setEnabled(id: scheduleID, enabled: false, at: Date())
        await environment.backgroundRunCoordinator.runDueSchedulesNow()
    }
}

// MARK: - Pill

struct TaskScheduleCapsuleView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var router: AppRouter
    let state: TaskScheduleCapsuleState
    let onOpenDetail: () -> Void
    let onChanged: () -> Void

    @State private var busy = false
    @State private var failure: String?

    var body: some View {
        Button(action: onOpenDetail) {
            HStack(spacing: 8) {
                Image(systemName: state.isEnabled ? "calendar.badge.clock" : "calendar.badge.minus")
                    .font(.subheadline)
                    .foregroundStyle(state.isEnabled ? FloeTheme.primary : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(state.title)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        if !state.isEnabled {
                            Text(ScheduleCopy.paused)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    timelineLine
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if state.otherLinkedCount > 0 {
                    Text("+\(state.otherLinkedCount)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(ScheduleCopy.others(state.otherLinkedCount))
                }
                if busy { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(FloeTheme.groupedSurface)
        .accessibilityIdentifier("thread.scheduleCapsule")
        .accessibilityHint(ScheduleCopy.detail)
        .contextMenu { menuItems }
        .alert("chat.conversation_list_view.action_failed", isPresented: Binding(
            get: { failure != nil },
            set: { if !$0 { failure = nil } }
        )) {
            Button("workspace.office_document_editor_view.ok", role: .cancel) { failure = nil }
        } message: {
            Text(failure ?? "")
        }
    }

    @ViewBuilder
    private var timelineLine: some View {
        if !state.isEnabled {
            Text(ScheduleCopy.noNextRun)
        } else if state.isEventDriven {
            Text(ScheduleCopy.waitingUpstream)
        } else if let next = state.nextRun {
            HStack(spacing: 5) {
                if next > Date() {
                    // System-driven countdown; no timer, database poll or
                    // keep-alive loop exists for this line.
                    Text(timerInterval: Date()...next, countsDown: true)
                        .monospacedDigit()
                    Text("·")
                    Text(ScheduleCopy.ordinal(state.automaticOrdinal))
                } else {
                    Text(ScheduleCopy.dueNow)
                    Text("·")
                    Text(ScheduleCopy.ordinal(state.automaticOrdinal))
                }
            }
        } else {
            Text(ScheduleCopy.noNextRun)
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        Button {
            perform {
                let receipt = try await TaskScheduleCommands.runNow(
                    scheduleID: state.scheduleID, environment: environment)
                router.openConversation(receipt.conversationID, runID: receipt.runID)
            }
        } label: {
            Label(ScheduleCopy.runNow, systemImage: "play.circle")
        }
        .disabled(!state.isEnabled || busy)
        if !state.isEventDriven {
            Button {
                perform { _ = try await TaskScheduleCommands.skipNext(
                    scheduleID: state.scheduleID, environment: environment) }
            } label: {
                Label(ScheduleCopy.skipNext, systemImage: "forward.end")
            }
            .disabled(!state.isEnabled || busy)
        }
        Button(role: .destructive) {
            perform { try await TaskScheduleCommands.cancelFuture(
                scheduleID: state.scheduleID, environment: environment) }
        } label: {
            Label(ScheduleCopy.cancelFuture, systemImage: "pause.circle")
        }
        .disabled(!state.isEnabled || busy)
        Button {
            onOpenDetail()
        } label: {
            Label(ScheduleCopy.detail, systemImage: "info.circle")
        }
    }

    private func perform(_ work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return } // double-tap fence in addition to the durable claim
        busy = true
        Task {
            defer { busy = false }
            do {
                try await work()
                onChanged()
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
#endif
