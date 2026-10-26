// FloeApp — independent background capabilities and PiP sound settings.
// SPDX-License-Identifier: MPL-2.0

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import CoreLocation
import UIKit

@MainActor
struct BackgroundExecutionSettingsView: View {
    @ObservedObject var center: SettingsCenter
    @ObservedObject var videoService: BackgroundVideoService
    @ObservedObject var audioService: PiPAudioService
    @ObservedObject private var locationService = LocationServicesCenter.shared
    @Environment(\.openURL) private var openURL

    private var statusPiPEnabled: Bool { StatusPiPReleaseGate.isEnabled }

    /// Inline bilingual fallback for strings whose central catalog entry has
    /// not landed yet (the catalog is root-owned for this round): a missing
    /// key must never render raw. Proposed keys go to the handoff so the
    /// rows can move to `background.features.*` in one catalog merge.
    private func capabilityText(zh: String, en: String) -> String {
        FloeL10n.isChinese ? zh : en
    }

    /// The user-facing names used by the cascade captions below.
    private func capabilityName(_ capability: BackgroundExecutionCapability) -> String {
        switch capability {
        case .enhancedBackground:
            return FloeL10n.l("background.features.enhanced")
        case .audio:
            return capabilityText(zh: "后台音频", en: "background audio")
        case .pictureInPicture:
            return FloeL10n.l("background.features.pip")
        case .screenFeedback:
            return FloeL10n.l("background.features.screen_feedback")
        case .taskLiveActivity:
            return FloeL10n.l("background.features.live_activity")
        }
    }

    /// Refusal copy: a prerequisite cannot be turned off while dependents
    /// are still enabled (Core policy; the row is disabled to match). Tells
    /// the user exactly what to turn off first.
    private func blockingCaption(_ capability: BackgroundExecutionCapability) -> String? {
        guard isBlocked(capability) else { return nil }
        let blocking = center.backgroundExecutionOptions
            .activeDependentsBlockingDisable(of: capability)
        guard !blocking.isEmpty else { return nil }
        let names = blocking.map(capabilityName).joined(
            separator: FloeL10n.isChinese ? "、" : ", ")
        return FloeL10n.isChinese
            ? "需先关闭\(names)。"
            : "Turn off \(names) first."
    }

    /// Enable-pull copy: what turning this capability on also enables
    /// (the prerequisite chain). Shown only while a prerequisite is off.
    private func prerequisiteCaption(_ capability: BackgroundExecutionCapability) -> String? {
        let missing = center.backgroundExecutionOptions
            .prerequisitesEnabledByTurningOn(capability)
        guard !missing.isEmpty else { return nil }
        let names = missing.map(capabilityName).joined(
            separator: FloeL10n.isChinese ? "、" : ", ")
        return FloeL10n.isChinese
            ? "开启后将同时开启\(names)。"
            : "Turning this on also turns on \(names)."
    }

    private func isBlocked(_ capability: BackgroundExecutionCapability) -> Bool {
        let options = center.backgroundExecutionOptions
        let currentlyEnabled: Bool
        switch capability {
        case .enhancedBackground: currentlyEnabled = options.enhancedBackgroundEnabled
        case .audio: currentlyEnabled = options.audioEnabled
        case .pictureInPicture: currentlyEnabled = options.pictureInPictureEnabled
        case .screenFeedback: currentlyEnabled = options.screenFeedbackEnabled
        case .taskLiveActivity: currentlyEnabled = options.taskLiveActivityEnabled
        }
        // A legacy off prerequisite can still be ENABLED. The restriction
        // applies only to disabling an on prerequisite with active dependents.
        return currentlyEnabled && !options.activeDependentsBlockingDisable(of: capability).isEmpty
    }

