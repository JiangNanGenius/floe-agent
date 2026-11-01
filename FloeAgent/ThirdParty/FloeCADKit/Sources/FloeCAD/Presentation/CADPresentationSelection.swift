// Present selection is an adapter over the live editor, never a second
// selection or geometry store. Numeric face labels are display-only here.
#if canImport(SwiftUI) && canImport(RealityKit) && canImport(UIKit)
import Foundation
import RealityKit
import UIKit
import simd

nonisolated struct CADPresentationPick: Equatable, Sendable {
    var entityID: UUID
    var bodyID: UUID
    var instanceID: UUID?
    var meshRevision: UInt64
    var triangles: [Int]
}

nonisolated struct CADPresentationSelectionStamp: Equatable, Sendable {
    var documentKey: String
    var documentRevision: Int
    var changeCount: Int
    var buildKey: String
    var renderGeneration: UInt64
    var interactionGeneration: UInt64
}

nonisolated struct CADPresentationSelectionState: Equatable, Sendable {
    var bodyIDs: Set<UUID>
    var instanceIDs: Set<UUID>
    var faces: [CADSelectionContext.FaceTrianglePick]
}

/// Cheap input identity for host notification. Geometry is measured only
/// when this value changes, never on every RealityKit/SwiftUI render tick.
nonisolated struct CADPresentationSelectionObservationKey: Equatable, Sendable {
    var documentIdentity: ObjectIdentifier
    var documentRevision: Int
    var changeCount: Int
    var editorKey: String
    var bodyIDs: Set<UUID>
    var facePicks: [CADSelectionContext.FaceTrianglePick]
    var edgePicks: [CADSelectionContext.EdgeSegmentPick]
    var sketchID: SketchID?
    var sketchEntityIDs: Set<UUID>
    var instanceIDs: Set<UUID>
}

@MainActor
enum CADPresentationSelection {
    static func observationKey(document: FloeCADDocument) -> CADPresentationSelectionObservationKey {
        let model = document.viewModel()
        let inputs = model.assistantSelectionInputs
        return CADPresentationSelectionObservationKey(
            documentIdentity: ObjectIdentifier(document), documentRevision: document.revision,
            changeCount: document.liveChangeCount, editorKey: model.assistantSelectionKey,
            bodyIDs: Set(inputs.bodyIDs.map(\.raw)), facePicks: inputs.facePicks,
            edgePicks: inputs.edgePicks, sketchID: inputs.sketchID,
            sketchEntityIDs: inputs.sketchEntityIDs, instanceIDs: inputs.instanceIDs)
    }

    static func state(document: FloeCADDocument) -> CADPresentationSelectionState {
        let inputs = document.viewModel().assistantSelectionInputs
        return CADPresentationSelectionState(bodyIDs: Set(inputs.bodyIDs.map(\.raw)),
                                             instanceIDs: inputs.instanceIDs, faces: inputs.facePicks)
    }

    /// The label the Present overlay and accessibility tree expose. It is the
    /// same live title the material inspector resolves from the current
    /// editor mode, so a body, a face and a placed instance stay distinct
    /// without a second selection cache.
    static func title(document: FloeCADDocument) -> String? {
        let model = document.viewModel()
        let inputs = model.assistantSelectionInputs
        if !inputs.instanceIDs.isEmpty,
           let assembly = try? CADAssembly.decode(from: document.session.document.assemblyData) {
            let names = inputs.instanceIDs
                .sorted { $0.uuidString < $1.uuidString }
                .compactMap { assembly.instance($0)?.name }
            if !names.isEmpty {
                return names.prefix(3).joined(separator: ", ")
            }
        }
        let target = CADMaterialTargetResolver.resolve(viewModel: model)
        return target.isEmpty ? nil : target.title
    }

    /// Body-local point in the live `RenderMesh` millimetre space for a
    /// RealityKit world-space collision. The stage carries the camera view
    /// transform; the body transform carries the entity's own placement and
    /// scale. This is the same conversion the scene builder used in reverse.
    nonisolated static func localPointMillimetres(
        worldPoint: SIMD3<Float>,
        bodyTransform: simd_float4x4,
        stageTransform: simd_float4x4
    ) -> SIMD3<Float> {
        let local = simd_inverse(stageTransform * bodyTransform)
            * SIMD4<Float>(worldPoint, 1)
        return SIMD3<Float>(local.x, local.y, local.z)
            * CADPresentationAxes.millimetresPerMeter
    }

    /// Correlate the snapshot's exact ordered index triples with the live
    /// render triangle numbering. Duplicate/overlapping ranges are ambiguous;
    /// callers then select the body, never invent a kernel face index.
    nonisolated private struct TriangleKey: Hashable {
        var a: UInt32; var b: UInt32; var c: UInt32
        init(_ indices: [UInt32], _ start: Int) {
            a = indices[start]; b = indices[start + 1]; c = indices[start + 2]
        }
    }

