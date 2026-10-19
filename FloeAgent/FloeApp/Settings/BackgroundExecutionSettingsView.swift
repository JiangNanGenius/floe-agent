// FloeApp — independent background capabilities and PiP sound settings.
// SPDX-License-Identifier: MPL-2.0

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore

@MainActor
struct BackgroundExecutionSettingsView: View {
    @ObservedObject var center: SettingsCenter
    @ObservedObject var videoService: BackgroundVideoService
    @ObservedObject var audioService: PiPAudioService

    private var statusPiPEnabled: Bool { StatusPiPReleaseGate.isEnabled }

    var body: some View {
        Form {
            Section {
                Toggle("background.features.enhanced", isOn: Binding(
                    get: { center.backgroundExecutionOptions.enhancedBackgroundEnabled },
                    set: { value in Task { await center.setEnhancedBackgroundEnabled(value) } }
                ))
                .accessibilityIdentifier("background.enhanced.toggle")

                Toggle("background.features.pip", isOn: Binding(
                    get: { center.backgroundExecutionOptions.pictureInPictureEnabled },
                    set: { value in Task { await center.setPictureInPictureEnabled(value) } }
                ))
                .disabled(!statusPiPEnabled)
                .accessibilityIdentifier("background.pip.toggle")

                NavigationLink {
                    PiPAudioSettingsView(center: center, audioService: audioService)
                } label: {
                    Label("pip.audio.settings.title", systemImage: "speaker.wave.2")
                        .padding(.leading, 20)
                }
                .accessibilityIdentifier("background.pip.audio.settings")

                Toggle("background.features.screen_feedback", isOn: Binding(
                    get: { center.backgroundExecutionOptions.screenFeedbackEnabled },
                    set: { value in Task { await center.setScreenFeedbackEnabled(value) } }
                ))
                .disabled(!statusPiPEnabled)
                .accessibilityIdentifier("background.screenFeedback.toggle")
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
        .task { await center.loadBackgroundExecution() }
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
