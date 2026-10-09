//
//  NumericInputBar.swift
//  openshape3d
//
//  Bottom contextual numeric input: dimension fields for the primitive being
//  edited. Committing a value goes through the same command path as any other
//  mutation, so it's undoable.
//

import SwiftUI

struct NumericInputBar: View {
    @Bindable var viewModel: EditorViewModel

    @State private var values: [Double] = []
    @FocusState private var focusedField: Int?

    /// The extrude bar's Distance field holds TEXT, not a formatted number:
    /// it takes the evaluator's arithmetic like every other numeric field
    /// (the arrow pill, the dimension field, the History rows), and the
    /// Extrude button applies whatever is typed before committing — a
    /// formatted field only flushed on Return, so a tap on Extrude used to
    /// commit the stale value silently (gotcha 37).
    @State private var extrudeDistanceText: String = ""
    @State private var extrudeDistancePadOpen = false
    @State private var extrudeDistanceUsesKeyboard = CADPreferences.prefersSystemKeyboard
    @FocusState private var extrudeDistanceFocused: Bool

    private func submitExtrudeDistance() {
        if applyExtrudeDistanceText() {
            viewModel.commitTool()
        } else {
            viewModel.errorMessage = String(
                format: FloeCADStrings.text("cad.ui.extrude.readDistance",
                                            "Couldn't read \"%@\" as a distance."),
                extrudeDistanceText
            )
        }
    }

    private func extrudeDistanceDisplay(_ mm: Double?) -> String {
        let shown = CADPreferences.shared.unit.display(fromMM: mm ?? 0)
        if abs(shown - shown.rounded()) < 1e-6 { return String(Int(shown.rounded())) }
        return String(format: "%g", (shown * 100).rounded() / 100)
    }

    /// Parse the field (arithmetic allowed) into the tool's distance.
    /// Returns false when the text is not a number, leaving the tool alone.
    @discardableResult
    private func applyExtrudeDistanceText() -> Bool {
        guard let typed = ExpressionEvaluator.evaluate(extrudeDistanceText) else { return false }
        viewModel.setExtrudeDistance(CADPreferences.shared.unit.mm(fromDisplay: typed))
        return true
    }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// A couple of bars carry controls too wide to share one row at iPhone
    /// width and move them to the bar's own row instead.
    private var isCompact: Bool { horizontalSizeClass == .compact }

    var body: some View {
        // (Exact-distance moves are typed in the pill riding the gizmo arrow —
        // `MoveDistanceOverlay` — not down here, so the field sits where the
        // user is looking.)
        if viewModel.scaleEntryActive {
            scaleBar
        } else if viewModel.mode == .rotatingAroundAxis,
                  viewModel.rotateAxisState?.hasAxis == true {
            rotateAxisBar
        } else if viewModel.mode == .patterning, let state = viewModel.patternState {
            patternBar(state)
        } else if let image = viewModel.selectedImage {
            imageBar(image)
        } else if let context = viewModel.toolContext, viewModel.mode != .pickingRevolveAxis,
                  !context.curvedRegion,
                  !viewModel.faceMoveActive, !viewModel.faceScaleActive, !viewModel.faceRotateActive {
            // While a face Move/Scale/Rotate tool is armed, the extrude bar is
            // hidden — only that gizmo (which deforms the solid) is shown.
            switch context.kind {
            case .extrude:
                // While the sweep path pick is armed but empty, the sweep bar
                // carries the prompt/cancel instead of the extrude controls.
                if viewModel.mode == .pickingSweepPath {
                    sweepBar(context)
                } else {
                    extrudeBar(context)
                }
            case .revolve:
                revolveBar(context)
            case .offsetPlane:
                offsetPlaneBar(context)
            case .sweep:
                sweepBar(context)
            case .loft:
                loftBar(context)
            }
        } else if case .sketching(_, .some(.polygon)) = viewModel.mode {
            polygonBar
        } else if let body = viewModel.editingPrimitiveBody, let spec = body.primitive {
            AdaptiveBar {
                Text(spec.displayName)
                    .font(.headline)
                    .fixedSize()

                ForEach(Array(fieldLabels(for: spec).enumerated()), id: \.offset) { index, label in
                    HStack(spacing: 6) {
                        Text(label)
                            .font(.caption)
                            .foregroundStyle(.barLabel)
                            .fixedSize()
                        // Raw millimetres: `.length` converts for display, so
                        // `unit.binding` here would convert twice. Values apply
                        // live, and Done / the pad's commit push them.
                        ExpressionValueField(
                            placeholder: label,
                            value: binding(at: index),
                            kind: .length,
                            clamp: nil,
                            width: 80,
                            identifier: "PrimitiveField-\(index)",
                            onSubmit: { commit() }
                        )
                    }
                }

                Spacer()
            } actions: {
                Button(FloeCADStrings.label("cad.ui.common.done", "Done")) {
                    commit()
                    viewModel.finishEditing()
                }
                .buttonStyle(.borderedProminent)
            }
            .onAppear { values = fieldValues(for: spec) }
            .onChange(of: body.id) {
                if let spec = viewModel.editingPrimitiveBody?.primitive {
                    values = fieldValues(for: spec)
                }
            }
            .onChange(of: focusedField) { old, new in
                // Commit when a field loses focus.
                if old != nil, new != old { commit() }
            }
        }
    }

