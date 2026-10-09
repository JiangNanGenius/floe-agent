//
//  HistoryPanelView.swift
//  openshape3d
//
//  Feature history / timeline panel (Phase D, Task C3): a leading sidebar
//  listing the parametric feature nodes in creation order (top = oldest) with
//  rename, suppress, delete, Zoom to, tap-to-select, an error badge, and an
//  inline distance editor for extrude / push-pull nodes. Mirrors the structure
//  and style of ItemsPanelView; consumes the C2 VM panel API.
//

import SwiftUI

struct HistoryPanelView: View {
    @Bindable var viewModel: EditorViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                sectionHeader("History")
                if viewModel.historyRows.isEmpty {
                    emptyRow("No features yet")
                }
                ForEach(Array(viewModel.historyRows.enumerated()), id: \.element.id) { index, row in
                    // Subtle divider marking where rollback begins: the first
                    // rolled-back row (the one whose predecessor is still active).
                    if row.isRolledBack,
                       index == 0 || viewModel.historyRows[index - 1].isRolledBack == false {
                        rollbackDivider
                    }
                    HistoryRowView(
                        icon: iconName(for: row.id),
                        row: row,
                        onSelect: { viewModel.selectFeature(row.id) },
                        onRename: { viewModel.renameFeature(row.id, to: $0) },
                        onToggleSuppressed: {
                            viewModel.setFeatureSuppressed(row.id, !row.suppressed)
                        },
                        onZoom: { viewModel.zoomToFeature(row.id) },
                        onDelete: { viewModel.deleteFeature(row.id) },
                        onRollbackHere: { viewModel.rollbackToFeature(row.id) },
                        onEditReferences: viewModel.referenceEditLabel(row.id).map { label in
                            (label: label, action: { viewModel.beginReferenceEdit(row.id) })
                        },
                        onEditScalar: { viewModel.editFeatureScalar(row.id, key: $0, value: $1) },
                        onSetOptionToggle: { viewModel.setFeatureOption(row.id, key: $0, toggle: $1) },
                        onSetOptionChoice: { viewModel.setFeatureOption(row.id, key: $0, choice: $1) },
                        onEditPatternCount: { viewModel.editPatternCount(row.id, $0) },
                        onEditPatternSpacing: { viewModel.editPatternSpacing(row.id, $0) },
                        onEditPatternAngle: { viewModel.editPatternAngle(row.id, $0) }
                    )
                    // Drag-to-reorder: the payload is the node's UUID; dropping it
                    // onto another row moves it to that row's position. Replaying
                    // out of dependency order surfaces a broken-ref badge (handled
                    // by the feature graph), so the reorder is never forbidden.
                    .draggable(AppDragPayload(kind: "feature", id: row.id.raw.uuidString)) {
                        Label(row.name, systemImage: "line.3.horizontal")
                            .font(.caption).padding(6)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                    // Typed payload (`AppDragPayload`): a String here was
                    // pasted into the row's Distance field by the text
                    // field's own drop handling.
                    .dropDestination(for: AppDragPayload.self) { items, _ in
                        reorder(droppedIDs: items.filter { $0.kind == "feature" }.map(\.id), onto: index)
                    }
                }
            }
            .padding(12)
        }
        .frame(width: 290)
        .frame(maxHeight: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
        .accessibilityIdentifier("HistoryPanel")
    }

    /// Move the dragged feature (by UUID payload) to the drop row's index.
    private func reorder(droppedIDs: [String], onto index: Int) -> Bool {
        guard let str = droppedIDs.first, let uuid = UUID(uuidString: str) else { return false }
        viewModel.moveFeature(FeatureID(raw: uuid), to: index)
        return true
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.barLabel)
            Spacer(minLength: 4)
            // When the timeline is rolled back, offer a one-tap return to the
            // full (latest) history. Hidden when rollbackIndex is nil.
            if viewModel.rollbackIndex != nil {
                Button {
                    viewModel.clearRollback()
                } label: {
                    Label("Return to Latest", systemImage: "arrow.uturn.forward")
                        .font(.caption2.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .accessibilityIdentifier("ReturnToLatest")
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    /// A thin dashed rule drawn just above the first rolled-back row to mark the
    /// boundary between the active (evaluated) prefix and the rolled-back tail.
    private var rollbackDivider: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.uturn.backward.circle")
                .font(.system(size: 11))
            Text("Rolled back")
                .font(.caption2.weight(.semibold))
            VStack { Divider() }
        }
        .foregroundStyle(.tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .accessibilityIdentifier("RollbackDivider")
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.barLabelDim)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
    }

    /// SF Symbol for a node kind (read directly from the graph node).
    private func iconName(for id: FeatureID) -> String {
        guard let node = viewModel.session.document.features.node(id) else { return "gearshape" }
        switch node.kind {
        case .primitive: return "cube"
        case .extrude: return "square.stack.3d.up"
        case .draftExtrude: return "square.stack.3d.up.trianglebadge.exclamationmark"
        case .boolean: return "circle.lefthalf.filled"
        case .pushPull: return "hand.draw"
        case .moveFace: return "arrow.up.and.down.and.arrow.left.and.right"
        case .scaleFace: return "arrow.down.left.and.arrow.up.right"
        case .rotateFace: return "rotate.3d"
        case .draftFace: return "triangle.righthalf.filled"
        case .revolve: return "arrow.triangle.2.circlepath"
        case .sweep: return "scribble.variable"
        case .loft: return "square.on.square.dashed"
        case .transform: return "move.3d"
        case .mirror: return "flip.horizontal"
        case .pattern: return "square.grid.3x3"
        case .chamfer: return "square.on.circle"
        case .fillet: return "circle.circle"
        case .shell: return "cube.transparent"
        case .deleteFace: return "square.slash"
        case .replaceFace: return "arrow.up.and.down.square"
        }
    }

}

