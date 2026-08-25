// FloeApp — Provider editor.
//
// SPDX-License-Identifier: MPL-2.0
//
// Add/edit a provider: preset picker, base URL, API key (Keychain-only),
// non-secret headers, plain-HTTP acknowledgement, iCloud Keychain sync
// toggle, Test connection with model discovery, and a manual-model
// fallback editor. Shows `.waitingForSecret` honestly when configuration
// synced but the secret hasn't.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloeProviders

/// The provider editor form.
struct ProviderEditorView: View {
    @StateObject private var viewModel: ProviderEditorViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showModelPicker = false
    @State private var editingModel: ModelProfile?

    init(center: ConversationCenter, existing: ProviderProfile?) {
        _viewModel = StateObject(
            wrappedValue: ProviderEditorViewModel(center: center, existing: existing)
        )
    }

    var body: some View {
        Form {
            presetSection
            protocolSection
            endpointSection
            credentialsSection
            compatibilitySection
            syncSection
            testSection
            modelsSection
            if let error = viewModel.errorMessage {
                Section {
                    Text(error)
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(FloeTheme.destructive)
                }
            }
        }
        .navigationTitle(viewModel.existing == nil
            ? LocalizedStringKey("providers.add")
            : LocalizedStringKey("providers.edit"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("action.cancel") { dismiss() }
                    .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                    .accessibilityIdentifier("action.cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("action.save") { save() }
                    .disabled(viewModel.isSaving)
                    .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                    .accessibilityIdentifier("action.save")
            }
        }
        .task { await viewModel.load() }
        .sheet(isPresented: $showModelPicker) {
            ModelPickerView(viewModel: viewModel)
        }
        .sheet(item: $editingModel) { model in
            ModelEditorView(
                model: model,
                isDefault: viewModel.defaultModelID == model.id,
                onMakeDefault: { viewModel.setDefaultModel(model.id) }
            ) { updated in viewModel.updateModel(updated) }
        }
    }

    private var protocolSection: some View {
        Section("providers.protocol") {
            Picker("providers.protocol", selection: $viewModel.selectedProtocol) {
                ForEach(viewModel.availableProtocols, id: \.self) { protocolKind in
                    Text(protocolKind.displayName).tag(protocolKind)
                }
            }
            .disabled(viewModel.availableProtocols.count == 1)
        }
    }

    // MARK: - Preset

    private var presetSection: some View {
        Section {
            Toggle("providers.enabled", isOn: $viewModel.enabled)
            TextField("providers.display_name", text: $viewModel.displayName)
                .textInputAutocapitalization(.words)
                .accessibilityIdentifier("providers.display_name")
            Picker("providers.preset", selection: Binding(
                get: { viewModel.selectedPreset },
                set: { viewModel.applyPreset($0) }
            )) {
                ForEach(viewModel.availablePresets) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            .accessibilityLabel("providers.preset")
            .accessibilityIdentifier("providers.preset")
        }
    }

    // MARK: - Endpoint

    private var endpointSection: some View {
        Section {
            TextField("providers.base_url", text: $viewModel.baseURLString)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .font(FloeTheme.Typography.evidence)
            TextField("providers.headers_placeholder", text: $viewModel.nonSecretHeadersText, axis: .vertical)
                .lineLimit(2...5)
                .textInputAutocapitalization(.never)
                .font(FloeTheme.Typography.evidence)
            if viewModel.selectedPreset.defaultBaseURL.scheme == "http" {
                Toggle("providers.allow_plain_http", isOn: $viewModel.allowsPlainHTTP)
            }
        } header: {
            Text("providers.endpoint")
        } footer: {
            Text("providers.headers_hint")
        }
    }

    // MARK: - Credentials (Keychain only)

    private var credentialsSection: some View {
        Section {
            HStack {
                if viewModel.showingAPIKey {
                    TextField("providers.api_key", text: $viewModel.apiKey)
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("providers.api_key")
                } else {
                    SecureField("providers.api_key", text: $viewModel.apiKey)
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("providers.api_key")
                }
                Button {
                    if viewModel.showingAPIKey {
                        viewModel.showingAPIKey = false
                    } else {
                        Task { await viewModel.authenticateAndRevealAPIKey() }
                    }
                } label: {
                    Image(systemName: viewModel.showingAPIKey ? "eye.slash" : "eye")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(viewModel.showingAPIKey ? "隐藏 API key" : "显示 API key")
            }
            if viewModel.secretStatus == .waitingForSecret {
                Label("providers.waiting_secret.hint", systemImage: "key.fill")
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(FloeTheme.pending)
            }
        } header: {
            Text("providers.credentials")
        } footer: {
            Text("providers.api_key.hint")
        }
    }

    // MARK: - Compatibility

    /// Some providers (DeepSeek, certain gateways) reject tool names with
    /// dots (`workspace.createFile`). This toggle converts tool names to
    /// underscores (`workspace_createFile`) for this provider only.
    private var compatibilitySection: some View {
        Section {
            Toggle("providers.tool_name_compatibility", isOn: $viewModel.toolNameCompatibility)
        } footer: {
            Text("providers.tool_name_compatibility.hint")
        }
    }

    // MARK: - iCloud Keychain sync

    private var syncSection: some View {
        Section {
            Toggle("providers.sync_keychain", isOn: $viewModel.syncEnabled)
        } footer: {
            Text("providers.sync_keychain.hint")
        }
    }

    // MARK: - Test connection

    private var testSection: some View {
        Section {
            Button {
                Task { await viewModel.testConnection() }
            } label: {
                HStack {
                    Text("providers.test_connection")
                    Spacer()
                    switch viewModel.testState {
                    case .idle:
                        EmptyView()
                    case .testing:
                        ProgressView()
                    case .succeeded(let count):
                        Label(
                            String(localized: "providers.test_ok") + " (\(count))",
                            systemImage: "checkmark.circle.fill"
                        )
                        .foregroundStyle(FloeTheme.success)
                    case .failed:
                        Label("providers.test_failed", systemImage: "xmark.octagon.fill")
                            .foregroundStyle(FloeTheme.destructive)
                    }
                }
                .frame(minHeight: FloeTheme.minimumTarget)
            }
            .disabled(viewModel.testState == .testing)
            .accessibilityIdentifier("providers.test_connection")
            if case .failed(let message) = viewModel.testState {
                Text(message)
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(FloeTheme.destructive)
            }
        }
    }

    // MARK: - Models (discovered + manual fallback)

    private var modelsSection: some View {
        Section {
            if viewModel.selectedModels.isEmpty {
                Text("providers.no_models")
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.selectedModels) { model in
                    modelRow(model)
                }
            }
            Button("providers.manage_models") { showModelPicker = true }
                .frame(minHeight: FloeTheme.minimumTarget)
                .accessibilityIdentifier("providers.manage_models")
            if viewModel.supportsDiscovery {
                Button {
                    Task { await viewModel.refreshModels() }
                } label: {
                    Label("providers.refresh_models", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.testState == .testing)
                .frame(minHeight: FloeTheme.minimumTarget)
                .accessibilityIdentifier("providers.refresh_models")
            }
        } header: {
            Text("providers.models_section")
        } footer: {
            if !viewModel.supportsDiscovery {
                Text("providers.manual_fallback.hint")
            }
        }
    }

    private func modelRow(_ model: ModelProfile) -> some View {
        HStack {
            Button {
                editingModel = model
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.displayName)
                            .font(FloeTheme.Typography.body)
                        Text(model.remoteModelID)
                            .font(FloeTheme.Typography.evidence)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if viewModel.defaultModelID == model.id {
                        Text("model.default")
                            .font(FloeTheme.Typography.metadata)
                            .foregroundStyle(FloeTheme.primary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            Toggle("model.enabled", isOn: Binding(
                get: {
                    viewModel.candidateModels.first(where: { $0.id == model.id })?.isEnabled
                        ?? model.isEnabled
                },
                set: { viewModel.setModelEnabled(model.id, isEnabled: $0) }
            ))
            .labelsHidden()
            .tint(FloeTheme.primary)
            .accessibilityIdentifier("providers.model.enabled.\(model.remoteModelID)")
        }
        .contextMenu {
            Button("model.set_default") { viewModel.setDefaultModel(model.id) }
        }
    }

    // MARK: - Save

    private func save() {
        Task {
            if await viewModel.save() {
                dismiss()
            }
        }
    }
}

private extension ModelProtocol {
    var displayName: String {
        switch self {
        case .openAIResponses: "OpenAI Responses"
        case .openAIChatCompletions: "OpenAI Chat Completions"
        case .anthropicMessages: "Anthropic Messages"
        }
    }
}
#endif
