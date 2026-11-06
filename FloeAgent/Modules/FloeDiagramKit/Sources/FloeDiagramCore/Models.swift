// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum DiagramError: Error, Equatable, Sendable {
    case invalid(String), notFound(UUID), conflict(expected: Int, actual: Int)
    case protectedContent(UUID), outsideSelection(UUID), closed, cancelled
    case duplicateRequest, corruptRecord, unsupported(String), io(String)
}

public struct DiagramPoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double = 0, y: Double = 0) { self.x = x; self.y = y }
    public static let zero = Self()
    public static func + (a: Self, b: Self) -> Self { .init(x: a.x + b.x, y: a.y + b.y) }
    public static func - (a: Self, b: Self) -> Self { .init(x: a.x - b.x, y: a.y - b.y) }
    public var isFinite: Bool { x.isFinite && y.isFinite && abs(x) < 1e9 && abs(y) < 1e9 }
}

public struct DiagramSize: Codable, Hashable, Sendable {
    public var width: Double
    public var height: Double
    public init(width: Double = 160, height: Double = 56) { self.width = width; self.height = height }
    public var isValid: Bool { width.isFinite && height.isFinite && width > 0 && height > 0 && width < 1e7 && height < 1e7 }
}

public struct DiagramRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double = 0, y: Double = 0, width: Double = 160, height: Double = 56) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var center: DiagramPoint { .init(x: x + width / 2, y: y + height / 2) }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var size: DiagramSize { .init(width: width, height: height) }
    public var isValid: Bool { DiagramPoint(x: x, y: y).isFinite && size.isValid }
    public func translated(by p: DiagramPoint) -> Self { .init(x: x + p.x, y: y + p.y, width: width, height: height) }
    public func insetBy(_ d: Double) -> Self { .init(x: x + d, y: y + d, width: width - 2*d, height: height - 2*d) }
    public func contains(_ p: DiagramPoint) -> Bool { p.x >= x && p.x <= maxX && p.y >= y && p.y <= maxY }
    public func intersects(_ other: Self) -> Bool { x <= other.maxX && maxX >= other.x && y <= other.maxY && maxY >= other.y }
    public func union(_ other: Self) -> Self {
        let a = min(x, other.x), b = min(y, other.y)
        return .init(x: a, y: b, width: max(maxX, other.maxX) - a, height: max(maxY, other.maxY) - b)
    }
}

public enum DiagramStructure: String, Codable, CaseIterable, Sendable {
    case balanced, right, left, tree, organization, fishbone, timeline, flow, free
}
public enum DiagramElementKind: String, Codable, CaseIterable, Sendable {
    case topic, floatingTopic, rectangle, roundedRectangle, ellipse, diamond, parallelogram
    case text, group, boundary, summary, swimlane, swimlanePool
    public var isTopic: Bool { self == .topic || self == .floatingTopic }
    public var isContainer: Bool { self == .group || self == .swimlane || self == .swimlanePool }
}
public enum DiagramRouteKind: String, Codable, CaseIterable, Sendable { case curve, orthogonal, straight }
public enum DiagramConnectionKind: String, Codable, Sendable { case association, flow }
public enum DiagramAnchorSide: String, Codable, CaseIterable, Sendable { case automatic, left, right, top, bottom }
public enum DiagramTaskStatus: String, Codable, CaseIterable, Sendable { case todo, inProgress, done }

public struct DiagramStyle: Codable, Hashable, Sendable {
    /// Hex colors or semantic tokens. UI resolves semantic colors for the active appearance.
    public var fill: String
    public var stroke: String
    public var text: String
    public var lineWidth: Double
    public var cornerRadius: Double
    public var fontSize: Double
    public var bold: Bool
    public init(fill: String = "surface", stroke: String = "border", text: String = "text",
                lineWidth: Double = 1.5, cornerRadius: Double = 12, fontSize: Double = 15, bold: Bool = false) {
        self.fill = fill; self.stroke = stroke; self.text = text; self.lineWidth = lineWidth
        self.cornerRadius = cornerRadius; self.fontSize = fontSize; self.bold = bold
    }
}

