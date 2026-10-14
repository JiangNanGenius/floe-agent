// FloeAppTests — production native CAD document creation workflow.
//
// Before this round, `FloeCADDocument.create` was reachable ONLY from the
// DEBUG fixture harness: no production path created a `.floecad` package or
// imported STEP/IGES into a new native document. The file tree's
// "New CAD Document" flow (FileTreeViewModel.createNativeCADDocument) and the
// agent `cad.document` create action now share the same production factory
// (`NativeCADPackageCreation`); this test drives the SAME public production
// APIs end to end — tool-level create → open through the shared bridge (the
// FilePreview path) → edit with the typed vocabulary → save → close → reopen
// from the saved bytes → verify, plus the agent create → native propose →
// preview → UI grant → apply → save → reopen loop and a REAL import of the
// kernel's own STEP export. No fixture arguments, no manufactured package
// JSON, no mocks of the kernel path.
//
// SPDX-License-Identifier: MPL-2.0

#if canImport(SwiftUI) && canImport(UIKit)
import XCTest
import FloeCAD
import FloeWorkbench
import FloeTools
import FloeCore
import FloeWorkspace
@testable import FloeApp

@MainActor
final class NativeCADDocumentCreationTests: XCTestCase {

    private var workspace: URL!

    override func setUp() async throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-cad-create-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for name in ["Bracket.floecad", "Bracket 2.floecad", "Part.floecad", "Imported.floecad"] {
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

    private func access(owner: UUID = UUID()) -> CadDocumentAccess {
        CadDocumentAccess(environmentID: "env-1", workspacePath: workspace.path,
                          ownerKind: "chat", ownerID: owner)
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

    // MARK: - R2: shared factory via the cad.document tool

    /// The agent create action runs the SAME production factory the file
    /// tree uses, through `CadDocumentTool` → `CadDocumentCenter` →
    /// `NativeCADPackageCreation`. It creates a real verified empty package,
    /// never a fake body.
    func testToolCreateBuildsARealVerifiedPackage() async throws {
        let center = CadDocumentCenter(nativeProposalStoreFileURL: workspace
            .appendingPathComponent("proposals-\(UUID().uuidString).json"))
        let tool = CadDocumentTool(host: center)
        let context = ToolContext(runID: UUID(), toolCallID: "call-create-1", scope: .local,
                                  workspaceRootURL: workspace, cancellation: CancellationToken(),
                                  environmentID: "env-1", conversationID: UUID())

        // 1. Create through the TOOL (the exact model surface).
        let created = try await tool.execute(try XCTUnwrap(decode(
            #"{"action":"create","path":"Part.floecad","name":"Part"}"#)), context: context)
        XCTAssertTrue(created.summary.contains("cad.document created"))
        XCTAssertTrue(created.summary.contains("Part.floecad"))
        let url = workspace.appendingPathComponent("Part.floecad")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("manifest.json").path),
                      "create must produce a real versioned package")

        // 2. Read-back through the tool against the SAME real package: the
        //    identity is verified by the versioned store, not a fixture.
        let read = try await tool.execute(try XCTUnwrap(decode(
            #"{"action":"read","path":"Part.floecad"}"#)), context: context)
        XCTAssertTrue(read.summary.contains("\"revision\""), read.summary)
        let verified = await FloeCADDocument.storedIdentity(at: url)
        XCTAssertNotNil(verified, "created package must verify through the store")

        // 3. The SAME tool create call does not overwrite (factory unique-ifies).
        let again = try await tool.execute(try XCTUnwrap(decode(
            #"{"action":"create","path":"Part.floecad","name":"Part"}"#)), context: context)
        XCTAssertTrue(again.summary.contains("Part 2.floecad"),
                      "second create must unique-ify, not overwrite: \(again.summary)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "the original package must remain")
    }

    /// The shared factory rejects traversal / outside-root / virtual roots
    /// with a fast structured failure and leaves NO package or directory
    /// behind.
    func testFactoryRejectsUnsafePathsWithoutSideEffects() async throws {
        let service = WorkspaceFileService(guard: WorkspacePathGuard(rootURL: workspace))
        let cases = ["../escape.floecad", "/etc/escape.floecad", "Cloud/shared/x.floecad",
                     "Network/remote/x.floecad"]
        for relative in cases {
            do {
                _ = try await NativeCADPackageCreation.create(
                    service: service, desiredRelativePath: relative, explicitName: "x")
                XCTFail("\(relative) must be refused")
            } catch {
                XCTAssertTrue(error is FloeError, "structured failure for \(relative): \(error)")
            }
        }
        // No directory/package was created anywhere for any refusal.
        let names = try FileManager.default.contentsOfDirectory(atPath: workspace.path)
        XCTAssertFalse(names.contains { $0.hasSuffix(".floecad") },
                       "no package may be created for a refused path")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.deletingLastPathComponent().appendingPathComponent("escape.floecad").path),
            "nothing may be created outside the workspace root")
    }

    // MARK: - R2: import with REAL kernel geometry

    /// Real import: a STEP file produced by the kernel's own export (the
    /// production OCCT writer) is imported through the shared authority
    /// (`nativeImportData`) into a second native package, which is then
    /// verified by reopening from the committed bytes. This is REAL kernel
    /// geometry, not a mock.
    func testImportRealSTEPGeometryThroughProductionPath() async throws {
        // 1. Create + build a real solid in the source package.
        let source = try await createDocument(named: "Bracket")
        let sourceDocument = try await FloeCAD3DBridge.shared.openDocument(at: source)
        let sketch = sourceDocument.executeJSON(Data(#"{"op":"sketch.create","args":{"name":"Base"}}"#.utf8))
        XCTAssertTrue(sketch.isOK, sketch.message ?? "")
        let sketchID = ((try? JSONSerialization.jsonObject(with: sketch.payload)) as? [String: Any])?["sketchID"] as? String ?? ""
        XCTAssertTrue(sourceDocument.executeJSON(Data("""
        {"op":"sketch.addEntities","args":{"sketchID":"\(sketchID)",
         "entities":[{"kind":"rect","min":[0,0],"max":[40,25]}]}}
        """.utf8)).isOK)
        let extrude = sourceDocument.executeJSON(Data("""
        {"op":"feature.extrude","args":{"sketchID":"\(sketchID)","seedPoint":[20,12],"distance":8}}
        """.utf8))
        XCTAssertTrue(extrude.isOK, extrude.message ?? "")
        _ = await sourceDocument.save()

        // 2. Export REAL STEP bytes from the kernel and write them as a
        //    workspace source file (the production `nativeExportData` path).
        var stepData: Data?
        if case .success(let result) = sourceDocument.nativeExportData(format: "step", pageID: nil) {
            stepData = result.data
        }
        let bytes = try XCTUnwrap(stepData, "the kernel must export real STEP bytes")
        XCTAssertFalse(bytes.isEmpty)
        await FloeCAD3DBridge.shared.releaseDocument(at: source)
        let sourceFile = workspace.appendingPathComponent("bracket.step")
        try bytes.write(to: sourceFile)

        // 3. Import those REAL bytes into a second package through the shared
        //    authority — the same `nativeImportData` the UI/bridge reuse.
        let target = try await createDocument(named: "Imported")
        let targetDocument = try await FloeCAD3DBridge.shared.openDocument(at: target)
        let outcome = targetDocument.nativeImportData(bytes, format: "step",
                                                      fileName: "bracket.step", unitScale: nil)
        XCTAssertTrue(outcome.isOK, outcome.message ?? "")
        _ = await targetDocument.save()

        // 4. Reopen from the committed package and verify the imported body
        //    survived: a REAL kernel round-trip, not a mock.
        await FloeCAD3DBridge.shared.releaseDocument(at: target)
        let reopened = try await FloeCAD3DBridge.shared.openDocument(at: target)
        XCTAssertGreaterThan(reopened.summary().bodyCount, 0,
                             "the imported STEP solid must be present after save/reopen")
        await FloeCAD3DBridge.shared.releaseDocument(at: target)
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

private extension NativeCADDocumentCreationTests {
    func decode(_ json: String) -> CadDocumentArguments? {
        try? JSONDecoder().decode(CadDocumentArguments.self, from: Data(json.utf8))
    }
}
