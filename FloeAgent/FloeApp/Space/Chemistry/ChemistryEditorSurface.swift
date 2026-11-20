// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeChemistryUI

typealias ChemistryNotesInsertion = @MainActor (UUID, UUID, UUID?) async throws -> Void

struct ChemistryEditorSurface: View {
    let session: ChemistryProjectSession
    var onInsertIntoNotes: ChemistryNotesInsertion?
    @State private var showingEnvironment = false
    @State private var preparationObjectID: UUID?
    var body: some View {
        ChemistryWorkbench(state: session.editor, onPrepareStructure: { id in
            preparationObjectID = id; showingEnvironment = true
        })
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(IDELanguageRunText.t("环境计算", "Environment calculations"), systemImage: "network") {
                        preparationObjectID = nil; showingEnvironment = true
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
                preparationObjectID = nil
                Task { await session.editor.refreshCapabilities(); await session.refreshFromHost() }
            }) { ChemistryEnvironmentPanel(session: session, preparingObjectID: preparationObjectID) }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if let notice = session.notice {
                        Label(notice, systemImage: "checkmark.circle")
                            .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                            .accessibilityIdentifier("chemistry.notice")
                            .task(id: notice) {
                                do {
                                    try await Task.sleep(for: .seconds(5))
                                } catch {
                                    // Cancellation (view swap or a newer notice):
                                    // never clear a message that may have been
                                    // re-shown under this identifier.
                                    return
                                }
                                if session.notice == notice { session.notice = nil }
                            }
                    }
                    if let error = session.diagnostic {
                        DisclosureGroup(IDELanguageRunText.t("操作未完成，查看详情", "Unable to finish. View details")) {
                            Text(error).font(.caption).textSelection(.enabled)
                            Button(IDELanguageRunText.t("关闭", "Dismiss")) { session.diagnostic = nil }
                        }.padding().background(.regularMaterial)
                    }
                }
            }
            .accessibilityElement(children: .contain)
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
