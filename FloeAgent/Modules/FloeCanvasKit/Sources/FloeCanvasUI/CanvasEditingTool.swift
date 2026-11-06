import Foundation

/// Primary board tool. One active tool at a time keeps the chrome honest —
/// the brief forbids stacking separate lab/flow/card toolbars.
public enum CanvasEditingTool: String, Codable, Hashable, Sendable, CaseIterable {
    /// Tap/drag to select and move; marquee with empty-space drag.
    case select
    /// Drag to pan; two-finger pinch zooms.
    case hand
    /// Freehand Pencil ink (PencilKit).
    case pencil
    /// PencilKit lasso selection of ink strokes and objects.
    case lasso
    /// PencilKit eraser.
    case eraser
    /// Drag between flow ports to create typed execution edges; drag between
    /// node bodies to create ordinary relations.
    case connector
}

/// What the contextual inspector is currently showing.
public enum CanvasInspectorTab: String, Codable, Hashable, Sendable, CaseIterable {
    case node
    case style
    case flow
    case source
    case resource
    case debugger
}
