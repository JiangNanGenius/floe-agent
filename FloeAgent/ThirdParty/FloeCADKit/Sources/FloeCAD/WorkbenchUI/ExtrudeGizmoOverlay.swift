//
//  ExtrudeGizmoOverlay.swift
//  openshape3d
//
//  Shapr3D-style on-arrow value pill for extrude / face push-pull / cylinder
//  diameter. Rides the pull arrow tip (projected from world each camera move
//  via `cameraEpoch`); tap the pill to type a value inline (Enter commits, like
//  the bottom bar), with a "Total / Symmetric" extent menu for axial extrudes.
//

import SwiftUI
import simd

struct ExtrudeGizmoOverlay: View {
    @Bindable var viewModel: EditorViewModel

    /// The arrow handle's screen anchor: where the symbol is drawn (and grabbed),
    /// plus the pull direction's on-screen orientation.
    private struct ArrowAnchor {
        var point: CGPoint
        var dir: (x: CGFloat, y: CGFloat, angle: Double)
        var isValid: Bool
    }

    private var arrowAnchor: ArrowAnchor? {
        // `pullArrowState`, NOT `scene.pullArrow`: reading `scene` here made
        // every camera tick re-assemble the whole viewport scene (review S2).
        guard let arrow = viewModel.pullArrowState,
              let cam = viewModel.cameraControl else { return nil }
        let o = SIMD3<Double>(Double(arrow.origin.x), Double(arrow.origin.y), Double(arrow.origin.z))
        let d = simd_normalize(SIMD3<Double>(Double(arrow.direction.x),
                                             Double(arrow.direction.y),
                                             Double(arrow.direction.z)))
        guard let p0 = cam.worldToScreenPoint(o) else { return nil }
        let p1 = cam.worldToScreenPoint(o + d)
        let dir = screenDir(from: p0, to: p1)
        // Float off the cap — shares the grab-region offset so the touch target
        // sits exactly under the drawn symbol.
        let float = ViewportCoordinator.pullHandleScreenOffset
        return ArrowAnchor(
            point: CGPoint(x: p0.x + dir.x * float, y: p0.y + dir.y * float),
            dir: dir, isValid: arrow.isValid
        )
    }

    /// Screen gap the pill sits below the arrow handle — clears the symbol so
    /// the measurement pill never hides the arrow (any face orientation).
    private static let pillDropBelowArrow: CGFloat = 60

