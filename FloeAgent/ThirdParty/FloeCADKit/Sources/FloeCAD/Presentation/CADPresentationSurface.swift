//
//  CADPresentationSurface.swift
//  FloeCADKit
//
//  The RealityKit presentation surface. One ARView (non-AR), one stage entity,
//  one resource cache and one camera. The stage is moved by the camera's
//  inverse view transform so orbit/pan/zoom never create a second scene, and
//  the ARView's own camera stays where RealityKit expects it.
//
//  Scene builds are asynchronous and fenced by (documentKey, changeCount):
//  switching documents, editing, or leaving Present cancels the previous job
//  and can never apply a stale stage.
//

#if canImport(SwiftUI) && canImport(RealityKit) && canImport(UIKit)
import Foundation
import Observation
import RealityKit
import SwiftUI
import UIKit
import simd

// MARK: - Errors

nonisolated enum CADPresentationError: Error, LocalizedError, Sendable {
    case renderingUnavailable
    case notAttached
    case snapshotStale
    case snapshotFailed
    case snapshotCancelled

    var errorDescription: String? {
        switch self {
        case .renderingUnavailable:
            return FloeCADStrings.text(
                "cad.present.error.unavailable",
                "The 3D presentation renderer is unavailable on this device.")
        case .notAttached:
            return FloeCADStrings.text(
                "cad.present.error.notAttached",
                "Show Present before capturing an image.")
        case .snapshotStale:
            return FloeCADStrings.text(
                "cad.present.error.stale",
                "The model changed while the image was being captured, so the image was discarded.")
        case .snapshotFailed:
            return FloeCADStrings.text(
                "cad.present.error.capture",
                "The presentation could not be captured.")
        case .snapshotCancelled:
            return FloeCADStrings.text(
                "cad.present.error.cancelled",
                "The capture was cancelled.")
        }
    }
}

// MARK: - Snapshot result

nonisolated struct CADPresentationSnapshot: Sendable, Equatable {
    var pngData: Data
    var width: Int
    var height: Int
    var revision: Int
    var changeCount: Int
    var documentKey: String
    /// Source identity of the document whose render this is.
    var contentSHA256: String
    /// SHA-256 of the encoded PNG itself (image identity, not source identity).
    var imageSHA256: String
    var capturedAt: Date
    var note: String
}

// MARK: - Handle

/// Stable object the workbench toolbar can use for Fit and Screenshot/Export.
/// It holds the controller weakly so leaving Present releases every GPU
/// resource even if a sheet or task still references the handle.
@MainActor
@Observable
final class CADPresentationHandle {
    @ObservationIgnored weak var controller: CADPresentationRenderController?
    /// Latest reported issues (missing images, unsupported face display,
    /// stale bindings). The UI shows these in a details section, never as
    /// fake success.
    private(set) var issues: [CADPresentationIssue] = []
    private(set) var isReady = false
    private(set) var lastBuiltKey: String?
    /// Set only when the RealityKit build actually failed; the host can offer
    /// the engineering viewport without implying the geometry was lost.
    private(set) var failureMessage: String?
    /// Camera pose remembered across a Present/Edit switch. GPU resources are
    /// still released on exit; only the value camera survives.
    var savedCamera: CADPresentationCamera?

    var bounds: CADPresentationBounds? { controller?.currentBounds }

    func fit() {
        controller?.fit()
    }

    func setIssues(_ issues: [CADPresentationIssue]) {
        self.issues = issues
    }

    func markReady(_ ready: Bool) {
        isReady = ready
    }

    func markBuilt(_ key: String?) {
        lastBuiltKey = key
    }

    func markFailure(_ message: String?) {
        failureMessage = message
    }
}

// MARK: - Controller

