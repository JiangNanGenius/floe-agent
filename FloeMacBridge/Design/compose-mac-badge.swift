import AppKit
let args = CommandLine.arguments
let source = NSImage(contentsOfFile: args[1])!
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
NSGraphicsContext.current!.imageInterpolation = .high
source.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
let badge = NSRect(x: 768, y: 66, width: 180, height: 180)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.48); shadow.shadowBlurRadius = 15; shadow.shadowOffset = NSSize(width: 0, height: -7); shadow.set()
let path = NSBezierPath(roundedRect: badge, xRadius: 42, yRadius: 42)
NSGradient(colors: [NSColor(calibratedRed: 0.16, green: 0.22, blue: 0.33, alpha: 1), NSColor(calibratedRed: 0.045, green: 0.075, blue: 0.145, alpha: 1)])!.draw(in: path, angle: -90)
NSGraphicsContext.restoreGraphicsState()
NSColor(calibratedRed: 0.68, green: 0.83, blue: 1, alpha: 0.65).setStroke(); path.lineWidth = 3; path.stroke()
let monitor = NSRect(x: badge.minX + 30, y: badge.minY + 57, width: 120, height: 82)
let frame = NSBezierPath(roundedRect: monitor, xRadius: 9, yRadius: 9)
NSColor(calibratedRed: 0.91, green: 0.95, blue: 1, alpha: 1).setStroke(); frame.lineWidth = 8; frame.stroke()
let screen = NSBezierPath(roundedRect: monitor.insetBy(dx: 8, dy: 8), xRadius: 3, yRadius: 3)
NSGradient(colors: [NSColor(calibratedRed: 0.05, green: 0.68, blue: 0.96, alpha: 1), NSColor(calibratedRed: 0.18, green: 0.26, blue: 0.66, alpha: 1)])!.draw(in: screen, angle: -60)
let foot = NSBezierPath(); foot.move(to: NSPoint(x: badge.midX, y: badge.minY + 53)); foot.line(to: NSPoint(x: badge.midX, y: badge.minY + 35)); foot.move(to: NSPoint(x: badge.midX - 27, y: badge.minY + 32)); foot.line(to: NSPoint(x: badge.midX + 27, y: badge.minY + 32)); foot.lineWidth = 8; foot.lineCapStyle = .round; foot.stroke()
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
