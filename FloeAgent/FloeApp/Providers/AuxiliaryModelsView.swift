// FloeApp — Dedicated image generation/editing model routing.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloeProviders

struct AuxiliaryModelsView: View {
    @StateObject private var viewModel: AuxiliaryModelsViewModel

    init(center: ConversationCenter) {
        _viewModel = StateObject(wrappedValue: AuxiliaryModelsViewModel(center: center))
    }

    var body: some View {
        Form {
            Section {
                Picker("通用辅助 LLM", selection: $viewModel.generalLLMModelID) {
                    Text("跟随主对话模型").tag(Optional<UUID>.none)
                    ForEach(viewModel.textCandidates) { model in
                        Text(viewModel.label(for: model)).tag(Optional(model.id))
                    }
                }
                LabeledContent("当前实际使用", value: viewModel.center.generalAuxiliaryModelLabel)
                    .font(FloeTheme.Typography.metadata)
            } header: {
                Text("文本辅助")
            } footer: {
                Text("用于记忆整理、用户画像、技能提炼与自动标题。视觉理解、图片和视频使用下方各自的模型。")
            }
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
                Picker("软件包审查", selection: $viewModel.packageReviewModelID) {
                    Text("跟随通用辅助 LLM").tag(Optional<UUID>.none)
                    ForEach(viewModel.packageReviewCandidates) { model in
                        Text(viewModel.label(for: model)).tag(Optional(model.id))
                    }
                }
                LabeledContent("当前实际使用", value: viewModel.packageReviewModelLabel)
                    .font(FloeTheme.Typography.metadata)
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

            videoModelSection

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
                } else if viewModel.errorMessage != nil {
                    Label("未保存", systemImage: "exclamationmark.circle")
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(FloeTheme.destructive)
                } else {
                    Text("已自动保存")
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task { await viewModel.load() }
        .onChange(of: viewModel.mode) { _, _ in viewModel.scheduleSave() }
        .onChange(of: viewModel.generalLLMModelID) { _, _ in viewModel.scheduleSave() }
        .onChange(of: viewModel.visionModelID) { _, _ in viewModel.scheduleSave() }
        .onChange(of: viewModel.visionReasoningEnabled) { _, value in
            viewModel.saveVisionReasoning(value)
        }
        .onChange(of: viewModel.packageReviewModelID) { _, _ in viewModel.scheduleSave() }
        .onChange(of: viewModel.sharedModelID) { _, _ in viewModel.scheduleSave() }
        .onChange(of: viewModel.generationModelID) { _, _ in viewModel.scheduleSave() }
        .onChange(of: viewModel.editingModelID) { _, _ in viewModel.scheduleSave() }
        .onChange(of: viewModel.videoModelID) { _, _ in viewModel.scheduleSave() }
        .onDisappear { viewModel.flushPendingSave() }
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

    private var videoModelSection: some View {
        Section {
            modelPicker(
                selection: $viewModel.videoModelID,
                models: viewModel.videoCandidates
            )
        } header: {
            Text("默认视频模型")
        } footer: {
            Text("在“模型服务商”中添加和维护视频模型；这里仅选择 Agent 默认使用的模型。")
        }
    }
}

@MainActor
final class AuxiliaryModelsViewModel: ObservableObject {
    @Published var generalLLMModelID: UUID?
    @Published var mode: AuxiliaryImageMode = .shared
    @Published var visionModelID: UUID?
    @Published var visionReasoningEnabled = false
    @Published var packageReviewModelID: UUID?
    @Published var sharedModelID: UUID?
    @Published var generationModelID: UUID?
    @Published var editingModelID: UUID?
    @Published var videoModelID: UUID?
    @Published private(set) var isSaving = false
    @Published var errorMessage: String?

    let center: ConversationCenter
    private let adapterFactory = ImageProviderAdapterFactory()
    private let cloudPreferences = NSUbiquitousKeyValueStore.default
    private var hasLoaded = false
    private var saveTask: Task<Void, Never>?

    init(center: ConversationCenter) { self.center = center }

    var visionCandidates: [ModelProfile] { center.visionModels }
    var textCandidates: [ModelProfile] {
        center.modelsByProvider.values.flatMap { $0 }
            .filter { $0.isEnabled && $0.supportsGeneralAuxiliaryLLM }
            .sorted { $0.displayName < $1.displayName }
    }
    var packageReviewCandidates: [ModelProfile] { center.approvalModels }
    var packageReviewModelLabel: String {
        guard let id = center.modelPreferences.packageReviewModelID else {
            return center.generalAuxiliaryModelLabel
        }
        guard let model = packageReviewCandidates.first(where: { $0.id == id }) else {
            return "所选模型不可用，请重新选择"
        }
        return label(for: model)
    }

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
    var videoCandidates: [ModelProfile] { center.videoModels }

    func load() async {
        hasLoaded = false
        saveTask?.cancel()
        await center.reload()
        let preferences = center.modelPreferences
        generalLLMModelID = preferences.generalAuxiliaryLLMModelID
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
        videoModelID = preferences.defaultVideoModelID
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
            preferences.generalAuxiliaryLLMModelID = generalLLMModelID
            preferences.visionModelID = visionModelID
            preferences.packageReviewModelID = packageReviewModelID
            preferences.auxiliaryImageMode = mode
            preferences.sharedImageModelID = mode == .shared ? sharedModelID : nil
            preferences.imageGenerationModelID = mode == .separate ? generationModelID : nil
            preferences.imageEditingModelID = mode == .separate ? editingModelID : nil
            preferences.defaultVideoModelID = videoModelID
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

#endif
