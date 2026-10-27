// FloeApp — inline batch management for the Installed skills list (lane file).
//
// SPDX-License-Identifier: MPL-2.0
//
// Pure selection vocabulary, the bounded serial batch engine and the
// bilingual product copy for inline skill management, mirroring the proven
// conversation task-bulk pattern WITHOUT reusing its conversation types.
// One item is one installed SKILL identity. The engine never executes
// anything in parallel, never invents an outcome and never claims success
// from a command acknowledgement: only a fresh, SUCCESSFUL durable store
// read decides present/missing/unreadable, exactly like the task bulk
// tri-state. Execution itself stays inside `SkillsCenter.runSkillBatch`,
// which calls the SAME existing single-target `manageSkill` command (with
// all of its guards: preinstalled rejection, digest CAS, busy fence and
// package backup rollback). This file adds no second store, queue or
// permission path, and MCP servers are a different domain that never enters
// a skill batch.
//
// Copy rule: every user-facing string resolves a catalog key first and falls
// back to the identical inline EN/ZH sentence, so this lane never writes the
// shared localization tables. Proposed catalog keys are listed in the lane
// HANDOFF for the integration owner.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloePersistence
import FloeSkills

// MARK: - Identity policy

/// Preinstalled means a `DomainSkillLibrary` identity, not an arbitrary
/// official-origin download. These guides ship with the app: they can be
/// enabled/disabled but never removed through any path.
enum SkillBatchSelectionPolicy {
    static func isPreinstalled(_ id: String) -> Bool {
        DomainSkillLibrary.all.contains { $0.id == id }
    }
}

// MARK: - Operations and outcomes

/// The user-visible batch action. It never changes the semantics of the
/// existing single-target commands; it only selects how many rows one tap
/// processes.
enum SkillBatchOperation: String, Sendable, Hashable, CaseIterable {
    case enable
    case disable
    case delete
}

/// Why an item was resolved without running the operation.
enum SkillBatchSkipReason: Sendable, Hashable {
    /// The row no longer exists (removed elsewhere, or the selection was
    /// stale); nothing to do and nothing to retry.
    case alreadyGone
    /// The row exists and is already in the operation's target state.
    case alreadyInTargetState
}

/// The real outcome of one submitted item.
enum SkillBatchItemOutcome: Sendable, Hashable {
    case enabled
    case disabled
    case deleted
    case skipped(SkillBatchSkipReason)
    /// Attempted; the operation did not complete. The reason is display-ready
    /// copy (never an internal identifier) and the item stays actionable.
    case failed(String)
    /// Attempted, but the durable state could NOT be proven (the command
    /// failed AND the verification read failed). Never reported as success
    /// or as gone; the item stays actionable for a truthful retry.
    case unverified(String)
    /// The batch stopped before this item ran.
    case notAttempted

    /// A resolved outcome neither needs a retry nor keeps the row selected.
    /// `unverified` is NOT resolved: it may not even have been applied.
    var isResolved: Bool {
        switch self {
        case .enabled, .disabled, .deleted, .skipped: true
        case .failed, .unverified, .notAttempted: false
        }
    }

    /// Display-ready reason for anything the list must show (a failure or an
    /// outcome that could not be verified).
    var issueText: String? {
        switch self {
        case .failed(let text), .unverified(let text): text
        default: nil
        }
    }
}

/// Tri-state durable row read. A FAILED read is deliberately neither
/// "present" nor "gone". The digest is compared against the item's FROZEN
/// selected revision: a mismatch means the package was replaced by another
/// window and the batch must fail honestly instead of acting on it.
enum SkillBatchRowState: Sendable, Hashable {
    case present(enabled: Bool, digest: String)
    case missing
    case unreadable(String)
}

/// One submitted skill row. `expectedDigest` is captured from the ACTUAL
/// selected `PersistedSkill` snapshot at submit time (freeze on click /
/// confirmation) and is the CAS revision every service command runs
/// against: if another window updates or replaces the package while the
/// selection or confirmation dialog is open, the batch reports
/// `changedPackage` instead of silently acting on the replacement.
struct SkillBatchItem: Sendable, Hashable, Identifiable {
    let id: String
    let title: String
    let preinstalled: Bool
    let expectedDigest: String
}

/// One item's result, in submission order.
struct SkillBatchItemResult: Sendable, Hashable, Identifiable {
    let item: SkillBatchItem
    let outcome: SkillBatchItemOutcome
    var id: String { item.id }
}

