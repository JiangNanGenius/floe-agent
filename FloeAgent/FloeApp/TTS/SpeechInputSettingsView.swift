// FloeApp — Speech recognition preferences and model management.
#if canImport(UIKit)
import SwiftUI
import FloeCore

// Shared by dictation and continuous voice. No view owns the recognition engine.
enum VoiceRecognitionPreferences {
    static let methodKey = "voice.input.method.v1"
    enum Method: String, CaseIterable, Sendable { case automatic, system, enhanced }
    static var method: Method { UserDefaults.standard.string(forKey: methodKey).flatMap(Method.init(rawValue:)) ?? .automatic }
    static func title(_ method: Method) -> String { FloeL10n.l("voice.input.method." + method.rawValue) }
}

struct SpeechInputSettingsView: View {
    @AppStorage(VoiceRecognitionLanguage.defaultsKey) private var language = VoiceRecognitionLanguage.automatic.rawValue
    @AppStorage(VoiceRecognitionPreferences.methodKey) private var method = VoiceRecognitionPreferences.Method.automatic.rawValue
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
            Section { NavigationLink("voice.input.model") { EnhancedRecognitionModelView() } }
        }.navigationTitle("voice.input.title")
    }
}

private struct SpeechInputMethodView: View {
    @AppStorage(VoiceRecognitionPreferences.methodKey) private var method = VoiceRecognitionPreferences.Method.automatic.rawValue
    @State private var installed = false
    @State private var showModel = false
    var body: some View {
        List {
            ForEach(VoiceRecognitionPreferences.Method.allCases, id: \.rawValue) { option in
                Button {
                    if option == .enhanced && !installed { showModel = true }
                    else { method = option.rawValue }
                } label: {
                    HStack {
                        Text(VoiceRecognitionPreferences.title(option)).foregroundStyle(.primary)
                        Spacer()
                        if option == .enhanced && !installed { Image(systemName: "arrow.down.circle") }
                        else if method == option.rawValue { Image(systemName: "checkmark") }
                    }.frame(minHeight: 44)
                }
            }
        }.navigationTitle("voice.input.method")
            .navigationDestination(isPresented: $showModel) { EnhancedRecognitionModelView() }
            .task { installed = await WhisperModelStore.shared.isInstalled() }
            .onChange(of: showModel) { _, showing in if !showing { Task { installed = await WhisperModelStore.shared.isInstalled() } } }
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
                    Button("voice.local.download", systemImage: "arrow.down.circle") { Task { await WhisperModelStore.shared.beginInstallation() } }
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
                    Button("voice.local.remove", role: .destructive) {
                        Task {
                            do {
                                try await WhisperModelStore.shared.remove()
                                installed = false
                                if method == VoiceRecognitionPreferences.Method.enhanced.rawValue { method = VoiceRecognitionPreferences.Method.automatic.rawValue }
                            } catch WhisperModelStore.Failure.busy { failure = "voice.local.error.busy" }
                            catch { failure = "voice.local.error.remove" }
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
                    if state.error != nil { failure = "voice.local.error.install" }
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                }
            }
    }
}
#endif
