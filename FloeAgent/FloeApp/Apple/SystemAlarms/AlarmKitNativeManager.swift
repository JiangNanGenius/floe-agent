// FloeApp — real AlarmKit native manager (the only AlarmKit touch point).
//
// SPDX-License-Identifier: MPL-2.0
//
// Adapts AlarmKit's `AlarmManager` to `SystemAlarmNativeManaging`. This is
// the single place the app constructs native alarm configurations and issues
// native mutations; tests substitute a fake so no real alarm rings, no system
// permission prompt appears and no Live Activity is created. AlarmKit is
// iOS/iPadOS 26+; the deployment target is 26.0 so no runtime availability
// dance is required, but `canImport(AlarmKit)` keeps Mac Catalyst builds out.

#if canImport(UIKit) && canImport(AlarmKit)
import Foundation
import SwiftUI
import FloeCore
import FloePersistence
import AlarmKit
import ActivityKit

/// Main-actor entry points for the native alarm service. The SDK owns its
/// nonisolated singleton and asynchronous work; only our value snapshots
/// cross the app's service boundary.
@MainActor
final class AlarmKitNativeManager: SystemAlarmNativeManaging {
    // No SDK object is stored or exposed as app actor-owned state. Resolve
    // AlarmManager.shared at each SDK entry point, as its public API expects;
    // sending a self.manager alias to its nonisolated async methods would
    // incorrectly transfer a reference from the main actor. This facade's
    // own entry points and the observation task remain main-actor isolated.
    nonisolated init() {}

    nonisolated var isAvailable: Bool { true }

    var authorization: SystemAlarmAuthorization {
        switch AlarmManager.shared.authorizationState {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        @unknown default: return .unavailable
        }
    }

    func requestAuthorization() async throws -> SystemAlarmAuthorization {
        let state = try await AlarmManager.shared.requestAuthorization()
        switch state {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        @unknown default: return .unavailable
        }
    }

    func alarms() async throws -> [SystemAlarmNativeSnapshot] {
        let states = Self.presentationStates()
        return try AlarmManager.shared.alarms.map {
            Self.snapshot(for: $0, states: states)
        }
    }

