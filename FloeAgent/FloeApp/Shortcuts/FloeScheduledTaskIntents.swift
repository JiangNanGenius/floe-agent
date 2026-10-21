// FloeApp — S4 selected-schedule system automation.
//
// A Shortcuts personal automation (Time of Day, etc.) can run ONE EXISTING
// Floe schedule by picking it in the "Run Scheduled Task" action. The action
// routes through the same durable occurrence claim/launch/bind path as the
// app's background scheduler (BackgroundRunCoordinator.runSelectedSchedule)
// and returns the SAME typed exact-run reference the Start/Status/Wait/Text/
// Files/Cancel actions accept — never a separate unbound Start(prompt), a
// random manual instance, or a success string that hides a store failure.

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
/// shared external-automation readiness, then the coordinator's single
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
        return try await environment.backgroundRunCoordinator
            .runSelectedSchedule(scheduleID: scheduleID)
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
