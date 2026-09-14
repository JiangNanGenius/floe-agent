// SPDX-License-Identifier: MPL-2.0
import Foundation
import Crypto

public enum NoteError: Error, LocalizedError, Sendable {
    case notFound, conflict, invalidDocument(String), invalidOperation(String), resourceUnavailable
    public var errorDescription: String? {
        switch self {
        case .notFound: "手记内容不存在。"
        case .conflict: "内容已被修改，请重新载入后再试。"
        case .invalidDocument(let reason), .invalidOperation(let reason): reason
        case .resourceUnavailable: "资料尚未下载或已经不可用。"
        }
    }
}

public struct NoteRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double = 0, y: Double = 0, width: Double = 240, height: Double = 120) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0
    }
}

public struct NoteSourceReference: Codable, Hashable, Sendable {
    public enum Space: String, Codable, Sendable { case notes, canvas, workspace }
    public var space: Space
    public var documentID: UUID
    public var revision: Int
    public var pageID: UUID?
    public var nodeID: UUID?
    public var region: NoteRect?
    public var recordingSeconds: Double?
    public init(space: Space = .notes, documentID: UUID, revision: Int, pageID: UUID? = nil,
                nodeID: UUID? = nil, region: NoteRect? = nil, recordingSeconds: Double? = nil) {
        self.space = space; self.documentID = documentID; self.revision = revision
        self.pageID = pageID; self.nodeID = nodeID; self.region = region
        self.recordingSeconds = recordingSeconds
    }
}

public struct NoteElement: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case text, image, rectangle, ellipse, line, arrow }
    public var id: UUID
    public var kind: Kind
    public var frame: NoteRect
    public var text: String
    public var resourceID: UUID?
    public var color: String
    public var fontSize: Double
    public var source: NoteSourceReference?
    public var isAIGenerated: Bool
    public init(id: UUID = UUID(), kind: Kind = .text, frame: NoteRect = .init(), text: String = "",
                resourceID: UUID? = nil, color: String = "#202020", fontSize: Double = 20,
                source: NoteSourceReference? = nil, isAIGenerated: Bool = false) {
        self.id = id; self.kind = kind; self.frame = frame; self.text = text
        self.resourceID = resourceID; self.color = color; self.fontSize = fontSize
        self.source = source; self.isAIGenerated = isAIGenerated
    }
}

public struct NotePage: Codable, Hashable, Identifiable, Sendable {
    public enum Paper: String, Codable, CaseIterable, Sendable { case plain, ruled, grid }
    public var id: UUID
    public var width: Double
    public var height: Double
    public var paper: Paper
    public var backgroundResourceID: UUID?
    public var pdfPageIndex: Int?
    public var drawingResourceID: UUID?
    public var elements: [NoteElement]
    public var isBookmarked: Bool
    /// Extracted source text is distinct from editable or AI-generated annotations.
    public var extractedText: String?
    public var ocrText: String?
    public var ocrSourceKey: String?
    public var ocrError: String?
    public var needsVisualIndex: Bool {
        drawingResourceID != nil || elements.contains { $0.kind == .image }
            || (backgroundResourceID != nil && (extractedText ?? "").isEmpty)
    }
    public var visualIndexKey: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let geometry = "\(width):\(height):\(pdfPageIndex ?? -1):\(backgroundResourceID?.uuidString ?? ""):\(drawingResourceID?.uuidString ?? "")"
        var data = Data(geometry.utf8)
        if let elements = try? encoder.encode(elements) { data.append(elements) }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public var indexedVisualText: String? { ocrSourceKey == visualIndexKey ? ocrText : nil }

    public var textExtractionTruncated: Bool?
    public init(id: UUID = UUID(), width: Double = 768, height: Double = 1024,
                paper: Paper = .plain, backgroundResourceID: UUID? = nil, pdfPageIndex: Int? = nil,
                drawingResourceID: UUID? = nil, elements: [NoteElement] = [], isBookmarked: Bool = false,
                extractedText: String? = nil, textExtractionTruncated: Bool? = nil) {
        self.id = id; self.width = width; self.height = height; self.paper = paper
        self.backgroundResourceID = backgroundResourceID; self.pdfPageIndex = pdfPageIndex
        self.drawingResourceID = drawingResourceID; self.elements = elements; self.isBookmarked = isBookmarked
        self.extractedText = extractedText; self.textExtractionTruncated = textExtractionTruncated
    }
}

