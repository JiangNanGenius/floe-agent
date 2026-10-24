// FloeApp — unified playback-source identity, listing and per-source voice filtering.
#if canImport(UIKit)
import Foundation
import FloeCore
import FloeProviders

/// Where spoken output currently comes from. Exactly one source is active at
/// a time: the built-in system voice, one installed local pack, or one
/// configured online profile (provider + billing channel). Identity is the
/// exact provider/channel/model/voice binding, never just a display label.
enum SpeechOutputSource: Hashable, Identifiable {
    case system
    case local(modelID: String)
    case online(provider: TTSSpeakerProvider, route: TTSBillingRoute)

    var id: String {
        switch self {
        case .system: return "system"
        case .local(let modelID): return "local.\(modelID)"
        case .online(let provider, let route):
            return "online.\(provider.rawValue).\(route.rawValue)"
        }
    }

    init(snapshot: TTSSettingsSnapshot) {
        switch snapshot.provider {
        case .apple: self = .system
        case .onDevice: self = .local(modelID: snapshot.modelID)
        default: self = .online(provider: snapshot.provider, route: snapshot.billingRoute)
        }
    }

    /// Source picker list: system first, then installed visible packs, then
    /// configured online profiles with their channel. Unconfigured drafts and
    /// uninstalled packs are never listed, so a paid channel can never be
    /// entered by a placeholder tap.
    static func available(
        installedVisibleModels: [LocalSpeechModel],
        configuredProfiles: [TTSSettingsSnapshot]
    ) -> [SpeechOutputSource] {
        var sources: [SpeechOutputSource] = [.system]
        sources.append(contentsOf: installedVisibleModels.map { .local(modelID: $0.id) })
        sources.append(contentsOf: configuredProfiles
            .filter { $0.provider.requiresCloudCredential }
            .map { .online(provider: $0.provider, route: $0.billingRoute) })
        return sources
    }
}

/// One voice row inside exactly one source. The snapshot carries the exact
/// provider/channel/model/voice identity applied when the row is chosen.
struct SpeechOutputVoiceOption: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String?
    let snapshot: TTSSettingsSnapshot
    let ready: Bool
}

/// Pure per-source voice filtering. Callers pass the catalog for the selected
/// source only; a saved custom voice ID that is absent from that catalog is
/// kept with its saved display name, so cloning/voices-list services remain
/// selectable after an explicit choice.
enum SpeechOutputVoices {
    static func options(
        for source: SpeechOutputSource,
        current: TTSSettingsSnapshot,
        localModel: LocalSpeechModel?,
        onlineProfile: TTSSettingsSnapshot?,
        catalogVoices: [TTSSpeechVoice],
        savedVoiceDisplayName: String?
    ) -> [SpeechOutputVoiceOption] {
        switch source {
        case .system:
            var options = [SpeechOutputVoiceOption(
                id: "apple/auto",
                title: FloeL10n.l("voice.settings.voice.automatic"),
                detail: nil,
                snapshot: .systemDefault,
                ready: true)]
            for voice in catalogVoices where voice.kind == .builtin || voice.kind == .listed {
                var value = TTSSettingsSnapshot.systemDefault
                value.voiceID = voice.voiceID
                options.append(SpeechOutputVoiceOption(
                    id: "apple/" + voice.voiceID,
                    title: voice.displayName,
                    detail: nil,
                    snapshot: value,
                    ready: true))
            }
            return options
        case .local(let modelID):
            guard let model = localModel, model.id == modelID else { return [] }
            var options = model.voices.map { voice in
                SpeechOutputVoiceOption(
                    id: modelID + "/" + voice.id,
                    title: SpeechVoiceNames.voice(voice),
                    detail: voice.languages.compactMap { Locale.current.localizedString(forLanguageCode: $0) }.joined(separator: " · "),
                    snapshot: localSnapshot(modelID: modelID, voiceID: voice.id),
                    ready: true)
            }
            if current.provider == .onDevice, current.modelID == modelID,
               !current.voiceID.isEmpty,
               !model.voices.contains(where: { $0.id == current.voiceID }) {
                options.append(SpeechOutputVoiceOption(
                    id: modelID + "/" + current.voiceID,
                    title: SpeechVoiceNames.voice(current.voiceID),
                    detail: nil,
                    snapshot: localSnapshot(modelID: modelID, voiceID: current.voiceID),
                    ready: true))
            }
            return options
        case .online(let provider, let route):
            let base: TTSSettingsSnapshot?
            if let onlineProfile, onlineProfile.provider == provider,
               onlineProfile.billingRoute == route {
                base = onlineProfile
            } else if current.provider == provider, current.billingRoute == route,
                      provider.requiresCloudCredential {
                base = current
            } else {
                base = nil
            }
            guard let base else { return [] }
            let binding = "\(provider.rawValue).\(route.rawValue)"
            var options: [SpeechOutputVoiceOption] = []
            if !base.voiceID.isEmpty, !catalogVoices.contains(where: { $0.voiceID == base.voiceID }) {
                options.append(SpeechOutputVoiceOption(
                    id: binding + "/" + base.voiceID,
                    title: savedVoiceDisplayName ?? base.voiceID,
                    detail: nil,
                    snapshot: withVoice(base, id: base.voiceID),
                    ready: true))
            }
            options.append(contentsOf: catalogVoices.map { voice in
                SpeechOutputVoiceOption(
                    id: binding + "/" + voice.voiceID,
                    title: voice.displayName,
                    detail: nil,
                    snapshot: withVoice(base, id: voice.voiceID),
                    ready: true)
            })
            return options
        }
    }

    private static func withVoice(_ base: TTSSettingsSnapshot, id: String) -> TTSSettingsSnapshot {
        var value = base
        value.voiceID = id
        return value
    }

    private static func localSnapshot(modelID: String, voiceID: String) -> TTSSettingsSnapshot {
        TTSSettingsSnapshot(provider: .onDevice, billingRoute: .payAsYouGo,
                            modelID: modelID, voiceID: voiceID)
    }
}
#endif
