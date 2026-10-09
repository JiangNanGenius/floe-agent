//
//  CADWorkbenchPanels.swift
//  FloeCADKit
//
//  Floe-owned workbench chrome for the native side of the CAD editor: assembly
//  instances/constraints/DOF/interference, drawing pages/views/dimensions/
//  exports, ShapeScript records and mesh operations. These views are the
//  interactive confirmation surface for the same services the `cad.document`
//  tool drives; mutating assistant proposals still require the grant banner.
//
//  Every user-visible string goes through `FloeCADStrings` so the host app can
//  route it to its localization catalog; without a host localizer the English
//  fallback is shown (never a bare key).
//
//  iPad-first layout contract (CUA 2026-10-10): the tools sheet fills its
//  width (no fixed 330pt column), every action is a real 44pt hit target, and
//  reports are NATIVE structured lists (instances / constraints / DOF /
//  conflicts / pages / records / results) with meaningful empty states —
//  never raw JSON, never a nested tiny popover.
//
//  SPDX-License-Identifier: MPL-2.0
//

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

// MARK: - Localization hook

/// Host-injected localization for Floe-owned workbench chrome. The package has
/// no dependency on the app's localization module; the host installs a closure
/// (e.g. `FloeL10n.localized`) at launch, and keys fall back to their English
/// text when the host has no entry.
public enum FloeCADStrings {
    nonisolated(unsafe) public static var localizer: (@Sendable (String) -> String?)?

    nonisolated public static func text(_ key: String, _ fallback: String) -> String {
        guard let localizer, let value = localizer(key) else { return fallback }
        return value.isEmpty ? fallback : value
    }

    /// Localized format string with `%@` substitution (same placeholder
    /// convention as the host catalog), e.g.
    /// `FloeCADStrings.format("cad.error.import", "Couldn't import “%@”.", name)`.
    nonisolated public static func format(_ key: String, _ fallback: String,
                                          _ arguments: Any...) -> String {
        let template = text(key, fallback)
        var result = ""
        var iterator = arguments.makeIterator()
        var index = template.startIndex
        while index < template.endIndex {
            let next = template.index(after: index)
            if template[index] == "%", next < template.endIndex, template[next] == "@",
               let argument = iterator.next() {
                result += String(describing: argument)
                index = template.index(after: next)
            } else {
                result.append(template[index])
                index = next
            }
        }
        return result
    }

    /// SwiftUI label text.
    nonisolated public static func label(_ key: String, _ fallback: String) -> LocalizedStringKey {
        LocalizedStringKey(text(key, fallback))
    }
}

// MARK: - Shared chrome

/// The 44-point hit-target floor the rest of the app follows; the CUA
/// measured 19–21pt panel buttons before this modifier existed.
private func panelHitTarget(_ button: some View) -> some View {
    button
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
}

private struct PanelActionButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        panelHitTarget(
            Button(action: action) {
                Label(title, systemImage: systemImage)
                    .lineLimit(1)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(disabled)
        )
    }
}

/// Action rows WRAP (adaptive grid) instead of squeezing — an HStack would
/// overflow or shrink buttons below the 44pt floor on narrower sheets.
private struct PanelActionGrid<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 10, alignment: .leading)],
                  spacing: 10) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A small status badge (stale/suppressed/conflict/...) used across panels.
private struct PanelBadge: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.22), in: Capsule())
            .foregroundStyle(tint)
    }
}

/// Readable, styled outcome line. Errors are complete sentences in the system
/// font — raw JSON never reaches the user (CUA 2026-10-10).
private struct PanelOutcome: View {
    let reply: [String: Any]

    private var message: String? {
        guard let text = reply["message"] as? String, !text.isEmpty else { return nil }
        return text
    }

