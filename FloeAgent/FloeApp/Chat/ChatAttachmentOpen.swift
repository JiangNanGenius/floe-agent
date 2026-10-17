// SPDX-License-Identifier: MPL-2.0
// Chat attachment handoff into the existing task workspace and file editors.
#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloeModels
import FloePersistence
import FloeTools
import FloeWorkspace

struct ChatAttachmentOpenRequest: Identifiable, Equatable {
    let conversationID: UUID
    let messageID: UUID
    let attachmentID: UUID?
    var id: String { "\(conversationID)/\(messageID)/\(attachmentID?.uuidString ?? "missing")" }
}

enum ChatAttachmentOpenError: Error, Equatable {
    case unavailable, wrongOwner, invalidName
}

@MainActor
enum ChatAttachmentOpenAdapter {
    /// Same identity/path as ConversationCenter.importRunAttachments. Existing
    /// task edits take precedence over the immutable original attachment.
    static func relativePath(for attachment: AttachmentRef) throws -> String {
        let name = (attachment.displayName as NSString).lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("\\"),
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ChatAttachmentOpenError.invalidName
        }
        return "Attachments/\(attachment.id.uuidString)/\(name)"
    }

    /// Existing edited copies need the same symlink/ownership protection as
    /// first import. resolve() alone permits links pointing within the root.
    private static func checkedTarget(_ path: String, service: WorkspaceFileService) throws -> URL {
        let target = try service.guardResolver.resolve(path)
        let root = service.guardResolver.rootURL.standardizedFileURL.resolvingSymlinksInPath()
        guard target.path.hasPrefix(root.path + "/") else { throw ChatAttachmentOpenError.wrongOwner }
        var cursor = root.appendingPathComponent(path).standardizedFileURL
        while cursor.path != root.path && cursor.path.hasPrefix(root.path + "/") {
            if (try? cursor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw ChatAttachmentOpenError.unavailable
            }
            cursor.deleteLastPathComponent()
        }
        return target
    }

    static func prepare(_ request: ChatAttachmentOpenRequest,
                        store: any ConversationStore,
                        resolveURL: (AttachmentRef) throws -> URL,
                        workspace: WorkspaceCenter) async throws -> String {
        guard let id = request.attachmentID,
              try await store.conversation(id: request.conversationID) != nil,
              let attachment = try await store.attachment(id: id) else { throw ChatAttachmentOpenError.unavailable }
        guard attachment.conversationID == request.conversationID,
              attachment.messageID == nil || attachment.messageID == request.messageID else { throw ChatAttachmentOpenError.wrongOwner }
        // Attachment metadata alone cannot prove which conversation owns a
        // message (legacy attachments may not carry messageID). Read bounded
        // existing pages until the exact persisted message is found.
        var cursor: ConversationMessageCursor?
        var messageOwned = false
        repeat {
            try Task.checkCancellation()
            let page = try await store.messagePage(conversationID: request.conversationID, before: cursor, limit: 100)
            if page.messages.contains(where: { $0.id == request.messageID && $0.conversationID == request.conversationID }) {
                messageOwned = true; break
            }
            guard page.hasEarlier, let next = page.earlierCursor, next != cursor else { break }
            cursor = next
        } while true
        guard messageOwned else { throw ChatAttachmentOpenError.wrongOwner }
        let parts = try await store.parts(messageID: request.messageID)
        guard parts.contains(where: { $0.attachmentID == id && ($0.kind == .file || $0.kind == .image) }) else {
            throw ChatAttachmentOpenError.unavailable
        }
        try Task.checkCancellation()
        // Local feature scope: same durable task workspace, no global route
        // change or new project. WorkspaceCenter repairs legacy missing binds.
        try await workspace.openTaskWorkspace(conversationID: request.conversationID)
        try Task.checkCancellation()
        let ownership = SQLiteWorkspaceStore(database: workspace.environment.database)
        guard let canonicalID = try await ownership.workspaceID(conversationID: request.conversationID),
              workspace.currentWorkspace?.id == canonicalID,
              let service = workspace.fileService else { throw ChatAttachmentOpenError.wrongOwner }
        let path = try relativePath(for: attachment)
        let target = try checkedTarget(path, service: service)
        if FileManager.default.fileExists(atPath: target.path) {
            guard (try target.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
                throw ChatAttachmentOpenError.unavailable
            }
            return path
        }
        let source = try resolveURL(attachment)
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let facts = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard facts.isRegularFile == true, let size = facts.fileSize, size > 0 else { throw ChatAttachmentOpenError.unavailable }
        // User attachments follow the existing disk import path rather than
        // the 4 MiB model-generated payload limit. No whole-file Data read.
        let cancellation = CancellationToken()
        do {
            _ = try await withTaskCancellationHandler {
                try await Task.detached(priority: .userInitiated) {
                    try service.importUserFile(from: source, to: path,
                        expectedSHA256: attachment.sha256, cancellation: cancellation)
                }.value
            } onCancel: { cancellation.cancel() }
        } catch is CancellationError { throw CancellationError() }
        catch {
            // A concurrent opener may have created the same edit copy. Never
            // overwrite it; all other failures remain actionable to the user.
            if let error = error as? WorkspaceToolError, case .alreadyExists = error {
                let currentTarget = try checkedTarget(path, service: service)
                guard (try currentTarget.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
                    throw ChatAttachmentOpenError.unavailable
                }
            } else { throw ChatAttachmentOpenError.unavailable }
        }
        try Task.checkCancellation()
        guard try await store.conversation(id: request.conversationID) != nil,
              try await ownership.workspaceID(conversationID: request.conversationID) == canonicalID else {
            throw ChatAttachmentOpenError.wrongOwner
        }
        return path
    }
}

struct ChatAttachmentOpenSheet: View {
    let request: ChatAttachmentOpenRequest
    private let environment: AppEnvironment
    @StateObject private var workspace: WorkspaceCenter
    @Environment(\.dismiss) private var dismiss
    @State private var path: String?
    @State private var failed = false
    @State private var attempt = 0

    init(request: ChatAttachmentOpenRequest, environment: AppEnvironment) {
        self.request = request; self.environment = environment
        _workspace = StateObject(wrappedValue: WorkspaceCenter(environment: environment, publishesSharedState: false))
    }

    var body: some View {
        Group {
            if let path, WorkspaceFileType.isCode(path) || WorkspaceFileType.isHTML(path) {
                WorkspaceIDEView(initialRelativePath: path, center: workspace)
            } else {
                NavigationStack {
                    Group {
                        if let path {
                            FilePreviewView(relativePath: path, center: workspace,
                                            conversationID: request.conversationID, allowsDesignPage: false)
                        } else if failed {
                            ContentUnavailableView {
                                Label("chat.attachment.open_failed", systemImage: "doc.badge.ellipsis")
                            } description: {
                                Text("chat.attachment.try_again")
                            } actions: {
                                Button("action.retry") { attempt += 1 }
                            }
                        } else {
                            ProgressView("chat.attachment.opening")
                        }
                    }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("action.done") { dismiss() } }
                    }
                }
            }
        }
        .accessibilityIdentifier("thread.attachment.editor")
        .task(id: attempt) {
            path = nil; failed = false
            do {
                let selected = try await ChatAttachmentOpenAdapter.prepare(request,
                    store: environment.conversationStore,
                    resolveURL: { try environment.filesCenter.resolveURL(for: $0) }, workspace: workspace)
                try Task.checkCancellation()
                path = selected
            } catch is CancellationError {
                // A dismissed/changed route cannot present a late editor.
            } catch {
                failed = true
            }
        }
    }
}
#endif
