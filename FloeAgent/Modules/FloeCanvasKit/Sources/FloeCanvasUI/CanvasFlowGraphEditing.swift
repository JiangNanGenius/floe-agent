import Foundation
import FloeCanvasCore

/// Metadata binding for cards created from a run's placed outputs. The
/// board draws a distinct badge for these so run-produced cards are
/// recognizable against ordinary content; the run record stays the state
/// authority (ICH07–09).
public struct CanvasRunOutputStateBadge: Hashable, Sendable {
    public static let metadataKey = "floe.canvas.runOutputBadge"
    public var runID: UUID

    public init(runID: UUID) {
        self.runID = runID
    }

    public init?(metadata: [String: String]) {
        guard let raw = metadata[Self.metadataKey],
              let runID = UUID(uuidString: raw) else { return nil }
        self.runID = runID
    }

    public func applied(to metadata: inout [String: String]) {
        metadata[Self.metadataKey] = runID.uuidString
    }
}

/// Typed-port validation used while dragging flow edges (UI_BRIEF: port
/// dragging validates types). The Flow compiler remains the execution
/// authority; this only stops visibly-invalid drops from committing.
public enum CanvasFlowPortValidator {
    public enum Verdict: Hashable, Sendable {
        case valid
        case directionMismatch
        case typeMismatch(FlowValueType, FlowValueType)
    }

    public static func validate(
        source: FlowPort,
        destination: FlowPort
    ) -> Verdict {
        guard source.direction == .output, destination.direction == .input else {
            return .directionMismatch
        }
        if source.isVariadic && !destination.isVariadic {
            return destination.dataType == .list || destination.dataType == .json
                ? .valid : .typeMismatch(source.dataType, destination.dataType)
        }
        if source.dataType == destination.dataType { return .valid }
        if source.dataType == .json || destination.dataType == .json { return .valid }
        return .typeMismatch(source.dataType, destination.dataType)
    }
}

