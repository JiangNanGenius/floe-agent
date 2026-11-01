//
//  FloeCADDocument+Observation.swift
//  FloeCADKit
//
//  Bounded, read-only multi-view observation of the live native document
//  scene for `cad.document action=observe`.
//
//  The pixels come from a DETACHED `Renderer` over a value copy of
//  `viewModel().scene`, with a locally fitted `TurntableCamera`. The user's
//  live camera, selection, preferences, saved appearance, animation playback,
//  undo/redo history and model geometry are never modified: there is no
//  `cameraControl`, no `ViewportCoordinator.attach`, no thumbnail provider and
//  no live renderer touched.
//
//  An observation is bound to ONE live generation:
//    * `revision` + `contentSHA256` are the last COMMITTED package identity;
//    * `changeCount` is the live in-memory generation (which also advances for
//      an unsaved draft).
//  `contentSHA256` is never described as a digest of unsaved mesh bytes.
//
//  The same reply reports the actual current scene's body/instance membership
//  (included and omitted, with hidden/isolate/preview reasons) from the SAME
//  value-copy scene the renderer consumes. It is drawable membership, never a
//  claim about pixels that occlusion or section clipping may hide.
//
//  This is the engineering offscreen renderer, not the live RealityKit
//  Present. A frame always reports `renderer: engineering` and
//  `present_pixels: false`; it never pretends to be a Present capture.
//
//  Frames are published only while the editor's ONE derived
//  `observationFrameReadiness` reports no transient preview. Tool, blend,
//  shell, delete/replace-face, pattern-ghost, exploded-view and material-draft
//  previews change the display scene without moving `session.changeCount`;
//  rendering through them would label uncommitted/unqueried geometry or
//  appearance as the model at the returned generation. Such a state is refused
//  before a frame exists, and `includeImages=false` remains the honest
//  query-only route. The fence reads state and never applies or cancels a
//  draft, moves the camera or edits the document.
//
//  SPDX-License-Identifier: MPL-2.0
//

import CoreGraphics
import Foundation
import ImageIO
import simd

/// Which transient editor preview currently prevents a frame from being
/// published as the queried model at the returned generation. These are
/// display-only states owned by the editor, not document commands: they change
/// the live viewport without moving `session.changeCount`, so a frame rendered
/// through them would not describe the body/occurrence rows and committed
/// material returned at that generation.
public nonisolated enum CADObservationFrameBlocker: String, Sendable, Equatable {
    case toolPreview = "tool_preview"
    case blendPreview = "blend_preview"
    case shellPreview = "shell_preview"
    case deleteFacePreview = "delete_face_preview"
    case replaceFacePreview = "replace_face_preview"
    case patternPreview = "pattern_preview"
    case explodedViewPreview = "exploded_view_preview"
    case materialPreview = "material_preview"
}

/// The editor's derived, read-only answer to "may observation publish frames
/// right now?". `blocker == nil` is the only state that permits a frame; every
/// blocked state means the live `scene` contains transient display geometry
/// that the body/occurrence query does not describe at the same generation.
/// The readiness itself is never a permission and never changes user state.
public nonisolated struct CADObservationFrameReadiness: Sendable, Equatable {
    /// The precise preview that blocks frame publication, or nil when ready.
    public let blocker: CADObservationFrameBlocker?
    /// What the live scene is displaying that the query does not describe.
    public let detail: String
    /// How the user can reach a settled state (finish/cancel/reset), phrased
    /// as guidance rather than an action observation performs for them.
    public let guidance: String

    static let ready = CADObservationFrameReadiness(
        blocker: nil, detail: "", guidance: "")

    static func blocked(_ blocker: CADObservationFrameBlocker,
                        detail: String, guidance: String) -> Self {
        CADObservationFrameReadiness(blocker: blocker, detail: detail,
                                     guidance: guidance)
    }

    public var isReady: Bool { blocker == nil }

    /// Model/human-facing refusal. It names the precise preview and the one
    /// non-mutating alternative (query-only observation); it never asks the
    /// observation to cancel the user's edit on its own.
    public var refusalMessage: String {
        guard blocker != nil else { return "" }
        return "Native observation images are paused while \(detail). \(guidance) "
            + "No tool, selection, camera or document state was changed. Re-run observe "
            + "with includeImages=false to read the body rows without rendering."
    }
}

