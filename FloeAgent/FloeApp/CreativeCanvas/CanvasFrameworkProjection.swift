// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloeCanvasCore
import FloeCanvasIntegration

/// The established canvas is the editing surface. Its document is a projection
/// of the original, never a replacement for the kit's richer document model.
enum CanvasFrameworkProjection {
    static let frameworkStateKey = "floe.framework.project"
    static let frameworkNodeKind = "floe.framework.node"

    static func snapshot(_ project: FloeCore.CanvasProject) throws -> CanvasSnapshot {
        var state = project
        state.canvasKitState = nil
        return .init(id: project.id, name: project.name, pages: try project.documents.map(page),
            selectedPageID: project.selectedDocumentID,
            viewports: project.viewports.mapValues { .init(center: .init(x: $0.center.x, y: $0.center.y), scale: $0.scale) },
            revision: project.revision, createdAt: project.createdAt, updatedAt: project.updatedAt,
            metadata: [frameworkStateKey: String(decoding: try JSONEncoder().encode(state), as: UTF8.self)])
    }

    static func project(_ snapshot: CanvasSnapshot, record: PersonalContentRecord) throws -> FloeCore.CanvasProject {
        var result: FloeCore.CanvasProject
        if let raw = snapshot.metadata[frameworkStateKey], let data = raw.data(using: .utf8) {
            result = try JSONDecoder().decode(FloeCore.CanvasProject.self, from: data)
            guard result.id == snapshot.id else { throw PersonalContentError.invalidProject }
        } else {
            result = .init(id: snapshot.id, name: snapshot.name, documents: [], selectedDocumentID: snapshot.selectedPageID)
        }
        result.name = snapshot.name
        result.revision = snapshot.revision
        result.createdAt = snapshot.createdAt
        result.updatedAt = snapshot.updatedAt
        result.selectedDocumentID = snapshot.selectedPageID
        let previousPages = Dictionary(uniqueKeysWithValues: result.documents.map { ($0.id, $0) })
        result.documents = try snapshot.pages.map { page in
            var document = previousPages[page.id] ?? .init(id: page.id, name: page.name)
            document.name = page.name
            document.nodes = try page.nodes.map { try node($0, record: record) }
            document.connections = page.connections.map { connection in
                .init(id: connection.id, sourceNodeID: connection.sourceNodeID, destinationNodeID: connection.destinationNodeID,
                      kind: .init(rawValue: connection.kind.rawValue) ?? .arrow, label: connection.label,
                      sourcePort: connection.sourcePort.flatMap { .init(rawValue: $0.rawValue) },
                      destinationPort: connection.destinationPort.flatMap { .init(rawValue: $0.rawValue) })
            }
            document.strokes = page.strokes.map {
                .init(id: $0.id, points: $0.points.map { .init(x: $0.x, y: $0.y) }, width: $0.width, color: $0.color, isEraser: $0.isEraser)
            }
            document.pencilDrawingData = page.pencilDrawingData
            document.backgroundStyle = .init(rawValue: page.background.rawValue) ?? .grid
            return document
        }
        result.viewports = snapshot.viewports.mapValues { .init(center: .init(x: $0.center.x, y: $0.center.y), scale: $0.scale) }
        return result
    }

