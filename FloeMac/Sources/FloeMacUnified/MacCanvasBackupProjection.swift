// SPDX-License-Identifier: MPL-2.0
import FloeCore
import Foundation

/// Read-only projection of a canvas project for the Mac simple board.
///
/// The Mac workbench is the simple board: it edits plain unlocked content
/// nodes and ordinary connectors only. Everything an iPad canvas can carry
/// beyond that (locked nodes, group members, generation tasks, 3D scenes,
/// freehand strokes, PencilKit data and the native kit editor state) is
/// OPAQUE to the board. This enum classifies nodes so the board can present
/// editable controls for the supported subset and a read-only
/// representation for the rest, while `CanvasProjectCodec` keeps the full
/// document intact for export. The semantics intentionally mirror
/// `CanvasFrameworkProjection` on iPad: geometry gestures never re-encode or
/// flatten rich content, and preserved bytes stay preserved.
///
/// Precise supported set (2026-11-23, Mac timeline/subtitle/grading round):
///   * `.text`, `.stickyNote`, `.card` — text editing, move, connect,
///     remove, rename.
///   * `.shape` — shape-kind switching between the five `CanvasShapeKind`
///     values, move, connect, remove, rename.
///   * `.image`, `.video`, `.audio`, `.file` — asset-backed nodes: open,
///     rename, move, connect, remove; image/video additionally keep the
///     existing basic editor route. Audio/file gain asset support through
///     `MacCreativeLibrary.assetURL`.
/// Preserved read-only: locked nodes, group members, `.group`,
/// `.generationTask` (provider-job state stays iPad-owned) and `.scene3D`
/// (no Mac 3D director in this round). Document-level ink strokes and
/// PencilKit data always remain preserved.
enum MacCanvasBackupProjection {
    /// What the simple board may do with one node.
    enum NodeCapability: Equatable {
        /// Unlocked supported node: edit, move, connect, remove, rename.
        case editable
        /// Locked node: content and geometry are owned by the iPad editor.
        case preservedLocked
        /// Member of a group: kit grouping semantics own its transforms.
        case preservedGroup
        /// A kind the simple board has no editor for (group, generation
        /// task, 3D scene).
        case preservedKind
    }

    /// Kinds the simple board can create and edit. See the documentation
    /// comment above for the precise per-kind capability matrix.
    static let editableKinds: Set<CanvasNodeKind> = [
        .text, .stickyNote, .card, .shape, .image, .video, .audio, .file,
    ]

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
