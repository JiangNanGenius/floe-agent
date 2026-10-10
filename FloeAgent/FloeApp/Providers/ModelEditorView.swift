// FloeApp — Per-model capability and limit editor.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore

struct ModelEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: ModelProfile
    @State private var makeDefault: Bool
    let serviceRole: ProviderServiceRole
    let isDefault: Bool
    let onMakeDefault: () -> Void
    let onSave: (ModelProfile) -> Void

    init(
        model: ModelProfile,
        serviceRole: ProviderServiceRole = .conversation,
        isDefault: Bool,
        onMakeDefault: @escaping () -> Void,
        onSave: @escaping (ModelProfile) -> Void
    ) {
        _model = State(initialValue: model)
        _makeDefault = State(initialValue: isDefault)
        self.serviceRole = serviceRole
        self.isDefault = isDefault
        self.onMakeDefault = onMakeDefault
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("model.section.identity") {
                    TextField("model.display_name", text: $model.displayName)
                    TextField("model.remote_id", text: $model.remoteModelID)
                        .textInputAutocapitalization(.never)
                    Toggle("model.enabled", isOn: $model.isEnabled)
                    if serviceRole == .conversation {
                        Toggle("model.hide_from_primary_picker", isOn: Binding(
                        get: { model.isHiddenFromPrimaryPicker == true },
                        set: { hidden in
                            model.isHiddenFromPrimaryPicker = hidden
                            if hidden { makeDefault = false }
                        }
                        ))
                        .accessibilityIdentifier("model.hide_from_primary_picker")
                        if makeDefault {
                            Label("model.default", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(FloeTheme.primary)
                        } else {
                            Button("model.set_default") { makeDefault = true }
                        }
                    }
                }
                Section("model.section.capabilities") {
                    capabilityControls
                }
                if serviceRole == .conversation {
                    Section {
                    Picker("model.reasoning.effort", selection: reasoningEffort) {
                        ForEach(ModelReasoningEffort.allCases) { effort in
                            Text(effort.localizedTitle).tag(effort)
                        }
                    }
                    .accessibilityIdentifier("model.reasoning_effort")
                    } header: {
                        Text("model.section.reasoning")
                    } footer: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("model.reasoning.hint")
                            if model.remoteModelID.lowercased().contains("deepseek") {
                                Text("providers.model_editor.reasoning.deepseek_medium_note")
                            }
                        }
                    }
                }
                if serviceRole == .conversation {
                    Section {
                        TokenLimitPicker(
                            title: "model.context_tokens",
                            value: $model.limits.contextTokens,
                            presets: [32_768, 65_536, 131_072, 262_144, 1_048_576]
                        )
                        TokenLimitPicker(
                            title: "model.max_output_tokens",
                            value: $model.limits.maxOutputTokens,
                            presets: [4_096, 8_192, 16_384, 32_768, 65_536],
                            allowsEmpty: true
                        )
                    } header: {
                        Text("model.section.limits")
                    } footer: {
                        Text("model.limits.hint")
                    }
                } else {
                    mediaCapabilitySummary
                }
            }
            .navigationTitle("model.settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.save") {
                        if serviceRole == .conversation {
                            model.capabilities.insert(.text)
                            // Every text model can be selected as the reviewer.
                            // Approval behavior itself is controlled per task.
                            model.capabilities.insert(.approval)
                        } else {
                            model.capabilities.remove(.text)
                            model.capabilities.remove(.tools)
                            model.capabilities.remove(.approval)
                            model.isHiddenFromPrimaryPicker = true
                        }
                        if makeDefault && !isDefault { onMakeDefault() }
                        onSave(model)
                        dismiss()
                    }
                    .disabled(model.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || model.remoteModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || (serviceRole == .conversation && (
                                model.limits.contextTokens <= 0 || model.limits.maxOutputTokens < 0
                                || (model.limits.maxOutputTokens > 0
                                    && model.limits.maxOutputTokens > model.limits.contextTokens)
                              )))
                }
            }
        }
    }

    private func capabilityToggle(_ title: LocalizedStringKey, capability: ModelCapabilities) -> some View {
        Toggle(title, isOn: Binding(
            get: { model.capabilities.contains(capability) },
            set: { enabled in
                if enabled { model.capabilities.insert(capability) }
                else { model.capabilities.remove(capability) }
            }
        ))
    }

    @ViewBuilder
    private var capabilityControls: some View {
        switch serviceRole {
        case .conversation:
            Label("model.capability.text", systemImage: "text.bubble")
            capabilityToggle("model.capability.vision", capability: .vision)
            capabilityToggle("model.capability.tools", capability: .tools)
        case .image:
            capabilityToggle("auxiliary.generation", capability: .imageGeneration)
            capabilityToggle("auxiliary.editing", capability: .imageEditing)
        case .video:
            Label("core.canvas_operations.video_generation", systemImage: "video.badge.plus")
            capabilityToggle("providers.model_editor_view.supports_reference_images", capability: .vision)
        }
    }

    private var reasoningEffort: Binding<ModelReasoningEffort> {
        Binding(
            get: { model.effectiveReasoningEffort },
            set: { model.reasoningEffort = $0 == .automatic ? nil : $0 }
        )
    }

    @ViewBuilder
    private var mediaCapabilitySummary: some View {
        let providerFamily = mediaProviderFamily
        let kind: MediaKind = serviceRole == .video ? .video : .image
        let presets = providerFamily.map { OfficialMediaModelCatalog.models(provider: $0, kind: kind) } ?? []
        let descriptor = presets.first { $0.remoteModelID == model.remoteModelID }
        Section {
            if let descriptor {
                if !descriptor.supportedAspectRatios.isEmpty {
                    LabeledContent("providers.model_editor_view.supported_ratios", value: descriptor.supportedAspectRatios.joined(separator: "、"))
                }
                if !descriptor.supportedResolutions.isEmpty {
                    LabeledContent("providers.model_editor_view.resolution", value: descriptor.supportedResolutions.joined(separator: "、"))
                }
                if !descriptor.supportedDurations.isEmpty {
                    LabeledContent("providers.model_editor_view.supported_duration", value: descriptor.supportedDurations.map { FloeL10n.l("providers.model_editor_view.sec", $0) }.joined(separator: "、"))
                }
                if !descriptor.supportedQualities.isEmpty {
                    LabeledContent("providers.model_editor_view.generation_quality", value: descriptor.supportedQualities.joined(separator: "、"))
                }
                if descriptor.maximumReferenceAssets > 0 {
                    LabeledContent("providers.model_editor_view.reference", value: FloeL10n.l("providers.model_editor_view.up_to", descriptor.maximumReferenceAssets))
                }
                if descriptor.supportsAudio { Label("providers.model_editor_view.audio_supported", systemImage: "speaker.wave.2") }
                if descriptor.supportsWatermark { Label("providers.model_editor_view.supports_watermark_settings", systemImage: "seal") }
                if descriptor.supportsSeed { Label("providers.model_editor_view.supports_random_seed", systemImage: "dice") }
                if descriptor.supportsPromptOptimization { Label("providers.model_editor_view.supports_prompt_refinement", systemImage: "wand.and.stars") }
            } else {
                Text("providers.model_editor_view.this_is_an_advanced_custom_media")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(serviceRole == .video ? "providers.model_editor_view.video_capabilities" : "providers.model_editor_view.image_capabilities")
        } footer: {
            Text("providers.model_editor_view.media_models_are_configured_by_official")
        }
    }

    private var mediaProviderFamily: MediaProviderFamily? {
        let id = model.remoteModelID.lowercased()
        if id.contains("gpt-image") { return .openAI }
        if id.contains("gemini") || id.contains("veo") { return .googleGemini }
        if id.contains("seedream") || id.contains("seedance") || id.contains("doubao") { return .volcengineArk }
        if id.contains("wan") || id.contains("qwen-image") { return .alibabaModelStudio }
        return nil
    }
}

