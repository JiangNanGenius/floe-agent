//
//  CADDrawingFormatAdmissionTests.swift
//  FloeCADKitTests
//
//  Drawing-set format admission through the EXISTING package machinery: a
//  document whose drawing set carries genuinely v4 sheet intent (a page with
//  `sheetViews`, or a dimension linked through a `feature` reference) must
//  raise the package floor to 4, because a frozen older build decodes away
//  `sheetViews`, reads a multi-view page's deliberately empty page-level
//  `sourceBodyIDs` and projects/exports a BLANK sheet with no newer-format
//  warning on read/project/export (only its drawing persist guard refuses
//  edits). Older clients open format-4 packages read-only with the existing
//  newer-format message — they may view cached geometry, never pretend to
//  represent or edit the full sheet. Flat/ordinary drawings keep the
//  existing lower floor; the stamped drawing schemaVersion alone is not intent.
//

import XCTest
import Foundation
import Euclid
import simd
@testable import FloeCAD

@MainActor
final class CADDrawingFormatAdmissionTests: XCTestCase {
    private var directory: URL!
    private var documents: [FloeCADDocument] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DrawingFormatAdmission-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for document in documents where !document.isClosed { document.close() }
        documents.removeAll()
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    private func url() -> URL { directory.appendingPathComponent("\(UUID().uuidString).floecad") }

    private func makeBoxDocument(_ name: String) async throws -> (FloeCADDocument, UUID) {
        let document = try await FloeCADDocument.create(at: url(), name: name)
        documents.append(document)
        let spec = PrimitiveSpec.box(width: 10, depth: 12, height: 8)
        var body = Body(name: "Box", euclidMesh: .primitive(spec), revision: 0)
        XCTAssertTrue(body.adoptBRep(try XCTUnwrap(
            OCCTKernel.primitiveShape(spec, placement: .identity))))
        document.session.perform(AddBodyCommand(body: body, title: name))
        return (document, body.id.raw)
    }

    private func manifest(_ url: URL) throws -> CADManifest {
        try JSONDecoder().decode(CADManifest.self,
                                 from: Data(contentsOf: url.appendingPathComponent("manifest.json")))
    }

    // MARK: - Intent inspection on real bytes

    func testFlatDrawingBytesKeepTheExistingLowerFloor() throws {
        let flat = CADDrawingSet.standardSheet(for: UUID(), title: "Flat")
        XCTAssertEqual(try CADDocumentFormat.drawingRequiredVersion(flat.encoded()),
                       CADDocumentFormat.legacyVersion)
        XCTAssertEqual(CADDocumentFormat.drawingRequiredVersion(nil),
                       CADDocumentFormat.legacyVersion)
        XCTAssertEqual(CADDocumentFormat.drawingRequiredVersion(Data()),
                       CADDocumentFormat.legacyVersion)
        // The stamped drawing schemaVersion alone is NOT intent: a flat set
        // written by this build (stamped v4) must not force older clients
        // read-only.
        var stamped = flat
        stamped.schemaVersion = CADDrawingSet.currentSchemaVersion
        XCTAssertEqual(try CADDocumentFormat.drawingRequiredVersion(stamped.encoded()),
                       CADDocumentFormat.legacyVersion)
    }

    func testSharedSheetIntentRaisesTheDrawingFloor() throws {
        let set = CADDrawingSet.multiViewSheet(
            bodyIDs: [UUID()], title: "Shared",
            sectionOrigin: SIMD3(50, 5, 30), sectionNormal: SIMD3(0, 1, 0))
        XCTAssertEqual(try CADDocumentFormat.drawingRequiredVersion(set.encoded()),
                       CADDocumentFormat.drawingSheetViewVersion)
    }

    func testLowerVersionRowsCannotReduceTheRequiredSharedSheetVersion() throws {
        let plane = try CADAssociativeFormatFixture.plane()
        let sketch = Sketch(plane: .ground,
                            support: PlaneRef(source: .construction(plane.id)))
        let encoder = JSONEncoder()
        let planeRow = CADBlobRecord(blobID: plane.id.raw,
                                     data: try encoder.encode(plane), sha256: "")
        let sketchRow = CADBlobRecord(blobID: sketch.id.raw,
                                      data: try encoder.encode(sketch), sha256: "")
        let hole = FeatureKind.hole(
            target: BodyRef(producer: FeatureID(), bodyID: BodyID()),
            profile: ProfileRef(sketchID: sketch.id, entityIDs: [],
                                holeEntityIDs: [], seedPoint: nil),
            plane: PlaneRef(source: .ground), spec: HoleSpec())
        let holeRow = CADFeatureRecord(featureID: UUID(), orderIndex: 0, name: "Hole",
                                       suppressed: false, kind: try encoder.encode(hole),
                                       outputBodyIDs: try encoder.encode([UUID]()))
        let drawing = try CADDrawingSet.multiViewSheet(
            bodyIDs: [UUID()], title: "Shared", sectionOrigin: .zero,
            sectionNormal: SIMD3(0, 1, 0)).encoded()
        for (planes, sketches, features) in [
            ([planeRow], [], []), ([], [sketchRow], []), ([], [], [holeRow]),
            ([planeRow], [sketchRow], [holeRow]),
        ] as [([CADBlobRecord], [CADBlobRecord], [CADFeatureRecord])] {
            let assessment = try CADDocumentFormat.assess(
                planes: planes, sketches: sketches, features: features, drawings: drawing)
            XCTAssertEqual(assessment.requiredVersion, CADDocumentFormat.drawingSheetViewVersion)
            XCTAssertFalse(assessment.isOpaqueReadOnly)
        }
    }

