// FloeApp — Per-model capability and limit editor.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore

struct ModelEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: ModelProfile
    @State private var makeDefault: Bool
    let isDefault: Bool
    let onMakeDefault: () -> Void
    let onSave: (ModelProfile) -> Void

    init(
        model: ModelProfile,
        isDefault: Bool,
        onMakeDefault: @escaping () -> Void,
        onSave: @escaping (ModelProfile) -> Void
    ) {
        _model = State(initialValue: model)
        _makeDefault = State(initialValue: isDefault)
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
                    if makeDefault {
                        Label("model.default", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(FloeTheme.primary)
                    } else {
                        Button("model.set_default") { makeDefault = true }
                    }
                }
                Section("model.section.capabilities") {
                    Label("model.capability.text", systemImage: "text.bubble")
                    capabilityToggle("model.capability.vision", capability: .vision)
                    capabilityToggle("model.capability.tools", capability: .tools)
                    capabilityToggle("model.capability.approval", capability: .approval)
                }
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
            }
            .navigationTitle("model.settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.save") {
                        model.capabilities.insert(.text)
                        if makeDefault && !isDefault { onMakeDefault() }
                        onSave(model)
                        dismiss()
                    }
                    .disabled(model.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || model.remoteModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || model.limits.contextTokens <= 0 || model.limits.maxOutputTokens < 0
                              || (model.limits.maxOutputTokens > 0
                                  && model.limits.maxOutputTokens > model.limits.contextTokens))
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
