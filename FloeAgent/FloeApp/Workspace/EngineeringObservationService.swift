// SPDX-License-Identifier: MPL-2.0
import Foundation
import ImageIO
import SwiftUI
import UIKit
import FloeCore
import FloeWorkbench
import FloeWorkspace

/// Owns disposable read-only render jobs independently of any visible preview.
/// A job never imports the model, edits a document, or reuses another window's
/// camera/playback. Source and resource identities are rechecked after capture.
///
/// The same typed scene contract covers the three original-file routes:
/// GLB/glTF keeps the bundled three.js scene path; other meshes render through
/// the bundled Online3DViewer static importer; STEP/IGES/BREP keep the local
/// OCCT display-triangulation conversion before that same static renderer.
@MainActor
final class EngineeringObservationService {
    static let shared = EngineeringObservationService()
    private var activeJob: UUID?

    private final class ErrorBox { var message: String? }
    private struct Failure: Codable { let viewIndex: Int; let reason: String }
    private struct Summary: Encodable {
        let observationID: UUID
        let provenance: EngineeringPreviewProvenance
        let backend: String
        let state: EngineeringSceneState
        let hierarchy: EngineeringSceneHierarchyPage
        let requestedFrames: Int
        let completedFrames: Int
        let partial: Bool
        let failures: [Failure]
        let sourceUnchanged: Bool
        let visualEvidence: String
        let limitations: [String]
    }
    private struct FrameReceipt: Encodable {
        let observationID: UUID
        let sourceSHA256: String
        let resources: [EngineeringPreviewProvenance.Resource]
        let imageSHA256: String
        let renderer: String
        let projection: String
        let viewIndex: Int
        let width: Int
        let height: Int
        let azimuthDegrees: Double
        let elevationDegrees: Double
        let timeSeconds: Double
        let clipIndex: Int?
        let state: EngineeringSceneState?
    }

