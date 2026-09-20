// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeNotes

/// World-space edge painting for the native mind map: tree links, cross
/// connections (with their saved curve control points), summary brackets and
/// the live connection draft. Drawn inside the zoomed container so geometry
/// always matches the topic cards.
struct MindMapEdgesLayer: View {
    let document: NoteDocument
    let frames: [UUID: NoteRect]
    var connectionDraft: (source: NoteRect, point: CGPoint)?
    let colorScheme: ColorScheme

    var body: some View {
        ZStack {
            treeLinks
            connectionEdges
            summaryBrackets
            draftLine
        }
    }

    // MARK: - Tree links

    private var treeLinks: some View {
        var path = Path()
        for node in document.nodes where node.parentID != nil {
            guard let parent = node.parentID, let parentFrame = frames[parent], let childFrame = frames[node.id] else { continue }
            path.addPath(linkCurve(from: rect(parentFrame), to: rect(childFrame)))
        }
        return path
            .stroke(Color.primary.opacity(colorScheme == .dark ? 0.32 : 0.25), lineWidth: 2)
    }

    private func linkCurve(from parent: CGRect, to child: CGRect) -> Path {
        let growsRight = child.midX >= parent.midX
        let start = CGPoint(x: growsRight ? parent.maxX : parent.minX, y: parent.midY)
        let end = CGPoint(x: growsRight ? child.minX : child.maxX, y: child.midY)
        let reach = max(24, abs(end.x - start.x) * 0.5) * (growsRight ? 1 : -1)
        return Path { path in
            path.move(to: start)
            path.addCurve(to: end,
                          control1: CGPoint(x: start.x + reach, y: start.y),
                          control2: CGPoint(x: end.x - reach, y: end.y))
        }
    }

    // MARK: - Cross connections

    private var connectionEdges: some View {
        ForEach(document.connections) { edge in
            if let curve = connectionCurve(edge) {
                curve.path
                    .stroke(connectionColor(edge), style: connectionStyle(edge))
                    .overlay {
                        Arrowhead(tip: curve.end, tangent: curve.endTangent)
                            .fill(connectionColor(edge))
                        if edge.bidirectional == true {
                            Arrowhead(tip: curve.start, tangent: curve.startTangent)
                                .fill(connectionColor(edge))
                        }
                    }
                    .overlay {
                        if !edge.title.isEmpty {
                            Text(edge.title)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                                .background(.thinMaterial, in: Capsule())
                                .position(curve.midpoint)
                        }
                    }
            }
        }
    }

    private struct Curve {
        var path: Path
        var start: CGPoint
        var end: CGPoint
        var startTangent: CGPoint
        var endTangent: CGPoint
        var midpoint: CGPoint
    }

    private func connectionCurve(_ edge: MindMapConnection) -> Curve? {
        guard let fromFrame = frames[edge.from], let toFrame = frames[edge.to] else { return nil }
        let from = rect(fromFrame), to = rect(toFrame)
        let start = anchor(from, toward: CGPoint(x: to.midX, y: to.midY))
        let end = anchor(to, toward: CGPoint(x: from.midX, y: from.midY))
        let distance = hypot(end.x - start.x, end.y - start.y)
        guard distance > 0 else { return nil }
        let stub = max(24, distance * 0.25)
        let unit = CGPoint(x: (end.x - start.x) / distance, y: (end.y - start.y) / distance)
        let control1 = edge.delta1.map { CGPoint(x: start.x + $0.x, y: start.y + $0.y) }
            ?? CGPoint(x: start.x + unit.x * stub, y: start.y + unit.y * stub)
        let control2 = edge.delta2.map { CGPoint(x: end.x + $0.x, y: end.y + $0.y) }
            ?? CGPoint(x: end.x - unit.x * stub, y: end.y - unit.y * stub)
        let path = Path { value in
            value.move(to: start)
            value.addCurve(to: end, control1: control1, control2: control2)
        }
        return Curve(path: path, start: start, end: end,
                     startTangent: CGPoint(x: control1.x - start.x, y: control1.y - start.y),
                     endTangent: CGPoint(x: end.x - control2.x, y: end.y - control2.y),
                     midpoint: cubicPoint(start: start, control1: control1, control2: control2, end: end, t: 0.5))
    }

    private func connectionColor(_ edge: MindMapConnection) -> Color {
        if let hex = edge.style?["color"], let color = Color(floeHex: hex) { return color }
        return Color.accentColor.opacity(0.8)
    }

