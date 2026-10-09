//
//  EditorView.swift
//  openshape3d
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import CoreTransferable
import PhotosUI

/// Minimal FileDocument wrapper so `.fileExporter` can save any export
/// payload (STL/OBJ/3MF/GLB/DXF/USDZ/PNG); the concrete type travels with
/// the data.
struct ExportDocument: FileDocument {
    static let stlType = UTType(filenameExtension: "stl") ?? .data
    static let objType = UTType("public.geometry-definition-format")
        ?? UTType(filenameExtension: "obj") ?? .data
    static let threeMFType = UTType("org.3mf.model")
        ?? UTType(filenameExtension: "3mf") ?? .data
    static let glbType = UTType(filenameExtension: "glb") ?? .data
    static let dxfType = UTType(filenameExtension: "dxf") ?? .data
    /// STEP AP214. iOS declares no UTI for STEP, so this resolves to a
    /// DYNAMIC type (`dyn.…`) unless something on the device has declared
    /// one. Good enough to STAMP an exported file, but a document picker
    /// filtered to a dynamic type matches nothing — see
    /// `ImportRequest.contentTypes`, which pairs it with `.data`.
    /// Declaring the type properly needs an `UTImportedTypeDeclarations`
    /// block, which needs the app off `GENERATE_INFOPLIST_FILE` (that setting
    /// makes Xcode ignore `INFOPLIST_FILE` outright) — its own change.
    static let stepType = UTType("org.iso.step")
        ?? UTType(filenameExtension: "step") ?? .data
    static let usdzType = UTType.usdz
    /// The .os3d project archive (Phase F, spec §13).
    static let os3dType = UTType(filenameExtension: "os3d") ?? .data
    static var readableContentTypes: [UTType] {
        [stlType, objType, threeMFType, glbType, dxfType, stepType,
         usdzType, os3dType, .png, .data]
    }

    var data: Data
    var contentType: UTType
    /// File extension for the default filename ("stl", "obj", …).
    var fileExtension: String

    init(data: Data, contentType: UTType, fileExtension: String) {
        self.data = data
        self.contentType = contentType
        self.fileExtension = fileExtension
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        contentType = .data
        fileExtension = "dat"
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Transferable wrapper so `.fileExporter(items:)` writes each per-body
/// temp file under its own name (plan §B14 "Separate File per Body").
struct ExportFileItem: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .item) { item in
            SentTransferredFile(item.url)
        }
    }
}

/// Export options for the mesh formats where a per-body split is supported
/// (plan §B14): OBJ and GLB can emit one file per body.
struct MeshExportOptionsSheet: View {
    /// User-facing format name ("OBJ" / "GLB") for the title.
    let formatName: String
    /// Called with the per-body choice when Export is confirmed.
    let onExport: (Bool) -> Void