/// Aggregated outcome of one batch. `removedIDs`/`retainedIDs` drive the
/// selection update: resolved items leave the selection, unresolved items
/// stay selected so a retry picks up exactly where the batch stopped.
/// `runToken` makes every accepted run a distinct identity: an equal
/// second outcome still reconciles the selection (no onChange can be
/// swallowed by value equality).
struct SkillBatchSummary: Sendable, Hashable {
    /// Unique per accepted run — never reused between batches.
    let runToken: UUID
    let operation: SkillBatchOperation
    let results: [SkillBatchItemResult]
    /// True when the batch stopped (cancellation) before every item ran.
    let wasCancelled: Bool

    var isEmpty: Bool { results.isEmpty }
    var enabledCount: Int { count(outcomes: [.enabled]) }
    var disabledCount: Int { count(outcomes: [.disabled]) }
    var deletedCount: Int { count(outcomes: [.deleted]) }
    var succeededCount: Int { enabledCount + disabledCount + deletedCount }
    var skippedCount: Int {
        results.reduce(0) { total, result in
            if case .skipped = result.outcome { return total + 1 }
            return total
        }
    }
    var failedCount: Int {
        results.reduce(0) { total, result in
            if case .failed = result.outcome { return total + 1 }
            return total
        }
    }
    var unverifiedCount: Int {
        results.reduce(0) { total, result in
            if case .unverified = result.outcome { return total + 1 }
            return total
        }
    }
    var notAttemptedCount: Int { count(outcomes: [.notAttempted]) }

    /// Resolved identities: acted on or provably needing no action.
    var removedIDs: Set<String> {
        Set(results.filter { $0.outcome.isResolved }.map(\.item.id))
    }

    /// Unresolved identities: failed, unverified or never attempted. They
    /// stay selected so the next tap retries only these.
    var retainedIDs: Set<String> {
        Set(results.filter { !$0.outcome.isResolved }.map(\.item.id))
    }

    /// Failed and unverified items, in submission order, with their
    /// display-ready reasons.
    var unresolvedItems: [SkillBatchItemResult] {
        results.filter { $0.outcome.issueText != nil }
    }

    private func count(outcomes: Set<SkillBatchItemOutcome>) -> Int {
        results.reduce(0) { total, result in
            outcomes.contains(result.outcome) ? total + 1 : total
        }
    }
}

/// Pure decision table shared by the service and its tests.
enum SkillBatchDecision {
    /// What the initial durable read decides before any command runs.
    /// `nil` means the operation should be attempted with
    /// `item.expectedDigest` as the CAS revision.
    static func preflight(
        operation: SkillBatchOperation,
        item: SkillBatchItem,
        state: SkillBatchRowState
    ) -> SkillBatchItemOutcome? {
        switch state {
        case .missing:
            return .skipped(.alreadyGone)
        case .unreadable(let reason):
            return .unverified(reason)
        case .present(let enabled, let digest):
            // Defense in depth: the UI never offers batch delete for a
            // preinstalled ID; if one arrives anyway, report the honest
            // refusal and keep the row selected and visible.
            if operation == .delete, item.preinstalled {
                return .failed(SkillBatchCopy.preinstalledCannotRemove)
            }
            // Stale UI snapshot: the package was updated/replaced by
            // another window after selection/confirmation. Never act on
            // the replacement; the row stays selected for a fresh retry.
            guard digest == item.expectedDigest else {
                return .failed(SkillBatchCopy.changedPackage)
            }
            switch operation {
            case .enable: return enabled ? .skipped(.alreadyInTargetState) : nil
            case .disable: return enabled ? nil : .skipped(.alreadyInTargetState)
            case .delete: return nil
            }
        }
    }

    /// What the durable read proves after the command returned without
    /// throwing. A success string is not the authority — only a fresh
    /// read of the expected revision may report success.
    static func afterCommand(
        operation: SkillBatchOperation,
        item: SkillBatchItem,
        state: SkillBatchRowState
    ) -> SkillBatchItemOutcome {
        switch state {
        case .missing:
            return operation == .delete ? .deleted : .skipped(.alreadyGone)
        case .unreadable(let reason):
            return .unverified(reason)
        case .present(let enabled, let digest):
            // The CAS-committed command must not change the digest of an
            // enable/disable, and a delete removes the row. Any other
            // readable state means the promised effect did not land on the
            // expected revision, or the package was replaced concurrently.
            guard digest == item.expectedDigest else {
                return .unverified(SkillBatchCopy.changedPackage)
            }
            switch operation {
            case .enable: return enabled ? .enabled : .failed(SkillBatchCopy.notLanded)
            case .disable: return enabled ? .failed(SkillBatchCopy.notLanded) : .disabled
            case .delete: return .failed(SkillBatchCopy.notLanded)
            }
        }
    }