/// Flow graph ⇄ canvas card batch construction.
///
/// Binding model (Core, frozen): a flow step is an ordinary
/// `CanvasNodeSnapshot(kind: .generationTask)` whose metadata carries
/// `CanvasFlowCardBinding` (`floe.flow.graphID` / `floe.flow.nodeID`).
/// Canvas node IDs and flow node IDs are independent; the binding is the
/// only link. Every structural change to a step (create/delete/duplicate)
/// touches graph + card + edges in ONE document batch.
public enum CanvasFlowGraphEditing {
    /// Applies a complete professional definition and its visual bindings
    /// in one transaction. Existing card identities/layout survive; added
    /// steps receive cards and removed steps lose their bound cards.
    public static func replaceDefinitionBatch(
        snapshot: CanvasSnapshot, pageID: UUID, definition: FlowGraph
    ) throws -> CanvasDocumentBatch {
        guard let page = snapshot.pages.first(where: { $0.id == pageID }),
              let original = page.flowGraphs.first(where: { $0.id == definition.id }) else {
            throw CanvasKitError.missingEntity("flow definition")
        }
        guard original.revision < Int64.max else {
            throw CanvasKitError.invalidSnapshot("flow revision exhausted")
        }
        var graph = definition
        graph.revision = original.revision + 1
        let oldIDs = Set(original.nodes.map(\.id))
        let originalNames = Dictionary(original.nodes.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let newIDs = Set(graph.nodes.map(\.id))
        var definitions: [UUID: FlowNode] = [:]
        for step in graph.nodes {
            guard definitions.updateValue(step, forKey: step.id) == nil else {
                throw CanvasKitError.invalidSnapshot("duplicate flow node identity")
            }
        }
        var edits: [CanvasEditOperation] = []
        for card in page.nodes {
            guard let binding = CanvasFlowCardBinding(metadata: card.metadata),
                  binding.graphID == graph.id else { continue }
            if !newIDs.contains(binding.nodeID) {
                edits.append(.removeNode(nodeID: card.id))
            } else if let step = definitions[binding.nodeID],
                      let previousName = originalNames[binding.nodeID],
                      previousName != step.name, card.title == previousName {
                edits.append(.updateTitle(nodeID: card.id, title: step.name))
                if case .shape(let kind, let text) = card.content, text == previousName {
                    edits.append(.updateContent(nodeID: card.id, content: .shape(kind: kind, text: step.name)))
                }
            }
        }
        let right = page.nodes.map { $0.frame.center.x + $0.frame.size.width / 2 }.max() ?? 0
        for (index, step) in graph.nodes.filter({ !oldIDs.contains($0.id) }).enumerated() {
            var metadata: [String: String] = [:]
            CanvasFlowCardBinding(graphID: graph.id, nodeID: step.id).applied(to: &metadata)
            let center = step.position == .zero
                ? CanvasGeometry.Point(x: right + 180 + Double(index % 4) * 280,
                                       y: Double(index / 4) * 180)
                : step.position
            edits.append(.insertNode(.init(kind: .generationTask, title: step.name,
                content: .shape(kind: .roundedRectangle, text: step.name),
                frame: .init(center: center, size: .init(width: 240, height: 140)),
                metadata: metadata)))
        }
        var operations: [CanvasDocumentOperation] = []
        if !edits.isEmpty {
            operations.append(.editPage(.init(pageID: pageID, scope: .wholeDocument, operations: edits)))
        }
        operations.append(.replaceFlowGraph(graph: graph))
        let batch = CanvasDocumentBatch(scope: .wholeDocument, operations: operations)
        _ = try CanvasDocumentEditEngine.apply(batch, to: snapshot)
        return batch
    }

    /// Default declared ports for a new step of `kind`.
    public static func defaultPorts(for kind: FlowNodeKind) -> [FlowPort] {
        func port(
            _ name: String,
            _ direction: FlowPortDirection,
            _ type: FlowValueType = .json
        ) -> FlowPort {
            FlowPort(name: name, dataType: type, direction: direction)
        }
        switch kind {
        case .source:
            return [port("out", .output)]
        case .transform:
            return [port("in", .input), port("out", .output)]
        case .condition:
            // Branch output ports are appended per branch at creation time.
            return [port("in", .input)]
        case .loop:
            return [port("in", .input), port("out", .output)]
        case .batch:
            return [
                port("items", .input, .list),
                port("out", .output, .json),
            ]
        case .subgraph:
            return [port("in", .input), port("out", .output)]
        case .customScript, .customAPI:
            return [port("in", .input), port("out", .output)]
        case .output:
            return [port("in", .input)]
        }
    }

    /// Creates a flow step and its bound visual card in one document batch.
    public static func insertStepBatch(
        snapshot: CanvasSnapshot,
        pageID: UUID,
        kind: FlowNodeKind,
        name: String,
        at position: CanvasGeometry.Point,
        cardSize: CanvasGeometry.Size
    ) throws -> CanvasDocumentBatch {
        guard let page = snapshot.pages.first(where: { $0.id == pageID }) else {
            throw CanvasKitError.missingEntity("page \(pageID)")
        }
        let graphID = page.flowGraphs.first?.id ?? UUID()
        var ports = defaultPorts(for: kind)
        var branches: [FlowConditionBranch]? = nil
        if kind == .condition {
            let branchPort = FlowPort(
                name: "branch", dataType: .json, direction: .output)
            ports.append(branchPort)
            branches = [FlowConditionBranch(
                predicate: .comparison(.equal, lhs: .literal(.bool(true)), rhs: .literal(.bool(true))),
                outputPortID: branchPort.id)]
        }
        let node = FlowNode(
            kind: kind,
            name: name,
            ports: ports,
            branches: branches,
            position: position)
        var operations: [CanvasDocumentOperation] = []
        if let existing = page.flowGraphs.first {
            var graph = existing
            graph.revision += 1
            graph.nodes.append(node)
            operations.append(.replaceFlowGraph(graph: graph))
        } else {
            let graph = FlowGraph(
                id: graphID,
                revision: 0,
                nodes: [node],
                edges: [],
                variables: [])
            operations.append(.insertFlowGraph(pageID: pageID, graph: graph))
        }
        var metadata: [String: String] = [:]
        CanvasFlowCardBinding(graphID: graphID, nodeID: node.id)
            .applied(to: &metadata)
        let card = CanvasNodeSnapshot(
            kind: .generationTask,
            title: name,
            content: .shape(kind: .roundedRectangle, text: name),
            frame: .init(center: position, size: cardSize),
            metadata: metadata)
        operations.append(.editPage(.init(
            pageID: pageID,
            scope: .wholeDocument,
            operations: [.insertNode(card)])))
        return CanvasDocumentBatch(scope: .wholeDocument, operations: operations)
    }

    /// Adds one typed execution edge inside the graph that owns both nodes.
    public static func connectPortsBatch(
        snapshot: CanvasSnapshot,
        pageID: UUID,
        sourceNodeID: UUID,
        sourcePortID: UUID,
        destinationNodeID: UUID,
        destinationPortID: UUID
    ) throws -> CanvasDocumentBatch {
        guard let page = snapshot.pages.first(where: { $0.id == pageID }) else {
            throw CanvasKitError.missingEntity("page \(pageID)")
        }
        guard let graphIndex = page.flowGraphs.firstIndex(where: { graph in
            graph.nodes.contains(where: { $0.id == sourceNodeID })
                && graph.nodes.contains(where: { $0.id == destinationNodeID })
        }) else {
            throw CanvasKitError.invalidFlowGraph([
                CanvasFlowIssue(
                    severity: .error,
                    code: .danglingEdge,
                    detail: "Ports belong to different graphs")
            ])
        }
        var graph = page.flowGraphs[graphIndex]
        guard let sourceNode = graph.nodes.first(where: { $0.id == sourceNodeID }),
              let destinationNode = graph.nodes.first(where: { $0.id == destinationNodeID }),
              let sourcePort = sourceNode.ports.first(where: { $0.id == sourcePortID }),
              let destinationPort = destinationNode.ports.first(where: { $0.id == destinationPortID }) else {
            throw CanvasKitError.invalidFlowGraph([
                CanvasFlowIssue(
                    severity: .error,
                    code: .danglingEdge,
                    detail: "Port not found")
            ])
        }
        switch CanvasFlowPortValidator.validate(source: sourcePort, destination: destinationPort) {
        case .valid:
            break
        case .directionMismatch:
            throw CanvasKitError.invalidFlowGraph([
                CanvasFlowIssue(
                    severity: .error,
                    code: .portDirectionMismatch,
                    detail: "Edge must leave an output port and enter an input port")
            ])
        case .typeMismatch(let lhs, let rhs):
            throw CanvasKitError.invalidFlowGraph([
                CanvasFlowIssue(
                    severity: .error,
                    code: .portTypeMismatch,
                    detail: "\(lhs.rawValue) → \(rhs.rawValue)")
            ])
        }
        graph.revision += 1
        graph.edges.append(FlowEdge(
            sourceNodeID: sourceNodeID,
            sourcePortID: sourcePortID,
            destinationNodeID: destinationNodeID,
            destinationPortID: destinationPortID))
        return CanvasDocumentBatch(scope: .wholeDocument, operations: [
            .replaceFlowGraph(graph: graph)
        ])
    }

    /// Replaces one flow node (inspector edits). Edges whose ports disappear
    /// are pruned so legitimate edits cannot dangle; deep semantics stay
    /// with `FlowGraphValidator` at commit time.
    public static func updateNodeBatch(
        snapshot: CanvasSnapshot,
        pageID: UUID,
        node: FlowNode
    ) throws -> CanvasDocumentBatch {
        guard let page = snapshot.pages.first(where: { $0.id == pageID }),
              let graphIndex = page.flowGraphs.firstIndex(where: {
                  $0.nodes.contains(where: { $0.id == node.id })
              }) else {
            throw CanvasKitError.missingEntity("flow node \(node.id)")
        }
        var graph = page.flowGraphs[graphIndex]
        graph.revision += 1
        graph.nodes = graph.nodes.map { $0.id == node.id ? node : $0 }
        let portIDs = Set(node.ports.map(\.id))
        graph.edges.removeAll { edge in
            (edge.sourceNodeID == node.id && !portIDs.contains(edge.sourcePortID))
                || (edge.destinationNodeID == node.id
                    && !portIDs.contains(edge.destinationPortID))
        }
        return CanvasDocumentBatch(scope: .wholeDocument, operations: [
            .replaceFlowGraph(graph: graph)
        ])
    }

    /// Deletes one flow step completely: bound card node + flow node +
    /// incident typed edges + node-scoped variables, in one batch. The
    /// execution node can never reappear as an unbound fallback because its
    /// definition leaves the document in the same batch as the card.
    public static func deleteFlowCardBatch(
        snapshot: CanvasSnapshot,
        pageID: UUID,
        cardNodeID: UUID
    ) throws -> CanvasDocumentBatch {
        try deleteNodesBatch(snapshot: snapshot, pageID: pageID, nodeIDs: [cardNodeID])
    }

    /// Deletes an arbitrary selection, unbinding flow cards first so no
    /// orphaned flow definitions survive (multi-selection delete is one
    /// batch; graph updates precede node removal in the same batch).
    public static func deleteNodesBatch(
        snapshot: CanvasSnapshot,
        pageID: UUID,
        nodeIDs: Set<UUID>
    ) throws -> CanvasDocumentBatch {
        guard let page = snapshot.pages.first(where: { $0.id == pageID }) else {
            throw CanvasKitError.missingEntity("page \(pageID)")
        }
        var operations: [CanvasDocumentOperation] = []
        var graphEdits: [UUID: FlowGraph] = [:]
        var removedFlowNodeIDs: [UUID: Set<UUID>] = [:]

        for nodeID in nodeIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let node = page.nodes.first(where: { $0.id == nodeID }),
                  let binding = CanvasFlowCardBinding(metadata: node.metadata) else {
                continue
            }
            guard let graph = (graphEdits[binding.graphID]
                ?? page.flowGraphs.first(where: { $0.id == binding.graphID })) else {
                continue
            }
            var edited = graph
            edited.revision += 1
            edited.nodes.removeAll { $0.id == binding.nodeID }
            edited.edges.removeAll {
                $0.sourceNodeID == binding.nodeID
                    || $0.destinationNodeID == binding.nodeID
            }
            edited.variables.removeAll { $0.ownerNodeID == binding.nodeID }
            graphEdits[binding.graphID] = edited
            removedFlowNodeIDs[binding.graphID, default: []].insert(binding.nodeID)
        }
        for (graphID, edited) in graphEdits.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            if edited.nodes.isEmpty {
                operations.append(.removeFlowGraph(graphID: graphID))
            } else {
                operations.append(.replaceFlowGraph(graph: edited))
            }
        }
        let removals = nodeIDs.sorted(by: { $0.uuidString < $1.uuidString })
            .map { CanvasEditOperation.removeNode(nodeID: $0) }
        if !removals.isEmpty {
            operations.append(.editPage(.init(
                pageID: pageID,
                scope: .wholeDocument,
                operations: removals)))
        }
        return CanvasDocumentBatch(scope: .wholeDocument, operations: operations)
    }
}

