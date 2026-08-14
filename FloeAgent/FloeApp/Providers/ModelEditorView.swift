// FloeApp — Per-model capability and limit editor.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore

struct ModelEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: ModelProfile
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
        self.isDefault = isDefault
        self.onMakeDefault = onMakeDefault
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Model") {
                    TextField("Display name", text: $model.displayName)
                    TextField("Model ID", text: $model.remoteModelID)
                        .textInputAutocapitalization(.never)
                    Toggle("Enabled", isOn: $model.isEnabled)
                    if isDefault {
                        Label("Default model", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(FloeTheme.primary)
                    } else {
                        Button("Set as default") { onMakeDefault() }
                    }
                }
                Section("Capabilities") {
                    Label("Text", systemImage: "text.bubble")
                    capabilityToggle("Vision input", capability: .vision)
                    capabilityToggle("Tool calling", capability: .tools)
                    capabilityToggle("Approval", capability: .approval)
                }
                Section("Limits") {
                    TextField("Context tokens", value: $model.limits.contextTokens, format: .number)
                        .keyboardType(.numberPad)
                    TextField("Maximum output tokens", value: $model.limits.maxOutputTokens, format: .number)
                        .keyboardType(.numberPad)
                }
            }
            .navigationTitle("Model settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.capabilities.insert(.text)
                        onSave(model)
                        dismiss()
                    }
                    .disabled(model.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || model.remoteModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || model.limits.contextTokens <= 0 || model.limits.maxOutputTokens <= 0)
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
#endif
