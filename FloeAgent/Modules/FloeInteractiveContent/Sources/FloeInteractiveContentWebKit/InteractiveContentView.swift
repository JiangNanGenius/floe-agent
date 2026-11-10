// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import WebKit
import FloeInteractiveContentCore

public struct InteractiveViewStrings: Sendable {
    public var retry: String
    public var continueAnalysis: String
    public var save: String
    public var unsavedChanges: String
    public var actionFailed: String
    public var details: String
    public init(retry: String, continueAnalysis: String, save: String,
                unsavedChanges: String = "Changes have not been saved. Your input is still here.",
                actionFailed: String = "The action could not finish. Your input is still here.", details: String = "Details") {
        self.retry = retry; self.continueAnalysis = continueAnalysis; self.save = save
        self.unsavedChanges = unsavedChanges
        self.actionFailed = actionFailed; self.details = details
    }
    public static func localized(locale: Locale = .current) -> Self {
        locale.language.languageCode?.identifier == "zh"
            ? .init(retry: "重试", continueAnalysis: "继续分析", save: "保存",
                    unsavedChanges: "更改尚未保存，当前输入仍保留。", actionFailed: "操作未完成，当前输入仍保留。", details: "详情")
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
    private let managesLifecycle: Bool
    @State private var actionError: String?
    @State private var failedAction: ContentAction?
    @State private var isPerformingAction = false
    private enum ContentAction { case continueAnalysis, save }

    public init(controller: InteractiveWebController, strings: InteractiveViewStrings = .localized(),
                onContinue: ((InteractiveState) -> Void)? = nil, onSave: ((Data) -> Void)? = nil,
                managesLifecycle: Bool = true) {
        self.controller = controller
        self.strings = strings
        self.onContinue = onContinue
        self.onSave = onSave
        self.managesLifecycle = managesLifecycle
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
                    if onContinue != nil {
                        Button(strings.continueAnalysis) { perform(.continueAnalysis) }
                    }
                    if onSave != nil {
                        Button(strings.save) { perform(.save) }
                    }
                    if isPerformingAction { ProgressView().controlSize(.small) }
                }
                .disabled(!controller.isReady || isPerformingAction)
            }
            if let actionError {
                Text(strings.actionFailed).font(.footnote)
                DisclosureGroup(strings.details) { Text(actionError).font(.caption).textSelection(.enabled) }
                if let failedAction {
                    Button(strings.retry) { perform(failedAction) }.disabled(isPerformingAction || !controller.isReady)
                }
            }
            if controller.hasUnsavedChanges { Text(strings.unsavedChanges).font(.footnote) }
        }
        .task { if managesLifecycle { await controller.resume() } }
        .onDisappear { if managesLifecycle { Task { await controller.suspend() } } }
    }

    private func perform(_ action: ContentAction) {
        guard !isPerformingAction, controller.isReady else { return }
        isPerformingAction = true
        actionError = nil
        failedAction = action
        Task { @MainActor in
            defer { isPerformingAction = false }
            do {
                switch action {
                case .continueAnalysis: onContinue?(try await controller.currentState())
                case .save: onSave?(try await controller.exportHTML())
                }
                failedAction = nil
            } catch { actionError = error.localizedDescription }
        }
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