/// One requested observation view. Degrees cross this boundary once and are
/// converted to radians once; `distanceScale` multiplies the fitted turntable
/// distance (the same meaning as the original-model viewer contract).
public nonisolated struct CADObservationView: Sendable, Equatable {
    public var azimuthDegrees: Double
    public var elevationDegrees: Double
    public var distanceScale: Double

    public init(azimuthDegrees: Double, elevationDegrees: Double,
                distanceScale: Double = 1) {
        self.azimuthDegrees = azimuthDegrees
        self.elevationDegrees = elevationDegrees
        self.distanceScale = distanceScale
    }
}

/// Requested projection for an observation frame. Nil uses the native
/// document's saved scene projection (perspective when the package has none),
/// never the user's transient orbit camera.
public nonisolated enum CADObservationProjection: String, Sendable,
                                                     Equatable, CaseIterable {
    case perspective
    case orthographic
}

/// The exact native generation one observation is bound to.
public nonisolated struct CADObservationIdentity: Sendable, Equatable {
    public var revision: Int
    public var changeCount: Int
    public var contentSHA256: String
    public var modelSHA256: String
    public var isReadOnly: Bool
    public var hasUnsavedChanges: Bool
    public var bodyCount: Int
    public var sketchCount: Int
    public var featureCount: Int
    public var hasAssembly: Bool

    public init(revision: Int, changeCount: Int, contentSHA256: String,
                modelSHA256: String, isReadOnly: Bool, hasUnsavedChanges: Bool,
                bodyCount: Int, sketchCount: Int, featureCount: Int,
                hasAssembly: Bool) {
        self.revision = revision
        self.changeCount = changeCount
        self.contentSHA256 = contentSHA256
        self.modelSHA256 = modelSHA256
        self.isReadOnly = isReadOnly
        self.hasUnsavedChanges = hasUnsavedChanges
        self.bodyCount = bodyCount
        self.sketchCount = sketchCount
        self.featureCount = featureCount
        self.hasAssembly = hasAssembly
    }
}

/// The workbench display state the observation scene was read from. These
/// are transient view aids (not saved appearance): reporting them keeps a
/// sectioned/isolated/alternate-display observation honest instead of
/// implying the frames always show the whole default shaded part.
public nonisolated struct CADObservationDisplayState: Sendable, Equatable {
    public var sectioned: Bool
    public var isolated: Bool
    public var displayMode: String
    public var hiddenEdges: Bool
    public var groundShadow: Bool

    public init(sectioned: Bool, isolated: Bool, displayMode: String,
                hiddenEdges: Bool, groundShadow: Bool) {
        self.sectioned = sectioned
        self.isolated = isolated
        self.displayMode = displayMode
        self.hiddenEdges = hiddenEdges
        self.groundShadow = groundShadow
    }
}

/// One actual drawable identity in the current engineering scene. Body entries
/// carry a model body id; assembly entries carry an occurrence id and, when it
/// resolves, that occurrence's source body id. The two identities are separate
/// on purpose: an assembly instance id is never reported as a body id.
public nonisolated enum CADObservationSceneMemberKind: String, Sendable, Equatable {
    case body
    case assemblyInstance = "assembly_instance"
    case editorPreview = "editor_preview"
}

/// Why a model body or drawable leaf occurrence does not contribute geometry
/// to the current scene. These are scene-membership reasons, not pixel
/// visibility results: an included object can still be occluded or sectioned.
public nonisolated enum CADObservationSceneOmissionReason: String, Sendable, Equatable {
    case hidden
    case outsideIsolate = "outside_isolate"
    case sourceBodyMissing = "source_body_missing"
    case unplaceableTransform = "unplaceable_transform"
    case replacedByEditorPreview = "replaced_by_editor_preview"
    case notInScene = "not_in_scene"
}

/// One bounded scene-membership row. `drawableCount` is the number of actual
/// drawables that reuse a body identity (0 when omitted, 1 for an ordinary
/// included body, and >1 for display-only drawables such as pattern ghosts).
public nonisolated struct CADObservationSceneMember: Sendable, Equatable {
    public var kind: CADObservationSceneMemberKind
    public var bodyID: UUID?
    public var assemblyInstanceID: UUID?
    public var sourceBodyID: UUID?
    public var included: Bool
    public var reason: CADObservationSceneOmissionReason?
    public var drawableCount: Int
    /// Transient kind for an editor-preview entry, or "pattern_preview" on a
    /// model body whose drawable_count includes display-only ghost drawables.
    public var previewKind: String?

    public init(kind: CADObservationSceneMemberKind, bodyID: UUID? = nil,
                assemblyInstanceID: UUID? = nil, sourceBodyID: UUID? = nil,
                included: Bool, reason: CADObservationSceneOmissionReason? = nil,
                drawableCount: Int, previewKind: String? = nil) {
        self.kind = kind
        self.bodyID = bodyID
        self.assemblyInstanceID = assemblyInstanceID
        self.sourceBodyID = sourceBodyID
        self.included = included
        self.reason = reason
        self.drawableCount = drawableCount
        self.previewKind = previewKind
    }
}

