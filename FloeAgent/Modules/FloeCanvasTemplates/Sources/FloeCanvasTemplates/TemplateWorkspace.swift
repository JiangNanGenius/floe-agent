import Foundation
import FloeCanvasCore
import FloeCanvasIntegration
import FloeCanvasFlow

public struct TemplateOwnership: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case personal, workspace, task, canvas }
    public var kind: Kind
    public var ownerID: UUID
    public var directoryID: UUID
    public var owningTaskID: UUID?
    public var environmentID: String
    public init(kind: Kind, ownerID: UUID, directoryID: UUID, owningTaskID: UUID? = nil,
                environmentID: String = "") {
        self.kind = kind; self.ownerID = ownerID; self.directoryID = directoryID
        self.owningTaskID = owningTaskID; self.environmentID = environmentID
    }
    public static let metadataKey = "floe.creation.owner"
}

public struct TemplateSession: Hashable, Sendable {
    public let id: UUID
    public let generation: Int
    public let canvasID: UUID
    public let pageID: UUID
    public let revision: Int64
    public let ownership: TemplateOwnership
    public var context: CanvasRuntimeContext {
        .init(canvasID: canvasID, pageID: pageID, revision: revision,
              owningTaskID: ownership.owningTaskID, environmentID: ownership.environmentID)
    }
}

public struct TemplateRegistration: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var templateID: UUID
    public var templateVersion: Int
    public var slots: [TemplateSlot]
    public var recordIDs: [UUID]
    public init(_ instance: CanvasTemplateInstance) {
        id = instance.instanceID; templateID = instance.templateID
        templateVersion = instance.templateVersion; slots = instance.slots; recordIDs = instance.records.map(\.id)
    }
    public static let metadataKey = "floe.template.state"
    public static func read(_ snapshot: CanvasSnapshot) throws -> [Self] {
        guard let raw = snapshot.metadata[metadataKey] else { return [] }
        return try JSONDecoder().decode([Self].self, from: Data(raw.utf8))
    }
    public static func encode(_ values: [Self]) throws -> String {
        String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
    }
}

public protocol TemplateDocumentStore: CanvasDocumentStore {
    func create(canvasID: UUID, snapshot: CanvasSnapshot, requestID: UUID) async throws
}
extension FileCanvasRepository: TemplateDocumentStore {}

public struct TemplateEditorCreateRequest: Hashable, Sendable {
    public let editorKind: String
    public let name: String
    public let context: CanvasRuntimeContext
    public let ownership: TemplateOwnership
    public let requestID: UUID
    public init(editorKind: String, name: String, context: CanvasRuntimeContext,
                ownership: TemplateOwnership, requestID: UUID = UUID()) {
        self.editorKind = editorKind; self.name = name; self.context = context
        self.ownership = ownership; self.requestID = requestID
    }
}

/// The App adapter creates through its EXISTING native editor/document service.
/// It must dedupe requestID, retain completed work on cancellation and use ownership.
public protocol TemplateEditorCreating: Sendable {
    func createEditor(_ request: TemplateEditorCreateRequest) async throws -> CanvasEditorReference
}

public struct TemplateEditorReceipt: Sendable {
    public var reference: CanvasEditorReference
    public var nodeID: UUID?
    public var attached: Bool
    public var recoveryReason: String?
}

public struct TemplateApplicationReceipt: Sendable {
    public var commit: CanvasCommitReceipt
    public var instanceID: UUID
    public var pageID: UUID
}

public struct TemplateDetachReceipt: Sendable {
    /// The file service moves this original; its identity is unchanged.
    public var original: CanvasEditorReference
    /// The canvas keeps this independent copy of the adopted version.
    /// A file move may proceed only when attached is true.
    public var retained: TemplateEditorReceipt
}

public struct TemplateFlowInputRequirement: Sendable {
    public var nodeID: UUID
    public var nodeName: String
    public var portName: String
    public var type: FlowValueType
}

