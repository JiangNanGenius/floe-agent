import Foundation
import FloeCanvasCore
import FloeCanvasFlow

public enum CanvasTemplateEngine {
    public static let maxArchiveBytes = 16 * 1024 * 1024
    public static let provenanceKey = "floe.template.provenance"
    public static let sourcePrefix = "template-node:"

    public static func validate(_ template: CanvasTemplate) throws {
        guard template.schemaVersion == 1, template.version > 0,
              !template.title.en.isEmpty, !template.title.zh.isEmpty,
              !template.snapshot.pages.isEmpty,
              template.snapshot.pages.contains(where: { $0.id == template.snapshot.selectedPageID })
        else { throw TemplateError.invalid("template header or selected page") }
        guard try JSONEncoder().encode(template).count <= maxArchiveBytes else {
            throw TemplateError.invalid("template is too large")
        }
        var nodeIDs = Set<UUID>()
        let allNodeIDs = Set(template.snapshot.pages.flatMap(\.nodes).map(\.id))
        var pageIDs = Set<UUID>()
        var graphIDs = Set<UUID>()
        for page in template.snapshot.pages {
            guard pageIDs.insert(page.id).inserted else { throw TemplateError.invalid("duplicate page") }
            let localIDs = Set(page.nodes.map(\.id))
            for node in page.nodes {
                guard nodeIDs.insert(node.id).inserted else { throw TemplateError.invalid("duplicate canvas node") }
                if let p = try CreativePurpose.read(node) {
                    guard p.referenceNodeIDs.allSatisfy(allNodeIDs.contains) else {
                        throw TemplateError.invalid("purpose references a missing node")
                    }
                    if let id = p.recordID, !template.records.contains(where: { $0.id == id }) {
                        throw TemplateError.invalid("purpose references a missing record")
                    }
                }
            }
            guard page.connections.allSatisfy({
                localIDs.contains($0.sourceNodeID) && localIDs.contains($0.destinationNodeID)
            }), page.groups.allSatisfy({ $0.memberNodeIDs.allSatisfy(localIDs.contains) }) else {
                throw TemplateError.invalid("dangling page relation")
            }
            for graph in page.flowGraphs {
                guard graphIDs.insert(graph.id).inserted else { throw TemplateError.invalid("duplicate graph") }
                _ = try FlowGraphCompiler.compile(graph)
                for source in graph.nodes where source.kind == .source {
                    if let key = source.parameters["bindingKey"]?.stringValue, key.hasPrefix(sourcePrefix) {
                        guard let id = UUID(uuidString: String(key.dropFirst(sourcePrefix.count))),
                              allNodeIDs.contains(id) else {
                            throw TemplateError.invalid("template source references a missing input")
                        }
                        if let locator = source.parameters[CanvasFlowSourceParameterKey.nodeID]?.stringValue,
                           UUID(uuidString: locator) != id {
                            throw TemplateError.invalid("template source locators disagree")
                        }
                    }
                }
            }
        }
        var keys = Set<String>()
        for slot in template.slots {
            guard !slot.id.isEmpty, keys.insert(slot.id).inserted, nodeIDs.contains(slot.nodeID) else {
                throw TemplateError.invalid("invalid or duplicate input slot")
            }
        }
        try CreativeRecords.validate(template.records, nodeIDs: nodeIDs)
        for node in template.snapshot.pages.flatMap(\.nodes) {
            if let binding = CanvasFlowCardBinding(metadata: node.metadata) {
                guard template.snapshot.pages.flatMap(\.flowGraphs).contains(where: {
                    $0.id == binding.graphID && $0.nodes.contains(where: { $0.id == binding.nodeID })
                }) else { throw TemplateError.invalid("dangling flow card binding") }
            }
        }
    }

