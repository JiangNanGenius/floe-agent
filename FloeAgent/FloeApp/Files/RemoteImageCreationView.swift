#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

import FloeCore
import FloeProviders

struct RemoteImageCreationView: View {
    @ObservedObject var center: FilesCenter
    @Environment(\.dismiss) private var dismiss
    @State private var prompt = ""
    @State private var options: [FilesCenter.RemoteImageModelOption] = []
    @State private var selectedModelID: UUID?
    @State private var count = 1
    @State private var resolution = ""
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?

    private var selectedOption: FilesCenter.RemoteImageModelOption? {
        options.first { $0.id == selectedModelID }
    }

    private var contract: ImageGenerationPresetResolver.ParameterContract? {
        selectedOption?.contract
    }

    private var maximumCount: Int {
        max(1, contract?.maximumCount ?? 1)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("files.remote_image_creation_view.image_description") {
                    TextEditor(text: $prompt).frame(minHeight: 120)
                }
                Section("auxiliary.image_model") {
                    if options.isEmpty {
                        Text("files.remote_image_creation_view.no_available_model")
                            .foregroundStyle(.secondary)
                    } else if options.count == 1, let selectedOption {
                        Text(selectedOption.title)
                    } else {
                        Picker("auxiliary.image_model", selection: $selectedModelID) {
                            ForEach(options) { option in
                                Text(option.title).tag(Optional(option.id))
                            }
                        }
                    }
                    if let contract, !contract.resolution.isEmpty {
                        Picker("providers.model_editor_view.resolution", selection: $resolution) {
                            ForEach(contract.resolution, id: \.self) { value in
                                Text(value).tag(value)
                            }
                        }
                    }
                    if maximumCount > 1 {
                        Stepper(
                            FloeL10n.l("files.remote_image_creation_view.count", count),
                            value: $count,
                            in: 1...maximumCount)
                    }
                    if let selectedOption {
                        Text(selectedOption.providerTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
                if let statusMessage {
                    Section("files.remote_image_creation_view.result") {
                        Text(statusMessage)
                        Button("action.done") { dismiss() }
                    }
                }
            }
            .navigationTitle("files.files_view.generate_image")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("canvas.artifact.action.generate") {
                        Task { await generate() }
                    }
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || selectedOption == nil
                              || isGenerating
                              || statusMessage != nil)
                }
            }
            .overlay { if isGenerating { ProgressView("files.remote_image_creation_view.generating").padding().background(.regularMaterial, in: Capsule()) } }
            .task { loadOptions() }
            .onChange(of: selectedModelID) { _, _ in normalizeControls() }
        }
    }

    @MainActor
    private func loadOptions() {
        guard options.isEmpty else { return }
        options = center.remoteImageModelOptions(operation: .generate)
        if selectedModelID == nil || !options.contains(where: { $0.id == selectedModelID }) {
            selectedModelID = options.first?.id
        }
        normalizeControls()
    }

    @MainActor
    private func normalizeControls() {
        guard let contract else {
            count = 1
            resolution = ""
            return
        }
        count = min(max(count, max(1, contract.minimumCount)), maximumCount)
        if !contract.resolution.contains(resolution) {
            resolution = contract.defaultResolution ?? contract.resolution.first ?? ""
        }
    }

    @MainActor
    private func generate() async {
        guard let selectedOption else { return }
        isGenerating = true
        defer { isGenerating = false }
        errorMessage = nil
        statusMessage = nil
        do {
            let selection = ImageGenerationSelection(
                resolution: resolution.isEmpty ? nil : resolution)
            let (attachments, report) = try await center.performRemoteImageResult(
                operation: .generate,
                prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                count: count,
                modelID: selectedOption.id,
                selection: selection,
                agentInitiated: true,
                routing: .selected
            )
            if report.isComplete {
                dismiss()
                return
            }
            var message = report.userSummary
            if !attachments.isEmpty {
                message += " " + FloeL10n.l(
                    "files.remote_image_creation_view.created_images_saved")
            }
            statusMessage = message
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
#endif
