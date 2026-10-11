// FloeAppTests — ordinary (workspace-less) Canvas native CAD creation.
//
// The production bug this test locks down: creating a CAD model from a
// default Canvas failed because the node preview was rasterized from a
// DRAWING page, and a brand-new package has none. The preview now comes from
// the VIEWPORT (bodies + assembly instances), independent of drawings, with
// an explicit placeholder fallback — and the editable package still commits.
//
// The test drives the exact production entry point
// (`CADCanvasActionBridge.newCADDocumentInCanvas`) against a default canvas
// in the app container (no file workspace, no chat task), then verifies the
// node binding, the on-device package (still editable, ZERO drawing pages),
// and the rendered asset bytes.
//
// SPDX-License-Identifier: MPL-2.0

#if canImport(SwiftUI) && canImport(UIKit)
import XCTest
import FloeCAD
@testable import FloeApp
import FloePersistence
import FloeCore

@MainActor
final class NativeCADCanvasCreationTests: XCTestCase {

    private var canvasID: UUID!

    override func setUp() async throws {
        canvasID = UUID()
        try WorkspaceCanvasRegistry.createIfNeeded(canvasID: canvasID,
                                                   name: "Ordinary Canvas",
                                                   workspaceID: nil)
    }

    override func tearDown() async throws {
        if let canvasID {
            try? WorkspaceCanvasRegistry.delete(canvasID: canvasID)
            CanvasCADStorage.removePackages(canvasID: canvasID)
        }
    }

    func testOrdinaryCanvasCreatesBlankCADNodeWithoutFileWorkspaceOrDrawingPage() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let assetStore = CreativeAssetStore(database: database)

        let project = try WorkspaceCanvasRegistry.project(canvasID: canvasID)
        let documentID = try XCTUnwrap(project.documents.first?.id,
                                       "a default canvas carries at least one document")

        let result = await CADCanvasActionBridge.newCADDocumentInCanvas(
            canvasID: canvasID,
            documentID: documentID,
            position: CanvasPoint(x: 100, y: 100),
            assetStore: assetStore)
        let nodeID = try XCTUnwrap(result.nodeID,
                                   "blank CAD creation failed: \(result.message)")

        // The node binds a canvas-owned package key.
        let updated = try WorkspaceCanvasRegistry.project(canvasID: canvasID)
        let node = try XCTUnwrap(updated.documents.flatMap(\.nodes).first { $0.id == nodeID })
        XCTAssertTrue(CADCanvasNodePlanner.isNativeCADNode(node))
        let key = try XCTUnwrap(node.metadata[CADCanvasNodePlanner.MetadataKeys.sourcePath])
        XCTAssertTrue(CanvasCADStorage.isCanvasOwnedKey(key),
                      "the node must bind the app-owned canvas storage, got \(key)")
        let packageURL = try XCTUnwrap(CADCanvasActionBridge.packageURL(forSourceKey: key))

