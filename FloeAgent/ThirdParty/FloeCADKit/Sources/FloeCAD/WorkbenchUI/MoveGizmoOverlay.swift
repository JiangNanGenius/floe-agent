//
//  MoveGizmoOverlay.swift
//  openshape3d
//
//  The move/rotate gizmo, drawn in 2D (SwiftUI) instead of as a Metal mesh so
//  it matches the extrude handle's flat, outlined look:
//
//   • axis translate arrows — solid flat arrows with a dark outline, exactly
//     like the extrude pull handle;
//   • rotation handles — thin double-headed arrows on a curve;
//   • plane-move handles — tiles lying IN their own plane (so the square
//     leans with the model and shows which way it drags);
//   • the pivot — a dot, or a crosshair once tapped (drag it to reposition
//     the whole control without moving the model).
//
//  Purely visual: it projects the gizmo's own local part anchors (the same
//  positions the 3D hit test in `GizmoGeometry` uses) to screen, so a tap on a
//  drawn handle lands on its 3D drag target. Hit-testing and drag math stay in
//  the viewport — this view never takes a touch.
//

import SwiftUI
import simd

struct MoveGizmoOverlay: View {
    @Bindable var viewModel: EditorViewModel

    // Extrude-handle palette: dark outline behind a light/coloured fill.
    private static let outline = Color(white: 0.08)
    private static let fill = Color.white
    private static let highlight = Color(red: 0.20, green: 0.52, blue: 1.0)
    private static let pivot = Color(red: 0.20, green: 0.80, blue: 0.85)
    /// The armed-pivot crosshair (Shapr3D uses a violet crosshair here).
    private static let reposition = Color(red: 0.55, green: 0.36, blue: 0.96)

    private let axes: [GizmoPart] = [.xAxis, .yAxis, .zAxis]
    private let rings: [GizmoPart] = [.xRing, .yRing, .zRing]

    var body: some View {
        let _ = viewModel.cameraEpoch
        if let origin = viewModel.gizmoOrigin,
           let control = viewModel.cameraControl,
           let center = control.worldToScreenPoint(dbl(origin)) {
            let scale = control.gizmoWorldScale(at: origin)
            let ctx = ProjectionContext(origin: origin, scale: scale, control: control)

            ZStack(alignment: .topLeading) {
                // Face-rotate shows ONLY the rings (+ pivot) so the control reads
                // as a pure rotate; body/move/scale keep their plane handles.
                if !viewModel.faceRotateActive {
                    planeTiles(ctx)
                }
                // A selected face translates/scales only — hide the rotation rings
                // unless the Rotate tool armed them.
                if viewModel.gizmoAllowsRotation {
                    ForEach(rings, id: \.self) { rotationArc($0, ctx) }
                }
                // Scale mode shows square grips at the axis ends (drag any to
                // scale about the centre); move mode shows the directional arrows;
                // rotate mode shows neither (rings only).
                if !viewModel.faceRotateActive {
                    if viewModel.gizmoIsScale {
                        ForEach(axes, id: \.self) { scaleHandle($0, ctx, center: center) }
                    } else {
                        ForEach(axes, id: \.self) { axisArrow($0, ctx) }
                    }
                }
                pivotDot(at: center)
            }
            .allowsHitTesting(false)   // drags are hit-tested in 3D by the viewport
            .ignoresSafeArea()         // full-bleed Metal viewport, inset SwiftUI
        }
    }

    // MARK: - Axis scale grip (square head with a stem trailing to the pivot)

