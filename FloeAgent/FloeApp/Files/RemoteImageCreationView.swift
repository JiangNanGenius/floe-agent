#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

import FloeCore
struct RemoteImageCreationView: View {
    @ObservedObject var center: FilesCenter
    @Environment(\.dismiss) private var dismiss
    @State private var prompt = ""
    @State private var count = 1
    @State private var size = "2K"
    @State private var isGenerating = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("files.remote_image_creation_view.image_description") {
                    TextEditor(text: $prompt).frame(minHeight: 120)
                }
                Section("tool.output") {
                    Stepper(FloeL10n.l("files.remote_image_creation_view.count", count), value: $count, in: 1...4)
                    Picker("workspace.workspace_canvas_view.size", selection: $size) {
                        Text("1K").tag("1K")
                        Text("2K").tag("2K")
                        Text("4K").tag("4K")
                    }
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle("files.files_view.generate_image")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("canvas.artifact.action.generate") {
                        Task {
                            isGenerating = true
                            defer { isGenerating = false }
                            do {
                                _ = try await center.performRemoteImage(
                                    operation: .generate,
                                    prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                                    count: count,
                                    size: size
                                )
                                dismiss()
                            } catch { errorMessage = error.localizedDescription }
                        }
                    }
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isGenerating)
                }
            }
            .overlay { if isGenerating { ProgressView("files.remote_image_creation_view.generating").padding().background(.regularMaterial, in: Capsule()) } }
        }
    }
}
#endif
