// SPDX-License-Identifier: MPL-2.0
#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

enum CADWorkbenchDestination { case building, mesh }

private struct CADBuildingWorkspaceActiveKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    var cadBuildingWorkspaceActive: Bool {
        get { self[CADBuildingWorkspaceActiveKey.self] }
        set { self[CADBuildingWorkspaceActiveKey.self] = newValue }
    }
}

/// A navigation child over the existing document, not another CAD owner or
/// NavigationStack. The system Back returns to the retained primary viewport.
struct CADBuildingEditorPage: View {
    let document: FloeCADDocument
    @State private var saving = false
    @State private var saveProblem: String?

    var body: some View {
        FloeBuildingWorkbenchView(document: document)
            .environment(\.cadBuildingWorkspaceActive, true)
            .navigationTitle(FloeCADStrings.text("cad.building.defaultName", "Building"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        guard !saving, !document.isClosed else { return }
                        saving = true
                        Task { @MainActor in
                            let outcome = await document.save()
                            saving = false
                            guard !document.isClosed else { return }
                            saveProblem = outcome.error
                        }
                    } label: {
                        Label(FloeCADStrings.text("cad.ui.common.save", "Save"), systemImage: "tray.and.arrow.down")
                    }.disabled(saving || document.isReadOnly).accessibilityIdentifier("CADBuildingSave")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let saveProblem {
                    Text(saveProblem).font(.callout).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12).background(.bar)
                }
            }
    }
}

/// Native inspector layout keeps the live viewport beside the parameters on
/// iPad. Compact widths use the system adaptation and an explicit model return.
struct CADMeshInspectorContent: View {
    let document: FloeCADDocument
    @Bindable var viewModel: EditorViewModel
    let onClose: () -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(FloeCADStrings.text("cad.workbench.panel.mesh", "Mesh")).font(.headline)
                Spacer()
                Button(action: onClose) {
                    Text(sizeClass == .compact
                        ? (locale.language.languageCode?.identifier == "zh" ? "返回模型" : "Back to model")
                        : FloeCADStrings.text("cad.ui.common.done", "Done"))
                }.frame(minWidth: 44, minHeight: 44).accessibilityIdentifier("CADMeshInspectorClose")
            }.padding(.horizontal, 12)
            Divider()
            ScrollView {
                CADMeshPanelView(document: document, viewModel: viewModel, onStartSculpting: onClose)
                    .padding(12)
            }
        }
    }
}

/// Recoverable import failures remain visible with the original document.
/// Retrying chooses a new authorized file; no expired source URL is reused.
struct CADImportProblemBar: View {
    let message: String
    let onChooseFile: () -> Void
    let onClose: () -> Void
    @Environment(\.locale) private var locale
    @State private var details = false
    private var chinese: Bool { locale.language.languageCode?.identifier == "zh" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(chinese ? "导入未完成" : "Import not completed", systemImage: "exclamationmark.triangle")
                    .font(.callout.weight(.medium))
                Spacer()
                Button(action: onClose) {
                    Label(FloeCADStrings.text("cad.ui.common.close", "Close"), systemImage: "xmark")
                }.frame(minWidth: 44, minHeight: 44).accessibilityIdentifier("CADImportProblemClose")
            }
            if details {
                ScrollView {
                    Text(message).font(.callout).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("CADImportProblemMessage")
                }.frame(maxHeight: 180)
            } else {
                Text(message).font(.callout).lineLimit(3).textSelection(.enabled)
                    .accessibilityIdentifier("CADImportProblemMessage")
            }
            HStack {
                Button(action: onChooseFile) {
                    Label(chinese ? "另选文件…" : "Choose another file…", systemImage: "folder")
                }.frame(minHeight: 44).accessibilityIdentifier("CADImportChooseFile")
                Spacer()
                Button {
                    details.toggle()
                } label: {
                    Label(FloeCADStrings.text("cad.ui.common.details", "Details"),
                          systemImage: details ? "chevron.up" : "chevron.down")
                }.frame(minHeight: 44).accessibilityIdentifier("CADImportProblemDetails")
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.bar)
    }
}
#endif
