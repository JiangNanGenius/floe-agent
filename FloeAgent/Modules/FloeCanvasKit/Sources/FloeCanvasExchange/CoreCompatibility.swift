// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCanvasCore
import FloeDiagramCore
import FloeDiagramExchange

// MARK: - Pending Core surface (single integration fix point)
//
// The Core writer (job-fb63f7f28957494e) is adding these cases to the
// frozen DTOs; per coordinator direction 2026-11-03 the intended shape is:
//
//   CanvasContent.richText(document: CanvasRichTextDocument)
//   CanvasRichTextDocument(runs: [CanvasRichTextRun])
//   CanvasRichTextRun(text: String, bold: Bool = false, italic: Bool = false,
//                     underline: Bool = false, strikethrough: Bool = false,
//                     link: URL? = nil, foregroundColor: String? = nil)
//   CanvasContent.shape(kind: CanvasShapeKind, text: String)
//   CanvasShapeKind: String — rectangle / roundedRectangle / ellipse /
//                    diamond / line / arrow
//   CanvasVisualMetadataKeys — node.metadata["fillColor"/"strokeColor"/
//                    "strokeWidth"/"textColor"]
//
// NOTHING in this file may be edited by other lanes. If the landed Core
// signatures differ from the intended shape above, ONLY this file needs
// adjustment; every codec consumes rich text and shapes through the helpers
// below, never through direct pattern matching.

public enum CanvasExchangeContent {
    // MARK: richText

    public static func richText(_ runs: [CanvasRichTextRun]) -> CanvasContent {
        .richText(document: CanvasRichTextDocument(runs: runs))
    }

    public static func richTextRuns(_ content: CanvasContent) -> [CanvasRichTextRun]? {
        guard case .richText(let document) = content else { return nil }
        return document.runs
    }

    /// Plain-text projection of a rich text document (link URLs are not
    /// inlined; exporters that support links should walk the runs).
    public static func plainText(runs: [CanvasRichTextRun]) -> String {
        runs.map(\.text).joined()
    }

    // MARK: shape

    public static func shape(_ kind: CanvasShapeKind, text: String) -> CanvasContent {
        .shape(kind: kind, text: text)
    }

    public static func shapeValue(_ content: CanvasContent) -> (kind: CanvasShapeKind, text: String)? {
        guard case .shape(let kind, let text) = content else { return nil }
        return (kind, text)
    }

    /// True when the content is a vector shape (possibly with text).
    public static func isShape(_ content: CanvasContent) -> Bool {
        shapeValue(content) != nil
    }

    // MARK: style metadata

    /// Resolved visual style of a node from the shared metadata keys.
    public struct Style: Hashable, Sendable {
        public var fill: String?
        public var stroke: String?
        public var strokeWidth: Double?
        public var textColor: String?

        public init(fill: String? = nil, stroke: String? = nil, strokeWidth: Double? = nil, textColor: String? = nil) {
            self.fill = fill
            self.stroke = stroke
            self.strokeWidth = strokeWidth
            self.textColor = textColor
        }
    }

    public static func style(of node: CanvasNodeSnapshot) -> Style {
        Style(
            fill: node.metadata[CanvasExchangeStyleKey.fillColor],
            stroke: node.metadata[CanvasExchangeStyleKey.strokeColor],
            strokeWidth: node.metadata[CanvasExchangeStyleKey.strokeWidth].flatMap(Double.init),
            textColor: node.metadata[CanvasExchangeStyleKey.textColor]
        )
    }

    public static func applying(_ style: Style, to metadata: inout [String: String]) {
        if let fill = style.fill { metadata[CanvasExchangeStyleKey.fillColor] = fill }
        if let stroke = style.stroke { metadata[CanvasExchangeStyleKey.strokeColor] = stroke }
        if let width = style.strokeWidth { metadata[CanvasExchangeStyleKey.strokeWidth] = CanvasExchangeGeometry.number(width) }
        if let textColor = style.textColor { metadata[CanvasExchangeStyleKey.textColor] = textColor }
    }

    // MARK: plain text projection