    func testFeatureLinkedDimensionIntentRaisesTheDrawingFloor() throws {
        var page = CADDrawingPage(name: "Sheet", kind: .front, title: "Linked",
                                  sourceBodyIDs: [UUID()])
        let anchor = CADDrawingFeatureAnchor(centroid: SIMD3(50, 30, 5),
                                             direction: SIMD3(0, 0, 1), radiusMM: 5)
        let feature = CADDrawingFeatureReference(
            bodyID: UUID(), anchor: anchor,
            featureID: UUID(), sketchID: UUID(), sketchEntityID: UUID())
        page.manualDimensions.append(CADDrawingManualDimension(
            kind: .diameter, drawingPoints: [], value: 10, textPosition: .zero,
            feature: feature))
        let set = CADDrawingSet(pages: [page])
        XCTAssertEqual(try CADDocumentFormat.drawingRequiredVersion(set.encoded()),
                       CADDocumentFormat.drawingSheetViewVersion)
        // A plain manual dimension on the same page keeps the lower floor.
        var plain = page
        plain.manualDimensions = [CADDrawingManualDimension(
            kind: .diameter, drawingPoints: [], value: 10, textPosition: .zero)]
        XCTAssertEqual(try CADDocumentFormat.drawingRequiredVersion(
            CADDrawingSet(pages: [plain]).encoded()),
            CADDocumentFormat.legacyVersion)
    }

    // MARK: - Package floor through the real store

    func testFlatDrawingPackageKeepsItsLowerFloor() async throws {
        let (document, bodyID) = try await makeBoxDocument("FlatDrawing")
        let service = CADDrawingService(document: document)
        let reply = service.handle(action: "standardSheet",
                                   args: ["bodyID": bodyID.uuidString, "title": "Flat"])
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        let save = await document.save()
        XCTAssertTrue(save.succeeded, save.error ?? "")
        let manifest = try manifest(document.url)
        XCTAssertLessThan(manifest.schemaVersion, CADDocumentFormat.drawingSheetViewVersion,
                          "a flat drawing must not raise the package floor: "
                            + "\(manifest.schemaVersion)")
        document.close()
    }

    func testSharedSheetPackageRaisesFloorToFourAndReopensWritable() async throws {
        let (document, bodyID) = try await makeBoxDocument("SharedSheet")
        let service = CADDrawingService(document: document)
        let reply = service.handle(action: "multiViewSheet", args: [
            "bodyID": bodyID.uuidString, "title": "Shared",
            "sectionOrigin": [5.0, 1.0, 6.0], "sectionNormal": [0.0, 1.0, 0.0],
        ])
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        let pageID = try XCTUnwrap((reply["page"] as? [String: Any])?["id"] as? String)
        let save = await document.save()
        XCTAssertTrue(save.succeeded, save.error ?? "")
        let manifest = try manifest(document.url)
        XCTAssertEqual(manifest.schemaVersion, CADDocumentFormat.drawingSheetViewVersion,
                       "shared-sheet intent must raise the package floor to 4: "
                         + "\(manifest.schemaVersion)")

        // This build supports format 4: the document reopens fully writable
        // and the sheet reads back with every view (no silent intent loss,
        // no fabricated blank sheet).
        document.close()
        let reopened = try await FloeCADDocument.open(at: document.url)
        documents.append(reopened)
        XCTAssertFalse(reopened.isReadOnly)
        XCTAssertEqual(reopened.summary().schemaVersion,
                       CADDocumentFormat.drawingSheetViewVersion)
        let geometry = CADDrawingService(document: reopened).handle(
            action: "project", args: ["pageID": pageID])
        XCTAssertEqual(geometry["ok"] as? Bool, true, "\(geometry)")
        XCTAssertEqual((geometry["views"] as? [[String: Any]])?.count, 4,
                       "the shared sheet must reopen with all four views: \(geometry)")
        reopened.close()
    }
}