public struct DiagramTextRun: Codable, Hashable, Sendable {
    public var text: String
    public var bold: Bool
    public var italic: Bool
    public var underline: Bool
    public var link: String?
    public init(_ text: String, bold: Bool = false, italic: Bool = false, underline: Bool = false, link: String? = nil) {
        self.text = text; self.bold = bold; self.italic = italic; self.underline = underline; self.link = link
    }
}
public struct DiagramTable: Codable, Hashable, Sendable {
    public var rows: [[String]]
    public var header: Bool
    public init(rows: [[String]], header: Bool = true) { self.rows = rows; self.header = header }
}
public enum DiagramContentBlock: Codable, Hashable, Sendable {
    case richText([DiagramTextRun])
    case image(assetID: UUID, caption: String)
    case formula(String)
    case code(language: String, text: String)
    case table(DiagramTable)
    case note(String)
    case attachment(UUID)
    public var assetID: UUID? {
        switch self { case .image(let id, _), .attachment(let id): return id; default: return nil }
    }
    public var plainText: String {
        switch self {
        case .richText(let runs): runs.map(\.text).joined()
        case .image(_, let caption): caption
        case .formula(let latex), .note(let latex): latex
        case .code(_, let text): text
        case .table(let table): table.rows.map { $0.joined(separator: "\t") }.joined(separator: "\n")
        case .attachment: ""
        }
    }
}

public struct DiagramSourceReference: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var documentID: String
    public var kind: String
    public var locator: String
    public var title: String
    public var sourceRevision: String?
    public var excerpt: String?
    public init(id: UUID = UUID(), documentID: String, kind: String = "file", locator: String = "",
                title: String = "", sourceRevision: String? = nil, excerpt: String? = nil) {
        self.id = id; self.documentID = documentID; self.kind = kind; self.locator = locator
        self.title = title; self.sourceRevision = sourceRevision; self.excerpt = excerpt
    }
}
public struct DiagramLink: Codable, Hashable, Sendable {
    public var pageID: UUID?
    public var elementID: UUID?
    public var url: String?
    public var title: String
    public var isBroken: Bool
    public init(pageID: UUID? = nil, elementID: UUID? = nil, url: String? = nil, title: String = "", isBroken: Bool = false) {
        self.pageID = pageID; self.elementID = elementID; self.url = url; self.title = title; self.isBroken = isBroken
    }
}
public struct DiagramAsset: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var fileName: String
    public var mediaType: String
    public var byteCount: Int
    public var sha256: String?
    public init(id: UUID = UUID(), fileName: String, mediaType: String, byteCount: Int, sha256: String? = nil) {
        self.id = id; self.fileName = fileName; self.mediaType = mediaType; self.byteCount = byteCount; self.sha256 = sha256
    }
}

public struct DiagramElement: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var kind: DiagramElementKind
    public var title: String
    public var parentID: UUID?
    public var containerID: UUID?
    public var order: Int
    /// nil means the layout engine chooses placement. A stored frame pins this element.
    public var frame: DiagramRect?
    public var structure: DiagramStructure?
    public var collapsed: Bool
    public var contentExpanded: Bool
    public var isLocked: Bool
    public var content: [DiagramContentBlock]
    public var style: DiagramStyle
    public var tags: [String]
    public var markers: [String]
    public var taskID: UUID?
    public var sources: [DiagramSourceReference]
    public var links: [DiagramLink]
    /// Boundary/summary members; separate from hierarchy and container ownership.
    public var memberIDs: [UUID]
    public var metadata: [String: String]
    public init(id: UUID = UUID(), kind: DiagramElementKind = .topic, title: String,
                parentID: UUID? = nil, containerID: UUID? = nil, order: Int = 0,
                frame: DiagramRect? = nil, structure: DiagramStructure? = nil,
                collapsed: Bool = false, contentExpanded: Bool = false, isLocked: Bool = false,
                content: [DiagramContentBlock] = [], style: DiagramStyle = .init(),
                tags: [String] = [], markers: [String] = [], taskID: UUID? = nil,
                sources: [DiagramSourceReference] = [], links: [DiagramLink] = [],
                memberIDs: [UUID] = [], metadata: [String: String] = [:]) {
        self.id = id; self.kind = kind; self.title = title; self.parentID = parentID; self.containerID = containerID
        self.order = order; self.frame = frame; self.structure = structure; self.collapsed = collapsed
        self.contentExpanded = contentExpanded; self.isLocked = isLocked; self.content = content
        self.style = style; self.tags = tags; self.markers = markers; self.taskID = taskID
        self.sources = sources; self.links = links; self.memberIDs = memberIDs; self.metadata = metadata
    }
}

