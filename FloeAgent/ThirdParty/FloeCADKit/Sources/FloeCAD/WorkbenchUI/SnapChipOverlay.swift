//
//  SnapChipOverlay.swift
//  openshape3d
//
//  The named-snap chip Shapr3D shows while you draw — "Endpoint", "Midpoint",
//  "Center" — floating just above the point that caught the pointer.
//
//  It exists because snapping is invisible otherwise: the geometry moves a
//  fraction of a millimetre and you cannot tell whether you landed on the
//  corner you aimed at or merely near it. Naming the snap makes the commitment
//  legible BEFORE the stroke ends. The grid is deliberately unnamed — it is
//  always on, so labelling it would tag every stroke with noise.
//

import SwiftUI

struct SnapChipOverlay: View {
    @Bindable var viewModel: EditorViewModel

    /// Points above the snapped point, so the chip clears the fingertip.
    private static let liftAbove: CGFloat = 26

    var body: some View {
        // Re-project as the camera moves.
        let _ = viewModel.cameraEpoch
        if let snap = viewModel.activeSnapLabel,
           let point = viewModel.cameraControl?.worldToScreenPoint(snap.world) {
            Text(snap.text)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.black.opacity(0.78))
                )
                .fixedSize()
                .position(x: point.x, y: point.y - Self.liftAbove)
                .allowsHitTesting(false)
                .accessibilityIdentifier("SnapChip")
                // The Metal viewport is full-bleed; a SwiftUI overlay is
                // safe-area inset by default, which would place the chip well
                // below the point it names.
                .ignoresSafeArea()
        }
    }
}
