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
    private let canvasActions: CADCanvasActions?

    public init(document: FloeCADDocument, canvasActions: CADCanvasActions? = nil) {
        self.document = document
        self.canvasActions = canvasActions
    }

    public var body: some View {
        FloeCADEditorView(document: document, canvasActions: canvasActions)
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
                Section(FloeCADStrings.label("cad.settings.display", "Display")) {
                    Picker(FloeCADStrings.label("cad.settings.units", "Units"),
                           selection: $settings.unit) {
                        ForEach(DisplayUnit.allCases, id: \.self) { unit in
                            Text(unit.rawValue).tag(unit)
                        }
                    }
                    Picker(FloeCADStrings.label("cad.settings.circularDimensions", "Circular dimensions"),
                           selection: $settings.circularAnnotations) {
                        ForEach(CircularAnnotations.allCases, id: \.self) { style in
                            Text(style.title).tag(style)
                        }
                    }
                }
                Section(FloeCADStrings.label("cad.settings.sketchAnnotations", "Sketch annotations")) {
                    Toggle(FloeCADStrings.label("cad.settings.alwaysDimensions", "Always show dimensions"),
                           isOn: $settings.alwaysShowDimensions)
                    Toggle(FloeCADStrings.label("cad.settings.alwaysConstraints", "Always show constraints"),
                           isOn: $settings.alwaysShowConstraints)
                    Picker(FloeCADStrings.label("cad.settings.anchoredEntity", "Anchored entity"),
                           selection: $settings.anchoredSketchEntity) {
                        ForEach(AnchoredSketchEntity.allCases, id: \.self) { entity in
                            Text(entity.title).tag(entity)
                        }
                    }
                }
                SnappingSettingsSection(settings: settings)
            }
            .navigationTitle(FloeCADStrings.label("cad.settings.title", "CAD Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(FloeCADStrings.label("cad.settings.done", "Done")) { dismiss() }
                }
            }
        }
    }
}
