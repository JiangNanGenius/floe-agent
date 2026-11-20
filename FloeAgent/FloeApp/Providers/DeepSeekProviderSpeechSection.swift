// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeCore

struct DeepSeekProviderSpeechSection: View {
    let environment: AppEnvironment
    private enum Direction: String, Identifiable { case input, output; var id: String { rawValue } }
    @State private var direction: Direction?

    var body: some View {
        Section {
            Button { direction = .input } label: {
                Label(FloeL10n.l("voice.whisper_settings_view.speech_recognition"), systemImage: "waveform")
            }.accessibilityIdentifier("providers.deepseek.speech.input")
            Button { direction = .output } label: {
                Label(FloeL10n.l("app.deep_seek_provider_speech_section.read_aloud"), systemImage: "speaker.wave.2")
            }.accessibilityIdentifier("providers.deepseek.speech.output")
        } header: {
            Text(FloeL10n.l("app.deep_seek_provider_speech_section.deepseek_speech"))
        }
        .sheet(item: $direction) { direction in
            switch direction {
            case .input:
                let store = environment.cloudASRSettingsStore
                let existing = store.primaryProfile.flatMap { $0.provider == .deepSeek ? $0 : nil }
                    ?? store.profiles.first { $0.provider == .deepSeek }
                NavigationStack {
                    CloudASRProfileEditor(store: store, original: existing ?? .deepSeek(),
                        preload: environment.voiceRecognitionPreload, onDone: { self.direction = nil })
                }
            case .output:
                SpeechProfileEditor(initial: environment.ttsSettingsService.profile(provider: .deepSeek, route: .payAsYouGo))
                    .environmentObject(environment)
                    .environmentObject(environment.ttsSettingsService)
                    .environmentObject(environment.speechService)
            }
        }
    }
}
#endif
