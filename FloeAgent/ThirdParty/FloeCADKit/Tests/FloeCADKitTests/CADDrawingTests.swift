//
//  CADDrawingTests.swift
//  FloeCADKitTests
//
//  Focused tests for `CADDrawingService`: page management, real orthographic
//  projection of the canonical 100×60×10 plate with an internal Ø10 through
//  hole, section loops, dimensions, vector PDF/SVG/DXF export, staleness and
//  persistence.
//
//  These tests exercise geometry, not pixels: every assertion reads projected
//  coordinates, loop areas or DXF entities. The exact 1e-6 diameter check runs
//  on the section loop (Double-precision kernel sampling). The front view is
//  checked at 1e-4: its circle comes from the Float32 render tessellation and
//  is corrected to the analytic radius only when `OCCTKernel.faceInfo` exposes
//  the cylinder signature.
//

import XCTest
import Foundation
import simd
@testable import FloeCAD

final class CADDrawingTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeCADDrawing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - Fixture helpers

    private func makeDocument(_ name: String) async throws -> FloeCADDocument {
        let url = workDir.appendingPathComponent("\(name).floecad")
        return try await FloeCADDocument.create(at: url, name: name)
    }

    private func run(_ document: FloeCADDocument, _ json: String,
                     file: StaticString = #filePath, line: UInt = #line) -> [String: Any] {
        let outcome = document.executeJSON(Data(json.utf8))
        XCTAssertTrue(outcome.isOK,
                      "command failed (\(outcome.status)) \(outcome.errorCode ?? ""): "
                        + "\(outcome.message ?? "") — \(json)",
                      file: file, line: line)
        return (try? JSONSerialization.jsonObject(with: outcome.payload)) as? [String: Any] ?? [:]
    }

    private func firstBodyID(_ response: [String: Any]) -> String? {
        if let produced = (response["producedBodyIDs"] as? [String])?.first { return produced }
        return (response["changedBodyIDs"] as? [String])?.first
    }

    /// 100×60×10 mm plate with an internal Ø10 through-hole, built through
    /// the same typed command vocabulary the AI tool uses.
    private func makePlateWithHole(_ document: FloeCADDocument) throws -> String {
        let plateSketch = try XCTUnwrap(
            run(document, #"{"op":"sketch.create","args":{"name":"Plate"}}"#)["sketchID"] as? String)
        _ = run(document, """
        {"op":"sketch.addEntities","args":{"sketchID":"\(plateSketch)",
         "entities":[{"kind":"rect","min":[0,0],"max":[100,60]}]}}
        """)
        let plateExtrude = run(document, """
        {"op":"feature.extrude","args":{"sketchID":"\(plateSketch)","seedPoint":[50,30],
         "distance":10}}
        """)
        let plateBodyID = try XCTUnwrap(firstBodyID(plateExtrude))

        let holeSketch = try XCTUnwrap(
            run(document, #"{"op":"sketch.create","args":{"name":"Hole"}}"#)["sketchID"] as? String)
        _ = run(document, """
        {"op":"sketch.addEntities","args":{"sketchID":"\(holeSketch)",
         "entities":[{"kind":"circle","center":[50,30],"radius":5}]}}
        """)
        _ = run(document, """
        {"op":"feature.extrude","args":{"sketchID":"\(holeSketch)","seedPoint":[50,30],
         "distance":40,"symmetric":true,"boolean":"subtract","booleanTargets":["\(plateBodyID)"]}}
        """)
        let snapshot = try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: document.snapshotJSON())) as? [String: Any])
        let bodies = try XCTUnwrap(snapshot["bodies"] as? [[String: Any]])
        return try XCTUnwrap(bodies.first?["id"] as? String, "post-cut snapshot: \(bodies)")
    }

    /// Creates the standard sheet and returns the front page id.
    private func addStandardSheet(_ service: CADDrawingService,
                                  bodyID: String) throws -> String {
        let reply = service.handle(action: "standardSheet",
                                   args: ["bodyID": bodyID, "title": "Plate"])
        XCTAssertEqual(reply["ok"] as? Bool, true, reply["message"] as? String ?? "")
        XCTAssertEqual(reply["pageCount"] as? Int, 4, "a standard sheet is four pages")
        let pages = try XCTUnwrap(reply["pages"] as? [[String: Any]])
        let front = try XCTUnwrap(pages.first { $0["kind"] as? String == "front" })
        return try XCTUnwrap(front["id"] as? String)
    }

    private func projectedBounds(_ entities: [[String: Any]])
        -> (width: Double, height: Double)? {
        var minX = Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude
        var any = false
        func include(_ x: Double, _ y: Double) {
            any = true
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
        }
        for entity in entities {
            switch entity["kind"] as? String {
            case "line":
                if let a = entity["a"] as? [Double], a.count >= 2 { include(a[0], a[1]) }
                if let b = entity["b"] as? [Double], b.count >= 2 { include(b[0], b[1]) }
            case "circle", "arc":
                if let center = entity["center"] as? [Double], center.count >= 2,
                   let radius = entity["radius"] as? Double {
                    include(center[0] - radius, center[1] - radius)
                    include(center[0] + radius, center[1] + radius)
                }
            case "polyline":
                for point in (entity["points"] as? [[Double]]) ?? [] where point.count >= 2 {
                    include(point[0], point[1])
                }
            default:
                break
            }
        }
        guard any else { return nil }
        return (maxX - minX, maxY - minY)
    }

    private func dimension(_ dimensions: [[String: Any]], kind: String,
                           axis: String? = nil) -> [String: Any]? {
        dimensions.first {
            ($0["kind"] as? String) == kind
                && (axis == nil || ($0["axis"] as? String) == axis)
        }
    }

    // MARK: - 1. Standard sheet

    func testStandardSheetCreatesFourProjectablePages() async throws {
        let document = try await makeDocument("StandardSheet")
        let bodyID = try makePlateWithHole(document)
        let service = CADDrawingService(document: document)

        let frontID = try addStandardSheet(service, bodyID: bodyID)
        let pagesReply = service.handle(action: "pages", args: [:])
        XCTAssertEqual(pagesReply["ok"] as? Bool, true, pagesReply["message"] as? String ?? "")
        XCTAssertEqual(pagesReply["count"] as? Int, 4)
        let pages = try XCTUnwrap(pagesReply["pages"] as? [[String: Any]])

        for page in pages {
            let id = try XCTUnwrap(page["id"] as? String)
            let projection = service.handle(action: "project", args: ["pageID": id])
            XCTAssertEqual(projection["ok"] as? Bool, true,
                           projection["message"] as? String ?? "")
            let entities = projection["entities"] as? [[String: Any]] ?? []
            XCTAssertFalse(entities.isEmpty,
                           "page \(page["kind"] ?? "?") projected no geometry")
            let outlines = entities.filter { ($0["layer"] as? String) == "outline" }
            XCTAssertGreaterThan(outlines.count, 0,
                                 "every standard view needs a silhouette outline")
        }

        // The front view of the plate is 100 × 60 mm at scale 1.
        let front = service.handle(action: "project", args: ["pageID": frontID])
        let bounds = try XCTUnwrap(projectedBounds(front["entities"] as? [[String: Any]] ?? []))
        XCTAssertEqual(bounds.width, 100, accuracy: 1e-4)
        XCTAssertEqual(bounds.height, 60, accuracy: 1e-4)
        document.close()
    }

    // MARK: - 2. Section through the hole

    func testSectionThroughHoleProducesClosedLoops() async throws {
        let document = try await makeDocument("Section")
        let bodyID = try makePlateWithHole(document)
        let service = CADDrawingService(document: document)

        let add = service.handle(action: "addPage", args: [
            "kind": "section",
            "bodyIDs": [bodyID],
            "title": "Section A-A",
            "sectionOrigin": [50.0, 5.0, -30.0],
            "sectionNormal": [0.0, 1.0, 0.0],
        ])
        XCTAssertEqual(add["ok"] as? Bool, true, add["message"] as? String ?? "")
        let page = try XCTUnwrap(add["page"] as? [String: Any])
        let pageID = try XCTUnwrap(page["id"] as? String)

        let projection = service.handle(action: "project", args: ["pageID": pageID])
        XCTAssertEqual(projection["ok"] as? Bool, true,
                       projection["message"] as? String ?? "")
        let entities = projection["entities"] as? [[String: Any]] ?? []
        let loops = entities.filter {
            ($0["kind"] as? String) == "polyline" && ($0["closed"] as? Bool) == true
        }
        XCTAssertGreaterThanOrEqual(loops.count, 2,
                                    "the plate section and the hole must both close: \(entities)")
        let areas = loops.compactMap { ($0["area"] as? Double).map { abs($0) } }
        XCTAssertFalse(areas.isEmpty)
        XCTAssertTrue(areas.contains { abs($0 - 6000) <= 2 },
                      "the 100×60 plate section needs area 6000 mm²: \(areas)")
        XCTAssertTrue(areas.contains { abs($0 - Double.pi * 25) <= 0.5 },
                      "the Ø10 hole section needs area ≈ 78.54 mm²: \(areas)")
        document.close()
    }

    // MARK: - 3. Dimensions

    func testDimensionsReadPlateAndHole() async throws {
        let document = try await makeDocument("Dimensions")
        let bodyID = try makePlateWithHole(document)
        let service = CADDrawingService(document: document)
        let frontID = try addStandardSheet(service, bodyID: bodyID)

        // The front view projects the hole as a real circle entity.
        let front = service.handle(action: "project", args: ["pageID": frontID])
        let frontEntities = front["entities"] as? [[String: Any]] ?? []
        XCTAssertTrue(frontEntities.contains { ($0["kind"] as? String) == "circle" },
                      "the front view must recognize the hole as a circle: \(frontEntities)")

        let frontDimsReply = service.handle(action: "dimensions", args: ["pageID": frontID])
        XCTAssertEqual(frontDimsReply["ok"] as? Bool, true,
                       frontDimsReply["message"] as? String ?? "")
        let frontDims = try XCTUnwrap(frontDimsReply["dimensions"] as? [[String: Any]])
        let width = try XCTUnwrap(dimension(frontDims, kind: "linear", axis: "x"))
        XCTAssertEqual(try XCTUnwrap(width["value"] as? Double), 100, accuracy: 1e-6)
        let height = try XCTUnwrap(dimension(frontDims, kind: "linear", axis: "y"))
        XCTAssertEqual(try XCTUnwrap(height["value"] as? Double), 60, accuracy: 1e-6)
        let frontDiameter = frontDims.first {
            ($0["kind"] as? String) == "diameter"
                && abs(($0["value"] as? Double ?? -1) - 10) <= 1e-4
        }
        XCTAssertNotNil(frontDiameter,
                        "the front view hole must dimension as Ø10: \(frontDims)")

        // A section perpendicular to the hole axis: the same diameter from the
        // section loop (Double-precision kernel sampling).
        let add = service.handle(action: "addPage", args: [
            "kind": "section",
            "bodyIDs": [bodyID],
            "sectionOrigin": [50.0, 5.0, -30.0],
            "sectionNormal": [0.0, 1.0, 0.0],
        ])
        let sectionPage = try XCTUnwrap(add["page"] as? [String: Any])
        let sectionID = try XCTUnwrap(sectionPage["id"] as? String)
        let sectionDimsReply = service.handle(action: "dimensions", args: ["pageID": sectionID])
        let sectionDims = try XCTUnwrap(sectionDimsReply["dimensions"] as? [[String: Any]])
        let sectionDiameter = sectionDims.first {
            ($0["kind"] as? String) == "diameter"
                && abs(($0["value"] as? Double ?? -1) - 10) <= 1e-6
        }
        XCTAssertNotNil(sectionDiameter,
                        "the section hole must dimension as Ø10 within 1e-6: \(sectionDims)")
        document.close()
    }

    // MARK: - 4. Scale

    func testScaleHalvesProjectedExtents() async throws {
        let document = try await makeDocument("Scale")
        let bodyID = try makePlateWithHole(document)
        let service = CADDrawingService(document: document)
        let frontID = try addStandardSheet(service, bodyID: bodyID)

        let update = service.handle(action: "updatePage",
                                    args: ["pageID": frontID, "scale": 0.5])
        XCTAssertEqual(update["ok"] as? Bool, true, update["message"] as? String ?? "")
        XCTAssertEqual((update["page"] as? [String: Any])?["scale"] as? Double, 0.5)

        let front = service.handle(action: "project", args: ["pageID": frontID])
        let bounds = try XCTUnwrap(projectedBounds(front["entities"] as? [[String: Any]] ?? []))
        XCTAssertEqual(bounds.width, 50, accuracy: 1e-4)
        XCTAssertEqual(bounds.height, 30, accuracy: 1e-4)

        // Dimensions keep reporting the true model size (100 mm).
        let dimsReply = service.handle(action: "dimensions", args: ["pageID": frontID])
        let dims = try XCTUnwrap(dimsReply["dimensions"] as? [[String: Any]])
        let width = try XCTUnwrap(dimension(dims, kind: "linear", axis: "x"))
        XCTAssertEqual(try XCTUnwrap(width["value"] as? Double), 100, accuracy: 1e-6)
        document.close()
    }

    // MARK: - 5. Vector exports

    func testVectorExportsCarryRealGeometry() async throws {
        let document = try await makeDocument("Exports")
        let bodyID = try makePlateWithHole(document)
        let service = CADDrawingService(document: document)
        let frontID = try addStandardSheet(service, bodyID: bodyID)
        _ = service.handle(action: "updatePage", args: [
            "pageID": frontID, "showDimensions": true, "showCenterlines": true,
        ])
        let frontUUID = try XCTUnwrap(UUID(uuidString: frontID))

        // PDF: real vector PDF, not an image.
        let pdf = try service.exportData(pageID: frontUUID, format: "pdf")
        XCTAssertGreaterThan(pdf.count, 1024)
        XCTAssertEqual(String(data: Data(pdf.prefix(5)), encoding: .ascii), "%PDF-")

        // SVG: mm units and the 100 mm front geometry in real line elements.
        let svg = try service.exportData(pageID: frontUUID, format: "svg")
        let svgText = try XCTUnwrap(String(data: svg, encoding: .utf8))
        XCTAssertTrue(svgText.contains("<svg"))
        XCTAssertTrue(svgText.contains("mm"))
        let geometryGroup = try XCTUnwrap(svgGroup(svgText, id: "GEOMETRY"),
                                          "SVG must carry a GEOMETRY group")
        XCTAssertTrue(geometryGroup.contains("<line"), "real line elements, not pixels")
        XCTAssertTrue(geometryGroup.contains("<circle"),
                      "the hole must export as a circle element")
        let xValues = svgAttributeValues(geometryGroup, attribute: "x1")
            + svgAttributeValues(geometryGroup, attribute: "x2")
        let centers = svgAttributeValues(geometryGroup, attribute: "cx")
        let radii = svgAttributeValues(geometryGroup, attribute: "r")
        var xExtents: [Double] = xValues
        if let minimumCenter = centers.min(), let maximumCenter = centers.max(),
           let radius = radii.max() {
            xExtents.append(minimumCenter - radius)
            xExtents.append(maximumCenter + radius)
        }
        let svgWidth = try XCTUnwrap(xExtents.max()) - (try XCTUnwrap(xExtents.min()))
        XCTAssertEqual(svgWidth, 100, accuracy: 1e-3,
                       "the SVG must carry the 100 mm plate geometry")

        // DXF: R12 with mm units, real layers, and round-trip entity counts.
        let dxf = try service.exportData(pageID: frontUUID, format: "dxf")
        let dxfText = try XCTUnwrap(String(data: dxf, encoding: .utf8))
        XCTAssertTrue(dxfText.contains("$INSUNITS"))
        XCTAssertTrue(dxfText.contains("AC1009"))
        XCTAssertTrue(dxfText.contains("GEOMETRY"))
        XCTAssertTrue(dxfText.contains("DIMENSIONS"))
        XCTAssertTrue(dxfText.contains("CENTERLINES"))
        XCTAssertTrue(dxfText.contains("TITLE"))
        XCTAssertTrue(dxfText.contains("0\nLINE\n"))
        XCTAssertTrue(dxfText.contains("0\nCIRCLE\n"))
        XCTAssertTrue(dxfText.contains("0\nTEXT\n"))

        let parsed = DXFKit.importDXF(dxf)
        XCTAssertGreaterThan(parsed.count, 0, "the DXF must parse back")
        let circleMarkers = dxfText.components(separatedBy: "0\nCIRCLE").count - 1
        let arcMarkers = dxfText.components(separatedBy: "0\nARC").count - 1
        let lineMarkers = dxfText.components(separatedBy: "0\nLINE").count - 1
        let parsedCircles = parsed.filter { if case .circle = $0 { return true } else { return false } }.count
        let parsedArcs = parsed.filter { if case .arc = $0 { return true } else { return false } }.count
        let parsedLines = parsed.filter { if case .line = $0 { return true } else { return false } }.count
        XCTAssertEqual(parsedCircles, circleMarkers,
                       "every CIRCLE entity must round-trip")
        XCTAssertEqual(parsedArcs, arcMarkers, "every ARC entity must round-trip")
        XCTAssertGreaterThanOrEqual(parsedLines, lineMarkers,
                                    "LINE entities round-trip; polylines add segments")

        // The action wrapper returns the same bytes with identity metadata.
        let reply = service.handle(action: "export",
                                   args: ["pageID": frontID, "format": "dxf"])
        XCTAssertEqual(reply["ok"] as? Bool, true, reply["message"] as? String ?? "")
        XCTAssertEqual(reply["noRasterization"] as? Bool, true)
        XCTAssertEqual(reply["byteCount"] as? Int, dxf.count)
        XCTAssertEqual((reply["sha256"] as? String)?.count, 64)
        XCTAssertEqual((reply["base64"] as? String).flatMap { Data(base64Encoded: $0) }, dxf)
        document.close()
    }

    // MARK: - 6. Staleness

    func testPagesReportStaleAfterBodyEdit() async throws {
        let document = try await makeDocument("Stale")
        let bodyID = try makePlateWithHole(document)
        let service = CADDrawingService(document: document)
        let frontID = try addStandardSheet(service, bodyID: bodyID)

        _ = service.handle(action: "project", args: ["pageID": frontID])
        var pages = try XCTUnwrap(
            service.handle(action: "pages", args: [:])["pages"] as? [[String: Any]])
        var front = try XCTUnwrap(pages.first { ($0["id"] as? String) == frontID })
        XCTAssertEqual(front["stale"] as? Bool, false,
                       "a freshly projected page is not stale")
        let recorded = try XCTUnwrap(front["modelRevision"] as? UInt64)

        // Edit the body in place (same id; the replacement re-mints meshRevision).
        let live = try XCTUnwrap(document.session.document.bodies.first {
            $0.id.raw.uuidString == bodyID
        })
        var edited = live
        edited.transform.translation.y += 1
        document.session.perform(ReplaceBodyCommand(title: "Lift plate",
                                                    before: live, after: edited))

        pages = try XCTUnwrap(
            service.handle(action: "pages", args: [:])["pages"] as? [[String: Any]])
        front = try XCTUnwrap(pages.first { ($0["id"] as? String) == frontID })
        XCTAssertEqual(front["stale"] as? Bool, true,
                       "a body edit must stale the recorded page revision")
        let liveRevision = try XCTUnwrap(front["liveRevision"] as? UInt64)
        XCTAssertNotEqual(liveRevision, recorded)

        // Re-projecting re-pins the page to the live revision.
        _ = service.handle(action: "project", args: ["pageID": frontID])
        pages = try XCTUnwrap(
            service.handle(action: "pages", args: [:])["pages"] as? [[String: Any]])
        front = try XCTUnwrap(pages.first { ($0["id"] as? String) == frontID })
        XCTAssertEqual(front["stale"] as? Bool, false)
        document.close()
    }

    // MARK: - 7. Persistence

    func testDrawingPersistsAcrossSaveAndReopen() async throws {
        let document = try await makeDocument("Persistence")
        let bodyID = try makePlateWithHole(document)
        let service = CADDrawingService(document: document)
        let frontID = try addStandardSheet(service, bodyID: bodyID)
        let frontUUID = try XCTUnwrap(UUID(uuidString: frontID))
        let before = service.handle(action: "project", args: ["pageID": frontID])
        let beforeCount = (before["entities"] as? [[String: Any]])?.count ?? 0
        let beforeBounds = try XCTUnwrap(
            projectedBounds(before["entities"] as? [[String: Any]] ?? []))

        let save = await document.save()
        XCTAssertTrue(save.succeeded, save.error ?? "")
        document.close()

        let reopened = try await FloeCADDocument.open(at: document.url)
        let reopenedService = CADDrawingService(document: reopened)
        let pagesReply = reopenedService.handle(action: "pages", args: [:])
        XCTAssertEqual(pagesReply["ok"] as? Bool, true)
        XCTAssertEqual(pagesReply["count"] as? Int, 4, "pages must survive save/reopen")
        let pages = try XCTUnwrap(pagesReply["pages"] as? [[String: Any]])
        let front = try XCTUnwrap(pages.first { ($0["id"] as? String) == frontID })
        XCTAssertNotNil(front["modelRevision"], "the pinned revision must be persisted")

        let after = reopenedService.pageGeometry(pageID: frontUUID)
        XCTAssertEqual(after["ok"] as? Bool, true, after["message"] as? String ?? "")
        XCTAssertEqual((after["entities"] as? [[String: Any]])?.count, beforeCount)
        let afterBounds = try XCTUnwrap(
            projectedBounds(after["entities"] as? [[String: Any]] ?? []))
        XCTAssertEqual(afterBounds.width, beforeBounds.width, accuracy: 1e-6)
        XCTAssertEqual(afterBounds.height, beforeBounds.height, accuracy: 1e-6)

        // Re-projecting once on the reopened document re-pins the revision
        // (load re-mints meshRevision — documented in the service header).
        _ = reopenedService.handle(action: "project", args: ["pageID": frontID])
        let pagesAfter = try XCTUnwrap(
            reopenedService.handle(action: "pages", args: [:])["pages"] as? [[String: Any]])
        let refreshed = try XCTUnwrap(pagesAfter.first { ($0["id"] as? String) == frontID })
        XCTAssertEqual(refreshed["stale"] as? Bool, false)
        reopened.close()
    }

    // MARK: - 8. Validation and corrupt blobs

    func testValidationAndCorruptBlobAreRefusedSafely() async throws {
        let document = try await makeDocument("Validation")
        let bodyID = try makePlateWithHole(document)
        let service = CADDrawingService(document: document)

        let unknownBody = service.handle(action: "addPage", args: [
            "kind": "front", "bodyIDs": [UUID().uuidString],
        ])
        XCTAssertEqual(unknownBody["ok"] as? Bool, false)
        XCTAssertEqual(unknownBody["error"] as? String, "unknown_body")

        let badScale = service.handle(action: "addPage", args: [
            "kind": "front", "bodyIDs": [bodyID], "scale": 0.0,
        ])
        XCTAssertEqual(badScale["error"] as? String, "bad_scale")

        let missingPlane = service.handle(action: "addPage", args: [
            "kind": "section", "bodyIDs": [bodyID],
        ])
        XCTAssertEqual(missingPlane["error"] as? String, "missing_section_plane")

        let missingDetail = service.handle(action: "addPage", args: [
            "kind": "detail", "bodyIDs": [bodyID],
        ])
        XCTAssertEqual(missingDetail["error"] as? String, "missing_detail_size")

        let unknownAction = service.handle(action: "explode", args: [:])
        XCTAssertEqual(unknownAction["error"] as? String, "unknown_action")

        // A corrupt stored blob is refused (and left untouched), never a crash.
        document.session.perform(SetDrawingsDataCommand(
            before: nil, after: Data("this is not a drawing set".utf8)))
        let corrupt = service.handle(action: "pages", args: [:])
        XCTAssertEqual(corrupt["ok"] as? Bool, false)
        XCTAssertEqual(corrupt["error"] as? String, "corrupt_drawings")
        let corruptProject = service.handle(action: "project", args: [
            "pageID": UUID().uuidString,
        ])
        XCTAssertEqual(corruptProject["error"] as? String, "corrupt_drawings")

        let pageUUID = UUID()
        XCTAssertThrowsError(try service.exportData(pageID: pageUUID, format: "png")) { error in
            guard let cadError = error as? CADDocumentError else {
                return XCTFail("expected CADDocumentError, got \(error)")
            }
            XCTAssertEqual(cadError.code, "corrupt_drawings")
        }
        document.close()
    }

    // MARK: - SVG helpers

    private func svgGroup(_ text: String, id: String) -> String? {
        guard let start = text.range(of: "<g id=\"\(id)\"") else { return nil }
        guard let end = text.range(of: "</g>", range: start.upperBound..<text.endIndex) else {
            return nil
        }
        return String(text[start.lowerBound..<end.lowerBound])
    }

    private func svgAttributeValues(_ fragment: String, attribute: String) -> [Double] {
        let marker = attribute + "=\""
        var values: [Double] = []
        var searchStart = fragment.startIndex
        while let range = fragment.range(of: marker, range: searchStart..<fragment.endIndex) {
            let valueStart = range.upperBound
            guard let valueEnd = fragment.range(of: "\"",
                                                range: valueStart..<fragment.endIndex) else {
                break
            }
            if let value = Double(fragment[valueStart..<valueEnd.lowerBound]) {
                values.append(value)
            }
            searchStart = valueEnd.upperBound
        }
        return values
    }
}

