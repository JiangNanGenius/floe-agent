//
//  CADWorkbenchPanels.swift
//  FloeCADKit
//
//  Floe-owned workbench chrome for the native side of the CAD editor: assembly
//  instances/constraints/interference, drawing pages/views/dimensions/exports,
//  ShapeScript records and mesh operations. These views are the interactive
//  confirmation surface for the same services the `cad.document` tool drives;
//  mutating assistant proposals still require the grant banner.
//
//  Every user-visible string goes through `FloeCADStrings` so the host app can
//  route it to its localization catalog; without a host localizer the English
//  fallback is shown (never a bare key).
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

private struct WorkbenchPanelChrome<Content: View>: View {
    let title: String
    let identifier: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                content
            }
            .padding(12)
        }
        .frame(width: 330)
        .frame(maxHeight: 540)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .accessibilityIdentifier(identifier)
    }
}

private func cadPanelSummary(_ reply: [String: Any]) -> String {
    if let message = reply["message"] as? String, !message.isEmpty { return message }
    if let data = try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys]),
       let text = String(data: data, encoding: .utf8) {
        return String(text.prefix(4000))
    }
    return "ok"
}

// MARK: - Assembly

struct CADAssemblyPanelView: View {
    let document: FloeCADDocument
    @Bindable var viewModel: EditorViewModel
    @State private var summary = ""
    @State private var busy = false

    private var selectedBodyID: UUID? {
        viewModel.selection.first?.raw
    }

