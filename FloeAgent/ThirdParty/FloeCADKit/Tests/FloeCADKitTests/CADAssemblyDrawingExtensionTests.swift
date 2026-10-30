//
//  CADAssemblyDrawingExtensionTests.swift
//  FloeCADKitTests
//
//  Focused contract tests for the assembly-selection / exploded-view and
//  assembly-aware drawing stage. Geometry is built through the same typed
//  command vocabulary the AI tool uses; assertions read real transforms,
//  projected coordinates, BOM quantities and exported vector bytes.
//

import XCTest
import Foundation
import simd
@testable import FloeCAD

final class CADAssemblyDrawingExtensionTests: XCTestCase {

    private var workDir: URL!
    private var document: FloeCADDocument!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeCADAssemblyDrawing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        document = try await FloeCADDocument.create(
            at: workDir.appendingPathComponent("extension.floecad"), name: "Extension")
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

    /// One extruded box; ground rect maps to world X/Z, extrusion is +Y.
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

    private func addInstance(_ bodyID: UUID, name: String? = nil,
                             position: [Double]? = nil,
                             independentCopy: Bool = false) throws -> String {
        var args: [String: Any] = ["bodyID": bodyID.uuidString]
        if let name { args["name"] = name }
        if let position { args["transform"] = ["position": position] }
        if independentCopy { args["independentCopy"] = true }
        let reply = service().handle(action: "addInstance", args: args)
        XCTAssertEqual(reply["ok"] as? Bool, true, reply["message"] as? String ?? "")
        return try XCTUnwrap(reply["id"] as? String)
    }

    private func assembly() throws -> CADAssembly {
        try CADAssembly.decode(from: document.session.document.assemblyData)
    }

    private func drawingSet() throws -> CADDrawingSet {
        try CADDrawingSet.decode(from: document.session.document.drawingsData)
    }

    private func body(_ id: UUID) throws -> Body {
        try XCTUnwrap(document.session.document.bodies.first { $0.id.raw == id })
    }

    /// A real geometry update: a body replacement with a fresh mesh revision,
    /// through the same command lifecycle every edit uses.
    private func bumpBodyRevision(_ id: UUID) throws {
        let before = try body(id)
        var after = Body(id: before.id, name: before.name, transform: before.transform,
                         primitive: before.primitive, render: before.render,
                         revision: before.meshRevision + 1)
        after.edges = before.edges
        after.brep = before.brep
        after.material = before.material
        after.isHidden = before.isHidden
        document.session.perform(ReplaceBodyCommand(title: "Test revision bump",
                                                    before: before, after: after))
    }

    private func topFacePick(_ bodyID: UUID) throws -> CADSelectionContext.FaceTrianglePick {
        let body = try body(bodyID)
        let positions = body.render.positions
        let indices = body.render.indices
        var triangles: [Int] = []
        for triangle in 0..<body.render.triangleCount {
            let i0 = Int(indices[triangle * 3])
            let i1 = Int(indices[triangle * 3 + 1])
            let i2 = Int(indices[triangle * 3 + 2])
            let a = SIMD3<Double>(positions[i0])
            let b = SIMD3<Double>(positions[i1])
            let c = SIMD3<Double>(positions[i2])
            let normal = simd_cross(b - a, c - a)
            guard simd_length(normal) > 1e-9 else { continue }
            if simd_dot(simd_normalize(normal), SIMD3(0, 1, 0)) > 0.95 {
                triangles.append(triangle)
            }
        }
        XCTAssertFalse(triangles.isEmpty, "the box fixture must expose a +Y planar face")
        return CADSelectionContext.FaceTrianglePick(bodyID: bodyID, triangles: triangles,
                                                    curved: false)
    }

    private func page(named name: String, in set: CADDrawingSet) throws -> CADDrawingPage {
        try XCTUnwrap(set.pages.first { $0.name == name })
    }

