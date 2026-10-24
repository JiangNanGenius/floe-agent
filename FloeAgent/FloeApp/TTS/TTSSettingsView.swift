// FloeApp — Voice output settings and live voice auditions.
#if canImport(UIKit)
import SwiftUI
import AVFoundation
import FloeCore
import FloeProviders

struct TTSSettingsView: View {
    @EnvironmentObject private var settings: TTSSettingsService
    var body: some View {
        Form {
            Section {
                NavigationLink { SpeechVoicePickerView() } label: {
                    LabeledContent("voice.settings.voice", value: settings.voiceDisplayName(for: settings.snapshot) ?? SpeechVoiceNames.current(settings.snapshot))
                }
                // Rate and intonation are written once by the shared output
                // effect for every route (system, local and cloud), so the two
                // compact controls stay available for every provider.
                HStack {
                    Text("voice.settings.rate")
                    Slider(value: Binding(get: { settings.snapshot.speechRateRatio }, set: { n in settings.update { $0.speechRateRatio = n } }), in: TTSPlaybackControls.rateRange, step: 0.05)
                    Text(settings.snapshot.speechRateRatio, format: .number.precision(.fractionLength(2))).monospacedDigit()
                }
                HStack {
                    Text("voice.settings.pitch")
                    Slider(value: Binding(get: { settings.snapshot.speechPitchSemitones }, set: { n in settings.update { $0.speechPitchSemitones = n } }), in: TTSPlaybackControls.pitchSemitoneRange, step: 1)
                    Text(settings.snapshot.speechPitchSemitones, format: .number.precision(.fractionLength(0)).sign(strategy: .always(includingZero: false))).monospacedDigit()
                }
            }
            Section {
                Toggle("voice.settings.autoread", isOn: Binding(get: { settings.snapshot.autoReadEnabled }, set: { n in settings.update { $0.autoReadEnabled = n } }))
                Toggle("voice.settings.barge_in", isOn: Binding(get: { settings.snapshot.allowBargeIn }, set: { n in settings.update { $0.allowBargeIn = n } }))
            }
            Section {
                NavigationLink("voice.local.title") { LocalSpeechSettingsView() }
                NavigationLink("voice.online.title") { OnlineSpeechServicesView() }
            }
        }.navigationTitle("settings.voice.title")
    }
}

enum SpeechVoiceNames {
    /// Ordinary surfaces always use the generic product label; concrete
    /// engine/repository names appear only inside the explicit pack detail.
    static func model(_ model: LocalSpeechModel) -> String {
        FloeL10n.l(model.isHidden ? "voice.local.legacy" : "voice.local.enhanced")
    }
    static func voice(_ id: String) -> String {
        ["uncle_fu": "Uncle Fu", "ono_anna": "Ono Anna", "default": FloeL10n.l("voice.local.voice.default")][id] ?? id.capitalized
    }
    /// Published reference voices display their catalog-provided qualified
    /// name; built-in ids keep the app-authored localizable mapping so the
    /// default voice is never shown as a hardcoded non-localized string.
    static func voice(_ voice: LocalSpeechModel.Voice) -> String {
        if voice.reference != nil, !voice.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return voice.name }
        return Self.voice(voice.id)
    }
    static func current(_ s: TTSSettingsSnapshot) -> String {
        if s.voiceID.isEmpty { return s.provider.title }
        if s.provider == .onDevice { return voice(s.voiceID) }
        if s.provider == .apple { return AVSpeechSynthesisVoice(identifier: s.voiceID)?.name ?? s.provider.title }
        if s.provider == .openAI { return s.voiceID.capitalized }
        return s.provider.title
    }
}

