import Foundation

/// One atomic, pure edit pass over a `CanvasSnapshot`. The engine never
/// mutates in place: it validates the whole batch first, then returns the
/// next snapshot. Violations surface as values, never as silent skips.
public enum CanvasEditOperation: Codable, Hashable, Sendable {
    case insertNode(CanvasNodeSnapshot)
    case updateContent(nodeID: UUID, content: CanvasContent)
    case updateTitle(nodeID: UUID, title: String?)
    case move(nodeID: UUID, center: CanvasGeometry.Point)
    case resize(nodeID: UUID, size: CanvasGeometry.Size)
    case setLocked(nodeID: UUID, isLocked: Bool)
    case removeNode(nodeID: UUID)
    case insertConnection(CanvasConnectionSnapshot)
    case removeConnection(connectionID: UUID)
    case setRegionCollapsed(regionID: UUID, isCollapsed: Bool)
    /// Replaces the page's lossless PencilKit drawing bytes (ICQA08: the
    /// original strokes, pressure and styles are preserved — the discrete
    /// `strokes` array is only a derived view). Nil clears the drawing.
    /// Page-level ownership gesture: requires `.wholeDocument` scope, and
    /// the byte count must not exceed
    /// `CanvasPageSnapshot.maxPencilDrawingByteCount`.
    case setPencilDrawingData(Data?)
}

/// Where an edit batch may apply. `.selected` models the host's current
/// selection: any operation touching a node outside the selection is a
/// violation, so an assistant or gesture can never leak past the scope the
/// user sees.
public enum CanvasEditScope: Hashable, Sendable {
    case wholeDocument
    case selectedNodes(Set<UUID>)

    public func allows(nodeID: UUID) -> Bool {
        switch self {
        case .wholeDocument: return true
        case .selectedNodes(let ids): return ids.contains(nodeID)
        }
    }
}

extension CanvasEditScope: Codable {
    /// Deterministic encoding is a hard requirement: the repository digest
    /// (`CanvasBatchDigest`) feeds idempotent replay detection, so a Set's
    /// nondeterministic element order must never leak into the encoded
    /// bytes. Selected node IDs are encoded sorted by UUID string;
    /// operation arrays keep their meaningful order elsewhere.
    private enum CodingKeys: String, CodingKey {
        case kind, nodeIDs
    }

    private enum Kind: String, Codable {
        case wholeDocument, selectedNodes
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try values.decode(Kind.self, forKey: .kind)
        switch kind {
        case .wholeDocument:
            self = .wholeDocument
        case .selectedNodes:
            let ids = try values.decode([UUID].self, forKey: .nodeIDs)
            self = .selectedNodes(Set(ids))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .wholeDocument:
            try values.encode(Kind.wholeDocument, forKey: .kind)
        case .selectedNodes(let ids):
            try values.encode(Kind.selectedNodes, forKey: .kind)
            let sorted = ids.map(\.uuidString).sorted().compactMap(UUID.init(uuidString:))
            try values.encode(sorted, forKey: .nodeIDs)
        }
    }
}

public struct CanvasEditViolation: Codable, Hashable, Sendable {
    public enum Reason: String, Codable, Hashable, Sendable {
        case nodeLocked
        case outsideScope
        case nodeMissing
        case connectionMissing
        case duplicateID
        case danglingConnection
        case regionMissing
        // P0.1 additive reasons (document transactions + trusted-context
        // application). String raw values keep older encoded violations
        // decodable.
        /// A batch claimed a scope the host request never granted (e.g.
        /// `wholeDocument` from a selection-scoped assistant).
        case scopeEscalation
        /// Creation intent was claimed but the host request did not allow it.
        case creationNotGranted
        /// Removal intent was claimed but the host request did not allow it.
        case removalNotGranted
        /// A lock change was claimed; only an explicit host unlock is legal.
        case lockNotGranted
        /// Geometry or visual metadata was not finite/positive/canonically
        /// spelled.
        case invalidGeometry
        /// A structural reference (membership, focus list, page order, flow
        /// source binding) points at an entity that does not exist.
        case invalidReference
        case pageMissing
        case groupMissing
        case sceneMissing
        case strokeMissing
        case flowGraphMissing
        /// A flow-graph replacement did not increase the graph revision.
        case staleFlowGraphRevision
        /// The last remaining page cannot be deleted.
        case lastPageRemaining
        /// A bounded payload (Pencil drawing, asset) exceeded its explicit
        /// byte cap.
        case dataTooLarge
    }

    public var operationIndex: Int
    public var reason: Reason
    public var nodeID: UUID?
    public var connectionID: UUID?
    public var detail: String?

    public init(
        operationIndex: Int,
        reason: Reason,
        nodeID: UUID? = nil,
        connectionID: UUID? = nil,
        detail: String? = nil
    ) {
        self.operationIndex = operationIndex
        self.reason = reason
        self.nodeID = nodeID
        self.connectionID = connectionID
        self.detail = detail
    }
}

public struct CanvasEditBatch: Codable, Hashable, Sendable {
    public var pageID: UUID
    public var scope: CanvasEditScope
    public var operations: [CanvasEditOperation]

