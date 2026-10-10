import CoreGraphics

/// Screen-space annotation only: never changes the circle or its dimension.
struct SketchDiameterDimensionLayout {
    var start: CGPoint
    var end: CGPoint
    var tail: CGPoint
    var anchor: CGPoint
    var rotation: Double
    var targetSize: CGSize

    static func make(start: CGPoint, end: CGPoint, anchor: CGPoint,
                     clearance: CGFloat, available: CGRect,
                     textWidth: CGFloat, allowVertical: Bool = true,
                     manualAnchor: CGPoint? = nil, preferVertical: Bool = false) -> Self? {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 1 else { return nil }
        if allowVertical, let requested = manualAnchor {
            let center = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            let vx = requested.x - center.x, vy = requested.y - center.y
            let distance = hypot(vx, vy)
            if distance > 1 {
                let ux = vx / distance, uy = vy / distance, radius = length / 2
                let near = CGPoint(x: center.x + ux * radius, y: center.y + uy * radius)
                let far = CGPoint(x: center.x - ux * radius, y: center.y - uy * radius)
                let labelDistance = max(distance, radius + max(44, textWidth) / 2 + 24)
                let tailDistance = labelDistance + max(44, textWidth) / 2 + 12
                var angle = atan2(Double(vy), Double(vx))
                if angle > .pi / 2 { angle -= .pi }
                if angle < -.pi / 2 { angle += .pi }
                let textAnchor = CGPoint(
                    x: center.x + ux * labelDistance + CGFloat(sin(angle)) * 20,
                    y: center.y + uy * labelDistance - CGFloat(cos(angle)) * 20)
                let w = max(44, textWidth), c = abs(CGFloat(cos(angle))), t = abs(CGFloat(sin(angle)))
                return Self(start: far, end: near,
                    tail: CGPoint(x: center.x + ux * tailDistance, y: center.y + uy * tailDistance),
                    anchor: textAnchor, rotation: angle,
                    targetSize: CGSize(width: max(44, c * w + t * 20),
                                       height: max(44, t * w + c * 20)))
            }
        }
        var rotation = atan2(Double(dy), Double(dx))
        if rotation > .pi / 2 { rotation -= .pi }
        if rotation < -.pi / 2 { rotation += .pi }
        let ordinary = CGPoint(x: anchor.x + CGFloat(sin(rotation)) * clearance,
                               y: anchor.y - CGFloat(cos(rotation)) * clearance)
        let target = CGRect(x: ordinary.x - max(44, textWidth) / 2,
                            y: ordinary.y - 22,
                            width: max(44, textWidth), height: 44)
        if !allowVertical || (!preferVertical && available.contains(target)) {
            return Self(start: start, end: end, tail: end,
                        anchor: ordinary, rotation: rotation,
                        targetSize: CGSize(width: max(44, textWidth), height: 44))
        }
        // Normal selection and side-chrome fallback use the native outside leader.
        // Prefer above/right for selection; fit near-edge labels inside the canvas.
        let center = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let radius = length / 2
        let upward = preferVertical
            ? center.y - radius - available.minY >= max(44, textWidth) + 48
            : center.y - available.minY >= available.maxY - center.y
        let sign: CGFloat = upward ? -1 : 1
        let near = CGPoint(x: center.x, y: center.y + sign * radius)
        let far = CGPoint(x: center.x, y: center.y - sign * radius)
        let room = upward ? near.y - available.minY : available.maxY - near.y
        let extensionLength = max(0, min(220, room))
        let tail = CGPoint(x: near.x, y: near.y + sign * extensionLength)
        func fit(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
            high >= low ? min(max(value, low), high) : (low + high) / 2
        }
        let inward: CGFloat = preferVertical
            ? (center.x + 46 <= available.maxX ? 1 : -1)
            : (center.x > available.midX ? -1 : 1)
        let x = fit(center.x + inward * 24, available.minX + 22, available.maxX - 22)
        let halfText = max(44, textWidth) / 2
        let y = fit(near.y + sign * extensionLength * 0.7,
                    available.minY + halfText, available.maxY - halfText)
        return Self(start: far, end: near, tail: tail,
                    anchor: CGPoint(x: x, y: y), rotation: .pi / 2,
                    targetSize: CGSize(width: 44, height: max(44, textWidth)))
    }
}
