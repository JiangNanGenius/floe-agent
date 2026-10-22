// FloeApp — Terminal cleanup popup for retired schedules (app-wide).
//
// SPDX-License-Identifier: MPL-2.0
//
// The durable cleanup rows (TaskScheduleCleanupReminderStore) already open
// exactly once at a plan's true terminal — permanent delete, a one-shot
// consumed by its own launch, or a stale system fire for a plan that no
// longer exists — including receipts observed while the app was in the
// background. This file owns the PRESENTATION of the honest popup that asks
// the user to clean the associated Shortcut/system automation, attached
// ONCE at the app root so it is reachable on ANY foreground page:
//
//   • the store's GRDB async ValueObservation on the OPEN set is the live
//     trigger (initial value + one per committed change) — no polling, no
//     timers, no system-install detection; a plan ending while the user
//     sits in the foreground surfaces immediately, and re-entering the
//     foreground re-runs one full durable pass so background receipts
//     surface too;
//   • observation starts only after persistenceReady && scene .active, and
//     ends with the surrounding Task otherwise; a durable pass that
//     returns AFTER that cancellation publishes nothing (the GRDB reads
//     can outlive the gate; late results are dropped and the durable rows
//     simply wait for the next gated pass);
//   • the alert's visibility follows the SAME gate: leaving foreground
//     only hides it, and a system/auto dismissal is never recorded as
//     "shown" — only an explicit Open-Shortcuts/Later button tap puts
//     the process mark; the queued event re-presents on the next
//     foreground moment, still exactly once per event;
//   • at most ONE popup on screen; a popup already shown is never swapped
//     or hidden by a later event — only answered, or released when its row
//     stops being open;
//   • "Open Shortcuts" performs the documented URL open and NOTHING else —
//     opening proves nothing, so it never resolves the row;
//   • "Later" only suppresses THIS event for this process; the durable row
//     stays open and fully actionable in the Home cleanup section
//     ("已移除" / "忽略" remain the only resolutions);
//   • the shown-marker is keyed to the event's LIFECYCLE (durable row +
//     that row's persisted monitoring epoch `setup_at`), never to the row
//     id alone: a re-arm updates the SAME row and advances the epoch, so
//     the fresh terminal of a re-armed plan is a new event and is offered
//     again, while duplicate open/stale receipts — which advance only
//     `last_seen_at`/`updated_at` — never re-nag per receipt;
//   • an inline resolution whose durable write succeeded releases that
//     row's process marks (scoped HomeOverviewView callback, presentation
//     only — it claims no deletion), so a later durable event for the
//     same row (a fresh stale fire reopening a `removed` row at its SAME
//     epoch) surfaces fresh instead of inheriting the old round's mark;
//   • there is no auto-delete path at all: no API lets Floe remove a
//     system automation, and the popup never claims otherwise;
//   • a resolved (dismissed/removed) or still-monitoring row is never a
//     popup candidate — silent monitoring and user choices keep their
//     exact store semantics.
//
// The shown-marker is deliberately process-scoped, not a DB write: a
// relaunch may re-offer an unresolved event once (honest re-reminder —
// the row was always still open), while repeated activations inside one
// session never re-nag the SAME lifecycle event.
//
// Attach point (Main-owned, exactly ONE line at the root — the RootView
// body Group):
//
//     .floeScheduleCleanupPopup(environment: environment)

#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI
import UIKit
import Combine
import FloeCore
import FloeModels
import FloePersistence

/// Identity of ONE cleanup event: the durable row plus that row's
/// PERSISTED monitoring epoch (`setup_at`).
///
/// The row id alone cannot separate rounds: `rearm` updates the SAME row
/// and only advances its monitoring epoch, so a re-armed plan's fresh
/// terminal would otherwise inherit the answered round's shown mark and
/// stay silently un-offered for the whole process. Duplicate open/stale
/// receipts advance `last_seen_at`/`updated_at` only — those receipt
/// bookkeeping fields are deliberately NOT part of the identity, so
/// repeated receipts of one event can never re-nag per receipt.
/// `setup_at` is the existing durable lifecycle binding (advanced exactly
/// by an actual handoff `recordSetup`, a re-arm, and a genuinely-live
/// intent observation), so this adds no schema, no counters and no name
/// guessing. A stale-created row has no epoch yet (nil) and keeps it
/// through reopen echoes; an inline resolution releases the row's marks
/// (see the ledger), so such a reopened fresh event stays presentable.
struct TaskScheduleCleanupEventKey: Hashable {
    let rowID: UUID
    let monitoringEpoch: Date?

    init(_ reminder: TaskScheduleCleanupReminder) {
        rowID = reminder.id
        monitoringEpoch = reminder.setupAt
    }
}

/// Pure popup-candidate decision. No view, no store, no system contact.
enum TaskScheduleCleanupPopupPolicy {
    /// The one reminder to present now: among genuinely OPEN rows, the
    /// first event not already shown this process (`reminders` arrives
    /// newest-seen-first from `openReminders`). Monitoring rows can never
    /// be a candidate even if a caller passes them in; an empty or fully
    /// shown set of events presents nothing.
    static func nextReminder(
        open reminders: [TaskScheduleCleanupReminder],
        alreadyShown shown: Set<TaskScheduleCleanupEventKey>
    ) -> TaskScheduleCleanupReminder? {
        reminders.first {
            $0.status == .open && !shown.contains(TaskScheduleCleanupEventKey($0))
        }
    }
}

