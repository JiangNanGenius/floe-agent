// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Pure per-text search shared by the Notes library navigation and the Notes
/// agent tools, so a tapped result and an agent `Hit` can point at the exact
/// page, element/node and UTF-16 range instead of only the containing document.
///
/// Offsets are UTF-16 code-unit offsets (the same unit as `NSRange` and the
/// UIKit/CoreText highlight APIs). Matching is case- and diacritic-insensitive,
/// which also keeps literal CJK search working.
public enum NoteTextSearch {
    /// Where a match was found. `elementText`/`elementAIText` carry page-element
    /// geometry; `extractedText`/`ocrText` are flat page text without per-run
    /// geometry; the map sources carry a node identity.
    public enum Source: String, Codable, Sendable, Equatable {
        case officeText
        case elementText
        case elementAIText
        case extractedText
        case ocrText
        case mapTitle
        case mapNote
        case mapAttachmentName
        case mapAttachmentCaption
    }

    public struct Match: Equatable, Sendable {
        public var documentID: UUID
        public var pageID: UUID?
        public var nodeID: UUID?
        public var elementID: UUID?
        public var source: Source
        /// Agent-facing label kept identical to the historical sourceKind values.
        public var sourceKind: String
        public var utf16Offset: Int
        public var utf16Length: Int
        public var snippet: String

        public init(documentID: UUID, pageID: UUID?, nodeID: UUID?, elementID: UUID?,
                    source: Source, sourceKind: String, utf16Offset: Int, utf16Length: Int, snippet: String) {
            self.documentID = documentID
            self.pageID = pageID
            self.nodeID = nodeID
            self.elementID = elementID
            self.source = source
            self.sourceKind = sourceKind
            self.utf16Offset = utf16Offset
            self.utf16Length = utf16Length
            self.snippet = snippet
        }
    }

    public static let compareOptions: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
    /// Context kept on each side of the match in the returned snippet.
    public static let snippetLeading = 100
    public static let snippetTrailing = 300

    /// Scans one document in a stable order (Office text, then each page's text
    /// elements, extracted text and cached OCR, then map topics and their
    /// attachments) and returns at most `limit` matches with exact UTF-16 ranges.
    public static func matches(in document: NoteDocument, query: String, limit: Int = Int.max) -> [Match] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard limit > 0, !needle.isEmpty else { return [] }
        var results: [Match] = []
        func append(_ text: String?, pageID: UUID?, nodeID: UUID?, elementID: UUID?,
                    source: Source, sourceKind: String) {
            guard results.count < limit, let text, !text.isEmpty else { return }
            let ns = text as NSString
            var searchRange = NSRange(location: 0, length: ns.length)
            while results.count < limit {
                let range = ns.range(of: needle, options: compareOptions, range: searchRange)
                guard range.location != NSNotFound else { break }
                results.append(Match(
                    documentID: document.id,
                    pageID: pageID,
                    nodeID: nodeID,
                    elementID: elementID,
                    source: source,
                    sourceKind: sourceKind,
                    utf16Offset: range.location,
                    utf16Length: range.length,
                    snippet: snippet(in: ns, around: range)))
                let next = range.location + max(1, range.length)
                guard next < ns.length else { break }
                searchRange = NSRange(location: next, length: ns.length - next)
            }
        }

        if document.officeTextResourceID == document.officeResourceID {
            append(document.officeExtractedText, pageID: nil, nodeID: nil, elementID: nil,
                   source: .officeText, sourceKind: "office")
        }
        for page in document.pages {
            for element in page.elements {
                append(element.text, pageID: page.id, nodeID: nil, elementID: element.id,
                       source: element.isAIGenerated ? .elementAIText : .elementText,
                       sourceKind: element.isAIGenerated ? "ai-annotation" : "annotation")
                if results.count >= limit { return results }
            }
            append(page.extractedText, pageID: page.id, nodeID: nil, elementID: nil,
                   source: .extractedText, sourceKind: "source")
            if results.count >= limit { return results }
            append(page.indexedVisualText, pageID: page.id, nodeID: nil, elementID: nil,
                   source: .ocrText, sourceKind: "ocr-composite")
            if results.count >= limit { return results }
        }
        for node in document.nodes {
            let sourceKind = node.isAIGenerated == true ? "ai-map-topic" : "map-topic"
            append(node.title, pageID: nil, nodeID: node.id, elementID: nil, source: .mapTitle, sourceKind: sourceKind)
            if results.count >= limit { return results }
            append(node.note, pageID: nil, nodeID: node.id, elementID: nil, source: .mapNote, sourceKind: sourceKind)
            if results.count >= limit { return results }
            for attachment in node.attachments ?? [] {
                append(attachment.fileName, pageID: nil, nodeID: node.id, elementID: nil,
                       source: .mapAttachmentName, sourceKind: sourceKind)
                append(attachment.caption, pageID: nil, nodeID: node.id, elementID: nil,
                       source: .mapAttachmentCaption, sourceKind: sourceKind)
                if results.count >= limit { return results }
            }
        }
        return results
    }

    /// First match in the same stable order used by `matches`, for one-tap
    /// library navigation.
    public static func firstMatch(in document: NoteDocument, query: String) -> Match? {
        matches(in: document, query: query, limit: 1).first
    }

    private static func snippet(in text: NSString, around range: NSRange) -> String {
        let start = max(0, range.location - snippetLeading)
        let end = min(text.length, range.location + range.length + snippetTrailing)
        return text.substring(with: NSRange(location: start, length: end - start))
    }
}