    func observe(path: String, service: WorkspaceFileService,
                 request: CadModelObservationRequest) async throws -> CadModelObservationResult {
        try request.validate()
        // A single job bounds WebGL memory without tying the job to view lifetime.
        while activeJob != nil {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(100))
        }
        try Task.checkCancellation()
        let jobID = UUID()
        activeJob = jobID
        let session = EngineeringWebSession()
        defer {
            session.web?.removeFromSuperview()
            session.tearDown()
            if activeJob == jobID { activeJob = nil }
        }
        let limits = EngineeringPreviewLimits(maximumBytes: request.maximumSourceBytes,
                                              maximumFiles: request.maximumResources)
        let package = try await load(path: path, service: service, limits: limits)
        guard let backend = package.backend,
              backend == .threeGLTF || backend == .online3DViewer || backend == .occt else {
            throw FloeError.validationFailed(
                "observe reads original mesh and CAD-surface files (STL, OBJ, PLY, OFF, 3DS, DAE, FBX, 3MF, AMF, WRL, BIM, STEP, IGES, BREP, GLB, glTF). Native .floecad uses capture/query/measure; drawings, Gerber and other formats use their existing tools.")
        }
        let isGLTFScene = backend == .threeGLTF
        if !isGLTFScene {
            // A static renderer has one display scene and no camera/clip/time
            // authority. Refuse an unsupported selection instead of quietly
            // returning the first static frame as if the request succeeded.
            if let sceneIndex = request.sceneIndex, sceneIndex != 0 {
                throw FloeError.validationFailed(
                    "This original static model has one display scene; use sceneIndex 0 or omit it.")
            }
            if request.cameraIndex != nil {
                throw FloeError.validationFailed(
                    "This original static model has no source scene cameras; omit cameraIndex.")
            }
            if request.clipIndex != nil {
                throw FloeError.validationFailed(
                    "This original static model has no animation clips; omit clipIndex.")
            }
            if let time = request.timeSeconds, time > 0 {
                throw FloeError.validationFailed(
                    "This original static model has no animation timeline; omit timeSeconds or use 0.")
            }
        }
        if let expected = request.expectedSourceSHA256,
           package.provenance.sourceSHA256.lowercased() != expected.lowercased() {
            throw FloeError.validationFailed("Model bytes changed; read the current model before observing it.")
        }
        guard package.diagnostics.isScenePreviewAvailable else {
            let details = package.diagnostics.blockingIssues.map { "\($0.code.rawValue): \($0.detail)" }
                .joined(separator: "; ")
            throw FloeError.validationFailed("The original scene cannot be rendered completely: \(details)")
        }
        let errors = ErrorBox()
        let web = session.attach(package: package,
            identity: "observation:\(jobID.uuidString)",
            error: Binding(get: { errors.message }, set: { errors.message = $0 }),
            onReview: nil, onSave: nil, onDirty: nil,
            dark: false, locale: Locale.current.identifier)
        web.frame = CGRect(x: 0, y: 0, width: CGFloat(request.width), height: CGFloat(request.height))
        web.layoutIfNeeded()
        let deadline = ContinuousClock.now.advanced(by: .seconds(65))
        while session.sceneState?.ready != true {
            try Task.checkCancellation()
            if let error = errors.message { throw FloeError.validationFailed(error) }
            guard ContinuousClock.now < deadline else {
                throw FloeError.validationFailed("The scene did not finish loading. Retry the observation.")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        if let sceneIndex = request.sceneIndex {
            guard let selected = await session.sceneCommand(.selectScene(index: sceneIndex)),
                  selected.activeSceneIndex == sceneIndex else {
                throw FloeError.validationFailed("The requested scene is unavailable.")
            }
        }
        if let cameraIndex = request.cameraIndex {
            guard let selected = await session.sceneCommand(.selectCamera(index: cameraIndex)),
                  selected.activeCameraIndex == cameraIndex else {
                throw FloeError.validationFailed("The requested scene camera is unavailable.")
            }
        }
        try Task.checkCancellation()
        guard let loadedState = session.sceneState, loadedState.ready else {
            throw FloeError.validationFailed("The scene did not report a ready state.")
        }
        if isGLTFScene {
            if let clipIndex = request.clipIndex,
               loadedState.clips.contains(where: { $0.index == clipIndex }) != true {
                throw FloeError.validationFailed("The requested animation clip is unavailable.")
            }
            if let time = request.timeSeconds, time > 0 {
                let clipIndex = request.clipIndex ?? loadedState.activeClipIndex
                guard let clipIndex,
                      let clip = loadedState.clips.first(where: { $0.index == clipIndex }) else {
                    throw FloeError.validationFailed(
                        "The requested animation time requires an available clip.")
                }
                guard time <= clip.durationSeconds + 0.001 else {
                    throw FloeError.validationFailed(
                        "The requested animation time is outside the selected clip.")
                }
            }
        }
        let requestedProjection = sceneProjection(request.projection)
        guard let hierarchy = await session.sceneHierarchy(offset: request.nodeOffset, limit: request.nodeLimit),
              hierarchy.sourceSHA256 == package.provenance.sourceSHA256 else {
            throw FloeError.validationFailed("The scene hierarchy is not available for these source bytes.")
        }
        let capture = request.includeImages ? try await session.captureScene(.init(
            views: request.views.map { .init(azimuthDegrees: $0.azimuthDegrees,
                elevationDegrees: $0.elevationDegrees, distanceScale: $0.distanceScale) },
            width: request.width, height: request.height,
            clipIndex: request.clipIndex, timeSeconds: request.timeSeconds,
            projection: requestedProjection,
            maximumFrames: request.views.count, maximumPNGBytes: 8 * 1024 * 1024,
            maximumTotalBytes: 32 * 1024 * 1024)) : EngineeringSceneCaptureResult(frames: [], failures: [])
        try Task.checkCancellation()
        let expectedRenderer = isGLTFScene ? "threeGLTF" : "online3DViewer"
        let expectedStateBackend = backend.rawValue
        if request.includeImages && capture.frames.isEmpty {
            throw FloeError.validationFailed(capture.failures.first?.reason
                ?? "The scene returned no image. Retry the observation.")
        }
        guard capture.frames.allSatisfy({ $0.sourceSHA256 == package.provenance.sourceSHA256 }),
              capture.frames.allSatisfy({ $0.renderer == expectedRenderer }),
              capture.frames.allSatisfy({ requestedProjection == nil || $0.projection == requestedProjection }),
              let state = session.sceneState, state.ready,
              state.sourceSHA256 == package.provenance.sourceSHA256,
              state.backend == expectedStateBackend else {
            throw FloeError.validationFailed("The scene did not return current, source-bound images.")
        }
        for frame in capture.frames {
            try validateFramePNG(frame)
        }
        // The main file alone is insufficient identity for external resources.
        // A changed texture, buffer or OBJ/MTL dependency invalidates every old
        // frame, so the exact same package is loaded again before returning.
        let current = try await load(path: path, service: service, limits: limits)
        guard current.provenance == package.provenance else {
            throw FloeError.validationFailed("The model or one of its resources changed during capture. Observe it again.")
        }
        let frames = try capture.frames.map { frame in
            let receipt = FrameReceipt(observationID: jobID,
                sourceSHA256: frame.sourceSHA256, resources: package.provenance.resources,
                imageSHA256: frame.pngSHA256, renderer: frame.renderer,
                projection: frame.projection.rawValue,
                viewIndex: frame.viewIndex, width: frame.width, height: frame.height,
                azimuthDegrees: frame.azimuthDegrees, elevationDegrees: frame.elevationDegrees,
                timeSeconds: frame.timeSeconds, clipIndex: frame.clipIndex, state: frame.state)
            return CadModelObservationFrame(pngData: frame.pngData,
                                             metadataJSON: try json(receipt))
        }
        let summary = Summary(observationID: jobID, provenance: package.provenance,
            backend: expectedStateBackend, state: state, hierarchy: hierarchy,
            requestedFrames: request.includeImages ? request.views.count : 0,
            completedFrames: frames.count,
            partial: (request.includeImages && frames.count != request.views.count)
                || !capture.failures.isEmpty || !state.missingResources.isEmpty
                || !state.unsupportedExtensions.isEmpty || !state.warnings.isEmpty
                || !package.diagnostics.warnings.isEmpty,
            failures: capture.failures.map { .init(viewIndex: $0.viewIndex, reason: $0.reason) },
            sourceUnchanged: true,
            visualEvidence: visualEvidence(for: backend),
            limitations: limitations(for: backend))
        return CadModelObservationResult(summaryJSON: try json(summary), frames: frames)
    }

    private func sceneProjection(_ projection: CadModelObservationProjection?)
        -> EngineeringSceneProjection? {
        guard let projection else { return nil }
        switch projection {
        case .perspective: return .perspective
        case .orthographic: return .orthographic
        }
    }

    /// Checks the actual PNG container dimensions against the frame metadata.
    /// A renderer that reports requested dimensions but returned different
    /// pixels must fail here rather than become trusted vision evidence.
    private func validateFramePNG(_ frame: EngineeringSceneCaptureFrame) throws {
        guard !frame.pngData.isEmpty,
              frame.pngData.count <= 16 * 1024 * 1024,
              (64...2048).contains(frame.width), (64...2048).contains(frame.height),
              let source = CGImageSourceCreateWithData(frame.pngData as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width == frame.width, height == frame.height else {
            throw FloeError.validationFailed(
                "The model observer did not return bounded PNG frames with actual dimensions.")
        }
    }

    private func visualEvidence(for backend: EngineeringPreviewBackend) -> String {
        switch backend {
        case .threeGLTF:
            return "Actual original glTF scene pixels, not CAD topology. Inspect images only with a vision-capable route; re-observe after any source or resource edit."
        case .online3DViewer:
            return "Actual original display-mesh pixels from the bundled Online3DViewer, not CAD topology. Pixel coordinates are not CAD face IDs; re-observe after any source or resource edit."
        case .occt:
            return "Actual pixels of the original CAD surface's display triangulation rendered by the bundled Online3DViewer after local OCCT conversion; this is not native editable B-Rep or CAD topology. Re-observe after any source change."
        case .dxfViewer, .gerber:
            return ""
        }
    }

    private func limitations(for backend: EngineeringPreviewBackend) -> [String] {
        switch backend {
        case .threeGLTF:
            return ["Rendered glTF scene only. Hierarchy, skins, morph targets, cameras and clips describe the actual local scene; this is not a CAD import, measurement or manufacturing approval."]
        case .online3DViewer:
            return ["Rendered original display mesh only. Node names/counts, mesh instances, materials and world bounds come from the imported original, but the result is not a CAD feature tree and pixels do not establish face IDs, dimensions or tolerances. Only explicit OBJ/MTL and glTF sibling resources are auto-collected; other formats may omit external resources."]
        case .occt:
            return ["The original CAD surface was tessellated by the local OCCT worker for display. Names, colors, exact analytic surfaces, tolerances and the complete source scene may be limited; this is not native editable B-Rep or a manufacturing approval."]
        case .dxfViewer, .gerber:
            return []
        }
    }

    private func load(path: String, service: WorkspaceFileService,
                      limits: EngineeringPreviewLimits) async throws -> EngineeringPreviewPackage {
        let loader = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try EngineeringPreviewPackage.load(path: path, service: service, limits: limits)
        }
        let package = try await withTaskCancellationHandler {
            try await loader.value
        } onCancel: { loader.cancel() }
        try Task.checkCancellation()
        return package
    }

    private func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
