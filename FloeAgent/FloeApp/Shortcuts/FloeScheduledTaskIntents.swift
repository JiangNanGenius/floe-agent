// FloeApp — S4 selected-schedule system automation.
//
// A Shortcuts personal automation (Time of Day, etc.) can run ONE EXISTING
// Floe schedule by picking it in the "Run Scheduled Task" action. The action
// routes through the same durable occurrence claim/launch/bind path as the
// app's background scheduler (BackgroundRunCoordinator.runSelectedSchedule)
// and returns the SAME typed exact-run reference the Start/Status/Wait/Text/
// Files/Cancel actions accept — never a separate unbound Start(prompt), a
// random manual instance, or a success string that hides a store failure.
//
// The picked-entity route is the ONLY identity route, on purpose: a shared
// signed template personalizes this action through the same REQUIRED
// `Schedule` entity parameter, chosen once in the system Shortcuts editor
// (the shipped template carries no import question: the iPadOS 27 importer's
// question-completion path could not commit, while the editor binding is
// measured to persist), so the recipient always names the concrete plan.
// A name/title text route could silently re-point an old imported trigger
// at a different same-title plan after the original was deleted or renamed
// — never a stable identity substitute.
//
// When the action fires for a schedule the durable store can no longer
// find, the deleted refusal is unchanged AND best-effort durable cleanup
// evidence is recorded under the ORIGINAL stable UUID for the still-
// lingering system automation. When it fires for a schedule the store CAN
// still find, the production runner best-effort OBSERVES that genuine
// system fire so an existing plan whose Shortcut was saved outside the
// app (284 / manual) gains silent monitoring before the launch — a later
// real terminal or delete can then open its cleanup reminder. Reminders
// cannot start, arm or re-enable anything.

#if canImport(AppIntents)
import AppIntents
import Foundation
import FloeCore
import FloeModels
import FloePersistence

// File-local aliases for the coordinator's typed receipt/failure. They stay
// internal (NOT private): `FloeScheduledTaskRunner.run` and the DEBUG
// `@TaskLocal debugRoute` are internal declarations whose signatures use
// these aliases, and an internal signature cannot reference a private
// typealias.
typealias SelectedScheduleReceipt = BackgroundRunCoordinator.FloeSelectedScheduleRunReceipt
typealias SelectedScheduleFailure = BackgroundRunCoordinator.FloeSelectedScheduleFailure

/// Narrow system-facing projection of one Floe schedule: stable ID + title
/// only. The prompt, frozen model/environment bindings and any secrets never
/// leave the app through this entity.
struct TaskScheduleEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "shortcuts.schedule.entity.type")
    static let defaultQuery = TaskScheduleEntityQuery()

    @Property(title: "shortcuts.schedule.property.id") var id: String
    @Property(title: "shortcuts.schedule.property.title") var title: String

    var displayRepresentation: DisplayRepresentation {
        // Title only in the normal picker/summary surface; the stable ID
        // stays an internal entity property and never a displayed subtitle.
        .init(title: "\(title)")
    }

    init(id: UUID, title: String) {
        self.id = id.uuidString
        self.title = title
    }
}

struct TaskScheduleEntityQuery: EntityQuery {
    @AppDependency private var environment: AppEnvironment

    #if DEBUG
    /// Task-scoped by one hosted test; there is deliberately no
    /// process-global install path. Compiled out of Release.
    @TaskLocal static var debugEnvironment: AppEnvironment?
    #endif

    @MainActor
    private func resolvedEnvironment() -> AppEnvironment {
        #if DEBUG
        if let debugEnvironment = Self.debugEnvironment { return debugEnvironment }
        #endif
        return environment
    }

    @MainActor
    func entities(for identifiers: [String]) async throws -> [TaskScheduleEntity] {
        // Rehydrate only explicitly supplied schedule identities from the
        // durable store. A query never substitutes another schedule, never
        // invents one and never starts anything. A storage failure is thrown
        // (honest unavailability); only a real not-found is treated as
        // absent. A malformed identifier is not an identity at all.
        let store = SQLiteTaskScheduleStore(database: resolvedEnvironment().database)
        var result: [TaskScheduleEntity] = []
        for identifier in identifiers {
            guard let id = UUID(uuidString: identifier) else { continue }
            let record: TaskScheduleRecord?
            do {
                record = try await store.schedule(id: id)
            } catch {
                throw SelectedScheduleFailure.storageUnavailable.actionError
            }
            guard let record else { continue }
            result.append(TaskScheduleEntity(id: record.id, title: record.title))
        }
        return result
    }

