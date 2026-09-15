// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeNotes

struct NoteEditConflict: Identifiable {
    let id = UUID()
    let current: NoteDocument
    let copy: NoteDocument
    let edits: [NoteEdit]
    let title: String
}

struct NotesConflictAccess: ViewModifier {
    let session: NotesSession
    @State private var reviewing = false
    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if !session.editConflicts.isEmpty {
                Button { reviewing = true } label: {
                    Label("edit.conflict.notesReview", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }.background(.bar)
            }
        }
        .sheet(isPresented: $reviewing) { NotesConflictReviewView(session: session) }
    }
}

private struct NotesConflictReviewView: View {
    let session: NotesSession
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("edit.conflict.notesPreserved").foregroundStyle(.secondary)
                    ForEach(session.editConflicts) { review in
                        VStack(alignment: .leading, spacing: 16) {
                            Text(review.title).font(.headline)
                            version("edit.conflict.current", document: review.current)
                            version("edit.conflict.mine", document: review.copy)
                            Text("edit.conflict.notesApplyHint").font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("edit.conflict.keepBoth") { resolve(review, useMine: false) }
                                    .buttonStyle(.bordered)
                                Button("edit.conflict.applyMine") { resolve(review, useMine: true) }
                                    .buttonStyle(.borderedProminent)
                            }.disabled(saving)
                        }.padding(18).background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
                    }
                }.padding(20)
            }
            .navigationTitle("edit.conflict.notesReview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("action.done") { dismiss() }.disabled(saving) } }
        }.interactiveDismissDisabled(saving)
        .onChange(of: session.editConflicts.isEmpty) { _, empty in if empty { dismiss() } }
    }
    private func version(_ label: LocalizedStringKey, document: NoteDocument) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.subheadline.bold())
            Button(document.title) {
                Task { if await session.select(document) { dismiss() } }
            }.disabled(saving)
            Text(String(document.searchableText.prefix(2_000))).font(.callout).foregroundStyle(.secondary)
                .textSelection(.enabled).lineLimit(10)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func resolve(_ review: NoteEditConflict, useMine: Bool) {
        saving = true
        Task { await session.resolveEditConflict(review, useMine: useMine); saving = false }
    }
}
#endif
