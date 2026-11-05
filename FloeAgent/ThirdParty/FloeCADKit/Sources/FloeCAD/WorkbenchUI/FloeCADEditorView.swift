//
//  EditorView.swift
//  openshape3d
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import CoreTransferable
import PhotosUI

// MARK: - Transient presentation ownership

/// Set by a host whose workbench is covered by a TRANSIENT presentation (the
/// workbench's own fullscreen cover). A disappearance caused by such a cover
/// is NOT a close — the live session is re-adopted on return — so the
/// close-time preview flush must not fire; the editor still flushes on its
/// real close and on backgrounding. (T7T)
nonisolated public struct CADWorkbenchTransientCoverKey: EnvironmentKey {
    public static let defaultValue = false
}

public extension EnvironmentValues {
    nonisolated var cadWorkbenchTransientlyCovered: Bool {
        get { self[CADWorkbenchTransientCoverKey.self] }
        set { self[CADWorkbenchTransientCoverKey.self] = newValue }
    }
}

/// Minimal FileDocument wrapper so `.fileExporter` can save any export
/// payload (STL/OBJ/3MF/GLB/DXF/STEP/IGES/USDZ/PNG); the concrete type
/// travels with the data.
struct ExportDocument: FileDocument {
    static let stlType = UTType(filenameExtension: "stl") ?? .data
    static let objType = UTType("public.geometry-definition-format")
        ?? UTType(filenameExtension: "obj") ?? .data
    static let threeMFType = UTType("org.3mf.model")
        ?? UTType(filenameExtension: "3mf") ?? .data
    static let glbType = UTType(filenameExtension: "glb") ?? .data
    static let zipType = UTType.zip
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
    /// IGES B-rep exchange. Like STEP, iOS declares no stable public UTI for
    /// IGES, so this can resolve to a dynamic type and is only used to stamp
    /// an exported file (no picker filter depends on it).
    static let igesType = UTType("com.iges")
        ?? UTType(filenameExtension: "iges") ?? .data
    static let usdzType = UTType.usdz
    /// The .os3d project archive (Phase F, spec §13).
    static let os3dType = UTType(filenameExtension: "os3d") ?? .data
    static var readableContentTypes: [UTType] {
        [stlType, objType, threeMFType, glbType, dxfType, stepType, igesType,
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
/// (plan §B14): OBJ and GLB can emit one file per body. OBJ also offers the
/// complete materials/textures ZIP; the geometry-only choice stays a real
/// single-file OBJ with UVs and an explicit "no materials" note.
struct MeshExportOptionsSheet: View {
    /// User-facing format name ("OBJ" / "GLB") for the title.
    let formatName: String
    /// OBJ exposes the materials choice; GLB keeps its existing single format.
    let supportsMaterials: Bool
    /// Exact bundle preflight for (perBody, acceptPartial, changeCount).
    /// Runs off the main actor; nil only when the caller has nothing to
    /// validate (GLB / geometry-only OBJ / empty doc) or was canceled.
    let preflight: (Bool, Bool, Int) async -> OBJBundlePreflight?
    let currentChangeCount: () -> Int
    let coverageForFormat: (String) -> CADExchangeCoverage?
    /// X22: this document carries a section cut / measurement guides that the
    /// exchange writer does not include. Nil for an ordinary model.
    var viewOnlyNotice: String? = nil
    /// Localized refusal message for a preflight diagnostic.
    let message: (OBJBundleDiagnostic) -> String
    /// Called with the per-body and materials choices when Export is confirmed.
    let onExport: (Bool, Bool, Bool, Int) -> Void

    @State private var perBodyFiles = false
    @State private var includeMaterials = true
    @State private var report: OBJBundlePreflight?
    @State private var prepared = false
    @State private var preparing = false
    @State private var coverage: CADExchangeCoverage?
    @State private var reviewedChangeCount: Int?
    @Environment(\.dismiss) private var dismiss

    private var exportUnavailable: Bool {
        guard reviewedChangeCount != nil, !preparing,
              let coverage, coverage.includedCount > 0 else { return true }
        return supportsMaterials && includeMaterials && !(report?.isReady ?? false)
    }

    /// Identity of the exact async preflight request. Toggling any reviewed
    /// choice cancels the previous task, so an old report can never reappear.
    private struct PreflightRequest: Equatable {
        var perBody: Bool
        var includeMaterials: Bool
        var acceptPartial: Bool
        var changeCount: Int
    }

    private var preflightRequest: PreflightRequest {
        PreflightRequest(perBody: perBodyFiles,
                         includeMaterials: includeMaterials,
                         acceptPartial: coverage?.requiresConfirmation == true,
                         changeCount: reviewedChangeCount ?? -1)
    }

    var body: some View {
        NavigationStack {
            Form {
                if supportsMaterials {
                    Section {
                        Toggle(FloeCADStrings.label(
                            "cad.ui.export.obj.materials", "Materials & Textures"),
                               isOn: $includeMaterials)
                            .accessibilityIdentifier("ExportIncludeMaterialsToggle")
                    } footer: {
                        Text(includeMaterials
                            ? FloeCADStrings.text(
                                "cad.ui.export.obj.materials.footer",
                                "Creates a .zip with model.obj, model.mtl and the texture images.")
                            : FloeCADStrings.text(
                                "cad.ui.export.obj.geometryOnly.footer",
                                "Writes one .obj with UVs. Materials and textures are not included."))
                            .font(.footnote)
                    }
                }
                Section {
                    Toggle(FloeCADStrings.label("cad.ui.export.separateFiles",
                                               "Separate File per Body"),
                           isOn: $perBodyFiles)
                        .accessibilityIdentifier("ExportPerBodyToggle")
                }
                if let viewOnlyNotice {
                    Section {
                        Text(viewOnlyNotice)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("ExportViewOnlyNotice")
                    }
                }
                if let coverage, !coverage.complete {
                    CADExportCoverageSummary(coverage: coverage)
                }
                if supportsMaterials, includeMaterials, preparing {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(FloeCADStrings.text(
                                "cad.ui.export.obj.preparing",
                                "Preparing export…"))
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("ExportBundlePreparing")
                    }
                } else if supportsMaterials, includeMaterials, prepared, report == nil {
                    Section {
                        Text(FloeCADStrings.text(
                            "cad.error.exportNoBodies",
                            "Nothing to export — the design has no solid bodies."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("ExportBundleEmpty")
                    }
                }
                if supportsMaterials, includeMaterials, !preparing, let report {
                    Section {
                        if let refusal = report.refusal {
                            Text(message(refusal))
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .accessibilityIdentifier("ExportBundleRefusal")
                        } else if report.isEmpty {
                            Text(FloeCADStrings.text(
                                "cad.error.exportNoBodies",
                                "Nothing to export — the design has no solid bodies."))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("ExportBundleEmpty")
                        } else if report.isReady {
                            Text(summary(report))
                                .accessibilityIdentifier("ExportBundleSummary")
                            let warnings = report.warnings.compactMap(warningText)
                            if !warnings.isEmpty {
                                ForEach(Array(warnings.prefix(4).enumerated()),
                                        id: \.offset) { _, warning in
                                    Text(warning)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text(FloeCADStrings.text("cad.ui.export.obj.preflight",
                                                 "Export Contents"))
                    } footer: {
                        if report.refusal == nil, report.isReady {
                            Text(FloeCADStrings.text(
                                "cad.ui.export.obj.preflight.mtl",
                                "Some viewers show only base color and opacity; metallic, roughness, normal and emissive maps use the extended MTL format, and scalar maps may be read as sRGB where MTL has no colorspace field."))
                                .font(.footnote)
                        }
                    }
                }
            }
            .navigationTitle(String(
                format: FloeCADStrings.text("cad.ui.export.meshTitle", "%@ Export"),
                formatName
            ))
            .onAppear { refresh() }
            .onChange(of: perBodyFiles) { _, _ in refresh() }
            .onChange(of: includeMaterials) { _, _ in refresh() }
            .task(id: preflightRequest) { await runPreflight() }
            .onDisappear { MacWindowTitle.restore() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(FloeCADStrings.label("cad.ui.common.cancel", "Cancel")) { dismiss() }
                        .accessibilityIdentifier("MeshExportCancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        guard let reviewedChangeCount, !preparing else { return }
                        onExport(perBodyFiles, supportsMaterials && includeMaterials,
                                 coverage?.requiresConfirmation == true, reviewedChangeCount)
                        dismiss()
                    } label: {
                        if coverage?.requiresConfirmation == true {
                            Text(FloeCADStrings.label("cad.ui.export.coverage.confirmPartial", "Export Included"))
                        } else {
                            Text(FloeCADStrings.label("cad.ui.common.export", "Export"))
                        }
                    }
                    .disabled(exportUnavailable)
                    .accessibilityIdentifier("MeshExportConfirm")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func refresh() {
        let count = currentChangeCount()
        let format = supportsMaterials && includeMaterials ? "obj_bundle" : formatName.lowercased()
        coverage = coverageForFormat(format)
        reviewedChangeCount = count
        guard supportsMaterials, includeMaterials else {
            report = nil
            prepared = false
            preparing = false
            return
        }
        // Do not keep showing the previous choice's report while the new
        // request is queued. `.task(id:)` starts the exact new request.
        report = nil
        prepared = false
        preparing = true
    }

    /// The expensive image-decode/ZIP build runs in the view model's owned
    /// background task. `.task(id:)` cancels it when any reviewed choice or the
    /// sheet disappears; a canceled result is never published here.
    private func runPreflight() async {
        guard supportsMaterials, includeMaterials,
              let count = reviewedChangeCount else {
            report = nil
            prepared = false
            preparing = false
            return
        }
        let acceptPartial = coverage?.requiresConfirmation == true
        preparing = true
        report = nil
        prepared = false
        let result = await preflight(perBodyFiles, acceptPartial, count)
        guard !Task.isCancelled else { return }
        report = result
        prepared = true
        preparing = false
    }

    private func summary(_ report: OBJBundlePreflight) -> String {
        let files = FloeCADStrings.format(
            "cad.ui.export.obj.preflight.summary",
            "%d materials · %d textures · %d files",
            report.materialCount, report.textureCount, report.fileCount)
        let bytes = String(format: "%.1f", Double(report.byteCount) / 1_048_576)
        let size = FloeCADStrings.format(
            "cad.ui.export.obj.preflight.bytes", "%@ MB", bytes)
        return "\(files) · \(size)"
    }

    /// Internal warning codes stay in the receipt/tests; ordinary screens show
    /// concise, actionable sentences and hide informational notices already
    /// covered by the footer.
    private func warningText(_ code: String) -> String? {
        switch code {
        case "face_material_fallback":
            return FloeCADStrings.text(
                "cad.ui.export.obj.warning.faceFallback",
                "Some face materials couldn't be resolved and use the body material instead.")
        case "texture_uv_generated":
            return FloeCADStrings.text(
                "cad.ui.export.obj.warning.uvGenerated",
                "Some textures use an automatic projection because the body has no UVs.")
        case "base_alpha_baked_to_map_d":
            return FloeCADStrings.text(
                "cad.ui.export.obj.warning.alphaBaked",
                "Base transparency is stored in the opacity map so MTL viewers apply it once.")
        case "scalar_map_normalized", "texture_rows_or_color_normalized":
            return FloeCADStrings.text(
                "cad.ui.export.obj.warning.normalized",
                "Some images were normalized to match OBJ color and row conventions.")
        case "opacity_map_semantics":
            return FloeCADStrings.text(
                "cad.ui.export.obj.warning.opacitySemantics",
                "Viewers differ on whether the opacity map uses luminance or alpha; this bundle writes the complete mask in both RGB and alpha, with the authored opacity baked in.")
        case "emissive_map_unused_zero_factor":
            return FloeCADStrings.text(
                "cad.ui.export.obj.warning.emissiveUnused",
                "An emissive image is ignored because the material has no emission.")
        case "empty_body_skipped":
            return FloeCADStrings.text(
                "cad.ui.export.obj.warning.emptyBody",
                "Empty bodies are skipped.")
        case "mtl_pbr_extension", "obj_uv_bottom_left":
            return nil
        default:
            return nil
        }
    }
}

/// Screenshot options sheet (spec §12.2): resolution, transparency, grid.
struct ScreenshotOptionsSheet: View {
    /// Multiplier of the 1024×768 base size (1x / 2x / 4x).
    @State private var resolutionScale = 1
    @State private var transparentBackground = false
    @State private var showGrid = true

    @Environment(\.dismiss) private var dismiss
    /// X22: non-nil only when saved measurement guides are visible and their
    /// numeric values are not baked into the pixels.
    let numericTextNotice: String?
    let onExport: (Int, Int, Bool, Bool) -> Void

    init(numericTextNotice: String? = nil,
         onExport: @escaping (Int, Int, Bool, Bool) -> Void) {
        self.numericTextNotice = numericTextNotice
        self.onExport = onExport
    }

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
                if let numericTextNotice {
                    Section {
                        Text(numericTextNotice)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("ScreenshotNumericTextNotice")
                    }
                }
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

/// The palette's Material action opens the full inspector (not the legacy
/// three-slider sheet) on the SAME document and frozen selection. The sheet
/// owns one stable editor preview sink for its lifetime; Apply stays one
/// undoable composite on the shared document session.
private struct EditorMaterialInspectorSheet: View {
    let document: FloeCADDocument
    let onApplied: () -> Void

    @State private var target: CADMaterialTarget
    @State private var previewSink: CADEditorMaterialPreviewSink

    init(document: FloeCADDocument, viewModel: EditorViewModel,
         onApplied: @escaping () -> Void) {
        self.document = document
        self.onApplied = onApplied
        _target = State(initialValue:
            CADMaterialTargetResolver.resolve(viewModel: viewModel))
        _previewSink = State(initialValue:
            CADEditorMaterialPreviewSink(viewModel: viewModel))
    }

    var body: some View {
        CADMaterialInspectorView(document: document,
                                 target: target,
                                 previewSink: previewSink,
                                 onApplied: onApplied)
            .presentationCompactAdaptation(horizontal: .popover, vertical: .sheet)
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

    /// E31-R3: one units prompt instance. It carries the manual import
    /// operation that produced the probe so the apply cannot land over a
    /// newer import; the UUID keeps `.sheet(item:)` identity stable.
    private struct PendingManualMeshImport: Identifiable {
        let id = UUID()
        let probe: MeshImportProbe
        let operation: CADManualImportOperation
    }

    @Environment(\.scenePhase) private var scenePhase
    /// True while this editor is covered by a transient presentation (the
    /// workbench fullscreen cover); its disappearance is not a close.
    @Environment(\.cadWorkbenchTransientlyCovered) private var transientlyCovered
    /// Host-installed selection observer; nil in standalone/qualification
    /// hosts, in which case no context is published.
    @Environment(\.cadSelectionObserver) private var selectionObserver
    @State private var viewModel: EditorViewModel?
    @State private var exportDocument: ExportDocument?
    /// X22 quick mesh exports (STL/3MF/USDZ/DXF) show the model-only notice
    /// before writing when the document actually has a view overlay.
    private enum QuickViewOnlyExport: String {
        case stl = "STL"
        case threeMF = "3MF"
        case usdz = "USDZ"
        case dxf = "DXF"
    }
    @State private var pendingViewOnlyExport: QuickViewOnlyExport?
    @State private var showItemsPanel = false
    /// Canvas result banner (`CADCanvasActionResult`); shown in a safe-area
    /// inset so the toolbar entry always has visible feedback.
    @State private var canvasActionMessage: (kind: CADCanvasActionResult.Kind, text: String)?
    @State private var isCanvasActionRunning = false
    /// Floe workbench tools (assembly / drawings / ShapeScript / mesh) sheet.
    @State private var showWorkbenchTools = false
    /// User-named design versions (E34) sheet.
    @State private var showVersions = false
    /// E31-R3: the units prompt's prepared probe plus the manual import
    /// operation that produced it. The apply runs under that same identity, so
    /// a prompt left open while a newer import runs cannot commit over it (and
    /// a stale probe return cannot replace a newer prompt).
    @State private var pendingMeshImport: PendingManualMeshImport?
    @State private var didHandleDebugImport = false
    /// E31-R2: the one in-flight manual import (probe, exact parse or prompt
    /// apply). A real close/switch cancels it; the services own the join.
    @State private var importTask: Task<Void, Never>?
    @State private var showSettings = false
    /// Measured height of the bottom bar stack, fed by `BottomBarHeightKey`.
    /// The palette and the corner chips inset above it — see `bottomBarInset`.
    @State private var bottomBarHeight: CGFloat = 0
    @State private var bottomControlsFrame: CGRect?
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
    /// Centred editing panels need not shorten a palette beside them. Keep
    /// full clearance only when their actual horizontal bounds intersect.
    private var paletteBottomInset: CGFloat {
        guard let controls = bottomControlsFrame, let palette = paletteFrame else {
            return bottomBarInset
        }
        let overlaps = controls.width > 0 && controls.height > 0
            && controls.minX < palette.maxX && palette.minX < controls.maxX
        return overlaps ? max(12, bottomBarHeight + 16) : 12
    }
    /// Which file the Import menu asked for. There is exactly ONE
    /// `.fileImporter` in this view because stacking several on one view
    /// silently leaves only the LAST one live — the STL and DXF entries did
    /// nothing at all for as long as they had importers ahead of the image
    /// one in the chain (found 2026-08-29 while wiring STEP: "Image from
    /// Files…" presented, the three above it did not).
    private enum ImportRequest: Equatable {
        case stl, dxf, step, iges, mesh, image

        var contentTypes: [UTType] {
            switch self {
            case .stl: [ExportDocument.stlType]
            // STEP and DXF have no system-declared UTI, so these resolve to
            // DYNAMIC types (`dyn.…`) that match no file in the picker.
            // `.data` is what makes the files selectable — the same escape
            // hatch the `.os3d` archive importer already uses.
            case .dxf: [ExportDocument.dxfType, .data]
            case .step: [ExportDocument.stepType, .data]
            // IGES has no system UTI; `.data` makes the file selectable.
            case .iges: [.data]
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
    @State private var showShellOptions = false
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
    /// Part/assembly exchange export with a pre-flight coverage receipt.
    @State private var showAssemblyExportSheet = false

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
            // A RELEASED document (e.g. a successful Cancel already deleted
            // the package through the bridge) must never be written by this
            // late view-lifetime flush. A disappearance caused by a TRANSIENT
            // cover (the workbench fullscreen presentation) is not a close
            // either: the live session is re-adopted on return, so the
            // close-time preview flush must not fire for it. For a REAL close
            // of a live document the flush is safe: the preview-only commit
            // keeps the semantic MODEL identity exact, and the cancel route
            // verifies that identity plus the session's own committed
            // revision before treating the model as untouched.
            guard !document.isClosed, !transientlyCovered else { return }
            viewModel?.saveThumbnail()
            Task { _ = await document.save() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || phase == .inactive {
                guard !document.isClosed else { return }
                viewModel?.saveThumbnail()
                Task { _ = await document.save() }
            }
        }
    }

    /// Sketch-state chip inside the sketch pill. DOF zero alone is not a
    /// success state: report-level conflicts, failed solves and unsupported
    /// relations take precedence over the green confirmation.
    @ViewBuilder
    private func sketchStateChip(_ viewModel: EditorViewModel) -> some View {
        let status = viewModel.sketchDefinitionStatus
        if viewModel.sketchSolveConflict || status?.conflicting == true {
            Text(FloeCADStrings.text("cad.status.constraintsConflict", "Constraints conflict"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.red, in: Capsule())
                .accessibilityIdentifier("SketchConflictChip")
        } else if let status, !status.converged {
            Text(FloeCADStrings.text("cad.status.solveDidNotConverge", "Sketch solve did not converge"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.orange, in: Capsule())
                .accessibilityIdentifier("SketchNonconvergedChip")
        } else if let status, status.unsupportedCount > 0 {
            let key = status.unsupportedCount == 1
                ? "cad.status.oneRelationNotApplied" : "cad.status.relationsNotApplied"
            let message = status.unsupportedCount == 1
                ? FloeCADStrings.text(key, "1 relation not applied")
                : FloeCADStrings.format(key, "%d relations not applied", status.unsupportedCount)
            Text(message)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.orange, in: Capsule())
                .accessibilityIdentifier("SketchUnsupportedChip")
        } else if let status, status.dof > 0 {
            // The remaining structural DOF is part of the sketch's definition
            // state, not an error: show it plainly (native "2 DOF remaining")
            // instead of saying nothing until the sketch happens to be rigid.
            Text(FloeCADStrings.format("cad.status.dofRemaining", "%d DOF remaining", status.dof))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.blue, in: Capsule())
                .accessibilityIdentifier("SketchDOFChip")
                .accessibilityValue(String(status.dof))
        } else if let status, status.fullyDefined {
            Text(FloeCADStrings.text("cad.status.fullyDefined", "Fully defined"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.green, in: Capsule())
                .accessibilityIdentifier("SketchStateChip")
        }
    }

    private func sketchStatusText(_ viewModel: EditorViewModel) -> String {
        if viewModel.isPickingSymmetryAxis {
            return FloeCADStrings.text("cad.status.pickSymmetryAxis",
                                       "Select a line for the axis of symmetry")
        }
        guard let sketch = viewModel.activeSketch else {
            return FloeCADStrings.text("cad.status.sketching", "Sketching")
        }
        if case .sketching(_, let tool) = viewModel.mode {
            switch tool {
            case .text: return FloeCADStrings.text("cad.status.tapToPlaceText", "Tap to place text")
            case .project: return FloeCADStrings.text("cad.status.tapToProject",
                                                      "Tap a body to project its edges")
            case nil:
                if viewModel.sketchTransformActive {
                    return viewModel.selectedSketchEntityIDs.isEmpty
                        ? FloeCADStrings.text("cad.status.selectSketchGeometry",
                                              "Select sketch geometry to move or rotate")
                        : FloeCADStrings.text("cad.status.dragOrExactValue",
                                              "Drag an arrow or tap for an exact value")
                }
                return FloeCADStrings.text("cad.status.dragToOrbit", "Drag to orbit — pick a tool to draw")
            default: break
            }
        }
        return sketch.plane.isCoincident(with: .ground)
            ? FloeCADStrings.text("cad.status.sketchingOnGround", "Sketching on ground plane")
            : FloeCADStrings.text("cad.status.sketchingOnPlane", "Sketching on plane")
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

    @ViewBuilder
    private func sketchDetailActions(_ viewModel: EditorViewModel) -> some View {
        sketchStateChip(viewModel).fixedSize(horizontal: true, vertical: false)
        if viewModel.lookAtSketchAvailable {
            Button("Look at Sketch") { viewModel.lookAtSketch() }
                .controlSize(.small)
                .accessibilityIdentifier("LookAtSketch")
        }
        if viewModel.isPickingSymmetryAxis {
            Button("Cancel Symmetry") { viewModel.cancelSymmetryAxisPick() }
                .accessibilityIdentifier("CancelSymmetry")
        }
    }

    private func sketchStatusPill(_ viewModel: EditorViewModel) -> some View {
        ViewThatFits(in: .horizontal) {
            statusPill(icon: "pencil.and.outline", text: sketchStatusText(viewModel)) {
                sketchDetailActions(viewModel)
                Button("Exit Sketching") { viewModel.finishSketch() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityIdentifier("ExitSketchingButton")
            }
            .fixedSize(horizontal: true, vertical: false)

            // Keep Exit visible at narrow widths and large text sizes. Status
            // and optional actions can scroll horizontally instead of forcing
            // every word into a tall capsule over the editable geometry.
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Label(sketchStatusText(viewModel), systemImage: "pencil.and.outline")
                        .font(.caption)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { viewModel.finishSketch() } label: {
                        Label("Exit Sketching", systemImage: "checkmark")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityIdentifier("ExitSketchingButton")
                }
                ScrollView(.horizontal) {
                    HStack(spacing: 12) { sketchDetailActions(viewModel) }
                        .fixedSize(horizontal: true, vertical: false)
                }
                .scrollIndicators(.hidden)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            .padding(.top, 8)
        }
        .padding(.horizontal, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("SketchStatusPill")
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
                // X22: a measurement becomes document data only when saved;
                // the pill itself stays a transient readout.
                Button(FloeCADStrings.text("cad.measure.saveAnnotation",
                                           "Save Annotation")) {
                    viewModel.saveMeasurementAnnotation()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("MeasureSaveAnnotation")
            } else {
                Text(viewModel.measurePoints.isEmpty
                    ? FloeCADStrings.text("cad.status.measureFirstPoint", "Tap two points to measure")
                    : FloeCADStrings.text("cad.status.measureSecondPoint", "Tap the second point"))
                    .font(.subheadline)
            }
            Button(FloeCADStrings.text("cad.ui.common.done", "Done")) {
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
    @ViewBuilder
    private func blendBar(_ kind: BlendKind, _ viewModel: EditorViewModel) -> some View {
        if horizontalSizeClass == .compact { compactBlendBar(kind, viewModel) }
        else { regularBlendBar(kind, viewModel) }
    }

    private func compactBlendBar(_ kind: BlendKind, _ viewModel: EditorViewModel) -> some View {
        AdaptiveBar(style: .capsule, spacing: 10) {
            blendModeMenu(kind, viewModel)
            if let failure = viewModel.blendPreviewFailure, !viewModel.blendSelectedEdges.isEmpty {
                Text(failure).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("BlendFailureHint")
            } else {
                Label(viewModel.blendSelectedEdges.isEmpty
                    ? FloeCADStrings.text("cad.blend.pickEdges", "Tap edges")
                    : String(format: FloeCADStrings.text("cad.blend.edgeCount", "%ld edges"), viewModel.blendSelectedEdges.count),
                    systemImage: kind == .chamfer ? "square.on.circle" : "circle.circle")
                    .font(.caption).foregroundStyle(.barLabel)
            }
            if let advanced = viewModel.blendAdvancedMode {
                HStack(alignment: .top, spacing: 12) {
                    blendValueControl(advanced == .variableFillet
                        ? FloeCADStrings.text("cad.blend.endRadius", "End radius")
                        : FloeCADStrings.text("cad.blend.short.firstDistance", "Distance 1"),
                        value: Binding(get: { viewModel.blendValue }, set: { viewModel.blendValue = max(0, $0) }),
                        kind: .length, identifier: "BlendValueField")
                    blendValueControl(advanced == .variableFillet
                        ? FloeCADStrings.text("cad.blend.middleRadius", "Middle radius")
                        : advanced == .distanceAngleChamfer ? FloeCADStrings.text("cad.feature.angle", "Angle")
                        : FloeCADStrings.text("cad.blend.short.secondDistance", "Distance 2"),
                        value: Binding(get: { viewModel.blendSecondValue }, set: { viewModel.blendSecondValue = $0 }),
                        kind: advanced == .distanceAngleChamfer ? .plain : .length,
                        identifier: "BlendSecondValueField")
                }
                if !advanced.isFillet {
                    Toggle(isOn: Binding(get: { viewModel.blendSwapSupport }, set: { viewModel.blendSwapSupport = $0 })) {
                        Label(FloeCADStrings.text("cad.blend.swapSides", "Swap sides"), systemImage: "arrow.left.arrow.right")
                    }
                    .toggleStyle(.button).labelStyle(.iconOnly)
                    .accessibilityLabel(FloeCADStrings.text("cad.blend.swapSides", "Swap sides"))
                    .accessibilityIdentifier("BlendSwapSides")
                }
            } else {
                blendValueControl(kind.valueLabel,
                    value: Binding(get: { viewModel.blendValue }, set: { viewModel.blendValue = max(0, $0) }),
                    kind: .length, identifier: "BlendValueField")
            }
        } actions: {
            Button("Cancel") { viewModel.cancelBlend() }
                .keyboardShortcut(.cancelAction).accessibilityIdentifier("BlendCancel")
            Button("Apply") { viewModel.commitBlend() }
                .buttonStyle(.borderedProminent).disabled(!viewModel.canCommitBlend)
                .accessibilityIdentifier("BlendApply")
        }
    }

    private func blendValueControl(_ label: String, value: Binding<Double>,
                                   kind: ExpressionValueField.Kind, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.barLabel)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                ExpressionValueField(placeholder: kind == .plain ? "°" : settings.unit.symbol,
                    value: value, kind: kind, clamp: nil, identifier: identifier)
                    .accessibilityLabel("\(label), \(kind == .plain ? "°" : settings.unit.symbol)")
                Text(kind == .plain ? "°" : settings.unit.symbol).font(.caption).foregroundStyle(.barLabel)
            }
        }
    }

    private func regularBlendBar(_ kind: BlendKind, _ viewModel: EditorViewModel) -> some View {
        AdaptiveBar(style: .capsule, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                blendModeMenu(kind, viewModel)
                if let failure = viewModel.blendPreviewFailure, !viewModel.blendSelectedEdges.isEmpty {
                    Text(failure).font(.caption).foregroundStyle(.orange).lineLimit(2)
                        .accessibilityIdentifier("BlendFailureHint")
                } else {
                    Text(viewModel.blendSelectedEdges.isEmpty
                        ? FloeCADStrings.text("cad.blend.pickEdges", "Tap edges")
                        : String(format: FloeCADStrings.text("cad.blend.edgeCount", "%ld edges"), viewModel.blendSelectedEdges.count))
                        .font(.caption).foregroundStyle(.barLabel)
                }
            }
            blendValueControl(viewModel.blendAdvancedMode == .variableFillet
                ? FloeCADStrings.text("cad.blend.endRadius", "End radius") : kind.valueLabel,
                value: Binding(get: { viewModel.blendValue }, set: { viewModel.blendValue = max(0, $0) }),
                kind: .length, identifier: "BlendValueField")
            if let advanced = viewModel.blendAdvancedMode {
                blendValueControl(advanced == .variableFillet
                    ? FloeCADStrings.text("cad.blend.middleRadius", "Middle radius")
                    : advanced == .distanceAngleChamfer ? FloeCADStrings.text("cad.feature.angle", "Angle")
                    : FloeCADStrings.text("cad.blend.secondDistance", "Second distance"),
                    value: Binding(get: { viewModel.blendSecondValue }, set: { viewModel.blendSecondValue = $0 }),
                    kind: advanced == .distanceAngleChamfer ? .plain : .length,
                    identifier: "BlendSecondValueField")
                if !advanced.isFillet {
                    Toggle(isOn: Binding(get: { viewModel.blendSwapSupport }, set: { viewModel.blendSwapSupport = $0 })) {
                        Label(FloeCADStrings.text("cad.blend.swapSides", "Swap sides"), systemImage: "arrow.left.arrow.right")
                    }
                    .toggleStyle(.button).labelStyle(.iconOnly)
                    .accessibilityLabel(FloeCADStrings.text("cad.blend.swapSides", "Swap sides"))
                    .accessibilityIdentifier("BlendSwapSides")
                }
            }
            if let cap = viewModel.blendDragMax {
                Text("max \(settings.unit.display(fromMM: cap), format: .number.precision(.fractionLength(0...1)))")
                    .font(.caption).foregroundStyle(.barLabel).fixedSize()
                    .accessibilityIdentifier("BlendMaxHint")
            }
            Spacer(minLength: 0)
        } actions: {
            Button("Cancel") { viewModel.cancelBlend() }
                .keyboardShortcut(.cancelAction).accessibilityIdentifier("BlendCancel")
            Button("Apply") { viewModel.commitBlend() }
                .buttonStyle(.borderedProminent).disabled(!viewModel.canCommitBlend)
                .accessibilityIdentifier("BlendApply")
        }
    }

    private func blendModeMenu(_ kind: BlendKind, _ viewModel: EditorViewModel) -> some View {
        Menu {
            Picker(FloeCADStrings.text("cad.blend.uniform", "Uniform"), selection: Binding<AdvancedBlendDefinition.Mode?>(
                get: { viewModel.blendAdvancedMode }, set: { viewModel.setBlendAdvancedMode($0) })) {
                Text(FloeCADStrings.text("cad.blend.uniform", "Uniform")).tag(nil as AdvancedBlendDefinition.Mode?)
                if kind == .fillet {
                    Text(FloeCADStrings.text("cad.blend.variableFillet", "Variable Fillet"))
                        .tag(AdvancedBlendDefinition.Mode.variableFillet as AdvancedBlendDefinition.Mode?)
                } else {
                    Text(FloeCADStrings.text("cad.blend.twoDistances", "Two-Distance Chamfer"))
                        .tag(AdvancedBlendDefinition.Mode.twoDistanceChamfer as AdvancedBlendDefinition.Mode?)
                    Text(FloeCADStrings.text("cad.blend.distanceAngle", "Distance-Angle Chamfer"))
                        .tag(AdvancedBlendDefinition.Mode.distanceAngleChamfer as AdvancedBlendDefinition.Mode?)
                }
            }
        } label: {
            let label: String = switch viewModel.blendAdvancedMode {
            case .variableFillet: FloeCADStrings.text("cad.blend.variableFillet", "Variable Fillet")
            case .twoDistanceChamfer: FloeCADStrings.text("cad.blend.twoDistances", "Two-Distance Chamfer")
            case .distanceAngleChamfer: FloeCADStrings.text("cad.blend.distanceAngle", "Distance-Angle Chamfer")
            case nil: FloeCADStrings.text("cad.blend.uniform", "Uniform")
            }
            let compactLabel: String = switch viewModel.blendAdvancedMode {
            case .variableFillet: FloeCADStrings.text("cad.blend.short.variable", "Variable")
            case .twoDistanceChamfer: FloeCADStrings.text("cad.blend.short.twoDistances", "Two distances")
            case .distanceAngleChamfer: FloeCADStrings.text("cad.blend.short.distanceAngle", "Distance + angle")
            case nil: label
            }
            Label(horizontalSizeClass == .compact ? compactLabel : label, systemImage: "slider.horizontal.3")
                .fixedSize(horizontal: false, vertical: true)
        }
        .controlSize(.small).accessibilityIdentifier("BlendModeMenu")
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
                .fixedSize(horizontal: horizontalSizeClass != .compact, vertical: true)
            if viewModel.replaceSourceFace != nil {
                if horizontalSizeClass != .compact { Divider().frame(height: 20) }
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
                .fixedSize(horizontal: horizontalSizeClass != .compact, vertical: true)
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
            Button {
                showShellOptions = true
            } label: {
                Label(FloeCADStrings.text("cad.shell.wallOptions", "Wall thicknesses"), systemImage: "slider.horizontal.3")
            }
            .accessibilityIdentifier("ShellWallOptions")
            .sheet(isPresented: $showShellOptions) { ShellOptionsSheet(viewModel: viewModel) }
            Text(viewModel.shellBodyID == nil
                 ? "Tap a body to shell"
                 : viewModel.shellSelectedFaces.isEmpty
                    ? "Tap faces to open (or Apply for a closed hollow)"
                    : "\(viewModel.shellSelectedFaces.count) face\(viewModel.shellSelectedFaces.count == 1 ? "" : "s") open")
                .font(.subheadline)
                .fixedSize(horizontal: horizontalSizeClass != .compact, vertical: true)
            if viewModel.shellPickingRegions {
                Text(FloeCADStrings.text("cad.shell.pickWall", "Tap walls to set thickness"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if horizontalSizeClass != .compact { Divider().frame(height: 20) }
            HStack(spacing: 6) {
                Text("Thickness").font(.caption).foregroundStyle(.barLabel).fixedSize(horizontal: horizontalSizeClass != .compact, vertical: true)
                ExpressionValueField(placeholder: settings.unit.symbol, value: value,
                                     clamp: nil, identifier: "ShellThicknessField")
                Text(settings.unit.symbol).font(.caption).foregroundStyle(.barLabel).fixedSize(horizontal: horizontalSizeClass != .compact, vertical: true)
            }
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
                .fixedSize(horizontal: horizontalSizeClass != .compact, vertical: true)
            if horizontalSizeClass != .compact { Divider().frame(height: 20) }
            HStack(spacing: 6) {
                Text("Length").font(.caption).foregroundStyle(.barLabel).fixedSize(horizontal: horizontalSizeClass != .compact, vertical: true)
                TextField(settings.unit.symbol, value: value,
                          format: .number.precision(.fractionLength(0...3)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.decimalPad)
                    .accessibilityIdentifier("AxisLengthField")
                Text(settings.unit.symbol).font(.caption).foregroundStyle(.barLabel).fixedSize(horizontal: horizontalSizeClass != .compact, vertical: true)
            }
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

    private func sketchCurveEditBar(_ viewModel: EditorViewModel) -> some View {
        AdaptiveBar(style: .capsule, spacing: 12) {
            Picker(FloeCADStrings.text("cad.sketch.curve.operation", "Operation"), selection: Binding(
                get: { viewModel.sketchCurveEditKind }, set: { viewModel.sketchCurveEditKind = $0 })) {
                Text(FloeCADStrings.text("cad.sketch.curve.trim", "Trim")).tag(SketchCurveEditKind.trim)
                Text(FloeCADStrings.text("cad.sketch.curve.extend", "Extend")).tag(SketchCurveEditKind.extend)
            }.pickerStyle(.segmented).fixedSize(horizontal: horizontalSizeClass != .compact, vertical: true).accessibilityIdentifier("SketchCurveOperation")
            Picker(FloeCADStrings.text("cad.sketch.curve.boundary", "Boundary"), selection: Binding(
                get: { viewModel.sketchCurveBoundaryID }, set: { viewModel.sketchCurveBoundaryID = $0 })) {
                Text(FloeCADStrings.text("cad.sketch.curve.chooseBoundary", "Choose the boundary first.")).tag(Optional<UUID>.none)
                ForEach(viewModel.sketchCurveBoundaryChoices) { choice in Text(choice.title).tag(Optional(choice.id)) }
            }.accessibilityIdentifier("SketchCurveBoundary")
            Text(FloeCADStrings.text("cad.sketch.curve.pickTarget", "Tap the part to remove or the endpoint to extend"))
                .font(.caption).foregroundStyle(.barLabel)
        } actions: {
            Button(FloeCADStrings.text("cad.sketch.curve.done", "Done")) { viewModel.cancelSketchCurveEdit() }
                .buttonStyle(.bordered).controlSize(.small).accessibilityIdentifier("SketchCurveDone")
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
                .fixedSize(horizontal: horizontalSizeClass != .compact, vertical: true)
            if viewModel.sketchOffsetUsesLinkedCurve {
                Text(FloeCADStrings.text("cad.sketch.curve.linkedOffset", "Linked offset")).font(.caption)
            }
            if horizontalSizeClass != .compact { Divider().frame(height: 20) }
            Picker("Type", selection: Binding(
                get: { viewModel.sketchOffsetType },
                set: { viewModel.sketchOffsetType = $0 }
            )) {
                ForEach(SketchOffsetType.allCases, id: \.self) { type in
                    Text(type.title).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize(horizontal: horizontalSizeClass != .compact, vertical: true)
            .accessibilityIdentifier("SketchOffsetType")
            HStack(spacing: 6) {
                Text("Distance").font(.caption).foregroundStyle(.barLabel).fixedSize(horizontal: horizontalSizeClass != .compact, vertical: true)
                TextField(settings.unit.symbol, value: value,
                          format: .number.precision(.fractionLength(0...3)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numbersAndPunctuation)
                    .accessibilityIdentifier("SketchOffsetDistanceField")
                Text(settings.unit.symbol).font(.caption).foregroundStyle(.barLabel).fixedSize(horizontal: horizontalSizeClass != .compact, vertical: true)
            }
        } actions: {
            if viewModel.sketchOffsetSelectedLinkID != nil {
                Button(FloeCADStrings.text("cad.sketch.curve.makeIndependent", "Make independent")) { viewModel.unlinkSelectedSketchOffset() }
                    .buttonStyle(.bordered).controlSize(.small).accessibilityIdentifier("SketchOffsetUnlink")
            }
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
    /// items named "<body>.<ext>" (duplicate names gain the body's short UUID);
    /// nil (with a user-facing error) on failure.
    private func perBodyExportItems(
        _ payloads: [(name: String, bodyID: UUID, data: Data)]?,
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
            // Duplicate body names are a real document case. The receipt keeps
            // each body's actual name + UUID; only the temp filename gets the
            // stable short UUID, so one file can never overwrite another.
            let stems = EditorViewModel.perBodyFileStems(
                namesAndIDs: payloads.map { (name: $0.name, id: $0.bodyID) })
            var items: [ExportFileItem] = []
            for (index, payload) in payloads.enumerated() {
                let url = directory
                    .appendingPathComponent(stems[index])
                    .appendingPathExtension(fileExtension)
                try payload.data.write(to: url)
                items.append(ExportFileItem(url: url))
            }
            return items
        } catch {
            viewModel.errorMessage = "Export failed — please try again."
            return nil
        }
    }

    /// Mesh options sheet confirm (plan §B14). OBJ with materials stages the
    /// exact ZIP preflight the sheet showed; geometry-only OBJ remains a true
    /// .obj with UVs and no MTL. GLB keeps its existing single format.
    private func stageMeshExport(
        _ format: MeshExportFormat, perBody: Bool, includeMaterials: Bool,
        acceptPartial: Bool, reviewedChangeCount: Int,
        viewModel: EditorViewModel
    ) {
        guard reviewedChangeCount == viewModel.session.changeCount else {
            viewModel.errorMessage = FloeCADStrings.text(
                "cad.error.exportChanged", "The document changed. Review the export again.")
            viewModel.clearOBJBundlePlan()
            return
        }
        switch format {
        case .obj where includeMaterials:
            // Consume the exact reviewed bytes. Never rebuild them here.
            guard let plan = viewModel.reviewedOBJBundlePlan(
                perBody: perBody, acceptPartial: acceptPartial,
                expectedChangeCount: reviewedChangeCount) else { return }
            guard !plan.hasRefusal else {
                viewModel.errorMessage = viewModel.objBundleFailureMessage(plan)
                viewModel.clearOBJBundlePlan()
                return
            }
            if perBody {
                guard !plan.items.isEmpty else {
                    viewModel.errorMessage = viewModel.objBundleFailureMessage(plan)
                    viewModel.clearOBJBundlePlan()
                    return
                }
                let payloads = plan.items.compactMap {
                    item -> (name: String, bodyID: UUID, data: Data)? in
                    guard let data = item.result.data,
                          let bodyID = item.bodyID else { return nil }
                    return (item.name, bodyID, data)
                }
                guard payloads.count == plan.items.count else {
                    viewModel.errorMessage = viewModel.objBundleFailureMessage(plan)
                    viewModel.clearOBJBundlePlan()
                    return
                }
                pendingExportItems = perBodyExportItems(
                    payloads, fileExtension: "zip", viewModel: viewModel
                )
            } else if let data = plan.single?.data {
                pendingExport = ExportDocument(
                    data: data, contentType: ExportDocument.zipType, fileExtension: "zip"
                )
            }
            viewModel.clearOBJBundlePlan()
        case .obj:
            viewModel.clearOBJBundlePlan()
            if perBody {
                pendingExportItems = perBodyExportItems(
                    viewModel.exportOBJPerBody(acceptPartial: acceptPartial,
                                               expectedChangeCount: reviewedChangeCount),
                    fileExtension: "obj", viewModel: viewModel
                )
            } else if let data = viewModel.exportOBJ(acceptPartial: acceptPartial,
                                                    expectedChangeCount: reviewedChangeCount) {
                pendingExport = ExportDocument(
                    data: data, contentType: ExportDocument.objType, fileExtension: "obj"
                )
            }
        case .glb:
            if perBody {
                pendingExportItems = perBodyExportItems(
                    viewModel.exportGLBPerBody(acceptPartial: acceptPartial,
                                               expectedChangeCount: reviewedChangeCount),
                    fileExtension: "glb", viewModel: viewModel
                )
            } else if let data = viewModel.exportGLB(acceptPartial: acceptPartial,
                                                    expectedChangeCount: reviewedChangeCount) {
                pendingExport = ExportDocument(
                    data: data, contentType: ExportDocument.glbType, fileExtension: "glb"
                )
            }
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
            // IGES exact exchange (closed solids and open surfaces). Same
            // off-main prepare + atomic commit as STEP; surfaces stay exact
            // open-surface bodies and are never reported as solids.
            Button(FloeCADStrings.label("cad.ui.import.igesFile", "IGES File…")) {
                importRequest = .iges
                showImporter = true
            }
            .accessibilityIdentifier("ImportIGES")
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

    /// X22: only a document with authored view-only content gets the
    /// pre-write notice. An ordinary model keeps the one-tap export.
    private func requestQuickExport(_ choice: QuickViewOnlyExport,
                                    viewModel: EditorViewModel) {
        if viewModel.viewOverlay.hasViewOnlyContent {
            pendingViewOnlyExport = choice
        } else {
            performQuickExport(choice)
        }
    }

    private func performQuickExport(_ choice: QuickViewOnlyExport) {
        guard let viewModel else { return }
        switch choice {
        case .stl:
            if let data = viewModel.exportSTL() {
                exportDocument = ExportDocument(
                    data: data, contentType: ExportDocument.stlType,
                    fileExtension: "stl")
            }
        case .threeMF:
            if let data = viewModel.exportThreeMF() {
                exportDocument = ExportDocument(
                    data: data, contentType: ExportDocument.threeMFType,
                    fileExtension: "3mf")
            }
        case .usdz:
            if let data = viewModel.exportUSDZ() {
                exportDocument = ExportDocument(
                    data: data, contentType: ExportDocument.usdzType,
                    fileExtension: "usdz")
            }
        case .dxf:
            if let data = viewModel.exportDXF() {
                exportDocument = ExportDocument(
                    data: data, contentType: ExportDocument.dxfType,
                    fileExtension: "dxf")
            }
        }
    }

    /// Toolbar Export menu (spec §12, plan §B14): mesh formats, sketch DXF,
    /// screenshot, and — where ModelIO can write USDZ — USDZ + AR Preview.
    private func exportMenu(_ viewModel: EditorViewModel) -> some View {
        Menu {
            Button("STL") {
                requestQuickExport(.stl, viewModel: viewModel)
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
                requestQuickExport(.threeMF, viewModel: viewModel)
            }
            // USDZ only where ModelIO can actually write it
            // (never faked — some simulators can't).
            if USDZExporter.isSupported {
                Button("USDZ") {
                    requestQuickExport(.usdz, viewModel: viewModel)
                }
            }
            // DXF of the active/ground sketch (plan §B14).
            Button("DXF") {
                requestQuickExport(.dxf, viewModel: viewModel)
            }
            // The exact-solid exchange path always previews included/excluded
            // parts before writing; the old STEP shortcut skipped mesh bodies.
            Button(FloeCADStrings.label("cad.ui.export.exchange", "Export Model…")) {
                showAssemblyExportSheet = true
            }
            .accessibilityIdentifier("ExportExchange")
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
    private func viewportChrome(_ viewModel: EditorViewModel) -> AnyView {
        // Bound metadata depth to avoid the device opening crash in 311.
        // These stable stages preserve every modifier and its original order.
        let sketchSurface = AnyView(
        // On a phone the palette covers a sixth of the width: Zoom to Fit
        // frames, and the view centres, in the strip it leaves visible.
        ViewportView(viewModel: viewModel,
                     paletteFrame: horizontalSizeClass == .compact ? paletteFrame : nil,
                     paletteOnRight: settings.paletteOnRight)
            // Stable surface identity for the native face-picker route. This
            // is an identifier only; the Metal view and its gestures are
            // unchanged.
            .accessibilityIdentifier("CADEditorViewport")
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
        )
        let gizmoSurface = AnyView(sketchSurface
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
                    if viewModel.sculptEditingBody != nil {
                        CADSculptHUD(viewModel:viewModel)
                    } else {
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
                    } else if viewModel.mode.sketchTool == .trim {
                        sketchCurveEditBar(viewModel)
                    } else if viewModel.mode.sketchTool == .offset {
                        sketchOffsetBar(viewModel)
                    } else {
                        NumericInputBar(viewModel: viewModel)
                    }
                    }
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                    bottomControlsFrame = $0
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .measuringBottomBarHeight()
            }
            .onPreferenceChange(BottomBarHeightKey.self) { height in
                bottomBarHeight = height
            }
        )
        let panelSurface = AnyView(gizmoSurface
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
                    // Use the full side height beside centred panels. Wide
                    // input bars still reserve their measured overlap so the
                    // last tools remain tappable in compact layouts.
                    .padding(.top, 8)
                    .padding(.bottom, paletteBottomInset)
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
                    .tint(viewModel.gizmoRepositionArmed ? Color.accentColor : nil)
                    .accessibilityIdentifier("RepositionBadge")
                    Button {
                        viewModel.copyOnDrag.toggle()
                    } label: {
                        Label("Copy", systemImage: "plus.square.on.square")
                            .font(.subheadline.weight(.semibold))
                    }
                    .tint(viewModel.copyOnDrag ? Color.accentColor : nil)
                    .accessibilityAddTraits(viewModel.copyOnDrag ? .isSelected : [])
                    .accessibilityIdentifier("CopyBadge")
                  }
                    .modifier(CADAccessoryControls())
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
                        Button { viewModel.sketchTransformActive.toggle() } label: {
                            Label(viewModel.sketchTransformActive ? "Done" : "Move/Rotate",
                                  systemImage: "arrow.up.left.and.arrow.down.right")
                        }
                        .accessibilityIdentifier("SketchTransformMode")
                    }
                    Button {
                        if viewModel.usesExplicitSketchTransform { viewModel.sketchTransformActive = true }
                        viewModel.sketchCopyOnDrag.toggle()
                    } label: {
                        Label("Copy", systemImage: "plus.square.on.square")
                            .font(.subheadline.weight(.semibold))
                    }
                    .tint(viewModel.sketchCopyOnDrag ? Color.accentColor : nil)
                    .accessibilityAddTraits(viewModel.sketchCopyOnDrag ? .isSelected : [])
                    .accessibilityIdentifier("SketchCopyBadge")
                    .disabled(viewModel.selectedSketchEntityIDs.isEmpty)
                    }
                    .modifier(CADAccessoryControls())
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
                    .modifier(CADAccessoryControls())
                    .padding(.trailing, 16)
                    .padding(.bottom, bottomBarInset)
                }
            }
        )
        let statusSurface = AnyView(panelSurface
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
                        sketchStatusPill(viewModel)
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
        )
        let noticeSurface = AnyView(statusSurface
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
        )
        let toolbarSurface = AnyView(noticeSurface
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if horizontalSizeClass != .compact {
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
                        } else if viewModel.viewOverlay.section != nil {
                            Button(FloeCADStrings.text(
                                "cad.overlay.section.show", "Show Section")) {
                                viewModel.setSectionEnabled(true)
                            }
                            Button("Section Off") {
                                viewModel.endSection()
                            }
                        } else {
                            Button("Section") {
                                viewModel.beginSectionPlanePick()
                            }
                        }
                        if viewModel.hasMeasurementAnnotations {
                            Toggle(FloeCADStrings.text(
                                "cad.overlay.measurements.toggle", "Show guides"),
                                   isOn: Binding(
                                    get: { viewModel.showsMeasurementGuides },
                                    set: { viewModel.setMeasurementGuidesVisible($0) }))
                                .accessibilityIdentifier("CADMeasurementGuidesToggle")
                        }
                    } label: {
                        Label("Views", systemImage: "square.stack.3d.up")
                    }
                    .accessibilityIdentifier("ViewsMenu")

                    Button {
                        viewModel.showHistoryPanel.toggle()
                    } label: {
                        Label(FloeCADStrings.label("cad.toolbar.history", "Feature Tree"),
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
                        showVersions = true
                    } label: {
                        Label(FloeCADStrings.label("cad.toolbar.versions", "Versions"),
                              systemImage: "bookmark")
                    }
                    .accessibilityIdentifier("CADVersionsButton")

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
                        Label("Settings", systemImage: "gearshape")
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("SettingsButton")
                    }
                }
            }
        )
        return AnyView(toolbarSurface
            .sheet(isPresented: $showSettings) {
                CADQuickSettingsSheet()
            }
            .sheet(isPresented: $showWorkbenchTools) {
                CADWorkbenchToolsPanel(document: document, viewModel: viewModel,
                                       canvasActions: canvasActions)
                    .presentationDetents([.medium, .large])
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            }
            .sheet(isPresented: $showVersions) {
                CADVersionsPanelView(document: document)
                    .presentationDetents([.medium, .large])
            }
        )
    }

    /// Compact-width toolbar: the CAD tools entry stays a DIRECT 44pt button
    /// (reachable by test and thumb) and every other action lives in one
    /// explicit overflow menu — no action is silently dropped by bar overflow.
    @ViewBuilder
    private func compactToolbarItems(_ viewModel: EditorViewModel) -> some View {
        Button {
            showWorkbenchTools = true
        } label: {
            ZStack {
                Color.clear
                Image(systemName: "square.grid.2x2")
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("CAD Tools")
        }
        .accessibilityIdentifier("CADWorkbenchToolsButton")

        Menu {
            Button {
                viewModel.fitView()
            } label: {
                Label("Fit View", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            Button {
                showSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .accessibilityIdentifier("CADCompactSettingsButton")
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
                    Label("Display: \(viewModel.displayMode.displayLabel)",
                          systemImage: "cube.transparent")
                }
                Toggle("Ground Shadow", isOn: Binding(
                    get: { viewModel.groundShadowEnabled },
                    set: { viewModel.groundShadowEnabled = $0 }
                ))
                if viewModel.isIsolateActive {
                    Button("Exit Isolate") { viewModel.exitIsolate() }
                } else {
                    Button("Isolate") { viewModel.enterIsolate() }
                        .disabled(viewModel.selection.isEmpty)
                }
                if viewModel.sectionState != nil {
                    Button("Flip Section") { viewModel.flipSection() }
                    Button("Section Off") { viewModel.endSection() }
                } else if viewModel.viewOverlay.section != nil {
                    Button(FloeCADStrings.text(
                        "cad.overlay.section.show", "Show Section")) {
                        viewModel.setSectionEnabled(true)
                    }
                    Button("Section Off") { viewModel.endSection() }
                } else {
                    Button("Section") { viewModel.beginSectionPlanePick() }
                }
                if viewModel.hasMeasurementAnnotations {
                    Toggle(FloeCADStrings.text(
                        "cad.overlay.measurements.toggle", "Show guides"),
                           isOn: Binding(
                            get: { viewModel.showsMeasurementGuides },
                            set: { viewModel.setMeasurementGuidesVisible($0) }))
                        .accessibilityIdentifier("CADMeasurementGuidesToggle")
                }
            } label: {
                Label("Views", systemImage: "square.stack.3d.up")
            }
            Button {
                viewModel.showHistoryPanel.toggle()
            } label: {
                Label(FloeCADStrings.label("cad.toolbar.history", "Feature Tree"),
                      systemImage: "clock.arrow.circlepath")
            }
            Button {
                showVersions = true
            } label: {
                Label(FloeCADStrings.label("cad.toolbar.versions", "Versions"),
                      systemImage: "bookmark")
            }
            .accessibilityIdentifier("CADVersionsButton")
            Button {
                viewModel.showVariablesPanel.toggle()
            } label: {
                Label(FloeCADStrings.label("cad.toolbar.variables", "Variables"),
                      systemImage: "function")
            }
            Button {
                showItemsPanel.toggle()
            } label: {
                Label(FloeCADStrings.label("cad.toolbar.items", "Items"),
                      systemImage: "sidebar.trailing")
            }
            importMenu(viewModel)
            exportMenu(viewModel)
            if let actions = canvasActions, actions.applyToCanvas != nil {
                Button {
                    runCanvasAction(actions.applyToCanvas)
                } label: {
                    Label(FloeCADStrings.label("cad.canvas.apply", "Apply to canvas"),
                          systemImage: "rectangle.on.rectangle.angled")
                }
                .disabled(isCanvasActionRunning)
            }
            if let actions = canvasActions, actions.makeVariant != nil {
                Button {
                    runCanvasAction(actions.makeVariant)
                } label: {
                    Label(FloeCADStrings.label("cad.canvas.variant", "Make variant"),
                          systemImage: "plus.square.on.square")
                }
                .disabled(isCanvasActionRunning)
            }
            Button {
                viewModel.openCommandSearch()
            } label: {
                Label("Command Search", systemImage: "magnifyingglass")
            }
        } label: {
            ZStack {
                Color.clear
                Image(systemName: "ellipsis.circle")
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("More")
        }
        .accessibilityIdentifier("CADCompactMoreMenu")
    }

    /// In-content compact control strip (iPhone): undo/redo, the CAD tools
    /// entry and the explicit action menu, each a 44pt target. The navigation
    /// bar's automatic overflow is never relied on for these.
    @ViewBuilder
    private func compactControlStrip(_ viewModel: EditorViewModel) -> some View {
        HStack(spacing: 4) {
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

            Spacer(minLength: 0)

            compactToolbarItems(viewModel)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    /// The one Import-menu completion handler; `importRequest` says which
    /// entry opened the picker. Every kind shares the same OFF-MAIN read and
    /// keeps its own feature semantics once the bytes are in hand.
    private func handleImport(
        _ result: Result<[URL], Error>, viewModel: EditorViewModel
    ) {
        guard case .success(let urls) = result, !urls.isEmpty else {
            viewModel.errorMessage = "Import failed — please try again."
            return
        }
        if importRequest == .mesh {
            beginMeshGroupImport(urls: urls, viewModel: viewModel)
        } else if urls.count == 1, let url = urls.first {
            beginImport(from: url, request: importRequest, viewModel: viewModel)
        } else {
            viewModel.errorMessage = FloeCADStrings.text("cad.import.oneSource", "Select one source file for this import.")
        }
    }

    private func beginMeshGroupImport(urls: [URL], viewModel: EditorViewModel) {
        importTask?.cancel()
        importTask = Task { @MainActor in
            let operation = viewModel.beginManualImportOperation()
            defer { viewModel.endManualImportOperation(operation) }
            let result = await CADImportSourceReader.readGroup(urls: urls)
            guard !Task.isCancelled, viewModel.isCurrentManualImport(operation) else { return }
            switch result {
            case .failure(.cancelled): return
            case .failure(.unreadable(let detail)):
                viewModel.errorMessage = FloeCADStrings.format("cad.import.groupReadFailed", "Couldn't read the file group: %@", detail)
            case .success(let group):
                if let prepared = await viewModel.probeMeshOffMainWithOperation(
                    data: group.primary.data, fileName: group.primary.fileName, siblings: group.resources) {
                    pendingMeshImport = PendingManualMeshImport(probe: prepared.probe, operation: prepared.operation)
                }
            }
        }
    }

    /// E31-R3: the user-selected source is prepared on the Workbench's owned
    /// Task, OFF the MainActor. `CADImportSourceReader` opens and closes the
    /// security-scoped lease on the worker that reads, so the lease is held for
    /// exactly the read and is never closed underneath it; the bytes are copied
    /// while it is open, so no later step reuses the URL. A cancelled read is
    /// joined and then dropped: no parse, no unit prompt and no commit follows.
    ///
    /// The picker selection is the user's own import action, not a model/tool
    /// grant: nothing here widens file access for an agent path.
    private func beginImport(from url: URL, request: ImportRequest,
                             viewModel: EditorViewModel) {
        importTask?.cancel()
        importTask = Task { @MainActor in
            let operation = viewModel.beginManualImportOperation()
            defer { viewModel.endManualImportOperation(operation) }
            let outcome = await CADImportSourceReader.read(url: url)
            guard !Task.isCancelled, viewModel.isCurrentManualImport(operation) else {
                return
            }
            switch outcome {
            case .failure(let error):
                guard !error.isCancellation else { return }
                // Keep the image wording the image importer had before these
                // entries were merged — "file" would be a small step backwards
                // for that entry.
                viewModel.errorMessage = request == .image
                    ? "Couldn't read the selected image."
                    : "Couldn't read the selected file."
            case .success(let source):
                switch request {
                case .stl, .mesh:
                    // Mesh formats go through the units prompt (Shapr3D
                    // parity). The probe parses OFF the MainActor under the
                    // shared budget and the prompt applies the SAME parsed
                    // parts, never a second parse.
                    if let prepared = await viewModel.probeMeshOffMainWithOperation(
                        data: source.data, fileName: source.fileName) {
                        pendingMeshImport = PendingManualMeshImport(
                            probe: prepared.probe, operation: prepared.operation)
                    }
                case .dxf:
                    viewModel.importDXF(data: source.data, fileName: source.fileName)
                case .step:
                    _ = await viewModel.importExactOffMain(
                        data: source.data, fileName: source.fileName, format: "step")
                case .iges:
                    _ = await viewModel.importExactOffMain(
                        data: source.data, fileName: source.fileName, format: "iges")
                case .image:
                    viewModel.beginInsertImage(data: source.data)
                }
            }
        }
    }

    /// The exact request for a DEBUG fixture path (`nil` for a non-exact path,
    /// which the previous triggers ignored).
    private func exactRequest(forPath path: String) -> ImportRequest? {
        switch (path as NSString).pathExtension.lowercased() {
        case "step", "stp": return .step
        case "iges", "igs": return .iges
        default: return nil
        }
    }

    private func editorContent(_ viewModel: EditorViewModel) -> AnyView {
        // Bound metadata depth to avoid the device opening crash in 311.
        // These stable stages preserve every modifier and its original order.
        let importedSurface = AnyView(
        viewportChrome(viewModel)
            // Compact widths get an IN-CONTENT control strip: the system
            // navigation bar collapses whole toolbar groups into an
            // unlabelled overflow on an iPhone, so the essential controls
            // (undo/redo, CAD tools, the explicit action menu) live in the
            // content where they are always visible and tappable at 44pt.
            .safeAreaInset(edge: .top, spacing: 0) {
                if horizontalSizeClass == .compact {
                    compactControlStrip(viewModel)
                }
            }
            .safeAreaInset(edge: .bottom) { canvasActionStatusBar }
            // ONE importer for every Import-menu entry (see `ImportRequest`).
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: importRequest == .mesh ? [.data] : importRequest.contentTypes,
                allowsMultipleSelection: importRequest == .mesh
            ) { result in
                handleImport(result, viewModel: viewModel)
            }
            .sheet(item: $pendingMeshImport) { pending in
                MeshUnitPromptSheet(probe: pending.probe) { unit in
                    // The scale copy runs on a worker; `importParts` is the
                    // MainActor body commit. No source bytes are reopened, and
                    // the apply runs under the SAME manual import operation
                    // that produced this probe, so a newer import cannot be
                    // overwritten by an old prompt.
                    guard viewModel.isCurrentManualImport(pending.operation) else { return }
                    importTask?.cancel()
                    importTask = Task { @MainActor in
                        await viewModel.importMeshProbe(pending.probe, unit: unit,
                                                        operation: pending.operation)
                    }
                }
            }
            .onAppear {
                // DEBUG hooks for the UI suite: the system file picker can't
                // be driven by XCUITest. MESH opens the real units prompt;
                // EXACT drives the same manual STEP/IGES path the menu uses.
                #if DEBUG
                guard !didHandleDebugImport else { return }
                didHandleDebugImport = true
                if let path = CADDebugFixtures.consumePendingManualImportPath(),
                   let request = exactRequest(forPath: path) {
                    // The real Workbench consumes the same prepared-read path
                    // the Import menu uses (no MainActor file read here).
                    beginImport(from: URL(fileURLWithPath: path), request: request,
                                viewModel: viewModel)
                    return
                }
                let environment = ProcessInfo.processInfo.environment
                if let path = environment["OS3D_DEBUG_IMPORT_MESH"] {
                    beginImport(from: URL(fileURLWithPath: path), request: .stl,
                                viewModel: viewModel)
                } else if let path = environment["OS3D_DEBUG_IMPORT_EXACT"],
                          let request = exactRequest(forPath: path) {
                    beginImport(from: URL(fileURLWithPath: path), request: request,
                                viewModel: viewModel)
                }
                #endif
            }
            .onDisappear {
                // A real close/switch (not the workbench's transient cover)
                // cancels the owned import and fences its manual-import
                // identity; the service joins its worker, the read keeps its
                // lease until it finishes, and a late read/probe/error/commit
                // cannot touch the newly presented surface.
                if !transientlyCovered {
                    viewModel.fenceManualImportOperations()
                    importTask?.cancel()
                    importTask = nil
                }
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
        )
        let selectedSurface = AnyView(importedSurface
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
                ScreenshotOptionsSheet(
                    numericTextNotice: viewModel.viewOverlay.visibleMeasurements.isEmpty
                        ? nil
                        : FloeCADStrings.text(
                            "cad.ui.export.numericTextNotice",
                            "Measurement lines are included. Numeric values are not drawn into the image; they remain in the overlay list.")
                ) { width, height, transparent, showGrid in
                    pendingScreenshot = viewModel.captureScreenshot(
                        width: width,
                        height: height,
                        transparentBackground: transparent,
                        showGrid: showGrid
                    )
                }
            }
            .sheet(
                isPresented: $showAssemblyExportSheet,
                onDismiss: {
                    if let staged = pendingExport {
                        pendingExport = nil
                        exportDocument = staged
                    }
                }
            ) {
                CADAssemblyExportSheet(document: document) { staged in
                    pendingExport = staged
                }
            }
            .sheet(
                item: $meshExportFormat,
                onDismiss: {
                    viewModel.clearOBJBundlePlan()
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
                MeshExportOptionsSheet(
                    formatName: format.rawValue,
                    supportsMaterials: format == .obj,
                    preflight: { perBody, acceptPartial, count in
                        await viewModel.objBundlePreflight(
                            perBody: perBody, acceptPartial: acceptPartial,
                            expectedChangeCount: count)
                    },
                    currentChangeCount: { viewModel.session.changeCount },
                    coverageForFormat: { viewModel.meshExportCoverage(format: $0) },
                    viewOnlyNotice: viewModel.viewOverlay.hasViewOnlyContent
                        ? FloeCADStrings.text(
                            "cad.ui.export.viewOnlyNotice",
                            "This file stores model geometry only; the section cut and measurement guides are not included.")
                        : nil,
                    message: { diagnostic in
                        viewModel.objBundleMessage(for: diagnostic)
                    },
                    onExport: { perBody, includeMaterials, acceptPartial, count in
                        stageMeshExport(format, perBody: perBody,
                                        includeMaterials: includeMaterials,
                                        acceptPartial: acceptPartial,
                                        reviewedChangeCount: count,
                                        viewModel: viewModel)
                    })
            }
        )
        let exportedSurface = AnyView(selectedSurface
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
                // The palette's existing Material action now opens the full
                // inspector (face/body targets, textures, mapping, library)
                // on the same document, selection, preview sink and undo
                // path as Present. The legacy three-slider sheet is retired.
                EditorMaterialInspectorSheet(document: document,
                                             viewModel: viewModel) { }
            }
            .sheet(item: Binding(
                get: { viewModel.holeDraft },
                set: { if $0 == nil { viewModel.cancelHole() } }
            )) { draft in
                HoleOptionsSheet(viewModel: viewModel, draft: draft)
            }
            .modifier(CADDatumEditorSheets(viewModel: viewModel))
            .modifier(CADLoftSurfaceEditorSheets(viewModel:viewModel))
            .sheet(isPresented: Binding(
                get: { viewModel.showThreadEditor },
                set: { viewModel.showThreadEditor = $0 }
            )) { ThreadOptionsSheet(document: document, viewModel: viewModel) }
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
        )
        let confirmedSurface = AnyView(exportedSurface
            .confirmationDialog(
                Text(FloeCADStrings.text(
                    "cad.ui.export.viewOnlyTitle",
                    "View-only overlays aren't included")),
                isPresented: Binding(
                    get: { pendingViewOnlyExport != nil },
                    set: { if !$0 { pendingViewOnlyExport = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingViewOnlyExport
            ) { choice in
                Button(FloeCADStrings.text("cad.ui.common.export", "Export")) {
                    pendingViewOnlyExport = nil
                    performQuickExport(choice)
                }
                Button(FloeCADStrings.text("cad.ui.common.cancel", "Cancel"),
                       role: .cancel) {
                    pendingViewOnlyExport = nil
                }
            } message: { choice in
                Text(FloeCADStrings.text(
                    "cad.ui.export.viewOnlyNotice",
                    "This file stores model geometry only; the section cut and measurement guides are not included."))
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
                FloeCADStrings.text("cad.ui.error.title", "Something Went Wrong"),
                isPresented: Binding(
                    get: { viewModel.errorMessage != nil },
                    set: { if !$0 { viewModel.errorMessage = nil } }
                )
            ) {
                Button(FloeCADStrings.text("cad.ui.common.ok", "OK")) { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
        )
        return AnyView(confirmedSurface
            .onChange(of: viewModel.session.lastSaveError) { _, saveError in
                // A failed save means recent work isn't reaching disk — the one
                // storage problem worth an alert mid-session. The document
                // deliberately stays open and dirty (the host bridge keeps the
                // live owner on failure); the message says so and names the
                // retry path instead of implying the work was lost.
                if let saveError {
                    viewModel.errorMessage = FloeCADStrings.format(
                        "cad.ui.save.failedMessage",
                        "Saving failed — recent changes may not be stored. (%@) The document stays open; free storage or fix access, then save again.",
                        saveError)
                }
            }
            .task(id: "\(document.revision)#\(viewModel.assistantSelectionKey)") {
                // Publish the REAL live selection (bodies/faces/edges/sketch/
                // assembly instances) with the package revision. The key
                // excludes expensive mesh/B-rep reads, so this runs only when
                // the selection or document generation actually changes.
                guard let observer = selectionObserver else { return }
                let inputs = viewModel.assistantSelectionInputs
                let context = CADSelectionContext.capture(
                    document: document,
                    bodyIDs: inputs.bodyIDs,
                    facePicks: inputs.facePicks,
                    edgePicks: inputs.edgePicks,
                    sketchID: inputs.sketchID,
                    sketchEntityIDs: inputs.sketchEntityIDs,
                    instanceIDs: inputs.instanceIDs,
                    featureIDs: inputs.featureIDs,
                planeID: inputs.planeID,
                    historyGeneration: inputs.historyGeneration)
                observer.handler(context)
            }
        )
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

/// Keep the datum presenters on the same editor subtree without growing the
/// import/export presentation expression every time a datum form is added.
@MainActor
private struct CADDatumEditorSheets: ViewModifier {
    let viewModel: EditorViewModel

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding<Bool>(
                get: { viewModel.showThreePointPlaneSheet },
                set: { viewModel.showThreePointPlaneSheet = $0 }
            )) {
                ThreePointPlaneSheet(viewModel: viewModel)
            }
            .sheet(isPresented: Binding<Bool>(
                get: { viewModel.showDatumAxisCreateSheet },
                set: { viewModel.showDatumAxisCreateSheet = $0 }
            )) {
                DatumAxisCreateSheet(viewModel: viewModel)
            }
            .sheet(isPresented: Binding<Bool>(
                get: { viewModel.showDatumAxisSheet },
                set: { if !$0 { viewModel.closeDatumAxisSheet() } }
            )) {
                if let id = viewModel.datumAxisSheetID {
                    DatumAxisEditSheet(viewModel: viewModel, axisID: id)
                }
            }
            .sheet(isPresented: Binding<Bool>(
                get: { viewModel.showDatumPointSheet },
                set: { if !$0 { viewModel.closeDatumPointSheet() } }
            )) {
                DatumPointSheet(viewModel: viewModel, pointID: viewModel.datumPointSheetID)
            }
    }
}
