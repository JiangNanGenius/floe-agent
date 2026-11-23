// SPDX-License-Identifier: MPL-2.0

/// A bundled visual-novel interpreter driven by the App's main thread.
@MainActor
public protocol VisualNovelGameSession: AnyObject {
    func start() throws
    func tick() -> Bool
    func currentFrame() -> VisualNovelFrame?
    func canvasSize() -> (width: Int32, height: Int32)
    func pointerDown(x: Float, y: Float, button: Int32)
    func pointerMoved(x: Float, y: Float, button: Int32)
    func pointerUp(x: Float, y: Float, button: Int32)
    func pointerCancelled(x: Float, y: Float, button: Int32)
    func rightClick(x: Float, y: Float)
    func touch(phase: Int32, x: Float, y: Float, id: Int32)
    func key(virtualKey: Int32, down: Bool)
    func stop()
}
