//
//  CADMaterialEditingModel.swift
//  FloeCADKit
//
//  Native material editing session for the workbench.
//
//  Editing is a LOCAL draft: sliders/textures/mapping change only this model
//  and a transient viewport preview. Apply commits ONE undoable composite
//  (document library copy + applied body/face snapshot); Cancel restores the
//  viewport and changes nothing. Browsing the library never mutates a draft,
//  and a library delete never changes an applied appearance because the applied
//  `BodyMaterialSpec` is an independent snapshot.
//

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Observation
import SwiftUI
import UIKit
import simd

// MARK: - Target

/// The immutable identity of the face the inspector was opened on. The
/// numeric `CADMaterialTarget.faceIndex` is only valid for `meshRevision`;
/// after a rebuild the signature must be matched again and the stored index
/// is never reused.
nonisolated struct CADMaterialFaceIdentity: Equatable, Sendable {
    /// The face signature captured when the inspector opened. Rebuild
    /// re-resolution always starts from this immutable identity; it is never
    /// replaced by whichever face currently occupies the old index.
    var signature: FaceSignature
    /// The current face's signature once a rebind has been proven. Apply uses
    /// this exact binding; nil means `signature` is still the exact binding.
    var resolvedSignature: FaceSignature? = nil
    /// The body's `meshRevision` when this signature/index pair was captured.
    var meshRevision: UInt64
    /// Triangle ordinals in that mesh generation. Preview only; it is replaced
    /// with the current authoritative table range when the mesh is rebuilt.
    var triangles: [Int]
}

nonisolated struct CADMaterialTarget: Equatable, Sendable {
    var bodyIDs: [UUID]
    var faceBodyID: UUID?
    /// Current 1-based kernel face index; nil means the pick could not be
    /// mapped to exactly one analytic face and must be reselected.
    var faceIndex: Int?
    var bodyNames: [String]
    var isFaceTarget: Bool
    var note: String?
    /// Stable face binding, set for a face target. The index above is never
    /// trusted without this identity.
    var faceIdentity: CADMaterialFaceIdentity?
    /// Mesh generation currently bound to each selected body. Whole-body
    /// identity is the body UUID; these revisions are diagnostics and keep the
    /// selection's provenance explicit.
    var bodyMeshRevisions: [UUID: UInt64]

    static let empty = CADMaterialTarget(
        bodyIDs: [], faceBodyID: nil, faceIndex: nil, bodyNames: [],
        isFaceTarget: false, note: nil, faceIdentity: nil,
        bodyMeshRevisions: [:])

    var isEmpty: Bool { bodyIDs.isEmpty }
    var needsReselect: Bool { isFaceTarget && faceIndex == nil }

    var title: String {
        if isFaceTarget {
            let name = bodyNames.first ?? FloeCADStrings.text("cad.material.target.body", "Body")
            if let faceIndex {
                return FloeCADStrings.format("cad.material.target.face", "%@ · Face %d",
                                             name, faceIndex)
            }
            return FloeCADStrings.format("cad.material.target.faceUnresolved",
                                         "%@ · Face needs reselecting", name)
        }
        if bodyIDs.count == 1 {
            return bodyNames.first ?? FloeCADStrings.text("cad.material.target.one", "1 body")
        }
        return FloeCADStrings.format("cad.material.target.many", "%d bodies",
                                     bodyIDs.count)
    }
}

// MARK: - Preview sink

@MainActor
protocol CADMaterialPreviewSink: AnyObject {
    func previewMaterial(_ spec: BodyMaterialSpec, for target: CADMaterialTarget)
    func endMaterialPreview()
}

/// Editor-side preview sink. It writes the transient `MaterialDraftPreview`
/// on the SAME `EditorViewModel` the viewport renders; no document command and
/// no undo record are created. Strong ownership belongs to the presenting
/// view/sheet.
@MainActor
final class CADEditorMaterialPreviewSink: CADMaterialPreviewSink {
    weak var viewModel: EditorViewModel?

    init(viewModel: EditorViewModel? = nil) {
        self.viewModel = viewModel
    }

    func previewMaterial(_ spec: BodyMaterialSpec, for target: CADMaterialTarget) {
        guard let viewModel else { return }
        if let faceBody = target.faceBodyID {
            viewModel.setMaterialDraftPreview(spec,
                                              faceBodyID: BodyID(raw: faceBody),
                                              faceIndex: target.faceIndex,
                                              faceTriangles: target.faceIdentity?.triangles ?? [])
        } else {
            let ids = Set(target.bodyIDs.compactMap { BodyID(raw: $0) })
            viewModel.setMaterialDraftPreview(spec, bodyIDs: ids)
        }
    }

    func endMaterialPreview() {
        viewModel?.clearMaterialDraftPreview()
    }
}

// MARK: - Target resolution