    /// Human-readable plain-text projection of any content case, used by
    /// outline-style exporters and as a fallback renderer input.
    public static func plainText(of content: CanvasContent) -> String {
        switch content {
        case .text(let text): return text
        case .markdown(let document, _): return document
        case .code(_, let source): return source
        case .formula(let source, _): return source
        case .table(let header, let rows):
            return ([header] + rows).map { $0.joined(separator: " | ") }.joined(separator: "\n")
        case .media(let locator): return locator.relativePath ?? locator.id.uuidString
        case .pdf(let assetID, let range):
            var text = assetID?.uuidString ?? "PDF"
            if let range { text += " p.\(range.lowerBound)-\(range.upperBound)" }
            return text
        case .web(let url, let title): return title ?? url.absoluteString
        case .editor(let reference): return reference.projectID.uuidString
        case .unknown(let kind, _): return "[\(kind)]"
        case .richText(let document): return plainText(runs: document.runs)
        case .shape(_, let text): return text
        }
    }

    /// Editable single-run rich text content from plain source.
    public static func editableText(_ text: String) -> CanvasContent {
        text.isEmpty ? .text(text) : richText([CanvasRichTextRun(text: text)])
    }
}

// MARK: - Flow graph reachability (additive Core field)

public enum CanvasExchangeFlowSupport {
    /// All flow graphs attached to a page. `CanvasPageSnapshot.flowGraphs`
    /// is the additive Core field (decodes absent as `[]`); isolating the
    /// access here keeps a hypothetical rename to one place.
    public static func flowGraphs(of page: CanvasPageSnapshot) -> [FlowGraph] {
        page.flowGraphs
    }

    /// True when any page carries at least one flow graph.
    public static func hasFlowGraphs(_ snapshot: CanvasSnapshot) -> Bool {
        snapshot.pages.contains { !flowGraphs(of: $0).isEmpty }
    }
}

// MARK: - Flow card binding (Core metadata contract)

public enum CanvasExchangeFlowBindingSupport {
    /// The flow graph binding recorded on a visual card node, when present.
    public struct Binding: Hashable, Sendable {
        public var graphID: UUID
        public var nodeID: UUID
    }

    /// Reads `floe.flow.graphID` / `floe.flow.nodeID` from node metadata.
    public static func binding(of node: CanvasNodeSnapshot) -> Binding? {
        guard let graph = node.metadata[CanvasExchangeFlowKey.graphID].flatMap(UUID.init(uuidString:)),
              let flowNode = node.metadata[CanvasExchangeFlowKey.nodeID].flatMap(UUID.init(uuidString:)) else { return nil }
        return Binding(graphID: graph, nodeID: flowNode)
    }

    public static func applying(_ binding: Binding, to metadata: inout [String: String]) {
        metadata[CanvasExchangeFlowKey.graphID] = binding.graphID.uuidString
        metadata[CanvasExchangeFlowKey.nodeID] = binding.nodeID.uuidString
    }

    /// True when the node is a visual flow card (generation task kind with
    /// a binding). Open formats render these as plain visual projections.
    public static func isFlowCard(_ node: CanvasNodeSnapshot) -> Bool {
        node.kind == .generationTask && binding(of: node) != nil
    }
}

// MARK: - Page-native PencilKit data (additive Core field)

public enum CanvasExchangePencilSupport {
    /// The page's real PKDrawing bytes (pressure/style preserved), or nil.
    /// `CanvasPageSnapshot.pencilDrawingData` is the additive Core field
    /// (decodes absent as nil). Access is isolated here so a signature
    /// drift is a one-line fix. The data is world-space: `DiagramNativeInk`
    /// reports the drawing bounds in the same coordinate system, so exports
    /// place the rasterized ink at exactly those bounds.
    public static func drawingData(of page: CanvasPageSnapshot) -> Data? {
        page.pencilDrawingData
    }

    /// World-space bounds of the page ink, when present and renderable.
    public static func inkBounds(of page: CanvasPageSnapshot) throws -> (minX: Double, minY: Double, maxX: Double, maxY: Double)? {
        guard let data = drawingData(of: page) else { return nil }
        guard let rect = try DiagramNativeInk.bounds(data) else { return nil }
        return (rect.x, rect.y, rect.maxX, rect.maxY)
    }
}
