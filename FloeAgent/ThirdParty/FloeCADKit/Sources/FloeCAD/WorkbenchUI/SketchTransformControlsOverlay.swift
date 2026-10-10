import SwiftUI
import simd

/// Explicit sketch Move/Rotate: white directional controls and nearby exact input.
struct SketchTransformControlsOverlay: View {
    @Bindable var viewModel: EditorViewModel
    @State private var editing: EditorViewModel.SketchTransformControl?
    @State private var dragging: EditorViewModel.SketchTransformControl?
    @State private var dragX = SIMD2<Double>(1, 0)
    @State private var dragY = SIMD2<Double>(0, 1)
    @State private var dragOffset = SIMD2<Double>.zero
    @State private var text = "0"
    @State private var initialValueSelected = true
    @State private var usingKeyboard = CADPreferences.prefersSystemKeyboard
    @FocusState private var focused: Bool

    var body: some View {
        let _ = viewModel.cameraEpoch
        GeometryReader { geo in
            if viewModel.sketchTransformActive, viewModel.mode.sketchTool == nil,
               viewModel.editingDimension == nil,
               let center = viewModel.sketchSelectionCentroid,
               let plane = viewModel.activeSketch?.plane,
               let camera = viewModel.cameraControl,
               let c = camera.worldToScreenPoint(plane.toWorld(center)),
               let px = camera.worldToScreenPoint(plane.toWorld(center + SIMD2(cos(viewModel.sketchTransformFrameAngle), sin(viewModel.sketchTransformFrameAngle)))),
               let py = camera.worldToScreenPoint(plane.toWorld(center + SIMD2(-sin(viewModel.sketchTransformFrameAngle), cos(viewModel.sketchTransformFrameAngle)))) {
                let x = SIMD2(Double(px.x - c.x), Double(px.y - c.y))
                let y = SIMD2(Double(py.x - c.x), Double(py.y - c.y))
                if simd_length(x) > 0.01, simd_length(y) > 0.01 {
                    let ux = simd_normalize(x), uy = simd_normalize(y)
                    ZStack {
                        Circle().fill(.white).overlay(Circle().stroke(.gray, lineWidth: 1))
                            .frame(width: 16, height: 16).position(c)
                            .allowsHitTesting(false)
                        ForEach(EditorViewModel.SketchTransformControl.allCases, id: \.self) { part in
                            control(part, center: c, x: x, y: y, ux: ux, uy: uy)
                            if let value = viewModel.retainedSketchTransformValue(part) {
                                Button { openInput(part) } label: {
                                    Text(formattedValue(value, part: part))
                                        .font(.caption.monospacedDigit())
                                        .padding(6)
                                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                                }
                                .accessibilityIdentifier("SketchTransformValue-\(part.rawValue)")
                                .position(x: c.x + (part == .y ? uy.x : ux.x) * 130,
                                          y: c.y + (part == .y ? uy.y : ux.y) * 130)
                            }
                        }
                        if let editing {
                            input(editing)
                                .position(editorPosition(c, size: geo.size))
                        }
                    }
                }
            }
        }
        .overlay {
            // Register exactly one Escape action for this operation. An open
            // exact-value editor cancels first; the next Escape exits the tool.
            // Keep it outside the selection-dependent controls so an armed,
            // unselected Move/Rotate can also be dismissed after Undo.
            if viewModel.sketchTransformActive, viewModel.editingDimension == nil {
                Button {
                    if editing != nil {
                        editing = nil
                        focused = false
                    } else {
                        viewModel.sketchTransformActive = false
                    }
                } label: { EmptyView() }
                .keyboardShortcut(.cancelAction)
                .frame(width: 0, height: 0)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .onChange(of: viewModel.sketchTransformActive) { _, active in
            if !active { editing = nil; dragging = nil }
        }
        .onChange(of: viewModel.selectedSketchEntityIDs) { _, _ in editing = nil }
    }

    private func control(_ part: EditorViewModel.SketchTransformControl,
                         center: CGPoint, x: SIMD2<Double>, y: SIMD2<Double>,
                         ux: SIMD2<Double>, uy: SIMD2<Double>) -> some View {
        let offset = part == .x ? ux * 80 : part == .y ? uy * 80 : (ux + uy) * 80
        let anchor = CGPoint(x: center.x + offset.x, y: center.y + offset.y)
        let rotation = part == .x ? atan2(ux.y, ux.x) : part == .y ? atan2(uy.y, uy.x) : atan2(offset.y, offset.x) + .pi / 2
        return ZStack {
            Image(systemName: part == .rotation ? "arrow.left.and.right" : "arrow.right")
                .foregroundStyle(Color(white: 0.2)).scaleEffect(1.10)
            Image(systemName: part == .rotation ? "arrow.left.and.right" : "arrow.right")
                .foregroundStyle(.white)
        }
        .font(.system(size: 28, weight: .semibold))
        .rotationEffect(.radians(rotation))
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .position(anchor)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("SketchTransform-\(part.rawValue)")
        .accessibilityLabel(part == .rotation ? "Rotate sketch" : "Move sketch \(part.title)")
        .accessibilityAddTraits(.isButton)
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global).onChanged { value in
            let delta = SIMD2(Double(value.translation.width), Double(value.translation.height))
            guard simd_length(delta) > 2 || dragging != nil else { return }
            if dragging == nil {
                editing = nil; dragging = part
                dragX = x; dragY = y; dragOffset = offset
            }
            let amount: Double
            if part == .rotation {
                let initialX = simd_normalize(dragX), initialY = simd_normalize(dragY)
                let start = atan2(simd_dot(dragOffset, initialY), simd_dot(dragOffset, initialX))
                let current = atan2(simd_dot(dragOffset + delta, initialY), simd_dot(dragOffset + delta, initialX))
                amount = (current - start) * 180 / .pi
            } else {
                let axis = part == .x ? dragX : dragY
                amount = simd_dot(delta, simd_normalize(axis)) / simd_length(axis)
            }
            viewModel.updateSketchTransformControl(part, value: amount)
        }.onEnded { _ in
            if dragging != nil {
                viewModel.endSketchTransformControl()
                dragging = nil
            } else {
                openInput(part)
            }
        })
    }

