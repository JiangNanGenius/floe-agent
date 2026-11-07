// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import SwiftUI
import FloeNotes

@MainActor final class BiologyNotesReturn: ObservableObject {
    struct Request: Identifiable {
        let id: UUID
        let payload: BiologyNotesPayload
        let host: BiologyHostServices
    }
    @Published private(set) var request: Request?
    private var continuation: CheckedContinuation<Void, Error>?

    func insert(_ payload: BiologyNotesPayload, host: BiologyHostServices) async throws {
        guard request == nil else { throw PersonalFileActionError.busy }
        let id = UUID()
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (pending: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else { pending.resume(throwing: CancellationError()); return }
                continuation = pending
                request = .init(id: id, payload: payload, host: host)
            }
        } onCancel: { Task { @MainActor [weak self] in self?.finish(id: id, result: .failure(CancellationError())) } }
    }
    func finish(id: UUID, result: Result<Void, Error>) {
        guard request?.id == id else { return }
        let pending = continuation; continuation = nil; request = nil
        pending?.resume(with: result)
    }
    func cancel() { if let id = request?.id { finish(id: id, result: .failure(CancellationError())) } }
}

/// A separate Notes editor session and one normal CAS/undo batch. The Biology
/// callback succeeds only after the selected note is saved and read back.
@MainActor struct BiologyNotesReturnSheet: View {
    let request: BiologyNotesReturn.Request
    let complete: (Result<Void, Error>) -> Void
    @State private var notes = NotesSession()
    @State private var selected: UUID?
    @State private var busy = false
    @State private var creating = false
    @State private var title = ""
    @State private var diagnostic: String?

    var body: some View {
        NavigationStack {
            Form {
                Section(IDELanguageRunText.t("内容", "Content")) {
                    Text(request.payload.text).font(.callout).textSelection(.enabled)
                        .lineLimit(8).frame(maxWidth: .infinity, alignment: .leading)
                }
                Section(IDELanguageRunText.t("选择手记", "Choose a note")) {
                    ForEach(notes.documents.filter { $0.deletedAt == nil && [.notebook, .mindMap].contains($0.kind) }) { note in
                        Button {
                            Task { @MainActor in
                                guard !busy else { return }
                                if await notes.select(note) { selected = note.id }
                            }
                        } label: {
                            HStack { Text(note.title); Spacer(); if selected == note.id { Image(systemName: "checkmark") } }
                        }.disabled(busy)
                    }
                    Button(IDELanguageRunText.t("新建手记", "New note"), systemImage: "plus") {
                        title = IDELanguageRunText.t("生物记录", "Biology notes"); creating = true
                    }.disabled(busy)
                }
                if let diagnostic { Section { Text(diagnostic).foregroundStyle(.secondary) } }
            }
            .navigationTitle(IDELanguageRunText.t("插入手记", "Insert into note"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(IDELanguageRunText.t("取消", "Cancel")) { complete(.failure(CancellationError())) }.disabled(busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(IDELanguageRunText.t("插入", "Insert")) { Task { await insert() } }
                        .disabled(busy || selected == nil).accessibilityIdentifier("biology.notes.insert")
                }
            }
            .alert(IDELanguageRunText.t("新建手记", "New note"), isPresented: $creating) {
                TextField(IDELanguageRunText.t("名称", "Name"), text: $title)
                Button(IDELanguageRunText.t("创建", "Create")) { Task { await createNote() } }
                Button(IDELanguageRunText.t("取消", "Cancel"), role: .cancel) {}
            }
        }
        .interactiveDismissDisabled(busy)
        .task {
            do { if let store = try await NotesRepository.shared.existingStore() { await notes.open(using: store) } }
            catch { diagnostic = error.localizedDescription }
        }
    }
    private func createNote() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            let store = try await NotesRepository.shared.store()
            let note = try await store.create(NoteDocument(title: title))
            await notes.open(using: store)
            if await notes.select(note) { selected = note.id }
        } catch { diagnostic = error.localizedDescription }
    }
    private func insert() async {
        guard !busy, let selected, let store = notes.store,
              notes.document?.id == selected else { return }
        busy = true; diagnostic = nil; defer { busy = false }
        do {
            let payload = request.payload
            let source = try await request.host.service.project(payload.projectID)
            guard source.revision == payload.projectRevision,
                  payload.assetID == nil || source.assets.contains(where: { $0.id == payload.assetID && $0.revision == payload.assetRevision }) else {
                throw BiologyHostError.changed
            }
            let base = try await store.document(selected)
            guard base.deletedAt == nil, [.notebook, .mindMap].contains(base.kind) else { throw BiologyHostError.changed }
            let reference = NoteWorkReference(workID: payload.projectID, kind: "biology", documentID: payload.projectID,
                revision: payload.projectRevision, objectID: payload.assetID, objectRevision: payload.assetRevision)
            try reference.validate()
            let text = payload.text + "\n" + reference.url.absoluteString
            guard text.utf8.count <= 128 * 1_024 else { throw PersonalFileActionError.tooLarge }
            var edits: [NoteEdit] = []
            if base.kind == .mindMap {
                guard let parent = base.nodes.first(where: { $0.parentID == nil }) else { throw BiologyHostError.changed }
                var node = MindMapNode(parentID: parent.id, title: source.title, note: text,
                    order: base.nodes.filter { $0.parentID == parent.id }.count)
                node.workReference = reference; edits.append(.upsertNode(node))
            } else {
                let template = base.pages.last ?? NotePage()
                let width = max(80, template.width - 80), height = max(100, template.height - 120)
                let count = min(1_800, max(200, Int(width / 16) * max(1, Int(height / 24))))
                var remaining = text[...], index = base.pages.count
                while !remaining.isEmpty {
                    let end = remaining.index(remaining.startIndex, offsetBy: min(count, remaining.count))
                    let part = String(remaining[..<end]); remaining = remaining[end...]
                    let page = NotePage(width: template.width, height: template.height, paper: template.paper)
                    var element = NoteElement(frame: .init(x: 40, y: 50, width: width, height: height), text: part, fontSize: 16)
                    element.workReference = reference
                    edits += [.insertPage(page, at: index), .upsertElement(pageID: page.id, element: element)]; index += 1
                }
            }
            try Task.checkCancellation()
            let current = try await request.host.service.project(payload.projectID)
            guard current.revision == source.revision else { throw BiologyHostError.changed }
            let saved = try await notes.commit(edits, documentID: base.id, expectedRevision: base.revision)
            let readback = try await store.document(saved.id)
            let present = readback.pages.flatMap(\.elements).contains { $0.workReference == reference }
                || readback.nodes.contains { $0.workReference == reference }
            guard present, readback.deletedAt == nil else { throw BiologyHostError.changed }
            complete(.success(()))
        } catch { diagnostic = error.localizedDescription }
    }
}
#endif