@MainActor
final class CADPresentationRenderController: NSObject, UIGestureRecognizerDelegate {
    let arView: ARView
    let cache = CADPresentationResourceCache()
    private let builder: CADPresentationEntityBuilder
    private let anchor = AnchorEntity(world: .zero)
    /// Explicit non-AR camera. RealityKit expects the app to provide the
    /// camera in non-AR mode; without one the implicit default camera is what
    /// renders, so the stage's fitted inverse-view transform does not own the
    /// visible framing. The observed Present view framed the whole 2 m ground
    /// plane instead of the fitted model, which is why Fit appeared inert.
    private let cameraEntity = PerspectiveCamera()
    private var stage: Entity?
    private var camera = CADPresentationCamera()
    private var cameraRestored = false
    private var currentScene: CADPresentationScene?
    private var bodyEntities: [UUID: CADPresentationBodyNodes] = [:]
    private var originalMaterials: [ObjectIdentifier: [any RealityFoundation.Material]] = [:]
    private var buildKey: String?
    private var buildTask: Task<Void, Never>?
    private var environmentTask: Task<Void, Never>?
    private(set) var currentBounds: CADPresentationBounds?
    private(set) var issues: [CADPresentationIssue] = []
    /// Camera/environment/build identity of the pixels the ARView currently
    /// shows. Export caches must include this or a moved camera would return
    /// an old picture for the same document revision.
    var renderStateToken: String {
        var hasher = Hasher()
        hasher.combine(camera.target)
        hasher.combine(camera.distance)
        hasher.combine(camera.azimuthRadians)
        hasher.combine(camera.elevationRadians)
        hasher.combine(camera.fovYDegrees)
        hasher.combine(currentScene?.environment.stableKey)
        hasher.combine(buildKey)
        hasher.combine(arView.bounds.width)
        hasher.combine(arView.bounds.height)
        return "render-\(hasher.finalize())"
    }
    weak var handle: CADPresentationHandle?

    private var orbitStartCamera: CADPresentationCamera?
    private var lastPanTranslation: CGPoint = .zero
    private let doubleTap = UITapGestureRecognizer()

    override init() {
        arView = ARView(frame: .zero, cameraMode: .nonAR,
                        automaticallyConfigureSession: false)
        builder = CADPresentationEntityBuilder(cache: cache)
        super.init()
        arView.backgroundColor = .clear
        cameraEntity.name = "CADPresentationCamera"
        cameraEntity.camera.fieldOfViewInDegrees = camera.fovYDegrees
        cameraEntity.camera.fieldOfViewOrientation = .vertical
        anchor.addChild(cameraEntity)
        arView.scene.addAnchor(anchor)
        installGestures()
    }

    /// One place that keeps the camera component and the stage's inverse view
    /// transform in sync. The camera stays at the anchor origin looking down
    /// −Z; every orbit/pan/zoom/fit moves the stage by the inverse camera
    /// matrix, exactly as `CADPresentationCamera.stageTransform` defines.
    private func applyCamera() {
        cameraEntity.camera.fieldOfViewInDegrees = camera.fovYDegrees
        stage?.transform = Transform(matrix: camera.stageTransform)
    }

    private var viewportAspect: Float? {
        let size = arView.bounds.size
        guard size.width > 1, size.height > 1 else { return nil }
        return Float(size.width / size.height)
    }

    // MARK: Attachment

    func attach(handle: CADPresentationHandle) {
        self.handle = handle
    }

    func apply(_ scene: CADPresentationScene) {
        currentScene = scene
        currentBounds = scene.bounds
        if buildKey == scene.buildKey, stage != nil {
            // Material-only changes still produce a new key; reaching here
            // means the same bytes/environment, so nothing is rebuilt.
            return
        }
        buildTask?.cancel()
        let token = scene.buildKey
        buildTask = Task { [weak self] in
            guard let self else { return }
            await self.build(scene: scene, token: token)
        }
    }

    private func build(scene: CADPresentationScene, token: String) async {
        do {
            let result = try await builder.build(scene: scene)
            try Task.checkCancellation()
            guard currentScene?.buildKey == token else { return }
            if let existing = stage {
                existing.removeFromParent()
            }
            stage = result.stage
            bodyEntities = result.bodyEntities
            originalMaterials.removeAll()
            anchor.addChild(result.stage)
            issues = result.issues
            handle?.setIssues(issues)
            if buildKey == nil && !cameraRestored {
                camera = CADPresentationCamera.fitted(
                    to: scene.bounds, aspect: viewportAspect)
            }
            camera.fitIfInvalid(scene.bounds, aspect: viewportAspect)
            applyCamera()
            await applyBackground(scene.environment)
            buildKey = token
            handle?.markFailure(nil)
            handle?.markReady(true)
            handle?.markBuilt(token)
        } catch is CancellationError {
            return
        } catch {
            issues = scene.issues + [CADPresentationIssue(
                id: "build-failed", kind: .corruptMaterial,
                bodyID: nil, bodyName: nil,
                detail: "The 3D presentation could not finish on this device; the engineering viewport and the model remain available.")]
            handle?.setIssues(issues)
            handle?.markReady(false)
            handle?.markFailure(FloeCADStrings.text(
                "cad.present.fallback.message",
                "Present couldn't start on this device. Your model is unchanged; Edit still shows it."))
        }
    }

