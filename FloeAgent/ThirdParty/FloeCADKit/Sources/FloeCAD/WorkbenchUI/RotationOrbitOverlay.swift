//
//  RotationOrbitOverlay.swift
//  openshape3d
//
//  The rotate control's orbit (Shapr3D §5.3): while a rotation ring is being
//  dragged — or an exact angle typed — a dashed circle is drawn around the
//  body in the plane of that ring, with a solid arc showing how far it has
//  swung and a value pill at the arc's leading end. Tapping a ring (instead of
//  dragging it) opens the pill as a field, so an angle can be typed exactly.
//
//  Sibling of `MoveDistanceOverlay`; the geometry comes from the view model's
//  `rotationOrbit`, projected here through the shared camera control.
//

import SwiftUI
import simd

struct RotationOrbitOverlay: View {
    @Bindable var viewModel: EditorViewModel

    /// Points the pill floats outward from the arc's leading end.
    private static let pillFloat: CGFloat = 34

    private static let orbitColor = Color(white: 0.35)
    private static let sweepColor = Color(red: 0.20, green: 0.52, blue: 1.0)

    var body: some View {
        let _ = viewModel.cameraEpoch
        if let orbit = viewModel.rotationOrbit,
           let circle = projectedCircle(orbit.part) {
            GeometryReader { geo in
            ZStack {
                // The full circle of the rotation, dashed — it reads as "this
                // is the plane you are turning in" even before anything moves.
                polyline(circle)
                    .stroke(Self.orbitColor.opacity(0.65),
                            style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))

                // …and the slice swept so far, solid on top of it.
                if abs(orbit.degrees) > 0.05,
                   let swept = projectedArc(orbit.part, from: orbit.startAngle,
                                            degrees: orbit.degrees) {
                    polyline(swept)
                        .stroke(Self.sweepColor,
                                style: StrokeStyle(lineWidth: 3, lineCap: .round))
                }

                if let label = viewModel.rotationAngleLabel,
                   let anchor = pillAnchor(orbit, in: geo.size) {
                    if label.isEditable {
                        RotationAngleField(viewModel: viewModel, part: label.part)
                            .position(anchor)
                    } else {
                        Text(label.text)
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7)
                                .stroke(Self.sweepColor, lineWidth: 1.5))
                            .foregroundStyle(Self.sweepColor)
                            .position(anchor)
                            .allowsHitTesting(false)
                            .accessibilityIdentifier("RotationAngleValue")
                    }
                }
            }
            }
            // Full-screen, like every other projected overlay — the Metal
            // viewport is full-bleed and `worldToScreenPoint` is in its space.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
        }
    }

    // MARK: - Geometry

    /// World point on the orbit at `angle` (radians in the ring's own basis).
    private func orbitPoint(_ part: GizmoPart, _ angle: Double) -> SIMD3<Double>? {
        guard let origin = viewModel.gizmoOrigin else { return nil }
        // Spelled out step by step: the one-line version of this is the kind of
        // mixed Float/Double SIMD expression the type checker gives up on.
        let (uf, vf) = GizmoGeometry.ringBasis(for: part)
        let u = SIMD3<Double>(Double(uf.x), Double(uf.y), Double(uf.z))
        let v = SIMD3<Double>(Double(vf.x), Double(vf.y), Double(vf.z))
        let radius: Double = viewModel.rotationOrbitRadius
        let c: Double = cos(angle)
        let s: Double = sin(angle)
        let dir: SIMD3<Double> = u * c + v * s
        let center = SIMD3<Double>(Double(origin.x), Double(origin.y), Double(origin.z))
        return center + dir * radius
    }

    private func project(_ world: SIMD3<Double>) -> CGPoint? {
        viewModel.cameraControl?.worldToScreenPoint(world)
    }

    /// The whole orbit, projected. nil if it does not survive projection (the
    /// circle is behind the camera).
    private func projectedCircle(_ part: GizmoPart) -> [CGPoint]? {
        let steps = 96
        var pts: [CGPoint] = []
        for i in 0...steps {
            let a: Double = Double(i) / Double(steps) * 2 * Double.pi
            guard let world = orbitPoint(part, a), let p = project(world) else { continue }
            pts.append(p)
        }
        return pts.count > 8 ? pts : nil
    }

    /// The swept slice, from where the drag was grabbed through `degrees`.
    private func projectedArc(_ part: GizmoPart, from start: Double,
                              degrees: Double) -> [CGPoint]? {
        let sweep: Double = degrees * Double.pi / 180
        let steps = max(2, min(96, Int(abs(degrees) / 3) + 2))
        var pts: [CGPoint] = []
        for i in 0...steps {
            let a = start + sweep * Double(i) / Double(steps)
            guard let world = orbitPoint(part, a), let p = project(world) else { continue }
            pts.append(p)
        }
        return pts.count >= 2 ? pts : nil
    }

    /// Where the pill sits: just outside the arc's leading end while dragging,
    /// so it reads as the arc's own value — and next to the GIZMO while an
    /// angle is being typed, because the orbit can be most of a screen wide and
    /// a field parked out on its rim is both far from the eye and, on a phone,
    /// behind the keyboard.
    private func pillAnchor(_ orbit: EditorViewModel.RotationOrbit,
                            in size: CGSize) -> CGPoint? {
        guard let origin = viewModel.gizmoOrigin,
              let center = project(SIMD3(Double(origin.x), Double(origin.y), Double(origin.z)))
        else { return nil }
        if orbit.isEditing {
            return clamp(CGPoint(x: center.x, y: center.y - 86), in: size, editing: true)
        }
        let angle: Double = orbit.startAngle + orbit.degrees * Double.pi / 180
        guard let world = orbitPoint(orbit.part, angle), let p = project(world) else {
            return nil
        }
        // Push it radially outward so it never sits on the arc it measures.
        let dx = p.x - center.x, dy = p.y - center.y
        let len = hypot(dx, dy)
        let out = len > 1
            ? CGPoint(x: p.x + dx / len * Self.pillFloat, y: p.y + dy / len * Self.pillFloat)
            : CGPoint(x: p.x, y: p.y - Self.pillFloat)
        return clamp(out, in: size, editing: false)
    }

    /// Keep the pill on screen — and, while typing, out of the keyboard's half
    /// of it. The orbit is drawn at the body's own radius, so its rim regularly
    /// projects past the edges of the viewport.
    private func clamp(_ p: CGPoint, in size: CGSize, editing: Bool) -> CGPoint {
        let inset: CGFloat = 72
        let maxY = editing ? max(inset, size.height * 0.42) : size.height - inset
        return CGPoint(x: min(max(p.x, inset), max(inset, size.width - inset)),
                       y: min(max(p.y, inset), maxY))
    }

    private func polyline(_ pts: [CGPoint]) -> Path {
        Path { path in path.addLines(pts) }
    }
}

