// FloeCoreTests — native `.floecad` Canvas node planning (drawing workbench).
import Foundation
import Testing
@testable import FloeCore

@Suite("CAD canvas node planner")
struct CADCanvasNodePlannerTests {

    private static let sourceHash = String(repeating: "a", count: 64)
    private static let renderHash = String(repeating: "b", count: 64)

    private func cadNode(
        id nodeID: UUID = UUID(),
        path: String = "Materials/abcd-plate.floecad",
        metadata: [String: String] = [:]
    ) -> CanvasNode {
        let asset = CanvasAssetReference(
            id: UUID(), contentHash: Self.sourceHash,
            localRelativePath: path, mimeType: "application/octet-stream",
            byteCount: 4096)
        return CanvasNode(
            id: nodeID, kind: .file, text: "Plate",
            position: .init(x: 10, y: 20), size: .init(width: 320, height: 260),
            asset: asset, metadata: metadata)
    }

    private func render() -> CanvasAssetReference {
        CanvasAssetReference(
            id: UUID(), contentHash: Self.renderHash,
            localRelativePath: "Materials/abcd-canvas-cad.png",
            mimeType: "image/png", byteCount: 2048)
    }

    @Test("apply replaces the asset and preserves identity, text, position, size and edges")
    func applyPreservesNodeIdentity() throws {
        let node = cadNode()
        let operation = try CADCanvasNodePlanner.applyPatch(
            liveNode: node,
            sourcePath: "floecad:plate.floecad",
            capturedSourceAssetHash: CADCanvasNodePlanner.capturedSourceHash(for: node),
            renderedAsset: render())
        #expect(operation.kind == .update)
        #expect(operation.nodeID == node.id)
        // No identity/text/position/size fields are emitted: the update never
        // rewrites them.
        #expect(operation.text == nil)
        #expect(operation.position == nil)
        #expect(operation.size == nil)
        #expect(operation.nodeKind == nil)
        #expect(operation.asset?.contentHash == Self.renderHash)
        let metadata = try #require(operation.metadata)
        #expect(metadata[CADCanvasNodePlanner.MetadataKeys.sourcePath] == "floecad:plate.floecad")
        #expect(metadata[CADCanvasNodePlanner.MetadataKeys.sourceHash] == Self.sourceHash)
        #expect(metadata["editor"] == "native-cad")
    }

    @Test("first apply lazily seeds the original package into the revision history")
    func firstApplySeedsHistory() throws {
        let node = cadNode()
        let operation = try CADCanvasNodePlanner.applyPatch(
            liveNode: node,
            sourcePath: "floecad:plate.floecad",
            capturedSourceAssetHash: Self.sourceHash,
            renderedAsset: render())
        let raw = try #require(operation.metadata?[CanvasDrawingRevisionHistory.metadataKey])
        let revisions = try JSONDecoder().decode([CanvasDrawingRevision].self, from: Data(raw.utf8))
        #expect(revisions.count == 2)
        #expect(revisions.first?.kind == .original)
        #expect(revisions.first?.contentHash == Self.sourceHash)
        #expect(revisions.last?.kind == .adopt)
        #expect(revisions.last?.contentHash == Self.renderHash)
    }

    @Test("re-apply matches the recorded source identity, not the live render hash")
    func reapplyMatchesRecordedIdentity() throws {
        var node = cadNode(metadata: [
            CADCanvasNodePlanner.MetadataKeys.sourceHash: Self.sourceHash,
            CADCanvasNodePlanner.MetadataKeys.sourcePath: "floecad:plate.floecad",
        ])
        // After the first apply the live asset is the PNG render.
        node.asset = CanvasAssetReference(
            id: UUID(), contentHash: Self.renderHash,
            localRelativePath: "Materials/first-canvas-cad.png",
            mimeType: "image/png", byteCount: 100)
        let operation = try CADCanvasNodePlanner.applyPatch(
            liveNode: node,
            sourcePath: "floecad:plate.floecad",
            capturedSourceAssetHash: CADCanvasNodePlanner.capturedSourceHash(for: node),
            renderedAsset: render())
        #expect(operation.nodeID == node.id)
        #expect(operation.metadata?[CADCanvasNodePlanner.MetadataKeys.sourceHash] == Self.sourceHash)
    }

