import SwiftUI
import FloeCanvasTemplates

/// Compiled host wiring: choosing a workflow appends to the existing canvas,
/// loads personal definitions from the real library and returns a fresh session.
public struct CanvasWorkflowPickerHost: View {
    private let workspace: CanvasTemplateWorkspace
    private let session: TemplateSession
    private let chinese: Bool
    private let onApplied: (TemplateSession) -> Void
    private let onClose: () -> Void
    @State private var personal: [CanvasTemplate] = []
    @State private var busy = false
    @State private var failure: String?

    public init(workspace: CanvasTemplateWorkspace, session: TemplateSession,
                chinese: Bool = true, onApplied: @escaping (TemplateSession) -> Void,
                onClose: @escaping () -> Void) {
        self.workspace = workspace; self.session = session; self.chinese = chinese
        self.onApplied = onApplied; self.onClose = onClose
    }
    public var body: some View {
        CanvasTemplatePicker(personal: personal, chinese: chinese) { selection in
            guard let selection else { onClose(); return }
            Task { await choose(selection) }
        }
        .disabled(busy)
        .overlay { if busy { ProgressView(chinese ? "正在加入流程" : "Adding workflow") } }
        .task {
            do { personal = try await workspace.library.list().map(\.latest) }
            catch { failure = chinese ? "暂时无法读取我的流程。" : "Could not load your workflows." }
        }
        .alert(chinese ? "流程未完成" : "Workflow incomplete", isPresented: .init(
            get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button(chinese ? "好" : "OK") { failure = nil }
        } message: { Text(failure ?? "") }
    }
    @MainActor private func choose(_ template: CanvasTemplate) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let receipt = try await workspace.append(template, to: session)
            try Task.checkCancellation()
            guard await workspace.current(session) else { return }
            let fresh = try await workspace.activate(canvasID: session.canvasID, pageID: receipt.pageID)
            onApplied(fresh)
        } catch is CancellationError {
            // A completed commit remains saved; navigation does not follow a late callback.
        } catch {
            failure = chinese ? "未能加入流程，请重新打开画布后再试。" : "Could not add the workflow. Reopen the canvas and try again."
        }
    }
}
