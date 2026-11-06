// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import FloeDiagramCore

private func expectFailure<T>(_ action: () async throws -> T) async {
    do { _ = try await action(); Issue.record("Expected a failure") } catch {}
}
@Test func richDocumentRoundTrip() throws {
    let document = DiagramExamples.library()
    try document.validate()
    let reopened = try DiagramCodec.decode(DiagramDocument.self, from: DiagramCodec.encode(document))
    #expect(document == reopened)
    #expect(reopened.pages.count == 3)
    #expect(reopened.pages[1].connections.contains { $0.from == DiagramExamples.id(512) && $0.to == DiagramExamples.id(511) })
}
@Test func duplicatePageRemapsInternalLinksAndTasks() throws {
    var document = DiagramExamples.library()
    document.pages[0].elements[0].links = [.init(pageID: document.pages[0].id, elementID: document.pages[0].elements[1].id)]
    let batch = DiagramEditBatch(documentID: document.id, expectedRevision: 0, edits: [.duplicatePage(document.pages[0].id)])
    let result = try DiagramEditEngine.applying(batch, to: document)
    #expect(result.pages.count == 4)
    let copy = result.pages[1]
    #expect(Set(copy.elements.map(\.id)).isDisjoint(with: Set(document.pages[0].elements.map(\.id))))
    #expect(copy.elements[0].links[0].pageID == copy.id)
    #expect(copy.elements[0].links[0].elementID == copy.elements[1].id)
    #expect(copy.elements[1].taskID != document.pages[0].elements[1].taskID)
    #expect(result.assets == document.assets)
}
@Test func selectionAndInheritedLocks() async throws {
    var document = DiagramExamples.library()
    let p = document.pages[0].id, root = document.pages[0].elements[0].id, branch = document.pages[0].elements[2].id
    var other = document.pages[0].elements[1]; other.title = "outside"
    let scope = DiagramEditContext(scope: .init(pageID: p, elementIDs: [branch]))
    await expectFailure { try DiagramEditEngine.applying(.init(documentID: document.id, expectedRevision: 0, edits: [.upsertElement(pageID: p, element: other)]), to: document, context: scope) }
    document.pages[0].elements[0].isLocked = true
    var child = document.pages[0].elements[2]; child.title = "locked"
    await expectFailure { try DiagramEditEngine.applying(.init(documentID: document.id, expectedRevision: 0, edits: [.upsertElement(pageID: p, element: child)]), to: document) }
    let unlock = try DiagramEditEngine.applying(.init(documentID: document.id, expectedRevision: 0, edits: [.setLocked(pageID: p, ids: [root], locked: false)]), to: document, context: .init(permitsUnlock: true))
    #expect(!unlock.pages[0].elements[0].isLocked)
    await expectFailure { try DiagramEditEngine.applying(.init(documentID: document.id, expectedRevision: 0, edits: [.setLocked(pageID: p, ids: [root], locked: false)]), to: document) }
}
@Test func lockedDescendantPreventsIndirectParentMovement() async throws {
    var document = DiagramExamples.library()
    for i in document.pages[0].elements.indices { document.pages[0].elements[i].frame = .init(x: Double(i * 50), y: 0) }
    document.pages[0].elements[5].isLocked = true
    let batch = DiagramEditBatch(documentID: document.id, expectedRevision: 0, edits: [.moveElements(pageID: document.pages[0].id, ids: [document.pages[0].elements[2].id], delta: .init(x: 20, y: 10), includeDescendants: true)])
    await expectFailure { try DiagramEditEngine.applying(batch, to: document) }
}
@Test func newSelectedChildAllowedButFloatingInsertionRejected() async throws {
    let document = DiagramExamples.library(), p = document.pages[0].id, parent = document.pages[0].elements[2].id
    let context = DiagramEditContext(scope: .init(pageID: p, elementIDs: [parent]))
    let child = DiagramElement(title: "new", parentID: parent)
    let result = try DiagramEditEngine.applying(.init(documentID: document.id, expectedRevision: 0, edits: [.upsertElement(pageID: p, element: child)]), to: document, context: context)
    #expect(result.element(child.id) != nil)
    await expectFailure { try DiagramEditEngine.applying(.init(documentID: document.id, expectedRevision: 0, edits: [.upsertElement(pageID: p, element: .init(kind: .floatingTopic, title: "outside"))]), to: document, context: context) }
}
@Test func hierarchyCyclesRejectedFlowCyclesAllowed() async throws {
    var document = DiagramExamples.library()
    let p = document.pages[0].id
    let cyclic = DiagramEditBatch(documentID: document.id, expectedRevision: 0, edits: [.reparent(pageID: p, id: document.pages[0].elements[0].id, parentID: document.pages[0].elements[2].id, order: 0)])
    await expectFailure { try DiagramEditEngine.applying(cyclic, to: document) }
    let a = document.pages[1].elements[3].id, b = document.pages[1].elements[4].id
    document.pages[1].connections += [.init(from: a, to: b, kind: .flow), .init(from: b, to: a, kind: .flow)]
    try document.validate()
    document.dependencies.append(.init(predecessorID: document.tasks[2].id, successorID: document.tasks[0].id))
    await expectFailure { try document.validate() }
}
@Test func inMemoryRevisionHistoryAndRequestIdempotency() async throws {
    let repository = InMemoryDiagramRepository(), document = DiagramExamples.library()
    try await repository.create(document)
    let batch = DiagramEditBatch(documentID: document.id, expectedRevision: 0, edits: [.rename("Changed")])
    let first = try await repository.commit(batch), retry = try await repository.commit(batch)
    #expect(first == retry)
    let undone = try await repository.undo(document.id, expectedRevision: 1)
    #expect(undone.title == document.title && undone.revision == 2)
    let retryAfterUndo = try await repository.commit(batch)
    #expect(retryAfterUndo.title == document.title && retryAfterUndo.revision == 2)
    let redone = try await repository.undo(document.id, expectedRevision: 2, redo: true)
    #expect(redone.title == "Changed" && redone.revision == 3)
    var reused = batch; reused.edits = [.rename("Different")]
    await expectFailure { try await repository.commit(reused) }
}
@Test func crossInstanceFileCASAndReopen() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let a = try FileDiagramRepository(directory: directory), b = try FileDiagramRepository(directory: directory)
    let document = DiagramExamples.library(); try await a.create(document)
    let batch = DiagramEditBatch(documentID: document.id, expectedRevision: 0, edits: [.rename("saved")])
    _ = try await a.commit(batch)
    await expectFailure { try await b.commit(.init(documentID: document.id, expectedRevision: 0, edits: [.rename("stale")])) }
    let reopened = try await b.load(document.id); #expect(reopened.title == "saved")
    let undo = try await b.undo(document.id, expectedRevision: 1); #expect(undo.revision == 2 && undo.title == document.title)
    let retry = try await a.commit(batch); #expect(retry.revision == 2)
    let history = try await a.history(document.id); #expect(history.canRedo)
}
@Test func simultaneousFileCASHasOneWinner() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let a = try FileDiagramRepository(directory: directory), b = try FileDiagramRepository(directory: directory), document = DiagramExamples.library()
    try await a.create(document)
    let batches = ["a", "b"].map { DiagramEditBatch(documentID: document.id, expectedRevision: 0, edits: [.rename($0)]) }
    let wins = await withTaskGroup(of: Bool.self) { group in
        group.addTask { do { _ = try await a.commit(batches[0]); return true } catch { return false } }
        group.addTask { do { _ = try await b.commit(batches[1]); return true } catch { return false } }
        var count = 0; for await success in group { if success { count += 1 } }; return count
    }
    #expect(wins == 1)
    let saved = try await a.load(document.id); #expect(saved.revision == 1)
}
@Test func failedSavePreservesOriginalAndCorruptionIsNotReplaced() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let document = DiagramDocument(title: "a"), normal = try FileDiagramRepository(directory: directory)
    try await normal.create(document)
    let record = directory.appendingPathComponent(document.id.uuidString + ".json"), before = try Data(contentsOf: record)
    let limited = try FileDiagramRepository(directory: directory, maximumRecordBytes: before.count + 20)
    await expectFailure { try await limited.commit(.init(documentID: document.id, expectedRevision: 0, edits: [.rename(String(repeating: "x", count: 10_000))])) }
    #expect(try Data(contentsOf: record) == before)
    try Data("broken".utf8).write(to: record)
    await expectFailure { try await normal.load(document.id) }
    #expect(try String(contentsOf: record, encoding: .utf8) == "broken")
}
@Test func sessionCannotRedirectOrPublishAfterClose() async throws {
    let repository = InMemoryDiagramRepository(), document = DiagramExamples.library()
    try await repository.create(document)
    let session = DiagramSession(documentID: document.id, repository: repository)
    await expectFailure { try await session.commit(.init(documentID: UUID(), expectedRevision: 0, edits: [.rename("bad")])) }
    await session.close()
    await expectFailure { try await session.snapshot() }
}
@Test func taskViewsShareDataAndScheduleIsExplicit() throws {
    var document = DiagramExamples.library()
    let parent = DiagramTask(title: "Summary")
    document.tasks.append(parent)
    document.tasks[0].parentID = parent.id; document.tasks[1].parentID = parent.id; document.tasks[2].parentID = parent.id
    let rollups = try DiagramPlanning.rollups(document)
    #expect(abs(rollups[parent.id]! - (1.6 / 3)) < 0.00001)
    let schedule = try DiagramPlanning.schedule(document, from: Date(timeIntervalSince1970: 1_793_577_600))
    #expect(schedule.count == document.tasks.count)
    #expect(schedule[document.tasks[1].id]!.start > schedule[document.tasks[0].id]!.end)
    #expect(document.revision == 0)
}
@Test func tenThousandNodesValidateAndIndexWithoutRecursiveStack() throws {
    let document = DiagramExamples.large()
    try document.validate()
    let index = DiagramPageIndex(document.pages[0])
    #expect(index.descendants(of: [document.pages[0].elements[0].id]).count == 10_000)
    let rich = DiagramExamples.large(count: 500, rich: true); try rich.validate()
    #expect(try DiagramCodec.decode(DiagramDocument.self, from: DiagramCodec.encode(rich)) == rich)
}