    /// Uniform scale about the body pivot (spec §5.4): factor field, Copy
    /// badge (scales a duplicate), commit via Apply or an empty-grid tap.
    private var scaleBar: some View {
        AdaptiveBar {
            Text(FloeCADStrings.label("cad.ui.tool.scale", "Scale"))
                .font(.headline)
                .fixedSize()
            BarHint("Uniform, about the body pivot")

            HStack(spacing: 6) {
                Text(FloeCADStrings.label("cad.ui.scale.factor", "Factor"))
                    .font(.caption)
                    .foregroundStyle(.barLabel)
                    .fixedSize()
                // A multiplier, not a length — `.plain` so the display unit
                // never scales it.
                ExpressionValueField(
                    placeholder: FloeCADStrings.text("cad.ui.scale.factor", "Factor"),
                    value: Binding(
                        get: { viewModel.scalePendingFactor },
                        set: { viewModel.scalePendingFactor = $0 }
                    ),
                    kind: .plain,
                    clamp: nil,
                    width: 90,
                    identifier: "ScaleFactorField",
                    onSubmit: { viewModel.commitScale(factor: viewModel.scalePendingFactor) }
                )
            }

            Button(FloeCADStrings.label("cad.ui.scale.copy", "Copy")) {
                viewModel.scaleCopyOnCommit.toggle()
            }
            .buttonStyle(.bordered)
            .tint(viewModel.scaleCopyOnCommit ? Color.blue : .barLabel)
            .accessibilityIdentifier("ScaleCopyBadge")

            Spacer()
        } actions: {
            Button(FloeCADStrings.label("cad.ui.common.cancel", "Cancel")) {
                viewModel.cancelScaleEntry()
            }
            Button(FloeCADStrings.label("cad.ui.common.apply", "Apply")) {
                viewModel.commitScale(factor: viewModel.scalePendingFactor)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("ScaleApply")
        }
    }

    /// Rotate Around Axis (spec §5.3): angle entry once the axis is set;
    /// drags scrub in 5° steps, typed values are exact.
    private var rotateAxisBar: some View {
        AdaptiveBar {
            Text(FloeCADStrings.label("cad.ui.tool.rotate", "Rotate"))
                .font(.headline)
                .fixedSize()
            BarHint("Drag to rotate (5° steps), or type an angle")

            HStack(spacing: 6) {
                Text(FloeCADStrings.label("cad.ui.common.angle", "Angle"))
                    .font(.caption)
                    .foregroundStyle(.barLabel)
                    .fixedSize()
                ExpressionValueField(
                    placeholder: FloeCADStrings.text("cad.ui.common.angle", "Angle"),
                    value: Binding(
                        get: { viewModel.rotateAxisState?.angleDegrees ?? 0 },
                        set: { viewModel.setRotateAngle($0) }
                    ),
                    kind: .plain,
                    clamp: nil,
                    width: 90,
                    identifier: "RotateAxisAngle",
                    onSubmit: { viewModel.commitRotateAxis() }
                )
            }

            Spacer()
        } actions: {
            Button(FloeCADStrings.label("cad.ui.common.cancel", "Cancel")) {
                viewModel.cancelRotateAxis()
            }
            Button(FloeCADStrings.label("cad.ui.common.apply", "Apply")) {
                viewModel.commitRotateAxis()
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("RotateAxisApply")
        }
    }

    /// Pattern bar (plan §B5): Linear/Circular, axis, count, spacing/angle;
    /// instances preview live as ghosts in the viewport.
    private func patternBar(_ state: EditorViewModel.PatternState) -> some View {
        let axisChoices: [EditorViewModel.PatternState.Axis] = {
            guard state.isSketchPattern else { return [.x, .y, .z] }
            // Sketch patterns are in-plane: X/Y only; circular needs no axis.
            return state.kind == .linear ? [.x, .y] : []
        }()
        // The two segmented pickers are ~220pt wide together — at iPhone width
        // they pushed Count and Spacing off the right edge, so the bar opened
        // with neither of its numbers visible. Compact width gives them their
        // own row instead; regular width keeps the original single row.
        return AdaptiveBar(showsFooter: isCompact) {
            Text(FloeCADStrings.label("cad.ui.tool.pattern", "Pattern"))
                .font(.headline)
                .fixedSize()

            if !isCompact { patternPickers(axisChoices) }

            HStack(spacing: 6) {
                Text(FloeCADStrings.label("cad.ui.common.count", "Count"))
                    .font(.caption)
                    .foregroundStyle(.barLabel)
                    .fixedSize()
                // `count` is an Int; the field speaks Double, so round on the
                // way in. The range lives in `clamp` rather than the setter so
                // the field knows about it too.
                ExpressionValueField(
                    placeholder: FloeCADStrings.text("cad.ui.common.count", "Count"),
                    value: Binding(
                        get: { Double(viewModel.patternState?.count ?? 3) },
                        set: { viewModel.patternState?.count = Int($0.rounded()) }
                    ),
                    kind: .plain,
                    clamp: 1...64,
                    width: 60,
                    identifier: "PatternCount"
                )
            }

            if state.kind == .linear {
                HStack(spacing: 6) {
                    Text(FloeCADStrings.label("cad.ui.common.spacing", "Spacing"))
                        .font(.caption)
                        .foregroundStyle(.barLabel)
                        .fixedSize()
                    // Bind the RAW millimetres: `.length` does the display-unit
                    // conversion itself, so wrapping in `unit.binding` here
                    // would convert twice.
                    ExpressionValueField(
                        placeholder: FloeCADStrings.text("cad.ui.common.spacing", "Spacing"),
                        value: Binding(
                            get: { viewModel.patternState?.spacing ?? 6 },
                            set: { viewModel.patternState?.spacing = $0 }
                        ),
                        kind: .length,
                        clamp: nil,
                        width: 80,
                        identifier: "PatternSpacing"
                    )
                }
            } else {
                HStack(spacing: 6) {
                    Text(FloeCADStrings.label("cad.ui.common.angle", "Angle"))
                        .font(.caption)
                        .foregroundStyle(.barLabel)
                        .fixedSize()
                    ExpressionValueField(
                        placeholder: FloeCADStrings.text("cad.ui.common.angle", "Angle"),
                        value: Binding(
                            get: { viewModel.patternState?.totalAngle ?? 360 },
                            set: { viewModel.patternState?.totalAngle = $0 }
                        ),
                        kind: .plain,
                        clamp: nil,
                        width: 80,
                        identifier: "PatternAngle"
                    )
                }
            }

            Spacer()
        } actions: {
            Button(FloeCADStrings.label("cad.ui.common.cancel", "Cancel")) {
                viewModel.cancelPattern()
            }
            Button(FloeCADStrings.label("cad.ui.common.apply", "Apply")) {
                viewModel.commitPattern()
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("PatternApply")
        } footer: {
            patternPickers(axisChoices)
        }
    }

    /// Linear/Circular and the axis choice — one row at regular width, moved to
    /// the bar's own row at compact width.
    @ViewBuilder
    private func patternPickers(_ axisChoices: [EditorViewModel.PatternState.Axis]) -> some View {
        Picker("Type", selection: Binding(
            get: { viewModel.patternState?.kind ?? .linear },
            set: { viewModel.patternState?.kind = $0 }
        )) {
            ForEach(EditorViewModel.PatternState.Kind.allCases, id: \.self) { kind in
                Text(kind.rawValue).tag(kind)
            }
        }
        .pickerStyle(.segmented)
        .fixedSize()

        let constructionAxes = viewModel.session.document.axes
        if !constructionAxes.isEmpty {
            // With construction axes in the document the choice is no longer
            // three-way, and a segmented control carrying named axes would blow
            // the row's width apart at compact size (gotcha 11). A menu stays
            // one control wide however many axes exist.
            Menu {
                Picker("Axis", selection: axisSelection) {
                    ForEach(axisChoices, id: \.self) { axis in
                        Text(axis.rawValue).tag(PatternAxisChoice.world(axis))
                    }
                    ForEach(constructionAxes) { axis in
                        Text(axis.name).tag(PatternAxisChoice.construction(axis.id))
                    }
                }
            } label: {
                Label(currentAxisLabel(), systemImage: "line.diagonal.arrow")
                    .font(.caption)
                    .fixedSize()
            }
            .accessibilityIdentifier("PatternAxisMenu")
        } else if !axisChoices.isEmpty {
            Picker("Axis", selection: Binding(
                get: { viewModel.patternState?.axis ?? .x },
                set: { viewModel.patternState?.axis = $0 }
            )) {
                ForEach(axisChoices, id: \.self) { axis in
                    Text(axis.rawValue).tag(axis)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
    }

    /// A world axis or a construction axis, as one selectable value.
    private enum PatternAxisChoice: Hashable {
        case world(EditorViewModel.PatternState.Axis)
        case construction(ConstructionAxisID)
    }

    private var axisSelection: Binding<PatternAxisChoice> {
        Binding(
            get: {
                if let id = viewModel.patternState?.constructionAxisID {
                    return .construction(id)
                }
                return .world(viewModel.patternState?.axis ?? .x)
            },
            set: { choice in
                switch choice {
                case .world(let axis):
                    viewModel.patternState?.axis = axis
                    viewModel.patternState?.constructionAxisID = nil
                case .construction(let id):
                    viewModel.patternState?.constructionAxisID = id
                }
            }
        )
    }

    private func currentAxisLabel() -> String {
        if let id = viewModel.patternState?.constructionAxisID,
           let axis = viewModel.session.document.axes.first(where: { $0.id == id }) {
            return axis.name
        }
        return (viewModel.patternState?.axis ?? .x).rawValue
    }

    /// Opacity label + slider, sized for whichever row it lands on.
    private func opacityControl(_ image: InsertedImage, width: CGFloat) -> some View {
        HStack(spacing: 6) {
            Text("Opacity")
                .font(.caption)
                .foregroundStyle(.barLabel)
                .fixedSize()
            Slider(
                value: Binding(
                    get: { viewModel.selectedImage?.opacity ?? image.opacity },
                    set: { viewModel.setImageOpacity($0) }
                ),
                in: 0...1,
                onEditingChanged: { editing in
                    if editing {
                        viewModel.beginImageInteraction()
                    } else {
                        viewModel.endImageInteraction()
                    }
                }
            )
            .frame(width: width)
            .accessibilityIdentifier("ImageOpacitySlider")
        }
    }

    /// Selected inserted image (plan §B10): size field (max dimension, aspect
    /// preserved), opacity slider, and delete — all through UpdateImageCommand.
    private func imageBar(_ image: InsertedImage) -> some View {
        // At iPhone width the opacity slider ran off the right edge, and a
        // slider sharing a row with a horizontal ScrollView competes with it
        // for the drag. Giving it the bar's own row solves both: alone it fits,
        // so the scroll view never engages and the slider owns the gesture.
        AdaptiveBar(showsFooter: isCompact) {
            Text(image.name)
                .font(.headline)
                .lineLimit(1)
                .fixedSize()

            HStack(spacing: 6) {
                Text("Size")
                    .font(.caption)
                    .foregroundStyle(.barLabel)
                    .fixedSize()
                ExpressionValueField(
                    placeholder: "Size",
                    value: Binding(
                        get: {
                            viewModel.selectedImage.map { max($0.width, $0.height) }
                                ?? max(image.width, image.height)
                        },
                        set: { viewModel.setImageMaxDimension($0) }
                    ),
                    kind: .length,
                    clamp: nil,
                    width: 80,
                    identifier: "ImageSizeField"
                )
            }

            if !isCompact { opacityControl(image, width: 140) }

            Spacer()
        } actions: {
            Button(FloeCADStrings.label("cad.ui.common.delete", "Delete"), role: .destructive) {
                viewModel.deleteImage(image.id)
            }
            .accessibilityIdentifier("ImageDelete")
            Button(FloeCADStrings.label("cad.ui.common.done", "Done")) {
                viewModel.selectedImageID = nil
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("ImageDone")
        } footer: {
            opacityControl(image, width: 220)
        }
    }

    private var polygonBar: some View {
        AdaptiveBar {
            Text(FloeCADStrings.label("cad.ui.tool.polygon", "Polygon"))
                .font(.headline)
                .fixedSize()
            BarHint("Drag from center to a vertex")

            HStack(spacing: 6) {
                Text(FloeCADStrings.label("cad.ui.polygon.sides", "Sides"))
                    .font(.caption)
                    .foregroundStyle(.barLabel)
                    .fixedSize()
                ExpressionValueField(
                    placeholder: FloeCADStrings.text("cad.ui.polygon.sides", "Sides"),
                    value: Binding(
                        get: { Double(viewModel.polygonSides) },
                        set: { viewModel.polygonSides = Int($0.rounded()) }
                    ),
                    kind: .plain,
                    clamp: 3...64,
                    width: 60,
                    identifier: "PolygonSidesField"
                )
                Stepper(FloeCADStrings.label("cad.ui.polygon.sides", "Sides"),
                    value: Binding(
                        get: { viewModel.polygonSides },
                        set: { viewModel.polygonSides = min(max($0, 3), 64) }
                    ),
                    in: 3...64
                )
                .labelsHidden()
            }

            Spacer()
        }
    }

    /// Radial push/pull on a cylinder edits the diameter (Shapr3D Offset Face).
    private func diameterBar(_ context: EditorViewModel.ToolContext, radius: Double) -> some View {
        AdaptiveBar {
            Text(FloeCADStrings.label("cad.ui.diameter.title", "Diameter"))
                .font(.headline)
                .fixedSize()
            HStack(spacing: 6) {
                Text("⌀")
                    .font(.caption)
                    .foregroundStyle(.barLabel)
                    .fixedSize()
                ExpressionValueField(
                    placeholder: FloeCADStrings.text("cad.ui.diameter.title", "Diameter"),
                    value: Binding(
                        get: { 2 * (radius + (viewModel.toolContext?.distance ?? 0)) },
                        set: { viewModel.setExtrudeDistance($0 / 2 - radius) }
                    ),
                    kind: .length,
                    clamp: nil,
                    width: 100,
                    identifier: "RadialDiameterField",
                    onSubmit: { viewModel.commitTool() }
                )
            }
            Spacer()
        } actions: {
            Button(FloeCADStrings.label("cad.ui.common.cancel", "Cancel")) { viewModel.cancelTool() }
            Button(FloeCADStrings.label("cad.ui.common.apply", "Apply")) { viewModel.commitTool() }
                .buttonStyle(.borderedProminent)
        }
    }

    private func extrudeBar(_ context: EditorViewModel.ToolContext) -> some View {
        if let cyl = context.cylinderFace {
            return AnyView(diameterBar(context, radius: cyl.radius))
        }
        return AnyView(extrudeBarBody(context))
    }

    private func extrudeBarBody(_ context: EditorViewModel.ToolContext) -> some View {
        AdaptiveBar {
            Text(FloeCADStrings.label("cad.ui.tool.extrude", "Extrude"))
                .font(.headline)
                .fixedSize()

            HStack(spacing: 6) {
                Text(FloeCADStrings.label("cad.ui.common.distance", "Distance"))
                    .font(.caption)
                    .foregroundStyle(.barLabel)
                    .fixedSize()
                TextField(FloeCADStrings.text("cad.ui.common.distance", "Distance"), text: $extrudeDistanceText)
                .keyboardType(.numbersAndPunctuation)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
                .focused($extrudeDistanceFocused)
                .onAppear { extrudeDistanceText = extrudeDistanceDisplay(context.distance) }
                // A drag on the arrow moves the distance under the field;
                // mirror it unless the person is mid-edit.
                .onChange(of: viewModel.toolContext?.distance) { _, new in
                    if !extrudeDistanceFocused && !extrudeDistancePadOpen {
                        extrudeDistanceText = extrudeDistanceDisplay(new)
                    }
                }
                .onSubmit { submitExtrudeDistance() }
                .allowsHitTesting(extrudeDistanceUsesKeyboard)
                .contentShape(Rectangle())
                .onTapGesture {
                    if !extrudeDistanceUsesKeyboard { extrudeDistancePadOpen = true }
                }
                .numericKeypad(
                    isPresented: $extrudeDistancePadOpen,
                    text: $extrudeDistanceText,
                    onCommit: {
                        extrudeDistancePadOpen = false
                        submitExtrudeDistance()
                    },
                    onSwitchToSystemKeyboard: {
                        extrudeDistancePadOpen = false
                        extrudeDistanceUsesKeyboard = true
                        extrudeDistanceFocused = true
                    }
                )
            }

            // End condition: Through All / Up To Next resolve to a distance
            // from the bodies in the document and land in the field, where
            // the person can still change it (spec: SOLIDWORKS end conditions).
            Menu {
                ForEach(ExtrudeEnd.allCases, id: \.self) { end in
                    Button(end.title) {
                        if end == .blind { return }
                        // Text typed but not yet submitted still decides the
                        // direction (its sign), so apply it first.
                        if extrudeDistanceText != extrudeDistanceDisplay(context.distance) {
                            _ = applyExtrudeDistanceText()
                        }
                        if let mm = viewModel.resolveExtrudeEnd(end) {
                            extrudeDistanceText = extrudeDistanceDisplay(mm)
                        }
                    }
                }
            } label: {
                Label(FloeCADStrings.label("cad.ui.extrude.end", "End"), systemImage: "arrow.down.to.line")
                    .labelStyle(.titleOnly)
            }
            .accessibilityIdentifier("ExtrudeEndMenu")

            // Symmetric sides: distance is per-side, total depth 2×.
            Button(FloeCADStrings.label("cad.ui.extrude.symmetric", "Symmetric")) {
                viewModel.setExtrudeSymmetric(!context.symmetric)
            }
            .buttonStyle(.bordered)
            // Concrete grey, not hierarchical `.secondary` — see `.barLabel`.
            .tint(context.symmetric ? Color.accentColor : .barLabel)

            Spacer()
        } actions: {
            // Sketch profiles can revolve about one of their lines, sweep
            // along a path, loft to more profiles, or coil into a helix.
            if context.sketchID != nil {
                Button(FloeCADStrings.label("cad.ui.tool.revolve", "Revolve")) {
                    viewModel.beginRevolveAxisPick()
                }
                Button(FloeCADStrings.label("cad.ui.tool.sweep", "Sweep")) {
                    viewModel.beginSweepPathPick()
                }
                Button(FloeCADStrings.label("cad.ui.tool.loft", "Loft")) {
                    viewModel.beginLoftProfilePick()
                }
                Button(FloeCADStrings.label("cad.ui.tool.helix", "Helix")) {
                    viewModel.showHelixOptions = true
                }
            }
            // Face pulls can become an offset construction plane instead.
            if context.sourceBody != nil {
                Button(FloeCADStrings.label("cad.ui.tool.offsetPlane", "Offset Plane")) {
                    viewModel.beginOffsetPlane()
                }
            }
            Button(FloeCADStrings.label("cad.ui.common.cancel", "Cancel")) {
                viewModel.cancelTool()
            }
            Button(FloeCADStrings.label("cad.ui.tool.extrude", "Extrude")) {
                // Whatever is in the field is what the person means, even
                // without a Return first.
                if extrudeDistanceFocused || extrudeDistanceText != extrudeDistanceDisplay(context.distance) {
                    guard applyExtrudeDistanceText() else {
                        viewModel.errorMessage = String(
                            format: FloeCADStrings.text("cad.ui.extrude.readDistance",
                                                        "Couldn't read \"%@\" as a distance."),
                            extrudeDistanceText
                        )
                        return
                    }
                }
                viewModel.commitTool()
            }
            .buttonStyle(.borderedProminent)
        } footer: {
            // Boolean badge: manual result override (spec §4.1).
            HStack(spacing: 8) {
                Text(FloeCADStrings.label("cad.ui.extrude.result", "Result"))
                    .font(.caption)
                    .foregroundStyle(.barLabel)
                    .fixedSize()
                Picker(FloeCADStrings.label("cad.ui.extrude.result", "Result"), selection: Binding(
                    get: { viewModel.toolContext?.booleanOverride ?? .auto },
                    set: { viewModel.setBooleanOverride($0) }
                )) {
                    ForEach(BooleanOverride.allCases, id: \.self) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
        .sheet(isPresented: $viewModel.showHelixOptions) {
            HelixOptionsSheet { radius, pitch, turns in
                viewModel.commitHelixSweep(radius: radius, pitch: pitch, turns: turns)
            }
        }
    }

    /// Sweep path builder (plan §B1): taps chain sketch lines/arcs into the
    /// spine; commit sweeps the armed profile along it.
    private func sweepBar(_ context: EditorViewModel.ToolContext) -> some View {
        let count = context.sweepPathEntityIDs.count
        return AdaptiveBar {
            Text(FloeCADStrings.label("cad.ui.tool.sweep", "Sweep"))
                .font(.headline)
                .fixedSize()
            Text(count == 0
                ? "Tap sketch lines or arcs to build the path"
                : "\(count) path segment\(count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.barLabel)
                .fixedSize()

            Spacer()
        } actions: {
            Button(FloeCADStrings.label("cad.ui.common.cancel", "Cancel")) {
                viewModel.cancelSweepPathPick()
            }
            Button(FloeCADStrings.label("cad.ui.tool.sweep", "Sweep")) {
                viewModel.commitTool()
            }
            .buttonStyle(.borderedProminent)
            .disabled(count == 0)
            .accessibilityIdentifier("SweepCommit")
        }
    }

    /// Loft section collector (plan §B2): taps append profile fills in order;
    /// commit lofts through them.
    private func loftBar(_ context: EditorViewModel.ToolContext) -> some View {
        let count = context.loftProfiles.count
        return AdaptiveBar {
            Text(FloeCADStrings.label("cad.ui.tool.loft", "Loft"))
                .font(.headline)
                .fixedSize()
            Text("\(count) section\(count == 1 ? "" : "s") — tap more profile fills")
                .font(.caption)
                .foregroundStyle(.barLabel)
                .fixedSize()

            Spacer()
        } actions: {
            Button(FloeCADStrings.label("cad.ui.common.cancel", "Cancel")) {
                viewModel.cancelLoftProfilePick()
            }
            Button(FloeCADStrings.label("cad.ui.tool.loft", "Loft")) {
                viewModel.commitTool()
            }
            .buttonStyle(.borderedProminent)
            .disabled(count < 2)
            .accessibilityIdentifier("LoftCommit")
        }
    }

    private func offsetPlaneBar(_ context: EditorViewModel.ToolContext) -> some View {
        AdaptiveBar {
            Text(FloeCADStrings.label("cad.ui.tool.offsetPlane", "Offset Plane"))
                .font(.headline)
                .fixedSize()
            BarHint("Drag the arrow, or type a distance")

            HStack(spacing: 6) {
                Text(FloeCADStrings.label("cad.ui.common.distance", "Distance"))
                    .font(.caption)
                    .foregroundStyle(.barLabel)
                    .fixedSize()
                ExpressionValueField(
                    placeholder: FloeCADStrings.text("cad.ui.common.distance", "Distance"),
                    value: Binding(
                        get: { viewModel.toolContext?.distance ?? 0 },
                        set: { viewModel.setOffsetPlaneDistance($0) }
                    ),
                    kind: .length,
                    clamp: nil,
                    width: 90,
                    identifier: "OffsetPlaneDistanceField",
                    onSubmit: { viewModel.commitTool() }
                )
            }

            Spacer()
        } actions: {
            Button(FloeCADStrings.label("cad.ui.common.cancel", "Cancel")) {
                viewModel.cancelTool()
            }
            Button(FloeCADStrings.label("cad.ui.extrude.addPlane", "Add Plane")) {
                viewModel.commitTool()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func revolveBar(_ context: EditorViewModel.ToolContext) -> some View {
        AdaptiveBar {
            Text(FloeCADStrings.label("cad.ui.tool.revolve", "Revolve"))
                .font(.headline)
                .fixedSize()
            BarHint("Drag to sweep, or type an angle")

            HStack(spacing: 6) {
                Text(FloeCADStrings.label("cad.ui.common.angle", "Angle"))
                    .font(.caption)
                    .foregroundStyle(.barLabel)
                    .fixedSize()
                ExpressionValueField(
                    placeholder: FloeCADStrings.text("cad.ui.common.angle", "Angle"),
                    value: Binding(
                        get: { viewModel.toolContext?.angle ?? 360 },
                        set: { viewModel.setRevolveAngle($0) }
                    ),
                    kind: .plain,
                    clamp: nil,
                    width: 90,
                    identifier: "RevolveAngleField",
                    onSubmit: { viewModel.commitTool() }
                )
            }

            Spacer()
        } actions: {
            Button(FloeCADStrings.label("cad.ui.common.cancel", "Cancel")) {
                viewModel.cancelTool()
            }
            Button(FloeCADStrings.label("cad.ui.tool.revolve", "Revolve")) {
                viewModel.commitTool()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func binding(at index: Int) -> Binding<Double> {
        Binding(
            get: { index < values.count ? values[index] : 0 },
            set: { newValue in
                if index < values.count { values[index] = newValue }
            }
        )
    }

    private func commit() {
        guard let spec = viewModel.editingPrimitiveBody?.primitive,
              let newSpec = makeSpec(from: values, like: spec)
        else { return }
        viewModel.commitPrimitiveSpec(newSpec)
    }

    private func fieldLabels(for spec: PrimitiveSpec) -> [String] {
        switch spec {
        case .box: ["W", "D", "H"]
        case .cylinder: ["R", "H"]
        case .sphere: ["R"]
        }
    }

    private func fieldValues(for spec: PrimitiveSpec) -> [Double] {
        switch spec {
        case let .box(w, d, h): [w, d, h]
        case let .cylinder(r, h): [r, h]
        case let .sphere(r): [r]
        }
    }

    private func makeSpec(from values: [Double], like spec: PrimitiveSpec) -> PrimitiveSpec? {
        let sane = values.map { max($0, 0.01) }
        switch spec {
        case .box where sane.count >= 3:
            return .box(width: sane[0], depth: sane[1], height: sane[2])
        case .cylinder where sane.count >= 2:
            return .cylinder(radius: sane[0], height: sane[1])
        case .sphere where sane.count >= 1:
            return .sphere(radius: sane[0])
        default:
            return nil
        }
    }
}

/// Helix sweep options (plan §B16, spec §1.17): the armed profile sweeps
/// along a helical spine coiling up from the sketch plane.
struct HelixOptionsSheet: View {
    @State private var radius = 3.0
    @State private var pitch = 2.0
    @State private var turns = 3.0

    @Environment(\.dismiss) private var dismiss
    let onCreate: (Double, Double, Double) -> Void

    var body: some View {
        NavigationStack {
            Form {
                // Radius and pitch are lengths and now read in the document's
                // display unit like every other length in the app; they used to
                // be bare numbers that silently meant millimetres. Turns is a
                // count, so it stays `.plain`.
                LabeledContent(FloeCADStrings.label("cad.ui.helix.radius", "Radius")) {
                    ExpressionValueField(
                        placeholder: FloeCADStrings.text("cad.ui.helix.radius", "Radius"),
                        value: $radius, kind: .length,
                        clamp: 0.001...1e6, width: 90, identifier: "HelixRadius")
                }
                LabeledContent(FloeCADStrings.label("cad.ui.helix.pitch", "Pitch")) {
                    ExpressionValueField(
                        placeholder: FloeCADStrings.text("cad.ui.helix.pitch", "Pitch"),
                        value: $pitch, kind: .length,
                        clamp: 0.001...1e6, width: 90, identifier: "HelixPitch")
                }
                LabeledContent(FloeCADStrings.label("cad.ui.helix.turns", "Turns")) {
                    ExpressionValueField(
                        placeholder: FloeCADStrings.text("cad.ui.helix.turns", "Turns"),
                        value: $turns, kind: .plain,
                        clamp: 0.01...1000, width: 90, identifier: "HelixTurns")
                }
            }
            .navigationTitle(FloeCADStrings.label("cad.ui.tool.helix", "Helix"))
            .onDisappear { MacWindowTitle.restore() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(FloeCADStrings.label("cad.ui.common.cancel", "Cancel")) { dismiss() }
                        .accessibilityIdentifier("HelixCancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(FloeCADStrings.label("cad.ui.helix.create", "Create")) {
                        onCreate(radius, pitch, turns)
                        dismiss()
                    }
                    .accessibilityIdentifier("HelixCreate")
                }
            }
        }
        .presentationDetents([.medium])
    }
}
