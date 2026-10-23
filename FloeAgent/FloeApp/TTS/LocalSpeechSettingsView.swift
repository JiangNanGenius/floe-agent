// FloeApp — Service-owned downloadable speech packs.
#if canImport(UIKit)
import SwiftUI
import FloeCore

/// One progress surface reused by the pack list, the voice picker and the
/// pack detail: all three render the same service-published installation, so
/// cancel/retry behave identically wherever the user is, and the transfer is
/// owned by the service, never by view lifetime.
struct SpeechPackInstallState: View {
    let model: LocalSpeechModel
    @EnvironmentObject private var settings: TTSSettingsService

    var body: some View {
        let installation = settings.localInstallation
        if installation.running && installation.modelID == model.id {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: min(1, installation.downloadPercent / 100))
                HStack(spacing: 8) {
                    Text(phaseText(installation))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("voice.local.cancel") { Task { await settings.cancelInstallation() } }
                        .font(.footnote)
                }
            }
        } else if let operation = settings.localProgressOperation, operation.modelID == model.id {
            // Between "bytes installed" and a finished transition: the pack is
            // not presented as ready until validation (or legacy removal) ends.
            HStack(spacing: 8) {
                ProgressView()
                Text(LocalizedStringKey(operation.key))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if settings.localInstalledModelIDs.contains(model.id) {
            Label("voice.local.installed", systemImage: "checkmark.circle")
        } else if !model.isHidden {
            Button(installation.modelID == model.id && installation.failureKey != nil ? "voice.action.retry" : "voice.local.download",
                   systemImage: "arrow.down.circle") {
                Task { await settings.install(model) }
            }.disabled(installation.running)
        }
    }

    private func phaseText(_ installation: LocalSpeechModelStore.Installation) -> String {
        var parts: [String] = [FloeL10n.l("voice.local.phase." + installation.phase.rawValue)]
        if installation.phase == .downloading {
            parts.append("\(Int(installation.downloadPercent))%")
            parts.append(ByteCountFormatter.string(fromByteCount: installation.completed, countStyle: .file)
                       + "/" + ByteCountFormatter.string(fromByteCount: installation.total, countStyle: .file))
            // Real network throughput only; cached or committed bytes never
            // inflate this number (the store reports 0 outside live samples).
            parts.append(ByteCountFormatter.string(fromByteCount: installation.bytesPerSecond, countStyle: .file) + "/s")
        }
        return parts.joined(separator: " · ")
    }
}

struct LocalSpeechSettingsView: View {
    @EnvironmentObject private var settings: TTSSettingsService
    @State private var failure: String?
    var body: some View {
        List {
            ForEach(settings.localManagedModels) { model in
                Section {
                    NavigationLink { SpeechPackDetailView(model: model) } label: {
                        LabeledContent(SpeechVoiceNames.model(model), value: ByteCountFormatter.string(fromByteCount: model.byteCount, countStyle: .file))
                    }
                    SpeechPackInstallState(model: model)
                }
            }
            if let key = settings.localMigrationNote {
                Section {
                    Label { Text(LocalizedStringKey(key)) } icon: { Image(systemName: "exclamationmark.triangle") }
                        .foregroundStyle(.secondary)
                    Button("voice.action.retry") { Task { await settings.retryLocalValidation() } }
                }
            }
            if let key = settings.localCatalogErrorKey ?? failure ?? settings.localInstallation.failureKey {
                Section { Text(LocalizedStringKey(key)).foregroundStyle(.red) }
            }
        }.navigationTitle("voice.local.title")
    }
}

struct SpeechPackDetailView: View {
    let model: LocalSpeechModel
    @EnvironmentObject private var playback: SpeechService
    @EnvironmentObject private var settings: TTSSettingsService
    @Environment(\.dismiss) private var dismiss
    @State private var failure: String?
    var body: some View {
        Form {
            Section {
                LabeledContent("voice.local.name", value: model.title)
                LabeledContent("voice.local.size", value: ByteCountFormatter.string(fromByteCount: model.byteCount, countStyle: .file))
                LabeledContent("voice.local.license", value: model.license)
                LabeledContent("voice.local.repository", value: model.repository)
                Text(model.revision).font(.caption.monospaced()).textSelection(.enabled)
            }
            Section {
                SpeechPackInstallState(model: model)
            }
            if settings.localInstalledModelIDs.contains(model.id) {
                Section {
                    Button("voice.local.remove", role: .destructive) {
                        Task {
                            do {
                                if playback.activeLocalModelID == model.id { await playback.stopAndWait() }
                                try await LocalSpeechModelStore.shared.remove(model)
                                if settings.snapshot.provider == .onDevice && settings.snapshot.modelID == model.id {
                                    settings.choose(.systemDefault)
                                }
                                await settings.refreshAfterExternalChange()
                                dismiss()
                            } catch LocalSpeechModelStore.Failure.busy { failure = "voice.local.error.busy" }
                            catch { failure = "voice.local.error.remove" }
                        }
                    }
                }
            }
            if let failure { Text(LocalizedStringKey(failure)).foregroundStyle(.red) }
        }.navigationTitle(SpeechVoiceNames.model(model))
    }
}
#endif