private extension ModelReasoningEffort {
    var localizedTitle: LocalizedStringKey {
        switch self {
        case .automatic: "model.reasoning.automatic"
        case .low: "model.reasoning.low"
        case .medium: "model.reasoning.medium"
        case .high: "model.reasoning.high"
        case .maximum: "model.reasoning.maximum"
        }
    }
}

private struct TokenLimitPicker: View {
    let title: LocalizedStringKey
    @Binding var value: Int
    let presets: [Int]
    var allowsEmpty = false

    private let columns = [GridItem(.adaptive(minimum: 64), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                Spacer()
                Text(value == 0 && allowsEmpty
                     ? String(localized: "model.limit.not_set")
                     : Self.shortLabel(value))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(presets, id: \.self) { preset in
                    Button(Self.shortLabel(preset)) { value = preset }
                        .buttonStyle(.bordered)
                        .tint(value == preset ? FloeTheme.primary : .secondary)
                }
            }
            TextField(title, text: numericText)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
            if allowsEmpty, value != 0 {
                Button("model.limit.use_provider_default") { value = 0 }
                    .font(.footnote)
            }
        }
        .padding(.vertical, 4)
    }

    private var numericText: Binding<String> {
        Binding(
            get: { value == 0 ? "" : String(value) },
            set: { input in
                let digits = input.filter(\.isNumber)
                if digits.isEmpty {
                    value = 0
                } else if let parsed = Int(digits) {
                    value = parsed
                }
            }
        )
    }

    static func shortLabel(_ tokens: Int) -> String {
        if tokens >= 1_048_576, tokens.isMultiple(of: 1_048_576) {
            return "\(tokens / 1_048_576)M"
        }
        if tokens >= 1_024, tokens.isMultiple(of: 1_024) {
            return "\(tokens / 1_024)K"
        }
        return tokens.formatted(.number.grouping(.automatic))
    }
}
#endif
