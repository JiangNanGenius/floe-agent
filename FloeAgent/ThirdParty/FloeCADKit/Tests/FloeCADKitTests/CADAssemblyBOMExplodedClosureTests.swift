//
//  CADAssemblyBOMExplodedClosureTests.swift
//  FloeCADKitTests
//
//  Focused E09/E17 regression through the REAL document transaction:
//
//  * two separately named exploded views persist stable IDs and per-instance
//    offsets; preview changes display only and never rewrites base transforms,
//    the assembly JSON or the undo baseline;
//  * a page bound to a named view exports that view (not the transient
//    preview) and blocks export when the saved view is gone;
//  * shared instances of one part definition resolve one engineering
//    part-number/material/version record while an explicit independent copy
//    keeps its own version;
//  * a multi-level BOM counts real occurrence identities (three shared leaves
//    across subassemblies plus one independent copy), does not merge an
//    identical body/name, updates quantities after hierarchy edits and exports
//    material/version/quantity into the vector table;
//  * save/reopen preserves the two views, metadata, BOM rows and balloons and
//    leaves them editable; missing instances stay visible and are never
//    silently rebound to a same-name/same-position replacement.
//
//  Geometry is built through the same typed command vocabulary the App/Agent
//  uses. No fixture invents a parallel geometry or BOM path.
//

import XCTest
import Foundation
import simd
@testable import FloeCAD

@MainActor
final class CADAssemblyBOMExplodedClosureTests: XCTestCase {

