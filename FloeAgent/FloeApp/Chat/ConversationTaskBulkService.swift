// FloeApp — Task bulk management service (App layer).
//
// SPDX-License-Identifier: MPL-2.0
//
// Composes the pure `TaskBulkRunner` over the EXISTING single-target task
// lifecycle. Every performed item calls the same public command the single
// row UI calls (`ConversationCenter.archiveConversation` /
// `restoreConversation` / `deleteConversation`); this lane does not add,
// remove or reorder any cancellation step those commands already perform
// (`archiveConversation` cancels live services and awaits their tasks before
// `setArchived`; `deleteConversation` stops owned work through the launch
// fence before the store transaction). Nothing here creates a second store,
// queue or permission system.
//
// The durable row is read as a TRI-STATE before and after each attempted
// command: only a successful read can prove a task exists or is gone. A
// failed read is reported `unverified` — never as success, skip or failure —
// so a database hiccup can neither silently skip a real task nor claim a
// deletion that was not proven.

#if canImport(UIKit)
import Foundation
import FloeCore
import FloePersistence

/// Task-management copy with a parameterized bilingual fallback: the key is
/// looked up in the catalog first (once the integration owner registers it),
/// and until then the exact same EN/ZH sentence is shown inline — a raw
/// dotted key or an internal detail never reaches the list.
enum TaskManagementCopy {
    static var title: String { localized("chat.task_management.title", en: "Manage Tasks", zh: "管理任务") }
    static var tasksFilter: String { localized("chat.task_management.tasks", en: "Tasks", zh: "任务") }
    static var noTasks: String { localized("chat.task_management.no_tasks", en: "No tasks yet", zh: "暂无任务") }
    static var working: String { localized("chat.task_management.working", en: "Working…", zh: "处理中…") }
    static var stopBatch: String { localized("chat.task_management.stop_batch", en: "Stop", zh: "停止") }
    static var cancelledNote: String {
        localized(
            "chat.task_management.cancelled_note",
            en: "Batch stopped. Unprocessed tasks stay selected.",
            zh: "已停止批量操作，未处理的任务保持选中。"
        )
    }
    static var keepFailedSelected: String {
        localized(
            "chat.task_management.keep_failed_selected",
            en: "Failed tasks stay selected so you can retry.",
            zh: "失败的任务会保持选中，可直接重试。"
        )
    }
    static var manageTasks: String { localized("settings.data_management_view.manage_tasks", en: "Manage tasks", zh: "管理任务") }
    static var manageTasksDetail: String {
        localized(
            "settings.data_management_view.manage_tasks_detail",
            en: "Select, archive, restore or delete tasks in bulk",
            zh: "选择、归档、恢复或批量删除任务"
        )
    }
    static var archiveStopsRunningWork: String {
        localized(
            "chat.task_management.archive_stops_running_work",
            en: "Archiving stops the selected tasks' own running work first; they can be restored from the archive later.",
            zh: "归档会先停止所选任务自身正在运行的工作；之后可从归档区恢复。"
        )
    }
    static var deleteStopsRunningWork: String {
        localized(
            "chat.task_management.delete_stops_running_work",
            en: "Deleting stops the selected tasks' own running work first.",
            zh: "删除会先停止所选任务自身正在运行的工作。"
        )
    }
    static var readFailure: String {
        localized(
            "chat.task_management.failure_read",
            en: "Could not read the task state; try again",
            zh: "无法读取任务状态，请重试"
        )
    }

    static func archivedRow(_ count: Int) -> String {
        parameterized("chat.task_management.manage_archived", count) {
            FloeL10n.isChinese ? "管理已归档任务（\(count)）" : "Manage archived tasks (\(count))"
        }
    }

    static func runningImpact(_ count: Int) -> String {
        parameterized("chat.task_management.running_impact", count) {
            FloeL10n.isChinese
                ? "其中 \(count) 个正在运行，会先停止其自身工作。"
                : "\(count) of them are running; their own work is stopped first."
        }
    }

    static func resultArchived(_ count: Int) -> String {
        parameterized("chat.task_management.result_archived", count) {
            FloeL10n.isChinese ? "已归档 \(count)" : "Archived \(count)"
        }
    }

    static func resultRestored(_ count: Int) -> String {
        parameterized("chat.task_management.result_restored", count) {
            FloeL10n.isChinese ? "已恢复 \(count)" : "Restored \(count)"
        }
    }

    static func resultDeleted(_ count: Int) -> String {
        parameterized("chat.task_management.result_deleted", count) {
            FloeL10n.isChinese ? "已删除 \(count)" : "Deleted \(count)"
        }
    }

    static func resultSkipped(_ count: Int) -> String {
        parameterized("chat.task_management.result_skipped", count) {
            FloeL10n.isChinese ? "已跳过 \(count)" : "Skipped \(count)"
        }
    }