    nonisolated static func triangleGroups(in body: CADPresentationBody) -> [Int: [Int]] {
        var lookup: [TriangleKey: Int] = [:]
        for triangle in 0..<body.mesh.triangleCount {
            if triangle % 4096 == 0, Task.isCancelled { return [:] }
            let key = TriangleKey(body.mesh.indices, triangle * 3)
            lookup[key] = lookup[key] == nil ? triangle : -1
        }
        var result: [Int: [Int]] = [:]
        var owner: [Int: Int] = [:]
        var invalid = Set<Int>()
        for group in body.faceGroups {
            if result[group.faceIndex] != nil { invalid.insert(group.faceIndex) }
            guard !group.indices.isEmpty, group.indices.count % 3 == 0 else {
                invalid.insert(group.faceIndex); continue
            }
            var triangles = Set<Int>()
            for start in stride(from: 0, to: group.indices.count, by: 3) {
                if start % 12288 == 0, Task.isCancelled { return [:] }
                guard let triangle = lookup[TriangleKey(group.indices, start)], triangle >= 0,
                      triangles.insert(triangle).inserted else { invalid.insert(group.faceIndex); continue }
                if let previous = owner[triangle], previous != group.faceIndex {
                    invalid.insert(previous); invalid.insert(group.faceIndex)
                }
                owner[triangle] = group.faceIndex
            }
            result[group.faceIndex] = triangles.sorted()
        }
        for face in invalid { result.removeValue(forKey: face) }
        return result
    }

    nonisolated static func triangles(for group: CADPresentationFaceGroup, in body: CADPresentationBody) -> [Int]? {
        triangleGroups(in: body)[group.faceIndex]
    }

    nonisolated static func pick(for body: CADPresentationBody, group: CADPresentationFaceGroup? = nil,
                                triangleGroups: [Int: [Int]]? = nil) -> CADPresentationPick {
        let triangles = group.flatMap { (triangleGroups ?? self.triangleGroups(in: body))[$0.faceIndex] } ?? []
        return CADPresentationPick(entityID: body.id, bodyID: body.sourceBodyID ?? body.id,
            instanceID: body.sourceBodyID == nil ? nil : body.id,
            meshRevision: body.mesh.meshRevision,
            // A placed face requires an instance-face selection model to carry
            // its placement. For now a placed group selects the instance.
            triangles: body.sourceBodyID == nil ? triangles : [])
    }

    @discardableResult
    static func apply(_ pick: CADPresentationPick?, stamp: CADPresentationSelectionStamp,
                      currentStamp: CADPresentationSelectionStamp?, scene: CADPresentationScene,
                      document: FloeCADDocument) -> Bool {
        guard stamp == currentStamp, stamp.documentKey == document.url.standardizedFileURL.path,
              stamp.documentRevision == document.revision, stamp.changeCount == document.liveChangeCount,
              stamp.buildKey == scene.buildKey, scene.documentKey == stamp.documentKey else { return false }
        if let pick {
            guard let drawn = scene.bodies.first(where: { $0.id == pick.entityID }),
                  drawn.sourceBodyID == (pick.instanceID == nil ? nil : pick.bodyID),
                  drawn.mesh.meshRevision == pick.meshRevision,
                  let body = document.session.document.body(with: BodyID(raw: pick.bodyID)),
                  body.meshRevision == pick.meshRevision else { return false }
            if let instanceID = pick.instanceID {
                guard instanceID == drawn.id,
                      let assembly = try? CADAssembly.decode(from: document.session.document.assemblyData),
                      let live = assembly.instance(instanceID), !live.isHidden, !live.isSubassembly,
                      (live.copiedBodyID ?? live.bodyID) == pick.bodyID else { return false }
            } else {
                guard drawn.id == pick.bodyID, !body.isHidden,
                      pick.triangles.allSatisfy({ $0 >= 0 && $0 < body.render.triangleCount }) else { return false }
            }
            return document.viewModel().selectPresentation(bodyID: BodyID(raw: pick.bodyID),
                instanceID: pick.instanceID, faceTriangles: pick.triangles)
        }
        return document.viewModel().selectPresentation(bodyID: nil)
    }

