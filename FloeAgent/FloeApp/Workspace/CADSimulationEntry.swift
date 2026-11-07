// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeCAD
import FloeSimulationUI

@MainActor struct CADSimulationEntry: ViewModifier {
    let document: FloeCADDocument
    var directory: URL? = nil
    var ownerID: UUID? = nil
    var onCoverChange: (@MainActor (Bool) -> Void)? = nil
    @Environment(\.cadWorkbenchTransientlyCovered) private var alreadyCovered
    @State private var presented = false
    func body(content: Content) -> some View {
        content
            .environment(\.cadWorkbenchTransientlyCovered,alreadyCovered || presented)
            .toolbar {
                Button(IDELanguageRunText.t("仿真与动画", "Simulation & Animation"),systemImage:"waveform.path") { onCoverChange?(true); presented = true }
                    .disabled(document.isClosed || document.isReadOnly).accessibilityIdentifier("cad.simulation.open")
            }
            .sheet(isPresented:$presented,onDismiss:{ onCoverChange?(false) }) {
                CADSimulationHome(document:document,directory:directory,ownerID:ownerID).presentationSizing(.page)
            }
    }
}

private struct CADSimulationHome: View {
    let document: FloeCADDocument
    let directory: URL?
    let ownerID: UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var entry: CADSimulationSessions.Entry?
    @State private var problem: String?
    var body: some View {
        NavigationStack {
            Group {
                if let entry {
                    SimulationWorkbenchView(model:entry.model) { model in CADSimulationResultViewport(entry:entry,model:model) }
                        .safeAreaInset(edge:.top) {
                            Text(IDELanguageRunText.t("分析当前可见零件", "Analyzes the currently visible parts"))
                                .font(.caption).foregroundStyle(.secondary).frame(maxWidth:.infinity).padding(.vertical,4)
                        }
                } else if let problem {
                    ContentUnavailableView(IDELanguageRunText.t("无法打开仿真", "Unable to open simulation"),systemImage:"cube.transparent",description:Text(problem))
                } else { ProgressView() }
            }
            .navigationTitle(IDELanguageRunText.t("仿真与动画", "Simulation & Animation"))
            .toolbar { ToolbarItem(placement:.cancellationAction) {
                Button(IDELanguageRunText.t("完成", "Done")) {
                    Task { if let entry, entry.model.hasUnsavedChanges, !(await entry.model.save()) { return }; dismiss() }
                }
            } }
            .interactiveDismissDisabled(entry?.model.hasUnsavedChanges == true)
        }.task {
            do { entry = try await CADSimulationSessions.open(document:document,directory:directory,ownerID:ownerID) }
            catch { problem = error.localizedDescription }
        }
    }
}
#endif