        // The rendered asset is real PNG bytes (viewport render or the
        // explicit placeholder — never a missing file).
        let renderPath = try XCTUnwrap(node.asset?.localRelativePath)
        guard renderPath.hasPrefix("Materials/") else {
            return XCTFail("the node asset must live in the material library, got \(renderPath)")
        }
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                  in: .userDomainMask,
                                                  appropriateFor: nil, create: false)
        let renderURL = support.appendingPathComponent("FloeAgent")
            .appendingPathComponent(renderPath)
        let renderData = try Data(contentsOf: renderURL)
        XCTAssertFalse(renderData.isEmpty, "the canvas node must carry a rendered preview")
        XCTAssertEqual(renderData.prefix(2), Data([0x89, 0x50]),
                       "the preview must be PNG bytes")
        XCTAssertNotNil(node.asset?.contentHash)
        XCTAssertEqual(node.metadata["preview"], "viewport",
                       "on a Metal-capable device the preview is the real viewport render")

        // The EDITABLE package exists and — the regression — has ZERO drawing
        // pages: creation must not require a sheet.
        XCTAssertTrue(FileManager.default.fileExists(atPath: packageURL.path))
        let document = try await FloeCADDocument.open(at: packageURL)
        defer { document.close() }
        XCTAssertEqual(document.summary().drawingPageCount, 0,
                       "a blank CAD document has no drawing page")
        // It is editable through the typed vocabulary.
        let sketch = document.executeJSON(
            Data(#"{"op":"sketch.create","args":{"name":"First"}}"#.utf8))
        XCTAssertTrue(sketch.isOK, sketch.message ?? "sketch.create failed")
        let save = await document.save()
        XCTAssertTrue(save.succeeded, save.error ?? "")

        // Retrying the same creation must NOT create a second orphan: the
        // pending record was cleared on success and a second node refuses
        // only if a binding already exists — here we assert the first bind
        // left exactly ONE node for the package.
        let nodes = updated.documents.flatMap(\.nodes).filter {
            CanvasCADStorage.isCanvasOwnedKey(
                $0.metadata[CADCanvasNodePlanner.MetadataKeys.sourcePath])
        }
        XCTAssertEqual(nodes.count, 1)
    }

    /// The node display title follows the UI language while the bound
    /// package's file-name identity stays the stable English stem — a device
    /// language switch must never break the `canvas-cad:` binding.
    func testNodeTitleIsLocalizedDefaultButPackageIdentityStaysStable() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let assetStore = CreativeAssetStore(database: database)

        let project = try WorkspaceCanvasRegistry.project(canvasID: canvasID)
        let documentID = try XCTUnwrap(project.documents.first?.id)

        let result = await CADCanvasActionBridge.newCADDocumentInCanvas(
            canvasID: canvasID,
            documentID: documentID,
            position: CanvasPoint(x: 200, y: 200),
            assetStore: assetStore)
        let nodeID = try XCTUnwrap(result.nodeID, result.message)
        let updated = try WorkspaceCanvasRegistry.project(canvasID: canvasID)
        let node = try XCTUnwrap(updated.documents.flatMap(\.nodes).first { $0.id == nodeID })

        XCTAssertEqual(node.text, CADCanvasNodePlanner.defaultDisplayName())
        // The title is one of the catalog defaults (host language may differ
        // from the test's preferred language in the XCTest environment).
        XCTAssertTrue(["CAD Model", "CAD 模型"].contains(node.text),
                      "node title must be a localized default, got \(node.text)")

        let key = try XCTUnwrap(node.metadata[CADCanvasNodePlanner.MetadataKeys.sourcePath])
        let packageURL = try XCTUnwrap(CADCanvasActionBridge.packageURL(forSourceKey: key))
        // The on-disk identity keeps the stable English stem regardless of
        // the localized display title.
        XCTAssertTrue(packageURL.lastPathComponent.hasPrefix("CAD Model"),
                      "package file name must keep the stable stem, got \(packageURL.lastPathComponent)")
        XCTAssertTrue(packageURL.lastPathComponent.hasSuffix(".floecad"))
    }

    /// The preview pipeline must refuse an uncommitted/conflicted draft BEFORE
    /// any canvas publish (review 2026-10-10): a failed save throws, keeps the
    /// draft alive, and produces no bytes for a node.
    func testExportPreviewRefusesWhenSaveFails() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-cad-save-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ReadOnly.floecad")
        let document = try await FloeCADDocument.create(at: url, name: "ReadOnly")
        defer { document.close() }

        // Real geometry so a preview would otherwise be produced.
        let sketch = document.executeJSON(
            Data(#"{"op":"sketch.create","args":{"name":"S"}}"#.utf8))
        XCTAssertTrue(sketch.isOK, sketch.message ?? "")
        let sketchID = try XCTUnwrap(
            ((try? JSONSerialization.jsonObject(with: sketch.payload)) as? [String: Any])?["sketchID"] as? String)
        _ = document.executeJSON(Data("""
        {"op":"sketch.addEntities","args":{"sketchID":"\(sketchID)",
         "entities":[{"kind":"rect","min":[0,0],"max":[10,10]}]}}
        """.utf8))
        _ = document.executeJSON(Data("""
        {"op":"feature.extrude","args":{"sketchID":"\(sketchID)","seedPoint":[5,5],"distance":10}}
        """.utf8))
        XCTAssertTrue(document.hasUnsavedChanges)

        // Force the next save to fail: the package and its parent are
        // read-only, so neither an in-package write nor a swap can commit.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: url.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }

        do {
            let exported = try await CADCanvasActionBridge.exportPNG(document: document, url: url)
            XCTFail("a failed save must refuse the preview (got \(exported.data.count) bytes)")
        } catch let error as CADDocumentError {
            XCTAssertEqual(error.code, "save_failed",
                           "the refusal must be an explicit save failure, got \(error.code)")
        }
        // The draft is preserved for retry, never discarded.
        XCTAssertTrue(document.hasUnsavedChanges)
    }

    // MARK: - Legacy 3D scene migration (first edit)

    private func legacyScene() -> CanvasScene3D {
        CanvasScene3D(objects: [
            CanvasSceneObject(name: "Cube", kind: .box,
                              position: .init(x: 0, y: 0.6, z: 0),
                              scale: .init(x: 2, y: 1, z: 1.5)),
            CanvasSceneObject(name: "Ground", kind: .plane,
                              position: .init(x: 0, y: 0.02, z: 0),
                              rotation: .init(x: 0, y: 30, z: 0),
                              scale: .init(x: 3, y: 1, z: 3),
                              colorHex: "#22AA66", metallic: true, isHidden: true)
        ])
    }

    /// Inserts a legacy node (plus one connected text node) into the canvas
    /// file, exactly as a pre-unification canvas carries it.
    @discardableResult
    private func insertLegacyNode(_ scene: CanvasScene3D) throws -> UUID {
        let url = try WorkspaceCanvasRegistry.projectURL(canvasID: canvasID, createDirectory: false)
        let project = try WorkspaceCanvasRegistry.project(canvasID: canvasID)
        var updated = project
        let sceneNode = CanvasNode(
            kind: .scene3D, text: "Old Scene",
            position: .init(x: 120, y: 160), size: .init(width: 420, height: 300),
            scene3D: scene)
        let sibling = CanvasNode(kind: .text, text: "Note",
                                 position: .init(x: 600, y: 160),
                                 size: .init(width: 200, height: 120))
        updated.documents[0].nodes.append(contentsOf: [sceneNode, sibling])
        updated.documents[0].connections.append(CanvasConnection(
            sourceNodeID: sibling.id, destinationNodeID: sceneNode.id,
            kind: .generatedFrom))
        updated.revision += 1
        try CanvasProjectFileWriter.shared.compareAndSwap(
            updated, at: url, expectedRevision: project.revision)
        return sceneNode.id
    }

    private func documentID() throws -> UUID {
        let project = try WorkspaceCanvasRegistry.project(canvasID: canvasID)
        return try XCTUnwrap(project.documents.first?.id)
    }

    private func node(_ id: UUID, in project: CanvasProject) -> CanvasNode? {
        project.documents.flatMap(\.nodes).first { $0.id == id }
    }

    private func marker(of node: CanvasNode) throws -> LegacySceneMigrationMarker {
        let raw = try XCTUnwrap(
            node.metadata[CADCanvasNodePlanner.MetadataKeys.legacyMigration])
        return try JSONDecoder().decode(LegacySceneMigrationMarker.self, from: Data(raw.utf8))
    }

    func testLegacySceneMigratesOnFirstEditPreservingNodeIdentityAndEdges() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let assetStore = CreativeAssetStore(database: database)

        let scene = legacyScene()
        let sceneNodeID = try insertLegacyNode(scene)
        let docID = try documentID()
        // The persisted scene is the canonical identity (the canvas file
        // stores ISO-8601 dates, so the on-disk readback is what the
        // migration digest and the backup path are computed from).
        let storedScene = try XCTUnwrap(
            node(sceneNodeID, in: try WorkspaceCanvasRegistry.project(canvasID: canvasID))?.scene3D)
        let digestBefore = LegacySceneMigration.evaluate(storedScene).canonicalDigest

        let outcome = await LegacySceneMigrationService.migrateOnFirstEdit(
            canvasID: canvasID, documentID: docID, nodeID: sceneNodeID,
            assetStore: assetStore)
        guard case .migrated(let success) = outcome else {
            return XCTFail("migration failed: \(outcome)")
        }
        XCTAssertEqual(success.objectCount, 2)

        let migrated = try WorkspaceCanvasRegistry.project(canvasID: canvasID)
        let node = try XCTUnwrap(node(sceneNodeID, in: migrated))
        // Same node identity: name, position, size preserved; kind flipped to
        // the native file node; the embedded scene remains the recoverable
        // original; edges untouched.
        XCTAssertEqual(node.kind, .file)
        XCTAssertEqual(node.text, "Old Scene")
        XCTAssertEqual(node.position, CanvasPoint(x: 120, y: 160))
        XCTAssertEqual(node.size, CanvasSize(width: 420, height: 300))
        XCTAssertEqual(node.rotation, 0)
        XCTAssertNotNil(node.scene3D, "the recoverable original stays embedded")
        XCTAssertTrue(CADCanvasNodePlanner.isNativeCADNode(node))
        XCTAssertEqual(migrated.documents[0].connections.count, 1)
        XCTAssertEqual(migrated.documents[0].connections[0].kind, .generatedFrom)
        // The marker records the exact source digest.
        let marker = try marker(of: node)
        XCTAssertEqual(marker.sceneDigest, digestBefore)
        XCTAssertEqual(marker.objectCount, 2)
        // The node now routes to the native workbench.
        guard case .migrated = node.legacySceneMigrationState else {
            return XCTFail("expected migrated node state")
        }

        // The package exists, opens with two bodies and carries the
        // presentation; exactly ONE package file exists for this node.
        let url = try XCTUnwrap(
            CADCanvasActionBridge.packageURL(forSourceKey: success.sourceKey))
        XCTAssertEqual(CanvasCADStorage.packageURLs(canvasID: canvasID).count, 1)
        let document = try await FloeCADDocument.open(at: url)
        defer { document.close() }
        XCTAssertEqual(document.summary().bodyCount, 2)
        XCTAssertNotNil(document.sceneSettings)

        // The recoverable original was written before the package and kept.
        let backup = try XCTUnwrap(LegacySceneMigrationService.backupFileURL(
            canvasID: canvasID, nodeID: sceneNodeID, digest: digestBefore))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path),
                      "the original scene backup must be retained")
        // The pending record is cleared on success.
        XCTAssertNil(LegacySceneMigrationService.pendingRecord(
            canvasID: canvasID, nodeID: sceneNodeID))
    }

    func testSecondMigrationReturnsAlreadyMigratedWithoutSecondPackage() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let assetStore = CreativeAssetStore(database: database)
        let sceneNodeID = try insertLegacyNode(legacyScene())
        let docID = try documentID()

        let first = await LegacySceneMigrationService.migrateOnFirstEdit(
            canvasID: canvasID, documentID: docID, nodeID: sceneNodeID,
            assetStore: assetStore)
        guard case .migrated = first else { return XCTFail("first migration: \(first)") }
        let second = await LegacySceneMigrationService.migrateOnFirstEdit(
            canvasID: canvasID, documentID: docID, nodeID: sceneNodeID,
            assetStore: assetStore)
        guard case .alreadyMigrated = second else {
            return XCTFail("expected alreadyMigrated, got \(second)")
        }
        XCTAssertEqual(CanvasCADStorage.packageURLs(canvasID: canvasID).count, 1,
                       "reopen must never create a second package")
    }

    func testUnsupportedSceneLeavesNodeAndPreviewIntact() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let assetStore = CreativeAssetStore(database: database)
        var scene = legacyScene()
        scene.objects[0].scale = .init(x: 0, y: 1, z: 1) // zero scale: unrepresentable
        let sceneNodeID = try insertLegacyNode(scene)
        let docID = try documentID()

        let outcome = await LegacySceneMigrationService.migrateOnFirstEdit(
            canvasID: canvasID, documentID: docID, nodeID: sceneNodeID,
            assetStore: assetStore)
        guard case .unsupported(let reasons) = outcome else {
            return XCTFail("expected unsupported, got \(outcome)")
        }
        XCTAssertFalse(reasons.isEmpty)

        // NOTHING changed: still a legacy scene node, no binding, no marker,
        // no package, no pending record, no backup.
        let project = try WorkspaceCanvasRegistry.project(canvasID: canvasID)
        let node = try XCTUnwrap(node(sceneNodeID, in: project))
        XCTAssertEqual(node.kind, .scene3D)
        XCTAssertNil(node.metadata[CADCanvasNodePlanner.MetadataKeys.sourcePath])
        XCTAssertNil(node.metadata[CADCanvasNodePlanner.MetadataKeys.legacyMigration])
        XCTAssertTrue(CanvasCADStorage.packageURLs(canvasID: canvasID).isEmpty)
        XCTAssertNil(LegacySceneMigrationService.pendingRecord(
            canvasID: canvasID, nodeID: sceneNodeID))
        let backup = LegacySceneMigrationService.backupFileURL(
            canvasID: canvasID, nodeID: sceneNodeID,
            digest: LegacySceneMigration.canonicalDigest(of: scene))
        if let backup {
            XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        }
        guard case .legacyUnchanged = node.legacySceneMigrationState else {
            return XCTFail("the node must stay a legacy scene")
        }
    }

    func testConflictAfterEmbeddedSceneEditIsSurfaced() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let assetStore = CreativeAssetStore(database: database)
        let sceneNodeID = try insertLegacyNode(legacyScene())
        let docID = try documentID()
        let first = await LegacySceneMigrationService.migrateOnFirstEdit(
            canvasID: canvasID, documentID: docID, nodeID: sceneNodeID,
            assetStore: assetStore)
        guard case .migrated = first else { return XCTFail("migration: \(first)") }

        // Simulate a stale writer editing the embedded scene AFTER migration.
        let url = try WorkspaceCanvasRegistry.projectURL(canvasID: canvasID, createDirectory: false)
        let project = try WorkspaceCanvasRegistry.project(canvasID: canvasID)
        var edited = project
        let index = try XCTUnwrap(edited.documents[0].nodes.firstIndex { $0.id == sceneNodeID })
        edited.documents[0].nodes[index].scene3D?.objects[0].name = "Edited after migration"
        edited.revision += 1
        try CanvasProjectFileWriter.shared.compareAndSwap(
            edited, at: url, expectedRevision: project.revision)

        let second = await LegacySceneMigrationService.migrateOnFirstEdit(
            canvasID: canvasID, documentID: docID, nodeID: sceneNodeID,
            assetStore: assetStore)
        guard case .conflict(let embedded, let markerDigest) = second else {
            return XCTFail("expected conflict, got \(second)")
        }
        XCTAssertNotEqual(embedded, markerDigest)
        XCTAssertEqual(CanvasCADStorage.packageURLs(canvasID: canvasID).count, 1)
    }

    func testCrashRecoveryReusesThePendingPackage() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let assetStore = CreativeAssetStore(database: database)
        let scene = legacyScene()
        let sceneNodeID = try insertLegacyNode(scene)
        let docID = try documentID()

        // Leave the exact state a crash between package save and canvas
        // commit produces: pending record + imported package, no node marker.
        let digest = LegacySceneMigration.evaluate(scene).canonicalDigest
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        let sourceJSON = try encoder.encode(scene)
        let packageURL = try CanvasCADStorage.uniquePackageURL(
            canvasID: canvasID, baseName: "Old Scene")
        let document = try await FloeCADDocument.create(
            at: packageURL, name: "Old Scene")
        _ = try document.importLegacyScene(LegacySceneMigrationService.cadScene(
            from: scene, digest: digest, sourceJSON: sourceJSON))
        let save = await document.save()
        XCTAssertTrue(save.succeeded, save.error ?? "")
        document.close()
        var pending = LegacySceneMigrationService.loadPending(canvasID: canvasID)
        pending[sceneNodeID.uuidString] = LegacySceneMigrationService.PendingRecord(
            fileName: packageURL.lastPathComponent, digest: digest, createdAt: Date())
        LegacySceneMigrationService.storePending(pending, canvasID: canvasID)

        let outcome = await LegacySceneMigrationService.migrateOnFirstEdit(
            canvasID: canvasID, documentID: docID, nodeID: sceneNodeID,
            assetStore: assetStore)
        guard case .migrated(let success) = outcome else {
            return XCTFail("recovery failed: \(outcome)")
        }
        // Reused the SAME package — no second orphan file.
        let urls = CanvasCADStorage.packageURLs(canvasID: canvasID)
        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(urls.first?.lastPathComponent, packageURL.lastPathComponent)
        let node = try XCTUnwrap(node(sceneNodeID,
            in: try WorkspaceCanvasRegistry.project(canvasID: canvasID)))
        XCTAssertEqual(node.metadata[CADCanvasNodePlanner.MetadataKeys.sourcePath],
                       success.sourceKey)
        let document2 = try await FloeCADDocument.open(at: packageURL)
        defer { document2.close() }
        XCTAssertEqual(document2.summary().bodyCount, 2,
                       "the recovered package keeps exactly one set of bodies")
    }

    /// Legacy-reader compatibility: the embedded scene survives migration and
    /// the migration state classifier routes a migrated node to the native
    /// workbench while a plain legacy node stays readable.
    func testLegacyReaderAndMigrationRoutingStayCompatible() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let assetStore = CreativeAssetStore(database: database)
        let scene = legacyScene()
        let sceneNodeID = try insertLegacyNode(scene)
        let docID = try documentID()

        let before = try XCTUnwrap(node(sceneNodeID,
            in: try WorkspaceCanvasRegistry.project(canvasID: canvasID)))
        let sceneBefore = try XCTUnwrap(before.scene3D)
        guard case .legacyUnchanged(let readable) = before.legacySceneMigrationState else {
            return XCTFail("unmigrated node must stay legacy-readable")
        }
        XCTAssertEqual(readable.objects.count, 2)

        let outcome = await LegacySceneMigrationService.migrateOnFirstEdit(
            canvasID: canvasID, documentID: docID, nodeID: sceneNodeID,
            assetStore: assetStore)
        guard case .migrated = outcome else { return XCTFail("migration: \(outcome)") }
        let after = try XCTUnwrap(node(sceneNodeID,
            in: try WorkspaceCanvasRegistry.project(canvasID: canvasID)))
        let embedded = try XCTUnwrap(after.scene3D)
        XCTAssertEqual(embedded.objects.count, 2, "the original remains readable")
        XCTAssertEqual(LegacySceneMigration.canonicalDigest(of: embedded),
                       LegacySceneMigration.canonicalDigest(of: sceneBefore))
    }

    /// A migration preview must be a REAL viewport render. The bridge's
    /// explicit empty placeholder is acceptable for a blank new document but
    /// must never be committed as the migrated scene's preview; the service
    /// refuses it, leaving the legacy node/backup intact and the reserved
    /// package reusable.
    func testMigrationPreviewGateRefusesPlaceholders() throws {
        let placeholder = CADCanvasActionBridge.ExportedRender(
            data: Data([0x89, 0x50, 0x4E, 0x47]), hash: "placeholder",
            revision: 1, packageSHA256: "sha", isPlaceholder: true)
        XCTAssertNil(LegacySceneMigrationService.migrationRender(from: placeholder),
                     "a placeholder must never be committed as a migrated preview")
        let real = CADCanvasActionBridge.ExportedRender(
            data: Data([0x89, 0x50, 0x4E, 0x47]), hash: "render",
            revision: 1, packageSHA256: "sha", isPlaceholder: false)
        XCTAssertNotNil(LegacySceneMigrationService.migrationRender(from: real))
    }

    /// The visual approximations the service returns to T6 must match the
    /// list persisted in the package provenance (one source of truth for the
    /// disclosure; drift would silently under-report the render difference).
    func testMigrationDisclosuresMatchThePersistedProvenance() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let assetStore = CreativeAssetStore(database: database)
        let sceneNodeID = try insertLegacyNode(legacyScene())
        let docID = try documentID()

        let outcome = await LegacySceneMigrationService.migrateOnFirstEdit(
            canvasID: canvasID, documentID: docID, nodeID: sceneNodeID,
            assetStore: assetStore)
        guard case .migrated(let success) = outcome else {
            return XCTFail("migration failed: \(outcome)")
        }
        XCTAssertEqual(success.visualApproximations,
                       [.lightingIntensityNormalized, .planarGroundShadow])

        let url = try XCTUnwrap(
            CADCanvasActionBridge.packageURL(forSourceKey: success.sourceKey))
        let document = try await FloeCADDocument.open(at: url)
        defer { document.close() }
        XCTAssertEqual(document.sceneSettings?.legacy?.visualApproximations ?? [],
                       success.visualApproximations,
                       "the service and the persisted provenance must agree")

        let node = try XCTUnwrap(node(sceneNodeID,
            in: try WorkspaceCanvasRegistry.project(canvasID: canvasID)))
        XCTAssertEqual(node.metadata["preview"], "viewport",
                       "a successful migration only ever commits a real render")
    }
    /// Rapid duplicate create requests for the same canvas document must
    /// share ONE package and ONE committed node: the bridge's single-flight
    /// coalesces the second caller instead of letting it observe the same
    /// pending package across its awaits and commit a second node.
    func testConcurrentDuplicateCreationSharesOneNode() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let assetStore = CreativeAssetStore(database: database)
        // Capture the main-actor test properties as locals BEFORE the
        // concurrent child tasks: the `async let` initializers must not send
        // the non-Sendable XCTestCase instance across isolation domains.
        let canvas = try XCTUnwrap(canvasID)
        let documentID = try XCTUnwrap(
            try WorkspaceCanvasRegistry.project(canvasID: canvas).documents.first?.id)

        async let first = CADCanvasActionBridge.newCADDocumentInCanvas(
            canvasID: canvas, documentID: documentID,
            position: CanvasPoint(x: 100, y: 100), assetStore: assetStore)
        async let second = CADCanvasActionBridge.newCADDocumentInCanvas(
            canvasID: canvas, documentID: documentID,
            position: CanvasPoint(x: 320, y: 320), assetStore: assetStore)
        let results = await [first, second]

        let nodeIDs = results.compactMap(\.nodeID)
        XCTAssertFalse(nodeIDs.isEmpty,
                       "at least one of the rapid creates must succeed: \(results.map(\.message))")
        XCTAssertEqual(Set(nodeIDs).count, 1,
                       "rapid duplicate creates must share the exact committed node")
        let updated = try WorkspaceCanvasRegistry.project(canvasID: canvas)
        let nativeNodes = updated.documents.flatMap(\.nodes).filter {
            CADCanvasNodePlanner.isNativeCADNode($0)
        }
        XCTAssertEqual(nativeNodes.count, 1, "exactly one native node may exist")
        XCTAssertEqual(CanvasCADStorage.packageURLs(canvasID: canvas).count, 1,
                       "exactly one package may exist")
    }

    /// Apply must bind the node the workbench presentation was opened for,
    /// even when the same `.floecad` package is referenced by several nodes.
    /// The first-match locator is never used when a presentation owner is
    /// registered.
    func testApplyBindsThePresentedOwnerAmongMultipleReferencingNodes() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let assetStore = CreativeAssetStore(database: database)
        let create = await CADCanvasActionBridge.newCADDocumentInCanvas(
            canvasID: canvasID, documentID: try XCTUnwrap(
                try WorkspaceCanvasRegistry.project(canvasID: canvasID).documents.first?.id),
            position: CanvasPoint(x: 100, y: 100), assetStore: assetStore)
        let firstNodeID = try XCTUnwrap(create.nodeID, create.message)

        // A second node referencing the SAME package (a real, legal canvas
        // state — e.g. an imported copy or a duplicated card).
        let url = try WorkspaceCanvasRegistry.projectURL(canvasID: canvasID, createDirectory: false)
        let project = try WorkspaceCanvasRegistry.project(canvasID: canvasID)
        let sourceNode = try XCTUnwrap(project.documents.flatMap(\.nodes).first {
            $0.id == firstNodeID
        })
        let sourceKey = try XCTUnwrap(
            sourceNode.metadata[CADCanvasNodePlanner.MetadataKeys.sourcePath])
        var duplicate = sourceNode
        duplicate.id = UUID()
        duplicate.text = "Second Reference"
        duplicate.position = CanvasPoint(x: 700, y: 100)
        var updated = project
        updated.documents[0].nodes.append(duplicate)
        // The creation committed an applied marker on the source node; clear
        // it on every reference so "untouched" is provable (any apply writes
        // it back).
        updated.documents[0].nodes = updated.documents[0].nodes.map { node in
            var copy = node
            copy.metadata["appliedRevision"] = nil
            copy.metadata["appliedContentHash"] = nil
            return copy
        }
        updated.revision += 1
        try CanvasProjectFileWriter.shared.compareAndSwap(
            updated, at: url, expectedRevision: project.revision)

        let packageURL = try XCTUnwrap(
            CADCanvasActionBridge.packageURL(forSourceKey: sourceKey))
        let document = try await FloeCADDocument.open(at: packageURL)
        defer { document.close() }

        // The presentation owner is the SECOND node; Apply must update it.
        let actions = CADCanvasActionBridge.actions(
            assetStore: assetStore,
            owner: CADCanvasActionBridge.CADCanvasNodeOwner(
                canvasID: canvasID, documentID: project.documents[0].id,
                nodeID: duplicate.id))
        guard let apply = actions.applyToCanvas else {
            return XCTFail("apply action must be installed")
        }
        let outcome = await apply(document, packageURL)
        XCTAssertEqual(outcome.kind, .success, outcome.message)

        let after = try WorkspaceCanvasRegistry.project(canvasID: canvasID)
        let firstAfter = try XCTUnwrap(after.documents.flatMap(\.nodes).first {
            $0.id == firstNodeID
        })
        let secondAfter = try XCTUnwrap(after.documents.flatMap(\.nodes).first {
            $0.id == duplicate.id
        })
        XCTAssertNil(firstAfter.metadata["appliedRevision"],
                     "the unpresented node must NOT be modified")
        XCTAssertNotNil(secondAfter.metadata["appliedRevision"],
                        "the presented node must receive the apply")
        XCTAssertNotNil(secondAfter.asset?.contentHash)
    }

    /// A frozen owner whose node was deleted must refuse the write rather
    /// than fall back to any other referencing node.
    func testApplyRefusesWhenPresentedOwnerIsGone() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let assetStore = CreativeAssetStore(database: database)
        let create = await CADCanvasActionBridge.newCADDocumentInCanvas(
            canvasID: canvasID, documentID: try XCTUnwrap(
                try WorkspaceCanvasRegistry.project(canvasID: canvasID).documents.first?.id),
            position: CanvasPoint(x: 100, y: 100), assetStore: assetStore)
        let nodeID = try XCTUnwrap(create.nodeID, create.message)
        let project = try WorkspaceCanvasRegistry.project(canvasID: canvasID)
        let node = try XCTUnwrap(project.documents.flatMap(\.nodes).first { $0.id == nodeID })
        let sourceKey = try XCTUnwrap(
            node.metadata[CADCanvasNodePlanner.MetadataKeys.sourcePath])
        let packageURL = try XCTUnwrap(
            CADCanvasActionBridge.packageURL(forSourceKey: sourceKey))
        let document = try await FloeCADDocument.open(at: packageURL)
        defer { document.close() }

        let actions = CADCanvasActionBridge.actions(
            assetStore: assetStore,
            owner: CADCanvasActionBridge.CADCanvasNodeOwner(
                canvasID: canvasID, documentID: project.documents[0].id,
                nodeID: UUID()))
        // Clear the creation-time applied marker so the refusal's "nothing
        // was written" assertion is provable.
        var cleared = project
        cleared.documents[0].nodes = cleared.documents[0].nodes.map { node in
            var copy = node
            copy.metadata["appliedRevision"] = nil
            copy.metadata["appliedContentHash"] = nil
            return copy
        }
        cleared.revision += 1
        try CanvasProjectFileWriter.shared.compareAndSwap(
            cleared,
            at: try WorkspaceCanvasRegistry.projectURL(canvasID: canvasID, createDirectory: false),
            expectedRevision: project.revision)
        guard let apply = actions.applyToCanvas else {
            return XCTFail("apply action must be installed")
        }
        let outcome = await apply(document, packageURL)
        XCTAssertEqual(outcome.kind, .status)
        let after = try WorkspaceCanvasRegistry.project(canvasID: canvasID)
        let unchanged = try XCTUnwrap(after.documents.flatMap(\.nodes).first { $0.id == nodeID })
        XCTAssertNil(unchanged.metadata["appliedRevision"],
                     "no referencing node may be written when the presented owner is gone")
    }

    /// Two action sets for the SAME package but DIFFERENT nodes stay
    /// independent: each apply binds only its own frozen node, and dropping
    /// one action set (the workbench closing) never affects the other. This
    /// is the replacement for the removed global presentation registry.
    func testTwoActionSetsSamePackageKeepIndependentTargets() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let assetStore = CreativeAssetStore(database: database)
        let documentID = try XCTUnwrap(
            try WorkspaceCanvasRegistry.project(canvasID: canvasID).documents.first?.id)
        let create = await CADCanvasActionBridge.newCADDocumentInCanvas(
            canvasID: canvasID, documentID: documentID,
            position: CanvasPoint(x: 100, y: 100), assetStore: assetStore)
        let firstNodeID = try XCTUnwrap(create.nodeID, create.message)
        let project = try WorkspaceCanvasRegistry.project(canvasID: canvasID)
        let sourceNode = try XCTUnwrap(project.documents.flatMap(\.nodes).first {
            $0.id == firstNodeID
        })
        let sourceKey = try XCTUnwrap(
            sourceNode.metadata[CADCanvasNodePlanner.MetadataKeys.sourcePath])
        var second = sourceNode
        second.id = UUID()
        second.text = "Second workbench"
        second.position = CanvasPoint(x: 700, y: 100)
        var updated = project
        updated.documents[0].nodes.append(second)
        // Clear the creation-time applied marker on both workbench targets so
        // each independent write is observable.
        updated.documents[0].nodes = updated.documents[0].nodes.map { node in
            var copy = node
            copy.metadata["appliedRevision"] = nil
            copy.metadata["appliedContentHash"] = nil
            return copy
        }
        updated.revision += 1
        try CanvasProjectFileWriter.shared.compareAndSwap(
            updated,
            at: try WorkspaceCanvasRegistry.projectURL(canvasID: canvasID, createDirectory: false),
            expectedRevision: project.revision)

        let packageURL = try XCTUnwrap(
            CADCanvasActionBridge.packageURL(forSourceKey: sourceKey))
        let document = try await FloeCADDocument.open(at: packageURL)
        defer { document.close() }
        let ownerA = CADCanvasActionBridge.CADCanvasNodeOwner(
            canvasID: canvasID, documentID: documentID, nodeID: firstNodeID)
        let ownerB = CADCanvasActionBridge.CADCanvasNodeOwner(
            canvasID: canvasID, documentID: documentID, nodeID: second.id)

        let actionsA = CADCanvasActionBridge.actions(assetStore: assetStore, owner: ownerA)
        let actionsB = CADCanvasActionBridge.actions(assetStore: assetStore, owner: ownerB)
        guard let applyA = actionsA.applyToCanvas, let applyB = actionsB.applyToCanvas else {
            return XCTFail("both action sets must install apply")
        }

        let outcomeA = await applyA(document, packageURL)
        XCTAssertEqual(outcomeA.kind, .success, outcomeA.message)
        let afterA = try WorkspaceCanvasRegistry.project(canvasID: canvasID)
        let firstAfterA = try XCTUnwrap(afterA.documents.flatMap(\.nodes).first {
            $0.id == firstNodeID
        })
        let secondAfterA = try XCTUnwrap(afterA.documents.flatMap(\.nodes).first {
            $0.id == second.id
        })
        XCTAssertNotNil(firstAfterA.metadata["appliedRevision"])
        XCTAssertNil(secondAfterA.metadata["appliedRevision"],
                     "action set A must never write action set B's node")

        // "Closing" A (dropping it) leaves B fully functional.
        let outcomeB = await applyB(document, packageURL)
        XCTAssertEqual(outcomeB.kind, .success, outcomeB.message)
        let afterB = try WorkspaceCanvasRegistry.project(canvasID: canvasID)
        let firstAfterB = try XCTUnwrap(afterB.documents.flatMap(\.nodes).first {
            $0.id == firstNodeID
        })
        let secondAfterB = try XCTUnwrap(afterB.documents.flatMap(\.nodes).first {
            $0.id == second.id
        })
        XCTAssertNotNil(secondAfterB.metadata["appliedRevision"],
                        "action set B must still apply after A is gone")
        XCTAssertEqual(firstAfterB.metadata["appliedRevision"],
                       firstAfterA.metadata["appliedRevision"],
                       "A's node must not be re-written by B")
    }

    /// The file-preview entry (no frozen owner) must NOT pick the first
    /// matching node when more than one verified reference exists: it refuses
    /// with an actionable status and writes nothing.
    func testFileEntryAmbiguousReferencesWriteNothing() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let assetStore = CreativeAssetStore(database: database)
        let documentID = try XCTUnwrap(
            try WorkspaceCanvasRegistry.project(canvasID: canvasID).documents.first?.id)
        let create = await CADCanvasActionBridge.newCADDocumentInCanvas(
            canvasID: canvasID, documentID: documentID,
            position: CanvasPoint(x: 100, y: 100), assetStore: assetStore)
        let firstNodeID = try XCTUnwrap(create.nodeID, create.message)
        let project = try WorkspaceCanvasRegistry.project(canvasID: canvasID)
        let sourceNode = try XCTUnwrap(project.documents.flatMap(\.nodes).first {
            $0.id == firstNodeID
        })
        let sourceKey = try XCTUnwrap(
            sourceNode.metadata[CADCanvasNodePlanner.MetadataKeys.sourcePath])
        var second = sourceNode
        second.id = UUID()
        second.text = "Duplicate reference"
        var updated = project
        updated.documents[0].nodes.append(second)
        // Clear the creation-time applied marker on every reference so the
        // ambiguous-entry refusal's "no node may be written" check is real.
        updated.documents[0].nodes = updated.documents[0].nodes.map { node in
            var copy = node
            copy.metadata["appliedRevision"] = nil
            copy.metadata["appliedContentHash"] = nil
            return copy
        }
        updated.revision += 1
        try CanvasProjectFileWriter.shared.compareAndSwap(
            updated,
            at: try WorkspaceCanvasRegistry.projectURL(canvasID: canvasID, createDirectory: false),
            expectedRevision: project.revision)

        let packageURL = try XCTUnwrap(
            CADCanvasActionBridge.packageURL(forSourceKey: sourceKey))
        let document = try await FloeCADDocument.open(at: packageURL)
        defer { document.close() }

        // No frozen owner: the file-preview action set.
        let actions = CADCanvasActionBridge.actions(assetStore: assetStore)
        guard let apply = actions.applyToCanvas else {
            return XCTFail("apply action must be installed")
        }
        let outcome = await apply(document, packageURL)
        XCTAssertEqual(outcome.kind, .status, "ambiguous references must refuse")
        let after = try WorkspaceCanvasRegistry.project(canvasID: canvasID)
        for node in after.documents.flatMap(\.nodes) where
            node.metadata[CADCanvasNodePlanner.MetadataKeys.sourcePath] == sourceKey {
            XCTAssertNil(node.metadata["appliedRevision"],
                         "no node may be written for an ambiguous file entry")
        }
    }

    /// A same-file-name node with NO verified `sourcePath` is not a target:
    /// the file entry refuses instead of applying over a foreign node.
    func testFileEntryNameOnlyMatchWritesNothing() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let assetStore = CreativeAssetStore(database: database)
        let documentID = try XCTUnwrap(
            try WorkspaceCanvasRegistry.project(canvasID: canvasID).documents.first?.id)
        let create = await CADCanvasActionBridge.newCADDocumentInCanvas(
            canvasID: canvasID, documentID: documentID,
            position: CanvasPoint(x: 100, y: 100), assetStore: assetStore)
        let nodeID = try XCTUnwrap(create.nodeID, create.message)
        let project = try WorkspaceCanvasRegistry.project(canvasID: canvasID)
        let sourceNode = try XCTUnwrap(project.documents.flatMap(\.nodes).first {
            $0.id == nodeID
        })
        let sourceKey = try XCTUnwrap(
            sourceNode.metadata[CADCanvasNodePlanner.MetadataKeys.sourcePath])
        let packageURL = try XCTUnwrap(
            CADCanvasActionBridge.packageURL(forSourceKey: sourceKey))
        let packageName = packageURL.lastPathComponent

        // A DIFFERENT canvas node merely carries the same file name and no
        // verified source key.
        let foreignNodeID = UUID()
        var foreign = sourceNode
        foreign.id = foreignNodeID
        foreign.text = "Name collision"
        foreign.position = CanvasPoint(x: 800, y: 200)
        foreign.metadata[CADCanvasNodePlanner.MetadataKeys.sourcePath] = "floecad:unrelated"
        foreign.metadata["appliedRevision"] = nil
        foreign.metadata["appliedContentHash"] = nil
        foreign.asset = CanvasAssetReference(
            id: UUID(), contentHash: FloeDigest.sha256Hex(Data("foreign".utf8)),
            localRelativePath: "Materials/\(packageName)",
            mimeType: "image/png", byteCount: 7)
        var updated = project
        updated.documents[0].nodes.append(foreign)
        // Remove the verified node so only the name-only match remains.
        updated.documents[0].nodes.removeAll { $0.id == nodeID }
        updated.revision += 1
        try CanvasProjectFileWriter.shared.compareAndSwap(
            updated,
            at: try WorkspaceCanvasRegistry.projectURL(canvasID: canvasID, createDirectory: false),
            expectedRevision: project.revision)

        let document = try await FloeCADDocument.open(at: packageURL)
        defer { document.close() }
        let actions = CADCanvasActionBridge.actions(assetStore: assetStore)
        guard let apply = actions.applyToCanvas else {
            return XCTFail("apply action must be installed")
        }
        let outcome = await apply(document, packageURL)
        XCTAssertEqual(outcome.kind, .status,
                       "an unverified name-only match must never be written")
        let after = try WorkspaceCanvasRegistry.project(canvasID: canvasID)
        let foreignAfter = try XCTUnwrap(after.documents.flatMap(\.nodes).first {
            $0.id == foreignNodeID
        })
        XCTAssertNil(foreignAfter.metadata["appliedRevision"])
    }

    // MARK: - Actual creation cancel (not a render-failure proxy)

    /// Cancel of a newly created, untouched model removes the exact created
    /// node and its orphan package: the user-cancel path leaves no empty node.
    func testCancelUntouchedNewCreationRemovesNodeAndPackage() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let assetStore = CreativeAssetStore(database: database)
        let documentID = try XCTUnwrap(
            try WorkspaceCanvasRegistry.project(canvasID: canvasID).documents.first?.id)
        let create = await CADCanvasActionBridge.newCADDocumentInCanvas(
            canvasID: canvasID, documentID: documentID,
            position: CanvasPoint(x: 100, y: 100), assetStore: assetStore)
        let nodeID = try XCTUnwrap(create.nodeID, create.message)
        XCTAssertEqual(CanvasCADStorage.packageURLs(canvasID: canvasID).count, 1)

        let outcome = await CADCanvasActionBridge.discardNewCADDocument(
            canvasID: canvasID, documentID: documentID, nodeID: nodeID,
            assetStore: assetStore)
        XCTAssertEqual(outcome.kind, .success, outcome.message)
        let project = try WorkspaceCanvasRegistry.project(canvasID: canvasID)
        XCTAssertNil(project.documents.flatMap(\.nodes).first { $0.id == nodeID },
                     "cancel of an untouched creation must remove the created node")
        XCTAssertTrue(CanvasCADStorage.packageURLs(canvasID: canvasID).isEmpty,
                      "cancel of an untouched creation must remove the orphan package")
        XCTAssertNil(CanvasCADStorage.pendingPackage(canvasID: canvasID, documentID: documentID))
    }

    /// Cancel of a model the user already edited preserves the recoverable
    /// draft: the node and package stay, and nothing is deleted.
    func testCancelEditedNewCreationKeepsRecoverableDraft() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let assetStore = CreativeAssetStore(database: database)
        let documentID = try XCTUnwrap(
            try WorkspaceCanvasRegistry.project(canvasID: canvasID).documents.first?.id)
        let create = await CADCanvasActionBridge.newCADDocumentInCanvas(
            canvasID: canvasID, documentID: documentID,
            position: CanvasPoint(x: 100, y: 100), assetStore: assetStore)
        let nodeID = try XCTUnwrap(create.nodeID, create.message)
        let project = try WorkspaceCanvasRegistry.project(canvasID: canvasID)
        let node = try XCTUnwrap(project.documents.flatMap(\.nodes).first { $0.id == nodeID })
        let sourceKey = try XCTUnwrap(
            node.metadata[CADCanvasNodePlanner.MetadataKeys.sourcePath])
        let packageURL = try XCTUnwrap(
            CADCanvasActionBridge.packageURL(forSourceKey: sourceKey))

        // A REAL edit through the document API changes the stored identity.
        let document = try await FloeCADDocument.open(at: packageURL)
        let payload = CADLegacyScene(
            objects: [CADLegacyScene.Object(
                id: UUID(), name: "Edit", kind: .box,
                positionX: 0, positionY: 1, positionZ: 0,
                rotationX: 0, rotationY: 0, rotationZ: 0,
                scaleX: 1, scaleY: 1, scaleZ: 1,
                colorHex: "#FFFFFF", roughness: 0.5, metallic: false,
                isHidden: false)],
            camera: CADLegacyScene.Camera(
                yawDegrees: 0, pitchDegrees: 0, distance: 4,
                targetX: 0, targetY: 0, targetZ: 0, fieldOfViewDegrees: 45),
            lighting: CADLegacyScene.Lighting(
                keyIntensity: 1, fillIntensity: 0.5, castsShadows: false),
            background: .studio,
            showsGrid: true,
            sourceDigest: "test-edit",
            sourceSceneJSON: Data("{}".utf8))
        _ = try document.importLegacyScene(payload)
        let save = await document.save()
        XCTAssertTrue(save.succeeded, save.error ?? "the test edit must save")
        document.close()

        let outcome = await CADCanvasActionBridge.discardNewCADDocument(
            canvasID: canvasID, documentID: documentID, nodeID: nodeID,
            assetStore: assetStore)
        XCTAssertEqual(outcome.kind, .status, outcome.message)
        let after = try WorkspaceCanvasRegistry.project(canvasID: canvasID)
        XCTAssertNotNil(after.documents.flatMap(\.nodes).first { $0.id == nodeID },
                        "an edited draft must never be silently discarded")
        XCTAssertEqual(CanvasCADStorage.packageURLs(canvasID: canvasID).count, 1)
    }
}
#endif
