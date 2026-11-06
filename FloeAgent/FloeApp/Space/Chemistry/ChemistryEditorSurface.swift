// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeChemistryUI

typealias ChemistryNotesInsertion = @MainActor (UUID, UUID, UUID?) async throws -> Void

struct ChemistryEditorSurface: View {
    let session: ChemistryProjectSession
    var onInsertIntoNotes: ChemistryNotesInsertion?
    @State private var showingEnvironment = false
    var body: some View {
        ChemistryWorkbench(state: session.editor)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(IDELanguageRunText.t("环境计算", "Environment calculations"), systemImage: "network") {
                        showingEnvironment = true
                    }.accessibilityIdentifier("chemistry.environment.open")
                }
                if let onInsertIntoNotes {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button(IDELanguageRunText.t("插入选中对象", "Insert selected object"), systemImage: "atom") {
                                insert(session.editor.selectedID, using: onInsertIntoNotes)
                            }.disabled(session.editor.selectedID == nil)
                            Button(IDELanguageRunText.t("插入工程链接", "Insert project link"), systemImage: "link") {
                                insert(nil, using: onInsertIntoNotes)
                            }
                        } label: { Label(IDELanguageRunText.t("插入手记", "Insert in Notes"), systemImage: "note.text.badge.plus") }
                    }
                }
            }
            .sheet(isPresented: $showingEnvironment, onDismiss: {
                Task { await session.editor.refreshCapabilities(); await session.refreshFromHost() }
            }) { ChemistryEnvironmentPanel(session: session) }
            .safeAreaInset(edge: .bottom) {
                if let error = session.diagnostic {
                    DisclosureGroup(IDELanguageRunText.t("操作未完成，查看详情", "Unable to finish. View details")) {
                        Text(error).font(.caption).textSelection(.enabled)
                        Button(IDELanguageRunText.t("关闭", "Dismiss")) { session.diagnostic = nil }
                    }.padding().background(.regularMaterial)
                }
            }
            .accessibilityIdentifier("chemistry.personalEditor")
    }
    private func insert(_ objectID: UUID?, using callback: @escaping ChemistryNotesInsertion) {
        Task { @MainActor in
            guard await session.flushForClose() else { return }
            do { try await callback(session.projectID, session.projectID, objectID) }
            catch is CancellationError {} catch { session.diagnostic = error.localizedDescription }
        }
    }
}
#endif
