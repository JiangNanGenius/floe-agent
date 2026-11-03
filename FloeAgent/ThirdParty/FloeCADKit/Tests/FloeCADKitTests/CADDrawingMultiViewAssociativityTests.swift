//
//  CADDrawingMultiViewAssociativityTests.swift
//  FloeCADKitTests
//
//  E11/E13/E15 focused behavior tests through the REAL document + services:
//  one shared A3 page with front/top/side/section views, editable per-view
//  scale and projection alignment, model-revision refresh of every view,
//  view-scoped annotations, a mixed B-rep/mesh section that must block vector
//  output instead of pretending completeness, and a linked Ø diameter bound to
//  a stable kernel cylindrical face (Ø10→Ø8; dangling after the hole is
//  deleted; undo/redo/save/reopen; the earlier hole keeps its captured
//  authoring identity when several features exist, and genuinely ambiguous
//  authorship is reported rather than guessed).
//
//  The historical cases below cover E11/E13/E15. The appended E12/E14
//  component tests do not claim independent-CAD or presented-UI acceptance.
//

import XCTest
import Foundation
import simd
@testable import FloeCAD

@MainActor
final class CADDrawingMultiViewAssociativityTests: XCTestCase {
    private var workDir: URL!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeCADDrawingMV-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - Fixtures

    private func makeDocument(_ name: String) async throws -> FloeCADDocument {
        try await FloeCADDocument.create(
            at: workDir.appendingPathComponent("\(name)-\(UUID().uuidString).floecad"),
            name: name)
    }

