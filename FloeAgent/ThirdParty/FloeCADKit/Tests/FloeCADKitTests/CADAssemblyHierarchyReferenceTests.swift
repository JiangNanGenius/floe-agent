//
//  CADAssemblyHierarchyReferenceTests.swift
//  FloeCADKitTests
//
//  Focused E01/E02 contract tests over the REAL document transaction,
//  persistence and drawing services:
//
//  * two-level subassembly hierarchy, local mates and stable BOM identities;
//  * external native part reference staged by the App-owned bridge;
//  * two shared reference instances (inside two different subassemblies) that
//    follow ONE explicit source update, plus one independent copy that keeps
//    its own geometry/material;
//  * missing-source diagnosis with cached display geometry preserved;
//  * compare-and-swap refusals that leave the document untouched;
//  * one-step undo/redo for a reference update and for make-independent;
//  * saved exploded views restoring the BASE placement after reopen;
//  * cycle/scope refusals and structural integrity diagnostics.
//
//  Geometry is built through the same typed command vocabulary the App/Agent
//  uses; no fixture invents a parallel geometry path.
//

import XCTest
import simd
@testable import FloeCAD

@MainActor
final class CADAssemblyHierarchyReferenceTests: XCTestCase {

    private var workDir: URL!
    private var document: FloeCADDocument!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeCADHierarchy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        document = try await FloeCADDocument.create(
            at: workDir.appendingPathComponent("target.floecad"), name: "Target")
    }

    override func tearDown() async throws {
        document?.close()
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - Helpers

    private func service() -> CADAssemblyService {
        CADAssemblyService(document: document)
    }

    @discardableResult
    private func run(_ doc: FloeCADDocument, _ json: String,
                     file: StaticString = #filePath, line: UInt = #line) -> [String: Any] {
        let outcome = doc.executeJSON(Data(json.utf8))
        XCTAssertTrue(outcome.isOK,
                      "command failed (\(outcome.status)) \(outcome.errorCode ?? ""): "
                        + "\(outcome.message ?? "") — \(json)",
                      file: file, line: line)
        return (try? JSONSerialization.jsonObject(with: outcome.payload)) as? [String: Any] ?? [:]
    }

    private func makeBox(_ doc: FloeCADDocument,
                         min: [Double] = [0, 0], max: [Double] = [10, 10],
                         height: Double = 10, name: String = "Box") throws -> String {
        let sketch = try XCTUnwrap(
            run(doc, #"{"op":"sketch.create","args":{"name":"\#(name)"}}"#)["sketchID"] as? String)
        _ = run(doc, """
        {"op":"sketch.addEntities","args":{"sketchID":"\(sketch)",
         "entities":[{"kind":"rect","min":[\(min[0]),\(min[1])],"max":[\(max[0]),\(max[1])]}]}}
        """)
        let response = run(doc, """
        {"op":"feature.extrude","args":{"sketchID":"\(sketch)",
         "seedPoint":[\((min[0] + max[0]) / 2),\((min[1] + max[1]) / 2)],
         "distance":\(height)}}
        """)
        return try XCTUnwrap((response["producedBodyIDs"] as? [String])?.first
            ?? (response["changedBodyIDs"] as? [String])?.first,
            "extrude returned no body: \(response)")
    }

    private func addSubassembly(_ service: CADAssemblyService, name: String,
                                parentID: String? = nil,
                                file: StaticString = #filePath, line: UInt = #line) throws -> String {
        var args: [String: Any] = ["name": name]
        if let parentID { args["parentID"] = parentID }
        let reply = service.handle(action: "addSubassembly", args: args)
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)", file: file, line: line)
        return try XCTUnwrap(reply["id"] as? String, file: file, line: line)
    }

    private func addInstance(_ service: CADAssemblyService, bodyID: String,
                             name: String, parentID: String? = nil,
                             position: [Double]? = nil,
                             independentCopy: Bool = false,
                             file: StaticString = #filePath, line: UInt = #line) throws -> String {
        var args: [String: Any] = ["bodyID": bodyID, "name": name]
        if let parentID { args["parentID"] = parentID }
        if let position { args["transform"] = ["position": position] }
        if independentCopy { args["independentCopy"] = true }
        let reply = service.handle(action: "addInstance", args: args)
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)", file: file, line: line)
        return try XCTUnwrap(reply["id"] as? String, file: file, line: line)
    }

    private func placeReference(_ service: CADAssemblyService, referenceID: String,
                                name: String? = nil, parentID: String? = nil,
                                independentCopy: Bool = false,
                                file: StaticString = #filePath, line: UInt = #line) throws -> String {
        var args: [String: Any] = ["referenceID": referenceID]
        if let name { args["name"] = name }
        if let parentID { args["parentID"] = parentID }
        if independentCopy { args["independentCopy"] = true }
        let reply = service.handle(action: "placePartReference", args: args)
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)", file: file, line: line)
        return try XCTUnwrap(reply["id"] as? String, file: file, line: line)
    }

    private func makeSourceDocument(name: String = "Source",
                                    min: [Double] = [0, 0], max: [Double] = [10, 10],
                                    height: Double = 10) async throws -> (URL, UUID) {
        let url = workDir.appendingPathComponent("\(name).floecad")
        let source = try await FloeCADDocument.create(at: url, name: name)
        let body = try makeBox(source, min: min, max: max, height: height, name: name)
        let save = await source.save()
        XCTAssertTrue(save.succeeded, save.error ?? "")
        source.close()
        return (url, try XCTUnwrap(UUID(uuidString: body)))
    }

    private func editSource(at url: URL, bodyID: UUID,
                            scale: Float, color: SIMD4<Double>) async throws {
        let source = try await FloeCADDocument.open(at: url)
        defer { source.close() }
        let body = try XCTUnwrap(source.session.document.body(with: BodyID(raw: bodyID)))
        var edited = Body(id: body.id, name: body.name, transform: body.transform,
                          primitive: body.primitive,
                          render: RenderMesh(
                            positions: body.render.positions.map { $0 * scale },
                            normals: body.render.normals,
                            indices: body.render.indices,
                            texcoords: body.render.texcoords),
                          revision: body.meshRevision)
        edited.brep = body.brep
        source.session.perform(ReplaceBodyCommand(title: "Source Geometry", before: body,
                                                  after: edited))
        let material = BodyMaterialSpec(baseColor: color, metallic: 0, roughness: 0.25)
        let design = source.session.document
        source.session.perform(SetMaterialCommand(
            bodyIDs: [body.id], material: material, document: design))
        let save = await source.save()
        XCTAssertTrue(save.succeeded, save.error ?? "")
    }

    private func assembly(_ doc: FloeCADDocument? = nil) throws -> CADAssembly {
        try CADAssembly.decode(from: (doc ?? document).session.document.assemblyData)
    }

    private func body(_ id: UUID, in doc: FloeCADDocument? = nil) -> Body? {
        (doc ?? document).session.document.bodies.first { $0.id.raw == id }
    }

    private func row(_ report: [String: Any], id: String) throws -> [String: Any] {
        let rows = try XCTUnwrap(report["instances"] as? [[String: Any]])
        return try XCTUnwrap(rows.first { $0["id"] as? String == id }, "missing row \(id)")
    }

    private func id(_ value: String) -> UUID {
        UUID(uuidString: value)!
    }

    // MARK: - Format admission

    func testNestedAssemblyRaisesFormatFloorButFlatDocumentDoesNot() async throws {
        let body = try makeBox(document, name: "Flat")
        let service = service()
        let first = try addInstance(service, bodyID: body, name: "Flat A")
        _ = try addInstance(service, bodyID: body, name: "Flat B")

        XCTAssertLessThan(CADDocumentFormat.requiredFormat(document: document.session.document),
                          CADDocumentFormat.nestedAssemblyVersion,
                          "a flat shared-instance document must keep its older floor")
        XCTAssertLessThan(try CADDocumentFormat.assess(
            planes: document.session.document.planes.map {
                CADBlobRecord(blobID: $0.planeID, data: $0.planeData, sha256: "")
            },
            sketches: document.session.document.sketches.map {
                CADBlobRecord(blobID: $0.sketchID, data: $0.sketchData, sha256: "")
            },
            features: [],
            assembly: document.session.document.assemblyData).requiredVersion,
                          CADDocumentFormat.nestedAssemblyVersion)
        let flatSave = await document.save()
        XCTAssertTrue(flatSave.succeeded, flatSave.error ?? "")
        XCTAssertLessThan(document.summary().schemaVersion,
                          CADDocumentFormat.nestedAssemblyVersion,
                          "flat documents must remain writable by the previous format floor")

        let sub = try addSubassembly(service, name: "Nested")
        let moved = service.handle(action: "moveInstance",
                                   args: ["id": first, "parentID": sub])
        XCTAssertEqual(moved["ok"] as? Bool, true, "\(moved)")
        XCTAssertEqual(CADDocumentFormat.requiredFormat(document: document.session.document),
                       CADDocumentFormat.nestedAssemblyVersion)
        XCTAssertEqual(try CADDocumentFormat.assess(
            planes: [], sketches: [], features: [],
            assembly: document.session.document.assemblyData).requiredVersion,
                       CADDocumentFormat.nestedAssemblyVersion,
                       "the persisted assembly bytes must raise the write floor")
        let nestedSave = await document.save()
        XCTAssertTrue(nestedSave.succeeded, nestedSave.error ?? "")
        XCTAssertEqual(document.summary().schemaVersion,
                       CADDocumentFormat.nestedAssemblyVersion,
                       "a nested document must be marked newer than an old writer")
        XCTAssertEqual(CADDocumentFormat.supportedVersion,
                       CADDocumentFormat.nestedAssemblyVersion,
                       "this writer must admit the floor it emits")

        document.close()
        document = try await FloeCADDocument.open(
            at: workDir.appendingPathComponent("target.floecad"))
        XCTAssertFalse(document.isReadOnly, "the current writer must edit its own v4 document")
        XCTAssertEqual(document.summary().schemaVersion, CADDocumentFormat.nestedAssemblyVersion)
        XCTAssertEqual(try assembly().instancePath(id(first))?.count, 2)
        XCTAssertEqual(try assembly().parentInstanceID(of: id(first)), id(sub))
    }

    // MARK: - E01 hierarchy

    func testTwoLevelSubassemblyHierarchyAndSaveReopen() async throws {
        let bodyA = try makeBox(document, name: "A")
        let bodyB = try makeBox(document, min: [20, 0], max: [30, 10], name: "B")
        let service = service()

        let root = try addSubassembly(service, name: "Machine")
        let stage = try addSubassembly(service, name: "Stage", parentID: root)
        let partA = try addInstance(service, bodyID: bodyA, name: "Part A", parentID: stage)
        let partB = try addInstance(service, bodyID: bodyB, name: "Part B", parentID: stage)
        let top = try addInstance(service, bodyID: bodyA, name: "Top shared")

        let hierarchy = service.handle(action: "hierarchy", args: [:])
        XCTAssertEqual(hierarchy["rootCount"] as? Int, 2)
        XCTAssertEqual(hierarchy["totalCount"] as? Int, 5)
        XCTAssertEqual(hierarchy["subassemblyCount"] as? Int, 2)
        let tree = try XCTUnwrap(hierarchy["tree"] as? [[String: Any]])
        let rootRow = try XCTUnwrap(tree.first { $0["id"] as? String == root })
        XCTAssertEqual(rootRow["kind"] as? String, "subassembly")
        let stageRow = try XCTUnwrap((rootRow["children"] as? [[String: Any]])?
            .first { $0["id"] as? String == stage })
        XCTAssertEqual(stageRow["kind"] as? String, "subassembly")
        XCTAssertEqual((stageRow["children"] as? [[String: Any]])?.count, 2)

        let report = service.handle(action: "report", args: [:])
        let rowA = try row(report, id: partA)
        let rowB = try row(report, id: partB)
        let rowTop = try row(report, id: top)
        XCTAssertEqual(rowA["path"] as? [String], [root, stage, partA])
        XCTAssertEqual(rowB["depth"] as? Int, 2)
        XCTAssertEqual(rowA["bomIdentity"] as? String, rowTop["bomIdentity"] as? String,
                       "shared body instances must keep one stable BOM identity")
        XCTAssertNotEqual(rowA["bomIdentity"] as? String, rowB["bomIdentity"] as? String)

        let save = await document.save()
        XCTAssertTrue(save.succeeded, save.error ?? "")
        document.close()
        document = try await FloeCADDocument.open(
            at: workDir.appendingPathComponent("target.floecad"))

        let reopened = service()
        let reopenedReport = reopened.handle(action: "report", args: [:])
        XCTAssertEqual(reopenedReport["totalInstanceCount"] as? Int, 5)
        XCTAssertEqual(try assembly().instance(id(partA))?.name, "Part A")
        XCTAssertEqual(try assembly().instancePath(id(partA))?.map(\.uuidString), [root, stage, partA])
        XCTAssertEqual(try assembly().instance(id(root))?.children.first?.id.uuidString, stage)
        XCTAssertEqual(try assembly().instance(id(partA))?.bomIdentity.uuidString,
                       rowA["bomIdentity"] as? String)
    }

    // MARK: - E01/E02 external source update and independent copy

    func testExternalReferenceSharedUpdateIndependentCopyAndUndo() async throws {
        let (sourceURL, _) = try await makeSourceDocument(name: "Gear")
        let bridge = CADAssemblyReferenceBridge()
        let attach = await bridge.attach(sourceURL: sourceURL, to: document, name: "Gear")
        XCTAssertEqual(attach["ok"] as? Bool, true, "\(attach)")
        let referenceID = try XCTUnwrap(attach["referenceID"] as? String)
        let firstInstance = try XCTUnwrap(attach["id"] as? String)
        let referenceBefore = try XCTUnwrap(try assembly().partReference(UUID(uuidString: referenceID)!))
        let stagedBefore = try XCTUnwrap(body(referenceBefore.stagedBodyID))
        let stagedHashBefore = CADAssemblyGeometryDigest.digest(of: stagedBefore)

        let service = service()
        let subA = try addSubassembly(service, name: "Sub A")
        let subB = try addSubassembly(service, name: "Sub B")
        let moved = service.handle(action: "moveInstance",
                                   args: ["id": firstInstance, "parentID": subA])
        XCTAssertEqual(moved["ok"] as? Bool, true, "\(moved)")
        let second = try placeReference(service, referenceID: referenceID,
                                        name: "Gear A2", parentID: subA)
        let mate = service.handle(action: "addConstraint", args: [
            "kind": "distance", "instanceA": firstInstance, "instanceB": second,
            "parentID": subA, "value": 30.0,
        ])
        XCTAssertEqual(mate["ok"] as? Bool, true, "\(mate)")
        let mateID = try XCTUnwrap(mate["id"] as? String)
        let third = try placeReference(service, referenceID: referenceID,
                                       name: "Gear B1", parentID: subB)
        let copy = try placeReference(service, referenceID: referenceID,
                                      name: "Gear Copy", independentCopy: true)
        let copyRow = try row(service.handle(action: "report", args: [:]), id: copy)
        let copyBodyID = try XCTUnwrap(UUID(uuidString: copyRow["copiedBodyID"] as? String ?? ""))
        let copyBodyBefore = try XCTUnwrap(body(copyBodyID))
        let copyHashBefore = CADAssemblyGeometryDigest.digest(of: copyBodyBefore)
        let copyMaterialBefore = copyBodyBefore.material
        let copyInstanceID = try XCTUnwrap(UUID(uuidString: copy))

        let changedColor = SIMD4<Double>(0.1, 0.7, 0.2, 1)
        try await editSource(at: sourceURL, bodyID: referenceBefore.sourceBodyID,
                             scale: 1.4, color: changedColor)

        let changeCountBefore = document.session.changeCount
        let beforeUpdateAssembly = try XCTUnwrap(document.session.document.assemblyData)
        let update = await bridge.update(
            referenceID: referenceBefore.id,
            sourceURL: sourceURL,
            in: document,
            expectedSourceContentHash: referenceBefore.sourceContentHash,
            expectedStagedGeometryHash: referenceBefore.stagedGeometryHash)
        XCTAssertEqual(update["ok"] as? Bool, true, "\(update)")
        XCTAssertEqual(update["mutated"] as? Bool, true)
        XCTAssertEqual(document.session.changeCount, changeCountBefore + 1,
                       "a source update must be exactly one undo step")

        let referenceAfter = try XCTUnwrap(try assembly().partReference(referenceBefore.id))
        XCTAssertNotEqual(referenceAfter.sourceContentHash, referenceBefore.sourceContentHash)
        XCTAssertNotEqual(referenceAfter.stagedGeometryHash, referenceBefore.stagedGeometryHash)
        let stagedAfter = try XCTUnwrap(body(referenceAfter.stagedBodyID))
        XCTAssertEqual(CADAssemblyGeometryDigest.digest(of: stagedAfter),
                       referenceAfter.stagedGeometryHash)
        XCTAssertEqual(stagedAfter.material?.baseColor, Optional(changedColor))
        XCTAssertNotEqual(CADAssemblyGeometryDigest.digest(of: stagedAfter), stagedHashBefore,
                          "shared instances must see the updated staged geometry")

        let current = try assembly()
        XCTAssertEqual(current.instance(UUID(uuidString: moved["id"] as? String ?? ""))?.sourceReferenceID,
                       referenceBefore.id)
        XCTAssertEqual(current.instance(UUID(uuidString: second)!)?.sourceReferenceID,
                       referenceBefore.id)
        XCTAssertEqual(current.instance(UUID(uuidString: third)!)?.sourceReferenceID,
                       referenceBefore.id)
        XCTAssertEqual(current.instance(UUID(uuidString: firstInstance)!)?.id.uuidString,
                       firstInstance, "the instance identity must not be replaced")
        XCTAssertEqual(current.instance(UUID(uuidString: firstInstance)!)?.bomIdentity,
                       referenceBefore.id)
        XCTAssertEqual(current.instance(UUID(uuidString: second)!)?.bomIdentity,
                       referenceBefore.id)
        XCTAssertEqual(current.instance(UUID(uuidString: third)!)?.bomIdentity,
                       referenceBefore.id)

        // Independent copy is untouched by the source update.
        XCTAssertEqual(current.instance(copyInstanceID)?.isIndependentCopy, true)
        XCTAssertEqual(current.instance(copyInstanceID)?.copiedBodyID, copyBodyID)
        let copyAfter = try XCTUnwrap(body(copyBodyID))
        XCTAssertEqual(CADAssemblyGeometryDigest.digest(of: copyAfter), copyHashBefore)
        XCTAssertEqual(copyAfter.material, copyMaterialBefore)
        XCTAssertEqual(current.instance(copyInstanceID)?.bomIdentity, copyBodyID)

        // The two subassemblies still contain their leaves and the local mate
        // keeps its stable constraint ID after the update.
        XCTAssertEqual(current.instance(UUID(uuidString: subA)!)?.children.count, 2)
        XCTAssertEqual(current.instance(UUID(uuidString: subB)!)?.children.count, 1)
        XCTAssertEqual(current.instance(UUID(uuidString: subA)!)?
            .constraints.first?.id.uuidString, mateID)
        XCTAssertNotNil(current.constraint(UUID(uuidString: mateID)!))

        // Undo the whole update in one step, then redo it.
        document.session.undo()
        let undone = try assembly()
        XCTAssertEqual(undone.partReference(referenceBefore.id)?.sourceContentHash,
                       referenceBefore.sourceContentHash)
        XCTAssertEqual(CADAssemblyGeometryDigest.digest(
            try XCTUnwrap(body(referenceBefore.stagedBodyID))), stagedHashBefore)
        document.session.redo()
        let redone = try assembly()
        XCTAssertEqual(redone.partReference(referenceBefore.id)?.stagedGeometryHash,
                       referenceAfter.stagedGeometryHash)

        let save = await document.save()
        XCTAssertTrue(save.succeeded, save.error ?? "")
        document.close()
        document = try await FloeCADDocument.open(
            at: workDir.appendingPathComponent("target.floecad"))
        let reopened = try assembly()
        XCTAssertEqual(reopened.instance(copyInstanceID)?.isIndependentCopy, true)
        XCTAssertEqual(reopened.instance(copyInstanceID)?.copiedBodyID, copyBodyID)
        XCTAssertEqual(reopened.instance(UUID(uuidString: second)!)?.sourceReferenceID,
                       referenceBefore.id)
        XCTAssertEqual(reopened.instance(UUID(uuidString: subA)!)?.children.count, 2)
        XCTAssertEqual(reopened.instance(UUID(uuidString: subA)!)?
            .constraints.first?.id.uuidString, mateID)
        XCTAssertEqual(reopened.partReference(referenceBefore.id)?.stagedGeometryHash,
                       referenceAfter.stagedGeometryHash)
    }

    // MARK: - CAS, missing sources and cached geometry

    func testReferenceCompareAndSwapAndMissingSourceDiagnosis() async throws {
        let (sourceURL, _) = try await makeSourceDocument(name: "Bracket")
        let bridge = CADAssemblyReferenceBridge()
        let attach = await bridge.attach(sourceURL: sourceURL, to: document, name: "Bracket")
        XCTAssertEqual(attach["ok"] as? Bool, true, "\(attach)")
        let referenceID = try XCTUnwrap(UUID(uuidString: attach["referenceID"] as? String ?? ""))
        let pinned = try XCTUnwrap(try assembly().partReference(referenceID))
        try await editSource(at: sourceURL, bodyID: pinned.sourceBodyID,
                             scale: 1.2, color: SIMD4<Double>(0.8, 0.2, 0.2, 1))
        let assemblyBefore = try XCTUnwrap(document.session.document.assemblyData)
        let changesBefore = document.session.changeCount
        let revisionBefore = document.store.revision

        let stale = await bridge.update(
            referenceID: referenceID, sourceURL: sourceURL, in: document,
            expectedSourceContentHash: "wrong-source-hash",
            expectedStagedGeometryHash: pinned.stagedGeometryHash)
        XCTAssertEqual(stale["ok"] as? Bool, false)
        XCTAssertEqual(stale["error"] as? String, "stale_reference")
        XCTAssertEqual(document.session.document.assemblyData, assemblyBefore)
        XCTAssertEqual(document.session.changeCount, changesBefore)
        XCTAssertEqual(document.store.revision, revisionBefore)

        let staleStaged = await bridge.update(
            referenceID: referenceID, sourceURL: sourceURL, in: document,
            expectedSourceContentHash: pinned.sourceContentHash,
            expectedStagedGeometryHash: "wrong-staged-hash")
        XCTAssertEqual(staleStaged["ok"] as? Bool, false)
        XCTAssertEqual(staleStaged["error"] as? String, "stale_reference")
        XCTAssertEqual(document.session.document.assemblyData, assemblyBefore)

        let updated = await bridge.update(
            referenceID: referenceID, sourceURL: sourceURL, in: document,
            expectedSourceContentHash: pinned.sourceContentHash,
            expectedStagedGeometryHash: pinned.stagedGeometryHash)
        XCTAssertEqual(updated["ok"] as? Bool, true, "\(updated)")
        let afterUpdate = try XCTUnwrap(try assembly().partReference(referenceID))
        let cachedBodyID = afterUpdate.stagedBodyID
        let cachedHash = afterUpdate.stagedGeometryHash

        try FileManager.default.removeItem(at: sourceURL)
        let diagnosis = await bridge.check(referenceID: referenceID,
                                           sourceURL: sourceURL, in: document)
        XCTAssertEqual(diagnosis["ok"] as? Bool, true)
        XCTAssertEqual(diagnosis["available"] as? Bool, false)
        XCTAssertEqual(diagnosis["missing"] as? Bool, true)
        XCTAssertEqual(diagnosis["cachedGeometryAvailable"] as? Bool, true)
        XCTAssertNotNil(diagnosis["missingReason"] as? String)

        // The cached body and every placed occurrence are still there.
        let cached = try XCTUnwrap(body(cachedBodyID))
        XCTAssertEqual(CADAssemblyGeometryDigest.digest(of: cached), cachedHash)
        let scene = document.sceneSnapshot()
        XCTAssertTrue(scene.bodies.contains { $0.sourceBodyID == cachedBodyID },
                      "missing sources must preserve cached display geometry")
        let references = service().handle(action: "references", args: [:])
        XCTAssertEqual(references["ok"] as? Bool, true)
        XCTAssertEqual(references["count"] as? Int, 1)
    }

    // MARK: - Exploded view base placement

    func testSavedExplodedViewKeepsBasePlacementAcrossReopen() async throws {
        let bodyA = try makeBox(document, name: "A")
        let service = service()
        let root = try addSubassembly(service, name: "Root")
        let child = try addInstance(service, bodyID: bodyA, name: "Child", parentID: root,
                                    position: [5, 0, 0])
        let baseBefore = try XCTUnwrap(try assembly().instance(id(child))?.transform)
        let add = service.handle(action: "addExplodedView", args: [
            "name": "Service",
            "direction": [1, 0, 0],
            "distanceMM": 20,
            "entries": [
                ["instanceID": root, "distanceMM": 30],
                ["instanceID": child, "distanceMM": 10],
            ],
        ])
        XCTAssertEqual(add["ok"] as? Bool, true, "\(add)")
        let viewID = try XCTUnwrap(UUID(uuidString: add["id"] as? String ?? ""))
        let preview = service.handle(action: "previewExplodedView",
                                     args: ["id": viewID.uuidString])
        XCTAssertEqual(preview["ok"] as? Bool, true)
        let baseAfterPreview = try XCTUnwrap(try assembly().instance(id(child))?.transform)
        XCTAssertEqual(baseAfterPreview, baseBefore, "preview must not write the base placement")
        let exploded = try XCTUnwrap(try assembly().explodedWorldTransform(
            for: UUID(uuidString: child)!, viewID: viewID))
        XCTAssertNotEqual(exploded.position, baseAfterPreview.position)
        XCTAssertEqual(exploded.position.x - baseAfterPreview.position.x, 40, accuracy: 1e-9,
                       "the root offset (30) carries the child, plus the child's own 10")

        let save = await document.save()
        XCTAssertTrue(save.succeeded, save.error ?? "")
        document.close()
        document = try await FloeCADDocument.open(
            at: workDir.appendingPathComponent("target.floecad"))
        let reopened = try assembly()
        XCTAssertEqual(reopened.instance(UUID(uuidString: child)!)?.transform, baseBefore)
        XCTAssertEqual(reopened.explodedView(viewID)?.entries.count, 2)
        let reopenedExploded = try XCTUnwrap(reopened.explodedWorldTransform(
            for: UUID(uuidString: child)!, viewID: viewID))
        XCTAssertEqual(reopenedExploded.position.x - baseBefore.position.x, 40, accuracy: 1e-9)
    }

    // MARK: - Refusals and integrity

    func testCyclesScopesAndIntegrityAreRefusedWithoutMutation() throws {
        let bodyA = try makeBox(document, name: "A")
        let bodyB = try makeBox(document, min: [20, 0], max: [30, 10], name: "B")
        let service = service()
        let parent = try addSubassembly(service, name: "Parent")
        let child = try addSubassembly(service, name: "Child", parentID: parent)
        let part = try addInstance(service, bodyID: bodyA, name: "Part", parentID: parent)
        let rootPart = try addInstance(service, bodyID: bodyB, name: "Root Part")

        let before = try XCTUnwrap(document.session.document.assemblyData)
        let changes = document.session.changeCount
        let cycle = service.handle(action: "moveInstance",
                                   args: ["id": parent, "parentID": child])
        XCTAssertEqual(cycle["ok"] as? Bool, false)
        XCTAssertEqual(cycle["error"] as? String, "cycle")
        XCTAssertEqual(document.session.document.assemblyData, before)
        XCTAssertEqual(document.session.changeCount, changes)

        let nestedRootConstraint = service.handle(action: "addConstraint", args: [
            "kind": "distance", "instanceA": rootPart, "instanceB": part, "value": 10,
        ])
        XCTAssertEqual(nestedRootConstraint["ok"] as? Bool, false)
        XCTAssertEqual(nestedRootConstraint["error"] as? String, "nested_constraint_scope")
        XCTAssertEqual(document.session.document.assemblyData, before)

        let badParent = service.handle(action: "addInstance", args: [
            "bodyID": bodyB, "parentID": rootPart,
        ])
        XCTAssertEqual(badParent["ok"] as? Bool, false)
        XCTAssertEqual(badParent["error"] as? String, "unknown_subassembly")

        let valid = service.handle(action: "addConstraint", args: [
            "kind": "distance", "instanceA": part, "instanceB": child,
            "parentID": parent, "value": 10,
        ])
        XCTAssertEqual(valid["ok"] as? Bool, true, "\(valid)")
        XCTAssertEqual(valid["scope"] as? String, "subassembly")

        var duplicated = try assembly()
        duplicated.updateInstance(UUID(uuidString: parent)!) { container in
            if let leaf = container.children.first {
                container.children.append(leaf)
            }
        }
        let issues = duplicated.integrityIssues()
        XCTAssertTrue(issues.contains { $0.kind == "duplicate_instance" })
    }

    // MARK: - Nested local mates

    func testNestedLocalConstraintSolvesAndSurvivesReopen() async throws {
        let bodyA = try makeBox(document, name: "A")
        let bodyB = try makeBox(document, min: [20, 0], max: [30, 10], name: "B")
        let service = service()
        let parent = try addSubassembly(service, name: "Pair")
        let a = try addInstance(service, bodyID: bodyA, name: "A", parentID: parent)
        let b = try addInstance(service, bodyID: bodyB, name: "B", parentID: parent,
                                position: [5, 0, 0])
        let added = service.handle(action: "addConstraint", args: [
            "kind": "distance", "instanceA": a, "instanceB": b,
            "parentID": parent, "value": 25.0,
        ])
        XCTAssertEqual(added["ok"] as? Bool, true, "\(added)")
        let constraintID = try XCTUnwrap(added["id"] as? String)

        let solved = service.handle(action: "solve", args: [:])
        XCTAssertEqual(solved["ok"] as? Bool, true, "\(solved)")
        XCTAssertEqual(solved["solved"] as? Bool, true)
        XCTAssertEqual((solved["nestedSolved"] as? [[String: Any]])?.count, 1)

        let stored = try assembly()
        let localA = try XCTUnwrap(stored.instance(UUID(uuidString: a)!))
        let localB = try XCTUnwrap(stored.instance(UUID(uuidString: b)!))
        XCTAssertEqual(simd_length(localB.transform.position - localA.transform.position),
                       25.0, accuracy: 1e-6)
        XCTAssertEqual(stored.instance(UUID(uuidString: parent)!)?
            .constraints.first?.id.uuidString, constraintID)

        let save = await document.save()
        XCTAssertTrue(save.succeeded, save.error ?? "")
        document.close()
        document = try await FloeCADDocument.open(
            at: workDir.appendingPathComponent("target.floecad"))
        let reopened = try assembly()
        XCTAssertEqual(reopened.instance(UUID(uuidString: parent)!)?
            .constraints.first?.id.uuidString, constraintID)
        let report = service().handle(action: "report", args: [:])
        let constraints = try XCTUnwrap(report["constraints"] as? [[String: Any]])
        let nested = try XCTUnwrap(constraints.first { $0["id"] as? String == constraintID })
        XCTAssertEqual(nested["scope"] as? String, "subassembly")
        XCTAssertEqual(nested["valid"] as? Bool, true)
    }

    // MARK: - Make independent one step + drawing BOM identity

    func testMakeIndependentIsOneStepAndBOMIdentitySurvivesReferenceUpdate() async throws {
        let body = try makeBox(document, name: "Plate")
        let service = service()
        let first = try addInstance(service, bodyID: body, name: "First")
        let second = try addInstance(service, bodyID: body, name: "Second")
        let before = try XCTUnwrap(document.session.document.assemblyData)
        let changes = document.session.changeCount
        let converted = service.handle(action: "makeIndependent", args: ["id": second])
        XCTAssertEqual(converted["ok"] as? Bool, true, "\(converted)")
        XCTAssertEqual(converted["id"] as? String, second)
        XCTAssertEqual(document.session.changeCount, changes + 1,
                       "makeIndependent must be one undo step")
        let copiedID = try XCTUnwrap(UUID(uuidString: converted["copiedBodyID"] as? String ?? ""))
        XCTAssertEqual(try assembly().instance(UUID(uuidString: second)!)?.copiedBodyID, copiedID)
        XCTAssertEqual(try assembly().instance(UUID(uuidString: first)!)?.bodyID,
                       try XCTUnwrap(UUID(uuidString: body)))
        document.session.undo()
        XCTAssertEqual(document.session.document.assemblyData, before)
        XCTAssertNil(try assembly().instance(UUID(uuidString: second)!)?.copiedBodyID)
        XCTAssertNil(body(copiedID), "undo must remove the copy body")
        document.session.redo()
        XCTAssertNotNil(body(copiedID))

        // Drawing BOM: nested/shared external rows keep their entry identity
        // and instance ids across an explicit source update.
        let (sourceURL, _) = try await makeSourceDocument(name: "Wheel")
        let bridge = CADAssemblyReferenceBridge()
        let attach = await bridge.attach(sourceURL: sourceURL, to: document, name: "Wheel")
        XCTAssertEqual(attach["ok"] as? Bool, true, "\(attach)")
        let referenceID = try XCTUnwrap(UUID(uuidString: attach["referenceID"] as? String ?? ""))
        let root = try addSubassembly(service, name: "Axle")
        let firstRef = try XCTUnwrap(attach["id"] as? String)
        _ = service.handle(action: "moveInstance", args: ["id": firstRef, "parentID": root])
        _ = try placeReference(service, referenceID: referenceID.uuidString,
                               name: "Wheel 2", parentID: root)
        let sheet = CADDrawingService(document: document).handle(action: "assemblySheet",
                                                                  args: ["title": "Assembly"])
        XCTAssertEqual(sheet["ok"] as? Bool, true, "\(sheet)")
        let frontID = try XCTUnwrap((sheet["pages"] as? [[String: Any]])?
            .first { $0["kind"] as? String == "front" }?["id"] as? String)
        let drawing = CADDrawingService(document: document)
        let bom = drawing.handle(action: "setBOM", args: ["pageID": frontID, "showBOM": true])
        XCTAssertEqual(bom["ok"] as? Bool, true, "\(bom)")
        let entries = try XCTUnwrap(bom["entries"] as? [[String: Any]])
        let wheelEntry = try XCTUnwrap(entries.first { ($0["quantity"] as? Int) == 2 })
        let entryID = try XCTUnwrap(wheelEntry["id"] as? String)
        let bumper = try XCTUnwrap(wheelEntry["bodyID"] as? String)
        let instanceIDs = try XCTUnwrap(wheelEntry["instanceIDs"] as? [String])
        XCTAssertEqual(Set(instanceIDs).count, 2)

        let pinned = try XCTUnwrap(try assembly().partReference(referenceID))
        try await editSource(at: sourceURL, bodyID: pinned.sourceBodyID,
                             scale: 1.1, color: SIMD4<Double>(0.3, 0.3, 0.9, 1))
        let update = await bridge.update(
            referenceID: referenceID, sourceURL: sourceURL, in: document,
            expectedSourceContentHash: pinned.sourceContentHash,
            expectedStagedGeometryHash: pinned.stagedGeometryHash)
        XCTAssertEqual(update["ok"] as? Bool, true, "\(update)")
        let bom2 = drawing.handle(action: "setBOM", args: ["pageID": frontID, "showBOM": true])
        XCTAssertEqual(bom2["ok"] as? Bool, true, "\(bom2)")
        let entries2 = try XCTUnwrap(bom2["entries"] as? [[String: Any]])
        let wheel2 = try XCTUnwrap(entries2.first { ($0["id"] as? String) == entryID })
        XCTAssertEqual(wheel2["bodyID"] as? String, bumper)
        XCTAssertEqual(wheel2["quantity"] as? Int, 2)
        XCTAssertEqual(Set(try XCTUnwrap(wheel2["instanceIDs"] as? [String])), Set(instanceIDs))
    }

    // MARK: - Guarded host reference commit (review repairs)

    /// A failed host commit reverts the EXACT reference command and nothing
    /// else: a pre-existing redo entry survives, the failed command never
    /// becomes redoable, and the document returns to its last committed state.
    func testFailedReferenceSaveRollsBackExactlyAndKeepsRedoHistory() async throws {
        let targetBodyID = try XCTUnwrap(UUID(uuidString: try makeBox(document, name: "Target")))
        let targetBody = try XCTUnwrap(body(targetBodyID))
        document.session.perform(RenameItemCommand(
            item: .body(targetBody.id), before: targetBody.name, after: "Renamed"))
        document.session.undo()
        let redoBefore = document.session.undoStack.redoCommands.map(\.title)
        XCTAssertEqual(redoBefore, ["Rename"])
        let cleanSave = await document.save()
        XCTAssertTrue(cleanSave.succeeded, cleanSave.error ?? "")
        XCTAssertFalse(document.hasUnsavedChanges)

        let undoDepthBefore = document.session.undoStack.undoCommands.count
        let (sourceURL, _) = try await makeSourceDocument(name: "Gear")
        let bridge = CADAssemblyReferenceBridge()
        let attach = await bridge.attach(sourceURL: sourceURL, to: document, name: "Gear")
        XCTAssertEqual(attach["ok"] as? Bool, true, "\(attach)")
        let referenceID = try XCTUnwrap(UUID(uuidString: attach["referenceID"] as? String ?? ""))
        let receipt = try XCTUnwrap(document.pendingOwnedCommand)
        XCTAssertEqual(receipt.tag, "cad.reference.attach:\(referenceID.uuidString)")
        XCTAssertTrue(document.containsPartReference(referenceID))

        document.session.saveFailureForTesting = "simulated explicit-save failure"
        let failed = await document.save()
        XCTAssertFalse(failed.succeeded, "the injected host commit failure must be reported")
        XCTAssertEqual(document.rollbackOwnedCommand(receipt), .reverted)
        XCTAssertFalse(document.containsPartReference(referenceID),
                       "the failed reference must not linger in memory")
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undoDepthBefore)
        XCTAssertEqual(document.session.undoStack.redoCommands.map(\.title), redoBefore,
                       "a failed reference command must not become redoable or destroy prior redo")
        XCTAssertFalse(document.hasUnsavedChanges)

        // The preserved redo still replays the ordinary edit, never the
        // rejected reference.
        document.session.redo()
        XCTAssertEqual(body(targetBodyID)?.name, "Renamed")
        XCTAssertFalse(document.containsPartReference(referenceID))
    }

    /// A later real edit during the commit suspension invalidates the exact
    /// rollback. Both the reference and the later edit are preserved, and a
    /// subsequent ordinary undo removes only the later edit.
    func testFailedReferenceSaveWithLaterEditPreservesBoth() async throws {
        let targetBodyID = try XCTUnwrap(UUID(uuidString: try makeBox(document, name: "Target")))
        let (sourceURL, _) = try await makeSourceDocument(name: "Gear")
        let bridge = CADAssemblyReferenceBridge()
        let attach = await bridge.attach(sourceURL: sourceURL, to: document, name: "Gear")
        XCTAssertEqual(attach["ok"] as? Bool, true, "\(attach)")
        let referenceID = try XCTUnwrap(UUID(uuidString: attach["referenceID"] as? String ?? ""))
        let receipt = try XCTUnwrap(document.pendingOwnedCommand)

        document.session.saveFailureForTesting = "simulated explicit-save failure"
        document.session.savePrewarmSuspensionForTesting = {
            guard let current = self.body(targetBodyID) else { return }
            document.session.perform(RenameItemCommand(
                item: .body(current.id), before: current.name, after: "Later Rename"))
        }
        let failed = await document.save()
        document.session.savePrewarmSuspensionForTesting = nil
        XCTAssertFalse(failed.succeeded)

        XCTAssertEqual(document.rollbackOwnedCommand(receipt), .superseded,
                       "a later edit must block the exact rollback")
        XCTAssertTrue(document.containsPartReference(referenceID),
                      "a reference that remains must never be reported as nothing applied")
        XCTAssertEqual(body(targetBodyID)?.name, "Later Rename",
                       "the later edit must survive the refused rollback")
        XCTAssertTrue(document.hasUnsavedChanges)

        document.session.undo()
        XCTAssertEqual(body(targetBodyID)?.name, "Target")
        XCTAssertTrue(document.containsPartReference(referenceID),
                      "undo must remove only the later edit, not the reference command beneath it")
    }

    /// Another save can commit the same reference command while the explicit
    /// commit is waiting to finish. A later failure must NOT undo that
    /// successful commit.
    func testReferenceCommittedByConcurrentSaveIsNeverRolledBack() async throws {
        let (sourceURL, _) = try await makeSourceDocument(name: "Gear")
        let bridge = CADAssemblyReferenceBridge()
        let attach = await bridge.attach(sourceURL: sourceURL, to: document, name: "Gear")
        XCTAssertEqual(attach["ok"] as? Bool, true, "\(attach)")
        let referenceID = try XCTUnwrap(UUID(uuidString: attach["referenceID"] as? String ?? ""))
        let receipt = try XCTUnwrap(document.pendingOwnedCommand)

        document.session.saveFailureForTesting = "simulated explicit-save failure"
        document.session.savePrewarmSuspensionForTesting = {
            document.session.savePrewarmSuspensionForTesting = nil
            document.session.save()
        }
        let failed = await document.save()
        document.session.savePrewarmSuspensionForTesting = nil
        XCTAssertFalse(failed.succeeded, "the explicit save still reports its own failure")
        XCTAssertFalse(document.hasUnsavedChanges,
                       "the concurrent save committed the reference")

        XCTAssertEqual(document.rollbackOwnedCommand(receipt), .alreadyCommitted)
        XCTAssertTrue(document.containsPartReference(referenceID))

        let committedRevision = document.revision
        document.close()
        document = try await FloeCADDocument.open(
            at: workDir.appendingPathComponent("target.floecad"))
        XCTAssertTrue(document.containsPartReference(referenceID),
                      "the concurrent commit must remain on disk")
        XCTAssertEqual(document.revision, committedRevision)
    }

    /// The real cancellation signal is checked after the asynchronous source
    /// load and before any mutation.
    func testAttachRefusesLateCancellationWithoutMutation() async throws {
        let (sourceURL, _) = try await makeSourceDocument(name: "Gear")
        let flag = ReferenceCancellationFlag()
        let liveURL = document.url
        let beforeAssembly = document.session.document.assemblyData
        let undoBefore = document.session.undoStack.undoCommands.count
        CADAssemblyReferenceBridge.referenceMutationSuspensionForTesting = { url in
            guard url.standardizedFileURL == liveURL.standardizedFileURL else { return }
            flag.isCancelled = true
            CADAssemblyReferenceBridge.referenceMutationSuspensionForTesting = nil
        }
        defer { CADAssemblyReferenceBridge.referenceMutationSuspensionForTesting = nil }

        let attach = await CADAssemblyReferenceBridge().attach(
            sourceURL: sourceURL, to: document, name: "Gear",
            isCancelled: { flag.isCancelled })
        XCTAssertEqual(attach["ok"] as? Bool, false)
        XCTAssertEqual(attach["error"] as? String, "cancelled")
        XCTAssertEqual(document.session.document.assemblyData, beforeAssembly)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undoBefore,
                       "cancellation after the source load must not start a mutation")
    }

    /// A foreign commit while the source is being read means the open target
    /// no longer represents the package; attach must refuse before mutating.
    func testAttachRefusesChangedTargetAfterSourceLoad() async throws {
        let (sourceURL, _) = try await makeSourceDocument(name: "Gear")
        let targetURL = workDir.appendingPathComponent("target.floecad")
        let beforeAssembly = document.session.document.assemblyData
        let undoBefore = document.session.undoStack.undoCommands.count
        let liveRevision = document.revision
        CADAssemblyReferenceBridge.referenceMutationSuspensionForTesting = { observedURL in
            guard observedURL.standardizedFileURL == targetURL.standardizedFileURL else { return }
            let foreign = try await FloeCADDocument.open(at: targetURL)
            defer { foreign.close() }
            foreign.session.perform(SetAssemblyDataCommand(
                before: foreign.session.document.assemblyData,
                after: foreign.session.document.assemblyData))
            let saved = await foreign.save()
            XCTAssertTrue(saved.succeeded, saved.error ?? "")
            CADAssemblyReferenceBridge.referenceMutationSuspensionForTesting = nil
        }
        defer { CADAssemblyReferenceBridge.referenceMutationSuspensionForTesting = nil }

        let attach = await CADAssemblyReferenceBridge().attach(
            sourceURL: sourceURL, to: document, name: "Gear")
        XCTAssertEqual(attach["ok"] as? Bool, false)
        XCTAssertEqual(attach["error"] as? String, "target_changed")
        XCTAssertEqual(document.session.document.assemblyData, beforeAssembly)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undoBefore)
        XCTAssertEqual(document.revision, liveRevision,
                       "the stale live document must not be advanced by a refused attach")
        let diskIdentity = await FloeCADDocument.storedIdentity(at: targetURL)
        let disk = try XCTUnwrap(diskIdentity)
        XCTAssertGreaterThan(disk.revision, liveRevision,
                             "the test must use a real foreign revision advance")
    }

    /// No raw metadata-only re-pin exists; only the verified bridge update can
    /// change the pin, and it follows the actual source bytes.
    func testForgedMetadataRePinIsRefusedAndBridgeFollowsActualBytes() async throws {
        let (sourceURL, _) = try await makeSourceDocument(name: "Gear")
        let bridge = CADAssemblyReferenceBridge()
        let attach = await bridge.attach(sourceURL: sourceURL, to: document, name: "Gear")
        XCTAssertEqual(attach["ok"] as? Bool, true, "\(attach)")
        let referenceID = try XCTUnwrap(UUID(uuidString: attach["referenceID"] as? String ?? ""))
        let pinned = try XCTUnwrap(try assembly().partReference(referenceID))
        let assemblyBefore = try XCTUnwrap(document.session.document.assemblyData)
        let changesBefore = document.session.changeCount

        let forged = service().handle(action: "updatePartReference", args: [
            "referenceID": referenceID.uuidString,
            "sourceContentHash": String(repeating: "f", count: 64),
            "sourceRevision": 99,
            "sourceDocumentName": "forged",
            "sourceBodyName": "forged",
            "sourceWriterVersion": 99,
            "clearMissing": true,
        ])
        XCTAssertEqual(forged["ok"] as? Bool, false)
        XCTAssertEqual(forged["error"] as? String, "unknown_action",
                       "a caller-supplied digest must never be accepted as verification")
        XCTAssertEqual(document.session.document.assemblyData, assemblyBefore)
        XCTAssertEqual(document.session.changeCount, changesBefore)
        XCTAssertEqual(try assembly().partReference(referenceID), pinned)

        try await editSource(at: sourceURL, bodyID: pinned.sourceBodyID,
                             scale: 1.3, color: SIMD4<Double>(0.2, 0.6, 0.3, 1))
        let actualIdentity = await FloeCADDocument.storedIdentity(at: sourceURL)
        let actual = try XCTUnwrap(actualIdentity)
        let source = try await FloeCADDocument.open(at: sourceURL)
        let sourceSchema = source.summary().schemaVersion
        source.close()
        let updated = await bridge.update(
            referenceID: referenceID, sourceURL: sourceURL, in: document,
            expectedSourceContentHash: pinned.sourceContentHash,
            expectedStagedGeometryHash: pinned.stagedGeometryHash)
        XCTAssertEqual(updated["ok"] as? Bool, true, "\(updated)")
        let after = try XCTUnwrap(try assembly().partReference(referenceID))
        XCTAssertEqual(after.sourceContentHash, actual.contentSHA256)
        XCTAssertEqual(after.sourceRevision, actual.revision)
        XCTAssertEqual(after.verifierSchemaVersion,
                       FloeCADDocument.supportedPackageSchemaVersion)
        XCTAssertEqual(after.sourceSchemaVersion, sourceSchema)
        let staged = try XCTUnwrap(body(after.stagedBodyID))
        XCTAssertEqual(CADAssemblyGeometryDigest.digest(of: staged), after.stagedGeometryHash)
    }

    func testClosingTargetDuringSourceLoadRefusesWithoutMutation() async throws {
        let (sourceURL, _) = try await makeSourceDocument(name: "Gear")
        let beforeChanges = document.session.changeCount
        let beforeUndo = document.session.undoStack.undoCommands.count
        let target = try XCTUnwrap(document)
        CADAssemblyReferenceBridge.referenceMutationSuspensionForTesting = { url in
            if url == target.url { target.close() }
        }
        defer { CADAssemblyReferenceBridge.referenceMutationSuspensionForTesting = nil }
        let reply = await CADAssemblyReferenceBridge().attach(sourceURL: sourceURL, to: target)
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(reply["error"] as? String, "target_changed")
        XCTAssertEqual(reply["mutated"] as? Bool, false)
        XCTAssertEqual(target.session.changeCount, beforeChanges)
        XCTAssertEqual(target.session.undoStack.undoCommands.count, beforeUndo)
        XCTAssertTrue(target.session.document.assembly.partReferences.isEmpty)
    }

    func testLegacyReferenceDecodesAndReencodesWithReaderProvenance() throws {
        let original = CADPartReference(
            name: "Legacy gear", sourceDocumentID: UUID(), sourceBodyID: UUID(),
            sourceDocumentName: "Source", sourceBodyName: "Gear",
            verifierSchemaVersion: 3, sourceSchemaVersion: 2, sourceRevision: 7,
            sourceContentHash: String(repeating: "a", count: 64),
            stagedBodyID: UUID(), stagedGeometryHash: String(repeating: "b", count: 64))
        let encoded = try JSONEncoder().encode(original)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy["sourceWriterVersion"] = legacy.removeValue(forKey: "verifierSchemaVersion")
        let recovered = try JSONDecoder().decode(
            CADPartReference.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(recovered, original)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(recovered)) as? [String: Any])
        XCTAssertEqual(saved["verifierSchemaVersion"] as? Int, 3)
        XCTAssertEqual(saved["sourceSchemaVersion"] as? Int, 2)
        XCTAssertEqual(saved["sourceRevision"] as? Int, 7)
        XCTAssertNil(saved["sourceWriterVersion"])
        XCTAssertEqual(try JSONDecoder().decode(
            CADPartReference.self, from: JSONEncoder().encode(recovered)), original)
    }

    /// Provenance reports the ACTUAL source schema plus this reader's verified
    /// capability — never a fabricated historical writer fact.
    func testReferenceProvenanceReportsReaderCapabilityAndSourceSchema() async throws {
        let (sourceURL, _) = try await makeSourceDocument(name: "Gear")
        let storedIdentity = await FloeCADDocument.storedIdentity(at: sourceURL)
        let identity = try XCTUnwrap(storedIdentity)
        let source = try await FloeCADDocument.open(at: sourceURL)
        let schema = source.summary().schemaVersion
        source.close()

        let inspect = await CADAssemblyReferenceBridge().inspectSource(at: sourceURL)
        XCTAssertEqual(inspect["ok"] as? Bool, true)
        XCTAssertEqual(inspect["sourceRevision"] as? Int, identity.revision)
        XCTAssertEqual(inspect["sourceContentHash"] as? String, identity.contentSHA256)
        XCTAssertEqual(inspect["sourceSchemaVersion"] as? Int, schema)
        XCTAssertEqual(inspect["verifierSchemaVersion"] as? Int,
                       FloeCADDocument.supportedPackageSchemaVersion)
        XCTAssertNil(inspect["sourceWriterVersion"],
                     "the reader capability must not be labelled a writer fact")

        let attach = await CADAssemblyReferenceBridge().attach(
            sourceURL: sourceURL, to: document, name: "Gear")
        XCTAssertEqual(attach["ok"] as? Bool, true, "\(attach)")
        let reference = try XCTUnwrap(attach["reference"] as? [String: Any])
        XCTAssertEqual(reference["sourceSchemaVersion"] as? Int, schema)
        XCTAssertEqual(reference["verifierSchemaVersion"] as? Int,
                       FloeCADDocument.supportedPackageSchemaVersion)
        XCTAssertNil(reference["sourceWriterVersion"])
        let references = service().handle(action: "references", args: [:])
        let rows = try XCTUnwrap(references["references"] as? [[String: Any]])
        let row = try XCTUnwrap(rows.first { $0["id"] as? String == reference["id"] as? String })
        XCTAssertEqual(row["sourceSchemaVersion"] as? Int, schema)
        XCTAssertEqual(row["verifierSchemaVersion"] as? Int,
                       FloeCADDocument.supportedPackageSchemaVersion)
        let referenceID = try XCTUnwrap(UUID(uuidString: reference["id"] as? String ?? ""))
        let check = await CADAssemblyReferenceBridge().check(
            referenceID: referenceID, sourceURL: sourceURL, in: document)
        XCTAssertEqual(check["pinnedVerifierSchemaVersion"] as? Int,
                       FloeCADDocument.supportedPackageSchemaVersion)
        XCTAssertNil(check["pinnedSourceWriterVersion"])
    }
}

private final class ReferenceCancellationFlag: @unchecked Sendable {
    var isCancelled = false
}
