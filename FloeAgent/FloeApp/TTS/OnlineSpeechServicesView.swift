// FloeApp — Explicit online speech accounts, separate from voice selection.
#if canImport(UIKit)
import SwiftUI
import FloeCore
import FloeProviders

struct OnlineSpeechServicesView: View {
    @EnvironmentObject private var settings: TTSSettingsService
    @State private var editor: SpeechProfileDraft?
    var body: some View {
        List {
            ForEach(settings.configuredProfiles, id: \.profileIdentity) { profile in
                Button { editor = SpeechProfileDraft(value: profile) } label: {
                    LabeledContent(profile.provider.title, value: profile.billingRoute.title).foregroundStyle(.primary)
                }
            }
            Section {
                Menu("voice.online.add", systemImage: "plus") {
                    ForEach(TTSSpeakerProvider.allCases.filter(\.requiresCloudCredential), id: \.self) { provider in
                        Button(provider.title) {
                            let route = provider.supportedBillingRoutes.first ?? .payAsYouGo
                            editor = SpeechProfileDraft(value: settings.profile(provider: provider, route: route))
                        }
                    }
                }
            }
        }.navigationTitle("voice.online.title")
            .sheet(item: $editor) { SpeechProfileEditor(initial: $0.value) }
    }
}

private struct SpeechProfileDraft: Identifiable {
    let id = UUID()
    let value: TTSSettingsSnapshot
}

