//
//  SketchConstraintOverlay.swift
//  openshape3d
//
//  On-canvas constraint glyphs (plan §C3). Each symbolic constraint draws a
//  small code badge at its location (a relationship has no geometry of its own,
//  so the anchor is the average of its operand points, projected from world
//  space each camera move via `cameraEpoch`). Tapping a glyph selects the
//  constraint (blue highlight); the palette / Delete key then removes it
//  (undoable) and re-solves. Mirrors `SketchDimensionOverlay`.
//

import SwiftUI

struct SketchConstraintOverlay: View {
    @Bindable var viewModel: EditorViewModel

    var body: some View {
        // Reproject whenever the camera moves.
        let _ = viewModel.cameraEpoch
        // Mirrors `SketchDimensionOverlay`, including gating on content rather
        // than mode so an empty overlay never sits over the viewport.
        let glyphs = viewModel.sketchConstraintGlyphs.filter { !$0.isRectangleCenterLock }
        let centerControls = viewModel.sketchRectangleCenterLockMarkers
        if !glyphs.isEmpty || !centerControls.isEmpty {
            ZStack(alignment: .topLeading) {
                ForEach(glyphs) { glyph in
                    glyphView(glyph)
                }
                ForEach(centerControls) { marker in
                    if let center = viewModel.cameraControl?.worldToScreenPoint(SIMD3<Double>(marker.world)) {
                        Button {
                            viewModel.toggleRectangleCenterLock()
                        } label: {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 12, weight: .regular))
                                .foregroundStyle(Color.black)
                                .frame(width: EditorViewModel.rectangleCenterLockHitSize, height: EditorViewModel.rectangleCenterLockHitSize)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .position(x: center.x, y: center.y + EditorViewModel.rectangleCenterLockOffset)
                        .accessibilityIdentifier(marker.id.hasSuffix(":circleCenter") ? "CircleCenterLockToggle" : "RectangleCenterLockToggle")
                        .accessibilityLabel(viewModel.canUnlockSketchSelection ? "Unlock center" : "Lock center")
                    }
                }
            }
            .allowsHitTesting(true)
            // The Metal viewport is full-bleed; a SwiftUI overlay is safe-area
            // inset by default, which would draw every projected point ~85pt
            // below the geometry it annotates.
            .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private func glyphView(_ glyph: EditorViewModel.SketchConstraintGlyph) -> some View {
        if let anchor = viewModel.cameraControl?.worldToScreenPoint(glyph.worldAnchor) {
            let selected = viewModel.selectedConstraintID == glyph.id
            // Stage-2 conflict attribution: this constraint is one the solver
            // could not satisfy — paint it red so the chip's "Constraints
            // conflict" has a WHERE. Tap-to-select still works (that is how
            // the user deletes their way out of the conflict).
            let conflicting =
                viewModel.sketchConflictAttribution.constraintIDs.contains(glyph.id)
            let tint = conflicting ? Color.red : Color.blue
            // Fan out glyphs that share an anchor so each stays tappable.
            let offset = CGFloat(glyph.slot) * 22
            // Do not put a clickable constraint badge over the transform's
            // center drag target. Native keeps these glyphs beside its axes.
            let position = glyph.isCircleCenterConnection
                ? CGPoint(x: anchor.x - 32, y: anchor.y + 40 + offset)
                : glyphPosition(anchor: anchor, offset: offset, sketchID: glyph.sketchID)
            Button {
                viewModel.selectConstraint(glyph.id, in: glyph.sketchID)
            } label: {
                if glyph.isCircleCenterConnection {
                    Image(systemName: "link")
                        .font(.system(size: 12))
                        .foregroundStyle(conflicting ? Color.red : Color.black)
                        .frame(width: 22, height: 22)
                        .background(selected ? Color.blue.opacity(0.2) : Color.clear)
                        .contentShape(Rectangle())
                } else {
                Text(glyph.code)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(selected ? Color.white : tint)
                    .frame(minWidth: 18, minHeight: 18)
                    .padding(2)
                    .background(
                        selected ? tint : Color(.systemBackground).opacity(0.9),
                        in: RoundedRectangle(cornerRadius: 5)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(tint, lineWidth: conflicting ? 2 : 1)
                    )
                }
            }
            .buttonStyle(.plain)
            // A drawing tool owns the canvas stroke. Constraint badges remain
            // visible as feedback, but must not swallow a new shape that starts
            // exactly on their anchor (notably Circle on a line midpoint's H/V
            // badge). Center Lock controls above remain separately interactive.
            .allowsHitTesting(viewModel.mode.sketchTool == nil)
            .position(position)
            .accessibilityIdentifier(
                conflicting ? "ConstraintGlyphConflict" : "ConstraintGlyph")
            .accessibilityLabel(glyph.isCircleCenterConnection ? "Connected circle centers" : glyph.code)
        }
    }

    private func glyphPosition(anchor: CGPoint, offset: CGFloat, sketchID: SketchID) -> CGPoint {
        var original = CGPoint(x: anchor.x, y: anchor.y + offset)
        // Keep the rectangle's center control available below a local Lock.
        if let sketch = viewModel.activeSketch, sketch.id == sketchID,
           viewModel.sketchRectangleCenterMarkers.contains(where: { marker in
               guard let center = viewModel.cameraControl?.worldToScreenPoint(SIMD3<Double>(marker.world)) else { return false }
               return abs(anchor.x - center.x) < 4 && abs(anchor.y - center.y) < 4
           }) {
            original.y += 40
        }
        guard viewModel.sketchTransformActive,
              let sketch = viewModel.activeSketch, sketch.id == sketchID,
              let centroid = viewModel.sketchSelectionCentroid,
              let center = viewModel.cameraControl?.worldToScreenPoint(sketch.plane.toWorld(centroid)),
              abs(original.x - center.x) < 44, abs(original.y - center.y) < 44 else { return original }
        return CGPoint(x: center.x - 58, y: center.y + 24 + offset)
    }
}
