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
let panel = NSWindow(contentRect: NSRect(x: 30, y: 40, width: 340, height: 130), styleMask: [.titled, .closable], backing: .buffered, defer: false)
panel.title = "Floe Background QA"
let field = NSTextField(string: "Fixture initial")
field.frame = NSRect(x: 15, y: 72, width: 300, height: 24)
field.setAccessibilityIdentifier("fixture-title")
let button = NSButton(title: "Record fixture click", target: handler, action: #selector(Handler.click(_:)))
button.frame = NSRect(x: 15, y: 20, width: 220, height: 28)
panel.contentView?.addSubview(field)
panel.contentView?.addSubview(button)
DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { panel.orderBack(nil) }
var activated = false
func record() {
    let current = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
    if current == getpid() { activated = true }
    let state: [String: Any] = ["pid": getpid(), "window": panel.isVisible ? panel.windowNumber : 0, "value": field.stringValue, "clicked": handler.pressed, "foregroundBefore": before, "foregroundNow": current, "becameFrontmost": activated]
    if let data = try? JSONSerialization.data(withJSONObject: state) { try? data.write(to: evidence.appendingPathComponent("state.json"), options: .atomic) }
}
_ = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in record() }
record()
_ = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { _ in record() }
app.run()