/// Explicit canvas context is independent from the file browser's current selection.
/// This service uses the existing document store for ALL mutations.
public actor CanvasTemplateWorkspace {
    public nonisolated let documents: any TemplateDocumentStore
    public nonisolated let library: CanvasTemplateLibrary
    private let editors: (any CanvasEditorGateway)?
    private let editorCreator: (any TemplateEditorCreating)?
    private let editorForker: (any CanvasEditorForkGateway)?
    private let ownershipResolver: (any TemplateOwnershipResolving)?
    private var generation = 0
    private var activeID: UUID?

    public init(documents: any TemplateDocumentStore, library: CanvasTemplateLibrary,
                editors: (any CanvasEditorGateway)? = nil,
                editorCreator: (any TemplateEditorCreating)? = nil,
                editorForker: (any CanvasEditorForkGateway)? = nil,
                ownershipResolver: (any TemplateOwnershipResolving)? = nil) {
        self.documents = documents; self.library = library; self.editors = editors
        self.editorCreator = editorCreator; self.editorForker = editorForker
        self.ownershipResolver = ownershipResolver
    }

    /// Creating persists content; navigation remains an explicit, fenced host decision.
    public func create(name: String, ownership: TemplateOwnership,
                       template: CanvasTemplate? = nil, inputs: [String: CanvasContent] = [:],
                       canvasID: UUID = UUID(), requestID: UUID = UUID()) async throws -> CanvasSnapshot {
        try Task.checkCancellation()
        var snapshot: CanvasSnapshot
        if let template {
            var instance = try CanvasTemplateEngine.instantiate(template, name: name,
                inputs: inputs, newCanvasID: canvasID)
            try await forkEditors(in: &instance.snapshot, context: .init(canvasID: canvasID,
                pageID: instance.snapshot.selectedPageID, revision: 0,
                owningTaskID: ownership.owningTaskID, environmentID: ownership.environmentID))
            instance.snapshot.metadata[TemplateRegistration.metadataKey] =
                try TemplateRegistration.encode([.init(instance)])
            instance.snapshot.metadata[CreativeRecords.metadataKey] = try CreativeRecords.encode(instance.records)
            snapshot = instance.snapshot
        } else {
            snapshot = .init(id: canvasID, name: name, pages: [.init()])
        }
        snapshot.metadata[TemplateOwnership.metadataKey] = try encoded(ownership)
        try Task.checkCancellation()
        try await documents.create(canvasID: snapshot.id, snapshot: snapshot, requestID: requestID)
        return snapshot
    }

    public func activate(canvasID: UUID, pageID: UUID? = nil) async throws -> TemplateSession {
        generation += 1
        let ticket = generation
        activeID = nil
        let snapshot = try await documents.load(canvasID: canvasID)
        try Task.checkCancellation()
        guard ticket == generation else { throw TemplateError.staleContext }
        let page = pageID ?? snapshot.selectedPageID
        guard snapshot.pages.contains(where: { $0.id == page }) else { throw TemplateError.invalid("page missing") }
        let ownership: TemplateOwnership
        if let ownershipResolver { ownership = try await ownershipResolver.ownership(for: canvasID) }
        else {
            guard let raw = snapshot.metadata[TemplateOwnership.metadataKey] else {
                throw TemplateError.invalid("explicit ownership missing")
            }
            ownership = try JSONDecoder().decode(TemplateOwnership.self, from: Data(raw.utf8))
        }
        guard ticket == generation else { throw TemplateError.staleContext }
        let session = TemplateSession(id: UUID(), generation: generation, canvasID: canvasID,
            pageID: page, revision: snapshot.revision, ownership: ownership)
        activeID = session.id
        return session
    }
    public func deactivate() { generation += 1; activeID = nil }

    public func current(_ session: TemplateSession) -> Bool {
        activeID == session.id && generation == session.generation
    }
    private func check(_ session: TemplateSession) throws {
        try Task.checkCancellation()
        guard current(session) else { throw TemplateError.staleContext }
    }
    private func snapshot(_ session: TemplateSession) async throws -> CanvasSnapshot {
        try check(session)
        let value = try await documents.load(canvasID: session.canvasID)
        try check(session)
        guard value.revision == session.revision else { throw TemplateError.staleContext }
        if let ownershipResolver {
            let owner = try await ownershipResolver.ownership(for: session.canvasID)
            try check(session)
            guard owner == session.ownership else { throw TemplateError.staleContext }
        }
        return value
    }

    /// Call on return using the editor's current owner, not the path used to open it.
    public func returnDestination(for reference: CanvasEditorReference) async throws -> TemplateReturnDestination {
        guard let ownershipResolver else { throw TemplateError.hostUnavailable("current file ownership") }
        return try await .init(currentOwnership: ownershipResolver.ownership(for: reference.projectID))
    }

    /// Adds to the SAME canvas in one CAS/undo unit. It never replaces existing content.
    public func append(_ template: CanvasTemplate, to session: TemplateSession,
                       inputs: [String: CanvasContent] = [:],
                       requestID: UUID = UUID()) async throws -> TemplateApplicationReceipt {
        let current = try await snapshot(session)
        var instance = try CanvasTemplateEngine.instantiate(template, inputs: inputs, newCanvasID: current.id)
        try await forkEditors(in: &instance.snapshot, context: session.context)
        _ = try await snapshot(session)
        guard var first = instance.snapshot.pages.first,
              let target = current.pages.first(where: { $0.id == session.pageID }) else {
            throw TemplateError.invalid("template or destination page missing")
        }
        let oldPageID = first.id
        let needsOwnPage = first.pencilDrawingData != nil
        let destinationID = needsOwnPage ? oldPageID : session.pageID
        for pi in instance.snapshot.pages.indices {
            for gi in instance.snapshot.pages[pi].flowGraphs.indices {
                for fi in instance.snapshot.pages[pi].flowGraphs[gi].nodes.indices {
                    let key = CanvasFlowSourceParameterKey.pageID
                    if instance.snapshot.pages[pi].flowGraphs[gi].nodes[fi].parameters[key]?.stringValue == oldPageID.uuidString {
                        instance.snapshot.pages[pi].flowGraphs[gi].nodes[fi].parameters[key] = .string(destinationID.uuidString)
                    }
                }
            }
        }
        first = instance.snapshot.pages[0]
        var operations: [CanvasDocumentOperation] = []
        if needsOwnPage {
            operations.append(.createPage(first, select: true))
        } else {
            let offset = target.nodes.isEmpty ? 0 : (target.nodes.map(\.frame.maxX).max() ?? 0) + 360
            for i in first.nodes.indices { first.nodes[i].frame.center.x += offset }
            for i in first.flowGraphs.indices {
                for j in first.flowGraphs[i].nodes.indices { first.flowGraphs[i].nodes[j].position.x += offset }
            }
            for i in first.regions.indices { first.regions[i].frame.center.x += offset }
            for i in first.scenes.indices { first.scenes[i].viewportCenter.x += offset }
            for i in first.strokes.indices {
                for j in first.strokes[i].points.indices { first.strokes[i].points[j].x += offset }
            }
            for region in first.regions { operations.append(.createRegion(pageID: destinationID, region: region)) }
            // Group creation sets membership after inserting ordinary nodes.
            var insertions: [CanvasEditOperation] = first.nodes.map {
                var n = $0; n.groupID = nil; return .insertNode(n)
            }
            insertions += first.connections.map(CanvasEditOperation.insertConnection)
            operations.append(.editPage(.init(pageID: destinationID, operations: insertions)))
            for group in first.groups { operations.append(.createGroup(pageID: destinationID, group: group)) }
            for scene in first.scenes { operations.append(.createScene(pageID: destinationID, scene: scene)) }
            for stroke in first.strokes { operations.append(.addStroke(pageID: destinationID, stroke: stroke)) }
        }
        for page in instance.snapshot.pages.dropFirst() { operations.append(.createPage(page, select: false)) }
        // Source validation sees every page/node; card bindings validate at batch end.
        if !needsOwnPage {
            for graph in first.flowGraphs { operations.append(.insertFlowGraph(pageID: destinationID, graph: graph)) }
        }
        var registrations = try TemplateRegistration.read(current)
        registrations.append(.init(instance))
        operations.append(.updateCanvasMetadata(
            values: [TemplateRegistration.metadataKey: try TemplateRegistration.encode(registrations),
                     CreativeRecords.metadataKey: try CreativeRecords.encode(CreativeRecords.read(current) + instance.records)],
            removingKeys: []))
        try check(session)
        let receipt = try await documents.commitDocument(.init(operations: operations),
            canvasID: current.id, expectedRevision: current.revision, requestID: requestID)
        return .init(commit: receipt, instanceID: instance.instanceID, pageID: destinationID)
    }

    public func saveWorkflow(title: TemplateText, category: TemplateCategory,
                             from session: TemplateSession, selectedNodeIDs: Set<UUID>? = nil,
                             policy: TemplateCapturePolicy = .inputsOnly,
                             updating: TemplateLibraryEntry? = nil) async throws -> TemplateLibraryEntry {
        let current = try await snapshot(session)
        var template = try CanvasTemplateEngine.capture(snapshot: current, title: title,
            category: category, selectedNodeIDs: selectedNodeIDs,
            records: try CreativeRecords.read(current), policy: policy)
        if let old = updating {
            template.id = old.latest.id; template.version = old.latest.version + 1
        }
        try check(session)
        return try await library.save(template, expectedRevision: updating?.revision)
    }

    public func bindInput(nodeID: UUID, content: CanvasContent, session: TemplateSession,
                          requestID: UUID = UUID()) async throws -> CanvasCommitReceipt {
        let s = try await snapshot(session)
        guard s.pages.first(where: { $0.id == session.pageID })?.nodes.contains(where: { $0.id == nodeID }) == true else {
            throw TemplateError.invalid("input node belongs to another page")
        }
        return try await documents.commit(.init(pageID: session.pageID,
            operations: [.updateContent(nodeID: nodeID, content: content)]),
            canvasID: s.id, expectedRevision: s.revision, requestID: requestID)
    }

    public func createEditor(kind: String, name: String, session: TemplateSession,
                             requestID: UUID = UUID()) async throws -> TemplateEditorReceipt {
        _ = try await snapshot(session)
        guard let editorCreator else { throw TemplateError.hostUnavailable("editor creation") }
        var childOwnership = session.ownership
        childOwnership.kind = .canvas; childOwnership.ownerID = session.canvasID
        let reference = try await editorCreator.createEditor(.init(editorKind: kind, name: name,
            context: session.context, ownership: childOwnership, requestID: requestID))
        guard reference.editorKind == kind else { throw TemplateError.invalid("host returned another editor kind") }
        guard current(session), !Task.isCancelled else {
            return .init(reference: reference, nodeID: nil, attached: false, recoveryReason: "session changed")
        }
        let node = CanvasNodeSnapshot(id: requestID, title: name, content: .editor(reference),
            frame: .init(center: .zero, size: .init(width: 320, height: 210)))
        do {
            _ = try await snapshot(session)
            _ = try await documents.commit(.init(pageID: session.pageID, operations: [.insertNode(node)]),
                canvasID: session.canvasID, expectedRevision: session.revision, requestID: requestID)
            return .init(reference: reference, nodeID: node.id, attached: true)
        } catch {
            return .init(reference: reference, nodeID: nil, attached: false, recoveryReason: String(describing: error))
        }
    }

    public func openEditor(nodeID: UUID, session: TemplateSession) async throws {
        let s = try await snapshot(session)
        guard let n = s.pages.first(where: { $0.id == session.pageID })?.nodes.first(where: { $0.id == nodeID }),
              case .editor(let reference) = n.content else { throw TemplateError.invalid("not an editable work") }
        guard let editors else { throw TemplateError.hostUnavailable("editor") }
        try check(session)
        try await editors.openEditor(reference, context: session.context)
    }

    public func applyEditor(nodeID: UUID, session: TemplateSession,
                            requestID: UUID = UUID()) async throws -> CanvasCommitReceipt {
        let s = try await snapshot(session)
        guard let n = s.pages.first(where: { $0.id == session.pageID })?.nodes.first(where: { $0.id == nodeID }),
              case .editor(let reference) = n.content else { throw TemplateError.invalid("not an editable work") }
        guard let editors else { throw TemplateError.hostUnavailable("editor") }
        let updated = try await editors.applyEditorResult(reference, context: session.context)
        _ = try await snapshot(session)
        guard updated.projectID == reference.projectID, updated.editorKind == reference.editorKind,
              updated.appliedRevision >= reference.appliedRevision else {
            throw TemplateError.invalid("editor returned an unrelated or older work")
        }
        return try await documents.commit(.init(pageID: session.pageID,
            operations: [.updateContent(nodeID: nodeID, content: .editor(updated))]),
            canvasID: session.canvasID, expectedRevision: session.revision, requestID: requestID)
    }

    /// Internal step of a literal move: keep the adopted version in the canvas,
    /// then let the existing file service move the unchanged original project.
    /// The user does not repair references or handle an extra workflow node.
    public func retainEditorVersionBeforeMove(nodeID: UUID, session: TemplateSession,
                                             requestID: UUID = UUID()) async throws -> TemplateDetachReceipt {
        let snapshot = try await snapshot(session)
        guard let node = snapshot.pages.first(where: { $0.id == session.pageID })?.nodes.first(where: { $0.id == nodeID }),
              case .editor(let original) = node.content else { throw TemplateError.invalid("not an editable work") }
        guard let editorForker else { throw TemplateError.hostUnavailable("retaining adopted editor version") }
        let fork = try await editorForker.forkEditor(.init(reference: original, context: session.context,
            reason: "canvas.move.retain-used-version/" + requestID.uuidString))
        guard fork.original == original, fork.forked.projectID != original.projectID,
              fork.forked.editorKind == original.editorKind else { throw TemplateError.invalid("invalid retained version") }
        do {
            _ = try await self.snapshot(session)
            _ = try await documents.commit(.init(pageID: session.pageID, operations: [
                .updateContent(nodeID: nodeID, content: .editor(fork.forked))
            ]), canvasID: session.canvasID, expectedRevision: session.revision, requestID: requestID)
            return .init(original: original, retained: .init(reference: fork.forked, nodeID: nodeID, attached: true))
        } catch {
            // Keep the actual created project recoverable. The original stays put.
            return .init(original: original, retained: .init(reference: fork.forked, nodeID: nil,
                attached: false, recoveryReason: String(describing: error)))
        }
    }

    public func setPurpose(_ purpose: CreativePurpose?, nodeID: UUID, session: TemplateSession,
                           requestID: UUID = UUID()) async throws -> CanvasCommitReceipt {
        let s = try await snapshot(session)
        guard var node = s.pages.first(where: { $0.id == session.pageID })?.nodes.first(where: { $0.id == nodeID }) else {
            throw TemplateError.invalid("node is outside the active page")
        }
        var records = try CreativeRecords.read(s)
        var operations: [CanvasDocumentOperation] = []
        if let purpose {
            if let id = purpose.recordID, !records.contains(where: { $0.id == id }) {
                throw TemplateError.invalid("record belongs to another canvas")
            }
            let nodeIDs = Set(s.pages.flatMap(\.nodes).map(\.id))
            guard purpose.referenceNodeIDs.allSatisfy(nodeIDs.contains) else {
                throw TemplateError.invalid("reference belongs to another canvas")
            }
            try purpose.apply(to: &node)
            operations.append(.updateNodeMetadata(nodeID: nodeID,
                values: [CreativePurpose.metadataKey: node.metadata[CreativePurpose.metadataKey]!], removingKeys: []))
        } else {
            operations.append(.updateNodeMetadata(nodeID: nodeID, values: [:], removingKeys: [CreativePurpose.metadataKey]))
        }
        for i in records.indices {
            records[i].nodeIDs.removeAll { $0 == nodeID }
            if records[i].id == purpose?.recordID { records[i].nodeIDs.append(nodeID) }
        }
        operations.append(.updateCanvasMetadata(
            values: [CreativeRecords.metadataKey: try CreativeRecords.encode(records)], removingKeys: []))
        return try await documents.commitDocument(.init(operations: operations),
            canvasID: s.id, expectedRevision: s.revision, requestID: requestID)
    }

    /// Works on a blank canvas too; selecting a preset is never required.
    public func upsertRecord(_ record: CreativeRecord, session: TemplateSession,
                             requestID: UUID = UUID()) async throws -> CanvasCommitReceipt {
        let s = try await snapshot(session)
        var records = try CreativeRecords.read(s)
        if let index = records.firstIndex(where: { $0.id == record.id }) { records[index] = record }
        else { records.append(record) }
        try CreativeRecords.validate(records, nodeIDs: Set(s.pages.flatMap(\.nodes).map(\.id)))
        return try await documents.commitDocument(.init(operations: [
            .updateCanvasMetadata(values: [CreativeRecords.metadataKey: try CreativeRecords.encode(records)], removingKeys: [])
        ]), canvasID: s.id, expectedRevision: s.revision, requestID: requestID)
    }

    public func prepareFlow(graphID: UUID, session: TemplateSession) async throws -> (CompiledFlow, [TemplateFlowInputRequirement]) {
        let s = try await snapshot(session)
        guard let graph = s.pages.first(where: { $0.id == session.pageID })?.flowGraphs.first(where: { $0.id == graphID }) else {
            throw TemplateError.invalid("flow belongs to another page")
        }
        let compiled = try FlowGraphCompiler.compile(graph)
        let required = compiled.requiredInputs.flatMap { nodeID, names in
            names.map { name in TemplateFlowInputRequirement(nodeID: nodeID,
                nodeName: compiled.nodes[nodeID]?.name ?? "", portName: name,
                type: compiled.nodes[nodeID]?.ports.first(where: { $0.name == name && $0.direction == .input })?.dataType ?? .json) }
        }
        return (compiled, required)
    }

    /// Actual FlowRuntime executes against the caller's existing service executor.
    public func startFlow(graphID: UUID, session: TemplateSession, runtime: FlowRuntimeService,
                          inputs: [FlowRunInput] = [], configurationDigest: String) async throws -> UUID {
        let (compiled, _) = try await prepareFlow(graphID: graphID, session: session)
        try check(session)
        let configuration = FlowRunConfiguration(identity: .init(canvasID: session.canvasID,
            canvasRevision: session.revision, flowGraphID: graphID, flowGraphRevision: compiled.graph.revision,
            environmentID: session.ownership.environmentID, owningTaskID: session.ownership.owningTaskID),
            pageID: session.pageID, runInputs: inputs, configurationDigest: configurationDigest)
        return try await runtime.startRun(compiled: compiled, configuration: configuration)
    }

    /// Completes runtime -> visible nodes -> persisted document through one CAS.
    /// A newer canvas or another owner never receives a late result. The runtime
    /// retains unapplied results, so a failed commit does not destroy user work.
    public func applyRunResult(_ result: FlowRunResult, session: TemplateSession,
                               disposition: CanvasResultDisposition = .branch,
                               requestID: UUID = UUID(),
                               project: @Sendable (FlowValue) throws -> CanvasContent = TemplateResultProjection.content)
        async throws -> CanvasCommitReceipt {
        let snapshot = try await snapshot(session)
        guard !result.stale, result.terminalStatus == .completed,
              result.identity.canvasID == session.canvasID,
              result.identity.canvasRevision == session.revision,
              result.identity.environmentID == session.ownership.environmentID,
              result.identity.owningTaskID == session.ownership.owningTaskID,
              let page = snapshot.pages.first(where: { $0.id == session.pageID }),
              let graph = page.flowGraphs.first(where: { $0.id == result.identity.flowGraphID }),
              graph.revision == result.identity.flowGraphRevision else { throw TemplateError.staleContext }
        var operations: [CanvasEditOperation] = []
        for card in page.nodes {
            guard let binding = CanvasFlowCardBinding(metadata: card.metadata), binding.graphID == graph.id,
                  let outputs = result.nodeOutputs[binding.nodeID] else { continue }
            if disposition == .replace {
                guard outputs.count == 1, let value = outputs.values.first else {
                    throw TemplateError.invalid("replacing a card requires one output")
                }
                operations.append(.updateContent(nodeID: card.id, content: try project(value)))
            } else {
                for (index, entry) in outputs.sorted(by: { $0.key < $1.key }).enumerated() {
                    var frame = card.frame
                    frame.center.y += Double(index + 1) * (frame.size.height + 40)
                    let output = CanvasNodeSnapshot(title: card.title, content: try project(entry.value), frame: frame,
                        createdByRunID: result.identity.runID,
                        metadata: ["floe.template.output.port": entry.key,
                                   "floe.template.output.flowNode": binding.nodeID.uuidString])
                    operations.append(.insertNode(output))
                    operations.append(.insertConnection(.init(sourceNodeID: card.id,
                        destinationNodeID: output.id, kind: .generatedFrom)))
                }
            }
        }
        guard !operations.isEmpty else { throw TemplateError.invalid("no bound outputs to apply") }
        try check(session)
        return try await documents.commit(.init(pageID: session.pageID, operations: operations),
            canvasID: session.canvasID, expectedRevision: session.revision, requestID: requestID)
    }

    private func forkEditors(in snapshot: inout CanvasSnapshot, context: CanvasRuntimeContext) async throws {
        var forks: [UUID: CanvasEditorReference] = [:]
        for pi in snapshot.pages.indices {
            for ni in snapshot.pages[pi].nodes.indices {
                guard case .editor(let reference) = snapshot.pages[pi].nodes[ni].content else { continue }
                if let existing = forks[reference.projectID] {
                    snapshot.pages[pi].nodes[ni].content = .editor(existing); continue
                }
                guard let editorForker else { throw TemplateError.hostUnavailable("mutable child-project fork") }
                var pageContext = context; pageContext.pageID = snapshot.pages[pi].id
                try Task.checkCancellation()
                let fork = try await editorForker.forkEditor(.init(reference: reference, context: pageContext,
                    reason: "canvas.template.instantiate"))
                guard fork.original == reference, fork.forked.projectID != reference.projectID,
                      fork.forked.editorKind == reference.editorKind else {
                    throw TemplateError.invalid("host did not create an independent child project")
                }
                try Task.checkCancellation()
                forks[reference.projectID] = fork.forked
                snapshot.pages[pi].nodes[ni].content = .editor(fork.forked)
            }
        }
    }

    private func encoded<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
}

