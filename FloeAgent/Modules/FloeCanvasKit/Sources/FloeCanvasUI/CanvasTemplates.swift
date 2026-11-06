import Foundation
import FloeCanvasCore
import FloeCanvasIntegration

/// New-scene templates (UI_BRIEF: Research / Compare proposals / Blank, plus
/// a deterministic lab sample that never claims model authorship).
public enum CanvasSceneTemplate: String, CaseIterable, Codable, Hashable, Sendable {
    case research
    case compare
    case blank
    case lab
}

/// Editable first-draft content for a new page. Everything here is ordinary
/// canvas content: the generated template is fully editable after creation.
public struct CanvasTemplateContent: Sendable {
    public var pageName: String
    public var nodes: [CanvasNodeSnapshot]
    public var connections: [CanvasConnectionSnapshot]
    public var flowGraph: FlowGraph?
    /// True only for the deterministic lab sample; surfaced in UI copy.
    public var isDeterministicLabSample: Bool

    public init(
        pageName: String,
        nodes: [CanvasNodeSnapshot] = [],
        connections: [CanvasConnectionSnapshot] = [],
        flowGraph: FlowGraph? = nil,
        isDeterministicLabSample: Bool = false
    ) {
        self.pageName = pageName
        self.nodes = nodes
        self.connections = connections
        self.flowGraph = flowGraph
        self.isDeterministicLabSample = isDeterministicLabSample
    }
}

public enum CanvasTemplateFactory {
    public static func make(
        _ template: CanvasSceneTemplate,
        name: String,
        configuration: CanvasEditorConfiguration
    ) -> CanvasTemplateContent {
        switch template {
        case .blank:
            return CanvasTemplateContent(pageName: name)
        case .research:
            return research(name: name, configuration: configuration)
        case .compare:
            return compare(name: name, configuration: configuration)
        case .lab:
            return lab(name: name, configuration: configuration)
        }
    }

    private static func textNode(
        _ title: String,
        _ content: CanvasContent,
        center: CanvasGeometry.Point,
        size: CanvasGeometry.Size,
        kind: CanvasNodeKind = .content
    ) -> CanvasNodeSnapshot {
        CanvasNodeSnapshot(
            kind: kind,
            title: title,
            content: content,
            frame: .init(center: center, size: size))
    }

    private static func research(
        name: String,
        configuration: CanvasEditorConfiguration
    ) -> CanvasTemplateContent {
        let size = configuration.defaultNodeSize
        let brief = textNode(
            "Research Brief",
            .markdown(document: "## Question\n\nWhat do we want to learn?", previewText: nil),
            center: .init(x: 0, y: 0),
            size: .init(width: 320, height: 200))
        var source1 = textNode(
            "Source A",
            .text(""),
            center: .init(x: -340, y: -40),
            size: size,
            kind: .sourced)
        source1.source = CanvasSourceReference(sourceID: UUID(), usedRevision: 0, annotations: [])
        var source2 = textNode(
            "Source B",
            .text(""),
            center: .init(x: -340, y: 220),
            size: size,
            kind: .sourced)
        source2.source = CanvasSourceReference(sourceID: UUID(), usedRevision: 0, annotations: [])
        let notes = textNode(
            "Notes",
            .richText(document: CanvasRichTextDocument(runs: [
                CanvasRichTextRun(text: "Findings"),
            ])),
            center: .init(x: 330, y: 40),
            size: size)
        let nodes = [brief, source1, source2, notes]
        let connections = [
            CanvasConnectionSnapshot(
                sourceNodeID: source1.id,
                destinationNodeID: brief.id,
                kind: .source),
            CanvasConnectionSnapshot(
                sourceNodeID: source2.id,
                destinationNodeID: brief.id,
                kind: .source),
            CanvasConnectionSnapshot(
                sourceNodeID: brief.id,
                destinationNodeID: notes.id,
                kind: .arrow),
        ]
        return CanvasTemplateContent(
            pageName: name,
            nodes: nodes,
            connections: connections)
    }

    private static func compare(
        name: String,
        configuration: CanvasEditorConfiguration
    ) -> CanvasTemplateContent {
        let size = configuration.defaultNodeSize
        let original = textNode(
            "Original",
            .text(""),
            center: .init(x: -320, y: 0),
            size: size)
        let optionA = textNode(
            "Proposal A",
            .richText(document: CanvasRichTextDocument(runs: [
                CanvasRichTextRun(text: "Variant A"),
            ])),
            center: .init(x: 300, y: -140),
            size: size)
        let optionB = textNode(
            "Proposal B",
            .richText(document: CanvasRichTextDocument(runs: [
                CanvasRichTextRun(text: "Variant B"),
            ])),
            center: .init(x: 300, y: 140),
            size: size)
        let connections = [
            CanvasConnectionSnapshot(
                sourceNodeID: original.id,
                destinationNodeID: optionA.id,
                kind: .generatedFrom),
            CanvasConnectionSnapshot(
                sourceNodeID: original.id,
                destinationNodeID: optionB.id,
                kind: .generatedFrom),
        ]
        return CanvasTemplateContent(
            pageName: name,
            nodes: [original, optionA, optionB],
            connections: connections)
    }

