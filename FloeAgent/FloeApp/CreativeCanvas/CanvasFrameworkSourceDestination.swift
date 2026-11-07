// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeNotes

struct CanvasFrameworkSourceRequest: Identifiable { let id: UUID }

/// A linked original opens as a child and returns to the same canvas.
struct CanvasFrameworkSourceDestination: View {
    let sourceID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var work: PersonalContentRecord?
    @State private var note: NoteDocument?
    @State private var session = NotesSession()
    @State private var error: String?

    var body: some View {
        Group {
            if let work { PersonalContentEditor(record: work) }
            else {
                NavigationStack {
                    Group {
                        if let note, session.document?.id == note.id {
                            NotesDocumentEditor(session: session, document: note, embedded: true)
                                .modifier(NotesConflictAccess(session: session))
                        } else if let error {
                            ContentUnavailableView(IDELanguageRunText.t("无法打开资料", "Unable to open source"),
                                systemImage: "doc.text", description: Text(error))
                        } else { ProgressView() }
                    }.toolbar { ToolbarItem(placement: .confirmationAction) {
                        Button(IDELanguageRunText.t("完成", "Done")) { dismiss() }
                    } }
                }
            }
        }.task(id: sourceID) { await open() }
    }

    @MainActor private func open() async {
        do {
            if let value = try? await PersonalContentService.shared.library().resolve(sourceID) {
                try Task.checkCancellation(); work = value.record
            } else {
                let store = try await NotesRepository.shared.store()
                let document = try await store.document(sourceID)
                guard document.deletedAt == nil else { throw PersonalContentError.missingDocument }
                await session.open(using: store)
                _ = await session.select(document)
                try Task.checkCancellation(); note = document
            }
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}
#endif