/// Real source resolution from the authoritative snapshot at the frozen run revision.
public struct TemplateCanvasBindingResolver: FlowCanvasBindingResolver {
    private let documents: any CanvasDocumentStore
    public init(documents: any CanvasDocumentStore) { self.documents = documents }
    public func resolve(canvasBinding key: String, context: CanvasRuntimeContext) async throws -> FlowValue {
        guard key.hasPrefix(CanvasTemplateEngine.sourcePrefix),
              let id = UUID(uuidString: String(key.dropFirst(CanvasTemplateEngine.sourcePrefix.count))) else {
            throw TemplateError.invalid("unsupported canvas binding")
        }
        let s = try await documents.load(canvasID: context.canvasID)
        guard s.revision == context.revision else { throw TemplateError.staleContext }
        guard let n = s.pages.flatMap(\.nodes).first(where: { $0.id == id }) else {
            throw TemplateError.invalid("source node is outside the run canvas")
        }
        if n.metadata["floe.template.required"] == "true",
           !CanvasTemplateInstance.hasContent(nodeID: id, in: s) { throw TemplateError.missingInput(n.title ?? id.uuidString) }
        return .json(try JSONFidelity.parse(JSONEncoder().encode(n.content)))
    }
}

/// Checks the typed operation, then forwards to the SAME production step executor.
/// It adds no provider, credential store, permission system or retry loop.
public struct TemplateStepExecutorAdapter: CanvasStepExecutor {
    private let upstream: any CanvasStepExecutor
    public init(upstream: any CanvasStepExecutor) { self.upstream = upstream }
    public func submitStep(_ request: CanvasStepExecutionRequest) async throws -> CanvasStepQueryResult {
        guard let raw = request.node.parameters[TemplateOperation.parameterKey]?.stringValue,
              TemplateOperation(rawValue: raw) != nil else { throw TemplateError.hostUnavailable("unknown template operation") }
        return try await upstream.submitStep(request)
    }
    public func queryStep(attemptID: UUID, runID: UUID) async throws -> CanvasStepQueryResult {
        try await upstream.queryStep(attemptID: attemptID, runID: runID)
    }
    public func queryRun(runID: UUID) async throws -> FlowRunCheckpoint { try await upstream.queryRun(runID: runID) }
    public func cancelRun(runID: UUID) async throws { try await upstream.cancelRun(runID: runID) }
}
