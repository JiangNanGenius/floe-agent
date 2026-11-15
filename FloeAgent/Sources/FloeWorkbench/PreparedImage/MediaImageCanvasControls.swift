// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum MediaImageCanvasControls {
    public enum Input: Sendable { case finger, pencil, pointer }
    public static let columnsKey = "workbench.image.toolRail.columns"
    public static func columns(_ stored: Int?) -> Int { stored == 2 ? 2 : 1 }

    /// A finger observation is delivered only for a completed solo drag.
    public static func pencilEditing(after input: Input, current: Bool, fingerDrawing: Bool) -> Bool {
        switch input {
        case .pencil: true
        case .pointer: false
        case .finger: current && !fingerDrawing
        }
    }
    public static func deliberateFingerDrag(distance: Double, multipleContacts: Bool) -> Bool {
        !multipleContacts && distance.isFinite && distance > 12
    }
    public static func fingerEditsCanvas(editsCanvas: Bool, stroke: Bool, pencilEditing: Bool, fingerDrawing: Bool) -> Bool {
        editsCanvas && (fingerDrawing || (!pencilEditing && !stroke))
    }
}
