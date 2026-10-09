//
//  CADPreviewBindingTests.swift
//  FloeCADKitTests
//
//  Focused tests for the pre-apply preview contract: ShapeScript and mesh
//  destructive operations must be previewable WITHOUT mutating the document,
//  the preview must carry the actual result geometry, and the following apply
//  must be bound to that exact preview (hash + revision/change-count), refusing
//  stale applications instead of committing unseen geometry.
//
//  Also covers the printf-aware `FloeCADStrings.format` substitution (the
//  `%lld`-vs-`%@` defect) including a host-localizer round trip.
//
//  SPDX-License-Identifier: MPL-2.0
//

import XCTest
import simd
import Euclid
@testable import FloeCAD

final class CADPreviewBindingTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeCADPreviewBinding-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    private func makeDocument(_ name: String) async throws -> FloeCADDocument {
        try await FloeCADDocument.create(at: workDir.appendingPathComponent("\(name).floecad"),
                                         name: name)
    }

    @discardableResult
    private func addCube(_ document: FloeCADDocument, name: String,
                         offsetX: Double = 0) -> Body {
        var transform = Transform3D.identity
        transform.translation = SIMD3(offsetX, 0, 0)
        let body = Body(name: name, transform: transform, primitive: nil,
                        euclidMesh: .cube(center: Vector(0, 0, 0), size: Vector(10, 10, 10)),
                        revision: 1)
        document.session.perform(AddBodyCommand(body: body, title: "Test \(name)"))
        return body
    }

    // MARK: - Mesh preview

    func testMeshCombinePreviewIsTransientAndBindsApply() async throws {
        let document = try await makeDocument("CombinePreview")
        let service = CADMeshService(document: document)
        let first = addCube(document, name: "C1")
        let second = addCube(document, name: "C2", offsetX: 20)
        let bodiesBefore = document.session.document.bodies.count
        let changeCountBefore = document.session.changeCount
        let revisionBefore = document.store.revision

        let combineArgs: [String: Any] = [
            "bodyIDs": [first.id.raw.uuidString, second.id.raw.uuidString],
            "name": "Merged",
        ]
        var previewArgs = combineArgs
        previewArgs["preview"] = true
        let preview = service.handle(action: "combine", args: previewArgs)
        XCTAssertEqual(preview["ok"] as? Bool, true, preview["message"] as? String ?? "")
        XCTAssertEqual(preview["preview"] as? Bool, true)
        XCTAssertEqual(preview["mutated"] as? Bool, false)
        let hash = try XCTUnwrap(preview["previewHash"] as? String)
        XCTAssertEqual(hash.count, 64)
        let mesh = try XCTUnwrap(preview["mesh"] as? [String: Any],
                                 "the preview must carry the actual result geometry")
        XCTAssertFalse((mesh["positions"] as? [Double] ?? []).isEmpty)
        XCTAssertFalse((mesh["indices"] as? [Int] ?? []).isEmpty)
        let revision = try XCTUnwrap(preview["previewRevision"] as? Int)
        let changeCount = try XCTUnwrap(preview["previewChangeCount"] as? Int)
        XCTAssertEqual(revision, revisionBefore)
        XCTAssertEqual(changeCount, changeCountBefore)

        // The preview must NOT mutate the document.
        XCTAssertEqual(document.session.document.bodies.count, bodiesBefore,
                       "a preview must not add or remove bodies")
        XCTAssertEqual(document.session.changeCount, changeCountBefore,
                       "a preview must not add an undo entry")
        XCTAssertEqual(document.store.revision, revisionBefore)

        // A stale/foreign hash is refused with no mutation.
        var staleArgs = combineArgs
        staleArgs["expectedPreviewHash"] = String(repeating: "0", count: 64)
        let stale = service.handle(action: "combine", args: staleArgs)
        XCTAssertEqual(stale["ok"] as? Bool, false)
        XCTAssertEqual(stale["error"] as? String, "preview_stale")
        XCTAssertEqual(document.session.document.bodies.count, bodiesBefore,
                       "a refused stale apply must not mutate")

        // The bound apply commits exactly the previewed result.
        var applyArgs = combineArgs
        applyArgs["expectedPreviewHash"] = hash
        applyArgs["expectedRevision"] = revision
        applyArgs["expectedChangeCount"] = changeCount
        let applied = service.handle(action: "combine", args: applyArgs)
        XCTAssertEqual(applied["ok"] as? Bool, true, applied["message"] as? String ?? "")
        XCTAssertEqual(applied["mutated"] as? Bool, true)
        XCTAssertEqual(document.session.document.bodies.count, 1,
                       "the combined inputs are consumed into one body")
    }

    func testMeshRepairPreviewReturnsGeometryWithoutMutation() async throws {
        let document = try await makeDocument("RepairPreview")
        let service = CADMeshService(document: document)
        let cube = addCube(document, name: "R1")
        let changeCountBefore = document.session.changeCount

        let preview = service.handle(action: "repair", args: [
            "bodyID": cube.id.raw.uuidString,
            "tolerance": 1e-3,
            "preview": true,
        ])
        XCTAssertEqual(preview["ok"] as? Bool, true, preview["message"] as? String ?? "")
        XCTAssertEqual(preview["preview"] as? Bool, true)
        XCTAssertNotNil(preview["previewHash"] as? String)
        let mesh = try XCTUnwrap(preview["mesh"] as? [String: Any])
        XCTAssertFalse((mesh["indices"] as? [Int] ?? []).isEmpty)
        XCTAssertEqual(document.session.changeCount, changeCountBefore,
                       "a repair preview must not mutate the document")
    }

    // MARK: - Script preview

    func testScriptPreviewReturnsTransientMeshAndBindsApply() async throws {
        let document = try await makeDocument("ScriptPreview")
        let service = CADScriptService(document: document)
        let bodiesBefore = document.session.document.bodies.count
        let changeCountBefore = document.session.changeCount

        let preview = await service.handle(action: "preview",
                                           args: ["source": "cube { size 10 }"])
        XCTAssertEqual(preview["ok"] as? Bool, true, preview["message"] as? String ?? "")
        XCTAssertEqual(preview["preview"] as? Bool, true)
        XCTAssertEqual(preview["mutated"] as? Bool, false)
        let hash = try XCTUnwrap(preview["previewHash"] as? String)
        let mesh = try XCTUnwrap(preview["mesh"] as? [String: Any],
                                 "a script preview must carry the evaluated geometry")
        XCTAssertEqual((mesh["indices"] as? [Int] ?? []).count, 36,
                       "cube { size 10 } is 12 triangles")
        let changeCount = try XCTUnwrap(preview["previewChangeCount"] as? Int)
        XCTAssertEqual(changeCount, changeCountBefore)
        XCTAssertEqual(document.session.document.bodies.count, bodiesBefore)

        // A mismatched preview hash must refuse without creating a body.
        let stale = await service.handle(action: "apply", args: [
            "source": "cube { size 10 }",
            "name": "S",
            "expectedPreviewHash": String(repeating: "0", count: 64),
        ])
        XCTAssertEqual(stale["ok"] as? Bool, false)
        XCTAssertEqual(stale["error"] as? String, "preview_stale")
        XCTAssertEqual(document.session.document.bodies.count, bodiesBefore,
                       "a refused stale script apply must not create a body")

        // Editing the script after the preview also refuses.
        let edited = await service.handle(action: "apply", args: [
            "source": "cube { size 30 }",
            "name": "S",
            "expectedPreviewHash": hash,
        ])
        XCTAssertEqual(edited["ok"] as? Bool, false)
        XCTAssertEqual(edited["error"] as? String, "preview_stale")

        // The exact previewed evaluation applies.
        let applied = await service.handle(action: "apply", args: [
            "source": "cube { size 10 }",
            "name": "S",
            "expectedPreviewHash": hash,
            "expectedChangeCount": changeCount,
        ])
        XCTAssertEqual(applied["ok"] as? Bool, true, applied["message"] as? String ?? "")
        XCTAssertEqual(document.session.document.bodies.count, bodiesBefore + 1)
    }

    // MARK: - String formatting

    func testFormatTemplateHandlesTypedPlaceholders() {
        XCTAssertEqual(
            FloeCADStrings.formatTemplate("PDF export ready (%lld bytes).", arguments: [1234]),
            "PDF export ready (1234 bytes).")
        XCTAssertEqual(
            FloeCADStrings.formatTemplate("%@ export ready (%lld bytes).",
                                          arguments: ["PDF", 4096]),
            "PDF export ready (4096 bytes).")
        XCTAssertEqual(
            FloeCADStrings.formatTemplate("%@ DOF", arguments: [6]),
            "6 DOF")
        XCTAssertEqual(
            FloeCADStrings.formatTemplate("%d-%i-%u", arguments: [1, 2, 3]),
            "1-2-3")
        XCTAssertEqual(
            FloeCADStrings.formatTemplate("%.2f mm", arguments: [3.14159]),
            "3.14 mm")
        XCTAssertEqual(
            FloeCADStrings.formatTemplate("100%% sure", arguments: []),
            "100% sure")
        XCTAssertEqual(
            FloeCADStrings.formatTemplate("no placeholders", arguments: []),
            "no placeholders")
        // A specifier with no remaining argument is left verbatim rather than
        // trapping or dropping text.
        XCTAssertEqual(
            FloeCADStrings.formatTemplate("%lld bytes left", arguments: []),
            "%lld bytes left")
    }

    func testFormatUsesHostLocalizerWithTypedCatalogValues() {
        let original = FloeCADStrings.localizer
        defer { FloeCADStrings.localizer = original }
        FloeCADStrings.localizer = { key in
            switch key {
            case "test.bytes": return "%lld 字节"
            case "test.exported": return "%@ 导出已就绪（%lld 字节）。"
            default: return nil
            }
        }
        XCTAssertEqual(FloeCADStrings.format("test.bytes", "fallback (%lld bytes).", 2048),
                       "2048 字节")
        XCTAssertEqual(FloeCADStrings.format("test.exported",
                                             "fallback",
                                             "PDF", 900),
                       "PDF 导出已就绪（900 字节）。")
        // A missing key falls back to the English template with the same
        // substitution semantics.
        XCTAssertEqual(FloeCADStrings.format("test.missing", "Missing %lld", 7), "Missing 7")
    }
}
