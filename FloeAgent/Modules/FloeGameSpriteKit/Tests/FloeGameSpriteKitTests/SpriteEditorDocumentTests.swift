// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeGameCore
import FloeGameEditingCore
import FloeGameSpriteCore

@Suite("Sprite editor over the shared editing session")
@MainActor
struct SpriteEditorDocumentTests {
    private func loadedModel(_ name: String) async throws
        -> (FileGameProjectRepository, GameEditingSession, GameRelativePath,
            SpriteEditorDocument, [UInt8]) {
        let sheet = try SpriteTestSupport.sheet(columns: 12, rows: 8,
                                                frameWidth: 4, frameHeight: 4)
        let (repository, session, path, unknown) = try await SpriteTestSupport.makeProject(
            name: name, sheet: sheet)
        let model = SpriteEditorDocument(session: session, path: path)
        await model.load()
        model.applyPreset(.rpgMakerMV, scope: .fullSheet)
        #expect(model.layout?.columns == 12)
        #expect(model.layout?.rows == 8)
        #expect(model.layout?.frameWidth == 4)
        #expect(model.layout?.frameHeight == 4)
        return (repository, session, path, model, unknown)
    }

    @Test("Load adopts a valid full-sheet grid and preserves exact pixels")
    func loadAndPreset() async throws {
        let (_, session, path, model, _) = try await loadedModel("load")
        #expect(model.image != nil)
        #expect(model.selectedFrameIndex == 0)
        #expect(model.selectedFrame?.characterIndex == 0)
        #expect(model.selectedFrame?.direction == .down)
        #expect(model.animationFrameIndices == [0, 1, 2])
        #expect(model.hasUnsavedChanges == false)

        let originalBytes = try await session.documentBytes(at: path)
        let decoded = try SpritePNG.decode(originalBytes)
        let topLeft = try #require(decoded.color(x: 0, y: 0))
        #expect(decoded.color(x: 0, y: 0) == topLeft)
        #expect(model.frameImage(at: 0) != nil)
        #expect(model.previewFrameImage != nil)
    }

    @Test("A brush gesture becomes one shared edit with undo/redo")
    func brushUndoRedo() async throws {
        let (_, session, path, model, _) = try await loadedModel("brush")
        let originalBytes = try await session.documentBytes(at: path)
        let original = try SpritePNG.decode(originalBytes)
        let untouched = try #require(original.color(x: 4, y: 4))
        let paint = SpriteRGBA(red: 10, green: 20, blue: 30, alpha: 255)
        model.color = paint
        model.tool = .brush
        #expect(model.beginStroke(at: SpritePixelPoint(x: 1, y: 1)))
        model.continueStroke(to: SpritePixelPoint(x: 2, y: 1))
        await model.endStroke()

        #expect(model.issue == nil)
        #expect(session.history.count == 1)
        #expect(session.isDocumentDirty(at: path))
        let editedBytes = try await session.documentBytes(at: path)
        let edited = try SpritePNG.decode(editedBytes)
        #expect(edited.color(x: 1, y: 1) == paint)
        #expect(edited.color(x: 2, y: 1) == paint)
        #expect(edited.color(x: 4, y: 4) == untouched)
        #expect(model.image?.color(x: 1, y: 1) == paint)

        try await session.undo()
        await model.refreshFromSession()
        #expect(model.image?.color(x: 1, y: 1) == original.color(x: 1, y: 1))

        try await session.redo()
        await model.refreshFromSession()
        #expect(model.image?.color(x: 1, y: 1) == paint)
        #expect(model.image?.color(x: 4, y: 4) == untouched)
    }

    @Test("A refresh during a stroke does not clobber the in-flight gesture")
    func inFlightStrokeKeepsExternalBytes() async throws {
        let (_, session, path, model, _) = try await loadedModel("inflight")
        let original = try SpritePNG.decode(try await session.documentBytes(at: path))
        let paint = SpriteRGBA(red: 240, green: 5, blue: 15, alpha: 255)
        let external = SpriteRGBA(red: 5, green: 60, blue: 240, alpha: 255)
        model.color = paint
        model.tool = .brush
        #expect(model.beginStroke(at: SpritePixelPoint(x: 1, y: 1)))

        try await session.editDocument(at: path, summary: GameEditCopy("External pixel", "外部像素")) { bytes in
            var image = try SpritePNG.decode(bytes)
            image.setColor(external, x: 20, y: 20)
            return try SpritePNG.encode(image)
        }
        await model.refreshFromSession()
        #expect(model.activeStroke != nil)
        #expect(model.image?.color(x: 20, y: 20) == original.color(x: 20, y: 20))

        model.continueStroke(to: SpritePixelPoint(x: 2, y: 2))
        await model.endStroke()
        #expect(model.issue == nil)
        let final = try SpritePNG.decode(try await session.documentBytes(at: path))
        #expect(final.color(x: 1, y: 1) == paint)
        #expect(final.color(x: 20, y: 20) == external)
    }