/// The current engineering scene's actual body/instance membership, bound to
/// the same revision/change count/content SHA used by the observation. The
/// members array is complete for one synchronous snapshot; callers page it
/// before publishing so model-visible JSON stays bounded.
public nonisolated struct CADObservationSceneMembership: Sendable, Equatable {
    public var revision: Int
    public var changeCount: Int
    public var contentSHA256: String
    public var assemblyPresent: Bool
    public var assemblyDecoded: Bool
    public var subassemblyContainerCount: Int
    public var members: [CADObservationSceneMember]
    public var includedBodyCount: Int
    public var omittedBodyCount: Int
    public var includedInstanceCount: Int
    public var omittedInstanceCount: Int
    public var editorPreviewCount: Int

    public var total: Int { members.count }

    public init(revision: Int, changeCount: Int, contentSHA256: String,
                assemblyPresent: Bool, assemblyDecoded: Bool,
                subassemblyContainerCount: Int,
                members: [CADObservationSceneMember],
                includedBodyCount: Int, omittedBodyCount: Int,
                includedInstanceCount: Int, omittedInstanceCount: Int,
                editorPreviewCount: Int) {
        self.revision = revision
        self.changeCount = changeCount
        self.contentSHA256 = contentSHA256
        self.assemblyPresent = assemblyPresent
        self.assemblyDecoded = assemblyDecoded
        self.subassemblyContainerCount = subassemblyContainerCount
        self.members = members
        self.includedBodyCount = includedBodyCount
        self.omittedBodyCount = omittedBodyCount
        self.includedInstanceCount = includedInstanceCount
        self.omittedInstanceCount = omittedInstanceCount
        self.editorPreviewCount = editorPreviewCount
    }
}

/// One actual observation frame. The pose fields describe the camera that
/// really rendered the pixels; `requested*` and `effective*` differ only by
/// the degree→radian round trip (and an exact pole frame is labelled).
public nonisolated struct CADObservationFrame: Sendable, Equatable {
    public var pngData: Data
    public var width: Int
    public var height: Int
    public var imageSHA256: String
    public var viewIndex: Int
    public var requestedAzimuthDegrees: Double
    public var requestedElevationDegrees: Double
    public var effectiveAzimuthDegrees: Double
    public var effectiveElevationDegrees: Double
    /// The exact radians the camera used (the same values used for the view
    /// matrix), so pole float representation is never hidden behind a rounded
    /// degree value.
    public var azimuthRadians: Double
    public var elevationRadians: Double
    public var distanceMM: Double
    public var targetMM: [Double]
    public var upVector: [Double]
    public var projection: String
    public var fovYDegrees: Double
    /// True when the request selected the exact top/bottom pole frame. The
    /// camera uses an explicit horizontal up vector there; no 89° fallback is
    /// substituted and the reported elevation is the requested ±90°.
    public var poleView: Bool
    public var revision: Int
    public var changeCount: Int
    public var contentSHA256: String
    public var renderer: String
    public var note: String

    public init(pngData: Data, width: Int, height: Int, imageSHA256: String,
                viewIndex: Int, requestedAzimuthDegrees: Double,
                requestedElevationDegrees: Double,
                effectiveAzimuthDegrees: Double,
                effectiveElevationDegrees: Double,
                azimuthRadians: Double, elevationRadians: Double,
                distanceMM: Double, targetMM: [Double], upVector: [Double],
                projection: String, fovYDegrees: Double, poleView: Bool,
                revision: Int, changeCount: Int, contentSHA256: String,
                renderer: String, note: String) {
        self.pngData = pngData
        self.width = width
        self.height = height
        self.imageSHA256 = imageSHA256
        self.viewIndex = viewIndex
        self.requestedAzimuthDegrees = requestedAzimuthDegrees
        self.requestedElevationDegrees = requestedElevationDegrees
        self.effectiveAzimuthDegrees = effectiveAzimuthDegrees
        self.effectiveElevationDegrees = effectiveElevationDegrees
        self.azimuthRadians = azimuthRadians
        self.elevationRadians = elevationRadians
        self.distanceMM = distanceMM
        self.targetMM = targetMM
        self.upVector = upVector
        self.projection = projection
        self.fovYDegrees = fovYDegrees
        self.poleView = poleView
        self.revision = revision
        self.changeCount = changeCount
        self.contentSHA256 = contentSHA256
        self.renderer = renderer
        self.note = note
    }
}

