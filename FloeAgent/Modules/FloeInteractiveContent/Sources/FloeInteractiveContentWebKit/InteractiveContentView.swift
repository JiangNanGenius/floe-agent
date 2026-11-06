// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import WebKit
import FloeInteractiveContentCore

public struct InteractiveViewStrings: Sendable {
    public var retry: String
    public var continueAnalysis: String
    public var save: String
    public var unsavedChanges: String
    public init(retry: String, continueAnalysis: String, save: String,
                unsavedChanges: String = "Changes have not been saved. Your input is still here.") {
        self.retry = retry; self.continueAnalysis = continueAnalysis; self.save = save
        self.unsavedChanges = unsavedChanges
    }
    public static func localized(locale: Locale = .current) -> Self {
        locale.language.languageCode?.identifier == "zh"
            ? .init(retry: "重试", continueAnalysis: "继续分析", save: "保存",
                    unsavedChanges: "更改尚未保存，当前输入仍保留。")
            : .init(retry: "Retry", continueAnalysis: "Continue analysis", save: "Save")
    }
}

/// The host owns the controller/session and decides which native actions exist.
/// The same controller can be moved to an expanded surface after detaching its old view.
public struct InteractiveContentView: View {
    @ObservedObject private var controller: InteractiveWebController
    private let strings: InteractiveViewStrings
    private let onContinue: ((InteractiveState) -> Void)?
    private let onSave: ((Data) -> Void)?
    @State private var actionFailed = false

    public init(controller: InteractiveWebController, strings: InteractiveViewStrings = .localized(),
                onContinue: ((InteractiveState) -> Void)? = nil, onSave: ((Data) -> Void)? = nil) {
        self.controller = controller
        self.strings = strings
        self.onContinue = onContinue
        self.onSave = onSave
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !controller.document.title.isEmpty { Text(controller.document.title).font(.headline) }
            if controller.failed {
                Text(controller.document.fallbackText)
                Button(strings.retry) { Task { await controller.resume() } }
            } else {
                NativeWebSurface(webView: controller.webView)
                    .frame(height: min(720, max(160, controller.contentHeight)))
                    .overlay { if !controller.isReady { ProgressView() } }
            }
            if onContinue != nil || onSave != nil {
                HStack {
                    if let onContinue {
                        Button(strings.continueAnalysis) {
                            Task { do { onContinue(try await controller.currentState()) }
                                   catch { actionFailed = true } }
                        }
                    }
                    if let onSave {
                        Button(strings.save) {
                            Task { do { onSave(try await controller.exportHTML()) }
                                   catch { actionFailed = true } }
                        }
                    }
                }
                .disabled(!controller.isReady)
            }
            if actionFailed { Text(controller.document.fallbackText).font(.footnote) }
            if controller.hasUnsavedChanges { Text(strings.unsavedChanges).font(.footnote) }
        }
        .task { await controller.resume() }
        .onDisappear { Task { await controller.suspend() } }
    }
}

#if os(iOS)
private struct NativeWebSurface: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#elseif os(macOS)
private struct NativeWebSurface: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#endif