    @Test("Cancel and eyedropper do not create project edits")
    func noOpGestures() async throws {
        let (_, session, _, model, _) = try await loadedModel("noop")
        let originalColor = try #require(model.image?.color(x: 1, y: 1))
        model.tool = .eyedropper
        #expect(model.beginStroke(at: SpritePixelPoint(x: 1, y: 1)))
        #expect(model.color == originalColor)
        #expect(session.history.isEmpty)
        #expect(!session.isDirty)

        model.tool = .brush
        #expect(model.beginStroke(at: SpritePixelPoint(x: 2, y: 2)))
        model.continueStroke(to: SpritePixelPoint(x: 3, y: 3))
        model.cancelStroke()
        #expect(model.activeStroke == nil)
        #expect(session.history.isEmpty)
        #expect(!session.isDirty)
    }

    @Test("Fill is clipped to one frame and can be undone")
    func fillFrame() async throws {
        let (_, session, path, model, _) = try await loadedModel("fill")
        let original = try SpritePNG.decode(try await session.documentBytes(at: path))
        let adjacent = try #require(original.color(x: 4, y: 0))
        let fill = SpriteRGBA(red: 240, green: 30, blue: 40, alpha: 255)
        model.color = fill
        model.tool = .fill
        model.selectFrame(0)
        #expect(model.beginStroke(at: SpritePixelPoint(x: 0, y: 0)))
        await model.endStroke()

        let filled = try SpritePNG.decode(try await session.documentBytes(at: path))
        for y in 0..<4 {
            for x in 0..<4 {
                #expect(filled.color(x: x, y: y) == fill)
            }
        }
        #expect(filled.color(x: 4, y: 0) == adjacent)
        #expect(session.history.count == 1)
        try await session.undo()
        await model.refreshFromSession()
        #expect(model.image?.color(x: 0, y: 0) == original.color(x: 0, y: 0))
    }

    @Test("Save, reopen and unrelated files stay byte-exact")
    func saveReopen() async throws {
        let (repository, session, path, model, unknown) = try await loadedModel("save")
        model.color = SpriteRGBA(red: 1, green: 2, blue: 3, alpha: 255)
        model.tool = .brush
        model.beginStroke(at: SpritePixelPoint(x: 0, y: 0))
        model.continueStroke(to: SpritePixelPoint(x: 3, y: 3))
        await model.endStroke()
        let editedBytes = try await session.documentBytes(at: path)
        let saved = try await session.save(title: "Sprite edit")
        #expect(session.expectedRevision == saved.revision)
        #expect(!session.isDirty)

        let reopened = try await GameEditingSession.open(
            repository: repository, projectID: session.projectID,
            owner: SpriteTestSupport.owner,
            adapter: GameUnknownEditingAdapter(engine: .rpgMakerMV))
        let reopenedBytes = try await reopened.documentBytes(at: path)
        #expect(reopenedBytes == editedBytes)
        let reopenedPNG = try SpritePNG.decode(reopenedBytes)
        #expect(reopenedPNG.color(x: 0, y: 0) == SpriteRGBA(red: 1, green: 2, blue: 3, alpha: 255))

        let keepPath = try GameRelativePath("notes/keep.bin")
        let keepBytes = try await reopened.documentBytes(at: keepPath)
        #expect([UInt8](keepBytes) == unknown)
        #expect(reopened.baseProject.files.contains { $0.path == keepPath })
    }

    @Test("Draft recovery restores a sprite edit without saving")
    func draftRecovery() async throws {
        let (repository, session, path, model, _) = try await loadedModel("draft")
        let original = try SpritePNG.decode(try await session.documentBytes(at: path))
        let paint = SpriteRGBA(red: 200, green: 10, blue: 20, alpha: 255)
        model.color = paint
        model.tool = .brush
        model.beginStroke(at: SpritePixelPoint(x: 2, y: 2))
        await model.endStroke()
        #expect(model.issue == nil)
        #expect(session.pendingDraft == nil) // detected only when opening a session

        let second = try await GameEditingSession.open(
            repository: repository, projectID: session.projectID,
            owner: SpriteTestSupport.owner,
            adapter: GameUnknownEditingAdapter(engine: .rpgMakerMV))
        #expect(second.pendingDraft != nil)
        try await second.recoverDraft()
        let recovered = try SpritePNG.decode(try await second.documentBytes(at: path))
        #expect(recovered.color(x: 2, y: 2) == paint)
        #expect(recovered.color(x: 3, y: 3) == original.color(x: 3, y: 3))
    }

