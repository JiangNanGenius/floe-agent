// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import XCTest
import FloeCore
import FloeCanvasCore
import FloeCanvasIntegration
@testable import FloeApp

@MainActor final class CanvasFrameworkProjectionAppTests: XCTestCase {
    func testOriginalFrameworkEditsPreserveRichTextFlowAndSourceAcrossUndoAndReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-framework-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rich = CanvasRichTextDocument(runs: [.init(text: "ABC", bold: true), .init(text: "XYZ", italic: true)])
        let source = CanvasSourceReference(sourceID: UUID(), fragment: "page:2", usedRevision: 7)
        let node = CanvasNodeSnapshot(content: .richText(document: rich),
            frame: .init(center: .zero, size: .init(width: 300, height: 200)), source: source)
        let editor = CanvasNodeSnapshot(content: .editor(.init(projectID: UUID(), appliedRevision: 12, editorKind: "cad3D")),
            frame: .init(center: .init(x: 400, y: 0), size: .init(width: 300, height: 200)))
        let graph = FlowGraph(nodes: [.init(kind: .source, name: "Input")])
        let page = CanvasPageSnapshot(nodes: [node, editor], flowGraphs: [graph])
        let snapshot = CanvasSnapshot(name: "Original", pages: [page], metadata: ["retained": "original"])
        let record = PersonalContentRecord(id: snapshot.id, kind: .canvas, title: snapshot.name,
            createdAt: snapshot.createdAt, modifiedAt: snapshot.updatedAt, folders: [], relativePath: "Original.floeproject")
        let repository = try FileCanvasRepository(root: root.appendingPathComponent("Canvas"))
        try await repository.create(canvasID: snapshot.id, snapshot: snapshot, requestID: UUID())
        let backing = try CanvasFrameworkBacking(record: record, directory: root, repository: repository)
        var project = try backing.load()
        project.documents[0].nodes[0].text = "AB🙂CXYZ"
        project.documents[0].nodes[0].position = .init(x: 20, y: 40)
        _ = try backing.commit(project, expectedRevision: 0)
        let reopened = try FileCanvasRepository(root: root.appendingPathComponent("Canvas"))
        let edited = try await reopened.load(canvasID: snapshot.id)
        let editedNode = try XCTUnwrap(edited.pages[0].nodes.first { $0.id == node.id })
        XCTAssertEqual(edited.pages[0].flowGraphs, [graph])
        XCTAssertEqual(editedNode.source, source)
        XCTAssertEqual(edited.pages[0].nodes.first { $0.id == editor.id }, editor)
        XCTAssertEqual(edited.metadata["retained"], "original")
        guard case .richText(let result) = editedNode.content else { return XCTFail("Rich text was flattened") }
        XCTAssertEqual(result.plainText, "AB🙂CXYZ")
        XCTAssertTrue(result.runs.filter { !$0.text.isEmpty && !$0.italic }.allSatisfy(\.bold))
        XCTAssertEqual(result.runs.last, rich.runs.last)
        _ = try backing.undo(expectedRevision: edited.revision)
        let afterUndo = try await reopened.load(canvasID: snapshot.id)
        XCTAssertEqual(afterUndo.pages[0].nodes.first { $0.id == node.id }?.content, node.content)
        _ = try await reopened.redo(canvasID: snapshot.id, expectedRevision: afterUndo.revision, requestID: UUID())
        XCTAssertEqual(try backing.load().documents[0].nodes.first { $0.id == node.id }?.text, "AB🙂CXYZ")
    }

    func testAnAICommitFencesStaleGestureAndRetainsCompleteRecoveryDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-framework-fence-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let node = CanvasNodeSnapshot(content: .text("Original"), frame: .init(center: .zero, size: .init(width: 300, height: 200)))
        let page = CanvasPageSnapshot(nodes: [node])
        let snapshot = CanvasSnapshot(name: "Fenced", pages: [page])
        let record = PersonalContentRecord(id: snapshot.id, kind: .canvas, title: snapshot.name,
            createdAt: snapshot.createdAt, modifiedAt: snapshot.updatedAt, folders: [], relativePath: "Fenced.floeproject")
        let repository = try FileCanvasRepository(root: root.appendingPathComponent("Canvas"))
        try await repository.create(canvasID: snapshot.id, snapshot: snapshot, requestID: UUID())
        let backing = try CanvasFrameworkBacking(record: record, directory: root, repository: repository)
        var gesture = try backing.load()
        gesture.documents[0].nodes[0].text = "Gesture draft"
        _ = try await repository.commit(.init(pageID: page.id, operations: [.updateContent(nodeID: node.id, content: .text("AI saved"))]),
            canvasID: snapshot.id, expectedRevision: 0, requestID: UUID())
        XCTAssertThrowsError(try backing.commit(gesture, expectedRevision: 0))
        let saved = try await repository.load(canvasID: snapshot.id)
        XCTAssertEqual(saved.pages[0].nodes[0].content, .text("AI saved"))
        let drafts = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Recovery"), includingPropertiesForKeys: nil)
        XCTAssertEqual(drafts.count, 1)
        let recovered = try JSONDecoder().decode(FloeCore.CanvasProject.self, from: Data(contentsOf: drafts[0]))
        XCTAssertEqual(recovered.documents[0].nodes[0].text, "Gesture draft")
    }

    func testLegacyOriginalCarriesCompleteFlowAndSurvivesExistingWriterEdit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-legacy-payload-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let node = FloeCore.CanvasNode(kind: .stickyNote, text: "Original body", position: .init(x: 10, y: 20),
            size: .init(width: 300, height: 200), metadata: ["original": "retained"])
        let page = FloeCore.CanvasDocument(name: "Original page", nodes: [node])
        let project = FloeCore.CanvasProject(id: UUID(), name: "Original project", documents: [page], selectedDocumentID: page.id)
        let originalURL = root.appendingPathComponent("Original.json")
        _ = try CanvasProjectFileWriter.shared.compareAndSwap(project, at: originalURL,
            expectedRevision: 0, requireRevisionAdvance: false, allowCreateIfMissing: true)
        let record = PersonalContentRecord(id: project.id, kind: .canvas, title: project.name,
            createdAt: project.createdAt, modifiedAt: project.updatedAt, folders: [], relativePath: "Original.floeproject")
        let repository = CanvasFrameworkLegacyRepository(record: record, originalURL: originalURL, root: root.appendingPathComponent("Extensions"))
        let graph = FlowGraph(nodes: [.init(kind: .source, name: "Input")])
        _ = try await repository.commitDocument(.init(operations: [.insertFlowGraph(pageID: page.id, graph: graph)]),
            canvasID: project.id, expectedRevision: 0, requestID: UUID())
        var existingWriterProject = try CanvasProjectFileWriter.shared.project(canvasID: project.id, at: originalURL)
        XCTAssertNotNil(existingWriterProject.canvasKitState)
        XCTAssertEqual(existingWriterProject.documents[0].nodes[0].kind, .stickyNote)
        existingWriterProject.documents[0].nodes[0].text = "Existing writer changed body"
        existingWriterProject.revision += 1
        _ = try CanvasProjectFileWriter.shared.compareAndSwap(existingWriterProject, at: originalURL, expectedRevision: 1)
        let reopened = CanvasFrameworkLegacyRepository(record: record, originalURL: originalURL, root: repository.root)
        let snapshot = try await reopened.load(canvasID: project.id)
        XCTAssertEqual(snapshot.revision, 2)
        XCTAssertEqual(snapshot.pages[0].flowGraphs, [graph])
        let projected = try CanvasFrameworkProjection.project(snapshot, record: record)
        XCTAssertEqual(projected.documents[0].nodes[0].text, "Existing writer changed body")
        XCTAssertEqual(projected.documents[0].nodes[0].kind, .stickyNote)
        XCTAssertEqual(projected.documents[0].nodes[0].metadata["original"], "retained")
        let next = try await reopened.commitDocument(.init(operations: [.renamePage(pageID: page.id, name: "Renamed")]),
            canvasID: project.id, expectedRevision: 2, requestID: UUID())
        _ = try await reopened.undo(canvasID: project.id, expectedRevision: next.revision, requestID: UUID())
        let restored = try CanvasProjectFileWriter.shared.project(canvasID: project.id, at: originalURL)
        XCTAssertEqual(restored.documents[0].name, page.name)
        XCTAssertEqual(restored.documents[0].nodes[0].text, "Existing writer changed body")
        XCTAssertNotNil(restored.canvasKitState)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.count, 1)
    }

    func testAITextEditsKeepFrameworkKindAssetsAndScenePayload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-ai-payload-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let frame = FloeCore.CanvasSize(width: 300, height: 200)
        let card = FloeCore.CanvasNode(kind: .stickyNote, text: "Card", position: .init(x: 0, y: 0), size: frame,
            metadata: ["original": "card"])
        let media = FloeCore.CanvasNode(kind: .image, text: "Image caption", position: .init(x: 400, y: 0), size: frame,
            asset: .init(contentHash: "original-hash", localRelativePath: "Materials/original.png", mimeType: "image/png", byteCount: 123),
            metadata: ["original": "image"])
        let scene = FloeCore.CanvasNode(kind: .scene3D, text: "Scene caption", position: .init(x: 800, y: 0), size: frame,
            scene3D: .init(objects: []), metadata: ["original": "scene"])
        let page = FloeCore.CanvasDocument(name: "Native", nodes: [card, media, scene])
        let project = FloeCore.CanvasProject(id: UUID(), name: "Native", documents: [page], selectedDocumentID: page.id)
        let snapshot = try CanvasFrameworkProjection.snapshot(project)
        let record = PersonalContentRecord(id: project.id, kind: .canvas, title: project.name,
            createdAt: project.createdAt, modifiedAt: project.updatedAt, folders: [], relativePath: "Native.floeproject")
        let repository = try FileCanvasRepository(root: root.appendingPathComponent("Canvas"))
        try await repository.create(canvasID: project.id, snapshot: snapshot, requestID: UUID())
        let batch = CanvasEditBatch(pageID: page.id, operations: page.nodes.map { .updateContent(nodeID: $0.id, content: .text("AI " + $0.text)) })
        let requestID = UUID()
        let receipt = try await CanvasHostServices.edit(record: record, directory: root, batch: batch, expectedRevision: 0, requestID: requestID)
        let replay = try await CanvasHostServices.edit(record: record, directory: root, batch: batch, expectedRevision: 0, requestID: requestID)
        XCTAssertEqual(replay, receipt)
        let saved = try await repository.load(canvasID: project.id)
        let result = try CanvasFrameworkProjection.project(saved, record: record)
        for old in page.nodes {
            let new = try XCTUnwrap(result.documents[0].nodes.first { $0.id == old.id })
            XCTAssertEqual(new.kind, old.kind)
            XCTAssertEqual(new.asset, old.asset)
            XCTAssertEqual(new.scene3D, old.scene3D)
            XCTAssertEqual(new.metadata, old.metadata)
            XCTAssertEqual(new.text, "AI " + old.text)
        }
    }

    func testNativeCanvasTextInsertionAndBodyCommitUseOriginalStoreAndHistory() async throws {
        try await exerciseTextInsertion(legacy: false)
    }

    func testLegacyCanvasTextInsertionAndBodyCommitUseOriginalStoreAndHistory() async throws {
        try await exerciseTextInsertion(legacy: true)
    }

    private func exerciseTextInsertion(legacy: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-insert-body-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = FloeCore.CanvasNode(kind: .stickyNote, text: "Keep this note",
            position: .init(x: 10, y: 20), size: .init(width: 260, height: 180),
            metadata: ["retained": "exact"])
        let page = FloeCore.CanvasDocument(name: "Original", nodes: [existing])
        let original = FloeCore.CanvasProject(id: UUID(), name: "Insert body", documents: [page], selectedDocumentID: page.id)
        let record = PersonalContentRecord(id: original.id, kind: .canvas, title: original.name,
            createdAt: original.createdAt, modifiedAt: original.updatedAt, folders: [], relativePath: "Original.floeproject")
        let repository: any CanvasFrameworkRepository
        if legacy {
            let url = root.appendingPathComponent("Original.json")
            _ = try CanvasProjectFileWriter.shared.compareAndSwap(original, at: url, expectedRevision: 0,
                requireRevisionAdvance: false, allowCreateIfMissing: true)
            repository = CanvasFrameworkLegacyRepository(record: record, originalURL: url, root: root.appendingPathComponent("Extensions"))
        } else {
            let native = try FileCanvasRepository(root: root.appendingPathComponent("Canvas"))
            try await native.create(canvasID: original.id, snapshot: CanvasFrameworkProjection.snapshot(original), requestID: UUID())
            repository = native
        }
        let backing = try CanvasFrameworkBacking(record: record, directory: root, repository: repository)
        let store = WorkspaceCanvasStoreQualification(backing: backing, project: try backing.load())
        // The bottom-menu route invokes addNote synchronously, then uses the
        // returned identity as selection/editingNodeID. That exact ID must
        // already identify an editable, finite-sized node after file CAS.
        let id = store.addNote(at: CGPoint(x: 440, y: 310))
        XCTAssertNil(store.saveError)
        XCTAssertEqual(store.project.selectedDocumentID, page.id)
        let inserted = try XCTUnwrap(store.selectedDocument?.nodes.first { $0.id == id })
        XCTAssertEqual(inserted.kind, .text)
        XCTAssertTrue(inserted.width.isFinite && inserted.width > 0)
        XCTAssertTrue(inserted.height.isFinite && inserted.height > 0)
        XCTAssertEqual(inserted.position, .init(x: 440, y: 310))
        XCTAssertEqual(store.selectedDocument?.nodes.first { $0.id == existing.id }, existing)
        XCTAssertEqual(try backing.load().documents[0].nodes.first { $0.id == id }, inserted)

        // CanvasNodeCard's body Binding commits through this real store API.
        let edited = inserted.text + "\n正文可以输入。"
        store.updateNode(id, text: edited)
        XCTAssertNil(store.saveError)
        let reopenedBacking = try CanvasFrameworkBacking(record: record, directory: root, repository: repository)
        let reopened = WorkspaceCanvasStoreQualification(backing: reopenedBacking, project: try reopenedBacking.load())
        XCTAssertEqual(reopened.selectedDocument?.nodes.first { $0.id == id }?.text, edited)
        XCTAssertEqual(reopened.selectedDocument?.nodes.first { $0.id == existing.id }, existing)
        XCTAssertTrue(reopened.canUndo)
        reopened.undo()
        XCTAssertNil(reopened.saveError)
        XCTAssertEqual(reopened.selectedDocument?.nodes.first { $0.id == id }?.text, inserted.text)
        reopened.undo()
        XCTAssertNil(reopened.saveError)
        XCTAssertNil(reopened.selectedDocument?.nodes.first { $0.id == id })
        XCTAssertEqual(reopened.selectedDocument?.nodes, [existing])
        reopened.redo()
        reopened.redo()
        XCTAssertNil(reopened.saveError)
        XCTAssertEqual(try reopenedBacking.load().documents[0].nodes.first { $0.id == id }?.text, edited)
    }

    func testClippedTextBodyIsRevealedInsideTheKeyboardReducedViewport() throws {
        // UI04 leaves about 149pt of canvas above the system input area. The
        // default text card's actual native input is 240x130 after its padding.
        let viewport = CGSize(width: 883, height: 149)
        let oldPan = CGSize(width: 0, height: -329)
        let body = CGRect(x: 321.5, y: -65, width: 240, height: 130)
        let pan = try XCTUnwrap(CanvasInlineEditingViewport.revealing(body, in: viewport, currentPan: oldPan))
        let visibleBody = body.offsetBy(dx: pan.width - oldPan.width, dy: pan.height - oldPan.height)
        XCTAssertGreaterThanOrEqual(visibleBody.minY, 8)
        XCTAssertLessThanOrEqual(visibleBody.maxY, viewport.height - 8)
        XCTAssertGreaterThanOrEqual(visibleBody.minX, 8)
        XCTAssertLessThanOrEqual(visibleBody.maxX, viewport.width - 8)
        XCTAssertEqual(pan.width, oldPan.width)
    }

    func testZeroOrNonfiniteViewportCannotReplaceTheLastValidCameraSample() throws {
        let last = CGSize(width: 883, height: 658), originalPan = CGSize.zero
        for transient in [CGSize(width: 883, height: 0), CGSize(width: CGFloat.nan, height: 149), CGSize(width: 883, height: CGFloat.infinity)] {
            XCTAssertNil(CanvasInlineEditingViewport.recenteredPan(from: last, to: transient, currentPan: originalPan))
        }
        // A subsequent valid keyboard viewport uses the retained real sample,
        // rather than a transient zero that would strand the node at the top.
        let resumed = try XCTUnwrap(CanvasInlineEditingViewport.recenteredPan(
            from: last, to: .init(width: 883, height: 149), currentPan: originalPan))
        XCTAssertEqual(resumed.width, 0)
        XCTAssertEqual(resumed.height, -254.5)
        XCTAssertEqual(329 + resumed.height, 149 / 2.0)
    }

    func testAlreadyVisibleInlineBodyDoesNotMoveAgainOnFocus() throws {
        let pan = CGSize(width: -30, height: 15)
        let body = CGRect(x: 200, y: 100, width: 240, height: 130)
        XCTAssertEqual(CanvasInlineEditingViewport.revealing(body, in: .init(width: 883, height: 600), currentPan: pan), pan)
        XCTAssertNil(CanvasInlineEditingViewport.revealing(.zero, in: .init(width: 883, height: 149), currentPan: pan))
    }

    func testOversizedInlineBodyKeepsItsBeginningVisibleWithoutChangingItsSize() throws {
        let body = CGRect(x: -500, y: -1000, width: 800, height: 1300)
        let viewport = CGSize(width: 260, height: 120)
        let pan = try XCTUnwrap(CanvasInlineEditingViewport.revealing(body, in: viewport, currentPan: .zero))
        let visibleBeginning = body.offsetBy(dx: pan.width, dy: pan.height)
        XCTAssertEqual(visibleBeginning.origin, CGPoint(x: 8, y: 8))
        XCTAssertEqual(visibleBeginning.size, body.size)
        // This intentionally does not claim the entire oversized editor fits.
    }

}
#endif
