// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import UIKit

/// Applies only to freehand ink, never layer movement, selection or video gestures.
enum MediaDrawingInputPolicy {
    static let preferenceKey = "workbench.fingerDrawing.enabled"
    static func isStrokeTool(_ tool: String) -> Bool {
        ["image.brush", "image.eraser", "image.pen"].contains(tool)
    }
    static func allows(_ source: UITouch.TouchType, fingerDrawing: Bool) -> Bool {
        switch source {
        case .pencil, .indirect, .indirectPointer: true
        case .direct: fingerDrawing
        @unknown default: false
        }
    }
}

/// A rejected/cancelled touch cannot later end as a stroke. Opting out during
/// a finger stroke revokes that whole stroke, even if toggled on before lift.
struct MediaStrokeInputGate {
    private(set) var source: UITouch.TouchType?
    private var revoked = false
    mutating func begin(_ source: UITouch.TouchType, fingerDrawing: Bool) -> Bool {
        guard self.source == nil, MediaDrawingInputPolicy.allows(source, fingerDrawing: fingerDrawing) else { return false }
        self.source = source; revoked = false
        return true
    }
    mutating func update(fingerDrawing: Bool) {
        if let source, !MediaDrawingInputPolicy.allows(source, fingerDrawing: fingerDrawing) { revoked = true }
    }
    func permitsSamples(fingerDrawing: Bool) -> Bool {
        guard let source else { return false }
        return !revoked && MediaDrawingInputPolicy.allows(source, fingerDrawing: fingerDrawing)
    }
    mutating func finish(fingerDrawing: Bool) -> Bool {
        defer { cancel() }
        return permitsSamples(fingerDrawing: fingerDrawing)
    }
    mutating func cancel() { source = nil; revoked = false }
}

struct MediaDrawingInputMenu: View {
    @AppStorage(MediaDrawingInputPolicy.preferenceKey) private var enabled = false
    var body: some View {
        Menu {
            Toggle(isOn: $enabled) {
                Label(WorkbenchText.t("手指绘图", "Draw with Finger"), systemImage: "hand.draw")
            }
            .accessibilityIdentifier("media.fingerDrawing.toggle")
        } label: {
            Image(systemName: enabled ? "hand.draw.fill" : "hand.draw")
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel(WorkbenchText.t("绘图输入", "Drawing input"))
        .accessibilityValue(enabled
            ? WorkbenchText.t("手指绘图已开启", "Finger drawing on")
            : WorkbenchText.t("手指绘图已关闭", "Finger drawing off"))
        .accessibilityIdentifier("media.drawingInput.menu")
        .help(WorkbenchText.t("绘图输入", "Drawing input"))
    }
}
#endif