@MainActor
enum CADMaterialTargetResolver {
    static func resolve(viewModel: EditorViewModel) -> CADMaterialTarget {
        if case .faceSelected(let bodyID) = viewModel.mode,
           let context = viewModel.toolContext,
           !context.faceTriangles.isEmpty,
           let body = viewModel.session.document.body(with: bodyID) {
            return faceTarget(for: body, triangles: context.faceTriangles,
                              session: viewModel.session)
        }
        let bodies = viewModel.session.document.bodies
            .filter { viewModel.selection.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return CADMaterialTarget(
            bodyIDs: bodies.map(\.id.raw),
            faceBodyID: nil,
            faceIndex: nil,
            bodyNames: bodies.map(\.name),
            isFaceTarget: false,
            note: nil,
            faceIdentity: nil,
            bodyMeshRevisions: Dictionary(uniqueKeysWithValues: bodies.map {
                ($0.id.raw, $0.meshRevision)
            }))
    }

    static func resolve(document: FloeCADDocument) -> CADMaterialTarget {
        resolve(viewModel: document.viewModel())
    }

    // MARK: Face target resolution

    /// Resolve one face pick into a stable identity. The authoritative feature
    /// face table is preferred whenever it is valid for the current mesh
    /// generation: it names the picked face directly, including curved faces
    /// that the planar fallback cannot express. Without a trustworthy table the
    /// existing planar geometric match remains the fallback.
    static func faceTarget(for body: Body, triangles: [Int],
                           session: DocumentSession) -> CADMaterialTarget {
        var faceIndex: Int?
        var signature: FaceSignature?
        var note: String?

        if let entry = authoritativeEntry(for: body, triangles: triangles,
                                          session: session) {
            switch CADFaceMaterialResolver.match(
                CADFaceKey(signature: entry.signature),
                candidates: CADFaceMaterialResolver.candidates(for: body)) {
            case .resolved(let index, _):
                faceIndex = index
                signature = kernelSignature(for: index, in: body)
            case .ambiguous(let indices):
                note = FloeCADStrings.format(
                    "cad.material.error.ambiguous",
                    "That face is not unique (%d candidates). Reselect a distinct face.",
                    indices.count)
            case .unresolved:
                note = reselectHint
            }
        } else if let index = kernelFaceIndex(in: body, triangles: triangles) {
            faceIndex = index
            signature = kernelSignature(for: index, in: body)
        } else {
            note = reselectHint
        }

        // Never keep a numeric index without the signature it was derived
        // from: Apply would otherwise have to trust the index alone.
        if faceIndex == nil || signature == nil {
            faceIndex = nil
            signature = nil
            note = note ?? reselectHint
        }

        let previewTriangles: [Int]
        if let signature,
           let authoritative = authoritativeTriangles(for: signature, in: body,
                                                      session: session) {
            previewTriangles = authoritative
        } else {
            previewTriangles = triangles
        }

        return CADMaterialTarget(
            bodyIDs: [body.id.raw],
            faceBodyID: body.id.raw,
            faceIndex: faceIndex,
            bodyNames: [body.name],
            isFaceTarget: true,
            note: note,
            faceIdentity: signature.map {
                CADMaterialFaceIdentity(signature: $0,
                                        meshRevision: body.meshRevision,
                                        triangles: previewTriangles)
            },
            bodyMeshRevisions: [body.id.raw: body.meshRevision])
    }

    /// The single current table entry that contains every picked triangle.
    /// Returns nil when the table is stale or the pick spans more than one
    /// face; callers fall back rather than guessing between entries.
    static func authoritativeEntry(for body: Body, triangles: [Int],
                                   session: DocumentSession) -> FaceTable.Entry? {
        guard !triangles.isEmpty,
              let table = session.lastFaceTables[body.id],
              session.lastNamingRevisions[body.id] == body.meshRevision else {
            return nil
        }
        let picked = Set(triangles)
        var matched: FaceTable.Entry?
        for entry in table.entries where !entry.triangles.isEmpty {
            guard picked.isSubset(of: Set(entry.triangles)) else { continue }
            if matched != nil { return nil }
            matched = entry
        }
        return matched
    }

    static func kernelMatch(for signature: FaceSignature, in body: Body) -> CADFaceMatch {
        CADFaceMaterialResolver.match(
            CADFaceKey(signature: signature),
            candidates: CADFaceMaterialResolver.candidates(for: body))
    }

    static func kernelSignature(for index: Int, in body: Body) -> FaceSignature? {
        CADFaceMaterialResolver.candidates(for: body)
            .first(where: { $0.index == index })?.signature
    }

    /// Exact-enough identity check for the same captured face. Used only to
    /// confirm the index still points at the face selected in the same mesh
    /// generation; a rebuilt body goes through the signature resolver instead.
    static func signaturesMatch(_ lhs: FaceSignature,
                                _ rhs: FaceSignature) -> Bool {
        guard lhs.kind == rhs.kind,
              let score = CADFaceMaterialResolver.score(lhs, rhs) else { return false }
        return score >= 0.9995
    }

    /// The authoritative triangle range for a stable signature, when the
    /// session's face table is valid for the current mesh generation and
    /// exactly one entry matches. Nil means "do not paint a guessed range".
    static func authoritativeTriangles(for signature: FaceSignature, in body: Body,
                                       session: DocumentSession) -> [Int]? {
        guard let table = session.lastFaceTables[body.id],
              session.lastNamingRevisions[body.id] == body.meshRevision else {
            return nil
        }
        var scored: [(triangles: [Int], score: Double)] = []
        for entry in table.entries {
            guard !entry.triangles.isEmpty,
                  let score = CADFaceMaterialResolver.score(signature, entry.signature)
            else { continue }
            scored.append((entry.triangles, score))
        }
        scored.sort { $0.score > $1.score }
        guard let best = scored.first,
              best.score >= CADFaceMaterialResolver.matchThreshold,
              scored.count == 1
                || best.score - scored[1].score >= CADFaceMaterialResolver.ambiguityMargin
        else { return nil }
        return best.triangles
    }

    private static var reselectHint: String {
        FloeCADStrings.text(
            "cad.material.target.reselectFaceHint",
            "This selection doesn't match one stable face. Reselect a single face.")
    }

    /// Match the selected render triangles to exactly one planar OCCT face.
    /// This is a deterministic geometric comparison against the kernel's face
    /// signatures — never an index guess. Curved/ambiguous selections return
    /// nil and must be reselected.
    static func kernelFaceIndex(in body: Body, triangles: [Int]) -> Int? {
        guard let brep = body.brep, !triangles.isEmpty else { return nil }
        let mesh = body.render
        var totalArea: Double = 0
        var weightedNormal = SIMD3<Double>.zero
        var weightedCentroid = SIMD3<Double>.zero
        for triangle in triangles {
            guard triangle >= 0, triangle * 3 + 2 < mesh.indices.count else { continue }
            let i0 = Int(mesh.indices[triangle * 3])
            let i1 = Int(mesh.indices[triangle * 3 + 1])
            let i2 = Int(mesh.indices[triangle * 3 + 2])
            guard i0 < mesh.positions.count, i1 < mesh.positions.count,
                  i2 < mesh.positions.count else { continue }
            let p0 = SIMD3<Double>(mesh.positions[i0])
            let p1 = SIMD3<Double>(mesh.positions[i1])
            let p2 = SIMD3<Double>(mesh.positions[i2])
            let cross = simd_cross(p1 - p0, p2 - p0)
            let area = simd_length(cross) * 0.5
            guard area.isFinite, area > 1e-9 else { continue }
            totalArea += area
            weightedNormal += simd_normalize(cross) * area
            weightedCentroid += ((p0 + p1 + p2) / 3) * area
        }
        guard totalArea > 1e-6, simd_length(weightedNormal) > 1e-9 else { return nil }
        let normal = simd_normalize(weightedNormal)
        let centroid = weightedCentroid / totalArea
        var planarCandidates: [Int] = []
        for face in OCCTKernel.faceInfo(brep) {
            guard let signature = face.signature else { continue }
            guard case .planar = signature.kind else { continue }
            let faceNormal = signature.normal
            let alignment = abs(simd_dot(faceNormal, normal))
            guard alignment > 0.999 else { continue }
            let planeOffset = simd_dot(faceNormal, centroid)
            guard abs(planeOffset - signature.planeOffset) < 0.15 else { continue }
            let areaTolerance = max(0.5, signature.area * 0.03)
            guard abs(signature.area - totalArea) <= areaTolerance else { continue }
            let centroidDistance = simd_length(signature.centroid - centroid)
            guard centroidDistance <= max(0.6, sqrt(max(signature.area, 1)) * 0.02) else { continue }
            planarCandidates.append(face.index)
        }
        guard planarCandidates.count == 1 else { return nil }
        return planarCandidates[0]
    }
}

// MARK: - Origin

nonisolated enum CADMaterialOrigin: Equatable, Sendable {
    case new
    case document(MaterialID)
    case personal(MaterialID)
    case preset(String)
}

// MARK: - Draft model

@MainActor
@Observable
final class CADMaterialDraftModel {
    let document: FloeCADDocument
    let personalStore: CADPersonalMaterialLibraryStore
    var target: CADMaterialTarget
    @ObservationIgnored weak var previewSink: CADMaterialPreviewSink?
    @ObservationIgnored var onApplied: (() -> Void)?