    public static func instantiate(
        _ template: CanvasTemplate, name: String? = nil,
        inputs: [String: CanvasContent] = [:], newCanvasID: UUID = UUID()
    ) throws -> CanvasTemplateInstance {
        try validate(template)
        let copy = CanvasIdentityMapper.copy(template.snapshot, newSnapshotID: newCanvasID)
        var instance = CanvasTemplateInstance(
            templateID: template.id, templateVersion: template.version, instanceID: UUID(),
            snapshot: copy.snapshot, slots: template.slots, records: template.records,
            identityMap: copy.idMapping)
        instance.snapshot.name = name ?? template.title.zh
        instance.snapshot.createdAt = Date(); instance.snapshot.updatedAt = Date()
        instance.snapshot.metadata.removeValue(forKey: "floe.template.state")
        instance.snapshot.metadata.removeValue(forKey: "floe.creation.owner")
        instance.snapshot.metadata.removeValue(forKey: CreativeRecords.metadataKey)
        for i in instance.records.indices {
            let old = instance.records[i].id
            instance.identityMap[old] = UUID()
        }
        func mapped(_ id: UUID) -> UUID { instance.identityMap[id] ?? id }
        for i in instance.records.indices {
            instance.records[i].id = mapped(instance.records[i].id)
            instance.records[i].nodeIDs = instance.records[i].nodeIDs.map(mapped)
            instance.records[i].relatedRecordIDs = instance.records[i].relatedRecordIDs.map(mapped)
        }
        for i in instance.slots.indices { instance.slots[i].nodeID = mapped(instance.slots[i].nodeID) }
        let knownKeys = Set(instance.slots.map(\.id))
        guard Set(inputs.keys).isSubset(of: knownKeys) else { throw TemplateError.invalid("unknown input key") }
        for pi in instance.snapshot.pages.indices {
            for ni in instance.snapshot.pages[pi].nodes.indices {
                var node = instance.snapshot.pages[pi].nodes[ni]
                if var purpose = try CreativePurpose.read(node) {
                    purpose.recordID = purpose.recordID.map(mapped)
                    purpose.referenceNodeIDs = purpose.referenceNodeIDs.map(mapped)
                    try purpose.apply(to: &node)
                }
                node.metadata[provenanceKey] = "\(template.id.uuidString)/\(template.version)/\(instance.instanceID.uuidString)"
                if let slot = instance.slots.first(where: { $0.nodeID == node.id }) {
                    node.metadata["floe.template.input"] = slot.id
                    node.metadata["floe.template.required"] = slot.required ? "true" : "false"
                    if let content = inputs[slot.id] { node.content = content }
                }
                instance.snapshot.pages[pi].nodes[ni] = node
            }
            for gi in instance.snapshot.pages[pi].flowGraphs.indices {
                for fi in instance.snapshot.pages[pi].flowGraphs[gi].nodes.indices {
                    var flow = instance.snapshot.pages[pi].flowGraphs[gi].nodes[fi]
                    if let oldKey = flow.parameters["bindingKey"]?.stringValue, oldKey.hasPrefix(sourcePrefix),
                       let oldID = UUID(uuidString: String(oldKey.dropFirst(sourcePrefix.count))) {
                        flow.parameters["bindingKey"] = .string(sourcePrefix + mapped(oldID).uuidString)
                    }
                    instance.snapshot.pages[pi].flowGraphs[gi].nodes[fi] = flow
                }
            }
        }
        return instance
    }

