// FloeCoreTests — copied-node child-project fork lifecycle (Build265 review).
import Foundation
import Testing
@testable import FloeCore

@Suite("Canvas copied-node fork lifecycle")
struct CanvasCopyForkPlannerTests {
    private func boundImageNode(projectID: UUID = UUID()) -> CanvasNode {
        var node = CanvasNode.placeholder(kind: .image, position: CanvasPoint(x: 0, y: 0), zIndex: 1)
        node.childProjectBinding = CanvasChildProjectBinding(projectID: projectID, appliedRevision: 3)
        return node
    }

    @Test("newly copied nodes are pending and cannot open the parent session")
    func copiesArePending() {
        let parentID = UUID()
        let original = boundImageNode(projectID: parentID)
        var nodes = [original]
        var copy = original
        copy.id = UUID()
        nodes.append(copy)
        CanvasCopyForkPlanner.markCopiesPending(nodes: &nodes, copyNodeIDs: [copy.id])
        // Original untouched.
        guard case .valid = nodes[0].childProjectBindingState else {
            Issue.record("original must stay valid"); return
        }
        // Copy is pending and references the parent, but exposes no binding.
        guard case .pending(let pending) = nodes[1].childProjectBindingState else {
            Issue.record("copy must be pending, got \(nodes[1].childProjectBindingState)"); return
        }
        #expect(pending.parentProjectID == parentID)
        #expect(nodes[1].childProjectBinding == nil)
        #expect(nodes[1].childProjectBindingState.isNotEditable)
    }

    @Test("successful fork resolves into an independent binding and clears pending")
    func successfulResolution() throws {
        let parentID = UUID()
        var nodes = [boundImageNode(projectID: parentID)]
        var copy = nodes[0]
        copy.id = UUID()
        nodes.append(copy)
        CanvasCopyForkPlanner.markCopiesPending(nodes: &nodes, copyNodeIDs: [copy.id])
        var document = CanvasDocument(name: "D", nodes: nodes)
        let forkID = UUID()
        let outcome = CanvasCopyForkPlanner.resolve(
            document: &document,
            resolutions: [copy.id: .forked(projectID: forkID, revision: 0)])
        #expect(outcome.resolvedIDs == [copy.id])
        let resolved = try #require(document.nodes.first { $0.id == copy.id })
        let binding = try #require(resolved.childProjectBinding)
        #expect(binding.projectID == forkID)
        #expect(binding.projectID != parentID)
        #expect(binding.appliedRevision == 0)
        #expect(resolved.metadata[CanvasNode.childProjectPendingMetadataKey] == nil)
        guard case .valid = resolved.childProjectBindingState else {
            Issue.record("resolved node must be valid"); return
        }
    }

    @Test("fork failure writes an explicit failed marker and keeps the copy non-editable")
    func failureResolution() {
        let parentID = UUID()
        var nodes = [boundImageNode(projectID: parentID)]
        var copy = nodes[0]; copy.id = UUID(); nodes.append(copy)
        CanvasCopyForkPlanner.markCopiesPending(nodes: &nodes, copyNodeIDs: [copy.id])
        var document = CanvasDocument(name: "D", nodes: nodes)
        _ = CanvasCopyForkPlanner.resolve(
            document: &document,
            resolutions: [copy.id: .failed(reason: "disk full")])
        let node = document.nodes.first { $0.id == copy.id }
        guard case .failed(_, let reason) = node?.childProjectBindingState else {
            Issue.record("expected failed state"); return
        }
        #expect(reason == "disk full")
        #expect(node?.childProjectBinding == nil, "failure must never fall back to the parent binding")
        // Retry: the store resets the failed marker to pending, then resolves.
        let forkID = UUID()
        if case .failed(let pending, _) = document.nodes.first(where: { $0.id == copy.id })?.childProjectBindingState {
            var retryNode = document.nodes[1]
            retryNode.setChildProjectPending(.pending(pending))
            document.nodes[1] = retryNode
        }
        _ = CanvasCopyForkPlanner.resolve(
            document: &document,
            resolutions: [copy.id: .forked(projectID: forkID, revision: 1)])
        #expect(document.nodes.first { $0.id == copy.id }?.childProjectBinding?.projectID == forkID)
    }

    @Test("document switch during fork: resolution only touches the captured document")
    func documentSwitchIsolation() {
        let parentID = UUID()
        var nodes = [boundImageNode(projectID: parentID)]
        var copy = nodes[0]; copy.id = UUID(); nodes.append(copy)
        CanvasCopyForkPlanner.markCopiesPending(nodes: &nodes, copyNodeIDs: [copy.id])
        let captured = CanvasDocument(name: "Captured", nodes: nodes)
        // Meanwhile the current document is a different one.
        var other = CanvasDocument(name: "Other", nodes: [boundImageNode()])
        let forkID = UUID()
        var capturedCopy = captured
        let inCaptured = CanvasCopyForkPlanner.resolve(
            document: &capturedCopy, resolutions: [copy.id: .forked(projectID: forkID, revision: 0)])
        #expect(inCaptured.resolvedIDs == [copy.id])
        // The other document is untouched.
        let beforeOther = other
        _ = CanvasCopyForkPlanner.resolve(document: &other, resolutions: [:])
        #expect(beforeOther == other)
    }

