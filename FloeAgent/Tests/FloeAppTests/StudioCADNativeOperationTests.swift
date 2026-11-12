// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import ImageIO
import Testing
import FloeCore
import FloeModels
import FloeTools
import FloePersistence
@testable import FloeCAD
@testable import FloeApp

@Suite("Managed CAD native Building and Mesh services", .serialized)
@MainActor struct StudioCADNativeOperationTests {
    private let registry = ToolRunnerRegistry()
    private struct Page { let revision: String; let state: [String: Any] }
    private func call(_ name: String, _ args: [String: Any], _ context: ToolContext) async throws -> [String: Any] {
        let runner = try #require(registry.runner(named: name))
        let output = try await runner.execute(argumentsJSON: JSONSerialization.data(withJSONObject: args), context: context)
        let bytes = Data((output.capturedOutput ?? output.summary).utf8)
        #expect(StudioToolOutput.hash(bytes) == output.fullOutputSHA256)
        return try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }
    private func read(_ id: UUID, _ context: ToolContext, cad: [String: Any]? = nil,
                      firstPage: [String: Any]? = nil) async throws -> Page {
        var text = "", offset = 0, revision: String?, contentHash: String?
        for index in 0..<128 {
            var arguments: [String: Any] = ["projectID": id.uuidString, "offset": offset, "limit": 12_000]
            if let cad { arguments["cad"] = cad }
            let page: [String: Any]
            if index == 0, let firstPage { page = firstPage }
            else { page = try await call("studio.read", arguments, context) }
            let current = try #require(page["revision"] as? String)
            if let revision { try #require(current == revision) } else { revision = current }
            let currentHash = try #require(page["contentSHA256"] as? String)
            if let contentHash { try #require(currentHash == contentHash) } else { contentHash = currentHash }
            text += try #require(page["contentJSON"] as? String)
            guard let next = page["nextOffset"] as? Int else {
                try #require(StudioToolOutput.hash(Data(text.utf8)) == currentHash)
                return Page(revision: current, state: try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]))
            }
            try #require(next > offset); offset = next
        }
        throw PersonalContentError.changedDocument
    }
    private func edit(_ id: UUID, _ page: Page, _ op: String, _ args: [String: Any], _ context: ToolContext) async throws -> [String: Any] {
        let text = String(decoding: try JSONSerialization.data(withJSONObject: ["op": op, "args": args]), as: UTF8.self)
        return try await call("studio.edit", ["projectID": id.uuidString, "expectedRevision": page.revision, "operationsJSON": text], context)
    }
    private func refuses(_ text: String, _ body: () async throws -> Void) async {
        do { try await body(); Issue.record("A refused native CAD request succeeded") }
        catch let FloeError.validationFailed(message) { #expect(message.contains(text)) }
        catch { Issue.record("Native CAD refusal failed for an unrelated reason: \(error)") }
    }
    private func building(_ page: Page) throws -> [String: Any] {
        let native = try #require(page.state["nativeCAD"] as? [String: Any])
        let services = try #require(native["nativeServices"] as? [String: Any])
        return try #require(services["building"] as? [String: Any])
    }
    private func room(_ page: Page, name: String = "Authored room") throws -> [String: Any] {
        let state = try building(page)
        return ["name": name, "min": [0,0], "max": [4000,3000], "heightMM": 3000,
            "wallThicknessMM": 200, "withWalls": true,
            "expected_revision": try #require(state["revision"]), "expected_change_count": try #require(state["change_count"]),
            "expected_source_sha256": try #require(state["content_sha256"])]
    }
    private func withWork(kind: String = "cad3D", _ body: @MainActor (UUID, URL, FloeCADDocument, ToolContext, ToolContext) async throws -> Void) async throws {
        let environment = FloeAgentApp.liveEnvironment; try await environment.ensureDurableAutomationReady()
        registerStudioAgentTools(environment: environment, registry: registry)
        var conversations: [UUID] = [], contexts: [ToolContext] = []
        var ownedDirectory: URL?, document: FloeCADDocument?
        func cleanupFiles() { document?.close(); if let ownedDirectory { try? FileManager.default.removeItem(at: ownedDirectory) } }
        do {
            for _ in 0..<2 {
                let id = UUID(), runID = UUID(), now = Date(); conversations.append(id)
                try await environment.conversationStore.saveConversation(.init(id: id, title: "Native CAD service contract", createdAt: now, updatedAt: now))
                _ = try await SQLiteWorkspaceStore(database: environment.database).ensureWorkspace(conversationID: id, title: "Native CAD service contract")
                try await environment.conversationStore.setArchived(id: id, archived: true)
                try await environment.runStore.saveRun(.init(id: runID, conversationID: id, state: "executing", goal: "Native CAD service contract", startedAt: now))
                var context = ToolContext(runID: runID, toolCallID: "native-cad-services", allowedToolNames: StudioCoordinator.names,
                    cancellation: CancellationToken(), conversationID: id)
                context.frozenEffectiveCatalogNames = StudioCoordinator.names; context.approvalGrantID = UUID(); contexts.append(context)
            }
            let created = try await call("studio.create", ["kind": kind, "title": "Native service fixture \(UUID())"], contexts[0])
            let record = try #require(created["record"] as? [String: Any])
            let id = try #require((record["id"] as? String).flatMap(UUID.init(uuidString:)))
            let resolved = try await PersonalContentService.shared.library().resolve(id)
            ownedDirectory = resolved.url
            let value = try await PersonalCADSessions.open(id: id, directory: resolved.url); document = value
            try await body(id, resolved.url, value, contexts[0], contexts[1])
        } catch {
            cleanupFiles(); for id in conversations { try? await environment.conversationStore.deleteConversation(id: id) }; throw error
        }
        cleanupFiles(); for id in conversations { try await environment.conversationStore.deleteConversation(id: id) }
    }
    @Test func registeredBuildingRoomAndMeshMaterialTransformSaveTheSameOriginalWithReceipts() async throws {
        try await withWork { id, directory, document, context, _ in
            let first = try await read(id, context)
            #expect(try building(first)["hasBuilding"] as? Bool == false)
            let native = try #require(first.state["nativeCAD"] as? [String: Any])
            let operations = try #require(native["nativeOperations"] as? [String])
            #expect(operations.contains("building.addRoom") && operations.contains("mesh.material") && !operations.contains("mesh.text"))
            let result = try await edit(id, first, "building.addRoom", room(first), context)
            let receipt = try #require(result["operationResult"] as? [String: Any])
            #expect(receipt["saved"] as? Bool == true && receipt["operation"] as? String == "building.addRoom")
            #expect((receipt["createdElementIDs"] as? [String])?.count == 5)
            let built = try await read(id, context), state = try building(built)
            #expect(state["elementCount"] as? Int == 5 && state["complete"] as? Bool == true)
            let bodies = try #require(built.state["bodies"] as? [[String: Any]])
            let body = try #require(bodies.first), raw = try #require(body["id"] as? String)
            let bounds = try #require(body["bounds"] as? [[Double]])
            let material = try await edit(id, built, "mesh.material", ["bodyID": raw, "color": [0.1,0.2,0.8], "roughness": 0.4], context)
            let materialReceipt = try #require(material["operationResult"] as? [String: Any])
            #expect(materialReceipt["saved"] as? Bool == true && materialReceipt["exactness"] as? String == "preserved")
            let colored = try await read(id, context)
            let moved = try await edit(id, colored, "mesh.transform", ["bodyID": raw, "translate": [20,0,0]], context)
            #expect((moved["operationResult"] as? [String: Any])?["saved"] as? Bool == true)
            let after = try await read(id, context)
            let updated = try #require((after.state["bodies"] as? [[String: Any]])?.first(where: { $0["id"] as? String == raw }))
            let movedBounds = try #require(updated["bounds"] as? [[Double]])
            #expect(abs(movedBounds[0][0] - bounds[0][0] - 20) < 1e-8)
            #expect(updated["brep"] as? Bool == body["brep"] as? Bool)
            let savedURL = document.url; document.close()
            let reopened = try await PersonalCADSessions.open(id: id, directory: directory)
            defer { reopened.close() }
            #expect(reopened.url == savedURL)
            let saved = try await read(id, context)
            #expect(try building(saved)["elementCount"] as? Int == 5)
            let actual = try #require(reopened.session.document.bodies.first(where: { $0.id.raw.uuidString == raw }))
            #expect(actual.material?.baseColor.z == 0.8)
            reopened.close()
        }
    }
    @Test func standalone2DOnlyOffersSketchServicesAndEditsEntityDimensionConstraintUndo() async throws {
        try await withWork(kind: "cad2D") { id, _, document, context, _ in
            let first = try await read(id, context)
            let native = try #require(first.state["nativeCAD"] as? [String: Any])
            let operations = try #require(native["nativeOperations"] as? [String])
            for op in ["updateSketchEntity", "deleteSketchEntity", "addSketchConstraint",
                       "setSketchDimension", "removeSketchDimension", "trimSketchCurve",
                       "offsetSketchCurve", "undo", "redo", "document.importDrawing"] {
                #expect(operations.contains(op))
            }
            #expect(!operations.contains("mesh.material") && !operations.contains("feature.extrude"))
            let geometry = try #require(native["geometryOperations"] as? [String])
            #expect(Set(geometry).isSubset(of: ["sketch.create", "sketch.addEntities", "sketch.addText", "item.setHidden"]))
            #expect((native["threeDOnlyGeometryOperations"] as? [String])?.contains("feature.extrude") == true)
            let created = try await edit(id, first, "sketch.create", ["name": "Bounded 2D"], context)
            let receipt = try #require(created["operationResult"] as? [String: Any])
            let sketchID = try #require(receipt["sketchID"] as? String)
            #expect(receipt["saved"] as? Bool == true)
            #expect(receipt["revision"] as? Int == document.revision)
            #expect(receipt["content_sha256"] as? String == document.contentSHA256)
            let storedIdentity = await FloeCADDocument.storedIdentity(at: document.url)
            let committed = try #require(storedIdentity)
            #expect(receipt["revision"] as? Int == committed.revision)
            #expect(receipt["content_sha256"] as? String == committed.contentSHA256)
            let query: [String: Any] = ["sketchID": sketchID]
            let withSketch = try await read(id, context, cad: query)
            _ = try await edit(id, withSketch, "sketch.addEntities", ["sketchID": sketchID,
                "entities": [["kind": "line", "a": [0, 0], "b": [100, 0]]]], context)
            let withEntity = try await read(id, context, cad: query)
            let entities = try #require((withEntity.state["nativeCAD"] as? [String: Any])?["entities"] as? [String: Any])
            let entity = try #require((entities["rows"] as? [[String: Any]])?.first)
            let entityID = try #require(entity["id"] as? String)
            #expect(entity["lengthMM"] as? Double == 100)
            let measured = try await read(id, context, cad: ["sketchID": sketchID,
                "measure": ["kind": "entity", "sketchID": sketchID, "entityID": entityID]])
            let measuredNative = try #require(measured.state["nativeCAD"] as? [String: Any])
            let measuredResult = try #require(measuredNative["measureResult"] as? [String: Any])
            #expect(measuredResult["ok"] as? Bool == true && measuredResult["lengthMM"] as? Double == 100)
            _ = try await edit(id, withEntity, "updateSketchEntity", ["sketch_id": sketchID,
                "entity_id": entityID, "a": [0, 0], "b": [120, 0]], context)
            let edited = try await read(id, context, cad: query)
            let editedRows = try #require((edited.state["nativeCAD"] as? [String: Any])?["entities"] as? [String: Any])
            #expect(((editedRows["rows"] as? [[String: Any]])?.first)?["lengthMM"] as? Double == 120)
            _ = try await edit(id, edited, "addSketchConstraint", ["sketch_id": sketchID,
                "kind": "horizontal", "refs": [["entity_id": entityID, "role": "whole"]]], context)
            let constrained = try await read(id, context, cad: query)
            _ = try await edit(id, constrained, "setSketchDimension", ["sketch_id": sketchID,
                "entity_id": entityID, "kind": "length", "value": 130], context)
            let dimensioned = try await read(id, context, cad: query)
            let dimensions = try #require((dimensioned.state["nativeCAD"] as? [String: Any])?["constraints"] as? [String: Any])
            let dimensionRows = try #require(dimensions["rows"] as? [[String: Any]])
            #expect(dimensionRows.contains { $0["isDimension"] as? Bool == true && $0["kind"] as? String == "distance" })
            #expect(((dimensioned.state["nativeCAD"] as? [String: Any])?["entities"] as? [String: Any])?["rows"] != nil)
            _ = try await edit(id, dimensioned, "deleteSketchEntity", ["sketch_id": sketchID, "entity_id": entityID], context)
            let deleted = try await read(id, context, cad: query)
            let deletedRows = try #require((deleted.state["nativeCAD"] as? [String: Any])?["entities"] as? [String: Any])
            #expect((deletedRows["rows"] as? [[String: Any]])?.isEmpty == true)
            _ = try await edit(id, deleted, "undo", [:], context)
            let restored = try await read(id, context, cad: query)
            let restoredRows = try #require((restored.state["nativeCAD"] as? [String: Any])?["entities"] as? [String: Any])
            #expect((restoredRows["rows"] as? [[String: Any]])?.count == 1)
            #expect(document.hasUnsavedChanges == false)
        }
    }

    @Test func managedDrawingImportAppendsIntoTheAuthorizedTwoDSketch() async throws {
        try await withWork(kind: "cad2D") { id, _, document, context, _ in
            let sketch = try await edit(id, try await read(id, context), "sketch.create", ["name": "Imported"], context)
            let sketchID = try #require((sketch["operationResult"] as? [String: Any])?["sketchID"] as? String)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("CADImport-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Drawings"), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            // Real source bytes go through the configured native drawing decoder.
            let bytes = Data("0\nSECTION\n2\nHEADER\n9\n$ACADVER\n1\nAC1015\n9\n$INSUNITS\n70\n4\n0\nENDSEC\n0\nSECTION\n2\nENTITIES\n0\nLINE\n5\nA1\n8\n0\n10\n0\n20\n0\n30\n0\n11\n25\n21\n0\n31\n0\n0\nENDSEC\n0\nEOF\n".utf8)
            let digest = CADSketchTransferEnvelope.digest(bytes)
            try bytes.write(to: root.appendingPathComponent("Drawings/test.dxf"))
            let query: [String: Any] = ["sketchID": sketchID]
            var taskContext = context
            taskContext.workspaceRootURL = root
            let before = try await read(id, taskContext, cad: query)
            let importJSON = try JSONSerialization.data(withJSONObject: ["op": "document.importDrawing", "args": [
                "sketchID": sketchID,
                "source": ["workspacePath": "Drawings/test.dxf", "expectedSHA256": digest],
                "placement": ["sourceAnchor": [0, 0], "offsetMM": [0, 0], "rotationDegrees": 0, "unitScaleMM": 1],
            ]], options: [.sortedKeys])
            _ = try await call("studio.edit", ["projectID": id.uuidString, "expectedRevision": before.revision,
                "operationsJSON": String(decoding: importJSON, as: UTF8.self)], taskContext)
            let after = try await read(id, taskContext, cad: query)
            let entities = try #require((after.state["nativeCAD"] as? [String: Any])?["entities"] as? [String: Any])
            #expect((entities["rows"] as? [[String: Any]])?.count == 1)
            #expect(((entities["rows"] as? [[String: Any]])?.first?["lengthMM"] as? Double) == 25)
        }
    }

    @Test func bounded2DReadPagesSketchesAndEntitiesWithoutClaimingCompleteness() async throws {
        try await withWork(kind: "cad2D") { id, _, document, context, _ in
            try #require(document.session.document.sketches.count == 1)
            let initialSketch = try #require(document.session.document.sketches.first)
            for index in 0..<3 {
                let sketchID: String
                if index == 0 { sketchID = initialSketch.id.raw.uuidString }
                else {
                    try #require(document.execute(["op": "sketch.create", "args": ["name": "Page \(index)"]]).isOK)
                    sketchID = try #require(document.session.document.sketches.last?.id.raw.uuidString)
                }
                try #require(document.execute(["op": "sketch.addEntities", "args": ["sketchID": sketchID,
                    "entities": [["kind": "circle", "center": [Double(index), 0], "radius": 5]]]]).isOK)
            }
            try #require((await document.save()).succeeded)
            let page = try await read(id, context, cad: ["sketchLimit": 1, "sketchOffset": 0, "entityLimit": 1])
            let object = page.state
            let native = try #require(object["nativeCAD"] as? [String: Any])
            let sketchQuery = try #require(native["sketchQuery"] as? [String: Any])
            #expect(sketchQuery["total"] as? Int == 3)
            #expect(sketchQuery["sketchesComplete"] as? Bool == false)
            #expect(sketchQuery["nextOffset"] as? Int == 1)
            #expect(native["sketchesComplete"] as? Bool == false)
            let entities = try #require(native["entities"] as? [String: Any])
            #expect(entities["complete"] as? Bool == true)
            #expect((entities["rows"] as? [[String: Any]])?.count == 1)
            let ordinaryProjection = try await read(id, context)
            #expect(ordinaryProjection.revision == page.revision)
            let unchangedCount = document.exchangeChangeCount
            _ = try await edit(id, page, "document.save", [:], context)
            #expect(document.exchangeChangeCount == unchangedCount)
        }
    }

    @Test func cadRenderAndExportUseTheSavedDrawingPageAndPublishRealBytes() async throws {
        try await withWork(kind: "cad2D") { id, _, document, context, _ in
            try #require(document.execute(["op": "sketch.create", "args": ["name": "Export sheet"]]).isOK)
            let actualSketch = try #require(document.session.document.sketches.last?.id.raw.uuidString)
            try #require(document.execute(["op": "sketch.addEntities", "args": ["sketchID": actualSketch,
                "entities": [["kind": "line", "a": [0, 0], "b": [50, 0]]]]]).isOK)
            try #require((await document.save()).succeeded)
            let state = try await read(id, context)
            print("CAD drawing contract stage: 2D native-plane PNG")
            let render = try await call("studio.run", ["projectID": id.uuidString, "action": "render",
                "inputJSON": "{\"expectedRevision\":\"\(state.revision)\"}"], context)
            #expect((render["width"] as? Int ?? 0) > 0 && (render["height"] as? Int ?? 0) > 0)
            #expect(render["artifact"] is [String: Any])
            let savedRevision = try #require((state.state["nativeCAD"] as? [String: Any])?["savedRevision"] as? Int)
            let legacyInput = try JSONSerialization.data(withJSONObject: ["expectedRevision": savedRevision])
            let legacy = try await call("studio.run", ["projectID": id.uuidString, "action": "render",
                "inputJSON": String(decoding: legacyInput, as: UTF8.self)], context)
            #expect((legacy["width"] as? Int ?? 0) > 0 && (legacy["height"] as? Int ?? 0) > 0)
            let actualID = try #require(UUID(uuidString: actualSketch))
            let expectedBytes: Data
            switch document.nativeSketchDXFData(sketchID: actualID) {
            case .success(let data, _): expectedBytes = data
            case .failure(let error): throw error
            }
            #expect(String(decoding: expectedBytes, as: UTF8.self).contains("LINE"))
            let exported = try await call("studio.run", ["projectID": id.uuidString, "action": "export",
                "inputJSON": "{\"expectedRevision\":\"\(state.revision)\",\"format\":\"dxf\",\"sketchID\":\"\(actualSketch)\"}"], context)
            let output = try #require(exported["outputFile"] as? [String: Any])
            #expect(output["byteCount"] as? Int == expectedBytes.count)
            #expect(exported["sha256"] as? String == StudioToolOutput.hash(expectedBytes))
            #expect(exported["format"] as? String == "dxf")
            #expect(document.hasUnsavedChanges == false)
            print("CAD drawing contract stage complete: 2D PNG and exact sketch DXF bytes/SHA")
        }
        // The 3D engineering route keeps its exact B-rep source requirement.
        // A real extruded body with explicit bodyIDs must export successfully;
        // an empty page must still refuse instead of claiming completeness.
        try await withWork(kind: "cad3D") { id, _, document, context, _ in
            let created = try await edit(id, try await read(id, context), "sketch.create", ["name": "Projection body"], context)
            let result = try #require(created["operationResult"] as? [String: Any])
            let sketchID = try #require(result["sketchID"] as? String)
            _ = try await edit(id, try await read(id, context), "sketch.addEntities", ["sketchID": sketchID,
                "entities": [["kind": "rect", "min": [0, 0], "max": [10, 5]]]], context)
            let extruded = try await edit(id, try await read(id, context), "feature.extrude", ["sketchID": sketchID,
                "seedPoint": [5, 2.5], "distance": 3], context)
            let producedIDs = try #require((extruded["operationResult"] as? [String: Any])?["producedBodyIDs"] as? [String])
            try #require(producedIDs.count == 1, "The positive control must use the body produced by this actual extrusion.")
            let body = try #require(document.session.document.bodies.first { $0.id.raw.uuidString == producedIDs[0] })
            try #require(body.brep != nil, "The 3D projection positive control must own an exact B-rep before drawing export.")
            let drawings = CADDrawingService(document: document)
            let empty = drawings.handle(action: "addPage", args: ["kind": "front"])
            try #require(empty["ok"] as? Bool == true)
            let emptyPage = try #require((empty["page"] as? [String: Any])?["id"] as? String)
            let prepared = drawings.handle(action: "addPage", args: ["kind": "front", "bodyIDs": [body.id.raw.uuidString]])
            try #require(prepared["ok"] as? Bool == true)
            let pageID = try #require((prepared["page"] as? [String: Any])?["id"] as? String)
            try #require((await document.save()).succeeded)
            let state = try await read(id, context)
            await refuses("incomplete_projection") {
                _ = try await call("studio.run", ["projectID": id.uuidString, "action": "export",
                    "inputJSON": "{\"expectedRevision\":\"\(state.revision)\",\"format\":\"dxf\",\"pageID\":\"\(emptyPage)\"}"], context)
            }
            print("CAD drawing contract stage: 3D exact B-rep front-page PNG and DXF")
            let rendered = try await call("studio.run", ["projectID": id.uuidString, "action": "render",
                "inputJSON": "{\"expectedRevision\":\"\(state.revision)\",\"pageID\":\"\(pageID)\"}"], context)
            #expect((rendered["width"] as? Int ?? 0) > 0 && (rendered["height"] as? Int ?? 0) > 0)
            #expect(rendered["artifact"] is [String: Any])
            let exported = try await call("studio.run", ["projectID": id.uuidString, "action": "export",
                "inputJSON": "{\"expectedRevision\":\"\(state.revision)\",\"format\":\"dxf\",\"pageID\":\"\(pageID)\"}"], context)
            let output = try #require(exported["outputFile"] as? [String: Any])
            #expect((output["byteCount"] as? Int ?? 0) > 0 && exported["format"] as? String == "dxf")
            #expect(!document.hasUnsavedChanges)
        }
    }

    @Test func staleForeignUnknownAndUnexpectedFieldRequestsDoNotAlterTheOriginal() async throws {
        try await withWork { id, _, document, context, foreign in
            let first = try await read(id, context)
            _ = try await edit(id, first, "building.addRoom", room(first), context)
            let fresh = try await read(id, context), bytes = document.contentSHA256, count = document.exchangeChangeCount
            do { _ = try await edit(id, first, "building.addRoom", room(first), context);Issue.record("A stale native edit succeeded") }
            catch PersonalContentError.changedDocument { }
            catch { Issue.record("Native CAD CAS failed for an unrelated reason: \(error)") }
            await refuses("Open this work") { _ = try await edit(id, fresh, "building.addRoom", room(fresh), foreign) }
            await refuses("nativeCAD.nativeOperations") { _ = try await edit(id, fresh, "mesh.arbitrary", [:], context) }
            let body = try #require((fresh.state["bodies"] as? [[String: Any]])?.first?["id"] as? String)
            await refuses("Unsupported native CAD fields") { _ = try await edit(id, fresh, "mesh.material", ["bodyID": body, "color": [0,0,1], "path": "/untrusted"], context) }
            await refuses("nativeCAD.nativeOperations") { _ = try await edit(id, fresh, "building.inspect", [:], context) }
            #expect(document.exchangeChangeCount == count && document.contentSHA256 == bytes)
            let repeatedRead = try await read(id, context)
            #expect(repeatedRead.revision == fresh.revision && document.exchangeChangeCount == count)
        }
    }
    #if DEBUG
    @Test func failedServiceSaveRestoresOnlyItsCheckpointAndNeverErasesANewerUICommand() async throws {
        try await withWork { id, _, document, context, _ in
            let first = try await read(id, context)
            _ = try await edit(id, first, "building.addRoom", room(first), context)
            let original = try await read(id, context), priorSHA = document.contentSHA256
            let body = try #require((original.state["bodies"] as? [[String: Any]])?.first?["id"] as? String)
            let bodyID = try #require(UUID(uuidString: body)), before = try #require(document.session.document.bodies.first(where: { $0.id.raw == bodyID }))
            document.saveFailureForTesting = "Native service save fixture"
            defer { document.saveFailureForTesting = nil; document.saveSuspensionForTesting = nil }
            await refuses("Native service save fixture") { _ = try await edit(id, original, "mesh.material", ["bodyID": body, "color": [1,0,0]], context) }
            #expect(document.contentSHA256 == priorSHA)
            #expect(document.session.document.bodies.first(where: { $0.id.raw == bodyID })?.material == before.material)
            #expect(document.saveFailureForTesting == nil, "The native save-failure fixture is consumed after one save.")
            let next = try await read(id, context)
            document.saveSuspensionForTesting = {
                #expect(document.renameExistingItem(kind: .body, id: bodyID, name: "Newer native UI name", expectedChangeCount: document.exchangeChangeCount).isOK)
            }
            // This is a second failed save; rearm the same one-shot native fixture.
            document.saveFailureForTesting = "Native service save fixture"
            await refuses("Native service save fixture") { _ = try await edit(id, next, "mesh.material", ["bodyID": body, "color": [0,0,1]], context) }
            #expect(document.session.document.bodies.first(where: { $0.id.raw == bodyID })?.name == "Newer native UI name")
            #expect(document.contentSHA256 == priorSHA)
        }
    }
    #endif
    @Test func cancellationAfterTheRealServiceAndBeforeSaveDoesNotPublishASavedEdit() async throws {
        try await withWork { id, _, document, context, _ in
            let first = try await read(id, context), before = document.contentSHA256
            let args = try room(first), command = try JSONSerialization.data(withJSONObject: ["op": "building.addRoom", "args": args])
            let identity = try StudioCADToolContract.Identity(snapshot: JSONSerialization.data(withJSONObject: first.state))
            var checks = 0
            await #expect(throws: (any Error).self) {
                _ = try await StudioCADToolContract.applyAndSave(command, to: document, expected: identity, kind: .cad3D, context: context) {
                    checks += 1
                    if checks == 2 { context.cancellation.cancel() }
                }
            }
            #expect(checks == 2 && document.contentSHA256 == before)
            #expect(try document.building() == nil)
        }
    }
    @Test func standalone2DRefusesManufacturingWhile3DSketchKeepsItsRoute() async throws {
        try await withWork(kind: "cad2D") { id, _, document, context, _ in
            let first = try await read(id, context)
            #expect(first.state["machining"] == nil)
            let page = try await call("studio.read", ["projectID": id.uuidString], context)
            #expect(page["manufacturingCell"] == nil)
            let guide = try #require(page["editFormat"] as? String)
            #expect(!guide.contains("feature.extrude") && !guide.contains("body.setMaterial"))
            let before = document.observationIdentity()
            for action in ["inspect", "prepare", "calculate", "preparePrint", "research.inspect"] {
                await refuses("standalone 2D") {
                    var arguments: [String: Any] = ["projectID": id.uuidString, "action": action,
                        "expectedRevision": first.revision]
                    if action.hasPrefix("research.") { arguments["researchJSON"] = "{\"family\":\"manufacturingCell\"}" }
                    _ = try await call("studio.machining", arguments, context)
                }
            }
            #expect(document.observationIdentity() == before)
        }
        try await withWork(kind: "cad3D") { id, _, _, context, _ in
            let first = try await read(id, context)
            _ = try await edit(id, first, "sketch.create", ["name": "Sketch inside 3D"], context)
            let current = try await read(id, context)
            #expect(current.state["machining"] != nil)
            let inspection = try await call("studio.machining", ["projectID": id.uuidString, "action": "inspect"], context)
            #expect(inspection["manufacturingCell"] != nil)
            let complete = try await read(id, context, firstPage: inspection)
            #expect(complete.state["machining"] != nil)
        }
    }

    @Test func standalone2DSketchObservationPublishesActualPNGOnItsPlaneWithoutChangingTheOriginal() async throws {
        // Each owned original has no drawing page. XY is normal +Z (0/0
        // turntable angles); YZ here has normal -X (-90/0), not a top pole.
        for (xAxis, normal, azimuth) in [([1.0,0,0], [0.0,0,1], 0.0), ([0.0,0,1], [-1.0,0,0], -90.0)] {
            try await withWork(kind: "cad2D") { id, _, document, context, _ in
                let first = try await read(id, context)
                let created = try await edit(id, first, "sketch.create", ["name": "Plane-bound observation",
                    "origin": [0,0,0], "xAxis": xAxis, "yAxis": [0,1,0]], context)
                let receipt = try #require(created["operationResult"] as? [String: Any])
                let sketchID = try #require(receipt["sketchID"] as? String)
                let sketchPage = try await read(id, context)
                _ = try await edit(id, sketchPage, "sketch.addEntities", ["sketchID": sketchID,
                    "entities": [["kind": "line", "a": [0,0], "b": [120,45]]]], context)
                let model = document.viewModel()
                let entity = try #require(document.session.document.sketches.first(where: { $0.id.raw.uuidString == sketchID })?.entities.first)
                model.selectedSketchEntityIDs = [entity.id]
                var navigationCamera = TurntableCamera()
                navigationCamera.azimuth = 0.37; navigationCamera.elevation = 0.21; navigationCamera.distance = 520
                model.cameraBeforeSketchNavigation = navigationCamera
                model.cameraEpoch = 19
                let beforeIdentity = document.observationIdentity()
                let beforeSnapshot = document.snapshotJSON()
                let beforeSelection = model.selectedSketchEntityIDs
                let beforeSettings = document.session.document.sceneSettingsData
                let input = String(decoding: try JSONSerialization.data(withJSONObject: ["expectedRevision": document.revision]), as: UTF8.self)
                // No Metal/viewport skip: a real renderer failure must remain a
                // failed App contract, with its original diagnostic intact.
                let output = try await call("studio.run", ["projectID": id.uuidString,
                    "action": azimuth == 0 ? "render" : "inspectFrame", "inputJSON": input], context)
                let observation = try #require(output["observation"] as? [String: Any])
                #expect(observation["normal"] as? [Double] == normal)
                #expect(abs((observation["azimuthDegrees"] as? Double ?? 999) - azimuth) < 1e-8)
                #expect(abs(observation["elevationDegrees"] as? Double ?? 999) < 1e-8)
                #expect(observation["projection"] as? String == "orthographic")
                #expect(observation["contentSHA256"] as? String == beforeIdentity.contentSHA256)
                #expect(observation["changeCount"] as? Int == beforeIdentity.changeCount)
                #expect((observation["sketchIDs"] as? [String])?.contains(sketchID) == true)
                let artifactJSON = try #require(output["artifact"] as? [String: Any])
                let artifact = try JSONDecoder().decode(ToolArtifactReference.self, from: JSONSerialization.data(withJSONObject: artifactJSON))
                try #require(artifact.relativePath.hasPrefix("GeneratedImages/Studio/\(context.runID.uuidString)/"))
                let url = try FloeArtifactStore.root().appendingPathComponent(artifact.relativePath)
                defer { try? FileManager.default.removeItem(at: url) }
                let bytes = try Data(contentsOf: url)
                #expect(StudioToolOutput.hash(bytes) == artifact.sha256 && bytes.count == artifact.byteCount)
                Attachment.record(Array(bytes), named: azimuth == 0 ? "CAD2D-observation-XY.png" : "CAD2D-observation-YZ.png")
                let image = try #require(CGImageSourceCreateWithData(bytes as CFData, nil))
                let properties = try #require(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any])
                #expect(properties[kCGImagePropertyPixelWidth] as? Int == 1024)
                #expect(properties[kCGImagePropertyPixelHeight] as? Int == 768)
                #expect(output["pageID"] == nil)
                #expect(document.observationIdentity() == beforeIdentity && document.snapshotJSON() == beforeSnapshot)
                #expect(model.selectedSketchEntityIDs == beforeSelection && model.cameraEpoch == 19)
                #expect(model.cameraBeforeSketchNavigation?.azimuth == navigationCamera.azimuth)
                #expect(model.cameraBeforeSketchNavigation?.elevation == navigationCamera.elevation)
                #expect(model.cameraBeforeSketchNavigation?.distance == navigationCamera.distance)
                #expect(document.session.document.sceneSettingsData == beforeSettings)
            }
        }
    }

}
#endif