/// A topic owns resource references, never temporary paths. Previews are created on demand.
public struct MindMapAttachment: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case image, document, audio, video, file }
    public var id: UUID
    public var resourceID: UUID
    public var fileName: String
    public var mediaType: String
    public var kind: Kind
    public var caption: String
    public var source: NoteSourceReference?
    public init(id: UUID = UUID(), resourceID: UUID, fileName: String, mediaType: String,
                kind: Kind = .file, caption: String = "", source: NoteSourceReference? = nil) {
        self.id = id; self.resourceID = resourceID; self.fileName = fileName
        self.mediaType = mediaType; self.kind = kind; self.caption = caption; self.source = source
    }
    public func validate() throws {
        guard !fileName.isEmpty, fileName != ".", fileName != "..",
              fileName == (fileName as NSString).lastPathComponent,
              !fileName.contains("\\"), !fileName.contains(":"),
              !fileName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              fileName.utf8.count <= 255, mediaType.utf8.count <= 256, caption.utf8.count <= 65_536 else {
            throw NoteError.invalidDocument("主题附件的文件名或说明无效。")
        }
    }
}

/// A document links to an independent map; removing this relationship never removes its target.
public struct NoteMindMapLink: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var documentID: UUID
    public var pageID: UUID?
    public init(id: UUID = UUID(), documentID: UUID, pageID: UUID? = nil) {
        self.id = id; self.documentID = documentID; self.pageID = pageID
    }
}

public struct MindMapNode: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var parentID: UUID?
    public var title: String
    public var note: String
    public var order: Int
    public var isCollapsed: Bool
    public var color: String?
    public var imageResourceID: UUID?
    public var attachments: [MindMapAttachment]?
    public var style: [String: String]?
    public var tags: [String]?
    public var icons: [String]?
    public var direction: Int?
    public var branchColor: String?
    public var hyperLink: String?
    public var isAIGenerated: Bool?
    public var source: NoteSourceReference?
    public init(id: UUID = UUID(), parentID: UUID? = nil, title: String, note: String = "", order: Int = 0,
                isCollapsed: Bool = false, color: String? = nil, imageResourceID: UUID? = nil,
                source: NoteSourceReference? = nil) {
        self.id = id; self.parentID = parentID; self.title = title; self.note = note; self.order = order
        self.isCollapsed = isCollapsed; self.color = color; self.imageResourceID = imageResourceID; self.source = source
    }
}

public struct MindMapConnection: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var from: UUID
    public var to: UUID
    public var title: String
    public struct Offset: Codable, Hashable, Sendable { public var x: Double; public var y: Double }
    public var delta1: Offset?
    public var delta2: Offset?
    public var bidirectional: Bool?
    public var style: [String: String]?
    public init(id: UUID = UUID(), from: UUID, to: UUID, title: String = "") {
        self.id = id; self.from = from; self.to = to; self.title = title
    }
}

public struct MindMapSummary: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var label: String
    public var parent: UUID
    public var start: Int
    public var end: Int
    public var style: [String: String]?
    public init(id: UUID = UUID(), label: String, parent: UUID, start: Int, end: Int, style: [String: String]? = nil) {
        self.id = id; self.label = label; self.parent = parent; self.start = start; self.end = end; self.style = style
    }
}

public struct Notebook: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public init(id: UUID = UUID(), title: String, createdAt: Date = Date()) {
        self.id = id; self.title = title; self.createdAt = createdAt
    }
}