    @Test("a node deleted or rebound while forking is skipped, not force-resolved")
    func deletedOrRetargetedNodeSkipped() {
        let parentID = UUID()
        var nodes = [boundImageNode(projectID: parentID)]
        var copy = nodes[0]; copy.id = UUID(); nodes.append(copy)
        CanvasCopyForkPlanner.markCopiesPending(nodes: &nodes, copyNodeIDs: [copy.id])

        // Case A: node deleted.
        var docA = CanvasDocument(name: "A", nodes: [nodes[0]])
        let rA = CanvasCopyForkPlanner.resolve(
            document: &docA, resolutions: [copy.id: .forked(projectID: UUID(), revision: 0)])
        #expect(rA.resolvedIDs.isEmpty)
        #expect(rA.skippedIDs == [copy.id])

        // Case B: node rebound to something else (no longer pending).
        var rebound = nodes
        rebound[1].childProjectBinding = CanvasChildProjectBinding(projectID: UUID(), appliedRevision: 9)
        var docB = CanvasDocument(name: "B", nodes: rebound)
        let rB = CanvasCopyForkPlanner.resolve(
            document: &docB, resolutions: [copy.id: .forked(projectID: UUID(), revision: 0)])
        #expect(rB.skippedIDs == [copy.id])
        #expect(docB.nodes[1].childProjectBinding?.appliedRevision == 9)
    }
}

@Suite("Canvas first-edit migration planner")
struct CanvasChildProjectMigrationPlannerTests {
    private func legacyNode(hash: String? = "flatten-hash") -> CanvasNode {
        var node = CanvasNode.placeholder(kind: .image, position: CanvasPoint(x: 1, y: 2), zIndex: 1)
        node.asset = CanvasAssetReference(contentHash: hash, localRelativePath: "Materials/original.png")
        return node
    }

    private func renderedAsset() -> CanvasAssetReference {
        CanvasAssetReference(contentHash: "rendered-hash",
                             localRelativePath: "Materials/rendered.png")
    }

    private func makeProject(nodes: [CanvasNode]) -> CanvasProject {
        let document = CanvasDocument(name: "Doc", nodes: nodes)
        return CanvasProject(id: UUID(), name: "迁移画布",
                             documents: [document], selectedDocumentID: document.id)
    }

    @Test("legacy first edit commits asset + binding + pending cleanup in one revision")
    func legacyFirstEditIsAtomic() throws {
        let node = legacyNode()
        let project = makeProject(nodes: [node])
        let rendered = renderedAsset()
        let projectID = UUID()
        let operation = try CanvasChildProjectMigrationPlanner.applyPatch(
            liveNode: node,
            capturedSourceAssetHash: "flatten-hash",
            renderedAsset: rendered,
            projectID: projectID,
            projectRevision: 7,
            extraMetadata: ["editor": "media-workbench"])
        #expect(operation.kind == .update)
        #expect(operation.nodeID == node.id)
        #expect(operation.asset?.id == rendered.id)
        #expect(operation.removedMetadataKeys == [CanvasNode.childProjectPendingMetadataKey])

        let patch = CanvasPatch(canvasID: project.id, documentID: project.documents[0].id,
                                expectedRevision: project.revision, operations: [operation])
        let (updated, result) = try CanvasCommandService.applying(patch, to: project)
        #expect(result.revision == project.revision + 1)
        #expect(result.previousRevision == project.revision)
        let committed = try #require(updated.documents[0].nodes.first { $0.id == node.id })
        #expect(committed.asset?.id == rendered.id)
        #expect(committed.asset?.contentHash == "rendered-hash")
        let binding = try #require(committed.childProjectBinding)
        #expect(binding.projectID == projectID)
        #expect(binding.appliedRevision == 7)
        #expect(binding.draftRevision == 7)
        #expect(binding.renderedAssetID == rendered.id)
        #expect(binding.sourceNodeID == node.id)
        // The ORIGINAL flatten hash, never the rendered hash.
        #expect(binding.sourceAssetHash == "flatten-hash")
        #expect(committed.metadata[CanvasNode.childProjectPendingMetadataKey] == nil)
        #expect(committed.metadata["editor"] == "media-workbench")
    }

