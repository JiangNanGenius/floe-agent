// SPDX-License-Identifier: MPL-2.0
// Shared target membership: FloeApp + FloeWidgets. LiveActivityIntent
// execution belongs to the host App; the extension only references controls.
#if canImport(AlarmKit) && !targetEnvironment(macCatalyst)
import Foundation
import AlarmKit
import AppIntents
import FloeCore

// MARK: - Intents (real native controls, executed in the host app)

/// Stops a firing alarm. `stop(id:)` is the genuine AlarmKit stop for the
/// alerting state.
struct FloeSystemAlarmStopIntent: LiveActivityIntent {
    static var isDiscoverable: Bool { false }
    static var title: LocalizedStringResource {
        LocalizedStringResource(stringLiteral: "apple.alarm.stop")
    }

    @Parameter(title: "Alarm ID")
    var alarmID: String

    init() {}
    init(alarmID: String) { self.alarmID = alarmID }

    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: alarmID) else {
            throw FloeSystemAlarmControlError.invalidIdentifier
        }
        try AlarmManager.shared.stop(id: id)
        return .result()
    }
}

/// Pauses a counting-down timer natively.
struct FloeSystemAlarmPauseIntent: LiveActivityIntent {
    static var isDiscoverable: Bool { false }
    static var title: LocalizedStringResource {
        LocalizedStringResource(stringLiteral: "apple.alarm.pause")
    }

    @Parameter(title: "Alarm ID")
    var alarmID: String

    init() {}
    init(alarmID: String) { self.alarmID = alarmID }

    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: alarmID) else {
            throw FloeSystemAlarmControlError.invalidIdentifier
        }
        try AlarmManager.shared.pause(id: id)
        return .result()
    }
}

/// Resumes a paused timer natively.
struct FloeSystemAlarmResumeIntent: LiveActivityIntent {
    static var isDiscoverable: Bool { false }
    static var title: LocalizedStringResource {
        LocalizedStringResource(stringLiteral: "apple.alarm.resume")
    }

    @Parameter(title: "Alarm ID")
    var alarmID: String

    init() {}
    init(alarmID: String) { self.alarmID = alarmID }

    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: alarmID) else {
            throw FloeSystemAlarmControlError.invalidIdentifier
        }
        try AlarmManager.shared.resume(id: id)
        return .result()
    }
}

private enum FloeSystemAlarmControlError: LocalizedError {
    case invalidIdentifier
    var errorDescription: String? { FloeL10n.l("widget.alarm.unavailable") }
}

#endif
