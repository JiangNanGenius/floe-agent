// FloeApp — Speech recognition preferences, cloud profiles and model management.
#if canImport(UIKit)
import SwiftUI
import FloeCore

// Shared by dictation and continuous voice. No view owns the recognition engine.
enum VoiceRecognitionPreferences {
    static let methodKey = "voice.input.method.v1"
    enum Method: String, CaseIterable, Sendable {
        case automatic
        case system
        case enhanced
        /// Explicit cloud primary. Requires a configured profile; an unusable
        /// selection surfaces a normal configuration error instead of a silent
        /// local switch.
        case cloud
    }
    static var method: Method { UserDefaults.standard.string(forKey: methodKey).flatMap(Method.init(rawValue:)) ?? .automatic }
    static func title(_ method: Method) -> String { FloeL10n.l("voice.input.method." + method.rawValue) }
}

struct SpeechInputSettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject private var cloudStore = CloudASRSettingsStore.shared
    @AppStorage(VoiceRecognitionLanguage.defaultsKey) private var language = VoiceRecognitionLanguage.automatic.rawValue
    @AppStorage(VoiceRecognitionPreferences.methodKey) private var method = VoiceRecognitionPreferences.Method.automatic.rawValue
    @AppStorage(VoiceRecognitionPreloadPolicy.enabledDefaultsKey) private var preloadEnabled = false

    var body: some View {
        Form {
            Section {
                NavigationLink { SpeechInputMethodView() } label: {
                    LabeledContent("voice.input.method", value: VoiceRecognitionPreferences.title(VoiceRecognitionPreferences.Method(rawValue: method) ?? .automatic))
                }
                Picker("settings.general_settings_view.recognition_language", selection: $language) {
                    ForEach(VoiceRecognitionLanguage.allCases, id: \.rawValue) { choice in
                        Text(choice.displayName).tag(choice.rawValue)
                    }
                }
            }
            Section {
                NavigationLink("voice.cloud.profiles.title") {
                    CloudASRProfilesView(
                        store: cloudStore,
                        preload: environment.voiceRecognitionPreload)
                }
                if let primary = cloudStore.primaryProfile {
                    LabeledContent("voice.cloud.profile.primary", value: primary.name)
                }
            } footer: {
                Text("voice.cloud.profiles.settings_footer")
            }
            Section {
                Toggle("voice.input.preload", isOn: Binding(
                    get: { preloadEnabled },
                    set: { value in
                        Task { await environment.voiceRecognitionPreload.setEnabled(value) }
                    }))
            } footer: {
                Text("voice.input.preload.footer")
            }
            Section { NavigationLink("voice.input.model") { EnhancedRecognitionModelView() } }
            Section {
                NavigationLink("voice.assistant.transcription") {
                    AssistantAudioSettingsView(
                        mode: .transcription,
                        assistant: environment.assistantAudioService)
                }
            } footer: {
                Text("voice.assistant.transcription.footer")
            }
        }
        .navigationTitle("voice.input.title")
        .onAppear {
            Task { await environment.voiceRecognitionPreload.refreshAfterSettingsEntry() }
        }
    }
}

