// FloeApp — standalone fullscreen Office editor for one workspace document.
//
// SPDX-License-Identifier: MPL-2.0
//
// The file inspector's expand action routes an Office document (docx/xlsx/
// pptx and the other ODF/legacy equivalents) straight to the native editor
// instead of the IDE: Office bytes must never pass through the code
// workbench. Local files resolve through the guarded workspace file service;
// cloud/network files are snapshotted into a private temporary copy first.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeWorkspace

struct OfficeFullscreenEditorView: View {
    let relativePath: String
    @ObservedObject var center: WorkspaceCenter
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = OfficeFileSession()
    /// Cloud/network documents need their own snapshot store; the visible
    /// preview copy (if any) is never cleared by this surface.
    @StateObject private var remoteCopy = RemoteFilePreviewCopy()
    @State private var loadError: String?
    @State private var didOpen = false

    var body: some View {
        NavigationStack {
            Group {
                if let loadError {
                    ContentUnavailableView {
                        Label("无法打开文档", systemImage: "doc.badge.ellipsis")
                    } description: {
                        Text(loadError)
                    }
                } else {
                    OfficeDocumentEditorView(
                        relativePath: relativePath,
                        session: session,
                        stableInkIdentity: remoteIdentity,
                        onClose: { dismiss() },
                        // The edit intent is requested explicitly by `open()`
                        // once the local open has settled; nothing here relies
                        // on parent/child `.task` ordering.
                        requestsEditingOnAppear: false
                    )
                }
            }
        }
        .task { await open() }
        .onDisappear { Task { await session.release() } }
    }

    private var fileName: String { (relativePath as NSString).lastPathComponent }

    /// Cloud/network documents are preview snapshots only; editing must never
    /// auto-start on a temporary copy that has no remote write-back.
    private var isRemoteDocument: Bool {
        center.isCloudWorkspacePath(relativePath) || center.isNetworkWorkspacePath(relativePath)
    }

    /// Stable logical identity for a cloud/network document whose editing URL
    /// is a fresh preview copy on every load.
    private var remoteIdentity: OfficeInkDocumentIdentity? {
        guard center.isCloudWorkspacePath(relativePath) || center.isNetworkWorkspacePath(relativePath) else {
            return nil
        }
        return OfficeInkDocumentIdentity(workspaceIdentity: center.currentWorkspace?.id.uuidString,
                                         relativePath: relativePath)
    }

    private func open() async {
        guard !didOpen else { return }
        didOpen = true
        guard OfficeFileSession.available else {
            loadError = "此构建不包含原生 Office 引擎。原文件已保留。"
            return
        }
        guard let service = center.fileService else {
            loadError = "请先打开一个工作区。"
            return
        }
        do {
            let url: URL
            if isRemoteDocument {
                let bytes = try await center.readRemotePreview(relativePath: relativePath)
                try Task.checkCancellation()
                url = try remoteCopy.store(bytes, fileName: fileName)
            } else {
                url = try service.guardResolver.resolve(relativePath)
                try service.guardResolver.assertReadableSize(url)
            }
            session.isRemoteSnapshot = isRemoteDocument
            await session.open(url)
            if let error = session.error { loadError = error }
            // Local files go straight to editing, but only after the open has
            // settled and only when it succeeded: the session's intent queue
            // serializes this request, so no parent/child `.task` ordering is
            // ever depended on. Remote snapshots stay read-only previews.
            if !isRemoteDocument, loadError == nil {
                await session.requestEditing()
            }
        } catch {
            loadError = error.localizedDescription
        }
    }
}
#endif