/// Process-lifetime presentation marks keyed by LIFECYCLE EVENT (see the
/// header: intentionally NOT durable). Tests build their own instance;
/// the UI shares one.
@MainActor
final class TaskScheduleCleanupPopupLedger {
    static let shared = TaskScheduleCleanupPopupLedger()
    private(set) var shownKeys: Set<TaskScheduleCleanupEventKey> = []
    init() {}

    func markShown(_ reminder: TaskScheduleCleanupReminder) {
        shownKeys.insert(TaskScheduleCleanupEventKey(reminder))
    }

    func contains(_ reminder: TaskScheduleCleanupReminder) -> Bool {
        shownKeys.contains(TaskScheduleCleanupEventKey(reminder))
    }

    /// Releases every process-scoped shown mark of ONE durable row.
    /// HomeOverviewView calls this ONLY after the user's inline
    /// "已移除"/"忽略" write succeeded. Presentation only: it deletes
    /// nothing, claims no system-automation removal and writes nothing
    /// durable — the row keeps exactly the status the store write set.
    /// A resolved row is never a popup candidate anyway; what this
    /// restores is FRESHNESS for a genuinely new durable event on the
    /// same row, notably the store-sanctioned case of a new stale fire
    /// reopening a `removed` row at the SAME monitoring epoch.
    func releaseRowSuppressions(rowID: UUID) {
        shownKeys = shownKeys.filter { $0.rowID != rowID }
    }
}

/// One shared bilingual copy source for BOTH cleanup surfaces (the popup
/// and the Home inline rows), so an event never reads differently in one
/// place than the other. Honest by construction: every line asks the USER
/// to act in Shortcuts; nothing claims Floe detected, added or removed a
/// system automation.
enum TaskScheduleCleanupCopy {
    static func title() -> String {
        FloeL10n.isChinese ? "清理系统自动化" : "Clean up the automation"
    }

    static func openShortcuts() -> String {
        FloeL10n.isChinese ? "打开快捷指令" : "Open Shortcuts"
    }

    static func later() -> String {
        FloeL10n.isChinese ? "稍后" : "Later"
    }

    static func removed() -> String {
        FloeL10n.isChinese ? "已移除" : "Removed"
    }

    static func dismiss() -> String {
        FloeL10n.isChinese ? "忽略" : "Dismiss"
    }

    /// One short, actionable bilingual line per retired schedule — the plan's
    /// own name, no IDs, conditional wording because no API detects the
    /// system side.
    static func reason(_ reminder: TaskScheduleCleanupReminder) -> String {
        switch reminder.reason {
        case .deleted:
            return FloeL10n.isChinese
                ? "已删除「\(reminder.title)」。你为它设置过系统自动化，请在快捷指令中删除对应自动化。"
                : "“\(reminder.title)” was deleted. You had set up a system automation for it — remove that automation in Shortcuts."
        case .onceConsumed:
            return FloeL10n.isChinese
                ? "一次性计划「\(reminder.title)」已运行结束，不会再运行。请在快捷指令中删除对应自动化。"
                : "The one-time plan “\(reminder.title)” has finished running and will not fire again. Remove its automation in Shortcuts."
        case .staleTrigger:
            return FloeL10n.isChinese
                ? "「\(reminder.title)」的系统自动化仍在触发已不存在的计划。请在快捷指令中删除它。"
                : "“\(reminder.title)” still fires an automation for a plan that no longer exists. Remove it in Shortcuts."
        case nil:
            return FloeL10n.isChinese
                ? "「\(reminder.title)」可能仍有对应的系统自动化。请在快捷指令中检查并删除。"
                : "A system automation for “\(reminder.title)” may still exist. Check and remove it in Shortcuts."
        }
    }
}

/// The popup's presentation state machine, view-free and store-backed so
/// its behavior is testable without any UI, scene or system contact.
@MainActor
final class TaskScheduleCleanupPopupModel: ObservableObject {
    /// The row currently offered (nil = no popup). Only ever one.
    @Published private(set) var candidate: TaskScheduleCleanupReminder?

    private let store: TaskScheduleCleanupReminderStore
    private let ledger: TaskScheduleCleanupPopupLedger

    init(
        store: TaskScheduleCleanupReminderStore,
        ledger: TaskScheduleCleanupPopupLedger = .shared
    ) {
        self.store = store
        self.ledger = ledger
    }

