// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeWorkspace

/// An IDE pins one workspace for its lifetime, including terminal ownership.
struct WorkspaceIDEView: View {
    @ObservedObject var center: WorkspaceCenter
    let initialRelativePath: String?
    let onSaved: () -> Void
    @StateObject private var state: IDEWorkbenchState
    private let workspaceID: UUID?
    private let workspaceName: String
    private let root: URL?
    @Environment(\.dismiss) private var dismiss
    @State private var showsCloseConfirmation = false
    @State private var terminalOwner: LocalTerminalOwner?
    @State private var preview: Preview?
    private struct Preview: Identifiable { let id: String }

    init(initialRelativePath: String? = nil, center: WorkspaceCenter, onSaved: @escaping () -> Void = {}) {
        self.center = center; self.initialRelativePath = initialRelativePath; self.onSaved = onSaved
        self.workspaceID = center.currentWorkspace?.id
        self.workspaceName = center.currentWorkspace?.name ?? String(localized: "ide.workspace")
        self.root = center.currentRootURL
        _state = StateObject(wrappedValue: IDEWorkbenchState(files: center.fileService))
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let error = state.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.red).padding(10)
                }
                if root != nil {
                    IDEWorkbenchWebView(state: state, initialPath: initialRelativePath)
                } else { ContentUnavailableView("ide.workspace.unavailable", systemImage: "folder.badge.questionmark") }
            }
            .navigationTitle(workspaceName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { if state.dirty { showsCloseConfirmation = true } else { close() } } label: {
                        Label("ide.close", systemImage: "chevron.down")
                    }.frame(minWidth: 44, minHeight: 44)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { Task { await state.saveAll(); if !state.dirty { onSaved() } } } label: {
                        Label("ide.save.all", systemImage: "square.and.arrow.down")
                    }.disabled(!state.ready).keyboardShortcut("s", modifiers: .command)
                    Button {
                        if let path = state.activePath { preview = Preview(id: path) }
                    } label: { Label("ide.open.editor", systemImage: "doc.richtext") }
                    .disabled(state.activePath == nil || center.currentWorkspace?.id != workspaceID)
                    Button {
                        if let workspaceID, let root {
                            terminalOwner = center.environment.localTerminals.owner(workspaceID: workspaceID, root: root)
                        }
                    } label: { Label("ide.terminal", systemImage: "terminal") }
                    .disabled(root == nil)
                }
            }
        }
        .interactiveDismissDisabled(state.dirty)
        .sheet(item: $terminalOwner) { LocalTerminalView(owner: $0) }
        .fullScreenCover(item: $preview) { item in
            NavigationStack {
                FilePreviewView(relativePath: item.id, center: center, allowsIDEExpansion: false)
                    .toolbar { ToolbarItem(placement: .topBarLeading) { Button("ide.back") { preview = nil } } }
            }
        }
        .confirmationDialog("ide.unsaved", isPresented: $showsCloseConfirmation, titleVisibility: .visible) {
            Button("ide.save.close") { Task { await state.saveAll(); if !state.dirty { close() } } }
            Button("ide.discard.close", role: .destructive) { close() }
            Button("ide.continue", role: .cancel) {}
        }
    }
    private func close() { onSaved(); dismiss() }
}
#endif
