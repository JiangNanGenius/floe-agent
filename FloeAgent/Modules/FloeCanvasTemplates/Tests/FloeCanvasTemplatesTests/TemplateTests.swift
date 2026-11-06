import Foundation
import Testing
import FloeCanvasCore
import FloeCanvasFlow
import FloeCanvasIntegration
@testable import FloeCanvasTemplates

@Suite("Canvas template predevelopment")
struct TemplateTests {
    func directory() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent(".test-data/" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func allPresetsCompileAndUseOneCanvasContract() throws {
        let all = BuiltInCanvasTemplates.all
        #expect(all.count == 12)
        #expect(all.filter { $0.category == .research }.count == 2)
        #expect(Set(all.map(\.id)).count == all.count)
        #expect(all.map(\.id) == BuiltInCanvasTemplates.all.map(\.id))
        for t in all {
            try CanvasTemplateEngine.validate(t)
            #expect(t.snapshot.pages.count == 1)
            #expect(t.snapshot.pages[0].nodes.allSatisfy { [.content, .generationTask].contains($0.kind) })
            for g in t.snapshot.pages[0].flowGraphs { _ = try FlowGraphCompiler.compile(g) }
        }
    }

    @Test func independentInstancesAndFilmReferencesRemap() throws {
        let template = BuiltInCanvasTemplates.all.first { $0.category == .film }!
        let a = try CanvasTemplateEngine.instantiate(template)
        let b = try CanvasTemplateEngine.instantiate(template)
        let aIDs = Set(a.snapshot.pages.flatMap(\.nodes).map(\.id))
        let bIDs = Set(b.snapshot.pages.flatMap(\.nodes).map(\.id))
        #expect(a.snapshot.id != b.snapshot.id)
        #expect(aIDs.isDisjoint(with: bIDs))
        #expect(Set(a.records.map(\.id)).isDisjoint(with: b.records.map(\.id)))
        for n in a.snapshot.pages[0].nodes {
            if let p = try CreativePurpose.read(n) {
                #expect(p.referenceNodeIDs.allSatisfy(aIDs.contains))
                if let id = p.recordID { #expect(a.records.contains { $0.id == id }) }
            }
        }
        #expect(a.missingRequiredInputs == ["brief"])
        let ready = try CanvasTemplateEngine.instantiate(template, inputs: ["brief": .text("Synthetic short film")])
        #expect(ready.missingRequiredInputs.isEmpty)
    }

    @Test func captureReplacesMutableEditorsAndPreservesReadOnlySourceVersion() throws {
        let editor = CanvasEditorReference(projectID: UUID(), appliedRevision: 4, editorKind: "music")
        let asset = CanvasAssetLocator(contentHash: "synthetic", relativePath: "audio.wav", mimeType: "audio/wav")
        let frame = CanvasGeometry.Frame(center: .zero, size: .init(width: 200, height: 120))
        let nodes = [CanvasNodeSnapshot(content: .editor(editor), frame: frame),
                     CanvasNodeSnapshot(content: .media(asset), frame: frame)]
        let snap = CanvasSnapshot(name: "Owned work", pages: [.init(nodes: nodes)])
        let t = try CanvasTemplateEngine.capture(snapshot: snap, title: .init("Mine", "我的"),
            category: .music, policy: .retainReadOnlySources)
        #expect(t.slots.count == 1)
        #expect(t.snapshot.pages[0].nodes[0].content == .text(""))
        #expect(t.snapshot.pages[0].nodes[1].content == .media(asset))
    }

    @Test func selectedWorkflowHasDeclaredBoundaryInputs() throws {
        let t = BuiltInCanvasTemplates.all[1]
        let card = t.snapshot.pages[0].nodes.first { $0.kind == .generationTask }!
        let captured = try CanvasTemplateEngine.capture(snapshot: t.snapshot,
            title: .init("Partial", "片段"), category: .image, selectedNodeIDs: [card.id])
        let graph = captured.snapshot.pages[0].flowGraphs[0]
        let compiled = try FlowGraphCompiler.compile(graph)
        #expect(graph.nodes.count == 1)
        #expect(!compiled.requiredInputs.isEmpty)
        #expect(captured.snapshot.pages[0].connections.isEmpty)
    }

    @Test func selectedSourceBecomesRequiredInputWithConsistentLocators() throws {
        var t = BuiltInCanvasTemplates.all[0]
        let page = t.snapshot.pages[0]
        let source = page.flowGraphs[0].nodes.first { $0.kind == .source }!
        var card = CanvasNodeSnapshot(content: .text("source"),
            frame: .init(center: .zero, size: .init(width: 200, height: 100)))
        CanvasFlowCardBinding(graphID: page.flowGraphs[0].id, nodeID: source.id).applied(to: &card.metadata)
        t.snapshot.pages[0].nodes.append(card)
        let selected = try CanvasTemplateEngine.capture(snapshot: t.snapshot, title: .init("Source", "来源"),
            category: .ideas, selectedNodeIDs: [card.id])
        let instance = try CanvasTemplateEngine.instantiate(selected)
        #expect(instance.missingRequiredInputs.count == 1)
        let copied = instance.snapshot.pages[0].flowGraphs[0].nodes[0]
        let id = instance.slots[0].nodeID
        #expect(copied.parameters["bindingKey"] == .string(CanvasTemplateEngine.sourcePrefix + id.uuidString))
        #expect(copied.parameters[CanvasFlowSourceParameterKey.nodeID] == .string(id.uuidString))
        var invalid = selected
        invalid.snapshot.pages[0].flowGraphs[0].nodes[0].parameters["bindingKey"] =
            .string(CanvasTemplateEngine.sourcePrefix + UUID().uuidString)
        #expect(throws: TemplateError.self) { try CanvasTemplateEngine.validate(invalid) }
    }

    @Test func realLibraryCASVersionsRestoreAndImportIsolation() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try CanvasTemplateLibrary(root: root), b = try CanvasTemplateLibrary(root: root)
        var t = try CanvasTemplateEngine.capture(snapshot: BuiltInCanvasTemplates.all[0].snapshot,
            title: .init("Personal", "个人"), category: .ideas)
        let initial = try await a.save(t, expectedRevision: nil)
        #expect(initial.revision == 1)
        t.version = 2; t.title.zh = "新版"
        _ = try await b.save(t, expectedRevision: 1)
        do {
            _ = try await a.save(t, expectedRevision: 1)
            Issue.record("stale save must fail")
        } catch let e as TemplateError {
            #expect(e == .conflict(expected: 1, actual: 2))
        }
        let restored = try await a.restoreVersion(id: t.id, version: 1, expectedRevision: 2)
        #expect(restored.latest.version == 3)
        #expect(restored.latest.title.zh == "个人")
        let fresh = try CanvasTemplateLibrary(root: root)
        #expect(try await fresh.load(id: t.id).versions.count == 3)
        let imported = try await fresh.importAsNew(CanvasTemplateEngine.encode(t))
        #expect(imported.latest.id != t.id)
        #expect(imported.latest.version == 1)
        _ = try await fresh.archive(id: t.id, expectedRevision: 3)
        #expect(try await fresh.list().count == 1)
        #expect(try await fresh.list(includeArchived: true).count == 2)
    }

    @Test func templateImportRejectsBrokenRelationsWithoutRunningAnything() throws {
        var t = BuiltInCanvasTemplates.all[0]
        t.snapshot.pages[0].connections.append(.init(sourceNodeID: UUID(), destinationNodeID: UUID()))
        #expect(throws: TemplateError.self) { try CanvasTemplateEngine.validate(t) }
    }

    @Test func oldCanvasSnapshotsDecodeAndDocumentMetadataUsesCASUndo() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = CanvasSnapshot(name: "Old", pages: [.init()])
        var raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as! [String: Any]
        raw.removeValue(forKey: "metadata")
        let old = try JSONDecoder().decode(CanvasSnapshot.self,
            from: JSONSerialization.data(withJSONObject: raw))
        #expect(old.metadata.isEmpty)
        let repo = try FileCanvasRepository(root: root)
        try await repo.create(canvasID: old.id, snapshot: old, requestID: UUID())
        _ = try await repo.commitDocument(.init(operations: [
            .updateCanvasMetadata(values: ["user": "preserved", "floe.template.state": "synthetic"], removingKeys: [])
        ]), canvasID: old.id, expectedRevision: 0, requestID: UUID())
        #expect(try await repo.load(canvasID: old.id).metadata["user"] == "preserved")
        _ = try await repo.undo(canvasID: old.id, expectedRevision: 1, requestID: UUID())
        #expect(try await repo.load(canvasID: old.id).metadata.isEmpty)
    }
}