    /// A Shapr3D-style scale grip: a rounded-square head at the axis end with a
    /// thin rectangular stem trailing back toward the centre pivot, so it reads
    /// as "drag me outward/inward to scale". Drawn outline-behind-fill (like the
    /// arrows) so the whole key shape carries one continuous dark outline.
    @ViewBuilder
    private func scaleHandle(_ part: GizmoPart, _ ctx: ProjectionContext, center: CGPoint) -> some View {
        if let tip = GizmoScreenLayout.axisAnchor(part, project: ctx.project) {
            let colored = viewModel.litGizmoPart == part ? Self.highlight : Self.fill
            // Direction from the head back toward the pivot; fall back to a fixed
            // heading if the head sits on top of the pivot (degenerate).
            let dx = center.x - tip.x, dy = center.y - tip.y
            let len = hypot(dx, dy)
            let ux = len > 0.5 ? dx / len : 0, uy = len > 0.5 ? dy / len : 1
            let head: CGFloat = 20, stem: CGFloat = 15, stemW: CGFloat = 8
            // Stem runs from just inside the head toward the pivot.
            let s0 = CGPoint(x: tip.x + ux * (head / 2 - 3), y: tip.y + uy * (head / 2 - 3))
            let s1 = CGPoint(x: tip.x + ux * (head / 2 + stem), y: tip.y + uy * (head / 2 + stem))
            ZStack {
                // Outline pass (behind, fatter).
                stemPath(s0, s1).stroke(Self.outline,
                    style: StrokeStyle(lineWidth: stemW + 4, lineCap: .round))
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Self.outline).frame(width: head + 4, height: head + 4).position(tip)
                // Fill pass (front).
                stemPath(s0, s1).stroke(colored,
                    style: StrokeStyle(lineWidth: stemW, lineCap: .round))
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(colored).frame(width: head, height: head).position(tip)
            }
            .accessibilityIdentifier("GizmoScale-\(part.axisName)")
        }
    }

    private func stemPath(_ a: CGPoint, _ b: CGPoint) -> Path {
        Path { p in p.move(to: a); p.addLine(to: b) }
    }

    // MARK: - Axis translate arrow (flat, outlined — like the extrude handle)

    @ViewBuilder
    private func axisArrow(_ part: GizmoPart, _ ctx: ProjectionContext) -> some View {
        let axis = part.axisDirection
        if let tip = GizmoScreenLayout.axisAnchor(part, project: ctx.project),
           let base = ctx.project(axis * (GizmoScreenLayout.armLocal * 0.35)) {
            let dx = tip.x - base.x, dy = tip.y - base.y
            let len = hypot(dx, dy)
            // Fade an axis that points nearly into/out of the screen (its arrow
            // would be a foreshortened smear); it is still draggable in 3D.
            if len > 6 {
                let angle = atan2(Double(dy), Double(dx))
                let colored = viewModel.litGizmoPart == part ? Self.highlight : Self.fill
                ZStack {
                    Image(systemName: "arrowshape.up.fill")
                        .foregroundStyle(Self.outline).scaleEffect(1.22)
                    Image(systemName: "arrowshape.up.fill")
                        .foregroundStyle(colored)
                }
                .font(.system(size: 30, weight: .semibold))
                .rotationEffect(.radians(angle + .pi / 2))
                .position(tip)
                .opacity(min(1, Double(len) / 24))
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("GizmoAxis-\(part.axisName)")
                .accessibilityValue(viewModel.litGizmoPart == part ? "lit" : "idle")
            }
        }
    }

    // MARK: - Rotation handle (double-headed arrow on a curve)

    /// Project the visible arc of a rotation ring (centred at 45° in the ring
    /// basis, ~66° wide) so the drawn curve follows its on-screen ellipse.
    @ViewBuilder
    private func rotationArc(_ part: GizmoPart, _ ctx: ProjectionContext) -> some View {
        let pts = GizmoScreenLayout.ringPolyline(part, project: ctx.project)
        if pts.count >= 3 {
            let colored = viewModel.litGizmoPart == part ? Self.highlight : Self.fill
            // Outline pass (fat, dark) then the fill pass, both with arrowheads
            // at each end — the double-ended curved arrow. Thicker + shorter and
            // pushed OUT past the move arrows (radius from GizmoScreenLayout) so
            // it reads as its own control, clear of the move handles.
            // One accessibility element for the whole handle (the passes are
            // several paths) so the UI suite can read its lit state.
            ZStack {
                curvedArrow(pts, width: 13, arrow: 20, color: Self.outline)
                curvedArrow(pts, width: 7, arrow: 16, color: colored)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("GizmoRing-\(part.axisName)")
            .accessibilityValue(viewModel.litGizmoPart == part ? "lit" : "idle")
        }
    }

    /// A polyline through `pts` with a triangular arrowhead at each end.
    @ViewBuilder
    private func curvedArrow(_ pts: [CGPoint], width: CGFloat,
                             arrow: CGFloat, color: Color) -> some View {
        Path { path in
            path.addLines(pts)
        }
        .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        arrowHead(tip: pts[0], from: pts[1], size: arrow, color: color)
        arrowHead(tip: pts[pts.count - 1], from: pts[pts.count - 2], size: arrow, color: color)
    }

    @ViewBuilder
    private func arrowHead(tip: CGPoint, from: CGPoint, size: CGFloat, color: Color) -> some View {
        let dx = tip.x - from.x, dy = tip.y - from.y
        let len = hypot(dx, dy)
        if len > 0.5 {
            let ux = dx / len, uy = dy / len
            let nx = -uy, ny = ux
            let base = CGPoint(x: tip.x - ux * size, y: tip.y - uy * size)
            Path { path in
                path.move(to: tip)
                path.addLine(to: CGPoint(x: base.x + nx * size * 0.6, y: base.y + ny * size * 0.6))
                path.addLine(to: CGPoint(x: base.x - nx * size * 0.6, y: base.y - ny * size * 0.6))
                path.closeSubpath()
            }
            .fill(color)
        }
    }

    // MARK: - Plane-move handle (a tile lying IN its plane)

    /// The plane tiles, drawn as the projected quads they actually are: each
    /// square lies in the plane it drags along, so it leans with the model and
    /// tells the user which way it will move (Shapr3D draws them the same way).
    /// A screen-aligned square said nothing about its plane — and worse, it
    /// disagreed with the hit test, which is the quad.
    @ViewBuilder
    private func planeTiles(_ ctx: ProjectionContext) -> some View {
        // Edge-on tiles are dropped here and by the hit test alike, so what is
        // drawn is exactly what is grabbable.
        let tiles = GizmoScreenLayout.visiblePlaneQuads(project: ctx.project)
        ForEach(tiles) { tile in
            planeTile(tile.part, quad: tile.quad, area: tile.area)
        }
    }

    @ViewBuilder
    private func planeTile(_ part: GizmoPart, quad: [CGPoint], area: CGFloat) -> some View {
        let colored = viewModel.litGizmoPart == part ? Self.highlight : Self.fill
        let path = Path { p in
            p.addLines(quad)
            p.closeSubpath()
        }
        ZStack {
            // Outline pass: the same quad stroked fat with round joins, which
            // rounds the corners outward the way the flat arrows are rounded.
            path.fill(Self.outline)
            path.stroke(Self.outline, style: StrokeStyle(lineWidth: 6, lineJoin: .round))
            path.fill(colored)
            path.stroke(colored, style: StrokeStyle(lineWidth: 3, lineJoin: .round))
        }
        // Fade a tile as it tips toward edge-on, so it never reads as a crisp
        // target while it is collapsing into a line.
        .opacity(min(1, Double(area) / 90))
        .accessibilityIdentifier("GizmoPlane-\(part.axisName)")
    }

    // MARK: - Pivot (tap it to reposition the whole control)

    @ViewBuilder
    private func pivotDot(at p: CGPoint) -> some View {
        if viewModel.gizmoRepositionArmed {
            crosshair(at: p)
        } else {
            Circle().fill(Self.pivot)
                .overlay(Circle().stroke(Self.outline, lineWidth: 1))
                .frame(width: 11, height: 11)
                .position(p)
        }
    }

    /// The armed pivot: a crosshair you drag to drop the gizmo somewhere else
    /// (the bodies stay put). Tapping the centre again puts the dot back.
    @ViewBuilder
    private func crosshair(at p: CGPoint) -> some View {
        let r: CGFloat = 17
        ZStack {
            ForEach(0..<2, id: \.self) { i in
                Path { path in
                    if i == 0 {
                        path.move(to: CGPoint(x: p.x - r, y: p.y))
                        path.addLine(to: CGPoint(x: p.x + r, y: p.y))
                    } else {
                        path.move(to: CGPoint(x: p.x, y: p.y - r))
                        path.addLine(to: CGPoint(x: p.x, y: p.y + r))
                    }
                }
                .stroke(Self.reposition, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
            Circle().stroke(Self.reposition, lineWidth: 2.5)
                .frame(width: 15, height: 15)
                .position(p)
        }
        .accessibilityIdentifier("GizmoPivotCrosshair")
    }

    private func dbl(_ v: SIMD3<Float>) -> SIMD3<Double> {
        SIMD3(Double(v.x), Double(v.y), Double(v.z))
    }
}

/// Projects gizmo-local offsets (unit-scale, origin at zero) to screen points.
private struct ProjectionContext {
    let origin: SIMD3<Float>
    let scale: Float
    let control: any ViewportCameraControl

    func project(_ local: SIMD3<Float>) -> CGPoint? {
        let world = origin + local * scale
        return control.worldToScreenPoint(
            SIMD3(Double(world.x), Double(world.y), Double(world.z)))
    }
}
