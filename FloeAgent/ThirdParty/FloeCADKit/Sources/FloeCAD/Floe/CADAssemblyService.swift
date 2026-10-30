//
//  CADAssemblyService.swift
//  FloeCADKit
//
//  JSON-action service over the persisted `CADAssembly`: instance placement,
//  positioning constraints (including live face/axis/edge picks with query-
//  generation fences), named exploded views (display/drawing state only), an
//  iterative projection solver, approximate DOF reporting, and exact (OCCT) /
//  approximate (AABB) interference checks.
//
//  The service is a MainActor façade. It reads and writes the assembly JSON in
//  `document.project.assemblyData` and manipulates document bodies only through
//  the existing `DocumentCommand` lifecycle. It never calls `document.save()`;
//  mutating actions return `"mutated": true` so the host commits with
//  `document.save()`. Every action returns a JSON-shaped dictionary and never
//  throws for expected errors: `["ok": false, "error": code, "message": text]`.
//
//  Contract: lengths are millimetres, angles are degrees, IDs are UUID strings,
//  transforms are {"position":[x,y,z],"rotation":[x,y,z,w],"scale":[x,y,z]}
//  (uniform scale only — the kernel's `Transform3D` cannot represent shear or
//  non-uniform scale, so such transforms are refused rather than mangled).
//
//  Threading: the service is a MainActor façade over the persisted JSON, but
//  exact OCCT work never runs there. `handleAsync(action: "interference")`
//  serializes the world-placed B-reps on the main actor, deserializes them in a
//  detached task that owns those copies exclusively, and validates task
//  cancellation plus the document revision/change count before accepting the
//  result — a late result from a document that moved is discarded. Live
//  `BRepHandle`s are never shared across threads (see the CAVEAT in
//  OCCTKernel.swift).
//

import Foundation
import simd

@MainActor
public final class CADAssemblyService {
    private let document: FloeCADDocument

    public init(document: FloeCADDocument) {
        self.document = document
    }

    /// One JSON-shaped action. See the action list in
    /// `docs/FLOE_CAD_AND_DRAWING_ASSISTANT.md`. Never throws.
    public func handle(action: String, args: [String: Any]) -> [String: Any] {
        switch action {
        case "report": return reportAction()
        case "instances": return instancesAction()
        case "addInstance": return addInstanceAction(args)
        case "removeInstance": return removeInstanceAction(args)
        case "setTransform": return setTransformAction(args)
        case "setVisible": return setVisibleAction(args)
        case "addConstraint": return addConstraintAction(args)
        case "removeConstraint": return removeConstraintAction(args)
        case "suppressConstraint": return suppressConstraintAction(args)
        case "solve": return solveAction()
        case "dof": return dofAction()
        case "interference":
            return fail("needs_async",
                        "Exact interference runs the kernel off the main actor; "
                        + "call handleAsync(action:args:) instead.")
        case "sourceUpdate": return sourceUpdateAction(args)
        case "clear": return clearAction()
        case "reference": return referenceAction(args)
        case "referenceCandidates": return referenceCandidatesAction(args)
        case "explodedViews": return explodedViewsAction()
        case "addExplodedView": return addExplodedViewAction(args)
        case "updateExplodedView": return updateExplodedViewAction(args)
        case "removeExplodedView": return removeExplodedViewAction(args)
        case "previewExplodedView": return previewExplodedViewAction(args)
        case "resetExplodedView": return resetExplodedViewAction(args)
        default:
            return fail("unknown_action", "Unknown assembly action '\(action)'.")
        }
    }

    /// Async entry point for actions with heavy OCCT work. `interference`
    /// serializes the world-placed B-reps on the main actor, runs the exact
    /// boolean common on SERIALIZED COPIES in a detached task (owning the
    /// deserialized handles; never sharing a live `BRepHandle`), then checks
    /// cancellation and the document revision/change count before any result
    /// is accepted (late results from a moved document are discarded). All
    /// other actions delegate to the synchronous path.
    public func handleAsync(action: String, args: [String: Any]) async -> [String: Any] {
        guard action == "interference" else { return handle(action: action, args: args) }
        return await interferenceOffMain(args)
    }

    /// Test-only seam called inside the detached exact-interference worker so
    /// a suite can prove the kernel work ran off the main actor. Never set in
    /// production code.
    nonisolated(unsafe) static var testOffMainProbe: (@Sendable () -> Void)?

    private struct KernelRevisionToken: Equatable, Sendable {
        let revision: Int
        let changeCount: Int
    }

    /// One resolved constraint reference in the instance's placement-local
    /// frame (the same frame `CADAssemblySolver` consumes). Produced by
    /// `reference` / inline face-edge picking; never guessed from an index
    /// without its query generation.
    struct CADAssemblyReference {
        var point: SIMD3<Double>
        var direction: SIMD3<Double>
        var sourceRevision: UInt64?
        var sourceKind: String
        var resolvedIndex: Int?
        var bodyID: UUID?
        var fence: [String: Any]?
        var notes: [String] = []

        var payload: [String: Any] {
            var object: [String: Any] = [
                "point": [point.x, point.y, point.z],
                "direction": [direction.x, direction.y, direction.z],
                "source": sourceKind,
            ]
            if let sourceRevision { object["source_revision"] = sourceRevision }
            if let resolvedIndex { object["index"] = resolvedIndex }
            if let bodyID { object["body_id"] = bodyID.uuidString }
            if let fence { object["fence"] = fence }
            if !notes.isEmpty { object["notes"] = notes }
            return object
        }
    }

    private struct ExactPairPlan: Sendable {
        let a: String
        let b: String
        let dataA: Data
        let dataB: Data
        let boxA: (min: SIMD3<Double>, max: SIMD3<Double>)
        let boxB: (min: SIMD3<Double>, max: SIMD3<Double>)
    }

    private enum ExactPairOutcome: Sendable {
        case interfering(volumeMM3: Double)
        case noSharedVolume
        case fallback
    }