    @Test("External save creates a conflict and the sprite edit rebases")
    func conflict() async throws {
        let (repository, sessionA, path, model, _) = try await loadedModel("conflict")
        let original = try SpritePNG.decode(try await sessionA.documentBytes(at: path))
        let sessionB = try await GameEditingSession.open(
            repository: repository, projectID: sessionA.projectID,
            owner: SpriteTestSupport.owner,
            adapter: GameUnknownEditingAdapter(engine: .rpgMakerMV))
        try await sessionB.editDocument(at: path, summary: GameEditCopy("External edit", "外部编辑")) { bytes in
            var image = try SpritePNG.decode(bytes)
            image.setColor(SpriteRGBA(red: 50, green: 60, blue: 70, alpha: 255), x: 20, y: 20)
            return try SpritePNG.encode(image)
        }
        _ = try await sessionB.save()

        model.color = SpriteRGBA(red: 240, green: 0, blue: 0, alpha: 255)
        model.tool = .brush
        model.beginStroke(at: SpritePixelPoint(x: 1, y: 1))
        await model.endStroke()
        #expect(model.issue == nil)

        do {
            _ = try await sessionA.save()
            Issue.record("Save should fail with a session conflict")
        } catch let error as GameProjectError {
            guard case .conflict = error else {
                Issue.record("Expected conflict, got \(error)")
                return
            }
        }
        try await sessionA.reloadForRebase()
        #expect(sessionA.fileConflicts[path] != nil)
        try sessionA.resolveConflict(at: path, .keepMine)
        #expect(sessionA.fileConflicts.isEmpty)
        _ = try await sessionA.save()
        await model.refreshFromSession()

        let final = try SpritePNG.decode(try await sessionA.documentBytes(at: path))
        #expect(final.color(x: 1, y: 1) == SpriteRGBA(red: 240, green: 0, blue: 0, alpha: 255))
        // Keep-mine is an explicit choice: the external pixel is not merged.
        #expect(final.color(x: 20, y: 20) == original.color(x: 20, y: 20))
    }

    @Test("Invalid grids keep the previous layout and report a readable issue")
    func invalidGridKeepsLayout() async throws {
        let (_, _, _, model, _) = try await loadedModel("invalid")
        let before = model.layout
        model.applyCustomGrid(columns: 5, rows: 8)
        #expect(model.layout == before)
        #expect(model.issue != nil)
        model.clearIssue()
    }

    @Test("Animation advances within one character row and wraps")
    func animation() async throws {
        let (_, _, _, model, _) = try await loadedModel("animation")
        model.selectFrame(0)
        #expect(model.animationFrameIndices == [0, 1, 2])
        model.startPlayback()
        #expect(model.isPlaying)
        #expect(model.highlightedFrameIndex == 0)
        model.advancePlayback()
        #expect(model.playbackStep == 1)
        model.advancePlayback()
        model.advancePlayback()
        #expect(model.playbackStep == 0)
        model.selectFrame(13)
        #expect(model.animationFrameIndices == [12, 13, 14])
        model.stopPlayback()
        #expect(!model.isPlaying)
    }

    @Test("Whole-sheet rotate keeps a covering grid and exact pixels")
    func rotate() async throws {
        let (_, session, path, model, _) = try await loadedModel("rotate")
        let original = try SpritePNG.decode(try await session.documentBytes(at: path))
        let red = try #require(original.color(x: 0, y: 0))
        await model.rotateClockwise()
        #expect(model.issue == nil)
        #expect(model.image?.width == 32)
        #expect(model.image?.height == 48)
        #expect(model.layout?.columns == 8)
        #expect(model.layout?.rows == 12)
        #expect(model.image?.color(x: 31, y: 0) == red)
        let savedBytes = try await session.documentBytes(at: path)
        let saved = try SpritePNG.decode(savedBytes)
        #expect(saved.color(x: 31, y: 0) == red)
        try await session.undo()
        await model.refreshFromSession()
        #expect(model.image?.width == 48)
        #expect(model.image?.height == 32)
    }
}
