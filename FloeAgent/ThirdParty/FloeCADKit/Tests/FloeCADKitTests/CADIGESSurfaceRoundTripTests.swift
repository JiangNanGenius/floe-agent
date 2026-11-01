//
//  CADIGESSurfaceRoundTripTests.swift
//  FloeCADKitTests
//
//  E26 — IGES with open surfaces: exact editable surface bodies that export
//  back to IGES. These tests drive the REAL production document path, not a
//  format-string stub:
//
//    * the fixture is an actual IGES file written by OCCT's own writer from
//      the existing native box primitive in face mode (a legitimate
//      open-surface exchange file, not a fake extension or hand-authored
//      string);
//    * `nativeImportData` must classify every root as a surface, keep the
//      exact handle in `Body.surfaceBRep`, and never set `Body.brep`;
//    * a surface body is a real document body: it can be transformed with the
//      ordinary `TransformBodiesCommand`, its exact geometry survives a
//      save/reopen through the shared B-rep blob, and `nativeExportData` /
//      `nativePartExport` write real IGES bytes;
//    * those bytes independently reopen in a fresh document with the same
//      surface count, exact handles and translated bounds;
//    * STEP (solid-only) refuses the surface with no bytes, and an incomplete
//      IGES selection (surface + mesh-only) returns coverageRequired instead
//      of a misleading partial file; a sentinel destination proves the
//      refusal wrote nothing, and the raw writer names the skipped mesh body;
//    * the closed-solid boundary is refused with real geometry, not string
//      stubs: executor boolean/face edit, the interactive face/blend/shell/
//      delete/replace tools, and a body copy; a solid boolean and face edit
//      still work; surface→solid adoption is exclusive and atomic;
//    * unreadable IGES bytes and an empty document's IGES export fail
//      structurally without mutating the document or writing anything.
//
//  NOT executed by the packet author: this is source-ready test material.
//  Root owns the native object/relink compile and the real test run.
//

import XCTest
import simd
@testable import FloeCAD

#if DEBUG
// `OCCTKernel.debugWriteIGES` / `debugStandaloneFace` are DEBUG-only fixture
// support (the product writer is `writeIGES`), so these round-trip tests exist
// only in a DEBUG test build — the same rule as CADIGESTests' DEBUG section.
@MainActor
final class CADIGESSurfaceRoundTripTests: XCTestCase {

