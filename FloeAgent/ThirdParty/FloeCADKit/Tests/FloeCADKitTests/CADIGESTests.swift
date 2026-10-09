//
//  CADIGESTests.swift
//  FloeCADKitTests
//
//  IGES import contract for `FloeCADDocument.nativeImportData`:
//
//  - unreadable/empty payloads are refused with a structured error and leave
//    the document — and its undo stack — untouched;
//  - a real IGES file imports through the native path with the solid vs
//    surface distinction kept honest: an OCCT BRep-mode file yields an exact
//    solid body with the analytic box volume, while a face-mode file yields
//    render-only surface bodies that are never marked `analyticBRep`.
//
//  No IGES sample exists in this repository, so both round-trip fixtures are
//  written in-test by OCCT's own IGES writer (`OCCTKernel.debugWriteIGES`,
//  DEBUG-only test support; the product itself exports STEP only). The tests
//  themselves are not run by the parse-only qualification this work came
//  under — see the delivery report.
//

import XCTest
import simd
@testable import FloeCAD

final class CADIGESTests: XCTestCase {

    private var workDir: URL!
    private var document: FloeCADDocument!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeCADIGES-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        document = try await FloeCADDocument.create(
            at: workDir.appendingPathComponent("iges.floecad"), name: "IGES")
    }

    override func tearDown() async throws {
        document?.close()
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - Helpers

    private func bodyCount() -> Int { document.session.document.bodies.count }

    private func object(_ outcome: CADCommandOutcome) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: outcome.payload)) as? [String: Any] ?? [:]
    }

    private func importOutcome(_ data: Data, fileName: String) -> CADCommandOutcome {
        document.nativeImportData(data, format: "iges", fileName: fileName, unitScale: nil)
    }

    // MARK: - Refusal

    /// Arbitrary bytes are not an IGES file: the import must come back as a
    /// structured 422 (either "unreadable" or "parsed but empty" — both are
    /// refusals that import nothing) and must not touch the document.
    func testUnreadableBytesAreRefusedWithNothingImported() {
        let outcome = importOutcome(Data("this is not an IGES file\n".utf8),
                                    fileName: "Broken.igs")
        XCTAssertFalse(outcome.isOK, "garbage bytes must not import")
        XCTAssertEqual(outcome.status, 422)
        let code = outcome.errorCode ?? ""
        XCTAssertTrue(["iges_read_failed", "iges_empty"].contains(code),
                      "expected a structured IGES refusal, got '\(code)' — \(outcome.message ?? "")")
        XCTAssertEqual(bodyCount(), 0, "a refused import must leave the document unchanged")
        XCTAssertFalse(document.session.undoStack.canUndo,
                       "a refused import must not push an undo entry")
    }

    /// A zero-byte payload cannot parse: the structured refusal says so and
    /// nothing is imported.
    func testEmptyPayloadIsRefusedWithNothingImported() {
        let outcome = importOutcome(Data(), fileName: "Empty.igs")
        XCTAssertFalse(outcome.isOK)
        XCTAssertEqual(outcome.errorCode, "iges_read_failed")
        XCTAssertEqual(bodyCount(), 0)
        XCTAssertFalse(document.session.undoStack.canUndo)
    }

    /// The kernel reader itself reports unreadable bytes as `readSucceeded ==
    /// false` with no shapes, which is what the import branch turns into the
    /// structured refusal above.
    func testKernelReaderReportsUnreadableBytesAsUnread() {
        let result = OCCTKernel.readIGES(Data("not iges".utf8))
        XCTAssertFalse(result.readSucceeded)
        XCTAssertEqual(result.rootCount, 0)
        XCTAssertTrue(result.solids.isEmpty)
        XCTAssertTrue(result.surfaces.isEmpty)
    }

    // MARK: - Round trip (DEBUG: the IGES writer exists only as test support)