    /// One durable-truth pass: the crash/lost-write safety net, then the
    /// OPEN set, then the pure policy. A popup already on screen is NOT
    /// swapped or hidden by a newer event — repeated receipts of ONE
    /// lifecycle event dedupe in the store and in the epoch-keyed marks,
    /// while a re-arm that advanced the row's monitoring epoch makes the
    /// NEXT terminal a genuinely new event — and the on-screen popup is
    /// released only when the user answers it or its row stops being
    /// open elsewhere.
    ///
    /// The root `.task(id: popupGate)` can be torn down (scene left
    /// foreground / persistence gate closed) while a GRDB read is still
    /// in flight, and that late read may return AFTER the cancellation.
    /// Cancellation is therefore re-checked AFTER the durable reads and
    /// BEFORE anything is published: an off-gate pass surfaces nothing,
    /// consumes no marks and cannot lose a row — the durable rows stay
    /// exactly where they are and the NEXT gated pass presents them.
    func refresh() async {
        try? await store.reconcileMonitoring()
        let open = (try? await store.openReminders()) ?? []
        if Task.isCancelled { return }
        if let current = candidate,
           open.contains(where: { $0.id == current.id }),
           !ledger.contains(current) {
            return
        }
        candidate = TaskScheduleCleanupPopupPolicy.nextReminder(
            open: open, alreadyShown: ledger.shownKeys)
    }

    /// The gated live pass for the root modifier: starts with one full
    /// durable refresh, then follows GRDB's own async observation of the
    /// OPEN set (initial value + every committed change). Ends when the
    /// surrounding Task is cancelled (scene inactive / persistence not
    /// ready); nothing else retains resources and no observation write or
    /// failure can ever touch schedule lifecycle.
    func runLivePass() async {
        await refresh()
        guard let stream = try? await store.openRemindersObservation()
        else { return }
        do {
            for try await _ in stream {
                await refresh()
                if Task.isCancelled { break }
            }
        } catch {
            // Observation loss cannot drop a durable row: the next gated
            // start runs a full refresh pass again anyway.
        }
    }

    /// THE two explicit popup answers (Open Shortcuts / Later) take this
    /// path — and ONLY they: a system or auto dismissal is never recorded
    /// as shown (see the gated binding). Marks THIS lifecycle event
    /// presented for the process and clears the screen. The durable row
    /// STAYS OPEN either way — only the Home inline "已移除"/"忽略"
    /// resolve it — and the mark is keyed to the row's monitoring epoch,
    /// so a later re-arm + new terminal is a fresh event that this
    /// answer does not silence.
    func markPresented() {
        if let candidate { ledger.markShown(candidate) }
        candidate = nil
    }
}

/// Root-attachable host: the ONE cleanup-popup source for every foreground
/// page. Attached exactly once by Main on the RootView body Group; Home's
/// inline rows intentionally carry no alert anymore.
struct TaskScheduleCleanupPopupModifier: ViewModifier {
    @ObservedObject var environment: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: TaskScheduleCleanupPopupModel

    init(environment: AppEnvironment) {
        self.environment = environment
        _model = StateObject(wrappedValue: TaskScheduleCleanupPopupModel(
            store: TaskScheduleCleanupReminderStore(database: environment.database)))
    }

    /// Observe only on solid ground: migrated storage AND a real foreground
    /// scene. Backgrounded/cold-inactive moments never consume a popup the
    /// user could not see; the durable rows simply wait for this gate.
    private var popupGate: Bool {
        environment.persistenceReady && scenePhase == .active
    }

    /// The alert follows the SAME gate as the live pass: its visible
    /// truth is "foreground gate open AND a candidate is queued". A
    /// background/transient scene change therefore only HIDES the alert —
    /// the candidate and its durable open row survive, and the next
    /// foreground moment re-offers them (still exactly once per event).
    /// The setter deliberately CONFIRMS NOTHING: a system/auto dismissal
    /// is never recorded as "already shown" (a backgrounded or
    /// interrupted user has not answered). Only the two real button
    /// actions below record the process mark. When the row is genuinely
    /// resolved elsewhere, the normal gated pass clears the candidate and
    /// the alert disappears naturally — no extra timers or observers.
    private var popupBinding: Binding<Bool> {
        Binding(
            get: { popupGate && model.candidate != nil },
            set: { _ in }
        )
    }

    func body(content: Content) -> some View {
        content
            .task(id: popupGate) {
                if popupGate {
                    await model.runLivePass()
                }
            }
            .alert(TaskScheduleCleanupCopy.title(), isPresented: popupBinding) {
                Button(TaskScheduleCleanupCopy.openShortcuts()) {
                    model.markPresented()
                    // Honest: opening Shortcuts proves nothing, so the
                    // durable row stays open for the inline resolutions.
                    // There is no auto-delete: no API lets Floe remove a
                    // system automation.
                    UIApplication.shared.open(
                        TaskScheduleShortcutImport.shortcutsAppURL)
                }
                Button(TaskScheduleCleanupCopy.later(), role: .cancel) {
                    model.markPresented()
                }
            } message: {
                if let candidate = model.candidate {
                    Text(TaskScheduleCleanupCopy.reason(candidate))
                }
            }
    }
}

extension View {
    /// THE single-line integration interface: attach once at the app root.
    /// ```swift
    /// .floeScheduleCleanupPopup(environment: environment)
    /// ```
    func floeScheduleCleanupPopup(environment: AppEnvironment) -> some View {
        modifier(TaskScheduleCleanupPopupModifier(environment: environment))
    }
}
#endif
