//
//  OrientationCubeLabels.swift
//  openshape3d
//
//  Standard-view names drawn over the orientation cube (spec §7.2). The cube
//  itself is Metal; the names ride above it as SwiftUI text, which keeps them
//  crisp at any size and avoids a glyph atlas in the render pass for six words.
//
//  Only faces turned toward the camera are named, fading out as they rotate
//  away — the cube stays readable instead of becoming a wall of text, and every
//  visible name is a face you can actually tap to snap to.
//

import SwiftUI

struct OrientationCubeLabels: View {
    @Bindable var viewModel: EditorViewModel

    var body: some View {
        // Re-project as the camera turns.
        let _ = viewModel.cameraEpoch
        ZStack(alignment: .topLeading) {
            ForEach(viewModel.cameraControl?.orientationCubeLabels() ?? []) { label in
                Text(label.name)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.75))
                    .shadow(color: .white.opacity(0.6), radius: 0.5)
                    .opacity(label.opacity)
                    .position(label.point)
            }
        }
        // The cube's own tap/drag handling lives in the viewport; the names
        // must not intercept either.
        .allowsHitTesting(false)
        // The Metal viewport is full-bleed while a SwiftUI overlay is
        // safe-area inset by default; without this every projected point lands
        // ~85pt below the geometry it annotates.
        .ignoresSafeArea()
    }
}