public struct DiagramConnection: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var from: UUID
    public var to: UUID
    public var kind: DiagramConnectionKind
    public var route: DiagramRouteKind
    public var sourceAnchor: DiagramAnchorSide
    public var targetAnchor: DiagramAnchorSide
    public var waypoints: [DiagramPoint]
    public var label: String
    /// Normalized distance along the path, independent of node placement.
    public var labelPosition: Double
    public var color: String
    public var width: Double
    public var dashed: Bool
    public var startArrow: Bool
    public var endArrow: Bool
    public var isLocked: Bool
    public var metadata: [String: String]
    public init(id: UUID = UUID(), from: UUID, to: UUID, kind: DiagramConnectionKind = .association,
                route: DiagramRouteKind = .curve, sourceAnchor: DiagramAnchorSide = .automatic,
                targetAnchor: DiagramAnchorSide = .automatic, waypoints: [DiagramPoint] = [],
                label: String = "", labelPosition: Double = 0.5, color: String = "edge",
                width: Double = 1.5, dashed: Bool = false, startArrow: Bool = false,
                endArrow: Bool = false, isLocked: Bool = false, metadata: [String: String] = [:]) {
        self.id = id; self.from = from; self.to = to; self.kind = kind; self.route = route
        self.sourceAnchor = sourceAnchor; self.targetAnchor = targetAnchor; self.waypoints = waypoints
        self.label = label; self.labelPosition = labelPosition; self.color = color; self.width = width
        self.dashed = dashed; self.startArrow = startArrow; self.endArrow = endArrow; self.isLocked = isLocked; self.metadata = metadata
    }
}

public struct DiagramTask: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var parentID: UUID?
    public var status: DiagramTaskStatus
    public var progress: Double
    public var priority: Int
    public var assignee: String
    public var start: Date?
    public var end: Date?
    public var floeTaskID: String?
    public init(id: UUID = UUID(), title: String, parentID: UUID? = nil, status: DiagramTaskStatus = .todo,
                progress: Double = 0, priority: Int = 0, assignee: String = "",
                start: Date? = nil, end: Date? = nil, floeTaskID: String? = nil) {
        self.id = id; self.title = title; self.parentID = parentID; self.status = status
        self.progress = status == .done ? 1 : progress; self.priority = priority
        self.assignee = assignee; self.start = start; self.end = end; self.floeTaskID = floeTaskID
    }
}
public struct DiagramTaskDependency: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var predecessorID: UUID
    public var successorID: UUID
    /// Finish-to-start, expressed in working days; scheduling is always explicit.
    public var lagDays: Int
    public init(id: UUID = UUID(), predecessorID: UUID, successorID: UUID, lagDays: Int = 0) {
        self.id = id; self.predecessorID = predecessorID; self.successorID = successorID; self.lagDays = lagDays
    }
}
public struct DiagramTheme: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var topicStyle: DiagramStyle
    public var branchColor: String
    public var background: String
    public init(id: UUID = UUID(), name: String = "Floe", topicStyle: DiagramStyle = .init(),
                branchColor: String = "edge", background: String = "canvas") {
        self.id = id; self.name = name; self.topicStyle = topicStyle; self.branchColor = branchColor; self.background = background
    }
}
public struct DiagramPage: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var structure: DiagramStructure
    public var elements: [DiagramElement]
    public var connections: [DiagramConnection]
    public var ink: Data?
    public var theme: DiagramTheme
    public var metadata: [String: String]
    public init(id: UUID = UUID(), title: String = "Overview", structure: DiagramStructure = .balanced,
                elements: [DiagramElement] = [], connections: [DiagramConnection] = [], ink: Data? = nil, theme: DiagramTheme = .init(), metadata: [String: String] = [:]) {
        self.id = id; self.title = title; self.structure = structure; self.elements = elements
        self.connections = connections; self.ink = ink; self.theme = theme; self.metadata = metadata
    }
}
public struct DiagramDocument: Codable, Hashable, Identifiable, Sendable {
    public var schemaVersion: Int
    public var id: UUID
    public var revision: Int
    public var title: String
    public var pages: [DiagramPage]
    public var tasks: [DiagramTask]
    public var dependencies: [DiagramTaskDependency]
    public var assets: [DiagramAsset]
    public var metadata: [String: String]
    /// Original legacy data survives migration; it is never executed or treated as permissions.
    public var legacyPayload: Data?
    public init(id: UUID = UUID(), revision: Int = 0, title: String = "Untitled",
                pages: [DiagramPage] = [.init()], tasks: [DiagramTask] = [],
                dependencies: [DiagramTaskDependency] = [], assets: [DiagramAsset] = [],
                metadata: [String: String] = [:], legacyPayload: Data? = nil) {
        schemaVersion = 1; self.id = id; self.revision = revision; self.title = title
        self.pages = pages; self.tasks = tasks; self.dependencies = dependencies; self.assets = assets
        self.metadata = metadata; self.legacyPayload = legacyPayload
    }
    public func page(_ id: UUID) -> DiagramPage? { pages.first { $0.id == id } }
    public func element(_ id: UUID) -> DiagramElement? { pages.lazy.compactMap { $0.elements.first { $0.id == id } }.first }
}

