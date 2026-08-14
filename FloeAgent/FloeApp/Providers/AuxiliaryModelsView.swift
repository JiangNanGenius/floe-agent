// FloeApp — Dedicated image generation/editing model routing.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloeProviders

struct AuxiliaryModelsView: View {
    @StateObject private var viewModel: AuxiliaryModelsViewModel
    @State private var showingAdd = false

    init(center: ConversationCenter) {
        _viewModel = StateObject(wrappedValue: AuxiliaryModelsViewModel(center: center))
    }

    var body: some View {
        Form {
            Section {
                Toggle("Use one model for generation and editing", isOn: Binding(
                    get: { viewModel.mode == .shared },
                    set: { viewModel.setSharedMode($0) }
                ))
            } footer: {
                Text("Image models reuse the selected provider's Keychain credential and stay separate from chat model selection.")
            }

            if viewModel.mode == .shared {
                Section("Shared image model") {
                    modelPicker(selection: $viewModel.sharedModelID, models: viewModel.sharedCandidates)
                    if viewModel.sharedCandidates.isEmpty {
                        Label("Add a model that supports both image generation and editing.", systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section("Image generation") {
                    modelPicker(selection: $viewModel.generationModelID, models: viewModel.generationCandidates)
                }
                Section("Image editing") {
                    modelPicker(selection: $viewModel.editingModelID, models: viewModel.editingCandidates)
                }
            }

            Section {
                Button {
                    showingAdd = true
                } label: {
                    Label("Add image model", systemImage: "plus")
                }
                .disabled(viewModel.center.providers.isEmpty)
            } footer: {
                if viewModel.center.providers.isEmpty {
                    Text("Add a provider before creating an image model.")
                }
            }

            if let error = viewModel.errorMessage {
                Section { Text(error).foregroundStyle(FloeTheme.destructive) }
            }
        }
        .navigationTitle("more.auxiliary_models")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await viewModel.save() } }
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
        Picker("Model", selection: selection) {
            Text("Not configured").tag(Optional<UUID>.none)
            ForEach(models) { model in
                Text(viewModel.label(for: model)).tag(Optional(model.id))
            }
        }
    }
}

@MainActor
final class AuxiliaryModelsViewModel: ObservableObject {
    @Published var mode: AuxiliaryImageMode = .shared
    @Published var sharedModelID: UUID?
    @Published var generationModelID: UUID?
    @Published var editingModelID: UUID?
    @Published private(set) var isSaving = false
    @Published var errorMessage: String?

    let center: ConversationCenter
    private let adapterFactory = ImageProviderAdapterFactory()

    init(center: ConversationCenter) { self.center = center }

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
        sharedModelID = preferences.sharedImageModelID
        generationModelID = preferences.imageGenerationModelID
        editingModelID = preferences.imageEditingModelID
    }

    func setSharedMode(_ shared: Bool) {
        var preferences = ModelSelectionPreferences(
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
        guard let canonical = center.imageModels.first(where: {
            $0.providerID == staged.providerID && $0.remoteModelID == staged.remoteModelID
        }) else { return }
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
        return "\(model.displayName) · \(provider.map { providerName($0.kind) } ?? "Provider")"
    }

    private func supports(_ operation: RemoteImageOperation, model: ModelProfile) -> Bool {
        guard let provider = center.providers.first(where: { $0.id == model.providerID }),
              let adapter = adapterFactory.adapter(for: provider) else { return false }
        return adapter.supports(operation, for: provider)
    }

    private func providerName(_ kind: ProviderKind) -> String {
        ProviderPreset.preset(for: kind).displayName
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
    @State private var isSaving = false
    @State private var errorMessage: String?
    private let adapterFactory = ImageProviderAdapterFactory()

    private var compatibleProviders: [ProviderProfile] {
        center.providers.filter { provider in
            guard let adapter = adapterFactory.adapter(for: provider) else { return false }
            return !adapter.supportedOperations(for: provider).isEmpty
        }
    }

    private var supportedOperations: Set<RemoteImageOperation> {
        guard let providerID,
              let provider = center.providers.first(where: { $0.id == providerID }),
              let adapter = adapterFactory.adapter(for: provider) else { return [] }
        return adapter.supportedOperations(for: provider)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Provider") {
                    Picker("Provider", selection: $providerID) {
                        ForEach(compatibleProviders) { provider in
                            Text(ProviderPreset.preset(for: provider.kind).displayName)
                                .tag(Optional(provider.id))
                        }
                    }
                    if compatibleProviders.isEmpty {
                        Label("No configured provider currently has an implemented image adapter.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Image model") {
                    TextField("Model ID", text: $remoteModelID).textInputAutocapitalization(.never)
                    TextField("Display name", text: $displayName)
                    Toggle("Image generation", isOn: $supportsGeneration)
                        .disabled(!supportedOperations.contains(.generate))
                    Toggle("Image editing", isOn: $supportsEditing)
                        .disabled(!supportedOperations.contains(.edit))
                    if !supportedOperations.contains(.edit) {
                        Text("Image editing is unavailable for this provider in the current build.")
                            .font(FloeTheme.Typography.metadata)
                            .foregroundStyle(.secondary)
                    }
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(FloeTheme.destructive) }
                }
            }
            .navigationTitle("Add Image Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!isValid || isSaving)
                }
            }
            .task {
                if providerID == nil { providerID = compatibleProviders.first?.id }
                applySupportedOperations()
            }
            .onChange(of: providerID) { _, _ in applySupportedOperations() }
        }
    }

    private var isValid: Bool {
        providerID != nil
            && !remoteModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (supportsGeneration || supportsEditing)
    }

    private func save() {
        guard let providerID else { return }
        Task {
            isSaving = true
            defer { isSaving = false }
            var capabilities: ModelCapabilities = []
            if supportsGeneration { capabilities.insert(.imageGeneration) }
            if supportsEditing { capabilities.insert(.imageEditing) }
            let remoteID = remoteModelID.trimmingCharacters(in: .whitespacesAndNewlines)
            let model = ModelProfile(
                providerID: providerID,
                remoteModelID: remoteID,
                displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? remoteID : displayName,
                limits: ModelLimits(contextTokens: 1, maxOutputTokens: 1),
                capabilities: capabilities
            )
            do {
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
    }
}
#endif