@MainActor
public extension FloeCADDocument {
    /// The current transient display aids, read WITHOUT changing them. The
    /// observation uses the same value-copy scene, so its frames and this
    /// report describe the same display state.
    func observationDisplayState() -> CADObservationDisplayState {
        let model = viewModel()
        return CADObservationDisplayState(
            sectioned: model.sectionState != nil,
            isolated: model.isolatedBodyIDs != nil,
            displayMode: model.displayMode.rawValue,
            hiddenEdges: model.showHiddenEdges,
            groundShadow: model.groundShadowEnabled)
    }

    /// The actual current engineering scene's body/instance membership. It is
    /// derived from the SAME `viewModel().scene` value the renderer consumes,
    /// at this document generation; it never renders, mutates, or infers a
    /// face/topology identity from pixels. Scene drawables that are transient
    /// editor previews are labelled instead of being passed off as model
    /// bodies. Drawable leaf assembly occurrences carry both their instance id
    /// and their resolved source body id.
    func observationSceneMembership() -> CADObservationSceneMembership {
        let model = viewModel()
        let document = session.document
        let scene = model.scene
        let identity = observationIdentity()

        // Transient preview bodies are display-only. A replacement preview can
        // reuse its source body id (blend/shell/delete/replace-face), so match
        // on the live preview values rather than only on "not a document body".
        var previewKinds: [UUID: String] = [:]
        var previewSourceIDs: [UUID: UUID] = [:]
        var replacedBodyIDs = Set<UUID>()
        if let context = model.toolContext, let preview = context.preview {
            previewKinds[preview.id.raw] = "tool_preview"
            if context.previewReplacesSource, let source = context.sourceBody {
                replacedBodyIDs.insert(source.raw)
                previewSourceIDs[preview.id.raw] = source.raw
            }
        }
        if let preview = model.blendPreview {
            previewKinds[preview.id.raw] = "blend_preview"
            if let source = model.blendBodyID {
                replacedBodyIDs.insert(source.raw)
                previewSourceIDs[preview.id.raw] = source.raw
            }
        }
        if let preview = model.shellPreview {
            previewKinds[preview.id.raw] = "shell_preview"
            if let source = model.shellBodyID {
                replacedBodyIDs.insert(source.raw)
                previewSourceIDs[preview.id.raw] = source.raw
            }
        }
        if let preview = model.deleteFacePreview {
            previewKinds[preview.id.raw] = "delete_face_preview"
            if let source = model.deleteFaceBodyID {
                replacedBodyIDs.insert(source.raw)
                previewSourceIDs[preview.id.raw] = source.raw
            }
        }
        if let preview = model.replaceFacePreview {
            previewKinds[preview.id.raw] = "replace_face_preview"
            if let source = model.replaceFaceBodyID {
                replacedBodyIDs.insert(source.raw)
                previewSourceIDs[preview.id.raw] = source.raw
            }
        }

        let documentBodyIDs = Set(document.bodies.map(\.id.raw))
        var bodyDrawableCounts: [UUID: Int] = [:]
        var includedInstanceIDs = Set<UUID>()
        var previewDrawableIDs: [UUID] = []
        var seenPreviewIDs = Set<UUID>()
        for drawable in scene.bodies {
            let id = drawable.id.raw
            if let instanceID = drawable.assemblyInstanceID {
                includedInstanceIDs.insert(instanceID)
            } else if previewKinds[id] != nil {
                if seenPreviewIDs.insert(id).inserted { previewDrawableIDs.append(id) }
            } else if documentBodyIDs.contains(id) {
                bodyDrawableCounts[id, default: 0] += 1
            } else if seenPreviewIDs.insert(id).inserted {
                // A scene-only body that is not one of the named previews is
                // still transient; label it honestly rather than as a model
                // body. It is never given a face or topology identity.
                previewDrawableIDs.append(id)
            }
        }

        var members: [CADObservationSceneMember] = []
        var includedBodyCount = 0
        var omittedBodyCount = 0
        let isolated = model.isolatedBodyIDs
        for body in document.bodies {
            let id = body.id.raw
            let drawableCount = bodyDrawableCounts[id] ?? 0
            let included = drawableCount > 0
            var reason: CADObservationSceneOmissionReason?
            if included {
                includedBodyCount += 1
            } else {
                // Same exclusion order as `EditorViewModel.scene`: persisted
                // hidden, a replacement preview, then transient isolate.
                if body.isHidden {
                    reason = .hidden
                } else if replacedBodyIDs.contains(id) {
                    reason = .replacedByEditorPreview
                } else if let isolated, !isolated.contains(body.id) {
                    reason = .outsideIsolate
                } else {
                    reason = .notInScene
                }
                omittedBodyCount += 1
            }
            var previewKind: String?
            if included, drawableCount > 1, model.patternState?.bodyID == body.id {
                previewKind = "pattern_preview"
            }
            members.append(CADObservationSceneMember(
                kind: .body, bodyID: id, included: included, reason: reason,
                drawableCount: drawableCount, previewKind: previewKind))
        }

        var assembly: CADAssembly?
        var assemblyDecoded = true
        if let data = document.assemblyData {
            do {
                assembly = try CADAssembly.decode(from: data)
            } catch {
                assemblyDecoded = false
            }
        }
        let previewViewID = assembly.flatMap { assembly in
            CADExplodedViewPreview.current(for: session)?.resolvedViewID(in: assembly)
        }
        let occurrences = assembly?.occurrences(viewID: previewViewID,
                                                includeHidden: true) ?? []
        var includedInstanceCount = 0
        var omittedInstanceCount = 0
        var subassemblyContainerCount = 0
        for occurrence in occurrences {
            guard occurrence.subassemblyID == nil else {
                // A subassembly container is structural, never a drawable part.
                subassemblyContainerCount += 1
                continue
            }
            let instanceID = occurrence.instance.id
            let sourceBodyID = occurrence.effectiveBodyID
            let included = includedInstanceIDs.contains(instanceID)
            var reason: CADObservationSceneOmissionReason?
            if included {
                includedInstanceCount += 1
            } else {
                if !occurrence.isVisible {
                    reason = .hidden
                } else if sourceBodyID == nil {
                    reason = .sourceBodyMissing
                } else if let sourceBodyID, !documentBodyIDs.contains(sourceBodyID) {
                    reason = .sourceBodyMissing
                } else if !(occurrence.explodedWorldTransform
                                ?? occurrence.worldTransform).isPlaceable {
                    reason = .unplaceableTransform
                } else {
                    reason = .notInScene
                }
                omittedInstanceCount += 1
            }
            members.append(CADObservationSceneMember(
                kind: .assemblyInstance, assemblyInstanceID: instanceID,
                sourceBodyID: sourceBodyID, included: included, reason: reason,
                drawableCount: included ? 1 : 0))
        }

        for id in previewDrawableIDs {
            let sourceID: UUID? = previewSourceIDs[id].flatMap { source in
                source == id ? nil : source
            }
            members.append(CADObservationSceneMember(
                kind: .editorPreview, bodyID: id, sourceBodyID: sourceID,
                included: true, drawableCount: 1,
                previewKind: previewKinds[id] ?? "unknown_preview"))
        }

        return CADObservationSceneMembership(
            revision: identity.revision,
            changeCount: identity.changeCount,
            contentSHA256: identity.contentSHA256,
            assemblyPresent: document.assemblyData != nil,
            assemblyDecoded: assemblyDecoded,
            subassemblyContainerCount: subassemblyContainerCount,
            members: members,
            includedBodyCount: includedBodyCount,
            omittedBodyCount: omittedBodyCount,
            includedInstanceCount: includedInstanceCount,
            omittedInstanceCount: omittedInstanceCount,
            editorPreviewCount: previewDrawableIDs.count)
    }