    func release() {
        buildTask?.cancel()
        environmentTask?.cancel()
        buildTask = nil
        environmentTask = nil
        handle?.savedCamera = camera
        stage?.removeFromParent()
        stage = nil
        bodyEntities.removeAll()
        originalMaterials.removeAll()
        anchor.removeFromParent()
        cache.dispose()
        buildKey = nil
        currentScene = nil
        issues = []
        handle?.setIssues([])
        handle?.markReady(false)
        handle?.markFailure(nil)
        handle?.controller = nil
        handle = nil
    }

    // MARK: Environment

    /// Live preview of an uncommitted appearance draft. The caller applies the
    /// document command only when the user taps Apply.
    func preview(environment: CADPresentationEnvironment) {
        environmentTask?.cancel()
        environmentTask = Task { [weak self] in
            guard let self, let stage = self.stage else { return }
            await self.builder.applyEnvironment(environment, to: stage,
                                                cache: self.cache)
            await self.applyBackground(environment)
            if let resource = await self.cache.environment(for: environment) {
                var lighting = self.arView.environment.lighting
                lighting.resource = resource
                lighting.intensityExponent = 0
                self.arView.environment.lighting = lighting
            }
        }
    }

    private func applyBackground(_ environment: CADPresentationEnvironment) async {
        let color = UIColor(
            red: CGFloat(environment.backgroundColor.x),
            green: CGFloat(environment.backgroundColor.y),
            blue: CGFloat(environment.backgroundColor.z),
            alpha: 1)
        var environmentValue = arView.environment
        environmentValue.background = .color(color)
        if let resource = await cache.environment(for: environment) {
            environmentValue.lighting.resource = resource
            environmentValue.lighting.intensityExponent = 0
        }
        arView.environment = environmentValue
    }

    // MARK: Material draft preview

    /// Local preview of an uncommitted inspector draft. No document command,
    /// no undo record and no rebuild of the mesh: only the material of the
    /// affected body entities is swapped and later restored.
    func previewMaterial(_ spec: BodyMaterialSpec, for target: CADMaterialTarget) async {
        guard let scene = currentScene else { return }
        var ids = Set(target.bodyIDs)
        if let faceBodyID = target.faceBodyID { ids.insert(faceBodyID) }
        // A source-body material edit must preview every assembly instance
        // that reuses it. The entity identity stays the instance ID; the
        // source ID is only the selection key.
        for body in scene.bodies where body.matchesMaterialTarget(ids) {
            guard let nodes = bodyEntities[body.id] else { continue }
            let faceGroup: CADPresentationFaceGroup?
            var targets: [ModelEntity]
            if target.isFaceTarget {
                // A face preview must never fall back to repainting the whole
                // body. If the current scene has no entity for this face, the
                // mapping is stale and the preview is skipped.
                guard let faceIndex = target.faceIndex,
                      let group = body.faceGroups.first(where: {
                          $0.faceIndex == faceIndex
                      }),
                      let faceEntity = nodes.faceEntities[faceIndex] else { continue }
                faceGroup = group
                targets = [faceEntity]
            } else {
                faceGroup = nil
                targets = nodes.entities
            }
            let hasUVs = faceGroup?.uvs != nil || body.mesh.uvs != nil
            let material = await builder.previewMaterial(
                spec: spec,
                bodyID: body.id,
                bodyName: body.name,
                hasUVs: hasUVs)
            for entity in targets {
                let key = ObjectIdentifier(entity)
                if originalMaterials[key] == nil {
                    originalMaterials[key] = entity.model?.materials ?? []
                }
                entity.model?.materials = [material]
            }
        }
    }

    func endMaterialPreview() {
        let nodes = bodyEntities
        for (identifier, materials) in originalMaterials {
            guard !materials.isEmpty else { continue }
            for bodyNodes in nodes.values {
                for entity in bodyNodes.entities
                where ObjectIdentifier(entity) == identifier {
                    entity.model?.materials = materials
                }
            }
        }
        originalMaterials.removeAll()
    }

    // MARK: Camera

    func restoreCamera(_ saved: CADPresentationCamera) {
        guard saved.isValid else { return }
        camera = saved
        cameraRestored = true
        applyCamera()
    }

    func fit() {
        camera.fit(currentBounds, aspect: viewportAspect)
        applyCamera()
    }

    private func updateCameraTransform() {
        guard camera.isValid else { return }
        applyCamera()
    }

    // MARK: Gestures

