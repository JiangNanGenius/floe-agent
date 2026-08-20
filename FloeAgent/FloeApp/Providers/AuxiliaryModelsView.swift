// FloeApp — Dedicated image generation/editing model routing.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloeProviders
import FloeSecurity

struct AuxiliaryModelsView: View {
    @StateObject private var viewModel: AuxiliaryModelsViewModel
    @State private var showingAdd = false

    init(center: ConversationCenter) {
        _viewModel = StateObject(wrappedValue: AuxiliaryModelsViewModel(center: center))
    }

    var body: some View {
        Form {
            Section("model.capability.vision") {
                modelPicker(selection: $viewModel.visionModelID, models: viewModel.visionCandidates)
                if viewModel.visionCandidates.isEmpty {
                    Label("auxiliary.shared.empty", systemImage: "eye.slash")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                modelPicker(
                    selection: $viewModel.packageReviewModelID,
                    models: viewModel.packageReviewCandidates
                )
                Text("所有受管 Python 包都会由该模型结合插件目录、包版本和任务意图进行审查；原生二进制和越权能力仍由本地规则硬性阻止。")
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
            } header: {
                Text("软件包审查模型")
            }

            Section {
                Toggle("auxiliary.shared.toggle", isOn: Binding(
                    get: { viewModel.mode == .shared },
                    set: { viewModel.setSharedMode($0) }
                ))
            } footer: {
                Text("auxiliary.keychain.hint")
            }

            if viewModel.mode == .shared {
                Section("auxiliary.shared.model") {
                    modelPicker(selection: $viewModel.sharedModelID, models: viewModel.sharedCandidates)
                    if viewModel.sharedCandidates.isEmpty {
                        Label("auxiliary.shared.empty", systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section("auxiliary.generation") {
                    modelPicker(selection: $viewModel.generationModelID, models: viewModel.generationCandidates)
                }
                Section("auxiliary.editing") {
                    modelPicker(selection: $viewModel.editingModelID, models: viewModel.editingCandidates)
                }
            }

            Section {
                Button {
                    showingAdd = true
                } label: {
                    Label("auxiliary.add_model", systemImage: "plus")
                }
                .disabled(viewModel.center.providers.isEmpty)
            } footer: {
                if viewModel.center.providers.isEmpty {
                    Text("auxiliary.provider_required")
                }
            }

            if let error = viewModel.errorMessage {
                Section { Text(error).foregroundStyle(FloeTheme.destructive) }
            }
        }
        .navigationTitle("more.auxiliary_models")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("action.save") { Task { await viewModel.save() } }
                    .disabled(viewModel.isSaving)
            }
        }
        .task { await viewModel.load() }
        .sheet(isPresented: $showingAdd) {
            AuxiliaryModelEditorView(center: viewModel.center) { model in
                await viewModel.modelAdded(model)
            }
        }
    }

    private func modelPicker(
        selection: Binding<UUID?>,
        models: [ModelProfile]
    ) -> some View {
        Picker("model.section.identity", selection: selection) {
            Text("auxiliary.not_configured").tag(Optional<UUID>.none)
            ForEach(models) { model in
                Text(viewModel.label(for: model)).tag(Optional(model.id))
            }
        }
    }
}

@MainActor
final class AuxiliaryModelsViewModel: ObservableObject {
    @Published var mode: AuxiliaryImageMode = .shared
    @Published var visionModelID: UUID?
    @Published var packageReviewModelID: UUID?
    @Published var sharedModelID: UUID?
    @Published var generationModelID: UUID?
    @Published var editingModelID: UUID?
    @Published private(set) var isSaving = false
    @Published var errorMessage: String?

    let center: ConversationCenter
    private let adapterFactory = ImageProviderAdapterFactory()

    init(center: ConversationCenter) { self.center = center }

    var visionCandidates: [ModelProfile] { center.visionModels }
    var packageReviewCandidates: [ModelProfile] { center.approvalModels }

    var generationCandidates: [ModelProfile] {
        center.imageModels.filter {
            $0.capabilities.contains(.imageGeneration) && supports(.generate, model: $0)
        }
    }
    var editingCandidates: [ModelProfile] {
        center.imageModels.filter {
            $0.capabilities.contains(.imageEditing) && supports(.edit, model: $0)
        }
    }
    var sharedCandidates: [ModelProfile] {
        center.imageModels.filter {
            $0.capabilities.contains(.imageGeneration) && $0.capabilities.contains(.imageEditing)
                && supports(.generate, model: $0) && supports(.edit, model: $0)
        }
    }

    func load() async {
        await center.reload()
        let preferences = center.modelPreferences
        mode = preferences.auxiliaryImageMode
        visionModelID = preferences.visionModelID
        packageReviewModelID = preferences.packageReviewModelID
        sharedModelID = preferences.sharedImageModelID
        generationModelID = preferences.imageGenerationModelID
        editingModelID = preferences.imageEditingModelID
    }

    func setSharedMode(_ shared: Bool) {
        var preferences = ModelSelectionPreferences(
            visionModelID: visionModelID,
            auxiliaryImageMode: mode,
            sharedImageModelID: sharedModelID,
            imageGenerationModelID: generationModelID,
            imageEditingModelID: editingModelID
        )
        preferences.switchAuxiliaryMode(to: shared ? .shared : .separate) { id in
            center.imageModels.first(where: { $0.id == id })?.capabilities
        }
        mode = preferences.auxiliaryImageMode
        sharedModelID = preferences.sharedImageModelID
        generationModelID = preferences.imageGenerationModelID
        editingModelID = preferences.imageEditingModelID
    }

    func save() async {
        isSaving = true
        defer { isSaving = false }
        errorMessage = nil
        do {
            var preferences = center.modelPreferences
            preferences.visionModelID = visionModelID
            preferences.packageReviewModelID = packageReviewModelID
            preferences.auxiliaryImageMode = mode
            preferences.sharedImageModelID = mode == .shared ? sharedModelID : nil
            preferences.imageGenerationModelID = mode == .separate ? generationModelID : nil
            preferences.imageEditingModelID = mode == .separate ? editingModelID : nil
            try await center.saveModelPreferences(preferences)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func modelAdded(_ staged: ModelProfile) async {
        await center.reload()
        let candidates = center.imageModels + center.visionModels
        guard let canonical = candidates.first(where: {
            $0.providerID == staged.providerID && $0.remoteModelID == staged.remoteModelID
        }) else { return }
        if canonical.capabilities.contains(.vision) { visionModelID = canonical.id }
        if mode == .shared,
           canonical.capabilities.contains(.imageGeneration),
           canonical.capabilities.contains(.imageEditing) {
            sharedModelID = canonical.id
        } else {
            if canonical.capabilities.contains(.imageGeneration) { generationModelID = canonical.id }
            if canonical.capabilities.contains(.imageEditing) { editingModelID = canonical.id }
        }
    }

    func label(for model: ModelProfile) -> String {
        let provider = center.providers.first(where: { $0.id == model.providerID })
        return "\(model.displayName) · \(provider.map(providerName) ?? String(localized: "auxiliary.provider"))"
    }

    private func supports(_ operation: RemoteImageOperation, model: ModelProfile) -> Bool {
        guard let provider = center.providers.first(where: { $0.id == model.providerID }),
              let adapter = adapterFactory.adapter(for: provider) else { return false }
        return adapter.supports(operation, for: provider)
    }

    private func providerName(_ provider: ProviderProfile) -> String {
        let custom = provider.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.flatMap { $0.isEmpty ? nil : $0 }
            ?? ProviderPreset.preset(for: provider.kind).displayName
    }
}

private struct AuxiliaryModelEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let center: ConversationCenter
    let onSaved: (ModelProfile) async -> Void

    @State private var providerID: UUID?
    @State private var remoteModelID = ""
    @State private var displayName = ""
    @State private var supportsGeneration = true
    @State private var supportsEditing = true
    @State private var supportsVision = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var discoveredModels: [ModelProfile] = []
    @State private var isDiscovering = false
    /// When true, a dedicated endpoint (base URL + API key) is created for
    /// this image model instead of reusing an existing chat provider. Image
    /// services (e.g. Doubao Seedream, DALL-E) often live on a different
    /// endpoint than the chat provider.
    @State private var useDedicatedEndpoint = false
    @State private var dedicatedBaseURL = ""
    @State private var dedicatedAPIKey = ""
    @State private var dedicatedName = ""
    @State private var dedicatedKind: ProviderKind = .volcengineArk
    private let adapterFactory = ImageProviderAdapterFactory()

    private var compatibleProviders: [ProviderProfile] { center.providers }

    private var supportedOperations: Set<RemoteImageOperation> {
        if useDedicatedEndpoint,
           let provider = dedicatedProviderPreview,
           let adapter = adapterFactory.adapter(for: provider) {
            return adapter.supportedOperations(for: provider)
        }
        guard let providerID,
              let provider = center.providers.first(where: { $0.id == providerID }),
              let adapter = adapterFactory.adapter(for: provider) else { return [] }
        return adapter.supportedOperations(for: provider)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("auxiliary.provider") {
                    Toggle("使用独立端点", isOn: $useDedicatedEndpoint)
                    if useDedicatedEndpoint {
                        Picker("服务商", selection: $dedicatedKind) {
                            Text("OpenAI").tag(ProviderKind.openAI)
                            Text("Volcengine Ark").tag(ProviderKind.volcengineArk)
                            Text("Alibaba Model Studio").tag(ProviderKind.alibabaStudio)
                        }
                        TextField("providers.display_name", text: $dedicatedName)
                        TextField("providers.base_url", text: $dedicatedBaseURL)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                        SecureField("providers.api_key", text: $dedicatedAPIKey)
                            .textInputAutocapitalization(.never)
                        Text("该模型使用独立端点和独立 API Key，不会复用聊天提供商的凭据。")
                            .font(FloeTheme.Typography.metadata)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("auxiliary.provider", selection: $providerID) {
                            ForEach(compatibleProviders) { provider in
                                Text(providerName(provider))
                                    .tag(Optional(provider.id))
                            }
                        }
                        if compatibleProviders.isEmpty {
                            Label("auxiliary.adapter.none", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                        }
                        Text("端点和 API Key 复用所选提供商；如需不同凭据，请开启上方独立端点。")
                            .font(FloeTheme.Typography.metadata)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("auxiliary.image_model") {
                    if !discoveredModels.isEmpty {
                        Picker("model.remote_id", selection: $remoteModelID) {
                            ForEach(discoveredModels) { model in
                                Text(model.remoteModelID).tag(model.remoteModelID)
                            }
                        }
                    } else {
                        TextField("model.remote_id", text: $remoteModelID).textInputAutocapitalization(.never)
                    }
                    TextField("model.display_name", text: $displayName)
                    Toggle("auxiliary.generation", isOn: $supportsGeneration)
                        .disabled(!supportedOperations.contains(.generate))
                    Toggle("auxiliary.editing", isOn: $supportsEditing)
                        .disabled(!supportedOperations.contains(.edit))
                    Toggle("model.capability.vision", isOn: $supportsVision)
                    if !supportedOperations.contains(.edit) {
                        Text("auxiliary.editing.unavailable")
                            .font(FloeTheme.Typography.metadata)
                            .foregroundStyle(.secondary)
                    }
                    if supportedOperations.isEmpty {
                        Text("auxiliary.vision.auto_enabled")
                            .font(FloeTheme.Typography.metadata)
                            .foregroundStyle(.secondary)
                    }
                    // Clarify: generation/editing produce images; vision reads them.
                    Text("auxiliary.model_kind_hint")
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(FloeTheme.destructive) }
                }
            }
            .navigationTitle("auxiliary.add_model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.save") { save() }
                        .disabled(!isValid || isSaving)
                }
            }
            .task {
                if providerID == nil { providerID = compatibleProviders.first?.id }
                applySupportedOperations()
                await discoverModels()
            }
            .onChange(of: providerID) { _, _ in
                applySupportedOperations()
                Task { await discoverModels() }
            }
            .onChange(of: useDedicatedEndpoint) { _, enabled in
                if enabled && dedicatedBaseURL.isEmpty {
                    dedicatedBaseURL = ProviderPreset.preset(for: dedicatedKind).defaultBaseURL.absoluteString
                }
                applySupportedOperations()
            }
            .onChange(of: dedicatedKind) { _, kind in
                dedicatedBaseURL = ProviderPreset.preset(for: kind).defaultBaseURL.absoluteString
                applySupportedOperations()
            }
        }
    }

    private func providerName(_ provider: ProviderProfile) -> String {
        let custom = provider.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.flatMap { $0.isEmpty ? nil : $0 }
            ?? ProviderPreset.preset(for: provider.kind).displayName
    }

    private var isValid: Bool {
        if useDedicatedEndpoint {
            return !dedicatedBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !dedicatedAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !remoteModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && (supportsGeneration || supportsEditing || supportsVision)
        }
        return providerID != nil
            && !remoteModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (supportsGeneration || supportsEditing || supportsVision)
    }

    private var dedicatedProviderPreview: ProviderProfile? {
        let trimmed = dedicatedBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = ProviderPreset.preset(for: dedicatedKind).defaultBaseURL
        guard let url = trimmed.isEmpty ? fallback : URL(string: trimmed) else { return nil }
        return ProviderProfile(
            kind: dedicatedKind,
            wireProtocol: ProviderPreset.preset(for: dedicatedKind).defaultProtocol,
            baseURL: url
        )
    }

    private func save() {
        Task {
            isSaving = true
            defer { isSaving = false }
            do {
                let resolvedProviderID: UUID
                if useDedicatedEndpoint {
                    // Create a dedicated provider for this image service so
                    // it carries its own base URL + API key (e.g. Doubao
                    // Seedream endpoint differs from the chat provider).
                    guard let baseURL = URL(string: dedicatedBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                        throw FloeError.invalidConfiguration("图片模型端点无效")
                    }
                    let providerID = UUID()
                    let provider = ProviderProfile(
                        id: providerID,
                        kind: dedicatedKind,
                        wireProtocol: ProviderPreset.preset(for: dedicatedKind).defaultProtocol,
                        baseURL: baseURL,
                        displayName: dedicatedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? remoteModelID : dedicatedName,
                        secretRef: SecretReference(
                            keychainAccount: "provider.\(providerID.uuidString)",
                            synchronizable: true
                        )
                    )
                    try await center.saveProvider(provider)
                    // Store the API key in Keychain under the provider's ref.
                    if let secretRef = provider.secretRef {
                        let store = KeychainStore(
                            service: "org.floeagent.ios.secrets",
                            synchronizable: secretRef.synchronizable
                        )
                        try store.store(
                            account: secretRef.keychainAccount,
                            secret: Data(dedicatedAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
                        )
                    }
                    resolvedProviderID = provider.id
                } else {
                    guard let providerID else { return }
                    resolvedProviderID = providerID
                }

                var capabilities: ModelCapabilities = []
                if supportsGeneration { capabilities.insert(.imageGeneration) }
                if supportsEditing { capabilities.insert(.imageEditing) }
                if supportsVision { capabilities.insert(.vision) }
                let remoteID = remoteModelID.trimmingCharacters(in: .whitespacesAndNewlines)
                let model = ModelProfile(
                    providerID: resolvedProviderID,
                    remoteModelID: remoteID,
                    displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? remoteID : displayName,
                    limits: ModelLimits(contextTokens: 1, maxOutputTokens: 1),
                    capabilities: capabilities
                )
                try await center.saveModel(model)
                await onSaved(model)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func applySupportedOperations() {
        supportsGeneration = supportedOperations.contains(.generate)
        supportsEditing = supportedOperations.contains(.edit)
        if supportedOperations.isEmpty { supportsVision = true }
    }

    /// Discovers models from the selected provider so the user can pick from
    /// a list instead of typing a raw model ID.
    private func discoverModels() async {
        guard let providerID,
              let provider = center.providers.first(where: { $0.id == providerID }) else { return }
        isDiscovering = true
        defer { isDiscovering = false }
        do {
            let credentials = center.resolveCredentials(for: provider)
            let adapter = ProviderAdapterFactory().adapter(for: provider)
            let models = try await adapter.listModels(provider: provider, credentials: credentials)
            discoveredModels = models.filter {
                $0.capabilities.contains(.imageGeneration)
                    || $0.capabilities.contains(.imageEditing)
                    || $0.capabilities.contains(.vision)
            }
        } catch {
            discoveredModels = []
        }
    }
}
#endif