    /// What a fresh durable read proves after the command threw. The error
    /// text is only used when the read proves the operation did not
    /// complete on the expected revision.
    static func afterFailure(
        operation: SkillBatchOperation,
        item: SkillBatchItem,
        state: SkillBatchRowState,
        errorText: String
    ) -> SkillBatchItemOutcome {
        switch state {
        case .missing:
            // The row is provably gone: a delete really completed; an
            // enable/disable target vanished concurrently.
            return operation == .delete ? .deleted : .skipped(.alreadyGone)
        case .unreadable(let reason):
            return .unverified(reason)
        case .present(let enabled, let digest):
            guard digest == item.expectedDigest else {
                return .failed(SkillBatchCopy.changedPackage)
            }
            switch operation {
            case .enable: return enabled ? .enabled : .failed(errorText)
            case .disable: return enabled ? .failed(errorText) : .disabled
            case .delete: return .failed(errorText)
            }
        }
    }
}

/// Bounded serial executor: one skill at a time, in submission order.
/// Duplicate identities are executed exactly once. Cancellation is checked
/// between items only — an in-flight single-target command is never
/// interrupted halfway, so the store can never see a partial transaction.
struct SkillBatchRunner: Sendable {
    typealias Perform = @Sendable (SkillBatchItem) async -> SkillBatchItemOutcome

    func run(
        operation: SkillBatchOperation,
        items: [SkillBatchItem],
        perform: Perform
    ) async -> SkillBatchSummary {
        var seen: Set<String> = []
        var results: [SkillBatchItemResult] = []
        var stopped = false
        for item in items {
            guard seen.insert(item.id).inserted else { continue }
            if stopped || Task.isCancelled {
                stopped = true
                results.append(SkillBatchItemResult(item: item, outcome: .notAttempted))
                continue
            }
            results.append(SkillBatchItemResult(item: item, outcome: await perform(item)))
            if Task.isCancelled { stopped = true }
        }
        return SkillBatchSummary(
            runToken: UUID(), operation: operation, results: results, wasCancelled: stopped
        )
    }
}

// MARK: - Selection model

/// View-side selection state. It only tracks intent; every mutation goes
/// through the durable single-target command, and the summary applies
/// truthful per-item results (resolved leave, failures stay).
struct SkillBatchSelection: Equatable {
    var active = false
    var ids: Set<String> = []

    /// Long press enters selection directly on the row — no menu or sheet.
    mutating func enter(selecting id: String) {
        active = true
        ids.insert(id)
    }

    mutating func toggle(_ id: String) {
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
    }

    func isRowSelected(_ id: String) -> Bool { ids.contains(id) }

    /// Select-all operates on the visible filtered rows only.
    func isEverythingSelected(visible: [String]) -> Bool {
        !visible.isEmpty && Set(visible).isSubset(of: ids)
    }

    mutating func selectAll(visible: [String]) { ids = Set(visible) }
    mutating func deselectAll() { ids = [] }

    /// Search narrows the list, so selections that are no longer visible
    /// leave the batch (they cannot be counted or acted on honestly).
    mutating func prune(toVisible visible: Set<String>) { ids.formIntersection(visible) }

    mutating func exit() {
        active = false
        ids = []
    }

    /// Applies one finished batch: resolved rows leave the selection;
    /// failed, unverified and not-attempted rows stay selected.
    mutating func apply(summary: SkillBatchSummary) {
        ids.subtract(summary.removedIDs)
        ids.formUnion(summary.retainedIDs)
    }
}

// MARK: - Accessibility identity contract (stable; listed in the HANDOFF)

enum SkillsSelectionAccessibility {
    static let selectAll = "skills.selection.select_all"
    static let done = "skills.selection.done"
    static let count = "skills.selection.count"
    static let batchEnable = "skills.batch.enable"
    static let batchDisable = "skills.batch.disable"
    static let batchDelete = "skills.batch.delete"
    static let batchProgress = "skills.batch.progress"
    static func rowCircle(_ id: String) -> String { "skills.select.\(id)" }
    static func rowIssue(_ id: String) -> String { "skills.batch.issue.\(id)" }
}

// MARK: - Bilingual product copy