    private(set) var documentLibrary: CADMaterialLibrary = .empty
    private(set) var draft: CADMaterialDefinition
    private(set) var origin: CADMaterialOrigin = .new
    private(set) var baseline: CADMaterialDefinition
    private(set) var errorMessage: String?
    private(set) var statusMessage: String?
    private(set) var isApplying = false
    /// Set when the frozen selection can no longer be applied (a body was
    /// removed, or a rebuilt face cannot be matched uniquely). Kept separate
    /// from `errorMessage` so periodic revalidation does not clear or invent a
    /// user-visible error; Apply reports it verbatim.
    private(set) var targetError: String?
    private(set) var staleBindings: [CADSceneUnresolvedFaceBinding] = []
    /// Faces whose material is saved but whose authoritative render range is
    /// absent for this mesh generation. They are not painted on a guessed
    /// range; the inspector says so.
    private(set) var faceRangeWarnings: [String] = []
    /// New materials are copied to the shared personal library on Apply.
    /// Editing an existing document copy never silently rewrites the personal
    /// entry.
    private(set) var willSaveToPersonal = true

    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var observationTask: Task<Void, Never>?

    init(document: FloeCADDocument,
         target: CADMaterialTarget,
         personalStore: CADPersonalMaterialLibraryStore = .shared) {
        self.document = document
        self.target = target
        self.personalStore = personalStore
        var initial = CADMaterialDefinition(
            name: FloeCADStrings.text("cad.material.defaultName", "Material"))
        if let existing = document.session.document.bodies
            .first(where: { target.bodyIDs.contains($0.id.raw) })?.material,
           existing.materialName != nil {
            initial = CADMaterialDefinition(spec: existing)
        }
        self.draft = initial
        self.baseline = initial
        refreshLibraries()
        refreshStaleBindings()
        startObservingDocument()
    }

    // MARK: Libraries

    var personalLibrary: CADMaterialLibrary { personalStore.library }

    var hasUnsavedChanges: Bool {
        draft.sanitized != baseline.sanitized
    }

    var canApply: Bool {
        !target.isEmpty && !target.needsReselect && targetError == nil && !isApplying
    }

