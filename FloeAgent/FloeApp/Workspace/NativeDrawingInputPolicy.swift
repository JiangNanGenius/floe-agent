// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit) && canImport(PencilKit)
import UIKit
import PencilKit

/// Pencil and a mouse draw immediately. The finger toggle controls only
/// direct touches; existing scrolling, zooming and selection keep their owners.
@MainActor enum NativeDrawingInputPolicy {
    static func apply(to canvas: PKCanvasView, fingerDrawing: Bool) {
        // pencilOnly also excludes a mouse. Filter the public drawing
        // recognizer so the finger setting does not change pointer behavior.
        if canvas.drawingPolicy != .anyInput { canvas.drawingPolicy = .anyInput }
        var types: [NSNumber] = [
            NSNumber(value: UITouch.TouchType.pencil.rawValue),
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue),
            NSNumber(value: UITouch.TouchType.indirect.rawValue)
        ]
        if fingerDrawing { types.append(NSNumber(value: UITouch.TouchType.direct.rawValue)) }
        if canvas.drawingGestureRecognizer.allowedTouchTypes != types {
            canvas.drawingGestureRecognizer.allowedTouchTypes = types
        }
    }
}
#endif
