import SwiftUI

struct ThreadOptionsSheet: View {
    let document: FloeCADDocument
    @Bindable var viewModel: EditorViewModel
    private var editingID: FeatureID? { viewModel.threadEditingFeatureID }
    @State private var sourceRows: [[String: Any]] = []
    @State private var sourceID = ""
    @State private var diameter: Double = 8
    @State private var pitch: Double = 1.25
    @State private var length = "5"
    @State private var hand: ThreadSpec.Hand = .right
    @State private var ends: ThreadSpec.Ends = .flatTrim
    @State private var mode: ThreadSpec.Representation = .geometry
    @State private var initial: ThreadSpec?
    @State private var generation = 0
    @State private var detail: String?

    private func text(_ key: String, _ fallback: String) -> String { FloeCADStrings.text(key, fallback) }
    private var selectedSource: [String: Any]? { sourceRows.first { $0["id"] as? String == sourceID } }
    private var availableDiameters: [Double] {
        guard editingID == nil, let stock = selectedSource?["stock_diameter"] as? Double else {
            return ThreadCatalog.diameters
        }
        return ThreadCatalog.diameters.filter { !availablePitches(for: $0, stock: stock).isEmpty }
    }
    private func availablePitches(for diameter: Double, stock: Double? = nil) -> [Double] {
        guard editingID == nil, let stock = stock ?? (selectedSource?["stock_diameter"] as? Double) else {
            return ThreadCatalog.pitches(for: diameter)
        }
        let internalFace = selectedSource?["side"] as? String == "internal"
        return ThreadCatalog.pitches(for: diameter).filter { pitch in
            internalFace ? diameter - 5 * sqrt(3) * pitch / 8 >= stock - 1e-7
                : diameter <= stock + 1e-7
        }
    }
    private var settingsAreValid: Bool {
        guard let value = Double(length)
                ?? ExpressionEvaluator.evaluate(length, variables: document.session.variableValues()),
              value.isFinite, value >= 2 * pitch, value <= 32 * pitch, value <= 100,
              availablePitches(for: diameter).contains(pitch) else { return false }
        if editingID == nil {
            guard selectedSource != nil,
                  let available = selectedSource?["available_length"] as? Double else { return false }
            return value + (ends == .onePitchSetback ? 2 * pitch : 0) <= available + 1e-7
        }
        return true
    }
    private func selectCompatibleDefaults() {
        guard editingID == nil, selectedSource != nil else { return }
        if !availableDiameters.contains(diameter) {
            let internalFace = selectedSource?["side"] as? String == "internal"
            diameter = (internalFace ? availableDiameters.first : availableDiameters.last) ?? diameter
        }
        if !availablePitches(for: diameter).contains(pitch), let first = availablePitches(for: diameter).first {
            pitch = first
        }
    }
    var body: some View {
        NavigationStack {
            Form {
                if editingID == nil {
                    Picker(text("cad.thread.source", "Cylinder"), selection: $sourceID) {
                        ForEach(sourceRows.indices, id: \.self) { index in
                            Text(sourceLabel(sourceRows[index])).tag(sourceRows[index]["id"] as? String ?? "")
                        }
                    }
                    .accessibilityIdentifier("CADThreadSource")
                    if sourceRows.isEmpty { Text(text("cad.thread.noSource", "Choose a complete cylindrical face in an editable solid.")).foregroundStyle(.secondary) }
                }
                Section(text("cad.thread.basicProfile", "Metric basic profile")) {
                    LabeledContent(text("cad.thread.type", "Type"), value:
                        (initial?.side == .internal || selectedSource?["side"] as? String == "internal")
                            ? text("cad.thread.internal", "Internal") : text("cad.thread.external", "External"))
                    Picker(text("cad.thread.size", "Size"), selection: $diameter) {
                        ForEach(availableDiameters, id: \.self) { Text(String(format: "M%.0f", $0)).tag($0) }
                    }
                    .accessibilityIdentifier("CADThreadSize")
                    .onChange(of: diameter) { _, value in
                        if !availablePitches(for: value).contains(pitch) { pitch = availablePitches(for: value).first ?? pitch }
                    }
                    Picker(text("cad.thread.pitch", "Pitch"), selection: $pitch) {
                        ForEach(availablePitches(for: diameter), id: \.self) { Text(String(format: "%.3g mm", $0)).tag($0) }
                    }
                    .accessibilityIdentifier("CADThreadPitch")
                    LabeledContent(text("cad.thread.length", "Effective length (mm)")) {
                        TextField(text("cad.thread.length", "Effective length (mm)"), text: $length)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("CADThreadLength")
                    }
                    Picker(text("cad.thread.hand", "Hand"), selection: $hand) {
                        Text(text("cad.thread.right", "Right-hand")).tag(ThreadSpec.Hand.right)
                        Text(text("cad.thread.left", "Left-hand")).tag(ThreadSpec.Hand.left)
                    }
                    Picker(text("cad.thread.ends", "Ends"), selection: $ends) {
                        Text(text("cad.thread.flat", "Flat trim")).tag(ThreadSpec.Ends.flatTrim)
                        Text(text("cad.thread.setback", "Leave at least one pitch at each end")).tag(ThreadSpec.Ends.onePitchSetback)
                    }
                }
                Section {
                    Text(text("cad.thread.limits", "Length: 2–32 pitches, up to 100 mm."))
                        .font(.footnote).foregroundStyle(.secondary)
                    Picker(text("cad.thread.mode", "Representation"), selection: $mode) {
                        Text(text("cad.thread.geometry", "Geometry")).tag(ThreadSpec.Representation.geometry)
                        Text(text("cad.thread.schematic", "Schematic")).tag(ThreadSpec.Representation.schematic)
                    }
                    Text(mode == .geometry
                        ? text("cad.thread.geometryHelp", "Models the basic thread profile. Fit allowances are not included.")
                        : text("cad.thread.schematicHelp", "Keeps the solid unchanged and records the thread specification."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let detail {
                    Text(text("cad.thread.failed", "Check the size, length and available material.")).foregroundStyle(.orange)
                    DisclosureGroup(text("cad.thread.details", "Details")) { Text(detail).font(.footnote) }
                }
            }
            .navigationTitle(text("cad.thread.title", "Metric thread"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(text("cad.thread.cancel", "Cancel")) { viewModel.showThreadEditor = false }
                        .accessibilityIdentifier("CADThreadCancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(text("cad.thread.apply", "Apply"), action: apply)
                        .disabled(!settingsAreValid)
                        .accessibilityIdentifier("CADThreadApply")
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: sourceID) { _, _ in selectCompatibleDefaults() }
        .presentationDetents([.large])
    }
    private func sourceLabel(_ row: [String: Any]) -> String {
        let side = row["side"] as? String == "internal"
            ? text("cad.thread.internal", "Internal") : text("cad.thread.external", "External")
        return "\(row["name"] as? String ?? "") · \(side) Ø\(String(format: "%.3g", row["stock_diameter"] as? Double ?? 0))"
    }
    private func load() {
        detail = nil; initial = nil; sourceRows = []; sourceID = ""
        generation = document.session.changeCount
        if let id = editingID, let node = document.session.document.features.node(id),
           case let .thread(_, spec) = node.kind {
            initial = spec; diameter = spec.diameter; pitch = spec.pitch.value
            length = spec.effectiveLength.formula ?? String(spec.effectiveLength.value)
            hand = spec.hand; ends = spec.ends; mode = spec.representation
        } else {
            diameter = 8; pitch = 1.25; length = "5"; hand = .right; ends = .flatTrim; mode = .geometry
            let reply = CADParameterService(document: document).handle(action: "thread.sources", args: [:])
            sourceRows = reply["rows"] as? [[String: Any]] ?? []
            sourceID = sourceRows.first?["id"] as? String ?? ""
            selectCompatibleDefaults()
        }
    }
    private func apply() {
        guard document.session.changeCount == generation else {
            detail = text("cad.thread.stale", "The design changed. Reopen the thread settings.")
            return
        }
        var fields: [String: Any] = [:]
        if initial?.diameter != diameter { fields["diameter"] = diameter }
        if initial?.pitch.value != pitch { fields["pitch"] = pitch }
        let originalLength = initial.map { $0.effectiveLength.formula ?? String($0.effectiveLength.value) }
        if originalLength != length { fields["effective_length"] = length }
        if initial?.hand != hand { fields["hand"] = hand.rawValue }
        if initial?.ends != ends { fields["ends"] = ends.rawValue }
        if initial?.representation != mode { fields["representation"] = mode.rawValue }
        let action: String, args: [String: Any]
        if let id = editingID {
            action = "thread.update"
            args = ["feature_id": id.raw.uuidString, "changes": fields, "expected_change_count": generation]
        } else {
            // A save may advance revision without a geometry generation.
            // Refresh this same selection only after proving no edit occurred.
            let fresh = CADParameterService(document: document).handle(action: "thread.sources", args: [:])
            let rows = fresh["rows"] as? [[String: Any]] ?? []
            guard let source = rows.first(where: { $0["id"] as? String == sourceID }) else { return }
            action = "thread.create"
            var create = fields
            for key in ["body_id", "face_index", "query_token", "side"] { create[key] = source[key] }
            create["expected_change_count"] = generation
            args = create
        }
        let reply = CADParameterService(document: document).handle(action: action, args: args)
        if reply["ok"] as? Bool == true { viewModel.showThreadEditor = false }
        else {
            let diagnostics = reply["details"] as? [String] ?? []
            detail = diagnostics.isEmpty ? (reply["message"] as? String ?? "Thread rebuild refused.")
                : diagnostics.joined(separator: "\n")
            if reply["error"] as? String == "thread_rebuild_failed" { generation = document.session.changeCount }
        }
    }
}
