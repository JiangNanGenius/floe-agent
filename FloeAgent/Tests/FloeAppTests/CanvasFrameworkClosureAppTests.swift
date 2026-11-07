// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import XCTest
import FloeCore
import FloeCanvasCore
import FloeCanvasIntegration
import FloeCanvasUI
@testable import FloeApp

private actor CanvasReferenceProbe: CanvasEditorGateway, CanvasSourceOpening {
    var opened: [CanvasEditorReference] = []
    var sources: [UUID] = []
    func openEditor(_ reference: CanvasEditorReference, context: CanvasRuntimeContext) async throws { opened.append(reference) }
    func applyEditorResult(_ reference: CanvasEditorReference, context: CanvasRuntimeContext) async throws -> CanvasEditorReference {
        var result = reference; result.appliedRevision += 1; return result
    }
    func openSource(sourceID: UUID, fragment: String?) async throws { sources.append(sourceID) }
    func counts() -> (Int, Int) { (opened.count, sources.count) }
}

@MainActor final class CanvasFrameworkClosureAppTests: XCTestCase {
    func testPrimaryReferenceActionsOpenExactServicesAndPersistChildReturnWithLockFence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-reference-actions-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let editor = CanvasEditorReference(projectID: UUID(), appliedRevision: 4, editorKind: "cad3D")
        let node = CanvasNodeSnapshot(content: .editor(editor), frame: .init(center: .zero, size: .init(width: 300, height: 200)))
        let sourceID = UUID()
        let source = CanvasNodeSnapshot(content: .text("Quoted original"), frame: .init(center: .init(x: 400, y: 0), size: .init(width: 300, height: 200)),
            isLocked: true, source: .init(sourceID: sourceID, fragment: "page:2", usedRevision: 8))
        let page = CanvasPageSnapshot(nodes: [node, source])
        let snapshot = CanvasSnapshot(name: "References", pages: [page])
        let repo = try FileCanvasRepository(root: root)
        try await repo.create(canvasID: snapshot.id, snapshot: snapshot, requestID: UUID())
        let probe = CanvasReferenceProbe()
        let store = CanvasEditorStore(canvasID: snapshot.id, services: .init(documentStore: repo, sourceOpening: probe, editorGateway: probe))
        await store.load()
        _ = try await CanvasFrameworkReferenceActions.perform(.openEditor, store: store,
            canvasID: snapshot.id, pageID: page.id, nodeID: node.id, revision: 0, isCurrent: { true })
        _ = try await CanvasFrameworkReferenceActions.perform(.openSource, store: store,
            canvasID: snapshot.id, pageID: page.id, nodeID: source.id, revision: 0, isCurrent: { true })
        let counts = await probe.counts()
        XCTAssertEqual(counts.0, 1); XCTAssertEqual(counts.1, 1)
        let receipt = try await CanvasFrameworkReferenceActions.perform(.applyEditor, store: store,
            canvasID: snapshot.id, pageID: page.id, nodeID: node.id, revision: 0, isCurrent: { true })
        XCTAssertEqual(receipt?.revision, 1)
        let reopened = try FileCanvasRepository(root: root)
        let saved = try await reopened.load(canvasID: snapshot.id)
        guard case .editor(let applied) = saved.pages[0].nodes.first(where: { $0.id == node.id })?.content else { return XCTFail("Missing editor reference") }
        XCTAssertEqual(applied.projectID, editor.projectID); XCTAssertEqual(applied.appliedRevision, 5)
        _ = try await repo.commit(.init(pageID: page.id, operations: [.setLocked(nodeID: node.id, isLocked: true)]),
            canvasID: snapshot.id, expectedRevision: 1, requestID: UUID())
        do {
            _ = try await CanvasFrameworkReferenceActions.perform(.openEditor, store: store,
                canvasID: snapshot.id, pageID: page.id, nodeID: node.id, revision: 2, isCurrent: { true })
            XCTFail("Locked node opened for editing")
        } catch {}
        let afterLock = await probe.counts(); XCTAssertEqual(afterLock.0, 1)
        do {
            _ = try await CanvasFrameworkReferenceActions.perform(.openSource, store: store,
                canvasID: snapshot.id, pageID: page.id, nodeID: source.id, revision: 2, isCurrent: { false })
            XCTFail("Cancelled owner opened a source")
        } catch is CancellationError {} catch { XCTFail("Expected owner cancellation: \(error)") }
    }

    func testFlowPortsFollowOldCardGeometryAndConnectionsPersistUndo() async throws {
        let output = FlowPort(name: "out", dataType: .string, direction: .output)
        let input = FlowPort(name: "in", dataType: .string, direction: .input)
        let source = FlowNode(kind: .source, name: "Input", ports: [output], position: .zero)
        let sink = FlowNode(kind: .output, name: "Output", ports: [input], position: .init(x: 600, y: 0))
        let graph = FlowGraph(nodes: [source, sink])
        var metadata: [String: String] = [:]
        CanvasFlowCardBinding(graphID: graph.id, nodeID: source.id).applied(to: &metadata)
        let card = CanvasNodeSnapshot(content: .text("Input"), frame: .init(center: .zero, size: .init(width: 200, height: 100)), metadata: metadata)
        let page = CanvasPageSnapshot(nodes: [card], flowGraphs: [graph])
        let snapshot = CanvasSnapshot(name: "Ports", pages: [page])
        let record = PersonalContentRecord(id: snapshot.id, kind: .canvas, title: snapshot.name,
            createdAt: snapshot.createdAt, modifiedAt: snapshot.updatedAt, folders: [], relativePath: "Ports.floeproject")
        var visible = try CanvasFrameworkProjection.project(snapshot, record: record).documents[0]
        visible.nodes[0].position = .init(x: 80, y: 30)
        let scene = CanvasFrameworkFlowPresentation.make(snapshot: snapshot, document: visible)
        let port = try XCTUnwrap(scene.ports.first { $0.value.id == output.id })
        XCTAssertEqual(port.point.x, 180); XCTAssertEqual(port.point.y, 30)
        XCTAssertEqual(port.canvasNodeID, card.id)
        XCTAssertEqual(scene.unboundNodes.count, 1)
        let batch = try CanvasFlowGraphEditing.connectPortsBatch(snapshot: snapshot, pageID: page.id,
            sourceNodeID: source.id, sourcePortID: output.id, destinationNodeID: sink.id, destinationPortID: input.id)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-flow-links-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try FileCanvasRepository(root: root)
        try await repo.create(canvasID: snapshot.id, snapshot: snapshot, requestID: UUID())
        let receipt = try await repo.commitDocument(batch, canvasID: snapshot.id, expectedRevision: 0, requestID: UUID())
        let reopened = try FileCanvasRepository(root: root)
        let saved = try await reopened.load(canvasID: snapshot.id)
        XCTAssertEqual(saved.pages[0].flowGraphs[0].edges.count, 1)
        let rendered = CanvasFrameworkFlowPresentation.make(snapshot: saved, document: visible)
        XCTAssertEqual(rendered.edges.count, 1)
        XCTAssertEqual(rendered.edges.first?.value.sourcePortID, output.id)
        _ = try reopened.undoSynchronously(canvasID: snapshot.id, expectedRevision: receipt.revision, requestID: UUID())
        let undone = try await repo.load(canvasID: snapshot.id)
        XCTAssertTrue(undone.pages[0].flowGraphs[0].edges.isEmpty)
    }

    func testCopyForksCompletePayloadAndNeverAdoptsOriginalReceiptsOrMutableChild() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-native-copy-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let page = FloeCore.CanvasDocument(name: "Original", nodes: [.init(kind: .stickyNote, text: "Kept body", position: .init(x: 0, y: 0), size: .init(width: 300, height: 200))])
        let project = FloeCore.CanvasProject(id: UUID(), name: "Original", documents: [page], selectedDocumentID: page.id)
        let url = root.appendingPathComponent("Original.json")
        _ = try CanvasProjectFileWriter.shared.compareAndSwap(project, at: url, expectedRevision: 0,
            requireRevisionAdvance: false, allowCreateIfMissing: true)
        let record = PersonalContentRecord(id: project.id, kind: .canvas, title: project.name,
            createdAt: project.createdAt, modifiedAt: project.updatedAt, folders: [], relativePath: "Original.floeproject")
        let repo = CanvasFrameworkLegacyRepository(record: record, originalURL: url, root: root)
        let graph = FlowGraph(nodes: [.init(kind: .source, name: "Input")])
        let child = CanvasNodeSnapshot(content: .editor(.init(projectID: UUID(), appliedRevision: 3, editorKind: "cad3D")),
            frame: .init(center: .init(x: 400, y: 0), size: .init(width: 300, height: 200)))
        _ = try await repo.commitDocument(.init(operations: [.insertFlowGraph(pageID: page.id, graph: graph),
            .editPage(.init(pageID: page.id, operations: [.insertNode(child)]))]), canvasID: project.id, expectedRevision: 0, requestID: UUID())
        let original = try CanvasProjectFileWriter.shared.project(canvasID: project.id, at: url)
        let copyID = UUID()
        let copied = try CanvasFrameworkLegacyRepository.forkProject(original, newID: copyID, workspaceID: nil, name: "Copy")
        let copyURL = root.appendingPathComponent("Copy.json")
        _ = try CanvasProjectFileWriter.shared.compareAndSwap(copied, at: copyURL, expectedRevision: 0, requireRevisionAdvance: false, allowCreateIfMissing: true)
        var copyRecord = record; copyRecord.id = copyID
        let copyRepo = CanvasFrameworkLegacyRepository(record: copyRecord, originalURL: copyURL, root: root)
        let snapshot = try await copyRepo.load(canvasID: copyID)
        XCTAssertEqual(snapshot.id, copyID); XCTAssertEqual(snapshot.revision, 0)
        XCTAssertNotEqual(snapshot.pages[0].id, page.id)
        XCTAssertNotEqual(snapshot.pages[0].flowGraphs[0].id, graph.id)
        let copiedChild = try XCTUnwrap(snapshot.pages[0].nodes.first { if case .editor = $0.content { return true }; return false })
        XCTAssertEqual(copiedChild.metadata[CanvasFrameworkLegacyRepository.pendingEditorForkKey], "true")
        XCTAssertEqual(try copyRepo.historyAvailabilitySynchronously(canvasID: copyID), .init(undoCount: 0, redoCount: 0))
        let originalAfter = try CanvasProjectFileWriter.shared.project(canvasID: project.id, at: url)
        XCTAssertEqual(originalAfter, original)
        XCTAssertNotNil(copied.canvasKitState)
        let probe = CanvasReferenceProbe()
        let store = CanvasEditorStore(canvasID: copyID, services: .init(documentStore: copyRepo, editorGateway: probe))
        await store.load()
        do {
            _ = try await CanvasFrameworkReferenceActions.perform(.openEditor, store: store, canvasID: copyID,
                pageID: snapshot.pages[0].id, nodeID: copiedChild.id, revision: 0, isCurrent: { true })
            XCTFail("A copy opened the original mutable child")
        } catch {}
        let counts = await probe.counts(); XCTAssertEqual(counts.0, 0)
    }
}
#endif