    private func interferenceOffMain(_ args: [String: Any]) async -> [String: Any] {
        let assembly: CADAssembly
        switch loadAssembly() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): assembly = loaded
        }

        let tolerance = doubleValue(args["toleranceMM"]) ?? 1e-6
        guard tolerance.isFinite, tolerance >= 0 else {
            return fail("bad_tolerance", "toleranceMM must be a finite, non-negative number of mm.")
        }

        let instances = assembly.instances
        let pairCount = instances.count * (instances.count - 1) / 2
        let maxPairs = 32
        guard pairCount <= maxPairs else {
            return fail("too_many_pairs",
                        "\(pairCount) instance pairs exceed the \(maxPairs)-pair exact-check budget; "
                        + "remove instances or check subsets.")
        }

        var plans: [ExactPairPlan] = []
        var entries: [[String: Any]] = []
        var unresolved: Set<String> = []
        var refusedPairs: [[String]] = []

        for i in 0..<instances.count {
            for j in (i + 1)..<instances.count {
                let a = instances[i]
                let b = instances[j]
                guard let sourceA = body(for: effectiveBodyID(a)),
                      let sourceB = body(for: effectiveBodyID(b)) else {
                    if body(for: effectiveBodyID(a)) == nil { unresolved.insert(a.id.uuidString) }
                    if body(for: effectiveBodyID(b)) == nil { unresolved.insert(b.id.uuidString) }
                    continue
                }
                guard let worldA = placedBody(sourceA, transform: a.transform),
                      let worldB = placedBody(sourceB, transform: b.transform),
                      let boxA = MeasureKit.boundingBox(bodies: [worldA]),
                      let boxB = MeasureKit.boundingBox(bodies: [worldB]) else {
                    unresolved.insert(a.id.uuidString)
                    unresolved.insert(b.id.uuidString)
                    continue
                }
                guard aabbOverlap(boxA, boxB, tolerance: tolerance) else { continue }

                let pair: [String] = [a.id.uuidString, b.id.uuidString]
                if let brepA = worldA.brep, let brepB = worldB.brep,
                   let dataA = OCCTKernel.serialize(brepA),
                   let dataB = OCCTKernel.serialize(brepB) {
                    plans.append(ExactPairPlan(a: pair[0], b: pair[1],
                                               dataA: dataA, dataB: dataB,
                                               boxA: boxA, boxB: boxB))
                } else {
                    entries.append(meshFallbackEntry(pair, boxA: boxA, boxB: boxB,
                                                     tolerance: tolerance))
                }
            }
        }

        let token = KernelRevisionToken(revision: document.store.revision,
                                        changeCount: document.session.changeCount)
        let probe = Self.testOffMainProbe
        let outcomes: [ExactPairOutcome] = await Task.detached(priority: .userInitiated) {
            probe?()
            var results: [ExactPairOutcome] = []
            results.reserveCapacity(plans.count)
            for plan in plans {
                if Task.isCancelled {
                    results.append(.fallback)
                    continue
                }
                guard let handleA = OCCTKernel.deserialize(plan.dataA),
                      let handleB = OCCTKernel.deserialize(plan.dataB) else {
                    results.append(.fallback)
                    continue
                }
                switch OCCTKernel.booleanResult(handleA, handleB, op: 2) {
                case .success(let booleanOutcome):
                    let volume = OCCTKernel.volume(booleanOutcome.handle)
                    if volume.isFinite, volume > tolerance {
                        results.append(.interfering(volumeMM3: volume))
                    } else {
                        results.append(.noSharedVolume)
                    }
                case .failure:
                    // A regularized common with no solid means the bodies do
                    // not share volume, not an error.
                    results.append(.noSharedVolume)
                }
            }
            return results
        }.value

        if Task.isCancelled {
            return fail("cancelled", "The interference check was cancelled; no result was used.")
        }
        let current = KernelRevisionToken(revision: document.store.revision,
                                          changeCount: document.session.changeCount)
        guard current == token else {
            return fail("stale",
                        "The document changed while the interference check ran; "
                        + "re-run it against the current revision.")
        }

        for (index, outcome) in outcomes.enumerated() where index < plans.count {
            let plan = plans[index]
            switch outcome {
            case .interfering(let volume):
                entries.append(["a": plan.a, "b": plan.b, "volumeMM3": volume, "exact": true])
            case .noSharedVolume:
                refusedPairs.append([plan.a, plan.b])
            case .fallback:
                entries.append(meshFallbackEntry([plan.a, plan.b], boxA: plan.boxA, boxB: plan.boxB,
                                                 tolerance: tolerance))
            }
        }

        return [
            "ok": true,
            "mutated": false,
            "pairCount": pairCount,
            "maxPairs": maxPairs,
            "toleranceMM": tolerance,
            "interferences": entries,
            "unresolvedInstances": unresolved.sorted(),
            "kernelRefusedPairs": refusedPairs,
            "kernelExecutor": "serialized-copy-off-main",
        ]
    }

    // MARK: - Read actions

    private func reportAction() -> [String: Any] {
        switch loadAssembly() {
        case .failure(let error):
            return fail(error.code, error.message)
        case .success(let assembly):
            let dof = CADAssemblySolver.degreesOfFreedom(assembly)
            let index = CADAssemblySolver.resolvableIndex(assembly)
            let invalidAll = assembly.constraints
                .filter { !CADAssemblySolver.constraintIsResolvable($0, in: index) }
                .map { $0.id.uuidString }
            // Conflicts are read-only diagnostics: run the pure solver but
            // never persist its candidate placements from the report action.
            let dryRun = CADAssemblySolver.solve(assembly, modelScale: modelScaleFor(assembly))
            let redundant = Set(dof.redundant.map(\.uuidString))

            var instanceEntries: [[String: Any]] = []
            var stale: [String] = []
            for instance in assembly.instances {
                var entry = instancePayload(instance)
                let body = body(for: effectiveBodyID(instance))
                let isStale = body == nil || instance.sourceRevision != body?.meshRevision
                entry["stale"] = isStale
                entry["dof"] = dof.perInstance[instance.id] ?? 0
                if isStale { stale.append(instance.id.uuidString) }
                instanceEntries.append(entry)
            }

            var constraintEntries: [[String: Any]] = []
            for constraint in assembly.constraints {
                var entry: [String: Any] = [
                    "id": constraint.id.uuidString,
                    "kind": constraint.kind.rawValue,
                    "instanceA": constraint.instanceA.uuidString,
                    "suppressed": constraint.isSuppressed,
                    "valid": CADAssemblySolver.constraintIsResolvable(constraint, in: index),
                    "redundant": redundant.contains(constraint.id.uuidString),
                ]
                if let instanceB = constraint.instanceB {
                    entry["instanceB"] = instanceB.uuidString
                }
                if let value = constraint.value { entry["value"] = value }
                let revisionState = constraintRevisionState(constraint, assembly: assembly)
                entry["staleReference"] = revisionState.stale
                if let a = constraint.sourceRevisionA { entry["sourceRevisionA"] = a }
                if let b = constraint.sourceRevisionB { entry["sourceRevisionB"] = b }
                if !revisionState.staleBodies.isEmpty {
                    entry["staleReferenceBodies"] = revisionState.staleBodies
                }
                constraintEntries.append(entry)
            }

            let explodedRows = assembly.explodedViews.map { view -> [String: Any] in
                let invalid = view.entries.filter { assembly.instance($0.instanceID) == nil }
                return [
                    "id": view.id.uuidString,
                    "name": view.name,
                    "direction": vectorPayload(safeDirection(view.direction)),
                    "distanceMM": view.distanceMM,
                    "entryCount": view.entries.count,
                    "invalidEntryIDs": invalid.map(\.id.uuidString),
                    "missingInstanceIDs": invalid.map { $0.instanceID.uuidString },
                ]
            }

            // Report (and repair) the TRANSIENT preview: a view removed by an
            // edit or undo must not stay active on a stale id.
            let preview = CADExplodedViewPreview.current(for: document.session)
            preview?.reconcile(with: assembly)
            let previewPayload: [String: Any]
            if let preview, preview.isActive, let viewID = preview.viewID {
                previewPayload = ["active": true, "id": viewID.uuidString,
                                  "name": preview.viewName ?? "",
                                  "transient": true]
            } else {
                previewPayload = ["active": false]
            }

            return [
                "ok": true,
                "dofModel": "kinematic-rank",
                "instanceCount": assembly.instances.count,
                "constraintCount": assembly.constraints.count,
                "instances": instanceEntries,
                "constraints": constraintEntries,
                "explodedViewCount": assembly.explodedViews.count,
                "explodedViews": explodedRows,
                "explodedPreview": previewPayload,
                // Total remaining mobility, including the 6 global rigid modes
                // while nothing is grounded (two free instances read 12).
                "assemblyDOF": dof.total,
                // Parts-vs-parts mobility: total minus the global modes.
                "relativeDOF": dof.relative,
                // The 6 free-fly modes remain until an instance is fixed.
                "globalRigidDOF": dof.globalRigid,
                // True only when the assembly is grounded AND has no remaining
                // mobility. A free-floating assembly is never "fully constrained".
                "fullyConstrained": dof.fullyConstrained,
                "unconstrainedInstances": dof.unconstrained.map(\.uuidString),
                "invalidRefs": invalidAll,
                "redundantConstraints": dof.redundant.map(\.uuidString),
                "conflicting": dryRun.conflicting.map(\.uuidString),
                "conflicts": dryRun.conflicting.map(\.uuidString),
                "solved": dryRun.solved,
                "staleInstances": stale,
                "staleSourceBodies": stale,
            ]
        }
    }

    private func instancesAction() -> [String: Any] {
        switch loadAssembly() {
        case .failure(let error):
            return fail(error.code, error.message)
        case .success(let assembly):
            return [
                "ok": true,
                "count": assembly.instances.count,
                "instances": assembly.instances.map { instancePayload($0) },
            ]
        }
    }

    private func dofAction() -> [String: Any] {
        switch loadAssembly() {
        case .failure(let error):
            return fail(error.code, error.message)
        case .success(let assembly):
            let dof = CADAssemblySolver.degreesOfFreedom(assembly)
            let rows: [[String: Any]] = assembly.instances.map { instance in
                ["id": instance.id.uuidString,
                 "dof": dof.perInstance[instance.id] ?? 0]
            }
            return [
                "ok": true,
                "dofModel": "kinematic-rank",
                "assemblyDOF": dof.total,
                "relativeDOF": dof.relative,
                "globalRigidDOF": dof.globalRigid,
                "fullyConstrained": dof.fullyConstrained,
                "unconstrainedInstances": dof.unconstrained.map(\.uuidString),
                "redundantConstraints": dof.redundant.map(\.uuidString),
                "instances": rows,
            ]
        }
    }

    // MARK: - Instance actions

    private func addInstanceAction(_ args: [String: Any]) -> [String: Any] {
        let assembly: CADAssembly
        switch loadAssembly() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): assembly = loaded
        }
        var updated = assembly

        guard let bodyUUID = uuidValue(args["bodyID"]) else {
            return fail("bad_body_id", "bodyID must be a body UUID string.")
        }
        guard let sourceBody = body(for: bodyUUID) else {
            return fail("unknown_body", "bodyID does not reference a document body.")
        }

        let transform: CADTransform
        switch parseTransform(args["transform"]) {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let parsed): transform = parsed ?? .identity
        }

        let independentCopy = boolValue(args["independentCopy"]) ?? false
        var copiedBodyID: UUID?
        if independentCopy {
            var scratch = document.session.document
            var copy = Body(
                id: BodyID(),
                name: scratch.uniqueBodyName(base: sourceBody.name + " Copy"),
                transform: sourceBody.transform,
                primitive: sourceBody.primitive,
                render: sourceBody.render,
                revision: scratch.nextRevision()
            )
            copy.euclid = sourceBody.euclid
            // Carry the analytic solid, same rule as every other copy path: a
            // copied cylinder must not degrade to its tessellation.
            copy.brep = sourceBody.brep
            copy.material = sourceBody.material
            copy.materialFaceBindings = sourceBody.materialFaceBindings
            copy.isHidden = sourceBody.isHidden
            document.session.perform(AddBodyCommand(body: copy, title: "Assembly Copy \(sourceBody.name)"))
            copiedBodyID = copy.id.raw
        }

        let placedBody = body(for: copiedBodyID ?? bodyUUID) ?? sourceBody
        let providedName = (args["name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = (providedName?.isEmpty == false) ? providedName! : placedBody.name
        let instance = CADAssemblyInstance(
            id: UUID(),
            name: uniqueInstanceName(base: baseName, in: updated),
            bodyID: bodyUUID,
            transform: transform,
            isIndependentCopy: independentCopy,
            copiedBodyID: copiedBodyID,
            sourceRevision: placedBody.meshRevision
        )
        updated.instances.append(instance)
        if let failure = persist(updated) { return failure }

        var payload = instancePayload(instance)
        payload["ok"] = true
        payload["mutated"] = true
        return payload
    }

    private func removeInstanceAction(_ args: [String: Any]) -> [String: Any] {
        let assembly: CADAssembly
        switch loadAssembly() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): assembly = loaded
        }
        var updated = assembly

        guard let id = uuidValue(args["id"]) else {
            return fail("bad_instance_id", "id must be an instance UUID string.")
        }
        guard updated.instances.contains(where: { $0.id == id }) else {
            return fail("unknown_instance", "No assembly instance with that id.")
        }
        let removed = updated.instances.first { $0.id == id }
        updated.instances.removeAll { $0.id == id }
        let dropped = updated.constraints
            .filter { $0.instanceA == id || $0.instanceB == id }
            .map(\.id.uuidString)
        updated.constraints.removeAll { $0.instanceA == id || $0.instanceB == id }
        // Exploded-view entries are display state: drop the removed instance's
        // entries so a later preview cannot point at a dead placement. The
        // named view itself is retained.
        var droppedExplodedEntries: [String] = []
        for index in updated.explodedViews.indices {
            let removed = updated.explodedViews[index].entries
                .filter { $0.instanceID == id }
                .map(\.id.uuidString)
            droppedExplodedEntries.append(contentsOf: removed)
            updated.explodedViews[index].entries.removeAll { $0.instanceID == id }
            if !removed.isEmpty {
                updated.explodedViews[index].updatedAt = Date()
            }
        }
        if let failure = persist(updated) { return failure }

        // The instance is removed, but an independent copy's body is a
        // first-class document body and is deliberately NOT deleted: removing
        // placement must never silently destroy geometry. The host can delete
        // it through the normal body lifecycle if that is what the user wants.
        var payload: [String: Any] = [
            "ok": true,
            "mutated": true,
            "removedInstance": id.uuidString,
            "removedConstraintIDs": dropped,
            "removedExplodedEntryIDs": droppedExplodedEntries,
        ]
        if let copied = removed?.copiedBodyID {
            payload["orphanedBodyID"] = copied.uuidString
        }
        return payload
    }

    private func setTransformAction(_ args: [String: Any]) -> [String: Any] {
        let assembly: CADAssembly
        switch loadAssembly() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): assembly = loaded
        }
        var updated = assembly

        guard let id = uuidValue(args["id"]) else {
            return fail("bad_instance_id", "id must be an instance UUID string.")
        }
        guard let index = updated.instances.firstIndex(where: { $0.id == id }) else {
            return fail("unknown_instance", "No assembly instance with that id.")
        }
        let transform: CADTransform
        switch parseTransform(args["transform"]) {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let parsed):
            guard let parsed else {
                return fail("missing_transform", "transform is required for setTransform.")
            }
            transform = parsed
        }
        updated.instances[index].transform = transform
        if let failure = persist(updated) { return failure }
        return ["ok": true, "mutated": true, "instance": instancePayload(updated.instances[index])]
    }

    private func setVisibleAction(_ args: [String: Any]) -> [String: Any] {
        let assembly: CADAssembly
        switch loadAssembly() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): assembly = loaded
        }
        var updated = assembly

        guard let id = uuidValue(args["id"]) else {
            return fail("bad_instance_id", "id must be an instance UUID string.")
        }
        guard let index = updated.instances.firstIndex(where: { $0.id == id }) else {
            return fail("unknown_instance", "No assembly instance with that id.")
        }
        guard let hidden = boolValue(args["hidden"]) else {
            return fail("bad_hidden", "hidden must be a boolean.")
        }
        updated.instances[index].isHidden = hidden
        if let failure = persist(updated) { return failure }
        return ["ok": true, "mutated": true, "instance": instancePayload(updated.instances[index])]
    }

    // MARK: - Constraint actions

    private func addConstraintAction(_ args: [String: Any]) -> [String: Any] {
        let assembly: CADAssembly
        switch loadAssembly() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): assembly = loaded
        }
        var updated = assembly

        guard let kindRaw = args["kind"] as? String,
              let kind = CADAssemblyConstraintKind(rawValue: kindRaw) else {
            return fail("unknown_constraint_kind",
                        "kind must be fixed, coaxial, planarAlign, distance or angle.")
        }
        guard let instanceA = uuidValue(args["instanceA"]),
              updated.instances.contains(where: { $0.id == instanceA }) else {
            return fail("unknown_instance", "instanceA must reference an assembly instance.")
        }

        var instanceB: UUID?
        if let raw = args["instanceB"], !(raw is NSNull) {
            guard let parsed = uuidValue(raw),
                  updated.instances.contains(where: { $0.id == parsed }) else {
                return fail("unknown_instance", "instanceB must reference an assembly instance.")
            }
            instanceB = parsed
        }
        if kind != .fixed, instanceB == nil {
            return fail("missing_instance_b", "\(kind.rawValue) needs an instanceB reference.")
        }

        // Live-picked references take precedence over numeric hand entry. A
        // reference carries its own revision fence; a stale pick is refused
        // instead of being applied to a changed part. `referenceX` supplies a
        // point+direction already resolved by `reference`; `faceX`/`edgeX`
        // resolve a kernel face/edge with the same query-token proof.
        let instanceAValue = updated.instances.first { $0.id == instanceA }!
        let instanceBValue = instanceB.flatMap { id in updated.instances.first { $0.id == id } }
        var referenceA: CADAssemblyReference?
        if let resolved = parseInlineReference(args: args, key: "referenceA",
                                               faceKey: "faceA", edgeKey: "edgeA",
                                               instance: instanceAValue,
                                               assembly: updated, label: "A") {
            switch resolved {
            case .failure(let error): return fail(error.code, error.message)
            case .success(let value): referenceA = value
            }
        }
        var referenceB: CADAssemblyReference?
        if let instanceBValue,
           let resolved = parseInlineReference(args: args, key: "referenceB",
                                               faceKey: "faceB", edgeKey: "edgeB",
                                               instance: instanceBValue,
                                               assembly: updated, label: "B") {
            switch resolved {
            case .failure(let error): return fail(error.code, error.message)
            case .success(let value): referenceB = value
            }
        }

        let pointA: SIMD3<Double>
        if let referenceA {
            pointA = referenceA.point
        } else {
            switch parseVector(args["pointA"]) {
            case .failure(let error): return fail(error.code, error.message)
            case .success(let parsed): pointA = parsed ?? .zero
            }
        }
        var pointB: SIMD3<Double>?
        if let referenceB {
            pointB = referenceB.point
        } else if let raw = args["pointB"], !(raw is NSNull) {
            switch parseVector(raw) {
            case .failure(let error): return fail(error.code, error.message)
            case .success(let parsed): pointB = parsed
            }
        }

        var directionA = referenceA?.direction ?? SIMD3<Double>(0, 0, 1)
        var directionB = referenceB?.direction
        switch kind {
        case .fixed:
            // Geometry references are ignored; the constraint only anchors A.
            if referenceA == nil, let raw = args["directionA"], !(raw is NSNull) {
                switch parseVector(raw) {
                case .failure(let error): return fail(error.code, error.message)
                case .success(let parsed): directionA = parsed ?? directionA
                }
            }
        case .coaxial, .planarAlign, .angle:
            if referenceA == nil {
                guard let rawA = args["directionA"], !(rawA is NSNull) else {
                    return fail("missing_direction", "\(kind.rawValue) needs a directionA.")
                }
                switch parseVector(rawA) {
                case .failure(let error): return fail(error.code, error.message)
                case .success(let parsed):
                    guard let parsed, simd_length(parsed) > 1e-12 else {
                        return fail("zero_direction", "directionA must be a non-zero [x,y,z] vector.")
                    }
                    directionA = parsed
                }
            }
            if directionB == nil {
                guard let rawB = args["directionB"], !(rawB is NSNull) else {
                    return fail("missing_direction", "\(kind.rawValue) needs a directionB.")
                }
                switch parseVector(rawB) {
                case .failure(let error): return fail(error.code, error.message)
                case .success(let parsed):
                    guard let parsed, simd_length(parsed) > 1e-12 else {
                        return fail("zero_direction", "directionB must be a non-zero [x,y,z] vector.")
                    }
                    directionB = parsed
                }
            }
        case .distance:
            if referenceA == nil, let raw = args["directionA"], !(raw is NSNull) {
                switch parseVector(raw) {
                case .failure(let error): return fail(error.code, error.message)
                case .success(let parsed): directionA = parsed ?? directionA
                }
            }
            if referenceB == nil, let raw = args["directionB"], !(raw is NSNull) {
                switch parseVector(raw) {
                case .failure(let error): return fail(error.code, error.message)
                case .success(let parsed): directionB = parsed
                }
            }
        }
        guard simd_length(directionA) > 1e-12 else {
            return fail("zero_direction", "directionA must be a non-zero [x,y,z] vector.")
        }
        directionA = simd_normalize(directionA)
        if let value = directionB {
            guard simd_length(value) > 1e-12 else {
                return fail("zero_direction", "directionB must be a non-zero [x,y,z] vector.")
            }
            directionB = simd_normalize(value)
        }

        var value: Double?
        if let raw = args["value"], !(raw is NSNull) {
            guard let parsed = doubleValue(raw), parsed.isFinite else {
                return fail("bad_value", "value must be a finite number (mm or degrees).")
            }
            value = parsed
        }
        switch kind {
        case .distance:
            guard let value, value >= 0 else {
                return fail("bad_value", "distance value must be a finite, non-negative number of mm.")
            }
        case .angle:
            guard let value, value >= 0, value <= 180 else {
                return fail("bad_value", "angle value must be a finite number of degrees in [0, 180].")
            }
        case .fixed, .coaxial, .planarAlign:
            break
        }

        let sourceRevisionA = referenceA?.sourceRevision
            ?? body(for: effectiveBodyID(instanceAValue))?.meshRevision
        let sourceRevisionB = instanceBValue.flatMap { instance in
            referenceB?.sourceRevision ?? body(for: effectiveBodyID(instance))?.meshRevision
        }
        let constraint = CADAssemblyConstraint(
            id: UUID(),
            kind: kind,
            instanceA: instanceA,
            instanceB: instanceB,
            pointA: pointA,
            directionA: directionA,
            pointB: pointB,
            directionB: directionB,
            value: value,
            isSuppressed: false,
            sourceRevisionA: sourceRevisionA,
            sourceRevisionB: sourceRevisionB
        )
        updated.constraints.append(constraint)
        if let failure = persist(updated) { return failure }

        var payload = constraintPayload(constraint)
        payload["ok"] = true
        payload["mutated"] = true
        if let referenceA { payload["referenceA"] = referenceA.payload }
        if let referenceB { payload["referenceB"] = referenceB.payload }
        return payload
    }

    private func removeConstraintAction(_ args: [String: Any]) -> [String: Any] {
        let assembly: CADAssembly
        switch loadAssembly() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): assembly = loaded
        }
        var updated = assembly

        guard let id = uuidValue(args["id"]) else {
            return fail("bad_constraint_id", "id must be a constraint UUID string.")
        }
        guard updated.constraints.contains(where: { $0.id == id }) else {
            return fail("unknown_constraint", "No assembly constraint with that id.")
        }
        updated.constraints.removeAll { $0.id == id }
        if let failure = persist(updated) { return failure }
        return ["ok": true, "mutated": true, "removedConstraint": id.uuidString]
    }

    private func suppressConstraintAction(_ args: [String: Any]) -> [String: Any] {
        let assembly: CADAssembly
        switch loadAssembly() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): assembly = loaded
        }
        var updated = assembly

        guard let id = uuidValue(args["id"]) else {
            return fail("bad_constraint_id", "id must be a constraint UUID string.")
        }
        guard let index = updated.constraints.firstIndex(where: { $0.id == id }) else {
            return fail("unknown_constraint", "No assembly constraint with that id.")
        }
        guard let suppressed = boolValue(args["suppressed"]) else {
            return fail("bad_suppressed", "suppressed must be a boolean.")
        }
        updated.constraints[index].isSuppressed = suppressed
        if let failure = persist(updated) { return failure }
        return ["ok": true, "mutated": true,
                "constraint": constraintPayload(updated.constraints[index])]
    }

    // MARK: - Live reference picking

    /// Resolve one constraint reference from the CURRENT workbench selection
    /// or an explicit kernel face/edge with its query generation. The reply
    /// is in the instance placement-local frame and carries the document
    /// revision/change-count/body-revision fence the caller must pass back to
    /// `addConstraint` as `referenceA`/`referenceB`.
    private func referenceAction(_ args: [String: Any]) -> [String: Any] {
        let assembly: CADAssembly
        switch loadAssembly() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): assembly = loaded
        }
        guard let instanceID = uuidValue(args["instanceID"]) ?? uuidValue(args["id"]) else {
            return fail("bad_instance_id", "instanceID must be an assembly instance UUID string.")
        }
        guard let instance = assembly.instance(instanceID) else {
            return fail("unknown_instance", "No assembly instance with that id.")
        }
        guard let source = body(for: effectiveBodyID(instance)) else {
            return fail("unknown_body", "The instance's source body no longer resolves.")
        }

        if let rawFace = args["face"] as? [String: Any] {
            switch resolveKernelFaceReference(instance: instance, source: source, args: rawFace) {
            case .failure(let error): return fail(error.code, error.message)
            case .success(let reference): return referenceReply(instance: instance, reference: reference)
            }
        }
        if let rawEdge = args["edge"] as? [String: Any] {
            switch resolveKernelEdgeReference(instance: instance, source: source, args: rawEdge) {
            case .failure(let error): return fail(error.code, error.message)
            case .success(let reference): return referenceReply(instance: instance, reference: reference)
            }
        }

        if boolValue(args["useSelection"]) ?? false {
            let context = document.assistantSelectionContext()
            let inputs = document.viewModel().assistantSelectionInputs
            switch referenceFromSelection(instance: instance, source: source,
                                          selection: context,
                                          facePicks: inputs.facePicks,
                                          edgePicks: inputs.edgePicks,
                                          axisPreset: args["axisPreset"]) {
            case .failure(let error): return fail(error.code, error.message)
            case .success(let reference): return referenceReply(instance: instance, reference: reference)
            }
        }

        // Explicit instance/reference-point pick: the constraint frame's
        // origin is the instance placement point. Direction is a local preset
        // (default +Z), never inferred from a stale index.
        let preset: SIMD3<Double>
        switch parseVector(args["axisPreset"] ?? args["direction"]) {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let parsed): preset = parsed ?? SIMD3(0, 0, 1)
        }
        guard simd_length(preset) > 1e-12 else {
            return fail("zero_direction", "axisPreset must be a non-zero [x,y,z] vector.")
        }
        let reference = CADAssemblyReference(
            point: .zero,
            direction: simd_normalize(preset),
            sourceRevision: source.meshRevision,
            sourceKind: "reference_point",
            resolvedIndex: nil,
            bodyID: source.id.raw,
            fence: fenceJSON(source: source),
            notes: ["No face or edge was selected; the instance reference point (placement origin) was used."])
        return referenceReply(instance: instance, reference: reference)
    }

    /// Live, validated pick candidates for one instance: the kernel's planar
    /// faces (plane normal), cylindrical faces (real axis) and crease edges
    /// (real direction), all expressed in the instance placement-local frame
    /// with the exact query generation token the edit must echo back. This is
    /// what the native reference picker lists; it never invents a face index.
    private func referenceCandidatesAction(_ args: [String: Any]) -> [String: Any] {
        let assembly: CADAssembly
        switch loadAssembly() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): assembly = loaded
        }
        guard let instanceID = uuidValue(args["instanceID"]) ?? uuidValue(args["id"]) else {
            return fail("bad_instance_id", "instanceID must be an assembly instance UUID string.")
        }
        guard let instance = assembly.instance(instanceID) else {
            return fail("unknown_instance", "No assembly instance with that id.")
        }
        guard let source = body(for: effectiveBodyID(instance)) else {
            return fail("unknown_body", "The instance's source body no longer resolves.")
        }
        let scope = (args["scope"] as? String) ?? "all"
        guard ["all", "faces", "edges"].contains(scope) else {
            return fail("unknown_scope", "scope must be all, faces or edges.")
        }
        var notes: [String] = []
        var faces: [[String: Any]] = []
        var edges: [[String: Any]] = []
        let faceToken = CADGeometryQueryGeneration(
            scope: "faces", bodyID: source.id.raw,
            documentRevision: document.revision, changeCount: document.session.changeCount,
            meshRevision: source.meshRevision).token
        let edgeToken = CADGeometryQueryGeneration(
            scope: "edges", bodyID: source.id.raw,
            documentRevision: document.revision, changeCount: document.session.changeCount,
            meshRevision: source.meshRevision).token

        if scope != "edges", let brep = source.brep {
            for face in OCCTKernel.faceInfo(brep).prefix(256) {
                guard let signature = face.signature else { continue }
                let kind: String
                let radius: Double?
                switch signature.kind {
                case .planar: kind = "planar"; radius = nil
                case .cylindrical(let value): kind = "cylindrical"; radius = value
                }
                let point = source.transform.applying(to: face.centroid)
                let direction = normalized(source.transform.rotation.act(face.normal))
                var row: [String: Any] = [
                    "index": face.index,
                    "kind": kind,
                    "reference": kind == "planar" ? "face" : "axis",
                    "label": kind == "planar"
                        ? "Face \(face.index) · plane"
                        : "Face \(face.index) · cylinder axis",
                    "point": vectorPayload(point),
                    "direction": vectorPayload(direction),
                    "areaMM2": face.area,
                    "query_token": faceToken,
                ]
                if let radius { row["radiusMM"] = radius }
                row["signature"] = CADFaceSignatureCodec.json(signature)
                faces.append(row)
            }
            if faces.isEmpty {
                notes.append("The body has no referenceable planar/cylindrical faces.")
            }
        } else if scope != "edges" {
            notes.append("The source body has no analytic B-rep; pick a live face/edge instead.")
        }

        if scope != "faces" {
            let midpoints = source.brep.map { OCCTKernel.edgeMidpoints($0) } ?? [:]
            for (index, midpoint) in midpoints.sorted(by: { $0.key < $1.key }).prefix(256) {
                var direction: SIMD3<Double>?
                var length: Double?
                if let brep = source.brep {
                    var best = Double.greatestFiniteMagnitude
                    let segments = source.edges.segments
                    for offset in stride(from: 0, to: max(segments.count - 1, 0), by: 2) {
                        let start = segments[offset]
                        let end = segments[offset + 1]
                        let localMid = SIMD3<Double>(Double((start.x + end.x) / 2),
                                                    Double((start.y + end.y) / 2),
                                                    Double((start.z + end.z) / 2))
                        let segmentLength = simd_length(SIMD3<Double>(Double(end.x - start.x),
                                                                     Double(end.y - start.y),
                                                                     Double(end.z - start.z)))
                        guard let mapped = OCCTKernel.nearestEdgeIndex(
                            brep, to: localMid,
                            tolerance: max(1e-4, segmentLength * 0.01)),
                            mapped == index else { continue }
                        let distance = simd_length(localMid - midpoint)
                        if distance < best {
                            best = distance
                            direction = normalized(source.transform.rotation.act(
                                SIMD3<Double>(Double(end.x - start.x),
                                              Double(end.y - start.y),
                                              Double(end.z - start.z))))
                            length = segmentLength
                        }
                    }
                }
                var row: [String: Any] = [
                    "index": index,
                    "kind": "edge",
                    "reference": "edge",
                    "label": "Edge \(index)",
                    "point": vectorPayload(source.transform.applying(to: midpoint)),
                    "query_token": edgeToken,
                ]
                if let direction { row["direction"] = vectorPayload(direction) }
                if let length { row["lengthMM"] = length }
                edges.append(row)
            }
            if edges.isEmpty {
                notes.append("The body has no kernel edges.")
            }
        }

        return [
            "ok": true,
            "mutated": false,
            "instanceID": instance.id.uuidString,
            "instanceName": instance.name,
            "bodyID": source.id.raw.uuidString,
            "fence": fenceJSON(source: source),
            "faces": faces,
            "edges": edges,
            "faceCount": faces.count,
            "edgeCount": edges.count,
            "notes": notes,
        ]
    }

    private func referenceReply(instance: CADAssemblyInstance,
                                reference: CADAssemblyReference) -> [String: Any] {
        var payload = reference.payload
        payload["ok"] = true
        payload["mutated"] = false
        payload["instanceID"] = instance.id.uuidString
        payload["instanceName"] = instance.name
        payload["bodyID"] = reference.bodyID?.uuidString ?? effectiveBodyID(instance).uuidString
        payload["point"] = [reference.point.x, reference.point.y, reference.point.z]
        payload["direction"] = [reference.direction.x, reference.direction.y, reference.direction.z]
        return payload
    }

    /// Resolve a live selection into a constraint reference. Face picks are
    /// real render-mesh triangles from the current revision; a curved pick is
    /// fitted to an actual cylinder axis, a planar pick uses its measured
    /// plane, and an edge pick uses the selected crease segment. No kernel
    /// index is guessed from a stale row.
    func referenceFromSelection(
        instance: CADAssemblyInstance,
        source: Body,
        selection: CADSelectionContext,
        facePicks: [CADSelectionContext.FaceTrianglePick],
        edgePicks: [CADSelectionContext.EdgeSegmentPick],
        axisPreset: Any? = nil
    ) -> Result<CADAssemblyReference, CADAssemblyServiceError> {
        guard selection.documentRevision == Int64(document.revision),
              selection.changeCount == document.session.changeCount else {
            return .failure(CADAssemblyServiceError(
                code: "requery_required",
                message: "The selection snapshot is stale (revision \(selection.documentRevision), "
                    + "change \(selection.changeCount); current \(document.revision), "
                    + "\(document.session.changeCount)). Select the geometry again."))
        }
        let sourceID = source.id.raw
        var notes: [String] = []

        if let pick = facePicks.first(where: { $0.bodyID == sourceID }) {
            switch referenceFromFacePick(pick, source: source) {
            case .failure(let error): return .failure(error)
            case .success(let reference):
                notes.append("Resolved from the live face selection.")
                var adjusted = reference
                adjusted.notes.append(contentsOf: notes)
                return .success(adjusted)
            }
        }
        if let contextFace = selection.faces.first(where: { $0.bodyID == sourceID.uuidString }) {
            if contextFace.curved {
                return .failure(CADAssemblyServiceError(
                    code: "needs_cylinder_pick",
                    message: "The selected face is curved but its tessellation was not supplied; "
                        + "a coaxial axis needs the live face pick, not a cached normal."))
            }
            let worldPoint = SIMD3<Double>(contextFace.centroid[0], contextFace.centroid[1],
                                           contextFace.centroid[2])
            let worldNormal = SIMD3<Double>(contextFace.normal[0], contextFace.normal[1],
                                            contextFace.normal[2])
            guard let localPoint = bodyLocalPoint(worldPoint, in: source),
                  let localDirection = bodyLocalDirection(worldNormal, in: source) else {
                return .failure(CADAssemblyServiceError(
                    code: "bad_selection", message: "The selected face geometry is not finite."))
            }
            notes.append("Resolved from the cached selection face (planar normal).")
            return .success(CADAssemblyReference(
                point: source.transform.applying(to: localPoint),
                direction: normalized(source.transform.rotation.act(localDirection)),
                sourceRevision: source.meshRevision,
                sourceKind: "face",
                resolvedIndex: nil,
                bodyID: sourceID,
                fence: fenceJSON(source: source),
                notes: notes))
        }
        if let pick = edgePicks.first(where: { $0.bodyID == sourceID }) {
            let midpoint = (pick.start + pick.end) / 2
            let direction = pick.end - pick.start
            guard simd_length(direction) > 1e-9 else {
                return .failure(CADAssemblyServiceError(
                    code: "zero_edge", message: "The selected edge has zero length."))
            }
            notes.append("Resolved from the live edge selection (crease segment).")
            return .success(CADAssemblyReference(
                point: source.transform.applying(to: midpoint),
                direction: normalized(source.transform.rotation.act(direction)),
                sourceRevision: source.meshRevision,
                sourceKind: "edge",
                resolvedIndex: nil,
                bodyID: sourceID,
                fence: fenceJSON(source: source),
                notes: notes))
        }

        // The instance itself is selected (no sub-entity): use its reference
        // point. This is still a live pick, not a numeric guess.
        let preset: SIMD3<Double>
        switch parseVector(axisPreset) {
        case .failure(let error): return .failure(error)
        case .success(let parsed): preset = parsed ?? SIMD3(0, 0, 1)
        }
        guard simd_length(preset) > 1e-12 else {
            return .failure(CADAssemblyServiceError(
                code: "zero_direction", message: "axisPreset must be a non-zero [x,y,z] vector."))
        }
        notes.append("No face or edge pick matched the source body; the instance reference point was used.")
        return .success(CADAssemblyReference(
            point: .zero,
            direction: simd_normalize(preset),
            sourceRevision: source.meshRevision,
            sourceKind: "reference_point",
            resolvedIndex: nil,
            bodyID: sourceID,
            fence: fenceJSON(source: source),
            notes: notes))
    }

    private func referenceFromFacePick(
        _ pick: CADSelectionContext.FaceTrianglePick,
        source: Body
    ) -> Result<CADAssemblyReference, CADAssemblyServiceError> {
        let triangles = pick.triangles.filter {
            $0 >= 0 && $0 < source.render.triangleCount
        }
        guard !triangles.isEmpty else {
            return .failure(CADAssemblyServiceError(
                code: "bad_selection", message: "The selected face triangles no longer resolve."))
        }
        if pick.curved, let seed = triangles.first,
           let cylinder = FaceTopology.cylindricalFace(in: source.render, seedTriangle: seed) {
            return .success(CADAssemblyReference(
                point: source.transform.applying(to: cylinder.axisPoint),
                direction: normalized(source.transform.rotation.act(cylinder.axisDir)),
                sourceRevision: source.meshRevision,
                sourceKind: "axis",
                resolvedIndex: nil,
                bodyID: source.id.raw,
                fence: fenceJSON(source: source),
                notes: ["Curved face fitted to a real cylinder axis "
                        + "(radius \(String(format: "%.3f", cylinder.radius)) mm)."]))
        }
        if pick.curved {
            return .failure(CADAssemblyServiceError(
                code: "unsupported_curved_face",
                message: "The selected curved face is not a clean cylinder; "
                    + "pick a planar face or an edge for this reference."))
        }
        var normal = SIMD3<Double>.zero
        var centroid = SIMD3<Double>.zero
        let positions = source.render.positions
        let indices = source.render.indices
        var used = 0
        for triangle in triangles {
            let i0 = Int(indices[triangle * 3])
            let i1 = Int(indices[triangle * 3 + 1])
            let i2 = Int(indices[triangle * 3 + 2])
            guard i0 < positions.count, i1 < positions.count, i2 < positions.count else { continue }
            let a = SIMD3<Double>(positions[i0])
            let b = SIMD3<Double>(positions[i1])
            let c = SIMD3<Double>(positions[i2])
            let cross = simd_cross(b - a, c - a)
            if simd_length(cross) > 1e-12 {
                normal += simd_normalize(cross)
                centroid += (a + b + c) / 3
                used += 1
            }
        }
        guard used > 0, simd_length(normal) > 1e-9 else {
            return .failure(CADAssemblyServiceError(
                code: "bad_selection", message: "The selected face has no measurable normal."))
        }
        centroid /= Double(used)
        let localNormal = simd_normalize(normal)
        return .success(CADAssemblyReference(
            point: source.transform.applying(to: centroid),
            direction: normalized(source.transform.rotation.act(localNormal)),
            sourceRevision: source.meshRevision,
            sourceKind: "face",
            resolvedIndex: nil,
            bodyID: source.id.raw,
            fence: fenceJSON(source: source),
            notes: ["Planar face normal measured from \(used) live triangle(s)."]))
    }

    private func resolveKernelFaceReference(instance: CADAssemblyInstance,
                                            source: Body,
                                            args: [String: Any])
        -> Result<CADAssemblyReference, CADAssemblyServiceError> {
        guard let brep = source.brep else {
            return .failure(CADAssemblyServiceError(
                code: "face_requires_brep",
                message: "Body '\(source.name)' has no analytic B-rep faces; "
                    + "pick a live face/edge from its render mesh instead."))
        }
        let faces = OCCTKernel.faceInfo(brep)
        guard !faces.isEmpty else {
            return .failure(CADAssemblyServiceError(
                code: "no_faces", message: "The body has no kernel faces."))
        }
        var resolvedIndex: Int?
        var resolvedBySignature = false
        var notes: [String] = []
        if let signatureObject = args["signature"] as? [String: Any],
           let reference = CADFaceSignatureCodec.signature(from: signatureObject) {
            var scored: [(index: Int, score: Double)] = []
            for face in faces {
                guard let candidate = face.signature,
                      let score = CADFaceMaterialResolver.score(reference, candidate) else { continue }
                scored.append((face.index, score))
            }
            scored.sort { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }
            guard let best = scored.first,
                  best.score >= CADFaceMaterialResolver.matchThreshold else {
                return .failure(CADAssemblyServiceError(
                    code: "stale_face_ref",
                    message: "The supplied face signature no longer matches this body. "
                        + "Re-query kind=faces and use the current row."))
            }
            if scored.count > 1, best.score - scored[1].score < 0.05 {
                return .failure(CADAssemblyServiceError(
                    code: "ambiguous_face",
                    message: "The supplied face signature matches several faces; "
                        + "re-query kind=faces and pass its index with the current query_token."))
            }
            resolvedIndex = best.index
            resolvedBySignature = true
            notes.append("Resolved by stable face signature.")
        } else {
            guard let index = intValue(args["index"]) else {
                return .failure(CADAssemblyServiceError(
                    code: "requery_required",
                    message: "A kernel face reference needs index + the current query_token "
                        + "(or a stable signature). Re-query kind=faces."))
            }
            resolvedIndex = index
        }
        guard let index = resolvedIndex, let face = faces.first(where: { $0.index == index }) else {
            return .failure(CADAssemblyServiceError(
                code: "stale_face_ref",
                message: "Face index \(resolvedIndex.map(String.init) ?? "?") no longer exists. "
                    + "Re-query kind=faces."))
        }
        if !resolvedBySignature,
           let token = args["query_token"] as? String,
           !tokenIsCurrent(token, scope: "faces", source: source) {
            return .failure(CADAssemblyServiceError(
                code: "requery_required",
                message: "The face query generation is stale. Re-query kind=faces "
                    + "and pass its current query_token with the current index."))
        }
        guard let signature = face.signature else {
            return .failure(CADAssemblyServiceError(
                code: "unsupported_face",
                message: "Face \(index) has a surface kind with no reference direction "
                    + "(only planar and cylindrical faces are supported)."))
        }
        let kindName: String
        switch signature.kind {
        case .planar: kindName = "face"
        case .cylindrical: kindName = "axis"
        }
        notes.append(kindName == "axis"
                     ? "Cylindrical face resolved to its kernel axis."
                     : "Planar face resolved to its kernel plane.")
        return .success(CADAssemblyReference(
            point: source.transform.applying(to: face.centroid),
            direction: normalized(source.transform.rotation.act(face.normal)),
            sourceRevision: source.meshRevision,
            sourceKind: kindName,
            resolvedIndex: index,
            bodyID: source.id.raw,
            fence: fenceJSON(source: source),
            notes: notes))
    }

    private func resolveKernelEdgeReference(instance: CADAssemblyInstance,
                                            source: Body,
                                            args: [String: Any])
        -> Result<CADAssemblyReference, CADAssemblyServiceError> {
        guard let brep = source.brep else {
            return .failure(CADAssemblyServiceError(
                code: "edge_requires_brep",
                message: "Body '\(source.name)' has no analytic B-rep edges; "
                    + "pick a live edge from its render mesh instead."))
        }
        guard let index = intValue(args["index"]) else {
            return .failure(CADAssemblyServiceError(
                code: "requery_required",
                message: "A kernel edge reference needs an index from query kind=edges."))
        }
        if let token = args["query_token"] as? String,
           !tokenIsCurrent(token, scope: "edges", source: source) {
            return .failure(CADAssemblyServiceError(
                code: "requery_required",
                message: "The edge query generation is stale. Re-query kind=edges "
                    + "and pass its current query_token with the current index."))
        }
        let midpoints = OCCTKernel.edgeMidpoints(brep)
        guard let kernelMidpoint = midpoints[index] else {
            return .failure(CADAssemblyServiceError(
                code: "stale_edge_ref",
                message: "Edge \(index) no longer exists. Re-query kind=edges."))
        }
        // The kernel reports a midpoint, not a direction. Use the renderer's
        // crease segment that maps to this kernel edge; it is live geometry,
        // not a guess at a stored index.
        var chosenStart: SIMD3<Double>?
        var chosenEnd: SIMD3<Double>?
        var bestDistance = Double.greatestFiniteMagnitude
        let segments = source.edges.segments
        for offset in stride(from: 0, to: max(segments.count - 1, 0), by: 2) {
            let start = segments[offset]
            let end = segments[offset + 1]
            let midpoint = SIMD3<Double>(Double((start.x + end.x) / 2),
                                         Double((start.y + end.y) / 2),
                                         Double((start.z + end.z) / 2))
            let length = simd_length(SIMD3<Double>(Double(end.x - start.x),
                                                   Double(end.y - start.y),
                                                   Double(end.z - start.z)))
            guard let mapped = OCCTKernel.nearestEdgeIndex(
                brep, to: midpoint, tolerance: max(1e-4, length * 0.01)),
                mapped == index else { continue }
            let distance = simd_length(midpoint - kernelMidpoint)
            if distance < bestDistance {
                bestDistance = distance
                chosenStart = SIMD3<Double>(Double(start.x), Double(start.y), Double(start.z))
                chosenEnd = SIMD3<Double>(Double(end.x), Double(end.y), Double(end.z))
            }
        }
        guard let start = chosenStart, let end = chosenEnd else {
            return .failure(CADAssemblyServiceError(
                code: "edge_direction_unavailable",
                message: "Edge \(index) has no renderer crease segment to give its direction; "
                    + "pick it live in the viewport or pass pointA/directionA explicitly."))
        }
        return .success(CADAssemblyReference(
            point: source.transform.applying(to: (start + end) / 2),
            direction: normalized(source.transform.rotation.act(end - start)),
            sourceRevision: source.meshRevision,
            sourceKind: "edge",
            resolvedIndex: index,
            bodyID: source.id.raw,
            fence: fenceJSON(source: source),
            notes: ["Kernel edge resolved with its live renderer crease direction."]))
    }

    /// Parse `referenceA`/`faceA`/`edgeA` (same for B). Returns nil when the
    /// caller supplied none of them (legacy numeric geometry path).
    private func parseInlineReference(args: [String: Any],
                                      key: String,
                                      faceKey: String,
                                      edgeKey: String,
                                      instance: CADAssemblyInstance,
                                      assembly: CADAssembly,
                                      label: String)
        -> Result<CADAssemblyReference?, CADAssemblyServiceError>? {
        guard let source = body(for: effectiveBodyID(instance)) else {
            if args[key] != nil || args[faceKey] != nil || args[edgeKey] != nil {
                return .failure(CADAssemblyServiceError(
                    code: "unknown_body",
                    message: "The instance's source body no longer resolves."))
            }
            return nil
        }
        if let raw = args[key] as? [String: Any] {
            guard raw["point"] != nil, raw["direction"] != nil else {
                return .failure(CADAssemblyServiceError(
                    code: "bad_reference",
                    message: "reference\(label) needs the point and direction returned by the reference action."))
            }
            var reference = CADAssemblyReference(
                point: .zero,
                direction: SIMD3(0, 0, 1),
                sourceRevision: source.meshRevision,
                sourceKind: "reference",
                resolvedIndex: nil,
                bodyID: source.id.raw,
                fence: fenceJSON(source: source))
            if let pointRaw = raw["point"] {
                switch parseVector(pointRaw) {
                case .failure(let error): return .failure(error)
                case .success(let parsed):
                    guard let parsed else {
                        return .failure(CADAssemblyServiceError(
                            code: "bad_reference", message: "reference\(label).point is invalid."))
                    }
                    reference.point = parsed
                }
            }
            if let directionRaw = raw["direction"] {
                switch parseVector(directionRaw) {
                case .failure(let error): return .failure(error)
                case .success(let parsed):
                    guard let parsed, simd_length(parsed) > 1e-12 else {
                        return .failure(CADAssemblyServiceError(
                            code: "bad_reference",
                            message: "reference\(label).direction must be a non-zero vector."))
                    }
                    reference.direction = simd_normalize(parsed)
                }
            }
            if let revision = raw["source_revision"] {
                guard let value = uint64Value(revision) else {
                    return .failure(CADAssemblyServiceError(
                        code: "bad_reference",
                        message: "reference\(label).source_revision must be an unsigned integer."))
                }
                reference.sourceRevision = value
            }
            if let fence = raw["fence"] as? [String: Any] {
                if let failure = validateReferenceFence(fence, source: source, label: label) {
                    return .failure(failure)
                }
                reference.fence = fence
            }
            if let kind = raw["source"] as? String, !kind.isEmpty {
                reference.sourceKind = kind
            }
            return .success(reference)
        }
        if let raw = args[faceKey] as? [String: Any] {
            return resolveKernelFaceReference(instance: instance, source: source, args: raw)
                .map { Optional($0) }
        }
        if let raw = args[edgeKey] as? [String: Any] {
            return resolveKernelEdgeReference(instance: instance, source: source, args: raw)
                .map { Optional($0) }
        }
        return nil
    }

    /// The fence is a staleness proof, not an authority token: it only proves
    /// the pick came from this document/body generation.
    private func validateReferenceFence(_ fence: [String: Any],
                                        source: Body,
                                        label: String) -> CADAssemblyServiceError? {
        if let revision = intValue(fence["document_revision"] ?? fence["revision"]),
           revision > document.revision {
            return CADAssemblyServiceError(
                code: "requery_required",
                message: "reference\(label) was picked from a newer document revision "
                    + "(\(revision) > \(document.revision)). Re-pick it.")
        }
        if let changeCount = intValue(fence["change_count"]),
           changeCount != document.session.changeCount {
            return CADAssemblyServiceError(
                code: "requery_required",
                message: "reference\(label) was picked at change \(changeCount); the document "
                    + "is now at \(document.session.changeCount). Re-pick it.")
        }
        if let rawBody = fence["body_id"] as? String,
           UUID(uuidString: rawBody) != source.id.raw {
            return CADAssemblyServiceError(
                code: "stale_face_ref",
                message: "reference\(label) targets a different body than this instance "
                    + "currently places. Re-pick it.")
        }
        if let meshRevision = uint64Value(fence["mesh_revision"]),
           meshRevision != source.meshRevision {
            return CADAssemblyServiceError(
                code: "stale_face_ref",
                message: "The source body changed since reference\(label) was picked "
                    + "(mesh revision \(meshRevision) -> \(source.meshRevision)). Re-pick it.")
        }
        return nil
    }

    private func tokenIsCurrent(_ token: String, scope: String, source: Body) -> Bool {
        guard let generation = CADGeometryQueryGeneration.parse(token),
              generation.scope == scope else { return false }
        return generation.matches(documentRevision: document.revision,
                                  changeCount: document.session.changeCount,
                                  bodyID: source.id.raw,
                                  meshRevision: source.meshRevision)
    }

    private func fenceJSON(source: Body) -> [String: Any] {
        [
            "document_revision": document.revision,
            "change_count": document.session.changeCount,
            "body_id": source.id.raw.uuidString,
            "mesh_revision": source.meshRevision,
        ]
    }

    private func bodyLocalPoint(_ world: SIMD3<Double>, in body: Body) -> SIMD3<Double>? {
        let transform = body.transform
        guard transform.scale.isFinite, abs(transform.scale) > 1e-12 else { return nil }
        let inverseRotation = transform.rotation.inverse
        return inverseRotation.act(world - transform.translation) / transform.scale
    }

    private func bodyLocalDirection(_ world: SIMD3<Double>, in body: Body) -> SIMD3<Double>? {
        let direction = body.transform.rotation.inverse.act(world)
        return simd_length(direction) > 1e-12 ? direction : nil
    }

    private func normalized(_ vector: SIMD3<Double>) -> SIMD3<Double> {
        let length = simd_length(vector)
        return length > 1e-12 ? vector / length : SIMD3(0, 0, 1)
    }

    private func safeDirection(_ vector: SIMD3<Double>) -> SIMD3<Double> {
        normalized(vector)
    }

    private func uint64Value(_ raw: Any?) -> UInt64? {
        if let value = raw as? UInt64 { return value }
        if let value = raw as? Int, value >= 0 { return UInt64(value) }
        if let value = raw as? NSNumber { return value.uint64Value }
        if let value = raw as? String { return UInt64(value) }
        return nil
    }

    private func intValue(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? NSNumber { return value.intValue }
        if let value = raw as? String { return Int(value) }
        return nil
    }

    /// A constraint's picked geometry is stale when a recorded source
    /// revision no longer matches the live source body. Legacy numeric
    /// constraints (nil revisions) are not falsely flagged.
    private func constraintRevisionState(_ constraint: CADAssemblyConstraint,
                                         assembly: CADAssembly)
        -> (stale: Bool, staleBodies: [String]) {
        var staleBodies: [String] = []
        if let recorded = constraint.sourceRevisionA,
           let instance = assembly.instance(constraint.instanceA) {
            if let source = body(for: effectiveBodyID(instance)) {
                if source.meshRevision != recorded { staleBodies.append(source.id.raw.uuidString) }
            } else {
                staleBodies.append(effectiveBodyID(instance).uuidString)
            }
        }
        if let recorded = constraint.sourceRevisionB,
           let instanceID = constraint.instanceB,
           let instance = assembly.instance(instanceID) {
            if let source = body(for: effectiveBodyID(instance)) {
                if source.meshRevision != recorded { staleBodies.append(source.id.raw.uuidString) }
            } else {
                staleBodies.append(effectiveBodyID(instance).uuidString)
            }
        }
        return (!staleBodies.isEmpty, Array(Set(staleBodies)).sorted())
    }

    // MARK: - Exploded views

    private func explodedViewsAction() -> [String: Any] {
        let assembly: CADAssembly
        switch loadAssembly() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): assembly = loaded
        }
        // A saved view that was removed/undone while it was previewed must not
        // keep the viewport exploded on a stale id.
        CADExplodedViewPreview.current(for: document.session)?.reconcile(with: assembly)
        let rows = assembly.explodedViews.map { view -> [String: Any] in
            var row = explodedViewPayload(view, assembly: assembly)
            row["offsets"] = assembly.instances.map { instance in
                let offset = view.offset(for: instance.id)
                return [
                    "instanceID": instance.id.uuidString,
                    "name": instance.name,
                    "offset": vectorPayload(offset),
                    "distanceMM": simd_length(offset),
                ]
            }
            return row
        }
        var payload: [String: Any] = ["ok": true, "count": rows.count, "views": rows]
        if let preview = CADExplodedViewPreview.current(for: document.session),
           preview.isActive {
            payload["previewActive"] = true
            payload["activeExplodedViewID"] = preview.viewID?.uuidString
            payload["activeExplodedViewName"] = preview.viewName
        } else {
            payload["previewActive"] = false
        }
        return payload
    }

    private func addExplodedViewAction(_ args: [String: Any]) -> [String: Any] {
        let assembly: CADAssembly
        switch loadAssembly() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): assembly = loaded
        }
        guard assembly.explodedViews.count < CADAssembly.maxExplodedViews else {
            return fail("too_many_exploded_views",
                        "An assembly is bounded to \(CADAssembly.maxExplodedViews) exploded views.")
        }
        switch parseExplodedView(args: args, existing: nil, assembly: assembly) {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let view):
            var updated = assembly
            updated.explodedViews.append(view)
            if let failure = persist(updated) { return failure }
            var payload = explodedViewPayload(view, assembly: updated)
            payload["ok"] = true
            payload["mutated"] = true
            return payload
        }
    }

    private func updateExplodedViewAction(_ args: [String: Any]) -> [String: Any] {
        let assembly: CADAssembly
        switch loadAssembly() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): assembly = loaded
        }
        guard let id = uuidValue(args["id"]) ?? uuidValue(args["viewID"]) else {
            return fail("bad_view_id", "id must be an exploded-view UUID string.")
        }
        guard let index = assembly.explodedViews.firstIndex(where: { $0.id == id }) else {
            return fail("unknown_exploded_view", "No exploded view with that id.")
        }
        switch parseExplodedView(args: args, existing: assembly.explodedViews[index],
                                 assembly: assembly) {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let view):
            var updated = assembly
            updated.explodedViews[index] = view
            if let failure = persist(updated) { return failure }
            // A rename of the view being previewed must reach the viewport
            // label immediately; offsets resolve live from the saved view.
            CADExplodedViewPreview.current(for: document.session)?.reconcile(with: updated)
            var payload = explodedViewPayload(view, assembly: updated)
            payload["ok"] = true
            payload["mutated"] = true
            return payload
        }
    }

    private func removeExplodedViewAction(_ args: [String: Any]) -> [String: Any] {
        let assembly: CADAssembly
        switch loadAssembly() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): assembly = loaded
        }
        guard let id = uuidValue(args["id"]) ?? uuidValue(args["viewID"]) else {
            return fail("bad_view_id", "id must be an exploded-view UUID string.")
        }
        guard assembly.explodedViews.contains(where: { $0.id == id }) else {
            return fail("unknown_exploded_view", "No exploded view with that id.")
        }
        var updated = assembly
        updated.explodedViews.removeAll { $0.id == id }
        if let failure = persist(updated) { return failure }
        // Removing the view that is being previewed must return the viewport
        // to the baseline immediately instead of leaving a stale name/offset.
        var previewReset = false
        if let preview = CADExplodedViewPreview.current(for: document.session),
           preview.viewID == id {
            previewReset = preview.reset()
        }
        return ["ok": true, "mutated": true, "removedExplodedView": id.uuidString,
                "viewCount": updated.explodedViews.count, "previewReset": previewReset]
    }

    /// Transient placements for a named view. NOTHING is persisted and the
    /// stored instance transforms are unchanged; the named view becomes the
    /// document's live transient preview, so the engineering viewport and the
    /// presentation snapshot immediately draw the same placements. "Reset"
    /// below returns the baseline placements from the same read path and
    /// deactivates that preview.
    private func previewExplodedViewAction(_ args: [String: Any]) -> [String: Any] {
        let assembly: CADAssembly
        switch loadAssembly() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): assembly = loaded
        }
        guard let id = uuidValue(args["id"]) ?? uuidValue(args["viewID"]) else {
            return fail("bad_view_id", "id must be an exploded-view UUID string.")
        }
        guard let view = assembly.explodedView(id) else {
            // A stale id (the view was deleted, undone or replaced) must never
            // keep an older preview alive: fall back to the base placements.
            CADExplodedViewPreview.current(for: document.session)?.reset()
            return fail("unknown_exploded_view", "No exploded view with that id.")
        }
        CADExplodedViewPreview.state(for: document.session)
            .activate(viewID: view.id, name: view.name)
        return explodedPreviewPayload(view: view, assembly: assembly)
    }

    private func resetExplodedViewAction(_ args: [String: Any]) -> [String: Any] {
        // Clear the transient viewport state FIRST: a corrupt/unreadable
        // assembly must still be able to return the viewport to the baseline.
        let wasActive = CADExplodedViewPreview.current(for: document.session)?.reset() ?? false
        let assembly: CADAssembly
        switch loadAssembly() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): assembly = loaded
        }
        var payload: [String: Any] = ["ok": true, "mutated": false,
                                      "applied": false, "preview": false,
                                      "reset": true, "previewActive": false,
                                      "wasPreviewing": wasActive]
        payload["explodedPreview"] = ["active": false]
        payload["instances"] = assembly.instances.map { instance in
            [
                "instanceID": instance.id.uuidString,
                "name": instance.name,
                "transform": transformPayload(instance.transform),
                "offset": [0.0, 0.0, 0.0],
            ]
        }
        return payload
    }

    private func explodedPreviewPayload(view: CADExplodedView,
                                        assembly: CADAssembly) -> [String: Any] {
        var rows: [[String: Any]] = []
        var invalid: [String] = []
        for instance in assembly.instances {
            guard let exploded = assembly.explodedTransform(for: instance.id, viewID: view.id) else {
                invalid.append(instance.id.uuidString)
                continue
            }
            let offset = view.offset(for: instance.id)
            rows.append([
                "instanceID": instance.id.uuidString,
                "name": instance.name,
                "offset": vectorPayload(offset),
                "distanceMM": simd_length(offset),
                "baseTransform": transformPayload(instance.transform),
                "transform": transformPayload(exploded),
            ])
        }
        var payload = explodedViewPayload(view, assembly: assembly)
        payload["ok"] = true
        // "applied" means applied to the TRANSIENT viewport preview, never to
        // the document: the persisted assembly/undo/dirty state is untouched.
        payload["mutated"] = false
        payload["applied"] = true
        payload["preview"] = true
        payload["previewActive"] = true
        payload["activeExplodedViewID"] = view.id.uuidString
        payload["baselineUnchanged"] = true
        payload["writesGeometry"] = false
        payload["instances"] = rows
        payload["invalidInstances"] = invalid
        return payload
    }

    private func parseExplodedView(args: [String: Any],
                                   existing: CADExplodedView?,
                                   assembly: CADAssembly)
        -> Result<CADExplodedView, CADAssemblyServiceError> {
        var name = existing?.name ?? ""
        if let raw = args["name"] {
            guard let value = raw as? String,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(CADAssemblyServiceError(
                    code: "bad_name", message: "name must be a non-empty string."))
            }
            name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !name.isEmpty else {
            return .failure(CADAssemblyServiceError(
                code: "missing_name", message: "An exploded view needs a name."))
        }
        if assembly.explodedViews.contains(where: {
            $0.id != existing?.id && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) {
            return .failure(CADAssemblyServiceError(
                code: "duplicate_name", message: "Another exploded view already uses that name."))
        }
        var direction = existing?.direction ?? SIMD3(1, 1, 1)
        if let raw = args["direction"] {
            switch parseVector(raw) {
            case .failure(let error): return .failure(error)
            case .success(let parsed):
                guard let parsed, simd_length(parsed) > 1e-9 else {
                    return .failure(CADAssemblyServiceError(
                        code: "bad_direction",
                        message: "direction must be a non-zero finite [x,y,z]."))
                }
                direction = parsed
            }
        }
        var distance = existing?.distanceMM ?? 40
        if let raw = args["distanceMM"] {
            guard let value = doubleValue(raw), value.isFinite, value >= 0 else {
                return .failure(CADAssemblyServiceError(
                    code: "bad_distance",
                    message: "distanceMM must be a finite, non-negative number of mm."))
            }
            distance = value
        }
        var entries = existing?.entries ?? []
        if let rawEntries = args["entries"] as? [[String: Any]] {
            guard rawEntries.count <= CADAssembly.maxExplodedEntriesPerView else {
                return .failure(CADAssemblyServiceError(
                    code: "too_many_entries",
                    message: "A view is bounded to \(CADAssembly.maxExplodedEntriesPerView) instance entries."))
            }
            var parsed: [CADExplodedViewEntry] = []
            var seen = Set<UUID>()
            for raw in rawEntries {
                guard let instanceID = uuidValue(raw["instanceID"]),
                      assembly.instance(instanceID) != nil else {
                    return .failure(CADAssemblyServiceError(
                        code: "unknown_instance",
                        message: "Every exploded entry instanceID must reference a live instance."))
                }
                guard seen.insert(instanceID).inserted else {
                    return .failure(CADAssemblyServiceError(
                        code: "duplicate_entry",
                        message: "An exploded view lists each instance at most once."))
                }
                var entryDirection: SIMD3<Double>?
                if let rawDirection = raw["direction"], !(rawDirection is NSNull) {
                    switch parseVector(rawDirection) {
                    case .failure(let error): return .failure(error)
                    case .success(let vector):
                        guard let vector, simd_length(vector) > 1e-9 else {
                            return .failure(CADAssemblyServiceError(
                                code: "bad_direction",
                                message: "An entry direction must be a non-zero finite [x,y,z]."))
                        }
                        entryDirection = vector
                    }
                }
                var entryDistance: Double?
                if let rawDistance = raw["distanceMM"], !(rawDistance is NSNull) {
                    guard let value = doubleValue(rawDistance), value.isFinite, value >= 0 else {
                        return .failure(CADAssemblyServiceError(
                            code: "bad_distance",
                            message: "An entry distanceMM must be a finite, non-negative number."))
                    }
                    entryDistance = value
                }
                parsed.append(CADExplodedViewEntry(
                    id: uuidValue(raw["id"]) ?? UUID(),
                    instanceID: instanceID,
                    direction: entryDirection,
                    distanceMM: entryDistance))
            }
            entries = parsed
        } else if let rawIDs = args["instanceIDs"] as? [String] {
            // Convenience: uniform per-instance offsets for a set of ids.
            guard rawIDs.count <= CADAssembly.maxExplodedEntriesPerView else {
                return .failure(CADAssemblyServiceError(
                    code: "too_many_entries",
                    message: "A view is bounded to \(CADAssembly.maxExplodedEntriesPerView) instance entries."))
            }
            var parsed: [CADExplodedViewEntry] = []
            for rawID in rawIDs {
                guard let instanceID = UUID(uuidString: rawID),
                      assembly.instance(instanceID) != nil else {
                    return .failure(CADAssemblyServiceError(
                        code: "unknown_instance",
                        message: "Every instanceID must reference a live instance."))
                }
                parsed.append(CADExplodedViewEntry(instanceID: instanceID))
            }
            entries = parsed
        }
        let now = Date()
        return .success(CADExplodedView(
            id: existing?.id ?? UUID(),
            name: name,
            direction: direction,
            distanceMM: distance,
            entries: entries,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now))
    }

    private func explodedViewPayload(_ view: CADExplodedView,
                                     assembly: CADAssembly) -> [String: Any] {
        var payload: [String: Any] = [
            "id": view.id.uuidString,
            "name": view.name,
            "direction": vectorPayload(safeDirection(view.direction)),
            "distanceMM": view.distanceMM,
            "entryCount": view.entries.count,
            "createdAt": ISO8601DateFormatter().string(from: view.createdAt),
            "updatedAt": ISO8601DateFormatter().string(from: view.updatedAt),
        ]
        payload["entries"] = view.entries.map { entry -> [String: Any] in
            var row: [String: Any] = [
                "id": entry.id.uuidString,
                "instanceID": entry.instanceID.uuidString,
                "valid": assembly.instance(entry.instanceID) != nil,
            ]
            if let direction = entry.direction {
                row["direction"] = vectorPayload(safeDirection(direction))
            }
            if let distance = entry.distanceMM { row["distanceMM"] = distance }
            return row
        }
        return payload
    }

    // MARK: - Solve

    private func solveAction() -> [String: Any] {
        let assembly: CADAssembly
        switch loadAssembly() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): assembly = loaded
        }
        // The solver is pure and runs on a value copy; it NEVER mutates the
        // persisted assembly. A failed solve (unresolved references or
        // contradictory constraints) must leave the stored model — revision,
        // undo stack and every placement — untouched and return structured
        // diagnostics plus the uncommitted candidate as a PREVIEW, rather than
        // persisting "as close as it got" placements.
        let result = CADAssemblySolver.solve(assembly, modelScale: modelScaleFor(assembly))
        guard result.solved else {
            let invalid = Set(result.invalidReferences.map(\.uuidString))
            let conflicts = Set(result.conflicting.map(\.uuidString))
            return [
                "ok": false,
                "error": "constraint_failed",
                "mutated": false,
                "solved": false,
                "message": failureMessage(invalid: invalid, conflicts: conflicts),
                "conflicting": result.conflicting.map(\.uuidString),
                "invalidRefs": result.invalidReferences.map(\.uuidString),
                // Candidate placements the solve reached; NOT applied. The
                // caller can render these as a preview only.
                "previewInstances": result.updatedInstances.map(instancePayload),
            ]
        }
        var updated = assembly
        updated.instances = result.updatedInstances
        if let failure = persist(updated) { return failure }
        let dof = CADAssemblySolver.degreesOfFreedom(updated)
        return [
            "ok": true,
            "mutated": true,
            "solved": true,
            "updatedInstances": result.updatedInstances.map { instancePayload($0) },
            "updatedInstanceIDs": result.updatedInstances.map(\.id.uuidString),
            "invalidRefs": [],
            "conflicting": [],
            "assemblyDOF": dof.relative,
            "globalRigidDOF": dof.globalRigid,
            "fullyConstrained": dof.fullyConstrained,
            "redundantConstraints": dof.redundant.map(\.uuidString),
        ]
    }

    private func failureMessage(invalid: Set<String>, conflicts: Set<String>) -> String {
        var parts: [String] = []
        if !conflicts.isEmpty {
            parts.append("\(conflicts.count) conflicting constraint(s) cannot be satisfied together")
        }
        if !invalid.isEmpty {
            parts.append("\(invalid.count) constraint(s) reference missing or changed geometry")
        }
        if parts.isEmpty { parts.append("the constraints could not be solved") }
        return parts.joined(separator: "; ") + "; the assembly was left unchanged."
    }

    // MARK: - Interference

    // The exact interference worker lives in `interferenceOffMain`: it
    // serializes the world-placed B-reps and runs OCCT on owned copies in a
    // detached task, so no live kernel handle is touched off the main actor.

    private func meshFallbackEntry(_ pair: [String],
                                   boxA: (min: SIMD3<Double>, max: SIMD3<Double>),
                                   boxB: (min: SIMD3<Double>, max: SIMD3<Double>),
                                   tolerance: Double) -> [String: Any] {
        [
            "a": pair[0],
            "b": pair[1],
            "exact": false,
            "approximation": "mesh",
            "aabbOverlapVolumeMM3": aabbOverlapVolume(boxA, boxB),
            "toleranceMM": tolerance,
        ]
    }

    // MARK: - Source revision tracking

    private func sourceUpdateAction(_ args: [String: Any]) -> [String: Any] {
        let assembly: CADAssembly
        switch loadAssembly() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): assembly = loaded
        }
        var updated = assembly
        let apply = boolValue(args["apply"]) ?? false

        guard apply else {
            var payload = staleReport(updated)
            payload["ok"] = true
            payload["mutated"] = false
            return payload
        }

        for index in updated.instances.indices {
            let instance = updated.instances[index]
            guard let source = body(for: effectiveBodyID(instance)) else { continue }
            updated.instances[index].sourceRevision = source.meshRevision
        }
        let result = CADAssemblySolver.solve(updated, modelScale: modelScaleFor(updated))
        // Same rule as `solve`: a failed re-solve (contradictory or now-invalid
        // constraints) must not be persisted. Return the diagnostics and the
        // uncommitted candidate, leaving the stored revisions and placements
        // exactly as they were.
        guard result.solved else {
            var payload = staleReport(updated)
            payload["ok"] = false
            payload["error"] = "constraint_failed"
            payload["mutated"] = false
            payload["solved"] = false
            payload["message"] = failureMessage(
                invalid: Set(result.invalidReferences.map(\.uuidString)),
                conflicts: Set(result.conflicting.map(\.uuidString)))
            payload["conflicting"] = result.conflicting.map(\.uuidString)
            payload["invalidRefs"] = result.invalidReferences.map(\.uuidString)
            payload["previewInstances"] = result.updatedInstances.map(instancePayload)
            return payload
        }
        updated.instances = result.updatedInstances
        if let failure = persist(updated) { return failure }

        var payload = staleReport(updated)
        payload["ok"] = true
        payload["mutated"] = true
        payload["solved"] = true
        payload["conflicting"] = []
        payload["invalidRefs"] = []
        return payload
    }

    private func staleReport(_ assembly: CADAssembly) -> [String: Any] {
        var rows: [[String: Any]] = []
        var stale: [String] = []
        for instance in assembly.instances {
            let source = body(for: effectiveBodyID(instance))
            let isStale = source == nil || instance.sourceRevision != source?.meshRevision
            var row: [String: Any] = [
                "id": instance.id.uuidString,
                "bodyID": effectiveBodyID(instance).uuidString,
                "stale": isStale,
            ]
            if let recorded = instance.sourceRevision { row["recordedRevision"] = recorded }
            if let source { row["currentRevision"] = source.meshRevision }
            rows.append(row)
            if isStale { stale.append(instance.id.uuidString) }
        }
        return ["stale": stale, "staleCount": stale.count, "instances": rows]
    }

    // MARK: - Clear

    private func clearAction() -> [String: Any] {
        let previewReset = CADExplodedViewPreview.current(for: document.session)?.reset() ?? false
        document.session.perform(SetAssemblyDataCommand(
            before: document.session.document.assemblyData, after: nil))
        return ["ok": true, "mutated": true, "cleared": true, "previewReset": previewReset]
    }

    // MARK: - Assembly I/O

    private func loadAssembly() -> Result<CADAssembly, CADAssemblyServiceError> {
        do {
            return .success(try CADAssembly.decode(from: document.session.document.assemblyData))
        } catch {
            return .failure(CADAssemblyServiceError(
                code: "corrupt_assembly",
                message: "The stored assembly JSON could not be read; it was left untouched."))
        }
    }

    /// Write the assembly back into the document record as ONE undoable
    /// command, so an assembly edit participates in the shared undo stack and
    /// can be composed atomically with geometry commands. Returns a failure
    /// envelope when encoding fails; nil on success.
    private func persist(_ assembly: CADAssembly) -> [String: Any]? {
        do {
            let data = try assembly.encoded()
            document.session.perform(SetAssemblyDataCommand(
                before: document.session.document.assemblyData, after: data))
            return nil
        } catch {
            return fail("encode_failed",
                        "The assembly could not be encoded: \(error.localizedDescription)")
        }
    }

    // MARK: - Model helpers

    private func body(for id: UUID) -> Body? {
        document.session.document.bodies.first { $0.id.raw == id }
    }

    /// The body an instance actually places: an independent copy's own body,
    /// otherwise the shared part definition.
    private func effectiveBodyID(_ instance: CADAssemblyInstance) -> UUID {
        instance.copiedBodyID ?? instance.bodyID
    }

    /// A copy of `body` placed by the assembly transform composed with the
    /// body's own transform. The copy carries the source B-rep (the `Body`
    /// preview init drops it) so exact interference can run on it.
    private func placedBody(_ body: Body, transform: CADTransform) -> Body? {
        guard CADAssemblySolver.isValidTransform(transform) else { return nil }
        let placement = CADAssemblySolver.transform3D(from: transform)
        let world = placement.composed(onto: body.transform)
        var placed = Body(id: body.id,
                          name: body.name,
                          transform: world,
                          render: body.render,
                          edges: FeatureEdgeSet(segments: []),
                          revision: body.meshRevision)
        placed.brep = body.brep
        return placed
    }

    /// Model scale for residual tolerances: the world AABB diagonal of every
    /// resolvable instance, floored at 1 mm.
    private func modelScaleFor(_ assembly: CADAssembly) -> Double {
        var placed: [Body] = []
        for instance in assembly.instances {
            guard let source = body(for: effectiveBodyID(instance)),
                  let world = placedBody(source, transform: instance.transform) else { continue }
            placed.append(world)
        }
        guard let bounds = MeasureKit.boundingBox(bodies: placed) else { return 1 }
        return max(simd_length(bounds.max - bounds.min), 1)
    }

    private func aabbOverlap(_ a: (min: SIMD3<Double>, max: SIMD3<Double>),
                             _ b: (min: SIMD3<Double>, max: SIMD3<Double>),
                             tolerance: Double) -> Bool {
        for axis in 0..<3 {
            if a.max[axis] + tolerance < b.min[axis] { return false }
            if b.max[axis] + tolerance < a.min[axis] { return false }
        }
        return true
    }

    private func aabbOverlapVolume(_ a: (min: SIMD3<Double>, max: SIMD3<Double>),
                                   _ b: (min: SIMD3<Double>, max: SIMD3<Double>)) -> Double {
        let overlap = simd_max(SIMD3<Double>.zero,
                               simd_min(a.max, b.max) - simd_max(a.min, b.min))
        return overlap.x * overlap.y * overlap.z
    }

    private func uniqueInstanceName(base: String, in assembly: CADAssembly) -> String {
        let existing = Set(assembly.instances.map(\.name))
        if !existing.contains(base) { return base }
        var n = 2
        while existing.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    // MARK: - JSON payload helpers

    private func instancePayload(_ instance: CADAssemblyInstance) -> [String: Any] {
        var payload: [String: Any] = [
            "id": instance.id.uuidString,
            "name": instance.name,
            "bodyID": instance.bodyID.uuidString,
            "transform": transformPayload(instance.transform),
            "hidden": instance.isHidden,
            "independentCopy": instance.isIndependentCopy,
        ]
        if let copiedBodyID = instance.copiedBodyID {
            payload["copiedBodyID"] = copiedBodyID.uuidString
        }
        if let sourceRevision = instance.sourceRevision {
            payload["sourceRevision"] = sourceRevision
        }
        let resolved = body(for: effectiveBodyID(instance))
        payload["resolved"] = resolved != nil
        if let resolved { payload["currentRevision"] = resolved.meshRevision }
        return payload
    }

    private func constraintPayload(_ constraint: CADAssemblyConstraint) -> [String: Any] {
        var payload: [String: Any] = [
            "id": constraint.id.uuidString,
            "kind": constraint.kind.rawValue,
            "instanceA": constraint.instanceA.uuidString,
            "pointA": vectorPayload(constraint.pointA),
            "directionA": vectorPayload(constraint.directionA),
            "suppressed": constraint.isSuppressed,
        ]
        if let instanceB = constraint.instanceB { payload["instanceB"] = instanceB.uuidString }
        if let pointB = constraint.pointB { payload["pointB"] = vectorPayload(pointB) }
        if let directionB = constraint.directionB {
            payload["directionB"] = vectorPayload(directionB)
        }
        if let value = constraint.value { payload["value"] = value }
        return payload
    }

    private func transformPayload(_ transform: CADTransform) -> [String: Any] {
        [
            "position": vectorPayload(transform.position),
            "rotation": [transform.rotation.x, transform.rotation.y,
                         transform.rotation.z, transform.rotation.w],
            "scale": vectorPayload(transform.scale),
        ]
    }

    private func vectorPayload(_ vector: SIMD3<Double>) -> [Double] {
        [vector.x, vector.y, vector.z]
    }

    private func fail(_ code: String, _ message: String) -> [String: Any] {
        ["ok": false, "error": code, "message": message]
    }

    // MARK: - Argument parsing

    private func parseTransform(_ raw: Any?) -> Result<CADTransform?, CADAssemblyServiceError> {
        guard let raw, !(raw is NSNull) else { return .success(nil) }
        guard let dict = raw as? [String: Any] else {
            return .failure(CADAssemblyServiceError(
                code: "bad_transform",
                message: #"transform must be {"position":[x,y,z],"rotation":[x,y,z,w],"scale":[x,y,z]}."#))
        }
        var transform = CADTransform.identity
        if let positionRaw = dict["position"], !(positionRaw is NSNull) {
            guard let position = vector3(positionRaw) else {
                return .failure(CADAssemblyServiceError(
                    code: "bad_position", message: "position must be a finite [x,y,z] in mm."))
            }
            transform.position = position
        }
        if let rotationRaw = dict["rotation"], !(rotationRaw is NSNull) {
            guard let rotation = vector4(rotationRaw), simd_length(rotation) > 1e-12 else {
                return .failure(CADAssemblyServiceError(
                    code: "bad_rotation",
                    message: "rotation must be a finite, non-zero quaternion [x,y,z,w]."))
            }
            transform.rotation = rotation / simd_length(rotation)
        }
        if let scaleRaw = dict["scale"], !(scaleRaw is NSNull) {
            guard let scale = vector3(scaleRaw),
                  scale.x > 0, scale.y > 0, scale.z > 0 else {
                return .failure(CADAssemblyServiceError(
                    code: "bad_scale", message: "scale must be three positive finite numbers."))
            }
            let spread = max(scale.x, scale.y, scale.z)
            guard abs(scale.x - scale.y) <= 1e-9 * spread,
                  abs(scale.y - scale.z) <= 1e-9 * spread else {
                return .failure(CADAssemblyServiceError(
                    code: "non_uniform_scale",
                    message: "The kernel places instances with uniform scale only; "
                           + "supply equal scale components."))
            }
            transform.scale = scale
        }
        return .success(transform)
    }

    private func parseVector(_ raw: Any?) -> Result<SIMD3<Double>?, CADAssemblyServiceError> {
        guard let raw, !(raw is NSNull) else { return .success(nil) }
        guard let vector = vector3(raw) else {
            return .failure(CADAssemblyServiceError(
                code: "bad_vector", message: "Expected a finite [x,y,z] vector."))
        }
        return .success(vector)
    }

    private func vector3(_ raw: Any) -> SIMD3<Double>? {
        guard let values = doubles(raw), values.count == 3,
              values.allSatisfy(\.isFinite) else { return nil }
        return SIMD3(values[0], values[1], values[2])
    }

    private func vector4(_ raw: Any) -> SIMD4<Double>? {
        guard let values = doubles(raw), values.count == 4,
              values.allSatisfy(\.isFinite) else { return nil }
        return SIMD4(values[0], values[1], values[2], values[3])
    }

    private func doubles(_ raw: Any) -> [Double]? {
        if let values = raw as? [Double] { return values }
        if let values = raw as? [Int] { return values.map(Double.init) }
        if let values = raw as? [NSNumber] { return values.map(\.doubleValue) }
        guard let values = raw as? [Any] else { return nil }
        var out: [Double] = []
        out.reserveCapacity(values.count)
        for value in values {
            guard let number = doubleValue(value) else { return nil }
            out.append(number)
        }
        return out
    }

    private func doubleValue(_ raw: Any?) -> Double? {
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        if let value = raw as? Float { return Double(value) }
        if let number = raw as? NSNumber { return number.doubleValue }
        return nil
    }

    private func boolValue(_ raw: Any?) -> Bool? {
        if let value = raw as? Bool { return value }
        if let number = raw as? NSNumber { return number.boolValue }
        return nil
    }

    private func uuidValue(_ raw: Any?) -> UUID? {
        if let value = raw as? UUID { return value }
        if let value = raw as? String { return UUID(uuidString: value) }
        return nil
    }
}

// MARK: - Errors

nonisolated struct CADAssemblyServiceError: Error {
    let code: String
    let message: String
}

// MARK: - Solver

/// Deterministic, bounded iterative-projection solver over assembly
/// constraints. Pure value math, no document access; the caller supplies the
/// model scale for the relative tolerance (1e-6 × max(scale, 1)).
private nonisolated enum CADAssemblySolver {
    static let maxIterations = 64

    private struct Role {
        let movingIndex: Int
        let fixedIndex: Int
        let movingPoint: SIMD3<Double>
        let movingDirection: SIMD3<Double>
        let fixedPoint: SIMD3<Double>
        let fixedDirection: SIMD3<Double>
        let canMove: Bool
    }

    static func solve(_ input: CADAssembly, modelScale: Double) -> CADAssemblySolveResult {
        var instances = input.instances
        let index = resolvableIndex(input)

        var invalid: [UUID] = []
        var active: [CADAssemblyConstraint] = []
        for constraint in input.constraints where !constraint.isSuppressed {
            if constraintIsResolvable(constraint, in: index) {
                active.append(constraint)
            } else {
                invalid.append(constraint.id)
            }
        }

        // Anchors: instances carrying a fixed constraint are immovable; absent
        // any fixed constraint, the first constrained instance (or the first
        // instance) anchors the solve.
        var anchors = Set<UUID>()
        for constraint in active where constraint.kind == .fixed {
            anchors.insert(constraint.instanceA)
        }
        if anchors.isEmpty {
            if let first = active.first?.instanceA {
                anchors.insert(first)
            } else if let first = instances.first(where: { index[$0.id] != nil })?.id {
                anchors.insert(first)
            }
        }

        func worldTransform(_ instanceIndex: Int) -> Transform3D {
            transform3D(from: instances[instanceIndex].transform)
        }
        func worldPoint(_ local: SIMD3<Double>, _ instanceIndex: Int) -> SIMD3<Double> {
            worldTransform(instanceIndex).applying(to: local)
        }
        func worldDirection(_ local: SIMD3<Double>, _ instanceIndex: Int) -> SIMD3<Double> {
            simd_normalize(worldTransform(instanceIndex).rotation.act(local))
        }
        func role(for constraint: CADAssemblyConstraint) -> Role? {
            guard constraint.kind != .fixed,
                  let aIndex = index[constraint.instanceA],
                  let instanceB = constraint.instanceB,
                  let bIndex = index[instanceB] else { return nil }
            let aAnchored = anchors.contains(constraint.instanceA)
            let bAnchored = anchors.contains(instanceB)
            if !bAnchored {
                return Role(
                    movingIndex: bIndex,
                    fixedIndex: aIndex,
                    movingPoint: constraint.pointB ?? .zero,
                    movingDirection: constraint.directionB ?? .zero,
                    fixedPoint: constraint.pointA,
                    fixedDirection: constraint.directionA,
                    canMove: true)
            }
            if !aAnchored {
                return Role(
                    movingIndex: aIndex,
                    fixedIndex: bIndex,
                    movingPoint: constraint.pointA,
                    movingDirection: constraint.directionA,
                    fixedPoint: constraint.pointB ?? .zero,
                    fixedDirection: constraint.directionB ?? .zero,
                    canMove: true)
            }
            // Both sides anchored: residual only, never move either instance.
            return Role(
                movingIndex: bIndex,
                fixedIndex: aIndex,
                movingPoint: constraint.pointB ?? .zero,
                movingDirection: constraint.directionB ?? .zero,
                fixedPoint: constraint.pointA,
                fixedDirection: constraint.directionA,
                canMove: false)
        }

        func residual(_ constraint: CADAssemblyConstraint, _ role: Role) -> Double {
            switch constraint.kind {
            case .fixed:
                return 0
            case .coaxial:
                let movingPoint = worldPoint(role.movingPoint, role.movingIndex)
                let fixedPoint = worldPoint(role.fixedPoint, role.fixedIndex)
                let fixedDirection = worldDirection(role.fixedDirection, role.fixedIndex)
                let movingDirection = worldDirection(role.movingDirection, role.movingIndex)
                let angle = angleBetweenLines(movingDirection, fixedDirection)
                let offset = fixedPoint - movingPoint
                let perpendicular = offset - simd_dot(offset, fixedDirection) * fixedDirection
                return max(simd_length(perpendicular), angle * modelScale)
            case .planarAlign:
                let movingPoint = worldPoint(role.movingPoint, role.movingIndex)
                let fixedPoint = worldPoint(role.fixedPoint, role.fixedIndex)
                let movingNormal = worldDirection(role.movingDirection, role.movingIndex)
                let fixedNormal = worldDirection(role.fixedDirection, role.fixedIndex)
                let angle = acos(clamped(simd_dot(movingNormal, -fixedNormal)))
                let offset = abs(simd_dot(movingPoint - fixedPoint, fixedNormal))
                return max(offset, angle * modelScale)
            case .distance:
                let target = constraint.value ?? 0
                let movingPoint = worldPoint(role.movingPoint, role.movingIndex)
                let fixedPoint = worldPoint(role.fixedPoint, role.fixedIndex)
                return abs(simd_length(movingPoint - fixedPoint) - target)
            case .angle:
                let target = (constraint.value ?? 0) * .pi / 180
                let movingDirection = worldDirection(role.movingDirection, role.movingIndex)
                let fixedDirection = worldDirection(role.fixedDirection, role.fixedIndex)
                let current = acos(clamped(simd_dot(movingDirection, fixedDirection)))
                return abs(current - target) * modelScale
            }
        }

        func rotate(_ instanceIndex: Int,
                    about anchor: SIMD3<Double>,
                    localPoint: SIMD3<Double>,
                    by delta: simd_quatd) {
            let current = worldTransform(instanceIndex)
            let rotation = simd_normalize(delta * current.rotation)
            let translation = anchor - rotation.act(localPoint * current.scale)
            instances[instanceIndex].transform.position = translation
            instances[instanceIndex].transform.rotation =
                SIMD4<Double>(rotation.imag.x, rotation.imag.y, rotation.imag.z, rotation.real)
        }

        func translate(_ instanceIndex: Int, by delta: SIMD3<Double>) {
            instances[instanceIndex].transform.position += delta
        }

        func project(_ constraint: CADAssemblyConstraint, _ role: Role) {
            switch constraint.kind {
            case .fixed:
                return
            case .coaxial:
                let fixedPoint = worldPoint(role.fixedPoint, role.fixedIndex)
                let fixedDirection = worldDirection(role.fixedDirection, role.fixedIndex)
                let movingDirection = worldDirection(role.movingDirection, role.movingIndex)
                let target = simd_dot(movingDirection, fixedDirection) >= 0
                    ? fixedDirection : -fixedDirection
                if simd_dot(movingDirection, target) < 1 - 1e-15 {
                    let delta = alignmentRotation(from: movingDirection, to: target)
                    rotate(role.movingIndex,
                           about: worldPoint(role.movingPoint, role.movingIndex),
                           localPoint: role.movingPoint,
                           by: delta)
                }
                let movingPoint = worldPoint(role.movingPoint, role.movingIndex)
                let offset = fixedPoint - movingPoint
                translate(role.movingIndex,
                          by: offset - simd_dot(offset, fixedDirection) * fixedDirection)
            case .planarAlign:
                let fixedPoint = worldPoint(role.fixedPoint, role.fixedIndex)
                let fixedNormal = worldDirection(role.fixedDirection, role.fixedIndex)
                let movingNormal = worldDirection(role.movingDirection, role.movingIndex)
                let target = -fixedNormal
                if simd_dot(movingNormal, target) < 1 - 1e-15 {
                    let delta = alignmentRotation(from: movingNormal, to: target)
                    rotate(role.movingIndex,
                           about: worldPoint(role.movingPoint, role.movingIndex),
                           localPoint: role.movingPoint,
                           by: delta)
                }
                let movingPoint = worldPoint(role.movingPoint, role.movingIndex)
                let offset = simd_dot(movingPoint - fixedPoint, fixedNormal)
                translate(role.movingIndex, by: -offset * fixedNormal)
            case .distance:
                let target = constraint.value ?? 0
                let movingPoint = worldPoint(role.movingPoint, role.movingIndex)
                let fixedPoint = worldPoint(role.fixedPoint, role.fixedIndex)
                let separation = movingPoint - fixedPoint
                let length = simd_length(separation)
                let direction: SIMD3<Double>
                if length > 1e-12 {
                    direction = separation / length
                } else if simd_length(role.fixedDirection) > 1e-12 {
                    direction = worldDirection(role.fixedDirection, role.fixedIndex)
                } else {
                    direction = SIMD3(0, 0, 1)
                }
                translate(role.movingIndex, by: fixedPoint + direction * target - movingPoint)
            case .angle:
                let target = (constraint.value ?? 0) * .pi / 180
                let movingDirection = worldDirection(role.movingDirection, role.movingIndex)
                let fixedDirection = worldDirection(role.fixedDirection, role.fixedIndex)
                let current = acos(clamped(simd_dot(movingDirection, fixedDirection)))
                let delta = current - target
                if abs(delta) < 1e-15 { return }
                let cross = simd_cross(movingDirection, fixedDirection)
                let axis: SIMD3<Double>
                if simd_length(cross) > 1e-9 {
                    axis = simd_normalize(cross)
                } else {
                    let helper: SIMD3<Double> = abs(fixedDirection.x) < 0.9
                        ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
                    axis = simd_normalize(simd_cross(fixedDirection, helper))
                }
                rotate(role.movingIndex,
                       about: worldPoint(role.movingPoint, role.movingIndex),
                       localPoint: role.movingPoint,
                       by: simd_quatd(angle: delta, axis: axis))
            }
        }

        let tolerance = 1e-6 * max(modelScale, 1)
        for _ in 0..<maxIterations {
            var worst = 0.0
            for constraint in active {
                guard let role = role(for: constraint) else { continue }
                let value = residual(constraint, role)
                worst = max(worst, value)
                if value > tolerance, role.canMove {
                    project(constraint, role)
                }
            }
            if worst <= tolerance { break }
        }

        var conflicting: [UUID] = []
        for constraint in active {
            guard let role = role(for: constraint) else { continue }
            if residual(constraint, role) > tolerance {
                conflicting.append(constraint.id)
            }
        }

        // Belt and braces: a solve must never emit a non-finite placement.
        for instanceIndex in instances.indices
        where !isValidTransform(instances[instanceIndex].transform) {
            instances[instanceIndex] = input.instances[instanceIndex]
        }

        return CADAssemblySolveResult(
            updatedInstances: instances,
            invalidReferences: invalid,
            conflicting: conflicting,
            solved: conflicting.isEmpty && invalid.isEmpty)
    }

    // MARK: - Degrees of freedom (kinematic rank)

    /// Rank-based DOF over the assembly's instantaneous twists.
    ///
    /// Every resolvable instance contributes six twist coordinates
    /// `[ωx ωy ωz vx vy vz]` (angular velocity about the instance origin plus
    /// the origin's linear velocity). Each unsuppressed, resolvable constraint
    /// contributes its linearized screw rows at the CURRENT configuration
    /// (fixed 6, coaxial 4, planarAlign 3, distance 1, angle 1); its true
    /// effect is the RANK of the stacked rows, so duplicate or redundant
    /// constraints add no extra rank and can never falsely reduce the count.
    ///
    /// Reported quantities:
    ///  * `total`     — remaining mobility `6N - rank`. With no `fixed`
    ///                  constraint the six global rigid modes are included, so
    ///                  two free instances report 12 (6 each).
    ///  * `globalRigid` — 6 while nothing is grounded, else 0. Internal
    ///                  constraints can never remove the global modes.
    ///  * `relative`  — `total - globalRigid`, the parts-vs-parts mobility.
    ///  * `fullyConstrained` — mobility 0 AND grounded; a free-floating
    ///                  assembly is never reported as fully constrained.
    ///  * `perInstance` — dimension of the projection of the nullspace onto
    ///                  each instance's six coordinates (0 for a pinned body).
    ///  * `redundant` — constraints whose own rows lie in the span of the
    ///                  other constraints' rows (duplicate/redundant rows).
    ///
    /// The computation is exact for ≤ `maxExactInstances` instances and
    /// ≤ `maxExactConstraints` constraints; beyond that the rank is still
    /// computed but `exact` is false and `fullyConstrained` is not claimed.
    static let maxExactInstances = 64
    static let maxExactConstraints = 128

    struct DOFResult: Sendable, Equatable {
        var perInstance: [UUID: Int]
        var total: Int
        var relative: Int
        var globalRigid: Int
        var fullyConstrained: Bool
        var unconstrained: [UUID]
        var redundant: [UUID]
        var exact: Bool
    }

    static func degreesOfFreedom(_ assembly: CADAssembly) -> DOFResult {
        let index = resolvableIndex(assembly)
        var order: [Int] = []
        var columnOf: [UUID: Int] = [:]
        var transforms: [Transform3D] = []
        for (position, instance) in assembly.instances.enumerated()
        where index[instance.id] == position {
            columnOf[instance.id] = order.count
            order.append(position)
            transforms.append(transform3D(from: instance.transform))
        }
        let n = order.count
        let columns = 6 * n
        let active = assembly.constraints.filter {
            !$0.isSuppressed && constraintIsResolvable($0, in: index)
        }
        let grounded = active.contains { $0.kind == .fixed }
        let exact = n <= maxExactInstances && active.count <= maxExactConstraints

        func row() -> [Double] { [Double](repeating: 0, count: columns) }

        /// Coefficients of the functional `n · v_p` at world point `p` for
        /// body `id`: linear part `n`, angular part `(p - o) × n`.
        func translationRow(_ id: UUID, direction n: SIMD3<Double>,
                            point p: SIMD3<Double>, sign: Double) -> [Double] {
            var result = row()
            guard let column = columnOf[id] else { return result }
            let offset = p - transforms[column].translation
            let angular = simd_cross(offset, n)
            for k in 0..<3 {
                result[6 * column + k] += sign * angular[k]
                result[6 * column + 3 + k] += sign * n[k]
            }
            return result
        }

        func rotationRow(_ id: UUID, axis a: SIMD3<Double>, sign: Double) -> [Double] {
            var result = row()
            guard let column = columnOf[id] else { return result }
            for k in 0..<3 { result[6 * column + k] += sign * a[k] }
            return result
        }

        func add(_ lhs: [Double], _ rhs: [Double]) -> [Double] {
            var result = lhs
            for k in 0..<result.count { result[k] += rhs[k] }
            return result
        }

        func perpendicularBasis(_ axis: SIMD3<Double>) -> [SIMD3<Double>] {
            let helper: SIMD3<Double> = abs(axis.x) < 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
            let first = simd_normalize(simd_cross(axis, helper))
            let second = simd_normalize(simd_cross(axis, first))
            return [first, second]
        }

        /// World reference point/direction of a constraint's local geometry.
        func worldPoint(_ id: UUID, _ local: SIMD3<Double>) -> SIMD3<Double>? {
            guard let column = columnOf[id] else { return nil }
            return transforms[column].applying(to: local)
        }

        func worldDirection(_ id: UUID, _ local: SIMD3<Double>) -> SIMD3<Double>? {
            guard let column = columnOf[id] else { return nil }
            let direction = transforms[column].rotation.act(local)
            guard simd_length(direction) > 1e-12 else { return nil }
            return simd_normalize(direction)
        }

        /// One pair constraint's linearized rows.
        ///
        /// All rows are pure functionals of the RELATIVE motion
        /// `(ω_B - ω_A, v_B - v_A)` so a global rigid motion applied to every
        /// body is exactly in the nullspace. For point/plane offsets the
        /// functional is evaluated at one common world point and includes the
        /// lever-arm angular coupling a rotating reference frame contributes.
        func rows(for constraint: CADAssemblyConstraint) -> [[Double]] {
            switch constraint.kind {
            case .fixed:
                guard let column = columnOf[constraint.instanceA] else { return [] }
                var result: [[Double]] = []
                for k in 0..<6 {
                    var r = row()
                    r[6 * column + k] = 1
                    result.append(r)
                }
                return result
            case .coaxial, .planarAlign:
                guard let b = constraint.instanceB,
                      let directionA = worldDirection(constraint.instanceA, constraint.directionA),
                      let _ = worldDirection(b, constraint.directionB ?? .zero),
                      let common = worldPoint(constraint.instanceA, constraint.pointA)
                else { return [] }
                let basis = perpendicularBasis(directionA)
                var result: [[Double]] = []
                for axis in basis {
                    // Relative angular velocity perpendicular to the axis
                    // keeps the two directions at a constant angle.
                    result.append(add(
                        rotationRow(b, axis: axis, sign: 1),
                        rotationRow(constraint.instanceA, axis: axis, sign: -1)))
                }
                if constraint.kind == .coaxial {
                    // Perpendicular point-on-axis offsets, measured at the
                    // common point. The lever arm λ (separation along the
                    // axis) couples relative rotation into the offset rate.
                    guard let pointB = worldPoint(b, constraint.pointB ?? .zero) else { return [] }
                    let lever = simd_dot(pointB - common, directionA)
                    for axis in basis {
                        var r = add(
                            translationRow(b, direction: axis, point: common, sign: 1),
                            translationRow(constraint.instanceA, direction: axis,
                                           point: common, sign: -1))
                        let coupling = simd_cross(directionA, axis) * lever
                        r = add(r, rotationRow(b, axis: coupling, sign: 1))
                        r = add(r, rotationRow(constraint.instanceA, axis: coupling, sign: -1))
                        result.append(r)
                    }
                } else {
                    // Coplanar offset along A's normal plus the lever-arm
                    // coupling of relative rotation at that point.
                    guard let pointB = worldPoint(b, constraint.pointB ?? .zero) else { return [] }
                    let lever = simd_cross(pointB - common, directionA)
                    var r = add(
                        translationRow(b, direction: directionA, point: common, sign: 1),
                        translationRow(constraint.instanceA, direction: directionA,
                                       point: common, sign: -1))
                    r = add(r, rotationRow(b, axis: lever, sign: 1))
                    r = add(r, rotationRow(constraint.instanceA, axis: lever, sign: -1))
                    result.append(r)
                }
                return result
            case .distance:
                guard let b = constraint.instanceB,
                      let pointA = worldPoint(constraint.instanceA, constraint.pointA),
                      let pointB = worldPoint(b, constraint.pointB ?? .zero) else { return [] }
                var separation = pointB - pointA
                if simd_length(separation) < 1e-12 {
                    separation = worldDirection(constraint.instanceA, constraint.directionA)
                        ?? SIMD3(0, 0, 1)
                }
                let normal = simd_normalize(separation)
                // n is parallel to (pointB - pointA), so the body-rate
                // angular term vanishes and the common-point form is exact.
                return [add(
                    translationRow(b, direction: normal, point: pointA, sign: 1),
                    translationRow(constraint.instanceA, direction: normal,
                                   point: pointA, sign: -1))]
            case .angle:
                guard let b = constraint.instanceB,
                      let directionA = worldDirection(constraint.instanceA, constraint.directionA),
                      let directionB = worldDirection(b, constraint.directionB ?? .zero)
                else { return [] }
                var axis = simd_cross(directionA, directionB)
                if simd_length(axis) < 1e-12 {
                    // Parallel axes: any perpendicular axis is a valid
                    // linearization of the angle constraint.
                    axis = perpendicularBasis(directionA)[0]
                }
                axis = simd_normalize(axis)
                return [add(
                    rotationRow(b, axis: axis, sign: 1),
                    rotationRow(constraint.instanceA, axis: axis, sign: -1))]
            }
        }

        var matrix: [[Double]] = []
        for constraint in active {
            matrix.append(contentsOf: rows(for: constraint))
        }

        let analysis = analyze(matrix, columns: columns)
        let rank = analysis.rank
        let total = max(0, columns - rank)
        let globalRigid = (!grounded && n > 0) ? 6 : 0
        let relative = max(0, total - globalRigid)
        let fullyConstrained = exact && grounded && total == 0

        var perInstance: [UUID: Int] = [:]
        for (slot, position) in order.enumerated() {
            let id = assembly.instances[position].id
            let projection = analysis.nullspace.map { vector in
                Array(vector[(6 * slot)..<(6 * slot + 6)])
            }
            perInstance[id] = analyze(projection, columns: 6).rank
        }
        // Instances skipped by the solver (invalid transform) stay listed but
        // have no kinematic contribution to report.
        for instance in assembly.instances where perInstance[instance.id] == nil {
            perInstance[instance.id] = 0
        }

        var referenced = Set<UUID>()
        for constraint in active {
            referenced.insert(constraint.instanceA)
            if let b = constraint.instanceB { referenced.insert(b) }
        }
        let unconstrained = assembly.instances
            .filter { !referenced.contains($0.id) }
            .map(\.id)

        // Redundancy, incremental and order-stable: a constraint is redundant
        // when adding its rows to the previously accepted constraints does not
        // increase the rank. With duplicate rows this flags the LATER copies
        // (the earlier one remains authoritative readable); independent
        // constraints are never flagged. Bounded to a small exact window.
        var redundant: [UUID] = []
        if exact && n <= 16 && active.count <= 24 {
            var accumulated: [[Double]] = []
            var accumulatedRank = 0
            for constraint in active {
                accumulated.append(contentsOf: rows(for: constraint))
                let grown = analyze(accumulated, columns: columns).rank
                if grown == accumulatedRank {
                    redundant.append(constraint.id)
                } else {
                    accumulatedRank = grown
                }
            }
        }

        return DOFResult(perInstance: perInstance,
                         total: total,
                         relative: relative,
                         globalRigid: globalRigid,
                         fullyConstrained: fullyConstrained,
                         unconstrained: unconstrained,
                         redundant: redundant,
                         exact: exact)
    }

    struct RankAnalysis {
        var rank: Int
        var nullspace: [[Double]]
    }

    /// Gauss-Jordan rank + nullspace. Rows are normalized to unit length so
    /// the pivot tolerance is scale-independent; `tolerance` is relative.
    static func analyze(_ matrix: [[Double]], columns: Int,
                        tolerance: Double = 1e-8) -> RankAnalysis {
        guard !matrix.isEmpty, columns > 0 else {
            return RankAnalysis(rank: 0, nullspace: identityNullspace(columns: columns))
        }
        var a = matrix.map { row -> [Double] in
            let norm = sqrt(row.reduce(0) { $0 + $1 * $1 })
            guard norm > 1e-15 else { return row }
            return row.map { $0 / norm }
        }
        let rows = a.count
        var pivotRow = 0
        var pivotColumns: [Int] = []
        for col in 0..<columns where pivotRow < rows {
            var best = pivotRow
            var bestValue = abs(a[pivotRow][col])
            for r in (pivotRow + 1)..<rows {
                let value = abs(a[r][col])
                if value > bestValue { best = r; bestValue = value }
            }
            guard bestValue > tolerance else { continue }
            a.swapAt(pivotRow, best)
            let pivot = a[pivotRow][col]
            for c in 0..<columns { a[pivotRow][c] /= pivot }
            for r in 0..<rows where r != pivotRow {
                let factor = a[r][col]
                guard factor != 0 else { continue }
                for c in 0..<columns { a[r][c] -= factor * a[pivotRow][c] }
            }
            pivotColumns.append(col)
            pivotRow += 1
        }
        let pivotSet = Set(pivotColumns)
        var nullspace: [[Double]] = []
        for free in 0..<columns where !pivotSet.contains(free) {
            var vector = [Double](repeating: 0, count: columns)
            vector[free] = 1
            for (rowIndex, pivotColumn) in pivotColumns.enumerated() {
                vector[pivotColumn] = -a[rowIndex][free]
            }
            nullspace.append(vector)
        }
        return RankAnalysis(rank: pivotColumns.count, nullspace: nullspace)
    }

    private static func identityNullspace(columns: Int) -> [[Double]] {
        (0..<columns).map { index in
            var vector = [Double](repeating: 0, count: columns)
            vector[index] = 1
            return vector
        }
    }

    // MARK: Validation

    static func resolvableIndex(_ assembly: CADAssembly) -> [UUID: Int] {
        var index: [UUID: Int] = [:]
        for (position, instance) in assembly.instances.enumerated()
        where index[instance.id] == nil && isValidTransform(instance.transform) {
            index[instance.id] = position
        }
        return index
    }

    static func constraintIsResolvable(_ constraint: CADAssemblyConstraint,
                                       in index: [UUID: Int]) -> Bool {
        guard index[constraint.instanceA] != nil, isFinite(constraint.pointA) else {
            return false
        }
        switch constraint.kind {
        case .fixed:
            return true
        case .distance:
            guard let instanceB = constraint.instanceB, index[instanceB] != nil,
                  let value = constraint.value, value.isFinite, value >= 0 else {
                return false
            }
            if let pointB = constraint.pointB, !isFinite(pointB) { return false }
            return true
        case .coaxial, .planarAlign:
            guard let instanceB = constraint.instanceB, index[instanceB] != nil,
                  isFinite(constraint.directionA),
                  simd_length_squared(constraint.directionA) > 1e-24,
                  let directionB = constraint.directionB,
                  isFinite(directionB),
                  simd_length_squared(directionB) > 1e-24 else {
                return false
            }
            if let pointB = constraint.pointB, !isFinite(pointB) { return false }
            return true
        case .angle:
            guard let instanceB = constraint.instanceB, index[instanceB] != nil,
                  isFinite(constraint.directionA),
                  simd_length_squared(constraint.directionA) > 1e-24,
                  let directionB = constraint.directionB,
                  isFinite(directionB),
                  simd_length_squared(directionB) > 1e-24,
                  let value = constraint.value,
                  value.isFinite, value >= 0, value <= 180 else {
                return false
            }
            if let pointB = constraint.pointB, !isFinite(pointB) { return false }
            return true
        }
    }

    static func isValidTransform(_ transform: CADTransform) -> Bool {
        guard isFinite(transform.position),
              isFinite(transform.rotation),
              isFinite(transform.scale) else { return false }
        guard transform.scale.x > 0, transform.scale.y > 0, transform.scale.z > 0 else {
            return false
        }
        let spread = max(transform.scale.x, transform.scale.y, transform.scale.z)
        guard abs(transform.scale.x - transform.scale.y) <= 1e-9 * spread,
              abs(transform.scale.y - transform.scale.z) <= 1e-9 * spread else {
            return false
        }
        return simd_length(transform.rotation) > 1e-12
    }

    static func transform3D(from transform: CADTransform) -> Transform3D {
        let length = simd_length(transform.rotation)
        let rotation = length > 1e-12
            ? simd_quatd(ix: transform.rotation.x / length,
                         iy: transform.rotation.y / length,
                         iz: transform.rotation.z / length,
                         r: transform.rotation.w / length)
            : simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        return Transform3D(translation: transform.position,
                           rotation: rotation,
                           scale: transform.scale.x)
    }

    // MARK: Math

    /// Minimal rotation carrying unit vector `a` onto unit vector `b`
    /// (identity when parallel; a well-defined half-turn when opposite).
    /// Mirrors `SweepLoftKit.rotation` so both solvers agree.
    static func alignmentRotation(from a: SIMD3<Double>, to b: SIMD3<Double>) -> simd_quatd {
        let dot = simd_dot(a, b)
        if dot > 1 - 1e-12 {
            return simd_quatd(angle: 0, axis: SIMD3(1, 0, 0))
        }
        if dot < -1 + 1e-12 {
            let helper: SIMD3<Double> = abs(a.x) < 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
            return simd_quatd(angle: .pi, axis: simd_normalize(simd_cross(a, helper)))
        }
        return simd_quatd(from: a, to: b)
    }

    /// Angle between two LINES (not arrows): values above π/2 fold back.
    private static func angleBetweenLines(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let angle = acos(clamped(simd_dot(a, b)))
        return min(angle, .pi - angle)
    }

    private static func clamped(_ value: Double) -> Double {
        min(1, max(-1, value))
    }

    private static func isFinite(_ vector: SIMD3<Double>) -> Bool {
        vector.x.isFinite && vector.y.isFinite && vector.z.isFinite
    }

    private static func isFinite(_ vector: SIMD4<Double>) -> Bool {
        vector.x.isFinite && vector.y.isFinite && vector.z.isFinite && vector.w.isFinite
    }
}
