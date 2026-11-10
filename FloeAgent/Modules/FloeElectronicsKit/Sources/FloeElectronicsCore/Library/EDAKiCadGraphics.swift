// SPDX-License-Identifier: MPL-2.0
import Foundation

enum EDAKiCadGraphics {
    static func point(_ node: EDASExpression, footprint: Bool) throws -> EDAPoint {
        let value = try node.point(); return .init(value.x, footprint ? -value.y : value.y)
    }
    static func read(_ node: EDASExpression, footprint: Bool) throws -> [EDAGraphic] {
        let tag = node.tag ?? ""
        let stroke = try node.child("stroke")?.child("width")?.number() ?? node.child("width")?.number() ?? 0.15
        // KiCad width=0 means the default stroke, not an omitted graphic.
        let width = stroke == 0 ? 0.15 : stroke
        func p(_ name: String) throws -> EDAPoint {
            guard let child = node.child(name) else { throw EDAError.invalid("missing graphic " + name) }
            return try point(child, footprint: footprint)
        }
        switch tag {
        case "polyline", "fp_poly":
            guard let pts = node.child("pts") else { throw EDAError.invalid("polyline points") }
            let points = try pts.children("xy").map { try point($0, footprint: footprint) }
            guard points.count >= 2 else { throw EDAError.invalid("polyline points") }
            return zip(points, points.dropFirst()).map { .line($0, $1, width: width) }
        case "rectangle", "fp_rect": return [try .rectangle(p("start"), p("end"), width: width)]
        case "circle", "fp_circle":
            let center = try p("center")
            let radius: Double
            if let declared = node.child("radius") { radius = try declared.number() }
            else { radius = try center.distance(to: p("end")) }
            return [.circle(center: center, radius: radius, width: width)]
        case "fp_line": return [try .line(p("start"), p("end"), width: width)]
        case "point":
            let at = try p("at"), size = try node.child("size")?.number() ?? 1
            return [.line(at + .init(-size / 2, 0), at + .init(size / 2, 0), width: width),
                    .line(at + .init(0, -size / 2), at + .init(0, size / 2), width: width)]
        case "arc", "fp_arc":
            let a = try p("start"), b = try p("mid"), c = try p("end")
            let d = 2 * (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y))
            guard abs(d) > 1e-10 else { throw EDAError.invalid("collinear arc") }
            let aa = a.x * a.x + a.y * a.y, bb = b.x * b.x + b.y * b.y, cc = c.x * c.x + c.y * c.y
            let center = EDAPoint((aa * (b.y - c.y) + bb * (c.y - a.y) + cc * (a.y - b.y)) / d,
                (aa * (c.x - b.x) + bb * (a.x - c.x) + cc * (b.x - a.x)) / d)
            func angle(_ q: EDAPoint) -> Double { atan2(q.y - center.y, q.x - center.x) * 180 / .pi }
            func positive(_ x: Double) -> Double { (x.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) }
            let start = angle(a), mid = positive(angle(b) - start), end = positive(angle(c) - start)
            return [.arc(center: center, radius: center.distance(to: a), start: start, sweep: mid <= end ? end : end - 360, width: width)]
        case "text", "fp_text", "property":
            guard let at = node.child("at") else { throw EDAError.invalid("text position") }
            let text = tag == "text" ? node.value() : node.value(2)
            guard let text else { throw EDAError.invalid("graphic text") }
            let fontSize = try node.child("effects")?.child("font")?.child("size")?.number() ?? 1
            let angle = try at.items.count > 3 ? at.number(3) : 0
            return [try .text(text, position: point(at, footprint: footprint), height: fontSize, angle: footprint ? -angle : angle)]
        default: throw EDAError.unsupported("KiCad graphic " + tag)
        }
    }
}