    private func installGestures() {
        let orbit = UIPanGestureRecognizer(target: self, action: #selector(handleOrbit(_:)))
        orbit.minimumNumberOfTouches = 1
        orbit.maximumNumberOfTouches = 1
        orbit.delegate = self
        arView.addGestureRecognizer(orbit)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        pan.delegate = self
        arView.addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        arView.addGestureRecognizer(pinch)

        doubleTap.numberOfTapsRequired = 2
        doubleTap.addTarget(self, action: #selector(handleDoubleTap))
        arView.addGestureRecognizer(doubleTap)
    }

    @objc private func handleOrbit(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            orbitStartCamera = camera
        case .changed:
            guard orbitStartCamera != nil else { return }
            let translation = recognizer.translation(in: arView)
            var updated = camera
            updated.orbit(delta: SIMD2(Float(translation.x), Float(translation.y)))
            camera = updated
            updateCameraTransform()
        case .ended, .cancelled, .failed:
            orbitStartCamera = nil
        default:
            break
        }
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: arView)
        if recognizer.state == .began {
            lastPanTranslation = translation
            return
        }
        guard recognizer.state == .changed else {
            if recognizer.state == .ended || recognizer.state == .cancelled {
                lastPanTranslation = .zero
            }
            return
        }
        let delta = CGPoint(x: translation.x - lastPanTranslation.x,
                            y: translation.y - lastPanTranslation.y)
        lastPanTranslation = translation
        camera.pan(delta: SIMD2(Float(delta.x), Float(delta.y)),
                   viewportHeight: Float(arView.bounds.height))
        updateCameraTransform()
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        guard recognizer.state == .changed else { return }
        camera.zoom(by: Float(recognizer.scale))
        recognizer.scale = 1
        updateCameraTransform()
    }

