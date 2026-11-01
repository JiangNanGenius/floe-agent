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
    /// The saved frame cannot be contained in the current viewport at a
    /// supported transient lens. Refusing is deliberate: fitting the clipped
    /// viewport would silently lose part of the saved shot.
    case framingUnsupported

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
        case .framingUnsupported:
            return FloeCADStrings.text(
                "cad.present.error.framing",
                "This view doesn’t fit the current window. Rotate the screen or resize the window and try again.")
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
    /// Current viewport width ÷ height, captured into a saved view.
    var currentFrameAspect: Double? { controller?.currentFrameAspect }

    func fit() {
        controller?.fit()
    }

    /// Show an already-persisted saved view without writing the document.
    func showCamera(_ camera: CADPresentationCamera) {
        controller?.showCamera(camera)
    }

    /// Temporary live projection change; never overwrites a saved camera.
    func setProjection(_ projection: CADCameraProjection) {
        controller?.setProjection(projection)
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
    /// A plain entity holds EITHER a perspective or an orthographic component
    /// (never both); `applyCamera` swaps them when the projection changes.
    private let cameraEntity = Entity()
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
        var isPreviewing = false

        init(target: SelectionFaceTarget, entity: ModelEntity) {
            self.target = target
            self.entity = entity
        }
    }

    private struct SelectionFaceTarget: Equatable {
        var bodyID: UUID
        var triangles: [Int]
    }

    private var selectionFacePatch: SelectionFacePatch?
    private var selectionPatchTask: Task<Void, Never>?
    private var selectionPatchTarget: SelectionFaceTarget?
    /// Latest-draft-wins identity for the render-only material preview. Every
    /// request advances it; an older detached build compares before it touches
    /// the stage. Ending the preview or replacing the stage advances it again,
    /// so a late await can never resurrect a cancelled draft.
    private var materialPreviewGeneration: UInt64 = 0
    /// Content identity of what is actually installed. It moves only when a
    /// draft is installed or restored (not when a replacement merely starts),
    /// so a snapshot cannot cache the old draft under the replacement's key.
    private var materialPreviewRevision: UInt64 = 0
    private var materialPreviewInstalled = false
    /// Body-wide draft overlays: one render-only entity per selected body.
    /// The original drawable entities stay resident (hidden) so Cancel can
    /// restore the exact appearance without rebuilding the stage.
    private var materialPreviewOverlays: [UUID: MaterialPreviewOverlay] = [:]
    /// Face draft previews swap one entity's ModelComponent. The baseline
    /// component is retained here until Cancel/end preview.
    private var materialPreviewModelSwaps: [ObjectIdentifier: MaterialPreviewModelSwap] = [:]
    private var materialPreviewIssues: [CADPresentationIssue] = []
    /// Actual render-side resources installed by the latest draft: the exact
    /// MeshResource reference put on the entity and the sampling coordinates
    /// handed to its mesh builder. It is a transient diagnostic of what was
    /// installed, never a model store; cleared on Cancel/end/replacement.
    private(set) var materialPreviewReceipts: [MaterialPreviewReceipt] = []
    /// Internal diagnostic used by the render-side tests to interleave a
    /// cancellation with a real in-flight build. It never feeds document state.
    private(set) var isMaterialPreviewInFlight = false

    private struct MaterialPreviewOverlay {
        var entity: ModelEntity
        var hidden: [(entity: Entity, wasEnabled: Bool)]
    }

    private struct MaterialPreviewModelSwap {
        var entity: ModelEntity
        var model: ModelComponent?
        var patch: SelectionFacePatch?
    }

    struct MaterialPreviewReceipt {
        var bodyID: UUID
        var faceIndex: Int?
        /// Triangle ordinals changed by a face draft; nil for a body draft.
        var triangles: [Int]?
        /// Sampling coordinates handed to the mesh builder for this install.
        var samplingUVs: [SIMD2<Float>]?
        var mesh: MeshResource
    }
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
        hasher.combine(camera.projection)
        // A transient saved-shot render widens the lens without changing the
        // pose; pixels taken under it must never share a live-view cache key.
        hasher.combine(camera.transientHalfHeightScale)
        hasher.combine(currentScene?.environment.stableKey)
        hasher.combine(buildKey)
        hasher.combine(animationToken)
        hasher.combine(renderGeneration)
        hasher.combine(materialPreviewGeneration)
        hasher.combine(materialPreviewRevision)
        hasher.combine(materialPreviewInstalled)
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
        anchor.addChild(cameraEntity)
        arView.scene.addAnchor(anchor)
        applyCamera()
        installGestures()
    }

    /// One place that keeps the camera component and the stage's inverse view
    /// transform in sync. The camera stays at the anchor origin looking down
    /// −Z; every orbit/pan/zoom/fit moves the stage by the inverse camera
    /// matrix, exactly as `CADPresentationCamera.stageTransform` defines.
    /// Exactly one projection component is installed so RealityKit cannot pick
    /// a stale one after a perspective/orthographic switch.
    private func applyCamera() {
        switch camera.projection {
        case .perspective:
            cameraEntity.components.set(camera.perspectiveCameraComponent)
            cameraEntity.components.remove(OrthographicCameraComponent.self)
        case .orthographic:
            cameraEntity.components.set(camera.orthographicCameraComponent)
            cameraEntity.components.remove(PerspectiveCameraComponent.self)
        }
        stage?.transform = Transform(matrix: camera.stageTransform)
    }

    private var viewportAspect: Float? {
        let size = arView.bounds.size
        guard size.width > 1, size.height > 1 else { return nil }
        return Float(size.width / size.height)
    }

    /// Width ÷ height of the actual viewport. Captured into a saved view so
    /// its export framing is the frame the user saw.
    var currentFrameAspect: Double? {
        guard let viewportAspect else { return nil }
        return Double(viewportAspect)
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
        // A new stage/build key retires every transient draft overlay. This
        // happens before the asynchronous build so an in-flight preview cannot
        // install on the outgoing stage or the replacement.
        materialPreviewGeneration &+= 1
        isMaterialPreviewInFlight = false
        restoreMaterialPreviewState(clearIssues: true)
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
                    to: scene.bounds, aspect: viewportAspect,
                    projection: camera.projection)
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
        materialPreviewGeneration &+= 1
        isMaterialPreviewInFlight = false
        restoreMaterialPreviewState(clearIssues: true)
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
    /// no undo record and no stage rebuild: a render-only mesh whose sampling
    /// UVs come from the CURRENT draft is shown instead of the applied
    /// appearance. Body drafts cover the whole selected body; face drafts
    /// change only the exact face range (or the existing unpainted-face
    /// selection patch) and never repaint the body as a fallback.
    func previewMaterial(_ spec: BodyMaterialSpec, for target: CADMaterialTarget) async {
        guard !target.isEmpty,
              let scene = currentScene,
              stage != nil,
              buildKey == scene.buildKey else { return }
        if let document = selectionDocument,
           scene.documentKey != document.url.standardizedFileURL.path { return }

        // Latest request wins over any older await. The previous draft stays
        // visible while the replacement's GPU resources build; the restore
        // runs only in the same synchronous install block, so a slider tick
        // never flashes the applied appearance and Cancel still restores the
        // exact applied baseline.
        materialPreviewGeneration &+= 1
        let generation = materialPreviewGeneration
        isMaterialPreviewInFlight = true
        defer {
            if generation == materialPreviewGeneration {
                isMaterialPreviewInFlight = false
            }
        }

        let startRenderGeneration = renderGeneration
        let startBuildKey = scene.buildKey
        let startDocument = selectionDocument
        let startStage = stage

        func isCurrent() -> Bool {
            guard !Task.isCancelled,
                  generation == materialPreviewGeneration,
                  renderGeneration == startRenderGeneration,
                  buildKey == startBuildKey,
                  currentScene?.buildKey == startBuildKey,
                  stage === startStage,
                  animationLease == nil else { return false }
            if let startDocument {
                guard selectionDocument === startDocument else { return false }
            }
            return true
        }

        var ids = Set(target.bodyIDs)
        if let faceBodyID = target.faceBodyID { ids.insert(faceBodyID) }
        var issues: [CADPresentationIssue] = []
        var installations: [MaterialPreviewInstallation] = []
        var matched: [(id: UUID, meshRevision: UInt64)] = []

        for body in scene.bodies where body.matchesMaterialTarget(ids) {
            guard let nodes = bodyEntities[body.id],
                  targetAccepts(body: body, target: target) else { continue }
            matched.append((body.id, body.mesh.meshRevision))
            let uvs = CADPresentationDraftUV.samplingUVs(
                for: body.mesh, mapping: spec.uvMapping)

            if target.isFaceTarget {
                guard let faceIndex = target.faceIndex else { continue }
                if let faceEntity = nodes.faceEntities[faceIndex],
                   let triangles = nodes.faceTriangles[faceIndex],
                   !triangles.isEmpty {
                    let preview = await builder.previewMaterial(
                        spec: spec, bodyID: body.id, bodyName: body.name, uvs: uvs)
                    guard isCurrent() else { return }
                    issues.append(contentsOf: preview.issues)
                    guard let mesh = await previewMesh(
                        body.mesh, triangles: triangles, uvs: uvs) else {
                        issues.append(previewMeshIssue(body))
                        continue
                    }
                    guard isCurrent() else { return }
                    installations.append(.modelSwap(
                        entity: faceEntity, bodyID: body.id,
                        mesh: mesh, material: preview.material, patch: nil,
                        faceIndex: faceIndex, triangles: triangles,
                        samplingUVs: uvs))
                } else {
                    // First material on a face with no applied face entity:
                    // only the EXACT live selection patch may show it. A
                    // different (or moved) selection is never repainted.
                    guard let identity = target.faceIdentity else { continue }
                    let selectedTriangles = lastSelectionState?.faces
                        .first(where: { $0.bodyID == body.id })?
                        .triangles.sorted()
                    guard let selectedTriangles, !selectedTriangles.isEmpty,
                          Self.sameFace(selectedTriangles, identity.triangles)
                    else { continue }
                    let preview = await builder.previewMaterial(
                        spec: spec, bodyID: body.id, bodyName: body.name, uvs: uvs)
                    guard isCurrent() else { return }
                    issues.append(contentsOf: preview.issues)
                    guard let mesh = await previewMesh(
                        body.mesh, triangles: selectedTriangles, uvs: uvs) else {
                        issues.append(previewMeshIssue(body))
                        continue
                    }
                    guard isCurrent(),
                          Self.selectionStillMatches(
                            bodyID: body.id, triangles: selectedTriangles,
                            state: lastSelectionState) else { return }
                    guard let patch = await ensureSelectionFacePatch(
                        for: SelectionFaceTarget(bodyID: body.id,
                                                 triangles: selectedTriangles),
                        body: body, nodes: nodes, scene: scene) else { continue }
                    guard isCurrent(),
                          selectionFacePatch === patch,
                          Self.selectionStillMatches(
                            bodyID: body.id, triangles: selectedTriangles,
                            state: lastSelectionState) else { return }
                    installations.append(.modelSwap(
                        entity: patch.entity, bodyID: body.id,
                        mesh: mesh, material: preview.material, patch: patch,
                        faceIndex: faceIndex, triangles: selectedTriangles,
                        samplingUVs: uvs))
                }
            } else {
                let preview = await builder.previewMaterial(
                    spec: spec, bodyID: body.id, bodyName: body.name, uvs: uvs)
                guard isCurrent() else { return }
                issues.append(contentsOf: preview.issues)
                guard let mesh = await previewMesh(
                    body.mesh, indices: body.mesh.indices, uvs: uvs) else {
                    issues.append(previewMeshIssue(body))
                    continue
                }
                guard isCurrent() else { return }
                installations.append(.bodyOverlay(
                    body: body, mesh: mesh, material: preview.material,
                    samplingUVs: uvs))
            }
        }

        guard isCurrent() else { return }
        // The scene generation can only be valid if every body this request
        // measured is still the same mesh generation at install time.
        for match in matched {
            guard let live = currentScene?.bodies.first(where: { $0.id == match.id }),
                  live.mesh.meshRevision == match.meshRevision else { return }
        }
        // Replace the previous draft atomically: restore its exact baseline
        // and install the new resources with no await in between. A capture
        // can never observe half of one draft and half of another.
        restoreMaterialPreviewState(clearIssues: false)
        for installation in installations {
            switch installation {
            case .bodyOverlay(let body, let mesh, let material,
                              let samplingUVs):
                guard let nodes = bodyEntities[body.id],
                      let overlay = installPreviewOverlay(
                        body: body, nodes: nodes, mesh: mesh,
                        material: material) else { continue }
                materialPreviewOverlays[body.id] = overlay
                materialPreviewReceipts.append(MaterialPreviewReceipt(
                    bodyID: body.id, faceIndex: nil, triangles: nil,
                    samplingUVs: samplingUVs, mesh: mesh))
            case .modelSwap(let entity, let bodyID, let mesh,
                            let material, let patch, let faceIndex,
                            let triangles, let samplingUVs):
                let key = ObjectIdentifier(entity)
                if materialPreviewModelSwaps[key] == nil {
                    materialPreviewModelSwaps[key] = MaterialPreviewModelSwap(
                        entity: entity, model: entity.model, patch: patch)
                }
                entity.model = ModelComponent(mesh: mesh,
                                              materials: [material])
                patch?.isPreviewing = true
                materialPreviewReceipts.append(MaterialPreviewReceipt(
                    bodyID: bodyID, faceIndex: faceIndex,
                    triangles: triangles, samplingUVs: samplingUVs,
                    mesh: mesh))
            }
        }
        materialPreviewInstalled = !materialPreviewOverlays.isEmpty
            || !materialPreviewModelSwaps.isEmpty
        materialPreviewRevision &+= 1
        setMaterialPreviewIssues(issues)
    }

    private enum MaterialPreviewInstallation {
        case bodyOverlay(body: CADPresentationBody,
                         mesh: MeshResource,
                         material: PhysicallyBasedMaterial,
                         samplingUVs: [SIMD2<Float>]?)
        case modelSwap(entity: ModelEntity, bodyID: UUID,
                       mesh: MeshResource,
                       material: PhysicallyBasedMaterial,
                       patch: SelectionFacePatch?,
                       faceIndex: Int?, triangles: [Int],
                       samplingUVs: [SIMD2<Float>]?)
    }

    /// The draft target is frozen at presentation time. A scene/stage whose
    /// body mesh generation moved on must not receive it, and a face target
    /// must keep pointing at the source body that produced the face.
    private func targetAccepts(body: CADPresentationBody,
                               target: CADMaterialTarget) -> Bool {
        let sourceID = body.sourceBodyID ?? body.id
        if let expected = target.bodyMeshRevisions[body.id]
            ?? target.bodyMeshRevisions[sourceID],
           expected != body.mesh.meshRevision { return false }
        if target.isFaceTarget {
            guard let faceBodyID = target.faceBodyID, sourceID == faceBodyID else {
                return false
            }
            if let expected = target.faceIdentity?.meshRevision,
               expected != body.mesh.meshRevision { return false }
        }
        return true
    }

    /// The same subset/equality rule the first-face preview already used.
    /// A shared edge or a superset is not the same face for a paint target.
    private static func sameFace(_ lhs: [Int], _ rhs: [Int]) -> Bool {
        let left = Set(lhs), right = Set(rhs)
        return left == right || left.isSubset(of: right) || right.isSubset(of: left)
    }

    private static func selectionStillMatches(
        bodyID: UUID, triangles: [Int],
        state: CADPresentationSelectionState?
    ) -> Bool {
        guard let picked = state?.faces.first(where: { $0.bodyID == bodyID }) else {
            return false
        }
        return picked.triangles.sorted() == triangles
    }

    private func previewMesh(
        _ body: CADPresentationMesh, indices: [UInt32],
        uvs: [SIMD2<Float>]?
    ) async -> MeshResource? {
        do {
            return try await CADPresentationEntityBuilder.makeMesh(
                body, indices: indices, uvs: uvs)
        } catch {
            return nil
        }
    }

    private func previewMesh(
        _ body: CADPresentationMesh, triangles: [Int],
        uvs: [SIMD2<Float>]?
    ) async -> MeshResource? {
        do {
            return try await CADPresentationEntityBuilder.makeMesh(
                body, triangles: triangles, uvs: uvs)
        } catch {
            return nil
        }
    }

    private func previewMeshIssue(_ body: CADPresentationBody) -> CADPresentationIssue {
        CADPresentationIssue(
            id: "preview-mesh-\(body.id.uuidString)", kind: .corruptMaterial,
            bodyID: body.id, bodyName: body.name,
            detail: "The draft's preview mesh could not be built on this device; the applied appearance is still shown.")
    }

    private func installPreviewOverlay(
        body: CADPresentationBody,
        nodes: CADPresentationBodyNodes,
        mesh: MeshResource,
        material: PhysicallyBasedMaterial
    ) -> MaterialPreviewOverlay? {
        guard let stage else { return nil }
        let overlay = ModelEntity(mesh: mesh, materials: [material])
        overlay.name = "CADPresentationMaterialPreview"
        // Follow the current body node transform (a playback frame may have
        // moved it away from the static document pose).
        overlay.transform = nodes.parent.transform
        if let shadow = nodes.entities.first?
            .components[GroundingShadowComponent.self] {
            overlay.components.set(shadow)
        }
        var hidden: [(entity: Entity, wasEnabled: Bool)] = []
        for entity in nodes.entities {
            hidden.append((entity, entity.isEnabled))
            entity.isEnabled = false
        }
        stage.addChild(overlay)
        return MaterialPreviewOverlay(entity: overlay, hidden: hidden)
    }

    /// Restore every render-side thing a draft may have changed. The stage,
    /// document, selection and undo stack were never touched, so this only
    /// removes the transient overlay and puts the exact ModelComponent back.
    private func restoreMaterialPreviewState(clearIssues: Bool) {
        for overlay in materialPreviewOverlays.values {
            overlay.entity.removeFromParent()
            for hidden in overlay.hidden {
                hidden.entity.isEnabled = hidden.wasEnabled
            }
        }
        materialPreviewOverlays.removeAll()
        for swap in materialPreviewModelSwaps.values {
            swap.entity.model = swap.model
            swap.patch?.isPreviewing = false
        }
        materialPreviewModelSwaps.removeAll()
        materialPreviewReceipts = []
        materialPreviewInstalled = false
        materialPreviewRevision &+= 1
        if clearIssues {
            materialPreviewIssues = []
            handle?.setIssues(issues)
        }
    }

    private func setMaterialPreviewIssues(_ new: [CADPresentationIssue]) {
        // A build issue and a draft issue can name the same condition (for
        // example a texture-less mesh source). Keep one row per identity so the
        // details list never gains duplicate Identifiable entries.
        var seen = Set(issues.map(\.id))
        materialPreviewIssues = new.filter { seen.insert($0.id).inserted }
        handle?.setIssues(issues + materialPreviewIssues)
    }

    func endMaterialPreview() {
        materialPreviewGeneration &+= 1
        isMaterialPreviewInFlight = false
        restoreMaterialPreviewState(clearIssues: true)
    }

    // MARK: Camera

    func restoreCamera(_ saved: CADPresentationCamera) {
        var camera = saved
        // A live camera is never a transient export lens.
        camera.transientHalfHeightScale = 1
        guard camera.isValid else { return }
        self.camera = camera
        cameraRestored = true
        applyCamera()
    }

    /// Show a saved view. This changes only the live camera; the bookmark is
    /// written by the document command the caller already performed.
    func showCamera(_ saved: CADPresentationCamera) {
        var camera = saved
        // A live camera is never a transient export lens.
        camera.transientHalfHeightScale = 1
        guard camera.isValid else { return }
        interactionGeneration &+= 1
        // A document selection/undo can arrive while a transient frame owns
        // the stage. Stopping that frame must restore the newly selected view,
        // rather than resurrecting the camera from before the document edit.
        if animationRestoreCamera != nil { animationRestoreCamera = camera }
        self.camera = camera
        cameraRestored = true
        applyCamera()
    }

    /// Live projection toggle. This is a temporary observation, exactly like
    /// an orbit: it never writes a saved camera. Saving the current view is
    /// the explicit document edit.
    func setProjection(_ projection: CADCameraProjection) {
        guard camera.projection != projection else { return }
        interactionGeneration &+= 1
        camera.projection = projection
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
        return SelectionFacePatch(target: target, entity: entity)
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
            materialPreviewOverlays[body.id]?.entity.transform =
                nodes.parent.transform
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
                if let parent = bodyEntities[body.id]?.parent {
                    materialPreviewOverlays[body.id]?.entity.transform =
                        parent.transform
                }
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

    /// Actual ARView pixels of one saved shot, rendered transiently so the
    /// WHOLE saved frustum exists in the current viewport and then centre-
    /// cropped to the saved frame. Applied under an exclusive render lease and
    /// restored with the document baseline before returning. Playback must
    /// already be stopped and no export lease may be held; the caller fences
    /// the document identity around the await. This never writes the document
    /// or the saved camera, and it never resizes the on-screen UI.
    ///
    /// The perspective lens is widened by `tan(fov/2)`, the orthographic by
    /// its half-height; the eye distance is never moved. A combination that
    /// would need an unsupported lens refuses instead of clipping.
    func framedSnapshotImage(camera exportCamera: CADPresentationCamera,
                             savedAspect: Double,
                             targetWidth: Int) async throws
    -> (image: UIImage, width: Int, height: Int) {
        guard arView.window != nil else { throw CADPresentationError.notAttached }
        guard stage != nil, let viewport = viewportAspect else {
            throw CADPresentationError.renderingUnavailable
        }
        guard animationLease == nil else {
            throw CADPresentationError.renderingUnavailable
        }
        guard exportCamera.isValid,
              let plan = CADExportFraming.plan(
                savedAspect: savedAspect,
                viewportAspect: Double(viewport),
                fovYDegrees: Double(exportCamera.fovYDegrees),
                projection: exportCamera.projection,
                targetWidth: targetWidth) else {
            throw CADPresentationError.framingUnsupported
        }
        var transientCamera = exportCamera
        transientCamera.transientHalfHeightScale = Float(plan.transientScale)
        guard let lease = beginAnimationLease() else {
            throw CADPresentationError.renderingUnavailable
        }
        let generation = renderGeneration
        let token = String(
            format: "camera-frame|%@|%.6f|%.6f|%.4f|%.4f|%.6f",
            exportCamera.projection.rawValue,
            exportCamera.distance,
            exportCamera.fovYDegrees,
            exportCamera.azimuthRadians,
            exportCamera.elevationRadians,
            plan.transientScale)
        let applied = applyAnimation(
            camera: transientCamera, instanceTransforms: [:],
            token: token, expectedGeneration: generation, lease: lease)
        guard applied else {
            endAnimationLease(lease)
            throw CADPresentationError.snapshotStale
        }
        defer {
            endAnimationLease(lease)
            clearAnimation()
        }
        // Raw pixels: the crop must be derived from the resolution the ARView
        // actually produced, not from an image already resized to the target.
        let image = try await snapshotImage(targetWidth: nil)
        guard animationToken == token,
              renderGeneration == generation,
              let capturedViewport = viewportAspect,
              abs(Double(capturedViewport) - Double(viewport)) <= 1e-3,
              let framed = CADExportFrame.framedStill(image, plan: plan) else {
            throw CADPresentationError.snapshotStale
        }
        return framed
    }
}

