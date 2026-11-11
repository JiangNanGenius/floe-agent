import SwiftUI
import Combine
import UserNotifications
import AlarmKit
import UIKit
import FloeToolboxUtilities
import FloeToolboxWorkbenches

@main struct TimekeepingApp: App {
    var body: some Scene {
        WindowGroup {
            let arguments = ProcessInfo.processInfo.arguments
            Group {
                if arguments.contains("--clear-test-reminders") { NotificationCleanupView() }
                else if arguments.contains("--alarm-settings-probe") { NavigationStack { AlarmSettingsProbe() } }
                else if arguments.contains("--inline-card-fixture") { NavigationStack { InlineTimerQualification() } }
                else { NavigationStack { ObservedTimekeepingPage() } }
            }
                .frame(maxWidth: arguments.contains("--compact") ? 390 : .infinity)
                .frame(maxWidth: .infinity)
                .preferredColorScheme(arguments.contains("--dark") ? .dark : .light)
                .environment(\.dynamicTypeSize, arguments.contains("--large-text") ? .accessibility2 : .large)
        }
    }
}

/// Reads raw authorization only. Opening Settings is an explicit button action.
@MainActor private struct AlarmSettingsProbe: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            VStack(spacing: 20) {
                Text(String(describing: AlarmManager.shared.authorizationState))
                    .accessibilityIdentifier("qualification.alarmProbe.authorization")
                Button("Open App Settings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("qualification.alarmProbe.openSettings")
            }
            .padding()
        }
        .navigationTitle("Alarm Authorization Probe")
    }
}

/// Qualification-only observation of the exact bridge used by the workbench.
/// It forwards every operation unchanged and never schedules, pauses or cancels
/// an alarm on its own. Missing native timeline values remain unavailable.
@MainActor private final class NativeTimerReadbacks: ObservableObject {
    struct Entry: Identifiable {
        var state: ToolboxTimerAlarmState
        var observation: UInt64
        var id: UUID { state.timerID }
    }
    struct AuthorizationObservation {
        var before: String
        var after: String
        var result: String
        var errorDomain: String
        var errorCode: String
    }
    @Published private(set) var entries: [UUID: Entry] = [:]
    @Published private(set) var authorization: AuthorizationObservation?

    func bridge(_ center: ToolboxTimerReminders) -> ToolboxTimerReminderBridge {
        .init(authorize: { try await self.authorize(center) }, synchronize: { request in
            let value = try await center.synchronize(request)
            if let value { self.record(value) }
            return value
        }, cancel: { try await center.cancel(timerID: $0) },
            prune: { try await center.prune(keeping: $0) }, updates: {
                AsyncStream(bufferingPolicy: .bufferingNewest(24)) { continuation in
                    let task = Task { @MainActor [weak self] in
                        for await value in center.updates() {
                            guard !Task.isCancelled else { break }
                            self?.record(value)
                            continuation.yield(value)
                        }
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            })
    }

    private func authorize(_ center: ToolboxTimerReminders) async throws -> Bool {
        let before = authorizationName(AlarmManager.shared.authorizationState)
        authorization = .init(before: before, after: "pending", result: "pending", errorDomain: "none", errorCode: "none")
        do {
            let result = try await center.authorize()
            authorization = .init(before: before, after: authorizationName(AlarmManager.shared.authorizationState),
                result: String(result), errorDomain: "none", errorCode: "none")
            return result
        } catch {
            let nativeError = error as NSError
            authorization = .init(before: before, after: authorizationName(AlarmManager.shared.authorizationState),
                result: "threw", errorDomain: nativeError.domain, errorCode: String(nativeError.code))
            throw error
        }
    }

    private func authorizationName(_ state: AlarmManager.AuthorizationState) -> String {
        switch state {
        case .notDetermined: "notDetermined"
        case .denied: "denied"
        case .authorized: "authorized"
        @unknown default: "unknown"
        }
    }

    private func record(_ value: ToolboxTimerAlarmState) {
        entries[value.timerID] = Entry(state: value,
            observation: (entries[value.timerID]?.observation ?? 0) + 1)
    }
}

@MainActor private struct ObservedTimekeepingPage: View {
    @StateObject private var readbacks = NativeTimerReadbacks()
    var body: some View {
        ToolboxTimerView(reminders: readbacks.bridge(ToolboxTimerReminders.shared))
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    authorizationReadback
                    ForEach(readbacks.entries.values.sorted { $0.id.uuidString < $1.id.uuidString }) { entry in
                        HStack(spacing: 6) {
                            Text(String(entry.id.uuidString.prefix(6)))
                            Text(phase(entry.state.phase))
                                .accessibilityIdentifier("qualification.native.phase." + entry.id.uuidString)
                            Text(remaining(entry.state.remaining))
                                .accessibilityIdentifier("qualification.native.remaining." + entry.id.uuidString)
                            Text(String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), entry.state.observedAt.timeIntervalSince1970))
                                .accessibilityIdentifier("qualification.native.observedAt." + entry.id.uuidString)
                            Text(String(entry.state.generation))
                                .accessibilityIdentifier("qualification.native.generation." + entry.id.uuidString)
                            Text(String(entry.observation))
                                .accessibilityIdentifier("qualification.native.observation." + entry.id.uuidString)
                        }
                    }
                }
                .font(.system(size: 8, design: .monospaced))
                .padding(4).background(.regularMaterial)
                .allowsHitTesting(false)
            }
    }
    @ViewBuilder private var authorizationReadback: some View {
        if let value = readbacks.authorization {
            VStack(alignment: .leading, spacing: 0) {
                Text("Auth before: " + value.before).accessibilityIdentifier("qualification.native.authorization.before")
                Text("Auth after: " + value.after).accessibilityIdentifier("qualification.native.authorization.after")
                Text("Auth result: " + value.result).accessibilityIdentifier("qualification.native.authorization.result")
                Text("Auth error domain: " + value.errorDomain).accessibilityIdentifier("qualification.native.authorization.errorDomain")
                Text("Auth error code: " + value.errorCode).accessibilityIdentifier("qualification.native.authorization.errorCode")
            }
        } else {
            Text("Auth: not called").accessibilityIdentifier("qualification.native.authorization.notCalled")
        }
    }
    private func remaining(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "unavailable" }
        return String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
    private func phase(_ value: ToolboxTimerAlarmState.Phase) -> String {
        switch value {
        case .running: "running"
        case .paused: "paused"
        case .alerting: "alerting"
        case .stopped: "stopped"
        case .unverified: "unverified"
        }
    }
}

private struct NotificationCleanupView: View {
    @State private var complete = false
    var body: some View {
        Text(complete ? "Test reminders cleared" : "Clearing test reminders")
            .accessibilityIdentifier(complete ? "qualification.notifications.cleared" : "qualification.notifications.clearing")
            .task {
                do {
                    try await ToolboxTimerReminders.shared.prune(keeping: [])
                    complete = true
                } catch { complete = false }
            }
    }
}

// Existing App language helper contract; native alarm dependencies are real
// package products. This remains a component host, without Notes or App navigation.
enum IDELanguageRunText {
    static func t(_ zh: String, _ en: String) -> String {
        Locale.current.language.languageCode?.identifier == "zh" ? zh : en
    }
}