    @objc private func handleDoubleTap() {
        fit()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    // MARK: Capture

    /// Actual current ARView render. Refuses when the surface is not in a
    /// window; the caller binds the returned image to a document revision.
    func snapshotPNG(targetWidth: Int?) async throws -> (png: Data, width: Int, height: Int) {
        guard arView.window != nil else { throw CADPresentationError.notAttached }
        guard stage != nil else { throw CADPresentationError.renderingUnavailable }
        let image: UIImage? = await withCheckedContinuation { continuation in
            arView.snapshot(saveToHDR: false) { image in
                continuation.resume(returning: image)
            }
        }
        guard let image else { throw CADPresentationError.snapshotFailed }
        if Task.isCancelled { throw CADPresentationError.snapshotCancelled }
        let output: UIImage
        if let targetWidth, targetWidth > 0,
           Int(image.size.width * image.scale) != targetWidth {
            output = Self.resized(image, targetWidth: targetWidth)
        } else {
            output = image
        }
        guard let png = output.pngData() else { throw CADPresentationError.snapshotFailed }
        return (png, Int(output.size.width * output.scale),
                Int(output.size.height * output.scale))
    }

    private static func resized(_ image: UIImage, targetWidth: Int) -> UIImage {
        let pixelWidth = image.size.width * image.scale
        let ratio = CGFloat(targetWidth) / max(pixelWidth, 1)
        let size = CGSize(width: CGFloat(targetWidth),
                          height: max(1, (image.size.height * image.scale * ratio).rounded()))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

// MARK: - Camera fit helper

private extension CADPresentationCamera {
    mutating func fitIfInvalid(_ bounds: CADPresentationBounds?, aspect: Float?) {
        if !isValid {
            self = CADPresentationCamera.fitted(
                to: bounds, fovYDegrees: fovYDegrees, aspect: aspect)
        }
    }
}

// MARK: - SwiftUI host

struct CADPresentationSurface: UIViewRepresentable {
    let scene: CADPresentationScene
    let handle: CADPresentationHandle

    func makeUIView(context: Context) -> ARView {
        let controller = CADPresentationRenderController()
        controller.attach(handle: handle)
        if let saved = handle.savedCamera {
            controller.restoreCamera(saved)
        }
        handle.controller = controller
        context.coordinator.controller = controller
        controller.apply(scene)
        return controller.arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.controller?.apply(scene)
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        coordinator.controller?.release()
        coordinator.controller = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var controller: CADPresentationRenderController?
    }
}

// MARK: - Snapshot service

/// Captures and caches actual presentation renders. A capture is bound to the
/// exact document identity + live change count before and after the ARView
/// snapshot, so an edit during capture discards the image rather than
/// returning a picture of a half-applied model.
@MainActor
final class CADPresentationSnapshotService {
    private struct Entry {
        let snapshot: CADPresentationSnapshot
        let bytes: Int
    }

    private var cache: [String: Entry] = [:]
    private var order: [String] = []
    private var totalBytes = 0
    private let maximumEntries = 8
    private let maximumBytes = 160 * 1024 * 1024

    func capture(handle: CADPresentationHandle,
                 document: FloeCADDocument,
                 targetWidth: Int) async throws -> CADPresentationSnapshot {
        guard let controller = handle.controller else {
            throw CADPresentationError.notAttached
        }
        let documentKey = document.url.standardizedFileURL.path
        let revision = document.revision
        let changeCount = document.liveChangeCount
        let contentSHA256 = document.contentSHA256
        let stateBefore = controller.renderStateToken
        let keyBefore = "\(documentKey)|\(revision)|\(changeCount)|\(contentSHA256)|\(stateBefore)|\(targetWidth)"
        if let cached = cache[keyBefore] {
            return cached.snapshot
        }
        if Task.isCancelled { throw CADPresentationError.snapshotCancelled }
        let result = try await controller.snapshotPNG(targetWidth: targetWidth)
        if Task.isCancelled { throw CADPresentationError.snapshotCancelled }
        guard document.url.standardizedFileURL.path == documentKey,
              document.revision == revision,
              document.liveChangeCount == changeCount,
              document.contentSHA256 == contentSHA256 else {
            throw CADPresentationError.snapshotStale
        }
        let snapshot = CADPresentationSnapshot(
            pngData: result.png,
            width: result.width,
            height: result.height,
            revision: revision,
            changeCount: changeCount,
            documentKey: documentKey,
            contentSHA256: contentSHA256,
            imageSHA256: CADMaterialTexture.digest(result.png),
            capturedAt: Date(),
            note: "Actual current RealityKit presentation render bound to the open document revision.")
        let stateAfter = controller.renderStateToken
        let keyAfter = "\(documentKey)|\(revision)|\(changeCount)|\(contentSHA256)|\(stateAfter)|\(targetWidth)"
        store(snapshot, key: keyAfter)
        return snapshot
    }

    private func store(_ snapshot: CADPresentationSnapshot, key: String) {
        if let existing = cache[key] {
            totalBytes -= existing.bytes
        }
        cache[key] = Entry(snapshot: snapshot, bytes: snapshot.pngData.count)
        order.removeAll { $0 == key }
        order.append(key)
        totalBytes += snapshot.pngData.count
        while order.count > maximumEntries || totalBytes > maximumBytes {
            guard let oldest = order.first else { break }
            order.removeFirst()
            if let entry = cache.removeValue(forKey: oldest) {
                totalBytes -= entry.bytes
            }
        }
    }

    func clear() {
        cache.removeAll()
        order.removeAll()
        totalBytes = 0
    }
}

// MARK: - Labels

extension CADPresentationIssueKind {
    var symbolName: String {
        switch self {
        case .emptyBody, .malformedTransform: return "cube.transparent"
        case .corruptMaterial, .missingTexture, .imageDecodeFailed: return "photo.badge.exclamationmark"
        case .missingMeshUV: return "square.on.square.dashed"
        case .mixedTextureOrientation: return "arrow.up.arrow.down"
        case .faceMaterialDisplayUnsupported, .unresolvedFaceBindings:
            return "square.stack.3d.up.slash"
        }
    }
}

extension CADPresentationIssue {
    var localizedSummary: String {
        switch kind {
        case .emptyBody:
            return FloeCADStrings.text("cad.present.issue.emptyBody",
                                       "This body has no drawable geometry.")
        case .malformedTransform:
            return FloeCADStrings.text("cad.present.issue.transform",
                                       "This body's placement could not be read.")
        case .corruptMaterial:
            return FloeCADStrings.text("cad.present.issue.material",
                                       "Part of this material could not be read; the rest still renders.")
        case .missingTexture:
            return FloeCADStrings.text("cad.present.issue.texture",
                                       "An assigned texture image is missing.")
        case .missingMeshUV:
            return FloeCADStrings.text("cad.present.issue.uv",
                                       "Textures need a UV mapping for this body.")
        case .mixedTextureOrientation:
            return FloeCADStrings.text("cad.present.issue.orientation",
                                       "Texture maps use different vertical orientations.")
        case .faceMaterialDisplayUnsupported:
            return FloeCADStrings.format("cad.present.issue.faces",
                                         "%d face material(s) couldn't be matched to this body and aren't shown individually.",
                                         detailFaceCount)
        case .unresolvedFaceBindings:
            return FloeCADStrings.format("cad.present.issue.unresolved",
                                         "%d face assignment(s) need reselecting.",
                                         detailFaceCount)
        case .imageDecodeFailed:
            return FloeCADStrings.text("cad.present.issue.image",
                                       "A material image could not be decoded on this device.")
        }
    }

    private var detailFaceCount: Int {
        let digits = detail.prefix { $0.isNumber }
        return Int(digits) ?? 1
    }
}
#endif