// MARK: - Camera fit helper

private extension CADPresentationCamera {
    mutating func fitIfInvalid(_ bounds: CADPresentationBounds?, aspect: Float?) {
        if !isValid {
            self = CADPresentationCamera.fitted(
                to: bounds, fovYDegrees: fovYDegrees, aspect: aspect,
                projection: projection)
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
        // A Present/Edit switch keeps the transient live camera; a REOPENED
        // document has no transient value, so it starts on its selected saved
        // view. Reopening thus restores the projection and framing the user
        // saved instead of an arbitrary fitted pose.
        if let saved = handle.savedCamera {
            controller.restoreCamera(saved)
        } else if let selected = document.activeSavedCamera {
            controller.restoreCamera(selected.presentationCamera)
        }
        handle.controller = controller
        context.coordinator.controller = controller
        context.coordinator.recordCameraSelection(document)
        controller.apply(scene)
        return controller.arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.controller?.bindSelection(to: document)
        context.coordinator.synchronizeCameraSelection(document)
        context.coordinator.controller?.apply(scene)
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        coordinator.controller?.release()
        coordinator.controller = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        var controller: CADPresentationRenderController?
        private var selectedID: UUID?
        private var selectedPose: CADPresentationCamera?

        func recordCameraSelection(_ document: FloeCADDocument) {
            let selected = document.activeSavedCamera
            selectedID = selected?.id
            selectedPose = selected?.presentationCamera
        }

        func synchronizeCameraSelection(_ document: FloeCADDocument) {
            let selected = document.activeSavedCamera
            let pose = selected?.presentationCamera
            guard selectedID != selected?.id || selectedPose != pose else { return }
            recordCameraSelection(document)
            // Rename, unrelated geometry edits and view updates do not reset
            // a user's temporary orbit. A changed selection/pose, including
            // undo/redo or an assistant edit, does update the actual camera.
            // Free view keeps the current pose and only removes the binding.
            if let pose { controller?.showCamera(pose) }
        }
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
                 targetWidth: Int,
                 savedCamera: CADSavedCamera? = nil) async throws
    -> CADPresentationSnapshot {
        guard let controller = handle.controller else {
            throw CADPresentationError.notAttached
        }
        var savedView: CADSavedCamera?
        if let savedCamera {
            guard let clean = savedCamera.sanitized else {
                throw CADPresentationError.snapshotFailed
            }
            savedView = clean
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
        // A framed saved-view capture is not the live render, so it neither
        // reads nor writes this cache.
        if savedView == nil, let cached = cache[keyBefore] {
            return cached.snapshot
        }
        if Task.isCancelled { throw CADPresentationError.snapshotCancelled }
        let result: (png: Data, width: Int, height: Int)
        let note: String
        if let savedView {
            // Render the complete saved frustum in the current viewport, then
            // crop the saved frame out of those real pixels. Fitting an
            // already-clipped viewport into the saved aspect would lose the
            // geometry outside the current window.
            let framed = try await controller.framedSnapshotImage(
                camera: savedView.presentationCamera,
                savedAspect: savedView.frameAspect,
                targetWidth: targetWidth)
            guard let png = framed.image.pngData() else {
                throw CADPresentationError.snapshotFailed
            }
            result = (png, framed.width, framed.height)
            note = "Actual live RealityKit render of saved view "
                + "“\(savedView.name)” "
                + "(\(savedView.projection.rawValue), \(savedView.frameLabel)), "
                + "framed from the complete saved shot and bound to the open "
                + "document revision."
        } else {
            result = try await controller.snapshotPNG(targetWidth: targetWidth)
            note = "Actual current RealityKit presentation render bound to the open document revision."
        }
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
            note: note)
        if savedView == nil {
            let keyAfter = "\(documentKey)|\(revision)|\(changeCount)|\(contentSHA256)|\(stateAfter)|\(targetWidth)"
            store(snapshot, key: keyAfter)
        }
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