    private var workDir: URL!
    private var document: FloeCADDocument!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeCADBOMExploded-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        document = try await FloeCADDocument.create(
            at: workDir.appendingPathComponent("closure.floecad"), name: "Closure")
    }

    override func tearDown() async throws {
        document?.close()
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - Fixtures

    private func run(_ json: String, file: StaticString = #filePath,
                     line: UInt = #line) -> [String: Any] {
        let outcome = document.executeJSON(Data(json.utf8))
        XCTAssertTrue(outcome.isOK,
                      "command failed (\(outcome.status)) \(outcome.errorCode ?? ""): "
                        + "\(outcome.message ?? "") — \(json)",
                      file: file, line: line)
        return (try? JSONSerialization.jsonObject(with: outcome.payload)) as? [String: Any] ?? [:]
    }

    private func makeBox(min: [Double] = [0, 0], max: [Double] = [10, 10],
                         height: Double = 10) throws -> UUID {
        let sketch = try XCTUnwrap(
            run(#"{"op":"sketch.create","args":{"name":"Box"}}"#)["sketchID"] as? String)
        _ = run("""
        {"op":"sketch.addEntities","args":{"sketchID":"\(sketch)",
         "entities":[{"kind":"rect","min":[\(min[0]),\(min[1])],"max":[\(max[0]),\(max[1])]}]}}
        """)
        let response = run("""
        {"op":"feature.extrude","args":{"sketchID":"\(sketch)",
         "seedPoint":[\((min[0] + max[0]) / 2),\((min[1] + max[1]) / 2)],
         "distance":\(height)}}
        """)
        let bodyID = try XCTUnwrap((response["producedBodyIDs"] as? [String])?.first
                                   ?? (response["changedBodyIDs"] as? [String])?.first)
        return try XCTUnwrap(UUID(uuidString: bodyID))
    }

    private func service() -> CADAssemblyService {
        CADAssemblyService(document: document)
    }

    private func addSubassembly(name: String, parentID: String? = nil) throws -> String {
        var args: [String: Any] = ["name": name]
        if let parentID { args["parentID"] = parentID }
        let reply = service().handle(action: "addSubassembly", args: args)
        XCTAssertEqual(reply["ok"] as? Bool, true, reply["message"] as? String ?? "")
        return try XCTUnwrap(reply["id"] as? String)
    }

    private func addInstance(_ bodyID: UUID, name: String, parentID: String? = nil,
                             position: [Double]? = nil,
                             independentCopy: Bool = false) throws -> String {
        var args: [String: Any] = ["bodyID": bodyID.uuidString, "name": name]
        if let parentID { args["parentID"] = parentID }
        if let position { args["transform"] = ["position": position] }
        if independentCopy { args["independentCopy"] = true }
        let reply = service().handle(action: "addInstance", args: args)
        XCTAssertEqual(reply["ok"] as? Bool, true, reply["message"] as? String ?? "")
        return try XCTUnwrap(reply["id"] as? String)
    }

    private func assembly() throws -> CADAssembly {
        try CADAssembly.decode(from: document.session.document.assemblyData)
    }

    private func setPartMetadata(instanceID: String, partNumber: String? = nil,
                                 material: String? = nil, version: String? = nil,
                                 in doc: FloeCADDocument? = nil,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) -> [String: Any] {
        var args: [String: Any] = ["instanceID": instanceID]
        if let partNumber { args["partNumber"] = partNumber }
        if let material { args["material"] = material }
        if let version { args["version"] = version }
        let service = CADAssemblyService(document: doc ?? document)
        let reply = service.handle(action: "setPartMetadata", args: args)
        XCTAssertEqual(reply["ok"] as? Bool, true, reply["message"] as? String ?? "",
                       file: file, line: line)
        return reply
    }

    private func partRow(instanceID: String, in doc: FloeCADDocument? = nil) throws -> [String: Any] {
        let service = CADAssemblyService(document: doc ?? document)
        let reply = service.handle(action: "partMetadata", args: ["instanceID": instanceID])
        XCTAssertEqual(reply["ok"] as? Bool, true, reply["message"] as? String ?? "")
        let rows = try XCTUnwrap(reply["parts"] as? [[String: Any]])
        return try XCTUnwrap(rows.first)
    }

    private func frontPageID(_ reply: [String: Any],
                             file: StaticString = #filePath,
                             line: UInt = #line) throws -> String {
        XCTAssertEqual(reply["ok"] as? Bool, true, reply["message"] as? String ?? "",
                       file: file, line: line)
        let pages = try XCTUnwrap(reply["pages"] as? [[String: Any]])
        return try XCTUnwrap(pages.first { $0["kind"] as? String == "front" }?["id"] as? String)
    }

    private func projectedBounds(_ entities: [[String: Any]])
        -> (min: SIMD2<Double>, max: SIMD2<Double>)? {
        var minPoint = SIMD2<Double>(.greatestFiniteMagnitude, .greatestFiniteMagnitude)
        var maxPoint = SIMD2<Double>(-.greatestFiniteMagnitude, -.greatestFiniteMagnitude)
        var any = false
        func include(_ x: Double, _ y: Double) {
            any = true
            minPoint = simd_min(minPoint, SIMD2(x, y))
            maxPoint = simd_max(maxPoint, SIMD2(x, y))
        }
        for entity in entities {
            let layer = entity["layer"] as? String ?? ""
            if ["balloon", "annotation", "dimension", "bom", "title"].contains(layer) {
                continue
            }
            switch entity["kind"] as? String {
            case "line":
                if let a = entity["a"] as? [Double], a.count == 2 { include(a[0], a[1]) }
                if let b = entity["b"] as? [Double], b.count == 2 { include(b[0], b[1]) }
            case "circle", "arc":
                if let center = entity["center"] as? [Double], center.count == 2,
                   let radius = entity["radius"] as? Double {
                    include(center[0] - radius, center[1] - radius)
                    include(center[0] + radius, center[1] + radius)
                }
            case "polyline":
                for point in (entity["points"] as? [[Double]]) ?? [] where point.count == 2 {
                    include(point[0], point[1])
                }
            default:
                break
            }
        }
        return any ? (minPoint, maxPoint) : nil
    }

    /// The SVG writer keeps BOM borders/lines in `<g id="BOM">` and every
    /// table cell in the separate `<g id="BOM_TEXT">` group. Read the actual
    /// text group; selecting only the rule group can never see a header or a
    /// row value.
    private func bomGroup(_ svg: String) -> String {
        guard let start = svg.range(of: "<g id=\"BOM_TEXT\"") else { return "" }
        let tail = svg[start.lowerBound...]
        guard let end = tail.range(of: "</g>") else { return String(tail) }
        return String(tail[..<end.upperBound])
    }

    // MARK: - E09: two named views, display-only preview, selected-view export

    func testTwoNamedExplodedViewsPreviewExportAndBOMStayConsistent() async throws {
        let bodyID = try makeBox()
        let subA = try addSubassembly(name: "Sub A")
        let subB = try addSubassembly(name: "Sub B")
        let p1 = try addInstance(bodyID, name: "Part 1", parentID: subA, position: [0, 0, 0])
        let p2 = try addInstance(bodyID, name: "Part 2", parentID: subA, position: [20, 0, 0])
        let p3 = try addInstance(bodyID, name: "Part 3", parentID: subB, position: [40, 0, 0])
        let copy = try addInstance(bodyID, name: "Copy", position: [60, 0, 0],
                                   independentCopy: true)

        let viewAReply = service().handle(action: "addExplodedView", args: [
            "name": "Service A",
            "direction": [1.0, 0.0, 0.0],
            "distanceMM": 30.0,
            "entries": [["instanceID": p1], ["instanceID": p2], ["instanceID": p3]],
        ])
        XCTAssertEqual(viewAReply["ok"] as? Bool, true, viewAReply["message"] as? String ?? "")
        let viewA = try XCTUnwrap(viewAReply["id"] as? String)
        let viewBReply = service().handle(action: "addExplodedView", args: [
            "name": "Maintenance B",
            "direction": [0.0, 1.0, 0.0],
            "distanceMM": 15.0,
            "entries": [["instanceID": p1], ["instanceID": copy]],
        ])
        XCTAssertEqual(viewBReply["ok"] as? Bool, true, viewBReply["message"] as? String ?? "")
        let viewB = try XCTUnwrap(viewBReply["id"] as? String)

        let baseAssembly = try assembly()
        let baseTransforms = Dictionary(uniqueKeysWithValues:
            baseAssembly.occurrences(includeHidden: true).map {
                ($0.instance.id, $0.instance.transform)
            })
        let baselineAssembly = try XCTUnwrap(document.session.document.assemblyData)
        let baselineChange = document.session.changeCount

        // Preview is display-only: no transform, JSON or undo mutation.
        let previewA = service().handle(action: "previewExplodedView", args: ["id": viewA])
        XCTAssertEqual(previewA["ok"] as? Bool, true, previewA["message"] as? String ?? "")
        XCTAssertEqual(CADExplodedViewPreview.current(for: document.session)?.viewID?.uuidString,
                       viewA)
        XCTAssertEqual(document.session.changeCount, baselineChange)
        XCTAssertEqual(document.session.document.assemblyData, baselineAssembly)
        var current = try assembly()
        for (id, transform) in baseTransforms {
            XCTAssertEqual(current.instance(id)?.transform, transform)
        }
        let previewB = service().handle(action: "previewExplodedView", args: ["id": viewB])
        XCTAssertEqual(previewB["ok"] as? Bool, true, previewB["message"] as? String ?? "")
        XCTAssertEqual(CADExplodedViewPreview.current(for: document.session)?.viewID?.uuidString,
                       viewB)
        XCTAssertEqual(document.session.changeCount, baselineChange)
        XCTAssertEqual(document.session.document.assemblyData, baselineAssembly)
        current = try assembly()
        for (id, transform) in baseTransforms {
            XCTAssertEqual(current.instance(id)?.transform, transform)
        }
        _ = service().handle(action: "resetExplodedView", args: [:])
        XCTAssertNil(CADExplodedViewPreview.current(for: document.session))

        let drawing = CADDrawingService(document: document)
        let sheetA = drawing.handle(action: "assemblySheet", args: [
            "title": "Service", "explodedViewID": viewA,
        ])
        let pageA = try frontPageID(sheetA)
        let pageAUUIDForBounds = try XCTUnwrap(UUID(uuidString: pageA))
        let baseGeometryA = drawing.pageGeometry(pageID: pageAUUIDForBounds)
        let boundsA = try XCTUnwrap(
            projectedBounds(baseGeometryA["entities"] as? [[String: Any]] ?? []))
        let bomA = drawing.handle(action: "setBOM", args: ["pageID": pageA, "showBOM": true])
        XCTAssertEqual(bomA["ok"] as? Bool, true, bomA["message"] as? String ?? "")
        let rowsA = try XCTUnwrap(bomA["entries"] as? [[String: Any]])
        XCTAssertEqual(rowsA.count, 2, "three shared instances group; the independent copy is separate")
        let sharedRow = try XCTUnwrap(rowsA.first {
            (($0["instanceIDs"] as? [String])?.count ?? 0) == 3
        })
        let copyRow = try XCTUnwrap(rowsA.first {
            (($0["instanceIDs"] as? [String])?.count ?? 0) == 1
        })
        XCTAssertEqual(sharedRow["quantity"] as? Int, 3)
        XCTAssertEqual(copyRow["quantity"] as? Int, 1)
        let sharedItem = try XCTUnwrap(sharedRow["itemNumber"] as? Int)
        let copyItem = try XCTUnwrap(copyRow["itemNumber"] as? Int)

        for instanceID in [p1, p2, p3] {
            let balloon = drawing.handle(action: "addBalloon", args: [
                "pageID": pageA, "itemNumber": sharedItem, "instanceID": instanceID,
            ])
            XCTAssertEqual(balloon["ok"] as? Bool, true, balloon["message"] as? String ?? "")
        }
        let copyBalloon = drawing.handle(action: "addBalloon", args: [
            "pageID": pageA, "itemNumber": copyItem, "instanceID": copy,
        ])
        XCTAssertEqual(copyBalloon["ok"] as? Bool, true, copyBalloon["message"] as? String ?? "")

        let pageAUUID = try XCTUnwrap(UUID(uuidString: pageA))
        let geometryA = drawing.pageGeometry(pageID: pageAUUID)
        XCTAssertEqual(geometryA["ok"] as? Bool, true, geometryA["message"] as? String ?? "")
        let balloonsA = try XCTUnwrap(geometryA["balloons"] as? [[String: Any]])
        XCTAssertEqual(balloonsA.count, 4)
        XCTAssertEqual(balloonsA.filter { ($0["invalid"] as? Bool) == true }.count, 0)
        XCTAssertEqual(Set(balloonsA.compactMap { $0["instanceID"] as? String }),
                       Set([p1, p2, p3, copy]))
        let sharedBalloons = balloonsA.filter { ($0["itemNumber"] as? Int) == sharedItem }
        XCTAssertEqual(sharedBalloons.count, 3)
        XCTAssertEqual(Set(sharedBalloons.compactMap { $0["instanceID"] as? String }),
                       Set([p1, p2, p3]))
        XCTAssertEqual(Set(sharedRow["instanceIDs"] as? [String] ?? []), Set([p1, p2, p3]))
        XCTAssertEqual(Set(copyRow["instanceIDs"] as? [String] ?? []), Set([copy]))
        let liveBOM = try XCTUnwrap((geometryA["bom"] as? [String: Any])?["entries"]
            as? [[String: Any]])
        XCTAssertEqual(liveBOM.first { ($0["itemNumber"] as? Int) == sharedItem }?["quantity"] as? Int,
                       3)
        XCTAssertEqual(liveBOM.first { ($0["itemNumber"] as? Int) == copyItem }?["quantity"] as? Int,
                       1)
        let sheetB = drawing.handle(action: "assemblySheet", args: [
            "title": "Maintenance", "explodedViewID": viewB,
        ])
        let pageB = try frontPageID(sheetB)
        let pageBUUID = try XCTUnwrap(UUID(uuidString: pageB))
        let geometryB = drawing.pageGeometry(pageID: pageBUUID)
        XCTAssertEqual(geometryB["ok"] as? Bool, true, geometryB["message"] as? String ?? "")
        let boundsB = try XCTUnwrap(projectedBounds(geometryB["entities"] as? [[String: Any]] ?? []))
        XCTAssertEqual(boundsA.min.x - boundsB.min.x, 30, accuracy: 1e-3,
                       "each page must project its own named view's x offset")
        let bomB = drawing.handle(action: "setBOM", args: ["pageID": pageB, "showBOM": true])
        XCTAssertEqual(bomB["ok"] as? Bool, true, bomB["message"] as? String ?? "")
        let rowsB = try XCTUnwrap(bomB["entries"] as? [[String: Any]])
        let sharedRowB = try XCTUnwrap(rowsB.first {
            (($0["instanceIDs"] as? [String])?.count ?? 0) == 3
        })
        let copyRowB = try XCTUnwrap(rowsB.first {
            (($0["instanceIDs"] as? [String])?.count ?? 0) == 1
        })
        let sharedItemB = try XCTUnwrap(sharedRowB["itemNumber"] as? Int)
        let copyItemB = try XCTUnwrap(copyRowB["itemNumber"] as? Int)
        _ = drawing.handle(action: "addBalloon", args: [
            "pageID": pageB, "itemNumber": sharedItemB, "instanceID": p1,
        ])
        _ = drawing.handle(action: "addBalloon", args: [
            "pageID": pageB, "itemNumber": copyItemB, "instanceID": copy,
        ])
        let geometryBFull = drawing.pageGeometry(pageID: pageBUUID)
        XCTAssertEqual((geometryBFull["balloons"] as? [[String: Any]])?.count, 2)

        // The transient viewport preview never changes a page's selected view.
        _ = service().handle(action: "previewExplodedView", args: ["id": viewB])
        let geometryAAfterPreview = drawing.pageGeometry(pageID: pageAUUID)
        let boundsAAfterPreview = try XCTUnwrap(
            projectedBounds(geometryAAfterPreview["entities"] as? [[String: Any]] ?? []))
        XCTAssertEqual(boundsAAfterPreview.min.x, boundsA.min.x, accuracy: 1e-9)
        let svgA = try drawing.exportData(pageID: pageAUUID, format: "svg")
        let svgAText = try XCTUnwrap(String(data: svgA, encoding: .utf8))
        XCTAssertTrue(svgAText.contains("Service A"),
                      "the exported sheet must name the frozen selected view")
        let groupA = bomGroup(svgAText)
        XCTAssertTrue(groupA.contains("Qty"))
        XCTAssertTrue(groupA.contains("3"))
        XCTAssertTrue(groupA.contains("Part no."))
        let dxfA = try drawing.exportData(pageID: pageAUUID, format: "dxf")
        let dxfAText = try XCTUnwrap(String(data: dxfA, encoding: .utf8))
        XCTAssertTrue(dxfAText.contains("Qty"))
        XCTAssertTrue(dxfAText.contains("Part no."))
        XCTAssertTrue(dxfAText.contains("ANNOTATIONS"))
        XCTAssertLessThan(CADDocumentFormat.requiredFormat(document: document.session.document),
                          CADDocumentFormat.partMetadataVersion,
                          "saved exploded views alone must not raise the next part-metadata floor")

        _ = service().handle(action: "previewExplodedView", args: ["id": viewA])
        let geometryBAfterPreview = drawing.pageGeometry(pageID: pageBUUID)
        let boundsBAfterPreview = try XCTUnwrap(
            projectedBounds(geometryBAfterPreview["entities"] as? [[String: Any]] ?? []))
        XCTAssertEqual(boundsBAfterPreview.min.x, boundsB.min.x, accuracy: 1e-9)
        let svgB = try drawing.exportData(pageID: pageBUUID, format: "svg")
        let svgBText = try XCTUnwrap(String(data: svgB, encoding: .utf8))
        XCTAssertTrue(svgBText.contains("Maintenance B"))
        let groupB = bomGroup(svgBText)
        XCTAssertTrue(groupB.contains("Qty"))
        XCTAssertTrue(groupB.contains("3"))
        _ = service().handle(action: "resetExplodedView", args: [:])

        // Save/reopen: both views, base placements and the page annotations
        // survive; the transient preview does not.
        let saved = await document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        document.close()
        let reopened = try await FloeCADDocument.open(at: document.url)
        defer { reopened.close() }
        XCTAssertNil(CADExplodedViewPreview.current(for: reopened.session))
        let reopenedAssembly = try CADAssembly.decode(from: reopened.session.document.assemblyData)
        XCTAssertEqual(reopenedAssembly.explodedViews.count, 2)
        let reopenedViewA = try XCTUnwrap(
            reopenedAssembly.explodedView(UUID(uuidString: viewA)!))
        let originalViewA = try XCTUnwrap(
            baseAssembly.explodedView(UUID(uuidString: viewA)!))
        XCTAssertEqual(reopenedViewA.name, "Service A")
        XCTAssertEqual(reopenedViewA.entries.map(\.id), originalViewA.entries.map(\.id))
        XCTAssertEqual(Set(reopenedViewA.entries.map(\.instanceID)),
                       Set([p1, p2, p3].compactMap { UUID(uuidString: $0) }))
        XCTAssertEqual(reopenedAssembly.explodedView(UUID(uuidString: viewB)!)?.name,
                       "Maintenance B")
        for (id, transform) in baseTransforms {
            XCTAssertEqual(reopenedAssembly.instance(id)?.transform, transform)
        }
        let reopenedDrawing = CADDrawingService(document: reopened)
        let reopenedGeometry = reopenedDrawing.pageGeometry(pageID: pageAUUID)
        XCTAssertEqual((reopenedGeometry["balloons"] as? [[String: Any]])?.count, 4)
        XCTAssertEqual((reopenedGeometry["bom"] as? [String: Any])?["entryCount"] as? Int, 2)

        // Continue editing after reopen, with one-command undo for a rename.
        let reopenedService = CADAssemblyService(document: reopened)
        let beforeRename = try XCTUnwrap(reopened.session.document.assemblyData)
        let rename = reopenedService.handle(action: "updateExplodedView", args: [
            "id": viewA, "name": "Service A revised",
        ])
        XCTAssertEqual(rename["ok"] as? Bool, true, rename["message"] as? String ?? "")
        XCTAssertEqual((try CADAssembly.decode(from: reopened.session.document.assemblyData))
            .explodedView(UUID(uuidString: viewA)!)?.name, "Service A revised")
        reopened.session.undo()
        XCTAssertEqual(reopened.session.document.assemblyData, beforeRename)
        reopened.session.redo()
        XCTAssertEqual((try CADAssembly.decode(from: reopened.session.document.assemblyData))
            .explodedView(UUID(uuidString: viewA)!)?.name, "Service A revised")
        let more = reopenedDrawing.handle(action: "addBalloon", args: [
            "pageID": pageA, "itemNumber": sharedItem, "instanceID": p1,
        ])
        XCTAssertEqual(more["ok"] as? Bool, true, more["message"] as? String ?? "")
        let redrive = reopenedDrawing.handle(action: "setBOM", args: ["pageID": pageA])
        XCTAssertEqual(redrive["ok"] as? Bool, true, redrive["message"] as? String ?? "")
    }

    // MARK: - E17: shared engineering metadata, independent version, multi-level BOM

    func testSharedPartMetadataIndependentVersionAndHierarchyBOMQuantities() async throws {
        let bodyID = try makeBox()
        let subA = try addSubassembly(name: "Sub A")
        let subB = try addSubassembly(name: "Sub B")
        let shared1 = try addInstance(bodyID, name: "Part 1", parentID: subA,
                                      position: [0, 0, 0])
        let shared2 = try addInstance(bodyID, name: "Part 2", parentID: subA,
                                      position: [20, 0, 0])
        let shared3 = try addInstance(bodyID, name: "Part 3", parentID: subB,
                                      position: [40, 0, 0])
        let copy = try addInstance(bodyID, name: "Copy", position: [60, 0, 0],
                                   independentCopy: true)

        _ = setPartMetadata(instanceID: shared1, partNumber: "PN-100",
                            material: "6061-T6", version: "A")
        var shared = try partRow(instanceID: shared1)
        XCTAssertEqual(shared["instanceCount"] as? Int, 3)
        XCTAssertEqual(shared["sharedInstanceCount"] as? Int, 3)
        XCTAssertEqual(shared["partNumber"] as? String, "PN-100")
        XCTAssertEqual(shared["material"] as? String, "6061-T6")
        XCTAssertEqual(shared["version"] as? String, "A")
        var copyRow = try partRow(instanceID: copy)
        XCTAssertEqual(copyRow["instanceCount"] as? Int, 1)
        XCTAssertEqual(copyRow["independentCopyCount"] as? Int, 1)
        XCTAssertEqual(copyRow["partNumber"] as? String, "")
        XCTAssertEqual(copyRow["version"] as? String, "")

        _ = setPartMetadata(instanceID: copy, partNumber: "PN-900-C",
                            material: "Steel", version: "B")
        _ = setPartMetadata(instanceID: shared2, partNumber: "PN-101",
                            material: "7075-T6", version: "C")
        shared = try partRow(instanceID: shared3)
        XCTAssertEqual(shared["partNumber"] as? String, "PN-101")
        XCTAssertEqual(shared["material"] as? String, "7075-T6")
        XCTAssertEqual(shared["version"] as? String, "C")
        copyRow = try partRow(instanceID: copy)
        XCTAssertEqual(copyRow["partNumber"] as? String, "PN-900-C")
        XCTAssertEqual(copyRow["material"] as? String, "Steel")
        XCTAssertEqual(copyRow["version"] as? String, "B",
                       "an explicit independent version survives a shared-source edit")

        // Same geometry and same display name, but a distinct body/definition:
        // the BOM must keep a separate row instead of merging by name/geometry.
        let otherBody = try makeBox()
        let other = try addInstance(otherBody, name: "Part 1", position: [80, 0, 0])

        let drawing = CADDrawingService(document: document)
        let sheet = drawing.handle(action: "assemblySheet", args: ["title": "Assembly"])
        let pageID = try frontPageID(sheet)
        let bom = drawing.handle(action: "setBOM", args: ["pageID": pageID, "showBOM": true])
        XCTAssertEqual(bom["ok"] as? Bool, true, bom["message"] as? String ?? "")
        let rows = try XCTUnwrap(bom["entries"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(Set(rows.compactMap { $0["partDefinitionID"] as? String }).count, 3)
        let sharedBOM = try XCTUnwrap(rows.first {
            ($0["partDefinitionID"] as? String) == bodyID.uuidString
        })
        XCTAssertEqual(sharedBOM["quantity"] as? Int, 3)
        XCTAssertEqual(sharedBOM["partNumber"] as? String, "PN-101")
        XCTAssertEqual(sharedBOM["material"] as? String, "7075-T6")
        XCTAssertEqual(sharedBOM["version"] as? String, "C")
        let copyBodyID = try XCTUnwrap(try assembly().instance(UUID(uuidString: copy)!)?.copiedBodyID)
        let copyBOM = try XCTUnwrap(rows.first {
            ($0["partDefinitionID"] as? String) == copyBodyID.uuidString
        })
        XCTAssertEqual(copyBOM["quantity"] as? Int, 1)
        XCTAssertEqual(copyBOM["partNumber"] as? String, "PN-900-C")
        XCTAssertEqual(copyBOM["material"] as? String, "Steel")
        XCTAssertEqual(copyBOM["version"] as? String, "B")
        let otherBOM = try XCTUnwrap(rows.first {
            ($0["partDefinitionID"] as? String) == otherBody.uuidString
        })
        XCTAssertEqual(otherBOM["quantity"] as? Int, 1)
        XCTAssertEqual(otherBOM["instanceIDs"] as? [String], [other])

        // The vector BOM table carries the live engineering columns.
        let pageUUID = try XCTUnwrap(UUID(uuidString: pageID))
        let svg = try drawing.exportData(pageID: pageUUID, format: "svg")
        let svgText = try XCTUnwrap(String(data: svg, encoding: .utf8))
        let group = bomGroup(svgText)
        XCTAssertTrue(group.contains("Material"))
        XCTAssertTrue(group.contains("Rev"))
        XCTAssertTrue(group.contains("Part no."))
        XCTAssertTrue(group.contains("PN-101"))
        XCTAssertTrue(group.contains("7075-T6"))
        XCTAssertTrue(group.contains("PN-900-C"))
        XCTAssertTrue(group.contains("Steel"))

        // Multi-level quantity: removing one nested shared leaf updates the
        // count while the row id/item number stay stable.
        let sharedRowID = try XCTUnwrap(sharedBOM["id"] as? String)
        let sharedItem = try XCTUnwrap(sharedBOM["itemNumber"] as? Int)
        _ = service().handle(action: "removeInstance", args: ["id": shared3])
        var redriven = drawing.handle(action: "setBOM", args: ["pageID": pageID])
        XCTAssertEqual(redriven["ok"] as? Bool, true, redriven["message"] as? String ?? "")
        var redrivenRows = try XCTUnwrap(redriven["entries"] as? [[String: Any]])
        var redrivenShared = try XCTUnwrap(redrivenRows.first {
            ($0["id"] as? String) == sharedRowID
        })
        XCTAssertEqual(redrivenShared["quantity"] as? Int, 2)
        XCTAssertEqual(redrivenShared["itemNumber"] as? Int, sharedItem)
        let shared4 = try addInstance(bodyID, name: "Part 4", parentID: subB,
                                      position: [40, 0, 0])
        redriven = drawing.handle(action: "setBOM", args: ["pageID": pageID])
        redrivenRows = try XCTUnwrap(redriven["entries"] as? [[String: Any]])
        redrivenShared = try XCTUnwrap(redrivenRows.first {
            ($0["id"] as? String) == sharedRowID
        })
        XCTAssertEqual(redrivenShared["quantity"] as? Int, 3)
        XCTAssertEqual(redrivenShared["itemNumber"] as? Int, sharedItem)
        XCTAssertTrue((redrivenShared["instanceIDs"] as? [String] ?? []).contains(shared4))

        // A deleted instance stays a visible missing association. A replacement
        // with the same body/name/position is NOT silently substituted before
        // an explicit re-derive.
        let balloon = drawing.handle(action: "addBalloon", args: [
            "pageID": pageID, "itemNumber": sharedItem, "instanceID": shared4,
        ])
        XCTAssertEqual(balloon["ok"] as? Bool, true, balloon["message"] as? String ?? "")
        _ = service().handle(action: "removeInstance", args: ["id": shared4])
        let missingGeometry = drawing.pageGeometry(pageID: pageUUID)
        let missingRows = try XCTUnwrap((missingGeometry["bom"] as? [String: Any])?["entries"]
            as? [[String: Any]])
        let missingShared = try XCTUnwrap(missingRows.first {
            ($0["id"] as? String) == sharedRowID
        })
        XCTAssertEqual(missingShared["stale"] as? Bool, true)
        XCTAssertEqual(missingShared["quantity"] as? Int, 2)
        XCTAssertTrue((missingShared["missingInstanceIDs"] as? [String] ?? []).contains(shared4))
        let missingBalloon = try XCTUnwrap((missingGeometry["balloons"] as? [[String: Any]])?
            .first { ($0["instanceID"] as? String) == shared4 })
        XCTAssertEqual(missingBalloon["invalid"] as? Bool, true)

        let replacement = try addInstance(bodyID, name: "Part 4", parentID: subB,
                                          position: [40, 0, 0])
        let beforeRedrive = drawing.pageGeometry(pageID: pageUUID)
        let beforeRows = try XCTUnwrap((beforeRedrive["bom"] as? [String: Any])?["entries"]
            as? [[String: Any]])
        let beforeShared = try XCTUnwrap(beforeRows.first {
            ($0["id"] as? String) == sharedRowID
        })
        XCTAssertTrue((beforeShared["missingInstanceIDs"] as? [String] ?? []).contains(shared4))
        XCTAssertFalse((beforeShared["instanceIDs"] as? [String] ?? []).contains(replacement))
        XCTAssertFalse((beforeShared["liveInstanceIDs"] as? [String] ?? []).contains(replacement))
        let recovered = drawing.handle(action: "setBOM", args: ["pageID": pageID])
        XCTAssertEqual(recovered["ok"] as? Bool, true, recovered["message"] as? String ?? "")
        let recoveredRows = try XCTUnwrap(recovered["entries"] as? [[String: Any]])
        let recoveredShared = try XCTUnwrap(recoveredRows.first {
            ($0["id"] as? String) == sharedRowID
        })
        XCTAssertEqual(recoveredShared["quantity"] as? Int, 3)
        XCTAssertTrue((recoveredShared["missingInstanceIDs"] as? [String] ?? []).isEmpty)
        XCTAssertTrue((recoveredShared["instanceIDs"] as? [String] ?? []).contains(replacement))

        // Save/reopen keeps the engineering records and BOM; later shared edits
        // propagate live, then become explicit only on re-derive.
        let saved = await document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        document.close()
        let reopened = try await FloeCADDocument.open(at: document.url)
        defer { reopened.close() }
        let reopenedAssemblyService = CADAssemblyService(document: reopened)
        let reopenedPart = reopenedAssemblyService.handle(action: "partMetadata", args: [
            "definitionID": bodyID.uuidString,
        ])
        let reopenedRows = try XCTUnwrap(reopenedPart["parts"] as? [[String: Any]])
        let reopenedShared = try XCTUnwrap(reopenedRows.first)
        XCTAssertEqual(reopenedShared["partNumber"] as? String, "PN-101")
        XCTAssertEqual(reopenedShared["material"] as? String, "7075-T6")
        XCTAssertEqual(reopenedShared["version"] as? String, "C")
        XCTAssertEqual(reopenedShared["instanceCount"] as? Int, 3)
        let reopenedCopy = reopenedAssemblyService.handle(action: "partMetadata", args: [
            "definitionID": copyBodyID.uuidString,
        ])
        XCTAssertEqual((reopenedCopy["parts"] as? [[String: Any]])?.first?["version"] as? String,
                       "B")
        let reopenedDrawing = CADDrawingService(document: reopened)
        let reopenedGeometry = reopenedDrawing.pageGeometry(pageID: pageUUID)
        let reopenedBOM = try XCTUnwrap((reopenedGeometry["bom"] as? [String: Any])?["entries"]
            as? [[String: Any]])
        let persistedShared = try XCTUnwrap(reopenedBOM.first {
            ($0["partDefinitionID"] as? String) == bodyID.uuidString
        })
        XCTAssertEqual(persistedShared["material"] as? String, "7075-T6")
        XCTAssertEqual(persistedShared["version"] as? String, "C")
        XCTAssertEqual(persistedShared["quantity"] as? Int, 3)

        _ = setPartMetadata(instanceID: shared1, partNumber: "PN-102", in: reopened)
        let liveMetadata = reopenedDrawing.pageGeometry(pageID: pageUUID)
        let liveRows = try XCTUnwrap((liveMetadata["bom"] as? [String: Any])?["entries"]
            as? [[String: Any]])
        let liveShared = try XCTUnwrap(liveRows.first {
            ($0["partDefinitionID"] as? String) == bodyID.uuidString
        })
        XCTAssertEqual(liveShared["partNumber"] as? String, "PN-102")
        XCTAssertEqual(liveShared["metadataChanged"] as? Bool, true)
        XCTAssertEqual(liveShared["stale"] as? Bool, true)
        let recaptured = reopenedDrawing.handle(action: "setBOM", args: ["pageID": pageID])
        XCTAssertEqual(recaptured["ok"] as? Bool, true, recaptured["message"] as? String ?? "")
        let recapturedRows = try XCTUnwrap(recaptured["entries"] as? [[String: Any]])
        let recapturedShared = try XCTUnwrap(recapturedRows.first {
            ($0["partDefinitionID"] as? String) == bodyID.uuidString
        })
        XCTAssertEqual(recapturedShared["partNumber"] as? String, "PN-102")
        XCTAssertEqual(recapturedShared["metadataChanged"] as? Bool, false)
        XCTAssertEqual(recapturedShared["stale"] as? Bool, false)
        let copyStill = reopenedAssemblyService.handle(action: "partMetadata", args: [
            "definitionID": copyBodyID.uuidString,
        ])
        XCTAssertEqual((copyStill["parts"] as? [[String: Any]])?.first?["version"] as? String, "B")

        // One command per metadata edit; a shared edit cannot change the
        // independent copy's version.
        let beforeUndo = try XCTUnwrap(reopened.session.document.assemblyData)
        _ = setPartMetadata(instanceID: shared1, partNumber: "PN-103", in: reopened)
        reopened.session.undo()
        XCTAssertEqual(try CADAssembly.decode(from: reopened.session.document.assemblyData)
            .partMetadataRecord(bodyID)?.partNumber, "PN-102")
        reopened.session.redo()
        XCTAssertEqual(try CADAssembly.decode(from: reopened.session.document.assemblyData)
            .partMetadataRecord(bodyID)?.partNumber, "PN-103")
        let afterUndoMeta = reopenedAssemblyService.handle(action: "partMetadata", args: [
            "definitionID": copyBodyID.uuidString,
        ])
        XCTAssertEqual((afterUndoMeta["parts"] as? [[String: Any]])?.first?["version"] as? String,
                       "B")

        // Next-floor admission: only the new association raises it; legacy
        // assembly JSON still decodes with empty metadata.
        let assessment = try CADDocumentFormat.assess(
            planes: [], sketches: [], features: [],
            assembly: reopened.session.document.assemblyData)
        XCTAssertEqual(assessment.requiredVersion, CADDocumentFormat.partMetadataVersion)
        XCTAssertEqual(CADDocumentFormat.requiredFormat(document: reopened.session.document),
                       CADDocumentFormat.partMetadataVersion)
        XCTAssertGreaterThanOrEqual(CADDocumentFormat.supportedVersion,
                                    assessment.requiredVersion)
        let legacy = try CADAssembly.decode(
            from: Data(#"{"instances":[],"constraints":[]}"#.utf8))
        XCTAssertTrue(legacy.partMetadata.isEmpty)
        XCTAssertFalse(legacy.requiresPartMetadataFormat)
    }

    // MARK: - E09 edge: missing named view is visible, blocks export, undoable

    func testRemovingNamedViewIsUndoableAndBlocksExportWithoutRebinding() throws {
        let bodyID = try makeBox()
        let instanceID = try addInstance(bodyID, name: "Part", position: [0, 0, 0])
        let added = service().handle(action: "addExplodedView", args: [
            "name": "One", "direction": [1.0, 0.0, 0.0], "distanceMM": 25.0,
            "entries": [["instanceID": instanceID]],
        ])
        XCTAssertEqual(added["ok"] as? Bool, true, added["message"] as? String ?? "")
        let viewID = try XCTUnwrap(added["id"] as? String)
        let baseTransform = try XCTUnwrap(try assembly().instance(
            UUID(uuidString: instanceID)!)?.transform)

        let drawing = CADDrawingService(document: document)
        let sheet = drawing.handle(action: "assemblySheet", args: [
            "title": "One", "explodedViewID": viewID,
        ])
        let pageID = try frontPageID(sheet)
        let pageUUID = try XCTUnwrap(UUID(uuidString: pageID))
        _ = drawing.handle(action: "setBOM", args: ["pageID": pageID, "showBOM": true])
        let balloon = drawing.handle(action: "addBalloon", args: [
            "pageID": pageID, "itemNumber": 1, "instanceID": instanceID,
        ])
        XCTAssertEqual(balloon["ok"] as? Bool, true, balloon["message"] as? String ?? "")
        XCTAssertNoThrow(try drawing.exportData(pageID: pageUUID, format: "svg"))

        let removed = service().handle(action: "removeExplodedView", args: ["id": viewID])
        XCTAssertEqual(removed["ok"] as? Bool, true, removed["message"] as? String ?? "")
        let missing = drawing.pageGeometry(pageID: pageUUID)
        XCTAssertEqual(missing["missingExplodedView"] as? Bool, true)
        XCTAssertEqual(missing["outputBlocked"] as? Bool, true)
        XCTAssertEqual((missing["explodedView"] as? [String: Any])?["found"] as? Bool, false)
        XCTAssertThrowsError(try drawing.exportData(pageID: pageUUID, format: "svg")) { error in
            XCTAssertEqual((error as? CADDocumentError)?.code, "missing_exploded_view")
        }

        document.session.undo()
        XCTAssertEqual(try assembly().explodedViews.count, 1)
        XCTAssertEqual(try assembly().instance(UUID(uuidString: instanceID)!)?.transform,
                       baseTransform)
        let restored = drawing.pageGeometry(pageID: pageUUID)
        XCTAssertEqual(restored["missingExplodedView"] as? Bool, false)
        XCTAssertEqual(restored["outputBlocked"] as? Bool, false)
        XCTAssertNoThrow(try drawing.exportData(pageID: pageUUID, format: "svg"))
        XCTAssertEqual((restored["balloons"] as? [[String: Any]])?.count, 1)

        let beforeRename = try XCTUnwrap(document.session.document.assemblyData)
        _ = service().handle(action: "updateExplodedView", args: [
            "id": viewID, "name": "Renamed",
        ])
        XCTAssertEqual(try assembly().explodedView(UUID(uuidString: viewID)!)?.name, "Renamed")
        document.session.undo()
        XCTAssertEqual(document.session.document.assemblyData, beforeRename)
        XCTAssertEqual(try assembly().instance(UUID(uuidString: instanceID)!)?.transform,
                       baseTransform)
    }
}