private struct SpeechProfileEditor: View {
    let initial: TTSSettingsSnapshot
    @Environment(\.dismiss) private var dismiss
    @Environment(\.continuousVoiceActive) private var voiceActive
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settings: TTSSettingsService
    @EnvironmentObject private var playback: SpeechService
    @State private var draft: TTSSettingsSnapshot
    @State private var key = ""
    @State private var failure: String?
    @State private var voices: [String: String] = [:]
    @State private var fetching = false
    @State private var testing = false
    init(initial: TTSSettingsSnapshot) { self.initial = initial; _draft = State(initialValue: initial) }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if draft.provider.supportedBillingRoutes.count > 1 {
                        Picker("voice.settings.channel", selection: $draft.billingRoute) {
                            ForEach(draft.provider.supportedBillingRoutes, id: \.self) { Text($0.title).tag($0) }
                        }.onChange(of: draft.billingRoute) { _, route in
                            key = ""; voices = [:]; failure = nil
                            draft = settings.profile(provider: draft.provider, route: route)
                            prepareDefaults()
                            if testing { playback.stop(); testing = false }
                        }
                    }
                    if draft.provider == .alibaba && draft.billingRoute == .payAsYouGo {
                        Picker("voice.settings.region", selection: Binding(get: { draft.alibabaRegion ?? "cn-beijing" }, set: { draft.alibabaRegion = $0 })) {
                            Text("voice.settings.region.china").tag("cn-beijing")
                            Text("voice.settings.region.international").tag("ap-southeast-1")
                        }
                    }
                    if draft.provider == .openAI {
                        TextField("voice.settings.api.url", text: Binding(
                            get: { draft.openAIBaseURL ?? "" },
                            set: { draft.openAIBaseURL = $0 }
                        ), prompt: Text(verbatim: "https://api.openai.com/v1"))
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    SecureField(settings.hasCredential(for: draft) ? "voice.settings.key.replace" : "voice.settings.key", text: $key)
                        .keyboardType(.asciiCapable)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section {
                    TextField("voice.settings.model", text: $draft.modelID)
                        .keyboardType(.asciiCapable)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Menu("voice.settings.model.choose") {
                        ForEach(suggestedModels, id: \.self) { model in Button(model) { draft.modelID = model } }
                    }
                    TextField("voice.settings.voice.id", text: $draft.voiceID)
                        .keyboardType(.asciiCapable)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if draft.provider == .elevenLabs {
                        Button("voice.settings.voice.refresh") { Task { await fetchVoices() } }.disabled(fetching || !canAuthenticate)
                        if fetching { ProgressView() }
                        ForEach(voices.keys.sorted(), id: \.self) { id in Button(voices[id] ?? id) { draft.voiceID = id } }
                    }
                    Button(testing && playback.isSpeaking ? "voice.settings.audition.stop" : "voice.online.test", systemImage: testing && playback.isSpeaking ? "stop.fill" : "play.fill") {
                        if testing && playback.isSpeaking { playback.stop(); testing = false }
                        else {
                            // Validate the endpoint before spending a request:
                            // the router repeats this check, but the editor can
                            // name the field that needs attention.
                            if draft.provider == .openAI, let base = draft.openAIBaseURL,
                               TTSOpenAISpeechEndpoint.validationProblem(for: base) != nil {
                                failure = "voice.error.endpoint_invalid"
                                return
                            }
                            if draft.provider == .openAI, enteredCredential.isEmpty,
                               TTSOpenAISpeechEndpoint.originChanged(
                                   from: settings.profile(provider: draft.provider, route: draft.billingRoute).openAIBaseURL,
                                   to: draft.openAIBaseURL) {
                                failure = "voice.error.endpoint_key_required"
                                return
                            }
                            failure = nil
                            testing = true
                            playback.preview(FloeL10n.l("voice.settings.audition.sample"), settings: draft, credential: enteredCredential.isEmpty ? nil : enteredCredential)
                        }
                    }.disabled(voiceActive || !canAuthenticate || draft.modelID.isEmpty || draft.voiceID.isEmpty)
                }
                if let message = failure ?? (testing ? playback.failureKey : nil) {
                    Section { Text(LocalizedStringKey(message)).foregroundStyle(.red) }
                }
                if settings.hasCredential(for: draft) {
                    Section { Button("voice.online.remove", role: .destructive) {
                        do { if testing { playback.stop() }; try settings.removeProfile(draft); dismiss() }
                        catch { failure = "voice.error.key_save" }
                    } }
                }
            }.navigationTitle(draft.provider.title)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("action.cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("action.save") {
                        do {
                            try settings.saveProfile(draft, credential: key)
                            if let name = voices[draft.voiceID] { settings.rememberVoiceName(name, for: draft) }
                            key = ""; dismiss()
                        }
                        catch { failure = Self.saveFailureKey(for: error) }
                    }.disabled(!canAuthenticate || draft.modelID.isEmpty || draft.voiceID.isEmpty) }
                }
                .onAppear { prepareDefaults() }
                .onDisappear { key = ""; if testing { playback.stop() } }
        }
    }
    private var enteredCredential: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canAuthenticate: Bool { !enteredCredential.isEmpty || settings.hasCredential(for: draft) }
    private var suggestedModels: [String] {
        let models = environment.ttsSpeechService.suggestedModels(for: draft.provider)
        if draft.provider == .volcengine {
            return models.filter { VolcengineSpeechAdapter.resourceID(forModel: $0, route: draft.billingRoute) != nil }
        }
        return models
    }
    private func prepareDefaults() {
        if draft.modelID.isEmpty { draft.modelID = suggestedModels.first ?? "" }
        if draft.provider == .openAI && draft.voiceID.isEmpty { draft.voiceID = "alloy" }
    }
    private func fetchVoices() async {
        let owner = draft.profileIdentity
        fetching = true; defer { fetching = false }
        do {
            let credential = enteredCredential.isEmpty ? try await settings.credential(for: draft) : enteredCredential
            let result = try await environment.ttsSpeechService.fetchVoiceCatalog(provider: draft.provider, credential: credential)
            guard owner == draft.profileIdentity else { return }
            voices = Dictionary(result.map { ($0.voiceID, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        } catch { failure = SpeechFailureCopy.key(for: error) }
    }

    /// Save failures name the field that needs attention instead of folding
    /// every outcome into one key error. Endpoint messages stay short and
    /// actionable in both languages.
    private static func saveFailureKey(for error: Error) -> String {
        if let failure = error as? TTSSettingsFailure {
            switch failure {
            case .credentialChangedRequiresNewKey: return "voice.error.endpoint_key_required"
            case .missingCredential: return "voice.error.key_save"
            }
        }
        if let synthesis = error as? TTSSynthesisError,
           case .invalidConfiguration = synthesis {
            return "voice.error.endpoint_invalid"
        }
        return "voice.error.key_save"
    }
}
#endif