    private func projectedBounds(_ entities: [[String: Any]]) -> (min: SIMD2<Double>, max: SIMD2<Double>)? {
        var minPoint = SIMD2<Double>(.greatestFiniteMagnitude, .greatestFiniteMagnitude)
        var maxPoint = SIMD2<Double>(-.greatestFiniteMagnitude, -.greatestFiniteMagnitude)
        var any = false
        func include(_ x: Double, _ y: Double) {
            any = true
            minPoint = simd_min(minPoint, SIMD2(x, y))
            maxPoint = simd_max(maxPoint, SIMD2(x, y))
        }
        for entity in entities {
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

    // MARK: - Exploded views

    func testExplodedViewsPersistPreviewWithoutMutatingBaseGeometry() throws {
        let bodyID = try makeBox()
        let first = try addInstance(bodyID, name: "A", position: [0, 0, 0])
        let second = try addInstance(bodyID, name: "B", position: [30, 0, 0])
        let before = try assembly()

        let add = service().handle(action: "addExplodedView", args: [
            "name": "Service",
            "direction": [1, 0, 0],
            "distanceMM": 20,
            "entries": [
                ["instanceID": first, "distanceMM": 25],
                ["instanceID": second, "direction": [0, 1, 0], "distanceMM": 10],
            ],
        ])
        XCTAssertEqual(add["ok"] as? Bool, true, add["message"] as? String ?? "")
        let viewID = try XCTUnwrap(UUID(uuidString: add["id"] as? String ?? ""))
        let persisted = try XCTUnwrap(try assembly().explodedView(viewID))
        XCTAssertEqual(persisted.entries.count, 2)
        XCTAssertEqual(persisted.entry(for: UUID(uuidString: second)!)?.direction,
                       SIMD3(0, 1, 0))

        // Preview returns transient placements and never rewrites the base
        // instance transforms.
        let preview = service().handle(action: "previewExplodedView", args: ["id": viewID.uuidString])
        XCTAssertEqual(preview["ok"] as? Bool, true, preview["message"] as? String ?? "")
        XCTAssertEqual(preview["mutated"] as? Bool, false)
        XCTAssertEqual(preview["writesGeometry"] as? Bool, false)
        let previewRows = try XCTUnwrap(preview["instances"] as? [[String: Any]])
        let rowA = try XCTUnwrap(previewRows.first { $0["instanceID"] as? String == first })
        let offsetA = try XCTUnwrap(rowA["offset"] as? [Double])
        XCTAssertEqual(offsetA[0], 25, accuracy: 1e-9)
        let baseA = try assembly().instance(UUID(uuidString: first)!)?.transform
        let baseB = try assembly().instance(UUID(uuidString: second)!)?.transform
        XCTAssertEqual(baseA, before.instance(UUID(uuidString: first)!)?.transform)
        XCTAssertEqual(baseB, before.instance(UUID(uuidString: second)!)?.transform)

        let afterPreviewA = try assembly().instance(UUID(uuidString: first)!)?.transform
        let afterPreviewB = try assembly().instance(UUID(uuidString: second)!)?.transform
        XCTAssertEqual(afterPreviewA, before.instance(UUID(uuidString: first)!)?.transform)
        XCTAssertEqual(afterPreviewB, before.instance(UUID(uuidString: second)!)?.transform)

        let reset = service().handle(action: "resetExplodedView", args: [:])
        XCTAssertEqual(reset["ok"] as? Bool, true)
        XCTAssertEqual(reset["mutated"] as? Bool, false)
        let resetRows = try XCTUnwrap(reset["instances"] as? [[String: Any]])
        for row in resetRows {
            XCTAssertEqual((row["offset"] as? [Double])?.reduce(0, +), 0)
        }
        // The persisted view survives reset; reset only stops previewing it.
        XCTAssertEqual(try assembly().explodedViews.count, 1)

        let remove = service().handle(action: "removeExplodedView", args: ["id": viewID.uuidString])
        XCTAssertEqual(remove["ok"] as? Bool, true)
        XCTAssertTrue(try assembly().explodedViews.isEmpty)
    }

    func testOldAssemblyAndDrawingJSONDecodeWithDefaults() throws {
        let oldAssembly = Data(#"{"instances":[],"constraints":[]}"#.utf8)
        let decodedAssembly = try CADAssembly.decode(from: oldAssembly)
        XCTAssertTrue(decodedAssembly.explodedViews.isEmpty)

        let constraintJSON = Data(#"""
        {"id":"11111111-1111-1111-1111-111111111111","kind":"fixed",
         "instanceA":"22222222-2222-2222-2222-222222222222",
         "pointA":[0,0,0],"directionA":[0,0,1],"isSuppressed":false}
        """#.utf8)
        let constraint = try JSONDecoder().decode(CADAssemblyConstraint.self, from: constraintJSON)
        XCTAssertNil(constraint.sourceRevisionA)
        XCTAssertNil(constraint.sourceRevisionB)

        let oldDrawing = Data(#"""
        {"schemaVersion":1,"pages":[{"id":"33333333-3333-3333-3333-333333333333",
         "name":"Front","kind":"front","scale":1,"paper":"a3",
         "sourceBodyIDs":[],"viewNormal":[0,-1,0],"viewUp":[0,1,0],
         "showCenterlines":false,"showDimensions":false}]}
        """#.utf8)
        let decodedDrawing = try CADDrawingSet.decode(from: oldDrawing)
        let page = try XCTUnwrap(decodedDrawing.pages.first)
        XCTAssertFalse(page.assemblyMode)
        XCTAssertNil(page.explodedViewID)
        XCTAssertFalse(page.showBOM)
        XCTAssertNil(page.bom)
        XCTAssertTrue(page.balloons.isEmpty)
        XCTAssertTrue(page.manualDimensions.isEmpty)
        XCTAssertTrue(page.annotations.isEmpty)
    }

    // MARK: - Live reference picking

    func testLiveSelectionResolvesFaceAndRecordsRevisionFence() throws {
        let bodyID = try makeBox()
        let instanceID = try addInstance(bodyID, name: "A")
        let liveBody = try body(bodyID)
        let pick = try topFacePick(bodyID)
        let context = CADSelectionContext.capture(
            document: document, bodyIDs: [liveBody.id], facePicks: [pick])
        let instance = try XCTUnwrap(try assembly().instance(UUID(uuidString: instanceID)!))

        let resolved = service().referenceFromSelection(
            instance: instance, source: liveBody, selection: context,
            facePicks: [pick], edgePicks: [])
        let reference = try resolved.get()
        XCTAssertEqual(reference.sourceKind, "face")
        XCTAssertEqual(reference.direction.y, 1, accuracy: 1e-3,
                       "the +Y planar top face must give a +Y local normal")
        XCTAssertEqual(reference.sourceRevision, liveBody.meshRevision)
        XCTAssertEqual(reference.fence?["mesh_revision"] as? UInt64, liveBody.meshRevision)

        let add = service().handle(action: "addConstraint", args: [
            "kind": "fixed",
            "instanceA": instanceID,
            "referenceA": reference.payload,
        ])
        XCTAssertEqual(add["ok"] as? Bool, true, add["message"] as? String ?? "")
        XCTAssertEqual(add["mutated"] as? Bool, true)

        let report = service().handle(action: "report", args: [:])
        let constraints = try XCTUnwrap(report["constraints"] as? [[String: Any]])
        let row = try XCTUnwrap(constraints.first)
        XCTAssertEqual(row["staleReference"] as? Bool, false)

        // A real geometry update must mark the picked reference stale rather
        // than silently re-binding it to the new topology.
        try bumpBodyRevision(bodyID)
        let staleReport = service().handle(action: "report", args: [:])
        let staleRows = try XCTUnwrap(staleReport["constraints"] as? [[String: Any]])
        let staleRow = try XCTUnwrap(staleRows.first)
        XCTAssertEqual(staleRow["staleReference"] as? Bool, true)
    }

    func testExplicitKernelFaceReferenceRejectsStaleQueryToken() throws {
        let bodyID = try makeBox()
        let instanceID = try addInstance(bodyID, name: "A")
        let liveBody = try body(bodyID)
        let brep = try XCTUnwrap(liveBody.brep)
        let face = try XCTUnwrap(OCCTKernel.faceInfo(brep).first { $0.signature?.kind != nil })
        let token = CADGeometryQueryGeneration(
            scope: "faces", bodyID: liveBody.id.raw,
            documentRevision: document.revision,
            changeCount: document.session.changeCount,
            meshRevision: liveBody.meshRevision).token

        let good = service().handle(action: "reference", args: [
            "instanceID": instanceID,
            "face": ["index": face.index, "query_token": token],
        ])
        XCTAssertEqual(good["ok"] as? Bool, true, good["message"] as? String ?? "")
        XCTAssertEqual(good["mutated"] as? Bool, false)
        XCTAssertEqual(good["index"] as? Int, face.index)

        try bumpBodyRevision(bodyID)
        let stale = service().handle(action: "reference", args: [
            "instanceID": instanceID,
            "face": ["index": face.index, "query_token": token],
        ])
        XCTAssertEqual(stale["ok"] as? Bool, false)
        XCTAssertEqual(stale["error"] as? String, "requery_required")
    }

    func testReferenceCandidatesListRealFacesAndEdges() throws {
        let bodyID = try makeBox()
        let instanceID = try addInstance(bodyID, name: "A")
        let reply = service().handle(action: "referenceCandidates", args: ["instanceID": instanceID])
        XCTAssertEqual(reply["ok"] as? Bool, true, reply["message"] as? String ?? "")
        let faces = try XCTUnwrap(reply["faces"] as? [[String: Any]])
        let edges = try XCTUnwrap(reply["edges"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(faces.count, 6, "a box exposes six planar faces")
        XCTAssertGreaterThanOrEqual(edges.count, 12, "a box exposes twelve kernel edges")
        for face in faces {
            XCTAssertNotNil(face["query_token"])
            XCTAssertEqual((face["point"] as? [Double])?.count, 3)
            XCTAssertEqual((face["direction"] as? [Double])?.count, 3)
        }
    }

    // MARK: - Assembly-aware projection / BOM

    func testAssemblyProjectionUsesPlacedInstancesAndExplodedOffsets() throws {
        let bodyID = try makeBox()
        let instanceID = try addInstance(bodyID, name: "A", position: [0, 0, 0])
        let sheet = CADDrawingService(document: document).handle(action: "assemblySheet", args: [
            "title": "Assembly",
        ])
        XCTAssertEqual(sheet["ok"] as? Bool, true, sheet["message"] as? String ?? "")
        let frontID = try XCTUnwrap(
            (sheet["pages"] as? [[String: Any]])?
                .first { $0["kind"] as? String == "front" }?["id"] as? String)
        let frontUUID = try XCTUnwrap(UUID(uuidString: frontID))
        let drawingService = CADDrawingService(document: document)
        let base = drawingService.pageGeometry(pageID: frontUUID)
        XCTAssertEqual(base["ok"] as? Bool, true, base["message"] as? String ?? "")
        let baseBounds = try XCTUnwrap(projectedBounds(base["entities"] as? [[String: Any]] ?? []))
        XCTAssertEqual(baseBounds.max.x - baseBounds.min.x, 10, accuracy: 1e-4)

        let add = service().handle(action: "addExplodedView", args: [
            "name": "Shifted",
            "direction": [1, 0, 0],
            "distanceMM": 20,
            "entries": [["instanceID": instanceID]],
        ])
        let viewID = try XCTUnwrap(add["id"] as? String)
        let update = drawingService.handle(action: "updatePage", args: [
            "pageID": frontID,
            "explodedViewID": viewID,
            "assemblyMode": true,
            "showBOM": true,
        ])
        XCTAssertEqual(update["ok"] as? Bool, true, update["message"] as? String ?? "")
        let exploded = drawingService.pageGeometry(pageID: frontUUID)
        XCTAssertEqual(exploded["ok"] as? Bool, true, exploded["message"] as? String ?? "")
        let explodedBounds = try XCTUnwrap(projectedBounds(exploded["entities"] as? [[String: Any]] ?? []))
        XCTAssertEqual(explodedBounds.min.x - baseBounds.min.x, 20, accuracy: 1e-3)
        XCTAssertEqual(try assembly().instance(UUID(uuidString: instanceID)!)?.transform.position,
                       SIMD3<Double>(0, 0, 0))
        XCTAssertEqual(exploded["explodedView"] as? [String: Any] != nil, true)
    }

    func testBOMGroupsSharedInstancesAndSeparatesIndependentCopies() throws {
        let bodyID = try makeBox()
        _ = try addInstance(bodyID, name: "A")
        _ = try addInstance(bodyID, name: "B")
        _ = try addInstance(bodyID, name: "A copy", independentCopy: true)
        let sheet = CADDrawingService(document: document).handle(action: "assemblySheet", args: [
            "title": "Assembly",
        ])
        let frontID = try XCTUnwrap(
            (sheet["pages"] as? [[String: Any]])?
                .first { $0["kind"] as? String == "front" }?["id"] as? String)
        let service = CADDrawingService(document: document)
        let bom = service.handle(action: "setBOM", args: ["pageID": frontID, "showBOM": true])
        XCTAssertEqual(bom["ok"] as? Bool, true, bom["message"] as? String ?? "")
        let entries = try XCTUnwrap(bom["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 2, "shared instances group; the independent copy is its own row")
        XCTAssertEqual(entries.first?["quantity"] as? Int, 2)
        XCTAssertEqual(entries.last?["quantity"] as? Int, 1)

        // Removing one shared instance leaves the captured quantity stale on
        // an unmodified page, and re-deriving the BOM updates it honestly.
        let sharedIDs = try XCTUnwrap(entries.first?["instanceIDs"] as? [String])
        _ = serviceObject().handle(action: "removeInstance", args: ["id": sharedIDs[0]])
        let projected = service.pageGeometry(pageID: UUID(uuidString: frontID)!)
        let liveBOM = try XCTUnwrap(projected["bom"] as? [String: Any])
        let liveEntries = try XCTUnwrap(liveBOM["entries"] as? [[String: Any]])
        let grouped = try XCTUnwrap(liveEntries.first {
            ($0["quantity"] as? Int) == 1 && ($0["stale"] as? Bool) == true
        })
        XCTAssertNotNil(grouped["missingInstanceIDs"])

        let redrive = service.handle(action: "setBOM", args: ["pageID": frontID])
        XCTAssertEqual(redrive["ok"] as? Bool, true, redrive["message"] as? String ?? "")
        let fixedEntries = try XCTUnwrap(redrive["entries"] as? [[String: Any]])
        XCTAssertEqual(fixedEntries.first?["quantity"] as? Int, 1)
        XCTAssertEqual(fixedEntries.first?["stale"] as? Bool, false)
    }

    private func serviceObject() -> CADAssemblyService {
        CADAssemblyService(document: document)
    }

    // MARK: - Balloons, dimensions, persistence, undo

    func testBalloonAndManualDimensionFollowPlacedInstance() throws {
        let bodyID = try makeBox()
        let instanceID = try addInstance(bodyID, name: "A")
        let sheet = CADDrawingService(document: document).handle(action: "assemblySheet", args: [
            "title": "Assembly",
        ])
        let frontID = try XCTUnwrap(
            (sheet["pages"] as? [[String: Any]])?
                .first { $0["kind"] as? String == "front" }?["id"] as? String)
        let service = CADDrawingService(document: document)
        _ = service.handle(action: "setBOM", args: ["pageID": frontID, "showBOM": true])
        let geometry = service.pageGeometry(pageID: UUID(uuidString: frontID)!)
        let bounds = try XCTUnwrap(projectedBounds(geometry["entities"] as? [[String: Any]] ?? []))

        let balloon = service.handle(action: "addBalloon", args: [
            "pageID": frontID,
            "itemNumber": 1,
            "instanceID": instanceID,
        ])
        XCTAssertEqual(balloon["ok"] as? Bool, true, balloon["message"] as? String ?? "")
        let dimension = service.handle(action: "addDimension", args: [
            "pageID": frontID,
            "kind": "length",
            "instanceID": instanceID,
            "drawingPoints": [[bounds.min.x, bounds.min.y], [bounds.max.x, bounds.min.y]],
        ])
        XCTAssertEqual(dimension["ok"] as? Bool, true, dimension["message"] as? String ?? "")
        let firstGeometry = service.pageGeometry(pageID: UUID(uuidString: frontID)!)
        let firstDimensions = try XCTUnwrap(firstGeometry["manualDimensions"] as? [[String: Any]])
        let firstDimension = try XCTUnwrap(firstDimensions.first)
        let firstValue = try XCTUnwrap(firstDimension["value"] as? Double)
        XCTAssertEqual(firstValue, 10, accuracy: 1e-3)
        let firstPoints = try XCTUnwrap(firstDimension["drawingPoints"] as? [[Double]])
        XCTAssertEqual(firstPoints.count, 2)

        // Move the instance: the bound dimension follows (drawing x +20), the
        // measured model value stays 10 mm, and the base transform is the only
        // changed state.
        _ = serviceObject().handle(action: "setTransform", args: [
            "id": instanceID,
            "transform": ["position": [20, 0, 0]],
        ])
        let movedGeometry = service.pageGeometry(pageID: UUID(uuidString: frontID)!)
        let movedDimensions = try XCTUnwrap(movedGeometry["manualDimensions"] as? [[String: Any]])
        let movedDimension = try XCTUnwrap(movedDimensions.first)
        let movedValue = try XCTUnwrap(movedDimension["value"] as? Double)
        XCTAssertEqual(movedValue, 10, accuracy: 1e-3)
        let movedPoints = try XCTUnwrap(movedDimension["drawingPoints"] as? [[Double]])
        XCTAssertEqual(movedPoints[0][0] - firstPoints[0][0], 20, accuracy: 1e-3)

        // A missing instance flags both annotations explicitly instead of
        // silently keeping stale leaders.
        _ = serviceObject().handle(action: "removeInstance", args: ["id": instanceID])
        let missingGeometry = service.pageGeometry(pageID: UUID(uuidString: frontID)!)
        let balloons = try XCTUnwrap(missingGeometry["balloons"] as? [[String: Any]])
        XCTAssertEqual(balloons.first?["invalid"] as? Bool, true)
        let missingDimensions = try XCTUnwrap(missingGeometry["manualDimensions"] as? [[String: Any]])
        XCTAssertEqual(missingDimensions.first?["invalid"] as? Bool, true)
    }

    func testDrawingAnnotationsUndoAndReopen() async throws {
        let bodyID = try makeBox()
        let instanceID = try addInstance(bodyID, name: "A")
        let sheet = CADDrawingService(document: document).handle(action: "assemblySheet", args: [
            "title": "Assembly",
        ])
        let frontID = try XCTUnwrap(
            (sheet["pages"] as? [[String: Any]])?
                .first { $0["kind"] as? String == "front" }?["id"] as? String)
        let service = CADDrawingService(document: document)
        let before = document.session.document.drawingsData
        _ = service.handle(action: "setBOM", args: ["pageID": frontID, "showBOM": true])
        let afterBOM = document.session.document.drawingsData
        let balloon = service.handle(action: "addBalloon", args: [
            "pageID": frontID, "itemNumber": 1, "instanceID": instanceID,
        ])
        XCTAssertEqual(balloon["ok"] as? Bool, true, balloon["message"] as? String ?? "")
        let afterBalloon = document.session.document.drawingsData
        XCTAssertNotEqual(afterBOM, afterBalloon)

        // One command per action: undo removes the balloon, then the BOM.
        document.session.undo()
        XCTAssertEqual(document.session.document.drawingsData, afterBOM)
        document.session.undo()
        XCTAssertEqual(document.session.document.drawingsData, before)

        // Redo both, save and reopen: annotations come back from drawingsData.
        document.session.redo()
        document.session.redo()
        let saved = await document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        document.close()
        let reopened = try await FloeCADDocument.open(at: document.url)
        let reopenedService = CADDrawingService(document: reopened)
        let reopenedGeometry = reopenedService.pageGeometry(pageID: UUID(uuidString: frontID)!)
        XCTAssertEqual(reopenedGeometry["ok"] as? Bool, true,
                       reopenedGeometry["message"] as? String ?? "")
        XCTAssertEqual((reopenedGeometry["balloons"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((reopenedGeometry["bom"] as? [String: Any])?["entryCount"] as? Int, 1)
        reopened.close()
    }

    // MARK: - Transient exploded preview (viewport state)

    /// Column-major world translation of one placed scene-snapshot body.
    private func sceneTranslation(_ snapshot: CADSceneSnapshot,
                                  instanceID: UUID) throws -> SIMD3<Double> {
        let body = try XCTUnwrap(snapshot.bodies.first { $0.id == instanceID })
        XCTAssertEqual(body.transform.count, 16)
        return SIMD3(body.transform[12], body.transform[13], body.transform[14])
    }

    /// The engineering viewport's actual drawable placement for an instance.
    private func editorTranslation(_ editor: EditorViewModel,
                                   instanceID: UUID) throws -> SIMD3<Double> {
        let drawable = try XCTUnwrap(
            editor.scene.bodies.first { $0.assemblyInstanceID == instanceID })
        let column = drawable.modelMatrix.columns.3
        return SIMD3(Double(column.x), Double(column.y), Double(column.z))
    }

    func testPreviewActivatesTransientPlacementsWithoutTouchingTheDocument() async throws {
        let bodyID = try makeBox()
        let first = try addInstance(bodyID, name: "A", position: [0, 0, 0])
        let second = try addInstance(bodyID, name: "B", position: [30, 0, 0])
        let add = service().handle(action: "addExplodedView", args: [
            "name": "Service",
            "direction": [1, 0, 0],
            "distanceMM": 20,
            "entries": [
                ["instanceID": first, "distanceMM": 25],
                ["instanceID": second, "direction": [0, 1, 0], "distanceMM": 10],
            ],
        ])
        let viewID = try XCTUnwrap(UUID(uuidString: add["id"] as? String ?? ""))
        let saved = await document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")

        // A committed document: preview must not look like an edit.
        let changeCount = document.session.changeCount
        let undoCount = document.session.undoStack.undoCommands.count
        let assemblyBytes = document.session.document.assemblyData
        let firstUUID = try XCTUnwrap(UUID(uuidString: first))
        let secondUUID = try XCTUnwrap(UUID(uuidString: second))
        XCTAssertNil(CADExplodedViewPreview.current(for: document.session))
        let editor = document.viewModel()
        let keyBefore = editor.assistantSelectionKey
        let baseScene = document.sceneSnapshot()
        let baseFirst = try sceneTranslation(baseScene, instanceID: firstUUID)
        let baseSecond = try sceneTranslation(baseScene, instanceID: secondUUID)
        let baseEditorFirst = try editorTranslation(editor, instanceID: firstUUID)

        let preview = service().handle(action: "previewExplodedView",
                                       args: ["id": viewID.uuidString])
        XCTAssertEqual(preview["ok"] as? Bool, true, preview["message"] as? String ?? "")
        XCTAssertEqual(preview["previewActive"] as? Bool, true)
        XCTAssertEqual(preview["activeExplodedViewID"] as? String, viewID.uuidString)
        XCTAssertEqual(preview["applied"] as? Bool, true,
                       "the preview is applied to the transient viewport, not the document")
        XCTAssertEqual(preview["mutated"] as? Bool, false)
        XCTAssertEqual(preview["writesGeometry"] as? Bool, false)
        XCTAssertEqual(preview["baselineUnchanged"] as? Bool, true)

        let state = try XCTUnwrap(CADExplodedViewPreview.current(for: document.session))
        XCTAssertEqual(state.viewID, viewID)
        XCTAssertEqual(state.viewName, "Service")

        // No document write, no undo entry, no dirty flag.
        XCTAssertEqual(document.session.changeCount, changeCount)
        XCTAssertFalse(document.hasUnsavedChanges)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undoCount)
        XCTAssertEqual(document.session.document.assemblyData, assemblyBytes)

        // The presentation snapshot and the engineering viewport draw the SAME
        // transient placement; the baseline stays one offset away.
        let previewScene = document.sceneSnapshot()
        let previewFirst = try sceneTranslation(previewScene, instanceID: firstUUID)
        XCTAssertEqual(previewFirst.x - baseFirst.x, 25, accuracy: 1e-9)
        XCTAssertEqual(previewFirst.y - baseFirst.y, 0, accuracy: 1e-9)
        let previewSecond = try sceneTranslation(previewScene, instanceID: secondUUID)
        XCTAssertEqual(previewSecond.y - baseSecond.y, 10, accuracy: 1e-9)
        let previewEditorFirst = try editorTranslation(editor, instanceID: firstUUID)
        XCTAssertEqual(previewEditorFirst.x - baseEditorFirst.x, 25, accuracy: 1e-3)
        XCTAssertNotEqual(editor.assistantSelectionKey, keyBefore,
                          "the viewport redraw key must follow the transient preview")

        // A display-less artifact producer can opt out of the transient view.
        let baselineOnly = document.sceneSnapshot(includeExplodedPreview: false)
        XCTAssertEqual(try sceneTranslation(baselineOnly, instanceID: firstUUID).x,
                       baseFirst.x, accuracy: 1e-12)
        XCTAssertEqual(try editorTranslation(editor, instanceID: firstUUID).x,
                       previewEditorFirst.x, accuracy: 1e-3,
                       "the live viewport keeps showing the preview")

        // An assistant/native scene query reports the transient state honestly.
        let summary = document.sceneSummaryJSON()
        XCTAssertEqual((summary["exploded_preview"] as? [String: Any])?["id"] as? String,
                       viewID.uuidString)
        XCTAssertEqual((summary["exploded_preview"] as? [String: Any])?["transient"] as? Bool,
                       true)

        // Reset is also not a write and restores both scenes exactly.
        let reset = service().handle(action: "resetExplodedView", args: [:])
        XCTAssertEqual(reset["ok"] as? Bool, true)
        XCTAssertEqual(reset["previewActive"] as? Bool, false)
        XCTAssertEqual(reset["wasPreviewing"] as? Bool, true)
        XCTAssertEqual(reset["mutated"] as? Bool, false)
        XCTAssertNil(CADExplodedViewPreview.current(for: document.session)?.viewID)
        XCTAssertEqual(document.session.changeCount, changeCount)
        XCTAssertFalse(document.hasUnsavedChanges)
        XCTAssertEqual(try sceneTranslation(document.sceneSnapshot(), instanceID: firstUUID).x,
                       baseFirst.x, accuracy: 1e-12)
        XCTAssertEqual(try editorTranslation(editor, instanceID: firstUUID).x,
                       baseEditorFirst.x, accuracy: 1e-3)
        XCTAssertNotEqual(editor.assistantSelectionKey, keyBefore)
        XCTAssertNil(document.sceneSummaryJSON()["exploded_preview"])
    }

    func testPreviewFallsBackToTheBaselineWhenTheViewDisappears() throws {
        let bodyID = try makeBox()
        let instanceID = try addInstance(bodyID, name: "A", position: [12, 0, 0])
        let uuid = try XCTUnwrap(UUID(uuidString: instanceID))
        let add = service().handle(action: "addExplodedView", args: [
            "name": "Removed soon",
            "direction": [0, 0, 1],
            "distanceMM": 30,
            "entries": [["instanceID": instanceID]],
        ])
        let viewID = try XCTUnwrap(UUID(uuidString: add["id"] as? String ?? ""))
        let base = try sceneTranslation(document.sceneSnapshot(), instanceID: uuid)
        _ = service().handle(action: "previewExplodedView", args: ["id": viewID.uuidString])
        let previewed = try sceneTranslation(document.sceneSnapshot(), instanceID: uuid)
        XCTAssertEqual(previewed.z - base.z, 30, accuracy: 1e-9)

        // Undoing the view's creation leaves the transient id pointing at
        // nothing: the viewport must snap back instead of keeping the offset.
        document.session.undo()
        XCTAssertTrue(try assembly().explodedViews.isEmpty)
        XCTAssertEqual(try sceneTranslation(document.sceneSnapshot(), instanceID: uuid),
                       base)

        // A live read repairs the transient state instead of leaving a name
        // that no longer exists.
        let report = service().handle(action: "report", args: [:])
        XCTAssertEqual((report["explodedPreview"] as? [String: Any])?["active"] as? Bool, false)
        XCTAssertNil(CADExplodedViewPreview.current(for: document.session)?.viewID)

        // Asking to preview a deleted view refuses AND keeps the baseline.
        let stale = service().handle(action: "previewExplodedView",
                                     args: ["id": viewID.uuidString])
        XCTAssertEqual(stale["ok"] as? Bool, false)
        XCTAssertEqual(stale["error"] as? String, "unknown_exploded_view")
        XCTAssertEqual(try sceneTranslation(document.sceneSnapshot(), instanceID: uuid),
                       base)
    }

    func testPreviewSurvivesADeletedInstanceWithoutResurrectingIt() throws {
        let bodyID = try makeBox()
        let first = try addInstance(bodyID, name: "A", position: [0, 0, 0])
        let second = try addInstance(bodyID, name: "B", position: [30, 0, 0])
        let secondUUID = try XCTUnwrap(UUID(uuidString: second))
        let add = service().handle(action: "addExplodedView", args: [
            "name": "Pair",
            "direction": [1, 0, 0],
            "distanceMM": 20,
            "entries": [["instanceID": first], ["instanceID": second]],
        ])
        let viewID = try XCTUnwrap(UUID(uuidString: add["id"] as? String ?? ""))
        _ = service().handle(action: "previewExplodedView", args: ["id": viewID.uuidString])
        let firstUUID = try XCTUnwrap(UUID(uuidString: first))
        let baseFirst = try sceneTranslation(document.sceneSnapshot(includeExplodedPreview: false),
                                             instanceID: firstUUID)
        _ = service().handle(action: "removeInstance", args: ["id": second])

        // The deleted target is gone from both the document and the scene; the
        // remaining instance keeps its transient offset.
        XCTAssertNil(try assembly().instance(secondUUID))
        let scene = document.sceneSnapshot()
        XCTAssertFalse(scene.bodies.contains { $0.id == secondUUID })
        XCTAssertEqual(try sceneTranslation(scene, instanceID: firstUUID).x - baseFirst.x,
                       20, accuracy: 1e-9)

        // Re-previewing lists only the live instances, so the removed entry can
        // never reappear as a placement.
        let preview = service().handle(action: "previewExplodedView",
                                       args: ["id": viewID.uuidString])
        XCTAssertEqual(preview["ok"] as? Bool, true, preview["message"] as? String ?? "")
        let rows = try XCTUnwrap(preview["instances"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["instanceID"] as? String, first)
        _ = service().handle(action: "resetExplodedView", args: [:])
    }

    func testPreviewOffsetsAreNeverSavedIntoTheAssembly() async throws {
        let bodyID = try makeBox()
        let instanceID = try addInstance(bodyID, name: "A", position: [10, 0, 0])
        let uuid = try XCTUnwrap(UUID(uuidString: instanceID))
        let add = service().handle(action: "addExplodedView", args: [
            "name": "Shifted",
            "direction": [1, 0, 0],
            "distanceMM": 15,
            "entries": [["instanceID": instanceID]],
        ])
        let viewID = try XCTUnwrap(UUID(uuidString: add["id"] as? String ?? ""))
        _ = service().handle(action: "previewExplodedView", args: ["id": viewID.uuidString])

        // Editing the base placement while the preview is on keeps ONE offset
        // over the NEW base — the offset is never accumulated into the value.
        _ = service().handle(action: "setTransform", args: [
            "id": instanceID, "transform": ["position": [40, 0, 0]],
        ])
        let movedBase = try sceneTranslation(
            document.sceneSnapshot(includeExplodedPreview: false), instanceID: uuid)
        XCTAssertEqual(try sceneTranslation(document.sceneSnapshot(), instanceID: uuid).x
                       - movedBase.x, 15, accuracy: 1e-9)
        let base = try XCTUnwrap(try assembly().instance(uuid)?.transform.position)
        XCTAssertEqual(base, SIMD3<Double>(40, 0, 0))

        // Saving with the preview active persists the base only.
        let saved = await document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        XCTAssertEqual(try assembly().instance(uuid)?.transform.position,
                       SIMD3<Double>(40, 0, 0))

        // Reopening starts with no transient preview at all.
        document.close()
        let reopened = try await FloeCADDocument.open(at: document.url)
        XCTAssertNil(CADExplodedViewPreview.current(for: reopened.session))
        let reopenedAssembly = try CADAssembly.decode(from: reopened.session.document.assemblyData)
        XCTAssertEqual(reopenedAssembly.instance(uuid)?.transform.position,
                       SIMD3<Double>(40, 0, 0))
        XCTAssertEqual(try sceneTranslation(reopened.sceneSnapshot(), instanceID: uuid),
                       movedBase)
        XCTAssertNil(reopened.sceneSummaryJSON()["exploded_preview"])
        reopened.close()
    }

    func testPreviewStateIsScopedToOneDocument() async throws {
        let bodyID = try makeBox()
        let instanceID = try addInstance(bodyID, name: "A")
        let add = service().handle(action: "addExplodedView", args: [
            "name": "Only here",
            "direction": [1, 0, 0],
            "distanceMM": 5,
            "entries": [["instanceID": instanceID]],
        ])
        let viewID = try XCTUnwrap(UUID(uuidString: add["id"] as? String ?? ""))
        let other = try await FloeCADDocument.create(
            at: workDir.appendingPathComponent("other.floecad"), name: "Other")
        defer { other.close() }

        _ = service().handle(action: "previewExplodedView", args: ["id": viewID.uuidString])
        XCTAssertEqual(CADExplodedViewPreview.current(for: document.session)?.viewID, viewID)
        XCTAssertNil(CADExplodedViewPreview.current(for: other.session),
                     "a different open document must never inherit the preview")
        XCTAssertNil(other.sceneSummaryJSON()["exploded_preview"])

        let reset = CADAssemblyService(document: other)
            .handle(action: "resetExplodedView", args: [:])
        XCTAssertEqual(reset["ok"] as? Bool, true)
        XCTAssertEqual(reset["wasPreviewing"] as? Bool, false)
        // Resetting the other document left this one previewing.
        XCTAssertEqual(CADExplodedViewPreview.current(for: document.session)?.viewID, viewID)
        _ = service().handle(action: "resetExplodedView", args: [:])
    }

    // MARK: - Vector exports

    func testExportsCarryBOMBalloonAndAnnotationAsVectors() throws {
        let bodyID = try makeBox()
        let instanceID = try addInstance(bodyID, name: "A")
        let sheet = CADDrawingService(document: document).handle(action: "assemblySheet", args: [
            "title": "Assembly",
        ])
        let frontID = try XCTUnwrap(
            (sheet["pages"] as? [[String: Any]])?
                .first { $0["kind"] as? String == "front" }?["id"] as? String)
        let frontUUID = try XCTUnwrap(UUID(uuidString: frontID))
        let service = CADDrawingService(document: document)
        _ = service.handle(action: "setBOM", args: ["pageID": frontID, "showBOM": true])
        _ = service.handle(action: "addBalloon", args: [
            "pageID": frontID, "itemNumber": 1, "instanceID": instanceID,
        ])
        _ = service.handle(action: "addAnnotation", args: [
            "pageID": frontID, "text": "ASSEMBLED", "position": [40, 120],
        ])

        let svg = try service.exportData(pageID: frontUUID, format: "svg")
        let text = try XCTUnwrap(String(data: svg, encoding: .utf8))
        XCTAssertTrue(text.contains("<g id=\"ANNOTATIONS\""), "balloon/text must be a vector group")
        XCTAssertTrue(text.contains("<g id=\"BOM\""), "BOM table must be a vector group")
        XCTAssertTrue(text.contains("ASSEMBLED"))
        XCTAssertTrue(text.contains(">1</text>"), "the balloon item number is real text")

        let dxf = try service.exportData(pageID: frontUUID, format: "dxf")
        let dxfText = try XCTUnwrap(String(data: dxf, encoding: .utf8))
        XCTAssertTrue(dxfText.contains("ANNOTATIONS"))
        XCTAssertTrue(dxfText.contains("BOM"))
        XCTAssertTrue(dxfText.contains("0\nTEXT\n"))

        let pdf = try service.exportData(pageID: frontUUID, format: "pdf")
        XCTAssertEqual(String(data: Data(pdf.prefix(5)), encoding: .ascii), "%PDF-")
        XCTAssertGreaterThan(pdf.count, 1024)
    }
}
