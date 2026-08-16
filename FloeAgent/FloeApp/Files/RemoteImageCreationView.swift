#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

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
                Section("图片描述") {
                    TextEditor(text: $prompt).frame(minHeight: 120)
                }
                Section("输出") {
                    Stepper("数量：\(count)", value: $count, in: 1...4)
                    Picker("尺寸", selection: $size) {
                        Text("1K").tag("1K")
                        Text("2K").tag("2K")
                        Text("4K").tag("4K")
                    }
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle("生成图片")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("生成") {
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
            .overlay { if isGenerating { ProgressView("正在生成…").padding().background(.regularMaterial, in: Capsule()) } }
        }
    }
}
#endif