    @Test("a node whose asset changed since the session opened is refused")
    func sourceChangeIsRefused() throws {
        var node = legacyNode(hash: "changed-hash")
        let project = makeProject(nodes: [node])
        #expect(throws: CanvasChildProjectMigrationPlanner.Refusal.self) {
            _ = try CanvasChildProjectMigrationPlanner.applyPatch(
                liveNode: node,
                capturedSourceAssetHash: "flatten-hash",
                renderedAsset: renderedAsset(),
                projectID: UUID(),
                projectRevision: 1)
        }
        // Nothing was mutated by planning.
        #expect(project.documents[0].nodes[0] == node)
        node.asset = nil
        #expect(throws: CanvasChildProjectMigrationPlanner.Refusal.self) {
            _ = try CanvasChildProjectMigrationPlanner.applyPatch(
                liveNode: node,
                capturedSourceAssetHash: nil,
                renderedAsset: renderedAsset(),
                projectID: UUID(),
                projectRevision: 1)
        }
    }

    @Test("missing project id is refused instead of inventing one")
    func missingProjectRefused() {
        let node = legacyNode()
        #expect(throws: CanvasChildProjectMigrationPlanner.Refusal.self) {
            _ = try CanvasChildProjectMigrationPlanner.applyPatch(
                liveNode: node,
                capturedSourceAssetHash: "flatten-hash",
                renderedAsset: renderedAsset(),
                projectID: nil,
                projectRevision: 1)
        }
    }

    @Test("preserved unknown/malformed bindings are refused and never overwritten")
    func preservedRawBindingsRefused() throws {
        let raws: [String] = [
            #"{"schemaVersion":99,"projectID":"\#(UUID().uuidString)","appliedRevision":4}"#,
            "not-json"
        ]
        for raw in raws {
            var node = legacyNode()
            node.metadata[CanvasNode.childProjectMetadataKey] = raw
            #expect(throws: CanvasChildProjectMigrationPlanner.Refusal.self) {
                _ = try CanvasChildProjectMigrationPlanner.applyPatch(
                    liveNode: node,
                    capturedSourceAssetHash: "flatten-hash",
                    renderedAsset: renderedAsset(),
                    projectID: UUID(),
                    projectRevision: 1)
            }
            // The raw bytes survive planning unchanged.
            #expect(node.metadata[CanvasNode.childProjectMetadataKey] == raw)
        }
        // Unrecognized pending status is equally non-migratable.
        let wrapper = try #require(PendingWrapper(
            status: "blocked-by-policy",
            pending: CanvasChildProjectPending(parentProjectID: UUID()),
            reason: "review").json)
        var node = legacyNode()
        node.metadata[CanvasNode.childProjectPendingMetadataKey] = wrapper
        #expect(throws: CanvasChildProjectMigrationPlanner.Refusal.self) {
            _ = try CanvasChildProjectMigrationPlanner.applyPatch(
                liveNode: node,
                capturedSourceAssetHash: "flatten-hash",
                renderedAsset: renderedAsset(),
                projectID: UUID(),
                projectRevision: 1)
        }
        #expect(node.metadata[CanvasNode.childProjectPendingMetadataKey] == wrapper)
    }

    @Test("video variant on a preserved raw binding creates a new node and leaves the original untouched")
    func variantPreservesRawBinding() throws {
        let raw = #"{"schemaVersion":99,"projectID":"\#(UUID().uuidString)","appliedRevision":4}"#
        var source = CanvasNode.placeholder(kind: .video, position: CanvasPoint(x: 0, y: 0), zIndex: 1)
        source.asset = CanvasAssetReference(contentHash: "video-hash",
                                            localRelativePath: "Materials/source.mp4",
                                            mimeType: "video/mp4")
        source.metadata[CanvasNode.childProjectMetadataKey] = raw
        let project = makeProject(nodes: [source])
        let rendered = renderedAsset()
        let projectID = UUID()
        let (newID, operations) = try CanvasChildProjectMigrationPlanner.variantPatch(
            sourceNodeID: source.id,
            kind: .video,
            position: CanvasPoint(x: 500, y: 20),
            size: source.size,
            renderedAsset: rendered,
            projectID: projectID,
            projectRevision: 3,
            sourceAssetHash: "video-hash",
            extraMetadata: ["variant": "true"])
        #expect(operations.count == 2)
        #expect(operations[0].kind == .create)
        #expect(operations[1].kind == .connect)
        let patch = CanvasPatch(canvasID: project.id, documentID: project.documents[0].id,
                                expectedRevision: project.revision, operations: operations)
        let (updated, result) = try CanvasCommandService.applying(patch, to: project)
        #expect(result.revision == project.revision + 1)
        // Original raw binding metadata is byte-identical.
        let original = try #require(updated.documents[0].nodes.first { $0.id == source.id })
        #expect(original.metadata[CanvasNode.childProjectMetadataKey] == raw)
        #expect(original.childProjectBinding == nil)
        // New node carries the resolved binding and the derivedFrom edge.
        let created = try #require(updated.documents[0].nodes.first { $0.id == newID })
        #expect(created.childProjectBinding?.projectID == projectID)
        #expect(created.childProjectBinding?.sourceNodeID == source.id)
        #expect(created.metadata["derivedFromNodeID"] == source.id.uuidString)
        #expect(updated.documents[0].connections.contains {
            $0.sourceNodeID == source.id && $0.destinationNodeID == newID
                && $0.kind == .generatedFrom
        })
    }

    @Test("failed commit keeps the original asset and a retry commits the exact binding")
    func failureMarkerAndRetry() throws {
        let node = legacyNode()
        let project = makeProject(nodes: [node])
        let rendered = renderedAsset()
        let projectID = UUID()
        let marker = try CanvasChildProjectMigrationPlanner.failedMarkerPatch(
            liveNode: node,
            projectID: projectID,
            projectRevision: 5,
            renderedAsset: rendered,
            sourceAssetHash: "flatten-hash",
            reason: "disk full")
        let patch = CanvasPatch(canvasID: project.id, documentID: project.documents[0].id,
                                expectedRevision: project.revision, operations: [marker])
        let (failedProject, _) = try CanvasCommandService.applying(patch, to: project)
        let failed = try #require(failedProject.documents[0].nodes.first { $0.id == node.id })
        // Original pixels/asset are preserved; only the marker was written.
        #expect(failed.asset?.id == node.asset?.id)
        #expect(failed.asset?.contentHash == "flatten-hash")
        guard case .failed(let pending, let reason) = failed.childProjectBindingState else {
            Issue.record("expected failed migration marker, got \(failed.childProjectBindingState)")
            return
        }
        #expect(reason == "disk full")
        #expect(pending.renderedAsset?.id == rendered.id)
        #expect(pending.sourceAssetHash == "flatten-hash")
        #expect(pending.appliedRevision == 5)

        // Retry commits the exact binding in one patch.
        let retry = try CanvasChildProjectMigrationPlanner.retryPatch(
            liveNode: failed, pending: pending, extraMetadata: ["editor": "media-workbench"])
        let retryPatch = CanvasPatch(canvasID: failedProject.id,
                                     documentID: failedProject.documents[0].id,
                                     expectedRevision: failedProject.revision, operations: [retry])
        let (retried, result) = try CanvasCommandService.applying(retryPatch, to: failedProject)
        #expect(result.revision == failedProject.revision + 1)
        let bound = try #require(retried.documents[0].nodes.first { $0.id == node.id })
        #expect(bound.asset?.id == rendered.id)
        let binding = try #require(bound.childProjectBinding)
        #expect(binding.projectID == projectID)
        #expect(binding.appliedRevision == 5)
        #expect(binding.draftRevision == 5)
        #expect(binding.sourceAssetHash == "flatten-hash")
        #expect(bound.metadata[CanvasNode.childProjectPendingMetadataKey] == nil)
    }

    @Test("fork markers are not migration retries")
    func forkMarkersAreNotMigrationRetries() throws {
        let parentID = UUID()
        let node = boundImageNode(projectID: parentID)
        var nodes = [node, { var copy = node; copy.id = UUID(); return copy }()]
        CanvasCopyForkPlanner.markCopiesPending(nodes: &nodes, copyNodeIDs: [nodes[1].id])
        guard case .pending(let pending) = nodes[1].childProjectBindingState else {
            Issue.record("expected pending fork marker"); return
        }
        #expect(pending.renderedAsset == nil)
        #expect(throws: CanvasChildProjectMigrationPlanner.Refusal.self) {
            _ = try CanvasChildProjectMigrationPlanner.retryPatch(
                liveNode: nodes[1], pending: pending)
        }
    }

    private func boundImageNode(projectID: UUID) -> CanvasNode {
        var node = CanvasNode.placeholder(kind: .image, position: CanvasPoint(x: 0, y: 0), zIndex: 1)
        node.childProjectBinding = CanvasChildProjectBinding(projectID: projectID, appliedRevision: 3)
        return node
    }
}

