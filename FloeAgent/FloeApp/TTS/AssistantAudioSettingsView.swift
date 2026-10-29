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
    @State private var baseURL = ""
    @State private var modelID = AssistantAudioPreferences.defaultASRModelID
    @State private var credential = ""
    @State private var messageKey: String?
    @State private var errorKey: String?
    @State private var confirmRemove = false

    var body: some View {
        List {
            prioritySection
            availabilitySection
            if mode == .transcription {
                cloudTranscriptionSection
            }
            if let messageKey {
                Section { Text(LocalizedStringKey(messageKey)).foregroundStyle(.secondary) }
            }
            if let errorKey {
                Section { Text(LocalizedStringKey(errorKey)).foregroundStyle(.red) }
            }
        }
        .navigationTitle(LocalizedStringKey(mode.titleKey))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
        }
        .onAppear {
            if mode == .transcription {
                baseURL = assistant.preferences.asrBaseURL ?? ""
                modelID = assistant.preferences.asrModelID
            }
            Task { await assistant.refresh() }
        }
        .onChange(of: assistant.preferences.asrBaseURL) { _, value in
            if mode == .transcription, baseURL.isEmpty { baseURL = value ?? "" }
        }
        .alert("voice.assistant.cloud.remove", isPresented: $confirmRemove) {
            Button("voice.local.cancel", role: .cancel) {}
            Button("voice.assistant.cloud.remove", role: .destructive) { removeCloudProfile() }
        } message: {
            Text("voice.assistant.cloud.remove.confirm")
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

    private var cloudTranscriptionSection: some View {
        Section {
            TextField("voice.assistant.cloud.endpoint", text: $baseURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            TextField("voice.assistant.cloud.model", text: $modelID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("voice.assistant.cloud.key.placeholder", text: $credential)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if assistant.hasASRProfile {
                Label("voice.assistant.cloud.ready", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                Text("voice.assistant.cloud.not_ready").foregroundStyle(.secondary)
            }
            if assistant.asrValidationProblem != nil {
                Text("voice.assistant.cloud.invalid_endpoint")
                    .font(.footnote).foregroundStyle(.red)
            }
            Button("voice.assistant.cloud.save") { saveCloudProfile() }
            if assistant.hasASRProfile {
                Button("voice.assistant.cloud.remove", role: .destructive) {
                    confirmRemove = true
                }
            }
        } header: {
            Text("voice.assistant.cloud.title")
        } footer: {
            Text("voice.assistant.cloud.endpoint.footer")
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
            return FloeL10n.l("voice.assistant.detail.cloud_voice")
        }
    }

    private func saveCloudProfile() {
        messageKey = nil
        errorKey = nil
        do {
            try assistant.saveASRProfile(
                baseURL: baseURL, modelID: modelID, credential: credential)
            credential = ""
            messageKey = "voice.assistant.cloud.saved"
        } catch AssistantAudioError.credentialChangedRequiresNewKey {
            errorKey = "voice.assistant.cloud.key_required"
        } catch AssistantAudioError.invalidConfiguration {
            errorKey = "voice.assistant.cloud.invalid_endpoint"
        } catch AssistantAudioError.credentialMissing {
            errorKey = "voice.assistant.cloud.key_required"
        } catch {
            errorKey = "voice.assistant.cloud.save_failed"
        }
    }

    private func removeCloudProfile() {
        messageKey = nil
        errorKey = nil
        do {
            try assistant.removeASRProfile()
            credential = ""
            baseURL = ""
            modelID = AssistantAudioPreferences.defaultASRModelID
        } catch {
            errorKey = "voice.assistant.cloud.remove_failed"
        }
    }
}
#endif
