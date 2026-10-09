//
//  CADScriptPanelView.swift
//  FloeCADKit
//
//  ShapeScript panel for the Floe workbench: explicit record selection (load
//  source + parameters), editable numeric parameters, a real evaluation
//  PREVIEW (triangle/polygon counts + bounds — never a blind apply), an
//  explicit conflict choice (`auto` refuses, `fork` keeps the edited body,
//  `rebuild` overwrites) and record save/delete through `CADScriptService`.
//
//  SPDX-License-Identifier: MPL-2.0
//

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

struct CADScriptPanelView: View {
    /// The default source shown for a new script. MUST be valid ShapeScript:
    /// a leading `#` is a comment in some languages but a parse error here
    /// (CUA 2026-10-10), so the default is a plain, previewable cube.
    static let defaultSource = "cube { size 10 }"

    let document: FloeCADDocument
    @State private var records: [[String: Any]] = []
    @State private var outcome: [String: Any] = Dictionary<String, Any>()
    @State private var busy = false
    @State private var selectedRecordID: String?
    @State private var name = ""
    @State private var source = CADScriptPanelView.defaultSource
    @State private var parameters: [ParameterRow] = []
    @State private var conflictMode = "auto"
    @State private var previewLines: [String] = []
    @State private var previewMesh: [String: Any]?
    @State private var previewHash: String?
    @State private var previewChangeCount: Int?

    private struct ParameterRow: Identifiable {
        let id = UUID()
        var name: String
        var value: String
    }