@Suite("Canvas drawing (CAD) node planner")
struct CanvasDrawingNodePlannerTests {
    private func drawingNode(
        path: String = "Materials/plate.dwg",
        hash: String? = "plate-hash-v1",
        kind: CanvasNodeKind = .file,
        text: String = "plate"
    ) -> CanvasNode {
        var node = CanvasNode.placeholder(
            kind: kind, position: CanvasPoint(x: 120, y: 80), zIndex: 4)
        node.text = text
        node.size = CanvasSize(width: 300, height: 210)
        node.asset = CanvasAssetReference(
            contentHash: hash, localRelativePath: path,
            mimeType: "image/vnd.dwg", byteCount: 512)
        return node
    }

    private func renderedDrawing() -> CanvasAssetReference {
        CanvasAssetReference(
            contentHash: "plate-hash-v2",
            localRelativePath: "Materials/plate-edited.dwg",
            mimeType: "image/vnd.dwg", byteCount: 640)
    }

    private func project(nodes: [CanvasNode],
                         connections: [CanvasConnection] = []) -> CanvasProject {
        let document = CanvasDocument(name: "Doc", nodes: nodes, connections: connections)
        return CanvasProject(id: UUID(), name: "CAD Canvas",
                             documents: [document], selectedDocumentID: document.id)
    }