/// One history row: a type icon, an editable name with the kind label beneath,
/// an inline labelled field per editable scalar (`row.scalars`: distance,
/// angle, radius, setback, thickness, factor, draft), a suppress toggle; tap
/// selects, an error badge surfaces the last eval error, and a context menu
/// offers Zoom to / Delete.
private struct HistoryRowView: View {
    let icon: String
    let row: EditorViewModel.FeatureRow
    let onSelect: () -> Void
    let onRename: (String) -> Void
    let onToggleSuppressed: () -> Void
    let onZoom: () -> Void
    let onDelete: () -> Void
    let onRollbackHere: () -> Void
    /// Non-nil when the kind re-picks references: "Edit Edges" (chamfer /
    /// fillet) or "Edit Faces" (shell / delete face) with the action.
    let onEditReferences: (label: String, action: () -> Void)?
    let onEditScalar: (EditorViewModel.FeatureScalarKey, Double) -> Void
    let onSetOptionToggle: (EditorViewModel.FeatureOptionKey, Bool) -> Void
    let onSetOptionChoice: (EditorViewModel.FeatureOptionKey, String) -> Void
    let onEditPatternCount: (Int) -> Void
    let onEditPatternSpacing: (Double) -> Void
    let onEditPatternAngle: (Double) -> Void

    @State private var draft = ""
    @State private var scalarTexts: [EditorViewModel.FeatureScalarKey: String] = [:]
    @State private var countText = ""
    @State private var spacingText = ""
    @State private var angleText = ""
    /// Which scalar's number pad is open, if any (the scalars are a ForEach,
    /// so a single flag would open every row's pad at once).
    @State private var padScalarKey: EditorViewModel.FeatureScalarKey?
    @State private var padCount = false
    @State private var padAngle = false
    @State private var padSpacing = false

    /// A row is visually de-emphasized when the node is suppressed OR sits at/
    /// after the rollback marker (its bodies are absent either way).
    private var dimmed: Bool { row.suppressed || row.isRolledBack }

