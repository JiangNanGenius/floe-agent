//
//  SketchPointStateOverlay.swift
//  openshape3d
//
//  On-canvas degrees-of-freedom markers for sketch points (plan §C4). Each
//  sketch point draws a small glyph coloured by how constrained it is, so the
//  user can see at a glance what is still movable (blue hollow), fully
//  determined (green dot) or locked down (blue square). Purely informational —
//  markers never take taps, so the canvas, gizmos and constraint glyphs stay
//  interactive. Anchors are projected from world space each camera move via
//  `cameraEpoch`, mirroring `SketchConstraintOverlay`.
//

import SwiftUI

struct SketchPointStateOverlay: View {
    @Bindable var viewModel: EditorViewModel

    // App palette (matches SketchConstraintOverlay / dimension chrome).
    private static let free = Color(red: 0.20, green: 0.48, blue: 0.95)     // blue
    private static let constrained = Color(red: 0.20, green: 0.70, blue: 0.35) // green
    private static let locked = Color(red: 0.20, green: 0.48, blue: 0.95)   // blue

    private struct Projection: Identifiable {
        let marker: EditorViewModel.SketchPointMarker
        let point: CGPoint
        var id: String { marker.id }
    }

    var body: some View {
        // Reproject whenever the camera moves.
        let _ = viewModel.cameraEpoch
        if viewModel.mode.isSketching {
            let circleCenters = viewModel.sketchCircleCenterMarkers
            let replaced = Set(circleCenters.map { $0.id.replacingOccurrences(of: ":circleCenter", with: ":center") })
            // Resolve the camera-dependent inputs before SwiftUI looks up the
            // ForEach children by their stable, model-space marker IDs.
            let points = viewModel.sketchPointMarkers.compactMap { marker in
                replaced.contains(marker.id) ? nil : project(marker)
            }
            let centers = (viewModel.sketchRectangleCenterMarkers + circleCenters).compactMap(project)
            ZStack(alignment: .topLeading) {
                ForEach(points) { item in
                    glyph(for: item.marker.state, rectangleCorner: item.marker.isRectangleCorner)
                        .position(item.point)
                        .accessibilityIdentifier("SketchPointMarker")
                }
                if let marker = viewModel.selectedMigratedRectangleCornerMarker,
                   let pt = viewModel.cameraControl?.worldToScreenPoint(SIMD3<Double>(marker.world)) {
                    Circle().stroke(Color.orange, lineWidth: 1.5)
                        .background(Circle().fill(Color.white.opacity(0.9)))
                        .frame(width: 9, height: 9)
                        .background(Circle().fill(Color.orange.opacity(0.25)).frame(width: 16, height: 16))
                        .position(x: pt.x, y: pt.y)
                        .accessibilityIdentifier("SelectedRectangleCorner")
                }
                ForEach(centers) { item in
                    let marker = item.marker
                    Circle().fill(marker.isSelected ? Color.orange : (marker.state == .free ? Self.free : Self.constrained))
                        .frame(width: 5, height: 5)
                        .background {
                            if marker.isSelected && marker.state == .free {
                                Circle().fill(Color.orange.opacity(0.25))
                                    .frame(width: 16, height: 16)
                            }
                        }
                        .position(item.point)
                        .accessibilityIdentifier(marker.id.hasSuffix(":circleCenter") ? "CircleCenterControl" : "RectangleCenterControl")
                }
            }
            // Informational only — must never steal taps from the canvas/gizmo.
            .allowsHitTesting(false)
            // The Metal viewport is full-bleed; a SwiftUI overlay is safe-area
            // inset by default, which would draw every projected point ~85pt
            // below the geometry it annotates.
            .ignoresSafeArea()
            // `children: .contain` matters: an identifier ALONE collapses this
            // into a single element and hides every marker from XCUITest (see
            // STATUS gotcha 2), which is why a test could not tell whether a
            // sketch stroke had actually landed.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("SketchPointStateOverlay")
        }
    }

    private func project(_ marker: EditorViewModel.SketchPointMarker) -> Projection? {
        guard let point = viewModel.cameraControl?.worldToScreenPoint(SIMD3<Double>(marker.world)) else { return nil }
        return Projection(marker: marker, point: point)
    }

    @ViewBuilder
    private func glyph(for state: SketchPointState, rectangleCorner: Bool) -> some View {
        if rectangleCorner {
            // Paired rectangle corners remain hollow even when fixed.
            Circle()
                .stroke(state == .free ? Self.free : Self.constrained, lineWidth: 1.5)
                .background(Circle().fill(Color.white.opacity(0.9)))
                .frame(width: 9, height: 9)
        } else {
            switch state {
            case .free:
                // Under-constrained / movable: hollow blue circle.
                Circle()
                    .stroke(Self.free, lineWidth: 1.5)
                    // The canvas remains light even when the surrounding chrome
                    // uses dark mode; a semantic background made hollow points black.
                    .background(Circle().fill(Color.white.opacity(0.9)))
                    .frame(width: 9, height: 9)
            case .constrained:
                // Fully determined / connected: solid green dot.
                Circle()
                    .fill(Self.constrained)
                    .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 0.75))
                    .frame(width: 8, height: 8)
            case .locked:
                // Fully fixed: solid blue square — distinct from the green dot.
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Self.locked)
                    .overlay(RoundedRectangle(cornerRadius: 1.5).stroke(Color.white.opacity(0.9), lineWidth: 0.75))
                    .frame(width: 8, height: 8)
            }
        }
    }
}