/// Pure, deterministic mapping of real run-output values onto native
/// editable card content. No runtime and no store state: the same value
/// tree always yields the same cards, so commit retries, lost-ack replays
/// and same-run dedupe stay stable.
public enum CanvasRunOutputPlacement {
    /// Resource bounds for batch (`.list`) materialization. Exceeding any
    /// bound is an explicit, recoverable error: the runtime result is kept
    /// intact and the caller surfaces an actionable alert — batch data is
    /// never truncated or silently dropped.
    public struct Limits: Hashable, Sendable {
        public var maxListDepth: Int
        public var maxListJSONByteCount: Int
        public var maxListAssetCards: Int

        public init(
            maxListDepth: Int = 64,
            maxListJSONByteCount: Int = 512 * 1024,
            maxListAssetCards: Int = 64
        ) {
            self.maxListDepth = maxListDepth
            self.maxListJSONByteCount = maxListJSONByteCount
            self.maxListAssetCards = maxListAssetCards
        }
    }

    public struct MappingError: Error, Hashable, Sendable {
        public enum Code: String, Hashable, Sendable {
            case listTooDeep
            case listTooLarge
            case tooManyAssetCards
        }
        public var code: Code
        public var detail: String
    }

    /// One typed asset leaf inside a batch, with its deterministic
    /// JSON-style path (e.g. `[2].report`). Paths are structural — derived
    /// from the list itself, never scanned from opaque text.
    public struct AssetLeaf: Hashable, Sendable {
        public var path: String
        public var locator: CanvasAssetLocator
    }

