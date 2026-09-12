// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import UIKit
import PencilKit
import FloeNotes

/// Shared by the editor, selection captures and exports, in stable page coordinates.
@MainActor enum NotePageRenderer {
    static func draw(_ page: NotePage, background: UIImage?, images: [UUID: UIImage] = [:], backgroundDrawing: (() -> Void)? = nil) {
        let bounds = CGRect(x: 0, y: 0, width: page.width, height: page.height)
        UIColor.white.setFill(); UIRectFill(bounds)
        background?.draw(in: bounds)
        backgroundDrawing?()
        if page.paper != .plain, background == nil, backgroundDrawing == nil, let context = UIGraphicsGetCurrentContext() {
            context.saveGState(); defer { context.restoreGState() }
            context.setStrokeColor(UIColor(white: 0.84, alpha: 1).cgColor); context.setLineWidth(0.5)
            for y in stride(from: 32.0, to: page.height, by: 32) {
                context.move(to: CGPoint(x: 0, y: y)); context.addLine(to: CGPoint(x: page.width, y: y))
            }
            if page.paper == .grid {
                for x in stride(from: 32.0, to: page.width, by: 32) {
                    context.move(to: CGPoint(x: x, y: 0)); context.addLine(to: CGPoint(x: x, y: page.height))
                }
            }
            context.strokePath()
        }
        for element in page.elements {
            let frame = CGRect(x: element.frame.x, y: element.frame.y, width: element.frame.width, height: element.frame.height)
            let tint = color(element.color)
            switch element.kind {
            case .text:
                (element.text as NSString).draw(in: frame, withAttributes: [.font: UIFont.systemFont(ofSize: element.fontSize), .foregroundColor: tint])
            case .image:
                if let id = element.resourceID { images[id]?.draw(in: frame) }
            case .rectangle, .ellipse, .line, .arrow:
                let path: UIBezierPath
                if element.kind == .rectangle { path = UIBezierPath(rect: frame) }
                else if element.kind == .ellipse { path = UIBezierPath(ovalIn: frame) }
                else {
                    path = UIBezierPath(); path.move(to: frame.origin); path.addLine(to: CGPoint(x: frame.maxX, y: frame.maxY))
                    if element.kind == .arrow {
                        let angle = atan2(frame.height, frame.width)
                        for offset in [-0.5, 0.5] {
                            path.move(to: CGPoint(x: frame.maxX - 18 * cos(angle + offset), y: frame.maxY - 18 * sin(angle + offset)))
                            path.addLine(to: CGPoint(x: frame.maxX, y: frame.maxY))
                        }
                    }
                }
                tint.setStroke(); path.lineWidth = 2; path.stroke()
            }
        }
    }

    static func color(_ hex: String) -> UIColor {
        let value = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard value.count == 6, let number = UInt32(value, radix: 16) else { return .black }
        return UIColor(red: CGFloat((number >> 16) & 255) / 255, green: CGFloat((number >> 8) & 255) / 255,
                       blue: CGFloat(number & 255) / 255, alpha: 1)
    }
}
#endif
