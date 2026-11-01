//
//  CADMeshPreviewConsentTests.swift
//  FloeCADKitTests
//
//  Focused source test for the native Mesh panel's explicit destructive-consent
//  path on a precise body. `CADMeshPanelView` captures the
//  "Allow destructive mesh edits" toggle into the preview request it submits;
//  this test mirrors that exact request shape against the real service:
//
//   * `preview:true` without `forceMesh` still refuses the analytic plate's
//     B-rep before any compute (`brep_body_refused`);
//   * the same request with the captured `forceMesh:true` returns real transient
//     result geometry (`preview:true`, `mutated:false`) and leaves the body
//     identity/B-rep, change count and undo/redo stacks untouched;
//   * an apply-shaped request after revoking consent (no `forceMesh`) is still
//     refused, never a silent downgrade.
//
// The App-level UI flow is CADMeshPanelConsentUITests. This test does not build
// or run the App; it supplies the exact geometry/undo assertions the Mesh panel
// UI cannot expose.
//
// SPDX-License-Identifier: MPL-2.0
//

import XCTest
import Foundation
import simd
import Euclid
@testable import FloeCAD

@MainActor
final class CADMeshPreviewConsentTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeCADMeshConsent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    private func makeDocument(_ name: String) async throws -> FloeCADDocument {
        try await FloeCADDocument.create(at: workDir.appendingPathComponent("\(name).floecad"),
                                         name: name)
    }

    private func run(_ document: FloeCADDocument, _ json: String,
                     file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let result = document.executeJSON(Data(json.utf8))
        XCTAssertTrue(result.isOK, "\(result.message ?? "") — \(json)", file: file, line: line)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: result.payload) as? [String: Any],
                             file: file, line: line)
    }

    /// The same production commands as the App's canonical plate fixture:
    /// a 100×60×10 analytic plate with a Ø10 through-hole.
    private func makePlate(_ document: FloeCADDocument) throws -> Body {
        let plate = try XCTUnwrap(try run(document, #"{"op":"sketch.create","args":{"name":"Plate"}}"#)["sketchID"] as? String)
        _ = try run(document, """
        {"op":"sketch.addEntities","args":{"sketchID":"\(plate)","entities":[{"kind":"rect","min":[0,0],"max":[100,60]}]}}
        """)
        _ = try run(document, """
        {"op":"feature.extrude","args":{"sketchID":"\(plate)","seedPoint":[50,30],"distance":10}}
        """)
        let source = try XCTUnwrap(document.session.document.bodies.first)
        let hole = try XCTUnwrap(try run(document, #"{"op":"sketch.create","args":{"name":"Hole"}}"#)["sketchID"] as? String)
        _ = try run(document, """
        {"op":"sketch.addEntities","args":{"sketchID":"\(hole)","entities":[{"kind":"circle","center":[50,30],"radius":5}]}}
        """)
        _ = try run(document, """
        {"op":"feature.extrude","args":{"sketchID":"\(hole)","seedPoint":[50,30],"distance":40,"symmetric":true,"boolean":"subtract","booleanTargets":["\(source.id.raw.uuidString)"]}}
        """)
        return try XCTUnwrap(document.session.document.bodies.first)
    }

    private func assertDocumentUnchanged(_ document: FloeCADDocument,
                                         bodyIDs: [UUID],
                                         changeCount: Int,
                                         undoTitles: [String],
                                         redoTitles: [String],
                                         brepBytes: Data,
                                         file: StaticString = #filePath,
                                         line: UInt = #line) throws {
        XCTAssertEqual(document.session.document.bodies.map(\.id.raw), bodyIDs,
                       "a refused or previewed operation must not add or remove bodies",
                       file: file, line: line)
        XCTAssertEqual(document.session.changeCount, changeCount,
                       "a refused or previewed operation must not add a change/undo epoch",
                       file: file, line: line)
        XCTAssertEqual(document.session.undoStack.undoCommands.map(\.title), undoTitles,
                       "a preview must not add an undo entry",
                       file: file, line: line)
        XCTAssertEqual(document.session.undoStack.redoCommands.map(\.title), redoTitles,
                       "a preview must not clear or add redo entries",
                       file: file, line: line)
        let body = try XCTUnwrap(document.session.document.bodies.first,
                                 "the precise body must still exist",
                                 file: file, line: line)
        let current = try XCTUnwrap(body.brep,
                                    "the precise body must keep its analytic B-rep",
                                    file: file, line: line)
        XCTAssertEqual(try XCTUnwrap(OCCTKernel.serialize(current)),
                       brepBytes,
                       "the exact B-rep bytes must be unchanged",
                       file: file, line: line)
    }

    func testConsentedSimplifyPreviewLeavesPreciseBodyAndUndoUntouched() async throws {
        let document = try await makeDocument("MeshConsentPreview")
        defer { document.close() }
        let plate = try makePlate(document)
        let brep = try XCTUnwrap(plate.brep,
                                 "the canonical plate must carry a real analytic B-rep")
        let brepBytes = try XCTUnwrap(OCCTKernel.serialize(brep))
        let bodyIDs = document.session.document.bodies.map(\.id.raw)
        let changeCount = document.session.changeCount
        let undoTitles = document.session.undoStack.undoCommands.map(\.title)
        let redoTitles = document.session.undoStack.redoCommands.map(\.title)
        let bodyID = plate.id.raw.uuidString
        let trianglesBefore = plate.render.triangleCount
        XCTAssertGreaterThan(trianglesBefore, 8)

        let service = CADMeshService(document: document)
        let base: [String: Any] = ["bodyIDs": [bodyID], "ratio": 0.5]

        // 1. Default state: the panel submits preview:true and no forceMesh.
        //    The real service refuses the precise body before computing.
        var refusedArgs = base
        refusedArgs["action"] = "simplify"
        refusedArgs["preview"] = true
        let refused = await service.handleAsync(action: "simplify", args: refusedArgs)
        XCTAssertEqual(refused["ok"] as? Bool, false,
                       refused["message"] as? String ?? "")
        XCTAssertEqual(refused["error"] as? String, "brep_body_refused")
        XCTAssertEqual(refused["inputExactness"] as? String, "precise")
        XCTAssertEqual(refused["brepBodyCount"] as? Int, 1)
        XCTAssertNil(refused["mesh"], "a refused preview must not carry result geometry")
        try assertDocumentUnchanged(document, bodyIDs: bodyIDs, changeCount: changeCount,
                                    undoTitles: undoTitles, redoTitles: redoTitles,
                                    brepBytes: brepBytes)

        // 2. The user explicitly enables "Allow destructive mesh edits": the
        //    panel captures that consent into the submitted preview request.
        var consentedArgs = base
        consentedArgs["action"] = "simplify"
        consentedArgs["preview"] = true
        consentedArgs["forceMesh"] = true
        let preview = await service.handleAsync(action: "simplify", args: consentedArgs)
        XCTAssertEqual(preview["ok"] as? Bool, true, preview["message"] as? String ?? "")
        XCTAssertEqual(preview["preview"] as? Bool, true)
        XCTAssertEqual(preview["mutated"] as? Bool, false,
                       "a preview must never commit geometry")
        XCTAssertEqual(preview["exactness"] as? String, "mesh")
        let previewTriangles = try XCTUnwrap(preview["triangleCount"] as? Int)
        XCTAssertGreaterThan(previewTriangles, 0,
                             "the consented preview must return real result geometry")
        XCTAssertLessThanOrEqual(previewTriangles, trianglesBefore,
                                 "simplify cannot add triangles to the real body")
        XCTAssertNotNil(preview["mesh"] as? [String: Any],
                        "the preview must carry the bounded transient mesh snapshot")
        let previewHash = try XCTUnwrap(preview["previewHash"] as? String)
        XCTAssertFalse(previewHash.isEmpty)
        XCTAssertEqual(document.session.document.bodies.first?.render.triangleCount,
                       trianglesBefore,
                       "a preview must not replace the body's render mesh")
        try assertDocumentUnchanged(document, bodyIDs: bodyIDs, changeCount: changeCount,
                                    undoTitles: undoTitles, redoTitles: redoTitles,
                                    brepBytes: brepBytes)

        // 3. Applying after the consent is revoked must refuse, not downgrade
        //    silently. The panel invalidates the pending card on revocation;
        //    this asserts the service-side safety net for the same shape.
        var revokedApply = base
        revokedApply["action"] = "simplify"
        revokedApply["expectedPreviewHash"] = previewHash
        if let revision = preview["previewRevision"] as? Int {
            revokedApply["expectedRevision"] = revision
        }
        if let count = preview["previewChangeCount"] as? Int {
            revokedApply["expectedChangeCount"] = count
        }
        let revoked = await service.handleAsync(action: "simplify", args: revokedApply)
        XCTAssertEqual(revoked["ok"] as? Bool, false,
                       revoked["message"] as? String ?? "")
        XCTAssertEqual(revoked["error"] as? String, "brep_body_refused")
        XCTAssertNotEqual(revoked["mutated"] as? Bool, true)
        try assertDocumentUnchanged(document, bodyIDs: bodyIDs, changeCount: changeCount,
                                    undoTitles: undoTitles, redoTitles: redoTitles,
                                    brepBytes: brepBytes)
    }
}