    var body: some View {
        let _ = viewModel.cameraEpoch
        GeometryReader { geo in
        ZStack {
            if let anchor = arrowAnchor {
                if !viewModel.editingExtrudeArrow {
                    pullSymbol(anchor)
                }
                if let label = viewModel.extrudeArrowLabel {
                    // Anchor the pill BELOW the arrow (screen-down) so it never
                    // overlaps the handle, whichever way the face points. While
                    // it is a text field, keep it clear of the on-screen
                    // keyboard (bug report 8c98bd3b).
                    let below = CGPoint(x: anchor.point.x,
                                        y: anchor.point.y + Self.pillDropBelowArrow)
                    pill(label)
                        .position(viewModel.editingExtrudeArrow
                                  ? MoveDistanceOverlay.clearOfKeyboard(below, in: geo.size)
                                  : below)
                }
            }
        }
        }
        // `worldToScreenPoint` returns full-screen (MTKView) coordinates, so the
        // overlay must span the full screen too — otherwise the safe-area inset
        // shifts every `.position` down and the handle/pill miss the geometry.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }

    /// The grab handle: the ACTUAL SF Symbol (`arrow.up.and.down`), drawn as an
    /// always-on-top overlay so it stays visible when the moving cap dips below
    /// or behind a surface (the 3D-drawn arrow used to get occluded there). It
    /// rides the pull arrow's world origin, projected each camera move, rotated
    /// so its axis follows the pull direction on screen. Hit-testing is disabled
    /// so drags fall through to the viewport, which grabs it geometrically.
    private func pullSymbol(_ anchor: ArrowAnchor) -> some View {
        ZStack {
            // The visible (rotated) symbol.
            ZStack {
                // Dark backing (a hair larger) → crisp outline like Shapr3D.
                symbolImage.foregroundStyle(Color(white: 0.08))
                    .scaleEffect(1.18)
                symbolImage.foregroundStyle(anchor.isValid ? Color(red: 0.20, green: 0.52, blue: 1.0)
                                                           : Color(red: 0.90, green: 0.26, blue: 0.26))
            }
            .rotationEffect(.radians(anchor.dir.angle + .pi / 2))
            .position(anchor.point)
            .allowsHitTesting(false)
            // A separate, un-rotated invisible marker at the exact grab point —
            // its accessibility frame is what UI tests target (rotation/nested
            // images make the symbol's own frame unreliable).
            Color.clear
                .frame(width: 52, height: 52)
                .contentShape(Rectangle())
                .position(anchor.point)
                .allowsHitTesting(false)
                .accessibilityElement()
                .accessibilityIdentifier("PullArrowHandle")
        }
    }

    private var symbolImage: some View {
        Image(systemName: "arrow.up.and.down")
            .font(.system(size: 30, weight: .bold))
    }

    /// Unit screen-space direction from `p0` toward `p1` (defaults to straight
    /// up when the axis projects to a point), plus its angle for rotation.
    private func screenDir(from p0: CGPoint, to p1: CGPoint?) -> (x: CGFloat, y: CGFloat, angle: Double) {
        guard let p1 else { return (0, -1, -.pi / 2) }
        let dx = p1.x - p0.x, dy = p1.y - p0.y
        let len = (dx * dx + dy * dy).squareRoot()
        guard len > 0.5 else { return (0, -1, -.pi / 2) }
        return (dx / len, dy / len, atan2(Double(dy), Double(dx)))
    }

    @ViewBuilder
    private func pill(_ label: EditorViewModel.ExtrudeArrowLabel) -> some View {
        if viewModel.editingExtrudeArrow {
            ExtrudeArrowField(viewModel: viewModel)
        } else {
            // Extent menu stacked above the value pill, centred on the arrow.
            VStack(spacing: 5) {
                if !label.isDiameter {
                    Menu {
                        Button { viewModel.setExtrudeSymmetric(false) } label: {
                            Label("Total", systemImage: label.symmetric ? "" : "checkmark")
                        }
                        Button { viewModel.setExtrudeSymmetric(true) } label: {
                            Label("Symmetric", systemImage: label.symmetric ? "checkmark" : "")
                        }
                    } label: {
                        HStack(spacing: 2) {
                            Text(label.symmetric ? "Symmetric" : "Total").font(.caption2)
                            Image(systemName: "chevron.down").font(.system(size: 8))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.regularMaterial, in: Capsule())
                    }
                    .accessibilityIdentifier("ExtrudeExtentMenu")
                }

                Button {
                    viewModel.beginExtrudeArrowEdit()
                } label: {
                    Text(label.text)
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.blue, lineWidth: 1.5))
                        .foregroundStyle(Color.blue)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("ExtrudeArrowValue")
            }
        }
    }
}

private struct ExtrudeArrowField: View {
    @Bindable var viewModel: EditorViewModel
    @State private var text = ""
    @State private var padOpen = false
    @State private var usingSystemKeyboard = CADPreferences.prefersSystemKeyboard
    @FocusState private var focused: Bool

    var body: some View {
        // An INLINE card, like the sketch dimension field. A `.popover` works
        // from a bar or a panel but does not reliably present from these
        // canvas-floating overlays, so the pad is stacked under the pill.
        VStack(spacing: 6) {
            pill
            if padOpen && !usingSystemKeyboard {
                NumericKeypad(
                    text: $text,
                    isLocked: nil,
                    onCommit: {
                        padOpen = false
                        viewModel.commitExtrudeArrowEdit(text)
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
        TextField("", text: $text)
            .keyboardType(.numbersAndPunctuation)
            .autocorrectionDisabled()
            .multilineTextAlignment(.center)
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .frame(width: 84)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.blue, lineWidth: 1.5))
            .focused($focused)
            .allowsHitTesting(usingSystemKeyboard)
            .submitLabel(.done)
            .onSubmit { viewModel.commitExtrudeArrowEdit(text) }
            .accessibilityIdentifier("ExtrudeArrowField")
            .contentShape(Rectangle())
            .onTapGesture { if !usingSystemKeyboard { padOpen = true } }
            .onAppear {
                // Seed with the numeric part of the current label.
                text = (viewModel.extrudeArrowLabel?.text ?? "")
                    .replacingOccurrences(of: "⌀ ", with: "")
                    .replacingOccurrences(
                        of: " " + CADPreferences.shared.unit.symbol, with: "")
                if usingSystemKeyboard { focused = true } else { padOpen = true }
            }
    }
}