    var body: some View {
        if let message {
            HStack(alignment: .top, spacing: 6) {
                if reply["ok"] as? Bool == false {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                Text(message)
                    .font(.callout)
                    .foregroundStyle(reply["ok"] as? Bool == false ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .accessibilityIdentifier("CADPanelOutcome")
        }
    }
}

/// Empty state with an actionable hint, instead of a blank panel.
private struct PanelEmptyState: View {
    let text: String
    let hint: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .font(.callout.weight(.medium))
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Panel container: fills the tools-sheet width on iPad (no fixed narrow
/// column), scrolls its content, keeps the test identifier.
private struct WorkbenchPanelChrome<Content: View>: View {
    let title: String
    let identifier: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.headline)
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityIdentifier(identifier)
    }
}

/// One labelled section inside a panel report.
private struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
    }
}

// MARK: - Assembly

private struct AssemblyReport {
    struct Instance {
        var id: String
        var name: String
        var dof: Int
        var stale: Bool
        var hidden: Bool
        var independentCopy: Bool
    }
    struct Constraint {
        var id: String
        var kind: String
        var value: Double?
        var suppressed: Bool
        var valid: Bool
        var conflicting: Bool
    }
    var instances: [Instance] = []
    var constraints: [Constraint] = []
    var assemblyDOF = 0
    var unconstrainedCount = 0
    var conflictCount = 0
    var invalidCount = 0

    init(reply: [String: Any] = [:]) {
        assemblyDOF = reply["assemblyDOF"] as? Int ?? 0
        unconstrainedCount = (reply["unconstrainedInstances"] as? [String])?.count ?? 0
        let conflicts = Set(reply["conflicts"] as? [String] ?? reply["conflicting"] as? [String] ?? [])
        conflictCount = conflicts.count
        let invalid = Set(reply["invalidRefs"] as? [String] ?? [])
        invalidCount = invalid.count
        instances = (reply["instances"] as? [[String: Any]] ?? []).map { row in
            Instance(id: row["id"] as? String ?? "",
                     name: row["name"] as? String ?? "—",
                     dof: row["dof"] as? Int ?? 0,
                     stale: row["stale"] as? Bool ?? false,
                     hidden: row["hidden"] as? Bool ?? false,
                     independentCopy: row["independentCopy"] as? Bool ?? false)
        }
        constraints = (reply["constraints"] as? [[String: Any]] ?? []).map { row in
            Constraint(id: row["id"] as? String ?? "",
                       kind: row["kind"] as? String ?? "",
                       value: row["value"] as? Double,
                       suppressed: row["isSuppressed"] as? Bool
                           ?? row["suppressed"] as? Bool ?? false,
                       valid: row["valid"] as? Bool ?? true,
                       conflicting: conflicts.contains(row["id"] as? String ?? ""))
        }
    }
}

private func localizedConstraintKind(_ raw: String) -> String {
    let key = "cad.constraint.\(raw)"
    let fallback: String
    switch raw {
    case "fixed": fallback = "Fixed"
    case "coaxial": fallback = "Coaxial"
    case "planarAlign": fallback = "Planar align"
    case "distance": fallback = "Distance"
    case "angle": fallback = "Angle"
    default: fallback = raw
    }
    return FloeCADStrings.text(key, fallback)
}

struct CADAssemblyPanelView: View {
    let document: FloeCADDocument
    @Bindable var viewModel: EditorViewModel
    @State private var report = AssemblyReport()
    @State private var outcome: [String: Any] = Dictionary<String, Any>()
    @State private var busy = false

    private var selectedBodyID: UUID? {
        viewModel.selection.first?.raw
    }