    var body: some View {
        Form {
            Section {
                Toggle("background.features.enhanced", isOn: Binding(
                    get: { center.backgroundExecutionOptions.enhancedBackgroundEnabled },
                    set: { value in Task { await center.setEnhancedBackgroundEnabled(value) } }
                ))
                .disabled(isBlocked(.enhancedBackground))
                .accessibilityIdentifier("background.enhanced.toggle")
                // Chain root: with any dependent capability still on, the
                // Core setter refuses the disable (no silent cascade-off)
                // and the row shows the actionable reason.
                if let caption = blockingCaption(.enhancedBackground) {
                    Text(caption)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("background.enhanced.blockedCaption")
                }

                // Standalone background audio: the service-owned ambient
                // loop and task speech for a real running task — no PiP
                // view required. Enabling it pulls in the enhanced
                // processing prerequisite; it never changes volume or
                // starts playback by itself.
                Toggle(capabilityText(zh: "后台音频", en: "Background audio"), isOn: Binding(
                    get: { center.backgroundExecutionOptions.audioEnabled },
                    set: { value in Task { await center.setAudioEnabled(value) } }
                ))
                .disabled(isBlocked(.audio))
                .accessibilityIdentifier("background.audio.toggle")
                if let caption = blockingCaption(.audio) ?? prerequisiteCaption(.audio) {
                    Text(caption)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("background.audio.policyCaption")
                }

                // The sound page is the AUDIO capability's own child —
                // de-nested from the PiP row. It stays reachable with the
                // capability off: the page's own preview is an explicit
                // foreground action, and existing users keep access to
                // their saved sound choices. The identifier stays
                // `background.pip.audio.settings` because the pinned UI
                // tests reference it.
                NavigationLink {
                    PiPAudioSettingsView(center: center, audioService: audioService)
                } label: {
                    Label("pip.audio.settings.title", systemImage: "speaker.wave.2")
                }
                .accessibilityIdentifier("background.pip.audio.settings")

                Toggle("background.features.pip", isOn: Binding(
                    get: { center.backgroundExecutionOptions.pictureInPictureEnabled },
                    set: { value in Task { await center.setPictureInPictureEnabled(value) } }
                ))
                .disabled(!statusPiPEnabled || isBlocked(.pictureInPicture))
                .accessibilityIdentifier("background.pip.toggle")
                if let caption = blockingCaption(.pictureInPicture) ?? prerequisiteCaption(.pictureInPicture) {
                    Text(caption)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("background.pip.policyCaption")
                }

                Toggle("background.features.screen_feedback", isOn: Binding(
                    get: { center.backgroundExecutionOptions.screenFeedbackEnabled },
                    set: { value in Task { await center.setScreenFeedbackEnabled(value) } }
                ))
                .disabled(!statusPiPEnabled)
                .accessibilityIdentifier("background.screenFeedback.toggle")
                if let caption = prerequisiteCaption(.screenFeedback) {
                    Text(caption)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("background.screenFeedback.policyCaption")
                }

                // Independent of every other switch: it changes nothing else
                // and requires no PiP, location or server capability.
                Toggle("background.features.live_activity", isOn: Binding(
                    get: { center.backgroundExecutionOptions.taskLiveActivityEnabled },
                    set: { value in Task { await setTaskLiveActivityEnabled(value) } }
                ))
                .accessibilityIdentifier("background.liveActivity.toggle")

                if center.backgroundExecutionOptions.taskLiveActivityEnabled,
                   TaskLiveActivityCoordinator.isSupported,
                   !TaskLiveActivityCoordinator.areSystemLiveActivitiesEnabled {
                    Text("background.live_activity.system_disabled")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent("background.location.title") {
                    Text(locationStatus)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("background.location.status")

                if locationService.authorizationStatus == .denied {
                    Button("background.location.open_settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    }
                    .accessibilityIdentifier("background.location.openSettings")
                }
            }

            if center.backgroundExecutionOptions.pictureInPictureEnabled, statusPiPEnabled {
                Section {
                    LabeledContent {
                        Text(videoService.preparationState.localizedDescription)
                            .foregroundStyle(.secondary)
                    } label: {
                        Label("background.pip_section", systemImage: videoService.isPiPActive ? "pip.fill" : "pip")
                    }
                    if let error = videoService.lastError {
                        Text(error)
                            .foregroundStyle(FloeTheme.destructive)
                            .font(.footnote)
                    }
                }
            }

            if !statusPiPEnabled {
                Section {
                    Text("background.pip_unavailable")
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle(FloeL10n.l("background.settings.title"))
        .task {
            await center.loadBackgroundExecution()
            locationService.refreshAuthorizationStatus()
        }
    }

    /// Persists the independent choice through the existing atomic options
    /// object; no other capability is touched.
    private func setTaskLiveActivityEnabled(_ enabled: Bool) async {
        var options = center.backgroundExecutionOptions
        guard options.taskLiveActivityEnabled != enabled else { return }
        options.setTaskLiveActivityEnabled(enabled)
        await center.setBackgroundExecutionOptions(options)
    }

    private var locationStatus: String {
        switch locationService.authorizationStatus {
        case .notDetermined:
            return FloeL10n.l("background.location.permission.not_determined")
        case .denied:
            return FloeL10n.l("background.location.permission.denied")
        case .restricted:
            return FloeL10n.l("background.location.permission.restricted")
        default:
            switch locationService.backgroundState {
            case .idle: return FloeL10n.l("background.location.state.idle")
            case .ready: return FloeL10n.l("background.location.state.ready")
            case .active: return FloeL10n.l("background.location.state.active")
            case .unavailable: return FloeL10n.l("background.location.state.unavailable")
            }
        }
    }
}

/// Shared by Settings navigation and the task PiP's quick-settings sheet.
/// The caller owns navigation; only an explicitly tapped preview is view-owned.
@MainActor
struct PiPAudioSettingsView: View {
    @ObservedObject var center: SettingsCenter
    @ObservedObject var audioService: PiPAudioService

    var body: some View {
        Form {
            Section {
                Toggle("pip.audio.ambient.enabled", isOn: Binding(
                    get: { center.pipAudioPreferences.ambientEnabled },
                    set: { value in updateAudio { $0.ambientEnabled = value } }
                ))
                .accessibilityIdentifier("pip.audio.ambient.toggle")

                Picker("pip.audio.sound", selection: Binding(
                    get: { center.pipAudioPreferences.ambientSound },
                    set: { value in selectSound(value) }
                )) {
                    ForEach(PiPAmbientSound.allCases, id: \.self) { sound in
                        Text(sound.title).tag(sound)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("pip.audio.sound")

                volumeRow(
                    value: Binding(
                        get: { center.pipAudioPreferences.ambientGain },
                        set: { value in updateAudio { $0.ambientGain = value } }
                    ),
                    identifier: "pip.audio.ambient.volume",
                    label: FloeL10n.l("pip.audio.ambient.volume.label")
                )

                Button {
                    if audioService.isPreviewing {
                        audioService.stopPreview()
                    } else {
                        audioService.startPreview(center.pipAudioPreferences.ambientSound)
                    }
                } label: {
                    Label(
                        audioService.isPreviewing
                            ? FloeL10n.l("pip.audio.preview.stop")
                            : FloeL10n.l("pip.audio.preview.start"),
                        systemImage: audioService.isPreviewing ? "stop.circle" : "play.circle"
                    )
                    .frame(minHeight: FloeTheme.minimumTarget)
                }
                .accessibilityIdentifier("pip.audio.preview")
            }

            Section {
                Toggle("pip.audio.speech.enabled", isOn: Binding(
                    get: { center.pipAudioPreferences.taskSpeechEnabled },
                    set: { value in updateAudio { $0.taskSpeechEnabled = value } }
                ))
                .accessibilityIdentifier("pip.audio.speech.toggle")

                Toggle("pip.audio.cues.enabled", isOn: Binding(
                    get: { center.pipAudioPreferences.cuesEnabled },
                    set: { value in updateAudio { $0.cuesEnabled = value } }
                ))
                .accessibilityIdentifier("pip.audio.cues.toggle")

                volumeRow(
                    value: Binding(
                        get: { center.pipAudioPreferences.taskSpeechGain },
                        set: { value in updateAudio { $0.taskSpeechGain = value } }
                    ),
                    identifier: "pip.audio.speech.volume",
                    label: FloeL10n.l("pip.audio.speech.volume.label")
                )
            }

            Section {
                LabeledContent("pip.audio.ambient.state", value: audioService.state.title)
                    .accessibilityIdentifier("pip.audio.playback.state")
                if let error = audioService.lastActionableError {
                    Text(error)
                        .foregroundStyle(FloeTheme.destructive)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle(FloeL10n.l("pip.audio.settings.title"))
        .onDisappear { audioService.stopPreview() }
    }

    private func volumeRow(value: Binding<Double>, identifier: String, label: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: value.wrappedValue == 0 ? "speaker.slash" : "speaker.wave.2")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Slider(value: value, in: 0...1, step: 0.01)
                .accessibilityLabel(label)
                .accessibilityIdentifier(identifier)
            Text(value.wrappedValue, format: .percent.precision(.fractionLength(0)))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .frame(minHeight: FloeTheme.minimumTarget)
    }

    /// Read the latest preferences on the actor when the update executes:
    /// two rapid changes to different fields must not restore stale values.
    private func updateAudio(_ mutate: @escaping @MainActor (inout PiPAudioPreferences) -> Void) {
        Task { @MainActor in
            var preferences = center.pipAudioPreferences
            mutate(&preferences)
            await center.setPiPAudioPreferences(preferences)
        }
    }

    /// Persist the picker's choice before touching an open preview. Closing
    /// the preview then returns to the newly stored track, never to the
    /// pre-selection one. Without a preview the stored change reaches the
    /// service through `SettingsCenter`; selection alone never starts audio.
    private func selectSound(_ sound: PiPAmbientSound) {
        Task { @MainActor in
            var preferences = center.pipAudioPreferences
            preferences.ambientSound = sound
            await center.setPiPAudioPreferences(preferences)
            guard center.pipAudioPreferences.ambientSound == sound,
                  audioService.isPreviewing else { return }
            audioService.startPreview(sound)
        }
    }
}
/// Keeps the same sound page reachable from a running task's PiP control.
/// A context menu preserves the existing one-tap start/stop action.
@MainActor
private struct PiPAudioQuickSettingsModifier: ViewModifier {
    let center: SettingsCenter
    let audioService: PiPAudioService
    @State private var showsSoundSettings = false

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button("pip.audio.settings.title", systemImage: "speaker.wave.2") {
                    showsSoundSettings = true
                }
                .accessibilityIdentifier("background.pip.audio.quickSettings")
            }
            .sheet(isPresented: $showsSoundSettings) {
                NavigationStack {
                    PiPAudioSettingsView(center: center, audioService: audioService)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("action.done") { showsSoundSettings = false }
                            }
                        }
                }
            }
    }
}

extension View {
    func pipAudioQuickSettings(center: SettingsCenter, audioService: PiPAudioService) -> some View {
        modifier(PiPAudioQuickSettingsModifier(center: center, audioService: audioService))
    }
}
#endif
