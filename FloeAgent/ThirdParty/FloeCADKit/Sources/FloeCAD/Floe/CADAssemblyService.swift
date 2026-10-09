//
//  CADAssemblyService.swift
//  FloeCADKit
//
//  JSON-action service over the persisted `CADAssembly`: instance placement,
//  positioning constraints, an iterative projection solver, approximate DOF
//  reporting, and exact (OCCT) / approximate (AABB) interference checks.
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
            let dof = dofModel(assembly)
            let dryRun = CADAssemblySolver.solve(assembly, modelScale: modelScaleFor(assembly))
            let index = CADAssemblySolver.resolvableIndex(assembly)
            let invalidAll = assembly.constraints
                .filter { !CADAssemblySolver.constraintIsResolvable($0, in: index) }
                .map { $0.id.uuidString }

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
                ]
                if let instanceB = constraint.instanceB {
                    entry["instanceB"] = instanceB.uuidString
                }
                if let value = constraint.value { entry["value"] = value }
                constraintEntries.append(entry)
            }

            return [
                "ok": true,
                "dofModel": "approximate",
                "instanceCount": assembly.instances.count,
                "constraintCount": assembly.constraints.count,
                "instances": instanceEntries,
                "constraints": constraintEntries,
                "assemblyDOF": dof.total,
                "unconstrainedInstances": dof.unconstrained.map(\.uuidString),
                "invalidRefs": invalidAll,
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
            let dof = dofModel(assembly)
            let rows: [[String: Any]] = assembly.instances.map { instance in
                ["id": instance.id.uuidString,
                 "dof": dof.perInstance[instance.id] ?? 0]
            }
            return [
                "ok": true,
                "dofModel": "approximate",
                "assemblyDOF": dof.total,
                "unconstrainedInstances": dof.unconstrained.map(\.uuidString),
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

        let pointA: SIMD3<Double>
        switch parseVector(args["pointA"]) {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let parsed): pointA = parsed ?? .zero
        }
        var pointB: SIMD3<Double>?
        if let raw = args["pointB"], !(raw is NSNull) {
            switch parseVector(raw) {
            case .failure(let error): return fail(error.code, error.message)
            case .success(let parsed): pointB = parsed
            }
        }

        var directionA = SIMD3<Double>(0, 0, 1)
        var directionB: SIMD3<Double>?
        switch kind {
        case .fixed:
            // Geometry references are ignored; the constraint only anchors A.
            if let raw = args["directionA"], !(raw is NSNull) {
                switch parseVector(raw) {
                case .failure(let error): return fail(error.code, error.message)
                case .success(let parsed): directionA = parsed ?? directionA
                }
            }
        case .coaxial, .planarAlign, .angle:
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
        case .distance:
            if let raw = args["directionA"], !(raw is NSNull) {
                switch parseVector(raw) {
                case .failure(let error): return fail(error.code, error.message)
                case .success(let parsed): directionA = parsed ?? directionA
                }
            }
            if let raw = args["directionB"], !(raw is NSNull) {
                switch parseVector(raw) {
                case .failure(let error): return fail(error.code, error.message)
                case .success(let parsed): directionB = parsed
                }
            }
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

        let constraint = CADAssemblyConstraint(
            id: UUID(),
            kind: kind,
            instanceA: instanceA,
            instanceB: instanceB,
            pointA: pointA,
            directionA: directionA,
            pointB: pointB,
            directionB: directionB,
            value: value
        )
        updated.constraints.append(constraint)
        if let failure = persist(updated) { return failure }

        var payload = constraintPayload(constraint)
        payload["ok"] = true
        payload["mutated"] = true
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

    // MARK: - Solve

    private func solveAction() -> [String: Any] {
        let assembly: CADAssembly
        switch loadAssembly() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): assembly = loaded
        }
        let result = CADAssemblySolver.solve(assembly, modelScale: modelScaleFor(assembly))
        var updated = assembly
        updated.instances = result.updatedInstances
        if let failure = persist(updated) { return failure }
        return [
            "ok": true,
            "mutated": true,
            "solved": result.solved,
            "updatedInstances": result.updatedInstances.map { instancePayload($0) },
            "updatedInstanceIDs": result.updatedInstances.map(\.id.uuidString),
            "invalidRefs": result.invalidReferences.map(\.uuidString),
            "conflicting": result.conflicting.map(\.uuidString),
        ]
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
        updated.instances = result.updatedInstances
        if let failure = persist(updated) { return failure }

        var payload = staleReport(updated)
        payload["ok"] = true
        payload["mutated"] = true
        payload["solved"] = result.solved
        payload["conflicting"] = result.conflicting.map(\.uuidString)
        payload["invalidRefs"] = result.invalidReferences.map(\.uuidString)
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
        document.session.perform(SetAssemblyDataCommand(
            before: document.session.document.assemblyData, after: nil))
        return ["ok": true, "mutated": true, "cleared": true]
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

    /// Approximate DOF model from the task contract: 6 per free instance, and
    /// each unsuppressed constraint removes its weight from every instance it
    /// references (fixed 6, coaxial 4, planarAlign 3, distance 1, angle 1),
    /// floored at 0. Deliberately a heuristic; callers see `dofModel`.
    private func dofModel(_ assembly: CADAssembly) -> (perInstance: [UUID: Int],
                                                       total: Int,
                                                       unconstrained: [UUID]) {
        var referenced = Set<UUID>()
        var fixedInstances = Set<UUID>()
        var weights: [UUID: Int] = [:]
        for constraint in assembly.constraints where !constraint.isSuppressed {
            referenced.insert(constraint.instanceA)
            if let instanceB = constraint.instanceB { referenced.insert(instanceB) }
            switch constraint.kind {
            case .fixed:
                fixedInstances.insert(constraint.instanceA)
            case .coaxial:
                weights[constraint.instanceA, default: 0] += 4
                if let instanceB = constraint.instanceB { weights[instanceB, default: 0] += 4 }
            case .planarAlign:
                weights[constraint.instanceA, default: 0] += 3
                if let instanceB = constraint.instanceB { weights[instanceB, default: 0] += 3 }
            case .distance, .angle:
                weights[constraint.instanceA, default: 0] += 1
                if let instanceB = constraint.instanceB { weights[instanceB, default: 0] += 1 }
            }
        }
        var perInstance: [UUID: Int] = [:]
        var total = 0
        var unconstrained: [UUID] = []
        for instance in assembly.instances {
            let dof: Int
            if fixedInstances.contains(instance.id) {
                dof = 0
            } else {
                dof = max(0, 6 - (weights[instance.id] ?? 0))
            }
            perInstance[instance.id] = dof
            total += dof
            if !referenced.contains(instance.id) { unconstrained.append(instance.id) }
        }
        return (perInstance, total, unconstrained)
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

private nonisolated struct CADAssemblyServiceError: Error {
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
