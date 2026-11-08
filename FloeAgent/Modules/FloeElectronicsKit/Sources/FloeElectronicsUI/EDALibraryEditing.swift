// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeElectronicsCore

/// Pure helpers behind the symbol/footprint library canvases. They only read
/// definitions and produce values the existing session commits; no editor
/// state, storage or tool registry lives here.
enum EDLibraryHit: Equatable {
    case pin(UUID)
    case pad(UUID)
    /// Index into the definition's `graphics` array.
    case graphic(Int)
}

enum EDLibraryEditing {
    // MARK: - Hit testing

    static func hitSymbol(_ definition: EDASymbolDefinition, at point: EDAPoint, tolerance: Double) -> EDLibraryHit? {
        var best: (Double, EDLibraryHit)?
        func consider(_ distance: Double, _ hit: EDLibraryHit) {
            guard distance <= tolerance else { return }
            if let current = best, current.0 < distance { return }
            best = (distance, hit)
        }
        for pin in definition.pins { consider(point.distance(to: pin.position), .pin(pin.id)) }
        for (index, graphic) in definition.graphics.enumerated() {
            consider(distance(point, to: graphic), .graphic(index))
        }
        return best?.1
    }

    static func hitFootprint(_ definition: EDAFootprintDefinition, at point: EDAPoint, tolerance: Double) -> EDLibraryHit? {
        var best: (Double, EDLibraryHit)?
        func consider(_ distance: Double, _ hit: EDLibraryHit) {
            guard distance <= tolerance else { return }
            if let current = best, current.0 < distance { return }
            best = (distance, hit)
        }
        for pad in definition.pads {
            let distance = pad.shape == .polygon ? EDCanvasInteraction.padDistance(point,pad) : point.distance(to:pad.position)
            consider(distance,.pad(pad.id))
        }
        for (index, graphic) in definition.graphics.enumerated() {
            consider(distance(point, to: graphic), .graphic(index))
        }
        return best?.1
    }

    static func distance(_ point: EDAPoint, to graphic: EDAGraphic) -> Double {
        func segment(_ a: EDAPoint, _ b: EDAPoint) -> Double {
            let ab = b - a, lengthSquared = ab.x * ab.x + ab.y * ab.y
            guard lengthSquared > 1e-12 else { return point.distance(to: a) }
            let t = max(0, min(1, ((point.x - a.x) * ab.x + (point.y - a.y) * ab.y) / lengthSquared))
            return point.distance(to: .init(a.x + t * ab.x, a.y + t * ab.y))
        }
        switch graphic {
        case .line(let a, let b, _): return segment(a, b)
        case .rectangle(let a, let b, _):
            let c = EDAPoint(b.x, a.y), d = EDAPoint(a.x, b.y)
            return min(segment(a, c), segment(c, b), segment(b, d), segment(d, a))
        case .circle(let center, let radius, _):
            return abs(point.distance(to: center) - radius)
        case .arc(let center, let radius, let start, let sweep, let width):
            guard point.isValid, center.isValid, radius.isFinite, radius > 0,
                  start.isFinite, sweep.isFinite, width.isFinite, width > 0 else { return .infinity }
            let delta = point - center, angle = atan2(delta.y, delta.x) * 180 / .pi
            var offset = (sweep >= 0 ? angle - start : start - angle).truncatingRemainder(dividingBy: 360)
            if offset < 0 { offset += 360 }
            let radial = abs(delta.length - radius)
            let a = EDAPoint(radius, 0).transformed(origin: center, angle: start)
            let b = EDAPoint(radius, 0).transformed(origin: center, angle: start + sweep)
            let distance = abs(sweep) >= 360 || offset <= abs(sweep) ? radial : min(point.distance(to: a), point.distance(to: b))
            return max(0, distance - width / 2)
        case .text(_, let position, _, _): return point.distance(to: position)
        case .dimension(let a, let b, _): return segment(a, b)
        }
    }

    // MARK: - Shape construction (one committed edit per finished gesture)

    static func lineShape(from start: EDAPoint, to end: EDAPoint, stroke: Double = 0.2) -> EDAGraphic? {
        guard start != end, stroke > 0 else { return nil }
        return .line(start, end, width: stroke)
    }

    static func rectangleShape(from start: EDAPoint, to end: EDAPoint, stroke: Double = 0.2) -> EDAGraphic? {
        guard start != end, stroke > 0 else { return nil }
        return .rectangle(start, end, width: stroke)
    }

