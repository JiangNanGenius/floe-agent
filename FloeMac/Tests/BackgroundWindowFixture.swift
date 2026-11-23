import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let evidence = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let before = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
final class Handler: NSObject {
    var pressed = 0
    @objc func click(_ sender: Any?) { pressed += 1 }
}
let handler = Handler()

/// Content-wide recorder for synthetic drag strokes. It sits behind the other
/// controls so any background drag the companion delivers to empty content is
/// captured in top-left-origin content points; the drag delta then matches the
/// window screenshot pixel delta exactly (screenshot px are 2x points).
final class DragSurfaceView: NSView {
    var onStroke: (([String: Double]) -> Void)?
    private var start: NSPoint?
    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
    }
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        let end = convert(event.locationInWindow, from: nil)
        guard let start else { return }
        self.start = nil
        onStroke?(["fromX": Double(start.x), "fromY": Double(start.y),
                   "toX": Double(end.x), "toY": Double(end.y)])
    }
}

let panel = NSWindow(contentRect: NSRect(x: 30, y: 40, width: 340, height: 220), styleMask: [.titled, .closable], backing: .buffered, defer: false)
panel.title = "Floe Background QA"
let field = NSTextField(string: "Fixture initial")
field.frame = NSRect(x: 15, y: 150, width: 300, height: 24)
field.setAccessibilityIdentifier("fixture-title")
let button = NSButton(title: "Record fixture click", target: handler, action: #selector(Handler.click(_:)))
button.frame = NSRect(x: 15, y: 95, width: 220, height: 28)
let dragSurface = DragSurfaceView(frame: NSRect(x: 0, y: 0, width: 340, height: 220))
dragSurface.wantsLayer = true
dragSurface.layer?.backgroundColor = NSColor.systemTeal.withAlphaComponent(0.25).cgColor
panel.contentView?.addSubview(dragSurface)
panel.contentView?.addSubview(field)
panel.contentView?.addSubview(button)
panel.initialFirstResponder = field
panel.makeFirstResponder(field)
var keysPressed: [String] = []
var drags: [[String: Double]] = []
dragSurface.onStroke = { stroke in drags.append(stroke) }
let keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
    if let text = event.characters, !text.isEmpty { keysPressed.append(text) }
    else { keysPressed.append("key\(event.keyCode)") }
    return event
}
DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { panel.orderBack(nil) }
var activated = false
func record() {
    let current = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
    if current == getpid() { activated = true }
    let state: [String: Any] = ["pid": getpid(), "window": panel.isVisible ? panel.windowNumber : 0, "value": field.stringValue, "clicked": handler.pressed, "foregroundBefore": before, "foregroundNow": current, "becameFrontmost": activated, "keysPressed": keysPressed, "drags": drags]
    if let data = try? JSONSerialization.data(withJSONObject: state) { try? data.write(to: evidence.appendingPathComponent("state.json"), options: .atomic) }
}
_ = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in record() }
record()
_ = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { _ in record() }
app.run()