    func refreshLibraries() {
        documentLibrary = CADMaterialLibraryCodec.decode(
            document.session.document.materialLibraryData)
        personalStore.reload()
    }

    func refreshStaleBindings() {
        guard !target.bodyIDs.isEmpty else {
            staleBindings = []
            return
        }
        var rows: [CADSceneUnresolvedFaceBinding] = []
        var warnings: [String] = []
        for body in document.session.document.bodies
        where target.bodyIDs.contains(body.id.raw) && !body.materialFaceBindings.isEmpty {
            for resolution in CADFaceMaterialResolver.resolve(body.materialFaceBindings,
                                                              in: body) {
                guard resolution.resolvedIndex == nil else { continue }
                var candidates: [Int] = []
                if case .ambiguous(let indices) = resolution.match { candidates = indices }
                let reason: String
                switch resolution.match {
                case .unresolved(let text): reason = text
                case .ambiguous: reason = "The stored face signature matches more than one current face."
                case .resolved: reason = ""
                }
                rows.append(CADSceneUnresolvedFaceBinding(
                    bodyID: body.id.raw, bodyName: body.name,
                    materialName: resolution.binding.material.materialName,
                    materialID: resolution.binding.material.materialID,
                    reason: reason, candidateIndices: candidates,
                    signature: resolution.binding.key.signature,
                    capturedIndex: resolution.binding.key.capturedIndex))
            }
        }
        for body in document.session.document.bodies
        where target.bodyIDs.contains(body.id.raw) && !body.materialFaceBindings.isEmpty {
            if document.session.lastFaceTables[body.id] == nil
                || document.session.lastNamingRevisions[body.id] != body.meshRevision {
                warnings.append(FloeCADStrings.format(
                    "cad.material.faceRange.missing",
                    "%@ has face materials with no trustworthy face range in this model generation; they are saved but not drawn individually.",
                    body.name))
            }
        }
        staleBindings = rows
        faceRangeWarnings = warnings
    }

    // MARK: Frozen target

    /// Revalidate the frozen selection against the live document. A face is
    /// bound by its captured signature, never by the old numeric index: after
    /// a mesh rebuild only a unique signature match can restore an index.
    /// Returns the user-facing failure (and disables Apply) when the target
    /// cannot be applied; the draft itself is untouched.
    @discardableResult
    func refreshTargetBinding() -> String? {
        guard !target.isEmpty else {
            targetError = nil
            return nil
        }

        if target.isFaceTarget {
            guard let raw = target.faceBodyID,
                  let body = document.session.document.bodies.first(where: {
                      $0.id.raw == raw
                  }) else {
                return failTarget(FloeCADStrings.text(
                    "cad.material.error.faceRebuilt",
                    "The model changed and that face could no longer be identified. Reselect it in the viewport."))
            }
            guard let identity = target.faceIdentity else {
                // The pick was never resolvable (unsupported/ambiguous face).
                // Keep its original concise reselect hint instead of claiming
                // a rebuild happened.
                return failTarget(target.note ?? FloeCADStrings.text(
                    "cad.material.error.faceRebuilt",
                    "The model changed and that face could no longer be identified. Reselect it in the viewport."))
            }

            let sameGeneration = body.meshRevision == identity.meshRevision
            if sameGeneration, target.faceIndex != nil {
                // The numeric index is legitimate only for the mesh
                // generation it was resolved from. Same revision + the
                // already-resolved index is the exact binding; avoid an
                // expensive OCCT face scan on every slider preview tick.
                target.bodyIDs = [body.id.raw]
                target.bodyNames = [body.name]
                target.bodyMeshRevisions = [body.id.raw: body.meshRevision]
                target.note = nil
                targetError = nil
                return nil
            }
            let expectedSignature = identity.resolvedSignature ?? identity.signature
            var resolvedIndex: Int?
            var currentSignature: FaceSignature?
            if sameGeneration,
               let current = target.faceIndex,
               let currentFaceSignature = CADMaterialTargetResolver.kernelSignature(
                   for: current, in: body),
               CADMaterialTargetResolver.signaturesMatch(currentFaceSignature,
                                                         expectedSignature) {
                resolvedIndex = current
                currentSignature = currentFaceSignature
            } else if case .resolved(let matched, _) = CADMaterialTargetResolver.kernelMatch(
                for: identity.signature, in: body) {
                // The index is NOT reused when the mesh generation changed;
                // only this unique match against the IMMUTABLE captured
                // signature may restore it.
                resolvedIndex = matched
                currentSignature = CADMaterialTargetResolver.kernelSignature(
                    for: matched, in: body)
            }

            guard let resolvedIndex, let currentSignature else {
                return failTarget(FloeCADStrings.text(
                    "cad.material.error.faceRebuilt",
                    "The model changed and that face could no longer be identified. Reselect it in the viewport."))
            }

            let triangles = CADMaterialTargetResolver.authoritativeTriangles(
                for: currentSignature, in: body, session: document.session)
                ?? (sameGeneration ? identity.triangles : [])
            target.faceIndex = resolvedIndex
            target.bodyIDs = [body.id.raw]
            target.bodyNames = [body.name]
            target.bodyMeshRevisions = [body.id.raw: body.meshRevision]
            target.faceIdentity = CADMaterialFaceIdentity(
                signature: identity.signature,
                resolvedSignature: currentSignature,
                meshRevision: body.meshRevision,
                triangles: triangles)
            target.note = nil
            targetError = nil
            if !sameGeneration {
                statusMessage = FloeCADStrings.text(
                    "cad.material.status.faceRebound",
                    "The model was rebuilt; the same face was matched again.")
            }
            return nil
        }

        var liveBodies: [Body] = []
        var missingNames: [String] = []
        for (offset, raw) in target.bodyIDs.enumerated() {
            if let body = document.session.document.bodies.first(where: {
                $0.id.raw == raw
            }) {
                liveBodies.append(body)
            } else {
                missingNames.append(offset < target.bodyNames.count
                                    ? target.bodyNames[offset] : raw.uuidString)
            }
        }
        guard missingNames.isEmpty else {
            return failTarget(FloeCADStrings.format(
                "cad.material.error.targetMissing",
                "Some selected bodies are no longer in this document: %@. Reselect them.",
                missingNames.joined(separator: ", ")))
        }
        target.bodyIDs = liveBodies.map(\.id.raw)
        target.bodyNames = liveBodies.map(\.name)
        var revisions: [UUID: UInt64] = [:]
        for body in liveBodies { revisions[body.id.raw] = body.meshRevision }
        target.bodyMeshRevisions = revisions
        target.note = nil
        targetError = nil
        return nil
    }

