// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Navigation state only. Closing a tab never mutates a document or its undo history.
public struct NoteWorkspaceTabs: Codable, Equatable, Sendable {
    public struct Viewport: Codable, Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var zoom: Double
        public init(x: Double, y: Double, zoom: Double) {
            self.x = x.isFinite ? max(0, x) : 0
            self.y = y.isFinite ? max(0, y) : 0
            self.zoom = zoom.isFinite ? min(5, max(0.1, zoom)) : 1
        }
    }
    public struct EditorState: Codable, Equatable, Sendable {
        public var pageID: UUID?
        public var tool: String?
        public var viewports: [UUID: Viewport] = [:]
        public init() {}
    }
    public private(set) var documentIDs: [UUID] = []
    public private(set) var selectedID: UUID?
    public private(set) var editors: [UUID: EditorState] = [:]
    public init() {}

    public mutating func open(_ id: UUID) {
        if !documentIDs.contains(id) { documentIDs.append(id) }
        selectedID = id
    }

    public mutating func close(_ id: UUID) {
        guard let index = documentIDs.firstIndex(of: id) else { return }
        documentIDs.remove(at: index)
        if selectedID == id {
            selectedID = documentIDs.isEmpty ? nil : documentIDs[min(index, documentIDs.count - 1)]
        }
        // Remember the reading position when a document is later reopened.
    }

    public mutating func prune(availableIDs: Set<UUID>) {
        for id in documentIDs where !availableIDs.contains(id) { close(id) }
        editors = editors.filter { availableIDs.contains($0.key) }
        // Also normalize decoded duplicate tab IDs without disturbing their order.
        var seen = Set<UUID>()
        documentIDs = documentIDs.filter { seen.insert($0).inserted }
        if let selectedID, !documentIDs.contains(selectedID) { self.selectedID = documentIDs.first }
    }

    public mutating func updateEditor(_ state: EditorState, for id: UUID) { editors[id] = state }
}