    static func resultFailed(_ count: Int) -> String {
        parameterized("chat.task_management.result_failed", count) {
            FloeL10n.isChinese ? "失败 \(count)" : "Failed \(count)"
        }
    }

    static func resultUnverified(_ count: Int) -> String {
        parameterized("chat.task_management.result_unverified", count) {
            FloeL10n.isChinese ? "未确认 \(count)" : "Unverified \(count)"
        }
    }

    static func resultNotAttempted(_ count: Int) -> String {
        parameterized("chat.task_management.result_not_attempted", count) {
            FloeL10n.isChinese ? "未处理 \(count)" : "Not processed \(count)"
        }
    }

    private static func localized(_ key: String, en: String, zh: String) -> String {
        let value = FloeL10n.l(key)
        if value != key { return value }
        return FloeL10n.isChinese ? zh : en
    }

    private static func parameterized(_ key: String, _ argument: Any, fallback: () -> String) -> String {
        guard FloeL10n.l(key) != key else { return fallback() }
        return FloeL10n.l(key, argument)
    }
}

@MainActor
struct ConversationTaskBulkService {
    let center: ConversationCenter

    /// How many of the given tasks have a live owner in the center's
    /// published `activeRuns` projection: a run in preprocessing or with a
    /// concrete runtime service (`registerPreparingRun` /
    /// `ConversationCenter.swift:5173`, cleared on terminal states). This is
    /// a confirmation HINT, not a completeness guarantee — background work
    /// that outlives the run service is not represented here. The UI
    /// therefore never asserts "nothing is running" from a zero count; the
    /// confirmation always states that a selected task's own running work
    /// stops first and only adds the count when it is non-zero.
    func runningCount(among ids: Set<UUID>) -> Int {
        let running = Set(center.activeRuns.values.map(\.conversationID))
        return ids.intersection(running).count
    }

    /// Runs one bulk operation in bounded serial order with per-item results.
    func run(
        operation: TaskBulkOperation,
        items: [TaskBulkItem],
        excluding resolvedIDs: Set<UUID> = [],
        cancellation: TaskBulkCancellationToken? = nil
    ) async -> TaskBulkSummary {
        await TaskBulkRunner().run(
            operation: operation,
            items: items,
            excluding: resolvedIDs,
            cancellation: cancellation
        ) { item in
            await perform(operation: operation, item: item)
        }
    }

    private func perform(operation: TaskBulkOperation, item: TaskBulkItem) async -> TaskBulkItemOutcome {
        let store = center.environment.conversationStore
        let state = await rowState(store: store, id: item.id)
        if let resolved = TaskBulkDecision.preflight(operation: operation, state: state) {
            return resolved
        }
        do {
            switch operation {
            case .archive:
                try await center.archiveConversation(id: item.id)
                return .archived
            case .restore:
                try await center.restoreConversation(id: item.id)
                return .restored
            case .delete:
                try await center.deleteConversation(id: item.id)
                return .deleted
            }
        } catch {
            // The command can throw after the store actually committed (for
            // example during post-commit workspace cleanup). Only a fresh,
            // SUCCESSFUL read is the authority; a failed read must not claim
            // success or failure.
            return TaskBulkDecision.afterFailure(
                operation: operation,
                state: await rowState(store: store, id: item.id),
                errorText: Self.failureText(for: error)
            )
        }
    }

    /// Tri-state durable read: `present` / `missing` / `unreadable`. A read
    /// error is never collapsed into "missing".
    private func rowState(store: any ConversationStore, id: UUID) async -> TaskBulkRowState {
        do {
            guard let record = try await store.conversation(id: id) else { return .missing }
            // Only ordinary tasks are managed here; a document assistant or
            // an ephemeral conversation is never touched from the task list.
            return .present(
                archived: record.archivedAt != nil,
                ordinary: record.purpose == .ordinary
            )
        } catch {
            return .unreadable(TaskManagementCopy.readFailure)
        }
    }

    /// Display-ready failure reason. Internal machine vocabulary (and raw
    /// English error details) never reaches the list; known lifecycle
    /// conflicts get concise bilingual copy and stay retryable.
    static func failureText(for error: Error) -> String {
        if let floe = error as? FloeError {
            switch floe {
            case .cancelled:
                return ChatBilingualCatalog.localized(
                    key: "chat.task_management.failure_stopped",
                    en: "Stopped",
                    zh: "已停止"
                )
            case .notFound:
                return ChatBilingualCatalog.localized(
                    key: "chat.task_management.failure_gone",
                    en: "No longer exists",
                    zh: "已不存在"
                )
            case .validationFailed:
                return ChatBilingualCatalog.localized(
                    key: "chat.task_management.failure_busy",
                    en: "Busy with another change; try again",
                    zh: "正在处理其他操作，请重试"
                )
            default:
                break
            }
        }
        return ChatBilingualCatalog.localized(
            key: "chat.task_management.failure_generic",
            en: "Could not complete; you can retry",
            zh: "未能完成，可重试"
        )
    }
}
#endif