    public init(
        pageID: UUID,
        scope: CanvasEditScope = .wholeDocument,
        operations: [CanvasEditOperation]
    ) {
        self.pageID = pageID
        self.scope = scope
        self.operations = operations
    }
}

public struct CanvasEditResult: Hashable, Sendable {
    public var snapshot: CanvasSnapshot
    public var changedNodeIDs: [UUID]
    public var changedConnectionIDs: [UUID]
}

public enum CanvasEditEngine {
    /// Validates then applies. Throws `CanvasKitError.editScopeViolations`
    /// with ALL violations found; on throw the input snapshot is untouched.
    public static func apply(
        _ batch: CanvasEditBatch,
        to snapshot: CanvasSnapshot
    ) throws -> CanvasEditResult {
        guard let pageIndex = snapshot.pages.firstIndex(where: { $0.id == batch.pageID }) else {
            throw CanvasKitError.missingEntity("page \(batch.pageID)")
        }
        var next = snapshot
        var page = next.pages[pageIndex]
        var violations: [CanvasEditViolation] = []
        var changedNodeIDs = Set<UUID>()
        var changedConnectionIDs = Set<UUID>()

        // Duplicate-safe build: a corrupt stored snapshot must surface as a
        // recoverable invalidSnapshot error, never trap the process.
        var nodeByID: [UUID: CanvasNodeSnapshot] = [:]
        var duplicateNodeIDs = Set<UUID>()
        for node in page.nodes {
            if nodeByID[node.id] != nil { duplicateNodeIDs.insert(node.id) }
            nodeByID[node.id] = node
        }
        guard duplicateNodeIDs.isEmpty else {
            let list = duplicateNodeIDs.map(\.uuidString).sorted().joined(separator: ", ")
            throw CanvasKitError.invalidSnapshot(
                "page \(batch.pageID) contains duplicate node IDs: \(list)")
        }

        for (index, operation) in batch.operations.enumerated() {
            switch operation {
            case .insertNode(let node):
                if nodeByID[node.id] != nil {
                    violations.append(.init(
                        operationIndex: index, reason: .duplicateID, nodeID: node.id))
                    continue
                }
                if !batch.scope.allows(nodeID: node.id) {
                    violations.append(.init(
                        operationIndex: index, reason: .outsideScope, nodeID: node.id))
                    continue
                }
                nodeByID[node.id] = node
                changedNodeIDs.insert(node.id)

            case .updateContent(let nodeID, let content):
                guard var node = validatedNode(
                    nodeID: nodeID, operationIndex: index,
                    nodeByID: nodeByID, scope: batch.scope,
                    violations: &violations) else { continue }
                node.content = content
                nodeByID[nodeID] = node
                changedNodeIDs.insert(nodeID)

            case .updateTitle(let nodeID, let title):
                guard var node = validatedNode(
                    nodeID: nodeID, operationIndex: index,
                    nodeByID: nodeByID, scope: batch.scope,
                    violations: &violations) else { continue }
                node.title = title
                nodeByID[nodeID] = node
                changedNodeIDs.insert(nodeID)

            case .move(let nodeID, let center):
                guard var node = validatedNode(
                    nodeID: nodeID, operationIndex: index,
                    nodeByID: nodeByID, scope: batch.scope,
                    violations: &violations) else { continue }
                node.frame.center = center
                nodeByID[nodeID] = node
                changedNodeIDs.insert(nodeID)

            case .resize(let nodeID, let size):
                guard var node = validatedNode(
                    nodeID: nodeID, operationIndex: index,
                    nodeByID: nodeByID, scope: batch.scope,
                    violations: &violations) else { continue }
                node.frame.size = size
                nodeByID[nodeID] = node
                changedNodeIDs.insert(nodeID)

            case .setLocked(let nodeID, let isLocked):
                // Lock/unlock is an ownership gesture: it requires the whole
                // document scope, so a scoped assistant can never lock or
                // unlock what the user did not select.
                guard var node = nodeByID[nodeID] else {
                    violations.append(.init(
                        operationIndex: index, reason: .nodeMissing, nodeID: nodeID))
                    continue
                }
                if case .selectedNodes = batch.scope {
                    violations.append(.init(
                        operationIndex: index, reason: .outsideScope, nodeID: nodeID,
                        detail: "setLocked requires wholeDocument scope"))
                    continue
                }
                node.isLocked = isLocked
                nodeByID[nodeID] = node
                changedNodeIDs.insert(nodeID)

            case .removeNode(let nodeID):
                guard let node = nodeByID[nodeID] else {
                    violations.append(.init(
                        operationIndex: index, reason: .nodeMissing, nodeID: nodeID))
                    continue
                }
                if node.isLocked {
                    violations.append(.init(
                        operationIndex: index, reason: .nodeLocked, nodeID: nodeID))
                    continue
                }
                if !batch.scope.allows(nodeID: nodeID) {
                    violations.append(.init(
                        operationIndex: index, reason: .outsideScope, nodeID: nodeID))
                    continue
                }
                nodeByID[nodeID] = nil
                changedNodeIDs.insert(nodeID)

            case .insertConnection(let connection):
                if page.connections.contains(where: { $0.id == connection.id }) {
                    violations.append(.init(
                        operationIndex: index, reason: .duplicateID,
                        connectionID: connection.id))
                    continue
                }
                guard nodeByID[connection.sourceNodeID] != nil,
                      nodeByID[connection.destinationNodeID] != nil else {
                    violations.append(.init(
                        operationIndex: index, reason: .danglingConnection,
                        connectionID: connection.id))
                    continue
                }
                if !batch.scope.allows(nodeID: connection.sourceNodeID)
                    || !batch.scope.allows(nodeID: connection.destinationNodeID) {
                    violations.append(.init(
                        operationIndex: index, reason: .outsideScope,
                        connectionID: connection.id))
                    continue
                }
                page.connections.append(connection)
                changedConnectionIDs.insert(connection.id)

            case .removeConnection(let connectionID):
                guard let indexInPage = page.connections.firstIndex(where: {
                    $0.id == connectionID
                }) else {
                    violations.append(.init(
                        operationIndex: index, reason: .connectionMissing,
                        connectionID: connectionID))
                    continue
                }
                let connection = page.connections[indexInPage]
                if !batch.scope.allows(nodeID: connection.sourceNodeID)
                    || !batch.scope.allows(nodeID: connection.destinationNodeID) {
                    violations.append(.init(
                        operationIndex: index, reason: .outsideScope,
                        connectionID: connectionID))
                    continue
                }
                page.connections.remove(at: indexInPage)
                changedConnectionIDs.insert(connectionID)

            case .setRegionCollapsed(let regionID, let isCollapsed):
                guard let regionIndex = page.regions.firstIndex(where: {
                    $0.id == regionID
                }) else {
                    violations.append(.init(
                        operationIndex: index, reason: .regionMissing))
                    continue
                }
                page.regions[regionIndex].isCollapsed = isCollapsed

            case .setPencilDrawingData(let data):
                // Page-level ownership gesture, same rule as setLocked: only
                // a whole-document batch may replace the original strokes.
                if case .selectedNodes = batch.scope {
                    violations.append(.init(
                        operationIndex: index, reason: .outsideScope,
                        detail: "setPencilDrawingData requires wholeDocument scope"))
                    continue
                }
                if let data, data.count > CanvasPageSnapshot.maxPencilDrawingByteCount {
                    violations.append(.init(
                        operationIndex: index, reason: .dataTooLarge,
                        detail: "pencil drawing is \(data.count) bytes, limit is "
                            + "\(CanvasPageSnapshot.maxPencilDrawingByteCount)"))
                    continue
                }
                page.pencilDrawingData = data
            }
        }

        guard violations.isEmpty else {
            throw CanvasKitError.editScopeViolations(violations)
        }

        // Remove connections that dangle after node removal, and scrub group
        // membership lists so groups never reference deleted nodes.
        let liveNodeIDs = Set(nodeByID.keys)
        let removedNodeIDs = changedNodeIDs.subtracting(liveNodeIDs)
        if !removedNodeIDs.isEmpty {
            page.connections.removeAll {
                removedNodeIDs.contains($0.sourceNodeID)
                    || removedNodeIDs.contains($0.destinationNodeID)
            }
            for groupIndex in page.groups.indices {
                page.groups[groupIndex].memberNodeIDs.removeAll {
                    removedNodeIDs.contains($0)
                }
            }
        }

        page.nodes = nodeByID.values.sorted { lhs, rhs in
            if lhs.zIndex != rhs.zIndex { return lhs.zIndex < rhs.zIndex }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        // The regionID cache is derived, never save authority: geometry
        // edits (move/resize/insert/remove) recompute it so the stored
        // snapshot stays consistent with actual containment.
        CanvasDocumentEditEngine.recomputeRegionCache(&page)
        next.pages[pageIndex] = page
        return CanvasEditResult(
            snapshot: next,
            changedNodeIDs: changedNodeIDs.sorted { $0.uuidString < $1.uuidString },
            changedConnectionIDs: changedConnectionIDs.sorted {
                $0.uuidString < $1.uuidString
            }
        )
    }

    /// Shared guard: node must exist, be unlocked, and sit inside the batch
    /// scope. Appends the right violation and returns nil on any failure.
    private static func validatedNode(
        nodeID: UUID,
        operationIndex: Int,
        nodeByID: [UUID: CanvasNodeSnapshot],
        scope: CanvasEditScope,
        violations: inout [CanvasEditViolation]
    ) -> CanvasNodeSnapshot? {
        guard let node = nodeByID[nodeID] else {
            violations.append(.init(
                operationIndex: operationIndex, reason: .nodeMissing, nodeID: nodeID))
            return nil
        }
        if node.isLocked {
            violations.append(.init(
                operationIndex: operationIndex, reason: .nodeLocked, nodeID: nodeID))
            return nil
        }
        if !scope.allows(nodeID: nodeID) {
            violations.append(.init(
                operationIndex: operationIndex, reason: .outsideScope, nodeID: nodeID))
            return nil
        }
        return node
    }
}
