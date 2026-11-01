//
//  CADPresentationWorkbench.swift
//  FloeCADKit
//
//  The workbench's Edit / Present switch and Present chrome.
//
//  Edit is the existing engineering Metal workbench (`FloeCADEditorView`).
//  Present is the RealityKit surface acting on the SAME `FloeCADDocument`
//  value snapshot. Switching never recreates the document, saves, versions or
//  owns a second undo stack; the outer host navigation and split view are
//  untouched.
//
//  Integration point for the host (one line):
//      FloeCADWorkbenchView.body  ->  CADPresentationWorkbenchView(
//          document: document, canvasActions: canvasActions)
//  The host file `Floe/CADWorkbenchView.swift` is core-owned, so this file is
//  the wrapper to hand to the integrating owner.
//

#if canImport(SwiftUI) && canImport(RealityKit) && canImport(UIKit)
import Foundation
import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Mode

enum CADWorkbenchMode: String, CaseIterable, Identifiable {
    case edit
    case present

    var id: String { rawValue }

    var title: String {
        switch self {
        case .edit:
            return FloeCADStrings.text("cad.workbench.edit", "Edit")
        case .present:
            return FloeCADStrings.text("cad.workbench.present", "Present")
        }
    }

    var symbol: String {
        switch self {
        case .edit: return "ruler"
        case .present: return "cube.transparent"
        }
    }
}

// MARK: - Scene store

/// Builds the presentation scene from the live document and keeps it fresh as
/// the document's change count moves. The snapshot is a value; it is never a
/// second source of geometry.
@MainActor
@Observable
final class CADPresentationSceneStore {
    let document: FloeCADDocument
    private(set) var scene: CADPresentationScene?
    private(set) var lastChangeCount = -1
    private var lastExplodedPreviewRevision = -1
    @ObservationIgnored private var observationTask: Task<Void, Never>?

    init(document: FloeCADDocument) {
        self.document = document
    }

    func refresh(force: Bool = false) {
        let changeCount = document.liveChangeCount
        let previewRevision = CADExplodedViewPreview.current(for: document.session)?.revision ?? 0
        if !force, scene != nil, changeCount == lastChangeCount,
           previewRevision == lastExplodedPreviewRevision,
           scene?.documentRevision == document.revision {
            return
        }
        let snapshot = document.sceneSnapshot()
        scene = CADPresentationSceneBuilder.build(
            snapshot: snapshot,
            documentKey: document.url.standardizedFileURL.path)
        lastChangeCount = changeCount
        lastExplodedPreviewRevision = previewRevision
    }

    /// Bounded, cancellable subscription. Observation tracking alone cannot be
    /// cancelled, and an awaited continuation would outlive the Present view;
    /// this polls the document's observable change count while Present is
    /// visible and stops immediately when the pane leaves or the task is
    /// cancelled.
    func startObserving() {
        stopObserving()
        observationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled, let self else { return }
                self.refresh()
            }
        }
    }

    func stopObserving() {
        observationTask?.cancel()
        observationTask = nil
    }
}

// MARK: - Present pane