    var body: some View {
        WorkbenchPanelChrome(title: FloeCADStrings.text("cad.workbench.panel.assembly", "Assembly"),
                             identifier: "CADAssemblyPanel") {
            PanelActionGrid {
                PanelActionButton(title: FloeCADStrings.label("cad.workbench.assembly.place", "Place instance"),
                                  systemImage: "cube.transparent", disabled: busy) {
                    run { service in
                        guard let bodyID = selectedBodyID ?? document.session.document.bodies.first?.id.raw else {
                            return ["ok": false,
                                    "message": FloeCADStrings.text("cad.ui.workbench.selectBody",
                                                                   "Select a body in the viewport first.")]
                        }
                        return await service.handleAsync(action: "addInstance",
                                                         args: ["bodyID": bodyID.uuidString])
                    }
                }
                PanelActionButton(title: FloeCADStrings.label("cad.workbench.assembly.solve", "Solve"),
                                  systemImage: "arrow.triangle.branch", disabled: busy) {
                    run { await $0.handleAsync(action: "solve", args: [:]) }
                }
                PanelActionButton(title: FloeCADStrings.label("cad.workbench.assembly.dof", "DOF"),
                                  systemImage: "number", disabled: busy) {
                    run { await $0.handleAsync(action: "dof", args: [:]) }
                }
                PanelActionButton(title: FloeCADStrings.label("cad.workbench.assembly.interference", "Interference"),
                                  systemImage: "square.on.square.dashed", disabled: busy) {
                    run { await $0.handleAsync(action: "interference", args: ["toleranceMM": 1e-6]) }
                }
                PanelActionButton(title: FloeCADStrings.label("cad.workbench.assembly.source", "Update sources"),
                                  systemImage: "arrow.triangle.2.circlepath", disabled: busy) {
                    run { await $0.handleAsync(action: "sourceUpdate", args: [:]) }
                }
            }

            if busy { ProgressView().controlSize(.small) }

            PanelOutcome(reply: outcome)

            assemblyReportContent
        }
        .task { refresh() }
    }

    @ViewBuilder
    private var assemblyReportContent: some View {
        if report.instances.isEmpty {
            PanelEmptyState(
                text: FloeCADStrings.text("cad.workbench.assembly.empty", "No assembly instances yet."),
                hint: FloeCADStrings.text("cad.workbench.assembly.emptyHint",
                                          "Select a body in the viewport and tap “Place instance”; constraints are solved against the placed instances."))
        } else {
            PanelSection(title: FloeCADStrings.text("cad.workbench.assembly.instances", "Instances")) {
                ForEach(report.instances, id: \.id) { instance in
                    HStack(spacing: 8) {
                        Text(instance.name)
                            .font(.callout)
                        Spacer(minLength: 4)
                        if instance.hidden {
                            PanelBadge(text: FloeCADStrings.text("cad.workbench.badge.hidden", "hidden"))
                        }
                        if instance.independentCopy {
                            PanelBadge(text: FloeCADStrings.text("cad.workbench.badge.copy", "copy"))
                        }
                        if instance.stale {
                            PanelBadge(text: FloeCADStrings.text("cad.workbench.badge.stale", "stale"),
                                       tint: .orange)
                        }
                        PanelBadge(text: FloeCADStrings.format("cad.workbench.assembly.dofEach", "%@ DOF", "\(instance.dof)"),
                                   tint: instance.dof == 0 ? .green : .blue)
                    }
                    .accessibilityIdentifier("CADAssemblyInstance-\(instance.id)")
                }
            }
            if !report.constraints.isEmpty {
                PanelSection(title: FloeCADStrings.text("cad.workbench.assembly.constraints", "Constraints")) {
                    ForEach(report.constraints, id: \.id) { constraint in
                        HStack(spacing: 8) {
                            Text(localizedConstraintKind(constraint.kind))
                                .font(.callout)
                            if let value = constraint.value {
                                Text("· \(Self.valueFormatter.string(from: NSNumber(value: value)) ?? "\(value)")")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            if constraint.suppressed {
                                PanelBadge(text: FloeCADStrings.text("cad.workbench.badge.suppressed", "suppressed"))
                            }
                            if !constraint.valid {
                                PanelBadge(text: FloeCADStrings.text("cad.workbench.badge.invalid", "invalid ref"),
                                           tint: .red)
                            }
                            if constraint.conflicting {
                                PanelBadge(text: FloeCADStrings.text("cad.workbench.badge.conflict", "conflict"),
                                           tint: .red)
                            }
                        }
                        .accessibilityIdentifier("CADAssemblyConstraint-\(constraint.id)")
                    }
                }
            }
            PanelSection(title: FloeCADStrings.text("cad.workbench.assembly.results", "Results")) {
                HStack(spacing: 10) {
                    PanelBadge(text: FloeCADStrings.format("cad.workbench.assembly.dofTotal", "%@ DOF total", "\(report.assemblyDOF)"),
                               tint: report.assemblyDOF == 0 ? .green : .blue)
                    if report.unconstrainedCount > 0 {
                        PanelBadge(text: FloeCADStrings.format("cad.workbench.assembly.unconstrained", "%@ unconstrained", "\(report.unconstrainedCount)"),
                                   tint: .orange)
                    }
                    if report.conflictCount > 0 {
                        PanelBadge(text: FloeCADStrings.format("cad.workbench.assembly.conflicts", "%@ conflicts", "\(report.conflictCount)"),
                                   tint: .red)
                    }
                    if report.invalidCount > 0 {
                        PanelBadge(text: FloeCADStrings.format("cad.workbench.assembly.invalid", "%@ invalid refs", "\(report.invalidCount)"),
                                   tint: .red)
                    }
                }
            }
        }
    }

    private static let valueFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.maximumFractionDigits = 3
        return formatter
    }()

