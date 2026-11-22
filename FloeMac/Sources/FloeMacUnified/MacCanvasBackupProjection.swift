// SPDX-License-Identifier: MPL-2.0
import FloeCore
import Foundation

/// Read-only projection of a canvas project for the Mac simple board.
///
/// The Mac workbench is the simple board: it edits plain text/image/video
/// nodes and ordinary connectors only. Everything an iPad canvas can carry
/// beyond that (locked nodes, group members, shapes, 3D/professional nodes,
/// generation tasks, freehand strokes, PencilKit data and the native kit
/// editor state) is OPAQUE to the board. This enum classifies nodes so the
/// board can present editable controls for the supported subset and a
/// read-only representation for the rest, while `CanvasProjectCodec` keeps
/// the full document intact for export. The semantics intentionally mirror
/// `CanvasFrameworkProjection` on iPad: geometry gestures never re-encode or
/// flatten rich content, and preserved bytes stay preserved.
enum MacCanvasBackupProjection {
    /// What the simple board may do with one node.
    enum NodeCapability: Equatable {
        /// Plain unlocked text/image/video node: edit, move, connect, remove.
        case editable
        /// Locked node: content and geometry are owned by the iPad editor.
        case preservedLocked
        /// Member of a group: kit grouping semantics own its transforms.
        case preservedGroup
        /// A kind the simple board has no editor for (shape, sticky note,
        /// card, audio, file, group, generation task, 3D scene, ...).
        case preservedKind
    }

    /// Kinds the simple board can create and edit.
    static let editableKinds: Set<CanvasNodeKind> = [.text, .image, .video]

    static func capability(of node: CanvasNode) -> NodeCapability {
        if node.isLocked { return .preservedLocked }
        if node.groupID != nil { return .preservedGroup }
        if !editableKinds.contains(node.kind) { return .preservedKind }
        return .editable
    }

    static func isEditable(_ node: CanvasNode) -> Bool {
        capability(of: node) == .editable
    }

    /// True when the project carries anything the simple board cannot edit
    /// but must keep intact through export (ink strokes, PencilKit bytes or
    /// non-editable nodes). Kit state alone is NOT a flag: every board,
    /// including fresh Mac ones, now carries seeded kit state.
    static func hasOpaqueContent(_ project: CanvasProject) -> Bool {
        project.documents.contains { document in
            if !document.strokes.isEmpty || document.pencilDrawingData != nil { return true }
            return document.nodes.contains { capability(of: $0) != .editable }
        }
    }

    /// Short bilingual badge for read-only tiles, by capability.
    static func readonlyBadge(_ capability: NodeCapability) -> String {
        switch capability {
        case .preservedLocked:
            return MacCanvasText.readonlyLocked
        case .preservedGroup:
            return MacCanvasText.readonlyGrouped
        case .preservedKind:
            return MacCanvasText.readonlyKind
        case .editable:
            return ""
        }
    }
}