    private var workDir: URL!
    private var document: FloeCADDocument!
    private var documentURL: URL!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeCADIGESSurface-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        documentURL = workDir.appendingPathComponent("surfaces.floecad")
        document = try await FloeCADDocument.create(at: documentURL, name: "Surfaces")
    }

    override func tearDown() async throws {
        document?.close()
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - Real IGES fixtures (OCCT writer over the native primitive)

    /// Face-mode IGES for the native 20 × 30 × 40 mm box: OCCT decomposes the
    /// solid into loose trimmed faces, exactly the surface-only exchange file
    /// common IGES consumers produce. Returns the bytes and the fixture box.
    private func faceModeBoxIGES(width: Double = 20, depth: Double = 30,
                                 height: Double = 40) throws -> Data {
        let box = try XCTUnwrap(OCCTKernel.primitiveShape(
            .box(width: width, depth: depth, height: height), placement: .identity))
        let url = workDir.appendingPathComponent("open-faces-\(UUID().uuidString).igs")
        XCTAssertTrue(OCCTKernel.debugWriteIGES([box], to: url, brepMode: false),
                      "OCCT's IGES writer refused the face-mode box fixture")
        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 0, "the IGES writer produced no bytes")
        return data
    }

    /// One standalone exact face from the native box: a minimal legitimate
    /// open sheet, used to prove the single-surface path independently of the
    /// six-face decomposition.
    private func singleFaceIGES() throws -> Data {
        let box = try XCTUnwrap(OCCTKernel.primitiveShape(
            .box(width: 10, depth: 10, height: 10), placement: .identity))
        let face = try XCTUnwrap(OCCTKernel.debugStandaloneFace(from: box),
                                 "the donor box must yield a standalone face")
        let url = workDir.appendingPathComponent("single-face-\(UUID().uuidString).igs")
        XCTAssertTrue(OCCTKernel.debugWriteIGES([face], to: url, brepMode: true),
                      "OCCT's IGES writer refused the standalone face")
        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 0)
        return data
    }

    private func object(_ outcome: CADCommandOutcome) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: outcome.payload)) as? [String: Any] ?? [:]
    }

    @discardableResult
    private func importIGES(_ data: Data, name: String,
                            into target: FloeCADDocument? = nil) -> CADCommandOutcome {
        (target ?? document).nativeImportData(data, format: "iges",
                                              fileName: name, unitScale: nil)
    }

    private func bodyBounds(_ bodies: [Body]) throws -> (min: SIMD3<Double>, max: SIMD3<Double>) {
        try XCTUnwrap(MeasureKit.boundingBox(bodies: bodies))
    }

    @discardableResult
    private func runJSON(_ json: String) -> CADCommandOutcome {
        document.executeJSON(Data(json.utf8))
    }

    /// A REAL feature-produced closed solid through the ordinary executor:
    /// sketch → rectangle → extrude. Used as the solid operand/destination in
    /// the surface-boundary regressions, so those prove the ordinary path
    /// still works rather than only the refusal.
    private func makeSolidPlate() throws -> Body {
        let created = runJSON(#"{"op":"sketch.create","args":{"name":"Plate"}}"#)
        XCTAssertTrue(created.isOK, created.message ?? "sketch.create failed")
        let sketch = try XCTUnwrap(object(created)["sketchID"] as? String)
        let added = runJSON("""
        {"op":"sketch.addEntities","args":{"sketchID":"\(sketch)","entities":[{"kind":"rect","min":[0,0],"max":[60,40]}]}}
        """)
        XCTAssertTrue(added.isOK, added.message ?? "sketch.addEntities failed")
        let extruded = runJSON("""
        {"op":"feature.extrude","args":{"sketchID":"\(sketch)","seedPoint":[30,20],"distance":10}}
        """)
        XCTAssertTrue(extruded.isOK, extruded.message ?? "feature.extrude failed")
        return try XCTUnwrap(document.session.document.bodies.first { $0.brep != nil },
                             "the solid plate must carry an exact B-rep")
    }

    private func firstPlanarFace(in body: Body) throws -> FaceTopology.PlanarFace {
        for triangle in 0..<body.render.triangleCount {
            if let face = FaceTopology.planarFace(in: body.render, seedTriangle: triangle) {
                return face
            }
        }
        throw NSError(domain: "noPlanarFace", code: 1)
    }

    private func bodyRows(_ target: FloeCADDocument) -> [[String: Any]] {
        let outcome = target.nativeQueryJSON(["scope": "bodies"])
        XCTAssertTrue(outcome.isOK, outcome.message ?? "query bodies failed")
        let payload = (try? JSONSerialization.jsonObject(with: outcome.payload)) as? [String: Any] ?? [:]
        return payload["rows"] as? [[String: Any]] ?? []
    }

    // MARK: - Import truth

    func testFaceModeIGESImportsExactSurfaceBodiesNotRenderOnlyMeshes() throws {
        let data = try faceModeBoxIGES()
        let outcome = importIGES(data, name: "Open")
        XCTAssertTrue(outcome.isOK,
                      "IGES import failed (\(outcome.status)) \(outcome.errorCode ?? ""): "
                        + "\(outcome.message ?? "")")
        let payload = object(outcome)
        XCTAssertEqual(payload["solidsImported"] as? Int, 0,
                       "a face-mode IGES file must not produce a solid")
        let surfaces = try XCTUnwrap(payload["surfacesImported"] as? Int)
        XCTAssertGreaterThanOrEqual(surfaces, 1, "the open faces must be preserved")
        XCTAssertEqual(payload["openSurfaceBodies"] as? Int, surfaces)
        XCTAssertEqual(payload["count"] as? Int, surfaces)

        let rows = try XCTUnwrap(payload["imported"] as? [[String: Any]])
        XCTAssertEqual(rows.count, surfaces)
        for row in rows {
            XCTAssertEqual(row["kind"] as? String, "surface")
            XCTAssertEqual(row["analyticBRep"] as? Bool, false,
                           "a surface must never be reported as an analytic solid")
            XCTAssertEqual(row["openSurfaceBRep"] as? Bool, true)
        }

        let bodies = document.session.document.bodies
        XCTAssertEqual(bodies.count, surfaces)
        for body in bodies {
            XCTAssertNil(body.brep, "an IGES surface must not enter the solid B-rep field")
            let surface = try XCTUnwrap(body.surfaceBRep,
                                        "an IGES surface must keep its exact B-rep")
            XCTAssertFalse(surface.containsSolid,
                           "an open surface handle must not contain a TopAbs_SOLID")
            XCTAssertFalse(body.render.indices.isEmpty, "the exact surface must render")
            let mesh = OCCTKernel.renderMesh(from: surface)
            XCTAssertFalse(mesh.positions.isEmpty)
            XCTAssertFalse(mesh.indices.isEmpty)
        }
        let bounds = try bodyBounds(bodies)
        XCTAssertEqual(bounds.max.x - bounds.min.x, 20, accuracy: 1e-6)
        XCTAssertEqual(bounds.max.y - bounds.min.y, 30, accuracy: 1e-6)
        XCTAssertEqual(bounds.max.z - bounds.min.z, 40, accuracy: 1e-6)

        let note = try XCTUnwrap(payload["note"] as? String)
        XCTAssertTrue(note.contains("not solids"), note)
        XCTAssertTrue(note.contains("exported back to IGES"),
                      "the import note must state the exact re-export capability: \(note)")
    }

    func testSingleFaceIGESKeepsOneExactSurfaceAndRefusesSTEP() throws {
        let data = try singleFaceIGES()
        let outcome = importIGES(data, name: "Sheet")
        XCTAssertTrue(outcome.isOK)
        let payload = object(outcome)
        XCTAssertEqual(payload["solidsImported"] as? Int, 0)
        XCTAssertEqual(payload["surfacesImported"] as? Int, 1)
        XCTAssertEqual(payload["openSurfaceBodies"] as? Int, 1)
        let body = try XCTUnwrap(document.session.document.bodies.first)
        XCTAssertNil(body.brep)
        let surface = try XCTUnwrap(body.surfaceBRep)
        XCTAssertEqual(OCCTKernel.faceInfo(surface).count, 1,
                       "the standalone sheet must keep exactly one exact face")
        XCTAssertEqual(MeasureKit.volume(of: body), 0,
                       "an open sheet must never report a fake closed volume")

        // STEP is the product's closed-solid exchange. A surface must not be
        // silently substituted or exported as a fake solid.
        switch document.nativePartExport(format: "step", pageID: nil) {
        case .success:
            XCTFail("STEP export must not claim an open surface as a solid")
        case .coverageRequired:
            XCTFail("a surface-only STEP selection has no partial route and must refuse")
        case .coverage:
            XCTFail("STEP export is not a receipt-only call here")
        case .failure(let error):
            XCTAssertTrue(["nothing_exportable", "no_analytic_geometry"].contains(error.code),
                          "unexpected STEP refusal: \(error.code) \(error.message)")
        }
    }

    // MARK: - Editable + export + independent reopen

    func testSurfaceBodyTransformsExportsIGESAndReopensWithTranslatedExactGeometry() async throws {
        let data = try faceModeBoxIGES()
        let imported = importIGES(data, name: "Open")
        XCTAssertTrue(imported.isOK)
        let importedSurfaces = try XCTUnwrap(object(imported)["surfacesImported"] as? Int)
        XCTAssertGreaterThanOrEqual(importedSurfaces, 1)

        // Ordinary document edit: move every imported surface by the same
        // delta through the SAME undoable command the editor uses. A
        // render-only mesh body could also be moved; the point here is that
        // the exact surface body remains a first-class body and its exact
        // geometry follows the transform.
        let before = Dictionary(uniqueKeysWithValues:
            document.session.document.bodies.map { ($0.id, $0.transform) })
        let delta = Transform3D(translation: SIMD3<Double>(10, -5, 7),
                                rotation: .init(ix: 0, iy: 0, iz: 0, r: 1),
                                scale: 1)
        let after = before.mapValues { delta.composed(onto: $0) }
        document.session.perform(TransformBodiesCommand(
            title: "Move", before: before, after: after))
        XCTAssertEqual(document.session.document.bodies.first?.transform.translation ?? .zero,
                       SIMD3<Double>(10, -5, 7))

        // Raw writer path: real IGES bytes, not a mesh or a receipt.
        let exported: Data
        switch document.nativeExportData(format: "iges", pageID: nil) {
        case .success(let (bytes, note)):
            exported = bytes
            XCTAssertGreaterThan(bytes.count, 0)
            XCTAssertTrue(note.contains("exact OCCT B-rep IGES"), note)
        case .failure(let error):
            XCTFail("IGES export failed: \(error.code) \(error.message)")
            return
        }

        // The coverage-gated product path returns the same writer over the
        // included exact bodies and a complete receipt.
        switch document.nativePartExport(format: "iges", pageID: nil) {
        case .success(let bytes, let note, let coverage):
            XCTAssertGreaterThan(bytes.count, 0)
            XCTAssertTrue(coverage.complete, "every surface body is exact; receipt must be complete")
            XCTAssertEqual(coverage.includedCount, importedSurfaces)
            XCTAssertTrue(coverage.items.allSatisfy { $0.openSurfaceBRep })
            XCTAssertTrue(note.contains("open surfaces"), note)
        case .coverageRequired(let coverage):
            XCTFail("unexpected IGES coverage confirmation: \(coverage.notes)")
            return
        case .coverage:
            XCTFail("IGES export must write bytes, not just a receipt")
            return
        case .failure(let error):
            XCTFail("IGES part export failed: \(error.code) \(error.message)")
            return
        }

        // Independent reopen: a FRESH document reads the exported bytes
        // through the real IGES reader, not the live session's state.
        let reopenedURL = workDir.appendingPathComponent("reopened.floecad")
        let reopened = try await FloeCADDocument.create(at: reopenedURL, name: "Reopened")
        defer { reopened.close() }
        let reopenedOutcome = importIGES(exported, name: "Returned", into: reopened)
        XCTAssertTrue(reopenedOutcome.isOK,
                      "the exported IGES bytes did not reopen: "
                        + "\(reopenedOutcome.errorCode ?? "") \(reopenedOutcome.message ?? "")")
        let reopenedPayload = object(reopenedOutcome)
        XCTAssertEqual(reopenedPayload["solidsImported"] as? Int, 0,
                       "exported open surfaces must not come back as solids")
        XCTAssertEqual(reopenedPayload["surfacesImported"] as? Int, importedSurfaces,
                       "every surface body must round-trip")
        let reopenedBodies = reopened.session.document.bodies
        XCTAssertEqual(reopenedBodies.count, importedSurfaces)
        for body in reopenedBodies {
            XCTAssertNil(body.brep)
            XCTAssertNotNil(body.surfaceBRep)
            XCTAssertFalse(body.surfaceBRep?.containsSolid ?? true)
        }
        let reopenedBounds = try bodyBounds(reopenedBodies)
        XCTAssertEqual(reopenedBounds.min.x, 10, accuracy: 1e-6)
        XCTAssertEqual(reopenedBounds.min.y, -5, accuracy: 1e-6)
        XCTAssertEqual(reopenedBounds.min.z, 7, accuracy: 1e-6)
        XCTAssertEqual(reopenedBounds.max.x, 30, accuracy: 1e-6)
        XCTAssertEqual(reopenedBounds.max.y, 25, accuracy: 1e-6)
        XCTAssertEqual(reopenedBounds.max.z, 47, accuracy: 1e-6)
    }

    // MARK: - Persistence identity

    func testSurfaceBRepSurvivesSaveAndReopenWithTheSameDocumentIdentity() async throws {
        let data = try singleFaceIGES()
        XCTAssertTrue(importIGES(data, name: "Sheet").isOK)
        let bodyCount = document.session.document.bodies.count
        let saved = await document.save()
        XCTAssertTrue(saved.succeeded, "save failed: \(saved.error ?? "unknown")")
        XCTAssertEqual(saved.contentSHA256, document.contentSHA256)

        document.close()
        document = try await FloeCADDocument.open(at: documentURL)
        XCTAssertEqual(document.contentSHA256, saved.contentSHA256,
                       "a reopened document must keep the exact saved identity")
        XCTAssertEqual(document.session.document.bodies.count, bodyCount)
        let body = try XCTUnwrap(document.session.document.bodies.first)
        XCTAssertNil(body.brep, "the persisted surface must not reload as a solid")
        let surface = try XCTUnwrap(body.surfaceBRep,
                                    "the exact surface B-rep must reload, not degrade to its mesh")
        XCTAssertEqual(OCCTKernel.faceInfo(surface).count, 1)

        // The metadata a caller reads after reopening must tell the same truth
        // as the live document: exact open surface, not an analytic solid, and
        // no applicable closed volume.
        let rows = bodyRows(document)
        XCTAssertEqual(rows.count, bodyCount)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row["openSurfaceBRep"] as? Bool, true)
        XCTAssertEqual(row["analyticBRep"] as? Bool, false)
        XCTAssertEqual(row["volumeApplicable"] as? Bool, false)
        XCTAssertEqual((row["volumeMM3"] as? Double) ?? -1, 0, accuracy: 1e-9)
        XCTAssertGreaterThan(row["triangles"] as? Int ?? 0, 0)
    }

    // MARK: - Undo, incomplete export, errors

    func testSurfaceImportUndoRedoAndIncompleteIGESExportWritesNothing() throws {
        let data = try faceModeBoxIGES()
        let imported = importIGES(data, name: "Open")
        XCTAssertTrue(imported.isOK)
        let count = document.session.document.bodies.count
        XCTAssertGreaterThanOrEqual(count, 1)

        // Each imported root is one ordinary undo step (same granularity as
        // the solid/mesh import paths).
        for expected in (0..<count).reversed() {
            document.session.undo()
            XCTAssertEqual(document.session.document.bodies.count, expected)
        }
        XCTAssertFalse(document.session.undoStack.canUndo)
        for expected in 1...count {
            document.session.redo()
            XCTAssertEqual(document.session.document.bodies.count, expected)
        }

        // Add a mesh-only body (no exact B-rep). A surface + mesh selection is
        // an incomplete IGES receipt: no bytes are returned unless the caller
        // explicitly accepts the loss, and the kernel writes no file at all.
        let mesh = RenderMesh(
            positions: [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0)],
            normals: [SIMD3<Float>(0, 0, 1), SIMD3<Float>(0, 0, 1), SIMD3<Float>(0, 0, 1)],
            indices: [0, 1, 2])
        var scratch = document.session.document
        var meshBody = Body(id: BodyID(), name: "MeshOnly", transform: .identity,
                            primitive: nil, render: mesh,
                            revision: scratch.nextRevision())
        meshBody.euclid = EuclidBridge.euclidMesh(from: mesh)
        document.session.perform(AddBodyCommand(body: meshBody, title: "Add mesh"))

        // The coverage-gated API never takes an output path — it returns no
        // bytes when the receipt is incomplete. Prove that a caller-visible
        // destination is untouched with a real sentinel file, then drive the
        // RAW exact writer over the same mixed set and check it really skips
        // the mesh body (named in the note) instead of substituting a mesh.
        let target = workDir.appendingPathComponent("partial.igs")
        let sentinel = Data("pre-existing target that a refused export must not touch\n".utf8)
        try sentinel.write(to: target)
        switch document.nativePartExport(format: "iges", pageID: nil) {
        case .coverageRequired(let coverage):
            XCTAssertEqual(coverage.includedCount, count)
            XCTAssertEqual(coverage.excludedCount, 1)
            XCTAssertTrue(coverage.requiresConfirmation)
            XCTAssertEqual(coverage.excludedItems.first?.reason, "mesh_only_no_exact_brep")
        case .success:
            XCTFail("an incomplete IGES selection must not return partial bytes silently")
        case .coverage:
            XCTFail("a non-dry-run export must not return only a receipt")
        case .failure(let error):
            XCTFail("unexpected incomplete-export failure: \(error.code) \(error.message)")
        }
        XCTAssertEqual(try Data(contentsOf: target), sentinel,
                       "a coverage-refused export must not write the caller's destination")

        // Raw writer boundary: the mesh-only body is skipped and NAMED; the
        // bytes are real IGES from the exact bodies, never a mesh substitute.
        switch document.nativeExportData(format: "iges", pageID: nil) {
        case .success(let (bytes, note)):
            XCTAssertGreaterThan(bytes.count, 0,
                                 "the raw writer must write the exact surface bodies")
            XCTAssertTrue(note.contains("MeshOnly"),
                          "the raw writer must name the skipped mesh body: \(note)")
            XCTAssertTrue(note.contains("skipped"),
                          "the raw writer must state that the mesh body was skipped: \(note)")
            let rawURL = workDir.appendingPathComponent("raw-mixed.igs")
            try bytes.write(to: rawURL)
            XCTAssertEqual(try Data(contentsOf: rawURL), bytes,
                           "the raw writer's bytes must survive a real filesystem round trip")
        case .failure(let error):
            XCTFail("raw IGES writer failed on a mixed exact+mesh set: "
                    + "\(error.code) \(error.message)")
        }

        // Explicit partial acceptance is the caller's informed choice; it
        // returns real bytes and a receipt that stays honestly incomplete.
        switch document.nativePartExport(format: "iges", pageID: nil, acceptPartial: true) {
        case .success(let bytes, _, let coverage):
            XCTAssertGreaterThan(bytes.count, 0)
            XCTAssertFalse(coverage.complete)
            XCTAssertTrue(coverage.acceptedPartial)
        default:
            XCTFail("an explicitly accepted partial IGES export must return bytes")
        }
    }

    func testEmptyAndUnreadableIGESExportsRefuseWithoutMutation() throws {
        // Empty document: no exact body exists, so IGES must refuse.
        switch document.nativeExportData(format: "iges", pageID: nil) {
        case .failure(let error):
            XCTAssertEqual(error.code, "no_analytic_geometry")
        case .success:
            XCTFail("an empty document must not produce IGES bytes")
        }

        // A valid surface, then garbage bytes: the refusal leaves both the
        // document and its undo stack untouched.
        let data = try singleFaceIGES()
        XCTAssertTrue(importIGES(data, name: "Sheet").isOK)
        let count = document.session.document.bodies.count
        let canUndo = document.session.undoStack.canUndo
        let garbage = Data("this is not an IGES file\n".utf8)
        let refused = importIGES(garbage, name: "Broken")
        XCTAssertFalse(refused.isOK)
        XCTAssertEqual(refused.status, 422)
        XCTAssertTrue(["iges_read_failed", "iges_empty"].contains(refused.errorCode ?? ""))
        XCTAssertEqual(document.session.document.bodies.count, count)
        XCTAssertEqual(document.session.undoStack.canUndo, canUndo)
    }

    // MARK: - Closed-solid boundary regressions (real geometry, no stubs)

    /// A real imported IGES surface must be refused as a boolean operand
    /// BEFORE any feature node or undo step exists. The exact handle must be
    /// byte-identical afterwards — `FeatureGraph`/executor mesh fallbacks would
    /// otherwise consume the sheet and leave a mesh-only body behind.
    func testImportedSurfaceBooleanIsRefusedBeforeAnyMutation() throws {
        XCTAssertTrue(importIGES(try singleFaceIGES(), name: "Sheet").isOK)
        let surfaceBody = try XCTUnwrap(
            document.session.document.bodies.first { $0.surfaceBRep != nil })
        let surface = try XCTUnwrap(surfaceBody.surfaceBRep)
        let surfaceBytes = try XCTUnwrap(OCCTKernel.serialize(surface))
        let tool = try makeSolidPlate()

        let bodies = document.session.document.bodies.count
        let features = document.session.document.features.nodes.count
        let undo = document.session.undoStack.undoCommands.count
        let surfaceID = surfaceBody.id.raw.uuidString
        let toolID = tool.id.raw.uuidString

        let asTarget = runJSON("""
        {"op":"feature.boolean","args":{"kind":"subtract","targetBodyID":"\(surfaceID)","toolBodyIDs":["\(toolID)"]}}
        """)
        XCTAssertFalse(asTarget.isOK)
        XCTAssertEqual(asTarget.errorCode, "exact_surface_needs_solid",
                       "a surface boolean must fail as a capability boundary: \(asTarget.message ?? "")")
        XCTAssertTrue(asTarget.message?.contains("exact open surface") == true,
                      asTarget.message ?? "")

        let asTool = runJSON("""
        {"op":"feature.boolean","args":{"kind":"subtract","targetBodyID":"\(toolID)","toolBodyIDs":["\(surfaceID)"]}}
        """)
        XCTAssertFalse(asTool.isOK)
        XCTAssertEqual(asTool.errorCode, "exact_surface_needs_solid")
        XCTAssertTrue(asTool.message?.contains("exact open surface") == true)

        XCTAssertEqual(document.session.document.bodies.count, bodies,
                       "a refused boolean must not consume or replace a body")
        XCTAssertEqual(document.session.document.features.nodes.count, features,
                       "a refused boolean must not append a feature")
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undo,
                       "a refused boolean must not consume an undo step")
        let current = try XCTUnwrap(document.session.document.body(with: surfaceBody.id))
        XCTAssertNil(current.brep, "the refused surface must not become a solid")
        XCTAssertEqual(try XCTUnwrap(OCCTKernel.serialize(try XCTUnwrap(current.surfaceBRep))),
                       surfaceBytes, "the exact surface handle must be unchanged")
    }

    /// A real face edit on an imported IGES surface is refused by the executor
    /// preflight; the document, history, undo stack and exact handle stay put.
    func testImportedSurfaceFaceEditIsRefusedBeforeAnyMutation() throws {
        XCTAssertTrue(importIGES(try singleFaceIGES(), name: "Sheet").isOK)
        let surfaceBody = try XCTUnwrap(
            document.session.document.bodies.first { $0.surfaceBRep != nil })
        let surface = try XCTUnwrap(surfaceBody.surfaceBRep)
        let face = try XCTUnwrap(OCCTKernel.faceInfo(surface).first?.index)
        let surfaceBytes = try XCTUnwrap(OCCTKernel.serialize(surface))
        let bodies = document.session.document.bodies.count
        let features = document.session.document.features.nodes.count
        let undo = document.session.undoStack.undoCommands.count

        let response = runJSON("""
        {"op":"feature.pushPull","args":{"bodyID":"\(surfaceBody.id.raw.uuidString)","face":[\(face)],"distance":2}}
        """)
        XCTAssertFalse(response.isOK)
        XCTAssertEqual(response.errorCode, "exact_surface_needs_solid")
        XCTAssertTrue(response.message?.contains("exact open surface") == true)
        XCTAssertEqual(document.session.document.bodies.count, bodies)
        XCTAssertEqual(document.session.document.features.nodes.count, features)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undo)
        let current = try XCTUnwrap(document.session.document.body(with: surfaceBody.id))
        XCTAssertNil(current.brep)
        XCTAssertEqual(try XCTUnwrap(OCCTKernel.serialize(try XCTUnwrap(current.surfaceBRep))),
                       surfaceBytes)
    }

    /// The interactive tools must refuse BEFORE entering a picking/drag mode:
    /// no preview, no ReplaceBody, no undo step and no dropped surface handle.
    func testLiveFaceAndBodyToolsRefuseExactOpenSurfaceWithoutMutation() throws {
        XCTAssertTrue(importIGES(try singleFaceIGES(), name: "Sheet").isOK)
        let body = try XCTUnwrap(document.session.document.bodies.first)
        let surface = try XCTUnwrap(body.surfaceBRep)
        let surfaceBytes = try XCTUnwrap(OCCTKernel.serialize(surface))
        let bodies = document.session.document.bodies.count
        let undo = document.session.undoStack.undoCommands.count

        let face = try firstPlanarFace(in: body)
        let scale = body.transform.scale
        let model = EditorViewModel(session: document.session)
        model.selection = [body.id]
        model.mode = .faceSelected(body.id)
        model.toolContext = EditorViewModel.ToolContext(
            profile: Profile(loop: face.outline.map { $0 * scale },
                             kind: .polygonal, sourceEntityIDs: []),
            holes: face.holes.map {
                Profile(loop: $0.map { $0 * scale }, kind: .polygonal, sourceEntityIDs: [])
            },
            plane: SketchPlane(origin: body.transform.applying(to: face.origin),
                               xAxis: body.transform.rotation.act(face.basisX),
                               yAxis: body.transform.rotation.act(face.basisY)),
            sketchID: nil, sourceBody: body.id, faceTriangles: face.triangles,
            kind: .extrude(distance: 0))

        XCTAssertFalse(model.beginFaceScale(),
                       "Scale Face has no exact result for an open sheet")
        XCTAssertTrue(model.errorMessage?.contains("exact open surface") == true,
                      model.errorMessage ?? "")
        XCTAssertFalse(model.beginFaceRotate(),
                       "Rotate Face has no exact result for an open sheet")
        XCTAssertTrue(model.errorMessage?.contains("exact open surface") == true)

        model.mode = .selected(body.id)
        model.beginBlend(.fillet)
        XCTAssertTrue(model.errorMessage?.contains("exact open surface") == true)
        if case .pickingBlendEdges = model.mode {
            XCTFail("Fillet must not arm edge picking on an exact open surface")
        }

        model.beginShell()
        XCTAssertTrue(model.errorMessage?.contains("exact open surface") == true)
        if case .pickingShellFaces = model.mode {
            XCTFail("Shell must not arm face picking on an exact open surface")
        }

        model.beginDeleteFace()
        XCTAssertTrue(model.errorMessage?.contains("exact open surface") == true)
        if case .pickingDeleteFaces = model.mode {
            XCTFail("Delete Face must not arm face picking on an exact open surface")
        }

        model.beginReplaceFace()
        XCTAssertTrue(model.errorMessage?.contains("exact open surface") == true)
        if case .pickingReplaceFace = model.mode {
            XCTFail("Replace Face must not arm face picking on an exact open surface")
        }

        XCTAssertEqual(document.session.document.bodies.count, bodies)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undo)
        let current = try XCTUnwrap(document.session.document.body(with: body.id))
        XCTAssertNil(current.brep)
        XCTAssertEqual(try XCTUnwrap(OCCTKernel.serialize(try XCTUnwrap(current.surfaceBRep))),
                       surfaceBytes)
    }

    /// A body owns one exact shape: adopting a solid replaces the surface (and
    /// a failed surface adoption leaves the prior solid untouched). The
    /// replacement is then exported and read back: no stale sheet survives as
    /// an alternate export source.
    func testSolidAdoptionReplacesSurfaceAndFailedAdoptionIsAtomic() throws {
        XCTAssertTrue(importIGES(try singleFaceIGES(), name: "Sheet").isOK)
        let original = try XCTUnwrap(document.session.document.bodies.first)
        let surface = try XCTUnwrap(original.surfaceBRep)
        let surfaceBytes = try XCTUnwrap(OCCTKernel.serialize(surface))
        let box = try XCTUnwrap(OCCTKernel.primitiveShape(
            .box(width: 10, depth: 10, height: 10), placement: .identity))

        var adopted = original
        XCTAssertTrue(adopted.adoptBRep(box))
        XCTAssertNotNil(adopted.brep)
        XCTAssertTrue(adopted.brep?.containsSolid ?? false)
        XCTAssertNil(adopted.surfaceBRep,
                     "adopting a solid must clear the old exact surface")

        // Failed surface adoption on a solid body: refusal leaves the solid.
        let adoptedBytes = try XCTUnwrap(OCCTKernel.serialize(try XCTUnwrap(adopted.brep)))
        var rejected = adopted
        XCTAssertFalse(rejected.adoptSurfaceBRep(box),
                       "a shape containing a solid must not become a surface body")
        XCTAssertNotNil(rejected.brep)
        XCTAssertNil(rejected.surfaceBRep)
        XCTAssertEqual(try XCTUnwrap(OCCTKernel.serialize(try XCTUnwrap(rejected.brep))),
                       adoptedBytes)

        // Failed surface adoption on the original surface: the sheet survives.
        var failed = original
        XCTAssertFalse(failed.adoptSurfaceBRep(box))
        XCTAssertNil(failed.brep)
        XCTAssertEqual(try XCTUnwrap(OCCTKernel.serialize(try XCTUnwrap(failed.surfaceBRep))),
                       surfaceBytes)

        document.session.perform(ReplaceBodyCommand(
            title: "Adopt Solid", before: original, after: adopted))
        let current = try XCTUnwrap(document.session.document.body(with: original.id))
        XCTAssertNil(current.surfaceBRep)
        XCTAssertNotNil(current.brep)

        switch document.nativePartExport(format: "iges", pageID: nil) {
        case .success(let bytes, _, let coverage):
            XCTAssertGreaterThan(bytes.count, 0)
            XCTAssertTrue(coverage.complete)
            let readBack = OCCTKernel.readIGES(bytes)
            XCTAssertEqual(readBack.solids.count, 1,
                           "the adopted solid must be the only exported exact shape")
            XCTAssertEqual(readBack.surfaces.count, 0,
                           "the replaced surface must not survive as a second export source")
        case .coverageRequired(let coverage):
            XCTFail("one exact solid is a complete IGES selection: \(coverage.notes)")
        case .coverage:
            XCTFail("a real IGES export must return bytes")
        case .failure(let error):
            XCTFail("IGES export failed after adoption: \(error.code) \(error.message)")
        }
    }

    /// The guards are surface-specific: a real feature-produced solid still
    /// takes a face edit and a boolean, and keeps its exact B-rep.
    func testClosedSolidFaceEditAndBooleanStillWork() throws {
        let plate = try makeSolidPlate()
        let plateBrep = try XCTUnwrap(plate.brep)
        let top = try XCTUnwrap(OCCTKernel.faceInfo(plateBrep).first { $0.normal.z > 0.99 })
        let push = runJSON("""
        {"op":"feature.pushPull","args":{"bodyID":"\(plate.id.raw.uuidString)","face":[\(top.index)],"distance":2}}
        """)
        XCTAssertTrue(push.isOK, "solid face push/pull must still work: \(push.message ?? "")")
        let pushed = try XCTUnwrap(document.session.document.body(with: plate.id))
        XCTAssertNotNil(pushed.brep, "a solid face edit must stay exact")
        XCTAssertNil(pushed.surfaceBRep)

        let created = runJSON(#"{"op":"sketch.create","args":{"name":"Cut"}}"#)
        XCTAssertTrue(created.isOK, created.message ?? "")
        let sketch = try XCTUnwrap(object(created)["sketchID"] as? String)
        let added = runJSON("""
        {"op":"sketch.addEntities","args":{"sketchID":"\(sketch)","entities":[{"kind":"rect","min":[10,10],"max":[20,20]}]}}
        """)
        XCTAssertTrue(added.isOK, added.message ?? "")
        let cut = runJSON("""
        {"op":"feature.extrude","args":{"sketchID":"\(sketch)","seedPoint":[15,15],"distance":20,"boolean":"subtract","booleanTargets":["\(plate.id.raw.uuidString)"]}}
        """)
        XCTAssertTrue(cut.isOK, "solid boolean must still work: \(cut.message ?? "")")
        let cutBody = try XCTUnwrap(document.session.document.body(with: plate.id))
        XCTAssertNotNil(cutBody.brep, "a solid boolean must keep the exact B-rep")
        XCTAssertNil(cutBody.surfaceBRep)
    }

    /// The ordinary copy path must carry the exact surface handle and keep the
    /// volume/analytic metadata truthful for every copy.
    func testSurfaceCopyKeepsExactHandleAndTruthfulMetadata() throws {
        XCTAssertTrue(importIGES(try singleFaceIGES(), name: "Sheet").isOK)
        let original = try XCTUnwrap(document.session.document.bodies.first)
        XCTAssertNotNil(original.surfaceBRep)

        let model = EditorViewModel(session: document.session)
        model.selection = [original.id]
        model.copyOnDrag = true
        model.beginMove()

        XCTAssertEqual(document.session.document.bodies.count, 2,
                       "copy-on-drag must add exactly one body")
        let copy = try XCTUnwrap(document.session.document.bodies.first { $0.id != original.id })
        XCTAssertNotNil(copy.surfaceBRep, "a copy must keep the exact surface handle")
        XCTAssertNil(copy.brep)

        let rows = bodyRows(document)
        XCTAssertEqual(rows.count, 2)
        for row in rows {
            XCTAssertEqual(row["openSurfaceBRep"] as? Bool, true)
            XCTAssertEqual(row["analyticBRep"] as? Bool, false)
            XCTAssertEqual(row["volumeApplicable"] as? Bool, false,
                           "an open sheet has no applicable closed volume")
            XCTAssertEqual((row["volumeMM3"] as? Double) ?? -1, 0, accuracy: 1e-9)
        }

        switch document.nativePartExport(format: "iges", pageID: nil) {
        case .success(let bytes, _, let coverage):
            XCTAssertGreaterThan(bytes.count, 0)
            XCTAssertTrue(coverage.complete)
            XCTAssertEqual(coverage.includedCount, 2,
                           "both exact surface copies must be exported")
        case .coverageRequired(let coverage):
            XCTFail("two exact surfaces are a complete IGES selection: \(coverage.notes)")
        case .coverage:
            XCTFail("a real IGES export must return bytes")
        case .failure(let error):
            XCTFail("IGES export failed after copy: \(error.code) \(error.message)")
        }
    }
}
#endif
