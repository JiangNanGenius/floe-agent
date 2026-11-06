import Foundation
import Testing
import FloeDiagramCore
import FloeDiagramIntegration

@Test func copyRemapsAllOwnedIdentitiesAndInternalLinks() throws {
    let original = DiagramExamples.library(), fresh = try DiagramCopy.fresh(original)
    try fresh.validate()
    #expect(fresh.id != original.id && fresh.revision == 0)
    #expect(Set(fresh.pages.flatMap(\.elements).map(\.id)).isDisjoint(with: original.pages.flatMap(\.elements).map(\.id)))
    #expect(fresh.tasks.allSatisfy { $0.floeTaskID == nil })
    #expect(fresh.assets[0].id != original.assets[0].id)
    let selected = try DiagramCopy.selection(original,pageID: original.pages[0].id,ids: [original.pages[0].elements[1].id])
    try selected.validate(); #expect(selected.pages[0].elements.first?.parentID == nil)
}
@Test func formPatchPreservesDisjointChangesAndRetainsConflictingDraft() throws {
    let base = DiagramElement(title: "before")
    var draft = base, current = base; draft.title = "typed"; current.tags = ["new remote tag"]
    let merged = try DiagramFieldPatch.apply(base: base,draft: draft,current: current)
    #expect(merged.title == "typed" && merged.tags == ["new remote tag"])
    current.title = "changed elsewhere"
    #expect(throws: DiagramError.self) { try DiagramFieldPatch.apply(base: base,draft: draft,current: current) }
    #expect(draft.title == "typed")
}
@Test func fileAssetsVerifyBytesAndRejectResourceReplacement() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try FileDiagramAssets(directory: directory)
    let asset = try await store.store(DiagramExamples.pixelPNG,fileName: "image.png",mediaType: "image/png")
    #expect(try await store.data(for: asset) == DiagramExamples.pixelPNG)
    try Data(repeating: 0,count: asset.byteCount).write(to: directory.appendingPathComponent(asset.id.uuidString))
    await #expect(throws: DiagramError.self) { try await store.data(for: asset) }
    await #expect(throws: DiagramError.self) { try await store.importAsset(asset,data: DiagramExamples.pixelPNG) }
}
@Test func pageOrderAndMetadataMergeUseTheSameUndoableDiff() throws {
    let base = DiagramExamples.library(); var incoming = base
    incoming.pages.swapAt(0,2); incoming.pages[0].metadata["direction"] = "TD"; incoming.metadata["theme.custom"] = "value"
    let result = try DiagramMerge.threeWay(base: base,local: base,incoming: incoming)
    #expect(!result.requiresReview && result.document.pages.map(\.id) == incoming.pages.map(\.id))
    let edits = try DiagramDiff.edits(from: base,to: result.document)
    let applied = try DiagramEditEngine.applying(.init(documentID: base.id,expectedRevision: base.revision,edits: edits),to: base)
    #expect(applied.pages == incoming.pages && applied.metadata == incoming.metadata)
}
@Test func legacyStyleAndLinkEditsDoNotExportStaleFields() throws {
    let doc = UUID(), node = UUID()
    let data = try JSONSerialization.data(withJSONObject: ["id": doc.uuidString,"kind": "mindMap","title": "Legacy","nodes": [["id": node.uuidString,"title": "Root"]]])
    var converted = try LegacyNotesBridge.importJSON(data)
    converted.pages[0].elements[0].style = .init(fill: "#AABBCC",stroke: "#112233",text: "#334455",lineWidth: 2,cornerRadius: 8,fontSize: 19,bold: true)
    converted.pages[0].elements[0].links = [.init(url: "https://example.com/source")]
    let restored = try LegacyNotesBridge.importJSON(LegacyNotesBridge.exportJSON(converted))
    #expect(restored.element(node)?.style == converted.element(node)?.style)
    #expect(restored.element(node)?.links.first?.url == "https://example.com/source")
    let copied = try DiagramCopy.fresh(converted)
    #expect(throws: DiagramError.self) { try LegacyNotesBridge.exportJSON(copied) }
    converted.pages[0].elements[0].sources = [.init(documentID: "unknown",title: "Unrepresentable source")]
    #expect(throws: DiagramError.self) { try LegacyNotesBridge.exportJSON(converted) }
}
@Test func executionIntentIsExplicitAndSerializable() throws {
    let document = DiagramExamples.library()
    let request = try DiagramExecutionRequest(document: document,taskIDs: Set(document.tasks.map(\.id)),userInstruction: "Stop the selected plan",intent: .stop)
    #expect(try DiagramCodec.decode(DiagramExecutionRequest.self,from: DiagramCodec.encode(request)).intent == .stop)
    #expect(throws: DiagramError.self) { try DiagramExecutionRequest(document: document,userInstruction: "") }
}
@Test func crossPageMovePreservesIdentitiesAndTurnsExternalEdgesIntoLinks() throws {
    let root = DiagramElement(title: "Root"), branch = DiagramElement(title: "Branch",parentID: nil), other = DiagramElement(title: "Other")
    var moved = branch; moved.parentID = root.id
    let source = DiagramPage(title: "Source",elements: [root,moved,other],connections: [.init(from: branch.id,to: other.id,label: "Related")]), target = DiagramPage(title: "Target")
    let doc = DiagramDocument(pages: [source,target]), edits = try DiagramCrossPage.edits(doc,ids: [branch.id],from: source.id,to: target.id)
    let changed = try DiagramEditEngine.applying(.init(documentID: doc.id,expectedRevision: 0,edits: edits),to: doc)
    #expect(changed.page(source.id)?.elements.count == 2 && changed.page(target.id)?.elements.first?.id == branch.id)
    #expect(changed.element(branch.id)?.parentID == nil)
    #expect(changed.element(branch.id)?.links.first?.elementID == other.id)
    #expect(changed.element(other.id)?.links.first?.pageID == target.id)
    var locked = doc; locked.pages[0].elements[1].isLocked = true
    #expect(throws: DiagramError.self) { try DiagramEditEngine.applying(.init(documentID: doc.id,expectedRevision: 0,edits: edits),to: locked) }
}
@Test func assistantTaskSelectionContainsTaskDataAndCannotEditAnotherTask() throws {
    let document = DiagramExamples.library(), task = document.tasks[0], scope = DiagramEditScope(pageID: document.pages[0].id,elementIDs: [],taskIDs: [task.id])
    let request = try DiagramAssistantRequest(document: document,pageID: document.pages[0].id,scope: scope,instruction: "Rename the selected task")
    #expect(request.selectedElements.isEmpty && request.selectedTasks == [task] && request.selectedDependencies.isEmpty)
    var allowed = task; allowed.title = "Renamed"
    _ = try DiagramEditEngine.applying(.init(documentID: document.id,expectedRevision: document.revision,edits: [.upsertTask(allowed)]),to: document,context: .init(scope: scope))
    var outside = document.tasks[1]; outside.title = "Unauthorized"
    #expect(throws: DiagramError.self) { try DiagramEditEngine.applying(.init(documentID: document.id,expectedRevision: document.revision,edits: [.upsertTask(outside)]),to: document,context: .init(scope: scope)) }
}
@Test func deletingLinkTargetDoesNotRewriteLockedSourceContent() throws {
    let target = DiagramElement(title: "Target"), p = UUID(), link = DiagramLink(pageID: p,elementID: target.id)
    var source = DiagramElement(title: "Locked source",links: [link]); source.isLocked = true
    let document = DiagramDocument(pages: [.init(id: p,elements: [source,target])])
    let changed = try DiagramEditEngine.applying(.init(documentID: document.id,expectedRevision: 0,edits: [.deleteElements(pageID: p,ids: [target.id],includeDescendants: true)]),to: document)
    #expect(changed.element(source.id) == source && changed.isBroken(link))
}
@Test func scopedAssistantCanExtendSelectedTasksAndOnlyExplicitlyCreateIndependentRoots() throws {
    let parent = DiagramTask(title: "Selected"), outside = DiagramTask(title: "Outside"), document = DiagramDocument(tasks: [parent,outside])
    let p = document.pages[0].id, scope = DiagramEditScope(pageID: p,elementIDs: [],taskIDs: [parent.id])
    let child = DiagramTask(title: "Child",parentID: parent.id), independent = DiagramTask(title: "Independent")
    let childBatch = DiagramEditBatch(documentID: document.id,expectedRevision: 0,edits: [.upsertTask(child),.upsertDependency(.init(predecessorID: parent.id,successorID: child.id))])
    #expect(try DiagramEditEngine.applying(childBatch,to: document,context: .init(scope: scope)).tasks.count == 3)
    let rootBatch = DiagramEditBatch(documentID: document.id,expectedRevision: 0,edits: [.upsertTask(independent)])
    #expect(throws: DiagramError.self) { try DiagramEditEngine.applying(rootBatch,to: document,context: .init(scope: scope)) }
    let entirePlan = DiagramEditScope(pageID: p,elementIDs: [],taskIDs: [parent.id,outside.id],allowsNewTasks: true)
    #expect(try DiagramEditEngine.applying(rootBatch,to: document,context: .init(scope: entirePlan)).tasks.count == 3)
}
@Test func lockedTaskAlsoProtectsChildCreationAndDependencyChanges() throws {
    let task = DiagramTask(title: "Locked"), other = DiagramTask(title: "Other")
    let node = DiagramElement(title: "Locked topic",isLocked: true,taskID: task.id), document = DiagramDocument(pages: [.init(elements: [node])],tasks: [task,other])
    let scope = DiagramEditScope(pageID: document.pages[0].id,elementIDs: [],taskIDs: [task.id,other.id],allowsNewTasks: true)
    let child = DiagramTask(title: "New child",parentID: task.id)
    #expect(throws: DiagramError.self) { try DiagramEditEngine.applying(.init(documentID: document.id,expectedRevision: 0,edits: [.upsertTask(child)]),to: document,context: .init(scope: scope)) }
    #expect(throws: DiagramError.self) { try DiagramEditEngine.applying(.init(documentID: document.id,expectedRevision: 0,edits: [.upsertDependency(.init(predecessorID: task.id,successorID: other.id))]),to: document,context: .init(scope: scope)) }
    let request = try DiagramAssistantRequest(document: document,pageID: document.pages[0].id,scope: scope,instruction: "Update plan")
    #expect(request.lockedTaskIDs == [task.id] && request.allowsNewTasks)
}