    private func refresh() {
        run { await $0.handleAsync(action: "report", args: [:]) }
    }

    private func run(_ operation: @escaping @MainActor (CADAssemblyService) async -> [String: Any]) {
        busy = true
        Task { @MainActor in
            let service = CADAssemblyService(document: document)
            let reply = await operation(service)
            if reply["mutated"] as? Bool == true {
                _ = await document.save()
            }
            outcome = reply
            if reply["mutated"] as? Bool == true || reply["instanceCount"] != nil {
                // Mutations (place/solve/source update) change the report;
                // re-read it so the structured lists stay current.
                let fresh = await service.handleAsync(action: "report", args: [:])
                report = AssemblyReport(reply: fresh)
            }
            busy = false
        }
    }
}

// MARK: - Drawings

struct CADDrawingPanelView: View {
    let document: FloeCADDocument
    @Bindable var viewModel: EditorViewModel
    @State private var pages: [[String: Any]] = []
    @State private var outcome: [String: Any] = Dictionary<String, Any>()
    @State private var exportURL: URL?
    @State private var busy = false

    private var selectedBodyID: UUID? {
        viewModel.selection.first?.raw ?? document.session.document.bodies.first?.id.raw
    }

    var body: some View {
        WorkbenchPanelChrome(title: FloeCADStrings.text("cad.workbench.panel.drawing", "Drawings"),
                             identifier: "CADDrawingPanel") {
            PanelActionGrid {
                PanelActionButton(title: FloeCADStrings.label("cad.workbench.drawing.sheet", "Standard sheet"),
                                  systemImage: "doc.on.doc", disabled: busy) {
                    run { service in
                        guard let bodyID = selectedBodyID else {
                            return ["ok": false,
                                    "message": FloeCADStrings.text("cad.ui.workbench.selectBody",
                                                                   "Select a body in the viewport first.")]
                        }
                        return service.handle(action: "standardSheet",
                                              args: ["bodyID": bodyID.uuidString, "title": document.name])
                    }
                }
                PanelActionButton(title: FloeCADStrings.label("cad.workbench.drawing.refresh", "Refresh"),
                                  systemImage: "arrow.clockwise", disabled: busy) {
                    refresh()
                }
            }

            if busy { ProgressView().controlSize(.small) }
            PanelOutcome(reply: outcome)

            if pages.isEmpty {
                PanelEmptyState(
                    text: FloeCADStrings.text("cad.workbench.drawing.empty", "No drawing pages yet."),
                    hint: FloeCADStrings.text("cad.workbench.drawing.emptyHint",
                                              "Pick a body and tap “Standard sheet”; pages carry their own scale, paper and dimensions, and mark themselves stale when the model moves."))
            } else {
                PanelSection(title: FloeCADStrings.text("cad.workbench.drawing.pages", "Pages")) {
                    ForEach(pages.indices, id: \.self) { index in
                        let page = pages[index]
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Text(page["name"] as? String ?? "—")
                                    .font(.callout.weight(.semibold))
                                Text("· \(page["kind"] as? String ?? "")")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                if let scale = page["scale"] as? Int, scale > 0 {
                                    Text("· 1:\(scale)")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                                if page["stale"] as? Bool == true {
                                    PanelBadge(text: FloeCADStrings.text("cad.workbench.badge.stale", "stale"),
                                               tint: .orange)
                                }
                            }
                            HStack(spacing: 8) {
                                panelHitTarget(Button(FloeCADStrings.label("cad.workbench.drawing.project", "View")) {
                                    project(page)
                                }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small))
                                panelHitTarget(Button(FloeCADStrings.label("cad.workbench.drawing.pdf", "PDF")) {
                                    export(page, format: "pdf")
                                }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small))
                                panelHitTarget(Button("SVG") { export(page, format: "svg") }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small))
                                panelHitTarget(Button("DXF") { export(page, format: "dxf") }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small))
                            }
                        }
                        .padding(.vertical, 4)
                        .accessibilityIdentifier("CADDrawingPage-\(page["id"] as? String ?? "\(index)")")
                    }
                }
            }
            if let exportURL {
                ShareLink(item: exportURL) {
                    Label(FloeCADStrings.label("cad.workbench.drawing.share", "Share export"),
                          systemImage: "square.and.arrow.up")
                }
                .font(.callout)
            }
        }
        .task { refresh() }
    }

    private func refresh() {
        let service = CADDrawingService(document: document)
        let reply = service.handle(action: "pages", args: [:])
        pages = reply["pages"] as? [[String: Any]] ?? []
        outcome = reply
    }

    private func project(_ page: [String: Any]) {
        guard let id = page["id"] as? String, let uuid = UUID(uuidString: id) else { return }
        let service = CADDrawingService(document: document)
        let reply = service.pageGeometry(pageID: uuid)
        outcome = reply
    }

    private func export(_ page: [String: Any], format: String) {
        guard let id = page["id"] as? String, let uuid = UUID(uuidString: id) else { return }
        busy = true
        Task { @MainActor in
            let service = CADDrawingService(document: document)
            do {
                let data = try service.exportData(pageID: uuid, format: format)
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(document.name)-\(page["kind"] as? String ?? "page").\(format)")
                try data.write(to: url, options: [.atomic])
                exportURL = url
                outcome = ["ok": true,
                           "message": FloeCADStrings.format("cad.workbench.drawing.exported", "%@ export ready (%lld bytes).", format.uppercased(), data.count)]
            } catch {
                outcome = ["ok": false, "message": error.localizedDescription]
            }
            busy = false
        }
    }

    private func run(_ operation: @escaping @MainActor (CADDrawingService) -> [String: Any]) {
        busy = true
        Task { @MainActor in
            let service = CADDrawingService(document: document)
            let reply = operation(service)
            if reply["mutated"] as? Bool == true {
                _ = await document.save()
            }
            outcome = reply
            pages = service.handle(action: "pages", args: [:])["pages"] as? [[String: Any]] ?? []
            busy = false
        }
    }
}

