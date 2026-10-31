// FloeApp — Native multi-provider cloud recognition profiles.
//
// SPDX-License-Identifier: MPL-2.0
//
// Every provider/billing route is available for configuration and calling with
// the user's own settings. There is deliberately no developer-test,
// membership, paid-entitlement or "verified" switch, and no provider probe on
// save/selection. A profile is ready when its local fields are valid and its
// Keychain secret exists; actual provider errors surface through the ordinary
// redacted runtime error/fallback path.

#if canImport(UIKit)
import SwiftUI
import FloeCore

struct CloudASRProfilesView: View {
    @ObservedObject var store: CloudASRSettingsStore
    var preload: CloudASRPreloadCoordinator?
    @State private var editing: ASRProfile?
    @State private var messageKey: String?

    var body: some View {
        List {
            Section {
                Menu {
                    ForEach(CloudASRSettingsStore.ProviderPreset.allCases, id: \.rawValue) { preset in
                        Button(presetTitle(preset)) { add(preset) }
                    }
                } label: {
                    Label("voice.cloud.profiles.add", systemImage: "plus.circle")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("voice.cloud.profiles.add")
                if store.profiles.isEmpty {
                    Text("voice.cloud.profiles.empty")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("voice.cloud.profiles.footer")
            }

            if !store.profiles.isEmpty {
                Section("voice.cloud.profiles.title") {
                    ForEach(store.profiles, id: \.id) { profile in
                        Button {
                            editing = profile
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(profile.name)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if store.primaryProfileID == profile.id {
                                        Image(systemName: "star.fill")
                                            .foregroundStyle(.tint)
                                            .accessibilityLabel(Text("voice.cloud.profile.primary"))
                                    }
                                    if store.isReady(profile) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                            .accessibilityLabel(Text("voice.cloud.profile.ready"))
                                    } else {
                                        Image(systemName: "key")
                                            .foregroundStyle(.secondary)
                                            .accessibilityLabel(Text("voice.cloud.profile.key_required"))
                                    }
                                }
                                Text(profileSummary(profile))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(minHeight: 44)
                        }
                        .accessibilityIdentifier("voice.cloud.profile." + profile.id.uuidString)
                        .swipeActions {
                            Button(role: .destructive) {
                                store.removeProfile(id: profile.id)
                                if let preload {
                                    Task { await preload.syncPrimaryRoute() }
                                }
                            } label: {
                                Label("voice.cloud.profile.remove", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            if let messageKey {
                Section { Text(LocalizedStringKey(messageKey)).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("voice.cloud.profiles.title")
        .sheet(item: $editing) { profile in
            NavigationStack {
                CloudASRProfileEditor(
                    store: store,
                    original: profile,
                    preload: preload,
                    onDone: { editing = nil })
            }
        }
    }

    private func add(_ preset: CloudASRSettingsStore.ProviderPreset) {
        var draft = preset.makeProfile()
        draft.name = FloeL10n.l(presetKey(preset))
        editing = draft
    }

    private func presetTitle(_ preset: CloudASRSettingsStore.ProviderPreset) -> LocalizedStringKey {
        LocalizedStringKey(presetKey(preset))
    }

    private func presetKey(_ preset: CloudASRSettingsStore.ProviderPreset) -> String {
        switch preset {
        case .openAI: return "voice.cloud.preset.openai"
        case .openAIRelay: return "voice.cloud.preset.relay"
        case .volcenginePayAsYouGo: return "voice.cloud.preset.volcengine_payg"
        case .volcengineAgentPlan: return "voice.cloud.preset.volcengine_plan"
        case .alibabaPayAsYouGo: return "voice.cloud.preset.alibaba_payg"
        case .alibabaTokenPlan: return "voice.cloud.preset.alibaba_token"
        }
    }

    private func profileSummary(_ profile: ASRProfile) -> String {
        let route: String
        switch profile.billingRoute {
        case .payAsYouGo: route = FloeL10n.l("voice.cloud.route.payg")
        case .agentPlan: route = FloeL10n.l("voice.cloud.route.agent")
        case .tokenPlan: route = FloeL10n.l("voice.cloud.route.token")
        }
        return "\(route) · \(profile.fileModelID)"
    }

}

private struct CloudASRProfileEditor: View {
    let store: CloudASRSettingsStore
    let original: ASRProfile
    let preload: CloudASRPreloadCoordinator?
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var fileModel: String
    @State private var liveModel: String
    @State private var fileEndpoint: String
    @State private var liveEndpoint: String
    @State private var resourceID: String
    @State private var languages: String
    @State private var key: String = ""
    @State private var advanced = false
    @State private var errorKey: String?
    @State private var savedKey = false
    @State private var isNew: Bool

    init(
        store: CloudASRSettingsStore,
        original: ASRProfile,
        preload: CloudASRPreloadCoordinator?,
        onDone: @escaping () -> Void
    ) {
        self.store = store
        self.original = original
        self.preload = preload
        _isNew = State(initialValue: store.profile(id: original.id) == nil)
        self.onDone = onDone
        _name = State(initialValue: original.name)
        _fileModel = State(initialValue: original.fileModelID)
        _liveModel = State(initialValue: original.liveModelID ?? "")
        _fileEndpoint = State(initialValue: original.resolvedFileEndpoint ?? "")
        _liveEndpoint = State(initialValue: original.liveEndpoint ?? "")
        _resourceID = State(initialValue: original.resourceID ?? "")
        _languages = State(initialValue: original.languages.joined(separator: ","))
    }

    var body: some View {
        Form {
            Section {
                TextField("voice.cloud.profile.name", text: $name)
                LabeledContent("voice.cloud.profile.provider", value: providerTitle)
                LabeledContent("voice.cloud.profile.route", value: routeTitle)
            }
            Section {
                TextField("voice.cloud.profile.file_endpoint", text: $fileEndpoint)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("voice.cloud.profile.file_model", text: $fileModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("voice.cloud.profile.live_model", text: $liveModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } footer: {
                Text("voice.cloud.profile.live_model.footer")
            }
            Section {
                SecureField("voice.cloud.profile.key", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if store.hasCredential(for: original), !savedKey {
                    Text("voice.cloud.profile.key_keep")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("voice.cloud.profile.key.footer")
            }
            DisclosureGroup("voice.cloud.profile.advanced", isExpanded: $advanced) {
                TextField("voice.cloud.profile.live_endpoint", text: $liveEndpoint)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                if original.provider == .volcengine {
                    TextField("voice.cloud.profile.resource", text: $resourceID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                TextField("voice.cloud.profile.languages", text: $languages)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Section {
                if !isNew, store.primaryProfileID != original.id {
                    Button("voice.cloud.profile.use_primary") { makePrimary() }
                        .frame(minHeight: 44)
                }
                Button("voice.cloud.profile.save") { save() }
                    .frame(minHeight: 44)
                if !isNew {
                    Button("voice.cloud.profile.remove", role: .destructive) {
                        store.removeProfile(id: original.id)
                        if let preload { Task { await preload.syncPrimaryRoute() } }
                        dismiss()
                        onDone()
                    }
                }
            }
            if let errorKey {
                Section { Text(LocalizedStringKey(errorKey)).foregroundStyle(.red) }
            }
        }
        .navigationTitle(original.name)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("voice.local.cancel") { dismiss(); onDone() }
            }
        }
    }

    private var providerTitle: String {
        switch original.provider {
        case .openaiCompatible: return FloeL10n.l("voice.cloud.provider.openai")
        case .volcengine: return FloeL10n.l("voice.cloud.provider.volcengine")
        case .alibaba: return FloeL10n.l("voice.cloud.provider.alibaba")
        }
    }

    private var routeTitle: String {
        switch original.billingRoute {
        case .payAsYouGo: return FloeL10n.l("voice.cloud.route.payg")
        case .agentPlan: return FloeL10n.l("voice.cloud.route.agent")
        case .tokenPlan: return FloeL10n.l("voice.cloud.route.token")
        }
    }

    private func save() {
        errorKey = nil
        var next = original
        next.name = name
        next.fileModelID = fileModel
        next.liveModelID = normalized(liveModel)
        next.fileEndpoint = normalized(fileEndpoint)
        next.liveEndpoint = normalized(liveEndpoint)
        next.resourceID = normalized(resourceID)
        next.languages = languages
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        do {
            let saved: ASRProfile
            if isNew {
                saved = try store.addProfile(next, credential: key.isEmpty ? nil : key)
            } else {
                saved = try store.updateProfile(next, credential: key.isEmpty ? nil : key)
            }
            savedKey = true
            key = ""
            _ = saved
            if let preload { Task { await preload.syncPrimaryRoute() } }
            dismiss()
            onDone()
        } catch CloudASRSettingsStore.StoreError.credentialChangedRequiresNewKey {
            errorKey = "voice.cloud.error.endpoint_changed"
        } catch CloudASRSettingsStore.StoreError.invalidConfiguration {
            errorKey = "voice.cloud.error.invalid"
        } catch CloudASRSettingsStore.StoreError.keychainUnavailable {
            errorKey = "voice.cloud.error.keychain"
        } catch {
            errorKey = "voice.cloud.error.save"
        }
    }

    private func makePrimary() {
        store.setPrimary(original.id)
        if let preload { Task { await preload.syncPrimaryRoute() } }
        onDone()
        dismiss()
    }

    private func normalized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
#endif
