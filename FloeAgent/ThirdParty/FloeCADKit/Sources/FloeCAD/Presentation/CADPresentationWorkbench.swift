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
    @ObservationIgnored private var observationTask: Task<Void, Never>?

    init(document: FloeCADDocument) {
        self.document = document
    }

    func refresh(force: Bool = false) {
        let changeCount = document.liveChangeCount
        if !force, scene != nil, changeCount == lastChangeCount,
           scene?.documentRevision == document.revision {
            return
        }
        let snapshot = document.sceneSnapshot()
        scene = CADPresentationSceneBuilder.build(
            snapshot: snapshot,
            documentKey: document.url.standardizedFileURL.path)
        lastChangeCount = changeCount
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
    @State private var showIssues = false

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
            if let scene = store.scene {
                CADPresentationSurface(scene: scene, handle: handle)
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

// MARK: - Workbench content

struct CADPresentationWorkbenchContent: View {
    let document: FloeCADDocument
    let canvasActions: CADCanvasActions?

    @State private var mode: CADWorkbenchMode = .edit
    @State private var showMaterialInspector = false
    @State private var showEnvironmentInspector = false
    @State private var materialTarget: CADMaterialTarget = .empty
    @State private var handle = CADPresentationHandle()
    @State private var store: CADPresentationSceneStore
    @State private var presentSink = CADPresentationMaterialPreviewSink()
    @State private var snapshotService = CADPresentationSnapshotService()
    @State private var pngExport: PNGFileDocument?
    @State private var glbExport: GLBFileDocument?
    @State private var showPNGExporter = false
    @State private var showGLBExporter = false
    @State private var exportError: String?

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
            if mode == .present { presentToolbar }
        }
        .sheet(isPresented: $showMaterialInspector) {
            CADMaterialInspectorView(
                document: document,
                target: materialTarget,
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
        .fileExporter(isPresented: $showPNGExporter, document: pngExport,
                      contentType: .png, defaultFilename: "\(document.name) presentation") { _ in
            pngExport = nil
        }
        .fileExporter(isPresented: $showGLBExporter, document: glbExport,
                      contentType: .data, defaultFilename: "\(document.name)") { _ in
            glbExport = nil
        }
        .alert(FloeCADStrings.text("cad.present.export.failed", "Couldn't export"),
               isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } })) {
            Button(FloeCADStrings.text("cad.ui.common.done", "Done")) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
        .onChange(of: mode) { _, newMode in
            presentSink.endMaterialPreview()
            if newMode == .present {
                store.refresh(force: true)
            }
        }
    }

    // MARK: Chrome

    private var modeChrome: some View {
        HStack(spacing: 8) {
            Picker(FloeCADStrings.text("cad.workbench.mode", "Mode"), selection: $mode) {
                ForEach(CADWorkbenchMode.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 168)
            .accessibilityIdentifier("CADWorkbenchMode")
        }
        .padding(6)
        .background(.regularMaterial, in: Capsule())
        .padding(.top, 8)
        .padding(.trailing, 12)
        .animation(.default, value: mode)
    }

    private var presentToolbar: some View {
        HStack(spacing: 4) {
            presentButton(FloeCADStrings.text("cad.ui.tool.material", "Material"),
                          symbol: "paintpalette", identifier: "CADPresentMaterial") {
                openMaterialInspector()
            }
            presentButton(FloeCADStrings.text("cad.present.environment", "Environment"),
                          symbol: "sun.max", identifier: "CADPresentEnvironment") {
                showEnvironmentInspector = true
            }
            presentButton(FloeCADStrings.text("cad.present.fit", "Fit"),
                          symbol: "arrow.up.left.and.arrow.down.right",
                          identifier: "CADPresentFit") {
                handle.fit()
            }
            Menu {
                Button {
                    exportPNG()
                } label: {
                    Label(FloeCADStrings.text("cad.present.export.png", "PNG image"),
                          systemImage: "photo")
                }
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
        materialTarget = CADMaterialTargetResolver.resolve(viewModel: document.viewModel())
        presentSink.handle = handle
        showMaterialInspector = true
    }

    private func exportPNG() {
        Task {
            do {
                let snapshot = try await snapshotService.capture(
                    handle: handle, document: document, targetWidth: 2048)
                pngExport = PNGFileDocument(data: snapshot.pngData)
                showPNGExporter = true
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    private func exportGLB() {
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
            // A new package at the same navigation position must not inherit
            // the previous document's Present store, camera or capture handle.
            .id(document.url.standardizedFileURL.path)
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

    /// Compatibility alias for the host bridge that already reads the PNG
    /// digest. `imageSHA256` is the canonical name; `contentSHA256` remains the
    /// source identity and must never be substituted here.
    public var sha256: String { imageSHA256 }

    public init(pngData: Data, width: Int, height: Int, revision: Int,
                changeCount: Int, documentKey: String, contentSHA256: String,
                imageSHA256: String, capturedAt: Date) {
        self.pngData = pngData
        self.width = width
        self.height = height
        self.revision = revision
        self.changeCount = changeCount
        self.documentKey = documentKey
        self.contentSHA256 = contentSHA256
        self.imageSHA256 = imageSHA256
        self.capturedAt = capturedAt
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

    public func capture(document: FloeCADDocument,
                        width: Int = 2048) async throws -> CADPresentationCapture {
        guard let handle = handles[key(for: document)]?.handle,
              handle.controller != nil else {
            throw CADPresentationCaptureError.notActive
        }
        do {
            let snapshot = try await service.capture(handle: handle, document: document,
                                                     targetWidth: max(64, min(width, 4096)))
            return CADPresentationCapture(
                pngData: snapshot.pngData, width: snapshot.width,
                height: snapshot.height, revision: snapshot.revision,
                changeCount: snapshot.changeCount, documentKey: snapshot.documentKey,
                contentSHA256: snapshot.contentSHA256,
                imageSHA256: snapshot.imageSHA256,
                capturedAt: snapshot.capturedAt)
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
