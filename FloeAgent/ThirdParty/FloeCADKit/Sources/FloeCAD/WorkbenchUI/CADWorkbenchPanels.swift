//
//  CADWorkbenchPanels.swift
//  FloeCADKit
//
//  Floe-owned workbench chrome shared by the CAD panels (assembly, drawings,
//  ShapeScript, mesh) and the single toolbar-toggled tools sheet. The panels
//  themselves live in their own files; this file owns the localization hook,
//  the 44pt action grid, structured report primitives and the tools sheet.
//
//  iPad-first layout contract (CUA 2026-10-10): the tools sheet fills its
//  width, every action is a real 44pt hit target, and reports are NATIVE
//  structured lists with meaningful empty states — never raw JSON.
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

    /// Localized format substitution. Supports the host catalog's `%@`
    /// convention AND typed printf specifiers (`%d`, `%lld`, `%ld`, `%i`,
    /// `%u`, `%f`, `%.2f`) left to right. This exists because the same key is
    /// shared with native code that formats byte counts with `%lld`; a catalog
    /// value must never reach the user with a raw conversion token.
    nonisolated public static func format(_ key: String, _ fallback: String,
                                          _ arguments: Any...) -> String {
        formatTemplate(text(key, fallback), arguments: arguments)
    }

    /// Specifier-aware substitution, split out so it is unit-testable without
    /// a host localizer. Arguments are consumed left to right. A specifier with
    /// no argument left (or a malformed specifier) is emitted verbatim rather
    /// than trapping — a raw conversion token is still better than a crash.
    public static func formatTemplate(_ template: String, arguments: [Any]) -> String {
        var result = ""
        var args = arguments
        var index = template.startIndex
        while index < template.endIndex {
            guard template[index] == "%" else {
                result.append(template[index])
                index = template.index(after: index)
                continue
            }
            guard let specifier = Parse.scanSpecifier(template, from: index) else {
                result.append(template[index])
                index = template.index(after: index)
                continue
            }
            let token = String(template[index..<specifier.end])
            if specifier.conversion == "%" {
                result.append("%")
                index = specifier.end
                continue
            }
            index = specifier.end
            guard !args.isEmpty else {
                result += token
                continue
            }
            let argument = args.removeFirst()
            result += Parse.render(argument: argument, conversion: specifier.conversion,
                                   rawToken: token)
        }
        return result
    }

    private enum Parse {
        struct Scanned { let end: String.Index; let conversion: String }

        /// Parse one printf-style conversion starting at the `%`. Returns nil
        /// when this `%` does not begin a recognized specifier.
        static func scanSpecifier(_ template: String, from start: String.Index) -> Scanned? {
            var cursor = template.index(after: start)
            func take(_ set: Set<Character>) {
                while cursor < template.endIndex, set.contains(template[cursor]) {
                    cursor = template.index(after: cursor)
                }
            }
            // Flags
            take(["-", "+", " ", "#", "0"])
            // Width (digits or *)
            if cursor < template.endIndex, template[cursor] == "*" {
                cursor = template.index(after: cursor)
            } else {
                take(["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"])
            }
            // Precision
            if cursor < template.endIndex, template[cursor] == "." {
                cursor = template.index(after: cursor)
                if cursor < template.endIndex, template[cursor] == "*" {
                    cursor = template.index(after: cursor)
                } else {
                    take(["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"])
                }
            }
            // Length modifiers
            take(["h", "l", "j", "z", "t", "L"])
            guard cursor < template.endIndex else { return nil }
            let conversion = template[cursor]
            let allowed: Set<Character> = ["@", "d", "i", "o", "u", "x", "X",
                                           "e", "E", "f", "F", "g", "G", "a",
                                           "A", "c", "C", "s", "S", "%"]
            guard allowed.contains(conversion) else { return nil }
            let end = template.index(after: cursor)
            return Scanned(end: end, conversion: String(conversion))
        }

        static func render(argument: Any, conversion: String, rawToken: String) -> String {
            // Object/string conversion always uses the description.
            if conversion == "@" || conversion == "s" || conversion == "S" {
                if let s = argument as? String { return s }
                return String(describing: argument)
            }
            if conversion == "c" || conversion == "C" {
                if let scalar = (argument as? NSNumber)?.intValue,
                   let us = UnicodeScalar(scalar) {
                    return String(us)
                }
                return String(describing: argument)
            }
            // Numeric conversions. Swift Int/Double/etc. bridge to NSNumber.
            guard let number = argument as? NSNumber else {
                // A non-numeric argument for a numeric specifier degrades to a
                // description rather than trapping or dropping the value.
                return String(describing: argument)
            }
            switch conversion {
            case "d", "i":
                return "\(number.intValue)"
            case "u", "o", "x", "X":
                let value = number.uint64Value
                switch conversion {
                case "o": return String(value, radix: 8)
                case "x": return String(value, radix: 16)
                case "X": return String(value, radix: 16).uppercased()
                default: return "\(value)"
                }
            case "f", "F", "e", "E", "g", "G", "a", "A":
                // Honour an explicit precision (e.g. %.2f) so measurements keep
                // their formatting; otherwise a clean shortest value.
                if let precision = precision(of: rawToken) {
                    return String(format: "%.\(precision)\(conversion)",
                                  number.doubleValue)
                }
                return String(number.doubleValue)
            default:
                return String(describing: argument)
            }
        }

        private static func precision(of token: String) -> Int? {
            guard let dot = token.firstIndex(of: ".") else { return nil }
            var digits = ""
            var cursor = token.index(after: dot)
            let numerals: Set<Character> = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]
            while cursor < token.endIndex, numerals.contains(token[cursor]) {
                digits.append(token[cursor])
                cursor = token.index(after: cursor)
            }
            return Int(digits)
        }
    }

    /// SwiftUI label text.
    nonisolated public static func label(_ key: String, _ fallback: String) -> LocalizedStringKey {
        LocalizedStringKey(text(key, fallback))
    }
}

// MARK: - Shared chrome

/// The 44-point hit-target floor the rest of the app follows.
func panelHitTarget(_ button: some View) -> some View {
    button
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
}

/// A labelled 44pt action.
struct PanelActionButton: View {
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
struct PanelActionGrid<Content: View>: View {
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
struct PanelBadge: View {
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
/// font — raw JSON never reaches the user.
struct PanelOutcome: View {
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
struct PanelEmptyState: View {
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

/// Panel container: fills the tools-sheet width on iPad, scrolls its content,
/// keeps the test identifier.
struct WorkbenchPanelChrome<Content: View>: View {
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
struct PanelSection<Content: View>: View {
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

// MARK: - Tools sheet

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
        // NavigationStack gives the sheet an explicit Close control.
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
    /// creates the FIRST node in an explicitly picked destination.
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