    /// Drag-to-reorder handle: the one part of the row with no context
    /// menu, so a press here always lifts a drag. Same payload as the
    /// row-level draggable (the node's UUID); rows are the drop targets.
    private var reorderGrip: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.barLabelDim)
            .frame(width: 16, height: 30)
            .contentShape(Rectangle())
            .draggable(AppDragPayload(kind: "feature", id: row.id.raw.uuidString)) {
                Label(row.name, systemImage: "line.3.horizontal")
                    .font(.caption).padding(6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            .accessibilityLabel("Reorder")
            .accessibilityIdentifier("HistoryDragHandle-\(row.name)")
    }

    var body: some View {
        // The reorder grip sits OUTSIDE the content that carries the context
        // menu: on one view a long press opens the menu before a drag can
        // lift, which is what made press-and-drag reordering unreliable
        // (and left XCUITest facing a menu — "Not hittable", 2026-09-03).
        HStack(alignment: .center, spacing: 6) {
        reorderGrip
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .frame(width: 24)
                    .foregroundStyle(dimmed ? Color.barLabelDim : Color.barLabel)
                VStack(alignment: .leading, spacing: 1) {
                    TextField("Name", text: $draft)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .onSubmit { onRename(draft) }
                        .foregroundStyle(dimmed ? Color.barLabel : Color.primary)
                        .accessibilityIdentifier("HistoryName-\(row.name)")
                    HStack(spacing: 4) {
                        Text(row.kindLabel)
                            .font(.caption2)
                            .foregroundStyle(.barLabelDim)
                        if row.isRolledBack {
                            Text("· rolled back")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tint)
                                .accessibilityIdentifier("HistoryRolledBack-\(row.name)")
                        }
                    }
                }
                Spacer(minLength: 4)
                if row.hasError {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 14))
                        .foregroundStyle(.orange)
                        .help(row.errorText ?? "Error")
                        .accessibilityIdentifier("HistoryError-\(row.name)")
                }
                Button(action: onToggleSuppressed) {
                    Image(systemName: row.suppressed ? "eye.slash" : "eye")
                        .font(.system(size: 14))
                        .foregroundStyle(dimmed ? Color.barLabel : Color.primary)
                }
                .buttonStyle(.plain)
                .disabled(row.isRolledBack)
                .accessibilityIdentifier("HistorySuppress-\(row.name)")
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                        .foregroundStyle(.barLabel)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("HistoryDelete-\(row.name)")
            }

            if row.hasError, let text = row.errorText {
                Text(text)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                // The repair, right where the failure is reported (spec §18):
                // a stale reference is fixed by re-picking it, so the row's
                // reference edit doubles as the error's action.
                if let onEditReferences {
                    Button {
                        onEditReferences.action()
                    } label: {
                        Label(onEditReferences.label, systemImage: "wrench.and.screwdriver")
                            .font(.caption2.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .tint(.orange)
                    .padding(.leading, 32)
                    .accessibilityIdentifier("HistoryRepair-\(row.name)")
                }
            }

            if !row.scalars.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(row.scalars) { scalar in
                        // The primary field keeps the identifier the History
                        // UI tests address; secondary scalars are keyed.
                        let primary = scalar.key == .primary
                        HStack(spacing: 4) {
                            Text(scalar.label)
                                .font(.caption2)
                                .foregroundStyle(.barLabel)
                            TextField("", text: scalarBinding(scalar.key))
                                .textFieldStyle(.plain)
                                .keyboardType(.numbersAndPunctuation)
                                .autocorrectionDisabled()
                                .submitLabel(.done)
                                .frame(width: 64)
                                .onSubmit { commitScalar(scalar.key) }
                                .accessibilityIdentifier(
                                    primary ? "HistoryDistanceField"
                                            : "HistoryScalarField-\(scalar.key.rawValue)-\(row.name)")
                                .allowsHitTesting(false)
                                .contentShape(Rectangle())
                                .onTapGesture { padScalarKey = scalar.key }
                                .numericKeypad(
                                    isPresented: Binding(
                                        get: { padScalarKey == scalar.key },
                                        set: { if !$0 { padScalarKey = nil } }),
                                    text: scalarBinding(scalar.key),
                                    onCommit: {
                                        padScalarKey = nil
                                        commitScalar(scalar.key)
                                    })
                            Text(scalar.unit)
                                .font(.caption2)
                                .foregroundStyle(.barLabel)
                            Button { commitScalar(scalar.key) } label: {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 14))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier(
                                primary ? "HistoryDistanceCommit-\(row.name)"
                                        : "HistoryScalarCommit-\(scalar.key.rawValue)-\(row.name)")
                        }
                    }
                }
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .padding(.leading, 32)
                // Editing a rolled-back node is a silent no-op; block the fields.
                .disabled(row.isRolledBack)
            }

            if !row.options.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(row.options) { option in
                        switch option.value {
                        case let .toggle(isOn):
                            // A Button-backed checkbox, not `.switch`: the
                            // row's whole-area tap gesture (select) beats a
                            // UISwitch, but Buttons win — as the eye/trash do.
                            Toggle(option.label, isOn: Binding(
                                get: { isOn },
                                set: { onSetOptionToggle(option.key, $0) }))
                            .toggleStyle(HistoryCheckboxToggleStyle())
                            .accessibilityIdentifier("HistoryOption-\(option.key.rawValue)-\(row.name)")
                            .accessibilityValue(isOn ? "on" : "off")
                        case let .choice(selected, choices):
                            HStack(spacing: 4) {
                                Text(option.label)
                                    .font(.caption2)
                                    .foregroundStyle(.barLabel)
                                Picker(option.label, selection: Binding(
                                    get: { selected },
                                    set: { onSetOptionChoice(option.key, $0) })) {
                                    ForEach(choices, id: \.self) { Text($0).tag($0) }
                                }
                                .pickerStyle(.menu)
                                .labelsHidden()
                                .fixedSize() // one line: "Subtract", never "Sub-/tract"
                                .accessibilityIdentifier("HistoryOption-\(option.key.rawValue)-\(row.name)")
                            }
                        }
                    }
                }
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .padding(.leading, 32)
                .disabled(row.isRolledBack)
            }

            if row.isPattern {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text("Count")
                            .font(.caption2)
                            .foregroundStyle(.barLabel)
                        TextField("", text: $countText)
                            .textFieldStyle(.plain)
                            .keyboardType(.numberPad)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .frame(width: 44)
                            .onSubmit(commitCount)
                            .accessibilityIdentifier("PatternCountField-\(row.name)")
                            .allowsHitTesting(false)
                            .contentShape(Rectangle())
                            .onTapGesture { padCount = true }
                            .numericKeypad(
                                isPresented: $padCount,
                                text: $countText,
                                onCommit: {
                                    padCount = false
                                    commitCount()
                                })
                        Stepper(
                            "",
                            value: Binding(
                                get: { Int(countText) ?? row.patternCount ?? 1 },
                                set: { countText = String($0); onEditPatternCount($0) }
                            ),
                            in: 1...999
                        )
                        .labelsHidden()
                        .accessibilityIdentifier("PatternCountStepper-\(row.name)")
                        Button(action: commitCount) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 14))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("PatternCountCommit-\(row.name)")
                    }

                    if row.patternIsCircular == true {
                        HStack(spacing: 4) {
                            Text("Angle")
                                .font(.caption2)
                                .foregroundStyle(.barLabel)
                            TextField("", text: $angleText)
                                .textFieldStyle(.plain)
                                .keyboardType(.numbersAndPunctuation)
                                .autocorrectionDisabled()
                                .submitLabel(.done)
                                .frame(width: 60)
                                .onSubmit(commitAngle)
                                .accessibilityIdentifier("PatternAngleField-\(row.name)")
                                .allowsHitTesting(false)
                                .contentShape(Rectangle())
                                .onTapGesture { padAngle = true }
                                .numericKeypad(
                                    isPresented: $padAngle,
                                    text: $angleText,
                                    onCommit: {
                                        padAngle = false
                                        commitAngle()
                                    })
                            Text("°")
                                .font(.caption2)
                                .foregroundStyle(.barLabel)
                            Button(action: commitAngle) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 14))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("PatternAngleCommit-\(row.name)")
                        }
                    } else {
                        HStack(spacing: 4) {
                            Text("Spacing")
                                .font(.caption2)
                                .foregroundStyle(.barLabel)
                            TextField("", text: $spacingText)
                                .textFieldStyle(.plain)
                                .keyboardType(.numbersAndPunctuation)
                                .autocorrectionDisabled()
                                .submitLabel(.done)
                                .frame(width: 60)
                                .onSubmit(commitSpacing)
                                .accessibilityIdentifier("PatternSpacingField-\(row.name)")
                                .allowsHitTesting(false)
                                .contentShape(Rectangle())
                                .onTapGesture { padSpacing = true }
                                .numericKeypad(
                                    isPresented: $padSpacing,
                                    text: $spacingText,
                                    onCommit: {
                                        padSpacing = false
                                        commitSpacing()
                                    })
                            Text("mm")
                                .font(.caption2)
                                .foregroundStyle(.barLabel)
                            Button(action: commitSpacing) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 14))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("PatternSpacingCommit-\(row.name)")
                        }
                    }
                }
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .padding(.leading, 32)
                // Editing a rolled-back node is a silent no-op; block the fields.
                .disabled(row.isRolledBack)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .contextMenu {
            Button {
                onZoom()
            } label: {
                Label("Zoom to", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            Button {
                onRollbackHere()
            } label: {
                Label("Roll Back to Here", systemImage: "arrow.uturn.backward")
            }
            .accessibilityIdentifier("RollbackHere-\(row.name)")
            if let onEditReferences {
                Button {
                    onEditReferences.action()
                } label: {
                    Label(onEditReferences.label, systemImage: "scribble")
                }
                // "EditEdges-…" / "EditFaces-…" — the blend UI tests address the first.
                .accessibilityIdentifier(
                    "\(onEditReferences.label.replacingOccurrences(of: " ", with: ""))-\(row.name)")
            }
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("HistoryRow-\(row.name)")
        .onAppear {
            draft = row.name
            seedScalarText()
            seedPatternText()
        }
        .onChange(of: row.name) { _, updated in draft = updated }
        .onChange(of: row.scalars) { _, _ in seedScalarText() }
        .onChange(of: row.patternCount) { _, updated in
            countText = updated.map { String($0) } ?? ""
        }
        .onChange(of: row.patternSpacing) { _, updated in
            spacingText = updated.map(Self.fmt) ?? ""
        }
        .onChange(of: row.patternAngleDegrees) { _, updated in
            angleText = updated.map(Self.fmt) ?? ""
        }
    }

    private func seedPatternText() {
        countText = row.patternCount.map { String($0) } ?? ""
        spacingText = row.patternSpacing.map(Self.fmt) ?? ""
        angleText = row.patternAngleDegrees.map(Self.fmt) ?? ""
    }

    private func seedScalarText() {
        var texts: [EditorViewModel.FeatureScalarKey: String] = [:]
        for scalar in row.scalars { texts[scalar.key] = Self.fmt(scalar.value) }
        scalarTexts = texts
    }

    private func scalarBinding(_ key: EditorViewModel.FeatureScalarKey) -> Binding<String> {
        Binding(
            get: { scalarTexts[key] ?? "" },
            set: { scalarTexts[key] = $0 }
        )
    }

    private func commitScalar(_ key: EditorViewModel.FeatureScalarKey) {
        // Accept plain numbers and simple arithmetic ("25.4/2").
        guard let value = ExpressionEvaluator.evaluate(scalarTexts[key] ?? "") else { return }
        onEditScalar(key, value)
    }

    private func commitCount() {
        // Accept plain integers and simple arithmetic; round to nearest int.
        guard let value = ExpressionEvaluator.evaluate(countText) else { return }
        onEditPatternCount(Int(value.rounded()))
    }

    private func commitSpacing() {
        guard let value = ExpressionEvaluator.evaluate(spacingText) else { return }
        onEditPatternSpacing(value)
    }

    private func commitAngle() {
        guard let value = ExpressionEvaluator.evaluate(angleText) else { return }
        onEditPatternAngle(value)
    }

    private nonisolated static func fmt(_ v: Double) -> String {
        String(format: "%g", (v * 1000).rounded() / 1000)
    }
}

/// A checkbox drawn as a plain Button: the History row selects on a
/// whole-area tap gesture, which swallows a `.switch` toggle's touch but not
/// a Button's.
private struct HistoryCheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 6) {
                configuration.label
                    .font(.caption2)
                    .foregroundStyle(.barLabel)
                Spacer(minLength: 4)
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15))
                    .foregroundStyle(configuration.isOn ? Color.accentColor : Color.barLabel)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
