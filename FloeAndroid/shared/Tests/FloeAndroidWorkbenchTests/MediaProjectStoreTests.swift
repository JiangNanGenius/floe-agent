import XCTest
import Foundation
@testable import FloeAndroidWorkbench

/// G09-R1 sanity for the ported original media project store. These are the
/// unchanged b192 semantics, run on the host against a temporary directory.
final class MediaProjectStoreTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        super.tearDown()
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-workbench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url)
        return url
    }

    private func project() -> MediaProject {
        var layer = ImageLayer(kind: .text, name: "Title")
        layer.text = ImageTextContent(text: "Hello")
        return MediaProject(
            kind: .image, name: "Poster",
            canvas: MediaCanvas(width: 1080, height: 1350),
            imageLayers: [layer],
            ownerKind: "standalone")
    }

    func testSaveLoadRevisionAndUndoRedoSurviveReopen() async throws {
        let directory = try makeDirectory()
        let store = MediaProjectStore(directory: directory)
        var value = project()
        value.revision = 1
        _ = try await store.save(value, expectedRevision: nil)

        guard var reopened = try await store.loadProject(id: value.id) else {
            return XCTFail("project missing after save")
        }
        XCTAssertEqual(reopened.revision, 1)
        XCTAssertEqual(reopened.imageLayers.count, 1)

        try MediaTransactions.apply(.setCanvas(width: 1200, height: 1600, frameRate: nil), to: &reopened)
        _ = try await store.save(reopened, expectedRevision: 1)
        guard var second = try await store.loadProject(id: value.id) else {
            return XCTFail("project missing after edit")
        }
        XCTAssertEqual(second.revision, 2)
        XCTAssertTrue(MediaTransactions.canUndo(second))

        XCTAssertTrue(MediaTransactions.undo(&second))
        _ = try await store.save(second, expectedRevision: 2)
        guard let undone = try await store.loadProject(id: value.id) else {
            return XCTFail("project missing after undo")
        }
        XCTAssertEqual(undone.revision, 3)
        XCTAssertTrue(MediaTransactions.canRedo(undone))
    }

    func testEqualRevisionContentConflictIsRefused() async throws {
        let directory = try makeDirectory()
        let store = MediaProjectStore(directory: directory)
        var value = project()
        value.revision = 1
        _ = try await store.save(value, expectedRevision: nil)

        var changed = value
        changed.name = "Different"
        do {
            _ = try await store.save(changed, expectedRevision: 1)
            XCTFail("equal-revision content change must be refused")
        } catch {
            // The original durable document must be unchanged.
            let reopened = try await store.loadProject(id: value.id)
            XCTAssertEqual(reopened?.name, "Poster")
        }
    }
}