    var alarmUpdates: AsyncStream<[SystemAlarmNativeSnapshot]> {
        let registry = ContentWatchRegistry()
        return AsyncStream { continuation in
            // Give the group nonisolated Sendable operations. SDK iteration
            // happens only after each operation hops into the main-actor registry.
            let observeAlarms: @Sendable () async -> Void = { [registry, continuation] in
                await registry.observeAlarms { continuation.yield($0) }
            }
            let observeActivities: @Sendable () async -> Void = { [registry, continuation] in
                await registry.observeActivities { continuation.yield($0) }
            }
            let task = Task { @MainActor in
                defer {
                    registry.cancelAll()
                    continuation.finish()
                }
                await withTaskGroup(of: Void.self) { group in
                    group.addTask(operation: observeAlarms)
                    // The Live Activity timeline can appear or change AFTER
                    // the manager snapshot (the system starts the activity
                    // for a scheduled countdown separately). Merge both
                    // ActivityKit streams in: `activityUpdates` only emits
                    // CREATION, so existing/new activities' `contentUpdates`
                    // are watched too — a resumed fireDate that arrives after
                    // the manager state must not remain unknown indefinitely.
                    group.addTask(operation: observeActivities)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                // Per-activity tasks are unstructured. Cancel them without
                // waiting for both SDK sequences to finish their next await.
                Task { @MainActor in registry.cancelAll() }
            }
        }
    }

    func schedule(
        id: UUID,
        kind: SystemAlarmKind,
        intendedFireDate: Date?,
        repeatRule: SystemAlarmRepeat,
        timerDuration: TimeInterval?,
        label: String,
        metadataOwnerReference: String
    ) async throws -> SystemAlarmNativeSnapshot {
        let attributes = AlarmAttributes<FloeAlarmMetadata>(
            presentation: SystemAlarmPresentationBuilder.presentation(
                label: label,
                includesCountdown: kind == .timer
            ),
            metadata: FloeAlarmMetadata(ownerReference: metadataOwnerReference),
            tintColor: .accentColor
        )
        let configuration: AlarmManager.AlarmConfiguration<FloeAlarmMetadata>
        switch kind {
        case .timer:
            guard let timerDuration, timerDuration > 0 else {
                throw SystemAlarmError.invalidRequest("timer duration must be positive")
            }
            configuration = .timer(duration: timerDuration, attributes: attributes)
        case .alarm:
            let schedule: Alarm.Schedule
            switch repeatRule {
            case .never:
                guard let intendedFireDate else {
                    throw SystemAlarmError.invalidRequest("alarm fire date required")
                }
                schedule = .fixed(intendedFireDate)
            case .weekly(let days):
                // A repeating alarm uses the device's calendar wall clock; the
                // caller already derived hour/minute in the intended timezone,
                // and repeat-timezone follows the device/system rules (there
                // is no per-instance timezone in a relative recurrence).
                guard let intendedFireDate else {
                    throw SystemAlarmError.invalidRequest("alarm fire date required")
                }
                let components = Calendar.current.dateComponents([.hour, .minute], from: intendedFireDate)
                guard let hour = components.hour, let minute = components.minute else {
                    throw SystemAlarmError.invalidRequest("could not derive alarm time")
                }
                let weekdays = days.compactMap { Self.weekday($0) }
                guard weekdays.count == days.count else {
                    throw SystemAlarmError.invalidRequest("invalid weekday")
                }
                schedule = .relative(.init(
                    time: .init(hour: hour, minute: minute),
                    repeats: .weekly(weekdays)
                ))
            }
            configuration = .alarm(schedule: schedule, attributes: attributes)
        }
        let alarm = try await AlarmManager.shared.schedule(id: id, configuration: configuration)
        return Self.snapshot(for: alarm, states: Self.presentationStates())
    }

    func cancel(id: UUID) async throws {
        // AlarmKit's cancel is synchronous-throwing; address only the exact
        // app-owned id. A foreign id surfaces a native error, never adoption.
        try AlarmManager.shared.cancel(id: id)
    }

    func pause(id: UUID) async throws {
        // Verified against the iOS 27 SDK: `pause(id:)` is synchronous
        // throwing on AlarmManager.shared.
        try AlarmManager.shared.pause(id: id)
    }

    func resume(id: UUID) async throws {
        try AlarmManager.shared.resume(id: id)
    }

    // MARK: - Live Activity timeline

    /// Current AlarmKit presentation states keyed by alarm id, from the real
    /// `Activity<FloeSystemAlarmActivityAttributes>` content state. Absent
    /// when no activity exists for a scheduled alarm (the snapshot then
    /// carries no timeline fields — displayed as syncing/unknown, never
    /// fabricated from createdAt+duration).
    fileprivate static func presentationStates() -> [UUID: AlarmPresentationState] {
        var states: [UUID: AlarmPresentationState] = [:]
        for activity in Activity<FloeSystemAlarmActivityAttributes>.activities {
            states[activity.content.state.alarmID] = activity.content.state
        }
        return states
    }

    fileprivate static func snapshot(
        for alarm: Alarm,
        states: [UUID: AlarmPresentationState]
    ) -> SystemAlarmNativeSnapshot {
        var snapshot = SystemAlarmNativeSnapshot(id: alarm.id, state: describe(alarm.state))
        guard let state = states[alarm.id] else { return snapshot }
        let attributes = Activity<FloeSystemAlarmActivityAttributes>.activities
            .first { $0.content.state.alarmID == alarm.id }?.attributes
        switch state.mode {
        case .countdown(let mode):
            snapshot.title = Self.titleString(
                attributes?.presentation.countdown?.title ?? attributes?.presentation.alert.title)
            snapshot.totalDuration = mode.totalCountdownDuration
            snapshot.previousElapsed = mode.previouslyElapsedDuration
            snapshot.startDate = mode.startDate
            snapshot.fireDate = mode.fireDate
            snapshot.timelineFingerprint = Self.timelineFingerprint(
                state: "countdown", total: mode.totalCountdownDuration,
                elapsed: mode.previouslyElapsedDuration, fireDate: mode.fireDate)
        case .paused(let mode):
            snapshot.title = Self.titleString(
                attributes?.presentation.paused?.title ?? attributes?.presentation.alert.title)
            snapshot.totalDuration = mode.totalCountdownDuration
            snapshot.previousElapsed = mode.previouslyElapsedDuration
            snapshot.timelineFingerprint = Self.timelineFingerprint(
                state: "paused", total: mode.totalCountdownDuration,
                elapsed: mode.previouslyElapsedDuration, fireDate: nil)
        case .alert:
            snapshot.title = Self.titleString(attributes?.presentation.alert.title)
            snapshot.timelineFingerprint = Self.timelineFingerprint(
                state: "alert", total: nil, elapsed: nil, fireDate: nil)
        @unknown default:
            break
        }
        return snapshot
    }

    private nonisolated static func titleString(_ resource: LocalizedStringResource?) -> String? {
        guard let resource else { return nil }
        let text = String(localized: resource)
        return text.isEmpty ? nil : String(text.prefix(64))
    }

    private nonisolated static func timelineFingerprint(
        state: String, total: TimeInterval?, elapsed: TimeInterval?, fireDate: Date?
    ) -> String? {
        var parts: [String] = [state]
        if let total { parts.append(String(format: "%.3f", total)) }
        if let elapsed { parts.append(String(format: "%.3f", elapsed)) }
        if let fireDate { parts.append(SystemAlarmDateCoding.encode(fireDate)) }
        return String(FloeDigest.sha256Hex(Data(parts.joined(separator: "|").utf8)).prefix(24))
    }

    private nonisolated static func describe(_ state: Alarm.State) -> String {
        switch state {
        case .scheduled: return "scheduled"
        case .countdown: return "countdown"
        case .paused: return "paused"
        case .alerting: return "alerting"
        @unknown default: return "unknown"
        }
    }

    /// Map our 1...7 (Monday=1) weekday to Foundation's `Locale.Weekday`.
    private static func weekday(_ day: Int) -> Locale.Weekday? {
        switch day {
        case 1: return .monday
        case 2: return .tuesday
        case 3: return .wednesday
        case 4: return .thursday
        case 5: return .friday
        case 6: return .saturday
        case 7: return .sunday
        default: return nil
        }
    }
}

/// Activity discovery, SDK references and watcher creation all stay on the
/// main actor. Only Sendable snapshots leave this registry. One task per known
/// activity id is retained, and completed/cancelled watchers are released.
@MainActor
private final class ContentWatchRegistry {
    // ActivityKit's Activity.ID is a String (not UUID).
    private var tasks: [String: Task<Void, Never>] = [:]
    private var cancelled = false

