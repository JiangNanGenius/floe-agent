// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeNotes

/// Office owns its native working-copy lifecycle. Notes only promotes a successfully saved
/// copy into a new immutable resource revision; the original resource is never modified.
struct NotesOfficeView: View {
    let session: NotesSession
    let document: NoteDocument
    @StateObject private var office = OfficeFileSession()
    @State private var draftURL: URL?
    @State private var baseRevision: Int?
    @State private var editing = false
    @State private var pendingCommit = false
    @State private var committing = false
    @State private var message: String?
    @State private var recoveryURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            if let message {
                VStack(alignment: .leading, spacing: 8) {
                    Text(message).font(.callout)
                    HStack {
                        if pendingCommit { Button("重试保存到手记") { Task { await commit() } }.disabled(committing) }
                        if let recoveryURL { ShareLink("导出恢复副本", item: recoveryURL) }
                    }
                }.padding().frame(maxWidth: .infinity, alignment: .leading).background(.regularMaterial)
            }
            if !OfficeFileSession.available {
                ContentUnavailableView("Office 编辑器不可用", systemImage: "doc", description: Text("此构建不包含原生 Office 引擎。原文件已保留。"))
            } else {
                OfficeDocumentSurface(session: office)
                HStack {
                    Text("Word · Excel · PowerPoint").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("编辑文档", systemImage: "square.and.pencil") { editing = true }
                        .buttonStyle(.borderedProminent).disabled(!office.canAct || pendingCommit || committing)
                }.padding()
            }
        }
        .task { await prepare() }
        .sheet(isPresented: $editing, onDismiss: {
            Task {
                if pendingCommit { await commit() }
                else if let draftURL { await office.open(draftURL) }
            }
        }) {
            NavigationStack {
                OfficeDocumentEditorView(relativePath: document.officeFileName ?? document.title, session: office, onSaved: {
                    pendingCommit = true
                })
            }.interactiveDismissDisabled()
        }
        .onDisappear {
            if !editing { Task { await office.release() } }
        }
    }

    private func prepare() async {
        guard draftURL == nil, let store = session.store, let resource = document.officeResourceID,
              let fileName = document.officeFileName else { return }
        do {
            let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true)
                .appendingPathComponent("FloeAgent/Notes/OfficeDrafts/\(document.id.uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let source = try await store.resourceURL(resource)
            let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = folder.appendingPathComponent(fileName)
            try FileManager.default.copyItem(at: source, to: target)
            let metadata: [String: String] = ["documentID": document.id.uuidString, "resourceID": resource.uuidString,
                                             "revision": String(document.revision), "fileName": fileName]
            try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]).write(to: folder.appendingPathComponent("recovery.json"), options: .atomic)
            draftURL = target; baseRevision = document.revision; recoveryURL = target
            await office.open(target)
            if let error = office.error { message = error }
        } catch { message = error.localizedDescription }
    }

    private func commit() async {
        guard !committing, let url = draftURL, let store = session.store, let revision = baseRevision else { return }
        committing = true
        defer { committing = false }
        do {
            // OfficeFileSession's save path has already validated its native save receipt and
            // working-copy commit. Re-import never overwrites the former immutable resource.
            let resource = try await store.importResource(from: url, mediaType: "application/octet-stream")
            let updated = try await session.commit([.replaceOfficeResource(resource)], documentID: document.id, expectedRevision: revision)
            baseRevision = updated.revision; pendingCommit = false; message = nil
            await office.open(url)
        } catch {
            message = "未能保存到手记：\(error.localizedDescription) Office 编辑副本已保留，可重试或导出。"
            recoveryURL = url
        }
    }
}
#endif
