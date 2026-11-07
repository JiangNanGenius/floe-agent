// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import WebKit
import UniformTypeIdentifiers

public struct HeavyEditorView: View {
    @Bindable private var controller: HeavyEditorController
    private let onClose: () -> Void
    public init(controller: HeavyEditorController, onClose: @escaping () -> Void = {}) {
        self.controller = controller; self.onClose = onClose
    }
    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Label(controller.document.title, systemImage: controller.descriptor.symbol).font(.headline).lineLimit(1)
                Spacer()
                if controller.isWorking {
                    ProgressView().controlSize(.small)
                    Button { controller.cancel() } label: { Image(systemName: "stop.circle") }
                        .accessibilityLabel(EditorText.t("取消当前操作", "Cancel current action"))
                }
                Button { controller.importRequested = true } label: { Image(systemName: "square.and.arrow.down") }
                    .accessibilityLabel(EditorText.t("导入", "Import"))
                Button { run("history.undo") } label: { Image(systemName: "arrow.uturn.backward") }
                    .accessibilityLabel(EditorText.t("撤销", "Undo")).keyboardShortcut("z", modifiers: .command)
                Button { run("history.redo") } label: { Image(systemName: "arrow.uturn.forward") }
                    .accessibilityLabel(EditorText.t("重做", "Redo")).keyboardShortcut("z", modifiers: [.command, .shift])
                Button { Task { do { try await controller.save() } catch { controller.errorMessage = error.localizedDescription } } } label: {
                    Text(EditorText.t("保存", "Save"))
                }.keyboardShortcut("s", modifiers: .command)
                if controller.onAssistant != nil {
                    Button { controller.onAssistant?() } label: { Image(systemName: "sparkles") }
                        .accessibilityLabel(EditorText.t("助手", "Assistant"))
                }
                Button(EditorText.t("完成", "Done")) { Task { await controller.endPresentation(); onClose() } }
            }.buttonStyle(.borderless).padding(.horizontal).frame(minHeight: 52)
            Divider()
            HeavyEditorWebSurface(webView: controller.webView)
        }
        .overlay {
            if !controller.isReady && controller.errorMessage == nil { ProgressView(EditorText.t("正在打开…", "Opening…")) }
        }
        .fileImporter(isPresented: $controller.importRequested, allowedContentTypes: allowedImports, allowsMultipleSelection: true) { result in
            Task {
                do {
                    for url in try result.get() {
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        try await controller.importFile(name: url.lastPathComponent, data: Data(contentsOf: url))
                    }
                } catch { controller.errorMessage = error.localizedDescription }
            }
        }
        .alert(EditorText.t("无法完成操作", "Unable to complete action"), isPresented: Binding(
            get: { controller.errorMessage != nil }, set: { if !$0 { controller.errorMessage = nil } })) {
                Button(EditorText.t("好", "OK")) { controller.errorMessage = nil }
        } message: { Text(controller.errorMessage ?? "") }
    }
    private var allowedImports: [UTType] {
        let types = controller.descriptor.importExtensions.compactMap { UTType(filenameExtension: $0) }
        return types.isEmpty ? [.data] : types + [.data]
    }
    private func run(_ command: String) {
        Task { do { _ = try await controller.execute(command) } catch { controller.errorMessage = error.localizedDescription } }
    }
}

#if canImport(UIKit)
private struct HeavyEditorWebSurface: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) { }
}
#else
private struct HeavyEditorWebSurface: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) { }
}
#endif