// MARK: - ShapeScript

struct CADScriptPanelView: View {
    let document: FloeCADDocument
    @State private var source = "cube { size 10 }"
    @State private var scripts: [[String: Any]] = []
    @State private var outcome: [String: Any] = Dictionary<String, Any>()
    @State private var busy = false

    var body: some View {
        WorkbenchPanelChrome(title: FloeCADStrings.text("cad.workbench.panel.script", "ShapeScript"),
                             identifier: "CADScriptPanel") {
            TextEditor(text: $source)
                .font(.system(.callout, design: .monospaced))
                .frame(minHeight: 110, maxHeight: 180)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                .accessibilityIdentifier("CADScriptSource")
            PanelActionGrid {
                PanelActionButton(title: FloeCADStrings.label("cad.workbench.script.preview", "Preview"),
                                  systemImage: "eye", disabled: busy) {
                    run { await $0.handle(action: "preview", args: ["source": self.source]) }
                }
                PanelActionButton(title: FloeCADStrings.label("cad.workbench.script.apply", "Apply"),
                                  systemImage: "checkmark.circle", disabled: busy) {
                    run { await $0.handle(action: "apply", args: ["source": self.source, "name": "Script"]) }
                }
                PanelActionButton(title: FloeCADStrings.label("cad.workbench.script.list", "Records"),
                                  systemImage: "list.bullet", disabled: busy) {
                    run { await $0.handle(action: "list", args: [:]) }
                }
            }

            if busy { ProgressView().controlSize(.small) }
            PanelOutcome(reply: outcome)

            if scripts.isEmpty {
                PanelEmptyState(
                    text: FloeCADStrings.text("cad.workbench.script.empty", "No script records yet."),
                    hint: FloeCADStrings.text("cad.workbench.script.emptyHint",
                                              "Write ShapeScript on the left and Preview it — applying creates a body bound to its source so later manual edits are detected, never overwritten silently."))
            } else {
                PanelSection(title: FloeCADStrings.text("cad.workbench.script.records", "Records")) {
                    ForEach(scripts.indices, id: \.self) { index in
                        let script = scripts[index]
                        panelHitTarget(
                            Button {
                                if let id = script["id"] as? String {
                                    run { await $0.handle(action: "apply", args: ["id": id]) }
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Text(script["name"] as? String
                                         ?? FloeCADStrings.text("cad.ui.script.untitled", "Script"))
                                        .font(.callout)
                                    if script["stale"] as? Bool == true {
                                        PanelBadge(text: FloeCADStrings.text("cad.workbench.badge.stale", "stale"),
                                                   tint: .orange)
                                    } else if script["outputBodyID"] != nil {
                                        PanelBadge(text: FloeCADStrings.text("cad.workbench.script.applied", "applied"),
                                                   tint: .green)
                                    }
                                    Spacer(minLength: 4)
                                    if let triangles = script["outputTriangleCount"] as? Int {
                                        Text(FloeCADStrings.format("cad.workbench.script.triangles", "%@ triangles", "\(triangles)"))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        )
                        .accessibilityIdentifier("CADScriptRecord-\(script["id"] as? String ?? "\(index)")")
                    }
                }
            }
        }
        .task { run { await $0.handle(action: "list", args: [:]) } }
    }

    private func run(_ operation: @escaping @MainActor (CADScriptService) async -> [String: Any]) {
        busy = true
        Task { @MainActor in
            let service = CADScriptService(document: document)
            let reply = await operation(service)
            if reply["mutated"] as? Bool == true {
                _ = await document.save()
            }
            if let list = reply["scripts"] as? [[String: Any]] {
                scripts = list
            }
            outcome = reply
            busy = false
        }
    }
}

// MARK: - Mesh

struct CADMeshPanelView: View {
    let document: FloeCADDocument
    @Bindable var viewModel: EditorViewModel
    @State private var outcome: [String: Any] = Dictionary<String, Any>()
    @State private var busy = false

    private var selectedBodyIDs: [UUID] {
        viewModel.selection.map(\.raw)
    }

    var body: some View {
        WorkbenchPanelChrome(title: FloeCADStrings.text("cad.workbench.panel.mesh", "Mesh"),
                             identifier: "CADMeshPanel") {
            PanelBadge(text: FloeCADStrings.format("cad.workbench.mesh.selected", "%@ bodies selected", "\(selectedBodyIDs.count)"),
                       tint: selectedBodyIDs.count >= 2 ? .green : .secondary)
            if document.session.document.bodies.isEmpty {
                PanelEmptyState(
                    text: FloeCADStrings.text("cad.workbench.mesh.empty", "No bodies to work with yet."),
                    hint: FloeCADStrings.text("cad.workbench.mesh.emptyHint",
                                              "Sketch and extrude a solid first; mesh operations run on tessellations and keep analytic B-rep bodies intact unless you explicitly force a downgrade."))
            } else {
                PanelActionGrid {
                    PanelActionButton(title: FloeCADStrings.label("cad.workbench.mesh.union", "Union"),
                                      systemImage: "plus.square.on.square", disabled: busy || selectedBodyIDs.count < 2) {
                        boolean("union")
                    }
                    PanelActionButton(title: FloeCADStrings.label("cad.workbench.mesh.subtract", "Subtract"),
                                      systemImage: "minus.square", disabled: busy || selectedBodyIDs.count < 2) {
                        boolean("subtract")
                    }
                    PanelActionButton(title: FloeCADStrings.label("cad.workbench.mesh.intersect", "Intersect"),
                                      systemImage: "arrow.triangle.merge", disabled: busy || selectedBodyIDs.count < 2) {
                        boolean("intersect")
                    }
                }
                PanelActionGrid {
                    PanelActionButton(title: FloeCADStrings.label("cad.workbench.mesh.combine", "Combine"),
                                      systemImage: "square.on.square", disabled: busy || selectedBodyIDs.count < 2) {
                        combine()
                    }
                    PanelActionButton(title: FloeCADStrings.label("cad.workbench.mesh.repair", "Repair"),
                                      systemImage: "wrench.and.screwdriver", disabled: busy || selectedBodyIDs.isEmpty) {
                        single("repair", extra: ["tolerance": 1e-4])
                    }
                    PanelActionButton(title: FloeCADStrings.label("cad.workbench.mesh.simplify", "Simplify"),
                                      systemImage: "arrow.down.right.and.arrow.up.left", disabled: busy || selectedBodyIDs.isEmpty) {
                        single("simplify", extra: ["ratio": 0.5])
                    }
                    PanelActionButton(title: FloeCADStrings.label("cad.workbench.mesh.normals", "Normals"),
                                      systemImage: "arrow.up.and.down.and.arrow.left.and.right", disabled: busy || selectedBodyIDs.isEmpty) {
                        single("recomputeNormals", extra: [:])
                    }
                }
            }
            if busy { ProgressView().controlSize(.small) }
            PanelOutcome(reply: outcome)
        }
    }

    private func boolean(_ op: String) {
        let target = selectedBodyIDs[0].uuidString
        let tools = selectedBodyIDs.dropFirst().map(\.uuidString)
        perform(["action": "boolean", "op": op, "target": target, "tools": tools])
    }

    private func combine() {
        perform(["action": "combine", "bodyIDs": selectedBodyIDs.map(\.uuidString)])
    }

    private func single(_ action: String, extra: [String: Any]) {
        guard let bodyID = selectedBodyIDs.first else {
            outcome = ["ok": false,
                       "message": FloeCADStrings.text("cad.workbench.mesh.selectOne", "Select a body first.")]
            return
        }
        var args: [String: Any] = ["action": action, "bodyID": bodyID.uuidString]
        for (key, value) in extra { args[key] = value }
        perform(args)
    }

    private func perform(_ args: [String: Any]) {
        busy = true
        Task { @MainActor in
            let reply = CADMeshService(document: document).handle(action: args["action"] as? String ?? "boundary",
                                                                  args: args)
            if reply["mutated"] as? Bool == true {
                _ = await document.save()
            }
            outcome = reply
            busy = false
        }
    }
}

/// The single toolbar-toggled panel with a mode picker, so the editor gains
/// one overlay/button instead of four.
struct CADWorkbenchToolsPanel: View {
    let document: FloeCADDocument
    @Bindable var viewModel: EditorViewModel
    /// Host-injected Canvas actions; nil in standalone/qualification hosts.
    var canvasActions: CADCanvasActions? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var mode = 0
    @State private var isCanvasActionRunning = false
    @State private var canvasMessage: String?

    var body: some View {
        // NavigationStack gives the sheet an explicit Close control (drag-to-
        // dismiss alone failed the CUA accessibility/narrow-layout review).
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("", selection: $mode) {
                        Text(FloeCADStrings.label("cad.workbench.panel.assembly", "Assembly")).tag(0)
                        Text(FloeCADStrings.label("cad.workbench.panel.drawing", "Drawings")).tag(1)
                        Text(FloeCADStrings.label("cad.workbench.panel.script", "ShapeScript")).tag(2)
                        Text(FloeCADStrings.label("cad.workbench.panel.mesh", "Mesh")).tag(3)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: .infinity)
                    if canvasActions != nil {
                        canvasSection
                    }
                    switch mode {
                    case 0: CADAssemblyPanelView(document: document, viewModel: viewModel)
                    case 1: CADDrawingPanelView(document: document, viewModel: viewModel)
                    case 2: CADScriptPanelView(document: document)
                    default: CADMeshPanelView(document: document, viewModel: viewModel)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .navigationTitle(FloeCADStrings.text("cad.workbench.tools", "CAD Tools"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(FloeCADStrings.label("cad.ui.common.done", "Done")) { dismiss() }
                        .accessibilityIdentifier("CADToolsSheetCloseButton")
                }
            }
        }
        .accessibilityIdentifier("CADWorkbenchToolsPanel")
    }

    /// The Canvas entry path, visible in the same panel the other CAD tools
    /// live in: "Apply to canvas" updates the ORIGINAL bound node;
    /// "Make variant" creates a new node FROM a bound one; "Add to canvas"
    /// creates the FIRST node in an explicitly picked destination — no
    /// first-canvas guessing, no contradictory dead end.
    @ViewBuilder
    private var canvasSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelActionGrid {
                if let apply = canvasActions?.applyToCanvas {
                    panelHitTarget(Button {
                        run(apply)
                    } label: {
                        Label(FloeCADStrings.label("cad.canvas.apply", "Apply to canvas"),
                              systemImage: "rectangle.on.rectangle.angled")
                            .font(.callout)
                            .lineLimit(1)
                    }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isCanvasActionRunning))
                    .accessibilityIdentifier("CADApplyToCanvasButton")
                }
                if let variant = canvasActions?.makeVariant {
                    panelHitTarget(Button {
                        run(variant)
                    } label: {
                        Label(FloeCADStrings.label("cad.canvas.variant", "Make variant"),
                              systemImage: "plus.square.on.square")
                            .font(.callout)
                            .lineLimit(1)
                    }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isCanvasActionRunning))
                    .accessibilityIdentifier("CADMakeVariantButton")
                }
                if canvasActions?.createNode != nil {
                    panelHitTarget(Button {
                        presentCreatePicker()
                    } label: {
                        Label(FloeCADStrings.label("cad.canvas.add", "Add to canvas"),
                              systemImage: "plus.rectangle.on.rectangle")
                            .font(.callout)
                            .lineLimit(1)
                    }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isCanvasActionRunning))
                    .accessibilityIdentifier("CADAddToCanvasButton")
                }
                if isCanvasActionRunning {
                    ProgressView().controlSize(.small)
                }
            }
            if let canvasMessage {
                Text(canvasMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .sheet(isPresented: $showCreatePicker) {
            createTargetPicker
        }
    }

    @State private var showCreatePicker = false
    @State private var createChoices: [CADCanvasActions.TargetChoice] = []
    @State private var createRequest: ((FloeCADDocument, URL, CADCanvasActions.TargetChoice) async -> CADCanvasActionResult)?

    private func presentCreatePicker() {
        guard let targets = canvasActions?.createTargets,
              let createNode = canvasActions?.createNode else { return }
        let choices = targets()
        guard !choices.isEmpty else {
            canvasMessage = FloeCADStrings.text("cad.canvas.noTargets",
                                                "No canvas is available to add this document to.")
            return
        }
        createChoices = choices
        createRequest = createNode
        showCreatePicker = true
    }

    /// Explicit destination picker: one row per canvas document the host
    /// offers; tapping a row performs the create against exactly that target.
    private var createTargetPicker: some View {
        NavigationStack {
            List(createChoices) { choice in
                Button {
                    showCreatePicker = false
                    let request = createRequest
                    guard let request else { return }
                    isCanvasActionRunning = true
                    canvasMessage = nil
                    Task { @MainActor in
                        let result = await request(document, document.url, choice)
                        canvasMessage = result.message
                        isCanvasActionRunning = false
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(choice.title)
                        if let documentTitle = choice.documentTitle {
                            Text(documentTitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityIdentifier("CADCreateTarget-\(choice.id)")
            }
            .navigationTitle(FloeCADStrings.text("cad.canvas.pickDestination", "Pick a canvas"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    private func run(_ operation: @escaping CADCanvasActions.Operation) {
        guard !isCanvasActionRunning else { return }
        isCanvasActionRunning = true
        canvasMessage = nil
        Task { @MainActor in
            let result = await operation(document, document.url)
            canvasMessage = result.message
            isCanvasActionRunning = false
        }
    }
}

#endif