    /// The ONE derived, read-only status for frame publication. The editor
    /// owns the transient preview vars; this accessor keeps the host summary
    /// and the renderer fence on the same answer. It never changes a tool,
    /// selection, camera or document value.
    func observationFrameReadiness() -> CADObservationFrameReadiness {
        viewModel().observationFrameReadiness
    }

    /// The committed + live identity an observation is bound to.
    func observationIdentity() -> CADObservationIdentity {
        let summary = summary()
        return CADObservationIdentity(
            revision: revision,
            changeCount: liveChangeCount,
            contentSHA256: contentSHA256,
            modelSHA256: modelSHA256,
            isReadOnly: isReadOnly,
            hasUnsavedChanges: hasUnsavedChanges,
            bodyCount: summary.bodyCount,
            sketchCount: summary.sketchCount,
            featureCount: summary.featureCount,
            hasAssembly: summary.hasAssembly)
    }

    /// Refuses a stale or mismatched generation BEFORE any frame is rendered.
    /// Every pin is optional; each supplied pin must match exactly.
    func verifyObservationPins(expectedRevision: Int64?,
                               expectedChangeCount: Int?,
                               expectedContentSHA256: String?) throws {
        if let expectedRevision {
            guard expectedRevision >= 0 else {
                throw CADDocumentError(code: "bad_revision",
                                       message: "revision must be a non-negative integer.")
            }
            guard Int64(revision) == expectedRevision else {
                throw CADDocumentError(
                    code: "revision_mismatch",
                    message: "The document is at revision \(revision), not the requested "
                        + "\(expectedRevision). Observe the current document and retry.")
            }
        }
        if let expectedChangeCount {
            guard expectedChangeCount >= 0 else {
                throw CADDocumentError(
                    code: "change_count_mismatch",
                    message: "expectedChangeCount must be a non-negative integer.")
            }
            guard liveChangeCount == expectedChangeCount else {
                throw CADDocumentError(
                    code: "change_count_mismatch",
                    message: "The document's live change count is \(liveChangeCount), not the requested "
                        + "\(expectedChangeCount); the scene (including any unsaved draft) changed. "
                        + "Observe the current generation or re-pin after the edit.")
            }
        }
        if let expectedContentSHA256 {
            let expected = expectedContentSHA256.lowercased()
            guard contentSHA256.lowercased() == expected else {
                throw CADDocumentError(
                    code: "content_mismatch",
                    message: "The last committed package content SHA-256 is \(contentSHA256), not the "
                        + "requested \(expected). The committed package changed; re-read the document "
                        + "before observing it. (This SHA is the committed package identity, never a "
                        + "digest of unsaved mesh bytes.)")
            }
        }
    }