    private func connectionStyle(_ edge: MindMapConnection) -> StrokeStyle {
        let width = edge.style?["width"].flatMap(Double.init).map { max(1, min(8, $0)) } ?? 1.5
        let dashed = edge.style?["lineStyle"] == "dashed" || edge.style?["dash"] == "true"
        return StrokeStyle(lineWidth: width, dash: dashed ? [6, 4] : [])
    }

    // MARK: - Summary brackets

    private var summaryBrackets: some View {
        ForEach(document.summaries ?? []) { summary in
            if let bracket = summaryBracket(summary) {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                    Text(summary.label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .background(Color(uiColor: .systemBackground), in: Capsule())
                        .offset(x: 8, y: -9)
                }
                .frame(width: bracket.width, height: bracket.height)
                .position(x: bracket.midX, y: bracket.midY)
                .allowsHitTesting(false)
            }
        }
    }

    private func summaryBracket(_ summary: MindMapSummary) -> CGRect? {
        let children = MindMapLayout.orderedChildren(of: summary.parent, in: document)
        guard summary.start >= 0, summary.end < children.count else { return nil }
        var union = CGRect.null
        for child in children[summary.start...summary.end] {
            guard let frame = frames[child.id] else { return nil }
            union = union.union(rect(frame).insetBy(dx: -8, dy: -8))
        }
        return union.isNull ? nil : union.insetBy(dx: -6, dy: -6)
    }

    // MARK: - Draft

    @ViewBuilder private var draftLine: some View {
        if let draft = connectionDraft {
            let source = rect(draft.source)
            let start = anchor(source, toward: draft.point)
            Path { path in
                path.move(to: start)
                path.addLine(to: draft.point)
            }
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
            Circle()
                .fill(Color.accentColor)
                .frame(width: 8, height: 8)
                .position(draft.point)
        }
    }

    // MARK: - Geometry helpers

    private func rect(_ frame: NoteRect) -> CGRect {
        CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
    }

    /// Point where the ray from the rect center toward `target` exits the rect.
    private func anchor(_ rect: CGRect, toward target: CGPoint) -> CGPoint {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let dx = target.x - center.x
        let dy = target.y - center.y
        guard dx != 0 || dy != 0 else { return center }
        let tx = dx != 0 ? (rect.width / 2) / abs(dx) : .infinity
        let ty = dy != 0 ? (rect.height / 2) / abs(dy) : .infinity
        let scale = min(tx, ty)
        return CGPoint(x: center.x + dx * scale, y: center.y + dy * scale)
    }

    private func cubicPoint(start: CGPoint, control1: CGPoint, control2: CGPoint, end: CGPoint, t: CGFloat) -> CGPoint {
        let mt = 1 - t
        let x = mt * mt * mt * start.x + 3 * mt * mt * t * control1.x + 3 * mt * t * t * control2.x + t * t * t * end.x
        let y = mt * mt * mt * start.y + 3 * mt * mt * t * control1.y + 3 * mt * t * t * control2.y + t * t * t * end.y
        return CGPoint(x: x, y: y)
    }
}

/// Small filled triangle pointing along `tangent` with its tip at `tip`.
private struct Arrowhead: Shape {
    var tip: CGPoint
    var tangent: CGPoint

    func path(in rect: CGRect) -> Path {
        let length = hypot(tangent.x, tangent.y)
        guard length > 0 else { return Path() }
        let ux = tangent.x / length
        let uy = tangent.y / length
        let base = CGPoint(x: tip.x - ux * 9, y: tip.y - uy * 9)
        let side = CGPoint(x: -uy, y: ux)
        return Path { path in
            path.move(to: tip)
            path.addLine(to: CGPoint(x: base.x + side.x * 4.5, y: base.y + side.y * 4.5))
            path.addLine(to: CGPoint(x: base.x - side.x * 4.5, y: base.y - side.y * 4.5))
            path.closeSubpath()
        }
    }
}

private extension Color {
    init?(floeHex hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.first == "#" else { return nil }
        value.removeFirst()
        guard value.count == 6 || value.count == 8, let number = UInt64(value, radix: 16) else { return nil }
        let red, green, blue, alpha: Double
        if value.count == 6 {
            red = Double((number >> 16) & 0xFF) / 255
            green = Double((number >> 8) & 0xFF) / 255
            blue = Double(number & 0xFF) / 255
            alpha = 1
        } else {
            red = Double((number >> 24) & 0xFF) / 255
            green = Double((number >> 16) & 0xFF) / 255
            blue = Double((number >> 8) & 0xFF) / 255
            alpha = Double(number & 0xFF) / 255
        }
        self = Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}
#endif