struct SpeechVoicePickerView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settings: TTSSettingsService
    @EnvironmentObject private var playback: SpeechService
    @Environment(\.continuousVoiceActive) private var voiceActive
    @AppStorage("voice.audition.text") private var sample = ""
    @AppStorage("voice.audition.kind") private var auditionKind = "zh"
    @State private var previewID: String?
    @State private var previewOwnerID = UUID()
    @State private var failure: String?
    var body: some View {
        List {
            Section {
                NavigationLink { SpeechAuditionTextView(text: $sample) } label: {
                    LabeledContent("voice.audition.content", value: FloeL10n.l("voice.audition." + auditionKind))
                }
                // Audition feedback belongs next to the control that triggers
                // it. On a phone the system-voice list below is long, so an
                // explanation parked at the end of the list is effectively
                // invisible after a tap that does nothing.
                if voiceActive {
                    Label { Text("voice.settings.audition.busy") } icon: { Image(systemName: "waveform") }
                        .foregroundStyle(.secondary)
                }
                if playback.activeOwnerID == previewOwnerID, playback.isSpeaking, playback.isPaused {
                    HStack {
                        Text("voice.settings.audition.paused").foregroundStyle(.secondary)
                        Spacer()
                        Button("voice.settings.audition.resume") { playback.resume() }
                            .frame(minHeight: 44)
                    }
                }
                if let key = auditionFailure {
                    Text(LocalizedStringKey(key)).foregroundStyle(.red)
                }
            }
            ForEach(settings.localVisibleModels) { model in
                Section {
                    if !settings.localInstalledModelIDs.contains(model.id) {
                        SpeechPackInstallState(model: model)
                    }
                    ForEach(model.voices) { voice in
                        let ready = settings.localInstalledModelIDs.contains(model.id)
                        let value = localChoice(model, voice: voice)
                        voiceRow(title: SpeechVoiceNames.voice(voice), detail: voice.languages.compactMap { Locale.current.localizedString(forLanguageCode: $0) }.joined(separator: " · "), id: model.id + "/" + voice.id, value: value, ready: ready) {
                            if ready { settings.choose(value) }
                        }
                    }
                } header: { Text(SpeechVoiceNames.model(model)) }
            }
            Section("voice.settings.service.system") {
                voiceRow(title: FloeL10n.l("voice.settings.voice.automatic"), detail: nil, id: "apple/auto", value: .systemDefault, ready: true) { settings.choose(.systemDefault) }
                ForEach(environment.ttsSpeechService.builtinVoices(for: .apple)) { voice in
                    let value = withVoice(.systemDefault, id: voice.voiceID)
                    voiceRow(title: voice.displayName, detail: nil, id: "apple/" + voice.voiceID, value: value, ready: true) { settings.choose(value) }
                }
            }
            ForEach(settings.configuredProfiles, id: \.profileIdentity) { profile in
                Section(profile.provider.title) {
                    let voices = environment.ttsSpeechService.builtinVoices(
                        for: profile.provider, modelID: profile.modelID)
                    if !profile.voiceID.isEmpty && !voices.contains(where: { $0.voiceID == profile.voiceID }) {
                        voiceRow(title: settings.voiceDisplayName(for: profile) ?? profile.voiceID, detail: profile.billingRoute.title, id: settings.profileID(profile) + "/" + profile.voiceID, value: profile, ready: true) { settings.choose(profile) }
                    }
                    ForEach(voices) { voice in
                        let choice = withVoice(profile, id: voice.voiceID)
                        voiceRow(title: voice.displayName, detail: profile.billingRoute.title, id: settings.profileID(profile) + "/" + voice.voiceID, value: choice, ready: true) { settings.choose(choice) }
                    }
                }
            }
            if let key = settings.localMigrationNote {
                Section {
                    Label { Text(LocalizedStringKey(key)) } icon: { Image(systemName: "exclamationmark.triangle") }
                        .foregroundStyle(.secondary)
                    Button("voice.action.retry") { Task { await settings.retryLocalValidation() } }
                }
            }
            if let key = settings.localCatalogErrorKey ?? settings.localInstallation.failureKey {
                Section { Text(LocalizedStringKey(key)).foregroundStyle(.red) }
            }
        }
        .navigationTitle("voice.settings.voice")
        .onAppear {
            if sample.isEmpty {
                auditionKind = FloeL10n.l("voice.audition.default_kind")
                sample = FloeL10n.l("voice.settings.audition.sample")
            }
        }
        .onDisappear {
            if playback.activeOwnerID == previewOwnerID { playback.stop() }
            playback.clearFailure(ownerID: previewOwnerID)
            previewID = nil
        }
    }
    private var auditionFailure: String? {
        failure ?? (playback.failureOwnerID == previewOwnerID ? playback.failureKey : nil)
    }
    private func withVoice(_ profile: TTSSettingsSnapshot, id: String) -> TTSSettingsSnapshot {
        var value = profile
        value.voiceID = id
        return value
    }
    private func localChoice(_ model: LocalSpeechModel, voice: LocalSpeechModel.Voice) -> TTSSettingsSnapshot {
        var s = settings.snapshot
        s.provider = .onDevice; s.modelID = model.id; s.voiceID = voice.id
        s.language = nil; s.connectionProviderID = nil; s.billingRoute = .payAsYouGo
        return s
    }
    private func voiceRow(title: String, detail: String?, id: String, value: TTSSettingsSnapshot, ready: Bool, select: @escaping () -> Void) -> some View {
        let selected = settings.snapshot.provider == value.provider && settings.snapshot.modelID == value.modelID && settings.snapshot.voiceID == value.voiceID && settings.snapshot.billingRoute == value.billingRoute
        let playing = previewID == id && playback.activeOwnerID == previewOwnerID && playback.isSpeaking
        return HStack(spacing: 12) {
            Button {
                if ready && value.provider.requiresCloudCredential { settings.rememberVoiceName(title, for: value) }
                select()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).foregroundStyle(.primary)
                        if let detail, !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    }
                    Spacer()
                    if selected { Image(systemName: "checkmark").accessibilityLabel("voice.local.selected") }
                }.frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!ready)
            if playing {
                // A paused preview is shown and resumed right here: the only
                // other resume lives on the message row, which is elsewhere.
                Button {
                    if playback.isPaused { playback.resume() } else { playback.pause() }
                } label: {
                    Image(systemName: playback.isPaused ? "play.circle" : "pause.circle")
                        .font(.title2).frame(width: 44, height: 44)
                }.buttonStyle(.borderless)
                    .accessibilityLabel(playback.isPaused ? "voice.settings.audition.resume" : "voice.settings.audition.pause")
            }
            Button {
                if playing { playback.stop(); previewID = nil }
                else { previewID = id; playback.preview(sample, settings: value, ownerID: previewOwnerID) }
            } label: {
                if playing && playback.isPreparing {
                    ZStack {
                        ProgressView().controlSize(.regular)
                        Image(systemName: "stop.fill").font(.system(size: 7))
                    }.frame(width: 44, height: 44)
                }
                else { Image(systemName: playing ? "stop.circle.fill" : "play.circle").font(.title2).frame(width: 44, height: 44) }
            }.buttonStyle(.borderless)
                .accessibilityLabel(playing ? "voice.settings.audition.stop" : "voice.settings.audition")
                .disabled(!playing && (!ready || voiceActive || sample.count > 600 || sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
        }
    }
}

