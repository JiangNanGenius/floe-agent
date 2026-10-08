// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI

import FloeCore
struct WhisperSettingsView: View {
    @State private var installed = false
    @State private var completed: Int64 = 0
    @State private var total: Int64 = 0
    @State private var running = false
    @State private var failure: String?
    var body: some View {
        Form {
            Section("voice.whisper_settings_view.on_device_recognition") {
                Label("voice.whisper_settings_view.whisper_small_multilingual", systemImage: "waveform")
                Text("voice.whisper_settings_view.english_mandarin_and_mixed_speech_prefer")
                Text(installed ? "voice.whisper_settings_view.the_model_is_installed_the_runtime" : "voice.whisper_settings_view.not_installed_yet_currently_using_apple")
                    .font(.caption).foregroundStyle(.secondary)
                if running {
                    ProgressView(value: Double(completed), total: Double(max(1, total)))
                    Text(FloeL10n.l("voice.whisper_settings_view.downloaded", ByteCountFormatter.string(fromByteCount: completed, countStyle: .file), ByteCountFormatter.string(fromByteCount: total, countStyle: .file)))
                        .font(.caption)
                    Button("voice.whisper_settings_view.cancel_download", role: .cancel) { Task { await WhisperModelStore.shared.cancelInstallation() } }
                } else {
                    Button(installed ? "voice.whisper_settings_view.download_model_again" : "voice.whisper_settings_view.download_model") {
                        Task { await WhisperModelStore.shared.beginInstallation() }

                    }
                    if installed {
                        Button("voice.whisper_settings_view.remove_model", role: .destructive) {
                            Task {
                                do { try await WhisperModelStore.shared.remove(); installed = false }
                                catch { failure = error.localizedDescription }
                            }
                        }
                    }
                }
                if let failure { Text(failure).foregroundStyle(.red) }
            }
            Section {
                Text("voice.whisper_settings_view.the_download_uses_about_500_mb")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("voice.whisper_settings_view.speech_recognition")
            .task {
                while !Task.isCancelled {
                    installed = await WhisperModelStore.shared.isInstalled()
                    let state = await WhisperModelStore.shared.installationState()
                    running = state.running; completed = state.completed; total = state.total
                    failure = state.error
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
                }
            }
    }
}
#endif
