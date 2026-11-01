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
    private(set) var selectionTitle: String?
    /// Camera pose remembered across a Present/Edit switch. GPU resources are
    /// still released on exit; only the value camera survives.
    var savedCamera: CADPresentationCamera?
    /// Present tap granularity. `.body` keeps the existing whole-body
    /// selection; `.face` refines a genuine hit on an unpainted body to the
    /// live face triangles. Runtime-only: changing it never edits the document
    /// or clears the current target.
    var selectionMode: CADPresentationSelectionMode = .body

    var bounds: CADPresentationBounds? { controller?.currentBounds }
    /// Current live camera; used by the timeline to capture a keyframe from
    /// exactly what the user is looking at.
    var currentCamera: CADPresentationCamera? { controller?.currentCamera }

    func fit() {
        controller?.fit()
    }

    /// The host control routes through here so a pending tap that began under
    /// the old granularity cannot finish under the new one.
    func setSelectionMode(_ mode: CADPresentationSelectionMode) {
        guard selectionMode != mode else { return }
        selectionMode = mode
        controller?.selectionModeDidChange()
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

    func markSelection(_ title: String?) { selectionTitle = title }

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
    private var pickTargets: [ObjectIdentifier: CADPresentationPick] = [:]
    private weak var selectionDocument: FloeCADDocument?
    private var selectionDecorations: [Entity] = []
    private var lastSelectionState: CADPresentationSelectionState?
    private var interactionGeneration: UInt64 = 0
    private var pendingTapStamp: CADPresentationSelectionStamp?
    private var pendingTapMode: CADPresentationSelectionMode?
    private var selectionRefinementTask: Task<Void, Never>?
    /// One render-only selection patch for the exact face selected on an
    /// unpainted body. It is never part of the document, has no collision, and
    /// lives under the body's existing transform.
    @MainActor
    private final class SelectionFacePatch {
        let target: SelectionFaceTarget
        let entity: ModelEntity
        let highlightMaterial: PhysicallyBasedMaterial
        var isPreviewing = false

        init(target: SelectionFaceTarget, entity: ModelEntity,
             highlightMaterial: PhysicallyBasedMaterial) {
            self.target = target
            self.entity = entity
            self.highlightMaterial = highlightMaterial
        }

        func restoreHighlight() {
            guard isPreviewing else { return }
            entity.model?.materials = [highlightMaterial]
            isPreviewing = false
        }
    }

    private struct SelectionFaceTarget: Equatable {
        var bodyID: UUID
        var triangles: [Int]
    }

    private var selectionFacePatch: SelectionFacePatch?
    private var selectionPatchTask: Task<Void, Never>?
    private var selectionPatchTarget: SelectionFaceTarget?
    private var originalMaterials: [ObjectIdentifier: [any RealityFoundation.Material]] = [:]
    private var buildKey: String?
    private var buildTask: Task<Void, Never>?
    private var environmentTask: Task<Void, Never>?
    private(set) var currentBounds: CADPresentationBounds?
    /// Bounds the ground is currently dressed against. This is normally the
    /// static scene bounds; during playback/export it follows the animated
    /// transforms so the floor never cuts a transient pose. It is separate
    /// from `currentBounds` because Fit should still frame the document pose.
    private var floorBounds: CADPresentationBounds?
    private(set) var issues: [CADPresentationIssue] = []
    /// Bumped whenever the stage is replaced or released. Playback and export
    /// capture it before touching the entities and refuse to apply a frame to
    /// a newer stage.
    private(set) var renderGeneration: UInt64 = 0
    /// Render-side animation state. `static` is the untransformed baseline.
    /// This is deliberately NOT document state: playback/scrub never creates a
    /// command and never writes the assembly.
    private var animationToken = "static"
    private var animationRestoreCamera: CADPresentationCamera?
    private var animationLease: UUID?
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
        hasher.combine(animationToken)
        hasher.combine(renderGeneration)
        if let selectionDocument {
            let state = CADPresentationSelection.state(document: selectionDocument)
            hasher.combine(state.bodyIDs.sorted { $0.uuidString < $1.uuidString })
            hasher.combine(state.instanceIDs.sorted { $0.uuidString < $1.uuidString })
            for face in state.faces { hasher.combine(face.bodyID); hasher.combine(face.triangles) }
            // The unpainted-face highlight patch is built after selection
            // resolves. A capture taken before/after it appears must not share
            // a cache key or it could return a highlight-less frame.
            hasher.combine(selectionFacePatch != nil)
        }
        hasher.combine(arView.bounds.width)
        hasher.combine(arView.bounds.height)
        return "render-\(hasher.finalize())"
    }
    var currentCamera: CADPresentationCamera { camera }
    var isAnimationLeased: Bool { animationLease != nil }
    /// True once a real stage has been built and can be snapshotted. The
    /// service-owned offscreen host waits for this instead of guessing that a
    /// frame is ready.
    var isStageReady: Bool { stage != nil && buildKey != nil }
    weak var handle: CADPresentationHandle?

    private var orbitStartCamera: CADPresentationCamera?
    private var lastPanTranslation: CGPoint = .zero
    private let doubleTap = UITapGestureRecognizer()
    private let singleTap = UITapGestureRecognizer()
    private var cameraGestures: [UIGestureRecognizer] = []

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

    func bindSelection(to document: FloeCADDocument) { selectionDocument = document }

    func apply(_ scene: CADPresentationScene) {
        currentScene = scene
        currentBounds = scene.bounds
        if buildKey == scene.buildKey, stage != nil {
            refreshSelection()
            // Material-only changes still produce a new key; reaching here
            // means the same bytes/environment, so nothing is rebuilt.
            return
        }
        #if DEBUG
        if animationLease != nil {
            // A real identity change (edit/environment) during a render lease
            // is a legitimate stale abort. Log which side moved so a run can
            // distinguish it from an unexplained export failure.
            NSLog("[CADPresentation] %@", "scene identity changed during an "
                + "animation lease; previous=\(String((buildKey ?? "nil").prefix(32))) "
                + "next=\(String(scene.buildKey.prefix(32)))")
        }
        #endif
        buildTask?.cancel()
        pendingTapStamp = nil
        pendingTapMode = nil
        selectionRefinementTask?.cancel()
        selectionRefinementTask = nil
        // The old visible stage cannot accept hits while its replacement
        // builds. The live document fence also rejects the polling interval.
        handle?.markReady(false)
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
            pickTargets = result.pickTargets
            floorBounds = scene.bounds
            selectionDecorations.removeAll()
            selectionRefinementTask?.cancel()
            selectionRefinementTask = nil
            selectionPatchTask?.cancel()
            selectionPatchTask = nil
            selectionFacePatch = nil
            selectionPatchTarget = nil
            lastSelectionState = nil
            originalMaterials.removeAll()
            // A replaced stage always starts from its document baseline; any
            // transient animation frame belonged to the previous generation.
            #if DEBUG
            if animationLease != nil {
                NSLog("[CADPresentation] %@", "stage rebuild generation="
                    + "\(renderGeneration) invalidated the active animation lease")
            }
            #endif
            animationToken = "static"
            animationRestoreCamera = nil
            animationLease = nil
            renderGeneration &+= 1
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
            try Task.checkCancellation()
            guard currentScene?.buildKey == token else { return }
            buildKey = token
            handle?.markFailure(nil)
            handle?.markReady(true)
            handle?.markBuilt(token)
            refreshSelection()
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
        pickTargets.removeAll()
        selectionDecorations.removeAll()
        selectionRefinementTask?.cancel()
        selectionRefinementTask = nil
        selectionPatchTask?.cancel()
        selectionPatchTask = nil
        selectionFacePatch = nil
        selectionPatchTarget = nil
        selectionDocument = nil
        lastSelectionState = nil
        pendingTapStamp = nil
        pendingTapMode = nil
        originalMaterials.removeAll()
        animationToken = "static"
        animationRestoreCamera = nil
        animationLease = nil
        renderGeneration &+= 1
        anchor.removeFromParent()
        cache.dispose()
        buildKey = nil
        currentScene = nil
        floorBounds = nil
        issues = []
        handle?.setIssues([])
        handle?.markReady(false)
        handle?.markFailure(nil)
        handle?.markSelection(nil)
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
                                                bounds: self.floorBounds,
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
            if target.isFaceTarget {
                // A face preview must never fall back to repainting the whole
                // body. An already painted face reuses its existing face
                // entity; the first material on an unpainted face paints only
                // the render-side selection patch for the exact live range.
                guard let faceIndex = target.faceIndex else { continue }
                if let group = body.faceGroups.first(where: {
                    $0.faceIndex == faceIndex
                }), let faceEntity = nodes.faceEntities[faceIndex] {
                    let material = await builder.previewMaterial(
                        spec: spec,
                        bodyID: body.id,
                        bodyName: body.name,
                        hasUVs: group.uvs != nil || body.mesh.uvs != nil)
                    guard !Task.isCancelled else { return }
                    let key = ObjectIdentifier(faceEntity)
                    if originalMaterials[key] == nil {
                        originalMaterials[key] = faceEntity.model?.materials ?? []
                    }
                    faceEntity.model?.materials = [material]
                } else {
                    // The inspector target is frozen at presentation time.
                    // Paint only the CURRENT selection patch when it names the
                    // same face; a later viewport selection must keep its own
                    // truthful highlight instead of being replaced by a stale
                    // inspector target.
                    guard let identity = target.faceIdentity,
                          let selected = lastSelectionState?.faces.first(where: {
                              $0.bodyID == body.id
                          }) else { continue }
                    let selectedSet = Set(selected.triangles.sorted())
                    let identitySet = Set(identity.triangles.sorted())
                    guard selectedSet == identitySet
                            || selectedSet.isSubset(of: identitySet)
                            || identitySet.isSubset(of: selectedSet) else { continue }
                    let faceTarget = SelectionFaceTarget(
                        bodyID: body.id,
                        triangles: selected.triangles.sorted())
                    guard let patch = await ensureSelectionFacePatch(
                        for: faceTarget, body: body, nodes: nodes, scene: scene),
                          let material = await previewMaterial(
                            spec: spec, body: body,
                            hasUVs: body.mesh.uvs != nil) else { continue }
                    patch.entity.model?.materials = [material]
                    patch.isPreviewing = true
                }
            } else {
                let material = await builder.previewMaterial(
                    spec: spec,
                    bodyID: body.id,
                    bodyName: body.name,
                    hasUVs: body.mesh.uvs != nil)
                for entity in nodes.entities {
                    let key = ObjectIdentifier(entity)
                    if originalMaterials[key] == nil {
                        originalMaterials[key] = entity.model?.materials ?? []
                    }
                    entity.model?.materials = [material]
                }
            }
        }
    }

    private func previewMaterial(spec: BodyMaterialSpec, body: CADPresentationBody,
                                 hasUVs: Bool) async -> PhysicallyBasedMaterial? {
        let material = await builder.previewMaterial(
            spec: spec, bodyID: body.id, bodyName: body.name, hasUVs: hasUVs)
        return Task.isCancelled ? nil : material
    }

    func endMaterialPreview() {
        selectionFacePatch?.restoreHighlight()
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
        interactionGeneration &+= 1
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

        cameraGestures = [orbit, pan, pinch]
        singleTap.numberOfTapsRequired = 1
        singleTap.numberOfTouchesRequired = 1
        singleTap.delegate = self
        singleTap.addTarget(self, action: #selector(handleSingleTap(_:)))
        singleTap.require(toFail: doubleTap)
        for gesture in cameraGestures {
            singleTap.require(toFail: gesture)
            doubleTap.require(toFail: gesture)
        }
        arView.addGestureRecognizer(singleTap)
        doubleTap.numberOfTapsRequired = 2
        doubleTap.numberOfTouchesRequired = 1
        doubleTap.delegate = self
        doubleTap.addTarget(self, action: #selector(handleDoubleTap))
        arView.addGestureRecognizer(doubleTap)
    }

    @objc private func handleOrbit(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            interactionGeneration &+= 1
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
            interactionGeneration &+= 1
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
        if recognizer.state == .began { interactionGeneration &+= 1 }
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
        cameraGestures.contains(where: { $0 === gestureRecognizer })
            && cameraGestures.contains(where: { $0 === other })
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === singleTap {
            pendingTapStamp = activeSelectionStamp
            pendingTapMode = handle?.selectionMode ?? .body
            return pendingTapStamp != nil
        }
        return true
    }

    /// A mode switch invalidates a tap that began under the old granularity.
    /// It never changes the document, the current selection or the material.
    func selectionModeDidChange() {
        interactionGeneration &+= 1
        pendingTapStamp = nil
        pendingTapMode = nil
        selectionRefinementTask?.cancel()
        selectionRefinementTask = nil
    }

    private var activeSelectionStamp: CADPresentationSelectionStamp? {
        guard let scene = currentScene, stage != nil, buildKey == scene.buildKey,
              selectionDocument != nil, animationToken == "static", animationLease == nil,
              !cameraGestures.contains(where: { $0.state == .began || $0.state == .changed }) else { return nil }
        return CADPresentationSelectionStamp(documentKey: scene.documentKey,
            documentRevision: scene.documentRevision, changeCount: scene.changeCount,
            buildKey: scene.buildKey, renderGeneration: renderGeneration,
            interactionGeneration: interactionGeneration)
    }

    @objc private func handleSingleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, let stamp = pendingTapStamp,
              let scene = currentScene, let document = selectionDocument,
              stamp == activeSelectionStamp else { return }
        let mode = pendingTapMode ?? handle?.selectionMode ?? .body
        pendingTapStamp = nil
        pendingTapMode = nil
        selectionRefinementTask?.cancel()
        selectionRefinementTask = nil

        let location = recognizer.location(in: arView)
        let hits = arView.hitTest(location, query: .all)
            .sorted { $0.distance < $1.distance }
        guard let routed = hits.first(where: {
            pickTargets[ObjectIdentifier($0.entity)] != nil
        }), var pick = pickTargets[ObjectIdentifier(routed.entity)] else {
            // A genuinely blank tap still clears the live selection, exactly
            // as before. Refinement only changes what a real body/face hit
            // resolves to.
            if CADPresentationSelection.apply(nil, stamp: stamp,
                                              currentStamp: activeSelectionStamp,
                                              scene: scene, document: document) {
                refreshSelection()
            }
            return
        }

        if mode == .body || pick.instanceID != nil || !pick.triangles.isEmpty {
            // Whole-body mode, a placed occurrence, or an already painted face
            // keeps the existing precise identity. Body mode intentionally
            // selects the whole body even when the hit surface carries a face
            // material group.
            if mode == .body { pick.triangles = [] }
            if CADPresentationSelection.apply(pick, stamp: stamp,
                                              currentStamp: activeSelectionStamp,
                                              scene: scene, document: document) {
                refreshSelection()
            }
            return
        }

        guard let drawn = scene.bodies.first(where: { $0.id == pick.entityID }) else { return }
        // A genuine collision on an unpainted regular body: correlate its
        // actual position with the live mesh under the hit entity. Placed
        // occurrences were handled above and never promote a source face.
        let localPoint = CADPresentationSelection.localPointMillimetres(
            worldPoint: routed.position,
            bodyTransform: drawn.transform,
            stageTransform: camera.stageTransform)
        // A later external selection (assistant/host or a rebuild) must win
        // over this still-running hit. Capture the live pre-tap target and
        // re-read it after the detached scan.
        let priorSelection = CADPresentationSelection.state(document: document)
        selectionRefinementTask = Task { [weak self] in
            guard let self else { return }
            let refined = await CADPresentationSelection.refinedFacePick(
                pick, localPointMillimetres: localPoint,
                presentationBody: drawn, scene: scene, document: document)
            guard !Task.isCancelled, stamp == self.activeSelectionStamp,
                  CADPresentationSelection.state(document: document) == priorSelection
            else { return }
            // Empty hits, exact ambiguous edges, stale generations and bodies
            // without a measurable face stay a whole-body selection; they
            // never receive an invented triangle range.
            var chosen = refined ?? pick
            if refined == nil { chosen.triangles = [] }
            if CADPresentationSelection.apply(chosen, stamp: stamp,
                                              currentStamp: self.activeSelectionStamp,
                                              scene: scene, document: document) {
                self.refreshSelection()
            }
        }
    }

    /// A small render-only overlay uses the selected entity's existing mesh.
    /// A selected face with no existing face entity gets one measured patch
    /// built from the exact live triangles, so the first material on an
    /// unpainted face is visible before any document edit. Neither overlay has
    /// a collision shape, so neither can intercept the next tap.
    func refreshSelection() {
        guard let document = selectionDocument, let scene = currentScene,
              buildKey == scene.buildKey else { return }
        let state = CADPresentationSelection.state(document: document)
        guard state != lastSelectionState else { return }
        lastSelectionState = state
        // A selection change is a newer interaction than any hit still being
        // measured; the late hit must not publish over it.
        selectionRefinementTask?.cancel()
        selectionRefinementTask = nil
        selectionDecorations.forEach { $0.removeFromParent() }
        selectionDecorations.removeAll()
        selectionPatchTask?.cancel()
        selectionPatchTask = nil
        selectionPatchTarget = nil
        selectionFacePatch = nil

        for body in scene.bodies {
            guard let nodes = bodyEntities[body.id] else { continue }
            let isInstance = body.sourceBodyID != nil
            guard isInstance ? state.instanceIDs.contains(body.id)
                              : state.bodyIDs.contains(body.id) else { continue }
            if !isInstance, let face = state.faces.first(where: { $0.bodyID == body.id }) {
                let triangles = face.triangles.sorted()
                if let entity = nodes.entities.first(where: {
                    pickTargets[ObjectIdentifier($0)]?.triangles == triangles
                }) {
                    addSelectionHighlight(to: entity)
                } else {
                    let target = SelectionFaceTarget(bodyID: body.id,
                                                     triangles: triangles)
                    startSelectionFacePatch(target: target, body: body,
                                            nodes: nodes, scene: scene)
                }
            } else {
                for entity in nodes.entities {
                    addSelectionHighlight(to: entity)
                }
            }
        }
        handle?.markSelection(CADPresentationSelection.title(document: document))
    }

    private func addSelectionHighlight(to entity: ModelEntity) {
        guard let model = entity.model else { return }
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: .systemOrange)
        material.emissiveColor = .init(color: .systemOrange)
        material.emissiveIntensity = 0.5
        material.blending = .transparent(opacity: .init(scale: 0.25))
        let highlight = ModelEntity(mesh: model.mesh, materials: [material])
        highlight.scale = SIMD3(repeating: 1.001)
        entity.addChild(highlight)
        selectionDecorations.append(highlight)
    }

    /// Build the exact face patch for an unpainted selection. The mesh is the
    /// same measured triangle range the selection was resolved from; it is
    /// fenced by the current stage generation, build key and selection state.
    private func startSelectionFacePatch(target: SelectionFaceTarget,
                                         body: CADPresentationBody,
                                         nodes: CADPresentationBodyNodes,
                                         scene: CADPresentationScene) {
        selectionPatchTask?.cancel()
        if let existing = selectionFacePatch {
            // A draft target may name the authoritative range while the
            // selection was resolved from measured topology. Replace the
            // overlay instead of leaving two coincident patches.
            existing.entity.removeFromParent()
            selectionDecorations.removeAll { $0 === existing.entity }
            selectionFacePatch = nil
        }
        selectionPatchTarget = target
        let generation = renderGeneration
        let expectedBuildKey = scene.buildKey
        selectionPatchTask = Task { [weak self] in
            guard let self else { return }
            guard let mesh = try? await CADPresentationEntityBuilder.makeMesh(
                body.mesh, triangles: target.triangles, uvs: body.mesh.uvs)
            else { return }
            guard !Task.isCancelled,
                  self.renderGeneration == generation,
                  self.buildKey == expectedBuildKey,
                  self.currentScene?.buildKey == expectedBuildKey,
                  self.lastSelectionState?.faces.contains(where: {
                      $0.bodyID == target.bodyID
                          && $0.triangles.sorted() == target.triangles
                  }) == true else { return }
            let patch = self.makeSelectionFacePatch(target: target,
                                                    body: body, mesh: mesh)
            nodes.parent.addChild(patch.entity)
            self.selectionFacePatch = patch
            self.selectionDecorations.append(patch.entity)
            self.selectionPatchTask = nil
        }
    }

    private func makeSelectionFacePatch(target: SelectionFaceTarget,
                                        body: CADPresentationBody,
                                        mesh: MeshResource) -> SelectionFacePatch {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: .systemOrange)
        material.emissiveColor = .init(color: .systemOrange)
        material.emissiveIntensity = 0.35
        material.blending = .transparent(opacity: .init(scale: 0.32))
        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.name = "CADPresentationSelectionFace"
        // Lift the coincident patch by a fraction of the model size so it is
        // visible over the body without a second depth or render pass.
        let normal = CADPresentationFaceHit.averageNormal(
            in: body.mesh, triangles: target.triangles)
        let diagonal = simd_length(body.mesh.boundsMax - body.mesh.boundsMin)
        let offset = max(2e-6, min(0.002, diagonal * 0.001))
        entity.position = normal * offset
        return SelectionFacePatch(target: target, entity: entity,
                                  highlightMaterial: material)
    }

    /// A material draft opened from a face selection may preview before the
    /// asynchronous highlight task has installed its patch. Await that single
    /// in-flight build rather than creating a competing overlay.
    private func ensureSelectionFacePatch(for target: SelectionFaceTarget,
                                          body: CADPresentationBody,
                                          nodes: CADPresentationBodyNodes,
                                          scene: CADPresentationScene) async -> SelectionFacePatch? {
        guard !Task.isCancelled else { return nil }
        if let patch = selectionFacePatch, patch.target == target { return patch }
        if selectionPatchTarget == target, let task = selectionPatchTask {
            await task.value
            if let patch = selectionFacePatch, patch.target == target { return patch }
        }
        guard !Task.isCancelled else { return nil }
        startSelectionFacePatch(target: target, body: body,
                                nodes: nodes, scene: scene)
        if let task = selectionPatchTask { await task.value }
        guard !Task.isCancelled else { return nil }
        guard let patch = selectionFacePatch, patch.target == target else { return nil }
        return patch
    }

    // MARK: Transient animation frame

    /// Exclusive render lease for a multi-frame capture/export. Playback
    /// frames are ignored while a lease is held, so two writers can never
    /// interleave transforms in one video.
    func beginAnimationLease() -> UUID? {
        guard stage != nil else { return nil }
        let id = UUID()
        animationLease = id
        return id
    }

    func endAnimationLease(_ id: UUID) {
        if animationLease == id { animationLease = nil }
    }

    func holdsAnimationLease(_ id: UUID) -> Bool { animationLease == id }

    /// Apply one transient animation frame to the live stage. The document,
    /// assembly and undo stack are untouched. `expectedGeneration` fences a
    /// frame computed against a stage that has since been rebuilt/released.
    @discardableResult
    func applyAnimation(camera animationCamera: CADPresentationCamera?,
                        instanceTransforms: [UUID: simd_float4x4],
                        token: String,
                        expectedGeneration: UInt64,
                        lease: UUID?) -> Bool {
        guard let stage, let scene = currentScene,
              renderGeneration == expectedGeneration else { return false }
        if let animationLease, lease != animationLease { return false }
        if animationRestoreCamera == nil { animationRestoreCamera = camera }
        if let animationCamera { camera = animationCamera }
        for body in scene.bodies {
            guard let nodes = bodyEntities[body.id] else { continue }
            nodes.parent.transform = Transform(
                matrix: instanceTransforms[body.id] ?? body.transform)
        }
        // The ground follows the pose actually drawn. Without this an animated
        // part moving below its static minimum would still be cut by a floor
        // placed from the document baseline.
        let animatedBounds = CADPresentationFloorPlacement.bounds(
            for: scene, transforms: instanceTransforms)
        floorBounds = animatedBounds
        CADPresentationEntityBuilder.updateFloor(in: stage, bounds: animatedBounds)
        animationToken = token
        applyCamera()
        return true
    }

    /// Restore every body to its document baseline and the camera to the pose
    /// captured before playback. Called on stop, mode exit and export finish.
    func clearAnimation() {
        // An export owns the stage for the whole clip; it restores when its
        // lease ends rather than letting a UI stop clear a frame mid-write.
        if animationLease != nil { return }
        if let scene = currentScene {
            for body in scene.bodies {
                bodyEntities[body.id]?.parent.transform = Transform(matrix: body.transform)
            }
            floorBounds = scene.bounds
            if let stage {
                CADPresentationEntityBuilder.updateFloor(in: stage,
                                                         bounds: scene.bounds)
            }
        }
        if let restore = animationRestoreCamera {
            camera = restore
            applyCamera()
        }
        animationRestoreCamera = nil
        animationToken = "static"
    }

    // MARK: Capture

    /// Actual current ARView render. Refuses when the surface is not in a
    /// window; the caller binds the returned image to a document revision.
    func snapshotPNG(targetWidth: Int?) async throws -> (png: Data, width: Int, height: Int) {
        let output = try await snapshotImage(targetWidth: targetWidth)
        guard let png = output.pngData() else { throw CADPresentationError.snapshotFailed }
        return (png, Int(output.size.width * output.scale),
                Int(output.size.height * output.scale))
    }

    /// The same actual ARView render without PNG encoding. Video export needs
    /// the pixels once; a poster image is encoded only for its first frame.
    func snapshotImage(targetWidth: Int?) async throws -> UIImage {
        guard arView.window != nil else { throw CADPresentationError.notAttached }
        guard stage != nil else { throw CADPresentationError.renderingUnavailable }
        let image: UIImage? = await withCheckedContinuation { continuation in
            arView.snapshot(saveToHDR: false) { image in
                continuation.resume(returning: image)
            }
        }
        guard let image else { throw CADPresentationError.snapshotFailed }
        if Task.isCancelled { throw CADPresentationError.snapshotCancelled }
        if let targetWidth, targetWidth > 0,
           Int(image.size.width * image.scale) != targetWidth {
            return Self.resized(image, targetWidth: targetWidth)
        }
        return image
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
    let document: FloeCADDocument

    func makeUIView(context: Context) -> ARView {
        let controller = CADPresentationRenderController()
        controller.attach(handle: handle)
        controller.bindSelection(to: document)
        if let saved = handle.savedCamera {
            controller.restoreCamera(saved)
        }
        handle.controller = controller
        context.coordinator.controller = controller
        controller.apply(scene)
        return controller.arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.controller?.bindSelection(to: document)
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
        // A pending debounced autosave of the SAME live content commits a new
        // receipt while the asynchronous ARView snapshot flies; the fence
        // below then discarded an unchanged image (run-18 colour witnesses).
        // Settle through the canonical async writer BEFORE pinning the
        // revision/SHA, and still abort on a real edit or save refusal.
        let sourceChangeCount = document.liveChangeCount
        let settleResult: AnimationIdentitySettleResult
        do {
            settleResult = try await document.session
                .settleSaveStateBeforeIdentityPin(
                    expectingChangeCount: sourceChangeCount)
        } catch is CancellationError {
            throw CADPresentationError.snapshotCancelled
        }
        // A close revokes the store: report the release before interpreting a
        // possible save refusal caused by it.
        guard !document.isClosed else {
            #if DEBUG
            NSLog("[CADPresentationCapture] %@", "stale "
                + "reason=document-closed revision=\(document.revision)")
            #endif
            throw CADPresentationError.snapshotStale
        }
        switch settleResult {
        case .ready:
            break
        case .sourceChanged:
            #if DEBUG
            NSLog("[CADPresentationCapture] %@", "stale "
                + "reason=settle-source-changed "
                + "changeCount=\(document.liveChangeCount) "
                + "expected=\(sourceChangeCount) "
                + "revision=\(document.revision)")
            #endif
            throw CADPresentationError.snapshotStale
        case .saveFailed:
            #if DEBUG
            NSLog("[CADPresentationCapture] %@", "failed "
                + "reason=settle-save-failed changeCount=\(document.liveChangeCount) "
                + "expected=\(sourceChangeCount)")
            #endif
            throw CADPresentationError.snapshotFailed
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
        let documentKeyAfter = document.url.standardizedFileURL.path
        let revisionAfter = document.revision
        let changeCountAfter = document.liveChangeCount
        let contentSHA256After = document.contentSHA256
        let stateAfter = controller.renderStateToken
        guard documentKeyAfter == documentKey,
              revisionAfter == revision,
              changeCountAfter == changeCount,
              contentSHA256After == contentSHA256 else {
            #if DEBUG
            NSLog("[CADPresentationCapture] %@", "stale "
                + "reason=document-fence "
                + "keyMatches=\(documentKeyAfter == documentKey) "
                + "revision=\(revisionAfter) expectedRevision=\(revision) "
                + "changeCount=\(changeCountAfter) expectedChangeCount=\(changeCount) "
                + "contentSHAMatches=\(contentSHA256After == contentSHA256) "
                + "closed=\(document.isClosed)")
            #endif
            throw CADPresentationError.snapshotStale
        }
        // A playback frame, export camera or environment change during the
        // asynchronous snapshot must discard the image rather than return a
        // picture of a different render state under the old key.
        guard stateAfter == stateBefore else {
            #if DEBUG
            NSLog("[CADPresentationCapture] %@", "stale "
                + "reason=render-state-changed "
                + "revision=\(revision) changeCount=\(changeCount)")
            #endif
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
