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
                Toggle("auxiliary.vision.reasoning", isOn: $viewModel.visionReasoningEnabled)
                Text("auxiliary.vision.reasoning.footer")
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
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
                Text("安装 Python 包前，会确认它确实用于当前任务。需要额外系统权限或不适合本机运行的包仍会被阻止。")
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
                if viewModel.isSaving {
                    ProgressView()
                        .accessibilityLabel("正在自动保存")
                } else {
                    Text("已自动保存")
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task { await viewModel.load() }
        .onChange(of: viewModel.mode) { _, _ in viewModel.scheduleSave() }
        .onChange(of: viewModel.visionModelID) { _, _ in viewModel.scheduleSave() }
        .onChange(of: viewModel.visionReasoningEnabled) { _, value in
            viewModel.saveVisionReasoning(value)
        }
        .onChange(of: viewModel.packageReviewModelID) { _, _ in viewModel.scheduleSave() }
        .onChange(of: viewModel.sharedModelID) { _, _ in viewModel.scheduleSave() }
        .onChange(of: viewModel.generationModelID) { _, _ in viewModel.scheduleSave() }
        .onChange(of: viewModel.editingModelID) { _, _ in viewModel.scheduleSave() }
        .onDisappear { viewModel.flushPendingSave() }
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
    @Published var visionReasoningEnabled = false
    @Published var packageReviewModelID: UUID?
    @Published var sharedModelID: UUID?
    @Published var generationModelID: UUID?
    @Published var editingModelID: UUID?
    @Published private(set) var isSaving = false
    @Published var errorMessage: String?

    let center: ConversationCenter
    private let adapterFactory = ImageProviderAdapterFactory()
    private let cloudPreferences = NSUbiquitousKeyValueStore.default
    private var hasLoaded = false
    private var saveTask: Task<Void, Never>?

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
        hasLoaded = false
        saveTask?.cancel()
        await center.reload()
        let preferences = center.modelPreferences
        mode = preferences.auxiliaryImageMode
        visionModelID = preferences.visionModelID
        if cloudPreferences.object(
            forKey: ConversationCenter.auxiliaryVisionReasoningDefaultsKey
        ) != nil {
            visionReasoningEnabled = cloudPreferences.bool(
                forKey: ConversationCenter.auxiliaryVisionReasoningDefaultsKey
            )
            UserDefaults.standard.set(
                visionReasoningEnabled,
                forKey: ConversationCenter.auxiliaryVisionReasoningDefaultsKey
            )
        } else {
            visionReasoningEnabled = UserDefaults.standard.bool(
                forKey: ConversationCenter.auxiliaryVisionReasoningDefaultsKey
            )
        }
        packageReviewModelID = preferences.packageReviewModelID
        sharedModelID = preferences.sharedImageModelID
        generationModelID = preferences.imageGenerationModelID
        editingModelID = preferences.imageEditingModelID
        hasLoaded = true
    }

    func saveVisionReasoning(_ enabled: Bool) {
        guard hasLoaded else { return }
        UserDefaults.standard.set(
            enabled,
            forKey: ConversationCenter.auxiliaryVisionReasoningDefaultsKey
        )
        cloudPreferences.set(
            enabled,
            forKey: ConversationCenter.auxiliaryVisionReasoningDefaultsKey
        )
        cloudPreferences.synchronize()
        FloeLogger(category: .sync).info(
            "auxiliaryVisionReasoningSaved enabled=\(enabled)"
        )
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

    /// Model routing is a preference, not an editor transaction. Persist it
    /// shortly after every change so leaving this screen cannot silently lose
    /// the auxiliary vision selection needed by a text-only model.
    func scheduleSave() {
        guard hasLoaded else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            await self.save()
        }
    }

    func flushPendingSave() {
        guard hasLoaded else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            await self?.save()
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
        scheduleSave()
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

    @State private var remoteModelID = ""
    @State private var displayName = ""
    @State private var supportsGeneration = true
    @State private var supportsEditing = true
    @State private var supportsVision = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var dedicatedBaseURL = ""
    @State private var dedicatedAPIKey = ""
    @State private var dedicatedName = ""
    @State private var dedicatedKind: ProviderKind = .volcengineArk
    private let adapterFactory = ImageProviderAdapterFactory()

    private var supportedOperations: Set<RemoteImageOperation> {
        if let provider = dedicatedProviderPreview,
           let adapter = adapterFactory.adapter(for: provider) {
            return adapter.supportedOperations(for: provider)
        }
        return []
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("auxiliary.provider") {
                    Picker("服务商", selection: $dedicatedKind) {
                        ForEach(Self.imageProviderKinds, id: \.self) { kind in
                            Text(Self.imageProviderName(kind)).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(Self.imageProviderHint(dedicatedKind))
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(.secondary)
                    TextField("providers.display_name", text: $dedicatedName)
                    TextField("providers.base_url", text: $dedicatedBaseURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    SecureField("providers.api_key", text: $dedicatedAPIKey)
                        .textInputAutocapitalization(.never)
                    Text("图片模型始终使用独立端点和独立 API Key，不复用聊天提供商凭据。")
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(.secondary)
                }
                Section("auxiliary.image_model") {
                    TextField("model.remote_id", text: $remoteModelID).textInputAutocapitalization(.never)
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
                if dedicatedBaseURL.isEmpty {
                    applyDedicatedPreset(for: dedicatedKind, replacesModel: remoteModelID.isEmpty)
                }
                applySupportedOperations()
            }
            .onChange(of: dedicatedKind) { _, kind in
                applyDedicatedPreset(for: kind, replacesModel: true)
                applySupportedOperations()
            }
        }
    }

    private var isValid: Bool {
        return !dedicatedBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !dedicatedAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                do {
                    // Every image model owns its provider endpoint and key;
                    // image APIs are not assumed to share chat credentials.
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

    private func applyDedicatedPreset(for kind: ProviderKind, replacesModel: Bool) {
        dedicatedBaseURL = ProviderPreset.preset(for: kind).defaultBaseURL.absoluteString
        dedicatedName = Self.imageProviderName(kind)
        guard replacesModel else { return }
        remoteModelID = Self.defaultImageModel(for: kind)
        displayName = remoteModelID
    }

    private static let imageProviderKinds: [ProviderKind] = [
        .openAI, .googleGemini, .volcengineArk, .alibabaStudio
    ]

    private static func imageProviderName(_ kind: ProviderKind) -> String {
        switch kind {
        case .openAI: "OpenAI"
        case .volcengineArk: "火山方舟"
        case .alibabaStudio: "DashScope"
        case .googleGemini: "Google Gemini"
        case .anthropic, .local, .custom: ProviderPreset.preset(for: kind).displayName
        }
    }

    private static func defaultImageModel(for kind: ProviderKind) -> String {
        switch kind {
        case .openAI: "gpt-image-2"
        case .volcengineArk: "doubao-seedream-5-0-260128"
        case .alibabaStudio: "wan2.7-image"
        case .googleGemini: "gemini-3-pro-image"
        case .anthropic, .local, .custom: ""
        }
    }

    private static func imageProviderHint(_ kind: ProviderKind) -> String {
        switch kind {
        case .openAI: "OpenAI Images API，支持图片生成与编辑。"
        case .volcengineArk: "火山方舟 Seedream，使用 Ark API Key。"
        case .alibabaStudio: "DashScope（阿里云百炼）图像 API，API Key 与地域端点需匹配。"
        case .googleGemini: "Google Gemini 原生图像 API；Nano Banana Pro 支持生成与编辑，Base URL 可改为兼容代理。"
        case .anthropic, .local, .custom: ""
        }
    }
}
#endif