struct CADPresentationPresentationPane: View {
    let document: FloeCADDocument
    let handle: CADPresentationHandle
    let store: CADPresentationSceneStore
    let onEdit: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showIssues = false

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
            if let scene = store.scene {
                CADPresentationSurface(scene: scene, handle: handle, document: document)
                    .accessibilityIdentifier("CADPresentationSurface")
                if scene.isEmpty {
                    ContentUnavailableView {
                        Label(FloeCADStrings.text("cad.present.empty.title",
                                                  "Nothing to present yet"),
                              systemImage: "cube.transparent")
                    } description: {
                        Text(FloeCADStrings.text(
                            "cad.present.empty.message",
                            "Create or import a body in Edit, then return to Present."))
                    }
                }
            } else {
                ProgressView()
            }
            if let title = handle.selectionTitle, !title.isEmpty {
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    // Compact width stacks the selection-mode control under
                    // the Mode switch; keep the live selection label below
                    // both controls instead of letting them overlap.
                    .padding(.top, horizontalSizeClass == .compact ? 104 : 58)
                    .padding(.horizontal, 16)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("CADPresentSelection")
            }
            if !handle.issues.isEmpty {
                Button {
                    showIssues = true
                } label: {
                    Label("\(handle.issues.count)", systemImage: "exclamationmark.triangle")
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 10)
                        .frame(minHeight: 34)
                }
                .buttonStyle(.bordered)
                .background(.regularMaterial, in: Capsule())
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: .topLeading)
                .accessibilityLabel(FloeCADStrings.text(
                    "cad.present.issues.open", "Presentation details"))
                .accessibilityIdentifier("CADPresentIssues")
            }
            if let failure = handle.failureMessage {
                VStack(spacing: 8) {
                    Text(failure)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                    Button(FloeCADStrings.text("cad.workbench.edit", "Edit")) {
                        onEdit()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 20)
                .padding(.bottom, 76)
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .onAppear {
            store.refresh(force: true)
            store.startObserving()
            CADPresentationCaptureRegistry.shared.register(handle, for: document)
        }
        .onDisappear {
            store.stopObserving()
            CADPresentationCaptureRegistry.shared.unregister(document)
            handle.controller?.release()
        }
        .onChange(of: CADPresentationSelection.state(document: document)) { _, _ in
            handle.controller?.refreshSelection()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                store.startObserving()
                store.refresh(force: true)
            } else {
                store.stopObserving()
            }
        }
        .sheet(isPresented: $showIssues) {
            NavigationStack {
                List {
                    if handle.issues.isEmpty {
                        Text(FloeCADStrings.text("cad.present.issues.none",
                                                 "No presentation issues."))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(handle.issues) { issue in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(issue.localizedSummary, systemImage: issue.kind.symbolName)
                                .font(.callout.weight(.medium))
                            Text(issue.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .navigationTitle(FloeCADStrings.text("cad.present.issues.title",
                                                     "Presentation details"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(FloeCADStrings.text("cad.ui.common.done", "Done")) {
                            showIssues = false
                        }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }
}

// MARK: - Preview sinks

@MainActor
final class CADPresentationMaterialPreviewSink: CADMaterialPreviewSink {
    weak var handle: CADPresentationHandle?
    private var previewTask: Task<Void, Never>?

    func previewMaterial(_ spec: BodyMaterialSpec, for target: CADMaterialTarget) {
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            guard let self, let controller = self.handle?.controller else { return }
            await controller.previewMaterial(spec, for: target)
        }
    }

    func endMaterialPreview() {
        previewTask?.cancel()
        handle?.controller?.endMaterialPreview()
    }
}

// MARK: - Camera views sheet

/// X21 compact camera UI. Standard Form/Picker/List controls only: no custom
/// camera panel. The projection picker changes the LIVE view (temporary, like
/// an orbit); "Save Current View" is the only action that writes a bookmark,
/// and switching/renaming/deleting go through the document's undoable camera
/// commands. This sheet never edits geometry, materials or the selection.
struct CADCameraBookmarksSheet: View {
    let document: FloeCADDocument
    let handle: CADPresentationHandle

    @Environment(\.dismiss) private var dismiss
    @State private var cameras: [CADSavedCamera] = []
    @State private var activeID: UUID?
    @State private var message: String?
    @State private var renaming: CADSavedCamera?
    @State private var renameText = ""

    private var liveCamera: CADPresentationCamera? { handle.currentCamera }
    private var liveProjection: CADCameraProjection {
        liveCamera?.projection ?? .perspective
    }
    private var liveAspect: Double { handle.currentFrameAspect ?? 1 }
    private var activeCamera: CADSavedCamera? {
        cameras.first { $0.id == activeID }
    }
    private var currentViewDiffers: Bool {
        guard let activeCamera, let liveCamera else { return false }
        return !liveCamera.matches(activeCamera)
    }
    /// A video export owns the live stage; its transient frame is not a user
    /// view and must never be saved or updated as one.
    private var isExportBusy: Bool {
        handle.controller?.isAnimationLeased == true
    }

    var body: some View {
        NavigationStack {
            Form {
                if isExportBusy {
                    Section {
                        Text(FloeCADStrings.text(
                            "cad.present.camera.error.busy",
                            "Wait for the current export to finish."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    Picker(FloeCADStrings.text("cad.present.camera.projection",
                                               "Projection"),
                           selection: Binding(
                            get: { liveProjection },
                            set: { handle.setProjection($0) })) {
                        Text(title(for: .perspective))
                            .tag(CADCameraProjection.perspective)
                        Text(title(for: .orthographic))
                            .tag(CADCameraProjection.orthographic)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("CADPresentCameraProjection")
                    Text(FloeCADStrings.text(
                        "cad.present.camera.liveOnly",
                        "Changes here apply to this view. Save it to keep it."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text(currentDescription)
                }

                Section {
                    Button {
                        select(nil)
                    } label: {
                        row(title: FloeCADStrings.text(
                                "cad.present.camera.free", "Free view"),
                            detail: nil, isActive: activeID == nil,
                            symbol: "viewfinder")
                    }
                    .accessibilityIdentifier("CADPresentCameraFree")

                    ForEach(cameras) { camera in
                        Button {
                            select(camera)
                        } label: {
                            row(title: camera.name,
                                detail: detail(for: camera),
                                isActive: camera.id == activeID,
                                symbol: "camera")
                        }
                        .accessibilityIdentifier(
                            "CADPresentCameraRow-\(camera.id.uuidString)")
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                delete(camera)
                            } label: {
                                Label(FloeCADStrings.text(
                                    "cad.present.camera.delete", "Delete"),
                                      systemImage: "trash")
                            }
                            Button {
                                beginRename(camera)
                            } label: {
                                Label(FloeCADStrings.text(
                                    "cad.present.camera.rename", "Rename"),
                                      systemImage: "pencil")
                            }
                            Button {
                                update(camera)
                            } label: {
                                Label(FloeCADStrings.text(
                                    "cad.present.camera.update",
                                    "Update from Current View"),
                                      systemImage: "arrow.triangle.2.circlepath")
                            }
                        }
                        .contextMenu {
                            Button {
                                update(camera)
                            } label: {
                                Label(FloeCADStrings.text(
                                    "cad.present.camera.update",
                                    "Update from Current View"),
                                      systemImage: "arrow.triangle.2.circlepath")
                            }
                            Button {
                                beginRename(camera)
                            } label: {
                                Label(FloeCADStrings.text(
                                    "cad.present.camera.rename", "Rename"),
                                      systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                delete(camera)
                            } label: {
                                Label(FloeCADStrings.text(
                                    "cad.present.camera.delete", "Delete"),
                                      systemImage: "trash")
                            }
                        }
                    }

                    if cameras.isEmpty {
                        Text(FloeCADStrings.text("cad.present.camera.none",
                                                 "No saved views yet."))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(FloeCADStrings.text("cad.present.camera.saved",
                                             "Saved views"))
                } footer: {
                    if currentViewDiffers {
                        Text(FloeCADStrings.text(
                            "cad.present.camera.differs",
                            "The live view differs from the selected view."))
                    }
                }

                Section {
                    Button {
                        saveCurrent()
                    } label: {
                        Label(FloeCADStrings.text(
                            "cad.present.camera.save", "Save Current View"),
                              systemImage: "plus")
                    }
                    if currentViewDiffers, let activeCamera {
                        Button {
                            update(activeCamera)
                        } label: {
                            Label(FloeCADStrings.format(
                                "cad.present.camera.updateActive",
                                "Update “%@”", activeCamera.name),
                                  systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    if let message {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } footer: {
                    Text(FloeCADStrings.text(
                        "cad.present.camera.footer",
                        "Orbit, pan and zoom freely; a saved view keeps its own projection and framing."))
                }
            }
            .disabled(isExportBusy)
            .navigationTitle(FloeCADStrings.text("cad.present.camera", "Camera"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(FloeCADStrings.text("cad.ui.common.done", "Done")) {
                        dismiss()
                    }
                    .accessibilityIdentifier("CADPresentCameraDone")
                }
            }
            .onAppear(perform: reload)
            .alert(FloeCADStrings.text("cad.present.camera.renameTitle",
                                       "Rename View"),
                   isPresented: Binding(
                    get: { renaming != nil },
                    set: { if !$0 { renaming = nil } })) {
                TextField(FloeCADStrings.text("cad.present.camera.namePlaceholder",
                                              "Name"), text: $renameText)
                    .accessibilityIdentifier("CADPresentCameraRenameField")
                Button(FloeCADStrings.text("cad.present.camera.nameSave", "Save")) {
                    commitRename()
                }
                Button(FloeCADStrings.text("cad.ui.common.cancel", "Cancel"),
                       role: .cancel) { renaming = nil }
            } message: {
                Text(FloeCADStrings.text(
                    "cad.present.camera.renameMessage",
                    "Choose a name for this saved view."))
            }
        }
        .presentationDetents([.medium, .large])
        .presentationCompactAdaptation(.sheet)
        .accessibilityIdentifier("CADPresentCameraSheet")
    }

    // MARK: Rows

    private func row(title: String, detail: String?, isActive: Bool,
                     symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: isActive ? "checkmark.circle.fill" : symbol)
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private var currentDescription: String {
        let current = "\(title(for: liveProjection)) · "
            + CADSavedCamera.frameLabel(forAspect: liveAspect)
        return FloeCADStrings.format("cad.present.camera.current",
                                     "Current: %@", current)
    }

    private func detail(for camera: CADSavedCamera) -> String {
        "\(title(for: camera.projection)) · \(camera.frameLabel)"
    }

    private func title(for projection: CADCameraProjection) -> String {
        switch projection {
        case .perspective:
            return FloeCADStrings.text("cad.present.camera.perspective",
                                       "Perspective")
        case .orthographic:
            return FloeCADStrings.text("cad.present.camera.orthographic",
                                       "Orthographic")
        }
    }

    // MARK: Actions

    private func reload() {
        cameras = document.savedCameras
        activeID = document.activeSavedCameraID
    }

    private func saveCurrent() {
        guard !isExportBusy else {
            message = FloeCADStrings.text(
                "cad.present.camera.error.busy",
                "Wait for the current export to finish.")
            return
        }
        guard let liveCamera else {
            message = FloeCADStrings.text("cad.present.camera.error.generic",
                                          "The view could not be saved.")
            return
        }
        let camera = CADSavedCamera(presentationCamera: liveCamera,
                                    name: nextName(), frameAspect: liveAspect)
        do {
            _ = try document.saveCamera(camera)
            message = nil
            reload()
        } catch {
            message = error.localizedDescription
        }
    }

    private func select(_ camera: CADSavedCamera?) {
        do {
            try document.selectCamera(id: camera?.id)
            if let camera {
                handle.showCamera(camera.presentationCamera)
            }
            message = nil
            reload()
        } catch {
            message = error.localizedDescription
        }
    }

    private func update(_ camera: CADSavedCamera) {
        guard !isExportBusy else {
            message = FloeCADStrings.text(
                "cad.present.camera.error.busy",
                "Wait for the current export to finish.")
            return
        }
        guard let liveCamera else { return }
        let draft = CADSavedCamera(presentationCamera: liveCamera,
                                   name: camera.name, frameAspect: liveAspect)
        do {
            _ = try document.updateCamera(id: camera.id, with: draft)
            message = nil
            reload()
        } catch {
            message = error.localizedDescription
        }
    }

    private func delete(_ camera: CADSavedCamera) {
        do {
            try document.deleteCamera(id: camera.id)
            message = nil
            reload()
        } catch {
            message = error.localizedDescription
        }
    }

    private func beginRename(_ camera: CADSavedCamera) {
        renameText = camera.name
        renaming = camera
    }

    private func commitRename() {
        guard let camera = renaming else { return }
        renaming = nil
        do {
            _ = try document.renameCamera(id: camera.id, to: renameText)
            message = nil
            reload()
        } catch {
            message = error.localizedDescription
        }
    }

    private func nextName() -> String {
        let used = Set(cameras.map { $0.name.lowercased() })
        for index in 1...(CADSavedCamera.maximumCount + 1) {
            let candidate = FloeCADStrings.format(
                "cad.present.camera.defaultName", "View %d", index)
            if !used.contains(candidate.lowercased()) { return candidate }
        }
        return FloeCADStrings.format("cad.present.camera.defaultName",
                                     "View %d", cameras.count + 1)
    }
}

// MARK: - Workbench content

struct CADPresentationWorkbenchContent: View {
    let document: FloeCADDocument
    let canvasActions: CADCanvasActions?

    @State private var mode: CADWorkbenchMode = .edit
    @State private var showEnvironmentInspector = false
    @State private var showCameraSheet = false
    @State private var materialInspector: MaterialInspectorRequest?
    @State private var handle = CADPresentationHandle()
    @State private var store: CADPresentationSceneStore
    @State private var presentSink = CADPresentationMaterialPreviewSink()
    @State private var snapshotService = CADPresentationSnapshotService()
    @State private var pngExport: PNGFileDocument?
    @State private var glbExport: GLBFileDocument?
    @State private var showPNGExporter = false
    @State private var showGLBExporter = false
    @State private var exportError: String?
    @State private var playback = CADAnimationPlaybackModel()
    @State private var animationState = CADAnimationLoadState()
    @State private var showTimeline = false
    @State private var movieExport: MovieFileDocument?
    @State private var showMovieExporter = false
    @State private var framesExport: ZipFileDocument?
    @State private var showFramesExporter = false
    @State private var exportProgress: CADAnimationExportProgress?
    @State private var exportFormat: CADAnimationExportOutputFormat = .mp4
    @State private var exportHandle: CADAnimationExportHandle?
    @State private var exportStarting = false
    @State private var interruptedExport: CADAnimationExportRecoverySummary?
    @State private var dismissingInterruptedExport = false
    @State private var videoExportOptions = CADAnimationExportOptions.load()
    @State private var videoExportPresentation: VideoExportPresentation?
    @State private var showOverlays = false
    @State private var showGLBModelOnlyNotice = false
    @State private var showNumericTextNotice = false

    /// A presentation carries its own frozen values. The first sheet body
    /// must not initialize draft State from an older render's preferences.
    private struct VideoExportPresentation: Identifiable {
        let id = UUID()
        let options: CADAnimationExportOptions
        let clipDuration: Double
    }

    /// One presentation owns one frozen selection. Keeping the target in the
    /// sheet item prevents a first-open closure from observing the previous
    /// target while the inspector's draft State is being initialized.
    private struct MaterialInspectorRequest: Identifiable {
        let id = UUID()
        let target: CADMaterialTarget
    }

    init(document: FloeCADDocument, canvasActions: CADCanvasActions?) {
        self.document = document
        self.canvasActions = canvasActions
        _store = State(initialValue: CADPresentationSceneStore(document: document))
    }

    var body: some View {
        Group {
            switch mode {
            case .edit:
                FloeCADEditorView(document: document, canvasActions: canvasActions)
            case .present:
                CADPresentationPresentationPane(
                    document: document, handle: handle, store: store,
                    onEdit: { mode = .edit })
            }
        }
        .overlay(alignment: .topTrailing) { modeChrome }
        .overlay(alignment: .bottom) {
            if mode == .present {
                VStack(spacing: 8) {
                    if let interruptedExport {
                        interruptedExportBanner(interruptedExport)
                    }
                    if showTimeline {
                        CADAnimationTimelineView(
                            document: document,
                            handle: handle,
                            playback: playback,
                            state: animationState,
                            onChanged: { refreshAnimation() })
                            .padding(.horizontal, 12)
                    }
                    presentToolbar
                }
            }
        }
        .overlay {
            if let progress = exportProgress, !progress.isFinished {
                exportProgressCard(progress)
            }
        }
        .sheet(item: $materialInspector) { request in
            CADMaterialInspectorView(
                document: document,
                target: request.target,
                previewSink: presentSink
            ) {
                store.refresh(force: true)
            }
            .presentationCompactAdaptation(horizontal: .popover, vertical: .sheet)
        }
        .sheet(isPresented: $showEnvironmentInspector) {
            CADEnvironmentInspectorView(
                document: document,
                onPreview: { appearance in
                    handle.controller?.preview(
                        environment: CADPresentationSceneBuilder.environment(from: appearance))
                },
                onCancelPreview: {
                    handle.controller?.preview(
                        environment: CADPresentationSceneBuilder.environment(
                            from: document.viewAppearance))
                })
            .presentationCompactAdaptation(horizontal: .popover, vertical: .sheet)
        }
        .sheet(isPresented: $showCameraSheet) {
            CADCameraBookmarksSheet(document: document, handle: handle)
        }
        .sheet(isPresented: $showOverlays) {
            // Refresh the applied scene before the sheet closes, so Export/
            // Screenshot immediately after a toggle does not wait for the
            // 450 ms Present subscription tick.
            CADViewOverlaySheet(document: document) {
                store.refresh(force: true)
            }
        }
        .sheet(item: $videoExportPresentation) { presentation in
            CADAnimationExportOptionsSheet(
                initial: presentation.options,
                clipDuration: presentation.clipDuration,
                numericTextNotice: document.viewOverlayState.visibleMeasurements.isEmpty
                    ? nil
                    : FloeCADStrings.text(
                        "cad.ui.export.numericTextNotice",
                        "Measurement lines are included. Numeric values are not drawn into the image or video; they remain in the overlay list.")) { options in
                // The confirmed draft is handed to the existing export
                // service verbatim; nothing is re-defaulted on the way.
                videoExportOptions = options
                options.save()
                exportVideo(options: options)
            }
            .presentationCompactAdaptation(horizontal: .popover, vertical: .sheet)
        }
        .fileExporter(isPresented: $showPNGExporter, document: pngExport,
                      contentType: .png, defaultFilename: "\(document.name) presentation") { _ in
            pngExport = nil
        }
        .fileExporter(isPresented: $showGLBExporter, document: glbExport,
                      contentType: .data, defaultFilename: "\(document.name)") { _ in
            glbExport = nil
        }
        .fileExporter(isPresented: $showMovieExporter, document: movieExport,
                      contentType: .mpeg4Movie,
                      defaultFilename: "\(document.name) animation") { _ in
            movieExport = nil
        }
        .fileExporter(isPresented: $showFramesExporter, document: framesExport,
                      contentType: .zip,
                      defaultFilename: "\(document.name) animation frames") { _ in
            framesExport = nil
        }
        .confirmationDialog(
            Text(FloeCADStrings.text(
                "cad.ui.export.numericTextTitle",
                "Measurement values aren't drawn")),
            isPresented: $showNumericTextNotice,
            titleVisibility: .visible
        ) {
            Button(FloeCADStrings.text("cad.ui.common.export", "Export")) {
                performExportPNG()
            }
            Button(FloeCADStrings.text("cad.ui.common.cancel", "Cancel"),
                   role: .cancel) {}
        } message: {
            Text(FloeCADStrings.text(
                "cad.ui.export.numericTextNotice",
                "Measurement lines are included. Numeric values are not drawn into the image; they remain in the overlay list."))
        }
        .confirmationDialog(
            Text(FloeCADStrings.text("cad.present.export.glbViewOnlyTitle",
                                     "GLB keeps the model only")),
            isPresented: $showGLBModelOnlyNotice,
            titleVisibility: .visible) {
            Button(FloeCADStrings.text("cad.present.export.glbModelOnly", "Export Model")) {
                exportGLBModelOnly()
            }
            Button(FloeCADStrings.text("cad.ui.common.cancel", "Cancel"),
                   role: .cancel) {}
        } message: {
            Text(FloeCADStrings.text(
                "cad.present.export.glbViewOnlyMessage",
                "The section cut and measurement guides are view-only and won't be included in this file."))
        }
        .alert(FloeCADStrings.text("cad.present.export.failed", "Couldn't export"),
               isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } })) {
            Button(FloeCADStrings.text("cad.ui.common.done", "Done")) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
        .onAppear {
            refreshAnimation(attach: true)
        }
        .task(id: ObjectIdentifier(document)) {
            await loadInterruptedExport()
        }
        .onDisappear {
            playback.stop()
        }
        .onChange(of: store.lastChangeCount) { _, _ in
            refreshAnimation()
        }
        .onChange(of: handle.isReady) { _, ready in
            if ready, mode == .present { refreshAnimation(attach: true) }
        }
        .onChange(of: mode) { _, newMode in
            presentSink.endMaterialPreview()
            if newMode == .present {
                store.refresh(force: true)
                refreshAnimation(attach: true)
                if !animationState.animation.isEmpty { showTimeline = true }
            } else {
                playback.stop()
                // X22: Edit's live SectionState mirrors the document. Present
                // may have toggled/flipped/removed it, so re-read before the
                // editor paints the first frame.
                document.viewModel().reloadViewOverlayFromDocument()
            }
        }
    }

    // MARK: Animation

    private func refreshAnimation(attach: Bool = false) {
        let next = document.animationLoadState()
        animationState = next
        if attach || playback.clipID == nil {
            playback.attach(document: document, handle: handle,
                            clipID: next.animation.activeClip?.id)
        } else {
            playback.documentDidChange(next)
        }
    }

    private func exportProgressCard(_ progress: CADAnimationExportProgress) -> some View {
        VStack(spacing: 10) {
            if progress.phase == .verifying || progress.phase == .assembling {
                // Rendering is complete; the bundle is being streamed off the
                // main actor. There is no honest frame percentage for this pass,
                // so show an indeterminate indicator instead of a 100% bar.
                ProgressView()
                    .frame(width: 240)
            } else {
                ProgressView(value: progress.fraction)
                    .frame(width: 240)
            }
            Text(exportStatusText(progress))
                .font(.callout)
                .multilineTextAlignment(.center)
            Button(FloeCADStrings.text("cad.animation.cancel", "Cancel")) {
                if let exportHandle {
                    document.cancelAnimationExport(exportHandle.id)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .accessibilityIdentifier("CADAnimationExportProgress")
    }

    private func exportStatusText(_ progress: CADAnimationExportProgress) -> String {
        let isFrames = exportFormat == .pngSequence
        switch progress.phase {
        case .preparing:
            return isFrames
                ? FloeCADStrings.text("cad.animation.export.frames.preparing",
                                      "Preparing frames…")
                : FloeCADStrings.text("cad.animation.export.preparing",
                                      "Preparing video…")
        case .rendering:
            return FloeCADStrings.format(
                "cad.animation.export.progress",
                "Rendering %d of %d frames",
                progress.completedFrames, progress.totalFrames)
        case .verifying:
            return isFrames
                ? FloeCADStrings.text("cad.animation.export.frames.verifying",
                                      "Verifying PNG frames…")
                : FloeCADStrings.text("cad.animation.export.finalizing",
                                      "Finishing video…")
        case .assembling:
            return isFrames
                ? FloeCADStrings.text("cad.animation.export.frames.assembling",
                                      "Writing frame bundle…")
                : FloeCADStrings.text("cad.animation.export.finalizing",
                                      "Finishing video…")
        case .finalizing:
            return isFrames
                ? FloeCADStrings.text("cad.animation.export.frames.finalizing",
                                      "Building frame bundle…")
                : FloeCADStrings.text("cad.animation.export.finalizing",
                                      "Finishing video…")
        case .finished:
            return isFrames
                ? FloeCADStrings.text("cad.animation.export.frames.finished",
                                      "PNG frames exported")
                : FloeCADStrings.text("cad.animation.export.finished", "Video exported")
        case .failed:
            return isFrames
                ? FloeCADStrings.text("cad.animation.export.frames.failed",
                                      "Couldn't export the frames.")
                : FloeCADStrings.text("cad.animation.export.failed",
                                      "Couldn't export the video.")
        case .cancelled:
            return isFrames
                ? FloeCADStrings.text("cad.animation.export.frames.cancelled",
                                      "Frame export cancelled.")
                : FloeCADStrings.text("cad.animation.export.cancelled",
                                      "Video export cancelled.")
        }
    }

    private func openExportOptions(format: CADAnimationExportOutputFormat) {
        var options = videoExportOptions
        options.format = format
        // The sheet only offers the executable opaque output.
        options.alpha = .opaque
        videoExportOptions = options
        presentExportOptions(options)
    }

    private func presentExportOptions(_ options: CADAnimationExportOptions) {
        videoExportPresentation = VideoExportPresentation(
            options: options,
            clipDuration: animationState.activeClip?.duration ?? 0)
    }

    private func exportVideo(options: CADAnimationExportOptions) {
        guard let clip = animationState.activeClip else {
            exportError = FloeCADStrings.text("cad.animation.empty",
                                              "Add a clip to animate the camera or parts.")
            return
        }
        guard exportHandle == nil, !exportStarting else { return }
        // An agent/tool export (or another presentation's export) owns the
        // document's renderer. Refuse before touching the durable registry so
        // a blocked attempt cannot leave a second native-editor record for an
        // operation that never started.
        guard !CADAnimationExportCenter.shared.hasActiveJob(
            documentKey: document.url.standardizedFileURL.path) else {
            exportError = CADAnimationExportError.exportInProgress.localizedDescription
            return
        }
        playback.pause()
        exportFormat = options.format
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "\(document.name)-animation-\(UUID().uuidString)."
                    + options.format.pathExtension)
        let request = CADAnimationExportRecoveryRequest(
            documentURL: document.url,
            options: options.recoveryOptions,
            sourceRevision: document.revision,
            sourceContentSHA256: document.contentSHA256,
            sourceChangeCount: document.liveChangeCount,
            clipID: clip.id,
            clipDuration: clip.duration,
            suggestedFilename: Self.suggestedExportFilename(
                document.name, format: options.format))
        exportStarting = true
        interruptedExport = nil
        Task { @MainActor in
            // The document may have closed between the button action and this
            // task. Do not create a record for a closed document.
            guard !document.isClosed else {
                exportStarting = false
                return
            }
            // The durable request is written BEFORE the renderer exists. If
            // that atomic write fails, this task returns without starting a
            // frame loop, creating a video or leaving a phantom record.
            var recovery: CADAnimationExportRecoverySession?
            if let sink = document.animationExportRecoverySink {
                let session = CADAnimationExportRecoverySession(
                    sink: sink, request: request)
                do {
                    try await session.begin()
                } catch {
                    exportStarting = false
                    exportError = FloeCADStrings.text(
                        "cad.animation.export.recoverySaveFailed",
                        "Couldn't save the export details, so the video wasn't started.")
                    return
                }
                recovery = session
            }
            // The begin above awaited real disk I/O. A close or edit in that
            // window must not attach the saved intent to a newer source. A
            // pending autosave may advance revision/hash without changing the
            // live edit count, so the exact clip value and live change count
            // are the frame-loop fence (the exporter keeps its own stricter
            // revision/background/staging fences after this point).
            let currentClip = document.animationLoadState().activeClip
            guard !document.isClosed,
                  currentClip?.id == request.clipID,
                  abs((currentClip?.duration ?? -1) - request.clipDuration) < 0.000_001,
                  document.liveChangeCount == request.sourceChangeCount else {
                exportStarting = false
                await recovery?.finish(
                    outcome: .cancelled,
                    detail: "the document changed before the frame loop started")
                exportError = FloeCADStrings.text(
                    "cad.animation.export.sourceChanged",
                    "The document changed before the video started. Try again.")
                return
            }
            let handle: CADAnimationExportHandle
            do {
                handle = try document.startAnimationExport(
                    to: temporary, settings: options.exportSettings()) { progress in
                        exportProgress = progress
                    }
                exportHandle = handle
                exportStarting = false
            } catch {
                exportStarting = false
                await recovery?.finish(
                    outcome: Self.recoveryOutcome(for: error),
                    detail: error.localizedDescription)
                exportError = error.localizedDescription
                exportProgress = nil
                return
            }
            let status = await document.waitForAnimationExport(handle.id)
            exportProgress = status.progress
            let result = status.result
            let data = result.flatMap { try? Data(contentsOf: $0.url) }
            var outcome = CADAnimationExportRecoveryOutcome(status: status)
            if outcome == .completed, data == nil {
                // The renderer produced a result but its bytes could not be
                // handed to the export picker; reporting completed would be a
                // fake success for the user.
                outcome = .failed
            }
            let detail: String?
            switch outcome {
            case .completed:
                if let result {
                    let kind = result.format == .mp4 ? "mp4" : "png frames zip"
                    detail = "\(kind) \(result.width)x\(result.height) "
                        + "\(Int(result.frameRate.rounded()))fps "
                        + "\(result.frameCount) frames, \(result.byteCount) bytes; "
                        + "rendered for the export picker"
                } else {
                    detail = "the export produced no readable result"
                }
            case .failed:
                detail = status.error ?? (result != nil
                    ? FloeCADStrings.text(
                        exportFormat == .mp4
                            ? "cad.animation.export.readFailed"
                            : "cad.animation.export.frames.readFailed",
                        exportFormat == .mp4
                            ? "The exported video could not be read."
                            : "The exported frame bundle could not be read.")
                    : nil)
            case .cancelled:
                detail = status.error
            }
            let cleanup: @MainActor () -> String? = {
                guard FileManager.default.fileExists(atPath: temporary.path) else {
                    return nil
                }
                do {
                    try FileManager.default.removeItem(at: temporary)
                    return nil
                } catch {
                    return FloeCADStrings.text(
                        "cad.animation.export.cleanupFailed",
                        "Temporary export files could not be removed.")
                }
            }
            if let recovery {
                // Cleanup runs before finish, so the durable record reports
                // the post-cleanup outcome. The session guard makes a second
                // status/close callback harmless.
                await recovery.finish(outcome: outcome, detail: detail,
                                      cleanup: cleanup)
            } else {
                _ = cleanup()
            }
            // Keep this presentation busy until its durable finish has
            // returned. A second export must not race an old picker callback.
            exportHandle = nil
            guard !document.isClosed else { return }
            guard outcome == .completed, let result, let data else {
                if !status.isCancelled {
                    exportError = status.error
                        ?? (result != nil
                            ? FloeCADStrings.text(
                                exportFormat == .mp4
                                    ? "cad.animation.export.readFailed"
                                    : "cad.animation.export.frames.readFailed",
                                exportFormat == .mp4
                                    ? "The exported video could not be read."
                                    : "The exported frame bundle could not be read.")
                            : FloeCADStrings.text(
                                "cad.present.export.failed", "Couldn't export"))
                }
                return
            }
            if result.format == .pngSequence {
                framesExport = ZipFileDocument(data: data)
                showFramesExporter = true
            } else {
                movieExport = MovieFileDocument(data: data)
                showMovieExporter = true
            }
        }
    }

    /// One terminal mapping for errors thrown by the synchronous start call.
    /// A close/lease revocation surfaces `.cancelled`; everything else is an
    /// honest failure.
    private static func recoveryOutcome(for error: Error) -> CADAnimationExportRecoveryOutcome {
        if let error = error as? CADAnimationExportError,
           case .cancelled = error {
            return .cancelled
        }
        return .failed
    }

    /// A display label, never a path. The Present pane renders into the system
    /// temporary directory and then asks the user where to save; recovery must
    /// not pretend that temporary URL is a permanent destination.
    private static func suggestedExportFilename(
        _ name: String, format: CADAnimationExportOutputFormat
    ) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = (trimmed.isEmpty ? "CAD" : trimmed)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
        let suffix = format == .mp4 ? " animation.mp4" : " animation frames.zip"
        return String(base.prefix(180)) + suffix
    }

    private func loadInterruptedExport() async {
        guard let sink = document.animationExportRecoverySink else { return }
        let summary = await sink.lastInterruptedAnimationExport(
            documentURL: document.url)
        guard !Task.isCancelled else { return }
        interruptedExport = summary
    }

    private func interruptedExportBanner(
        _ summary: CADAnimationExportRecoverySummary
    ) -> some View {
        let restored = CADAnimationExportOptions(recoveryOptions: summary.options)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.counterclockwise.circle")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(FloeCADStrings.text(
                        "cad.animation.export.recovery.title",
                        "Video export interrupted"))
                        .font(.callout.weight(.semibold))
                        .accessibilityIdentifier("CADAnimationExportRecovery")
                    Text(recoveryDescription(summary))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if restored != nil {
                    Button(FloeCADStrings.text(
                        "cad.animation.export.recovery.restore", "Use settings")) {
                        if let restored {
                            videoExportOptions = restored
                            presentExportOptions(restored)
                        }
                        interruptedExport = nil
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(animationState.activeClip == nil || exportHandle != nil
                              || exportStarting || dismissingInterruptedExport)
                    .accessibilityIdentifier("CADAnimationExportRecoveryRestore")
                }
                Button(FloeCADStrings.text(
                    "cad.animation.export.recovery.dismiss", "Dismiss")) {
                    dismissInterruptedExport(summary)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(dismissingInterruptedExport)
                .accessibilityIdentifier("CADAnimationExportRecoveryDismiss")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 12)
    }

    private func dismissInterruptedExport(_ summary: CADAnimationExportRecoverySummary) {
        guard !dismissingInterruptedExport,
              let sink = document.animationExportRecoverySink else { return }
        dismissingInterruptedExport = true
        Task { @MainActor in
            defer { dismissingInterruptedExport = false }
            do {
                try await sink.dismissInterruptedAnimationExport(
                    id: summary.id, documentURL: document.url)
                if interruptedExport?.id == summary.id { interruptedExport = nil }
            } catch {
                exportError = FloeCADStrings.text(
                    "cad.animation.export.dismissFailed",
                    "Couldn't dismiss the interrupted export. Try again.")
            }
        }
    }

    private func recoveryDescription(_ summary: CADAnimationExportRecoverySummary) -> String {
        let format = CADAnimationExportOutputFormat(rawValue: summary.options.format)
        let kind: String
        if format == .pngSequence {
            kind = FloeCADStrings.text("cad.animation.export.options.format.png",
                                       "PNG frames (ZIP)")
        } else {
            let codec = summary.options.codec.lowercased()
            kind = codec == "hevc"
                ? FloeCADStrings.text("cad.animation.export.options.codec.hevc",
                                      "HEVC (smaller)")
                : (codec == "h264"
                    ? FloeCADStrings.text("cad.animation.export.options.codec.h264",
                                          "H.264")
                    : summary.options.codec.uppercased())
        }
        return "\(summary.suggestedFilename) · \(kind) · \(summary.options.width)×"
            + "\(summary.options.height) · \(summary.options.frameRate) fps"
    }

    // MARK: Chrome

    private var modeChrome: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Picker(FloeCADStrings.text("cad.workbench.mode", "Mode"), selection: $mode) {
                ForEach(CADWorkbenchMode.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 168)
            .accessibilityIdentifier("CADWorkbenchMode")
            if mode == .present {
                Picker(FloeCADStrings.text("cad.present.selection.mode", "Selection"),
                       selection: Binding(
                        get: { handle.selectionMode },
                        set: { handle.setSelectionMode($0) })) {
                    ForEach(CADPresentationSelectionMode.allCases) { item in
                        Text(item.title)
                            .tag(item)
                            .accessibilityIdentifier(item == .body
                                ? "CADPresentSelectionBody"
                                : "CADPresentSelectionFace")
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 168)
                .accessibilityIdentifier("CADPresentSelectionMode")
            }
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.top, 8)
        .padding(.trailing, 12)
        .animation(.default, value: mode)
    }

    private var presentToolbar: some View {
        HStack(spacing: 4) {
            presentButton(FloeCADStrings.text("cad.animation.title", "Animation"),
                          symbol: "timeline.selection",
                          identifier: "CADPresentAnimation") {
                showTimeline.toggle()
                if showTimeline { refreshAnimation(attach: playback.clipID == nil) }
            }
            presentButton(FloeCADStrings.text("cad.ui.tool.material", "Material"),
                          symbol: "paintpalette", identifier: "CADPresentMaterial") {
                openMaterialInspector()
            }
            presentButton(FloeCADStrings.text("cad.present.environment", "Environment"),
                          symbol: "sun.max", identifier: "CADPresentEnvironment") {
                showEnvironmentInspector = true
            }
            presentButton(FloeCADStrings.text("cad.present.camera", "Camera"),
                          symbol: "camera", identifier: "CADPresentCamera") {
                // Opening the camera list from a paused animated frame would
                // describe that frame as the live camera. Return to the
                // document baseline first; the saved views are unaffected.
                playback.stop()
                showCameraSheet = true
            }
            presentButton(FloeCADStrings.text("cad.present.fit", "Fit"),
                          symbol: "arrow.up.left.and.arrow.down.right",
                          identifier: "CADPresentFit") {
                handle.fit()
            }
            presentButton(FloeCADStrings.text("cad.present.overlays", "Overlays"),
                          symbol: "square.3.layers.3d",
                          identifier: "CADPresentOverlays") {
                showOverlays = true
            }
            Menu {
                Button {
                    exportPNG()
                } label: {
                    Label(FloeCADStrings.text("cad.present.export.png", "PNG image"),
                          systemImage: "photo")
                }
                Button {
                    openExportOptions(format: .mp4)
                } label: {
                    Label(FloeCADStrings.text("cad.animation.export.video", "MP4 video"),
                          systemImage: "film")
                }
                .disabled(animationState.activeClip == nil
                          || exportHandle != nil || exportStarting)

                Button {
                    openExportOptions(format: .pngSequence)
                } label: {
                    Label(FloeCADStrings.text("cad.animation.export.frames",
                                               "PNG frames (ZIP)"),
                          systemImage: "square.stack.3d.up")
                }
                .disabled(animationState.activeClip == nil
                          || exportHandle != nil || exportStarting)
                .accessibilityIdentifier("CADAnimationExportFrames")

                Button {
                    exportGLB()
                } label: {
                    Label(FloeCADStrings.text("cad.present.export.glb", "GLB model"),
                          systemImage: "cube")
                }
            } label: {
                Label(FloeCADStrings.text("cad.present.export", "Export"),
                      systemImage: "square.and.arrow.up")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 12)
                    .frame(minHeight: 38)
            }
            .accessibilityIdentifier("CADPresentExport")
        }
        .padding(6)
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, 16)
    }

    private func presentButton(_ title: String, symbol: String, identifier: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.titleAndIcon)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 10)
                .frame(minHeight: 38)
        }
        .accessibilityIdentifier(identifier)
    }

    // MARK: Actions

    private func openMaterialInspector() {
        presentSink.handle = handle
        materialInspector = MaterialInspectorRequest(
            target: CADPresentationSelection.materialTarget(document: document))
    }

    private func exportPNG() {
        // X22: the capture will include the real guide lines but not their
        // numeric text. State that before writing when a visible guide exists;
        // an ordinary document exports in one tap with no dialog.
        if !document.viewOverlayState.visibleMeasurements.isEmpty {
            showNumericTextNotice = true
            return
        }
        performExportPNG()
    }

    private func performExportPNG() {
        // A video export owns the live stage; a framed still must not race it
        // or save/export its transient frame.
        if handle.controller?.isAnimationLeased == true {
            exportError = FloeCADStrings.text(
                "cad.present.camera.error.busy",
                "Wait for the current export to finish.")
            return
        }
        // A paused animation frame is not the document's camera. Return to the
        // baseline so the still shows the selected saved view (or the live
        // free view), never a transient animated pose.
        playback.stop()
        Task {
            do {
                // A selected saved view exports its exact pose, projection and
                // saved frame aspect; with no selection the live Present
                // pixels keep the existing behavior. The service awaits the
                // exact overlay stage instead of accepting a stale one.
                let snapshot = try await snapshotService.capture(
                    handle: handle, document: document, targetWidth: 2048,
                    savedCamera: document.activeSavedCamera)
                pngExport = PNGFileDocument(data: snapshot.pngData)
                showPNGExporter = true
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    private func exportGLB() {
        // X22: a GLB writer carries model geometry only. An active cut/guide
        // is view-only; tell the user before the picker instead of letting a
        // "complete" export imply it contains them.
        if document.viewOverlayState.hasViewOnlyContent {
            showGLBModelOnlyNotice = true
            return
        }
        exportGLBModelOnly()
    }

    private func exportGLBModelOnly() {
        guard let data = document.viewModel().exportGLB() else {
            exportError = FloeCADStrings.text(
                "cad.present.export.glbUnavailable",
                "This model could not be exported as GLB.")
            return
        }
        glbExport = GLBFileDocument(data: data)
        showGLBExporter = true
    }
}

// MARK: - X22 section & measurement overlay sheet

/// One place to inspect/change exactly what Edit, Present, screenshots and
/// video share. The document owns the values; this sheet is a plain Form that
/// reads them back after every commit and reports a refusal instead of
/// pretending a read-only document changed.
struct CADViewOverlaySheet: View {
    let document: FloeCADDocument
    /// Called after a committed overlay change (the Present scene store
    /// refresh). The default is a no-op in a preview/test host.
    var onCommit: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var overlay: CADViewOverlayState = .empty
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if overlay.section == nil {
                        Text(FloeCADStrings.text(
                            "cad.overlay.section.none",
                            "Add a section from Edit › Views › Section."))
                            .foregroundStyle(.secondary)
                    } else {
                        Toggle(FloeCADStrings.text(
                            "cad.overlay.section.toggle", "Show section cut"),
                               isOn: Binding(
                                get: { overlay.section?.enabled ?? false },
                                set: { setSectionEnabled($0) }))
                            .accessibilityIdentifier("CADOverlaySectionToggle")
                        Button(FloeCADStrings.text(
                            "cad.overlay.section.flip", "Flip side")) {
                            commit { document.flipSectionView() }
                        }
                        .accessibilityIdentifier("CADOverlayFlip")
                        Button(role: .destructive) {
                            commit { document.removeSectionView() }
                        } label: {
                            Text(FloeCADStrings.text(
                                "cad.overlay.section.remove", "Remove section"))
                        }
                        .accessibilityIdentifier("CADOverlayRemoveSection")
                    }
                } header: {
                    Text(FloeCADStrings.text("cad.overlay.section", "Section"))
                }

                Section {
                    if overlay.measurements.isEmpty {
                        Text(FloeCADStrings.text(
                            "cad.overlay.measurements.none",
                            "Measure two points in Edit, then save the result."))
                            .foregroundStyle(.secondary)
                    } else {
                        Toggle(FloeCADStrings.text(
                            "cad.overlay.measurements.toggle", "Show guides"),
                               isOn: Binding(
                                get: { overlay.showsMeasurements },
                                set: { setMeasurementVisibility($0) }))
                            .accessibilityIdentifier("CADOverlayMeasurementsToggle")
                        ForEach(Array(overlay.measurements.enumerated()),
                                id: \.element.id) { index, annotation in
                            HStack(spacing: 10) {
                                Text(FloeCADStrings.format(
                                    "cad.overlay.measurement.row",
                                    "Measurement %d", index + 1))
                                Spacer(minLength: 0)
                                Text(CADPreferences.shared.unit
                                    .compactLengthString(fromMM: annotation.lengthMM))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                Button(role: .destructive) {
                                    commit { document.removeMeasurementAnnotation(id: annotation.id) }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityIdentifier(
                                    "CADOverlayDelete-\(annotation.id.uuidString)")
                            }
                            .accessibilityIdentifier("CADOverlayAnnotationRow")
                        }
                    }
                } header: {
                    Text(FloeCADStrings.text(
                        "cad.overlay.measurements", "Measurements"))
                }

                Section {
                    Text(FloeCADStrings.text(
                        "cad.overlay.footer.capture",
                        "Screenshots and video include the section cut and measurement lines; values stay in this list."))
                        .font(.footnote)
                    Text(FloeCADStrings.text(
                        "cad.overlay.footer.exchange",
                        "STEP, IGES, GLB, USDZ, OBJ, STL and 3MF store model geometry only; they don't include view cuts or guides."))
                        .font(.footnote)
                    if overlay.section?.enabled == true {
                        Text(FloeCADStrings.text(
                            "cad.overlay.footer.faceSelection",
                            "Face selection is off while a section is shown."))
                            .font(.footnote)
                    }
                    if overlay.section?.enabled == true,
                       document.animationLoadState().activeClip?.instanceTracks.isEmpty == false {
                        Text(FloeCADStrings.text(
                            "cad.overlay.footer.partAnimation",
                            "Part animation moves the cut with each part. Remove the section before playing or exporting part tracks."))
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle(FloeCADStrings.text(
                "cad.overlay.title", "Section & Annotations"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(FloeCADStrings.text("cad.ui.common.done", "Done")) {
                        dismiss()
                    }
                }
            }
            .onAppear { reload() }
            .alert(FloeCADStrings.text("cad.overlay.error.title", "Couldn't change the view"),
                   isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } })) {
                Button(FloeCADStrings.text("cad.ui.common.done", "Done")) {
                    errorMessage = nil
                }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func reload() {
        overlay = document.viewOverlayState
    }

    private func commit(_ change: () -> Bool) {
        guard change() else {
            errorMessage = FloeCADStrings.text(
                "cad.overlay.error.readOnly",
                "This document is read-only; its section and annotations can't be changed.")
            reload()
            return
        }
        reload()
        onCommit()
    }

    private func setSectionEnabled(_ enabled: Bool) {
        commit { document.setSectionEnabled(enabled) }
    }

    private func setMeasurementVisibility(_ visible: Bool) {
        commit { document.setMeasurementGuidesVisible(visible) }
    }
}

// MARK: - Host selection publication

/// Lives above Edit/Present so switching the rendering surface cannot remove
/// the host's selection notification path. The shared editor remains the sole
/// selection authority. Standalone FloeCADEditorView keeps its own publisher.
struct CADPresentationSelectionObserver: ViewModifier {
    let document: FloeCADDocument
    @Environment(\.cadSelectionObserver) private var observer
    @State private var active = false

    func body(content: Content) -> some View {
        let key = CADPresentationSelection.observationKey(document: document)
        ZStack {
            // Wrapped Edit must not race or duplicate the persistent publisher.
            // This changes only the child's environment, not this modifier's.
            content.environment(\.cadSelectionObserver, nil)
        }
            .onAppear {
                active = true
                publish(expected: CADPresentationSelection.observationKey(document: document))
            }
            .onDisappear { active = false }
            .onChange(of: key) { _, current in publish(expected: current) }
    }

    private func publish(expected: CADPresentationSelectionObservationKey) {
        guard active, !document.isClosed, let observer,
              expected == CADPresentationSelection.observationKey(document: document) else { return }
        // Synchronous main-actor capture: no pending task/handler lease can
        // later publish another mode/document's selection.
        observer.handler(document.assistantSelectionContext())
    }
}

// MARK: - Public wrapper

/// Drop-in workbench with the native Edit / Present switch. The host keeps its
/// own navigation and split view; this view only owns the two modes and their
/// contextual chrome.
public struct CADPresentationWorkbenchView: View {
    private let document: FloeCADDocument
    private let canvasActions: CADCanvasActions?

    public init(document: FloeCADDocument, canvasActions: CADCanvasActions? = nil) {
        self.document = document
        self.canvasActions = canvasActions
    }

    public var body: some View {
        CADPresentationWorkbenchContent(document: document,
                                        canvasActions: canvasActions)
            .modifier(CADPresentationSelectionObserver(document: document))
            // A new package at the same navigation position must not inherit
            // the previous document's Present store, camera or capture handle.
            // A reopened live owner at the same URL is a different session.
            .id(ObjectIdentifier(document))
            // Edit's editor view owns this same compact title. Present has no
            // editor view, so the shared wrapper keeps it in both modes
            // instead of leaving a blank navigation bar above Present.
            .navigationTitle(document.name)
            .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Capture connector

public nonisolated struct CADPresentationCapture: Sendable, Equatable {
    public var pngData: Data
    public var width: Int
    public var height: Int
    public var revision: Int
    public var changeCount: Int
    public var documentKey: String
    /// Source identity of the document (revision-bound content digest).
    public var contentSHA256: String
    /// SHA-256 of the PNG bytes (image identity).
    public var imageSHA256: String
    public var capturedAt: Date
    /// Live projection the captured pixels actually used (`perspective` /
    /// `orthographic`).
    public var projection: String
    /// Selected saved view at capture time, when one exists.
    public var cameraName: String?
    /// Whether the live camera still shows that saved view. Nil when no view
    /// is selected. A temporary orbit reports false without changing the view.
    public var matchesSavedCamera: Bool?
    /// Concise description of the actual camera state for the host/AI.
    public var note: String
    /// X22: the captured pixels contain the persisted section cut.
    public var sectionCutIncluded: Bool
    /// X22: saved measurement guides drawn in the captured pixels.
    public var measurementGuideCount: Int
    /// Exact measured lengths (millimetres) of those guides, in draw order.
    public var measurementLengthsMM: [Double]
    /// Installed scene/build identity that produced these exact pixels.
    public var sceneBuildKey: String

    /// Compatibility alias for the host bridge that already reads the PNG
    /// digest. `imageSHA256` is the canonical name; `contentSHA256` remains the
    /// source identity and must never be substituted here.
    public var sha256: String { imageSHA256 }

    public init(pngData: Data, width: Int, height: Int, revision: Int,
                changeCount: Int, documentKey: String, contentSHA256: String,
                imageSHA256: String, capturedAt: Date,
                projection: String = "", cameraName: String? = nil,
                matchesSavedCamera: Bool? = nil, note: String = "",
                sectionCutIncluded: Bool = false,
                measurementGuideCount: Int = 0,
                measurementLengthsMM: [Double] = [],
                sceneBuildKey: String = "") {
        self.pngData = pngData
        self.width = width
        self.height = height
        self.revision = revision
        self.changeCount = changeCount
        self.documentKey = documentKey
        self.contentSHA256 = contentSHA256
        self.imageSHA256 = imageSHA256
        self.capturedAt = capturedAt
        self.projection = projection
        self.cameraName = cameraName
        self.matchesSavedCamera = matchesSavedCamera
        self.note = note
        self.sectionCutIncluded = sectionCutIncluded
        self.measurementGuideCount = measurementGuideCount
        self.measurementLengthsMM = measurementLengthsMM
        self.sceneBuildKey = sceneBuildKey
    }
}

public nonisolated enum CADPresentationCaptureError: Error, LocalizedError, Sendable {
    case notActive
    case stale
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notActive:
            return FloeCADStrings.text(
                "cad.present.error.notActive",
                "Present mode is not showing this document, so no presentation image was captured.")
        case .stale:
            return FloeCADStrings.text(
                "cad.present.error.stale",
                "The document changed during capture; the image was discarded.")
        case .failed(let message):
            return message
        }
    }
}

/// Live-presentation capture connector for the host and the assistant viewport
/// path. It returns the ACTUAL current RealityKit render bound to the open
/// document revision; when Present is not visible it reports `notActive` and
/// the caller must use the explicit engineering capture instead of an old
/// thumbnail. No GPU resource is retained after Present leaves.
@MainActor
public final class CADPresentationCaptureRegistry {
    public static let shared = CADPresentationCaptureRegistry()

    private final class WeakHandle {
        weak var handle: CADPresentationHandle?
        init(_ handle: CADPresentationHandle) { self.handle = handle }
    }

    private var handles: [String: WeakHandle] = [:]
    private var service = CADPresentationSnapshotService()

    private init() {}

    func register(_ handle: CADPresentationHandle, for document: FloeCADDocument) {
        handles[key(for: document)] = WeakHandle(handle)
    }

    func unregister(_ document: FloeCADDocument) {
        handles.removeValue(forKey: key(for: document))
    }

    public func isActive(for document: FloeCADDocument) -> Bool {
        handles[key(for: document)]?.handle?.controller != nil
    }

    /// The live Present handle for animation playback/capture/export. Nil when
    /// Present is not showing this document; callers must report that instead
    /// of substituting an image or an offscreen fake.
    func activeHandle(for document: FloeCADDocument) -> CADPresentationHandle? {
        guard let handle = handles[key(for: document)]?.handle,
              handle.controller != nil else { return nil }
        return handle
    }

    public func capture(document: FloeCADDocument,
                        width: Int = 2048) async throws -> CADPresentationCapture {
        guard let handle = handles[key(for: document)]?.handle,
              handle.controller != nil else {
            throw CADPresentationCaptureError.notActive
        }
        do {
            let snapshot = try await service.capture(handle: handle, document: document,
                                                     targetWidth: max(64, min(width, 4096)))
            let liveCamera = handle.currentCamera
            let selected = document.activeSavedCamera
            let projection = liveCamera?.projection.rawValue ?? ""
            let matches = selected.map { liveCamera?.matches($0) ?? false }
            let note: String
            if let selected {
                note = matches == true
                    ? "Actual live RealityKit Present render (\(projection)) "
                        + "showing saved view “\(selected.name)”. The saved view is unchanged."
                    : "Actual live RealityKit Present render (\(projection)); "
                        + "saved view “\(selected.name)” is selected but the live view "
                        + "was moved. The saved view is unchanged."
            } else {
                note = "Actual live RealityKit Present render (\(projection)); "
                    + "no saved view is selected."
            }
            // X22: report the overlay identity that belonged to the EXACT
            // stage captured, never a later document read. The service pinned
            // it before the await and refused if the stage or document moved.
            let sectionCut = snapshot.sectionCutIncluded
            let guideCount = snapshot.measurementGuideCount
            var overlayNote: String?
            if sectionCut || guideCount > 0 {
                if sectionCut, guideCount > 0 {
                    overlayNote = "Section cut and \(guideCount) measurement guide(s) are included."
                } else if sectionCut {
                    overlayNote = "Section cut is included; no measurement guides are drawn."
                } else {
                    overlayNote = "\(guideCount) measurement guide(s) are included."
                }
                if guideCount > 0 {
                    let values = snapshot.measurementLengthsMM.prefix(6).map {
                        String(format: "%.3f mm", $0)
                    }
                    overlayNote? += " Values: " + values.joined(separator: ", ")
                        + (guideCount > values.count ? ", …" : "")
                        + ". Values are listed here, not drawn into the pixels."
                }
            }
            let finalNote = [note, overlayNote].compactMap { $0 }.joined(separator: " ")
            return CADPresentationCapture(
                pngData: snapshot.pngData, width: snapshot.width,
                height: snapshot.height, revision: snapshot.revision,
                changeCount: snapshot.changeCount, documentKey: snapshot.documentKey,
                contentSHA256: snapshot.contentSHA256,
                imageSHA256: snapshot.imageSHA256,
                capturedAt: snapshot.capturedAt,
                projection: projection,
                cameraName: selected?.name,
                matchesSavedCamera: matches,
                note: finalNote,
                sectionCutIncluded: sectionCut,
                measurementGuideCount: guideCount,
                measurementLengthsMM: snapshot.measurementLengthsMM,
                sceneBuildKey: snapshot.sceneBuildKey)
        } catch let error as CADPresentationError {
            switch error {
            case .snapshotStale:
                throw CADPresentationCaptureError.stale
            case .snapshotCancelled:
                throw CADPresentationCaptureError.failed(error.localizedDescription)
            default:
                throw CADPresentationCaptureError.failed(error.localizedDescription)
            }
        }
    }

    private func key(for document: FloeCADDocument) -> String {
        document.url.standardizedFileURL.path
    }
}

// MARK: - File documents

struct PNGFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.png] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct MovieFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.mpeg4Movie] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct ZipFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.zip] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct GLBFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
#endif
