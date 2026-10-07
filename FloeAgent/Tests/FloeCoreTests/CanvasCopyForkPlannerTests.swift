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