    public struct PreparedBatch: Hashable, Sendable {
        /// Primary card content: the WHOLE batch serialized as valid,
        /// high-fidelity JSON (exact Unicode/escaping, exact number
        /// literals — never an Int64(Double) re-typing).
        public var content: CanvasContent
        /// Typed asset leaves to materialize as additional media cards so
        /// the native archive's typed asset collection embeds real bytes.
        public var assetLeaves: [AssetLeaf]
    }

    /// Maps one non-batch output value to native editable content.
    /// `nil` = honestly unsupported (never a lossy projection).
    public static func content(for value: FlowValue) -> CanvasContent? {
        switch value {
        case .string(let string):
            return .text(string)
        case .number(let number):
            if number == number.rounded()
                && abs(number) < 9_007_199_254_740_992 {
                return .text(String(Int64(number)))
            }
            return .text(String(number))
        case .bool(let value):
            return .text(value ? "true" : "false")
        case .table(let header, let rows):
            return .table(header: header, rows: rows)
        case .asset(let locator):
            return .media(locator)
        case .json(let json):
            guard let data = try? JSONFidelity.serialize(
                json,
                options: .init(sortedKeys: true, prettyPrinted: true)),
                  let source = String(data: data, encoding: .utf8) else {
                return nil
            }
            return .code(language: "json", source: source)
        case .list:
            return nil
        }
    }

