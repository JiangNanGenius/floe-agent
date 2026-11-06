// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeDiagramCore
@testable import FloeDiagramIntegration

@Test func refreshKeepsManualTitleAndUpdatesUneditedContent() throws {
    let base = DiagramExamples.library()
    var local = base, incoming = base
    local.pages[0].elements[2].title = "手工标题"; local.revision = 1
    incoming.pages[0].elements[2].content = [.note("新的来源内容")]
    let merged = try DiagramMerge.threeWay(base: base, local: local, incoming: incoming)
    #expect(!merged.requiresReview)
    #expect(merged.document.pages[0].elements[2].title == "手工标题")
    #expect(merged.document.pages[0].elements[2].content == [.note("新的来源内容")])
    let edits = try DiagramDiff.edits(from: local, to: merged.document)
    let applied = try DiagramEditEngine.applying(.init(documentID: local.id, expectedRevision: 1, edits: edits), to: local)
    #expect(applied.pages == merged.document.pages)
}
@Test func sameFieldConflictPreservesBothVersions() throws {
    let base = DiagramExamples.library()
    var local = base, incoming = base
    local.pages[0].elements[1].title = "manual"; incoming.pages[0].elements[1].title = "updated source"
    let result = try DiagramMerge.threeWay(base: base, local: local, incoming: incoming)
    #expect(result.requiresReview)
    #expect(result.document.pages[0].elements[1].title == "manual")
    #expect(result.incomingRecovery?.pages[0].elements[1].title == "updated source")
    #expect(result.incomingRecovery?.id != base.id)
}
@Test func mergeDeletionDoesNotCreateDanglingGraph() throws {
    let base = DiagramExamples.library()
    var local = base, incoming = base
    incoming.pages[0].elements.removeAll { $0.id == DiagramExamples.id(105) }
    local.pages[0].elements[5].title = "manually changed"
    let result = try DiagramMerge.threeWay(base: base, local: local, incoming: incoming)
    #expect(result.requiresReview)
    #expect(result.document.element(DiagramExamples.id(105))?.title == "manually changed")
    try result.document.validate()
}
@Test func assistantUsesHostScopeAndCannotUnlock() async throws {
    let repository = InMemoryDiagramRepository()
    var document = DiagramExamples.library(); document.pages[0].elements[1].isLocked = true
    try await repository.create(document)
    let session = DiagramSession(documentID: document.id, repository: repository)
    let batch = DiagramEditBatch(documentID: document.id, expectedRevision: 0, edits: [.setLocked(pageID: document.pages[0].id, ids: [document.pages[0].elements[1].id], locked: false)])
    do { _ = try await DiagramAssistantBridge.apply(batch, to: session, trustedScope: .document); Issue.record("AI unlocked protected content") } catch {}
    let current = try await session.snapshot(); #expect(current.pages[0].elements[1].isLocked)
    do { _ = try DiagramExecutionRequest(document: document, userInstruction: "  "); Issue.record("Implicit execution request allowed") } catch {}
}
@Test func legacyKnownAndUnknownFieldsSurvive() throws {
    let docID = UUID(), root = UUID(), child = UUID(), connection = UUID()
    let object: [String: Any] = ["schemaVersion": 2, "kind": "mindMap", "id": docID.uuidString, "revision": 4, "title": "旧导图",
        "futureField": ["preserve": true], "mindMapDirection": 0,
        "nodes": [["id": root.uuidString, "title": "Root", "note": "", "order": 0, "isCollapsed": false],
                  ["id": child.uuidString, "parentID": root.uuidString, "title": "Child", "note": "原始备注", "order": 0, "isCollapsed": false, "tags": ["tag"], "position": ["x": 300.0, "y": 50.0], "futureNodeField": "keep"]],
        "connections": [["id": connection.uuidString, "from": root.uuidString, "to": child.uuidString, "title": "关系", "delta1": ["x": 40.0, "y": -30.0]]]]
    let source = try JSONSerialization.data(withJSONObject: object)
    let imported = try LegacyNotesBridge.importJSON(source)
    #expect(imported.id == docID && imported.revision == 4)
    #expect(imported.pages[0].structure == .left)
    #expect(imported.pages[0].elements[1].frame?.center == .init(x: 300, y: 50))
    #expect(imported.pages[0].connections[0].metadata["legacyControl1"] != nil)
    let returned = try JSONSerialization.jsonObject(with: LegacyNotesBridge.exportJSON(imported)) as! [String: Any]
    #expect((returned["futureField"] as? [String: Bool])?["preserve"] == true)
    #expect(((returned["nodes"] as? [[String: Any]])?[1]["futureNodeField"] as? String) == "keep")
    var changed = imported; changed.pages[0].elements[1].content.append(.formula("x^2"))
    do { _ = try LegacyNotesBridge.exportJSON(changed); Issue.record("Legacy export silently flattened formula") } catch {}
}
@Test func missingLegacyAssetsFailClosed() throws {
    let object: [String: Any] = ["kind": "mindMap", "id": UUID().uuidString, "nodes": [["id": UUID().uuidString, "title": "Image", "imageResourceID": UUID().uuidString]]]
    do { _ = try LegacyNotesBridge.importJSON(JSONSerialization.data(withJSONObject: object)); Issue.record("missing resource accepted") } catch {}
}
