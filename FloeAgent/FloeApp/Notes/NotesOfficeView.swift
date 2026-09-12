// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeNotes
import FloeCore

/// Office owns its native working-copy lifecycle. Notes only promotes a successfully saved
/// copy into a new immutable resource revision; the original resource is never modified.
struct NotesOfficeView: View {
    let session: NotesSession
    let document: NoteDocument
    @StateObject private var office = OfficeFileSession()
    @State private var draftURL: URL?
    @State private var baseRevision: Int?
    @State private var baseResourceID: UUID?
    @State private var editing = false
    @State private var pendingCommit = false
    @State private var committing = false
    @State private var message: String?
    @State private var recoveryURL: URL?
    @State private var recoveries: [Recovery] = []
    @State private var showingRecoveries = false
    private struct Recovery: Identifiable, Sendable {
        let url: URL
        let date: Date
        var id: URL { url }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !recoveries.isEmpty {
                Button("发现 \(recoveries.count) 份 Office 恢复副本", systemImage: "clock.arrow.circlepath") { showingRecoveries = true }
                    .padding().frame(maxWidth: .infinity, alignment: .leading)
            }
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
        .onChange(of: document.officeResourceID) { _, value in
            guard value != baseResourceID, !editing, !committing, !pendingCommit else { return }
            Task {
                await office.release()
                draftURL = nil; baseRevision = nil; baseResourceID = nil
                await prepare()
            }
        }
        .sheet(isPresented: $showingRecoveries) {
            NavigationStack {
                List(recoveries) { recovery in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(recovery.url.lastPathComponent).font(.headline)
                        Text(recovery.date, style: .date).font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("恢复为独立文档") {
                                Task {
                                    do {
                                        guard let store = session.store else { return }
                                        var restored = try await NoteFileImporter.importFile(recovery.url, notebookID: document.notebookID, store: store)
                                        restored.title = document.title + " · 恢复副本"
                                        session.importDocument(restored)
                                        showingRecoveries = false
                                    } catch { message = error.localizedDescription }
                                }
                            }
                            ShareLink("导出", item: recovery.url)
                        }
                    }.padding(.vertical, 6)
                }
                .navigationTitle("Office 恢复")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showingRecoveries = false } } }
            }
        }
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
            let documentID = document.id
            var sourceHashes: [String: String] = [:]
            for folder in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                let metadataURL = folder.appendingPathComponent("recovery.json")
                guard let data = try? Data(contentsOf: metadataURL), data.count < 16_384,
                      let fields = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                      let resourceID = fields["resourceID"], let id = UUID(uuidString: resourceID),
                      let original = try? await store.resourceURL(id) else { continue }
                sourceHashes[resourceID] = original.lastPathComponent
            }
            let originalHashes = sourceHashes
            recoveries = try await Task.detached(priority: .utility) {
                var result: [Recovery] = []
                let currentHash = try FloeDigest.sha256Hex(ofFileAt: source)
                for folder in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
                    try Task.checkCancellation()
                    let metadataURL = folder.appendingPathComponent("recovery.json")
                    guard folder.resolvingSymlinksInPath().deletingLastPathComponent() == root.resolvingSymlinksInPath(),
                          let metadata = try? Data(contentsOf: metadataURL), metadata.count < 16_384,
                          let fields = try? JSONSerialization.jsonObject(with: metadata) as? [String: String],
                          fields["documentID"] == documentID.uuidString,
                          let name = fields["fileName"], name == (name as NSString).lastPathComponent else { continue }
                    let file = folder.appendingPathComponent(name)
                    guard file.resolvingSymlinksInPath().deletingLastPathComponent() == folder.resolvingSymlinksInPath(),
                          let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]), values.isRegularFile == true,
                          let hash = try? FloeDigest.sha256Hex(ofFileAt: file), hash != currentHash,
                          hash != (fields["sourceHash"] ?? originalHashes[fields["resourceID"] ?? ""]) else { continue }
                    result.append(Recovery(url: file, date: values.contentModificationDate ?? .distantPast))
                }
                return result.sorted { $0.date > $1.date }
            }.value
            let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = folder.appendingPathComponent(fileName)
            try FileManager.default.copyItem(at: source, to: target)
            let metadata: [String: String] = ["documentID": document.id.uuidString, "resourceID": resource.uuidString,
                                             "revision": String(document.revision), "fileName": fileName, "sourceHash": source.lastPathComponent]
            try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]).write(to: folder.appendingPathComponent("recovery.json"), options: .atomic)
            draftURL = target; baseRevision = document.revision; baseResourceID = resource; recoveryURL = target
            await office.open(target)
            if let error = office.error { message = error }
        } catch { message = error.localizedDescription }
    }

    private func commit() async {
        guard !committing, let url = draftURL, let store = session.store, baseRevision != nil else { return }
        committing = true
        defer { committing = false }
        do {
            // OfficeFileSession's save path has already validated its native save receipt and
            // working-copy commit. Re-import never overwrites the former immutable resource.
            let resource = try await store.importResource(from: url, mediaType: "application/octet-stream")
            let current = try await store.document(document.id)
            guard current.officeResourceID == baseResourceID else { throw NoteError.conflict }
            let updated = try await session.commit([.replaceOfficeResource(resource)], documentID: document.id, expectedRevision: current.revision)
            let savedResource = try await store.resourceURL(resource)
            let metadata = ["documentID": document.id.uuidString, "resourceID": resource.uuidString,
                            "revision": String(updated.revision), "fileName": url.lastPathComponent, "sourceHash": savedResource.lastPathComponent]
            // The content transaction has committed. A metadata failure must not retry an old revision.
            baseRevision = updated.revision; baseResourceID = resource; pendingCommit = false; message = nil
            do {
                try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]).write(to: url.deletingLastPathComponent().appendingPathComponent("recovery.json"), options: .atomic)
            } catch { message = "文档已保存，但恢复记录未能更新：\(error.localizedDescription)" }
            await office.open(url)
        } catch {
            message = "未能保存到手记：\(error.localizedDescription) Office 编辑副本已保留，可重试或导出。"
            recoveryURL = url
        }
    }
}
#endif