    /// Maps a batch (`.list`) output: one full-list JSON card plus one
    /// media card per typed asset leaf. Throws `MappingError` on bound
    /// violations — recoverable, with the runtime result untouched.
    public static func prepareBatch(
        _ values: [FlowValue],
        limits: Limits = Limits()
    ) throws -> PreparedBatch {
        let json = try jsonValue(from: .list(values), depth: 1, limits: limits)
        var leaves: [AssetLeaf] = []
        try collectAssetLeaves(in: .list(values), path: "", depth: 1, limits: limits, into: &leaves)
        let data = try JSONFidelity.serialize(
            json,
            options: .init(sortedKeys: true, prettyPrinted: true))
        guard data.count <= limits.maxListJSONByteCount else {
            throw MappingError(
                code: .listTooLarge,
                detail: "batch JSON is \(data.count) bytes, exceeding the \(limits.maxListJSONByteCount) byte limit")
        }
        guard let source = String(data: data, encoding: .utf8) else {
            throw MappingError(code: .listTooLarge, detail: "batch JSON is not valid UTF-8")
        }
        return PreparedBatch(
            content: .code(language: "json", source: source),
            assetLeaves: leaves)
    }

    // MARK: - Value → JSON tree (bounded)

    private static func jsonValue(
        from value: FlowValue,
        depth: Int,
        limits: Limits
    ) throws -> JSONValue {
        guard depth <= limits.maxListDepth else {
            throw MappingError(
                code: .listTooDeep,
                detail: "batch nesting exceeds the depth limit of \(limits.maxListDepth)")
        }
        switch value {
        case .string(let string):
            return .string(string)
        case .number(let number):
            return .number(numberLiteral(number))
        case .bool(let bool):
            return .bool(bool)
        case .list(let items):
            return .array(try items.map {
                try jsonValue(from: $0, depth: depth + 1, limits: limits)
            })
        case .table(let header, let rows):
            return .object([
                "header": .array(header.map { .string($0) }),
                "rows": .array(rows.map { row in
                    .array(row.map { .string($0) })
                }),
            ])
        case .asset(let locator):
            return assetJSON(locator)
        case .json(let json):
            return json
        }
    }

    /// Exact numeric literal for JSON emission: integral values inside the
    /// Int64-safe range keep their plain spelling; everything else keeps the
    /// Double's shortest round-trip spelling (never `Int64(double)`, which
    /// overflows/collapses beyond 2^53). Non-finite values are preserved as
    /// strings so the JSON document stays valid.
    private static func numberLiteral(_ value: Double) -> String {
        guard value.isFinite else { return String(value) }
        if value == value.rounded(), abs(value) < 9_007_199_254_740_992 {
            return String(Int64(value))
        }
        return String(value)
    }

    /// Deterministic structured identity of a typed asset inside the
    /// full-list JSON (the archive collects real bytes from the media
    /// cards, never by scanning this text).
    private static func assetJSON(_ locator: CanvasAssetLocator) -> JSONValue {
        var object: [String: JSONValue] = ["id": .string(locator.id.uuidString)]
        if let contentHash = locator.contentHash {
            object["contentHash"] = .string(contentHash)
        }
        if let relativePath = locator.relativePath {
            object["relativePath"] = .string(relativePath)
        }
        if let mimeType = locator.mimeType {
            object["mimeType"] = .string(mimeType)
        }
        if let byteCount = locator.byteCount {
            object["byteCount"] = .number("\(byteCount)")
        }
        if let sourceURL = locator.sourceURL {
            object["sourceURL"] = .string(sourceURL.absoluteString)
        }
        if let license = locator.license {
            object["license"] = .string(license)
        }
        return .object(object)
    }

    // MARK: - Typed asset leaves (bounded, deterministic order)

    private static func collectAssetLeaves(
        in value: FlowValue,
        path: String,
        depth: Int,
        limits: Limits,
        into leaves: inout [AssetLeaf]
    ) throws {
        guard depth <= limits.maxListDepth else {
            throw MappingError(
                code: .listTooDeep,
                detail: "batch nesting exceeds the depth limit of \(limits.maxListDepth)")
        }
        switch value {
        case .asset(let locator):
            leaves.append(AssetLeaf(path: path, locator: locator))
            guard leaves.count <= limits.maxListAssetCards else {
                throw MappingError(
                    code: .tooManyAssetCards,
                    detail: "batch contains more than \(limits.maxListAssetCards) typed assets")
            }
        case .list(let items):
            for (index, item) in items.enumerated() {
                try collectAssetLeaves(
                    in: item,
                    path: "\(path)[\(index)]",
                    depth: depth + 1,
                    limits: limits,
                    into: &leaves)
            }
        case .string, .number, .bool, .table, .json:
            break
        }
    }
}