#if DEBUG
    /// A 20 × 30 × 40 mm box written by OCCT's own IGES writer. `brepMode`
    /// true keeps the solid an IGES BRep solid; false decomposes it into
    /// loose faces — the surface-only file IGES consumers commonly produce.
    private func writeIGESBox(brepMode: Bool, name: String) throws -> Data {
        let box = try XCTUnwrap(OCCTKernel.primitiveShape(
            .box(width: 20, depth: 30, height: 40), placement: .identity))
        let url = workDir.appendingPathComponent(name)
        XCTAssertTrue(OCCTKernel.debugWriteIGES([box], to: url, brepMode: brepMode),
                      "OCCT's IGES writer refused the box")
        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 0, "the IGES writer produced no bytes")
        return data
    }

    /// BRep-mode round trip: the imported body must be an exact solid (not a
    /// tessellation approximation), keep the analytic box volume, and undo as
    /// one step.
    func testBREPModeIGESImportsOneExactSolidBody() throws {
        let data = try writeIGESBox(brepMode: true, name: "box-brep.igs")
        let outcome = importOutcome(data, fileName: "Box")
        XCTAssertTrue(outcome.isOK,
                      "IGES import failed (\(outcome.status)) \(outcome.errorCode ?? ""): "
                        + "\(outcome.message ?? "")")
        let payload = object(outcome)
        XCTAssertEqual(payload["count"] as? Int, 1)
        XCTAssertEqual(payload["solidsImported"] as? Int, 1)
        XCTAssertEqual(payload["surfacesImported"] as? Int, 0)
        let rows = try XCTUnwrap(payload["imported"] as? [[String: Any]],
                                 "imported rows missing: \(payload)")
        XCTAssertEqual(rows.first?["kind"] as? String, "solid")
        XCTAssertEqual(rows.first?["analyticBRep"] as? Bool, true)

        XCTAssertEqual(bodyCount(), 1)
        let body = try XCTUnwrap(document.session.document.bodies.first)
        let brep = try XCTUnwrap(body.brep, "an IGES solid must be an exact body")
        XCTAssertFalse(body.render.indices.isEmpty, "the imported solid must render")
        XCTAssertEqual(OCCTKernel.volume(brep), 24_000.0, accuracy: 1e-3,
                       "the round-tripped solid must keep the box volume (20×30×40)")

        // One undo step restores the document exactly.
        document.session.undo()
        XCTAssertEqual(bodyCount(), 0, "the import must be one undoable step")
        document.session.redo()
        XCTAssertEqual(bodyCount(), 1)
    }

    /// Face-mode round trip: an IGES file that carries only surfaces must
    /// import as render-only bodies, honestly reported as surfaces — never as
    /// analytic solids.
    func testFaceModeIGESImportsAsSurfaceBodiesNotSolids() throws {
        let data = try writeIGESBox(brepMode: false, name: "box-faces.igs")
        let outcome = importOutcome(data, fileName: "BoxFaces")
        XCTAssertTrue(outcome.isOK,
                      "IGES import failed (\(outcome.status)) \(outcome.errorCode ?? ""): "
                        + "\(outcome.message ?? "")")
        let payload = object(outcome)
        XCTAssertEqual(payload["solidsImported"] as? Int, 0,
                       "a face-only IGES file must not produce a solid")
        XCTAssertGreaterThanOrEqual(payload["surfacesImported"] as? Int ?? 0, 1,
                                    "the faces must arrive as surface bodies")
        XCTAssertEqual(payload["count"] as? Int, payload["surfacesImported"] as? Int)
        let rows = try XCTUnwrap(payload["imported"] as? [[String: Any]])
        XCTAssertFalse(rows.isEmpty)
        for row in rows {
            XCTAssertEqual(row["kind"] as? String, "surface")
            XCTAssertEqual(row["analyticBRep"] as? Bool, false)
        }
        for body in document.session.document.bodies {
            XCTAssertNil(body.brep, "an IGES surface must not be adopted as an analytic solid")
        }
        let note = try XCTUnwrap(payload["note"] as? String,
                                 "the surface import must carry an honest note")
        XCTAssertTrue(note.contains("not solids"),
                      "the note must state that IGES surfaces are not solids: \(note)")
    }
#endif
}
