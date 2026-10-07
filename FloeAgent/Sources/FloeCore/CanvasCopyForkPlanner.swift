// Canvas child-project fork lifecycle for copied nodes.
//
// A duplicated/pasted image node must never share the original's mutable
// editable project. The lifecycle is explicit and crash-recoverable:
//
//   1. When copies are created they are synchronously marked `.pending`
//      (parent project id recorded, resolved binding key removed) BEFORE they
//      become visible. A pending node cannot open any editable session.
//   2. A forked project is created off the main actor.
//   3. The result is committed back to the CAPTURED document id (never the
//      live "selected document"), with file revision checks: success writes a
//      resolved valid binding; failure writes an explicit `.failed` marker that
//      retains the parent id for retry. There is no fallback that leaves the
//      copy sharing the parent's mutable project.
//
// These helpers are value-based and unit-testable; the view owns the async
// fork call and the atomic file commit.

import Foundation

public enum CanvasCopyForkPlanner {
    /// Marks freshly created copied nodes as pending forks, capturing the
    /// parent project they must be forked from. Called inside the SAME
    /// synchronous mutation that appends the copies, so a copy is never exposed
    /// with a live (shared) binding.
    public static func markCopiesPending(
        nodes: inout [CanvasNode],
        copyNodeIDs: [UUID],
        startedAt: Date = Date()
    ) {
        for index in nodes.indices where copyNodeIDs.contains(nodes[index].id) {
            // Resolve the parent project from whatever binding the copy
            // inherited. If none, there is nothing to fork (leave as-is).
            guard let inherited = nodes[index].childProjectBinding else { continue }
            let pending = CanvasChildProjectPending(
                parentProjectID: inherited.projectID,
                sourceNodeID: inherited.sourceNodeID,
                startedAt: startedAt)
            nodes[index].setChildProjectPending(.pending(pending))
        }
    }

    public enum Resolution: Sendable {
        case forked(projectID: UUID, revision: Int64)
        case failed(reason: String)
    }

    /// Applies fork resolutions to a captured document snapshot, producing a
    /// new document value. Nodes are resolved by id inside `documentID` only —
    /// the caller must pass the document captured before awaiting, so a
    /// document switch cannot rebind into the wrong canvas. Nodes that have
    /// disappeared (deleted while the fork ran) are skipped; their forks become
    /// orphans the store can prune, but they never mutate another document.
    @discardableResult
    public static func resolve(
        document: inout CanvasDocument,
        resolutions: [UUID: Resolution],
        resolvedAt: Date = Date()
    ) -> (resolvedIDs: Set<UUID>, failedIDs: Set<UUID>, skippedIDs: Set<UUID>) {
        var resolved = Set<UUID>()
        var failed = Set<UUID>()
        var skipped = Set<UUID>()
        for (nodeID, result) in resolutions {
            guard let index = document.nodes.firstIndex(where: { $0.id == nodeID }) else {
                skipped.insert(nodeID)
                continue
            }
            // Resolve only a node still waiting on a pending marker. The store
            // resets failed nodes to pending before retrying. A node retargeted
            // or rebound meanwhile is skipped.
            guard case .pending(let pending) = document.nodes[index].childProjectBindingState else {
                skipped.insert(nodeID)
                continue
            }
            switch result {
            case .forked(let projectID, let revision):
                let binding = CanvasChildProjectBinding(
                    projectID: projectID,
                    appliedRevision: revision,
                    draftRevision: revision,
                    renderedAssetID: nil,
                    sourceNodeID: pending.sourceNodeID)
                document.nodes[index].childProjectBinding = binding
                resolved.insert(nodeID)
            case .failed(let reason):
                document.nodes[index].setChildProjectPending(
                    .failed(pending, reason: reason))
                failed.insert(nodeID)
            }
        }
        if !resolved.isEmpty || !failed.isEmpty {
            document.updatedAt = resolvedAt
        }
        return (resolved, failed, skipped)
    }

    /// Collects pending fork requests (node id → parent project) from a
    /// captured document. Used to kick off forks against fixed identities.
    public static func pendingRequests(in document: CanvasDocument) -> [UUID: CanvasChildProjectPending] {
        var map: [UUID: CanvasChildProjectPending] = [:]
        for node in document.nodes {
            if case .pending(let pending) = node.childProjectBindingState {
                map[node.id] = pending
            }
        }
        return map
    }
}
