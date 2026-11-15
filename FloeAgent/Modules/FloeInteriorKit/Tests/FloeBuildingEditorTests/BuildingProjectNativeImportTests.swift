// SPDX-License-Identifier: MPL-2.0
#if os(iOS)
import XCTest
import simd
@testable import FloeCAD
@testable import FloeBuildingEditor

@MainActor
final class BuildingProjectNativeImportTests: XCTestCase {
    private func makeRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(name + "-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// The App creates a project from the drawing it has open. The project must
    /// own a byte-verified copy, keep the native sketch/undo document intact,
    /// and publish/reopen that same content in one generation.
    func testProjectStartsWithAVerifiedCopyOfTheSavedDrawing() async throws {
        let root = try makeRoot("BuildingProjectImport")
        let sourceDirectory = root.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let sourceURL = sourceDirectory.appendingPathComponent("Plan.floecad", isDirectory: true)
        let source = try await FloeCADDocument.create(at: sourceURL, name: "Plan")
        let sketchID = SketchID(raw: UUID())
        let lineID = UUID()
        source.session.perform(AddSketchCommand(
            sketch: Sketch(id: sketchID, name: "Plan sketch", plane: .offsetGround(y: 0)),
            title: "Plan sketch"))
        source.session.perform(AddSketchEntityCommand(sketchID: sketchID,
            entity: .line(id: lineID, a: SIMD2(0, 0), b: SIMD2(2400, 0))))
        XCTAssertEqual(source.session.document.sketches.first(where: { $0.id == sketchID })?.entities.count, 1)
        let saved = await source.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        let sourceIdentity = await FloeCADDocument.storedIdentity(at: sourceURL)
        let sourceStored = try XCTUnwrap(sourceIdentity)
        let sourceModel = try XCTUnwrap(sourceStored.modelSHA256)
        source.close()

        let projectURL = root.appendingPathComponent("Project", isDirectory: true)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let session = try await BuildingEditorProjectSession.create(at: projectURL, name: "Imported project",
            assetLibraryDirectory: library, importingNativeDocument: sourceURL)
        do {
            var relationship = FileManager.URLRelationship.other
            try FileManager.default.getRelationship(&relationship,
                ofDirectoryAt: projectURL.resolvingSymlinksInPath().standardizedFileURL,
                toItemAt: session.nativeDocument.url.resolvingSymlinksInPath().standardizedFileURL)
            XCTAssertEqual(relationship, .contains, "The imported drawing must belong to the project's directory")
            XCTAssertEqual(session.nativeDocument.session.document.sketches.map(\.id), [sketchID])
            XCTAssertEqual(session.nativeDocument.session.document.sketches.first?.entities.map(\.id), [lineID])
            XCTAssertEqual(session.nativeDocument.savedIdentity.modelSHA256, sourceModel)
            let initial = try XCTUnwrap(session.published)
            XCTAssertEqual(initial.identity.cadModelSHA256, sourceModel)
            XCTAssertFalse(session.hasUnpublishedChanges, "Creation publishes the verified imported drawing")

            let secondLineID = UUID()
            session.nativeDocument.session.perform(AddSketchEntityCommand(sketchID: sketchID,
                entity: .line(id: secondLineID, a: SIMD2(2400, 0), b: SIMD2(2400, 1800))))
            XCTAssertTrue(session.hasUnpublishedChanges)
            try await session.checkpoint()
            let generation = try XCTUnwrap(session.published?.generationID)
            XCTAssertNotEqual(generation, initial.generationID)
            XCTAssertFalse(session.hasUnpublishedChanges)
            try await session.close()
            let reopened = try await BuildingEditorProjectSession.open(at: projectURL, assetLibraryDirectory: library)
            do {
                XCTAssertEqual(reopened.published?.generationID, generation)
                XCTAssertEqual(reopened.nativeDocument.session.document.sketches.map(\.id), [sketchID])
                let sketch = try XCTUnwrap(reopened.nativeDocument.session.document.sketches.first)
                XCTAssertEqual(sketch.entities.map(\.id), [lineID, secondLineID])
                try await reopened.close()
            } catch { try? await reopened.close(discardWorkingCopy: false); throw error }
            // The source package is only read: its committed identity did not move.
            let sourceAfterIdentity = await FloeCADDocument.storedIdentity(at: sourceURL)
            let sourceAfter = try XCTUnwrap(sourceAfterIdentity)
            XCTAssertEqual(sourceAfter.contentSHA256, sourceStored.contentSHA256)
            if testRun?.failureCount == 0 { try? FileManager.default.removeItem(at: root) }
        } catch {
            try? await session.close(discardWorkingCopy: false)
            throw error
        }
    }

    /// An unreadable or unsaved source is refused before a project directory or
    /// generation exists, so a failed import cannot become an empty project.
    func testUnreadableSourceIsRefusedBeforeAProjectExists() async throws {
        let root = try makeRoot("BuildingProjectImportMissing")
        let projectURL = root.appendingPathComponent("Project", isDirectory: true)
        do {
            _ = try await BuildingEditorProjectSession.create(at: projectURL, name: "Missing source",
                assetLibraryDirectory: root.appendingPathComponent("Library", isDirectory: true),
                importingNativeDocument: root.appendingPathComponent("Missing.floecad", isDirectory: true))
            XCTFail("An unreadable source must not create a project")
        } catch BuildingEditorProjectError.importSourceUnavailable {
            XCTAssertFalse(FileManager.default.fileExists(atPath: projectURL.path))
            if testRun?.failureCount == 0 { try? FileManager.default.removeItem(at: root) }
        }
    }
}
#endif