    @MainActor
    func suggestedEntities() async throws -> [TaskScheduleEntity] {
        // Picker discovery: the existing ENABLED schedules, title-only
        // display with the stable ID as an internal property. A disabled
        // schedule resolves through `entities(for:)` and the intent then
        // reports it honestly as turned off. A storage failure is thrown,
        // never an empty list that pretends "no schedules".
        let store = SQLiteTaskScheduleStore(database: resolvedEnvironment().database)
        let records: [TaskScheduleRecord]
        do {
            records = try await store.schedules()
        } catch {
            throw SelectedScheduleFailure.storageUnavailable.actionError
        }
        return records.filter(\.isEnabled).prefix(20).map {
            TaskScheduleEntity(id: $0.id, title: $0.title)
        }
    }
}

/// Production route for the selected-schedule action: the same capability
/// gate as the legacy Schedule action (Shortcuts AND Automation), then the
/// shared external-automation readiness, then a BEST-EFFORT observation of
/// this genuine system fire (silent monitoring only — see
/// `FloeScheduledTaskInvocationObservation`), then the coordinator's single
/// durable claim/launch/bind path. No second environment or scheduler.
@MainActor
enum FloeScheduledTaskRunner {
    static func run(
        scheduleID: UUID, environment: AppEnvironment
    ) async throws -> SelectedScheduleReceipt {
        guard AppleCapabilityPreferences.isEnabled(.shortcuts),
              AppleCapabilityPreferences.isEnabled(.automation) else {
            throw FloeShortcutActionError(
                FloeL10n.l("shortcuts.schedule.run.error.disabled"))
        }
        try await environment.ensureReadyForExternalAutomation()
        try Task.checkCancellation()
        // A real system firing of this action for a plan the durable store
        // still finds is DIRECT evidence that its automation may remain —
        // even when the app UI handoff was never recorded (284 / manually
        // saved Shortcuts). One idempotent durable monitoring write, placed
        // strictly after the existing gates and BEFORE the core launch, so
        // this very round's imminent terminal is observable. It can never
        // block, roll back, cancel or re-arm the launch: every failure is
        // swallowed here and the coordinator below behaves exactly as
        // before. Never wired to the DEBUG `debugRoute` fake-receipt tests,
        // discovery/query, or the background coordinator's ordinary pass.
        await FloeScheduledTaskInvocationObservation.observe(
            store: TaskScheduleCleanupReminderStore(database: environment.database),
            scheduleID: scheduleID,
            at: Date())
        try Task.checkCancellation()
        return try await environment.backgroundRunCoordinator
            .runSelectedSchedule(scheduleID: scheduleID)
    }
}

/// The production runner's observation seam. It takes the durable store so
/// hosted tests can inject their OWN temporary database and prove the
/// swallow contract without any AppEnvironment, real defaults, system
/// prompts or launches. DEBUG `debugRoute` fake receipts bypass the runner
/// entirely, so the existing hosted failure-copy tests keep their zero side
/// effects.
@MainActor
enum FloeScheduledTaskInvocationObservation {
    /// Optional observation: `try?` is the whole point — a cleanup-evidence
    /// failure may NEVER change the core launch it precedes. No schedule
    /// row, occurrence or claim is written here; the durable store decides
    /// eligibility from its own read-only inspection and stays idempotent
    /// (an existing monitoring epoch is never reset, no open reminder is
    /// hidden, no resolved marker is re-nagged without a genuinely live
    /// current round).
    static func observe(
        store: TaskScheduleCleanupReminderStore,
        scheduleID: UUID,
        at date: Date
    ) async {
        try? await store.observeIntentInvocation(scheduleID: scheduleID, at: date)
    }
}

extension BackgroundRunCoordinator.FloeSelectedScheduleFailure {
    /// Concise bilingual copy for each honest refusal. Internal identifiers
    /// and store detail never reach the user.
    var actionError: FloeShortcutActionError {
        switch self {
        case .scheduleDeleted:
            FloeShortcutActionError(FloeL10n.l("shortcuts.schedule.run.error.not_found"))
        case .scheduleDisabled:
            FloeShortcutActionError(FloeL10n.l("shortcuts.schedule.run.error.schedule_disabled"))
        case .noDueOccurrence(let eventDriven):
            FloeShortcutActionError(FloeL10n.l(eventDriven
                ? "shortcuts.schedule.run.error.event_driven"
                : "shortcuts.schedule.run.error.not_due"))
        case .concurrentlyClaimed:
            FloeShortcutActionError(FloeL10n.l("shortcuts.schedule.run.error.claimed"))
        case .environmentUnavailable:
            FloeShortcutActionError(FloeL10n.l("shortcuts.schedule.run.error.environment"))
        case .modelUnavailable:
            FloeShortcutActionError(FloeL10n.l("shortcuts.schedule.run.error.model"))
        case .storageUnavailable:
            FloeShortcutActionError(FloeL10n.l("shortcuts.run.error.storage"))
        case .launchFailed:
            FloeShortcutActionError(FloeL10n.l("shortcuts.schedule.run.error.launch_failed"))
        case .runReferenceMismatch:
            FloeShortcutActionError(FloeL10n.l("shortcuts.schedule.run.error.reference_mismatch"))
        case .permissionUnavailable:
            FloeShortcutActionError(FloeL10n.l("shortcuts.schedule.run.error.permission"))
        }
    }
}