/// The inline field shown when a rotation ring is tapped: type an angle,
/// Enter to turn by exactly that much. Same shape as `MoveDistanceField`:
/// the app's own keypad comes up with the field (focusing a text field
/// from an overlay left the iPad with an empty field and no keyboard,
/// 2026-09-14), and the pad's keyboard key hands over to the system one.
private struct RotationAngleField: View {
    @Bindable var viewModel: EditorViewModel
    let part: GizmoPart
    @State private var text = ""
    @State private var padOpen = false
    @State private var usingSystemKeyboard = CADPreferences.prefersSystemKeyboard
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 6) {
            pill
            if padOpen && !usingSystemKeyboard {
                NumericKeypad(
                    text: $text,
                    isLocked: nil,
                    onCommit: {
                        padOpen = false
                        viewModel.commitRotationAngle(text)
                    },
                    onSwitchToSystemKeyboard: {
                        padOpen = false
                        usingSystemKeyboard = true
                        focused = true
                    }
                )
            }
        }
    }

    private var pill: some View {
        HStack(spacing: 4) {
            Text(part.axisName)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            TextField("°", text: $text)
                .keyboardType(.numbersAndPunctuation)
                .autocorrectionDisabled()
                .multilineTextAlignment(.center)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .frame(width: 66)
                .focused($focused)
                .submitLabel(.done)
                .allowsHitTesting(usingSystemKeyboard)
                .onSubmit { viewModel.commitRotationAngle(text) }
                .accessibilityIdentifier("RotationAngleField")
            Button {
                viewModel.cancelAngleEntry()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("RotationAngleCancel")
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .stroke(Color(red: 0.20, green: 0.52, blue: 1.0), lineWidth: 1.5))
        .contentShape(Rectangle())
        .onTapGesture { if !usingSystemKeyboard { padOpen = true } }
        .onAppear {
            text = ""
            if usingSystemKeyboard { focused = true } else { padOpen = true }
        }
    }
}
