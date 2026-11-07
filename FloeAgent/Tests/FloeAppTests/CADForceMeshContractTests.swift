// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloeCAD
import FloeWorkbench

@Suite("Native force-mesh contract", .serialized)
@MainActor struct CADForceMeshContractTests {
    private func json(_ outcome: CADCommandOutcome) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: outcome.payload) as? [String: Any])
    }
    private func body(_ document: FloeCADDocument, id: String? = nil) throws -> [String: Any] {
        let rows = try #require(json(document.nativeQueryJSON(["scope":"bodies"]))["rows"] as? [[String:Any]])
        if let id { return try #require(rows.first { $0["id"] as? String == id }) }
        return try #require(rows.first)
    }
    private func cube(_ document: FloeCADDocument) throws -> String {
        let created = document.execute(["op":"sketch.create","args":["name":"Exact cube"]])
        try #require(created.isOK)
        let sketch = try #require(json(created)["sketchID"] as? String)
        try #require(document.execute(["op":"sketch.addEntities","args":["sketchID":sketch,
            "entities":[["kind":"rect","min":[0.0,0.0],"max":[10.0,10.0]]]]]).isOK)
        try #require(document.execute(["op":"feature.extrude","args":["sketchID":sketch,
            "seedPoint":[5.0,5.0],"distance":10.0]]).isOK)
        let row = try body(document)
        try #require(row["analyticBRep"] as? Bool == true)
        return try #require(row["id"] as? String)
    }
    private func directory() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent("ForceMesh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:value,withIntermediateDirectories:true)
        return value
    }
    private func same(_ lhs: Any, _ rhs: Any) throws -> Bool {
        try JSONSerialization.data(withJSONObject:lhs,options:[.sortedKeys,.fragmentsAllowed])
            == JSONSerialization.data(withJSONObject:rhs,options:[.sortedKeys,.fragmentsAllowed])
    }

    @Test func falseIsNotConversionConsentAndInvalidFlagsChangeNothing() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at:root) }
        let document = try await FloeCADDocument.create(at:root.appendingPathComponent("exact.floecad"),name:"Exact")
        defer { document.close() }
        let id = try cube(document), service = CADMeshService(document:document)
        let count = document.exchangeChangeCount, before = document.snapshotJSON()
        let refused = await service.handleAsync(action:"repair",args:["bodyID":id,"forceMesh":false])
        #expect(refused["ok"] as? Bool == false)
        #expect(refused["error"] as? String == "brep_body_refused")
        for value:Any in ["true",1,NSNull()] {
            let invalid = await service.handleAsync(action:"repair",args:["bodyID":id,"forceMesh":value])
            #expect(invalid["error"] as? String == "bad_request")
        }
        let alias = await service.handleAsync(action:"repair",args:["bodyID":id,"force_mesh":true])
        #expect(alias["error"] as? String == "unknown_argument")
        #expect(document.exchangeChangeCount == count)
        #expect(document.snapshotJSON() == before)
        #expect(try body(document,id:id)["analyticBRep"] as? Bool == true)
    }

    @Test func preservingEditsRefuseAnApparentConversionInsteadOfIgnoringIt() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at:root) }
        let document = try await FloeCADDocument.create(at:root.appendingPathComponent("preserved.floecad"),name:"Preserved")
        defer { document.close() }
        let id = try cube(document), service = CADMeshService(document:document)
        let count = document.exchangeChangeCount, before = document.snapshotJSON()
        for action in ["transform","material","recomputeNormals"] {
            let result = await service.handleAsync(action:action,args:["bodyID":id,"forceMesh":true,
                "translate":[20.0,0.0,0.0],"color":[0.2,0.4,0.8,1.0]])
            #expect(result["ok"] as? Bool == false)
            #expect(result["error"] as? String == "unsupported_argument")
            #expect(result["mutated"] as? Bool != true)
        }
        #expect(document.exchangeChangeCount == count)
        #expect(document.snapshotJSON() == before)
        let moved = await service.handleAsync(action:"transform",args:["bodyID":id,"translate":[20.0,0.0,0.0]])
        let painted = await service.handleAsync(action:"material",args:["bodyID":id,"color":[0.2,0.4,0.8,1.0]])
        #expect(moved["ok"] as? Bool == true && moved["exactness"] as? String == "preserved")
        #expect(painted["ok"] as? Bool == true && painted["exactness"] as? String == "preserved")
        #expect(try body(document,id:id)["analyticBRep"] as? Bool == true)
    }

    @Test func explicitRebuildSavesAnActualMeshCopyAndKeepsPlacementAppearanceAndOriginal() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at:root) }
        let sourceURL = root.appendingPathComponent("original.floecad"), copyURL = root.appendingPathComponent("mesh-copy.floecad")
        let source = try await FloeCADDocument.create(at:sourceURL,name:"Original")
        let id = try cube(source)
        try #require((await source.save()).succeeded)
        let sourceHash = source.contentSHA256
        source.close()
        try FileManager.default.copyItem(at:sourceURL,to:copyURL)
        let copy = try await FloeCADDocument.open(at:copyURL); defer { copy.close() }
        let service = CADMeshService(document:copy)
        try #require((await service.handleAsync(action:"transform",args:["bodyID":id,"translate":[20.0,0.0,0.0]]))["ok"] as? Bool == true)
        try #require((await service.handleAsync(action:"material",args:["bodyID":id,"color":[0.2,0.4,0.8,1.0],"roughness":0.4]))["ok"] as? Bool == true)
        let positioned = try body(copy,id:id), count = copy.exchangeChangeCount
        let preview = await service.handleAsync(action:"repair",args:["bodyID":id,"forceMesh":true,"preview":true])
        try #require(preview["ok"] as? Bool == true)
        #expect(preview["preview"] as? Bool == true && preview["mutated"] as? Bool == false)
        #expect(copy.exchangeChangeCount == count)
        #expect(try body(copy,id:id)["analyticBRep"] as? Bool == true)
        let applied = await service.handleAsync(action:"repair",args:["bodyID":id,"forceMesh":true,"preview":false,
            "expectedPreviewHash":try #require(preview["previewHash"] as? String),
            "expectedRevision":copy.revision,"expectedChangeCount":count])
        try #require(applied["ok"] as? Bool == true)
        #expect(applied["mutated"] as? Bool == true && applied["exactness"] as? String == "mesh")
        #expect(applied["preview"] as? Bool != true)
        #expect(try body(copy,id:id)["analyticBRep"] as? Bool == false)
        let undo = CADViewOverlayService(document:copy).handle(action:"undo",args:["expected_change_count":copy.exchangeChangeCount])
        try #require(undo["ok"] as? Bool == true)
        #expect(try body(copy,id:id)["analyticBRep"] as? Bool == true)
        let redo = CADViewOverlayService(document:copy).handle(action:"redo",args:["expected_change_count":copy.exchangeChangeCount])
        try #require(redo["ok"] as? Bool == true)
        try #require((await copy.save()).succeeded)
        copy.close()
        let reopened = try await FloeCADDocument.open(at:copyURL); defer { reopened.close() }
        let row = try body(reopened,id:id)
        #expect(row["analyticBRep"] as? Bool == false && row["openSurfaceBRep"] as? Bool == false)
        #expect(try same(try #require(row["bounds"]),try #require(positioned["bounds"])))
        #expect(try same(try #require(row["material"]),try #require(positioned["material"])))
        let original = try await FloeCADDocument.open(at:sourceURL); defer { original.close() }
        #expect(original.contentSHA256 == sourceHash)
        #expect(try body(original,id:id)["analyticBRep"] as? Bool == true)
    }

    @Test func schemaRejectsTopLevelFlagsAndCatalogMatchesPreservingOperations() throws {
        for key in ["forceMesh","force_mesh"] {
            let bytes = try JSONSerialization.data(withJSONObject:["action":"import","path":"target.floecad","source_path":"part.step",key:true])
            do {
                _ = try JSONDecoder().decode(CadDocumentArguments.self,from:bytes)
                Issue.record("A misplaced conversion flag was silently ignored")
            } catch DecodingError.dataCorrupted(let context) {
                #expect(context.debugDescription.contains("not a cad.document top-level argument"))
            }
        }
        for action in ["transform","recomputeNormals","material"] {
            let operation = try #require(CadServiceOperationCatalog.operation(kind:"mesh",action:action))
            #expect(!operation.arguments.contains { $0.name == "forceMesh" })
        }
        let combine = try #require(CadServiceOperationCatalog.operation(kind:"mesh",action:"combine"))
        #expect(combine.arguments.contains { $0.name == "forceMesh" })
    }
}
#endif
