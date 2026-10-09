// FloeAppTests — production native CAD document creation workflow.
//
// Before this round, `FloeCADDocument.create` was reachable ONLY from the
// DEBUG fixture harness: no production path created a `.floecad` package or
// imported STEP/IGES into a new native document. The file tree's
// "New CAD Document" flow (FileTreeViewModel.createNativeCADDocument) now
// exercises the real creation contract; this test drives the same public
// production APIs end to end — create → open through the shared bridge (the
// FilePreview path) → edit with the typed vocabulary → save → close →
// reopen from the saved bytes → verify. No fixture arguments, no
// manufactured package JSON.
//
// SPDX-License-Identifier: MPL-2.0

#if canImport(SwiftUI) && canImport(UIKit)
import XCTest
import FloeCAD
@testable import FloeApp
import FloeWorkspace

@MainActor
final class NativeCADDocumentCreationTests: XCTestCase {

    private var workspace: URL!

    override func setUp() async throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-cad-create-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for name in ["Bracket.floecad", "Bracket 2.floecad"] {
            let url = workspace.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                await FloeCAD3DBridge.shared.releaseDocument(at: url)
            }
        }
        try? FileManager.default.removeItem(at: workspace)
    }

    /// What the file-tree creation flow runs: guard-resolved path,
    /// `FloeCADDocument.create` (production, non-DEBUG), immediate reopen
    /// through the same bridge the preview uses.
    private func createDocument(named name: String) async throws -> URL {
        let relative = "\(name).floecad"
        let url = try WorkspacePathGuard(rootURL: workspace).resolve(relative)
        _ = try await FloeCADDocument.create(at: url, name: name)
        return url
    }

    func testCreateEditSaveReopenThroughProductionPath() async throws {
        // 1. Create (production path — the same call the file tree makes).
        let url = try await createDocument(named: "Bracket")
        let manifest = url.appendingPathComponent("manifest.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.path),
                      "creation must write a real versioned package")

        // 2. Open through the shared bridge (exactly what FilePreviewView
        //    does), then edit through the typed command vocabulary.
        let document = try await FloeCAD3DBridge.shared.openDocument(at: url)
        let sketch = document.executeJSON(Data(#"{"op":"sketch.create","args":{"name":"Base"}}"#.utf8))
        XCTAssertTrue(sketch.isOK, sketch.message ?? "")
        let sketchID = ((try? JSONSerialization.jsonObject(with: sketch.payload)) as? [String: Any])?["sketchID"] as? String ?? ""
        XCTAssertFalse(sketchID.isEmpty)
        XCTAssertTrue(document.executeJSON(Data("""
        {"op":"sketch.addEntities","args":{"sketchID":"\(sketchID)",
         "entities":[{"kind":"rect","min":[0,0],"max":[80,40]}]}}
        """.utf8)).isOK)
        let extrude = document.executeJSON(Data("""
        {"op":"feature.extrude","args":{"sketchID":"\(sketchID)","seedPoint":[40,20],"distance":10}}
        """.utf8))
        XCTAssertTrue(extrude.isOK, extrude.message ?? "")
        let baseRevision = document.revision

        // 3. Save and release (the preview's close path).
        let save = await document.save()
        XCTAssertTrue(save.succeeded, save.error ?? "")
        XCTAssertGreaterThan(save.revision, baseRevision)
        await FloeCAD3DBridge.shared.releaseDocument(at: url)

        // 4. Reopen from the SAVED bytes and verify the geometry survived.
        //    (Release/save housekeeping may commit further revisions; the
        //    contract under test is that the committed package reopens with
        //    the exact geometry and a verified identity.)
        let reopened = try await FloeCAD3DBridge.shared.openDocument(at: url)
        let summary = reopened.summary()
        XCTAssertEqual(summary.bodyCount, 1)
        XCTAssertEqual(summary.sketchCount, 1)
        XCTAssertGreaterThanOrEqual(summary.revision, save.revision)
        let verified = await FloeCADDocument.storedIdentity(at: url)
        XCTAssertEqual(reopened.contentSHA256, verified?.contentSHA256,
                       "reopen must see the verified committed identity")
        let measure = reopened.measureJSON(["kind": "body",
                                            "bodyID": reopened.snapshotJSONBodyID()])
        XCTAssertTrue(measure.isOK, measure.message ?? "")
        await FloeCAD3DBridge.shared.releaseDocument(at: url)
    }

    /// Creation never overwrites: a second document with the same stem gets
    /// its own package (the view model unique-ifies; the store itself refuses
    /// to replace without `overwrite`).
    func testCreateRefusesToReplaceExistingPackage() async throws {
        let url = try await createDocument(named: "Bracket")
        do {
            _ = try await FloeCADDocument.create(at: url, name: "Bracket")
            XCTFail("create without overwrite must refuse an existing package")
        } catch {
            // expected: the store's `exists` refusal, evidence preserved
        }
        let identity = await FloeCADDocument.storedIdentity(at: url)
        XCTAssertNotNil(identity, "the original package must be untouched")
    }
}

private extension FloeCADDocument {
    /// First body id from the snapshot payload (test helper).
    func snapshotJSONBodyID() -> String {
        guard let object = (try? JSONSerialization.jsonObject(with: snapshotJSON())) as? [String: Any],
              let bodies = object["bodies"] as? [[String: Any]] else { return "" }
        return bodies.first?["id"] as? String ?? ""
    }
}
#endif