    @Test("an externally changed node is refused instead of overwritten")
    func changedNodeIsRefused() throws {
        let node = cadNode()
        #expect(throws: CADCanvasNodePlanner.Refusal.self) {
            _ = try CADCanvasNodePlanner.applyPatch(
                liveNode: node,
                sourcePath: "floecad:plate.floecad",
                capturedSourceAssetHash: String(repeating: "c", count: 64),
                renderedAsset: render())
        }
    }

    @Test("unsupported raw history is preserved, never overwritten")
    func unsupportedHistoryIsPreserved() throws {
        var node = cadNode(metadata: [
            CanvasDrawingRevisionHistory.metadataKey: "[{\"future\":true}]",
        ])
        node.metadata[CADCanvasNodePlanner.MetadataKeys.sourcePath] = "floecad:plate.floecad"
        let operation = try CADCanvasNodePlanner.applyPatch(
            liveNode: node,
            sourcePath: "floecad:plate.floecad",
            capturedSourceAssetHash: CADCanvasNodePlanner.capturedSourceHash(for: node),
            renderedAsset: render())
        // The patch still applies the asset but does NOT touch the raw key.
        #expect(operation.metadata?[CanvasDrawingRevisionHistory.metadataKey] == nil)
        #expect(operation.metadata?[CADCanvasNodePlanner.MetadataKeys.sourceHash] == Self.sourceHash)
    }

    @Test("variant creates a new file node plus one generatedFrom edge")
    func variantCreatesNodeAndEdge() throws {
        let source = cadNode()
        let (newID, operations) = try CADCanvasNodePlanner.variantPatch(
            sourceNodeID: source.id,
            sourcePath: "floecad:plate.floecad",
            capturedSourceAssetHash: Self.sourceHash,
            renderedAsset: render(),
            position: CanvasPoint(x: 430, y: 20),
            size: source.size,
            text: "Plate")
        #expect(operations.count == 2)
        #expect(operations[0].kind == .create)
        #expect(operations[0].nodeID == newID)
        #expect(operations[0].nodeKind == .file)
        #expect(operations[1].kind == .connect)
        #expect(operations[1].sourceNodeID == source.id)
        #expect(operations[1].destinationNodeID == newID)
        #expect(operations[1].connectionKind == .generatedFrom)
        let raw = try #require(operations[0].metadata?[CanvasDrawingRevisionHistory.metadataKey])
        let revisions = try JSONDecoder().decode([CanvasDrawingRevision].self, from: Data(raw.utf8))
        #expect(revisions.count == 1)
        #expect(revisions.first?.kind == .variant)
        #expect(operations[0].metadata?["derivedFromNodeID"] == source.id.uuidString)
    }

    @Test("a variant list validates and its assets stay reachable")
    func variantHistoryIsReachable() throws {
        let source = cadNode()
        let (_, operations) = try CADCanvasNodePlanner.variantPatch(
            sourceNodeID: source.id,
            sourcePath: "floecad:plate.floecad",
            capturedSourceAssetHash: Self.sourceHash,
            renderedAsset: render(),
            position: CanvasPoint(x: 430, y: 20),
            size: source.size)
        let create = operations[0]
        let node = CanvasNode(
            id: try #require(create.nodeID), kind: .file,
            position: .init(x: 430, y: 20), size: .init(width: 320, height: 260),
            asset: create.asset, metadata: create.metadata ?? [:])
        let document = CanvasDocument(name: "D", nodes: [node])
        let project = CanvasProject(
            id: UUID(), name: "P", documents: [document],
            selectedDocumentID: document.id)
        #expect(CanvasDrawingRevisionHistory.hasUsableHistory(on: node))
        try CanvasDrawingRevisionHistory.requireClosableHistory(in: project)
        #expect(CanvasDrawingRevisionHistory.reachableAssetReferences(in: project)
            .contains(try #require(create.asset?.id)))
    }
}