/// Runs the schedule the user picked in Shortcuts and returns a typed
/// reference to the exact run the schedule's due occurrence launched (or
/// already owned). Background-only, exactly like the other run actions.
struct RunScheduledTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "shortcuts.schedule.run.title"
    static let description = IntentDescription("shortcuts.schedule.run.description")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "shortcuts.schedule.run.parameter.schedule")
    var schedule: TaskScheduleEntity

    @AppDependency private var environment: AppEnvironment

    #if DEBUG
    /// Task-scoped route injection for hosted `perform()` tests, mirroring
    /// `FloeShortcutRunIntentBridge.debugService`: no launched App, real
    /// settings or environment is touched while set. Compiled out of
    /// Release.
    @TaskLocal static var debugRoute: (@MainActor (UUID) async throws -> SelectedScheduleReceipt)?

    /// Task-scoped environment injection for hosted stale-trigger-evidence
    /// tests (same shape as `TaskScheduleEntityQuery.debugEnvironment`).
    /// Compiled out of Release. When UNSET, the deleted-schedule path
    /// performs NO recording and no environment access at all — exactly
    /// today's behavior, so existing hosted failure-copy tests keep their
    /// zero side effects and no fixture ever initializes an environment.
    @TaskLocal static var debugEnvironment: AppEnvironment?
    #endif

    static var parameterSummary: some ParameterSummary {
        // The system localizes a parameter summary with the exact compiled
        // template: this literal text plus a `${schedule}` token, not a
        // printf-style "%@" key, from the app's default Localizable table.
        Summary("shortcuts.schedule.run.summary \(\.$schedule)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<FloeShortcutRunEntity> {
        guard let scheduleID = UUID(uuidString: schedule.id) else {
            throw FloeShortcutActionError(FloeL10n.l("shortcuts.run.error.invalid_id"))
        }
        let receipt: SelectedScheduleReceipt
        do {
            #if DEBUG
            if let debugRoute = Self.debugRoute {
                receipt = try await debugRoute(scheduleID)
            } else {
                receipt = try await FloeScheduledTaskRunner.run(
                    scheduleID: scheduleID, environment: environment)
            }
            #else
            receipt = try await FloeScheduledTaskRunner.run(
                scheduleID: scheduleID, environment: environment)
            #endif
        } catch let failure as SelectedScheduleFailure {
            if case .scheduleDeleted = failure {
                // Best-effort durable cleanup evidence for the still-firing
                // automation, keyed by the ORIGINAL stable UUID with the
                // picked entity's captured title. ANY failure here is
                // swallowed — the original typed refusal is always what the
                // user sees, and recording can never start or change a
                // schedule. A DEBUG hosted test that injected no
                // environment skips recording entirely (no environment
                // access), exactly like today.
                #if DEBUG
                if let debugEnvironment = Self.debugEnvironment {
                    try? await TaskScheduleCleanupReminderStore(
                        database: debugEnvironment.database
                    ).recordStaleTrigger(
                        scheduleID: scheduleID, title: schedule.title, at: Date())
                }
                #else
                try? await TaskScheduleCleanupReminderStore(
                    database: environment.database
                ).recordStaleTrigger(
                    scheduleID: scheduleID, title: schedule.title, at: Date())
                #endif
            }
            throw failure.actionError
        }
        // The receipt was already proven against the occurrence ledger (or
        // the schedule's predetermined launch identity) inside the
        // coordinator. Project the run through the SAME exact-run snapshot
        // and ownership validation the Status/Wait/Text/Files/Cancel
        // actions use — no broader scheduled-run allow list exists: a
        // reference that cannot prove its durable owner is rejected here.
        let value = try await FloeShortcutRunIntentBridge.snapshot(
            runID: receipt.runID,
            expectedConversationID: receipt.conversationID,
            environment: { environment })
        return .result(value: value)
    }
}
#endif
