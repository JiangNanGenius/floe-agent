// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import FloeNotes
import FloeCore

/// Presentation for the existing document context menu: choose a photo or a
/// file, or restore the automatic cover.
///
/// Every path converges on `NotesCoverCommandService.apply`, so this view keeps
/// no parallel cover state: the document's own stored cover is the only source
/// of truth, and cancellation or a stale document revision leaves the previous
/// cover untouched.
/// One presentation of a cover source picker: the presentation flag and the
/// immutable target snapshot captured when the menu action fires.
///
/// They are deliberately separate state. The system pickers clear their
/// `isPresented` binding on dismiss, and that dismiss setter can run BEFORE
/// the selection/completion callback. Sharing one piece of state for
/// "presented" and "which document" (the previous shape) let the dismiss drop
/// the target, so a real picked photo/file never applied. The snapshot is
/// therefore never cleared by dismissal; it is cleared when a resolved
/// selection finished applying, or overwritten by the next `present(for:)`.
/// Nothing reads a current selection to recover the target.
struct NotesCoverPickerTarget {
    var isPresented = false
    var document: NoteDocument?

    /// Opens the picker for exactly this document; a previous snapshot (for
    /// example one left by a cancelled presentation) is replaced here.
    mutating func present(for document: NoteDocument) {
        self.document = document
        isPresented = true
    }

    /// The immutable target for one resolved callback.
    func resolvedDocument() -> NoteDocument? { document }

    /// A resolved selection (or a cancelled import completion) is done.
    mutating func finish() {
        isPresented = false
        document = nil
    }
}

struct NotesCoverPickerModifier: ViewModifier {
    @Binding var target: NoteDocument?
    let store: NotesStore?
    let onApplied: (NoteDocument) -> Void
    let onError: (String) -> Void

    @State private var photoPicker = NotesCoverPickerTarget()
    @State private var photoItem: PhotosPickerItem?
    @State private var filePicker = NotesCoverPickerTarget()
    @State private var working = false

    func body(content: Content) -> some View {
        content
            .confirmationDialog(Text(String(localized: "notes.cover.menu.title", defaultValue: "Document Cover")),
                                isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }),
                                titleVisibility: .visible, presenting: target) { document in
                Button(String(localized: "notes.cover.menu.photo", defaultValue: "Choose Photo")) {
                    // Reset the selection before a new presentation so picking
                    // the same photo again still fires a change.
                    photoItem = nil
                    photoPicker.present(for: document)
                }
                Button(String(localized: "notes.cover.menu.file", defaultValue: "Choose File")) {
                    filePicker.present(for: document)
                }
                if document.coverResourceID != nil {
                    Button(String(localized: "notes.cover.menu.restore", defaultValue: "Restore Automatic Cover"),
                           role: .destructive) {
                        Task { await apply(.restoreAutomatic, to: document) }
                    }
                }
                Button(role: .cancel) { target = nil } label: {
                    Text(String(localized: "workspace.workspace_canvas_view.cancel", defaultValue: "Cancel"))
                }
            } message: { document in
                Text(document.title)
            }
            .photosPicker(isPresented: $photoPicker.isPresented,
                          selection: $photoItem, matching: .images, photoLibrary: .shared())
            .fileImporter(isPresented: $filePicker.isPresented,
                          allowedContentTypes: [.image], allowsMultipleSelection: false) { result in
                // The importer's dismiss setter never touches the snapshot, so
                // the completion still addresses the document the menu opened.
                guard let document = filePicker.resolvedDocument() else {
                    filePicker.finish()
                    return
                }
                defer { filePicker.finish() }
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    Task { await applyFile(url, to: document) }
                case .failure(let error):
                    onError(error.localizedDescription)
                }
            }
            .onChange(of: photoItem) { _, item in
                guard let item, let document = photoPicker.resolvedDocument() else { return }
                // Consume the item immediately: a repeated same-photo pick
                // must still produce a new change.
                photoItem = nil
                Task {
                    await applyPhoto(item, to: document)
                    photoPicker.finish()
                }
            }
            .overlay {
                if working {
                    ProgressView(String(localized: "notes.cover.working", defaultValue: "Updating cover…"))
                        .padding(12)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
    }

    private func applyPhoto(_ item: PhotosPickerItem, to document: NoteDocument) async {
        await run {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw NoteError.resourceUnavailable
            }
            try Task.checkCancellation()
            guard let store else { throw NoteError.resourceUnavailable }
            try await importAndApply(data: data, document: document, store: store)
        }
    }

    private func applyFile(_ url: URL, to document: NoteDocument) async {
        await run {
            guard let store else { throw NoteError.resourceUnavailable }
            let resource = try await NotesCoverImageProcessor.importCover(from: url, store: store)
            try await commit(resource: resource, document: document, store: store)
        }
    }

    private func apply(_ command: NoteCoverCommand, to document: NoteDocument) async {
        await run {
            guard let store else { throw NoteError.resourceUnavailable }
            let updated = try await NotesCoverCommandService.apply(command, documentID: document.id,
                                                                   expectedRevision: document.revision,
                                                                   expectedCoverRevision: document.normalizedCoverRevision,
                                                                   store: store)
            onApplied(updated)
        }
    }

    /// Import through the one bounded raster normalizer, then commit. A stale
    /// baseline, cancellation or refusal discards only the freshly imported
    /// (unreferenced) asset through the store's reference-guarded collection
    /// path; the previous cover and any referenced bytes are untouched.
    private func importAndApply(data: Data, document: NoteDocument, store: NotesStore) async throws {
        let resource = try await NotesCoverImageProcessor.importCover(data: data, store: store)
        try await commit(resource: resource, document: document, store: store)
    }

    private func commit(resource: UUID, document: NoteDocument, store: NotesStore) async throws {
        do {
            try Task.checkCancellation()
            let updated = try await NotesCoverCommandService.apply(.useResource(resource), documentID: document.id,
                                                                   expectedRevision: document.revision,
                                                                   expectedCoverRevision: document.normalizedCoverRevision,
                                                                   store: store)
            onApplied(updated)
        } catch {
            _ = try? await store.discardUnreferencedResource(resource)
            throw error
        }
    }

    /// One operation at a time; a cancellation (picker dismissed, view left) is
    /// silent and preserves the previous cover; a stale baseline is reported as
    /// a retryable change; a real failure is reported.
    private func run(_ operation: @escaping () async throws -> Void) async {
        guard !working else { return }
        working = true
        defer { working = false }
        do { try await operation() }
        catch is CancellationError {}
        catch NoteError.conflict {
            onError(String(localized: "notes.cover.error.changed", defaultValue: "The document changed. Try again."))
        }
        catch { onError(error.localizedDescription) }
    }
}

extension View {
    /// Presents the cover source dialog with the same bounded ingestion path the
    /// assistant tool uses. `target` is set by the document context menu.
    func notesCoverPicker(target: Binding<NoteDocument?>, store: NotesStore?,
                          onApplied: @escaping (NoteDocument) -> Void,
                          onError: @escaping (String) -> Void) -> some View {
        modifier(NotesCoverPickerModifier(target: target, store: store, onApplied: onApplied, onError: onError))
    }
}
#endif