private struct SpeechAuditionTextView: View {
    @Binding var text: String
    @AppStorage("voice.audition.kind") private var selection = "zh"
    private let choices: [(String, String)] = [
        ("zh", "你好，很高兴见到你。今天有什么想一起聊聊的？"),
        ("en", "Hi, it's good to see you. What would you like to talk about today?"),
        ("ja", "こんにちは。今日はどんなことを一緒に話しましょうか。"),
        ("zh-en", "今天的 meeting 很顺利，我们明天再 review 一下，then we can get started。"),
        ("ja-en", "今日の meeting ありがとう。明日の morning に、また一緒に review しましょう。"),
        ("zh-ja-en", "今天的 demo 很不错，ちょっと待ってね，我把 results 整理好，明天一緒に review しましょう。")
    ]
    var body: some View {
        Form {
            Section {
                Picker("voice.audition.content", selection: $selection) {
                    ForEach(choices, id: \.0) { Text(LocalizedStringKey("voice.audition." + $0.0)).tag($0.0) }
                    Text("voice.audition.custom").tag("custom")
                }.onChange(of: selection) { _, id in if let s = choices.first(where: { $0.0 == id }) { text = s.1 } }
            }
            Section {
                TextEditor(text: $text).frame(minHeight: 150).onChange(of: text) { _, value in
                    if let preset = choices.first(where: { $0.0 == selection }), value != preset.1 { selection = "custom" }
                }
            }
            if text.count > 600 { Section { Text("voice.audition.too_long").foregroundStyle(.red) } }
        }.navigationTitle("voice.audition.content")
    }
}

extension TTSSettingsSnapshot {
    var profileIdentity: String { provider.rawValue + "/" + billingRoute.rawValue }
}

extension TTSSpeakerProvider {
    var title: String {
        switch self {
        case .apple: return FloeL10n.l("voice.settings.service.system")
        case .onDevice: return FloeL10n.l("voice.settings.service.local")
        case .volcengine: return FloeL10n.l("voice.settings.service.volcengine")
        case .elevenLabs: return "ElevenLabs"
        case .openAI: return "OpenAI"
        case .alibaba: return FloeL10n.l("voice.settings.service.alibaba")
        }
    }
}
extension TTSBillingRoute {
    var title: String {
        switch self {
        case .agentPlan: return "Agent Plan"
        case .tokenPlan: return "Token Plan"
        case .payAsYouGo: return FloeL10n.l("voice.settings.channel.paygo")
        }
    }
}
#endif
