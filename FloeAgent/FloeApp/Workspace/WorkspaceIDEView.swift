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
                    Button { Task { await state.refreshDirty(); if state.dirty { showsCloseConfirmation = true } else { close() } } } label: {
                        Label("ide.close", systemImage: "chevron.down")
                    }.frame(minWidth: 44, minHeight: 44).disabled(state.saving)
                    .accessibilityIdentifier("workspace.ide.close")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { Task { if await state.saveAll() { onSaved() } } } label: {
                        Label("ide.save.all", systemImage: "square.and.arrow.down")
                    }.disabled(!state.ready || state.saving).accessibilityIdentifier("workspace.ide.save").keyboardShortcut("s", modifiers: .command)
                    Button {
                        if let path = state.activePath { preview = Preview(id: path) }
                    } label: { Label("ide.open.editor", systemImage: "doc.richtext") }
                    .disabled(state.activePath == nil || center.currentWorkspace?.id != workspaceID)
                    .accessibilityIdentifier("workspace.ide.richEditor")
                    Button {
                        if let workspaceID, let root {
                            terminalOwner = center.environment.localTerminals.owner(workspaceID: workspaceID, root: root)
                        }
                    } label: { Label("ide.terminal", systemImage: "terminal") }
                    .disabled(root == nil).accessibilityIdentifier("workspace.ide.terminal")
                }
            }
        }
        .interactiveDismissDisabled(state.dirty || state.saving)
        .sheet(item: $terminalOwner) { LocalTerminalView(owner: $0) }
        .sheet(item: $state.conflict) { review in
            TextConflictReviewView(conflict: review, onResolve: { content in
                await state.resolve(review, content: content)
                if state.conflict == nil && !state.dirty { onSaved() }
            }, onCancel: { state.conflict = nil }).id(review.id)
        }
        .fullScreenCover(item: $preview) { item in
            NavigationStack {
                FilePreviewView(relativePath: item.id, center: center, allowsIDEExpansion: false)
                    .toolbar { ToolbarItem(placement: .topBarLeading) { Button("ide.back") { preview = nil } } }
            }
        }
        .confirmationDialog("ide.unsaved", isPresented: $showsCloseConfirmation, titleVisibility: .visible) {
            Button("ide.save.close") { Task { if await state.saveAll() { close() } } }
            Button("ide.discard.close", role: .destructive) { close() }
            Button("ide.continue", role: .cancel) {}
        }
    }
    private func close() { onSaved(); dismiss() }
}
#endif