    var body: some View {
        WorkbenchPanelChrome(title: FloeCADStrings.text("cad.workbench.panel.assembly", "Assembly"),
                             identifier: "CADAssemblyPanel") {
            HStack {
                Button {
                    run { service in
                        guard let bodyID = selectedBodyID ?? document.session.document.bodies.first?.id.raw else {
                            return ["ok": false,
                                    "message": FloeCADStrings.text("cad.ui.workbench.selectBody",
                                                                   "Select a body first.")]
                        }
                        return await service.handleAsync(action: "addInstance",
                                                         args: ["bodyID": bodyID.uuidString])
                    }
                } label: {
                    Label(FloeCADStrings.label("cad.workbench.assembly.place", "Place instance"),
                          systemImage: "cube.transparent")
                }
                .disabled(busy)
                Spacer()
                Button {
                    run { await $0.handleAsync(action: "solve", args: [:]) }
                } label: {
                    Label(FloeCADStrings.label("cad.workbench.assembly.solve", "Solve"), systemImage: "arrow.triangle.branch")
                }
                .disabled(busy)
            }
            HStack {
                Button {
                    run { await $0.handleAsync(action: "dof", args: [:]) }
                } label: {
                    Label(FloeCADStrings.label("cad.workbench.assembly.dof", "DOF"), systemImage: "degreesign.celsius")
                }
                .disabled(busy)
                Button {
                    run { await $0.handleAsync(action: "interference", args: ["toleranceMM": 1e-6]) }
                } label: {
                    Label(FloeCADStrings.label("cad.workbench.assembly.interference", "Interference"),
                          systemImage: "square.on.square.dashed")
                }
                .disabled(busy)
                Button {
                    run { await $0.handleAsync(action: "sourceUpdate", args: [:]) }
                } label: {
                    Label(FloeCADStrings.label("cad.workbench.assembly.source", "Sources"), systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(busy)
            }
            Button {
                run { await $0.handleAsync(action: "report", args: [:]) }
            } label: {
                Label(FloeCADStrings.label("cad.workbench.assembly.report", "Refresh report"),
                      systemImage: "list.bullet.rectangle")
            }
            .disabled(busy)
            if busy {
                ProgressView().controlSize(.small)
            }
            if !summary.isEmpty {
                Text(summary)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
        .task { run { await $0.handleAsync(action: "report", args: [:]) } }
    }

    private func run(_ operation: @escaping @MainActor (CADAssemblyService) async -> [String: Any]) {
        busy = true
        Task { @MainActor in
            let service = CADAssemblyService(document: document)
            let reply = await operation(service)
            if reply["mutated"] as? Bool == true {
                _ = await document.save()
            }
            summary = cadPanelSummary(reply)
            busy = false
        }
    }
}

// MARK: - Drawings

struct CADDrawingPanelView: View {
    let document: FloeCADDocument
    @Bindable var viewModel: EditorViewModel
    @State private var pages: [[String: Any]] = []
    @State private var summary = ""
    @State private var exportURL: URL?
    @State private var busy = false

    private var selectedBodyID: UUID? {
        viewModel.selection.first?.raw ?? document.session.document.bodies.first?.id.raw
    }

    var body: some View {
        WorkbenchPanelChrome(title: FloeCADStrings.text("cad.workbench.panel.drawing", "Drawings"),
                             identifier: "CADDrawingPanel") {
            HStack {
                Button {
                    open { service in
                        guard let bodyID = selectedBodyID else {
                            return ["ok": false,
                                    "message": FloeCADStrings.text("cad.ui.workbench.selectBody",
                                                                   "Select a body first.")]
                        }
                        return service.handle(action: "standardSheet",
                                              args: ["bodyID": bodyID.uuidString, "title": document.name])
                    }
                } label: {
                    Label(FloeCADStrings.label("cad.workbench.drawing.sheet", "Standard sheet"),
                          systemImage: "doc.on.doc")
                }
                .disabled(busy)
                Button {
                    refresh()
                } label: {
                    Label(FloeCADStrings.label("cad.workbench.drawing.refresh", "Refresh"), systemImage: "arrow.clockwise")
                }
                .disabled(busy)
            }
            ForEach(pages.indices, id: \.self) { index in
                let page = pages[index]
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("\(page["name"] as? String ?? "?") · \(page["kind"] as? String ?? "?")")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        if page["stale"] as? Bool == true {
                            Text(FloeCADStrings.label("cad.workbench.drawing.stale", "stale"))
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .background(.orange.opacity(0.25), in: Capsule())
                        }
                    }
                    HStack(spacing: 8) {
                        Button(FloeCADStrings.label("cad.workbench.drawing.project", "View")) {
                            project(page)
                        }
                        Button(FloeCADStrings.label("cad.workbench.drawing.pdf", "PDF")) {
                            export(page, format: "pdf")
                        }
                        Button("SVG") { export(page, format: "svg") }
                        Button("DXF") { export(page, format: "dxf") }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                .padding(.vertical, 2)
            }
            if let exportURL {
                ShareLink(item: exportURL) {
                    Label(FloeCADStrings.label("cad.workbench.drawing.share", "Share export"),
                          systemImage: "square.and.arrow.up")
                }
            }
            if busy { ProgressView().controlSize(.small) }
            if !summary.isEmpty {
                Text(summary)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
        .task { refresh() }
    }

    private func refresh() {
        let service = CADDrawingService(document: document)
        let reply = service.handle(action: "pages", args: [:])
        pages = reply["pages"] as? [[String: Any]] ?? []
        summary = cadPanelSummary(reply)
    }

    private func project(_ page: [String: Any]) {
        guard let id = page["id"] as? String, let uuid = UUID(uuidString: id) else { return }
        let service = CADDrawingService(document: document)
        summary = cadPanelSummary(service.pageGeometry(pageID: uuid))
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
                summary = "\(format.uppercased()): \(data.count) bytes"
            } catch {
                summary = error.localizedDescription
            }
            busy = false
        }
    }

    private func open(_ operation: @escaping @MainActor (CADDrawingService) -> [String: Any]) {
        busy = true
        Task { @MainActor in
            let service = CADDrawingService(document: document)
            let reply = operation(service)
            if reply["mutated"] as? Bool == true {
                _ = await document.save()
            }
            summary = cadPanelSummary(reply)
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
    @State private var summary = ""
    @State private var busy = false

    var body: some View {
        WorkbenchPanelChrome(title: FloeCADStrings.text("cad.workbench.panel.script", "ShapeScript"),
                             identifier: "CADScriptPanel") {
            TextEditor(text: $source)
                .font(.system(.footnote, design: .monospaced))
                .frame(minHeight: 90, maxHeight: 150)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                .accessibilityIdentifier("CADScriptSource")
            HStack {
                Button {
                    run { await $0.handle(action: "preview", args: ["source": self.source]) }
                } label: {
                    Label(FloeCADStrings.label("cad.workbench.script.preview", "Preview"), systemImage: "eye")
                }
                .disabled(busy)
                Button {
                    run { await $0.handle(action: "apply", args: ["source": self.source, "name": "Script"]) }
                } label: {
                    Label(FloeCADStrings.label("cad.workbench.script.apply", "Apply"), systemImage: "checkmark.circle")
                }
                .disabled(busy)
                Button {
                    run { await $0.handle(action: "list", args: [:]) }
                } label: {
                    Label(FloeCADStrings.label("cad.workbench.script.list", "Records"), systemImage: "list.bullet")
                }
                .disabled(busy)
            }
            ForEach(scripts.indices, id: \.self) { index in
                let script = scripts[index]
                Button {
                    if let id = script["id"] as? String {
                        run { await $0.handle(action: "apply", args: ["id": id]) }
                    }
                } label: {
                    HStack {
                        Text(script["name"] as? String
                             ?? FloeCADStrings.text("cad.ui.script.untitled", "Script"))
                        Spacer()
                        if script["stale"] as? Bool == true {
                            Image(systemName: "exclamationmark.triangle")
                        }
                    }
                    .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            if busy { ProgressView().controlSize(.small) }
            if !summary.isEmpty {
                Text(summary)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
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
            summary = cadPanelSummary(reply)
            busy = false
        }
    }
}

// MARK: - Mesh

struct CADMeshPanelView: View {
    let document: FloeCADDocument
    @Bindable var viewModel: EditorViewModel
    @State private var summary = ""
    @State private var busy = false

    private var selectedBodyIDs: [UUID] {
        viewModel.selection.map(\.raw)
    }

    var body: some View {
        WorkbenchPanelChrome(title: FloeCADStrings.text("cad.workbench.panel.mesh", "Mesh"),
                             identifier: "CADMeshPanel") {
            Text(FloeCADStrings.label("cad.workbench.mesh.hint",
                                     "Select two or more bodies, then choose an operation."))
                .font(.caption)
            HStack {
                Button {
                    boolean("union")
                } label: { Text(FloeCADStrings.label("cad.workbench.mesh.union", "Union")) }
                    .disabled(busy)
                Button {
                    boolean("subtract")
                } label: { Text(FloeCADStrings.label("cad.workbench.mesh.subtract", "Subtract")) }
                    .disabled(busy)
                Button {
                    boolean("intersect")
                } label: { Text(FloeCADStrings.label("cad.workbench.mesh.intersect", "Intersect")) }
                    .disabled(busy)
            }
            HStack {
                Button {
                    combine()
                } label: { Text(FloeCADStrings.label("cad.workbench.mesh.combine", "Combine")) }
                    .disabled(busy)
                Button {
                    single("repair", extra: ["tolerance": 1e-4])
                } label: { Text(FloeCADStrings.label("cad.workbench.mesh.repair", "Repair")) }
                    .disabled(busy)
                Button {
                    single("simplify", extra: ["ratio": 0.5])
                } label: { Text(FloeCADStrings.label("cad.workbench.mesh.simplify", "Simplify")) }
                    .disabled(busy)
                Button {
                    single("recomputeNormals", extra: [:])
                } label: { Text(FloeCADStrings.label("cad.workbench.mesh.normals", "Normals")) }
                    .disabled(busy)
            }
            if busy { ProgressView().controlSize(.small) }
            if !summary.isEmpty {
                Text(summary)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
    }

    private func boolean(_ op: String) {
        guard selectedBodyIDs.count >= 2 else {
            summary = FloeCADStrings.text("cad.workbench.mesh.selectTwo", "Select at least two bodies.")
            return
        }
        let target = selectedBodyIDs[0].uuidString
        let tools = selectedBodyIDs.dropFirst().map(\.uuidString)
        perform(["action": "boolean", "op": op, "target": target, "tools": tools])
    }

    private func combine() {
        guard selectedBodyIDs.count >= 2 else {
            summary = FloeCADStrings.text("cad.workbench.mesh.selectTwo", "Select at least two bodies.")
            return
        }
        perform(["action": "combine", "bodyIDs": selectedBodyIDs.map(\.uuidString)])
    }

    private func single(_ action: String, extra: [String: Any]) {
        guard let bodyID = selectedBodyIDs.first else {
            summary = FloeCADStrings.text("cad.workbench.mesh.selectOne", "Select a body first.")
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
            summary = cadPanelSummary(reply)
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
    @State private var mode = 0
    @State private var isCanvasActionRunning = false
    @State private var canvasMessage: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Picker("", selection: $mode) {
                Text(FloeCADStrings.label("cad.workbench.panel.assembly", "Assembly")).tag(0)
                Text(FloeCADStrings.label("cad.workbench.panel.drawing", "Drawings")).tag(1)
                Text(FloeCADStrings.label("cad.workbench.panel.script", "ShapeScript")).tag(2)
                Text(FloeCADStrings.label("cad.workbench.panel.mesh", "Mesh")).tag(3)
            }
            .pickerStyle(.segmented)
            .frame(width: 330)
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
        .accessibilityIdentifier("CADWorkbenchToolsPanel")
    }

    /// The Canvas entry path, visible in the same panel the other CAD tools
    /// live in: "Apply to canvas" updates the ORIGINAL bound node;
    /// "Make variant" creates a new node FROM a bound one; "Add to canvas"
    /// creates the FIRST node in an explicitly picked destination — no
    /// first-canvas guessing, no contradictory dead end.
    @ViewBuilder
    private var canvasSection: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 8) {
                if let apply = canvasActions?.applyToCanvas {
                    Button {
                        run(apply)
                    } label: {
                        Label(FloeCADStrings.label("cad.canvas.apply", "Apply to canvas"),
                              systemImage: "rectangle.on.rectangle.angled")
                            .font(.caption)
                    }
                    .disabled(isCanvasActionRunning)
                    .accessibilityIdentifier("CADApplyToCanvasButton")
                }
                if let variant = canvasActions?.makeVariant {
                    Button {
                        run(variant)
                    } label: {
                        Label(FloeCADStrings.label("cad.canvas.variant", "Make variant"),
                              systemImage: "plus.square.on.square")
                            .font(.caption)
                    }
                    .disabled(isCanvasActionRunning)
                    .accessibilityIdentifier("CADMakeVariantButton")
                }
                if canvasActions?.createNode != nil {
                    Button {
                        presentCreatePicker()
                    } label: {
                        Label(FloeCADStrings.label("cad.canvas.add", "Add to canvas"),
                              systemImage: "plus.rectangle.on.rectangle")
                            .font(.caption)
                    }
                    .disabled(isCanvasActionRunning)
                    .accessibilityIdentifier("CADAddToCanvasButton")
                }
                if isCanvasActionRunning {
                    ProgressView().controlSize(.small)
                }
            }
            if let canvasMessage {
                Text(canvasMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 330, alignment: .trailing)
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