    static func circleShape(from center: EDAPoint, to edge: EDAPoint, stroke: Double = 0.2) -> EDAGraphic? {
        let radius = center.distance(to: edge)
        guard radius > 0.01, stroke > 0 else { return nil }
        return .circle(center: center, radius: radius, width: stroke)
    }

    static func translated(_ graphic: EDAGraphic, by delta: EDAPoint) -> EDAGraphic {
        switch graphic {
        case .line(let a, let b, let width): return .line(a + delta, b + delta, width: width)
        case .rectangle(let a, let b, let width): return .rectangle(a + delta, b + delta, width: width)
        case .circle(let center, let radius, let width): return .circle(center: center + delta, radius: radius, width: width)
        case .arc(let center, let radius, let start, let sweep, let width):
            return .arc(center: center + delta, radius: radius, start: start, sweep: sweep, width: width)
        case .text(let value, let position, let height, let angle):
            return .text(value, position: position + delta, height: height, angle: angle)
        case .dimension(let a, let b, let offset): return .dimension(a + delta, b + delta, offset: offset)
        }
    }

    // MARK: - Automatic numbering (pin/pad numbers must stay unique per unit)

    static func nextPinNumber(_ pins: [EDAPin]) -> String {
        let used = Set(pins.map(\.number))
        var candidate = 1
        while used.contains(String(candidate)) { candidate += 1 }
        return String(candidate)
    }

    static func nextPadNumber(_ pads: [EDAPad]) -> String {
        let used = Set(pads.map(\.number))
        var candidate = 1
        while used.contains(String(candidate)) { candidate += 1 }
        return String(candidate)
    }
}

// MARK: - Localized, unit-carrying display names

func edaPinTypeTitle(_ type: EDAPinType) -> String {
    switch type {
    case .input: return edText("输入", "Input")
    case .output: return edText("输出", "Output")
    case .bidirectional: return edText("双向", "Bidirectional")
    case .triState: return edText("三态", "Tri-state")
    case .passive: return edText("无源", "Passive")
    case .powerInput: return edText("电源输入", "Power input")
    case .powerOutput: return edText("电源输出", "Power output")
    case .openCollector: return edText("集电极开路", "Open collector")
    case .openEmitter: return edText("发射极开路", "Open emitter")
    case .noConnect: return edText("不连接", "No connect")
    case .unspecified: return edText("未指定", "Unspecified")
    }
}

func edaPadShapeTitle(_ shape: EDAPadShape) -> String {
    switch shape {
    case .circle: return edText("圆形", "Circle")
    case .rectangle: return edText("矩形", "Rectangle")
    case .oval: return edText("椭圆形", "Oval")
    case .roundRectangle: return edText("圆角矩形", "Rounded rectangle")
    case .polygon: return edText("自定义多边形", "Custom polygon")
    }
}

func edaGraphicKindTitle(_ graphic: EDAGraphic) -> String {
    switch graphic {
    case .line: return edText("线段", "Line")
    case .rectangle: return edText("矩形", "Rectangle")
    case .circle: return edText("圆", "Circle")
    case .arc: return edText("圆弧", "Arc")
    case .text: return edText("文字", "Text")
    case .dimension: return edText("尺寸", "Dimension")
    }
}

/// Readable geometry summary with units, e.g. "(-0.80, -2.54) → (0.80, 2.54) · 0.30 mm".
func edaGraphicSummary(_ graphic: EDAGraphic) -> String {
    func mm(_ value: Double) -> String { String(format: "%.2f", value) }
    func point(_ value: EDAPoint) -> String { "(\(mm(value.x)), \(mm(value.y)))" }
    switch graphic {
    case .line(let a, let b, let width):
        return "\(point(a)) → \(point(b)) · \(mm(width)) mm"
    case .rectangle(let a, let b, let width):
        return "\(point(a)) – \(point(b)) · \(mm(width)) mm"
    case .circle(let center, let radius, let width):
        return edText("圆心 ", "Center ") + point(center) + " · " + edText("半径", "Radius") + " \(mm(radius)) mm · \(mm(width)) mm"
    case .arc(let center, let radius, let start, let sweep, let width):
        return point(center) + " · " + edText("半径", "radius") + " \(mm(radius)) mm · \(mm(start))°→\(mm(sweep))° · \(mm(width)) mm"
    case .text(let value, let position, let height, let angle):
        return "“\(value)” " + point(position) + " · \(mm(height)) mm" + (angle == 0 ? "" : " · \(mm(angle))°")
    case .dimension(let a, let b, let offset):
        return "\(point(a)) → \(point(b)) · \(mm(a.distance(to: b))) mm" + (offset == 0 ? "" : " · \(mm(offset)) mm")
    }
}