    static func batch(project: FloeCore.CanvasProject, original: CanvasSnapshot,
                      record: PersonalContentRecord) throws -> CanvasDocumentBatch {
        guard project.id == original.id else { throw PersonalContentError.changedDocument }
        let baseline = try self.project(original, record: record)
        let beforePages = Dictionary(uniqueKeysWithValues: original.pages.map { ($0.id, $0) })
        let projectedPages = Dictionary(uniqueKeysWithValues: baseline.documents.map { ($0.id, $0) })
        var operations: [CanvasDocumentOperation] = []
        let retainedIDs = Set(project.documents.map(\.id))
        // Add first so replacing the last page remains one valid transaction.
        for document in project.documents where beforePages[document.id] == nil {
            operations.append(.createPage(try page(document), select: false))
        }
        for page in original.pages where !retainedIDs.contains(page.id) {
            operations.append(.deletePage(pageID: page.id))
        }
        if project.name != original.name { operations.append(.renameCanvas(name: project.name)) }
        for document in project.documents {
            guard let old = beforePages[document.id], let projected = projectedPages[document.id] else { continue }
            if document.name != old.name { operations.append(.renamePage(pageID: document.id, name: document.name)) }
            if let background = document.backgroundStyle, background.rawValue != old.background.rawValue,
               let value = FloeCanvasCore.CanvasBackgroundStyle(rawValue: background.rawValue) {
                operations.append(.setPageBackground(pageID: document.id, background: value))
            }
            let oldNodes = Dictionary(uniqueKeysWithValues: old.nodes.map { ($0.id, $0) })
            let projectedNodes = Dictionary(uniqueKeysWithValues: projected.nodes.map { ($0.id, $0) })
            let nodeIDs = Set(document.nodes.map(\.id))
            var edits: [CanvasEditOperation] = []
            let connections = Dictionary(uniqueKeysWithValues: document.connections.map { ($0.id, $0) })
            for connection in old.connections where connections[connection.id] == nil
                && nodeIDs.contains(connection.sourceNodeID) && nodeIDs.contains(connection.destinationNodeID) {
                edits.append(.removeConnection(connectionID: connection.id))
            }
            for node in old.nodes where !nodeIDs.contains(node.id) { edits.append(.removeNode(nodeID: node.id)) }
            for value in document.nodes {
                guard let oldNode = oldNodes[value.id], let oldProjection = projectedNodes[value.id] else {
                    edits.append(.insertNode(try nativeNode(value))); continue
                }
                if value == oldProjection { continue }
                if oldNode.isLocked && !value.isLocked { edits.append(.setLocked(nodeID: value.id, isLocked: false)) }
                if value.text != oldProjection.text {
                    edits.append(.updateContent(nodeID: value.id, content: try editedContent(oldNode.content, text: value.text)))
                }
                if value.title != oldProjection.title { edits.append(.updateTitle(nodeID: value.id, title: value.title)) }
                if value.position != oldProjection.position { edits.append(.move(nodeID: value.id, center: .init(x: value.x, y: value.y))) }
                if value.size != oldProjection.size { edits.append(.resize(nodeID: value.id, size: .init(width: value.width, height: value.height))) }
                if !oldNode.isLocked && value.isLocked { edits.append(.setLocked(nodeID: value.id, isLocked: true)) }
                if value.rotation != oldProjection.rotation { operations.append(.updateNodeRotation(nodeID: value.id, rotationDegrees: value.rotation)) }
                if value.zIndex != oldProjection.zIndex { operations.append(.updateNodeStyle(nodeID: value.id, zIndex: value.zIndex)) }
                let changed = value.metadata.filter { oldProjection.metadata[$0.key] != $0.value }
                let removed = oldProjection.metadata.keys.filter { value.metadata[$0] == nil }
                if !changed.isEmpty || !removed.isEmpty {
                    operations.append(.updateNodeMetadata(nodeID: value.id, values: changed, removingKeys: Array(removed)))
                }
                // Native child/media edits are retained in full. A geometry
                // gesture never re-encodes or flattens existing rich content.
                if value.asset != oldProjection.asset || value.scene3D != oldProjection.scene3D || value.kind != oldProjection.kind {
                    edits.append(.updateContent(nodeID: value.id, content: try preservedFrameworkContent(value)))
                }
            }
            let oldConnections = Dictionary(uniqueKeysWithValues: old.connections.map { ($0.id, $0) })
            for value in document.connections {
                let connection = nativeConnection(value)
                if let previous = oldConnections[value.id] {
                    if connection != previous {
                        edits.append(.removeConnection(connectionID: value.id)); edits.append(.insertConnection(connection))
                    }
                } else { edits.append(.insertConnection(connection)) }
            }
            if document.pencilDrawingData != old.pencilDrawingData { edits.append(.setPencilDrawingData(document.pencilDrawingData)) }
            if !edits.isEmpty { operations.insert(.editPage(.init(pageID: document.id, operations: edits)), at: 0) }
            let oldStrokes = Dictionary(uniqueKeysWithValues: old.strokes.map { ($0.id, $0) })
            let strokes = Dictionary(uniqueKeysWithValues: document.strokes.map { ($0.id, $0) })
            for stroke in old.strokes where strokes[stroke.id] == nil { operations.append(.removeStroke(strokeID: stroke.id)) }
            for stroke in document.strokes {
                let value = CanvasStrokeSnapshot(id: stroke.id, points: stroke.points.map { .init(x: $0.x, y: $0.y) }, width: stroke.width, color: stroke.color, isEraser: stroke.isEraser)
                if let previous = oldStrokes[stroke.id] {
                    if previous != value { operations.append(.updateStroke(value)) }
                } else { operations.append(.addStroke(pageID: document.id, stroke: value)) }
            }
        }
        if project.documents.map(\.id) != original.pages.map(\.id) { operations.append(.reorderPages(orderedPageIDs: project.documents.map(\.id))) }
        if project.selectedDocumentID != original.selectedPageID { operations.append(.selectPage(pageID: project.selectedDocumentID)) }
        for (pageID, viewport) in project.viewports {
            let value = FloeCanvasCore.CanvasViewport(center: .init(x: viewport.center.x, y: viewport.center.y), scale: viewport.scale)
            if original.viewports[pageID] != value { operations.append(.setViewport(pageID: pageID, viewport: value)) }
        }
        var state = project
        state.canvasKitState = nil
        let raw = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        operations.append(.updateCanvasMetadata(values: [frameworkStateKey: raw], removingKeys: []))
        return .init(operations: operations)
    }

