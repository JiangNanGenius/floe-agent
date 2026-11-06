import Foundation
import FloeCanvasCore

/// One search hit on the current page.
public struct CanvasSearchResult: Identifiable, Hashable, Sendable {
    public var id: UUID { node.id }
    public var node: CanvasNodeSnapshot
    /// Lowercased match excerpt (title preferred, then content preview).
    public var excerpt: String

    public init(node: CanvasNodeSnapshot, excerpt: String) {
        self.node = node
        self.excerpt = excerpt
    }
}

/// Pure page-local search over node titles and textual content. Case
/// insensitive substring matching; deterministic order (title matches first,
/// then source order). Geometry lookups go through the layout index, not a
/// second scan of hidden/collapsed members.
public enum CanvasSearch {
    public static func search(
        _ query: String,
        in page: CanvasPageSnapshot
    ) -> [CanvasSearchResult] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !needle.isEmpty else { return [] }
        var titleHits: [CanvasSearchResult] = []
        var contentHits: [CanvasSearchResult] = []
        for node in page.nodes {
            if let title = node.title, title.lowercased().contains(needle) {
                titleHits.append(CanvasSearchResult(node: node, excerpt: title))
                continue
            }
            let text = contentPreview(of: node.content)
            if text.lowercased().contains(needle) {
                let lower = text.lowercased()
                guard let range = lower.range(of: needle) else { continue }
                let start = text.index(
                    range.lowerBound,
                    offsetBy: -24,
                    limitedBy: text.startIndex) ?? text.startIndex
                let end = text.index(
                    range.upperBound,
                    offsetBy: 24,
                    limitedBy: text.endIndex) ?? text.endIndex
                contentHits.append(CanvasSearchResult(
                    node: node,
                    excerpt: String(text[start..<end])))
            }
        }
        return titleHits + contentHits
    }

    /// Short, human-readable text summary used for search and list rows.
    public static func contentPreview(of content: CanvasContent) -> String {
        switch content {
        case .text(let text):
            return text
        case .markdown(let document, _):
            return document
        case .richText(let document):
            return document.plainText
        case .shape(_, let text):
            return text
        case .code(_, let source):
            return source
        case .formula(let source, _):
            return source
        case .table(let header, let rows):
            return (header + rows.flatMap { $0 }).joined(separator: " | ")
        case .media(let locator):
            return locator.relativePath ?? locator.sourceURL?.absoluteString ?? ""
        case .pdf:
            return "PDF"
        case .web(let url, let title):
            return title ?? url.absoluteString
        case .editor(let reference):
            return reference.editorKind
        case .unknown(let kind, _):
            return kind
        }
    }
}
