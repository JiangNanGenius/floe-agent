// FloeAppTests — cover picker target lifecycle (G2, primary-reported UI bug).
//
// The real UI report: after "Choose Photo", the system picker opened, the
// synthetic photo was selected and the picker closed, but the card stayed on
// the note page after 20 s. Root cause: the `photosPicker`/`fileImporter`
// `isPresented` setters cleared the pending document on dismiss, and that
// dismissal runs BEFORE the selection/completion callback, so the callback
// guard found no target. These deterministic tests pin the replacement
// contract of `NotesCoverPickerTarget`: the presentation flag and the
// immutable document snapshot are separate, and dismissal never drops the
// snapshot a resolved callback still has to use.
#if canImport(UIKit)
import Foundation
import Testing
import FloeNotes
@testable import FloeApp

@Suite("FloeApp.NotesCoverPickerLifecycle")
struct NotesCoverPickerLifecycleTests {
    @Test("dismiss before the selection callback keeps the exact target")
    func dismissBeforeSelectionKeepsTarget() {
        var picker = NotesCoverPickerTarget()
        let document = NoteDocument(title: "封面文档")
        picker.present(for: document)
        #expect(picker.isPresented)
        #expect(picker.resolvedDocument()?.id == document.id)

        // What the system picker does on pick: it clears the presentation
        // flag first...
        picker.isPresented = false
        // ...and the snapshot must survive until the callback resolves it
        // (the previous shape cleared the document here and the pick was
        // silently dropped).
        #expect(picker.resolvedDocument()?.id == document.id)

        // The selection/completion callback captures the target, applies it,
        // and only then finishes the presentation.
        let resolved = picker.resolvedDocument()
        #expect(resolved?.id == document.id)
        picker.finish()
        #expect(picker.document == nil)
        #expect(!picker.isPresented)
    }

    @Test("a later presentation overwrites a cancelled snapshot; nothing reads the current selection")
    func representationOverwritesCancelledSnapshot() {
        var picker = NotesCoverPickerTarget()
        let first = NoteDocument(title: "第一份")
        let second = NoteDocument(title: "第二份")
        picker.present(for: first)
        #expect(picker.resolvedDocument()?.id == first.id)
        // Cancelled presentation: the flag drops, the snapshot stays inert
        // until the next menu action replaces it.
        picker.isPresented = false
        picker.present(for: second)
        #expect(picker.resolvedDocument()?.id == second.id)
        picker.finish()
        #expect(picker.resolvedDocument() == nil)
        #expect(!picker.isPresented)
    }

    @Test("re-presenting resets to a fresh, non-presented state after finish")
    func finishResetsPresentation() {
        var picker = NotesCoverPickerTarget()
        let document = NoteDocument(title: "封面文档")
        picker.present(for: document)
        picker.finish()
        #expect(picker.document == nil)
        #expect(!picker.isPresented)
        picker.present(for: document)
        #expect(picker.document?.id == document.id)
        #expect(picker.isPresented)
    }
}
#endif