    @State private var perBodyFiles = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Toggle(FloeCADStrings.label("cad.ui.export.separateFiles", "Separate File per Body"),
                       isOn: $perBodyFiles)
                    .accessibilityIdentifier("ExportPerBodyToggle")
            }
            .navigationTitle(String(
                format: FloeCADStrings.text("cad.ui.export.meshTitle", "%@ Export"),
                formatName
            ))
            .onDisappear { MacWindowTitle.restore() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(FloeCADStrings.label("cad.ui.common.cancel", "Cancel")) { dismiss() }
                        .accessibilityIdentifier("MeshExportCancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(FloeCADStrings.label("cad.ui.common.export", "Export")) {
                        onExport(perBodyFiles)
                        dismiss()
                    }
                    .accessibilityIdentifier("MeshExportConfirm")
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// Screenshot options sheet (spec §12.2): resolution, transparency, grid.
struct ScreenshotOptionsSheet: View {
    /// Multiplier of the 1024×768 base size (1x / 2x / 4x).
    @State private var resolutionScale = 1
    @State private var transparentBackground = false
    @State private var showGrid = true

    @Environment(\.dismiss) private var dismiss
    let onExport: (Int, Int, Bool, Bool) -> Void

    private static let baseSize = (width: 1024, height: 768)

    var body: some View {
        NavigationStack {
            Form {
                Picker("Resolution", selection: $resolutionScale) {
                    ForEach([1, 2, 4], id: \.self) { scale in
                        Text("\(Self.baseSize.width * scale) × \(Self.baseSize.height * scale)")
                            .tag(scale)
                    }
                }
                .accessibilityIdentifier("ScreenshotResolution")
                Toggle("Transparent Background", isOn: $transparentBackground)
                    .accessibilityIdentifier("ScreenshotTransparent")
                Toggle("Show Grid", isOn: $showGrid)
                    .accessibilityIdentifier("ScreenshotGrid")
            }
            .navigationTitle("Screenshot")
            .onDisappear { MacWindowTitle.restore() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("ScreenshotCancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Export") {
                        onExport(
                            Self.baseSize.width * resolutionScale,
                            Self.baseSize.height * resolutionScale,
                            transparentBackground,
                            showGrid
                        )
                        dismiss()
                    }
                    .accessibilityIdentifier("ScreenshotExport")
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// User-facing labels for the Display menu (spec §16.4: "active shader
/// labeled") — UI naming stays out of the render contract.
extension DisplayMode {
    var displayLabel: String {
        switch self {
        case .shaded: return "Shaded"
        case .shadedNoEdges: return "Shaded (No Edges)"
        case .wireframe: return "Wireframe"
        case .xray: return "X-Ray"
        }
    }
}

/// Modeling editor: full-bleed Metal viewport with floating tool chrome.
///
/// FloeCAD: adapted from OpenShape3D's `EditorView` (MIT). The SwiftData
/// project/modelContext pair is replaced by the public `FloeCADDocument`
/// facade, and the app-shell sheets (gallery settings / bug report / AR
/// preview) are replaced or removed. The visual language is the existing
/// viewport-dominant editor: full-bleed Metal viewport, contextual bars,
/// native SF Symbols and system type.
struct FloeCADEditorView: View {
    let document: FloeCADDocument
    /// Host-injected Canvas actions; nil in standalone/qualification hosts.
    var canvasActions: CADCanvasActions? = nil

    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel: EditorViewModel?
    @State private var exportDocument: ExportDocument?
    @State private var showItemsPanel = false
    /// Canvas result banner (`CADCanvasActionResult`); shown in a safe-area
    /// inset so the toolbar entry always has visible feedback.
    @State private var canvasActionMessage: (kind: CADCanvasActionResult.Kind, text: String)?
    @State private var isCanvasActionRunning = false
    /// Floe workbench tools (assembly / drawings / ShapeScript / mesh) sheet.
    @State private var showWorkbenchTools = false
        @State private var pendingMeshImport: MeshImportProbe?
    @State private var didHandleDebugImport = false
    @State private var showSettings = false
    /// Measured height of the bottom bar stack, fed by `BottomBarHeightKey`.
    /// The palette and the corner chips inset above it — see `bottomBarInset`.
    @State private var bottomBarHeight: CGFloat = 0
    /// The tool palette's frame (global coordinates), measured for the
    /// viewport's phone safe area — see `ViewportSafeArea`.
    @State private var paletteFrame: CGRect?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// App-wide preferences; reads in body are Observation-tracked so unit /
    /// palette-side changes re-render live.
    private var settings: CADPreferences { CADPreferences.shared }

    /// How far the tool palette and the bottom corner chips must sit above the
    /// bottom edge to clear the bars. 96pt is the historical iPad value and
    /// stays the floor so nothing moves on iPad; a taller compact bar pushes
    /// them further up instead of being overlapped by them.
    private var bottomBarInset: CGFloat { max(96, bottomBarHeight + 16) }
    /// Which file the Import menu asked for. There is exactly ONE
    /// `.fileImporter` in this view because stacking several on one view
    /// silently leaves only the LAST one live — the STL and DXF entries did
    /// nothing at all for as long as they had importers ahead of the image
    /// one in the chain (found 2026-08-29 while wiring STEP: "Image from
    /// Files…" presented, the three above it did not).
    private enum ImportRequest: Equatable {
        case stl, dxf, step, mesh, image

        var contentTypes: [UTType] {
            switch self {
            case .stl: [ExportDocument.stlType]
            // STEP and DXF have no system-declared UTI, so these resolve to
            // DYNAMIC types (`dyn.…`) that match no file in the picker.
            // `.data` is what makes the files selectable — the same escape
            // hatch the `.os3d` archive importer already uses.
            case .dxf: [ExportDocument.dxfType, .data]
            case .step: [ExportDocument.stepType, .data]
            // glTF/GLB, USDZ, OBJ (+MTL/textures) and zips of them. `.data`
            // again: .glb/.gltf/.obj have no system UTI worth trusting.
            case .mesh: [ExportDocument.usdzType, .zip, .data]
            case .image: [.png, .jpeg, .image]
            }
        }
    }
    @State private var importRequest: ImportRequest = .stl
    @State private var showImporter = false
    @State private var showScreenshotOptions = false
    /// Insert Image (plan §B10): Photos picker + image file importer.
    @State private var showPhotoPicker = false
    @State private var photoPickerItem: PhotosPickerItem?
    /// Screenshot captured by the options sheet; promoted to `exportDocument`
    /// once the sheet has dismissed (two presentations can't overlap).
    @State private var pendingScreenshot: Data?

    /// Mesh export options (plan §B14): which format's sheet is up.
    private enum MeshExportFormat: String, Identifiable {
        case obj = "OBJ"
        case glb = "GLB"
        var id: String { rawValue }
    }
    @State private var meshExportFormat: MeshExportFormat?
    /// Payloads produced inside the mesh options sheet; promoted once the
    /// sheet has dismissed (two presentations can't overlap), single-file
    /// into `exportDocument`, per-body into `exportItems`.
    @State private var pendingExport: ExportDocument?
    @State private var pendingExportItems: [ExportFileItem]?
    /// Per-body temp files currently offered by `.fileExporter(items:)`.
    @State private var exportItems: [ExportFileItem]?

    /// Draft name for the Make Symbol prompt (plan §B16).
    @State private var symbolNameDraft = ""
    /// Temp USDZ shown by the AR preview sheet (plan §B14).
    
    var body: some View {
        Group {
            if let viewModel {
                editorContent(viewModel)
            } else {
                Color(.systemGroupedBackground).ignoresSafeArea()
            }
        }
        .task {
            #if DEBUG
            OpenTiming.mark("editor task start")
            #endif
            if viewModel == nil {
                viewModel = document.viewModel()
                viewModel?.debugSeedIfRequested()
                #if DEBUG
                OpenTiming.mark("view model built")
                #endif
            }
            // Hand the live editor to the agent bridge. Costs nothing unless
            // the control channel is on — until something asks, this is one
            // weak reference. Deliberately outside the `viewModel == nil` guard
            // so returning to an already-built document re-attaches too.
        }
        .navigationTitle(document.name)
        .onAppear { MacWindowTitle.want(document.name) }
        .onChange(of: document.name) { _, name in MacWindowTitle.want(name) }
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            viewModel?.saveThumbnail()
            Task { _ = await document.save() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || phase == .inactive {
                viewModel?.saveThumbnail()
                Task { _ = await document.save() }
            }
        }
    }

    /// Sketch-state chip inside the sketch pill (plan §C4). Under-defined
    /// geometry is conveyed by the on-canvas point/edge colours (blue = free),
    /// not a toolbar badge that reads like an error while you're mid-sketch —
    /// so this only surfaces the positive GREEN "Fully defined" confirmation.
    @ViewBuilder
    private func sketchStateChip(_ viewModel: EditorViewModel) -> some View {
        if viewModel.sketchSolveConflict {
            // A conflicting system is the one sketch state that IS an error:
            // drags spring back rather than writing the solver's compromise
            // into the document, and without this chip that reads as a
            // stuck gesture.
            Text("Constraints conflict")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.red, in: Capsule())
                .accessibilityIdentifier("SketchConflictChip")
        } else if let status = viewModel.sketchDefinitionStatus, status.fullyDefined {
            Text("Fully defined")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.green, in: Capsule())
                .accessibilityIdentifier("SketchStateChip")
        }
    }

    private func sketchStatusText(_ viewModel: EditorViewModel) -> String {
        if viewModel.isPickingSymmetryAxis { return "Select a line for the axis of symmetry" }
        guard let sketch = viewModel.activeSketch else { return "Sketching" }
        if case .sketching(_, let tool) = viewModel.mode {
            switch tool {
            case .text: return "Tap to place text"
            case .project: return "Tap a body to project its edges"
            case nil:
                if viewModel.sketchTransformActive {
                    return viewModel.selectedSketchEntityIDs.isEmpty
                        ? "Select sketch geometry to move or rotate" : "Drag an arrow or tap for an exact value"
                }
                return "Drag to orbit — pick a tool to draw"
            default: break
            }
        }
        return sketch.plane.isCoincident(with: .ground)
            ? "Sketching on ground plane"
            : "Sketching on plane"
    }

    private func statusPill(
        icon: String, text: String, @ViewBuilder trailing: () -> some View
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
            Text(text)
                .font(.subheadline)
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .padding(.top, 8)
    }

    /// Measure tool pill: prompts for picks, then shows distance + deltas.
    private func measurePill(_ viewModel: EditorViewModel) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "ruler")
            if let result = viewModel.measureResult {
                Text(EditorViewModel.formattedLength(result.distance))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .accessibilityIdentifier("MeasureDistanceValue")
                Text(String(
                    format: "ΔX %.2f  ΔY %.2f  ΔZ %.2f",
                    settings.unit.display(fromMM: result.deltas.x),
                    settings.unit.display(fromMM: result.deltas.y),
                    settings.unit.display(fromMM: result.deltas.z)
                ))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            } else {
                Text(viewModel.measurePoints.isEmpty
                    ? "Tap two points to measure"
                    : "Tap the second point")
                    .font(.subheadline)
            }
            Button("Done") {
                viewModel.exitMeasure()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .padding(.top, 8)
    }

    /// Chamfer/Fillet bar (Phase E, spec §4.3): shows the pick prompt, the
    /// size field (setback/radius), and Apply/Cancel.
    private func blendBar(_ kind: BlendKind, _ viewModel: EditorViewModel) -> some View {
        let value = Binding(
            get: { viewModel.blendValue },
            set: { viewModel.blendValue = max(0, $0) })
        return AdaptiveBar(style: .capsule, spacing: 12) {
            Image(systemName: kind == .chamfer ? "square.on.circle" : "circle.circle")
            // When the kernel refused the current size/pick, say WHY — the
            // typed diagnostic replaces the count until the preview is valid
            // again. Concrete color, not hierarchical .secondary (gotcha 10).
            if let failure = viewModel.blendPreviewFailure,
               !viewModel.blendSelectedEdges.isEmpty {
                Text(failure)
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .accessibilityIdentifier("BlendFailureHint")
            } else {
                Text(viewModel.blendSelectedEdges.isEmpty
                     ? "Tap edges to \(kind.title.lowercased())"
                     : "\(viewModel.blendSelectedEdges.count) edge\(viewModel.blendSelectedEdges.count == 1 ? "" : "s") selected")
                    .font(.subheadline)
                    .fixedSize()
            }
            Divider().frame(height: 20)
            Text(kind.valueLabel).font(.caption).foregroundStyle(.barLabel).fixedSize()
            // Text, applied live, arithmetic allowed — see ExpressionValueField.
            ExpressionValueField(placeholder: settings.unit.symbol, value: value,
                                 clamp: nil, identifier: "BlendValueField")
            Text(settings.unit.symbol).font(.caption).foregroundStyle(.barLabel).fixedSize()
            // While dragging, show the kernel-derived ceiling the drag is
            // clamped to, so the stop doesn't read as a stuck gesture.
            if let cap = viewModel.blendDragMax {
                Text("max \(settings.unit.display(fromMM: cap), format: .number.precision(.fractionLength(0...1)))")
                    .font(.caption)
                    .foregroundStyle(.barLabel)
                    .fixedSize()
                    .accessibilityIdentifier("BlendMaxHint")
            }
        } actions: {
            Button("Cancel") { viewModel.cancelBlend() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("BlendCancel")
            Button("Apply") { viewModel.commitBlend() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!viewModel.canCommitBlend)
                .accessibilityIdentifier("BlendApply")
        }
    }

    /// Shell bar (Phase E, spec §4.4): pick prompt, wall-thickness field,
    /// Apply/Cancel. Zero picked faces is valid (enclosed hollow).
    /// Replace Face bar (spec §4.12): a two-stage pick, so the bar's job is to
    /// say which stage you are in and — when the kit refuses — why.
    private func replaceFaceBar(_ viewModel: EditorViewModel) -> some View {
        AdaptiveBar(style: .capsule, spacing: 12) {
            Image(systemName: "arrow.up.and.down.square")
            Text(replaceFaceHint(viewModel))
                .font(.subheadline)
                .fixedSize()
            if viewModel.replaceSourceFace != nil {
                Divider().frame(height: 20)
                Toggle("Flip", isOn: Binding(
                    get: { viewModel.replaceFaceFlip },
                    set: { viewModel.replaceFaceFlip = $0 }))
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .accessibilityIdentifier("ReplaceFaceFlip")
            }
        } actions: {
            Button("Cancel") { viewModel.cancelReplaceFace() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("ReplaceFaceCancel")
            Button("Apply") { viewModel.commitReplaceFace() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!viewModel.canCommitReplaceFace)
                .accessibilityIdentifier("ReplaceFaceApply")
        }
    }

    /// Stage prompt, or the kit's refusal. A refusal is the interesting case:
    /// "not parallel" is a real geometric answer, not a glitch, and saying it
    /// beats a disabled Apply with no explanation.
    private func replaceFaceHint(_ viewModel: EditorViewModel) -> String {
        if let refusal = viewModel.replaceFaceRefusal {
            return refusal.prefix(1).uppercased() + refusal.dropFirst()
        }
        if viewModel.replaceSourceFace == nil { return "Tap the face to replace" }
        if viewModel.replaceTargetPlane == nil { return "Now tap the face to move it to" }
        return "Ready — Apply to replace"
    }

    /// Delete Face bar (spec §4.16). No parameter to set — the whole control
    /// is "which faces", so the bar reports the pick and why Apply is off.
    private func deleteFaceBar(_ viewModel: EditorViewModel) -> some View {
        AdaptiveBar(style: .capsule, spacing: 12) {
            Image(systemName: "square.slash")
            Text(deleteFaceHint(viewModel))
                .font(.subheadline)
                .fixedSize()
        } actions: {
            Button("Cancel") { viewModel.cancelDeleteFace() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("DeleteFaceCancel")
            Button("Apply") { viewModel.commitDeleteFace() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!viewModel.canCommitDeleteFace)
                .accessibilityIdentifier("DeleteFaceApply")
        }
    }

    /// The bar's text. A picked face with NO preview means OCCT could not
    /// close the gap — say that, rather than leaving a disabled Apply with no
    /// explanation (§4.16: some deletions legitimately leave a sheet body).
    private func deleteFaceHint(_ viewModel: EditorViewModel) -> String {
        if viewModel.deleteFaceBodyID == nil { return "Tap a body to edit" }
        let count = viewModel.deleteFaceTargets.count
        if count == 0 { return "Tap the faces to delete" }
        if viewModel.deleteFacePreview == nil {
            return "The surrounding faces can't heal that"
        }
        return "\(count) face\(count == 1 ? "" : "s") to delete"
    }

    private func shellBar(_ viewModel: EditorViewModel) -> some View {
        let value = Binding(
            get: { viewModel.shellThickness },
            set: { viewModel.shellThickness = max(0, $0) })
        return AdaptiveBar(style: .capsule, spacing: 12) {
            Image(systemName: "cube.transparent")
            Text(viewModel.shellBodyID == nil
                 ? "Tap a body to shell"
                 : viewModel.shellSelectedFaces.isEmpty
                    ? "Tap faces to open (or Apply for a closed hollow)"
                    : "\(viewModel.shellSelectedFaces.count) face\(viewModel.shellSelectedFaces.count == 1 ? "" : "s") open")
                .font(.subheadline)
                .fixedSize()
            Divider().frame(height: 20)
            Text("Thickness").font(.caption).foregroundStyle(.barLabel).fixedSize()
            ExpressionValueField(placeholder: settings.unit.symbol, value: value,
                                 clamp: nil, identifier: "ShellThicknessField")
            Text(settings.unit.symbol).font(.caption).foregroundStyle(.barLabel).fixedSize()
        } actions: {
            Button("Cancel") { viewModel.cancelShell() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("ShellCancel")
            Button("Apply") { viewModel.commitShell() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!viewModel.canCommitShell)
                .accessibilityIdentifier("ShellApply")
        }
    }

    /// Add Axis bar (spec §6.2). The construction is derived from the picks
    /// rather than chosen up front, so the bar's job is to NAME what the
    /// current picks resolve to — otherwise "tap two flat faces" and "tap one"
    /// would look identical right up until Apply.
    private func axisBar(_ viewModel: EditorViewModel) -> some View {
        let value = settings.unit.binding(Binding(
            get: { viewModel.axisLength },
            set: { viewModel.axisLength = max(0.001, $0) }))
        return AdaptiveBar(style: .capsule, spacing: 12) {
            Image(systemName: "line.diagonal.arrow")
            Text(viewModel.axisConstructionLabel)
                .font(.subheadline)
                .fixedSize()
            Divider().frame(height: 20)
            Text("Length").font(.caption).foregroundStyle(.barLabel).fixedSize()
            TextField(settings.unit.symbol, value: value,
                      format: .number.precision(.fractionLength(0...3)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
                .multilineTextAlignment(.trailing)
                .keyboardType(.decimalPad)
                .accessibilityIdentifier("AxisLengthField")
            Text(settings.unit.symbol).font(.caption).foregroundStyle(.barLabel).fixedSize()
        } actions: {
            Button("Cancel") { viewModel.cancelAxisTool() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("AxisCancel")
            Button("Apply") { viewModel.commitAxis() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!viewModel.canCommitAxis)
                .accessibilityIdentifier("AxisApply")
        }
    }

    /// Offset Edge bar (spec §1.9): Single/Chain type, the signed distance,
    /// and Apply/Cancel. A negative distance offsets inward on a closed
    /// profile, which is why the field is not clamped to zero the way Shell's
    /// thickness is.
    private func sketchOffsetBar(_ viewModel: EditorViewModel) -> some View {
        let value = settings.unit.binding(Binding(
            get: { viewModel.sketchOffsetDistance },
            set: { viewModel.sketchOffsetDistance = $0 }))
        let picked = viewModel.sketchOffsetSourceEntities.count
        return AdaptiveBar(style: .capsule, spacing: 12) {
            Image(systemName: "square.on.square.dashed")
            Text(picked == 0
                 ? "Tap sketch geometry to offset"
                 : "\(picked) selected")
                .font(.subheadline)
                .fixedSize()
            Divider().frame(height: 20)
            Picker("Type", selection: Binding(
                get: { viewModel.sketchOffsetType },
                set: { viewModel.sketchOffsetType = $0 }
            )) {
                ForEach(SketchOffsetType.allCases, id: \.self) { type in
                    Text(type.title).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .accessibilityIdentifier("SketchOffsetType")
            Text("Distance").font(.caption).foregroundStyle(.barLabel).fixedSize()
            TextField(settings.unit.symbol, value: value,
                      format: .number.precision(.fractionLength(0...3)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
                .multilineTextAlignment(.trailing)
                .keyboardType(.numbersAndPunctuation)
                .accessibilityIdentifier("SketchOffsetDistanceField")
            Text(settings.unit.symbol).font(.caption).foregroundStyle(.barLabel).fixedSize()
        } actions: {
            Button("Cancel") { viewModel.cancelSketchOffset() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("SketchOffsetCancel")
            Button("Apply") { viewModel.commitSketchOffset() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!viewModel.canCommitSketchOffset)
                .accessibilityIdentifier("SketchOffsetApply")
        }
    }

    /// Marquee rectangle over the viewport (plan §B13, spec §8.2). Standard
    /// visual cue: solid border = window (L→R drag, fully-inside selects),
    /// dashed = crossing (R→L, touched selects). Screen points come straight
    /// from the gesture, so the path ignores the safe area to line up with
    /// the full-bleed Metal view.
    @ViewBuilder
    private func marqueeOverlay(_ viewModel: EditorViewModel) -> some View {
        if let marquee = viewModel.marqueeState {
            let rect = CGRect(
                x: min(marquee.start.x, marquee.current.x),
                y: min(marquee.start.y, marquee.current.y),
                width: abs(marquee.current.x - marquee.start.x),
                height: abs(marquee.current.y - marquee.start.y)
            )
            Path { $0.addRect(rect) }
                .fill(Color.blue.opacity(0.08))
                .overlay(
                    Path { $0.addRect(rect) }
                        .stroke(
                            Color.blue,
                            style: StrokeStyle(
                                lineWidth: 1.5,
                                dash: marquee.isWindow ? [] : [6, 4]
                            )
                        )
                )
                .allowsHitTesting(false)
                .ignoresSafeArea()
                .accessibilityIdentifier("MarqueeOverlay")
        }
    }

    /// Select-mode pill (plan §B13): filter chips (Bodies | Sketches) + Done.
    private func selectModePill(_ viewModel: EditorViewModel) -> some View {
        statusPill(
            icon: "cursorarrow.and.square.on.square.dashed",
            text: "Drag to select"
        ) {
            Button("Bodies") {
                viewModel.toggleAreaSelectBodies()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(viewModel.areaSelectIncludesBodies ? Color.blue : Color.secondary)
            .accessibilityIdentifier("SelectFilterBodies")
            Button("Sketches") {
                viewModel.toggleAreaSelectSketches()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(viewModel.areaSelectIncludesSketches ? Color.blue : Color.secondary)
            .accessibilityIdentifier("SelectFilterSketches")
            Button("Done") {
                viewModel.exitSelectMode()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("SelectModeDone")
        }
    }

    /// Writes per-body payloads into a fresh temp folder and returns exporter
    /// items named "<body>.<ext>"; nil (with a user-facing error) on failure.
    private func perBodyExportItems(
        _ payloads: [(name: String, data: Data)]?,
        fileExtension: String,
        viewModel: EditorViewModel
    ) -> [ExportFileItem]? {
        guard let payloads else { return nil }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("os3d-perbody-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            return try payloads.map { payload in
                let stem = payload.name.replacingOccurrences(of: "/", with: "-")
                let url = directory
                    .appendingPathComponent(stem.isEmpty ? "Body" : stem)
                    .appendingPathExtension(fileExtension)
                try payload.data.write(to: url)
                return ExportFileItem(url: url)
            }
        } catch {
            viewModel.errorMessage = "Export failed — please try again."
            return nil
        }
    }

    /// Mesh options sheet confirm (plan §B14): stages the chosen OBJ/GLB
    /// payload for the exporter that presents once the sheet dismisses.
    private func stageMeshExport(
        _ format: MeshExportFormat, perBody: Bool, viewModel: EditorViewModel
    ) {
        switch (format, perBody) {
        case (.obj, false):
            if let data = viewModel.exportOBJ() {
                pendingExport = ExportDocument(
                    data: data, contentType: ExportDocument.objType, fileExtension: "obj"
                )
            }
        case (.obj, true):
            pendingExportItems = perBodyExportItems(
                viewModel.exportOBJPerBody(), fileExtension: "obj", viewModel: viewModel
            )
        case (.glb, false):
            if let data = viewModel.exportGLB() {
                pendingExport = ExportDocument(
                    data: data, contentType: ExportDocument.glbType, fileExtension: "glb"
                )
            }
        case (.glb, true):
            pendingExportItems = perBodyExportItems(
                viewModel.exportGLBPerBody(), fileExtension: "glb", viewModel: viewModel
            )
        }
    }

    /// Toolbar Import menu (STL/DXF files, inserted images).
    private func importMenu(_ viewModel: EditorViewModel) -> some View {
        Menu {
            Button(FloeCADStrings.label("cad.ui.import.stlFile", "STL File…")) {
                importRequest = .stl
                showImporter = true
            }
            .accessibilityIdentifier("ImportSTL")
            // DXF import (plan §B14): entities join a ground-plane
            // sketch as one undo step.
            Button(FloeCADStrings.label("cad.ui.import.dxfFile", "DXF File…")) {
                importRequest = .dxf
                showImporter = true
            }
            .accessibilityIdentifier("ImportDXF")
            // STEP import (spec §12.1): solids arrive analytic, so an imported
            // part can be filleted/shelled/booleaned like a native one.
            Button(FloeCADStrings.label("cad.ui.import.stepFile", "STEP File…")) {
                importRequest = .step
                showImporter = true
            }
            .accessibilityIdentifier("ImportSTEP")
            // Textured meshes: glTF/GLB, USDZ, OBJ with its MTL and images, .blend,
            // or a zip holding any of them. Parts become mesh bodies.
            Button(FloeCADStrings.label("cad.ui.import.meshFile", "OBJ / glTF / USDZ / Blender…")) {
                importRequest = .mesh
                showImporter = true
            }
            .accessibilityIdentifier("ImportMesh")
            Divider()
            // Insert Image (plan §B10, spec §6.3): the picked
            // picture waits for a plane tap (ground by default).
            Button(FloeCADStrings.label("cad.ui.import.imagePhotos", "Image from Photos…")) {
                showPhotoPicker = true
            }
            .accessibilityIdentifier("InsertImagePhotos")
            Button(FloeCADStrings.label("cad.ui.import.imageFiles", "Image from Files…")) {
                importRequest = .image
                showImporter = true
            }
            .accessibilityIdentifier("InsertImageFiles")
        } label: {
            Label(FloeCADStrings.label("cad.ui.common.import", "Import"), systemImage: "square.and.arrow.down")
        }
        .accessibilityIdentifier("ImportMenu")
    }

    /// Toolbar Export menu (spec §12, plan §B14): mesh formats, sketch DXF,
    /// screenshot, and — where ModelIO can write USDZ — USDZ + AR Preview.
    private func exportMenu(_ viewModel: EditorViewModel) -> some View {
        Menu {
            Button("STL") {
                if let data = viewModel.exportSTL() {
                    exportDocument = ExportDocument(
                        data: data,
                        contentType: ExportDocument.stlType,
                        fileExtension: "stl"
                    )
                }
            }
            // OBJ and GLB open an options sheet (plan §B14): both
            // support the "Separate File per Body" split.
            Button("OBJ") {
                meshExportFormat = .obj
            }
            Button("GLB") {
                meshExportFormat = .glb
            }
            Button("3MF") {
                if let data = viewModel.exportThreeMF() {
                    exportDocument = ExportDocument(
                        data: data,
                        contentType: ExportDocument.threeMFType,
                        fileExtension: "3mf"
                    )
                }
            }
            // USDZ only where ModelIO can actually write it
            // (never faked — some simulators can't).
            if USDZExporter.isSupported {
                Button("USDZ") {
                    if let data = viewModel.exportUSDZ() {
                        exportDocument = ExportDocument(
                            data: data,
                            contentType: ExportDocument.usdzType,
                            fileExtension: "usdz"
                        )
                    }
                }
            }
            // DXF of the active/ground sketch (plan §B14).
            Button("DXF") {
                if let data = viewModel.exportDXF() {
                    exportDocument = ExportDocument(
                        data: data,
                        contentType: ExportDocument.dxfType,
                        fileExtension: "dxf"
                    )
                }
            }
            // STEP (spec §12.2): the only export here that stays EXACT — a
            // cylinder opens as a cylinder in the receiving CAD, not as a
            // prism. Mesh-only bodies are skipped, with a notice naming them.
            Button("STEP") {
                if let data = viewModel.exportSTEP() {
                    exportDocument = ExportDocument(
                        data: data,
                        contentType: ExportDocument.stepType,
                        fileExtension: "step"
                    )
                }
            }
            .accessibilityIdentifier("ExportSTEP")
            Divider()
            // Full-fidelity FloeCAD project package: sketches, features,
            // variables, assembly and drawings. Mesh exports above are
            // geometry-only; this commits the versioned package (off-main,
            // revision-guarded) that reopens as a live document.
            Button(FloeCADStrings.label("cad.ui.export.saveProject", "Save Project")) {
                Task {
                    let outcome = await document.save()
                    if let error = outcome.error {
                        viewModel.errorMessage = "Save failed: \(error)"
                    }
                }
            }
            .accessibilityIdentifier("SaveProjectButton")
            Divider()
            Button(FloeCADStrings.label("cad.ui.export.pngScreenshot", "PNG Screenshot…")) {
                showScreenshotOptions = true
            }
            // AR Quick Look presentation is host-provided UI in Floe; the
            // USDZ export itself stays in the menu above.
        } label: {
            Label(FloeCADStrings.label("cad.ui.common.export", "Export"), systemImage: "square.and.arrow.up")
        }
        .accessibilityIdentifier("ExportMenu")
    }

    /// Viewport + floating chrome + toolbar; the presentation modifiers
    /// (importers, exporters, sheets, alerts) attach in `editorContent`.
    /// Split keeps each expression type-checkable in reasonable time.
    private func viewportChrome(_ viewModel: EditorViewModel) -> some View {
        // On a phone the palette covers a sixth of the width: Zoom to Fit
        // frames, and the view centres, in the strip it leaves visible.
        ViewportView(viewModel: viewModel,
                     paletteFrame: horizontalSizeClass == .compact ? paletteFrame : nil,
                     paletteOnRight: settings.paletteOnRight)
            .ignoresSafeArea()
            .overlay {
                marqueeOverlay(viewModel)
            }
            .overlay {
                // Constraint glyphs: tap to select, Delete removes (plan §C3).
                // Below the dimension overlay so that when an auto-constraint
                // glyph and a dimension label share an anchor (e.g. a horizontal
                // line's "H" glyph over its length label), tapping opens the
                // dimension editor — the primary interaction — rather than
                // selecting the glyph (which is also deletable via the Items
                // panel).
                if !viewModel.isPickingSymmetryAxis {
                    SketchConstraintOverlay(viewModel: viewModel)
                }
            }
            .overlay {
                // Informational point markers belong below numeric editors:
                // otherwise endpoint circles paint over opaque keypad keys.
                SketchPointStateOverlay(viewModel: viewModel)
            }
            .overlay {
                // Pending measurements remain below opaque numeric editors.
                SketchLiveDimensionOverlay(viewModel: viewModel)
            }
            .overlay {
                // Sketch dimension annotations + inline editors (plan §C2).
                if !viewModel.isPickingSymmetryAxis {
                    SketchDimensionOverlay(viewModel: viewModel)
                }
            }
            .overlay {
                if !viewModel.isPickingSymmetryAxis {
                    SketchTransformControlsOverlay(viewModel: viewModel)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea()
                }
                if !viewModel.isPickingSymmetryAxis {
                    SketchRadialHandleOverlay(viewModel: viewModel)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea()
                }
                if !viewModel.isPickingSymmetryAxis {
                    SketchRectangleEdgeHandleOverlay(viewModel: viewModel)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea()
                }
            }
            .overlay {
                // Non-interactive projected overlays, grouped in one ZStack to
                // keep the modifier chain type-checkable: cube face names
                // (§7.2), the flat extrude-style move/rotate gizmo (replaces
                // the Metal mesh; drags stay 3D-hit-tested), and the named-snap
                // chip while drawing.
                ZStack {
                    OrientationCubeLabels(viewModel: viewModel)
                    MoveGizmoOverlay(viewModel: viewModel)
                    SnapChipOverlay(viewModel: viewModel)
                }
            }
            .overlay {
                // Shapr3D on-arrow value pills: extrude / diameter (§4.1), and
                // the move gizmo's twin — live drag distance, plus the typed
                // exact-distance field when an arrow is tapped (§5.1). One
                // ZStack, so the modifier chain stays type-checkable.
                ZStack {
                    ExtrudeGizmoOverlay(viewModel: viewModel)
                    MoveDistanceOverlay(viewModel: viewModel)
                    RotationOrbitOverlay(viewModel: viewModel)
                }
            }
            .overlay {
                // Hardware-keyboard hotkeys (spec §8.4). Zero-sized; see
                // CommandShortcutsView for why the shortcuts ride on buttons.
                CommandShortcutsView(viewModel: viewModel)
            }
            .overlay {
                // Command Search (spec §8.4). An overlay rather than a sheet:
                // it must be openable from anywhere, and two sheets cannot be
                // up at once.
                if viewModel.commandSearchActive {
                    CommandSearchView(viewModel: viewModel)
                }
            }
            .overlay(alignment: settings.paletteOnRight ? .leading : .trailing) {
                if viewModel.mode.isSketching, !viewModel.sketchTransformActive, !viewModel.isPickingSymmetryAxis {
                    SketchConstraintRail(viewModel: viewModel)
                        .padding(settings.paletteOnRight ? .leading : .trailing, 14)
                        .padding(.top, 100)
                        .padding(.bottom, bottomBarInset + 20)
                }
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 10) {
                    // Selection info strip sits above the numeric bar when
                    // both are visible (spec §16.3).
                    SelectionInfoBar(viewModel: viewModel)
                    // Chamfer/Fillet pick replaces the numeric bar with the
                    // blend bar (both bottom-anchored; never stacked).
                    if case .pickingBlendEdges(let kind) = viewModel.mode {
                        blendBar(kind, viewModel)
                    } else if case .pickingShellFaces = viewModel.mode {
                        shellBar(viewModel)
                    } else if case .pickingDeleteFaces = viewModel.mode {
                        deleteFaceBar(viewModel)
                    } else if case .pickingReplaceFace = viewModel.mode {
                        replaceFaceBar(viewModel)
                    } else if case .pickingAxisReferences = viewModel.mode {
                        axisBar(viewModel)
                    } else if viewModel.mode.sketchTool == .offset {
                        sketchOffsetBar(viewModel)
                    } else {
                        NumericInputBar(viewModel: viewModel)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .measuringBottomBarHeight()
            }
            .onPreferenceChange(BottomBarHeightKey.self) { height in
                bottomBarHeight = height
            }
            .overlay(alignment: .topTrailing) {
                // Items Manager sidebar (spec §11).
                if showItemsPanel {
                    ItemsPanelView(viewModel: viewModel)
                        .padding(.trailing, 14)
                        .padding(.top, 8)
                }
            }
            .overlay(alignment: .topLeading) {
                // Feature history / timeline panel (Phase D, Task C3). Anchored
                // leading so it clears the Items panel at .topTrailing.
                if viewModel.showHistoryPanel {
                    HistoryPanelView(viewModel: viewModel)
                        .padding(.leading, 14)
                        .padding(.top, 8)
                }
            }
            // Keep palette flyouts above the panels they temporarily overlap.
            .overlay(alignment: settings.paletteOnRight ? .trailing : .leading) {
                ToolPaletteView(viewModel: viewModel)
                    // The column itself (flyouts are overlays, outside it).
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                        paletteFrame = $0
                    }
                    // Interface side (spec §17): palette flips to the right
                    // for left-handed sketching.
                    .padding(settings.paletteOnRight ? .trailing : .leading,
                             (settings.paletteOnRight ? showItemsPanel : viewModel.showHistoryPanel)
                             ? 318 : 14)
                    // Keep the (scrollable) palette clear of the top bar and
                    // the bottom info/input bars, which span the full width:
                    // without the inset the last tools (Delete) can sit under
                    // the numeric bar and become untappable in portrait.
                    .padding(.top, 8)
                    .padding(.bottom, bottomBarInset)
            }
            .overlay(alignment: .bottomLeading) {
                // Variables panel (Phase D, Task B3). Anchored bottom-leading so
                // it clears the History panel (.topLeading) and Items
                // (.topTrailing); the tool palette is inset above it.
                if viewModel.showVariablesPanel {
                    VariablesPanelView(viewModel: viewModel)
                        .padding(.leading, 14)
                        .padding(.bottom, 8)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                // Copy badge (spec §5.1): next gizmo drag moves a duplicate.
                if viewModel.gizmoOrigin != nil {
                  HStack(spacing: 10) {
                    // "Move the gizmo" mode (tap the pivot): say what a touch
                    // does now, and how to leave (iPad, 2026-09-14).
                    if viewModel.gizmoRepositionArmed {
                        Text("Tap or drag where the gizmo should sit")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.orange, in: Capsule())
                            .accessibilityIdentifier("GizmoRepositionHint")
                    }
                    // Recenter: back to the selection's centre once the gizmo
                    // has been dropped elsewhere (Jason, iPad, 2026-09-14).
                    if viewModel.gizmoRepositionArmed, viewModel.gizmoPivotIsOffset {
                        Button {
                            viewModel.recenterGizmoPivot()
                        } label: {
                            Label("Recenter", systemImage: "arrow.counterclockwise")
                                .font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .tint(Color.secondary)
                        .background(.regularMaterial, in: Capsule())
                        .accessibilityIdentifier("RecenterBadge")
                    }
                    // Reposition badge: the same mode a tap on the pivot
                    // enters, from a button that is easy to hit (the pivot
                    // dot was still too small a target — Jason, iPad,
                    // 2026-09-14). Reads "Done" while the mode is on.
                    Button {
                        viewModel.toggleGizmoReposition()
                    } label: {
                        Label(viewModel.gizmoRepositionArmed ? "Done" : "Reposition",
                              systemImage: viewModel.gizmoRepositionArmed ? "checkmark" : "scope")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(viewModel.gizmoRepositionArmed ? Color.orange : Color.secondary)
                    .background(.regularMaterial, in: Capsule())
                    .accessibilityIdentifier("RepositionBadge")
                    Button {
                        viewModel.copyOnDrag.toggle()
                    } label: {
                        Label("Copy", systemImage: "plus.square.on.square")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(viewModel.copyOnDrag ? Color.blue : Color.secondary)
                    .background(.regularMaterial, in: Capsule())
                    .accessibilityIdentifier("CopyBadge")
                  }
                    .padding(.trailing, 16)
                    .padding(.bottom, bottomBarInset)
                } else if viewModel.mode.isSketching, viewModel.mode.sketchTool == nil,
                          viewModel.editingDimension == nil,
                          (!viewModel.selectedSketchEntityIDs.isEmpty || viewModel.sketchTransformActive) {
                    // Sketch Copy chip (spec §1.10): the next selection-gizmo
                    // drag moves/rotates duplicates.
                    HStack {
                    // Any selection can opt into exact values (Shapr3D: Move/Rotate
                    // offers arrows plus a keypad for whatever is selected); a
                    // mixed selection used to have only the drag gizmo.
                    if !viewModel.selectedSketchEntityIDs.isEmpty || viewModel.sketchTransformActive {
                        Button(viewModel.sketchTransformActive ? "Done" : "Move/Rotate") {
                            viewModel.sketchTransformActive.toggle()
                        }
                        .buttonStyle(.bordered)
                        .background(.regularMaterial, in: Capsule())
                        .accessibilityIdentifier("SketchTransformMode")
                    }
                    Button {
                        if viewModel.usesExplicitSketchTransform { viewModel.sketchTransformActive = true }
                        viewModel.sketchCopyOnDrag.toggle()
                    } label: {
                        Label("Copy", systemImage: "plus.square.on.square")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(viewModel.sketchCopyOnDrag ? Color.blue : Color.secondary)
                    .background(.regularMaterial, in: Capsule())
                    .accessibilityIdentifier("SketchCopyBadge")
                    .disabled(viewModel.selectedSketchEntityIDs.isEmpty)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.trailing, 16)
                    .padding(.bottom, bottomBarInset)
                } else if viewModel.sectionState != nil {
                    // Section badges (spec §16.1): Flip switches the visible
                    // side; Off restores the full model.
                    HStack(spacing: 8) {
                        Button {
                            viewModel.flipSection()
                        } label: {
                            Label("Flip", systemImage: "arrow.left.arrow.right")
                                .font(.subheadline.weight(.semibold))
                        }
                        .accessibilityIdentifier("SectionFlip")
                        Button {
                            viewModel.endSection()
                        } label: {
                            Label("Section Off", systemImage: "xmark")
                                .font(.subheadline.weight(.semibold))
                        }
                        .accessibilityIdentifier("SectionOff")
                    }
                    .buttonStyle(.bordered)
                    .tint(Color.secondary)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.trailing, 16)
                    .padding(.bottom, bottomBarInset)
                }
            }
            .overlay(alignment: .top) {
                if let tool = viewModel.pendingCreateTool {
                    // Modify group armed (pick the operation, then the region).
                    statusPill(
                        icon: "cube",
                        text: "Tap a sketch region to \(tool.rawValue.capitalized)"
                    ) {
                        Button("Cancel") { viewModel.cancelCreate() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .keyboardShortcut(.cancelAction)
                            .accessibilityIdentifier("CreateToolCancel")
                    }
                } else if viewModel.selectModeActive {
                    selectModePill(viewModel)
                } else if viewModel.mode.isSketching, let symbol = viewModel.pendingSymbol {
                    // Insert Symbol armed (plan §B16): each tap stamps an
                    // instance; Done (or Esc) exits placement.
                    statusPill(
                        icon: "rectangle.stack",
                        text: "Tap to place \"\(symbol.name)\""
                    ) {
                        Button("Done") {
                            viewModel.cancelInsertSymbol()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("InsertSymbolDone")
                    }
                } else if viewModel.mode.isSketching {
                    VStack(spacing: 8) {
                        if viewModel.mode.sketchTool == .rect {
                            HStack(spacing: 12) {
                                Menu {
                                    ForEach(RectangleType.allCases, id: \.self) { type in
                                        Button(type.title + " Rectangle") { viewModel.setRectangleType(type) }
                                            .accessibilityIdentifier("RectangleType-" + type.rawValue)
                                    }
                                } label: {
                                    Label(viewModel.rectangleType.title + " Rectangle", systemImage: "chevron.down")
                                }
                                .accessibilityIdentifier("RectangleTypeMenu")
                                Text(viewModel.rectangleInstruction).font(.caption)
                                if viewModel.hasPendingRectangle {
                                    Button("Cancel Rectangle") { viewModel.clearRectanglePlacement() }
                                        .accessibilityIdentifier("CancelRectangle")
                                }
                            }
                            .padding(10)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        }
                        statusPill(icon: "pencil.and.outline", text: sketchStatusText(viewModel)) {
                            sketchStateChip(viewModel)
                            // Shown when the camera drifted >10° off head-on.
                            if viewModel.lookAtSketchAvailable {
                                Button("Look at Sketch") {
                                    viewModel.lookAtSketch()
                                }
                                .controlSize(.small)
                                .accessibilityIdentifier("LookAtSketch")
                            }
                            if viewModel.isPickingSymmetryAxis {
                                Button("Cancel Symmetry") { viewModel.cancelSymmetryAxisPick() }
                                    .accessibilityIdentifier("CancelSymmetry")
                            }
                            Button("Exit Sketching") {
                                viewModel.finishSketch()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                } else if case .pickingSketchPlane = viewModel.mode {
                    statusPill(
                        icon: "square.3.layers.3d",
                        text: "Choose a sketch plane"
                    ) {
                        Button("Cancel") {
                            viewModel.cancelPlanePicking()
                        }
                        .controlSize(.small)
                        .keyboardShortcut(.cancelAction)
                    }
                } else if case .pickingSectionPlane = viewModel.mode {
                    statusPill(
                        icon: "square.split.diagonal.2x2",
                        text: "Choose a section plane"
                    ) {
                        Button("Cancel") {
                            viewModel.cancelSectionPlanePick()
                        }
                        .controlSize(.small)
                        .keyboardShortcut(.cancelAction)
                    }
                } else if case .pickingImagePlane = viewModel.mode {
                    statusPill(
                        icon: "photo",
                        text: "Tap a plane for the image"
                    ) {
                        Button("Cancel") {
                            viewModel.cancelImagePlanePick()
                        }
                        .controlSize(.small)
                        .keyboardShortcut(.cancelAction)
                    }
                } else if case .pickingBooleanTool(let kind, _) = viewModel.mode {
                    statusPill(
                        icon: "square.on.square",
                        text: "Tap the second body to \(kind.rawValue)"
                    ) {
                        Button("Cancel") {
                            viewModel.cancelBooleanPicking()
                        }
                        .controlSize(.small)
                        .keyboardShortcut(.cancelAction)
                    }
                } else if case .pickingFeatureBody = viewModel.mode {
                    statusPill(
                        icon: "cube",
                        text: viewModel.featureBodyPickPrompt ?? "Tap the body"
                    ) {
                        Button("Cancel") {
                            viewModel.cancelFeatureBodyPick()
                        }
                        .controlSize(.small)
                        .keyboardShortcut(.cancelAction)
                    }
                } else if case .pickingFeatureFace = viewModel.mode {
                    statusPill(
                        icon: "square.on.square.dashed",
                        text: viewModel.featureFacePickPrompt ?? "Tap the face"
                    ) {
                        Button("Cancel") {
                            viewModel.cancelFeatureFacePick()
                        }
                        .controlSize(.small)
                        .keyboardShortcut(.cancelAction)
                    }
                } else if case .pickingFeatureProfile = viewModel.mode {
                    statusPill(
                        icon: "pencil.and.outline",
                        text: viewModel.featureProfilePickPrompt ?? "Tap the profile"
                    ) {
                        Button("Cancel") {
                            viewModel.cancelFeatureProfilePick()
                        }
                        .controlSize(.small)
                        .keyboardShortcut(.cancelAction)
                    }
                } else if case .pickingRevolveAxis = viewModel.mode {
                    statusPill(
                        icon: "arrow.triangle.2.circlepath",
                        text: "Tap a sketch line to set the revolve axis"
                    ) {
                        Button("Cancel") {
                            viewModel.cancelRevolveAxisPick()
                        }
                        .controlSize(.small)
                        .keyboardShortcut(.cancelAction)
                    }
                } else if case .pickingSweepPath = viewModel.mode {
                    // Pill mirrors the sweep bar's segment count (plan §B1).
                    let count = viewModel.toolContext?.sweepPathEntityIDs.count ?? 0
                    statusPill(
                        icon: "point.topleft.down.to.point.bottomright.curvepath",
                        text: count == 0
                            ? "Tap sketch lines to build the sweep path"
                            : "Sweep path: \(count) segment\(count == 1 ? "" : "s") chained"
                    ) {
                        Button("Cancel") {
                            viewModel.cancelSweepPathPick()
                        }
                        .controlSize(.small)
                        .keyboardShortcut(.cancelAction)
                    }
                } else if case .pickingLoftProfiles = viewModel.mode {
                    // Pill mirrors the loft bar's section count (plan §B2).
                    let count = viewModel.toolContext?.loftProfiles.count ?? 0
                    statusPill(
                        icon: "square.stack.3d.up",
                        text: count < 2
                            ? "Tap profile fills to add loft sections"
                            : "Loft: \(count) sections in tap order"
                    ) {
                        Button("Cancel") {
                            viewModel.cancelLoftProfilePick()
                        }
                        .controlSize(.small)
                        .keyboardShortcut(.cancelAction)
                    }
                } else if case .pickingSplitCutter = viewModel.mode {
                    statusPill(
                        icon: "square.split.1x2",
                        text: "Tap a plane or profile to split"
                    ) {
                        Button("Cancel") {
                            viewModel.cancelSplitCutterPick()
                        }
                        .controlSize(.small)
                        .keyboardShortcut(.cancelAction)
                    }
                } else if case .patterning = viewModel.mode {
                    statusPill(
                        icon: "square.grid.3x3",
                        text: "Set pattern options below, then Apply"
                    ) {
                        Button("Cancel") {
                            viewModel.cancelPattern()
                        }
                        .controlSize(.small)
                        .keyboardShortcut(.cancelAction)
                    }
                } else if case .rotatingAroundAxis = viewModel.mode {
                    statusPill(
                        icon: "arrow.clockwise",
                        text: viewModel.rotateAxisState?.hasAxis == true
                            ? "Drag to rotate, or type an angle"
                            : "Tap a sketch line, or pick a world axis"
                    ) {
                        if viewModel.rotateAxisState?.hasAxis != true {
                            Button("X") { viewModel.setRotateWorldAxis(.x) }
                                .controlSize(.small)
                                .accessibilityIdentifier("RotateAxisX")
                            Button("Y") { viewModel.setRotateWorldAxis(.y) }
                                .controlSize(.small)
                                .accessibilityIdentifier("RotateAxisY")
                            Button("Z") { viewModel.setRotateWorldAxis(.z) }
                                .controlSize(.small)
                                .accessibilityIdentifier("RotateAxisZ")
                        }
                        Button("Cancel") {
                            viewModel.cancelRotateAxis()
                        }
                        .controlSize(.small)
                        .keyboardShortcut(.cancelAction)
                    }
                } else if case .translating = viewModel.mode {
                    statusPill(
                        icon: "arrow.right.to.line",
                        text: viewModel.transformPickPoints.isEmpty
                            ? "Tap the source point"
                            : "Tap the destination point"
                    ) {
                        Button("Cancel") {
                            viewModel.cancelTranslate()
                        }
                        .controlSize(.small)
                        .keyboardShortcut(.cancelAction)
                    }
                } else if case .aligning = viewModel.mode {
                    statusPill(
                        icon: "point.3.connected.trianglepath.dotted",
                        text: viewModel.transformPickPoints.isEmpty
                            ? "Tap a point on the body to move"
                            : "Tap the destination point"
                    ) {
                        Button("Cancel") {
                            viewModel.cancelAlign()
                        }
                        .controlSize(.small)
                        .keyboardShortcut(.cancelAction)
                    }
                } else if case .measuring = viewModel.mode {
                    measurePill(viewModel)
                } else if case .faceSelected = viewModel.mode {
                    statusPill(
                        icon: viewModel.notice != nil
                            ? "exclamationmark.circle.fill"
                            : "square.3.layers.3d.top.filled",
                        // A refusal (e.g. Move on a curved face) takes over the
                        // pill so the reason lands where the user is looking.
                        text: viewModel.notice ?? (viewModel.faceMoveActive
                            ? "Move face — drag to shear the solid"
                            : viewModel.faceScaleActive
                                ? "Scale face — drag to taper the solid"
                                : viewModel.faceRotateActive
                                    ? "Rotate face — drag a ring to tilt the solid"
                                    : viewModel.toolContext?.curvedRegion == true
                                        ? "Curved face — no push/pull or transform"
                                        : "Face selected — drag it to push or pull")
                    ) {
                        Button("Done") {
                            viewModel.commitTool()
                        }
                        .controlSize(.small)
                    }
                }
            }
            // Transient explanation (e.g. a tool refusing a curved face). Its OWN
            // overlay, pushed below the status pill — sharing the pill's overlay
            // would stack the two at the same .top alignment, hiding this one.
            .overlay(alignment: .top) {
                if let notice = viewModel.notice {
                    Label(notice, systemImage: "exclamationmark.circle.fill")
                        .font(.subheadline)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.regularMaterial, in: Capsule())
                        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
                        .padding(.top, 68)
                        .transition(.opacity)
                        .accessibilityIdentifier("EditorNotice")
                }
            }
            .animation(.easeInOut(duration: 0.2), value: viewModel.notice)
            .overlay {
                if viewModel.isComputingBoolean {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Computing…")
                            .font(.subheadline)
                        Button("Cancel") {
                            viewModel.cancelBooleanComputation()
                        }
                        .controlSize(.small)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        viewModel.undo()
                    } label: {
                        ZStack {
                            Color.clear
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .accessibilityLabel("Undo")
                    }
                    .disabled(!viewModel.session.undoStack.canUndo && !viewModel.hasPendingRectangle)
                    // Distinct from the software keyboard's own "Undo": with
                    // only a label to match on, `app.buttons["Undo"]` found two
                    // elements and every single-element query threw.
                    .accessibilityIdentifier("UndoButton")

                    Button {
                        viewModel.redo()
                    } label: {
                        ZStack {
                            Color.clear
                            Image(systemName: "arrow.uturn.forward")
                        }
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .accessibilityLabel("Redo")
                    }
                    .disabled(!viewModel.session.undoStack.canRedo)
                    .accessibilityIdentifier("RedoButton")

                    Button {
                        viewModel.fitView()
                    } label: {
                        Label("Fit View", systemImage: "arrow.up.left.and.arrow.down.right")
                    }

                    // Views popover (spec §7.3): standard views + projection,
                    // plus Display modes / Isolate / Section (spec §16).
                    Menu {
                        ForEach(StandardView.allCases) { standard in
                            Button(standard.rawValue) {
                                viewModel.applyStandardView(standard)
                            }
                        }
                        Divider()
                        Toggle("Orthographic", isOn: Binding(
                            get: { viewModel.orthographicEnabled },
                            set: { viewModel.setOrthographic($0) }
                        ))
                        Divider()
                        // Display modes (spec §16.4); the submenu label names
                        // the active shader.
                        Menu {
                            Picker("Display", selection: Binding(
                                get: { viewModel.displayMode },
                                set: { viewModel.displayMode = $0 }
                            )) {
                                ForEach(DisplayMode.allCases, id: \.self) { mode in
                                    Text(mode.displayLabel).tag(mode)
                                }
                            }
                            Divider()
                            Toggle("Show Hidden Edges", isOn: Binding(
                                get: { viewModel.showHiddenEdges },
                                set: { viewModel.showHiddenEdges = $0 }
                            ))
                        } label: {
                            Label(
                                "Display: \(viewModel.displayMode.displayLabel)",
                                systemImage: "cube.transparent"
                            )
                        }
                        // Ground blob shadows (visualization v1, plan §B15).
                        Toggle("Ground Shadow", isOn: Binding(
                            get: { viewModel.groundShadowEnabled },
                            set: { viewModel.groundShadowEnabled = $0 }
                        ))
                        // Isolate (spec §16.2): hide everything but the
                        // selection; exiting restores.
                        if viewModel.isIsolateActive {
                            Button("Exit Isolate") {
                                viewModel.exitIsolate()
                            }
                        } else {
                            Button("Isolate") {
                                viewModel.enterIsolate()
                            }
                            .disabled(viewModel.selection.isEmpty)
                        }
                        // Section View (spec §16.1).
                        if viewModel.sectionState != nil {
                            Button("Flip Section") {
                                viewModel.flipSection()
                            }
                            Button("Section Off") {
                                viewModel.endSection()
                            }
                        } else {
                            Button("Section") {
                                viewModel.beginSectionPlanePick()
                            }
                        }
                    } label: {
                        Label("Views", systemImage: "square.stack.3d.up")
                    }
                    .accessibilityIdentifier("ViewsMenu")

                    Button {
                        viewModel.showHistoryPanel.toggle()
                    } label: {
                        Label(FloeCADStrings.label("cad.toolbar.history", "History"),
                              systemImage: "clock.arrow.circlepath")
                    }
                    .accessibilityIdentifier("HistoryButton")

                    Button {
                        viewModel.showVariablesPanel.toggle()
                    } label: {
                        Label(FloeCADStrings.label("cad.toolbar.variables", "Variables"),
                              systemImage: "function")
                    }
                    .accessibilityIdentifier("VariablesButton")

                    Button {
                        showItemsPanel.toggle()
                    } label: {
                        Label(FloeCADStrings.label("cad.toolbar.items", "Items"),
                              systemImage: "sidebar.trailing")
                    }
                    .accessibilityIdentifier("ItemsButton")

                    importMenu(viewModel)

                    exportMenu(viewModel)

                    Button {
                        showWorkbenchTools = true
                    } label: {
                        Label(FloeCADStrings.label("cad.workbench.tools", "CAD Tools"),
                              systemImage: "square.grid.2x2")
                    }
                    .accessibilityIdentifier("CADWorkbenchToolsButton")

                    // Canvas integration (host-injected). "Apply to canvas"
                    // replaces the ORIGINAL bound node's asset; "Make variant"
                    // is the ONLY path that creates a new node. Both appear
                    // only when the host installed the corresponding action.
                    if let actions = canvasActions, actions.applyToCanvas != nil {
                        Button {
                            runCanvasAction(actions.applyToCanvas)
                        } label: {
                            Label(FloeCADStrings.label("cad.canvas.apply", "Apply to canvas"),
                                  systemImage: "rectangle.on.rectangle.angled")
                        }
                        .disabled(isCanvasActionRunning)
                        .accessibilityIdentifier("CADApplyToCanvasButton")
                    }
                    if let actions = canvasActions, actions.makeVariant != nil {
                        Button {
                            runCanvasAction(actions.makeVariant)
                        } label: {
                            Label(FloeCADStrings.label("cad.canvas.variant", "Make variant"),
                                  systemImage: "plus.square.on.square")
                        }
                        .disabled(isCanvasActionRunning)
                        .accessibilityIdentifier("CADMakeVariantButton")
                    }

                    // Command Search (spec §8.4). A toolbar button, not just
                    // the X / ⌘F chords: without one the launcher would be
                    // unreachable on a touch-only iPad, which is most of them.
                    Button {
                        viewModel.openCommandSearch()
                    } label: {
                        Label("Command Search", systemImage: "magnifyingglass")
                    }
                    .accessibilityIdentifier("CommandSearchButton")

                    Button {
                        showSettings = true
                    } label: {
                        // One shape for both places this button can end up.
                        //
                        // In the bar: a custom 44pt clear surface. As a
                        // `Label`, the bar renders a native 41.5pt item, and
                        // a tap at its exact centre missed while ±9pt opened
                        // (6c8ffaf, and again 2026-09-16; mechanism
                        // unconfirmed). testSettingsCenterTargetOpensInBothOrientations
                        // guards it.
                        //
                        // In the "…" overflow: whenever the bar is too narrow
                        // (an iPhone in portrait, but also an iPad mini in
                        // portrait at REGULAR width), each row is built from
                        // a `Text` in the label. `.accessibilityLabel` does not
                        // count; without the hidden `Text` the menu silently
                        // dropped Settings, its only route (gotcha 58).
                        ZStack {
                            Color.clear
                            Image(systemName: "gearshape")
                            Text("Settings").opacity(0).frame(width: 0)
                        }
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .accessibilityLabel("Settings")
                    }
                    .accessibilityIdentifier("SettingsButton")
                }
            }
            .sheet(isPresented: $showSettings) {
                CADQuickSettingsSheet()
            }
            .sheet(isPresented: $showWorkbenchTools) {
                CADWorkbenchToolsPanel(document: document, viewModel: viewModel,
                                       canvasActions: canvasActions)
                    .presentationDetents([.medium, .large])
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            }
    }

    /// The one Import-menu completion handler; `importRequest` says which
    /// entry opened the picker. Every kind needs the same security-scoped
    /// read, so only the last line differs.
    private func handleImport(
        _ result: Result<URL, Error>, viewModel: EditorViewModel
    ) {
        guard case .success(let url) = result else {
            viewModel.errorMessage = "Import failed — please try again."
            return
        }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            // Keep the image wording the image importer had before these were
            // merged — "file" would be a small step backwards for that entry.
            viewModel.errorMessage = importRequest == .image
                ? "Couldn't read the selected image."
                : "Couldn't read the selected file."
            return
        }
        let name = url.lastPathComponent
        switch importRequest {
        case .stl, .mesh:
            // Mesh formats go through the units prompt (Shapr3D parity):
            // parse now, build only once the user has picked the unit.
            if let probe = viewModel.probeMesh(data: data, fileName: name) {
                pendingMeshImport = probe
            }
        case .dxf: viewModel.importDXF(data: data, fileName: name)
        case .step: viewModel.importSTEP(data: data, fileName: name)
        case .image: viewModel.beginInsertImage(data: data)
        }
    }

    @ViewBuilder
    private func editorContent(_ viewModel: EditorViewModel) -> some View {
        viewportChrome(viewModel)
            .safeAreaInset(edge: .bottom) { canvasActionStatusBar }
            // ONE importer for every Import-menu entry (see `ImportRequest`).
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: importRequest.contentTypes
            ) { result in
                handleImport(result, viewModel: viewModel)
            }
            .sheet(item: $pendingMeshImport) { probe in
                MeshUnitPromptSheet(probe: probe) { unit in
                    viewModel.importParts(
                        MeshImportKit.scaled(probe.parts, by: unit.millimetresPerUnit),
                        fileName: probe.fileName)
                }
            }
            .onAppear {
                // DEBUG hook for the UI suite: OS3D_DEBUG_IMPORT_MESH=<path>
                // opens the units prompt for that file as if it had been
                // picked — the system file picker can't be driven by XCUITest.
                #if DEBUG
                guard !didHandleDebugImport else { return }
                didHandleDebugImport = true
                if let path = ProcessInfo.processInfo.environment["OS3D_DEBUG_IMPORT_MESH"],
                   let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                    pendingMeshImport = viewModel.probeMesh(
                        data: data, fileName: (path as NSString).lastPathComponent)
                }
                #endif
            }
            .photosPicker(
                isPresented: $showPhotoPicker,
                selection: $photoPickerItem,
                matching: .images
            )
            .onChange(of: photoPickerItem) { _, item in
                guard let item else { return }
                photoPickerItem = nil
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        viewModel.beginInsertImage(data: data)
                    } else {
                        viewModel.errorMessage = "Couldn't read the selected image."
                    }
                }
            }
            .sheet(
                isPresented: $showScreenshotOptions,
                onDismiss: {
                    if let data = pendingScreenshot {
                        pendingScreenshot = nil
                        exportDocument = ExportDocument(
                            data: data, contentType: .png, fileExtension: "png"
                        )
                    }
                }
            ) {
                ScreenshotOptionsSheet { width, height, transparent, showGrid in
                    pendingScreenshot = viewModel.captureScreenshot(
                        width: width,
                        height: height,
                        transparentBackground: transparent,
                        showGrid: showGrid
                    )
                }
            }
            .sheet(
                item: $meshExportFormat,
                onDismiss: {
                    // Promote whichever payload the sheet staged; the
                    // exporter can only present after the sheet is gone.
                    if let staged = pendingExport {
                        pendingExport = nil
                        exportDocument = staged
                    } else if let staged = pendingExportItems {
                        pendingExportItems = nil
                        exportItems = staged
                    }
                }
            ) { format in
                MeshExportOptionsSheet(formatName: format.rawValue) { perBody in
                    stageMeshExport(format, perBody: perBody, viewModel: viewModel)
                }
            }
            .fileExporter(
                isPresented: Binding(
                    get: { exportItems != nil },
                    set: { if !$0 { exportItems = nil } }
                ),
                items: exportItems ?? []
            ) { result in
                exportItems = nil
                if case .failure = result {
                    viewModel.errorMessage = "Export failed — please try again."
                }
            }
            .sheet(isPresented: Binding(
                get: { viewModel.textPlacement != nil },
                set: { if !$0 { viewModel.textPlacement = nil } }
            )) {
                TextToolSheet { content, height, fontName in
                    viewModel.commitText(content: content, height: height, fontName: fontName)
                }
            }
            .sheet(isPresented: Binding(
                get: { viewModel.showMaterialSheet },
                set: { viewModel.showMaterialSheet = $0 }
            )) {
                // Body material assignment (plan §B15): one undoable
                // SetMaterialCommand over the whole selection.
                MaterialSheet(initial: viewModel.materialForSelection) { spec in
                    viewModel.applyMaterial(spec)
                }
            }
            .sheet(isPresented: Binding(
                get: { viewModel.showConstraintSettings },
                set: { viewModel.showConstraintSettings = $0 }
            )) {
                // Auto-constrain inference settings (plan §B, contract D).
                ConstraintSettingsView(viewModel: viewModel)
            }
            .fileExporter(
                isPresented: Binding(
                    get: { exportDocument != nil },
                    set: { if !$0 { exportDocument = nil } }
                ),
                document: exportDocument,
                contentType: exportDocument?.contentType ?? .data,
                defaultFilename: "\(document.name).\(exportDocument?.fileExtension ?? "stl")"
            ) { result in
                exportDocument = nil
                if case .failure = result {
                    viewModel.errorMessage = "Export failed — please try again."
                }
            }
            .confirmationDialog(
                "Select Through",
                isPresented: Binding(
                    get: { viewModel.selectThroughCandidates != nil },
                    set: { if !$0 { viewModel.selectThroughCandidates = nil } }
                ),
                titleVisibility: .visible
            ) {
                // Long-press hit list, front→back (plan §B13, spec §8.3):
                // choosing an occluded body selects it (Select Through).
                ForEach(viewModel.selectThroughCandidates ?? []) { candidate in
                    Button(candidate.name) {
                        viewModel.chooseSelectThrough(candidate)
                    }
                }
                Button("Cancel", role: .cancel) {
                    viewModel.selectThroughCandidates = nil
                }
            }
            .alert(
                "Make Symbol",
                isPresented: Binding(
                    get: { viewModel.showMakeSymbolPrompt },
                    set: { viewModel.showMakeSymbolPrompt = $0 }
                )
            ) {
                // Name prompt (plan §B16): the selected sketch entities
                // become a reusable symbol in the document.
                TextField("Name", text: $symbolNameDraft)
                Button("Create") {
                    viewModel.makeSymbol(named: symbolNameDraft)
                    symbolNameDraft = ""
                }
                Button("Cancel", role: .cancel) {
                    symbolNameDraft = ""
                }
            } message: {
                Text("Save the selected sketch entities as a reusable symbol.")
            }
            .alert(
                "Something Went Wrong",
                isPresented: Binding(
                    get: { viewModel.errorMessage != nil },
                    set: { if !$0 { viewModel.errorMessage = nil } }
                )
            ) {
                Button("OK") { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
            .onChange(of: viewModel.session.lastSaveError) { _, saveError in
                // A failed SwiftData save means recent work isn't reaching
                // disk — the one storage problem worth an alert mid-session.
                if let saveError {
                    viewModel.errorMessage =
                        "Saving failed — recent changes may not be stored. (\(saveError))"
                }
            }
    }

    // MARK: - Canvas actions (host-injected)

    /// Runs one injected Canvas action against the live document. The host
    /// closure owns export, asset persistence and the atomic Canvas commit;
    /// its result message (success or refusal) is shown above the bottom bar.
    private func runCanvasAction(_ operation: CADCanvasActions.Operation?) {
        guard let operation, !isCanvasActionRunning else { return }
        isCanvasActionRunning = true
        canvasActionMessage = nil
        Task { @MainActor in
            let result = await operation(document, document.url)
            canvasActionMessage = (result.kind, result.message)
            isCanvasActionRunning = false
        }
    }

    @ViewBuilder
    private var canvasActionStatusBar: some View {
        if isCanvasActionRunning {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(FloeCADStrings.label("cad.canvas.working", "Updating the canvas…"))
                    .font(.footnote)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(.bar)
            .accessibilityIdentifier("CADCanvasActionStatus")
        } else if let canvasActionMessage {
            HStack(spacing: 8) {
                Image(systemName: canvasActionMessage.kind == .success
                      ? "checkmark.circle.fill" : "exclamationmark.triangle")
                    .foregroundStyle(canvasActionMessage.kind == .success ? .green : .orange)
                Text(canvasActionMessage.text)
                    .font(.footnote)
                Spacer(minLength: 8)
                Button {
                    self.canvasActionMessage = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("CADCanvasActionDismiss")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(.bar)
            .accessibilityIdentifier("CADCanvasActionStatus")
        }
    }
}
