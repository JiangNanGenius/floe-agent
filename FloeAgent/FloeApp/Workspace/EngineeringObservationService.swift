// SPDX-License-Identifier: MPL-2.0
import Foundation
import SwiftUI
import UIKit
import FloeCore
import FloeWorkbench
import FloeWorkspace

/// Owns disposable read-only render jobs independently of any visible preview.
/// A job never imports the model, edits a document, or reuses another window's
/// camera/playback. Source and resource identities are rechecked after capture.
@MainActor
final class EngineeringObservationService {
    static let shared = EngineeringObservationService()
    private var activeJob: UUID?

    private final class ErrorBox { var message: String? }
    private struct Failure: Codable { let viewIndex: Int; let reason: String }
    private struct Summary: Encodable {
        let observationID: UUID
        let provenance: EngineeringPreviewProvenance
        let state: EngineeringSceneState
        let hierarchy: EngineeringSceneHierarchyPage
        let requestedFrames: Int
        let completedFrames: Int
        let partial: Bool
        let failures: [Failure]
        let sourceUnchanged: Bool
        let visualEvidence: String
    }
    private struct FrameReceipt: Encodable {
        let observationID: UUID
        let sourceSHA256: String
        let resources: [EngineeringPreviewProvenance.Resource]
        let imageSHA256: String
        let renderer: String
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
        guard package.backend == .threeGLTF else {
            throw FloeError.validationFailed("observe requires an original GLB/glTF scene.")
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
        if let clipIndex = request.clipIndex,
           session.sceneState?.clips.contains(where: { $0.index == clipIndex }) != true {
            throw FloeError.validationFailed("The requested animation clip is unavailable.")
        }
        guard let hierarchy = await session.sceneHierarchy(offset: request.nodeOffset, limit: request.nodeLimit),
              hierarchy.sourceSHA256 == package.provenance.sourceSHA256 else {
            throw FloeError.validationFailed("The scene hierarchy is not available for these source bytes.")
        }
        let capture = request.includeImages ? try await session.captureScene(.init(
            views: request.views.map { .init(azimuthDegrees: $0.azimuthDegrees,
                elevationDegrees: $0.elevationDegrees, distanceScale: $0.distanceScale) },
            width: request.width, height: request.height,
            clipIndex: request.clipIndex, timeSeconds: request.timeSeconds,
            maximumFrames: request.views.count, maximumPNGBytes: 8 * 1024 * 1024,
            maximumTotalBytes: 32 * 1024 * 1024)) : EngineeringSceneCaptureResult(frames: [], failures: [])
        try Task.checkCancellation()
        guard (!request.includeImages || !capture.frames.isEmpty),
              capture.frames.allSatisfy({ $0.sourceSHA256 == package.provenance.sourceSHA256 }),
              let state = session.sceneState, state.ready,
              state.sourceSHA256 == package.provenance.sourceSHA256 else {
            throw FloeError.validationFailed("The scene did not return current, source-bound images.")
        }
        // The main file alone is insufficient identity for external .gltf
        // resources. A changed texture or buffer invalidates every old frame.
        let current = try await load(path: path, service: service, limits: limits)
        guard current.provenance == package.provenance else {
            throw FloeError.validationFailed("The model or one of its resources changed during capture. Observe it again.")
        }
        let frames = try capture.frames.map { frame in
            let receipt = FrameReceipt(observationID: jobID,
                sourceSHA256: frame.sourceSHA256, resources: package.provenance.resources,
                imageSHA256: frame.pngSHA256, renderer: "threeGLTF",
                viewIndex: frame.viewIndex, width: frame.width, height: frame.height,
                azimuthDegrees: frame.azimuthDegrees, elevationDegrees: frame.elevationDegrees,
                timeSeconds: frame.timeSeconds, clipIndex: frame.clipIndex, state: frame.state)
            return CadModelObservationFrame(pngData: frame.pngData,
                                             metadataJSON: try json(receipt))
        }
        let summary = Summary(observationID: jobID, provenance: package.provenance,
            state: state, hierarchy: hierarchy, requestedFrames: request.includeImages ? request.views.count : 0,
            completedFrames: frames.count,
            partial: (request.includeImages && frames.count != request.views.count)
                || !capture.failures.isEmpty || !state.missingResources.isEmpty
                || !state.unsupportedExtensions.isEmpty || !package.diagnostics.warnings.isEmpty,
            failures: capture.failures.map { .init(viewIndex: $0.viewIndex, reason: $0.reason) },
            sourceUnchanged: true,
            visualEvidence: "Actual original-scene pixels, not CAD topology. Inspect images only with a vision-capable route; re-observe after any source or resource edit.")
        return CadModelObservationResult(summaryJSON: try json(summary), frames: frames)
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
