// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreFoundation

/// The existing mesh router, proposal classifier, session undo and package
/// writer remain the only UI/AI authority. Workers receive value snapshots;
/// their result cannot commit into another model epoch or a closed document.
@MainActor
final class CADVoxelRemeshService {
    nonisolated static let actions = ["voxel.catalog","voxel.remesh","voxel.update","voxel.inspect"]
    nonisolated static let mutations: Set<String> = ["voxel.remesh","voxel.update"]
    private static var active: [ObjectIdentifier: CADMeshCancellation] = [:]
    private static var activeActions: [ObjectIdentifier: String] = [:]
    nonisolated(unsafe) static var testComputeProbe: (@Sendable () -> Void)?
    nonisolated(unsafe) static var testBeforeCommitProbe: (@Sendable () -> Void)?
    static func cancelActiveOperation(for document: FloeCADDocument) -> Bool {
        guard let token = active[ObjectIdentifier(document)] else { return false }; token.cancel(); return true
    }
    static func activeOperationStatus(for document: FloeCADDocument) -> [String: Any]? {
        let owner = ObjectIdentifier(document)
        guard let token = active[owner] else { return nil }
        return ["ok":true,"active":true,"action":activeActions[owner] ?? "voxel.remesh","cancelRequested":token.isCancelled,"mutated":false]
    }
    private let document: FloeCADDocument
    init(document: FloeCADDocument) { self.document = document }
    private nonisolated struct Plan: Sendable {
        let action: String
        let node: FeatureNode
        let bodyID: BodyID
        let definition: CADVoxelRemeshDefinition
        let placement: Transform3D
        let creating: Bool
        let original: CADVoxelRemeshDefinition?
        let existingRender: RenderMesh?
        let watchedBodyID: BodyID
        let watchedRevision: UInt64
        let changeCount: Int
    }
    func handle(action: String,args: [String: Any]) -> [String: Any] {
        if action == "voxel.catalog" { return Self.catalog() }
        do {
            let plan = try prepare(action,args), token = CADMeshCancellation()
            if Task.isCancelled { token.cancel() }
            return try finish(plan,try Self.compute(plan,token),args:args,token:token)
        } catch { return Self.failure(error) }
    }
    func handleAsync(action: String,args: [String: Any]) async -> [String: Any] {
        if action == "voxel.catalog" { return Self.catalog() }
        do {
            let plan = try prepare(action,args), token = CADMeshCancellation(), owner = ObjectIdentifier(document)
            if Task.isCancelled { token.cancel() }
            _ = CADMeshService.cancelActiveOperation(for:document)
            Self.active[owner] = token; Self.activeActions[owner] = action
            defer { if Self.active[owner] === token { Self.active[owner] = nil; Self.activeActions[owner] = nil } }
            let probe = Self.testComputeProbe, after = Self.testBeforeCommitProbe
            let worker = Task.detached(priority:.userInitiated) { () -> Result<CADVoxelRemeshKernel.Evaluation,CADVoxelFailure> in
                probe?()
                do { let value = try Self.compute(plan,token); after?(); return .success(value) }
                catch let error as CADVoxelFailure { return .failure(error) }
                catch { return .failure(.invalid(error.localizedDescription)) }
            }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { token.cancel(); worker.cancel() }
            return try finish(plan,result.get(),args:args,token:token)
        } catch { return Self.failure(error) }
    }
    private func prepare(_ action: String,_ args: [String: Any]) throws -> Plan {
        guard !document.isClosed else { throw CADVoxelFailure.invalid("The document is closed.") }
        if Self.mutations.contains(action), let block = document.session.writeBlock { throw CADVoxelFailure.invalid(block.message) }
        let session = document.session
        if let raw = args["preview"] {
            guard let value = raw as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { throw CADVoxelFailure.invalid("preview must be a boolean.") }
        }
        if args["expectedPreviewHash"] != nil {
            guard let value = args["expectedPreviewHash"] as? String, !value.isEmpty else { throw CADVoxelFailure.invalid("The expected preview hash must be a nonempty string.") }
        }
        if args["expectedChangeCount"] != nil, try Self.number(args,"expectedChangeCount") != Double(session.changeCount) {
            throw CADVoxelFailure.invalid("The document changed after preview. Preview again before applying.")
        }
        if args["expectedRevision"] != nil, try Self.number(args,"expectedRevision") != Double(document.store.revision) {
            throw CADVoxelFailure.invalid("The saved document changed after preview. Preview again before applying.")
        }
        if let algorithm = args["algorithm"], algorithm as? String != CADVoxelRemeshDefinition.algorithmV1 {
            throw CADVoxelFailure.unsupported("Only the bounded cubical reconstruction algorithm is available.")
        }
        let requested = BodyID(raw:try Self.uuid(args,"bodyID"))
        guard let body = session.document.body(with:requested) else { throw CADVoxelFailure.invalid("Select an existing scan or reconstruction body.") }
        let definition: CADVoxelRemeshDefinition, node: FeatureNode, placement: Transform3D
        let original: CADVoxelRemeshDefinition?, existing: RenderMesh?, creating: Bool, output: BodyID
        switch action {
        case "voxel.remesh":
            guard body.brep == nil, body.surfaceBRep == nil else { throw CADVoxelFailure.unsupported("Voxel reconstruction accepts scan meshes. Convert an exact body through an explicit mesh workflow first.") }
            let size = try Self.number(args,"voxelSize",fallback:1)
            definition = .init(sourceBodyID:body.id,source:.init(body.render),voxelSizeMM:size,
                               maxDeviationMM:try Self.number(args,"maxDeviation",fallback:4*size))
            placement = body.transform; output = BodyID(); creating = true; original = nil; existing = nil
            node = FeatureNode(name:FloeCADStrings.text("cad.mesh.voxel.title","Voxel reconstruction"),
                kind:.voxelRemesh(definition:definition,placement:placement),outputBodyIDs:[output])
        case "voxel.update","voxel.inspect":
            let graph = session.document.features
            let applied = graph.nodes.prefix(max(0,min(graph.rollbackIndex ?? graph.nodes.count,graph.nodes.count)))
            let writer = session.lastBodyWriters[requested]
            let candidate = writer.flatMap { id in applied.last { $0.id == id && !$0.suppressed } }
                ?? applied.last { !$0.suppressed && $0.outputBodyIDs.contains(requested) }
            guard let owner = candidate, case let .voxelRemesh(stored,storedPlacement) = owner.kind,
                  owner.outputBodyIDs == [requested], body.brep == nil, body.surfaceBRep == nil,
                  body.transform == storedPlacement else {
                throw CADVoxelFailure.unsupported("Select the latest unchanged voxel reconstruction. Direct edits cannot be overwritten by its stored scan.")
            }
            if action == "voxel.update", args["definitionDigest"] as? String != stored.digest { throw CADVoxelFailure.invalid("The reconstruction changed. Inspect it again before updating.") }
            var changed = stored
            if action == "voxel.update" {
                changed.voxelSizeMM = try Self.number(args,"voxelSize",fallback:stored.voxelSizeMM)
                changed.maxDeviationMM = try Self.number(args,"maxDeviation",fallback:stored.maxDeviationMM)
                guard changed != stored else { throw CADVoxelFailure.invalid("The reconstruction parameters did not change.") }
            }
            definition = changed; node = owner; placement = storedPlacement; output = requested
            original = stored; existing = body.render; creating = false
        default: throw CADVoxelFailure.invalid("Unknown voxel reconstruction action.")
        }
        try CADPolygonMeshDefinition.validatePlacement(placement)
        // Full scan validation is deliberately performed by the worker.
        return Plan(action:action,node:node,bodyID:output,definition:definition,placement:placement,creating:creating,
            original:original,existingRender:existing,watchedBodyID:requested,watchedRevision:body.meshRevision,changeCount:session.changeCount)
    }
    private nonisolated static func compute(_ plan: Plan,_ token: CADMeshCancellation) throws -> CADVoxelRemeshKernel.Evaluation {
        let clock = EvaluationDeadlineClock(seconds:60)
        let stop: @Sendable () -> Bool = { token.kernelIsCancelled() || Task.isCancelled || clock.isExpired() }
        do {
            if let original = plan.original, let expected = plan.existingRender {
                let current = try CADVoxelRemeshKernel.evaluate(original,scale:plan.placement.scale,cancelled:stop)
                guard current.render == expected else { throw CADVoxelFailure.unsupported("The output mesh was edited after reconstruction. Its stored scan cannot overwrite those edits.") }
            }
            let result = try CADVoxelRemeshKernel.evaluate(plan.definition,scale:plan.placement.scale,cancelled:stop)
            if token.isCancelled || Task.isCancelled { throw CADVoxelFailure.cancelled }
            if clock.isExpired() { throw CADVoxelFailure.timedOut }
            return result
        } catch {
            if token.isCancelled || Task.isCancelled { throw CADVoxelFailure.cancelled }
            if clock.isExpired() { throw CADVoxelFailure.timedOut }
            throw error
        }
    }
    private func fence(_ plan: Plan,_ token: CADMeshCancellation) throws {
        guard !token.isCancelled, !Task.isCancelled else { throw CADVoxelFailure.cancelled }
        guard !document.isClosed, document.session.changeCount == plan.changeCount,
              document.session.document.body(with:plan.watchedBodyID)?.meshRevision == plan.watchedRevision else {
            throw CADVoxelFailure.invalid("The document changed during reconstruction. The worker result was discarded.")
        }
        if Self.mutations.contains(plan.action), let block = document.session.writeBlock { throw CADVoxelFailure.invalid(block.message) }
    }
    private func finish(_ plan: Plan,_ value: CADVoxelRemeshKernel.Evaluation,args: [String: Any],token: CADMeshCancellation) throws -> [String: Any] {
        try fence(plan,token)
        guard let hash = CADTransientMeshPreview.hash(of:[value.render]) else { throw CADVoxelFailure.invalid("The reconstructed mesh is invalid.") }
        var reply = value.payload
        reply.merge(["ok":true,"mutated":false,"action":plan.action,"bodyID":plan.bodyID.raw.uuidString,
            "sourceBodyID":plan.definition.sourceBodyID.raw.uuidString,
            "sourceBodyPresent":document.session.document.body(with:plan.definition.sourceBodyID) != nil,
            "featureID":plan.node.id.raw.uuidString,
            "definitionDigest":plan.definition.digest,"voxelSizeMM":plan.definition.voxelSizeMM,
            "maxDeviationMM":plan.definition.maxDeviationMM,"algorithm":plan.definition.algorithm]) { _,new in new }
        if plan.action == "voxel.inspect" { return reply }
        if let expected = args["expectedPreviewHash"] as? String {
            guard expected == hash,
                  try Self.number(args,"expectedChangeCount") == Double(plan.changeCount),
                  try Self.number(args,"expectedRevision") == Double(document.store.revision) else {
                throw CADVoxelFailure.invalid("The preview is stale. Preview this reconstruction again.")
            }
        }
        if args["preview"] as? Bool == true {
            guard let snapshot = CADTransientMeshPreview.snapshot(of:[value.render]) else { throw CADVoxelFailure.invalid("The reconstruction preview is empty.") }
            reply.merge(["preview":true,"previewHash":hash,"previewRevision":document.store.revision,
                "previewChangeCount":plan.changeCount,"mesh":CADTransientMeshPreview.payload(snapshot)]) { _,new in new }
            if plan.creating {
                // A transient preview reserves no author or document identity.
                reply.removeValue(forKey:"bodyID"); reply.removeValue(forKey:"featureID"); reply.removeValue(forKey:"definitionDigest")
            }
            return reply
        }
        try fence(plan,token)
        let session = document.session, checkpoint = document.captureEditCheckpoint(), before = session.lastEvalErrors
        let retainedSource = session.document.body(with:plan.definition.sourceBodyID)
        let kind = FeatureKind.voxelRemesh(definition:plan.definition,placement:plan.placement)
        if plan.creating {
            var node = plan.node; node.kind = kind
            session.recordAndRebuild([node],title:FloeCADStrings.text("cad.mesh.voxel.createUndo","Reconstruct Scan"))
        } else { session.editFeature(plan.node.id,to:kind,title:FloeCADStrings.text("cad.mesh.voxel.updateUndo","Update Reconstruction")) }
        let introduced = session.lastEvalErrors.contains { id,error in before[id] != error }
        let sourceAfter = session.document.body(with:plan.definition.sourceBodyID)
        let sourceUnchanged: Bool
        switch (retainedSource,sourceAfter) {
        case (nil,nil): sourceUnchanged = true
        case let (before?,after?): sourceUnchanged = before.render == after.render && before.transform == after.transform
        default: sourceUnchanged = false
        }
        guard sourceUnchanged, !introduced, session.lastRebuildRejection.isEmpty,
              let body = session.document.body(with:plan.bodyID), body.brep == nil, body.surfaceBRep == nil, body.render == value.render,
              !token.isCancelled, !Task.isCancelled else {
            document.restoreEditCheckpoint(checkpoint)
            throw CADVoxelFailure.invalid("The reconstruction could not rebuild. The previous model and redo were kept.")
        }
        session.save(); reply["mutated"] = true; reply["undoSteps"] = 1; return reply
    }
    private nonisolated static func catalog() -> [String: Any] {
        ["ok":true,"mutated":false,"algorithm":CADVoxelRemeshDefinition.algorithmV1,"version":1,
         "maxInputTriangles":50_000,"maxGridCells":CADVoxelRemeshKernel.maxCells,
         "maxAxisCells":CADVoxelRemeshKernel.maxAxisCells,"maxOutputQuads":CADVoxelRemeshKernel.maxQuads,
         "wallClockSeconds":60,"computeWallClockSeconds":60,"maxDistanceQueries":2*(CADVoxelRemeshKernel.maxCells+CADVoxelRemeshKernel.maxDeviationQueries),
         "maxEvaluationsPerAction":2,"queryBudgetsApplyPerEvaluation":true,
         "maxVoxelQueries":CADVoxelRemeshKernel.maxCells,"maxDeviationQueries":CADVoxelRemeshKernel.maxDeviationQueries,
         "exactness":"mesh","sourceRetained":true,"supportsUVTransfer":false,
         "scope":"one enclosed scan; conservative half-diagonal distance band; six-neighbour exterior fill; outward manifold cubical boundary; bounded bidirectional surface-deviation certificate",
         "unavailable":["arbitrary large-hole repair","thin sheets","feature-preserving quad flow","surface projection","BRep conversion","texture transfer","internal cavity preservation"]]
    }
    private static func uuid(_ args: [String: Any],_ key: String) throws -> UUID {
        guard let raw = args[key] as? String, let id = UUID(uuidString:raw) else { throw CADVoxelFailure.invalid("Select an existing body.") }; return id
    }
    private static func number(_ args: [String: Any],_ key: String,fallback: Double? = nil) throws -> Double {
        if args[key] == nil, let fallback { return fallback }
        guard let n = args[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { throw CADVoxelFailure.invalid("\(key) must be a finite number.") }; return n.doubleValue
    }
    private static func failure(_ error: Error) -> [String: Any] {
        ["ok":false,"mutated":false,"error":(error as? CADVoxelFailure)?.code ?? "invalid_voxel_request","message":error.localizedDescription]
    }
}
