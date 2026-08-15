// FloeApp — Workspace picker / manager.
//
// SPDX-License-Identifier: MPL-2.0
//
// Shared by the composer and the inspector: lists persisted workspaces,
// opens one as current, and adds a new workspace by picking a folder
// (Files / iCloud Drive) — the picked URL becomes a security-scoped
// bookmark on a WorkspaceRecord (never file contents).

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UniformTypeIdentifiers
import FloeModels

/// Workspace list with add (folder picker) / open / delete.
struct WorkspacePickerView: View {
    @ObservedObject var center: WorkspaceCenter
    /// Optional callback after a workspace becomes current (e.g. dismiss).
    var onOpened: (() -> Void)? = nil

    @State private var isPickerPresented = false

    var body: some View {
        List {
            if center.workspaces.isEmpty {
                ContentUnavailableView {
                    Label("workspace.empty", systemImage: "folder.badge.plus")
                } description: {
                    Text("workspace.empty.hint")
                }
            } else {
                ForEach(center.workspaces) { workspace in
                    workspaceRow(workspace)
                }
                .onDelete(perform: delete)
            }
        }
        .navigationTitle("workspace.title")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isPickerPresented = true
                } label: {
                    Label("workspace.add", systemImage: "plus")
                }
                .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                .accessibilityLabel("workspace.add")
            }
        }
        .sheet(isPresented: $isPickerPresented) {
            // Folder picking: directory content type only.
            DocumentPickerView(contentTypes: [.folder]) { url in
                Task { await add(url) }
            }
        }
        .task { await center.reload() }
        .alert(
            Text("workspace.error.title"),
            isPresented: errorBinding,
            presenting: center.actionError
        ) { _ in
            Button("action.done", role: .cancel) { center.actionError = nil }
        } message: { message in
            Text(message)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { center.actionError != nil },
            set: { if !$0 { center.actionError = nil } }
        )
    }

    private func workspaceRow(_ workspace: WorkspaceRecord) -> some View {
        Button {
            Task { await open(workspace.id) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: center.currentWorkspace?.id == workspace.id
                      ? "folder.fill" : "folder")
                    .foregroundStyle(FloeTheme.primary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(workspace.name)
                        .font(FloeTheme.Typography.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let opened = workspace.lastOpenedAt {
                        Text(opened, style: .relative)
                            .font(FloeTheme.Typography.metadata)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if center.currentWorkspace?.id == workspace.id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(FloeTheme.primary)
                        .accessibilityLabel("workspace.current")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minHeight: FloeTheme.minimumTarget)
        .accessibilityLabel(workspace.name)
    }

    private func add(_ url: URL) async {
        do {
            let record = try await center.addWorkspace(fromDirectory: url, name: nil)
            try await center.openWorkspace(id: record.id)
            onOpened?()
        } catch {
            center.actionError = error.localizedDescription
        }
    }

    private func open(_ id: UUID) async {
        do {
            try await center.openWorkspace(id: id)
            onOpened?()
        } catch {
            center.actionError = error.localizedDescription
        }
    }

    private func delete(at offsets: IndexSet) {
        let ids = offsets.compactMap { center.workspaces[safe: $0]?.id }
        Task {
            for id in ids {
                try? await center.deleteWorkspace(id: id)
            }
        }
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
#endif