    /// Captures data only. Runtime records, jobs and permissions are not template content.
    public static func capture(
        snapshot: CanvasSnapshot, title: TemplateText, category: TemplateCategory,
        selectedNodeIDs: Set<UUID>? = nil, records: [CreativeRecord] = [],
        policy: TemplateCapturePolicy = .inputsOnly
    ) throws -> CanvasTemplate {
        var captured = snapshot
        captured.metadata.removeValue(forKey: "floe.template.state")
        captured.metadata.removeValue(forKey: "floe.creation.owner")
        captured.metadata.removeValue(forKey: CreativeRecords.metadataKey)
        var slots: [TemplateSlot] = []
        if let selectedNodeIDs {
            let available = Set(snapshot.pages.flatMap(\.nodes).map(\.id))
            guard !selectedNodeIDs.isEmpty, selectedNodeIDs.isSubset(of: available) else {
                throw TemplateError.invalid("empty or unknown selection")
            }
            for pi in captured.pages.indices {
                var p = captured.pages[pi]
                let flowBindings = p.nodes.filter { selectedNodeIDs.contains($0.id) }
                    .compactMap { CanvasFlowCardBinding(metadata: $0.metadata) }
                p.nodes.removeAll { !selectedNodeIDs.contains($0.id) }
                p.connections.removeAll {
                    !selectedNodeIDs.contains($0.sourceNodeID) || !selectedNodeIDs.contains($0.destinationNodeID)
                }
                p.groups = p.groups.compactMap {
                    var g = $0; g.memberNodeIDs = g.memberNodeIDs.filter(selectedNodeIDs.contains)
                    return g.memberNodeIDs.isEmpty ? nil : g
                }
                p.scenes = []; p.strokes = []; p.pencilDrawingData = nil
                p.flowGraphs = try p.flowGraphs.compactMap { graph in
                    var selected = Set(flowBindings.filter { $0.graphID == graph.id }.map(\.nodeID))
                    guard !selected.isEmpty else { return nil }
                    // A loop/batch and its body are one reusable structural unit.
                    var changed = true
                    while changed {
                        let before = selected
                        for n in graph.nodes {
                            let body = Set(n.bodyNodeIDs ?? [])
                            if selected.contains(n.id) || !selected.isDisjoint(with: body) {
                                selected.insert(n.id); selected.formUnion(body)
                            }
                        }
                        changed = before != selected
                    }
                    var g = graph
                    g.nodes.removeAll { !selected.contains($0.id) }
                    g.edges.removeAll {
                        !selected.contains($0.sourceNodeID) || !selected.contains($0.destinationNodeID)
                    }
                    g.variables.removeAll { !selected.contains($0.ownerNodeID) }
                    _ = try FlowGraphCompiler.compile(g)
                    return g
                }
                captured.pages[pi] = p
            }
            captured.pages.removeAll { $0.nodes.isEmpty && $0.flowGraphs.isEmpty }
            guard let first = captured.pages.first else { throw TemplateError.invalid("empty selection") }
            captured.selectedPageID = first.id
            captured.viewports = captured.viewports.filter { id, _ in captured.pages.contains { $0.id == id } }
        }
        let retainedNodeIDs = Set(captured.pages.flatMap(\.nodes).map(\.id))
        var keptRecords = records.filter { selectedNodeIDs == nil || !$0.nodeIDs.allSatisfy { !retainedNodeIDs.contains($0) } }
        let retainedRecords = Set(keptRecords.map(\.id))
        for i in keptRecords.indices {
            keptRecords[i].nodeIDs = keptRecords[i].nodeIDs.filter(retainedNodeIDs.contains)
            keptRecords[i].relatedRecordIDs = keptRecords[i].relatedRecordIDs.filter(retainedRecords.contains)
        }
        for pi in captured.pages.indices {
            for ni in captured.pages[pi].nodes.indices {
                var n = captured.pages[pi].nodes[ni]
                n.createdByRunID = nil
                n.metadata.removeValue(forKey: provenanceKey)
                if var purpose = try CreativePurpose.read(n) {
                    purpose.referenceNodeIDs = purpose.referenceNodeIDs.filter(retainedNodeIDs.contains)
                    if let id = purpose.recordID, !retainedRecords.contains(id) { purpose.recordID = nil }
                    try purpose.apply(to: &n)
                }
                var replace = n.metadata["floe.template.input"] != nil
                switch n.content {
                case .editor: replace = true
                case .media, .pdf, .web: replace = replace || policy == .inputsOnly
                default: break
                }
                if n.source != nil && policy == .inputsOnly { replace = true }
                if replace {
                    slots.append(.init(id: "input-\(n.id.uuidString)", title: .init(n.title ?? "Input", n.title ?? "输入"), nodeID: n.id,
                        required: n.metadata["floe.template.required"] == "true"))
                    n.content = .text(""); n.source = nil
                }
                captured.pages[pi].nodes[ni] = n
            }
        }
        // Existing source bindings whose target was excluded become explicit inputs.
        for pi in captured.pages.indices {
            for gi in captured.pages[pi].flowGraphs.indices {
                for fi in captured.pages[pi].flowGraphs[gi].nodes.indices {
                    var flow = captured.pages[pi].flowGraphs[gi].nodes[fi]
                    if let key = flow.parameters["bindingKey"]?.stringValue, key.hasPrefix(sourcePrefix),
                       let id = UUID(uuidString: String(key.dropFirst(sourcePrefix.count))),
                       !retainedNodeIDs.contains(id) {
                        let n = CanvasNodeSnapshot(title: "Input", content: .text(""),
                            frame: .init(center: flow.position, size: .init(width: 260, height: 160)),
                            metadata: ["floe.template.required": "true", "floe.template.input": "input"])
                        captured.pages[pi].nodes.append(n)
                        slots.append(.init(id: "input-\(n.id.uuidString)", title: .init("Input", "输入"), nodeID: n.id, required: true))
                        flow.parameters["bindingKey"] = .string(sourcePrefix + n.id.uuidString)
                        flow.parameters[CanvasFlowSourceParameterKey.canvasID] = .string(captured.id.uuidString)
                        flow.parameters[CanvasFlowSourceParameterKey.pageID] = .string(captured.pages[pi].id.uuidString)
                        flow.parameters[CanvasFlowSourceParameterKey.nodeID] = .string(n.id.uuidString)
                        captured.pages[pi].flowGraphs[gi].nodes[fi] = flow
                    }
                }
            }
        }
        let result = CanvasTemplate(title: title, summary: .init("Saved personal workflow", "保存的个人流程"),
            category: category, snapshot: captured, slots: slots, records: keptRecords)
        try validate(result)
        return result
    }

    public static func encode(_ template: CanvasTemplate) throws -> Data {
        try validate(template)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(template)
    }
    public static func decode(_ data: Data) throws -> CanvasTemplate {
        guard data.count <= maxArchiveBytes else { throw TemplateError.invalid("template is too large") }
        let t = try JSONDecoder().decode(CanvasTemplate.self, from: data)
        try validate(t)
        return t
    }
}