    var body: some View {
        WorkbenchPanelChrome(title: FloeCADStrings.text("cad.workbench.panel.script", "ShapeScript"),
                             identifier: "CADScriptPanel") {
            TextEditor(text: $source)
                .font(.system(.callout, design: .monospaced))
                .frame(minHeight: 110, maxHeight: 180)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                .accessibilityIdentifier("CADScriptSource")
            TextField(FloeCADStrings.text("cad.workbench.script.name", "Record name"), text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("CADScriptName")

            PanelSection(title: FloeCADStrings.text("cad.workbench.script.parameters", "Parameters")) {
                ForEach(parameters.indices, id: \.self) { index in
                    HStack(spacing: 8) {
                        TextField("name", text: $parameters[index].name)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        TextField("value", text: $parameters[index].value)
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.numbersAndPunctuation)
                        Button(role: .destructive) {
                            parameters.remove(at: index)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .accessibilityIdentifier("CADScriptParameterRemove-\(index)")
                    }
                }
                panelHitTarget(Button(FloeCADStrings.text("cad.workbench.script.addParameter",
                                                          "Add parameter")) {
                    parameters.append(ParameterRow(name: "", value: "0"))
                }
                    .buttonStyle(.bordered)
                    .controlSize(.small))
            }

            PanelActionGrid {
                PanelActionButton(title: FloeCADStrings.label("cad.workbench.script.preview", "Preview"),
                                  systemImage: "eye", disabled: busy) {
                    run { await $0.handle(action: "preview", args: self.inlineArgs()) }
                }
                PanelActionButton(title: FloeCADStrings.label("cad.workbench.script.apply", "Apply"),
                                  systemImage: "checkmark.circle", disabled: busy) {
                    apply()
                }
                PanelActionButton(title: FloeCADStrings.label("cad.workbench.script.save", "Save record"),
                                  systemImage: "square.and.arrow.down", disabled: busy) {
                    saveRecord()
                }
                PanelActionButton(title: FloeCADStrings.label("cad.workbench.script.list", "Records"),
                                  systemImage: "list.bullet", disabled: busy) {
                    run { await $0.handle(action: "list", args: [:]) }
                }
            }

            Picker(FloeCADStrings.text("cad.workbench.script.conflict", "On manual-edit conflict"),
                   selection: $conflictMode) {
                Text(FloeCADStrings.text("cad.workbench.script.conflictAuto", "Refuse (safe)"))
                    .tag("auto")
                Text(FloeCADStrings.text("cad.workbench.script.conflictFork", "Fork new body"))
                    .tag("fork")
                Text(FloeCADStrings.text("cad.workbench.script.conflictRebuild", "Rebuild (overwrite)"))
                    .tag("rebuild")
            }
            .accessibilityIdentifier("CADScriptConflict")

            if busy { ProgressView().controlSize(.small) }
            PanelOutcome(reply: outcome)

            if !previewLines.isEmpty || previewMesh != nil {
                PanelSection(title: FloeCADStrings.text("cad.workbench.script.previewTitle", "Preview")) {
                    if let previewMesh {
                        CADTransientPreviewView(mesh: previewMesh)
                    }
                    ForEach(previewLines, id: \.self) { line in
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("CADScriptPreview")
            }

            if records.isEmpty {
                PanelEmptyState(
                    text: FloeCADStrings.text("cad.workbench.script.empty", "No script records yet."),
                    hint: FloeCADStrings.text("cad.workbench.script.emptyHint",
                                              "Write ShapeScript above and Preview it — applying creates a body bound to its source so later manual edits are detected, never overwritten silently."))
            } else {
                PanelSection(title: FloeCADStrings.text("cad.workbench.script.records", "Records")) {
                    ForEach(records.indices, id: \.self) { index in
                        let record = records[index]
                        VStack(alignment: .leading, spacing: 4) {
                            panelHitTarget(
                                Button {
                                    load(record)
                                } label: {
                                    HStack(spacing: 8) {
                                        Text(record["name"] as? String
                                             ?? FloeCADStrings.text("cad.ui.script.untitled", "Script"))
                                            .font(.callout)
                                        if record["stale"] as? Bool == true {
                                            PanelBadge(text: FloeCADStrings.text("cad.workbench.badge.stale", "stale"),
                                                       tint: .orange)
                                        } else if record["outputBodyID"] != nil {
                                            PanelBadge(text: FloeCADStrings.text("cad.workbench.script.applied", "applied"),
                                                       tint: .green)
                                        }
                                        if record["id"] as? String == selectedRecordID {
                                            PanelBadge(text: FloeCADStrings.text("cad.workbench.script.selected", "selected"),
                                                       tint: .blue)
                                        }
                                        Spacer(minLength: 4)
                                        if let triangles = record["outputTriangleCount"] as? Int {
                                            Text(FloeCADStrings.format("cad.workbench.script.triangles",
                                                                       "%@ triangles", triangles))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small))
                            .accessibilityIdentifier("CADScriptRecord-\(record["id"] as? String ?? "\(index)")")
                            HStack(spacing: 8) {
                                panelHitTarget(Button(FloeCADStrings.text("cad.workbench.script.applySelected",
                                                                          "Apply this record")) {
                                    guard let id = record["id"] as? String else { return }
                                    run { await $0.handle(action: "apply",
                                                          args: ["id": id,
                                                                 "conflict": self.conflictMode]) }
                                }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small))
                                panelHitTarget(Button(role: .destructive) {
                                    remove(record)
                                } label: {
                                    Text(FloeCADStrings.text("cad.workbench.script.remove", "Remove"))
                                }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small))
                            }
                        }
                    }
                }
            }
        }
        .task { run { await $0.handle(action: "list", args: [:]) } }
    }

    // MARK: Helpers

    private func parameterDictionary() -> [String: Double]? {
        var result: [String: Double] = [:]
        for row in parameters {
            let key = row.name.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            let valueText = row.value.trimmingCharacters(in: .whitespaces)
            guard let value = Double(valueText), value.isFinite else { return nil }
            result[key] = value
        }
        return result
    }

    private func inlineArgs() -> [String: Any] {
        var args: [String: Any] = ["source": source]
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        if !trimmedName.isEmpty { args["name"] = trimmedName }
        if let parameters = parameterDictionary() { args["parameters"] = parameters }
        return args
    }

    private func apply() {
        guard parameterDictionary() != nil else {
            outcome = ["ok": false,
                       "message": FloeCADStrings.text("cad.workbench.script.badParameter",
                                                      "Every parameter needs a name and a finite numeric value.")]
            return
        }
        busy = true
        Task { @MainActor in
            let service = CADScriptService(document: document)
            var applyArgs: [String: Any]
            if let selectedRecordID {
                // Persist the editor's edits to the selected record first, so
                // apply evaluates exactly the source/parameters on screen.
                var putArgs = inlineArgs()
                putArgs["id"] = selectedRecordID
                let putReply = await service.handle(action: "put", args: putArgs)
                guard putReply["ok"] as? Bool == true else {
                    outcome = putReply
                    busy = false
                    return
                }
                if putReply["mutated"] as? Bool == true { _ = await document.save() }
                applyArgs = ["id": selectedRecordID, "conflict": conflictMode]
                // The put changes the change count but not the evaluation
                // inputs; bind the preview hash only.
                if let previewHash { applyArgs["expectedPreviewHash"] = previewHash }
            } else {
                applyArgs = inlineArgs()
                applyArgs["conflict"] = conflictMode
                // Inline apply has no intervening write: bind BOTH the preview
                // hash and the change count so an edited editor/script after
                // the preview refuses instead of committing unseen geometry.
                if let previewHash { applyArgs["expectedPreviewHash"] = previewHash }
                if let previewChangeCount { applyArgs["expectedChangeCount"] = previewChangeCount }
            }
            let reply = await service.handle(action: "apply", args: applyArgs)
            finish(reply: reply)
        }
    }

    private func saveRecord() {
        guard parameterDictionary() != nil else {
            outcome = ["ok": false,
                       "message": FloeCADStrings.text("cad.workbench.script.badParameter",
                                                      "Every parameter needs a name and a finite numeric value.")]
            return
        }
        var args = inlineArgs()
        if let selectedRecordID { args["id"] = selectedRecordID }
        run { await $0.handle(action: "put", args: args) }
    }

    private func remove(_ record: [String: Any]) {
        guard let id = record["id"] as? String else { return }
        run { await $0.handle(action: "remove", args: ["id": id]) }
    }

    private func load(_ record: [String: Any]) {
        selectedRecordID = record["id"] as? String
        name = record["name"] as? String ?? ""
        source = record["source"] as? String ?? ""
        if let raw = record["parameters"] as? [String: Double] {
            parameters = raw.keys.sorted().map { ParameterRow(name: $0, value: "\(raw[$0] ?? 0)") }
        } else if let raw = record["parameters"] as? [String: Any] {
            parameters = raw.keys.sorted().compactMap { key in
                guard let value = raw[key] as? Double else { return nil }
                return ParameterRow(name: key, value: "\(value)")
            }
        } else {
            parameters = []
        }
        previewLines = []
    }

    private func run(_ operation: @escaping @MainActor (CADScriptService) async -> [String: Any]) {
        busy = true
        Task { @MainActor in
            let service = CADScriptService(document: document)
            let reply = await operation(service)
            finish(reply: reply)
        }
    }

    /// Shared completion for every script action: commit mutations, refresh
    /// the record list, build the preview summary from an evaluation reply.
    private func finish(reply: [String: Any]) {
        if reply["mutated"] as? Bool == true {
            Task { @MainActor in _ = await document.save() }
        }
        if let list = reply["scripts"] as? [[String: Any]] {
            records = list
        }
        // Every non-preview action invalidates the previous preview binding.
        previewLines = []
        previewMesh = nil
        previewHash = nil
        previewChangeCount = nil
        if reply["preview"] as? Bool == true,
           reply["ok"] as? Bool == true,
           let triangles = reply["triangleCount"] as? Int {
            var lines = [FloeCADStrings.format("cad.workbench.script.previewTriangles",
                                               "%@ triangles", triangles)]
            if let polygons = reply["polygonCount"] as? Int {
                lines.append(FloeCADStrings.format("cad.workbench.script.previewPolygons",
                                                   "%@ polygons", polygons))
            }
            if let bounds = reply["bounds"] as? [[Double]], bounds.count == 2 {
                let size = zip(bounds[1], bounds[0]).map { $1 - $0 }
                lines.append(FloeCADStrings.format("cad.workbench.script.previewBounds",
                                                   "Bounds (mm): %@ × %@ × %@",
                                                   CADPanelTransform.format(size.count > 0 ? size[0] : 0),
                                                   CADPanelTransform.format(size.count > 1 ? size[1] : 0),
                                                   CADPanelTransform.format(size.count > 2 ? size[2] : 0)))
            }
            lines.append(FloeCADStrings.text("cad.workbench.script.previewNoWrite",
                                             "Preview only — nothing was written."))
            previewLines = lines
            previewMesh = reply["mesh"] as? [String: Any]
            previewHash = reply["previewHash"] as? String
            previewChangeCount = reply["previewChangeCount"] as? Int
        }
        outcome = reply
        busy = false
    }
}
#endif