/// Catalog-first copy with an identical inline EN/ZH fallback, so no shared
/// localization table is written by this lane.
enum SkillBatchCopy {
    static var selectAll: String { localized("skills.selection.select_all", en: "Select All", zh: "全选") }
    static var deselectAll: String { localized("skills.selection.deselect_all", en: "Deselect", zh: "取消全选") }
    static var done: String { localized("skills.selection.done", en: "Done", zh: "完成") }
    static var enable: String { localized("skills.batch.enable", en: "Enable", zh: "启用") }
    static var disable: String { localized("skills.batch.disable", en: "Disable", zh: "停用") }
    static var preinstalledCannotRemove: String {
        localized(
            "skills.batch.preinstalled_cannot_remove",
            en: "Built-in guides come with Floe and can be turned off, not removed.",
            zh: "内置插件随 Floe 提供，可停用但不可删除。"
        )
    }
    static var busy: String {
        localized("skills.batch.busy", en: "Another change is running; try again", zh: "正在处理其他操作，请稍后重试")
    }
    static var readFailure: String {
        localized("skills.batch.failure_read", en: "Could not read the current state; try again", zh: "无法读取当前状态，请重试")
    }
    static var selectRow: String { localized("skills.selection.select_row", en: "Select", zh: "选择") }
    static var deselectRow: String { localized("skills.selection.deselect_row", en: "Deselect", zh: "取消选择") }
    static var builtInTag: String { localized("skills.batch.builtin_tag", en: "Built-in", zh: "内置") }
    static var keepFailedSelected: String {
        localized(
            "skills.batch.keep_failed_selected",
            en: "Failed rows stay selected so you can retry.",
            zh: "失败的项目会保持选中，可直接重试。"
        )
    }
    static var changedPackage: String {
        localized(
            "skills.batch.failure_changed_package",
            en: "This skill changed after you selected it; select it again to retry.",
            zh: "该插件在选择后已更新，请重新选择后重试。"
        )
    }
    static var notLanded: String {
        localized(
            "skills.batch.failure_not_landed",
            en: "The change did not land; you can retry.",
            zh: "改动未生效，可重试。"
        )
    }

    static func selectedCount(_ count: Int) -> String {
        FloeL10n.isChinese ? "已选 \(count)" : "\(count) selected"
    }

    static func deleteButton(_ count: Int) -> String {
        FloeL10n.isChinese ? "删除 \(count)" : "Delete \(count)"
    }

    static func deleteConfirmTitle(_ count: Int) -> String {
        FloeL10n.isChinese
            ? "删除 \(count) 个插件？安装包会保留备份，可在详情中回滚。"
            : "Delete \(count) skill\(count == 1 ? "" : "s")? Package backups stay available for rollback."
    }

    /// Compact truthful result line: only the meaningful segments appear.
    static func resultLine(_ summary: SkillBatchSummary) -> String {
        var parts: [String] = []
        if summary.enabledCount > 0 { parts.append(segment("已启用", "Enabled", summary.enabledCount)) }
        if summary.disabledCount > 0 { parts.append(segment("已停用", "Disabled", summary.disabledCount)) }
        if summary.deletedCount > 0 { parts.append(segment("已删除", "Deleted", summary.deletedCount)) }
        if summary.skippedCount > 0 { parts.append(segment("已跳过", "Skipped", summary.skippedCount)) }
        if summary.failedCount > 0 { parts.append(segment("失败", "Failed", summary.failedCount)) }
        if summary.unverifiedCount > 0 { parts.append(segment("未确认", "Unverified", summary.unverifiedCount)) }
        if summary.notAttemptedCount > 0 { parts.append(segment("未处理", "Not processed", summary.notAttemptedCount)) }
        if parts.isEmpty {
            return FloeL10n.isChinese ? "没有可处理的选择" : "Nothing to process"
        }
        return parts.joined(separator: " · ")
    }

    /// Display-ready failure reason. Internal machine vocabulary never
    /// reaches the list; known conflicts get concise bilingual copy and
    /// stay retryable.
    static func failureText(for error: Error) -> String {
        if error is SkillStoreConflict {
            return localized("skills.batch.failure_changed", en: "Changed or removed; state refreshed", zh: "状态已变化或已移除，已刷新")
        }
        if let floe = error as? FloeError {
            switch floe {
            case .cancelled:
                return localized("skills.batch.failure_stopped", en: "Stopped", zh: "已停止")
            case .notFound:
                return localized("skills.batch.failure_gone", en: "No longer exists", zh: "已不存在")
            case .validationFailed:
                return localized("skills.batch.failure_busy", en: "Busy with another change; try again", zh: "正在处理其他操作，请重试")
            default:
                break
            }
        }
        return localized("skills.batch.failure_generic", en: "Could not complete; you can retry", zh: "未能完成，可重试")
    }

    private static func segment(_ zh: String, _ en: String, _ count: Int) -> String {
        FloeL10n.isChinese ? "\(zh) \(count)" : "\(en) \(count)"
    }

    private static func localized(_ key: String, en: String, zh: String) -> String {
        let value = FloeL10n.l(key)
        if value != key { return value }
        return FloeL10n.isChinese ? zh : en
    }
}

// MARK: - Row selection circle

/// Leading selection circle shown only while selection is active. It is
/// purely decorative; the enclosing Button carries the accessibility
/// identifier/label so the circle stays reachable for XCUITest.
struct SkillSelectionCircle: View {
    let selected: Bool

    var body: some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.title2)
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            .frame(minWidth: 32, minHeight: 32)
            .accessibilityHidden(true)
    }
}
#endif