public extension DiagramDocument {
    func isBroken(_ link: DiagramLink, sourcePageID: UUID? = nil) -> Bool {
        if link.isBroken { return true }
        if let pageID = link.pageID, page(pageID) == nil { return true }
        if let elementID = link.elementID {
            if let p = link.pageID ?? sourcePageID { return page(p)?.elements.contains(where: { $0.id == elementID }) != true }
            return element(elementID) == nil
        }
        return false
    }
}
/// Indexed graph access keeps selection, descendants and large-map traversal linear.
public struct DiagramPageIndex: Sendable {
    public let elements: [UUID: DiagramElement]
    public let children: [UUID: [UUID]]
    public let members: [UUID: [UUID]]
    public let effectivelyLockedIDs: Set<UUID>
    public init(_ page: DiagramPage) {
        elements = Dictionary(page.elements.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        children = Dictionary(grouping: page.elements.filter { $0.parentID != nil }, by: { $0.parentID! })
            .mapValues { $0.sorted { $0.order == $1.order ? $0.id.uuidString < $1.id.uuidString : $0.order < $1.order }.map(\.id) }
        members = Dictionary(grouping: page.elements.filter { $0.containerID != nil }, by: { $0.containerID! }).mapValues { $0.map(\.id) }
        var locked = Set(page.elements.filter(\.isLocked).map(\.id)), queue = Array(locked), cursor = 0
        while cursor < queue.count {
            let id = queue[cursor]; cursor += 1
            for next in (children[id] ?? []) + (members[id] ?? []) where locked.insert(next).inserted { queue.append(next) }
        }
        effectivelyLockedIDs = locked
    }
    public func descendants(of roots: Set<UUID>, includingContainers: Bool = true) -> Set<UUID> {
        var found = roots, queue = Array(roots), cursor = 0
        while cursor < queue.count {
            let id = queue[cursor]; cursor += 1
            for next in (children[id] ?? []) + (includingContainers ? members[id] ?? [] : []) where found.insert(next).inserted { queue.append(next) }
        }
        return found
    }
    public func isEffectivelyLocked(_ id: UUID) -> Bool {
        effectivelyLockedIDs.contains(id)
    }
    public func visibleAncestor(of id: UUID) -> UUID? {
        guard elements[id] != nil else { return nil }
        var current = id, answer = id, seen: Set<UUID> = []
        while let p = elements[current]?.parentID, seen.insert(p).inserted {
            if elements[p]?.collapsed == true { answer = p }
            current = p
        }
        return answer
    }
}