    @Test("only .file nodes whose asset is DWG/DXF are drawing nodes")
    func drawingNodeClassification() {
        #expect(CanvasDrawingNodePlanner.isDrawingNode(drawingNode()))
        #expect(CanvasDrawingNodePlanner.isDrawingNode(
            drawingNode(path: "Materials/plan.DXF")))
        #expect(!CanvasDrawingNodePlanner.isDrawingNode(
            drawingNode(path: "Materials/photo.png")))
        #expect(!CanvasDrawingNodePlanner.isDrawingNode(
            drawingNode(kind: .image, text: "image")))
        var missing = drawingNode()
        missing.asset = nil
        #expect(!CanvasDrawingNodePlanner.isDrawingNode(missing))
        #expect(CanvasDrawingNodePlanner.drawingExtension(for: "a/b/plan.DWG") == "dwg")
        #expect(CanvasDrawingNodePlanner.drawingExtension(for: "plan.step") == nil)
    }

    @Test("open plan stages under a deterministic contained path with the source hash")
    func openPlanIsDeterministic() throws {
        let node = drawingNode(path: "Materials/../evil name.dwg")
        let canvasID = UUID()
        let plan = try CanvasDrawingNodePlanner.openPlan(node: node, canvasID: canvasID)
        #expect(plan.nodeID == node.id)
        #expect(plan.canvasID == canvasID)
        #expect(plan.sourceContentHash == "plate-hash-v1")
        #expect(plan.fileExtension == "dwg")
        #expect(plan.stagedRelativePath.contains(canvasID.uuidString.lowercased()))
        #expect(plan.stagedRelativePath.contains(node.id.uuidString.lowercased()))
        #expect(!plan.stagedRelativePath.contains(".."))
        #expect(!plan.stagedRelativePath.hasPrefix("/"))
        #expect(plan.stagedRelativePath.hasSuffix(".dwg"))
        let again = try CanvasDrawingNodePlanner.openPlan(node: node, canvasID: canvasID)
        #expect(again.stagedRelativePath == plan.stagedRelativePath)
        // A non-drawing node never yields a plan.
        #expect(throws: CanvasDrawingNodePlanner.Refusal.self) {
            _ = try CanvasDrawingNodePlanner.openPlan(
                node: drawingNode(path: "Materials/photo.png"), canvasID: canvasID)
        }
    }

    @Test("open→save→reopen→apply replaces the asset in one revision, keeping identity")
    func openSaveReopenApplyIsAtomic() throws {
        let source = drawingNode()
        var other = CanvasNode.placeholder(
            kind: .text, position: CanvasPoint(x: 500, y: 80), zIndex: 1)
        other.text = "edge target"
        let edge = CanvasConnection(
            sourceNodeID: source.id, destinationNodeID: other.id,
            kind: .arrow)
        let original = project(nodes: [source, other], connections: [edge])

        let plan = try CanvasDrawingNodePlanner.openPlan(node: source, canvasID: original.id)
        #expect(plan.sourceContentHash == "plate-hash-v1")

        let rendered = renderedDrawing()
        let operation = try CanvasDrawingNodePlanner.applyPatch(
            liveNode: source,
            capturedSourceAssetHash: plan.sourceContentHash,
            renderedAsset: rendered,
            extraMetadata: ["editor": "cad"])
        let patch = CanvasPatch(canvasID: original.id,
                                documentID: original.documents[0].id,
                                expectedRevision: original.revision,
                                operations: [operation])
        let (updated, result) = try CanvasCommandService.applying(patch, to: original)
        #expect(result.revision == original.revision + 1)
        #expect(result.previousRevision == original.revision)
        let committed = try #require(updated.documents[0].nodes.first { $0.id == source.id })
        // Identity, position, size, kind and edges survive.
        #expect(committed.id == source.id)
        #expect(committed.kind == .file)
        #expect(committed.text == "plate")
        #expect(committed.position == source.position)
        #expect(committed.size == source.size)
        #expect(updated.documents[0].connections.count == 1)
        #expect(updated.documents[0].connections[0].destinationNodeID == other.id)
        // The asset is the saved drawing, never an image conversion.
        #expect(committed.asset?.id == rendered.id)
        #expect(committed.asset?.contentHash == "plate-hash-v2")
        #expect(committed.asset?.mimeType == "image/vnd.dwg")
        // Source revision recorded for compare; no child-project claims.
        #expect(committed.metadata["drawingEditor"] == "engineering")
        #expect(committed.metadata["drawingSourceHash"] == "plate-hash-v1")
        #expect(committed.metadata["drawingContentHash"] == "plate-hash-v2")
        #expect(committed.metadata["editor"] == "cad")
        #expect(committed.childProjectBinding == nil)

        // Reopen plans against the applied revision deterministically and
        // captures the new source hash for the next compare.
        let reopened = try CanvasDrawingNodePlanner.openPlan(
            node: committed, canvasID: original.id)
        let reopenedAgain = try CanvasDrawingNodePlanner.openPlan(
            node: committed, canvasID: original.id)
        #expect(reopened.stagedRelativePath == reopenedAgain.stagedRelativePath)
        #expect(reopened.stagedRelativePath.hasSuffix("plate-edited.dwg"))
        #expect(reopened.sourceContentHash == "plate-hash-v2")
    }

    @Test("apply refuses a node whose drawing changed since the session opened")
    func applyRefusesChangedSource() throws {
        let stale = drawingNode(hash: "plate-hash-v1")
        let changed = drawingNode(hash: "changed-hash")
        #expect(throws: CanvasDrawingNodePlanner.Refusal.self) {
            _ = try CanvasDrawingNodePlanner.applyPatch(
                liveNode: changed,
                capturedSourceAssetHash: "plate-hash-v1",
                renderedAsset: renderedDrawing())
        }
        // Missing hashes and non-drawing nodes are refused too.
        #expect(throws: CanvasDrawingNodePlanner.Refusal.self) {
            _ = try CanvasDrawingNodePlanner.applyPatch(
                liveNode: stale,
                capturedSourceAssetHash: nil,
                renderedAsset: renderedDrawing())
        }
        #expect(throws: CanvasDrawingNodePlanner.Refusal.self) {
            _ = try CanvasDrawingNodePlanner.applyPatch(
                liveNode: drawingNode(path: "Materials/photo.png"),
                capturedSourceAssetHash: "plate-hash-v1",
                renderedAsset: renderedDrawing())
        }
    }

    @Test("make variant creates a NEW file node with provenance in one revision")
    func variantCreatesNewNode() throws {
        let source = drawingNode()
        let original = project(nodes: [source])
        let variantAsset = CanvasAssetReference(
            contentHash: "variant-hash",
            localRelativePath: "Materials/variant-copy.dwg",
            mimeType: "image/vnd.dwg", byteCount: 512)
        let (newID, operations) = try CanvasDrawingNodePlanner.variantPatch(
            sourceNodeID: source.id,
            drawingAsset: variantAsset,
            position: CanvasPoint(x: 620, y: 80),
            size: source.size,
            sourceAssetHash: "plate-hash-v1",
            extraMetadata: ["editor": "cad"])
        #expect(operations.count == 2)
        let patch = CanvasPatch(canvasID: original.id,
                                documentID: original.documents[0].id,
                                expectedRevision: original.revision,
                                operations: operations)
        let (updated, result) = try CanvasCommandService.applying(patch, to: original)
        #expect(result.revision == original.revision + 1)
        // Original untouched.
        let untouched = try #require(updated.documents[0].nodes.first { $0.id == source.id })
        #expect(untouched.asset?.contentHash == "plate-hash-v1")
        #expect(untouched.childProjectBinding == nil)
        // New node owns the copied drawing with provenance and an edge.
        let created = try #require(updated.documents[0].nodes.first { $0.id == newID })
        #expect(created.kind == .file)
        #expect(created.asset?.id == variantAsset.id)
        #expect(created.metadata["derivedFromNodeID"] == source.id.uuidString)
        #expect(created.metadata["drawingVariant"] == "true")
        #expect(created.metadata["drawingSourceHash"] == "plate-hash-v1")
        #expect(updated.documents[0].connections.contains {
            $0.sourceNodeID == source.id && $0.destinationNodeID == newID
                && $0.kind == .generatedFrom
        })
    }

    @Test("draft resume decision only matches the exact source revision")
    func resumeDecisionRequiresMatchingSource() throws {
        let plan = try CanvasDrawingNodePlanner.openPlan(
            node: drawingNode(), canvasID: UUID())
        #expect(CanvasDrawingNodePlanner.shouldResumeDraft(
            plan.descriptor, liveSourceHash: "plate-hash-v1"))
        #expect(!CanvasDrawingNodePlanner.shouldResumeDraft(
            plan.descriptor, liveSourceHash: "plate-hash-v2"))
        #expect(!CanvasDrawingNodePlanner.shouldResumeDraft(plan.descriptor, liveSourceHash: nil))
        #expect(!CanvasDrawingNodePlanner.shouldResumeDraft(
            nil, liveSourceHash: "plate-hash-v1"))
        var future = plan.descriptor
        future.schemaVersion = 99
        #expect(!CanvasDrawingNodePlanner.shouldResumeDraft(
            future, liveSourceHash: "plate-hash-v1"))
        let alternate = CanvasDrawingNodePlanner.alternateStagedRelativePath(
            plan, contentHash: "abc12345dead")
        #expect(alternate != plan.stagedRelativePath)
        #expect(alternate.hasSuffix(".dwg"))
        #expect(!alternate.contains(".."))
    }

    // MARK: Draft continuity (dirty close, eviction, repeated apply, conflicts)

    @Test("dirty close serializes a durable draft then restart resumes")
    func dirtyCloseThenRestartResumes() throws {
        // Same revision: the session resumes, and the durable descriptor
        // written at staging survives a restart with the same identity.
        #expect(CanvasDrawingDraftContinuity.resumeDecision(
            existingSourceHash: "plate-hash-v1",
            liveSourceHash: "plate-hash-v1",
            sessionDirty: true) == .resume)
        let plan = try CanvasDrawingNodePlanner.openPlan(
            node: drawingNode(), canvasID: UUID())
        let encoded = try JSONEncoder().encode(plan.descriptor)
        let decoded = try JSONDecoder().decode(
            CanvasDrawingNodePlanner.CanvasDrawingDraftDescriptor.self, from: encoded)
        #expect(CanvasDrawingNodePlanner.shouldResumeDraft(
            decoded, liveSourceHash: "plate-hash-v1"))
        // An unapplied draft carries no applied marker: it is user work.
        #expect(decoded.appliedContentHash == nil)
        #expect(decoded.appliedAssetID == nil)
        #expect(!CanvasDrawingDraftContinuity.isProvablyApplied(
            appliedContentHash: decoded.appliedContentHash,
            liveSourceHash: "plate-hash-v1"))
    }

    @Test("saved-but-unapplied draft survives LRU eviction and reopens")
    func unappliedDraftSurvivesEviction() {
        // Unapplied (or applied-to-another-revision) drafts are never
        // provably redundant, so eviction must keep the files.
        #expect(!CanvasDrawingDraftContinuity.isProvablyApplied(
            appliedContentHash: nil, stagedContentHash: "plate-hash-v1",
            liveSourceHash: "plate-hash-v1"))
        #expect(!CanvasDrawingDraftContinuity.isProvablyApplied(
            appliedContentHash: "plate-hash-v2", stagedContentHash: "plate-hash-v2",
            liveSourceHash: "plate-hash-v1"))
        // Saved edits after an apply: the staged hash diverged from the
        // applied hash and the node still has the old bytes.
        #expect(!CanvasDrawingDraftContinuity.isProvablyApplied(
            appliedContentHash: "plate-hash-v1", stagedContentHash: "plate-hash-saved",
            liveSourceHash: "plate-hash-v1"))
        // Only an unmodified applied draft is redundant.
        #expect(CanvasDrawingDraftContinuity.isProvablyApplied(
            appliedContentHash: "plate-hash-v1", stagedContentHash: "plate-hash-v1",
            liveSourceHash: "plate-hash-v1"))
        // Legacy descriptor without a staged hash keeps the old semantics.
        #expect(CanvasDrawingDraftContinuity.isProvablyApplied(
            appliedContentHash: "plate-hash-v1", stagedContentHash: nil,
            liveSourceHash: "plate-hash-v1"))
        #expect(!CanvasDrawingDraftContinuity.isProvablyApplied(
            appliedContentHash: "plate-hash-v1", stagedContentHash: "plate-hash-v1",
            liveSourceHash: nil))
        // The unapplied draft still resumes after the session was released.
        #expect(CanvasDrawingDraftContinuity.resumeDecision(
            existingSourceHash: "plate-hash-v1",
            liveSourceHash: "plate-hash-v1",
            sessionDirty: false) == .resume)
    }

    @Test("apply→edit→apply uses the fresh baseline; stale baseline is refused")
    func repeatedApplyUsesFreshBaseline() throws {
        let source = drawingNode()
        let original = project(nodes: [source])
        let secondAsset = CanvasAssetReference(
            contentHash: "plate-hash-v3",
            localRelativePath: "Materials/plate-edited-2.dwg",
            mimeType: "image/vnd.dwg", byteCount: 700)
        let firstOperation = try CanvasDrawingNodePlanner.applyPatch(
            liveNode: source,
            capturedSourceAssetHash: "plate-hash-v1",
            renderedAsset: renderedDrawing())
        let firstPatch = CanvasPatch(canvasID: original.id,
                                     documentID: original.documents[0].id,
                                     expectedRevision: original.revision,
                                     operations: [firstOperation])
        let (afterFirst, _) = try CanvasCommandService.applying(firstPatch, to: original)
        let committed = try #require(afterFirst.documents[0].nodes.first { $0.id == source.id })

        // The applied baseline is adopted durably (descriptor marked applied).
        let markedDescriptor = CanvasDrawingNodePlanner.CanvasDrawingDraftDescriptor(
            canvasID: original.id, nodeID: source.id, sourceAssetID: nil,
            sourceContentHash: "plate-hash-v2",
            sourceRelativePath: "Materials/plate-edited.dwg",
            stagedRelativePath: "x/plate-edited.dwg",
            appliedContentHash: "plate-hash-v2", appliedAssetID: UUID(),
            stagedContentHash: "plate-hash-v2")
        #expect(CanvasDrawingDraftContinuity.isProvablyApplied(
            appliedContentHash: markedDescriptor.appliedContentHash,
            stagedContentHash: markedDescriptor.stagedContentHash,
            liveSourceHash: committed.asset?.contentHash))
        #expect(CanvasDrawingDraftContinuity.resumeDecision(
            existingSourceHash: markedDescriptor.sourceContentHash,
            liveSourceHash: committed.asset?.contentHash,
            sessionDirty: true) == .resume)

        // Second apply uses the FRESH baseline and succeeds.
        let secondOperation = try CanvasDrawingNodePlanner.applyPatch(
            liveNode: committed,
            capturedSourceAssetHash: "plate-hash-v2",
            renderedAsset: secondAsset)
        let secondPatch = CanvasPatch(canvasID: afterFirst.id,
                                      documentID: afterFirst.documents[0].id,
                                      expectedRevision: afterFirst.revision,
                                      operations: [secondOperation])
        let (afterSecond, result) = try CanvasCommandService.applying(secondPatch, to: afterFirst)
        #expect(result.revision == afterFirst.revision + 1)
        let twice = try #require(afterSecond.documents[0].nodes.first { $0.id == source.id })
        #expect(twice.asset?.contentHash == "plate-hash-v3")
        #expect(twice.metadata["drawingSourceHash"] == "plate-hash-v2")

        // The stale baseline is refused (draft would be preserved).
        #expect(throws: CanvasDrawingNodePlanner.Refusal.self) {
            _ = try CanvasDrawingNodePlanner.applyPatch(
                liveNode: twice,
                capturedSourceAssetHash: "plate-hash-v1",
                renderedAsset: secondAsset)
        }
    }

    @Test("external node revision conflict is refused and preserves the draft")
    func externalConflictPreservesDraft() throws {
        // The session must be serialized first when it still has live edits.
        #expect(CanvasDrawingDraftContinuity.resumeDecision(
            existingSourceHash: "plate-hash-v1",
            liveSourceHash: "plate-hash-v2",
            sessionDirty: true) == .replacePreservingDraft(serializeFirst: true))
        #expect(CanvasDrawingDraftContinuity.resumeDecision(
            existingSourceHash: "plate-hash-v1",
            liveSourceHash: "plate-hash-v2",
            sessionDirty: false) == .replacePreservingDraft(serializeFirst: false))
        #expect(CanvasDrawingDraftContinuity.resumeDecision(
            existingSourceHash: nil,
            liveSourceHash: "plate-hash-v2",
            sessionDirty: true) == .fresh)
        #expect(CanvasDrawingDraftContinuity.resumeDecision(
            existingSourceHash: "plate-hash-v1",
            liveSourceHash: nil,
            sessionDirty: true) == .replacePreservingDraft(serializeFirst: true))
        // Applying the stale draft to the changed node is refused.
        #expect(throws: CanvasDrawingNodePlanner.Refusal.self) {
            _ = try CanvasDrawingNodePlanner.applyPatch(
                liveNode: drawingNode(hash: "plate-hash-v2"),
                capturedSourceAssetHash: "plate-hash-v1",
                renderedAsset: renderedDrawing())
        }
    }

    @Test("over-budget drafts are reported instead of silently deleted")
    func draftBudgetReporting() {
        #expect(CanvasDrawingDraftContinuity.maintenanceNotice(
            draftCount: 0, totalBytes: 0) == nil)
        #expect(CanvasDrawingDraftContinuity.maintenanceNotice(
            draftCount: 3, totalBytes: 10, budgetBytes: 100) == nil)
        let notice = CanvasDrawingDraftContinuity.maintenanceNotice(
            draftCount: 3, totalBytes: 300 * 1024 * 1024,
            budgetBytes: 256 * 1024 * 1024)
        #expect(notice != nil)
        #expect(notice?.contains("3") == true)
    }

    @Test("a failed serialization retains the session instead of releasing it")
    func failedSerializationRetainsSession() {
        // The registry branch must use the deterministic requestSave API.
        #expect(CanvasDrawingDraftContinuity.serializationPlan(
            isDirty: false, supportsRequestSave: true) == .noop)
        #expect(CanvasDrawingDraftContinuity.serializationPlan(
            isDirty: true, supportsRequestSave: true) == .requestSave)
        #expect(CanvasDrawingDraftContinuity.serializationPlan(
            isDirty: true, supportsRequestSave: false) == .unavailable)
        // A failed flush is never a release: the session is retained for retry.
        #expect(CanvasDrawingDraftContinuity.sessionRetentionDecision(
            flushSucceeded: true) == .release)
        #expect(CanvasDrawingDraftContinuity.sessionRetentionDecision(
            flushSucceeded: false) == .retainForRetry)
    }

    @Test("descriptor write races cannot regress an applied baseline")
    func descriptorGenerationCAS() {
        let base = CanvasDrawingNodePlanner.CanvasDrawingDraftDescriptor(
            canvasID: UUID(), nodeID: UUID(), sourceAssetID: nil,
            sourceContentHash: "v1", sourceRelativePath: "Materials/a.dwg",
            stagedRelativePath: "c/n/a.dwg",
            appliedContentHash: "v2", appliedAssetID: UUID(),
            stagedContentHash: "v2", generation: 5)
        // A delayed saved-draft marker (older generation) is rejected.
        var stale = base
        stale.generation = 4
        stale.appliedContentHash = nil
        stale.stagedContentHash = "v3"
        #expect(CanvasDrawingDraftContinuity.mergedDescriptor(
            current: base, incoming: stale) == nil)
        // A same-generation write that would clear the applied baseline is
        // rejected too.
        var sameGeneration = base
        sameGeneration.appliedContentHash = nil
        #expect(CanvasDrawingDraftContinuity.mergedDescriptor(
            current: base, incoming: sameGeneration) == nil)
        // A newer generation is accepted and keeps its own state.
        var newer = base
        newer.generation = 6
        newer.stagedContentHash = "v4"
        let merged = CanvasDrawingDraftContinuity.mergedDescriptor(
            current: base, incoming: newer)
        #expect(merged?.generation == 6)
        #expect(merged?.stagedContentHash == "v4")
        #expect(merged?.appliedContentHash == "v2")
        // No existing descriptor: the first write is accepted.
        let fresh = CanvasDrawingDraftContinuity.mergedDescriptor(
            current: nil, incoming: base)
        #expect(fresh == base)
        // Descriptor generation survives a Codable round trip.
        let encoded = try? JSONEncoder().encode(base)
        let decoded = encoded.flatMap {
            try? JSONDecoder().decode(
                CanvasDrawingNodePlanner.CanvasDrawingDraftDescriptor.self, from: $0)
        }
        #expect(decoded?.generation == 5)
    }

    // MARK: - Unapplied-draft restore guard

    @Test("hasUnappliedDraft distinguishes applied/source-equal staged bytes")
    func unappliedDraftDetection() {
        let applied = String(repeating: "a", count: 64)
        let source = String(repeating: "b", count: 64)
        let newer = String(repeating: "c", count: 64)

        // No staged hash: nothing unapplied.
        #expect(!CanvasDrawingDraftContinuity.hasUnappliedDraft(
            stagedContentHash: nil, appliedContentHash: applied,
            sourceContentHash: source))
        // Staged bytes equal the adopted baseline: applied, not unapplied.
        #expect(!CanvasDrawingDraftContinuity.hasUnappliedDraft(
            stagedContentHash: applied, appliedContentHash: applied,
            sourceContentHash: source))
        // Staged bytes equal the node's current source hash: clean resume.
        #expect(!CanvasDrawingDraftContinuity.hasUnappliedDraft(
            stagedContentHash: source, appliedContentHash: applied,
            sourceContentHash: source))
        // Staged bytes differ from both: saved but unapplied work.
        #expect(CanvasDrawingDraftContinuity.hasUnappliedDraft(
            stagedContentHash: newer, appliedContentHash: applied,
            sourceContentHash: source))
        // An empty staged hash is ignored.
        #expect(!CanvasDrawingDraftContinuity.hasUnappliedDraft(
            stagedContentHash: "", appliedContentHash: applied,
            sourceContentHash: source))
        // Staged work with no recorded applied baseline is unapplied unless
        // it equals the source the node still carries.
        #expect(CanvasDrawingDraftContinuity.hasUnappliedDraft(
            stagedContentHash: newer, appliedContentHash: nil,
            sourceContentHash: source))
    }
}