private struct SpeechInputMethodView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject private var cloudStore = CloudASRSettingsStore.shared
    @AppStorage(VoiceRecognitionPreferences.methodKey) private var method = VoiceRecognitionPreferences.Method.automatic.rawValue
    @State private var installed = false
    @State private var showModel = false
    @State private var showCloudProfiles = false

    var body: some View {
        List {
            ForEach(VoiceRecognitionPreferences.Method.allCases, id: \.rawValue) { option in
                Button {
                    select(option)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(VoiceRecognitionPreferences.title(option)).foregroundStyle(.primary)
                            if option == .cloud {
                                Text(cloudDetail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if option == .enhanced && !installed { Image(systemName: "arrow.down.circle") }
                        else if option == .cloud && cloudStore.readyProfiles.isEmpty {
                            Image(systemName: "key")
                        } else if method == option.rawValue { Image(systemName: "checkmark") }
                    }.frame(minHeight: 44)
                }
            }
            Section {
                NavigationLink("voice.cloud.profiles.title") {
                    CloudASRProfilesView(
                        store: cloudStore,
                        preload: environment.voiceRecognitionPreload)
                }
            }
        }.navigationTitle("voice.input.method")
            .navigationDestination(isPresented: $showModel) { EnhancedRecognitionModelView() }
            .navigationDestination(isPresented: $showCloudProfiles) {
                CloudASRProfilesView(
                    store: cloudStore,
                    preload: environment.voiceRecognitionPreload)
            }
            .task { installed = await WhisperModelStore.shared.isInstalled() }
            .onChange(of: showModel) { _, showing in if !showing { Task { installed = await WhisperModelStore.shared.isInstalled() } } }
    }

    private var cloudDetail: String {
        if let primary = cloudStore.primaryProfile {
            return "\(primary.name) · \(primary.fileModelID)"
        }
        return FloeL10n.l("voice.cloud.profiles.empty")
    }

    private func select(_ option: VoiceRecognitionPreferences.Method) {
        if option == .enhanced && !installed {
            showModel = true
            return
        }
        if option == .cloud && cloudStore.profiles.isEmpty {
            showCloudProfiles = true
            return
        }
        method = option.rawValue
        Task { await environment.voiceRecognitionPreload.syncPrimaryRoute() }
    }
}

private struct EnhancedRecognitionModelView: View {
    @AppStorage(VoiceRecognitionPreferences.methodKey) private var method = VoiceRecognitionPreferences.Method.automatic.rawValue
    @State private var installed = false
    @State private var running = false
    @State private var completed: Int64 = 0
    @State private var total: Int64 = 1
    @State private var failure: String?
    var body: some View {
        Form {
            Section {
                Label("voice.input.enhanced", systemImage: "waveform")
                if running {
                    ProgressView(value: Double(completed), total: Double(max(1, total)))
                    Button("voice.local.cancel") { Task { await WhisperModelStore.shared.cancelInstallation() } }
                } else if installed {
                    Label("voice.local.installed", systemImage: "checkmark.circle")
                    Button("voice.input.use_model") { method = VoiceRecognitionPreferences.Method.enhanced.rawValue }
                } else {
                    Button("voice.input.model.download", systemImage: "arrow.down.circle") { failure = nil; Task { await WhisperModelStore.shared.beginInstallation() } }
                }
                NavigationLink("voice.local.source") {
                    Form {
                        LabeledContent("voice.local.name", value: "Whisper small multilingual")
                        LabeledContent("voice.local.repository", value: "argmaxinc/whisperkit-coreml")
                        LabeledContent("voice.local.license", value: "MIT")
                    }.navigationTitle("voice.local.source")
                }
            }
            if installed {
                Section {
                    Button("voice.input.model.remove", role: .destructive) {
                        Task {
                            do {
                                try await WhisperModelStore.shared.remove()
                                installed = false
                                if method == VoiceRecognitionPreferences.Method.enhanced.rawValue { method = VoiceRecognitionPreferences.Method.automatic.rawValue }
                            } catch WhisperModelStore.Failure.busy { failure = "voice.input.model.error.busy" }
                            catch { failure = "voice.input.model.error.remove" }
                        }
                    }
                }
            }
            if let failure { Section { Text(LocalizedStringKey(failure)).foregroundStyle(.red) } }
        }.navigationTitle("voice.input.model")
            .task {
                while !Task.isCancelled {
                    installed = await WhisperModelStore.shared.isInstalled()
                    let state = await WhisperModelStore.shared.installationState()
                    running = state.running; completed = state.completed; total = state.total
                    if state.error != nil { failure = "voice.input.model.error.install" }
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                }
            }
    }
}
#endif