    /// Refine a real collision hit on an unpainted body entity into the live
    /// face triangles. The heavy buffer/topology scan runs as one cancellable
    /// detached value task; the document is only read before and revalidated
    /// after it, never mutated. Nil is a truthful "select the body" fallback:
    /// placed occurrences, stale generations, empty hits and exact ambiguous
    /// edges do not invent a face or a numerical face index.
    static func refinedFacePick(
        _ pick: CADPresentationPick,
        localPointMillimetres: SIMD3<Float>,
        presentationBody: CADPresentationBody,
        scene: CADPresentationScene,
        document: FloeCADDocument
    ) async -> CADPresentationPick? {
        guard pick.instanceID == nil,
              presentationBody.id == pick.entityID,
              presentationBody.id == pick.bodyID,
              presentationBody.sourceBodyID == nil,
              localPointMillimetres.x.isFinite,
              localPointMillimetres.y.isFinite,
              localPointMillimetres.z.isFinite else { return nil }

        let documentKey = document.url.standardizedFileURL.path
        let revision = document.revision
        let changeCount = document.liveChangeCount
        guard documentKey == scene.documentKey,
              revision == scene.documentRevision,
              changeCount == scene.changeCount,
              scene.bodies.contains(where: {
                  $0.id == pick.entityID && $0.sourceBodyID == nil
              }),
              let liveBody = document.session.document.body(with: BodyID(raw: pick.bodyID)),
              liveBody.meshRevision == pick.meshRevision,
              presentationBody.mesh.meshRevision == pick.meshRevision else {
            return nil
        }

        let liveMesh = liveBody.render
        let meshRevision = liveBody.meshRevision
        let faceTable = document.session.lastFaceTables[liveBody.id]
        let faceTableRevision = document.session.lastNamingRevisions[liveBody.id]
        let diagonalMM = simd_length(
            presentationBody.mesh.boundsMax - presentationBody.mesh.boundsMin)
            * CADPresentationAxes.millimetresPerMeter
        let tolerance = CADPresentationFaceHit.tolerance(diagonalMM: diagonalMM)

        let work = Task.detached(priority: .userInitiated) {
            CADPresentationFaceHit.resolve(
                mesh: liveMesh, meshRevision: meshRevision,
                point: localPointMillimetres, tolerance: tolerance,
                faceTable: faceTable, faceTableRevision: faceTableRevision)
        }
        let region = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        guard !Task.isCancelled, let region, !region.triangles.isEmpty else { return nil }

        // A late hit may not publish against an edit, save identity or mesh
        // generation that moved while the detached scan was running. The
        // caller additionally checks its tap stamp before applying.
        guard document.url.standardizedFileURL.path == documentKey,
              document.revision == revision,
              document.liveChangeCount == changeCount,
              let current = document.session.document.body(with: BodyID(raw: pick.bodyID)),
              current.meshRevision == pick.meshRevision,
              region.triangles.allSatisfy({
                  $0 >= 0 && $0 < current.render.triangleCount
              }) else { return nil }

        var refined = pick
        refined.triangles = region.triangles
        return refined
    }

    /// The instance remains selected as an instance. A material edits its
    /// effective shared/independent definition, matching assembly rendering.
    static func materialTarget(document: FloeCADDocument) -> CADMaterialTarget {
        let model = document.viewModel()
        guard !model.selectedAssemblyInstances.isEmpty,
              let assembly = try? CADAssembly.decode(from: document.session.document.assemblyData) else {
            return CADMaterialTargetResolver.resolve(viewModel: model)
        }
        let allOccurrences = assembly.occurrences(includeHidden: true)
        let instances = allOccurrences.filter { occurrence in
            guard occurrence.isDrawablePart, occurrence.isVisible else { return false }
            return occurrence.path.contains(where: { model.selectedAssemblyInstances.contains($0) })
        }
        let sourceIDs = Set(instances.compactMap { $0.effectiveBodyID })
        let bodies = document.session.document.bodies.filter { sourceIDs.contains($0.id.raw) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        // A shared placement edits its source definition even when it is the
        // only current occurrence. Keep that scope visible; an independent
        // copy owns a separate definition and needs no shared-material note.
        let shared = instances.contains { !$0.instance.isIndependentCopy }
        return CADMaterialTarget(bodyIDs: bodies.map(\.id.raw), faceBodyID: nil, faceIndex: nil,
            bodyNames: bodies.map(\.name), isFaceTarget: false,
            note: shared ? FloeCADStrings.text("cad.present.selection.sharedMaterial", "Shared material — changes apply to all instances of this part.") : nil,
            faceIdentity: nil, bodyMeshRevisions: Dictionary(uniqueKeysWithValues: bodies.map { ($0.id.raw, $0.meshRevision) }))
    }
}

/// One build's object-identity index. Names are only labels; hit routing uses
/// these actual entity objects and the controller's scene-generation stamp.
@MainActor
final class CADPresentationPickIndex {
    private(set) var targets: [ObjectIdentifier: CADPresentationPick] = [:]
    private var shapes: [ObjectIdentifier: ShapeResource] = [:]

    func register(_ entity: ModelEntity, mesh: MeshResource, pick: CADPresentationPick) async throws {
        let key = ObjectIdentifier(mesh)
        let shape: ShapeResource
        if let cached = shapes[key] { shape = cached }
        else {
            // Preserve holes and concavities; a convex hull would select empty
            // space through a bore. No physics body or alternate engine.
            shape = try await ShapeResource.generateStaticMesh(from: mesh)
            try Task.checkCancellation()
            shapes[key] = shape
        }
        entity.components.set(CollisionComponent(shapes: [shape]))
        targets[ObjectIdentifier(entity)] = pick
    }
}
#endif
