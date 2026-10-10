//
//  SketchLiveDimensionOverlay.swift
//  openshape3d
//
//  The dimensions shown WHILE a sketch stroke is in flight (spec §1.1) — the
//  "480 mm / 210 mm" a rectangle reads as you drag it out, the "Ø661.60 mm" a
//  circle reads. Distinct from `SketchDimensionOverlay`, which draws the
//  PERSISTED driving dimensions: nothing here is tappable or stored, it exists
//  only for the duration of the drag.
//
//  Everything is projected from world space, so the annotation reads correctly
//  with the camera at any angle — which is the point, since sketching no longer
//  forces a head-on view.
//

import SwiftUI

// The Metal canvas has a fixed light gradient, even with dark UI chrome.
// Annotation ink follows that canvas, not the system foreground (white in dark mode).
struct SketchLiveDimensionOverlay: View {
    @Bindable var viewModel: EditorViewModel

    /// Half-length of an arrow head, in points.
    private static let arrowLength: CGFloat = 9
    private static let arrowHalfWidth: CGFloat = 3.5
    /// Half-length of the tick that marks where a diameter meets the circle.
    private static let edgeTickHalfLength: CGFloat = 7

    var body: some View {
        // Reproject whenever the camera moves.
        let _ = viewModel.cameraEpoch
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ForEach(viewModel.liveDimensionLabels, id: \.id) { label in
                    dimensionView(label, in: geo.size)
                }
            }
        }
        // Purely informational — taps must reach the sketch underneath.
        .allowsHitTesting(false)
        // The Metal viewport is full-bleed; a SwiftUI overlay is safe-area
        // inset by default, which would draw every projected point ~85pt
        // below the geometry it annotates.
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func dimensionView(_ label: EditorViewModel.LiveDimensionLabel,
                               in size: CGSize) -> some View {
        if !label.worldArcPoints.isEmpty, let arc = arcLeader(label) {
            Path { path in
                path.addLines(arc.points)
                path.move(to: arc.center)
                path.addLine(to: arc.points[0])
                path.move(to: arc.center)
                path.addLine(to: arc.points[arc.points.count - 1])
            }
            .stroke(Color.black.opacity(0.85), lineWidth: 1)
            arrowHead(at: arc.points[0], pointingFrom: arc.points[1])
            arrowHead(at: arc.points[arc.points.count - 1],
                      pointingFrom: arc.points[arc.points.count - 2])
            liveText(label.text, rotation: arc.rotation, at: arc.anchor)
        } else if label.isArcRadius,
                  let center = project(label.worldLineStart),
                  let tip = project(label.worldLineEnd),
                  let radial = radiusLeader(center: center, tip: tip, in: size) {
            Path { path in
                path.move(to: center)
                path.addLine(to: radial.tail)
            }
            .stroke(Color.black.opacity(0.85), lineWidth: 1)
            arrowHead(at: tip, pointingFrom: radial.tail)
            liveText(label.text, rotation: radial.rotation, at: radial.anchor)
        } else if let geometry = linearGeometry(label),
                  hypot(geometry.lineEnd.x - geometry.lineStart.x,
                        geometry.lineEnd.y - geometry.lineStart.y) > 1 {
            let lineStart = geometry.lineStart, lineEnd = geometry.lineEnd
            let witnessStart = geometry.witnessStart, witnessEnd = geometry.witnessEnd

            // Witness lines: thin leaders from the geometry out to the
            // dimension line. Skipped entirely for a dimension drawn straight
            // across the shape, where they would be zero-length.
            if label.hasWitnessLines {
                Path { path in
                    path.move(to: witnessStart)
                    path.addLine(to: lineStart)
                    path.move(to: witnessEnd)
                    path.addLine(to: lineEnd)
                }
                .stroke(Color.black.opacity(0.45), lineWidth: 0.75)
            }

            Path { path in
                path.move(to: lineStart)
                path.addLine(to: lineEnd)
            }
            .stroke(Color.black.opacity(0.85), lineWidth: 1)

            // Ticks ON the circle where the diameter meets it — without them
            // the arrowheads float against the curve with nothing saying where
            // the measurement is actually taken.
            if label.drawsEdgeTicks {
                Path { path in
                    appendTick(&path, at: lineStart, along: lineEnd)
                    appendTick(&path, at: lineEnd, along: lineStart)
                }
                .stroke(Color.black.opacity(0.85), lineWidth: 1.25)
            }

            arrowHead(at: lineStart, pointingFrom: lineEnd)
            arrowHead(at: lineEnd, pointingFrom: lineStart)

            liveText(label.text,
                     rotation: readableAngle(from: lineStart, to: lineEnd), at: geometry.anchor,
                     outlined: label.isPendingRectangleBaseline)
        }
    }

    private func linearGeometry(_ label: EditorViewModel.LiveDimensionLabel)
        -> (lineStart: CGPoint, lineEnd: CGPoint, witnessStart: CGPoint,
            witnessEnd: CGPoint, anchor: CGPoint)? {
        guard var start = project(label.worldLineStart),
              var end = project(label.worldLineEnd),
              let a = project(label.worldWitnessStart),
              let b = project(label.worldWitnessEnd),
              var anchor = project(label.worldLabel) else { return nil }
        if label.isPendingRectangleBaseline {
            // Native keeps this distance fixed as baseline length changes.
            // Match completed rectangle leaders (100 view points), not the
            // generic in-flight measurement's length-proportional world offset.
            let dx = start.x - a.x, dy = start.y - a.y
            let length = hypot(dx, dy)
            guard length > 0.001 else { return nil }
            let nx = dx / length, ny = dy / length
            start = CGPoint(x: a.x + nx * 100, y: a.y + ny * 100)
            end = CGPoint(x: b.x + nx * 100, y: b.y + ny * 100)
            // Native places the value above its readable text baseline.
            // Reversing construction moves the leader to the other side of
            // the geometry, but must not flip the value below that leader.
            let angle = readableAngle(from: start, to: end)
            anchor = CGPoint(x: (start.x + end.x) / 2 + CGFloat(sin(angle)) * 24,
                             y: (start.y + end.y) / 2 - CGFloat(cos(angle)) * 24)
        }
        return (start, end, a, b, anchor)
    }

    private func liveText(_ text: String, rotation: Double, at anchor: CGPoint,
                          outlined: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 16))
            .foregroundStyle(Color.black)
            .monospacedDigit()
            .fixedSize()
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background {
                if outlined {
                    RoundedRectangle(cornerRadius: 3).fill(Color.white)
                        .overlay(RoundedRectangle(cornerRadius: 3)
                            .stroke(Color.blue, lineWidth: 1.5))
                }
            }
            .rotationEffect(.radians(rotation))
            .position(anchor)
            .accessibilityIdentifier("LiveDimension")
    }

    private func arcLeader(_ label: EditorViewModel.LiveDimensionLabel)
        -> (points: [CGPoint], center: CGPoint, anchor: CGPoint, rotation: Double)? {
        guard let worldCenter = label.worldArcCenter,
              let center = project(worldCenter), label.worldArcPoints.count > 2 else { return nil }
        let projected = label.worldArcPoints.compactMap(project)
        guard projected.count == label.worldArcPoints.count else { return nil }
        func offset(_ point: CGPoint, by distance: CGFloat) -> CGPoint {
            let dx = point.x - center.x, dy = point.y - center.y
            let length = hypot(dx, dy)
            guard length > 0.001 else { return point }
            return CGPoint(x: point.x + dx / length * distance,
                           y: point.y + dy / length * distance)
        }
        let points = projected.map { offset($0, by: 40) }
        let middle = points.count / 2
        let before = points[middle - 1], after = points[middle + 1]
        var rotation = atan2(Double(after.y - before.y), Double(after.x - before.x))
        if rotation > .pi / 2 { rotation -= .pi }
        if rotation < -.pi / 2 { rotation += .pi }
        return (points, center, offset(projected[middle], by: 60), rotation)
    }

    private func radiusLeader(center: CGPoint, tip: CGPoint, in size: CGSize)
        -> (tail: CGPoint, anchor: CGPoint, rotation: Double)? {
        let dx = tip.x - center.x, dy = tip.y - center.y
        let length = hypot(dx, dy)
        guard length > 1 else { return nil }
        let ux = dx / length, uy = dy / length
        let bounds = CGRect(x: 96, y: 140, width: max(1, size.width - 192),
                            height: max(1, size.height - 210))
        var extensionLength: CGFloat = 220
        if ux > 0.001 { extensionLength = min(extensionLength, (bounds.maxX - tip.x) / ux) }
        if ux < -0.001 { extensionLength = min(extensionLength, (bounds.minX - tip.x) / ux) }
        if uy > 0.001 { extensionLength = min(extensionLength, (bounds.maxY - tip.y) / uy) }
        if uy < -0.001 { extensionLength = min(extensionLength, (bounds.minY - tip.y) / uy) }
        extensionLength = max(0, extensionLength)
        let tail = CGPoint(x: tip.x + ux * extensionLength, y: tip.y + uy * extensionLength)
        var rotation = atan2(Double(dy), Double(dx))
        if rotation > .pi / 2 { rotation -= .pi }
        if rotation < -.pi / 2 { rotation += .pi }
        let anchor = CGPoint(x: tip.x + ux * extensionLength * 0.7 - uy * 18,
                             y: tip.y + uy * extensionLength * 0.7 + ux * 18)
        return (tail, anchor, rotation)
    }

    /// Short tick at `point`, perpendicular to the line running to `other`.
    private func appendTick(_ path: inout Path, at point: CGPoint, along other: CGPoint) {
        let dx = other.x - point.x, dy = other.y - point.y
        let length = hypot(dx, dy)
        guard length > 1 else { return }
        let nx = -dy / length, ny = dx / length
        path.move(to: CGPoint(x: point.x - nx * Self.edgeTickHalfLength,
                              y: point.y - ny * Self.edgeTickHalfLength))
        path.addLine(to: CGPoint(x: point.x + nx * Self.edgeTickHalfLength,
                                 y: point.y + ny * Self.edgeTickHalfLength))
    }

    /// Solid arrow head at `tip`, aimed away from `origin`.
    @ViewBuilder
    private func arrowHead(at tip: CGPoint, pointingFrom origin: CGPoint) -> some View {
        let dx = tip.x - origin.x, dy = tip.y - origin.y
        let length = hypot(dx, dy)
        if length > 1 {
            let ux = dx / length, uy = dy / length
            let base = CGPoint(x: tip.x - ux * Self.arrowLength,
                               y: tip.y - uy * Self.arrowLength)
            Path { path in
                path.move(to: tip)
                path.addLine(to: CGPoint(x: base.x - uy * Self.arrowHalfWidth,
                                         y: base.y + ux * Self.arrowHalfWidth))
                path.addLine(to: CGPoint(x: base.x + uy * Self.arrowHalfWidth,
                                         y: base.y - ux * Self.arrowHalfWidth))
                path.closeSubpath()
            }
            .fill(Color.black.opacity(0.85))
        }
    }

    /// The line's screen angle, flipped when it would read upside down.
    private func readableAngle(from a: CGPoint, to b: CGPoint) -> Double {
        var angle = atan2(Double(b.y - a.y), Double(b.x - a.x))
        if angle > .pi / 2 { angle -= .pi }
        if angle < -.pi / 2 { angle += .pi }
        return angle
    }

    private func project(_ world: SIMD3<Double>) -> CGPoint? {
        viewModel.cameraControl?.worldToScreenPoint(world)
    }
}
