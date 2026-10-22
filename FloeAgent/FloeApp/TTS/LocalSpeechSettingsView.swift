// FloeApp — Service-owned downloadable speech packs.
#if canImport(UIKit)
import SwiftUI

struct LocalSpeechSettingsView: View {
    @EnvironmentObject private var settings: TTSSettingsService
    @State private var models: [LocalSpeechModel] = []
    @State private var installed = Set<String>()
    @State private var installation = LocalSpeechModelStore.Installation()
    @State private var failure: String?
    var body: some View {
        List {
            ForEach(models) { model in
                Section {
                    NavigationLink { SpeechPackDetailView(model: model) } label: {
                        LabeledContent(SpeechVoiceNames.model(model), value: ByteCountFormatter.string(fromByteCount: model.byteCount, countStyle: .file))
                    }
                    if installation.running && installation.modelID == model.id {
                        ProgressView(value: Double(installation.completed), total: Double(max(1, installation.total)))
                        Button("voice.local.cancel") { Task { await settings.cancelInstallation() } }
                    } else if installed.contains(model.id) {
                        Label("voice.local.installed", systemImage: "checkmark.circle")
                    } else {
                        Button(installation.modelID == model.id && installation.failureKey != nil ? "voice.action.retry" : "voice.local.download", systemImage: "arrow.down.circle") {
                            Task { await settings.install(model) }
                        }.disabled(installation.running)
                    }
                }
            }
            if let key = failure ?? installation.failureKey { Section { Text(LocalizedStringKey(key)).foregroundStyle(.red) } }
        }.navigationTitle("voice.local.title")
            .task {
                do { models = try await LocalSpeechModelStore.shared.catalog() }
                catch { failure = "voice.local.error.catalog"; return }
                while !Task.isCancelled {
                    installation = await LocalSpeechModelStore.shared.state()
                    var found = Set<String>()
                    for m in models { if await LocalSpeechModelStore.shared.isInstalled(m) { found.insert(m.id) } }
                    installed = found
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                }
            }
    }
}

private struct SpeechPackDetailView: View {
    let model: LocalSpeechModel
    @EnvironmentObject private var playback: SpeechService
    @EnvironmentObject private var settings: TTSSettingsService
    @Environment(\.dismiss) private var dismiss
    @State private var failure: String?
    @State private var installed = false
    var body: some View {
        Form {
            Section {
                LabeledContent("voice.local.name", value: model.title)
                LabeledContent("voice.local.size", value: ByteCountFormatter.string(fromByteCount: model.byteCount, countStyle: .file))
                LabeledContent("voice.local.license", value: model.license)
                LabeledContent("voice.local.repository", value: model.repository)
                Text(model.revision).font(.caption.monospaced()).textSelection(.enabled)
            }
            if installed {
                Section {
                    Button("voice.local.remove", role: .destructive) {
                        Task {
                            do {
                                if playback.activeLocalModelID == model.id { await playback.stopAndWait() }
                                try await LocalSpeechModelStore.shared.remove(model)
                                if settings.snapshot.provider == .onDevice && settings.snapshot.modelID == model.id {
                                    settings.choose(.systemDefault)
                                }
                                dismiss()
                            } catch LocalSpeechModelStore.Failure.busy { failure = "voice.local.error.busy" }
                            catch { failure = "voice.local.error.remove" }
                        }
                    }
                }
            }
            if let failure { Text(LocalizedStringKey(failure)).foregroundStyle(.red) }
        }.navigationTitle(SpeechVoiceNames.model(model))
            .task { installed = await LocalSpeechModelStore.shared.isInstalled(model) }
    }
}
#endif