    func observeAlarms(yield: @Sendable @escaping ([SystemAlarmNativeSnapshot]) -> Void) async {
        guard !cancelled, !Task.isCancelled else { return }
        for await alarms in AlarmManager.shared.alarmUpdates {
            guard !cancelled, !Task.isCancelled else { return }
            let states = AlarmKitNativeManager.presentationStates()
            yield(alarms.map { AlarmKitNativeManager.snapshot(for: $0, states: states) })
        }
    }

    func observeActivities(yield: @Sendable @escaping ([SystemAlarmNativeSnapshot]) -> Void) async {
        guard !cancelled, !Task.isCancelled else { return }
        for activity in Activity<FloeSystemAlarmActivityAttributes>.activities {
            watch(activity, yield: yield)
        }
        for await activity in Activity<FloeSystemAlarmActivityAttributes>.activityUpdates {
            guard !cancelled, !Task.isCancelled else { return }
            watch(activity, yield: yield)
            let states = AlarmKitNativeManager.presentationStates()
            let snapshots = (try? AlarmManager.shared.alarms).map {
                $0.map { AlarmKitNativeManager.snapshot(for: $0, states: states) }
            } ?? []
            yield(snapshots)
        }
    }

    private func watch(
        _ activity: Activity<FloeSystemAlarmActivityAttributes>,
        yield: @Sendable @escaping ([SystemAlarmNativeSnapshot]) -> Void
    ) {
        guard !cancelled, !Task.isCancelled, tasks[activity.id] == nil else { return }
        let id = activity.id
        tasks[id] = Task { @MainActor in
            defer { tasks[id] = nil }
            for await _ in activity.contentUpdates {
                guard !cancelled, !Task.isCancelled else { return }
                let states = AlarmKitNativeManager.presentationStates()
                let snapshots = (try? AlarmManager.shared.alarms).map {
                    $0.map { AlarmKitNativeManager.snapshot(
                        for: $0, states: states) }
                } ?? []
                yield(snapshots)
            }
        }
    }

    func cancelAll() {
        cancelled = true
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
    }
}
#endif