    /// Renders 1...4 actual offscreen frames of the live scene at ONE bounded
    /// generation. The whole loop is synchronous on the main actor, so an edit
    /// cannot interleave between the identity check, the renders and the
    /// returned receipts; the generation is still rechecked before each frame
    /// and once more before returning.
    ///
    /// `shouldCancel` is consulted before every frame and before returning.
    /// Cancellation returns no partial frames.
    func captureObservationViews(_ views: [CADObservationView],
                                 width: Int, height: Int,
                                 projection: CADObservationProjection? = nil,
                                 maximumFrameBytes: Int = 16 * 1024 * 1024,
                                 maximumTotalBytes: Int = 32 * 1024 * 1024,
                                 shouldCancel: @MainActor () -> Bool = { false }) throws
    -> [CADObservationFrame] {
        guard (1...4).contains(views.count),
              (64...2048).contains(width), (64...2048).contains(height) else {
            throw CADDocumentError(
                code: "bad_observation_request",
                message: "observe requires 1...4 views at 64...2048 pixels.")
        }
        guard views.allSatisfy({ view in
            view.azimuthDegrees.isFinite && view.elevationDegrees.isFinite
                && (-90...90).contains(view.elevationDegrees)
                && view.distanceScale.isFinite && (0.1...5).contains(view.distanceScale)
        }) else {
            throw CADDocumentError(
                code: "bad_observation_request",
                message: "observe views require finite azimuth/elevation, elevation within -90...90 "
                    + "and distanceScale within 0.1...5.")
        }
        guard maximumFrameBytes > 0, maximumTotalBytes >= maximumFrameBytes else {
            throw CADDocumentError(
                code: "bad_observation_request",
                message: "The observation frame budget is invalid.")
        }
        guard !isReadOnly else {
            throw CADDocumentError(
                code: "document_read_only",
                message: "A .floecad package written by a newer app version opens read-only and is "
                    + "not observed as an editable scene. Update the app or use a matching package.")
        }
        try throwIfObservationCancelled(shouldCancel)
        try throwIfObservationFramesBlocked()

        let identity = observationIdentity()
        guard let context = RenderContext() else {
            throw CADDocumentError(
                code: "viewport_unavailable",
                message: "The offscreen Metal viewport is unavailable on this device/build; "
                    + "no observation image was fabricated.")
        }
        // ONE value copy of the live scene. UI-only overlays are removed from
        // the COPY (never from the live view model) so the observation frames
        // show the document, not the user's current gizmo/selection chrome.
        var scene = viewModel().scene
        scene.gizmo = nil
        scene.pullArrow = nil
        scene.planePickers = []
        for index in scene.bodies.indices {
            // 0 == SelectionStateNone (ShaderTypes.h); the COPY is cleaned so
            // an observation never advertises the user's selection highlight.
            scene.bodies[index].selectionState = 0
        }
        guard let bounds = scene.worldBounds,
              bounds.min.x.isFinite, bounds.min.y.isFinite, bounds.min.z.isFinite,
              bounds.max.x.isFinite, bounds.max.y.isFinite, bounds.max.z.isFinite,
              bounds.min.x <= bounds.max.x, bounds.min.y <= bounds.max.y,
              bounds.min.z <= bounds.max.z else {
            throw CADDocumentError(
                code: "empty_scene",
                message: "The native document has no renderable geometry to observe. "
                    + "Add or import geometry first; no placeholder image is produced.")
        }
        let settings = session.document.sceneSettingsData.flatMap {
            try? JSONDecoder().decode(CADSceneSettings.self, from: $0)
        }
        // X21: the selected saved view is the document's real camera state.
        // `projection` on the request is a TEMPORARY observation override and
        // is deliberately never written back to the saved camera.
        let activeSavedCamera = settings?.activeSavedCameraEntry
        let savedFovYDegrees = activeSavedCamera?.fovYDegrees
            ?? settings?.camera?.fovYDegrees
        let selectedProjection: CADObservationProjection
        if let projection {
            selectedProjection = projection
        } else if let activeSavedCamera {
            selectedProjection = activeSavedCamera.projection.isOrthographic
                ? .orthographic : .perspective
        } else if settings?.camera?.isOrthographic == true {
            selectedProjection = .orthographic
        } else {
            selectedProjection = .perspective
        }
        let fovY: Float = {
            guard let savedFovYDegrees, savedFovYDegrees.isFinite,
                  savedFovYDegrees > 1, savedFovYDegrees < 179 else {
                return TurntableCamera.defaultFovY
            }
            return Float(savedFovYDegrees * .pi / 180)
        }()

        let renderer = Renderer(context: context)
        renderer.scene = scene
        var frames: [CADObservationFrame] = []
        frames.reserveCapacity(views.count)
        var totalBytes = 0

        for (index, view) in views.enumerated() {
            try throwIfObservationCancelled(shouldCancel)
            try throwIfObservationFramesBlocked()
            let current = observationIdentity()
            guard current.revision == identity.revision,
                  current.changeCount == identity.changeCount,
                  current.contentSHA256 == identity.contentSHA256 else {
                throw CADDocumentError(
                    code: "document_changed",
                    message: "The native document changed during observation; no frame was published. "
                        + "Observe the current generation again.")
            }
            var camera = TurntableCamera()
            switch selectedProjection {
            case .perspective: camera.projection = .perspective(fovY: fovY)
            case .orthographic: camera.projection = .orthographic
            }
            camera.fit(boundsMin: bounds.min, boundsMax: bounds.max,
                       aspect: Float(width) / Float(max(height, 1)))
            camera.distance = min(max(camera.distance * Float(view.distanceScale), 0.05),
                                  TurntableCamera.maxZoomDistance)
            camera.azimuth = Float(view.azimuthDegrees * .pi / 180)
            camera.elevation = Float(view.elevationDegrees * .pi / 180)
            let pole = abs(view.elevationDegrees) >= 90 - 1e-9
            if pole {
                // Exact top/bottom frame. The turntable's +Y up is parallel to
                // the view direction at ±90°, so use the horizontal direction
                // the limit approaches. This is a real ±90° plan view, not an
                // undisclosed 89° approximation.
                camera.elevation = view.elevationDegrees >= 0
                    ? Float.pi / 2
                    : -Float.pi / 2
                let azimuth = Double(camera.azimuth)
                let sign = view.elevationDegrees >= 0 ? 1.0 : -1.0
                camera.upVector = SIMD3<Float>(Float(-sign * sin(azimuth)), 0,
                                               Float(-sign * cos(azimuth)))
            } else {
                camera.upVector = SIMD3<Float>(0, 1, 0)
            }
            renderer.camera = camera
            guard let png = renderer.makeThumbnailPNG(
                width: width, height: height,
                transparentBackground: false,
                showGrid: scene.showsGrid), !png.isEmpty else {
                throw CADDocumentError(
                    code: "viewport_unavailable",
                    message: "The offscreen renderer returned no image for view \(index); "
                        + "no placeholder was substituted.")
            }
            guard png.count <= maximumFrameBytes else {
                throw CADDocumentError(
                    code: "observation_budget_exceeded",
                    message: "Observation view \(index) produced \(png.count) bytes, above the "
                        + "\(maximumFrameBytes)-byte frame budget.")
            }
            totalBytes += png.count
            guard totalBytes <= maximumTotalBytes else {
                throw CADDocumentError(
                    code: "observation_budget_exceeded",
                    message: "The observation frames exceeded the \(maximumTotalBytes)-byte total budget.")
            }
            guard let actual = cadObservationPNGSize(png),
                  actual.width == width, actual.height == height else {
                throw CADDocumentError(
                    code: "observation_budget_exceeded",
                    message: "Observation view \(index) did not return a PNG with the requested "
                        + "\(width)x\(height) pixels; the image was discarded.")
            }
            let effectiveElevation = pole
                ? view.elevationDegrees
                : Double(camera.elevation) * 180 / .pi
            frames.append(CADObservationFrame(
                pngData: png,
                width: actual.width,
                height: actual.height,
                imageSHA256: CADMaterialTexture.digest(png),
                viewIndex: index,
                requestedAzimuthDegrees: view.azimuthDegrees,
                requestedElevationDegrees: view.elevationDegrees,
                effectiveAzimuthDegrees: Double(camera.azimuth) * 180 / .pi,
                effectiveElevationDegrees: effectiveElevation,
                azimuthRadians: Double(camera.azimuth),
                elevationRadians: Double(camera.elevation),
                distanceMM: Double(camera.distance),
                targetMM: [Double(camera.target.x), Double(camera.target.y),
                           Double(camera.target.z)],
                upVector: [Double(camera.upVector.x), Double(camera.upVector.y),
                           Double(camera.upVector.z)],
                projection: selectedProjection.rawValue,
                fovYDegrees: Double(camera.fovY) * 180 / .pi,
                poleView: pole,
                revision: identity.revision,
                changeCount: identity.changeCount,
                contentSHA256: identity.contentSHA256,
                renderer: "engineering",
                note: "Actual offscreen engineering snapshot rendered by a detached Renderer "
                    + "over a value-copy scene; not the live RealityKit Present, and it does not "
                    + "change the user's camera, selection or document."))
        }
        try throwIfObservationCancelled(shouldCancel)
        try throwIfObservationFramesBlocked()
        let after = observationIdentity()
        guard after.revision == identity.revision,
              after.changeCount == identity.changeCount,
              after.contentSHA256 == identity.contentSHA256 else {
            throw CADDocumentError(
                code: "document_changed",
                message: "The native document changed during observation; no frame was published. "
                    + "Observe the current generation again.")
        }
        return frames
    }

    /// Refuses frames while the editor's derived status reports transient
    /// preview geometry. Re-read before every frame and before returning so a
    /// preview that appears during the block cannot leak into a published
    /// frame list. This checks only; it never cancels the edit.
    private func throwIfObservationFramesBlocked() throws {
        let readiness = observationFrameReadiness()
        guard readiness.isReady else {
            throw CADDocumentError(code: "transient_preview_active",
                                   message: readiness.refusalMessage)
        }
    }

    private func throwIfObservationCancelled(_ shouldCancel: @MainActor () -> Bool) throws {
        if shouldCancel() || Task.isCancelled {
            throw CADDocumentError(code: "cancelled",
                                   message: "The observation was cancelled before it completed.")
        }
    }
}

/// PNG container identity check; a renderer that reports requested dimensions
/// but returned different pixels must not become trusted vision evidence.
private func cadObservationPNGSize(_ data: Data) -> (width: Int, height: Int)? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          image.width > 0, image.height > 0 else { return nil }
    return (image.width, image.height)
}