    private func formattedValue(_ value: Double, part: EditorViewModel.SketchTransformControl) -> String {
        let displayed = part == .rotation ? value : CADPreferences.shared.unit.display(fromMM: value)
        return String(format: "%.3g", displayed) + (part == .rotation ? "°" : " " + CADPreferences.shared.unit.symbol)
    }

    private func openInput(_ part: EditorViewModel.SketchTransformControl) {
        let value = viewModel.retainedSketchTransformValue(part) ?? 0
        let displayed = part == .rotation ? value : CADPreferences.shared.unit.display(fromMM: value)
        text = String(format: "%.12g", displayed)
        initialValueSelected = true; usingKeyboard = false
        editing = part
    }

    private func input(_ part: EditorViewModel.SketchTransformControl) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                Text(part.title).font(.caption.weight(.semibold))
                TextField("", text: $text)
                    .font(.caption.monospacedDigit())
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .allowsHitTesting(usingKeyboard)
                    .onSubmit { commit(part) }
                    .accessibilityIdentifier("SketchTransformField")
                Button { editing = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .accessibilityIdentifier("SketchTransformCancel")
            }
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
            if !usingKeyboard {
                NumericKeypad(text: $text, isLocked: nil, initialValueSelected: $initialValueSelected,
                    onCommit: { commit(part) }, onSwitchToSystemKeyboard: {
                        usingKeyboard = true; focused = true
                    })
            }
        }
        .frame(width: 300)
    }

    private func commit(_ part: EditorViewModel.SketchTransformControl) {
        if viewModel.commitSketchTransformControl(part, text: text) { editing = nil }
    }

    private func editorPosition(_ center: CGPoint, size: CGSize) -> CGPoint {
        let left: CGFloat = CADPreferences.shared.paletteOnRight ? 184 : 96
        let right: CGFloat = CADPreferences.shared.paletteOnRight ? 96 : 184
        let lowX = left + 150, highX = size.width - right - 150
        let lowY: CGFloat = 300, highY = size.height - 250
        return CGPoint(x: highX >= lowX ? min(max(center.x, lowX), highX) : size.width / 2,
                       y: highY >= lowY ? min(max(center.y, lowY), highY) : size.height / 2)
    }
}
