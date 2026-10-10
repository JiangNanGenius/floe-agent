// FloeApp — select an attachment without changing the conversation's workspace.
#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeModels
import FloeWorkspace

import FloeCore
struct OfficeWorkspaceAttachmentPicker: View {
    enum Purpose {
        case attachment, notesImport
        var title: String { self == .notesImport ? FloeL10n.l("workspace.office_workspace_attachment_picker.import_from_workspace") : FloeL10n.l("workspace.office_workspace_attachment_picker.select_attachment") }
        var progress: String { self == .notesImport ? FloeL10n.l("workspace.office_workspace_attachment_picker.importing_note") : FloeL10n.l("workspace.office_workspace_attachment_picker.inserting_attachment") }
        var failure: String { self == .notesImport ? FloeL10n.l("workspace.office_workspace_attachment_picker.could_not_import_the_file") : FloeL10n.l("workspace.office_workspace_attachment_picker.could_not_insert_the_attachment") }
    }
    @StateObject private var center: WorkspaceCenter
    let purpose: Purpose
    let insert: (URL) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var busy = false

    init(environment: AppEnvironment, purpose: Purpose = .attachment, insert: @escaping (URL) async throws -> Void) {
        _center = StateObject(wrappedValue: WorkspaceCenter(environment: environment, publishesSharedState: false))
        self.purpose = purpose
        self.insert = insert
    }

    var body: some View {
        NavigationStack {
            List {
                if purpose == .notesImport {
                    Text("workspace.office_workspace_attachment_picker.choose_a_file_generated_in_a")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if let error = center.actionError { Text(error).foregroundStyle(.secondary) }
                ForEach(center.workspaces.filter { query.isEmpty || $0.name.localizedStandardContains(query) }) { workspace in
                    NavigationLink {
                        OfficeAttachmentFolder(center: center, workspace: workspace, path: ".", purpose: purpose, busy: $busy) { url in
                            try await insert(url)
                            dismiss()
                        }
                    } label: {
                        Label(workspace.name.isEmpty ? "settings.all_workspaces_files_view.chat_workspace" : workspace.name,
                              systemImage: workspace.kind == .project ? "folder" : "bubble.left")
                    }
                    .accessibilityIdentifier("workspace.import.source.\(workspace.id)")
                }
                if center.workspaces.isEmpty { ContentUnavailableView("workspace.office_workspace_attachment_picker.no_workspaces_available", systemImage: "folder") }
            }
            .navigationTitle(purpose.title)
            .searchable(text: $query, prompt: "workspace.office_workspace_attachment_picker.search_workspaces")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("workspace.workspace_canvas_view.cancel") { dismiss() }.disabled(busy) } }
            .task { await center.reload() }
        }
        .interactiveDismissDisabled(busy)
        .onDisappear { if !busy { center.closeCurrentWorkspace() } }
    }
}

private struct OfficeAttachmentFolder: View {
    @ObservedObject var center: WorkspaceCenter
    let workspace: WorkspaceRecord
    let path: String
    let purpose: OfficeWorkspaceAttachmentPicker.Purpose
    @Binding var busy: Bool
    let insert: (URL) async throws -> Void
    @State private var entries: [FileNode] = []
    @State private var nextPage: String?
    @State private var loading = true
    @State private var error: String?
    @State private var insertionError: String?

    var body: some View {
        List {
            if let error {
                Text(error).foregroundStyle(.secondary)
                Button("settings.document_recovery_list_view.retry") { Task { await load() } }
            }
            ForEach(entries, id: \.relativePath) { file in
                if file.isDirectory {
                    NavigationLink {
                        OfficeAttachmentFolder(center: center, workspace: workspace, path: file.relativePath,
                                               purpose: purpose, busy: $busy, insert: insert)
                    } label: { Label(file.name, systemImage: "folder") }
                } else {
                    Button {
                        Task { await select(file) }
                    } label: {
                        Label {
                            VStack(alignment: .leading) {
                                Text(file.name).foregroundStyle(.primary)
                                Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "doc") }
                    }
                    .accessibilityIdentifier("office.attachment.workspace.file.\(file.relativePath)")
                }
            }
            if nextPage != nil { Button("workspace.office_workspace_attachment_picker.load_more_files") { Task { await load(more: true) } }.disabled(loading) }
            if loading { ProgressView() }
            if !loading, error == nil, entries.isEmpty { ContentUnavailableView("inspector.tree.empty", systemImage: "folder") }
        }
        .navigationTitle(path == "." ? workspace.name : (path as NSString).lastPathComponent)
        .navigationBarBackButtonHidden(busy)
        .disabled(busy)
        .overlay { if busy { ProgressView(purpose.progress).padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .task(id: path) { await load() }
        .alert(purpose.failure, isPresented: Binding(get: { insertionError != nil }, set: { if !$0 { insertionError = nil } })) {
            Button("workspace.office_document_editor_view.ok", role: .cancel) { insertionError = nil }
        } message: { Text(insertionError ?? "") }
    }

    private func load(more: Bool = false) async {
        loading = true
        defer { loading = false }
        do {
            if center.currentWorkspace?.id != workspace.id {
                if workspace.kind == .project { try await center.openWorkspace(id: workspace.id) }
                else if let owner = center.conversationWorkspaceIDs.first(where: { $0.value == workspace.id })?.key {
                    try await center.openTaskWorkspace(conversationID: owner)
                } else { throw CocoaError(.fileNoSuchFile) }
            }
            let page = try await center.listDirectory(relativePath: path, pageToken: more ? nextPage : nil)
            try Task.checkCancellation()
            entries = more ? entries + page.entries : page.entries
            nextPage = page.nextPageToken
            error = nil
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    private func select(_ file: FileNode) async {
        guard !busy, center.currentWorkspace?.id == workspace.id else { return }
        busy = true
        defer { busy = false }
        var temporaryDirectory: URL?
        defer { if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) } }
        do {
            let url: URL
            if center.isCloudWorkspacePath(file.relativePath) || center.isNetworkWorkspacePath(file.relativePath) {
                let bytes = try await center.readRemotePreview(relativePath: file.relativePath)
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                temporaryDirectory = directory
                url = directory.appendingPathComponent((file.name as NSString).lastPathComponent)
                try await Task.detached(priority: .userInitiated) { try bytes.write(to: url, options: .atomic) }.value
            } else {
                guard let service = center.fileService else { throw CocoaError(.fileReadNoPermission) }
                url = try service.guardResolver.resolve(file.relativePath)
            }
            // Keep the workspace's scopes and any downloaded copy alive until
            // the native host has copied and inserted the original bytes.
            try await insert(url)
        } catch { insertionError = error.localizedDescription }
    }
}
#endif
