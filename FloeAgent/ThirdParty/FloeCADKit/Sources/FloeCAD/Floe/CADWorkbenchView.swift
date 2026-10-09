//
//  CADWorkbenchView.swift
//  FloeCADKit
//
//  Public workbench entry points embedded by the Floe app. The viewport is
//  dominant; chrome stays contextual and progressive, using the system type
//  and SF Symbols the rest of the app uses.
//

import SwiftUI

/// A complete FloeCAD document workbench: full-bleed Metal viewport, adaptive
/// tool palette, history/items panels, numeric entry and sketch overlays.
/// Floe embeds this for `.floecad` documents; the host owns navigation,
/// saving policy and the assistant entry points.
public struct FloeCADWorkbenchView: View {
    private let document: FloeCADDocument

    public init(document: FloeCADDocument) {
        self.document = document
    }

    public var body: some View {
        FloeCADEditorView(document: document)
    }
}

/// Compact settings sheet used by the workbench gear button. Covers exactly
/// the preferences the extracted editor reads (display unit, snapping,
/// constraint visibility and anchored entity) — no app-shell sections.
struct CADQuickSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var settings = CADPreferences.shared

    var body: some View {
        NavigationStack {
            Form {
                Section("Display") {
                    Picker("Units", selection: $settings.unit) {
                        ForEach(DisplayUnit.allCases, id: \.self) { unit in
                            Text(unit.rawValue).tag(unit)
                        }
                    }
                    Picker("Circular dimensions", selection: $settings.circularAnnotations) {
                        ForEach(CircularAnnotations.allCases, id: \.self) { style in
                            Text(style.title).tag(style)
                        }
                    }
                }
                Section("Sketch annotations") {
                    Toggle("Always show dimensions", isOn: $settings.alwaysShowDimensions)
                    Toggle("Always show constraints", isOn: $settings.alwaysShowConstraints)
                    Picker("Anchored entity", selection: $settings.anchoredSketchEntity) {
                        ForEach(AnchoredSketchEntity.allCases, id: \.self) { entity in
                            Text(entity.title).tag(entity)
                        }
                    }
                }
                SnappingSettingsSection(settings: settings)
            }
            .navigationTitle("CAD Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