    private func run(_ document: FloeCADDocument, _ json: String,
                     file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let outcome = document.executeJSON(Data(json.utf8))
        XCTAssertTrue(outcome.isOK,
                      "command failed (\(outcome.status)) \(outcome.errorCode ?? ""): "
                        + "\(outcome.message ?? "") — \(json)",
                      file: file, line: line)
        return try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: outcome.payload)) as? [String: Any],
            "the command reply was not a JSON object", file: file, line: line)
    }

    private func queryRows(_ document: FloeCADDocument, _ scope: String,
                           file: StaticString = #filePath, line: UInt = #line) throws -> [[String: Any]] {
        let outcome = document.nativeQueryJSON(["scope": scope])
        XCTAssertTrue(outcome.isOK,
                      "query \(scope) failed: \(outcome.errorCode ?? "") \(outcome.message ?? "")",
                      file: file, line: line)
        let object = try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: outcome.payload)) as? [String: Any],
            file: file, line: line)
        return try XCTUnwrap(object["rows"] as? [[String: Any]], file: file, line: line)
    }

    private func firstBodyID(_ document: FloeCADDocument) throws -> String {
        let rows = try queryRows(document, "bodies")
        return try XCTUnwrap(rows.first?["id"] as? String)
    }

    private func addSketch(_ document: FloeCADDocument, name: String,
                           entities: String) throws -> (sketchID: String, entityIDs: [String]) {
        let created = try run(document, #"{"op":"sketch.create","args":{"name":"\#(name)"}}"#)
        let sketchID = try XCTUnwrap(created["sketchID"] as? String)
        _ = try run(document, #"{"op":"sketch.addEntities","args":{"sketchID":"\#(sketchID)","entities":\#(entities)}}"#)
        let sketches = try queryRows(document, "sketches")
        let row = try XCTUnwrap(sketches.first { ($0["id"] as? String) == sketchID })
        let entities = try XCTUnwrap(row["entityRows"] as? [[String: Any]])
        return (sketchID, entities.compactMap { $0["id"] as? String })
    }

    private func featureID(_ document: FloeCADDocument, sketchID: String) throws -> String {
        let rows = try queryRows(document, "features")
        let row = try XCTUnwrap(rows.first {
            (($0["referencedSketches"] as? [String]) ?? []).contains(sketchID)
        })
        return try XCTUnwrap(row["id"] as? String)
    }

    private func makePlateWithHole(_ document: FloeCADDocument) throws
        -> (bodyID: String, plateSketch: String, plateEntity: String,
            holeSketch: String, holeEntity: String, holeFeature: String) {
        let plate = try addSketch(
            document, name: "Plate",
            entities: #"[{"kind":"rect","min":[0,0],"max":[100,60]}]"#)
        let plateExtrude = try run(document, """
        {"op":"feature.extrude","args":{"sketchID":"\(plate.sketchID)","seedPoint":[50,30],
         "distance":10}}
        """)
        let plateBodyID = try XCTUnwrap(
            (plateExtrude["producedBodyIDs"] as? [String])?.first
                ?? (plateExtrude["changedBodyIDs"] as? [String])?.first)
        let hole = try addSketch(
            document, name: "Hole",
            entities: #"[{"kind":"circle","center":[50,30],"radius":5}]"#)
        _ = try run(document, """
        {"op":"feature.extrude","args":{"sketchID":"\(hole.sketchID)","seedPoint":[50,30],
         "distance":40,"symmetric":true,"boolean":"subtract","booleanTargets":["\(plateBodyID)"]}}
        """)
        let holeFeature = try featureID(document, sketchID: hole.sketchID)
        let bodyID = try firstBodyID(document)
        return (bodyID, plate.sketchID, plate.entityIDs[0],
                hole.sketchID, hole.entityIDs[0], holeFeature)
    }

    private func projectedBounds(_ geometry: [String: Any],
                                 viewID: String? = nil) -> (min: SIMD2<Double>, max: SIMD2<Double>)? {
        let rows = geometry["views"] as? [[String: Any]] ?? []
        let row: [String: Any]?
        if let viewID {
            row = rows.first { (($0["id"] as? String) == viewID) }
        } else {
            row = nil
        }
        if let bounds = row?["bounds"] as? [[Double]], bounds.count == 2,
           bounds[0].count == 2, bounds[1].count == 2 {
            return (SIMD2(bounds[0][0], bounds[0][1]), SIMD2(bounds[1][0], bounds[1][1]))
        }
        let entities = geometry["entities"] as? [[String: Any]] ?? []
        var minPoint = SIMD2<Double>(.greatestFiniteMagnitude, .greatestFiniteMagnitude)
        var maxPoint = SIMD2<Double>(-.greatestFiniteMagnitude, -.greatestFiniteMagnitude)
        func include(_ p: SIMD2<Double>) {
            minPoint = simd_min(minPoint, p)
            maxPoint = simd_max(maxPoint, p)
        }
        for entity in entities {
            switch entity["kind"] as? String {
            case "line":
                if let a = entity["a"] as? [Double], a.count >= 2 { include(SIMD2(a[0], a[1])) }
                if let b = entity["b"] as? [Double], b.count >= 2 { include(SIMD2(b[0], b[1])) }
            case "circle", "arc":
                if let c = entity["center"] as? [Double], c.count >= 2,
                   let r = entity["radius"] as? Double {
                    include(SIMD2(c[0] - r, c[1] - r))
                    include(SIMD2(c[0] + r, c[1] + r))
                }
            case "polyline":
                for p in (entity["points"] as? [[Double]]) ?? [] where p.count >= 2 {
                    include(SIMD2(p[0], p[1]))
                }
            default:
                break
            }
        }
        guard minPoint.x.isFinite, minPoint.x <= maxPoint.x else { return nil }
        return (minPoint, maxPoint)
    }

    private func dimensionRow(_ geometry: [String: Any], id: String) -> [String: Any]? {
        (geometry["manualDimensions"] as? [[String: Any]])?.first { ($0["id"] as? String) == id }
    }

    private func candidate(for viewID: String, pageID: String,
                           service: CADDrawingService) throws -> [String: Any] {
        let reply = service.handle(action: "dimensionCandidates",
                                   args: ["pageID": pageID, "viewID": viewID])
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        let candidates = try XCTUnwrap(reply["candidates"] as? [[String: Any]])
        return try XCTUnwrap(candidates.first { row in
            abs((row["radiusMM"] as? Double ?? -1) - 5) <= 1e-4
        }, "a Ø10 hole candidate must be present: \(candidates)")
    }

    // MARK: - Legacy compatibility + v4 round-trip

    func testLegacyPageOpensAndV4SheetRoundTrips() throws {
        let legacy = Data("""
        {"schemaVersion":1,"pages":[{"id":"33333333-3333-3333-3333-333333333333",
         "name":"Front","kind":"front"}]}
        """.utf8)
        let old = try CADDrawingSet.decode(from: legacy)
        XCTAssertEqual(old.schemaVersion, 1)
        XCTAssertNil(old.pages[0].sheetViews)
        XCTAssertEqual(old.pages[0].effectiveSheetViews.count, 1)
        XCTAssertEqual(old.pages[0].effectiveSheetViews[0].scale, 1)

        let bodyID = UUID()
        var set = CADDrawingSet.multiViewSheet(
            bodyIDs: [bodyID], title: "V4",
            sectionOrigin: SIMD3(0, 0, 0), sectionNormal: SIMD3(0, 1, 0))
        let pageID = set.pages[0].id
        let viewID = set.pages[0].effectiveSheetViews[1].id
        let feature = CADDrawingFeatureReference(
            bodyID: bodyID,
            anchor: CADDrawingFeatureAnchor(centroid: SIMD3(0, 0, 0),
                                            direction: SIMD3(0, 1, 0),
                                            radiusMM: 5))
        set.pages[0].manualDimensions = [CADDrawingManualDimension(
            kind: .diameter, drawingPoints: [SIMD2(0, 0), SIMD2(5, 0)],
            value: 10, textPosition: SIMD2(6, 6), viewID: viewID, feature: feature)]
        let encoded = try set.encoded()
        let decoded = try CADDrawingSet.decode(from: encoded)
        XCTAssertEqual(decoded.schemaVersion, CADDrawingSet.currentSchemaVersion)
        XCTAssertEqual(decoded.pages[0].id, pageID)
        XCTAssertEqual(decoded.pages[0].sheetViews?.count, 4)
        XCTAssertEqual(decoded.pages[0].effectiveSheetViews[1].id, viewID)
        XCTAssertEqual(decoded.pages[0].effectiveSheetViews[1].alignment.placement,
                       CADDrawingViewPlacement.above)
        XCTAssertEqual(decoded.pages[0].manualDimensions[0].viewID, viewID)
        XCTAssertEqual(try XCTUnwrap(decoded.pages[0].manualDimensions[0].feature?.bodyID),
                       bodyID)
        XCTAssertEqual(try XCTUnwrap(
            decoded.pages[0].manualDimensions[0].feature?.anchor.radiusMM), 5.0)
        XCTAssertEqual(try XCTUnwrap(
            decoded.pages[0].manualDimensions[0].feature?.anchor.direction),
                       SIMD3<Double>(0, 1, 0))
    }

    // MARK: - E11: same-sheet views, editable scale/alignment, refresh

    func testMultiViewSheetLayoutScaleAlignmentAndModelRefresh() async throws {
        let document = try await makeDocument("E11")
        let fixture = try makePlateWithHole(document)
        let service = CADDrawingService(document: document)

        let created = service.handle(action: "multiViewSheet", args: [
            "bodyID": fixture.bodyID,
            "title": "E11 sheet",
            "paper": "a3",
            "sectionOrigin": [50.0, 5.0, 30.0],
            "sectionNormal": [0.0, 1.0, 0.0],
        ])
        XCTAssertEqual(created["ok"] as? Bool, true, "\(created)")
        let page = try XCTUnwrap(created["page"] as? [String: Any])
        let pageID = try XCTUnwrap(page["id"] as? String)
        XCTAssertEqual(page["viewCount"] as? Int, 4)
        XCTAssertEqual(page["isMultiView"] as? Bool, true)
        let viewRows = try XCTUnwrap(page["views"] as? [[String: Any]])
        XCTAssertEqual(viewRows.compactMap { $0["kind"] as? String },
                       ["front", "top", "side", "section"])
        XCTAssertEqual(page["paper"] as? String, "a3")

        var geometry = service.pageGeometry(pageID: UUID(uuidString: pageID)!)
        XCTAssertEqual(geometry["ok"] as? Bool, true, "\(geometry)")
        XCTAssertEqual((geometry["views"] as? [[String: Any]])?.count, 4)
        XCTAssertEqual(geometry["sectionComplete"] as? Bool, true)
        XCTAssertEqual(geometry["outputBlocked"] as? Bool, false)
        for row in (geometry["views"] as? [[String: Any]]) ?? [] {
            XCTAssertGreaterThan(row["entityCount"] as? Int ?? 0, 0,
                                 "every view must project real geometry: \(row)")
        }

        let front = try XCTUnwrap(projectedBounds(geometry, viewID: viewRows[0]["id"] as? String))
        let top = try XCTUnwrap(projectedBounds(geometry, viewID: viewRows[1]["id"] as? String))
        let side = try XCTUnwrap(projectedBounds(geometry, viewID: viewRows[2]["id"] as? String))
        let section = try XCTUnwrap(projectedBounds(geometry, viewID: viewRows[3]["id"] as? String))
        XCTAssertGreaterThan(top.min.y, front.max.y, "Top must sit above Front")
        XCTAssertGreaterThan(side.min.x, front.max.x, "Side must sit right of Front")
        XCTAssertLessThan(section.max.y, front.min.y, "Section must sit below Front")
        XCTAssertEqual((front.min.x + front.max.x) / 2, (top.min.x + top.max.x) / 2,
                       accuracy: 1e-6, "Front/Top share a vertical projection line")

        // Per-view scale is editable and only that view changes size.
        let topID = try XCTUnwrap(viewRows[1]["id"] as? String)
        let scaled = service.handle(action: "updateView", args: [
            "pageID": pageID, "viewID": topID, "scale": 0.5,
        ])
        XCTAssertEqual(scaled["ok"] as? Bool, true, "\(scaled)")
        geometry = service.pageGeometry(pageID: UUID(uuidString: pageID)!)
        let scaledTop = try XCTUnwrap(projectedBounds(geometry, viewID: topID))
        XCTAssertEqual(scaledTop.max.x - scaledTop.min.x,
                       (top.max.x - top.min.x) / 2, accuracy: 1e-6)
        let scaledFront = try XCTUnwrap(projectedBounds(geometry,
                                                        viewID: viewRows[0]["id"] as? String))
        XCTAssertEqual(scaledFront.max.x - scaledFront.min.x,
                       front.max.x - front.min.x, accuracy: 1e-6)

        // Projection alignment is editable: move Top below Front.
        let frontID = try XCTUnwrap(viewRows[0]["id"] as? String)
        let aligned = service.handle(action: "updateView", args: [
            "pageID": pageID, "viewID": topID,
            "alignmentPlacement": "below",
            "alignmentReferenceID": frontID,
            "gapMM": 10,
        ])
        XCTAssertEqual(aligned["ok"] as? Bool, true, "\(aligned)")
        geometry = service.pageGeometry(pageID: UUID(uuidString: pageID)!)
        let belowTop = try XCTUnwrap(projectedBounds(geometry, viewID: topID))
        let belowFront = try XCTUnwrap(projectedBounds(geometry, viewID: frontID))
        XCTAssertLessThan(belowTop.max.y, belowFront.min.y,
                          "the edited alignment must place Top below Front")

        // Change the plate width 100 -> 80 through the real parameter service.
        let parameters = CADParameterService(document: document)
        let edit = parameters.handle(action: "updateSketchEntity", args: [
            "sketch_id": fixture.plateSketch,
            "entity_id": fixture.plateEntity,
            "max": [80.0, 60.0],
        ])
        XCTAssertEqual(edit["ok"] as? Bool, true, "\(edit)")
        let stalePages = service.handle(action: "pages", args: [:])
        let staleRow = try XCTUnwrap(
            (stalePages["pages"] as? [[String: Any]])?.first { ($0["id"] as? String) == pageID })
        XCTAssertEqual(staleRow["stale"] as? Bool, true,
                       "a model edit must stale the whole shared sheet")

        geometry = service.handle(action: "project", args: ["pageID": pageID])
        XCTAssertEqual(geometry["ok"] as? Bool, true, "\(geometry)")
        let refreshedFront = try XCTUnwrap(projectedBounds(geometry, viewID: frontID))
        XCTAssertEqual(refreshedFront.max.x - refreshedFront.min.x, 80, accuracy: 1e-4,
                       "the Front view must refresh from the edited model")
        let refreshedSection = try XCTUnwrap(projectedBounds(geometry,
                                                             viewID: viewRows[3]["id"] as? String))
        XCTAssertFalse(refreshedSection.min.x.isNaN)
        let pagesAfter = service.handle(action: "pages", args: [:])
        let freshRow = try XCTUnwrap(
            (pagesAfter["pages"] as? [[String: Any]])?.first { ($0["id"] as? String) == pageID })
        XCTAssertEqual(freshRow["stale"] as? Bool, false,
                       "re-projecting refreshes every view's fingerprint")

        // Save/reopen keeps the same page and view identities.
        let save = await document.save()
        XCTAssertTrue(save.succeeded, save.error ?? "")
        document.close()
        let reopened = try await FloeCADDocument.open(at: document.url)
        let reopenedService = CADDrawingService(document: reopened)
        let reopenedPages = reopenedService.handle(action: "pages", args: [:])
        let reopenedRow = try XCTUnwrap(
            (reopenedPages["pages"] as? [[String: Any]])?.first)
        XCTAssertEqual(reopenedRow["id"] as? String, pageID)
        XCTAssertEqual(reopenedRow["viewCount"] as? Int, 4)
        let reopenedViewIDs = (reopenedRow["views"] as? [[String: Any]])?
            .compactMap { $0["id"] as? String }
        XCTAssertEqual(reopenedViewIDs, viewRows.compactMap { $0["id"] as? String })
        reopened.close()
    }

    // MARK: - View-scoped annotations follow their own view

    func testTextAnnotationStaysAttachedToItsView() async throws {
        let document = try await makeDocument("ViewAnnotation")
        let fixture = try makePlateWithHole(document)
        let service = CADDrawingService(document: document)
        let created = service.handle(action: "multiViewSheet", args: [
            "bodyID": fixture.bodyID, "title": "Views",
            "sectionOrigin": [50.0, 5.0, 30.0], "sectionNormal": [0.0, 1.0, 0.0],
        ])
        XCTAssertEqual(created["ok"] as? Bool, true, "\(created)")
        let page = try XCTUnwrap(created["page"] as? [String: Any])
        let pageID = try XCTUnwrap(page["id"] as? String)
        let section = try XCTUnwrap((page["views"] as? [[String: Any]])?
            .first { ($0["kind"] as? String) == "section" })
        let sectionID = try XCTUnwrap(section["id"] as? String)

        let added = service.handle(action: "addAnnotation", args: [
            "pageID": pageID, "viewID": sectionID,
            "text": "SECTION A-A", "position": [10.0, 10.0],
        ])
        XCTAssertEqual(added["ok"] as? Bool, true, "\(added)")
        let moved = service.handle(action: "updateView", args: [
            "pageID": pageID, "viewID": sectionID,
            "offset": [40.0, 60.0], "alignmentPlacement": "free",
        ])
        XCTAssertEqual(moved["ok"] as? Bool, true, "\(moved)")
        let geometry = service.handle(action: "project", args: ["pageID": pageID])
        let rows = try XCTUnwrap(geometry["annotations"] as? [[String: Any]])
        let row = try XCTUnwrap(rows.first { ($0["text"] as? String) == "SECTION A-A" })
        XCTAssertEqual(row["viewID"] as? String, sectionID)
        let position = try XCTUnwrap(row["position"] as? [Double])
        XCTAssertEqual(position[0], 50, accuracy: 1e-6)
        XCTAssertEqual(position[1], 70, accuracy: 1e-6)
        let local = try XCTUnwrap(row["localPosition"] as? [Double])
        XCTAssertEqual(local[0], 10, accuracy: 1e-6)
        XCTAssertEqual(local[1], 10, accuracy: 1e-6)
        document.close()
    }

    // MARK: - E15: linked diameter remeasure, dangling, undo/redo/reopen

    func testLinkedDiameterRemeasuresAndDangles() async throws {
        let document = try await makeDocument("E15")
        let fixture = try makePlateWithHole(document)
        let service = CADDrawingService(document: document)
        let created = service.handle(action: "multiViewSheet", args: [
            "bodyID": fixture.bodyID, "title": "E15",
            "sectionOrigin": [50.0, 5.0, 30.0], "sectionNormal": [0.0, 1.0, 0.0],
        ])
        XCTAssertEqual(created["ok"] as? Bool, true, "\(created)")
        let page = try XCTUnwrap(created["page"] as? [String: Any])
        let pageID = try XCTUnwrap(page["id"] as? String)
        let front = try XCTUnwrap((page["views"] as? [[String: Any]])?
            .first { ($0["kind"] as? String) == "front" })
        let frontID = try XCTUnwrap(front["id"] as? String)
        let candidate = try candidate(for: frontID, pageID: pageID, service: service)
        let reference = try XCTUnwrap(candidate["reference"] as? [String: Any])
        XCTAssertEqual(reference["sketchID"] as? String, fixture.holeSketch,
                       "the candidate must name the authoring hole sketch")
        XCTAssertEqual(reference["sketchEntityID"] as? String, fixture.holeEntity,
                       "the candidate must name the authoring circle entity")
        XCTAssertEqual(reference["featureID"] as? String, fixture.holeFeature,
                       "the candidate must name the authoring feature")

        let added = service.handle(action: "addDimension", args: [
            "pageID": pageID, "viewID": frontID, "kind": "diameter", "feature": reference,
        ])
        XCTAssertEqual(added["ok"] as? Bool, true, "\(added)")
        let dimension = try XCTUnwrap(added["dimension"] as? [String: Any])
        let dimensionID = try XCTUnwrap(dimension["id"] as? String)
        XCTAssertEqual(dimension["value"] as? Double ?? 0, 10, accuracy: 1e-6)
        XCTAssertEqual(dimension["dangling"] as? Bool, false)
        XCTAssertEqual(dimension["text"] as? String, "Ø10")

        // Ø10 -> Ø8 through the real sketch edit/rebuild.
        let parameters = CADParameterService(document: document)
        let radiusEdit = parameters.handle(action: "updateSketchEntity", args: [
            "sketch_id": fixture.holeSketch,
            "entity_id": fixture.holeEntity,
            "radius": 4.0,
        ])
        XCTAssertEqual(radiusEdit["ok"] as? Bool, true, "\(radiusEdit)")
        let undoCountBeforeProjection = document.session.undoStack.undoCommands.count
        var geometry = service.handle(action: "project", args: ["pageID": pageID])
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undoCountBeforeProjection,
                       "refreshing derived projection data must not consume undo")
        var row = try XCTUnwrap(dimensionRow(geometry, id: dimensionID))
        XCTAssertEqual(row["value"] as? Double ?? 0, 8, accuracy: 1e-6,
                       "the SAME dimension id must display Ø8: \(row)")
        XCTAssertEqual(row["text"] as? String, "Ø8")
        XCTAssertEqual(row["dangling"] as? Bool, false)
        XCTAssertEqual(row["remeasured"] as? Bool, true)
        XCTAssertEqual(row["viewID"] as? String, frontID)

        // Save/reopen: the linked dimension identity and measurement survive.
        let save = await document.save()
        XCTAssertTrue(save.succeeded, save.error ?? "")
        document.close()
        let reopened = try await FloeCADDocument.open(at: document.url)
        let reopenedService = CADDrawingService(document: reopened)
        geometry = reopenedService.handle(action: "project", args: ["pageID": pageID])
        row = try XCTUnwrap(dimensionRow(geometry, id: dimensionID))
        XCTAssertEqual(row["value"] as? Double ?? 0, 8, accuracy: 1e-6)
        XCTAssertEqual(row["dangling"] as? Bool, false)

        // Delete the hole feature: dangling, never the plausible old 8.
        let reopenedParameters = CADParameterService(document: reopened)
        let deleted = reopenedParameters.handle(action: "feature.delete", args: [
            "feature_id": fixture.holeFeature,
        ])
        XCTAssertEqual(deleted["ok"] as? Bool, true, "\(deleted)")
        geometry = reopenedService.handle(action: "project", args: ["pageID": pageID])
        row = try XCTUnwrap(dimensionRow(geometry, id: dimensionID))
        XCTAssertEqual(row["dangling"] as? Bool, true)
        XCTAssertEqual(row["status"] as? String, "dangling")
        XCTAssertTrue(row["value"] is NSNull, "a deleted hole must not keep the old value: \(row)")
        XCTAssertFalse((row["text"] as? String ?? "").contains("8"),
                       "the dangling label must not present the old value")
        XCTAssertTrue((row["reasons"] as? [String] ?? []).contains {
            $0.localizedCaseInsensitiveContains("no longer exists")
                || $0.localizedCaseInsensitiveContains("deleted")
                || $0.localizedCaseInsensitiveContains("ambiguous")
        }, "\(row)")

        // Undo restores the hole AND the live Ø8 measurement.
        XCTAssertEqual(reopenedParameters.handle(action: "undo", args: [:])["ok"] as? Bool, true)
        geometry = reopenedService.handle(action: "project", args: ["pageID": pageID])
        row = try XCTUnwrap(dimensionRow(geometry, id: dimensionID))
        XCTAssertEqual(row["value"] as? Double ?? 0, 8, accuracy: 1e-6)
        XCTAssertEqual(row["dangling"] as? Bool, false)

        // Redo deletes it again and the dimension dangles again.
        XCTAssertEqual(reopenedParameters.handle(action: "redo", args: [:])["ok"] as? Bool, true)
        geometry = reopenedService.handle(action: "project", args: ["pageID": pageID])
        row = try XCTUnwrap(dimensionRow(geometry, id: dimensionID))
        XCTAssertEqual(row["dangling"] as? Bool, true)

        // A view offset carries the linked dimension with its view.
        let pinned = reopenedService.handle(action: "updateView", args: [
            "pageID": pageID, "viewID": frontID, "offset": [0.0, 0.0],
            "alignmentPlacement": "free",
        ])
        XCTAssertEqual(pinned["ok"] as? Bool, true, "\(pinned)")
        geometry = reopenedService.handle(action: "project", args: ["pageID": pageID])
        let pinnedRow = try XCTUnwrap(dimensionRow(geometry, id: dimensionID))
        let before = try XCTUnwrap(pinnedRow["sheetPoints"] as? [[Double]])
        let shifted = reopenedService.handle(action: "updateView", args: [
            "pageID": pageID, "viewID": frontID, "offset": [17.0, 9.0],
            "alignmentPlacement": "free",
        ])
        XCTAssertEqual(shifted["ok"] as? Bool, true, "\(shifted)")
        geometry = reopenedService.handle(action: "project", args: ["pageID": pageID])
        let shiftedRow = try XCTUnwrap(dimensionRow(geometry, id: dimensionID))
        let after = try XCTUnwrap(shiftedRow["sheetPoints"] as? [[Double]])
        XCTAssertEqual(after[0][0] - before[0][0], 17, accuracy: 1e-6)
        XCTAssertEqual(after[0][1] - before[0][1], 9, accuracy: 1e-6)
        reopened.close()
    }

    /// Identity, not geometry guessing: deleting the measured hole must
    /// DANGLE even though another plausible unique coaxial cylinder (the
    /// counterbore-like groove left at the same axial station) still matches
    /// the captured anchor; a legitimate Ø10 → Ø8 edit on the SAME feature
    /// still remeasures, and undo/save/reopen stay stable.
    func testLinkedDiameterNeverRematchesAnotherCoaxialCylinder() async throws {
        let document = try await makeDocument("E15-identity")
        let fixture = try makePlateWithHole(document)
        let service = CADDrawingService(document: document)
        let created = service.handle(action: "multiViewSheet", args: [
            "bodyID": fixture.bodyID, "title": "E15 identity",
            "sectionOrigin": [50.0, 5.0, 30.0], "sectionNormal": [0.0, 1.0, 0.0],
        ])
        XCTAssertEqual(created["ok"] as? Bool, true, "\(created)")
        let page = try XCTUnwrap(created["page"] as? [String: Any])
        let pageID = try XCTUnwrap(page["id"] as? String)
        let front = try XCTUnwrap((page["views"] as? [[String: Any]])?
            .first { ($0["kind"] as? String) == "front" })
        let frontID = try XCTUnwrap(front["id"] as? String)
        let candidate = try candidate(for: frontID, pageID: pageID, service: service)
        let reference = try XCTUnwrap(candidate["reference"] as? [String: Any])
        XCTAssertEqual(reference["featureID"] as? String, fixture.holeFeature,
                       "the candidate must name the authoring hole feature")
        let added = service.handle(action: "addDimension", args: [
            "pageID": pageID, "viewID": frontID, "kind": "diameter", "feature": reference,
        ])
        XCTAssertEqual(added["ok"] as? Bool, true, "\(added)")
        let dimension = try XCTUnwrap(added["dimension"] as? [String: Any])
        let dimensionID = try XCTUnwrap(dimension["id"] as? String)
        XCTAssertEqual(dimension["value"] as? Double ?? 0, 10, accuracy: 1e-6)

        // Ø10 → Ø8 on the SAME feature/entity still remeasures on the same id.
        let parameters = CADParameterService(document: document)
        let radiusEdit = parameters.handle(action: "updateSketchEntity", args: [
            "sketch_id": fixture.holeSketch,
            "entity_id": fixture.holeEntity,
            "radius": 4.0,
        ])
        XCTAssertEqual(radiusEdit["ok"] as? Bool, true, "\(radiusEdit)")
        var geometry = service.handle(action: "project", args: ["pageID": pageID])
        var row = try XCTUnwrap(dimensionRow(geometry, id: dimensionID))
        XCTAssertEqual(row["value"] as? Double ?? 0, 8, accuracy: 1e-6,
                       "the SAME dimension id must remeasure to Ø8: \(row)")
        XCTAssertEqual(row["dangling"] as? Bool, false)

        // A full-depth foreign bore has the SAME mid-thickness station as
        // the captured face. A symmetric cut about the sketch's y=0 plane
        // would only cut the first 2 mm of this plate and test a different
        // station instead. The live Ø8 provenance must reject this Ø20 bore.
        let groove = try addSketch(
            document, name: "Groove",
            entities: #"[{"kind":"circle","center":[50,30],"radius":10}]"#)
        _ = try run(document, """
        {"op":"feature.extrude","args":{"sketchID":"\(groove.sketchID)","seedPoint":[50,30],
         "distance":10,"boolean":"subtract","booleanTargets":["\(fixture.bodyID)"]}}
        """)
        // Independent kernel witness: the surviving foreign cylinder really
        // shares the captured station, so this exercises provenance refusal
        // rather than the simpler no-cylinder-at-this-station path.
        let foreignBody = try XCTUnwrap(document.session.document.bodies.first {
            $0.id.raw.uuidString == fixture.bodyID
        })
        let foreignBRep = try XCTUnwrap(foreignBody.brep)
        let foreignFace = try XCTUnwrap(OCCTKernel.faceInfo(foreignBRep).first {
            guard let signature = $0.signature,
                  case let .cylindrical(radius) = signature.kind else { return false }
            return abs(radius - 10) < 1e-6
        })
        let foreignSignature = try XCTUnwrap(foreignFace.signature)
        let capturedAnchor = try XCTUnwrap(reference["anchor"] as? [String: Any])
        let capturedCentroid = try XCTUnwrap(capturedAnchor["centroid"] as? [Double])
        XCTAssertEqual(capturedCentroid.count, 3)
        XCTAssertEqual(foreignSignature.centroid.x, capturedCentroid[0], accuracy: 1e-6)
        XCTAssertEqual(foreignSignature.centroid.y, capturedCentroid[1], accuracy: 1e-6)
        XCTAssertEqual(foreignSignature.centroid.z, capturedCentroid[2], accuracy: 1e-6)
        geometry = service.handle(action: "project", args: ["pageID": pageID])
        row = try XCTUnwrap(dimensionRow(geometry, id: dimensionID))
        XCTAssertEqual(row["dangling"] as? Bool, true,
                       "the captured Ø8 cylinder at the anchor station is gone; "
                       + "the groove must NOT be adopted: \(row)")
        XCTAssertTrue(row["value"] is NSNull, "the groove's Ø20 must not be displayed: \(row)")
        XCTAssertFalse((row["text"] as? String ?? "").contains("20"),
                       "the dangling label must not present the groove value: \(row)")
        // Exact strict-path classification: the captured station still has a
        // face (the groove), but it is not the captured cylinder, so this is
        // LOST PROVENANCE. An empty provenance-filtered set is not an
        // ambiguous face and must never fall through to that message.
        XCTAssertTrue((row["reasons"] as? [String] ?? []).contains {
            $0.contains("The linked feature no longer owns this geometry")
                && $0.contains("the captured cylinder is gone")
        }, "expected the exact provenance-lost reason: \(row)")
        XCTAssertFalse((row["reasons"] as? [String] ?? []).contains {
            $0.localizedCaseInsensitiveContains("ambiguous")
        }, "one surviving foreign cylinder is not an ambiguous face: \(row)")

        // Deleting the measured hole while the groove remains must keep the
        // dimension dangling (provenance gate), never rematch the groove.
        let deleted = parameters.handle(action: "feature.delete", args: [
            "feature_id": fixture.holeFeature, "force": true,
        ])
        XCTAssertEqual(deleted["ok"] as? Bool, true, "\(deleted)")
        geometry = service.handle(action: "project", args: ["pageID": pageID])
        row = try XCTUnwrap(dimensionRow(geometry, id: dimensionID))
        XCTAssertEqual(row["dangling"] as? Bool, true)
        XCTAssertTrue(row["value"] is NSNull, "a deleted hole must not rematch the "
                       + "remaining coaxial cylinder: \(row)")
        XCTAssertTrue((row["reasons"] as? [String] ?? []).contains {
            $0.localizedCaseInsensitiveContains("no longer exists")
                || $0.localizedCaseInsensitiveContains("no longer owns")
        }, "\(row)")

        // Undo restores the hole feature; the geometry at the captured band
        // is still consumed by the groove, so the row honestly stays dangling
        // rather than guessing.
        XCTAssertEqual(parameters.handle(action: "undo", args: [:])["ok"] as? Bool, true)
        geometry = service.handle(action: "project", args: ["pageID": pageID])
        row = try XCTUnwrap(dimensionRow(geometry, id: dimensionID))
        XCTAssertEqual(row["dangling"] as? Bool, true)

        // Save/reopen keeps the same dangling identity (no invented value).
        let save = await document.save()
        XCTAssertTrue(save.succeeded, save.error ?? "")
        document.close()
        let reopened = try await FloeCADDocument.open(at: document.url)
        let reopenedService = CADDrawingService(document: reopened)
        geometry = reopenedService.handle(action: "project", args: ["pageID": pageID])
        row = try XCTUnwrap(dimensionRow(geometry, id: dimensionID))
        XCTAssertEqual(row["dangling"] as? Bool, true)
        XCTAssertTrue(row["value"] is NSNull)
        reopened.close()
    }

    /// Capture, not recency: two holes are cut into the plate BEFORE the
    /// dimension is linked. The candidate for the EARLIER hole must name
    /// that hole's own feature/sketch/entity even though a newer, unrelated
    /// hole feature exists; Ø10 → Ø8 on the earlier hole remeasures on the
    /// same dimension id; deleting the earlier hole dangles (never adopting
    /// the surviving unrelated cylinder); undo and save/reopen stay stable.
    func testLinkedDiameterCapturesEarlierHoleAuthoredBeforeLaterHole() async throws {
        let document = try await makeDocument("E15-capture")
        let fixture = try makePlateWithHole(document)
        // A second, unrelated hole cut after the first: smaller, elsewhere.
        let holeB = try addSketch(
            document, name: "HoleB",
            entities: #"[{"kind":"circle","center":[20,15],"radius":3}]"#)
        _ = try run(document, """
        {"op":"feature.extrude","args":{"sketchID":"\(holeB.sketchID)","seedPoint":[20,15],
         "distance":40,"symmetric":true,"boolean":"subtract","booleanTargets":["\(fixture.bodyID)"]}}
        """)
        let holeBFeature = try featureID(document, sketchID: holeB.sketchID)
        XCTAssertNotEqual(holeBFeature, fixture.holeFeature,
                          "the fixture needs two distinct hole features")

        let service = CADDrawingService(document: document)
        let created = service.handle(action: "multiViewSheet", args: [
            "bodyID": fixture.bodyID, "title": "E15 capture",
            "sectionOrigin": [50.0, 5.0, 30.0], "sectionNormal": [0.0, 1.0, 0.0],
        ])
        XCTAssertEqual(created["ok"] as? Bool, true, "\(created)")
        let page = try XCTUnwrap(created["page"] as? [String: Any])
        let pageID = try XCTUnwrap(page["id"] as? String)
        let front = try XCTUnwrap((page["views"] as? [[String: Any]])?
            .first { ($0["kind"] as? String) == "front" })
        let frontID = try XCTUnwrap(front["id"] as? String)

        // The Ø10 candidate is the EARLIER hole's face; its reference must
        // name the earlier hole's authoring triple, not nil (newest-writer
        // scan) and not the later hole.
        let candidate = try candidate(for: frontID, pageID: pageID, service: service)
        let reference = try XCTUnwrap(candidate["reference"] as? [String: Any])
        XCTAssertEqual(reference["featureID"] as? String, fixture.holeFeature,
                       "the earlier hole must be captured despite the later feature: "
                       + "\(reference)")
        XCTAssertEqual(reference["sketchID"] as? String, fixture.holeSketch)
        XCTAssertEqual(reference["sketchEntityID"] as? String, fixture.holeEntity)
        XCTAssertNil(reference["provenanceAmbiguity"])

        let added = service.handle(action: "addDimension", args: [
            "pageID": pageID, "viewID": frontID, "kind": "diameter", "feature": reference,
        ])
        XCTAssertEqual(added["ok"] as? Bool, true, "\(added)")
        let dimension = try XCTUnwrap(added["dimension"] as? [String: Any])
        let dimensionID = try XCTUnwrap(dimension["id"] as? String)
        XCTAssertEqual(dimension["value"] as? Double ?? 0, 10, accuracy: 1e-6)
        let storedFeature = try XCTUnwrap(dimension["feature"] as? [String: Any])
        XCTAssertEqual(storedFeature["featureID"] as? String, fixture.holeFeature,
                       "the stored dimension must carry the earlier hole's identity")
        XCTAssertEqual(storedFeature["sketchID"] as? String, fixture.holeSketch)
        XCTAssertEqual(storedFeature["sketchEntityID"] as? String, fixture.holeEntity)

        // Ø10 → Ø8 on the EARLIER hole: the same dimension id remeasures
        // from the live kernel face.
        let parameters = CADParameterService(document: document)
        let radiusEdit = parameters.handle(action: "updateSketchEntity", args: [
            "sketch_id": fixture.holeSketch,
            "entity_id": fixture.holeEntity,
            "radius": 4.0,
        ])
        XCTAssertEqual(radiusEdit["ok"] as? Bool, true, "\(radiusEdit)")
        var geometry = service.handle(action: "project", args: ["pageID": pageID])
        var row = try XCTUnwrap(dimensionRow(geometry, id: dimensionID))
        XCTAssertEqual(row["value"] as? Double ?? 0, 8, accuracy: 1e-6,
                       "the SAME dimension id must remeasure the earlier hole to Ø8: \(row)")
        XCTAssertEqual(row["text"] as? String, "Ø8")
        XCTAssertEqual(row["dangling"] as? Bool, false)
        XCTAssertEqual(row["remeasured"] as? Bool, true)

        // Delete the EARLIER hole while the unrelated Ø6 cylinder survives:
        // the provenance gate dangles first; the surviving cylinder is never
        // adopted.
        let deleted = parameters.handle(action: "feature.delete", args: [
            "feature_id": fixture.holeFeature, "force": true,
        ])
        XCTAssertEqual(deleted["ok"] as? Bool, true, "\(deleted)")
        geometry = service.handle(action: "project", args: ["pageID": pageID])
        row = try XCTUnwrap(dimensionRow(geometry, id: dimensionID))
        XCTAssertEqual(row["dangling"] as? Bool, true)
        XCTAssertTrue(row["value"] is NSNull, "a deleted hole must not keep or adopt a "
                       + "surviving cylinder's value: \(row)")
        XCTAssertFalse((row["text"] as? String ?? "").contains("6"),
                       "the dangling label must not present the surviving hole's value")
        XCTAssertTrue((row["reasons"] as? [String] ?? []).contains {
            $0.localizedCaseInsensitiveContains("no longer exists")
                || $0.localizedCaseInsensitiveContains("deleted")
        }, "\(row)")

        // Undo restores the earlier hole AND the live Ø8 measurement.
        XCTAssertEqual(parameters.handle(action: "undo", args: [:])["ok"] as? Bool, true)
        geometry = service.handle(action: "project", args: ["pageID": pageID])
        row = try XCTUnwrap(dimensionRow(geometry, id: dimensionID))
        XCTAssertEqual(row["value"] as? Double ?? 0, 8, accuracy: 1e-6)
        XCTAssertEqual(row["dangling"] as? Bool, false)

        // Save/reopen keeps the same identity and measurement.
        let save = await document.save()
        XCTAssertTrue(save.succeeded, save.error ?? "")
        document.close()
        let reopened = try await FloeCADDocument.open(at: document.url)
        let reopenedService = CADDrawingService(document: reopened)
        geometry = reopenedService.handle(action: "project", args: ["pageID": pageID])
        row = try XCTUnwrap(dimensionRow(geometry, id: dimensionID))
        XCTAssertEqual(row["value"] as? Double ?? 0, 8, accuracy: 1e-6)
        XCTAssertEqual(row["dangling"] as? Bool, false)
        let reopenedFeature = try XCTUnwrap(row["feature"] as? [String: Any])
        XCTAssertEqual(reopenedFeature["featureID"] as? String, fixture.holeFeature,
                       "reopen must keep the earlier hole's captured identity")
        XCTAssertEqual(reopenedFeature["sketchID"] as? String, fixture.holeSketch)
        XCTAssertEqual(reopenedFeature["sketchEntityID"] as? String, fixture.holeEntity)
        reopened.close()
    }

    /// Real ambiguity is reported, never guessed: two same-radius holes cut
    /// by two different features close together leave cylindrical faces that
    /// both features' circles match. Candidates must name NO author (no
    /// newest/first adoption) and must say authorship is ambiguous; an
    /// explicit featureID/sketchID/sketchEntityID re-selection is then
    /// validated against the model and works.
    func testAmbiguousHoleAuthorshipIsReportedNotGuessed() async throws {
        let document = try await makeDocument("E15-ambiguity")
        let fixture = try makePlateWithHole(document)
        // At d=0.5 and r=5, each exposed cylindrical arc has radial centroid
        // 2*r*sqrt(1-(d/(2*r))^2)/(pi+2*asin(d/(2*r))) = 3.081 mm.
        // Both centres are then inside the 3.75 mm capture band. A 3.5 mm
        // separation is NOT ambiguous: its opposite-centre distance is
        // 3.5+2.429=5.929 mm, as the first actual kernel run demonstrated.
        let holeB = try addSketch(
            document, name: "HoleB",
            entities: #"[{"kind":"circle","center":[50,30.5],"radius":5}]"#)
        _ = try run(document, """
        {"op":"feature.extrude","args":{"sketchID":"\(holeB.sketchID)","seedPoint":[50,30.5],
         "distance":40,"symmetric":true,"boolean":"subtract","booleanTargets":["\(fixture.bodyID)"]}}
        """)
        let holeBFeature = try featureID(document, sketchID: holeB.sketchID)
        XCTAssertNotEqual(holeBFeature, fixture.holeFeature)

        let service = CADDrawingService(document: document)
        let created = service.handle(action: "multiViewSheet", args: [
            "bodyID": fixture.bodyID, "title": "E15 ambiguity",
            "sectionOrigin": [50.0, 5.0, 30.0], "sectionNormal": [0.0, 1.0, 0.0],
        ])
        XCTAssertEqual(created["ok"] as? Bool, true, "\(created)")
        let page = try XCTUnwrap(created["page"] as? [String: Any])
        let pageID = try XCTUnwrap(page["id"] as? String)
        let front = try XCTUnwrap((page["views"] as? [[String: Any]])?
            .first { ($0["kind"] as? String) == "front" })
        let frontID = try XCTUnwrap(front["id"] as? String)

        let reply = service.handle(action: "dimensionCandidates",
                                   args: ["pageID": pageID, "viewID": frontID])
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        let candidates = try XCTUnwrap(reply["candidates"] as? [[String: Any]])
        let radiusFive = candidates.filter {
            abs(($0["radiusMM"] as? Double ?? -1) - 5) <= 1e-4
        }
        XCTAssertFalse(radiusFive.isEmpty,
                       "two overlapping Ø10 holes must expose cylindrical candidates")
        for candidate in radiusFive {
            let reference = try XCTUnwrap(candidate["reference"] as? [String: Any])
            XCTAssertNil(reference["featureID"],
                         "an ambiguous face must not adopt any author: \(reference)")
            XCTAssertNil(reference["sketchID"])
            XCTAssertNil(reference["sketchEntityID"])
            XCTAssertEqual(reference["provenanceAmbiguity"] as? Bool, true,
                           "the candidate must flag structured ambiguity: \(reference)")
        }
        XCTAssertTrue(((reply["notes"] as? [String]) ?? []).contains {
            $0.localizedCaseInsensitiveContains("authored by more than one feature")
        }, "\(reply["notes"] ?? [])")

        // Explicit re-selection: name the EARLIER hole's authoring triple on
        // the candidate nearest [50,30]; addDimension validates it against
        // the live model (gate + entity circle) and links it.
        let nearest = try XCTUnwrap(radiusFive.min { lhs, rhs in
            func distance(_ row: [String: Any]) -> Double {
                let center = row["center"] as? [Double] ?? [0, 0]
                let dx = center.count > 0 ? center[0] - 50 : 0.0
                let dy = center.count > 1 ? center[1] - 30 : 0.0
                return dx * dx + dy * dy
            }
            return distance(lhs) < distance(rhs)
        })
        var reference = try XCTUnwrap(nearest["reference"] as? [String: Any])
        let beforeRejectedReference = document.session.changeCount
        let ambiguous = service.handle(action: "addDimension", args: [
            "pageID": pageID, "viewID": frontID, "kind": "diameter", "feature": reference,
        ])
        XCTAssertEqual(ambiguous["ok"] as? Bool, false)
        XCTAssertEqual(ambiguous["error"] as? String, "ambiguous_feature_reference")
        XCTAssertEqual(document.session.changeCount, beforeRejectedReference)
        reference["featureID"] = fixture.holeFeature
        reference["sketchID"] = fixture.holeSketch
        reference["sketchEntityID"] = fixture.holeEntity
        var unrelatedSource = reference
        unrelatedSource["featureID"] = holeBFeature
        let mismatched = service.handle(action: "addDimension", args: [
            "pageID": pageID, "viewID": frontID, "kind": "diameter", "feature": unrelatedSource,
        ])
        XCTAssertEqual(mismatched["ok"] as? Bool, false)
        XCTAssertEqual(mismatched["error"] as? String, "stale_feature_reference")
        XCTAssertEqual(document.session.changeCount, beforeRejectedReference)
        let added = service.handle(action: "addDimension", args: [
            "pageID": pageID, "viewID": frontID, "kind": "diameter", "feature": reference,
        ])
        XCTAssertEqual(added["ok"] as? Bool, true, "\(added)")
        let dimension = try XCTUnwrap(added["dimension"] as? [String: Any])
        let dimensionID = try XCTUnwrap(dimension["id"] as? String)
        XCTAssertEqual(dimension["value"] as? Double ?? 0, 10, accuracy: 1e-6)
        let storedFeature = try XCTUnwrap(dimension["feature"] as? [String: Any])
        XCTAssertEqual(storedFeature["featureID"] as? String, fixture.holeFeature,
                       "the explicit re-selection must store the named author")

        // Shrinking A to r=4 makes it wholly contained in B (4+0.5<5).
        // A's cylindrical face is therefore gone. The named dimension must
        // dangle rather than adopt B's surviving Ø10 cylinder. The separate
        // non-overlapping-hole tests prove the live Ø10->Ø8 remeasurement.
        let parameters = CADParameterService(document: document)
        let radiusEdit = parameters.handle(action: "updateSketchEntity", args: [
            "sketch_id": fixture.holeSketch,
            "entity_id": fixture.holeEntity,
            "radius": 4.0,
        ])
        XCTAssertEqual(radiusEdit["ok"] as? Bool, true, "\(radiusEdit)")
        let geometry = service.handle(action: "project", args: ["pageID": pageID])
        let row = try XCTUnwrap(dimensionRow(geometry, id: dimensionID))
        XCTAssertEqual(row["dangling"] as? Bool, true)
        XCTAssertTrue(row["value"] is NSNull, "do not adopt B's cylinder: \(row)")
        document.close()
    }

    // MARK: - E13: mixed B-rep/mesh section must be blocked before output

    func testMixedSectionBlocksVectorOutput() async throws {
        let document = try await makeDocument("E13")
        let fixture = try makePlateWithHole(document)
        let plate = try XCTUnwrap(document.session.document.bodies.first {
            $0.id.raw.uuidString == fixture.bodyID
        })
        var mesh = Body(id: BodyID(), name: "MeshOnly",
                        transform: plate.transform, primitive: nil,
                        render: plate.render,
                        revision: plate.meshRevision &+ 1)
        mesh.brep = nil
        document.session.perform(AddBodyCommand(body: mesh, title: "Mesh part"))
        let meshID = mesh.id.raw.uuidString

        let assembly = CADAssemblyService(document: document)
        for (bodyID, name) in [(fixture.bodyID, "Plate"), (meshID, "MeshOnly")] {
            let reply = assembly.handle(action: "addInstance", args: [
                "bodyID": bodyID, "name": name,
            ])
            XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        }
        let service = CADDrawingService(document: document)
        let added = service.handle(action: "addPage", args: [
            "kind": "section",
            "bodyIDs": [fixture.bodyID, meshID],
            "assemblyMode": true,
            "sectionOrigin": [40.0, 5.0, 30.0],
            "sectionNormal": [0.0, 1.0, 0.0],
        ])
        XCTAssertEqual(added["ok"] as? Bool, true, "\(added)")
        let pageID = try XCTUnwrap((added["page"] as? [String: Any])?["id"] as? String)

        let geometry = service.handle(action: "project", args: ["pageID": pageID])
        XCTAssertEqual(geometry["ok"] as? Bool, true, "\(geometry)")
        XCTAssertEqual(geometry["sectionComplete"] as? Bool, false)
        XCTAssertEqual(geometry["outputBlocked"] as? Bool, true)
        let coverage = try XCTUnwrap(geometry["sectionCoverage"] as? [[String: Any]])
        XCTAssertTrue(coverage.contains { ($0["analyticBRep"] as? Bool) == false },
                      "the mesh source must be named in the coverage: \(coverage)")
        XCTAssertTrue(((geometry["notes"] as? [String]) ?? []).contains {
            $0.localizedCaseInsensitiveContains("INCOMPLETE")
        }, "\(geometry["notes"] ?? [])")

        let pageUUID = try XCTUnwrap(UUID(uuidString: pageID))
        XCTAssertThrowsError(try service.exportData(pageID: pageUUID, format: "pdf")) { error in
            guard let cadError = error as? CADDocumentError else {
                return XCTFail("expected CADDocumentError, got \(error)")
            }
            XCTAssertEqual(cadError.code, "incomplete_section")
        }

        // A pure analytic section exports normally; only the mixed one blocks.
        let analytic = service.handle(action: "addPage", args: [
            "kind": "section", "bodyIDs": [fixture.bodyID],
            "sectionOrigin": [50.0, 5.0, 30.0], "sectionNormal": [0.0, 1.0, 0.0],
        ])
        XCTAssertEqual(analytic["ok"] as? Bool, true, "\(analytic)")
        let analyticID = try XCTUnwrap((analytic["page"] as? [String: Any])?["id"] as? String)
        let analyticProjection = service.handle(action: "project", args: ["pageID": analyticID])
        XCTAssertEqual(analyticProjection["outputBlocked"] as? Bool, false)
        let pdf = try service.exportData(pageID: try XCTUnwrap(UUID(uuidString: analyticID)),
                                         format: "pdf")
        XCTAssertEqual(String(data: Data(pdf.prefix(5)), encoding: .ascii), "%PDF-")
        document.close()
    }
}

// E12/E14 source packet: these tests require the pinned native OCCT archive.
// They are component behavior tests, not independent-CAD or presented-UI proof.
extension CADDrawingMultiViewAssociativityTests {
    private func retainProjectionEdges(_ edges: [CADHiddenLineEdge], name: String,
                                       normal: SIMD3<Double>, xAxis: SIMD3<Double>) throws {
        func point(_ p: SIMD2<Double>) -> [Double] { [p.x, p.y] }
        func encoded(_ curve: CADHiddenLineEdge.Curve) -> [String: Any] {
            switch curve {
            case let .line(a, b): return ["kind": "line", "a": point(a), "b": point(b)]
            case let .circle(c, r): return ["kind": "circle", "center": point(c), "radius": r]
            case let .arc(c, r, a, b): return ["kind": "arc", "center": point(c), "radius": r, "angles": [a, b]]
            case let .polyline(points): return ["kind": "polyline", "points": points.map(point)]
            }
        }
        let rows = edges.map { edge -> [String: Any] in
            var row = encoded(edge.curve)
            row["sourceIndex"] = edge.sourceIndex
            row["layer"] = edge.hidden ? "hidden" : edge.outline ? "outline" : "edges"
            row["sourceEdges"] = edge.sourceEdges.map { source -> [String: Any] in
                var span = encoded(source.curve)
                span["sourceIndex"] = source.sourceIndex
                span["nativeEdgeIndex"] = source.nativeEdgeIndex
                span["nativeCurveType"] = source.nativeCurveType
                return span
            }
            return row
        }
        let bytes = try JSONSerialization.data(withJSONObject: ["name": name, "projectionMethod": "occt-brep-hlr",
            "projectionComplete": true, "scale": 1, "normal": [normal.x, normal.y, normal.z],
            "xAxis": [xAxis.x, xAxis.y, xAxis.z], "entities": rows], options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.json")
        attachment.name = name+"-floe-exact-edges.json"; attachment.lifetime = .keepAlways; add(attachment)
    }

    /// Analytic one-to-one witness. These coordinates are prescribed by the
    /// unchanged solids/view frames, not fitted to the current projection.
    private func assertExactHLRCurves(_ actual: [CADHiddenLineEdge],
                                     _ expected: [(Bool, CADHiddenLineEdge.Curve)],
                                     file: StaticString = #filePath, line: UInt = #line) {
        func near(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Bool {
            simd_length(a - b) <= 1e-6
        }
        func same(_ a: CADHiddenLineEdge.Curve, _ b: CADHiddenLineEdge.Curve) -> Bool {
            switch (a, b) {
            case let (.line(a0, a1), .line(b0, b1)):
                return (near(a0, b0) && near(a1, b1)) || (near(a0, b1) && near(a1, b0))
            case let (.circle(a0, ar), .circle(b0, br)):
                return near(a0, b0) && abs(ar - br) <= 1e-6
            default: return false // no polyline-to-line relaxation
            }
        }
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        var consumed = Set<Int>()
        for (hidden, curve) in expected {
            guard let index = actual.indices.first(where: {
                !consumed.contains($0) && actual[$0].hidden == hidden && same(actual[$0].curve, curve)
            }) else {
                XCTFail("Missing analytic HLR curve with hidden=\(hidden)", file: file, line: line)
                continue
            }
            consumed.insert(index)
        }
        XCTAssertEqual(consumed.count, actual.count, "Unexpected/duplicate/non-analytic output curve",
                       file: file, line: line)
        let raw = actual.flatMap(\.sourceEdges).map(\.nativeEdgeIndex)
        XCTAssertEqual(Set(raw).count, raw.count, "An original native edge was bound twice", file: file, line: line)
        XCTAssertEqual(raw.sorted(), Array(0..<raw.count), "An original native edge lost ownership", file: file, line: line)
    }

    private func expectedHLRRectangle(_ x0: Double, _ x1: Double, _ y0: Double, _ y1: Double,
                                      hidden: Bool) -> [(Bool, CADHiddenLineEdge.Curve)] {
        [(hidden, .line(SIMD2(x0, y0), SIMD2(x0, y1))),
         (hidden, .line(SIMD2(x1, y0), SIMD2(x1, y1))),
         (hidden, .line(SIMD2(x0, y0), SIMD2(x1, y0))),
         (hidden, .line(SIMD2(x0, y1), SIMD2(x1, y1)))]
    }

    func testExactHLRMutualOcclusionHiddenStyleAndReopen() async throws {
        let small = try XCTUnwrap(OCCTKernel.primitiveShape(
            .box(width: 10, depth: 10, height: 4), placement: .identity))
        let cover = try XCTUnwrap(OCCTKernel.primitiveShape(
            .box(width: 40, depth: 40, height: 4),
            placement: Transform3D(translation: SIMD3(0, 0, 50))))
        let alone = try XCTUnwrap(OCCTKernel.hiddenLineProjection([small],
            normal: SIMD3(0, 0, 1), xAxis: SIMD3(1, 0, 0)))
        XCTAssertTrue(alone.contains { !$0.hidden })
        assertExactHLRCurves(alone,
            expectedHLRRectangle(-5, 5, 0, 4, hidden: false)
                + expectedHLRRectangle(-5, 5, 0, 4, hidden: true))
        let together = try XCTUnwrap(OCCTKernel.hiddenLineProjection([small, cover],
            normal: SIMD3(0, 0, 1), xAxis: SIMD3(1, 0, 0)))
        XCTAssertTrue(together.contains { $0.sourceIndex == 0 && $0.hidden })
        XCTAssertFalse(together.contains { $0.sourceIndex == 0 && !$0.hidden },
                       "A larger nearer B-rep must hide the OTHER body's edges")
        XCTAssertTrue(together.contains { $0.sourceIndex == 1 && !$0.hidden })
        assertExactHLRCurves(together,
            expectedHLRRectangle(-20, 20, 0, 4, hidden: false)
                + expectedHLRRectangle(-20, 20, 0, 4, hidden: true)
                + [(true, .line(SIMD2(-5, 0), SIMD2(-5, 4))),
                   (true, .line(SIMD2(5, 0), SIMD2(5, 4)))])
        XCTAssertEqual(together.flatMap(\.sourceEdges).count, 16,
                       "Normalization retains all 16 native source records, while drawing only 10 curves")
        let absorbed = together.filter { Set($0.sourceEdges.map(\.sourceIndex)) == Set([0, 1]) }
        XCTAssertEqual(absorbed.count, 2, "Both long hidden horizontals retain the covered smaller-body spans")
        for edge in absorbed {
            for source in edge.sourceEdges where source.sourceIndex == 0 {
                guard case let .line(a, b) = source.curve else { return XCTFail("Small source must stay analytic") }
                XCTAssertEqual(min(a.x, b.x), -5, accuracy: 1e-6)
                XCTAssertEqual(max(a.x, b.x), 5, accuracy: 1e-6,
                               "The smaller instance owns its short span, never the full cover edge")
            }
        }
        try retainProjectionEdges(alone, name: "box-alone", normal: SIMD3(0,0,1), xAxis: SIMD3(1,0,0))
        try retainProjectionEdges(together, name: "mutual-occlusion", normal: SIMD3(0,0,1), xAxis: SIMD3(1,0,0))
        let sphere = try XCTUnwrap(OCCTKernel.primitiveShape(.sphere(radius: 20), placement: .identity))
        let sphereEdges = try XCTUnwrap(OCCTKernel.hiddenLineProjection([sphere], normal: SIMD3(0,0,1), xAxis: SIMD3(1,0,0)))
        assertExactHLRCurves(sphereEdges, [(false, .circle(SIMD2(0, 20), 20))])
        try retainProjectionEdges(sphereEdges, name: "sphere", normal: SIMD3(0,0,1), xAxis: SIMD3(1,0,0))

        let document = try await makeDocument("E12-HLR")
        let fixture = try makePlateWithHole(document)
        let actualBody = try XCTUnwrap(document.session.document.bodies.first { $0.id.raw.uuidString == fixture.bodyID })
        let actualBRep = try XCTUnwrap(actualBody.brep.flatMap { OCCTKernel.transformed($0, by: actualBody.transform) })
        for (name,normal) in [("bore-side",SIMD3<Double>(0,0,1)),("bore-circle",SIMD3<Double>(0,1,0))] {
            let exact = try XCTUnwrap(OCCTKernel.hiddenLineProjection([actualBRep], normal: normal, xAxis: SIMD3(1,0,0)))
            if name == "bore-side" {
                assertExactHLRCurves(exact,
                    expectedHLRRectangle(0, 100, 0, 10, hidden: false)
                        + expectedHLRRectangle(0, 100, 0, 10, hidden: true)
                        + [(true, .line(SIMD2(45, 0), SIMD2(45, 10))),
                           (true, .line(SIMD2(55, 0), SIMD2(55, 10)))])
                XCTAssertEqual(exact.flatMap(\.sourceEdges).count, 14)
                XCTAssertEqual(exact.flatMap(\.sourceEdges).filter { $0.nativeCurveType == 6 }.count, 4,
                               "The four original edge-on B-splines remain traceable after the control-hull proof")
            } else {
                assertExactHLRCurves(exact,
                    expectedHLRRectangle(0, 100, 0, 60, hidden: false)
                        + expectedHLRRectangle(0, 100, 0, 60, hidden: true)
                        + [(false, .circle(SIMD2(50, 30), 5)), (true, .circle(SIMD2(50, 30), 5))])
            }
            try retainProjectionEdges(exact, name: name, normal: normal, xAxis: SIMD3(1,0,0))
        }
        let service = CADDrawingService(document: document)
        let created = service.handle(action: "addPage", args: [
            "name": "Occluded bore", "kind": "side", "bodyIDs": [fixture.bodyID],
            "viewNormal": [0.0, 0.0, 1.0], "viewUp": [1.0, 0.0, 0.0],
            "showDimensions": false, "showCenterlines": false,
        ])
        XCTAssertEqual(created["ok"] as? Bool, true, "\(created)")
        let page = try XCTUnwrap(created["page"] as? [String: Any])
        let pageID = try XCTUnwrap(page["id"] as? String)
        let id = try XCTUnwrap(UUID(uuidString: pageID))
        let viewID = try XCTUnwrap((page["views"] as? [[String: Any]])?.first?["id"] as? String)
        XCTAssertEqual(viewID, pageID, "legacy view identity must be stable")
        var geometry = service.pageGeometry(pageID: id)
        XCTAssertEqual(geometry["projectionMethod"] as? String, "occt-brep-hlr")
        XCTAssertEqual(geometry["projectionComplete"] as? Bool, true)
        XCTAssertGreaterThan(geometry["hiddenEdgeCount"] as? Int ?? 0, 0)
        let hidden = (geometry["entities"] as? [[String: Any]] ?? []).filter { $0["layer"] as? String == "hidden" }
        XCTAssertFalse(hidden.isEmpty, "the occluded curved bore must have classified drawing edges")
        let visibleBefore = (geometry["entities"] as? [[String: Any]] ?? []).filter { $0["layer"] as? String != "hidden" }
        let dxf = String(decoding: try service.exportData(pageID: id, format: "dxf"), as: UTF8.self)
        XCTAssertTrue(dxf.contains("0\nLTYPE\n2\nHIDDEN\n"))
        XCTAssertTrue(dxf.contains("49\n2\n49\n-1\n"))
        XCTAssertTrue(dxf.contains("8\nHIDDEN\n"))
        let svg = String(decoding: try service.exportData(pageID: id, format: "svg"), as: UTF8.self)
        XCTAssertTrue(svg.contains("id=\"HIDDEN\""))
        XCTAssertTrue(svg.contains("stroke-dasharray=\"2 1\""))
        let toggle = service.handle(action: "updateView", args: [
            "pageID": pageID, "viewID": viewID, "showHiddenLines": false,
        ])
        XCTAssertEqual(toggle["ok"] as? Bool, true, "\(toggle)")
        geometry = service.pageGeometry(pageID: id)
        let offEntities = geometry["entities"] as? [[String: Any]] ?? []
        XCTAssertFalse(offEntities.contains { $0["layer"] as? String == "hidden" })
        XCTAssertEqual(offEntities.count, visibleBefore.count)
        XCTAssertGreaterThan(geometry["hiddenEdgeCount"] as? Int ?? 0, 0,
                             "hiding ink must not erase the actual classification")
        let undo = CADParameterService(document: document).handle(action: "undo", args: [:])
        XCTAssertEqual(undo["ok"] as? Bool, true)
        XCTAssertTrue((service.pageGeometry(pageID: id)["entities"] as? [[String: Any]] ?? [])
            .contains { $0["layer"] as? String == "hidden" })
        let redo = CADParameterService(document: document).handle(action: "redo", args: [:])
        XCTAssertEqual(redo["ok"] as? Bool, true)
        let save = await document.save()
        XCTAssertTrue(save.succeeded, save.error ?? "")
        document.close()
        let reopened = try await FloeCADDocument.open(at: document.url)
        defer { reopened.close() }
        let reopenedService = CADDrawingService(document: reopened)
        geometry = reopenedService.pageGeometry(pageID: id)
        XCTAssertFalse((geometry["entities"] as? [[String: Any]] ?? []).contains { $0["layer"] as? String == "hidden" })
        let again = reopenedService.handle(action: "updateView", args: [
            "pageID": pageID, "viewID": viewID, "showHiddenLines": true,
            "viewNormal": [0.0, 1.0, 0.0], "viewUp": [1.0, 0.0, 0.0],
        ])
        XCTAssertEqual(again["ok"] as? Bool, true, "\(again)")
        let circles = reopenedService.pageGeometry(pageID: id)["entities"] as? [[String: Any]] ?? []
        XCTAssertTrue(circles.contains { row in
            row["kind"] as? String == "circle" && abs((row["radius"] as? Double ?? 0) - 5) < 1e-8
        }, "the through bore must remain an analytic R5 circle, not mesh chords")
        let exactBody = try XCTUnwrap(reopened.session.document.bodies.first { $0.id.raw.uuidString == fixture.bodyID })
        let mesh = Body(id: BodyID(), name: "Mesh preview only", transform: exactBody.transform,
                        primitive: nil, render: exactBody.render, revision: exactBody.meshRevision &+ 1)
        reopened.session.perform(AddBodyCommand(body: mesh, title: "Mesh-only source"))
        let meshPage = reopenedService.handle(action: "addPage", args: [
            "kind": "front", "name": "Unclassified", "bodyIDs": [mesh.id.raw.uuidString],
        ])
        let meshPageID = try XCTUnwrap(UUID(uuidString: (meshPage["page"] as? [String: Any])?["id"] as? String ?? ""))
        let approximate = reopenedService.pageGeometry(pageID: meshPageID)
        XCTAssertEqual(approximate["projectionMethod"] as? String, "mesh-unclassified")
        XCTAssertEqual(approximate["projectionComplete"] as? Bool, false)
        XCTAssertEqual(approximate["outputBlocked"] as? Bool, true)
        XCTAssertThrowsError(try reopenedService.exportData(pageID: meshPageID, format: "dxf")) { error in
            XCTAssertEqual((error as? CADDocumentError)?.code, "incomplete_projection")
        }
    }

    func testMaterialHatchesSteppedCutMarkerUndoAndReopen() async throws {
        // Even-odd fixture deliberately gives outer and inner wires the SAME
        // winding. Hole preservation must not depend on that orientation.
        let outer = SectionLoop(closed: true, points: [SIMD2(0, 0), SIMD2(20, 0), SIMD2(20, 20), SIMD2(0, 20)], area: 400)
        let inner = SectionLoop(closed: true, points: [SIMD2(8, 8), SIMD2(12, 8), SIMD2(12, 12), SIMD2(8, 12)], area: 16)
        let strokes = try XCTUnwrap(CADDrawingSectionDrafting.hatches(loops: [outer, inner], angleDegrees: 0, spacingMM: 1))
        XCTAssertTrue(strokes.contains { abs($0.0.y - 10) < 1e-8 })
        for (a, b) in strokes where abs(a.y - 10) < 1e-8 {
            XCTAssertTrue(max(a.x, b.x) <= 8 + 1e-8 || min(a.x, b.x) >= 12 - 1e-8,
                          "no section hatch may cross the bore")
        }
        let document = try await makeDocument("E14-offset")
        let fixture = try makePlateWithHole(document)
        // A real curved second part: unlike a uniform extrusion, its section
        // changes when the offset plane moves, giving an actual cut witness.
        let sphereBody = BodyID()
        let sphere = FeatureNode(name: "Brass sphere", kind: .primitive(
            spec: .sphere(radius: 20), placement: Transform3D(translation: SIMD3(130, 0, 30))),
            outputBodyIDs: [sphereBody])
        document.session.recordAndRebuild([sphere], title: "Second material")
        XCTAssertTrue(document.session.lastEvalErrors.isEmpty)
        let secondID = sphereBody.raw.uuidString
        for (bodyID, materialID) in [(fixture.bodyID, "steel"), (secondID, "brass")] {
            let body = try XCTUnwrap(document.session.document.bodies.first { $0.id.raw.uuidString == bodyID })
            var material = BodyMaterialSpec.default
            material.materialID = materialID; material.materialName = materialID.capitalized
            document.session.perform(SetMaterialCommand(bodyIDs: [body.id], material: material,
                                                       document: document.session.document))
        }
        let assembly = CADAssemblyService(document: document)
        for bodyID in [fixture.bodyID, secondID] {
            let instance = assembly.handle(action: "addInstance", args: ["bodyID": bodyID])
            XCTAssertEqual(instance["ok"] as? Bool, true, "\(instance)")
        }
        let service = CADDrawingService(document: document)
        let created = service.handle(action: "multiViewSheet", args: [
            "bodyIDs": [fixture.bodyID, secondID], "assemblyMode": true,
            "sectionOrigin": [0.0, 5.0, 30.0],
            "sectionNormal": [0.0, 1.0, 0.0], "showDimensions": false, "showCenterlines": false,
        ])
        XCTAssertEqual(created["ok"] as? Bool, true, "\(created)")
        let page = try XCTUnwrap(created["page"] as? [String: Any])
        let pageID = try XCTUnwrap(page["id"] as? String), id = try XCTUnwrap(UUID(uuidString: pageID))
        let views = try XCTUnwrap(page["views"] as? [[String: Any]])
        let cutID = try XCTUnwrap(views.first { $0["kind"] as? String == "section" }?["id"] as? String)
        let parentID = try XCTUnwrap(views.first { $0["kind"] as? String != "section" }?["id"] as? String)
        let parentEdit = service.handle(action: "updateView", args: [
            "pageID": pageID, "viewID": parentID, "viewNormal": [0.0, 0.0, 1.0],
            "viewUp": [1.0, 0.0, 0.0],
        ])
        XCTAssertEqual(parentEdit["ok"] as? Bool, true)
        let path: [String: Any] = ["referenceViewID": parentID, "label": "B",
            "points": [[0.0,5.0,30.0], [110.0,5.0,30.0], [110.0,7.0,30.0], [150.0,7.0,30.0]]]
        let edit = service.handle(action: "updateView", args: [
            "pageID": pageID, "viewID": cutID, "sectionPath": path,
            "sectionHatches": [
                ["materialID": "steel", "angleDegrees": 45.0, "spacingMM": 2.0, "enabled": true],
                ["materialID": "brass", "angleDegrees": -45.0, "spacingMM": 3.0, "enabled": true],
            ],
        ])
        XCTAssertEqual(edit["ok"] as? Bool, true, "\(edit)")
        var geometry = service.pageGeometry(pageID: id)
        XCTAssertEqual(geometry["sectionComplete"] as? Bool, true, "\(geometry)")
        XCTAssertEqual(geometry["outputBlocked"] as? Bool, false)
        let cutRow = try XCTUnwrap((geometry["views"] as? [[String: Any]])?.first { $0["id"] as? String == cutID })
        XCTAssertEqual(cutRow["projectionMethod"] as? String, "occt-brep-offset-section")
        let hatches = (geometry["entities"] as? [[String: Any]] ?? []).filter { $0["layer"] as? String == "hatch" }
        XCTAssertGreaterThan(hatches.count, 10)
        let slopes = hatches.compactMap { row -> Double? in
            guard let a = row["a"] as? [Double], let b = row["b"] as? [Double], a.count == 2, b.count == 2,
                  abs(b[0] - a[0]) > 1e-8 else { return nil }
            return (b[1] - a[1]) / (b[0] - a[0])
        }
        XCTAssertTrue(slopes.contains { abs($0 - 1) < 1e-6 })
        XCTAssertTrue(slopes.contains { abs($0 + 1) < 1e-6 })
        let texts = geometry["texts"] as? [[String: Any]] ?? []
        XCTAssertEqual(texts.filter { $0["text"] as? String == "B" }.count, 2)
        XCTAssertTrue(texts.contains { $0["text"] as? String == "B–B" })
        let marker = try XCTUnwrap((geometry["entities"] as? [[String: Any]])?.first {
            $0["layer"] as? String == "section-mark" && $0["kind"] as? String == "polyline"
        })
        let markPoints = try XCTUnwrap(marker["points"] as? [[Double]])
        XCTAssertEqual(markPoints.count, 4)
        XCTAssertEqual(markPoints[2][1] - markPoints[1][1], 2, accuracy: 1e-6,
                       "the two-mm riser must exist in actual parent-view linework")
        let svg = String(decoding: try service.exportData(pageID: id, format: "svg"), as: UTF8.self)
        let dxf = String(decoding: try service.exportData(pageID: id, format: "dxf"), as: UTF8.self)
        XCTAssertTrue(svg.contains("id=\"HATCH\"")); XCTAssertTrue(svg.contains("B–B"))
        XCTAssertTrue(dxf.contains("8\nHATCH\n")); XCTAssertTrue(dxf.contains("8\nSECTION_MARKS\n"))

        // Changing the path changes BOTH actual stepped cut data and labels;
        // undo restores the one record, including its generated marker.
        var changedPath = path; changedPath["label"] = "C"
        changedPath["points"] = [[0.0,5.0,30.0], [110.0,5.0,30.0], [110.0,8.0,30.0], [150.0,8.0,30.0]]
        let changed = service.handle(action: "updateView", args: ["pageID": pageID, "viewID": cutID, "sectionPath": changedPath])
        XCTAssertEqual(changed["ok"] as? Bool, true)
        let changedGeometry = service.pageGeometry(pageID: id)
        XCTAssertTrue((changedGeometry["texts"] as? [[String: Any]] ?? []).contains { $0["text"] as? String == "C–C" })
        let beforeBounds = try XCTUnwrap(cutRow["localBounds"] as? [[Double]])
        let afterRow = try XCTUnwrap((changedGeometry["views"] as? [[String: Any]])?.first { $0["id"] as? String == cutID })
        let afterBounds = try XCTUnwrap(afterRow["localBounds"] as? [[Double]])
        XCTAssertGreaterThan(afterBounds[1][0], beforeBounds[1][0] + 0.3,
                             "sphere center y20: moving the actual cut from y7 to y8 increases its projected radius")
        XCTAssertEqual(CADParameterService(document: document).handle(action: "undo", args: [:])["ok"] as? Bool, true)
        geometry = service.pageGeometry(pageID: id)
        XCTAssertTrue((geometry["texts"] as? [[String: Any]] ?? []).contains { $0["text"] as? String == "B–B" })
        let badPath: [String: Any] = ["referenceViewID": parentID, "label": "X",
            "points": [[0.0,5.0,30.0], [100.0,7.0,30.0]]]
        let before = document.session.document.drawingsData
        let rejected = service.handle(action: "updateView", args: ["pageID": pageID, "viewID": cutID, "sectionPath": badPath])
        XCTAssertEqual(rejected["error"] as? String, "unsupported_section_path")
        XCTAssertEqual(document.session.document.drawingsData, before)
        let save = await document.save(); XCTAssertTrue(save.succeeded, save.error ?? "")
        document.close()
        let reopened = try await FloeCADDocument.open(at: document.url)
        defer { reopened.close() }
        let reopenedService = CADDrawingService(document: reopened)
        geometry = reopenedService.pageGeometry(pageID: id)
        XCTAssertEqual(geometry["sectionComplete"] as? Bool, true)
        XCTAssertTrue((geometry["texts"] as? [[String: Any]] ?? []).contains { $0["text"] as? String == "B–B" })
        let savedSet = try CADDrawingSet.decode(from: reopened.session.document.drawingsData)
        let savedCut = try XCTUnwrap(savedSet.pages.first?.sheetViews?.first { $0.id.uuidString == cutID })
        XCTAssertEqual(savedCut.sectionPath?.points[2].y, 7)
        XCTAssertEqual(savedCut.sectionHatches.map(\.spacingMM), [2, 3])
        XCTAssertEqual(savedSet.schemaVersion, 6)
    }
}


#if DEBUG
private nonisolated final class DrawingProjectionTestLatch: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var mainThread = true
    func pause() {
        lock.lock(); mainThread = Thread.isMainThread; lock.unlock()
        entered.signal()
        _ = release.wait(timeout: .now() + 10)
    }
    func waitUntilEntered() -> Bool { entered.wait(timeout: .now() + 10) == .success }
    var ranOnMainThread: Bool {
        lock.lock(); defer { lock.unlock() }; return mainThread
    }
}

extension CADDrawingMultiViewAssociativityTests {
    private func awaitWorker(_ latch: DrawingProjectionTestLatch) async -> Bool {
        await Task.detached { latch.waitUntilEntered() }.value
    }

    func testAnnotationWriteRetainsAcceptedWorkerGeometryWithoutMainThreadReprojection() async throws {
        let document = try await makeDocument("E12-annotation-worker")
        defer { document.close() }
        let fixture = try makePlateWithHole(document)
        let service = CADDrawingService(document: document)
        let created = service.handle(action: "addPage", args: [
            "kind": "front", "name": "Annotation worker", "bodyIDs": [fixture.bodyID]])
        let id = try XCTUnwrap(UUID(uuidString: (created["page"] as? [String: Any])?["id"] as? String ?? ""))
        var synchronousFallbacks = 0
        CADDrawingService.testSynchronousProjectionFallbackProbe = { synchronousFallbacks += 1 }
        defer { CADDrawingService.testSynchronousProjectionFallbackProbe = nil }
        let result = await service.handleAsync(action: "addAnnotation", args: [
            "pageID": id.uuidString, "text": "Actual saved annotation", "position": [10.0, 20.0]])
        XCTAssertEqual(result["ok"] as? Bool, true, "\(result)")
        XCTAssertEqual(synchronousFallbacks, 0, "Annotation persistence must not repeat HLR on MainActor")
        XCTAssertEqual(try CADDrawingSet.decode(from: document.session.document.drawingsData).pages.first?.annotations.last?.text,
                       "Actual saved annotation")
        let geometry = await service.pageGeometryAsync(pageID: id)
        XCTAssertEqual(geometry["projectionComplete"] as? Bool, true)
        XCTAssertEqual(synchronousFallbacks, 0)
    }

    func testDrawingWorkerRunsOffMainAndDiscardsCancellation() async throws {
        let document = try await makeDocument("E12-worker-cancel")
        defer { document.close() }
        let fixture = try makePlateWithHole(document)
        let service = CADDrawingService(document: document)
        let created = service.handle(action: "addPage", args: [
            "kind": "front", "name": "Worker", "bodyIDs": [fixture.bodyID],
        ])
        let id = try XCTUnwrap(UUID(uuidString: (created["page"] as? [String: Any])?["id"] as? String ?? ""))
        let original = document.session.document.drawingsData
        let latch = DrawingProjectionTestLatch()
        CADDrawingService.testProjectionWorkerProbe = { latch.pause() }
        defer {
            CADDrawingService.testProjectionWorkerProbe = nil
            CADDrawingService.testProjectionBeforeCommitProbe = nil
            latch.release.signal()
        }
        let request = Task { @MainActor in
            let reply = await service.handleAsync(action: "project", args: ["pageID": id.uuidString])
            return (try? JSONSerialization.data(withJSONObject: reply)) ?? Data()
        }
        let entered = await awaitWorker(latch)
        XCTAssertTrue(entered, "real serial drawing worker never entered")
        XCTAssertFalse(latch.ranOnMainThread)
        // This continuation runs while the native worker is held. If projection
        // had remained synchronous MainActor code it could never get here.
        XCTAssertTrue(Thread.isMainThread)
        request.cancel()
        latch.release.signal()
        let replyBytes = await request.value
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: replyBytes) as? [String: Any])
        XCTAssertEqual(reply["error"] as? String, "drawing_cancelled", "\(reply)")
        XCTAssertEqual(document.session.document.drawingsData, original,
                       "cancelled projection may not publish even cache metadata")
        CADDrawingService.testProjectionWorkerProbe = nil
        let next = await service.pageGeometryAsync(pageID: id)
        XCTAssertEqual(next["projectionMethod"] as? String, "occt-brep-hlr")
        XCTAssertEqual(next["projectionComplete"] as? Bool, true)
        XCTAssertGreaterThan(next["visibleEdgeCount"] as? Int ?? 0, 0)
        XCTAssertFalse((next["entities"] as? [[String: Any]] ?? []).isEmpty)
    }

    func testDrawingWorkerRejectsChangedRevisionAndClosedOwner() async throws {
        let document = try await makeDocument("E14-worker-fence")
        defer { document.close() }
        let fixture = try makePlateWithHole(document)
        let service = CADDrawingService(document: document)
        let created = service.handle(action: "addPage", args: [
            "kind": "front", "name": "Fence", "bodyIDs": [fixture.bodyID],
        ])
        let id = try XCTUnwrap(UUID(uuidString: (created["page"] as? [String: Any])?["id"] as? String ?? ""))
        let latch = DrawingProjectionTestLatch()
        CADDrawingService.testProjectionBeforeCommitProbe = { latch.pause() }
        defer {
            CADDrawingService.testProjectionWorkerProbe = nil
            CADDrawingService.testProjectionBeforeCommitProbe = nil
            latch.release.signal()
        }
        let request = Task { @MainActor in
            let reply = await service.pageGeometryAsync(pageID: id)
            return (try? JSONSerialization.data(withJSONObject: reply)) ?? Data()
        }
        let entered = await awaitWorker(latch)
        XCTAssertTrue(entered, "real projection never reached the post-compute fence")
        XCTAssertFalse(latch.ranOnMainThread)
        let edit = service.handle(action: "updatePage", args: ["pageID": id.uuidString, "title": "New revision"])
        XCTAssertEqual(edit["ok"] as? Bool, true)
        let edited = document.session.document.drawingsData
        latch.release.signal()
        let rejectedBytes = await request.value
        let rejected = try XCTUnwrap(JSONSerialization.jsonObject(with: rejectedBytes) as? [String: Any])
        XCTAssertEqual(rejected["error"] as? String, "drawing_source_changed", "\(rejected)")
        XCTAssertEqual(document.session.document.drawingsData, edited)

        let closedLatch = DrawingProjectionTestLatch()
        CADDrawingService.testProjectionBeforeCommitProbe = { closedLatch.pause() }
        let closing = Task { @MainActor in
            let reply = await service.pageGeometryAsync(pageID: id)
            return (try? JSONSerialization.data(withJSONObject: reply)) ?? Data()
        }
        let closeEntered = await awaitWorker(closedLatch)
        XCTAssertTrue(closeEntered)
        document.close()
        let replacement = try await makeDocument("Replacement owner")
        defer { replacement.close(); closedLatch.release.signal() }
        let replacementBytes = replacement.session.document.drawingsData
        closedLatch.release.signal()
        let closedBytes = await closing.value
        let closed = try XCTUnwrap(JSONSerialization.jsonObject(with: closedBytes) as? [String: Any])
        XCTAssertEqual(closed["error"] as? String, "document_closed", "\(closed)")
        XCTAssertEqual(replacement.session.document.drawingsData, replacementBytes,
                       "an old document result cannot publish into the replacement owner")
    }
}
#endif