    static func node(_ value: CanvasNodeSnapshot, record: PersonalContentRecord) throws -> FloeCore.CanvasNode {
        if case .unknown(let kind, let payload) = value.content, kind == frameworkNodeKind {
            var original = try JSONDecoder().decode(FloeCore.CanvasNode.self, from: JSONFidelity.serialize(payload))
            original.id = value.id; original.position = .init(x: value.frame.center.x, y: value.frame.center.y)
            original.size = .init(width: value.frame.size.width, height: value.frame.size.height)
            original.rotation = value.rotationDegrees; original.zIndex = value.zIndex; original.isLocked = value.isLocked
            original.groupID = value.groupID; original.title = value.title
            original.metadata = value.metadata; original.createdByRunID = value.createdByRunID
            return original
        }
        var result = FloeCore.CanvasNode(id: value.id, kind: .card, title: value.title,
            text: CanvasHostSources.text(value.content) ?? value.title ?? "",
            position: .init(x: value.frame.center.x, y: value.frame.center.y),
            size: .init(width: value.frame.size.width, height: value.frame.size.height),
            rotation: value.rotationDegrees, zIndex: value.zIndex, isLocked: value.isLocked,
            groupID: value.groupID, createdByRunID: value.createdByRunID, metadata: value.metadata)
        switch value.content {
        case .text: result.kind = .text
        case .shape(let kind, _): result.kind = .shape; result.shape = .init(rawValue: kind.rawValue) ?? .roundedRectangle
        case .media(let locator):
            result.kind = locator.mimeType?.hasPrefix("video/") == true ? .video : locator.mimeType?.hasPrefix("audio/") == true ? .audio : .image
            result.asset = asset(locator, record: record)
        case .pdf:
            result.kind = .file
            if let raw = value.metadata["floe.asset.locator"], let data = raw.data(using: .utf8),
               let locator = try? JSONDecoder().decode(CanvasAssetLocator.self, from: data) { result.asset = asset(locator, record: record) }
        default: break
        }
        if value.kind == .legacyGroup { result.kind = .group }
        if value.kind == .generationTask, CanvasFlowCardBinding(metadata: value.metadata) == nil { result.kind = .generationTask }
        return result
    }

    private static func asset(_ locator: CanvasAssetLocator, record: PersonalContentRecord) -> CanvasAssetReference {
        let path = locator.relativePath.map { "PersonalContent/" + record.relativePath + "/Assets/" + $0 }
        return .init(id: locator.id, contentHash: locator.contentHash, localRelativePath: path,
                     mimeType: locator.mimeType, byteCount: locator.byteCount)
    }

    private static func nativeNode(_ value: FloeCore.CanvasNode) throws -> CanvasNodeSnapshot {
        .init(id: value.id, kind: value.kind == .group ? .legacyGroup : .content, title: value.title,
              content: try preservedFrameworkContent(value),
              frame: .init(center: .init(x: value.x, y: value.y), size: .init(width: value.width, height: value.height)),
              rotationDegrees: value.rotation, zIndex: value.zIndex, isLocked: value.isLocked,
              groupID: value.groupID, createdByRunID: value.createdByRunID, metadata: value.metadata)
    }

