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
        try AlarmManager.shared.alarms.map {
            SystemAlarmNativeSnapshot(id: $0.id, state: Self.describe($0.state))
        }
    }

    var alarmUpdates: AsyncStream<[SystemAlarmNativeSnapshot]> {
        AsyncStream { continuation in
            let task = Task {
                for await alarms in AlarmManager.shared.alarmUpdates {
                    let snapshots = alarms.map {
                        SystemAlarmNativeSnapshot(id: $0.id, state: Self.describe($0.state))
                    }
                    continuation.yield(snapshots)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
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
        return SystemAlarmNativeSnapshot(id: alarm.id, state: Self.describe(alarm.state))
    }

    func cancel(id: UUID) async throws {
        // AlarmKit's cancel is synchronous-throwing; address only the exact
        // app-owned id. A foreign id surfaces a native error, never adoption.
        try AlarmManager.shared.cancel(id: id)
    }

    private static func describe(_ state: Alarm.State) -> String {
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
#endif
