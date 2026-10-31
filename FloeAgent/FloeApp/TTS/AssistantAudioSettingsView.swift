// FloeApp — Assistant-only file transcription / generated-audio settings.
#if canImport(UIKit)
import SwiftUI
import FloeCore

enum AssistantAudioSettingsMode: String, Hashable {
    case transcription
    case synthesis

    var capability: AssistantAudioCapability {
        switch self {
        case .transcription: return .transcription
        case .synthesis: return .synthesis
        }
    }

    var titleKey: String {
        switch self {
        case .transcription: return "voice.assistant.transcription"
        case .synthesis: return "voice.assistant.synthesis"
        }
    }

    var footerKey: String {
        switch self {
        case .transcription: return "voice.assistant.transcription.footer"
        case .synthesis: return "voice.assistant.synthesis.footer"
        }
    }
}

struct AssistantAudioSettingsView: View {
    let mode: AssistantAudioSettingsMode
    @ObservedObject var assistant: AssistantAudioService
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        List {
            prioritySection
            availabilitySection
            if mode == .transcription {
                profilesSection
            }
        }
        .navigationTitle(LocalizedStringKey(mode.titleKey))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
        }
        .onAppear {
            Task { await assistant.refresh() }
        }
    }

    private var orderedServices: [AssistantAudioServiceDescriptor] {
        assistant.orderedServices(for: mode.capability)
    }

    private var prioritySection: some View {
        Section {
            ForEach(orderedServices) { service in
                VStack(alignment: .leading, spacing: 2) {
                    Text(serviceTitle(service))
                    if let detail = serviceDetail(service) {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 44)
            }
            .onMove { source, destination in
                var ids = orderedServices.map(\.id)
                ids.move(fromOffsets: source, toOffset: destination)
                assistant.setPriority(ids, for: mode.capability)
            }
            if orderedServices.isEmpty {
                Text(LocalizedStringKey(mode == .transcription
                    ? "voice.assistant.no_transcription"
                    : "voice.assistant.no_synthesis"))
                    .foregroundStyle(.secondary)
            }
            if !assistant.priorityIDs(for: mode.capability).isEmpty {
                Button("voice.assistant.priority.reset") {
                    assistant.setPriority([], for: mode.capability, preservingUnavailable: false)
                }
            }
        } header: {
            Text("voice.assistant.priority")
        } footer: {
            Text("voice.assistant.priority.footer")
        }
    }

    private var availabilitySection: some View {
        Section {
            if mode == .transcription, !assistant.hasASRProfile {
                Text("voice.assistant.cloud.not_configured").foregroundStyle(.secondary)
            }
            if mode == .synthesis,
               !assistant.synthesisServices.contains(where: { !$0.local }) {
                Text("voice.assistant.online.not_configured").foregroundStyle(.secondary)
            }
            if assistant.hasUnavailablePriority(for: mode.capability) {
                Text("voice.assistant.priority.unavailable").foregroundStyle(.secondary)
            }
            Button {
                Task { await assistant.refresh() }
            } label: {
                Label("voice.assistant.refresh", systemImage: "arrow.clockwise")
            }
        } footer: {
            Text(LocalizedStringKey(mode.footerKey))
        }
    }

    private var profilesSection: some View {
        Section {
            NavigationLink("voice.cloud.profiles.title") {
                CloudASRProfilesView(
                    store: assistant.cloudASRSettings,
                    preload: environment.voiceRecognitionPreload)
            }
            if let primary = assistant.cloudASRSettings.primaryProfile {
                LabeledContent("voice.cloud.profile.primary", value: primary.name)
            }
        } header: {
            Text("voice.cloud.profiles.title")
        } footer: {
            Text("voice.cloud.profiles.footer")
        }
    }

    private func serviceTitle(_ service: AssistantAudioServiceDescriptor) -> String {
        switch service.id {
        case AssistantAudioService.ID.transcriptionEnhanced:
            return FloeL10n.l("voice.assistant.service.local")
        case AssistantAudioService.ID.transcriptionSystem:
            return FloeL10n.l("voice.assistant.service.system.recognition")
        case AssistantAudioService.ID.transcriptionCloud:
            return FloeL10n.l("voice.assistant.service.cloud")
        default:
            return service.title
        }
    }

    private func serviceDetail(_ service: AssistantAudioServiceDescriptor) -> String? {
        switch service.id {
        case AssistantAudioService.ID.transcriptionEnhanced:
            return FloeL10n.l("voice.assistant.detail.enhanced")
        case AssistantAudioService.ID.transcriptionSystem:
            return service.requiresAuthorization
                ? FloeL10n.l("voice.assistant.detail.system_permission")
                : FloeL10n.l("voice.assistant.detail.system")
        case AssistantAudioService.ID.transcriptionCloud:
            return FloeL10n.l("voice.assistant.detail.cloud")
        default:
            if service.provider == "apple" { return FloeL10n.l("voice.assistant.detail.system_voice") }
            if service.local { return FloeL10n.l("voice.assistant.detail.local_voice") }
            return service.detail ?? FloeL10n.l("voice.assistant.detail.cloud_voice")
        }
    }
}
#endif