    private static func preservedFrameworkContent(_ value: FloeCore.CanvasNode) throws -> CanvasContent {
        return .unknown(kind: frameworkNodeKind, payload: try JSONFidelity.parse(JSONEncoder().encode(value)))
    }

    private static func nativeConnection(_ value: FloeCore.CanvasConnection) -> CanvasConnectionSnapshot {
        .init(id: value.id, sourceNodeID: value.sourceNodeID, destinationNodeID: value.destinationNodeID,
              kind: .init(rawValue: value.kind.rawValue) ?? .arrow, label: value.label,
              sourcePort: value.sourcePort.flatMap { .init(rawValue: $0.rawValue) }, destinationPort: value.destinationPort.flatMap { .init(rawValue: $0.rawValue) })
    }

    private static func page(_ value: FloeCore.CanvasDocument) throws -> CanvasPageSnapshot {
        .init(id: value.id, name: value.name, nodes: try value.nodes.map(nativeNode),
              connections: value.connections.map(nativeConnection),
              strokes: value.strokes.map { .init(id: $0.id, points: $0.points.map { .init(x: $0.x, y: $0.y) }, width: $0.width, color: $0.color, isEraser: $0.isEraser) },
              groups: groups(value), background: .init(rawValue: value.backgroundStyle?.rawValue ?? "grid") ?? .grid,
              pencilDrawingData: value.pencilDrawingData)
    }

    private static func groups(_ page: FloeCore.CanvasDocument) -> [CanvasGroupRecord] {
        let memberships = Dictionary(grouping: page.nodes.compactMap { node in node.groupID.map { ($0, node.id) } }, by: { $0.0 })
        return memberships.keys.sorted { $0.uuidString < $1.uuidString }.map { id in
            .init(id: id, name: page.nodes.first(where: { $0.id == id })?.text ?? "",
                  memberNodeIDs: memberships[id, default: []].map { $0.1 })
        }
    }

    /// Apply a plain editing gesture to its existing rich type. Unchanged
    /// runs retain their exact attributes; inserted text inherits at the caret.
    static func editedContent(_ content: CanvasContent, text: String) throws -> CanvasContent {
        switch content {
        case .unknown(let kind, let payload) where kind == frameworkNodeKind:
            guard case .object(var original) = payload else { throw PersonalContentError.invalidProject }
            original["text"] = .string(text)
            return .unknown(kind: kind, payload: .object(original))
        case .unknown, .editor, .media, .pdf:
            // A caption edit must not detach an unknown payload, child
            // project or asset. Their native editors own their content.
            return content
        case .web(let url, _): return .web(url, title: text)
        case .markdown: return .markdown(document: text, previewText: nil)
        case .code(let language, _): return .code(language: language, source: text)
        case .formula(_, let assetID): return .formula(source: text, renderedAssetID: assetID)
        case .shape(let kind, _): return .shape(kind: kind, text: text)
        case .richText(let document):
            let old = Array(document.plainText), new = Array(text)
            var prefix = 0
            while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
            var suffix = 0
            while suffix < old.count - prefix, suffix < new.count - prefix,
                  old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
            let replacement = String(new[prefix..<(new.count - suffix)])
            var runs: [CanvasRichTextRun] = [], cursor = 0
            var insertionStyle = document.runs.first ?? .init(text: "")
            var inserted = false
            for var run in document.runs {
                let characters = Array(run.text), start = cursor, end = cursor + characters.count
                if start <= prefix && prefix <= end { insertionStyle = run }
                let keptPrefix = max(0, min(end, prefix) - start)
                if keptPrefix > 0 { var part = run; part.text = String(characters.prefix(keptPrefix)); runs.append(part) }
                if !inserted && end >= prefix {
                    insertionStyle.text = replacement
                    if !replacement.isEmpty { runs.append(insertionStyle) }
                    inserted = true
                }
                let suffixStart = max(start, old.count - suffix)
                if suffixStart < end { run.text = String(characters.suffix(end - suffixStart)); runs.append(run) }
                cursor = end
            }
            if !inserted && !replacement.isEmpty { insertionStyle.text = replacement; runs.append(insertionStyle) }
            return .richText(document: .init(runs: runs))
        case .table:
            let rows = text.components(separatedBy: "\n").map { $0.components(separatedBy: "\t") }
            return .table(header: rows.first ?? [], rows: Array(rows.dropFirst()))
        default: return .text(text)
        }
    }
}
#endif