    private static func lab(
        name: String,
        configuration: CanvasEditorConfiguration
    ) -> CanvasTemplateContent {
        // Deterministic, model-free sample (ICH12 small scenario): one text
        // card, one table, one shape, one condition flow step with bound card.
        let size = configuration.defaultNodeSize
        let text = textNode(
            "Sample Text",
            .text("Deterministic lab sample."),
            center: .init(x: -260, y: -120),
            size: size)
        let table = textNode(
            "Sample Table",
            .table(header: ["k", "v"], rows: [["a", "1"], ["b", "2"]]),
            center: .init(x: 60, y: -140),
            size: .init(width: 300, height: 180))
        let shape = CanvasNodeSnapshot(
            content: .shape(kind: .rectangle, text: "Box"),
            frame: .init(
                center: .init(x: -80, y: 120),
                size: .init(width: 180, height: 100)))
        let graphID = UUID()
        let conditionPort = FlowPort(
            name: "branch", dataType: .json, direction: .output)
        let flowNode = FlowNode(
            kind: .condition,
            name: "Check",
            ports: [
                FlowPort(name: "in", dataType: .json, direction: .input),
                conditionPort,
            ],
            branches: [FlowConditionBranch(
                predicate: .comparison(.equal, lhs: .literal(.bool(true)), rhs: .literal(.bool(true))),
                outputPortID: conditionPort.id)],
            position: .init(x: 320, y: 80))
        let graph = FlowGraph(
            id: graphID,
            revision: 0,
            nodes: [flowNode],
            edges: [],
            variables: [])
        var metadata: [String: String] = [:]
        CanvasFlowCardBinding(graphID: graphID, nodeID: flowNode.id)
            .applied(to: &metadata)
        let card = CanvasNodeSnapshot(
            kind: .generationTask,
            title: "Check",
            content: .shape(kind: .roundedRectangle, text: "Check"),
            frame: .init(
                center: .init(x: 320, y: 240),
                size: .init(width: 200, height: 100)),
            metadata: metadata)
        return CanvasTemplateContent(
            pageName: name,
            nodes: [text, table, shape, card],
            flowGraph: graph,
            isDeterministicLabSample: true)
    }
}

/// Turns a goal description into an editable first draft.
///
/// ICQA03: the description goes to the host's injected AI/proposal
/// capability. Without a gateway the composer honestly falls back to the
/// plain template content and the UI says the assistant is unavailable —
/// the name/description text is never passed off as AI output.
#if canImport(UIKit)
@MainActor
public enum CanvasSceneGoalComposer {
    public static func compose(
        description: String,
        template: CanvasSceneTemplate,
        store: CanvasEditorStore
    ) async -> CanvasTemplateContent {
        let fallback = CanvasTemplateFactory.make(
            template, name: description.isEmpty ? "Scene" : description,
            configuration: store.configuration)
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }

        let context = CanvasRuntimeContext(
            canvasID: store.canvasID,
            pageID: store.selectedPageID,
            revision: store.revision)
        let request = CanvasAssistantRequest(
            context: context,
            selectedNodeIDs: [],
            instruction: trimmed,
            disposition: nil)
        if let proposalGateway = store.services.proposalGateway {
            do {
                let proposal = try await proposalGateway.propose(request: request)
                return try translate(
                    proposal: proposal,
                    fallback: fallback,
                    template: template)
            } catch {
                store.presentAlertFromError(error)
                return fallback
            }
        }
        if let assistantGateway = store.services.assistantGateway {
            do {
                let batch = try await assistantGateway.perform(request: request)
                return translate(batch: batch, fallback: fallback)
            } catch {
                store.presentAlertFromError(error)
                return fallback
            }
        }
        return fallback
    }

    private static func translate(
        proposal: CanvasAssistantProposal,
        fallback: CanvasTemplateContent,
        template: CanvasSceneTemplate
    ) throws -> CanvasTemplateContent {
        switch proposal {
        case .canvasBatch(let batch):
            return translate(batch: batch, fallback: fallback)
        case .documentBatch(let batch):
            var nodes: [CanvasNodeSnapshot] = []
            var connections: [CanvasConnectionSnapshot] = []
            var graph: FlowGraph? = nil
            for operation in batch.operations {
                switch operation {
                case .editPage(let pageBatch):
                    for op in pageBatch.operations {
                        switch op {
                        case .insertNode(let node): nodes.append(node)
                        case .insertConnection(let c): connections.append(c)
                        default: break
                        }
                    }
                case .insertFlowGraph(_, let g): graph = g
                default: break
                }
            }
            if nodes.isEmpty { return fallback }
            return CanvasTemplateContent(
                pageName: fallback.pageName,
                nodes: nodes,
                connections: connections,
                flowGraph: graph,
                isDeterministicLabSample: template == .lab)
        }
    }

    private static func translate(
        batch: CanvasEditBatch,
        fallback: CanvasTemplateContent
    ) -> CanvasTemplateContent {
        var nodes: [CanvasNodeSnapshot] = []
        var connections: [CanvasConnectionSnapshot] = []
        for operation in batch.operations {
            switch operation {
            case .insertNode(let node): nodes.append(node)
            case .insertConnection(let c): connections.append(c)
            default: break
            }
        }
        if nodes.isEmpty { return fallback }
        return CanvasTemplateContent(
            pageName: fallback.pageName,
            nodes: nodes,
            connections: connections)
    }
}

#endif