    @discardableResult
    private func failTarget(_ message: String) -> String {
        if target.isFaceTarget { target.faceIndex = nil }
        target.note = message
        targetError = message
        // A target that can no longer be proven must not leave the last
        // transient preview painted on the viewport.
        previewTask?.cancel()
        previewSink?.endMaterialPreview()
        return message
    }

    /// Bounded subscription: the sheet must not leave a task waiting forever
    /// after it is dismissed. Polling only runs while the inspector is open and
    /// is stopped explicitly from `onDisappear`.
    private func startObservingDocument() {
        observationTask?.cancel()
        observationTask = Task { [weak self] in
            var lastChange = -1
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(650))
                guard !Task.isCancelled, let self else { return }
                let change = self.document.liveChangeCount
                if change != lastChange {
                    lastChange = change
                    self.refreshLibraries()
                    self.refreshStaleBindings()
                    self.refreshTargetBinding()
                }
            }
        }
    }

    func stopObserving() {
        observationTask?.cancel()
        observationTask = nil
    }

    // MARK: Draft mutation

    /// Every edit updates only the local draft and schedules a bounded
    /// preview. No undo record and no document write happen here.
    func update(_ mutate: (inout CADMaterialDefinition) -> Void) {
        var copy = draft
        mutate(&copy)
        draft = copy.sanitized
        statusMessage = nil
        schedulePreview()
    }

    func setName(_ name: String) {
        update { $0.name = CADMaterialDefinition.sanitizedName(name) }
    }

    func setTexture(slot: MaterialTextureSlot, data: Data, displayName: String?) {
        guard data.count <= CADMaterialLimits.maximumTextureBytes,
              MaterialImageSniffer.mimeType(of: data) != nil else {
            errorMessage = FloeCADStrings.text(
                "cad.material.error.image",
                "Choose a PNG or JPEG image no larger than 8 MB.")
            return
        }
        var texture = CADMaterialTexture(slot: slot, name: displayName, bytes: data)
        if texture.sanitized() == nil {
            errorMessage = FloeCADStrings.text("cad.material.error.image",
                                               "That image could not be read.")
            return
        }
        if slot == .baseColor || slot == .emissive {
            texture.colorSpace = .srgb
        } else {
            texture.colorSpace = .linear
        }
        update { definition in
            definition.textures.removeAll { $0.slot == slot }
            definition.textures.append(texture)
        }
    }

    func removeTexture(slot: MaterialTextureSlot) {
        update { $0.textures.removeAll { $0.slot == slot } }
    }

    func toggleTextureOrientation(slot: MaterialTextureSlot) {
        update { definition in
            guard let index = definition.textures.firstIndex(where: { $0.slot == slot })
            else { return }
            definition.textures[index].orientation =
                definition.textures[index].orientation == .topLeft ? .bottomLeft : .topLeft
        }
    }

    func setTextureColorSpace(slot: MaterialTextureSlot,
                              _ colorSpace: MaterialTextureColorSpace) {
        update { definition in
            guard let index = definition.textures.firstIndex(where: { $0.slot == slot })
            else { return }
            definition.textures[index].colorSpace = colorSpace
        }
    }

    func setMapping(_ mapping: CADMaterialUVMapping) {
        update { $0.uvMapping = mapping }
    }

    // MARK: Selection / library

    func select(_ definition: CADMaterialDefinition, origin: CADMaterialOrigin) {
        let copy = definition.sanitized
        draft = copy
        baseline = copy
        self.origin = origin
        willSaveToPersonal = (origin == .new)
        statusMessage = nil
        errorMessage = nil
        schedulePreview()
    }

    func selectPreset(_ preset: MaterialPreset) {
        var definition = CADMaterialDefinition(spec: preset.spec, name: preset.name)
        definition.uvMapping = .mesh
        select(definition, origin: .preset(preset.name))
    }

    func newMaterial() {
        select(CADMaterialDefinition(
            name: FloeCADStrings.text("cad.material.newName", "New Material")),
               origin: .new)
    }

    func duplicateCurrent() {
        var copy = draft.sanitized
        copy = CADMaterialDefinition(
            id: MaterialID(),
            name: uniqueName(copy.name, in: documentLibrary),
            baseColor: copy.baseColor,
            metallic: copy.metallic,
            roughness: copy.roughness,
            opacity: copy.opacity,
            emissive: copy.emissive,
            emissiveStrength: copy.emissiveStrength,
            textures: copy.textures,
            uvMapping: copy.uvMapping)
        select(copy, origin: .new)
    }

    // MARK: Apply / cancel

    func cancel() {
        previewTask?.cancel()
        draft = baseline
        previewSink?.endMaterialPreview()
        errorMessage = nil
        statusMessage = nil
    }

    func endPreviewOnly() {
        previewTask?.cancel()
        previewSink?.endMaterialPreview()
    }

    /// Persist the draft as a personal library entry without applying it.
    func saveToPersonalLibrary() {
        var definition = draft.sanitized
        if case .document(let id) = origin, definition.id == id {
            definition = CADMaterialDefinition(
                id: MaterialID(), name: definition.name,
                baseColor: definition.baseColor, metallic: definition.metallic,
                roughness: definition.roughness, opacity: definition.opacity,
                emissive: definition.emissive,
                emissiveStrength: definition.emissiveStrength,
                textures: definition.textures, uvMapping: definition.uvMapping)
        }
        definition.name = personalStore.uniqueName(definition.name,
                                                   excluding: definition.id)
        if let failure = personalStore.upsert(definition) {
            errorMessage = failure
            return
        }
        origin = .personal(definition.id)
        draft = definition
        baseline = definition
        willSaveToPersonal = false
        statusMessage = FloeCADStrings.text("cad.material.status.savedPersonal",
                                            "Saved to My Materials.")
    }

    func apply() {
        guard !target.isEmpty else {
            errorMessage = FloeCADStrings.text(
                "cad.material.error.noSelection",
                "Select a body or a face in the viewport first.")
            return
        }
        if let issue = refreshTargetBinding() {
            errorMessage = issue
            return
        }
        guard canApply else {
            if target.needsReselect {
                errorMessage = FloeCADStrings.text(
                    "cad.material.error.reselectFace",
                    "Reselect a single face, then apply the material.")
            }
            return
        }
        isApplying = true
        defer { isApplying = false }
        errorMessage = nil

        let live = document.session.document

        // Resolve the frozen target to current bodies BEFORE any write. A
        // rebuilt face is re-bound by its captured signature only; a missing
        // body in a multi-body selection fails the whole apply instead of
        // silently painting a subset.
        var faceBody: Body?
        var faceKey: CADFaceKey?
        if target.isFaceTarget {
            guard let faceBodyID = target.faceBodyID,
                  let body = live.bodies.first(where: { $0.id.raw == faceBodyID }),
                  let faceIndex = target.faceIndex,
                  let identity = target.faceIdentity,
                  body.meshRevision == identity.meshRevision else {
                let message = FloeCADStrings.text(
                    "cad.material.error.faceRebuilt",
                    "The model changed and that face could no longer be identified. Reselect it in the viewport.")
                errorMessage = message
                targetError = message
                target.faceIndex = nil
                target.note = message
                return
            }
            guard body.brep != nil else {
                errorMessage = FloeCADStrings.text(
                    "cad.material.error.meshFace",
                    "Face materials need an exact solid; use a whole-body material for this mesh.")
                return
            }
            let candidates = CADFaceMaterialResolver.candidates(for: body)
            let expectedSignature = identity.resolvedSignature ?? identity.signature
            guard let signature = candidates.first(where: { $0.index == faceIndex })?.signature,
                  CADMaterialTargetResolver.signaturesMatch(signature,
                                                            expectedSignature) else {
                let message = FloeCADStrings.text(
                    "cad.material.error.faceRebuilt",
                    "The model changed and that face could no longer be identified. Reselect it in the viewport.")
                errorMessage = message
                targetError = message
                return
            }
            let key = CADFaceKey(signature: signature, capturedIndex: faceIndex)
            if case .ambiguous(let indices) = CADFaceMaterialResolver.match(
                key, candidates: candidates) {
                errorMessage = FloeCADStrings.format(
                    "cad.material.error.ambiguous",
                    "That face is not unique (%d candidates). Reselect a distinct face.",
                    indices.count)
                return
            }
            faceBody = body
            faceKey = key
        } else {
            var missingNames: [String] = []
            for (offset, raw) in target.bodyIDs.enumerated() {
                guard !live.bodies.contains(where: { $0.id.raw == raw }) else {
                    continue
                }
                missingNames.append(offset < target.bodyNames.count
                                    ? target.bodyNames[offset] : raw.uuidString)
            }
            guard missingNames.isEmpty else {
                let message = FloeCADStrings.format(
                    "cad.material.error.targetMissing",
                    "Some selected bodies are no longer in this document: %@. Reselect them.",
                    missingNames.joined(separator: ", "))
                errorMessage = message
                targetError = message
                target.note = message
                return
            }
        }

        // Merge the live library, not the snapshot taken when the sheet
        // opened. An entry added/changed by another editor is preserved; a
        // concurrent change to the same entry makes this draft a new entry
        // instead of clobbering the other one.
        let liveLibrary = CADMaterialLibraryCodec.decode(live.materialLibraryData)
        var definition = draft.sanitized
        var updatingID: MaterialID?
        if let existingID = origin.documentID,
           let liveEntry = liveLibrary.entry(existingID) {
            // `baseline.revision` is the version this draft was based on.
            // Polling may have refreshed `documentLibrary` already, so it is
            // not a valid conflict witness; comparing the live entry to the
            // draft's baseline preserves a concurrent edit to the same entry
            // by saving this draft as a new entry instead of clobbering it.
            if baseline.revision == liveEntry.revision {
                definition.id = existingID
                definition.revision = max(liveEntry.revision, definition.revision) + 1
                updatingID = existingID
            } else {
                definition.id = MaterialID()
                definition.revision = 1
            }
        } else {
            definition.id = MaterialID()
            definition.revision = 1
        }
        definition.name = uniqueName(definition.name, in: liveLibrary,
                                     excluding: updatingID)
        definition.updatedAt = Date()
        let spec = definition.bodyMaterialSpec()

        // Build the ONE undoable composite: library copy + applied snapshot.
        var library = liveLibrary
        library.upsert(definition)
        guard library.entry(definition.id) != nil else {
            errorMessage = FloeCADStrings.text(
                "cad.material.error.library",
                "The material library could not be saved within its size limit.")
            return
        }
        guard let encodedLibrary = CADMaterialLibraryCodec.encode(library) else {
            errorMessage = FloeCADStrings.text(
                "cad.material.error.library",
                "The material library could not be saved within its size limit.")
            return
        }

        var snapshots: [BodyID: SetMaterialAppearanceCommand.Snapshot] = [:]
        if target.isFaceTarget {
            guard let faceBody, let faceKey, let faceIndex = target.faceIndex else {
                let message = FloeCADStrings.text(
                    "cad.material.error.faceRebuilt",
                    "The model changed and that face could no longer be identified. Reselect it in the viewport.")
                errorMessage = message
                targetError = message
                target.faceIndex = nil
                target.note = message
                return
            }
            let candidates = CADFaceMaterialResolver.candidates(for: faceBody)
            var bindings = faceBody.materialFaceBindings.filter { binding in
                if case .resolved(let index, _) = CADFaceMaterialResolver.match(
                    binding.key, candidates: candidates) {
                    return index != faceIndex
                }
                return true
            }
            bindings.append(CADFaceMaterialBinding(key: faceKey, material: spec))
            snapshots[faceBody.id] = SetMaterialAppearanceCommand.Snapshot(
                material: faceBody.material, faceBindings: bindings)
        } else {
            for raw in target.bodyIDs {
                guard let body = live.bodies.first(where: { $0.id.raw == raw }) else {
                    continue
                }
                snapshots[body.id] = SetMaterialAppearanceCommand.Snapshot(
                    material: spec, faceBindings: [])
            }
            guard snapshots.count == target.bodyIDs.count else {
                let message = FloeCADStrings.text(
                    "cad.material.error.vanished",
                    "The selected bodies are no longer in this document.")
                errorMessage = message
                targetError = message
                target.note = message
                return
            }
        }
        guard !snapshots.isEmpty else {
            errorMessage = FloeCADStrings.text(
                "cad.material.error.vanished",
                "The selected bodies are no longer in this document.")
            return
        }

        let appearance = SetMaterialAppearanceCommand(
            title: "Apply Material",
            bodyIDs: Set(snapshots.keys),
            after: snapshots,
            document: live)
        var commands: [DocumentCommand] = []
        let beforeLibrary = live.materialLibraryData
        if beforeLibrary != encodedLibrary {
            commands.append(SetMaterialLibraryDataCommand(
                before: beforeLibrary, after: encodedLibrary))
        }
        commands.append(appearance)
        document.session.perform(CompositeCommand(title: "Apply Material",
                                                  commands: commands))

        documentLibrary = library
        baseline = definition
        draft = definition
        origin = .document(definition.id)
        targetError = nil
        let shouldCopyToPersonal = willSaveToPersonal
        willSaveToPersonal = false
        if shouldCopyToPersonal {
            var personal = definition
            personal.id = MaterialID()
            personal.name = personalStore.uniqueName(personal.name,
                                                     excluding: personal.id)
            if let failure = personalStore.upsert(personal) {
                // The document change succeeded; report the personal-store
                // failure separately without undoing the applied material.
                errorMessage = failure
            }
        }
        previewTask?.cancel()
        previewSink?.endMaterialPreview()
        statusMessage = FloeCADStrings.text("cad.material.status.applied",
                                           "Material applied. Undo restores the previous look.")
        refreshStaleBindings()
        onApplied?()
    }

    // MARK: Library entries

    /// Rename a document library entry as one undoable change. Applied body
    /// snapshots keep their own captured name and appearance.
    @discardableResult
    func renameDocumentEntry(_ id: MaterialID, to rawName: String) -> String? {
        let name = CADMaterialDefinition.sanitizedName(rawName)
        // Start from the LIVE library: another editor may have added entries
        // since this sheet opened, and a rename must not write them away.
        let live = document.session.document
        var library = CADMaterialLibraryCodec.decode(live.materialLibraryData)
        guard var entry = library.entry(id) else {
            return FloeCADStrings.text("cad.material.error.libraryEntryGone",
                                       "That material is no longer in this document.")
        }
        guard library.entry(named: name) == nil || library.entry(named: name)?.id == id else {
            return FloeCADStrings.text("cad.material.error.duplicateName",
                                       "Another material already uses that name.")
        }
        entry.name = name
        entry.revision += 1
        entry.updatedAt = Date()
        library.upsert(entry)
        guard let encoded = CADMaterialLibraryCodec.encode(library) else {
            return FloeCADStrings.text("cad.material.error.library",
                                       "The material library could not be saved.")
        }
        let before = live.materialLibraryData
        if before != encoded {
            document.session.perform(SetMaterialLibraryDataCommand(before: before,
                                                                   after: encoded))
        }
        documentLibrary = library
        if case .document(let current) = origin, current == id {
            draft.name = name
            baseline.name = name
            // This rename is our own library write: acknowledge its revision
            // so a later Apply updates the same entry instead of treating our
            // own rename as a concurrent conflict.
            draft.revision = entry.revision
            baseline.revision = entry.revision
        }
        return nil
    }

    /// Delete only the document library entry. Applied appearances are
    /// independent snapshots and are reported, not modified.
    func deleteDocumentEntry(_ id: MaterialID) -> (error: String?, references: Int) {
        // Delete from the LIVE library for the same reason as rename: keep
        // entries added by another editor.
        let live = document.session.document
        var library = CADMaterialLibraryCodec.decode(live.materialLibraryData)
        guard library.remove(id) != nil,
              let encoded = CADMaterialLibraryCodec.encode(library) else {
            return (FloeCADStrings.text("cad.material.error.libraryEntryGone",
                                        "That material is no longer in this document."), 0)
        }
        let references = appliedReferenceCount(id)
        let before = live.materialLibraryData
        if before != encoded {
            document.session.perform(SetMaterialLibraryDataCommand(before: before,
                                                                   after: encoded))
        }
        documentLibrary = library
        if case .document(let current) = origin, current == id {
            origin = .new
            willSaveToPersonal = false
        }
        return (nil, references)
    }

    func deletePersonalEntry(_ id: MaterialID) -> String? {
        let failure = personalStore.remove(id)
        if case .personal(let current) = origin, current == id {
            origin = .new
            willSaveToPersonal = false
        }
        return failure
    }

    func appliedReferenceCount(_ id: MaterialID) -> Int {
        var count = 0
        for body in document.session.document.bodies {
            if body.material?.materialID == id.raw.uuidString { count += 1 }
            count += body.materialFaceBindings.filter {
                $0.material.materialID == id.raw.uuidString
            }.count
        }
        return count
    }

    func importPersonalPack(from url: URL) -> String? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            return FloeCADStrings.text("cad.material.error.readPack",
                                       "That material pack could not be read.")
        }
        let failure = personalStore.importLibrary(data: data)
        if failure == nil { refreshLibraries() }
        return failure
    }

    func exportPersonalPackData() -> Data? {
        personalStore.exportLibraryData()
    }

    // MARK: Preview

    private func schedulePreview() {
        guard !target.isEmpty, !target.needsReselect else {
            previewSink?.endMaterialPreview()
            return
        }
        previewTask?.cancel()
        let spec = draft.bodyMaterialSpec()
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled, let self else { return }
            // Fence the transient preview against a stale face mapping: do
            // not paint a draft from an older mesh generation onto whichever
            // face now carries the old index.
            guard self.refreshTargetBinding() == nil else {
                self.previewSink?.endMaterialPreview()
                return
            }
            self.previewSink?.previewMaterial(spec, for: self.target)
        }
    }

    // MARK: Stale bindings

    /// Drop only the face bindings that no longer resolve. The saved snapshot
    /// is unchanged for every face that still resolves; one undo step.
    func removeStaleFaceBindings() {
        let live = document.session.document
        var snapshots: [BodyID: SetMaterialAppearanceCommand.Snapshot] = [:]
        for raw in target.bodyIDs {
            guard let body = live.bodies.first(where: { $0.id.raw == raw }),
                  !body.materialFaceBindings.isEmpty else { continue }
            let kept = CADFaceMaterialResolver.resolve(body.materialFaceBindings,
                                                       in: body)
                .filter { $0.resolvedIndex != nil }
                .map(\.binding)
            guard kept.count != body.materialFaceBindings.count else { continue }
            snapshots[body.id] = SetMaterialAppearanceCommand.Snapshot(
                material: body.material, faceBindings: kept)
        }
        guard !snapshots.isEmpty else {
            refreshStaleBindings()
            return
        }
        document.session.perform(SetMaterialAppearanceCommand(
            title: "Remove Stale Face Materials",
            bodyIDs: Set(snapshots.keys),
            after: snapshots,
            document: live))
        refreshStaleBindings()
        statusMessage = FloeCADStrings.text(
            "cad.material.stale.removed",
            "Stale face assignments were removed. Undo restores them.")
    }

    // MARK: External messages

    func setExternalError(_ message: String) {
        errorMessage = message
        statusMessage = nil
    }

    func setExternalNote(_ message: String) {
        statusMessage = message
        errorMessage = nil
    }

    // MARK: Names

    private func uniqueName(_ raw: String, in library: CADMaterialLibrary,
                            excluding: MaterialID? = nil) -> String {
        let base = CADMaterialDefinition.sanitizedName(raw)
        let used = Set(library.entries.filter { $0.id != excluding }
            .map { $0.name.lowercased() })
        guard used.contains(base.lowercased()) else { return base }
        for index in 2...999 {
            let candidate = "\(base) \(index)"
            if !used.contains(candidate.lowercased()) { return candidate }
        }
        return base
    }
}

// MARK: - Origin helpers

nonisolated extension CADMaterialOrigin {
    var isDocument: Bool {
        if case .document = self { return true }
        return false
    }

    var documentID: MaterialID? {
        if case .document(let id) = self { return id }
        return nil
    }
}
#endif
