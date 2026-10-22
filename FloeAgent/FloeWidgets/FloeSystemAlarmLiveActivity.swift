// FloeWidgets — Live Activity for system alarms/timers (S5 C3).
//
// SPDX-License-Identifier: MPL-2.0
//
// Renders the genuine AlarmKit Live Activity for alarms/timers the App
// scheduled through `AlarmManager`. The system matches this
// `ActivityConfiguration` to a scheduled alarm by the exact attributes type
// (`FloeSystemAlarmActivityAttributes` from FloeCore), drives the
// AlarmPresentationState transitions itself (countdown → paused → alert),
// and the App never requests/ends this activity manually.
//
// Only real controls are drawn: pause/resume perform the native
// AlarmManager pause/resume, stop performs the native stop — each from a
// LiveActivityIntent delivered in the host app process. No fake buttons, no
// relaunch-only disguises, no protocol chatter in user-facing copy.

#if canImport(AlarmKit) && !targetEnvironment(macCatalyst)
import Foundation
import WidgetKit
import SwiftUI
import AlarmKit
import AppIntents
import FloeCore

// MARK: - Live Activity widget

struct FloeSystemAlarmLiveActivityWidget: Widget {
    init() {
        // Live Activity rendering does not pass through the home-widget
        // provider; resolve the App-mirrored language here too. Idempotent.
        FloeL10n.bootstrap()
    }

    var body: some WidgetConfiguration {
        ActivityConfiguration(
            for: FloeSystemAlarmActivityAttributes.self,
            content: { context in
                FloeSystemAlarmLiveActivityView(context: context)
            },
            dynamicIsland: { context in
                FloeSystemAlarmDynamicIslandBuilder.make(context: context)
            }
        )
    }
}

// MARK: - Shared presentation bits

private enum FloeSystemAlarmPresentation {
    /// Mode-appropriate title authored by the App (user label or the shared
    /// localized default), falling back to the alert title.
    static func title(
        attributes: FloeSystemAlarmActivityAttributes,
        mode: AlarmPresentationState.Mode
    ) -> LocalizedStringResource {
        switch mode {
        case .countdown:
            return attributes.presentation.countdown?.title
                ?? attributes.presentation.alert.title
        case .paused:
            return attributes.presentation.paused?.title
                ?? attributes.presentation.alert.title
        case .alert:
            return attributes.presentation.alert.title
        @unknown default:
            return attributes.presentation.alert.title
        }
    }

    static var symbol: String { "alarm.fill" }

    /// h:mm:ss / mm:ss, always non-negative.
    static func durationText(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    /// Wall clock for a firing alarm, in the device-calendar rules the
    /// repeating schedule already follows.
    static func clockText(hour: Int, minute: Int) -> String {
        String(format: "%02d:%02d", hour, minute)
    }

    /// Compact summary per mode for the Dynamic Island trailing slot.
    static func compactText(_ mode: AlarmPresentationState.Mode) -> String {
        switch mode {
        case .countdown(let countdown):
            return durationText(countdown.fireDate.timeIntervalSinceNow)
        case .paused(let paused):
            return durationText(
                paused.totalCountdownDuration - paused.previouslyElapsedDuration)
        case .alert(let alert):
            return clockText(hour: alert.time.hour, minute: alert.time.minute)
        @unknown default:
            return ""
        }
    }
}

// MARK: - Lock screen / banner view

struct FloeSystemAlarmLiveActivityView: View {
    let context: ActivityViewContext<FloeSystemAlarmActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: FloeSystemAlarmPresentation.symbol)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(FloeSystemAlarmPresentation.title(
                    attributes: context.attributes, mode: context.state.mode))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            switch context.state.mode {
            case .countdown(let countdown):
                Text(timerInterval: countdown.startDate...countdown.fireDate, countsDown: true)
                    .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                Button(intent: FloeSystemAlarmPauseIntent(
                    alarmID: context.state.alarmID.uuidString)) {
                    Label(FloeL10n.l("widget.alarm.pause"), systemImage: "pause.fill")
                }
                .buttonStyle(.bordered)
            case .paused(let paused):
                Text(FloeSystemAlarmPresentation.durationText(
                    paused.totalCountdownDuration - paused.previouslyElapsedDuration))
                    .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                Text(FloeL10n.l("widget.alarm.paused"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button(intent: FloeSystemAlarmResumeIntent(
                    alarmID: context.state.alarmID.uuidString)) {
                    Label(FloeL10n.l("widget.alarm.resume"), systemImage: "play.fill")
                }
                .buttonStyle(.bordered)
            case .alert(let alert):
                Text(FloeSystemAlarmPresentation.clockText(
                    hour: alert.time.hour, minute: alert.time.minute))
                    .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                Button(intent: FloeSystemAlarmStopIntent(
                    alarmID: context.state.alarmID.uuidString)) {
                    Label(FloeL10n.l("widget.alarm.stop"), systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
            @unknown default:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .containerBackground(for: .widget) {
            Color(uiColor: .secondarySystemBackground)
        }
    }
}

// MARK: - Dynamic Island

private enum FloeSystemAlarmDynamicIslandBuilder {
    static func make(
        context: ActivityViewContext<FloeSystemAlarmActivityAttributes>
    ) -> DynamicIsland {
        DynamicIsland {
            DynamicIslandExpandedRegion(.leading) {
                Image(systemName: FloeSystemAlarmPresentation.symbol)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            DynamicIslandExpandedRegion(.trailing) {
                Text(FloeSystemAlarmPresentation.compactText(context.state.mode))
                    .font(.subheadline.monospacedDigit())
            }
            DynamicIslandExpandedRegion(.center) {
                Text(FloeSystemAlarmPresentation.title(
                    attributes: context.attributes, mode: context.state.mode))
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
            }
            DynamicIslandExpandedRegion(.bottom) {
                switch context.state.mode {
                case .countdown:
                    Button(intent: FloeSystemAlarmPauseIntent(
                        alarmID: context.state.alarmID.uuidString)) {
                        Label(FloeL10n.l("widget.alarm.pause"), systemImage: "pause.fill")
                    }
                    .buttonStyle(.bordered)
                case .paused:
                    Button(intent: FloeSystemAlarmResumeIntent(
                        alarmID: context.state.alarmID.uuidString)) {
                        Label(FloeL10n.l("widget.alarm.resume"), systemImage: "play.fill")
                    }
                    .buttonStyle(.bordered)
                case .alert:
                    Button(intent: FloeSystemAlarmStopIntent(
                        alarmID: context.state.alarmID.uuidString)) {
                        Label(FloeL10n.l("widget.alarm.stop"), systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                @unknown default:
                    EmptyView()
                }
            }
        } compactLeading: {
            Image(systemName: FloeSystemAlarmPresentation.symbol)
                .foregroundStyle(.secondary)
        } compactTrailing: {
            Text(FloeSystemAlarmPresentation.compactText(context.state.mode))
                .font(.caption.monospacedDigit())
        } minimal: {
            Image(systemName: FloeSystemAlarmPresentation.symbol)
                .foregroundStyle(.secondary)
        }
    }
}
#endif