public struct NoteDocument: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case notebook, mindMap, office }
    public var schemaVersion: Int = 1
    public var id: UUID
    public var kind: Kind
    public var notebookID: UUID?
    public var title: String
    public var revision: Int
    public var pages: [NotePage]
    public var nodes: [MindMapNode]
    public var connections: [MindMapConnection]
    public var linkedMindMaps: [NoteMindMapLink]?
    public var mindMapDirection: Int?
    public var summaries: [MindMapSummary]?
    public var tags: [String]
    public var isFavorite: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var officeResourceID: UUID?
    public var officeFileName: String?
    /// Rebuildable text cache, valid only for this immutable Office resource.
    public var officeTextResourceID: UUID?
    public var officeExtractedText: String?
    public var officeTextError: String?
    public init(id: UUID = UUID(), kind: Kind = .notebook, notebookID: UUID? = nil, title: String) {
        self.id = id; self.kind = kind; self.notebookID = notebookID; self.title = title; self.revision = 0
        self.pages = kind == .notebook ? [NotePage()] : []
        self.nodes = kind == .mindMap ? [MindMapNode(title: title)] : []
        self.connections = []; self.tags = []; self.isFavorite = false
        self.createdAt = Date(); self.updatedAt = createdAt
    }
    public var resourceIDs: Set<UUID> {
        Set(pages.flatMap { page in
            [page.backgroundResourceID, page.drawingResourceID].compactMap { $0 }
            + page.elements.compactMap(\.resourceID)
        } + nodes.compactMap(\.imageResourceID) + nodes.flatMap { ($0.attachments ?? []).map(\.resourceID) } + [officeResourceID].compactMap { $0 })
    }
    public var searchableText: String {
        ([title] + tags + ((officeTextResourceID == officeResourceID ? officeExtractedText : nil).map { [$0] } ?? []) + pages.compactMap(\.extractedText) + pages.compactMap(\.indexedVisualText) + pages.flatMap { $0.elements.map(\.text) }
         + nodes.flatMap { [$0.title, $0.note] + ($0.attachments ?? []).flatMap { [$0.fileName, $0.caption] } }).joined(separator: "\n")
    }
    public func validate() throws {
        guard schemaVersion == 1, revision >= 0, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NoteError.invalidDocument("文档版本或标题无效。")
        }
        guard Set(pages.map(\.id)).count == pages.count,
              Set(nodes.map(\.id)).count == nodes.count,
              Set(connections.map(\.id)).count == connections.count,
              Set((summaries ?? []).map(\.id)).count == (summaries ?? []).count,
              pages.count <= 5_000, connections.count <= 10_000, (summaries ?? []).count <= 10_000 else {
            throw NoteError.invalidDocument("文档包含重复标识。")
        }
        let links = linkedMindMaps ?? []
        guard links.count <= 100, Set(links.map(\.id)).count == links.count,
              Set(links.map(\.documentID)).count == links.count,
              kind != .mindMap || links.isEmpty,
              links.allSatisfy({ link in link.documentID != id && (link.pageID == nil || pages.contains(where: { $0.id == link.pageID })) }) else {
            throw NoteError.invalidDocument("关联导图重复、数量过多或页面锚点无效。")
        }
        for page in pages {
            guard page.width.isFinite, page.height.isFinite, page.width > 0, page.height > 0,
                  page.width <= 16_384, page.height <= 16_384,
                  Set(page.elements.map(\.id)).count == page.elements.count, page.elements.count <= 2_000,
                  page.elements.filter({ $0.kind == .image }).count <= 64 else {
                throw NoteError.invalidDocument("页面尺寸或内容标识无效。")
            }
            if let index = page.pdfPageIndex, index < 0 || page.backgroundResourceID == nil {
                throw NoteError.invalidDocument("PDF 页面引用无效。")
            }
            for element in page.elements {
                guard element.frame.isValid, element.fontSize.isFinite, (1...512).contains(element.fontSize) else {
                    throw NoteError.invalidDocument("页面内容尺寸无效。")
                }
                if element.kind == .image && element.resourceID == nil {
                    throw NoteError.invalidDocument("图片缺少资源引用。")
                }
            }
        }
        if kind != .mindMap, mindMapDirection != nil || !(summaries ?? []).isEmpty {
            throw NoteError.invalidDocument("普通手记不能包含导图布局。")
        }
        switch kind {
        case .office:
            guard pages.isEmpty, nodes.isEmpty, connections.isEmpty, officeResourceID != nil,
                  let name = officeFileName, name == (name as NSString).lastPathComponent,
                  ["docx", "doc", "odt", "rtf", "xlsx", "xls", "ods", "pptx", "ppt", "odp"].contains((name as NSString).pathExtension.lowercased()) else {
                throw NoteError.invalidDocument("Office 文档缺少有效的文件引用。")
            }
        case .notebook:
            guard !pages.isEmpty, nodes.isEmpty, connections.isEmpty, officeResourceID == nil, officeFileName == nil else {
                throw NoteError.invalidDocument("笔记至少需要一页，且不能包含导图节点。")
            }
        case .mindMap:
            guard Set(nodes.compactMap(\.imageResourceID)).count <= 64 else {
                throw NoteError.invalidDocument("一张导图最多使用 64 张不同的图片，请拆分导图。")
            }
            guard pages.isEmpty, !nodes.isEmpty, nodes.count <= 10_000, officeResourceID == nil, officeFileName == nil,
                  nodes.filter({ $0.parentID == nil }).count == 1 else {
                throw NoteError.invalidDocument("导图需要唯一中心主题。")
            }
            let lookup = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
            guard mindMapDirection == nil || (0...2).contains(mindMapDirection!) else { throw NoteError.invalidDocument("导图方向无效。") }
            let permittedStyles: Set<String> = ["fontSize", "fontFamily", "color", "background", "fontWeight", "width", "border", "textDecoration"]
            guard nodes.reduce(0, { $0 + ($1.attachments ?? []).count }) <= 2_000 else {
                throw NoteError.invalidDocument("一张导图最多保留 2000 个附件。")
            }
            for node in nodes {
                let attachments = node.attachments ?? []
                guard attachments.count <= 32, Set(attachments.map(\.id)).count == attachments.count else {
                    throw NoteError.invalidDocument("每个主题最多保留 32 个附件，且标识不能重复。")
                }
                for attachment in attachments { try attachment.validate() }
                guard node.order >= 0, node.title.utf8.count <= 65_536, node.note.utf8.count <= 65_536,
                      (node.style ?? [:]).allSatisfy({ permittedStyles.contains($0.key) && $0.value.utf8.count <= 256 }),
                      node.direction == nil || node.direction == 0 || node.direction == 1,
                      (node.tags ?? []).count <= 100, (node.icons ?? []).count <= 100 else {
                    throw NoteError.invalidDocument("导图样式无效。")
                }
                if let link = node.hyperLink, !link.isEmpty {
                    guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                        throw NoteError.invalidDocument("导图链接只支持网页地址。")
                    }
                }
                var visited = Set<UUID>()
                var current: MindMapNode? = node
                while let value = current {
                    guard visited.insert(value.id).inserted else { throw NoteError.invalidDocument("导图不能形成循环。") }
                    if let parent = value.parentID {
                        guard let next = lookup[parent] else { throw NoteError.invalidDocument("导图父节点不存在。") }
                        current = next
                    } else { current = nil }
                }
            }
            for summary in summaries ?? [] {
                let count = nodes.filter { $0.parentID == summary.parent }.count
                guard lookup[summary.parent] != nil, summary.start >= 0, summary.end >= summary.start, summary.end < count, summary.label.utf8.count <= 65_536,
                      (summary.style ?? [:]).count <= 32, (summary.style ?? [:]).allSatisfy({ $0.key.utf8.count <= 64 && $0.value.utf8.count <= 256 }) else {
                    throw NoteError.invalidDocument("导图概要范围无效。")
                }
            }
            for edge in connections {
                for offset in [edge.delta1, edge.delta2].compactMap({ $0 }) {
                    guard offset.x.isFinite, offset.y.isFinite, abs(offset.x) <= 100_000, abs(offset.y) <= 100_000 else {
                        throw NoteError.invalidDocument("导图关联线位置无效。")
                    }
                }
                guard edge.title.utf8.count <= 65_536, (edge.style ?? [:]).count <= 32,
                      (edge.style ?? [:]).allSatisfy({ $0.key.utf8.count <= 64 && $0.value.utf8.count <= 256 }),
                      edge.from != edge.to, lookup[edge.from] != nil, lookup[edge.to] != nil else {
                    throw NoteError.invalidDocument("导图关联节点无效。")
                }
            }
        }
    }
}

public struct NoteSelectionContext: Codable, Hashable, Sendable {
    public var source: NoteSourceReference
    public var selectedElementIDs: [UUID]
    public var selectedNodeIDs: [UUID]
    public var extractedText: String
    public var surroundingText: String
    public var compositeImageResourceID: UUID?
    public init(source: NoteSourceReference, selectedElementIDs: [UUID] = [], selectedNodeIDs: [UUID] = [],
                extractedText: String, surroundingText: String = "", compositeImageResourceID: UUID? = nil) {
        self.source = source; self.selectedElementIDs = selectedElementIDs; self.selectedNodeIDs = selectedNodeIDs
        self.extractedText = extractedText; self.surroundingText = surroundingText
        self.compositeImageResourceID = compositeImageResourceID
    }
}
