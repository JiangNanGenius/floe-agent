//
//  CADAssemblyService.swift
//  FloeCADKit
//
//  JSON-action service over the persisted `CADAssembly`: instance placement,
//  positioning constraints (including live face/axis/edge picks with query-
//  generation fences), named exploded views (display/drawing state only), an
//  iterative projection solver, rank-based DOF reporting with an explicit
//  residual-solve credibility check, and selected-instance all-pairs
//  interference: exact OCCT common volume where both instances carry a B-rep,
//  otherwise real triangle-surface distance/contact/containment (AABB is
//  broadphase only). Existing constraints can be edited in place while
//  keeping their stable id, scope and reference pins.
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
//  resolves an explicit instance/subassembly subset, snapshots immutable mesh
//  and B-rep bytes on the main actor, then streams every requested pair through
//  one detached worker that owns its deserialized copies exclusively. The
//  service owns real processed-pair progress and cancellation, and validates
//  task cancellation plus the document revision/change count before accepting
//  the result — a late result from a document that moved is discarded. Live
//  `BRepHandle`s are never shared across threads (see the CAVEAT in
//  OCCTKernel.swift).
//

import Foundation
import CryptoKit
import simd


// MARK: - Interference run state

/// One generation of a CAD document. Both values are checked after the worker
/// joins; a result from any other generation is discarded.
nonisolated struct CADAssemblyKernelRevisionToken: Equatable, Sendable {
    let revision: Int
    let changeCount: Int
}

nonisolated struct CADAssemblyInterferenceGeometryKey: Hashable, Sendable {
    let bodyID: UUID
    let meshRevision: UInt64
}

/// Immutable per-occurrence input for off-main inspection. The mesh arrays are
/// retained value storage (copy-on-write), not a new world-space triangle copy;
/// the worker builds one local geometry per unique body definition.
nonisolated struct CADAssemblyInterferenceInstanceSnapshot: Sendable {
    let instanceID: UUID
    let name: String
    let bodyID: UUID?
    let geometryKey: CADAssemblyInterferenceGeometryKey?
    let placement: CADInterferenceTransform
    let positions: [SIMD3<Float>]
    let indices: [UInt32]
    let brepData: Data?
    let brepUnavailable: Bool
    let missingReason: String?
}

nonisolated struct CADAssemblyInterferencePairOutcome: Sendable {
    let a: UUID
    let b: UUID
    let mode: String
    let classification: String
    let exactVolume: Bool
    let volumeMM3: Double?
    /// The explicit cubic (mm³) threshold used for this exact result. Never
    /// the linear contact tolerance.
    let volumeThresholdMM3: Double?
    /// A real positive common volume is below the explicit cubic threshold.
    /// It remains reported with its actual volume; it is never rewritten as
    /// `noSharedVolume` or `separated`.
    let volumeBelowThreshold: Bool?
    let volumeClassification: String?
    let minimumDistanceMM: Double?
    let precisionMM: Double?
    let witnessA: SIMD3<Double>?
    let witnessB: SIMD3<Double>?
    let triangleA: Int?
    let triangleB: Int?
    let surfaceCrossing: Bool
    let surfaceTouching: Bool
    let containment: String
    let aabbGapMM: Double?
    let aabbOverlapVolumeMM3: Double?
    let topologyA: CADInterferenceMeshTopology?
    let topologyB: CADInterferenceMeshTopology?
    let notes: [String]
    let unresolvedReason: String?
    let kernelRefused: Bool
    let kernelErrorDetail: String?
}

nonisolated struct CADAssemblyInterferenceWorkerResult: Sendable {
    let outcomes: [CADAssemblyInterferencePairOutcome]
    let cancelled: Bool
    /// The complete detailed result would exceed the explicit byte envelope.
    /// No outcome is returned in this case: an envelope refusal is atomic and
    /// never presents `ok=true` with a dropped tail.
    let budgetExceeded: Bool
    /// A row could not be encoded as finite JSON. The service refuses instead
    /// of silently omitting it.
    let detailEncodingFailed: Bool
    /// Encoded UTF-8 bytes of every accepted detail row (canonical sorted-key
    /// JSON, one LF per row).
    let detailBytes: Int
}

/// Thread-safe progress owned by the service run. Every processed requested
/// pair increments exactly one counter; no UI-derived percentage is used.
nonisolated final class CADAssemblyInterferenceProgressBox: @unchecked Sendable {
    struct Snapshot: Sendable, Equatable {
        var runID: UUID
        var phase: String
        var selectedInstanceCount: Int
        var requestedPairCount: Int
        var processedPairCount: Int
        var exactPairCount: Int
        var meshPairCount: Int
        var interferingPairCount: Int
        var contactPairCount: Int
        var separatedPairCount: Int
        var unresolvedPairCount: Int
        var cancelled: Bool
        var startedAt: Date
    }

    private let lock = NSLock()
    private var state: Snapshot

    init(runID: UUID) {
        state = Snapshot(
            runID: runID, phase: "preparing", selectedInstanceCount: 0,
            requestedPairCount: 0, processedPairCount: 0,
            exactPairCount: 0, meshPairCount: 0,
            interferingPairCount: 0, contactPairCount: 0,
            separatedPairCount: 0, unresolvedPairCount: 0,
            cancelled: false, startedAt: Date())
    }

    func begin(total: Int, selected: Int) {
        lock.lock()
        state.requestedPairCount = max(0, total)
        state.selectedInstanceCount = max(0, selected)
        state.phase = "checking"
        lock.unlock()
    }

    func recordPair(mode: String, classification: String) {
        lock.lock()
        state.processedPairCount += 1
        if mode.hasPrefix("brep") { state.exactPairCount += 1 }
        if mode == "mesh" { state.meshPairCount += 1 }
        switch classification {
        case "penetrating": state.interferingPairCount += 1
        case "contact": state.contactPairCount += 1
        case "separated": state.separatedPairCount += 1
        default: state.unresolvedPairCount += 1
        }
        lock.unlock()
    }

    func setPhase(_ phase: String) {
        lock.lock()
        state.phase = phase
        lock.unlock()
    }

    func requestCancel() {
        lock.lock()
        state.cancelled = true
        state.phase = "cancelling"
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state.cancelled
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return state
    }
}

@MainActor
final class CADAssemblyInterferenceRun {
    let id: UUID
    let documentKey: ObjectIdentifier
    let token: CADAssemblyKernelRevisionToken
    let progress: CADAssemblyInterferenceProgressBox
    private var worker: Task<CADAssemblyInterferenceWorkerResult, Never>?

    init(documentKey: ObjectIdentifier, token: CADAssemblyKernelRevisionToken) {
        self.id = UUID()
        self.documentKey = documentKey
        self.token = token
        self.progress = CADAssemblyInterferenceProgressBox(runID: id)
    }

    func attach(_ task: Task<CADAssemblyInterferenceWorkerResult, Never>) {
        worker = task
        if progress.isCancelled { task.cancel() }
    }

    func cancel() {
        progress.requestCancel()
        worker?.cancel()
    }
}

@MainActor
public final class CADAssemblyService {
    private let document: FloeCADDocument

    public init(document: FloeCADDocument) {
        self.document = document
    }

    /// One JSON-shaped action. See the action list in
    /// `docs/FLOE_CAD_AND_DRAWING_ASSISTANT.md`. Never throws.
    public func handle(action: String, args: [String: Any]) -> [String: Any] {
        guard !document.isClosed else {
            return fail("closed", "The CAD document is closed.")
        }
        if let refusal = CADServiceOperations.readOnlyRefusal(document: document, kind: "assembly", action: action) { return refusal }
        switch action {
        case "report": return reportAction()
        case "instances": return instancesAction()
        case "addInstance": return addInstanceAction(args)
        case "removeInstance": return removeInstanceAction(args)
        case "setTransform": return setTransformAction(args)
        case "setVisible": return setVisibleAction(args)
        case "addConstraint": return addConstraintAction(args)
        case "updateConstraint": return updateConstraintAction(args)
        case "removeConstraint": return removeConstraintAction(args)
        case "suppressConstraint": return suppressConstraintAction(args)
        case "solve": return solveAction()
        case "dof": return dofAction()
        case "interferencePlan": return interferencePlanAction(args)
        case "interferenceStatus": return interferenceStatusAction()
        case "cancelInterference": return cancelInterferenceAction()
        case "interference":
            return fail("needs_async",
                        "Exact interference runs the kernel off the main actor; "
                        + "call handleAsync(action:args:) instead.")
        case "sourceUpdate": return sourceUpdateAction(args)
        case "clear": return clearAction()
        case "hierarchy": return hierarchyAction()
        case "references", "referenceDiagnostics": return referencesAction()
        case "addSubassembly": return addSubassemblyAction(args)
        case "placePartReference": return placePartReferenceAction(args)
        case "moveInstance": return moveInstanceAction(args)
        case "removePartReference": return removePartReferenceAction(args)
        // `updatePartReference` (a metadata-only re-pin that accepted caller
        // hashes without reading the source) is deliberately NOT dispatched.
        // External source identity changes only through the App-owned
        // `CADAssemblyReferenceBridge`, which re-reads verified source bytes.
        case "makeIndependent": return makeIndependentAction(args)
        case "reference": return referenceAction(args)
        case "referenceCandidates": return referenceCandidatesAction(args)
        case "explodedViews": return explodedViewsAction()
        case "addExplodedView": return addExplodedViewAction(args)
        case "updateExplodedView": return updateExplodedViewAction(args)
        case "removeExplodedView": return removeExplodedViewAction(args)
        case "previewExplodedView": return previewExplodedViewAction(args)
        case "resetExplodedView": return resetExplodedViewAction(args)
        case "partMetadata": return partMetadataAction(args)
        case "setPartMetadata": return setPartMetadataAction(args)
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
        guard !document.isClosed else {
            return fail("closed", "The CAD document is closed.")
        }
        if let refusal = CADServiceOperations.readOnlyRefusal(document: document, kind: "assembly", action: action) { return refusal }
        guard action == "interference" else { return handle(action: action, args: args) }
        return await interferenceOffMain(args)
    }

    /// Current progress/pair counts of the one active inspection for this
    /// document, or nil when none is active. The service, not the UI, owns
    /// these counters; a tool caller can poll `interferenceStatus`.
    public func interferenceProgress() -> [String: Any]? {
        guard let run = Self.activeInterferenceRuns[ObjectIdentifier(document)] else {
            return nil
        }
        return progressPayload(run.progress.snapshot())
    }

    /// Request cancellation of the active inspection. The awaiting caller is
    /// released only after the detached worker observes the flag and returns;
    /// no partial result is accepted.
    public func cancelInterference() -> [String: Any] {
        let key = ObjectIdentifier(document)
        guard let run = Self.activeInterferenceRuns[key] else {
            return ["ok": true, "active": false, "cancelRequested": false, "mutated": false]
        }
        run.cancel()
        var payload = progressPayload(run.progress.snapshot())
        payload["ok"] = true
        payload["active"] = true
        payload["cancelRequested"] = true
        return payload
    }

    /// Closing the owner fences the existing run, including calls made through
    /// another facade. The awaiting caller still joins its serialized-copy
    /// worker before returning; a close never accepts those late results.
    static func cancelInterference(for document: FloeCADDocument) {
        activeInterferenceRuns[ObjectIdentifier(document)]?.cancel()
    }

    /// Test-only seam called inside the detached exact-interference worker so
    /// a suite can prove the kernel work ran off the main actor. Never set in
    /// production code.
    nonisolated(unsafe) static var testOffMainProbe: (@Sendable () -> Void)?

    /// Test-only progress seam. Called after every processed requested pair
    /// with the service-owned snapshot; it may block a suite that needs to
    /// cancel or mutate the document at a deterministic midpoint. Never set in
    /// production code.
    nonisolated(unsafe) static var testInterferencePairProbe:
        (@Sendable (CADAssemblyInterferenceProgressBox.Snapshot) -> Void)?

    private static var activeInterferenceRuns:
        [ObjectIdentifier: CADAssemblyInterferenceRun] = [:]

    /// Explicit result envelope for ALL completed pair details. It is below
    /// the runtime's 8 MiB per-result full-capture budget and far below the
    /// 64 MiB per-task capture quota, so a complete accepted result is retained
    /// and pageable without an intrinsic detail-row cap. A result that would
    /// exceed this envelope is refused atomically (`result_too_large`) with an
    /// actionable subset-selection message; it is never returned as
    /// `ok=true` with a dropped tail.
    public static let interferenceResultBudgetBytes = 6 * 1_024 * 1_024

    /// Digest basis for the complete detail arrays: SHA-256 over each row's
    /// canonical JSON (sorted keys, UTF-8) in returned order, one LF after
    /// each row. Recovery/paging can verify the exact retained bytes without
    /// re-running the kernel.
    public static let interferenceDetailDigestAlgorithm =
        "sha256-canonical-json-row-lf-v1"

    /// Test-only envelope override, used to prove honest refusal without
    /// allocating a six-megabyte result. Never set in production code.
    nonisolated(unsafe) static var testInterferenceResultBudgetBytes: Int?

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

    // MARK: - Interference planning and execution

    private struct InterferenceSelection {
        let occurrences: [CADAssemblyOccurrence]
        let requestedIDs: [UUID]?
    }

    private enum InterferenceSerializedBRep: Sendable {
        case data(Data)
        case failed
    }

    private func interferencePlanAction(_ args: [String: Any]) -> [String: Any] {
        let assembly: CADAssembly
        switch loadAssembly() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): assembly = loaded
        }
        let selection: InterferenceSelection
        switch resolveInterferenceSelection(assembly, args: args) {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let resolved): selection = resolved
        }
        let count = selection.occurrences.count
        let pairCount = count * (count - 1) / 2
        var payload: [String: Any] = [
            "ok": true,
            "mutated": false,
            "selectedInstanceCount": count,
            "selectedInstanceIDs": selection.occurrences.map { $0.instance.id.uuidString },
            "selectedNames": selection.occurrences.map(\.instance.name),
            "pairCount": pairCount,
            "units": "mm",
        ]
        if let requested = selection.requestedIDs {
            payload["requestedInstanceIDs"] = requested.map(\.uuidString)
        } else {
            payload["requestedInstanceIDs"] = NSNull()
        }
        return payload
    }

    private func interferenceStatusAction() -> [String: Any] {
        guard let run = Self.activeInterferenceRuns[ObjectIdentifier(document)] else {
            return ["ok": true, "active": false, "mutated": false]
        }
        var payload = progressPayload(run.progress.snapshot())
        payload["ok"] = true
        payload["active"] = true
        return payload
    }

    private func cancelInterferenceAction() -> [String: Any] {
        var payload = cancelInterference()
        payload["mutated"] = false
        return payload
    }

    private func interferenceOffMain(_ args: [String: Any]) async -> [String: Any] {
        let assembly: CADAssembly
        switch loadAssembly() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): assembly = loaded
        }

        let tolerance: Double
        if let raw = args["toleranceMM"], !(raw is NSNull) {
            guard let value = doubleValue(raw), value.isFinite, value >= 0 else {
                return fail("bad_tolerance",
                            "toleranceMM must be a finite, non-negative number of mm.")
            }
            tolerance = value
        } else {
            tolerance = 1e-6
        }
        // Distance/contact tolerance stays a LINEAR millimetre value. The
        // exact OCCT common volume is CUBIC and therefore has its own explicit
        // threshold; default 0 means any strictly positive common volume is a
        // real penetration regardless of the linear clearance tolerance.
        let volumeToleranceMM3: Double
        if let raw = args["volumeToleranceMM3"], !(raw is NSNull) {
            guard let value = doubleValue(raw), value.isFinite, value >= 0 else {
                return fail("bad_volume_tolerance",
                            "volumeToleranceMM3 must be a finite, non-negative number of mm³. "
                            + "Use 0 (the default) to report any strictly positive exact common volume.")
            }
            volumeToleranceMM3 = value
        } else {
            volumeToleranceMM3 = 0
        }
        // `detailLimit` was an intrinsic row cap that silently dropped the
        // tail of a completed result before the runtime could capture it.
        // Refuse it explicitly instead of silently rerouting it.
        if let legacy = args["detailLimit"], !(legacy is NSNull) {
            return fail(
                "deprecated_argument",
                "detailLimit was removed because it silently dropped completed pair details. "
                + "Every completed pair detail is now returned in full under the explicit "
                + "\(Self.interferenceResultBudgetBytes)-byte result envelope; the runtime's "
                + "existing capture paging exposes the retained text. Select a smaller instance "
                + "subset instead of truncating the result.")
        }
        let resultBudgetBytes = max(
            1_024,
            min(Self.interferenceResultBudgetBytes,
                Self.testInterferenceResultBudgetBytes ?? Self.interferenceResultBudgetBytes))

        let selection: InterferenceSelection
        switch resolveInterferenceSelection(assembly, args: args) {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let resolved): selection = resolved
        }

        let selected = selection.occurrences
        let pairCount = selected.count * (selected.count - 1) / 2
        if pairCount == 0 {
            let payload: [String: Any] = [
                "ok": true,
                "mutated": false,
                "mode": "selected-subset-all-pairs",
                "selectedInstanceCount": selected.count,
                "selectedInstanceIDs": selected.map { $0.instance.id.uuidString },
                "selectedNames": selected.map(\.instance.name),
                "pairCount": 0,
                "requestedPairCount": 0,
                "processedPairCount": 0,
                "interferingPairCount": 0,
                "contactPairCount": 0,
                "separatedPairCount": 0,
                "unresolvedPairCount": 0,
                "toleranceMM": tolerance,
                "volumeToleranceMM3": volumeToleranceMM3,
                "units": "mm",
                "interferences": [],
                "contacts": [],
                "clearances": [],
                "unresolvedPairs": [],
                "unresolvedInstances": [],
                "kernelRefusedPairs": [],
                "kernelExecutor": "serialized-copy-off-main",
                "resultBudgetBytes": resultBudgetBytes,
                "detailRowCount": 0,
                "detailBytes": 0,
                "detailsComplete": true,
                "detailDigest": Self.emptyDetailDigest,
                "detailDigestAlgorithm": Self.interferenceDetailDigestAlgorithm,
                "completed": true,
                "notes": ["fewer than two drawable instances were selected; there are no pairs to inspect"],
            ]
            guard let encoded = try? JSONSerialization.data(withJSONObject: payload,
                                                           options: [.sortedKeys]),
                  encoded.count <= resultBudgetBytes else {
                return interferenceBudgetFailure(
                    budget: resultBudgetBytes, requestedPairs: 0,
                    processedPairs: 0, selected: selected.count, progress: nil)
            }
            return payload
        }

        let token = CADAssemblyKernelRevisionToken(revision: document.store.revision,
                                                   changeCount: document.session.changeCount)
        let documentKey = ObjectIdentifier(document)
        let started = Self.beginInterferenceRun(documentKey: documentKey, token: token)
        if let busy = started.busy { return busy }
        guard let run = started.run else {
            return fail("interference_unavailable",
                        "The interference run could not be started.")
        }
        defer { Self.finishInterferenceRun(run) }

        var serialized: [CADAssemblyInterferenceGeometryKey: InterferenceSerializedBRep] = [:]
        var snapshots: [CADAssemblyInterferenceInstanceSnapshot] = []
        snapshots.reserveCapacity(selected.count)
        for occurrence in selected {
            snapshots.append(interferenceSnapshot(occurrence, serialized: &serialized))
        }
        // Reserve the payload's own identity/name/progress metadata before any
        // pair work. The worker enforces the remaining row budget pair by
        // pair, so a large assembly never materializes an unbounded pair plan
        // or an oversized detail array.
        let metadataAllowance = 16 * 1_024
            + snapshots.reduce(0) {
                $0 + $1.instanceID.uuidString.utf8.count + $1.name.utf8.count + 32
            }
            + (selection.requestedIDs?.reduce(0) {
                $0 + $1.uuidString.utf8.count + 8
            } ?? 0)
        let detailBudgetBytes = resultBudgetBytes - metadataAllowance
        guard detailBudgetBytes >= 4 * 1_024 else {
            return interferenceBudgetFailure(
                budget: resultBudgetBytes, requestedPairs: pairCount,
                processedPairs: 0, selected: snapshots.count, progress: nil)
        }
        run.progress.begin(total: pairCount, selected: snapshots.count)

        if run.progress.isCancelled || Task.isCancelled {
            run.progress.setPhase("cancelled")
            return interferenceFailure("cancelled",
                                       "The interference check was cancelled before it started; "
                                       + "no result was used.",
                                       progress: run.progress.snapshot())
        }

        let box = run.progress
        let offMainProbe = Self.testOffMainProbe
        let pairProbe = Self.testInterferencePairProbe
        let worker = Task.detached(priority: .userInitiated) {
            offMainProbe?()
            return Self.runInterferenceWorker(
                snapshots: snapshots, toleranceMM: tolerance,
                volumeToleranceMM3: volumeToleranceMM3,
                detailBudgetBytes: detailBudgetBytes,
                progress: box, pairProbe: pairProbe)
        }
        run.attach(worker)

        let result = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            box.requestCancel()
            worker.cancel()
        }

        guard !document.isClosed else {
            box.setPhase("closed")
            return interferenceFailure("closed",
                                       "The document closed during the interference check; no result was used.",
                                       progress: box.snapshot())
        }
        if box.isCancelled || Task.isCancelled {
            box.setPhase("cancelled")
            return interferenceFailure("cancelled",
                                       "The interference check was cancelled and its worker joined; "
                                       + "no partial result was used.",
                                       progress: box.snapshot())
        }
        let current = CADAssemblyKernelRevisionToken(revision: document.store.revision,
                                                     changeCount: document.session.changeCount)
        guard current == token else {
            box.setPhase("stale")
            return interferenceFailure("stale",
                                       "The document changed while the interference check ran; "
                                       + "the old result was rejected. Re-run it against the current revision.",
                                       progress: box.snapshot())
        }
        if result.detailEncodingFailed {
            box.setPhase("refused")
            return interferenceFailure(
                "detail_encoding_failed",
                "A completed pair detail could not be encoded as finite JSON. No partial result "
                + "was returned; report this as a service defect rather than a geometry result.",
                progress: box.snapshot())
        }
        if result.budgetExceeded {
            box.setPhase("result_too_large")
            return interferenceBudgetFailure(
                budget: resultBudgetBytes, requestedPairs: pairCount,
                processedPairs: box.snapshot().processedPairCount,
                selected: snapshots.count, progress: box.snapshot())
        }
        box.setPhase("completed")

        var interferences: [[String: Any]] = []
        var contacts: [[String: Any]] = []
        var clearances: [[String: Any]] = []
        var unresolved: [[String: Any]] = []
        var kernelRefused: [[String]] = []
        var missingInstances: [String] = []
        var belowVolumeThresholdPairCount = 0
        for snapshot in snapshots {
            if snapshot.missingReason != nil {
                missingInstances.append(snapshot.instanceID.uuidString)
            }
        }
        for outcome in result.outcomes {
            let entry = Self.interferenceEntry(outcome)
            switch outcome.classification {
            case "penetrating": interferences.append(entry)
            case "contact": contacts.append(entry)
            case "separated": clearances.append(entry)
            default: unresolved.append(entry)
            }
            if outcome.volumeBelowThreshold == true {
                belowVolumeThresholdPairCount += 1
            }
            if outcome.kernelRefused {
                kernelRefused.append([outcome.a.uuidString, outcome.b.uuidString])
            }
        }
        interferences.sort {
            let left = ($0["volumeMM3"] as? Double) ?? 0
            let right = ($1["volumeMM3"] as? Double) ?? 0
            if left != right { return left > right }
            return pairKey($0) < pairKey($1)
        }
        contacts.sort { pairKey($0) < pairKey($1) }
        clearances.sort {
            let left = ($0["minimumDistanceMM"] as? Double) ?? .infinity
            let right = ($1["minimumDistanceMM"] as? Double) ?? .infinity
            if left != right { return left < right }
            return pairKey($0) < pairKey($1)
        }
        unresolved.sort { pairKey($0) < pairKey($1) }
        kernelRefused.sort { $0.joined(separator: ":") < $1.joined(separator: ":") }

        // The complete detail arrays ARE the retained truth. No prefix page is
        // substituted for them, and no per-list truncation flag exists.
        let detailRows = interferences + contacts + clearances + unresolved
        guard let detailEnvelope = Self.detailEnvelope(rows: detailRows) else {
            box.setPhase("refused")
            return interferenceFailure(
                "detail_encoding_failed",
                "A completed pair detail could not be encoded as finite JSON. No partial result "
                + "was returned; report this as a service defect rather than a geometry result.",
                progress: box.snapshot())
        }
        let snapshot = box.snapshot()

        var payload: [String: Any] = [
            "ok": true,
            "mutated": false,
            "completed": true,
            "mode": "selected-subset-all-pairs",
            "selectedInstanceCount": snapshots.count,
            "selectedInstanceIDs": snapshots.map { $0.instanceID.uuidString },
            "selectedNames": snapshots.map(\.name),
            "pairCount": pairCount,
            "requestedPairCount": pairCount,
            "processedPairCount": snapshot.processedPairCount,
            "exactPairCount": snapshot.exactPairCount,
            "meshPairCount": snapshot.meshPairCount,
            "interferingPairCount": snapshot.interferingPairCount,
            "contactPairCount": snapshot.contactPairCount,
            "separatedPairCount": snapshot.separatedPairCount,
            "unresolvedPairCount": snapshot.unresolvedPairCount,
            "belowVolumeThresholdPairCount": belowVolumeThresholdPairCount,
            "toleranceMM": tolerance,
            "volumeToleranceMM3": volumeToleranceMM3,
            "units": "mm",
            "interferences": interferences,
            "contacts": contacts,
            "clearances": clearances,
            "unresolvedPairs": unresolved,
            "unresolvedInstances": Array(Set(missingInstances)).sorted(),
            "kernelRefusedPairs": kernelRefused,
            "kernelExecutor": "serialized-copy-off-main",
            "progress": progressPayload(snapshot),
            "resultBudgetBytes": resultBudgetBytes,
            "detailRowCount": detailRows.count,
            "detailBytes": detailEnvelope.bytes,
            "detailsComplete": true,
            "detailDigest": detailEnvelope.digest,
            "detailDigestAlgorithm": Self.interferenceDetailDigestAlgorithm,
            "precision": [
                "units": "mm",
                "basis": "Float render-mesh vertices, Double triangle distances; "
                    + "tessellation chord error is not stored in the mesh and is not included.",
            ],
            "notes": [
                "Every requested pair was processed exactly once; progress counts come from the service.",
                "Exact OCCT regularized common volume is used when both instances carry a B-rep. "
                    + "The cubic common volume is compared with volumeToleranceMM3 (default 0, "
                    + "strictly positive), never with the linear toleranceMM.",
                "A positive exact common volume below an explicit volumeToleranceMM3 is still reported "
                    + "with its actual volume and volumeBelowThreshold=true; it is never rewritten as "
                    + "noSharedVolume or separated.",
                "Otherwise minimum surface distance and contact/containment come from the render triangles; "
                    + "AABB is broadphase only.",
                "The four detail arrays are complete; the runtime's existing capture/paging may present "
                    + "a bounded window of these same retained bytes.",
            ],
        ]
        if let requested = selection.requestedIDs {
            payload["requestedInstanceIDs"] = requested.map(\.uuidString)
        }
        // Verify the actual encoded service reply against the explicit
        // envelope before accepting. A metadata-heavy selection can still
        // exceed the envelope; it refuses atomically instead of shipping a
        // result that the runtime capture would truncate.
        guard let encoded = try? JSONSerialization.data(withJSONObject: payload,
                                                       options: [.sortedKeys]),
              encoded.count <= resultBudgetBytes else {
            box.setPhase("result_too_large")
            return interferenceBudgetFailure(
                budget: resultBudgetBytes, requestedPairs: pairCount,
                processedPairs: snapshot.processedPairCount,
                selected: snapshots.count, progress: snapshot)
        }
        // Include the reply's own exact encoded size in the receipt. Iterate
        // to a fixed point because the decimal value itself adds bytes.
        var resultBytes = encoded.count
        for _ in 0..<4 {
            payload["resultBytes"] = resultBytes
            guard let receiptEncoded = try? JSONSerialization.data(
                    withJSONObject: payload, options: [.sortedKeys]),
                  receiptEncoded.count <= resultBudgetBytes else {
                box.setPhase("result_too_large")
                return interferenceBudgetFailure(
                    budget: resultBudgetBytes, requestedPairs: pairCount,
                    processedPairs: snapshot.processedPairCount,
                    selected: snapshots.count, progress: snapshot)
            }
            if receiptEncoded.count == resultBytes { return payload }
            resultBytes = receiptEncoded.count
        }
        box.setPhase("result_too_large")
        return interferenceBudgetFailure(
            budget: resultBudgetBytes, requestedPairs: pairCount,
            processedPairs: snapshot.processedPairCount,
            selected: snapshots.count, progress: snapshot)
    }

    /// Honest refusal when the complete detail result cannot fit the explicit
    /// envelope. It never contains accepted detail rows: `ok=false` and
    /// `detailsComplete=false` are the whole result.
    private func interferenceBudgetFailure(
        budget: Int, requestedPairs: Int, processedPairs: Int,
        selected: Int, progress: CADAssemblyInterferenceProgressBox.Snapshot?
    ) -> [String: Any] {
        var payload = fail(
            "result_too_large",
            "The COMPLETE pair-detail result cannot fit the explicit \(budget)-byte result "
            + "envelope (below the runtime's 8 MiB full-capture budget), so no partial rows "
            + "were accepted. Select fewer instances; for example use assembly.interferencePlan "
            + "to split the requested set into smaller subsets and run them separately.")
        payload["mutated"] = false
        payload["completed"] = false
        payload["cancelled"] = false
        payload["detailsComplete"] = false
        payload["resultBudgetBytes"] = budget
        payload["requestedPairCount"] = requestedPairs
        payload["processedPairCount"] = processedPairs
        payload["selectedInstanceCount"] = selected
        if let progress { payload["progress"] = progressPayload(progress) }
        return payload
    }

    private func pairKey(_ row: [String: Any]) -> String {
        "\(row["a"] as? String ?? ""):\(row["b"] as? String ?? "")"
    }

    private static let emptyDetailDigest: String = {
        SHA256.hash(data: Data())
            .map { String(format: "%02x", $0) }
            .joined()
    }()

    /// Canonical bytes and digest of the COMPLETE detail arrays. The digest is
    /// SHA-256 over each row's sorted-key JSON plus one LF, in returned order.
    private nonisolated static func detailEnvelope(rows: [[String: Any]])
        -> (digest: String, bytes: Int)? {
        var hasher = SHA256()
        var bytes = 0
        for row in rows {
            guard JSONSerialization.isValidJSONObject(row),
                  let data = try? JSONSerialization.data(
                    withJSONObject: row, options: [.sortedKeys]) else {
                return nil
            }
            hasher.update(data: data)
            hasher.update(data: Data([0x0A]))
            bytes += data.count + 1
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (digest, bytes)
    }

    private nonisolated static func encodedDetailRowBytes(_ row: [String: Any]) -> Int? {
        guard JSONSerialization.isValidJSONObject(row),
              let data = try? JSONSerialization.data(
                withJSONObject: row, options: [.sortedKeys]) else {
            return nil
        }
        return data.count + 1
    }

    private func interferenceFailure(_ code: String, _ message: String,
                                     progress: CADAssemblyInterferenceProgressBox.Snapshot)
        -> [String: Any] {
        var payload = fail(code, message)
        payload["mutated"] = false
        payload["completed"] = false
        payload["cancelled"] = code == "cancelled"
        payload["detailsComplete"] = false
        payload["processedPairCount"] = progress.processedPairCount
        payload["requestedPairCount"] = progress.requestedPairCount
        payload["progress"] = progressPayload(progress)
        return payload
    }

    private func progressPayload(_ snapshot: CADAssemblyInterferenceProgressBox.Snapshot)
        -> [String: Any] {
        let elapsed = max(0, Date().timeIntervalSince(snapshot.startedAt) * 1000)
        var payload: [String: Any] = [
            "runID": snapshot.runID.uuidString,
            "phase": snapshot.phase,
            "selectedInstanceCount": snapshot.selectedInstanceCount,
            "requestedPairCount": snapshot.requestedPairCount,
            "processedPairCount": snapshot.processedPairCount,
            "exactPairCount": snapshot.exactPairCount,
            "meshPairCount": snapshot.meshPairCount,
            "interferingPairCount": snapshot.interferingPairCount,
            "contactPairCount": snapshot.contactPairCount,
            "separatedPairCount": snapshot.separatedPairCount,
            "unresolvedPairCount": snapshot.unresolvedPairCount,
            "cancelled": snapshot.cancelled,
            "elapsedMilliseconds": elapsed,
            "startedAt": ISO8601DateFormatter().string(from: snapshot.startedAt),
        ]
        if snapshot.requestedPairCount > 0 {
            payload["fraction"] = min(1, max(0,
                Double(snapshot.processedPairCount) / Double(snapshot.requestedPairCount)))
        } else {
            payload["fraction"] = 0
        }
        return payload
    }

    private func resolveInterferenceSelection(_ assembly: CADAssembly, args: [String: Any])
        -> Result<InterferenceSelection, CADAssemblyServiceError> {
        let raw = args["instanceIDs"] ?? args["instanceIds"]
        var requested: [UUID]? = nil
        if let raw, !(raw is NSNull) {
            var ids: [UUID] = []
            if let values = raw as? [String] {
                for value in values {
                    guard let id = UUID(uuidString: value) else {
                        return .failure(CADAssemblyServiceError(
                            code: "bad_instance_id",
                            message: "instanceIDs must be an array of instance UUID strings."))
                    }
                    ids.append(id)
                }
            } else if let values = raw as? [UUID] {
                ids = values
            } else if let values = raw as? [Any] {
                for value in values {
                    guard let id = uuidValue(value) else {
                        return .failure(CADAssemblyServiceError(
                            code: "bad_instance_id",
                            message: "instanceIDs must be an array of instance UUID strings."))
                    }
                    ids.append(id)
                }
            } else if let id = uuidValue(raw) {
                ids = [id]
            } else {
                return .failure(CADAssemblyServiceError(
                    code: "bad_instance_id",
                    message: "instanceIDs must be an array of instance UUID strings."))
            }
            requested = ids
        }

        let all = assembly.occurrences(includeHidden: true)
        var byID: [UUID: CADAssemblyOccurrence] = [:]
        for occurrence in all {
            byID[occurrence.instance.id] = occurrence
        }

        let selectedIDs: Set<UUID>
        if let requested {
            var resolved = Set<UUID>()
            for id in requested {
                guard let occurrence = byID[id] else {
                    return .failure(CADAssemblyServiceError(
                        code: "unknown_instance",
                        message: "No assembly occurrence has id \(id.uuidString)."))
                }
                if occurrence.instance.isSubassembly {
                    for descendant in all
                        where descendant.isDrawablePart
                        && descendant.path.contains(id) {
                        resolved.insert(descendant.instance.id)
                    }
                } else if occurrence.isDrawablePart {
                    resolved.insert(id)
                }
            }
            selectedIDs = resolved
        } else {
            selectedIDs = Set(all.filter(\.isDrawablePart).map(\.instance.id))
        }
        let occurrences = all.filter {
            $0.isDrawablePart && selectedIDs.contains($0.instance.id)
        }
        return .success(InterferenceSelection(occurrences: occurrences,
                                              requestedIDs: requested))
    }

    private func interferenceSnapshot(
        _ occurrence: CADAssemblyOccurrence,
        serialized: inout [CADAssemblyInterferenceGeometryKey: InterferenceSerializedBRep]
    ) -> CADAssemblyInterferenceInstanceSnapshot {
        guard let bodyID = occurrence.effectiveBodyID else {
            return CADAssemblyInterferenceInstanceSnapshot(
                instanceID: occurrence.instance.id, name: occurrence.instance.name,
                bodyID: nil, geometryKey: nil, placement: .identity,
                positions: [], indices: [], brepData: nil, brepUnavailable: false,
                missingReason: "the occurrence has no drawable body")
        }
        guard let body = body(for: bodyID) else {
            return CADAssemblyInterferenceInstanceSnapshot(
                instanceID: occurrence.instance.id, name: occurrence.instance.name,
                bodyID: bodyID, geometryKey: nil, placement: .identity,
                positions: [], indices: [], brepData: nil, brepUnavailable: false,
                missingReason: "the occurrence references a body that is not in the document")
        }
        guard CADAssemblySolver.isValidTransform(occurrence.worldTransform) else {
            return CADAssemblyInterferenceInstanceSnapshot(
                instanceID: occurrence.instance.id, name: occurrence.instance.name,
                bodyID: bodyID, geometryKey: nil, placement: .identity,
                positions: [], indices: [], brepData: nil, brepUnavailable: false,
                missingReason: "the occurrence placement is not a finite uniform transform")
        }
        let placed = CADAssemblySolver.transform3D(from: occurrence.worldTransform)
            .composed(onto: body.transform)
        guard placed.scale.isFinite, placed.scale > 0,
              placed.translation.x.isFinite, placed.translation.y.isFinite,
              placed.translation.z.isFinite,
              placed.rotation.imag.x.isFinite, placed.rotation.imag.y.isFinite,
              placed.rotation.imag.z.isFinite, placed.rotation.real.isFinite else {
            return CADAssemblyInterferenceInstanceSnapshot(
                instanceID: occurrence.instance.id, name: occurrence.instance.name,
                bodyID: bodyID, geometryKey: nil, placement: .identity,
                positions: [], indices: [], brepData: nil, brepUnavailable: false,
                missingReason: "the composed body placement is not finite")
        }
        let placement = CADInterferenceTransform(
            rotation: placed.rotation, scale: placed.scale,
            translation: placed.translation)
        let key = CADAssemblyInterferenceGeometryKey(
            bodyID: bodyID, meshRevision: body.meshRevision)
        var brepData: Data?
        var brepUnavailable = false
        if let brep = body.brep {
            switch serialized[key] {
            case .some(.data(let data)):
                brepData = data
            case .some(.failed):
                brepUnavailable = true
            case .none:
                if let data = OCCTKernel.serialize(brep) {
                    serialized[key] = .data(data)
                    brepData = data
                } else {
                    serialized[key] = .failed
                    brepUnavailable = true
                }
            }
        }
        return CADAssemblyInterferenceInstanceSnapshot(
            instanceID: occurrence.instance.id, name: occurrence.instance.name,
            bodyID: bodyID, geometryKey: key, placement: placement,
            positions: body.render.positions, indices: body.render.indices,
            brepData: brepData, brepUnavailable: brepUnavailable,
            missingReason: nil)
    }

    private static func beginInterferenceRun(
        documentKey: ObjectIdentifier,
        token: CADAssemblyKernelRevisionToken
    ) -> (run: CADAssemblyInterferenceRun?, busy: [String: Any]?) {
        if let active = activeInterferenceRuns[documentKey] {
            var busy = ["ok": false,
                        "error": "interference_busy",
                        "mutated": false,
                        "message": "An interference check is already running for this document; "
                            + "cancel it before starting another."] as [String: Any]
            busy["progress"] = progressPayloadStatic(active.progress.snapshot())
            return (nil, busy)
        }
        let run = CADAssemblyInterferenceRun(documentKey: documentKey, token: token)
        activeInterferenceRuns[documentKey] = run
        return (run, nil)
    }

    private static func finishInterferenceRun(_ run: CADAssemblyInterferenceRun) {
        if activeInterferenceRuns[run.documentKey]?.id == run.id {
            activeInterferenceRuns.removeValue(forKey: run.documentKey)
        }
    }

    private static func progressPayloadStatic(
        _ snapshot: CADAssemblyInterferenceProgressBox.Snapshot
    ) -> [String: Any] {
        let elapsed = max(0, Date().timeIntervalSince(snapshot.startedAt) * 1000)
        var payload: [String: Any] = [
            "runID": snapshot.runID.uuidString,
            "phase": snapshot.phase,
            "selectedInstanceCount": snapshot.selectedInstanceCount,
            "requestedPairCount": snapshot.requestedPairCount,
            "processedPairCount": snapshot.processedPairCount,
            "exactPairCount": snapshot.exactPairCount,
            "meshPairCount": snapshot.meshPairCount,
            "interferingPairCount": snapshot.interferingPairCount,
            "contactPairCount": snapshot.contactPairCount,
            "separatedPairCount": snapshot.separatedPairCount,
            "unresolvedPairCount": snapshot.unresolvedPairCount,
            "cancelled": snapshot.cancelled,
            "elapsedMilliseconds": elapsed,
            "startedAt": ISO8601DateFormatter().string(from: snapshot.startedAt),
        ]
        if snapshot.requestedPairCount > 0 {
            payload["fraction"] = min(1, max(0,
                Double(snapshot.processedPairCount) / Double(snapshot.requestedPairCount)))
        } else {
            payload["fraction"] = 0
        }
        return payload
    }

    private nonisolated static func runInterferenceWorker(
        snapshots: [CADAssemblyInterferenceInstanceSnapshot],
        toleranceMM: Double,
        volumeToleranceMM3: Double,
        detailBudgetBytes: Int,
        progress: CADAssemblyInterferenceProgressBox,
        pairProbe: (@Sendable (CADAssemblyInterferenceProgressBox.Snapshot) -> Void)?
    ) -> CADAssemblyInterferenceWorkerResult {
        var geometries: [CADAssemblyInterferenceGeometryKey: CADInterferenceMeshGeometry] = [:]
        var outcomes: [CADAssemblyInterferencePairOutcome] = []
        // Do not reserve from a caller-controlled all-pairs count: the array
        // grows only while the encoded detail budget admits the next row.
        outcomes.reserveCapacity(min(1_024, snapshots.count * 2))
        var detailBytes = 0

        func geometry(for snapshot: CADAssemblyInterferenceInstanceSnapshot)
            -> CADInterferenceMeshGeometry? {
            guard let key = snapshot.geometryKey else { return nil }
            if let existing = geometries[key] { return existing }
            let built = CADInterferenceMeshGeometry.build(
                positions: snapshot.positions, indices: snapshot.indices)
            geometries[key] = built
            return built
        }

        func refused(_ cancelled: Bool, _ budgetExceeded: Bool,
                     _ encodingFailed: Bool) -> CADAssemblyInterferenceWorkerResult {
            CADAssemblyInterferenceWorkerResult(
                outcomes: [], cancelled: cancelled,
                budgetExceeded: budgetExceeded,
                detailEncodingFailed: encodingFailed,
                detailBytes: detailBytes)
        }

        for i in 0..<snapshots.count {
            for j in (i + 1)..<snapshots.count {
                if progress.isCancelled || Task.isCancelled {
                    return refused(true, false, false)
                }
                let a = snapshots[i]
                let b = snapshots[j]
                let outcome = interferencePairOutcome(
                    a: a, b: b, geometryA: geometry(for: a), geometryB: geometry(for: b),
                    toleranceMM: toleranceMM, volumeToleranceMM3: volumeToleranceMM3)
                // Account the exact canonical row bytes before accepting. A
                // row that would push the complete envelope over budget
                // refuses the WHOLE result atomically.
                let row = Self.interferenceEntry(outcome)
                guard let rowBytes = encodedDetailRowBytes(row) else {
                    return refused(false, false, true)
                }
                guard detailBytes + rowBytes <= detailBudgetBytes else {
                    return refused(false, true, false)
                }
                detailBytes += rowBytes
                outcomes.append(outcome)
                progress.recordPair(mode: outcome.mode, classification: outcome.classification)
                pairProbe?(progress.snapshot())
                if progress.isCancelled || Task.isCancelled {
                    return refused(true, false, false)
                }
            }
        }
        return CADAssemblyInterferenceWorkerResult(
            outcomes: outcomes, cancelled: false,
            budgetExceeded: false, detailEncodingFailed: false,
            detailBytes: detailBytes)
    }

    private nonisolated static func interferencePairOutcome(
        a: CADAssemblyInterferenceInstanceSnapshot,
        b: CADAssemblyInterferenceInstanceSnapshot,
        geometryA: CADInterferenceMeshGeometry?,
        geometryB: CADInterferenceMeshGeometry?,
        toleranceMM: Double,
        volumeToleranceMM3: Double
    ) -> CADAssemblyInterferencePairOutcome {
        if let reason = a.missingReason ?? b.missingReason {
            return baseOutcome(a: a, b: b, mode: "unresolved", classification: "unresolved",
                               exactVolume: false, notes: [reason],
                               unresolvedReason: reason)
        }
        guard let geometryA, let geometryB else {
            let reason = "one instance has no usable mesh geometry"
            return baseOutcome(a: a, b: b, mode: "unresolved", classification: "unresolved",
                               exactVolume: false, notes: [reason],
                               unresolvedReason: reason)
        }
        let placedA = CADInterferencePlacedMesh(geometry: geometryA, placement: a.placement)
        let placedB = CADInterferencePlacedMesh(geometry: geometryB, placement: b.placement)
        let worldA = geometryA.bounds.transformed(by: a.placement)
        let worldB = geometryB.bounds.transformed(by: b.placement)
        let aabbGap = sqrt(max(0, worldA.distanceSquared(to: worldB)))
        let overlapVolume = worldA.overlapVolume(with: worldB)
        let broadphaseOverlap = worldA.overlaps(worldB, tolerance: toleranceMM)

        if let dataA = a.brepData, let dataB = b.brepData,
           !a.brepUnavailable, !b.brepUnavailable {
            if geometryA.isValid, geometryB.isValid, !broadphaseOverlap {
                return baseOutcome(
                    a: a, b: b, mode: "brep-exact", classification: "separated",
                    exactVolume: true, volumeMM3: 0,
                    volumeThresholdMM3: volumeToleranceMM3,
                    volumeBelowThreshold: false,
                    volumeClassification: "no_positive_common_volume",
                    aabbGapMM: aabbGap, aabbOverlapVolumeMM3: 0,
                    notes: ["AABB separation proves no shared solid; the exact common was not run"])
            }
            guard let handleA = OCCTKernel.deserialize(dataA),
                  let handleB = OCCTKernel.deserialize(dataB) else {
                let mesh = CADInterferenceGeometry.surfacePair(
                    a: placedA, b: placedB, toleranceMM: toleranceMM)
                return meshOutcome(
                    a: a, b: b, mesh: mesh, aabbGapMM: aabbGap,
                    overlapVolumeMM3: overlapVolume,
                    notes: ["the serialized B-rep could not be reopened off-main; "
                            + "the render-mesh result is labelled approximate"])
            }
            switch OCCTKernel.booleanResult(handleA, handleB, op: 2) {
            case .success(let booleanOutcome):
                let volume = OCCTKernel.volume(booleanOutcome.handle)
                guard volume.isFinite else {
                    let mesh = CADInterferenceGeometry.surfacePair(
                        a: placedA, b: placedB, toleranceMM: toleranceMM)
                    return meshOutcome(
                        a: a, b: b, mesh: mesh, mode: "brep-exact-failed",
                        classification: "unresolved", exactVolume: true,
                        aabbGapMM: aabbGap, overlapVolumeMM3: overlapVolume,
                        unresolvedReason: "OCCT returned a non-finite common volume",
                        notes: ["the exact result is unresolved, not a claim of no shared volume"])
                }
                // CUBIC common volume vs CUBIC threshold. Never compare it
                // with the LINEAR contact/clearance tolerance.
                if volume > 0 {
                    let belowThreshold = volume < volumeToleranceMM3
                    var notes = ["exact OCCT regularized common volume"]
                    if belowThreshold {
                        notes.append(
                            "positive common volume is below the explicit volumeToleranceMM3; "
                            + "it is reported with its actual volume belowThreshold=true, "
                            + "never as noSharedVolume or separated")
                    }
                    return baseOutcome(
                        a: a, b: b, mode: "brep-exact", classification: "penetrating",
                        exactVolume: true, volumeMM3: volume,
                        volumeThresholdMM3: volumeToleranceMM3,
                        volumeBelowThreshold: belowThreshold,
                        volumeClassification: belowThreshold
                            ? "positive_common_below_threshold"
                            : "positive_common_at_or_above_threshold",
                        minimumDistanceMM: 0,
                        aabbGapMM: aabbGap, aabbOverlapVolumeMM3: overlapVolume,
                        notes: notes)
                }
                let mesh = CADInterferenceGeometry.surfacePair(
                    a: placedA, b: placedB, toleranceMM: toleranceMM)
                let contact = (mesh.minimumDistanceMM ?? .infinity) <= toleranceMM
                return meshOutcome(
                    a: a, b: b, mesh: mesh, mode: "brep-exact-empty-common",
                    classification: contact ? "contact" : "separated",
                    exactVolume: true, volumeMM3: max(0, volume),
                    volumeThresholdMM3: volumeToleranceMM3,
                    volumeBelowThreshold: false,
                    volumeClassification: "no_positive_common_volume",
                    aabbGapMM: aabbGap, overlapVolumeMM3: overlapVolume,
                    kernelRefused: false,
                    notes: ["the exact common has no positive volume; "
                            + "surface distance comes from the render triangles"])
            case .failure(let error):
                if case .kernelRefused(let detail) = error,
                   detail == "the operation leaves no solid" {
                    let mesh = CADInterferenceGeometry.surfacePair(
                        a: placedA, b: placedB, toleranceMM: toleranceMM)
                    let contact = (mesh.minimumDistanceMM ?? .infinity) <= toleranceMM
                    return meshOutcome(
                        a: a, b: b, mesh: mesh, mode: "brep-exact-empty-common",
                        classification: contact ? "contact" : "separated",
                        exactVolume: true, volumeMM3: 0,
                        volumeThresholdMM3: volumeToleranceMM3,
                        volumeBelowThreshold: false,
                        volumeClassification: "no_positive_common_volume",
                        aabbGapMM: aabbGap, overlapVolumeMM3: overlapVolume,
                        kernelRefused: true,
                        notes: ["OCCT reports a regularized common with no solid; "
                                + "this is not treated as a generic kernel error"])
                }
                let mesh = CADInterferenceGeometry.surfacePair(
                    a: placedA, b: placedB, toleranceMM: toleranceMM)
                return meshOutcome(
                    a: a, b: b, mesh: mesh, mode: "brep-exact-failed",
                    classification: "unresolved", exactVolume: true,
                    aabbGapMM: aabbGap, overlapVolumeMM3: overlapVolume,
                    unresolvedReason: "OCCT exact common failed: \(error.message)",
                    notes: ["the exact result is unresolved, not a claim of no shared volume"],
                    kernelErrorDetail: error.message)
            }
        }

        let mesh = CADInterferenceGeometry.surfacePair(
            a: placedA, b: placedB, toleranceMM: toleranceMM)
        return meshOutcome(
            a: a, b: b, mesh: mesh, aabbGapMM: aabbGap,
            overlapVolumeMM3: overlapVolume,
            notes: a.brepUnavailable || b.brepUnavailable
                ? ["a B-rep could not be serialized; the render-mesh result is labelled approximate"]
                : [])
    }

    private nonisolated static func meshOutcome(
        a: CADAssemblyInterferenceInstanceSnapshot,
        b: CADAssemblyInterferenceInstanceSnapshot,
        mesh: CADInterferenceMeshPairResult,
        mode: String = "mesh",
        classification: String? = nil,
        exactVolume: Bool = false,
        volumeMM3: Double? = nil,
        volumeThresholdMM3: Double? = nil,
        volumeBelowThreshold: Bool? = nil,
        volumeClassification: String? = nil,
        aabbGapMM: Double?,
        overlapVolumeMM3: Double?,
        kernelRefused: Bool = false,
        unresolvedReason: String? = nil,
        notes: [String] = [],
        kernelErrorDetail: String? = nil
    ) -> CADAssemblyInterferencePairOutcome {
        var combinedNotes = notes
        combinedNotes.append(contentsOf: mesh.notes)
        let resolvedClassification = classification ?? mesh.classification.rawValue
        return CADAssemblyInterferencePairOutcome(
            a: a.instanceID, b: b.instanceID, mode: mode,
            classification: resolvedClassification, exactVolume: exactVolume,
            volumeMM3: volumeMM3, volumeThresholdMM3: volumeThresholdMM3,
            volumeBelowThreshold: volumeBelowThreshold,
            volumeClassification: volumeClassification,
            minimumDistanceMM: mesh.minimumDistanceMM,
            precisionMM: mesh.precisionMM, witnessA: mesh.witnessAWorld,
            witnessB: mesh.witnessBWorld, triangleA: mesh.triangleA,
            triangleB: mesh.triangleB, surfaceCrossing: mesh.surfaceCrossing,
            surfaceTouching: mesh.surfaceTouching, containment: mesh.containment,
            aabbGapMM: aabbGapMM, aabbOverlapVolumeMM3: overlapVolumeMM3,
            topologyA: mesh.topologyA, topologyB: mesh.topologyB,
            notes: combinedNotes,
            unresolvedReason: unresolvedReason ?? mesh.unresolvedReason,
            kernelRefused: kernelRefused, kernelErrorDetail: kernelErrorDetail)
    }

    private nonisolated static func baseOutcome(
        a: CADAssemblyInterferenceInstanceSnapshot,
        b: CADAssemblyInterferenceInstanceSnapshot,
        mode: String,
        classification: String,
        exactVolume: Bool,
        volumeMM3: Double? = nil,
        volumeThresholdMM3: Double? = nil,
        volumeBelowThreshold: Bool? = nil,
        volumeClassification: String? = nil,
        minimumDistanceMM: Double? = nil,
        aabbGapMM: Double? = nil,
        aabbOverlapVolumeMM3: Double? = nil,
        notes: [String] = [],
        unresolvedReason: String? = nil,
        kernelRefused: Bool = false,
        kernelErrorDetail: String? = nil
    ) -> CADAssemblyInterferencePairOutcome {
        CADAssemblyInterferencePairOutcome(
            a: a.instanceID, b: b.instanceID, mode: mode,
            classification: classification, exactVolume: exactVolume,
            volumeMM3: volumeMM3, volumeThresholdMM3: volumeThresholdMM3,
            volumeBelowThreshold: volumeBelowThreshold,
            volumeClassification: volumeClassification,
            minimumDistanceMM: minimumDistanceMM,
            precisionMM: nil, witnessA: nil, witnessB: nil,
            triangleA: nil, triangleB: nil, surfaceCrossing: false,
            surfaceTouching: false, containment: "none",
            aabbGapMM: aabbGapMM, aabbOverlapVolumeMM3: aabbOverlapVolumeMM3,
            topologyA: nil, topologyB: nil, notes: notes,
            unresolvedReason: unresolvedReason, kernelRefused: kernelRefused,
            kernelErrorDetail: kernelErrorDetail)
    }

    private nonisolated static func interferenceEntry(
        _ outcome: CADAssemblyInterferencePairOutcome
    ) -> [String: Any] {
        var row: [String: Any] = [
            "a": outcome.a.uuidString,
            "b": outcome.b.uuidString,
            "classification": outcome.classification,
            "exact": outcome.exactVolume,
            "approximation": outcome.mode.hasPrefix("brep")
                ? "brep" : (outcome.mode == "mesh" ? "mesh" : "none"),
            "method": outcome.mode,
            "units": "mm",
        ]
        if let volume = outcome.volumeMM3, volume.isFinite {
            row["volumeMM3"] = volume
        }
        if let threshold = outcome.volumeThresholdMM3, threshold.isFinite {
            row["volumeThresholdMM3"] = threshold
        }
        if let below = outcome.volumeBelowThreshold {
            row["volumeBelowThreshold"] = below
        }
        if let volumeClass = outcome.volumeClassification {
            row["volumeClassification"] = volumeClass
        }
        if let distance = outcome.minimumDistanceMM, distance.isFinite {
            row["minimumDistanceMM"] = distance
        }
        if let precision = outcome.precisionMM, precision.isFinite {
            row["precisionMM"] = precision
        }
        if let gap = outcome.aabbGapMM, gap.isFinite { row["aabbGapMM"] = gap }
        if let overlap = outcome.aabbOverlapVolumeMM3, overlap.isFinite {
            row["aabbOverlapVolumeMM3"] = overlap
            row["aabbOverlapVolumeIsBroadphaseOnly"] = true
        }
        if let witness = outcome.witnessA { row["witnessA"] = Self.vectorPayload(witness) }
        if let witness = outcome.witnessB { row["witnessB"] = Self.vectorPayload(witness) }
        if let triangle = outcome.triangleA { row["triangleA"] = triangle }
        if let triangle = outcome.triangleB { row["triangleB"] = triangle }
        if outcome.surfaceCrossing { row["surfaceCrossing"] = true }
        if outcome.surfaceTouching { row["surfaceTouching"] = true }
        row["containment"] = outcome.containment
        if let topology = outcome.topologyA {
            row["meshTopologyA"] = Self.topologyPayload(topology)
        }
        if let topology = outcome.topologyB {
            row["meshTopologyB"] = Self.topologyPayload(topology)
        }
        if !outcome.notes.isEmpty { row["notes"] = outcome.notes }
        if let reason = outcome.unresolvedReason { row["unresolvedReason"] = reason }
        if outcome.kernelRefused { row["kernelRefused"] = true }
        if let detail = outcome.kernelErrorDetail { row["kernelError"] = detail }
        return row
    }

    private nonisolated static func topologyPayload(
        _ topology: CADInterferenceMeshTopology
    ) -> [String: Any] {
        [
            "summary": topology.summary,
            "closed": topology.isClosed,
            "oriented": topology.isOriented,
            "watertight": topology.isWatertight,
            "components": topology.componentCount,
            "inwardComponents": topology.inwardComponentCount,
            "boundaryEdges": topology.boundaryEdgeCount,
            "nonManifoldEdges": topology.nonManifoldEdgeCount,
            "degenerateTriangles": topology.degenerateTriangleCount,
        ]
    }

    // MARK: - Read actions

    private func reportAction() -> [String: Any] {
        switch loadAssembly() {
        case .failure(let error):
            return fail(error.code, error.message)
        case .success(let assembly):
            let dof = CADAssemblySolver.degreesOfFreedom(
                assembly, modelScale: modelScaleFor(assembly))
            let index = CADAssemblySolver.resolvableIndex(assembly)
            let invalidAll = assembly.constraints
                .filter { !CADAssemblySolver.constraintIsResolvable($0, in: index) }
                .map { $0.id.uuidString }
            // DOF runs the pure solver internally and reports an unsatisfied
            // system as not credible; a report read never persists its
            // candidate placements.
            let redundant = Set(dof.redundant.map(\.uuidString))

            let occurrences = assembly.occurrences(includeHidden: true)
            var localDOF: [UUID: Int] = [:]
            var localSolved = true
            var localCredible = true
            var localFullyConstrained = true
            var nestedConflicts: [String] = []
            var nestedInvalidRefs: [String] = []
            var nestedRedundant = Set<String>()
            var nestedConflictSet = Set<String>()
            for occurrence in occurrences where occurrence.instance.isSubassembly {
                let container = occurrence.instance
                let local = CADAssembly(instances: container.children,
                                        constraints: container.constraints)
                let localResult = CADAssemblySolver.degreesOfFreedom(
                    local, modelScale: modelScaleFor(local))
                if !localResult.solved { localSolved = false }
                if !localResult.credible { localCredible = false }
                // Solvable is not locked: only a zero-mobility local scope
                // stops the children from moving inside the container.
                if !container.children.isEmpty, !localResult.fullyConstrained {
                    localFullyConstrained = false
                }
                nestedConflicts.append(contentsOf: localResult.conflicting.map(\.uuidString))
                nestedInvalidRefs.append(contentsOf: localResult.invalidReferences.map(\.uuidString))
                nestedRedundant.formUnion(localResult.redundant.map(\.uuidString))
                nestedConflictSet.formUnion(localResult.conflicting.map(\.uuidString))
                for (id, value) in localResult.perInstance { localDOF[id] = value }
            }
            var instanceEntries: [[String: Any]] = []
            var stale: [String] = []
            var staleReferences: [String] = []
            for occurrence in occurrences {
                let instance = occurrence.instance
                var entry = instancePayload(instance)
                if let parentID = occurrence.parentInstanceID {
                    entry["parentID"] = parentID.uuidString
                } else {
                    entry["parentID"] = NSNull()
                }
                entry["path"] = occurrence.path.map(\.uuidString)
                entry["depth"] = occurrence.depth
                entry["visible"] = occurrence.isVisible
                if let effectiveBodyID = occurrence.effectiveBodyID {
                    entry["effectiveBodyID"] = effectiveBodyID.uuidString
                } else {
                    entry["effectiveBodyID"] = NSNull()
                }
                entry["bomIdentity"] = occurrence.bomIdentity.uuidString
                if !instance.isSubassembly,
                   let metadata = assembly.partMetadataRecord(occurrence.bomIdentity) {
                    entry["partMetadata"] = partMetadataJSON(metadata)
                }
                entry["dof"] = localDOF[instance.id] ?? dof.perInstance[instance.id] ?? 0
                if instance.isSubassembly {
                    entry["kind"] = "subassembly"
                    entry["stale"] = false
                } else if let referenceID = instance.sourceReferenceID,
                          let reference = assembly.partReference(referenceID),
                          !instance.isIndependentCopy {
                    let status = referenceInstanceStatus(instance, reference: reference)
                    entry["kind"] = "reference"
                    entry["referenceStatus"] = status.code
                    entry["referenceMissing"] = status.missing
                    entry["stale"] = status.stale
                    if let reason = status.reason { entry["referenceMessage"] = reason }
                    if status.stale { stale.append(instance.id.uuidString) }
                    if status.missing { staleReferences.append(referenceID.uuidString) }
                } else {
                    let body = body(for: effectiveBodyID(instance))
                    let isStale = body == nil || instance.sourceRevision != body?.meshRevision
                    entry["kind"] = instance.isIndependentCopy ? "independentCopy" : "part"
                    entry["stale"] = isStale
                    if isStale { stale.append(instance.id.uuidString) }
                }
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
                    "scope": "root",
                    "parentID": NSNull(),
                ]
                if let instanceB = constraint.instanceB {
                    entry["instanceB"] = instanceB.uuidString
                }
                entry["pointA"] = Self.vectorPayload(constraint.pointA)
                entry["directionA"] = Self.vectorPayload(constraint.directionA)
                if let pointB = constraint.pointB {
                    entry["pointB"] = Self.vectorPayload(pointB)
                }
                if let directionB = constraint.directionB {
                    entry["directionB"] = Self.vectorPayload(directionB)
                }
                if let value = constraint.value {
                    entry["value"] = value
                    entry["valueUnit"] = constraint.kind == .angle ? "degrees" : "mm"
                }
                let revisionState = constraintRevisionState(constraint, assembly: assembly)
                entry["staleReference"] = revisionState.stale
                if let a = constraint.sourceRevisionA { entry["sourceRevisionA"] = a }
                if let b = constraint.sourceRevisionB { entry["sourceRevisionB"] = b }
                if !revisionState.staleBodies.isEmpty {
                    entry["staleReferenceBodies"] = revisionState.staleBodies
                }
                constraintEntries.append(entry)
            }
            var invalidNested: [String] = []
            for occurrence in occurrences where occurrence.instance.isSubassembly {
                let container = occurrence.instance
                let local = CADAssembly(instances: container.children,
                                        constraints: container.constraints)
                let localIndex = CADAssemblySolver.resolvableIndex(local)
                for constraint in container.constraints {
                    let valid = CADAssemblySolver.constraintIsResolvable(constraint, in: localIndex)
                    var entry: [String: Any] = [
                        "id": constraint.id.uuidString,
                        "kind": constraint.kind.rawValue,
                        "instanceA": constraint.instanceA.uuidString,
                        "suppressed": constraint.isSuppressed,
                        "valid": valid,
                        "redundant": nestedRedundant.contains(constraint.id.uuidString),
                        "conflicting": nestedConflictSet.contains(constraint.id.uuidString),
                        "scope": "subassembly",
                        "parentID": container.id.uuidString,
                        "path": occurrence.path.map(\.uuidString),
                    ]
                    if let instanceB = constraint.instanceB {
                        entry["instanceB"] = instanceB.uuidString
                    }
                    entry["pointA"] = Self.vectorPayload(constraint.pointA)
                    entry["directionA"] = Self.vectorPayload(constraint.directionA)
                    if let pointB = constraint.pointB {
                        entry["pointB"] = Self.vectorPayload(pointB)
                    }
                    if let directionB = constraint.directionB {
                        entry["directionB"] = Self.vectorPayload(directionB)
                    }
                    if let value = constraint.value {
                        entry["value"] = value
                        entry["valueUnit"] = constraint.kind == .angle ? "degrees" : "mm"
                    }
                    let revisionState = constraintRevisionState(constraint, assembly: assembly)
                    entry["staleReference"] = revisionState.stale
                    if let a = constraint.sourceRevisionA { entry["sourceRevisionA"] = a }
                    if let b = constraint.sourceRevisionB { entry["sourceRevisionB"] = b }
                    if !revisionState.staleBodies.isEmpty {
                        entry["staleReferenceBodies"] = revisionState.staleBodies
                    }
                    if !valid { invalidNested.append(constraint.id.uuidString) }
                    constraintEntries.append(entry)
                }
            }

            let explodedRows = assembly.explodedViews.map { view -> [String: Any] in
                let invalid = view.entries.filter { assembly.instance($0.instanceID) == nil }
                return [
                    "id": view.id.uuidString,
                    "name": view.name,
                    "direction": Self.vectorPayload(safeDirection(view.direction)),
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

            let issues = assembly.integrityIssues(
                documentBodyIDs: Set(document.session.document.bodies.map { $0.id.raw }))

            return [
                "ok": true,
                "dofModel": "kinematic-rank",
                "instanceCount": assembly.instances.count,
                "totalInstanceCount": occurrences.count,
                "subassemblyCount": occurrences.filter { $0.subassemblyID != nil }.count,
                "referenceCount": assembly.partReferences.count,
                "references": referencesPayload(assembly),
                "partMetadataCount": assembly.partMetadata.count,
                "parts": partMetadataRows(assembly),
                "constraintCount": assembly.constraints.count,
                "totalConstraintCount": constraintEntries.count,
                "instances": instanceEntries,
                "constraints": constraintEntries,
                "explodedViewCount": assembly.explodedViews.count,
                "explodedViews": explodedRows,
                "explodedPreview": previewPayload,
                // Remaining mobility at the ROOT scope only (each subassembly
                // container counts as one rigid body, its internal motion is
                // reported per scope in `dof.scopes`); the 6 global rigid
                // modes are included while nothing is grounded (two free
                // root instances read 12).
                "assemblyDOF": dof.total,
                "assemblyDOFScope": "root",
                // Parts-vs-parts mobility at the root scope: total minus the
                // global modes.
                "relativeDOF": dof.relative,
                // The 6 free-fly modes remain until an instance is fixed.
                "globalRigidDOF": dof.globalRigid,
                // Root-scope verdict: grounded, exactly analyzed, zero
                // root mobility and the residual solve converges.
                "rootFullyConstrained": dof.fullyConstrained,
                // True only when every nested local scope has zero internal
                // mobility (movable children inside a container block it).
                "nestedFullyConstrained": localFullyConstrained,
                // Whole-assembly claim: root scope locked AND no internal
                // motion anywhere. Never true while a child can still move
                // inside its container.
                "fullyConstrained": dof.fullyConstrained && localFullyConstrained,
                "dofCredible": dof.credible && localCredible,
                "dofExact": dof.exact,
                "unconstrainedInstances": dof.unconstrained.map(\.uuidString),
                "invalidRefs": invalidAll,
                "invalidNestedRefs": invalidNested,
                "nestedInvalidRefs": Array(Set(nestedInvalidRefs)).sorted(),
                "nestedConflicting": Array(Set(nestedConflicts)).sorted(),
                "redundantConstraints": dof.redundant.map(\.uuidString),
                "conflicting": Array(Set(dof.conflicting.map(\.uuidString) + nestedConflicts)).sorted(),
                "conflicts": Array(Set(dof.conflicting.map(\.uuidString) + nestedConflicts)).sorted(),
                "solved": dof.solved && localSolved,
                "staleInstances": stale,
                "staleSourceBodies": stale,
                "staleReferences": Array(Set(staleReferences)).sorted(),
                "integrity": issues.map(integrityPayload),
            ]
        }
    }

    private func instancesAction() -> [String: Any] {
        switch loadAssembly() {
        case .failure(let error):
            return fail(error.code, error.message)
        case .success(let assembly):
            let occurrences = assembly.occurrences(includeHidden: true)
            let rows = occurrences.map { occurrence -> [String: Any] in
                var payload = instancePayload(occurrence.instance)
                if let parentID = occurrence.parentInstanceID {
                    payload["parentID"] = parentID.uuidString
                } else {
                    payload["parentID"] = NSNull()
                }
                payload["path"] = occurrence.path.map(\.uuidString)
                payload["depth"] = occurrence.depth
                payload["bomIdentity"] = occurrence.bomIdentity.uuidString
                if !occurrence.instance.isSubassembly,
                   let metadata = assembly.partMetadataRecord(occurrence.bomIdentity) {
                    payload["partMetadata"] = partMetadataJSON(metadata)
                }
                if let effectiveBodyID = occurrence.effectiveBodyID {
                    payload["effectiveBodyID"] = effectiveBodyID.uuidString
                } else {
                    payload["effectiveBodyID"] = NSNull()
                }
                return payload
            }
            return [
                "ok": true,
                "count": occurrences.count,
                "rootCount": assembly.instances.count,
                "referenceCount": assembly.partReferences.count,
                "instances": rows,
            ]
        }
    }

    private func dofAction() -> [String: Any] {
        switch loadAssembly() {
        case .failure(let error):
            return fail(error.code, error.message)
        case .success(let assembly):
            let scale = modelScaleFor(assembly)
            let dof = CADAssemblySolver.degreesOfFreedom(assembly, modelScale: scale)
            let rows: [[String: Any]] = assembly.instances.map { instance in
                ["id": instance.id.uuidString,
                 "dof": dof.perInstance[instance.id] ?? 0]
            }

            // Local scopes are reported separately: their six free-fly modes
            // live in the subassembly frame, so folding them into the root
            // total would double-count. Their solve status still participates
            // in the top-level `solved` flag, matching the real solve action
            // (which refuses when any local scope fails).
            var scopes: [[String: Any]] = []
            var nestedConflicts: [String] = []
            var nestedInvalid: [String] = []
            var nestedSolved = true
            var nestedCredible = true
            var nestedFullyConstrained = true
            for occurrence in assembly.occurrences(includeHidden: true)
            where occurrence.instance.isSubassembly {
                let container = occurrence.instance
                let local = CADAssembly(instances: container.children,
                                        constraints: container.constraints)
                let localDof = CADAssemblySolver.degreesOfFreedom(
                    local, modelScale: modelScaleFor(local))
                if !localDof.solved { nestedSolved = false }
                if !localDof.credible { nestedCredible = false }
                // A solvable yet underconstrained local scope still permits
                // internal motion, so it must not satisfy the global claim.
                if !container.children.isEmpty, !localDof.fullyConstrained {
                    nestedFullyConstrained = false
                }
                nestedConflicts.append(contentsOf: localDof.conflicting.map(\.uuidString))
                nestedInvalid.append(contentsOf: localDof.invalidReferences.map(\.uuidString))
                scopes.append([
                    "scope": "subassembly",
                    "parentID": container.id.uuidString,
                    "name": container.name,
                    "path": occurrence.path.map(\.uuidString),
                    "assemblyDOF": localDof.total,
                    "relativeDOF": localDof.relative,
                    "globalRigidDOF": localDof.globalRigid,
                    "fullyConstrained": localDof.fullyConstrained,
                    "dofCredible": localDof.credible,
                    "solved": localDof.solved,
                    "exact": localDof.exact,
                    "conflicting": localDof.conflicting.map(\.uuidString),
                    "invalidRefs": localDof.invalidReferences.map(\.uuidString),
                    "redundantConstraints": localDof.redundant.map(\.uuidString),
                ])
            }
            let solved = dof.solved && nestedSolved
            let conflicts = (dof.conflicting.map(\.uuidString) + nestedConflicts)
                .reduce(into: [String]()) { result, value in
                    if !result.contains(value) { result.append(value) }
                }
            let invalid = (dof.invalidReferences.map(\.uuidString) + nestedInvalid)
                .reduce(into: [String]()) { result, value in
                    if !result.contains(value) { result.append(value) }
                }
            return [
                "ok": true,
                "dofModel": "kinematic-rank",
                // Root-scope counts only (each subassembly container is one
                // rigid body here); per-scope counts live in `scopes` and no
                // verified whole-assembly aggregate is fabricated.
                "assemblyDOF": dof.total,
                "assemblyDOFScope": "root",
                "relativeDOF": dof.relative,
                "globalRigidDOF": dof.globalRigid,
                "rootFullyConstrained": dof.fullyConstrained,
                "nestedFullyConstrained": nestedFullyConstrained,
                "fullyConstrained": dof.fullyConstrained && nestedFullyConstrained,
                "dofCredible": dof.credible && nestedCredible,
                "dofExact": dof.exact,
                "exact": dof.exact,
                "solved": solved,
                "conflicting": conflicts,
                "invalidRefs": invalid,
                "unconstrainedInstances": dof.unconstrained.map(\.uuidString),
                "redundantConstraints": dof.redundant.map(\.uuidString),
                "instances": rows,
                "scopes": scopes,
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

        var parentID: UUID?
        if let raw = args["parentID"] ?? args["parentInstanceID"], !(raw is NSNull) {
            guard let parsed = uuidValue(raw) else {
                return fail("bad_parent_id", "parentID must be a subassembly instance UUID string.")
            }
            guard let parent = updated.instance(parsed), parent.isSubassembly else {
                return fail("unknown_subassembly", "parentID must reference an existing subassembly instance.")
            }
            parentID = parsed
        }

        let independentCopy = boolValue(args["independentCopy"]) ?? false
        var copiedBodyID: UUID?
        var copyBody: Body?
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
            copyBody = copy
            copiedBodyID = copy.id.raw
        }

        let placedBody = copyBody ?? body(for: bodyUUID) ?? sourceBody
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
        guard updated.appendInstance(instance, parentID: parentID) else {
            return fail("placement_failed",
                        "The instance could not be placed under the requested subassembly.")
        }
        if let copyBody {
            do {
                let before = document.session.document.assemblyData
                let after = try updated.encoded()
                document.session.perform(CompositeCommand(
                    title: "Assembly Copy \(sourceBody.name)",
                    commands: [
                        AddBodyCommand(body: copyBody),
                        SetAssemblyDataCommand(before: before, after: after),
                    ]))
            } catch {
                return fail("encode_failed",
                            "The assembly could not be encoded: \(error.localizedDescription)")
            }
        } else if let failure = persist(updated) {
            return failure
        }

        var payload = instancePayload(instance)
        payload["ok"] = true
        payload["mutated"] = true
        payload["path"] = updated.instancePath(instance.id)?.map(\.uuidString) ?? []
        if let parentID { payload["parentID"] = parentID.uuidString }
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
        guard let removedInstance = updated.instance(id) else {
            return fail("unknown_instance", "No assembly instance with that id.")
        }
        let removedIDs = Set(subtreeIDs(removedInstance))
        let removedBodyIDs = removedIDs.compactMap { updated.instance($0)?.copiedBodyID }
        let removedConstraintIDs = updated.constraints
            .filter { removedIDs.contains($0.instanceA)
                || ($0.instanceB.map { removedIDs.contains($0) } ?? false) }
            .map(\.id.uuidString)
        updated.constraints.removeAll { constraint in
            removedIDs.contains(constraint.instanceA)
                || (constraint.instanceB.map { removedIDs.contains($0) } ?? false)
        }
        var nestedRemovedConstraintIDs: [String] = []
        removeConstraints(referencing: removedIDs, in: &updated.instances,
                          removedIDs: &nestedRemovedConstraintIDs)
        _ = updated.removeSubtree(id)
        // Exploded-view entries are display state: drop the removed subtree's
        // entries so a later preview cannot point at a dead placement. The
        // named view itself is retained.
        var droppedExplodedEntries: [String] = []
        for index in updated.explodedViews.indices {
            let removedEntries = updated.explodedViews[index].entries
                .filter { removedIDs.contains($0.instanceID) }
                .map(\.id.uuidString)
            droppedExplodedEntries.append(contentsOf: removedEntries)
            updated.explodedViews[index].entries.removeAll { removedIDs.contains($0.instanceID) }
            if !removedEntries.isEmpty {
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
            "removedInstanceIDs": removedIDs.sorted { $0.uuidString < $1.uuidString }
                .map(\.uuidString),
            "removedConstraintIDs": removedConstraintIDs + nestedRemovedConstraintIDs,
            "removedExplodedEntryIDs": droppedExplodedEntries,
        ]
        if let copied = removedInstance.copiedBodyID {
            payload["orphanedBodyID"] = copied.uuidString
        }
        if !removedBodyIDs.isEmpty {
            payload["orphanedBodyIDs"] = removedBodyIDs.map(\.uuidString)
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
        guard updated.instance(id) != nil else {
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
        updated.updateInstance(id) { $0.transform = transform }
        if let failure = persist(updated) { return failure }
        guard let instance = updated.instance(id) else {
            return fail("unknown_instance", "The instance disappeared while updating it.")
        }
        return ["ok": true, "mutated": true,
                "instance": instancePayload(instance),
                "path": updated.instancePath(id)?.map(\.uuidString) ?? []]
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
        guard updated.instance(id) != nil else {
            return fail("unknown_instance", "No assembly instance with that id.")
        }
        guard let hidden = boolValue(args["hidden"]) else {
            return fail("bad_hidden", "hidden must be a boolean.")
        }
        updated.updateInstance(id) { $0.isHidden = hidden }
        if let failure = persist(updated) { return failure }
        guard let instance = updated.instance(id) else {
            return fail("unknown_instance", "The instance disappeared while updating it.")
        }
        return ["ok": true, "mutated": true,
                "instance": instancePayload(instance),
                "path": updated.instancePath(id)?.map(\.uuidString) ?? []]
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
        var parentID: UUID?
        if let raw = args["parentID"] ?? args["parentInstanceID"], !(raw is NSNull) {
            guard let parsed = uuidValue(raw) else {
                return fail("bad_parent_id", "parentID must be a subassembly instance UUID string.")
            }
            guard let container = updated.instance(parsed), container.isSubassembly else {
                return fail("unknown_subassembly", "parentID must reference an existing subassembly instance.")
            }
            parentID = parsed
        }
        let scopeChildren: Set<UUID>? = parentID.flatMap { id in
            updated.instance(id).map { Set($0.children.map(\.id)) }
        }
        guard let instanceA = uuidValue(args["instanceA"]),
              updated.instance(instanceA) != nil else {
            return fail("unknown_instance", "instanceA must reference an assembly instance.")
        }
        if let scopeChildren, !scopeChildren.contains(instanceA) {
            return fail("nested_constraint_scope",
                        "A subassembly constraint must reference one of its direct children.")
        }
        if scopeChildren == nil, !updated.instances.contains(where: { $0.id == instanceA }) {
            return fail("nested_constraint_scope",
                        "A root constraint cannot reference a nested instance; "
                        + "add the constraint inside its owning subassembly.")
        }

        var instanceB: UUID?
        if let raw = args["instanceB"], !(raw is NSNull) {
            guard let parsed = uuidValue(raw),
                  updated.instance(parsed) != nil else {
                return fail("unknown_instance", "instanceB must reference an assembly instance.")
            }
            if let scopeChildren, !scopeChildren.contains(parsed) {
                return fail("nested_constraint_scope",
                            "A subassembly constraint must reference one of its direct children.")
            }
            if scopeChildren == nil, !updated.instances.contains(where: { $0.id == parsed }) {
                return fail("nested_constraint_scope",
                            "A root constraint cannot reference a nested instance; "
                            + "add the constraint inside its owning subassembly.")
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
        guard let instanceAValue = updated.instance(instanceA) else {
            return fail("unknown_instance", "instanceA must reference an assembly instance.")
        }
        let instanceBValue = instanceB.flatMap { updated.instance($0) }
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
        if let parentID {
            guard updated.updateInstance(parentID, { $0.constraints.append(constraint) }) else {
                return fail("unknown_subassembly", "The owning subassembly disappeared while adding the constraint.")
            }
        } else {
            updated.constraints.append(constraint)
        }
        if let failure = persist(updated) { return failure }

        var payload = constraintPayload(constraint)
        payload["ok"] = true
        payload["mutated"] = true
        payload["scope"] = parentID == nil ? "root" : "subassembly"
        if let parentID { payload["parentID"] = parentID.uuidString }
        if let referenceA { payload["referenceA"] = referenceA.payload }
        if let referenceB { payload["referenceB"] = referenceB.payload }
        return payload
    }


    // MARK: - Constraint editing

    /// Result of one transactional candidate solve for a constraint edit.
    /// Nothing here is persisted: the caller writes `assembly` only when
    /// `solved` is true, so a contradictory edit cannot touch placement, the
    /// undo stack or the package.
    private struct ConstraintSolveOutcome {
        var assembly: CADAssembly
        var solved: Bool
        var invalidReferences: [UUID]
        var conflicting: [UUID]
        var scope: String
        var parentID: UUID?
        var previewInstances: [CADAssemblyInstance]
        var nestedRows: [[String: Any]]
    }

    /// Solve nested local scopes first (each in its own frame), then the root,
    /// mirroring `solve` exactly. Failure reports the actual scope/id so the
    /// editor never blames the wrong constraint.
    private func solveCandidate(_ input: CADAssembly) -> ConstraintSolveOutcome {
        var updated = input
        var nestedRows: [[String: Any]] = []
        for occurrence in input.occurrences(includeHidden: true) {
            let container = occurrence.instance
            guard container.isSubassembly else { continue }
            let local = CADAssembly(instances: container.children,
                                    constraints: container.constraints)
            let localResult = CADAssemblySolver.solve(local,
                                                      modelScale: modelScaleFor(local))
            guard localResult.solved else {
                return ConstraintSolveOutcome(
                    assembly: updated,
                    solved: false,
                    invalidReferences: localResult.invalidReferences,
                    conflicting: localResult.conflicting,
                    scope: "subassembly",
                    parentID: container.id,
                    previewInstances: localResult.updatedInstances,
                    nestedRows: nestedRows)
            }
            updated.updateInstance(container.id) { $0.children = localResult.updatedInstances }
            nestedRows.append([
                "parentID": container.id.uuidString,
                "name": container.name,
                "path": occurrence.path.map(\.uuidString),
                "solved": true,
                "updatedInstanceIDs": localResult.updatedInstances.map { $0.id.uuidString },
            ])
        }

        let result = CADAssemblySolver.solve(updated, modelScale: modelScaleFor(updated))
        var solvedAssembly = updated
        if result.solved {
            solvedAssembly.instances = result.updatedInstances
        }
        return ConstraintSolveOutcome(
            assembly: solvedAssembly,
            solved: result.solved,
            invalidReferences: result.invalidReferences,
            conflicting: result.conflicting,
            scope: "root",
            parentID: nil,
            previewInstances: result.updatedInstances,
            nestedRows: nestedRows)
    }

    /// Resolvable instance index for the constraint's own scope. Root
    /// constraints index root instances; local constraints index the owning
    /// subassembly's direct children.
    private func constraintScopeIndex(_ assembly: CADAssembly,
                                      parentID: UUID?) -> [UUID: Int] {
        guard let parentID else {
            return CADAssemblySolver.resolvableIndex(assembly)
        }
        guard let container = assembly.instance(parentID) else { return [:] }
        var index: [UUID: Int] = [:]
        for (position, child) in container.children.enumerated()
        where index[child.id] == nil && CADAssemblySolver.isValidTransform(child.transform) {
            index[child.id] = position
        }
        return index
    }

    /// True when every nested local scope is inside the exact DOF window and
    /// its residual solve is credible. Used by solve/edit responses so a
    /// root-level claim cannot ignore an unsolved or approximate local scope.
    private func nestedScopesAreCredible(_ assembly: CADAssembly) -> Bool {
        for occurrence in assembly.occurrences(includeHidden: true)
        where occurrence.instance.isSubassembly {
            let container = occurrence.instance
            let local = CADAssembly(instances: container.children,
                                    constraints: container.constraints)
            if !CADAssemblySolver.degreesOfFreedom(
                local, modelScale: modelScaleFor(local)).credible {
                return false
            }
        }
        return true
    }

    /// True only when EVERY nested local scope actually has zero internal
    /// mobility: each scope is exactly analyzed, its residual solve
    /// converges, and its local rank leaves no child free to move inside its
    /// container. A scope that merely solves while staying underconstrained
    /// (movable children) is NOT enough — `credible` covers solvability, this
    /// covers freedom. An empty container has no internal motion by
    /// definition, so it never blocks the claim. With no subassemblies this
    /// is vacuously true, matching the historical flat behavior.
    private func nestedScopesAreFullyConstrained(_ assembly: CADAssembly) -> Bool {
        for occurrence in assembly.occurrences(includeHidden: true)
        where occurrence.instance.isSubassembly {
            let container = occurrence.instance
            guard !container.children.isEmpty else { continue }
            let local = CADAssembly(instances: container.children,
                                    constraints: container.constraints)
            if !CADAssemblySolver.degreesOfFreedom(
                local, modelScale: modelScaleFor(local)).fullyConstrained {
                return false
            }
        }
        return true
    }

    /// Edit one existing constraint. The constraint id, kind, instance pair
    /// and scope are immutable; `value` (mm/degrees) and geometry references
    /// are editable. Omitted references keep their exact points, directions
    /// and source revision pins. The edit and the solved placements are one
    /// `SetAssemblyDataCommand`; an unsatisfiable candidate returns
    /// `constraint_failed / mutated:false` before any write.
    private func updateConstraintAction(_ args: [String: Any]) -> [String: Any] {
        let assembly: CADAssembly
        switch loadAssembly() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): assembly = loaded
        }
        var updated = assembly

        guard let id = uuidValue(args["id"]) else {
            return fail("bad_constraint_id", "id must be a constraint UUID string.")
        }
        guard let located = updated.constraintsWithScope().first(where: { $0.constraint.id == id }),
              var constraint = updated.constraint(id) else {
            return fail("unknown_constraint", "No assembly constraint with that id.")
        }
        let parentID = located.parentID
        let original = constraint
        let kind = constraint.kind

        if let rawKind = args["kind"], !(rawKind is NSNull) {
            guard let requested = rawKind as? String, requested == kind.rawValue else {
                return fail("unsupported_constraint_kind",
                            "The constraint kind cannot be changed in place; remove it and add a new constraint.")
            }
        }
        if let rawA = args["instanceA"], !(rawA is NSNull) {
            guard let requested = uuidValue(rawA), requested == constraint.instanceA else {
                return fail("unsupported_instance_change",
                            "The constrained instance pair cannot be changed in place; remove it and add a new constraint.")
            }
        }
        if let rawB = args["instanceB"], !(rawB is NSNull) {
            guard let requested = uuidValue(rawB), requested == constraint.instanceB else {
                return fail("unsupported_instance_change",
                            "The constrained instance pair cannot be changed in place; remove it and add a new constraint.")
            }
        }

        if let rawExpected = args["expectedValue"], !(rawExpected is NSNull) {
            guard let expectedValue = doubleValue(rawExpected), expectedValue.isFinite else {
                return fail("bad_expected_value", "expectedValue must be a finite number.")
            }
            guard let currentValue = constraint.value,
                  abs(currentValue - expectedValue) <= 1e-9 * max(1, abs(expectedValue)) else {
                return fail("stale_constraint",
                            "The constraint value changed since it was queried; re-query it and retry.")
            }
        }

        if let rawValue = args["value"], !(rawValue is NSNull) {
            guard let parsed = doubleValue(rawValue), parsed.isFinite else {
                return fail("bad_value", "value must be a finite number (mm or degrees).")
            }
            switch kind {
            case .distance:
                guard parsed >= 0 else {
                    return fail("bad_value", "distance value must be a finite, non-negative number of mm.")
                }
            case .angle:
                guard parsed >= 0, parsed <= 180 else {
                    return fail("bad_value", "angle value must be a finite number of degrees in [0, 180].")
                }
            case .fixed, .coaxial, .planarAlign:
                return fail("unsupported_value",
                            "Only distance and angle constraints carry an editable value.")
            }
            constraint.value = parsed
        }

        let geometryKeys = ["pointA", "directionA", "pointB", "directionB",
                            "referenceA", "faceA", "edgeA", "referenceB", "faceB", "edgeB"]
        let hasGeometryInput = geometryKeys.contains { key in
            guard let raw = args[key] else { return false }
            return !(raw is NSNull)
        }
        if kind == .fixed, hasGeometryInput {
            return fail("unsupported_reference",
                        "A fixed constraint anchors its instance and has no editable geometry reference.")
        }

        guard let instanceAValue = updated.instance(constraint.instanceA) else {
            return fail("unknown_instance", "The constraint's instanceA no longer exists.")
        }
        let instanceBValue = constraint.instanceB.flatMap { updated.instance($0) }
        if instanceBValue == nil, ["pointB", "directionB", "referenceB", "faceB", "edgeB"]
            .contains(where: { key in
                guard let raw = args[key] else { return false }
                return !(raw is NSNull)
            }) {
            return fail("missing_instance_b",
                        "This constraint has no instanceB to receive geometry on B.")
        }

        var referenceA: CADAssemblyReference?
        var referenceB: CADAssemblyReference?
        if hasGeometryInput {
            if kind != .fixed {
                if let resolved = parseInlineReference(args: args, key: "referenceA",
                                                       faceKey: "faceA", edgeKey: "edgeA",
                                                       instance: instanceAValue,
                                                       assembly: updated, label: "A") {
                    switch resolved {
                    case .failure(let error): return fail(error.code, error.message)
                    case .success(let value): referenceA = value
                    }
                }
                if args["referenceB"] != nil || args["faceB"] != nil || args["edgeB"] != nil {
                    guard let instanceBValue else {
                        return fail("missing_instance_b",
                                    "This constraint has no instanceB to receive referenceB.")
                    }
                    if let resolved = parseInlineReference(args: args, key: "referenceB",
                                                           faceKey: "faceB", edgeKey: "edgeB",
                                                           instance: instanceBValue,
                                                           assembly: updated, label: "B") {
                        switch resolved {
                        case .failure(let error): return fail(error.code, error.message)
                        case .success(let value): referenceB = value
                        }
                    }
                }
            }
        }

        var geometryAChanged = false
        if let referenceA {
            constraint.pointA = referenceA.point
            constraint.directionA = referenceA.direction
            constraint.sourceRevisionA = referenceA.sourceRevision
            geometryAChanged = true
        } else {
            if let raw = args["pointA"], !(raw is NSNull) {
                switch parseVector(raw) {
                case .failure(let error): return fail(error.code, error.message)
                case .success(let parsed):
                    guard let parsed else {
                        return fail("bad_vector", "pointA must be a finite [x,y,z] vector.")
                    }
                    constraint.pointA = parsed
                    geometryAChanged = true
                }
            }
            if let raw = args["directionA"], !(raw is NSNull) {
                switch parseVector(raw) {
                case .failure(let error): return fail(error.code, error.message)
                case .success(let parsed):
                    guard let parsed, simd_length(parsed) > 1e-12 else {
                        return fail("zero_direction", "directionA must be a non-zero [x,y,z] vector.")
                    }
                    constraint.directionA = simd_normalize(parsed)
                    geometryAChanged = true
                }
            }
        }
        if geometryAChanged, referenceA == nil,
           let source = body(for: effectiveBodyID(instanceAValue)) {
            constraint.sourceRevisionA = source.meshRevision
        }

        var geometryBChanged = false
        if let referenceB {
            constraint.pointB = referenceB.point
            constraint.directionB = referenceB.direction
            constraint.sourceRevisionB = referenceB.sourceRevision
            geometryBChanged = true
        } else if let instanceBValue {
            if args.keys.contains("pointB") {
                if args["pointB"] is NSNull {
                    constraint.pointB = nil
                    geometryBChanged = true
                } else if let raw = args["pointB"] {
                    switch parseVector(raw) {
                    case .failure(let error): return fail(error.code, error.message)
                    case .success(let parsed):
                        guard let parsed else {
                            return fail("bad_vector", "pointB must be a finite [x,y,z] vector.")
                        }
                        constraint.pointB = parsed
                        geometryBChanged = true
                    }
                }
            }
            if args.keys.contains("directionB") {
                if args["directionB"] is NSNull {
                    if kind == .coaxial || kind == .planarAlign || kind == .angle {
                        return fail("missing_direction",
                                    "\(kind.rawValue) needs a directionB; pass a non-zero vector.")
                    }
                    constraint.directionB = nil
                    geometryBChanged = true
                } else if let raw = args["directionB"] {
                    switch parseVector(raw) {
                    case .failure(let error): return fail(error.code, error.message)
                    case .success(let parsed):
                        guard let parsed, simd_length(parsed) > 1e-12 else {
                            return fail("zero_direction", "directionB must be a non-zero [x,y,z] vector.")
                        }
                        constraint.directionB = simd_normalize(parsed)
                        geometryBChanged = true
                    }
                }
            }
            if geometryBChanged, referenceB == nil,
               let source = body(for: effectiveBodyID(instanceBValue)) {
                constraint.sourceRevisionB = source.meshRevision
            }
        }

        let scopeIndex = constraintScopeIndex(updated, parentID: parentID)
        guard CADAssemblySolver.constraintIsResolvable(constraint, in: scopeIndex) else {
            return fail("invalid_constraint",
                        "The edited constraint no longer resolves; nothing was changed.")
        }

        if let parentID {
            guard updated.updateInstance(parentID, { container in
                if let index = container.constraints.firstIndex(where: { $0.id == id }) {
                    container.constraints[index] = constraint
                }
            }) else {
                return fail("unknown_subassembly", "The owning subassembly disappeared while editing the constraint.")
            }
        } else {
            guard let index = updated.constraints.firstIndex(where: { $0.id == id }) else {
                return fail("unknown_constraint", "The constraint disappeared while editing it.")
            }
            updated.constraints[index] = constraint
        }

        if constraint == original {
            var payload = constraintQueryPayload(constraint, scope: parentID == nil ? "root" : "subassembly",
                                                 parentID: parentID)
            payload["ok"] = true
            payload["mutated"] = false
            payload["unchanged"] = true
            return payload
        }

        let outcome = solveCandidate(updated)
        guard outcome.solved else {
            var payload: [String: Any] = [
                "ok": false,
                "error": "constraint_failed",
                "mutated": false,
                "solved": false,
                "constraintID": id.uuidString,
                "scope": outcome.scope,
                "message": failureMessage(
                    invalid: Set(outcome.invalidReferences.map(\.uuidString)),
                    conflicts: Set(outcome.conflicting.map(\.uuidString))),
                "conflicting": outcome.conflicting.map(\.uuidString),
                "invalidRefs": outcome.invalidReferences.map(\.uuidString),
                // Candidate placements the solve reached; NOT applied.
                "previewInstances": outcome.previewInstances.map(instancePayload),
            ]
            if let parentID = outcome.parentID {
                payload["parentID"] = parentID.uuidString
            } else {
                payload["parentID"] = NSNull()
            }
            return payload
        }

        updated = outcome.assembly
        if let failure = persist(updated) { return failure }
        guard let current = updated.constraint(id) else {
            return fail("unknown_constraint", "The constraint disappeared while updating it.")
        }
        let dof = CADAssemblySolver.degreesOfFreedom(updated, modelScale: modelScaleFor(updated))
        let nestedCredible = nestedScopesAreCredible(updated)
        let nestedFullyConstrained = nestedScopesAreFullyConstrained(updated)
        var payload = constraintQueryPayload(current,
                                             scope: parentID == nil ? "root" : "subassembly",
                                             parentID: parentID)
        payload["ok"] = true
        payload["mutated"] = true
        payload["solved"] = true
        payload["constraintID"] = id.uuidString
        payload["nestedSolved"] = outcome.nestedRows
        // Same root-scope diagnostic contract as report/dof/solve.
        payload["assemblyDOF"] = dof.total
        payload["assemblyDOFScope"] = "root"
        payload["relativeDOF"] = dof.relative
        payload["globalRigidDOF"] = dof.globalRigid
        payload["rootFullyConstrained"] = dof.fullyConstrained
        payload["nestedFullyConstrained"] = nestedFullyConstrained
        payload["fullyConstrained"] = dof.fullyConstrained && nestedFullyConstrained
        payload["dofCredible"] = dof.credible && nestedCredible
        payload["redundantConstraints"] = dof.redundant.map(\.uuidString)
        payload["invalidRefs"] = []
        payload["conflicting"] = []
        return payload
    }

    /// Full query representation of one constraint (including the fields an
    /// inspector needs to edit it without guessing geometry).
    private func constraintQueryPayload(_ constraint: CADAssemblyConstraint,
                                        scope: String,
                                        parentID: UUID?) -> [String: Any] {
        var payload = constraintPayload(constraint)
        payload["scope"] = scope
        if let parentID {
            payload["parentID"] = parentID.uuidString
        } else {
            payload["parentID"] = NSNull()
        }
        payload["valid"] = true
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
        guard let located = updated.constraintsWithScope().first(where: { $0.constraint.id == id }) else {
            return fail("unknown_constraint", "No assembly constraint with that id.")
        }
        if let parentID = located.parentID {
            updated.updateInstance(parentID) { container in
                container.constraints.removeAll { $0.id == id }
            }
        } else {
            updated.constraints.removeAll { $0.id == id }
        }
        if let failure = persist(updated) { return failure }
        var payload: [String: Any] = ["ok": true, "mutated": true, "removedConstraint": id.uuidString]
        if let parentID = located.parentID {
            payload["parentID"] = parentID.uuidString
            payload["scope"] = "subassembly"
        } else {
            payload["scope"] = "root"
        }
        return payload
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
        guard let located = updated.constraintsWithScope().first(where: { $0.constraint.id == id }) else {
            return fail("unknown_constraint", "No assembly constraint with that id.")
        }
        guard let suppressed = boolValue(args["suppressed"]) else {
            return fail("bad_suppressed", "suppressed must be a boolean.")
        }
        if let parentID = located.parentID {
            updated.updateInstance(parentID) { container in
                if let index = container.constraints.firstIndex(where: { $0.id == id }) {
                    container.constraints[index].isSuppressed = suppressed
                }
            }
        } else if let index = updated.constraints.firstIndex(where: { $0.id == id }) {
            updated.constraints[index].isSuppressed = suppressed
        }
        if let failure = persist(updated) { return failure }
        guard let current = updated.constraint(id) else {
            return fail("unknown_constraint", "The constraint disappeared while updating it.")
        }
        var payload: [String: Any] = ["ok": true, "mutated": true,
                                      "constraint": constraintPayload(current)]
        if let parentID = located.parentID {
            payload["parentID"] = parentID.uuidString
            payload["scope"] = "subassembly"
        } else {
            payload["scope"] = "root"
        }
        return payload
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
        guard !instance.isSubassembly else {
            return fail("subassembly_reference_unsupported",
                        "Pick a reference on a part inside the subassembly, not on the container.")
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
        guard !instance.isSubassembly else {
            return fail("subassembly_reference_unsupported",
                        "Pick a reference on a part inside the subassembly, not on the container.")
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
                    "point": Self.vectorPayload(point),
                    "direction": Self.vectorPayload(direction),
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
                    "point": Self.vectorPayload(source.transform.applying(to: midpoint)),
                    "query_token": edgeToken,
                ]
                if let direction { row["direction"] = Self.vectorPayload(direction) }
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
            row["offsets"] = assembly.occurrences(includeHidden: true).map { occurrence in
                let instance = occurrence.instance
                let offset = view.offset(for: instance.id)
                var entry: [String: Any] = [
                    "instanceID": instance.id.uuidString,
                    "name": instance.name,
                    "offset": Self.vectorPayload(offset),
                    "distanceMM": simd_length(offset),
                    "path": occurrence.path.map(\.uuidString),
                    "depth": occurrence.depth,
                    "baseTransform": transformPayload(instance.transform),
                ]
                if let parentID = occurrence.parentInstanceID {
                    entry["parentID"] = parentID.uuidString
                }
                return entry
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
        payload["instances"] = assembly.occurrences(includeHidden: true).map { occurrence in
            let instance = occurrence.instance
            var row: [String: Any] = [
                "instanceID": instance.id.uuidString,
                "name": instance.name,
                "transform": transformPayload(instance.transform),
                "path": occurrence.path.map(\.uuidString),
                "depth": occurrence.depth,
                "offset": [0.0, 0.0, 0.0],
            ]
            if let parentID = occurrence.parentInstanceID {
                row["parentID"] = parentID.uuidString
            }
            return row
        }
        return payload
    }

    // MARK: - Engineering part metadata

    /// Read engineering part definitions. A live part without a stored record
    /// is still returned (empty fields, `hasRecord:false`) so the inspector can
    /// create the first record without a separate lookup.
    private func partMetadataAction(_ args: [String: Any]) -> [String: Any] {
        let assembly: CADAssembly
        switch loadAssembly() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): assembly = loaded
        }
        var filter: UUID?
        if let raw = args["instanceID"] ?? args["id"], !(raw is NSNull) {
            guard let id = uuidValue(raw), let instance = assembly.instance(id) else {
                return fail("unknown_instance", "instanceID must reference a live assembly instance.")
            }
            guard !instance.isSubassembly else {
                return fail("subassembly_has_no_part",
                            "A subassembly container has no part metadata; edit its placed parts.")
            }
            filter = instance.bomIdentity
        } else if let raw = args["definitionID"] ?? args["partID"], !(raw is NSNull) {
            guard let id = uuidValue(raw) else {
                return fail("bad_definition_id", "definitionID must be a part-definition UUID string.")
            }
            filter = id
        }
        let rows = partMetadataRows(assembly, filter: filter)
        guard filter == nil || !rows.isEmpty else {
            return fail("unknown_part", "No stored or live part uses that definition.")
        }
        var payload: [String: Any] = ["ok": true, "count": rows.count, "parts": rows]
        if let filter { payload["definitionID"] = filter.uuidString }
        return payload
    }

    /// Set the shared engineering record for one part definition. The target
    /// is resolved through the SAME `bomIdentity` used by BOM rows: every
    /// shared instance behind that identity reads the new values, while an
    /// explicit independent copy has its own identity and is untouched.
    private func setPartMetadataAction(_ args: [String: Any]) -> [String: Any] {
        let assembly: CADAssembly
        switch loadAssembly() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): assembly = loaded
        }
        let identity: UUID
        switch parsePartIdentity(args, assembly: assembly) {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let resolved): identity = resolved
        }
        var record = assembly.partMetadataRecord(identity) ?? CADPartMetadata(id: identity)
        let before = record
        let fields: [(name: String, limit: Int)] = [
            ("partNumber", 64), ("material", 64), ("version", 32),
        ]
        for field in fields where args.keys.contains(field.name) {
            switch parsePartMetadataValue(args[field.name],
                                          field: field.name,
                                          limit: field.limit) {
            case .failure(let error):
                return fail(error.code, error.message)
            case .success(let value):
                switch field.name {
                case "partNumber": record.partNumber = value
                case "material": record.material = value
                default: record.version = value
                }
            }
        }
        let changed = record.partNumber != before.partNumber
            || record.material != before.material
            || record.version != before.version
        guard changed else {
            return ["ok": true, "mutated": false,
                    "part": partMetadataRows(assembly, filter: identity).first ?? [:]]
        }
        var updated = assembly
        if record.isEmpty {
            updated.partMetadata.removeAll { $0.id == identity }
        } else {
            record.updatedAt = Date()
            if let index = updated.partMetadata.firstIndex(where: { $0.id == identity }) {
                updated.partMetadata[index] = record
            } else {
                updated.partMetadata.append(record)
            }
        }
        if let failure = persist(updated) { return failure }
        var payload: [String: Any] = [
            "ok": true,
            "mutated": true,
            "definitionID": identity.uuidString,
            "part": partMetadataRows(updated, filter: identity).first ?? [:],
            "partMetadataCount": updated.partMetadata.count,
        ]
        if record.isEmpty { payload["removed"] = true }
        return payload
    }

    private func parsePartIdentity(_ args: [String: Any], assembly: CADAssembly)
        -> Result<UUID, CADAssemblyServiceError> {
        if let raw = args["instanceID"] ?? args["id"], !(raw is NSNull) {
            guard let id = uuidValue(raw), let instance = assembly.instance(id) else {
                return .failure(CADAssemblyServiceError(
                    code: "unknown_instance",
                    message: "instanceID must reference a live assembly instance."))
            }
            guard !instance.isSubassembly else {
                return .failure(CADAssemblyServiceError(
                    code: "subassembly_has_no_part",
                    message: "A subassembly container has no part metadata; edit its placed parts."))
            }
            return .success(instance.bomIdentity)
        }
        if let raw = args["definitionID"] ?? args["partID"], !(raw is NSNull) {
            guard let id = uuidValue(raw) else {
                return .failure(CADAssemblyServiceError(
                    code: "bad_definition_id",
                    message: "definitionID must be a part-definition UUID string."))
            }
            let live = Set(assembly.occurrences(includeHidden: true)
                .filter { !$0.instance.isSubassembly }
                .map(\.bomIdentity))
            guard live.contains(id) else {
                return .failure(CADAssemblyServiceError(
                    code: "unknown_part",
                    message: "definitionID does not name a live part definition."))
            }
            return .success(id)
        }
        return .failure(CADAssemblyServiceError(
            code: "missing_part",
            message: "Supply instanceID or definitionID for the part to edit."))
    }

    private func parsePartMetadataValue(_ raw: Any?, field: String, limit: Int)
        -> Result<String, CADAssemblyServiceError> {
        guard let raw else { return .success("") }
        if raw is NSNull { return .success("") }
        guard let text = raw as? String else {
            return .failure(CADAssemblyServiceError(
                code: "bad_part_metadata",
                message: "\(field) must be a string; an empty string clears it."))
        }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= limit else {
            return .failure(CADAssemblyServiceError(
                code: "part_metadata_too_long",
                message: "\(field) is bounded to \(limit) characters."))
        }
        return .success(value)
    }

    private func partMetadataRows(_ assembly: CADAssembly,
                                  filter: UUID? = nil) -> [[String: Any]] {
        var identities: [UUID] = []
        var occurrencesByIdentity: [UUID: [CADAssemblyOccurrence]] = [:]
        for occurrence in assembly.occurrences(includeHidden: true)
        where !occurrence.instance.isSubassembly {
            let identity = occurrence.bomIdentity
            if occurrencesByIdentity[identity] == nil {
                identities.append(identity)
            }
            occurrencesByIdentity[identity, default: []].append(occurrence)
        }
        for metadata in assembly.partMetadata where occurrencesByIdentity[metadata.id] == nil {
            identities.append(metadata.id)
            occurrencesByIdentity[metadata.id] = []
        }
        return identities.compactMap { identity -> [String: Any]? in
            guard filter == nil || filter == identity else { return nil }
            return partMetadataRow(identity: identity,
                                   occurrences: occurrencesByIdentity[identity] ?? [],
                                   assembly: assembly)
        }
    }

    private func partMetadataRow(identity: UUID,
                                 occurrences: [CADAssemblyOccurrence],
                                 assembly: CADAssembly) -> [String: Any] {
        let metadata = assembly.partMetadataRecord(identity)
        var row: [String: Any] = [
            "definitionID": identity.uuidString,
            "partNumber": metadata?.partNumber ?? "",
            "material": metadata?.material ?? "",
            "version": metadata?.version ?? "",
            "hasRecord": metadata != nil,
            "instanceCount": occurrences.count,
            "instanceIDs": occurrences.map { $0.instance.id.uuidString },
            "sharedInstanceCount": occurrences.filter { !$0.instance.isIndependentCopy }.count,
            "independentCopyCount": occurrences.filter { $0.instance.isIndependentCopy }.count,
            "referenced": !occurrences.isEmpty,
        ]
        if let first = occurrences.first {
            if let bodyID = first.effectiveBodyID {
                row["bodyID"] = bodyID.uuidString
            }
            row["name"] = first.instance.name
            row["path"] = first.path.map(\.uuidString)
            if let referenceID = first.sourceReferenceID {
                row["referenceID"] = referenceID.uuidString
            }
        }
        if let updatedAt = metadata?.updatedAt {
            row["updatedAt"] = ISO8601DateFormatter().string(from: updatedAt)
        }
        return row
    }

    private func partMetadataJSON(_ metadata: CADPartMetadata) -> [String: Any] {
        [
            "definitionID": metadata.id.uuidString,
            "partNumber": metadata.partNumber,
            "material": metadata.material,
            "version": metadata.version,
        ]
    }

    private func explodedPreviewPayload(view: CADExplodedView,
                                        assembly: CADAssembly) -> [String: Any] {
        var rows: [[String: Any]] = []
        var invalid: [String] = []
        for occurrence in assembly.occurrences(viewID: view.id, includeHidden: true) {
            let instance = occurrence.instance
            let base = occurrence.worldTransform
            let exploded = occurrence.explodedWorldTransform ?? base
            let offset = exploded.position - base.position
            var row: [String: Any] = [
                "instanceID": instance.id.uuidString,
                "name": instance.name,
                "offset": Self.vectorPayload(offset),
                "distanceMM": simd_length(offset),
                "baseTransform": transformPayload(base),
                "transform": transformPayload(exploded),
                "path": occurrence.path.map(\.uuidString),
                "depth": occurrence.depth,
            ]
            if let parentID = occurrence.parentInstanceID {
                row["parentID"] = parentID.uuidString
            }
            rows.append(row)
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
            "direction": Self.vectorPayload(safeDirection(view.direction)),
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
                row["direction"] = Self.vectorPayload(safeDirection(direction))
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
        // The solver is pure and runs on value copies; it NEVER mutates the
        // persisted assembly. Nested subassemblies are solved first in their
        // own local frame (their constraints target direct children), and any
        // failure aborts the whole action without persisting a partial result.
        var updated = assembly
        var nestedRows: [[String: Any]] = []
        for occurrence in assembly.occurrences(includeHidden: true) {
            let container = occurrence.instance
            guard container.isSubassembly else { continue }
            let local = CADAssembly(instances: container.children,
                                    constraints: container.constraints)
            let localResult = CADAssemblySolver.solve(local,
                                                      modelScale: modelScaleFor(local))
            guard localResult.solved else {
                return [
                    "ok": false,
                    "error": "constraint_failed",
                    "mutated": false,
                    "solved": false,
                    "scope": "subassembly",
                    "parentID": container.id.uuidString,
                    "message": "Subassembly '\(container.name)' could not be solved; "
                        + "the assembly was left unchanged.",
                    "conflicting": localResult.conflicting.map(\.uuidString),
                    "invalidRefs": localResult.invalidReferences.map(\.uuidString),
                    "previewInstances": localResult.updatedInstances.map(instancePayload),
                ]
            }
            updated.updateInstance(container.id) { $0.children = localResult.updatedInstances }
            nestedRows.append([
                "parentID": container.id.uuidString,
                "name": container.name,
                "path": occurrence.path.map(\.uuidString),
                "solved": true,
                "updatedInstanceIDs": localResult.updatedInstances.map { $0.id.uuidString },
            ])
        }

        let result = CADAssemblySolver.solve(updated, modelScale: modelScaleFor(updated))
        guard result.solved else {
            let invalid = Set(result.invalidReferences.map(\.uuidString))
            let conflicts = Set(result.conflicting.map(\.uuidString))
            return [
                "ok": false,
                "error": "constraint_failed",
                "mutated": false,
                "solved": false,
                "scope": "root",
                "message": failureMessage(invalid: invalid, conflicts: conflicts),
                "conflicting": result.conflicting.map(\.uuidString),
                "invalidRefs": result.invalidReferences.map(\.uuidString),
                // Candidate placements the solve reached; NOT applied. The
                // caller can render these as a preview only.
                "previewInstances": result.updatedInstances.map(instancePayload),
            ]
        }
        updated.instances = result.updatedInstances
        if let failure = persist(updated) { return failure }
        let dof = CADAssemblySolver.degreesOfFreedom(
            updated, modelScale: modelScaleFor(updated))
        let nestedCredible = nestedScopesAreCredible(updated)
        let nestedFullyConstrained = nestedScopesAreFullyConstrained(updated)
        return [
            "ok": true,
            "mutated": true,
            "solved": true,
            "updatedInstances": result.updatedInstances.map { instancePayload($0) },
            "updatedInstanceIDs": result.updatedInstances.map(\.id.uuidString),
            "nestedSolved": nestedRows,
            "invalidRefs": [],
            "conflicting": [],
            // Same root-scope total/relative split as report and dof, so a
            // successful solve and the DOF diagnostic cannot disagree. The
            // count covers the root scope only; nested scopes are diagnosed
            // separately and no global aggregate is fabricated.
            "assemblyDOF": dof.total,
            "assemblyDOFScope": "root",
            "relativeDOF": dof.relative,
            "globalRigidDOF": dof.globalRigid,
            "rootFullyConstrained": dof.fullyConstrained,
            "nestedFullyConstrained": nestedFullyConstrained,
            "fullyConstrained": dof.fullyConstrained && nestedFullyConstrained,
            "dofCredible": dof.credible && nestedCredible,
            "dofExact": dof.exact,
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

        // Local body-backed instances re-pin to their current body revision.
        // External references are NEVER re-pinned from local state: only the
        // App-owned bridge may change a source pin/geometry after verifying a
        // user-authorized source. A missing source therefore stays missing
        // and keeps its cached display body.
        var refreshedReferences = 0
        for occurrence in updated.occurrences(includeHidden: true) {
            let instance = occurrence.instance
            guard !instance.isSubassembly else { continue }
            guard let source = body(for: effectiveBodyID(instance)) else { continue }
            if instance.isIndependentCopy || instance.sourceReferenceID == nil {
                updated.updateInstance(instance.id) { $0.sourceRevision = source.meshRevision }
            } else if let referenceID = instance.sourceReferenceID,
                      let reference = updated.partReference(referenceID) {
                if reference.stagedRevision != source.meshRevision {
                    refreshedReferences += 1
                }
                updated.partReferences = updated.partReferences.map { item in
                    guard item.id == referenceID else { return item }
                    var copy = item
                    copy.stagedRevision = source.meshRevision
                    return copy
                }
            }
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
        payload["refreshedReferenceStages"] = refreshedReferences
        payload["conflicting"] = []
        payload["invalidRefs"] = []
        return payload
    }

    private func staleReport(_ assembly: CADAssembly) -> [String: Any] {
        var rows: [[String: Any]] = []
        var stale: [String] = []
        var missingReferences: [String] = []
        for occurrence in assembly.occurrences(includeHidden: true) {
            let instance = occurrence.instance
            var row: [String: Any] = [
                "id": instance.id.uuidString,
                "name": instance.name,
                "path": occurrence.path.map(\.uuidString),
                "depth": occurrence.depth,
                "bomIdentity": occurrence.bomIdentity.uuidString,
            ]
            if let parentID = occurrence.parentInstanceID {
                row["parentID"] = parentID.uuidString
            }
            if instance.isSubassembly {
                row["kind"] = "subassembly"
                row["stale"] = false
                rows.append(row)
                continue
            }
            if let referenceID = instance.sourceReferenceID,
               let reference = assembly.partReference(referenceID),
               !instance.isIndependentCopy {
                let status = referenceInstanceStatus(instance, reference: reference)
                row["bodyID"] = reference.stagedBodyID.uuidString
                row["kind"] = "reference"
                row["referenceID"] = referenceID.uuidString
                row["referenceStatus"] = status.code
                row["missing"] = status.missing
                row["stale"] = status.stale
                row["sourceRevision"] = reference.sourceRevision
                row["sourceContentHash"] = reference.sourceContentHash
                row["stagedGeometryHash"] = reference.stagedGeometryHash
                row["recordedRevision"] = reference.stagedRevision
                if let reason = status.reason { row["message"] = reason }
                if status.missing { missingReferences.append(referenceID.uuidString) }
                if status.stale { stale.append(instance.id.uuidString) }
                rows.append(row)
                continue
            }
            let source = body(for: effectiveBodyID(instance))
            let isStale = source == nil || instance.sourceRevision != source?.meshRevision
            row["bodyID"] = effectiveBodyID(instance).uuidString
            row["kind"] = instance.isIndependentCopy ? "independentCopy" : "part"
            row["stale"] = isStale
            if let recorded = instance.sourceRevision { row["recordedRevision"] = recorded }
            if let source { row["currentRevision"] = source.meshRevision }
            rows.append(row)
            if isStale { stale.append(instance.id.uuidString) }
        }
        return [
            "stale": stale,
            "staleCount": stale.count,
            "staleReferences": Array(Set(missingReferences)).sorted(),
            "missingReferences": Array(Set(missingReferences)).sorted(),
            "references": referencesPayload(assembly),
            "instances": rows,
        ]
    }


    // MARK: - Hierarchy and external references

    private func hierarchyAction() -> [String: Any] {
        let assembly: CADAssembly
        switch loadAssembly() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): assembly = loaded
        }
        let occurrences = assembly.occurrences(includeHidden: true)

        func node(_ instance: CADAssemblyInstance,
                  parentID: UUID?,
                  path: [UUID],
                  pathNames: [String],
                  depth: Int) -> [String: Any] {
            var row = instancePayload(instance)
            row["kind"] = instance.isSubassembly
                ? "subassembly" : (instance.sourceReferenceID != nil
                    ? "reference" : (instance.isIndependentCopy ? "independentCopy" : "part"))
            row["path"] = path.map(\.uuidString)
            row["pathNames"] = pathNames
            row["depth"] = depth
            if let parentID { row["parentID"] = parentID.uuidString }
            row["bomIdentity"] = occurrenceBomIdentity(instance).uuidString
            row["children"] = instance.children.map { child in
                node(child, parentID: instance.id,
                     path: path + [child.id],
                     pathNames: pathNames + [child.name],
                     depth: depth + 1)
            }
            row["constraints"] = instance.constraints.map { constraint -> [String: Any] in
                var payload = constraintPayload(constraint)
                payload["scope"] = "subassembly"
                payload["parentID"] = instance.id.uuidString
                return payload
            }
            if let referenceID = instance.sourceReferenceID,
               let reference = assembly.partReference(referenceID) {
                row["reference"] = referencePayload(reference)
            }
            return row
        }

        return [
            "ok": true,
            "mutated": false,
            "rootCount": assembly.instances.count,
            "totalCount": occurrences.count,
            "subassemblyCount": occurrences.filter { $0.subassemblyID != nil }.count,
            "referenceCount": assembly.partReferences.count,
            "maxDepth": occurrences.map(\.depth).max() ?? 0,
            "tree": assembly.instances.map { instance in
                node(instance, parentID: nil, path: [instance.id],
                     pathNames: [instance.name], depth: 0)
            },
            "rootConstraints": assembly.constraints.map { constraint -> [String: Any] in
                var payload = constraintPayload(constraint)
                payload["scope"] = "root"
                return payload
            },
            "integrity": assembly.integrityIssues(
                documentBodyIDs: Set(document.session.document.bodies.map { $0.id.raw }))
                .map(integrityPayload),
        ]
    }

    private func referencesAction() -> [String: Any] {
        switch loadAssembly() {
        case .failure(let error):
            return fail(error.code, error.message)
        case .success(let assembly):
            let rows = referencesPayload(assembly)
            let missing = rows.filter { ($0["missing"] as? Bool) == true }
            let updates = rows.filter { ($0["updateAvailable"] as? Bool) == true }
            return [
                "ok": true,
                "mutated": false,
                "count": rows.count,
                "missingCount": missing.count,
                "updateAvailableCount": updates.count,
                "references": rows,
                "integrity": assembly.integrityIssues(
                    documentBodyIDs: Set(document.session.document.bodies.map { $0.id.raw }))
                    .map(integrityPayload),
            ]
        }
    }

    private func addSubassemblyAction(_ args: [String: Any]) -> [String: Any] {
        let assembly: CADAssembly
        switch loadAssembly() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): assembly = loaded
        }
        var updated = assembly
        var parentID: UUID?
        if let raw = args["parentID"] ?? args["parentInstanceID"], !(raw is NSNull) {
            guard let parsed = uuidValue(raw) else {
                return fail("bad_parent_id", "parentID must be a subassembly instance UUID string.")
            }
            guard let parent = updated.instance(parsed), parent.isSubassembly else {
                return fail("unknown_subassembly", "parentID must reference an existing subassembly instance.")
            }
            parentID = parsed
        }
        let transform: CADTransform
        switch parseTransform(args["transform"]) {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let parsed): transform = parsed ?? .identity
        }
        let requested = (args["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = (requested?.isEmpty == false) ? requested! : "Subassembly"
        let subassemblyID = UUID()
        let container = CADAssemblyInstance(
            id: UUID(),
            name: uniqueInstanceName(base: baseName, in: updated),
            bodyID: subassemblyID,
            transform: transform,
            subassemblyID: subassemblyID)
        guard updated.appendInstance(container, parentID: parentID) else {
            return fail("placement_failed", "The subassembly could not be placed under the requested parent.")
        }
        if let failure = persist(updated) { return failure }
        var payload = instancePayload(container)
        payload["ok"] = true
        payload["mutated"] = true
        payload["subassemblyID"] = subassemblyID.uuidString
        payload["path"] = updated.instancePath(container.id)?.map(\.uuidString) ?? []
        return payload
    }

    private func placePartReferenceAction(_ args: [String: Any]) -> [String: Any] {
        let assembly: CADAssembly
        switch loadAssembly() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): assembly = loaded
        }
        var updated = assembly
        guard let referenceID = uuidValue(args["referenceID"]) else {
            return fail("bad_reference_id", "referenceID must be a part-reference UUID string.")
        }
        guard let reference = updated.partReference(referenceID) else {
            return fail("unknown_reference", "No part reference with that id.")
        }
        guard let staged = body(for: reference.stagedBodyID) else {
            return fail("missing_staged_body",
                        "The reference's cached staged body is missing; its geometry cannot be placed.")
        }
        var parentID: UUID?
        if let raw = args["parentID"] ?? args["parentInstanceID"], !(raw is NSNull) {
            guard let parsed = uuidValue(raw) else {
                return fail("bad_parent_id", "parentID must be a subassembly instance UUID string.")
            }
            guard let parent = updated.instance(parsed), parent.isSubassembly else {
                return fail("unknown_subassembly", "parentID must reference an existing subassembly instance.")
            }
            parentID = parsed
        }
        let transform: CADTransform
        switch parseTransform(args["transform"]) {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let parsed): transform = parsed ?? .identity
        }
        let requested = (args["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = (requested?.isEmpty == false) ? requested! : reference.name
        let independent = boolValue(args["independentCopy"]) ?? false
        let instance = CADAssemblyInstance(
            id: UUID(),
            name: uniqueInstanceName(base: baseName, in: updated),
            bodyID: reference.stagedBodyID,
            transform: transform,
            isIndependentCopy: independent,
            sourceRevision: staged.meshRevision,
            sourceReferenceID: referenceID)
        if independent {
            let copy = independentCopyTemplate(of: staged, in: document)
            let beforeAssembly = document.session.document.assemblyData
            var placed = instance
            placed.copiedBodyID = copy.id.raw
            let command = CADAssemblyStagedBodyCommand(
                title: "Reference Copy \(reference.name)",
                beforeAssembly: beforeAssembly,
                beforeBody: nil,
                bodyTemplate: copy,
                mutate: { assembly, revision in
                    var value = placed
                    value.sourceRevision = revision
                    _ = assembly.appendInstance(value, parentID: parentID)
                })
            document.session.perform(command)
            guard let current = currentAssemblyValue() else {
                return fail("encode_failed", "The assembly could not be read back after the copy was created.")
            }
            guard let stored = current.instance(instance.id) else {
                return fail("placement_failed", "The independent copy was not persisted.")
            }
            var payload = instancePayload(stored)
            payload["ok"] = true
            payload["mutated"] = true
            payload["referenceID"] = referenceID.uuidString
            payload["path"] = current.instancePath(stored.id)?.map(\.uuidString) ?? []
            return payload
        }
        guard updated.appendInstance(instance, parentID: parentID) else {
            return fail("placement_failed", "The reference could not be placed under the requested parent.")
        }
        if let failure = persist(updated) { return failure }
        var payload = instancePayload(instance)
        payload["ok"] = true
        payload["mutated"] = true
        payload["referenceID"] = referenceID.uuidString
        payload["path"] = updated.instancePath(instance.id)?.map(\.uuidString) ?? []
        return payload
    }

    private func moveInstanceAction(_ args: [String: Any]) -> [String: Any] {
        let assembly: CADAssembly
        switch loadAssembly() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): assembly = loaded
        }
        var updated = assembly
        guard let id = uuidValue(args["id"]) else {
            return fail("bad_instance_id", "id must be an instance UUID string.")
        }
        guard let moving = updated.instance(id) else {
            return fail("unknown_instance", "No assembly instance with that id.")
        }
        var parentID: UUID?
        if let raw = args["parentID"] ?? args["parentInstanceID"], !(raw is NSNull) {
            guard let parsed = uuidValue(raw) else {
                return fail("bad_parent_id", "parentID must be a subassembly instance UUID string.")
            }
            guard parsed != id else {
                return fail("cycle", "An instance cannot be placed inside itself.")
            }
            guard let parent = updated.instance(parsed), parent.isSubassembly else {
                return fail("unknown_subassembly", "parentID must reference an existing subassembly instance.")
            }
            guard !updated.isAncestor(id, of: parsed) else {
                return fail("cycle",
                            "A subassembly cannot be moved inside one of its own descendants.")
            }
            parentID = parsed
        }
        let movedIDs = Set(subtreeIDs(moving))
        if let scopeProblem = constraintScopeProblem(movingIDs: movedIDs,
                                                     toParent: parentID,
                                                     assembly: updated) {
            return fail("constraint_scope", scopeProblem)
        }
        guard updated.moveInstance(id, toParent: parentID) else {
            return fail("move_failed", "The instance could not be moved.")
        }
        if let failure = persist(updated) { return failure }
        guard let stored = updated.instance(id) else {
            return fail("unknown_instance", "The instance disappeared while moving it.")
        }
        var payload = instancePayload(stored)
        payload["ok"] = true
        payload["mutated"] = true
        payload["path"] = updated.instancePath(id)?.map(\.uuidString) ?? []
        payload["frame"] = "local"
        return payload
    }

    private func removePartReferenceAction(_ args: [String: Any]) -> [String: Any] {
        let assembly: CADAssembly
        switch loadAssembly() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): assembly = loaded
        }
        var updated = assembly
        guard let referenceID = uuidValue(args["id"]) ?? uuidValue(args["referenceID"]) else {
            return fail("bad_reference_id", "id must be a part-reference UUID string.")
        }
        guard let reference = updated.partReference(referenceID) else {
            return fail("unknown_reference", "No part reference with that id.")
        }
        let usage = updated.occurrences(includeHidden: true)
            .filter { $0.instance.sourceReferenceID == referenceID }
            .map { $0.instance.id.uuidString }
        guard usage.isEmpty else {
            return fail("reference_in_use",
                        "The reference is still placed by \(usage.count) instance(s); "
                        + "remove those placements first. Cached geometry was retained.")
        }
        updated.partReferences.removeAll { $0.id == referenceID }
        if let failure = persist(updated) { return failure }
        return [
            "ok": true,
            "mutated": true,
            "removedReference": referenceID.uuidString,
            "retainedStagedBodyID": reference.stagedBodyID.uuidString,
        ]
    }

    private func makeIndependentAction(_ args: [String: Any]) -> [String: Any] {
        let assembly: CADAssembly
        switch loadAssembly() {
        case .failure(let error): return fail(error.code, error.message)
        case .success(let loaded): assembly = loaded
        }
        guard let id = uuidValue(args["id"]) ?? uuidValue(args["instanceID"]) else {
            return fail("bad_instance_id", "id must be an instance UUID string.")
        }
        guard let instance = assembly.instance(id) else {
            return fail("unknown_instance", "No assembly instance with that id.")
        }
        guard !instance.isSubassembly else {
            return fail("subassembly_copy_unsupported",
                        "A subassembly placement is already shared; make its child parts independent instead.")
        }
        guard !instance.isIndependentCopy else {
            return ["ok": true, "mutated": false, "alreadyIndependent": true,
                    "instance": instancePayload(instance)]
        }
        guard let source = body(for: effectiveBodyID(instance)) else {
            return fail("unknown_body", "The instance's source body no longer resolves.")
        }
        let copy = independentCopyTemplate(of: source, in: document)
        let beforeAssembly = document.session.document.assemblyData
        let command = CADAssemblyStagedBodyCommand(
            title: "Make Independent \(instance.name)",
            beforeAssembly: beforeAssembly,
            beforeBody: nil,
            bodyTemplate: copy,
            mutate: { assembly, revision in
                assembly.updateInstance(id) { target in
                    target.copiedBodyID = copy.id.raw
                    target.isIndependentCopy = true
                    target.sourceRevision = revision
                }
            })
        document.session.perform(command)
        guard let current = currentAssemblyValue(), let stored = current.instance(id) else {
            return fail("encode_failed", "The independent copy could not be read back.")
        }
        var payload = instancePayload(stored)
        payload["ok"] = true
        payload["mutated"] = true
        payload["copiedBodyID"] = copy.id.raw.uuidString
        return payload
    }

    // MARK: - Reference bridge commit helpers

    /// Commit a newly staged external reference and its first shared
    /// placement as ONE undoable step. Called only by
    /// `CADAssemblyReferenceBridge` after it verified a user-authorized
    /// source document.
    func attachStagedReference(reference: CADPartReference,
                               stagedBody: Body,
                               instanceName: String?,
                               transform: CADTransform) -> [String: Any] {
        guard !document.isReadOnly else {
            return fail("document_read_only", "This document is read-only; the reference was not added.")
        }
        let assembly: CADAssembly
        do {
            assembly = try CADAssembly.decode(from: document.session.document.assemblyData)
        } catch {
            return fail("corrupt_assembly", "The stored assembly JSON could not be read; it was left untouched.")
        }
        guard stagedBody.id.raw == reference.stagedBodyID else {
            return fail("staged_body_mismatch", "The staged body identity does not match the reference pin.")
        }
        guard assembly.partReference(reference.id) == nil else {
            return fail("duplicate_reference", "A part reference with that identity already exists.")
        }
        guard assembly.instance(reference.stagedBodyID) == nil else {
            return fail("staged_body_mismatch", "The staged body identity collides with an instance.")
        }
        let baseName = instanceName
            ?? normalizedName(reference.name)
            ?? reference.name
        let instance = CADAssemblyInstance(
            id: UUID(),
            name: uniqueInstanceName(base: baseName, in: assembly),
            bodyID: reference.stagedBodyID,
            transform: transform,
            sourceRevision: nil,
            sourceReferenceID: reference.id)
        let beforeAssembly = document.session.document.assemblyData
        let command = CADAssemblyStagedBodyCommand(
            title: "Reference \(reference.name)",
            beforeAssembly: beforeAssembly,
            beforeBody: nil,
            bodyTemplate: stagedBody,
            mutate: { assembly, revision in
                var pinned = reference
                pinned.stagedRevision = revision
                assembly.partReferences.append(pinned)
                var placed = instance
                placed.sourceRevision = revision
                _ = assembly.appendInstance(placed, parentID: nil)
            })
        let tag = "cad.reference.attach:\(reference.id.uuidString)"
        guard let receipt = document.session.performOwned(command, tag: tag) else {
            return fail("document_read_only", "This document is read-only; the reference was not added.")
        }
        guard let current = currentAssemblyValue(),
              let stored = current.instance(instance.id),
              let pinned = current.partReference(reference.id) else {
            document.session.rollbackOwnedCommand(token: receipt.token)
            return fail("reference_commit_failed",
                        "The reference was not persisted and its in-memory command was rolled back.")
        }
        var payload = instancePayload(stored)
        payload["ok"] = true
        payload["mutated"] = true
        payload["referenceID"] = reference.id.uuidString
        payload["reference"] = referencePayload(pinned)
        payload["path"] = current.instancePath(stored.id)?.map(\.uuidString) ?? []
        return payload
    }

    /// Replace a staged body and re-pin its reference as ONE undoable step.
    /// Shared instances (at any nesting depth, including several
    /// subassemblies) keep their IDs and see the new body; independent copies
    /// are never touched because their effective body is `copiedBodyID`.
    func applyStagedReferenceUpdate(updatedReference: CADPartReference,
                                    stagedBody: Body,
                                    expectedStagedGeometryHash: String,
                                    expectedSourceContentHash: String) -> [String: Any] {
        guard !document.isReadOnly else {
            return fail("document_read_only", "This document is read-only; the reference was not updated.")
        }
        let assembly: CADAssembly
        do {
            assembly = try CADAssembly.decode(from: document.session.document.assemblyData)
        } catch {
            return fail("corrupt_assembly", "The stored assembly JSON could not be read; it was left untouched.")
        }
        guard let current = assembly.partReference(updatedReference.id) else {
            return fail("unknown_reference", "No part reference with that id.")
        }
        guard expectedSourceContentHash == current.sourceContentHash else {
            return fail("stale_reference", "The source pin changed while preparing the update.")
        }
        guard expectedStagedGeometryHash == current.stagedGeometryHash else {
            return fail("stale_reference", "The staged geometry changed while preparing the update.")
        }
        guard updatedReference.sourceDocumentID == current.sourceDocumentID,
              updatedReference.sourceBodyID == current.sourceBodyID,
              updatedReference.stagedBodyID == current.stagedBodyID else {
            return fail("staged_body_mismatch",
                        "A reference update cannot change the source/body identity; attach a new reference instead.")
        }
        guard stagedBody.id.raw == current.stagedBodyID,
              let existing = body(for: current.stagedBodyID) else {
            return fail("missing_staged_body", "The cached staged body is missing.")
        }
        guard CADAssemblyGeometryDigest.digest(of: existing) == current.stagedGeometryHash else {
            return fail("stale_reference", "The cached staged geometry changed; reload the reference.")
        }
        let independentIDs = assembly.occurrences(includeHidden: true)
            .filter { $0.instance.sourceReferenceID == current.id && $0.instance.isIndependentCopy }
            .map { $0.instance.id.uuidString }
        let beforeAssembly = document.session.document.assemblyData
        let command = CADAssemblyStagedBodyCommand(
            title: "Update Reference \(current.name)",
            beforeAssembly: beforeAssembly,
            beforeBody: existing,
            bodyTemplate: stagedBody,
            mutate: { assembly, revision in
                var pinned = updatedReference
                pinned.stagedRevision = revision
                if let index = assembly.partReferences.firstIndex(where: { $0.id == current.id }) {
                    assembly.partReferences[index] = pinned
                }
                for occurrence in assembly.occurrences(includeHidden: true) {
                    guard occurrence.instance.sourceReferenceID == current.id,
                          !occurrence.instance.isIndependentCopy else { continue }
                    assembly.updateInstance(occurrence.instance.id) { target in
                        target.sourceRevision = revision
                        target.bodyID = pinned.stagedBodyID
                    }
                }
            })
        let tag = "cad.reference.update:\(current.id.uuidString)"
        guard let receipt = document.session.performOwned(command, tag: tag) else {
            return fail("document_read_only", "This document is read-only; the reference was not updated.")
        }
        guard let latest = currentAssemblyValue(),
              let pinned = latest.partReference(current.id) else {
            document.session.rollbackOwnedCommand(token: receipt.token)
            return fail("reference_commit_failed",
                        "The reference update was not persisted and its in-memory command was rolled back.")
        }
        let sharedIDs = latest.occurrences(includeHidden: true)
            .filter { $0.instance.sourceReferenceID == current.id && !$0.instance.isIndependentCopy }
            .map { $0.instance.id.uuidString }
        return [
            "ok": true,
            "mutated": true,
            "referenceID": current.id.uuidString,
            "reference": referencePayload(pinned),
            "affectedSharedInstanceIDs": sharedIDs,
            "untouchedIndependentCopyIDs": independentIDs,
            "stagedBodyID": pinned.stagedBodyID.uuidString,
        ]
    }

    // MARK: - Reference payload helpers

    private func normalizedName(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func referencesPayload(_ assembly: CADAssembly) -> [[String: Any]] {
        assembly.partReferences.map { reference in
            var payload = referencePayload(reference)
            let staged = body(for: reference.stagedBodyID)
            let geometryHash = staged.map { CADAssemblyGeometryDigest.digest(of: $0) }
            let geometryChanged = geometryHash != nil && geometryHash != reference.stagedGeometryHash
            let shared = assembly.occurrences(includeHidden: true).filter {
                $0.instance.sourceReferenceID == reference.id && !$0.instance.isIndependentCopy
            }
            let copies = assembly.occurrences(includeHidden: true).filter {
                $0.instance.sourceReferenceID == reference.id && $0.instance.isIndependentCopy
            }
            var containers: [(UUID, String)] = []
            var seenContainers = Set<UUID>()
            for occurrence in shared {
                for ancestorID in occurrence.path.dropLast() {
                    guard let ancestor = assembly.instance(ancestorID),
                          ancestor.isSubassembly,
                          seenContainers.insert(ancestorID).inserted else { continue }
                    containers.append((ancestorID, ancestor.name))
                }
            }
            let missing = staged == nil || reference.missingReason != nil
            let status: String
            if missing {
                status = "missing"
            } else if reference.hasAvailableUpdate {
                status = "updateAvailable"
            } else if geometryChanged {
                status = "stagedGeometryChanged"
            } else {
                status = "resolved"
            }
            payload["status"] = status
            payload["missing"] = missing
            payload["updateAvailable"] = reference.hasAvailableUpdate
            payload["geometryChanged"] = geometryChanged
            payload["cachedGeometryAvailable"] = staged.map { !$0.render.positions.isEmpty } ?? false
            payload["sharedInstanceCount"] = shared.count
            payload["independentCopyCount"] = copies.count
            payload["sharedInstanceIDs"] = shared.map { $0.instance.id.uuidString }
            payload["independentCopyIDs"] = copies.map { $0.instance.id.uuidString }
            payload["subassemblies"] = containers.map { container -> [String: Any] in
                ["id": container.0.uuidString, "name": container.1]
            }
            payload["instancePaths"] = shared.map { $0.path.map(\.uuidString) }
            payload["bomIdentity"] = reference.id.uuidString
            payload["bomBodyID"] = reference.stagedBodyID.uuidString
            return payload
        }
    }

    private func referencePayload(_ reference: CADPartReference) -> [String: Any] {
        var payload: [String: Any] = [
            "id": reference.id.uuidString,
            "name": reference.name,
            "kind": reference.kind.rawValue,
            "sourceDocumentID": reference.sourceDocumentID.uuidString,
            "sourceBodyID": reference.sourceBodyID.uuidString,
            "sourceDocumentName": reference.sourceDocumentName,
            "sourceBodyName": reference.sourceBodyName,
            "verifierSchemaVersion": reference.verifierSchemaVersion,
            "sourceSchemaVersion": reference.sourceSchemaVersion,
            "sourceRevision": reference.sourceRevision,
            "sourceContentHash": reference.sourceContentHash,
            "stagedBodyID": reference.stagedBodyID.uuidString,
            "stagedGeometryHash": reference.stagedGeometryHash,
            "stagedRevision": reference.stagedRevision,
            "pinnedAt": reference.pinnedAt.timeIntervalSince1970,
            "updateAvailable": reference.hasAvailableUpdate,
        ]
        if let value = reference.availableSourceRevision { payload["availableSourceRevision"] = value }
        if let value = reference.availableSourceContentHash { payload["availableSourceContentHash"] = value }
        if let value = reference.availableSchemaVersion { payload["availableSchemaVersion"] = value }
        if let value = reference.lastCheckedAt { payload["lastCheckedAt"] = value.timeIntervalSince1970 }
        if let value = reference.missingReason { payload["missingReason"] = value }
        return payload
    }

    private func integrityPayload(_ issue: CADAssemblyIntegrityIssue) -> [String: Any] {
        var payload: [String: Any] = ["id": issue.id.uuidString, "kind": issue.kind,
                                      "message": issue.message]
        if let instanceID = issue.instanceID { payload["instanceID"] = instanceID.uuidString }
        if let referenceID = issue.referenceID { payload["referenceID"] = referenceID.uuidString }
        return payload
    }

    private func referenceInstanceStatus(_ instance: CADAssemblyInstance,
                                         reference: CADPartReference)
    -> (code: String, missing: Bool, stale: Bool, reason: String?) {
        if instance.isIndependentCopy {
            return (code: "independentCopy", missing: false, stale: false, reason: nil)
        }
        guard let staged = body(for: effectiveBodyID(instance)) else {
            return (code: "missing", missing: true, stale: true,
                    reason: reference.missingReason ?? "The cached staged body is missing.")
        }
        if reference.missingReason != nil {
            return (code: "missing", missing: true, stale: true, reason: reference.missingReason)
        }
        if CADAssemblyGeometryDigest.digest(of: staged) != reference.stagedGeometryHash {
            return (code: "stagedGeometryChanged", missing: false, stale: true,
                    reason: "The cached staged geometry no longer matches the pinned source.")
        }
        if reference.hasAvailableUpdate {
            return (code: "updateAvailable", missing: false, stale: false,
                    reason: "A newer source revision was detected; apply an explicit update.")
        }
        return (code: "resolved", missing: false, stale: false, reason: nil)
    }

    private func occurrenceBomIdentity(_ instance: CADAssemblyInstance) -> UUID {
        instance.bomIdentity
    }

    private func currentAssemblyValue() -> CADAssembly? {
        try? CADAssembly.decode(from: document.session.document.assemblyData)
    }

    private func subtreeIDs(_ instance: CADAssemblyInstance) -> [UUID] {
        var result: [UUID] = [instance.id]
        for child in instance.children {
            result.append(contentsOf: subtreeIDs(child))
        }
        return result
    }

    private func removeConstraints(referencing ids: Set<UUID>,
                                   in list: inout [CADAssemblyInstance],
                                   removedIDs: inout [String]) {
        for index in list.indices {
            let removed = list[index].constraints.filter { constraint in
                ids.contains(constraint.instanceA)
                    || (constraint.instanceB.map { ids.contains($0) } ?? false)
            }.map(\.id.uuidString)
            if !removed.isEmpty {
                removedIDs.append(contentsOf: removed)
                list[index].constraints.removeAll { constraint in
                    ids.contains(constraint.instanceA)
                        || (constraint.instanceB.map { ids.contains($0) } ?? false)
                }
            }
            removeConstraints(referencing: ids, in: &list[index].children,
                              removedIDs: &removedIDs)
        }
    }

    private func constraintScopeProblem(movingIDs: Set<UUID>,
                                        toParent parentID: UUID?,
                                        assembly: CADAssembly) -> String? {
        if parentID != nil {
            for constraint in assembly.constraints where
                movingIDs.contains(constraint.instanceA)
                || (constraint.instanceB.map { movingIDs.contains($0) } ?? false) {
                return "A root constraint references the moved instance; remove or re-scope it first."
            }
        }
        for occurrence in assembly.occurrences(includeHidden: true) {
            let container = occurrence.instance
            guard container.isSubassembly, !movingIDs.contains(container.id) else { continue }
            for constraint in container.constraints where
                movingIDs.contains(constraint.instanceA)
                || (constraint.instanceB.map { movingIDs.contains($0) } ?? false) {
                return "A constraint in subassembly '\(container.name)' references the moved instance; "
                    + "remove or re-scope it first."
            }
        }
        return nil
    }

    private func independentCopyTemplate(of body: Body, in document: FloeCADDocument) -> Body {
        var copy = Body(id: BodyID(),
                        name: document.session.document.uniqueBodyName(base: body.name + " Copy"),
                        transform: body.transform,
                        primitive: body.primitive,
                        render: body.render,
                        revision: 0)
        copy.euclid = body.euclid
        copy.brep = body.brep
        copy.material = body.material
        copy.materialFaceBindings = body.materialFaceBindings
        copy.isHidden = body.isHidden
        return copy
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

    private func uniqueInstanceName(base: String, in assembly: CADAssembly) -> String {
        let existing = Set(assembly.occurrences(includeHidden: true).map { $0.instance.name })
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
        if let sourceReferenceID = instance.sourceReferenceID {
            payload["referenceID"] = sourceReferenceID.uuidString
        }
        if let subassemblyID = instance.subassemblyID {
            payload["subassemblyID"] = subassemblyID.uuidString
        }
        payload["isSubassembly"] = instance.isSubassembly
        payload["childCount"] = instance.children.count
        payload["bomIdentity"] = instance.bomIdentity.uuidString
        if let resolvedBodyID = instance.resolvedBodyID {
            payload["effectiveBodyID"] = resolvedBodyID.uuidString
        } else {
            payload["effectiveBodyID"] = NSNull()
        }
        let resolved = instance.isSubassembly ? nil : body(for: effectiveBodyID(instance))
        payload["resolved"] = instance.isSubassembly || resolved != nil
        if let resolved { payload["currentRevision"] = resolved.meshRevision }
        return payload
    }

    private func constraintPayload(_ constraint: CADAssemblyConstraint) -> [String: Any] {
        var payload: [String: Any] = [
            "id": constraint.id.uuidString,
            "kind": constraint.kind.rawValue,
            "instanceA": constraint.instanceA.uuidString,
            "pointA": Self.vectorPayload(constraint.pointA),
            "directionA": Self.vectorPayload(constraint.directionA),
            "suppressed": constraint.isSuppressed,
        ]
        if let instanceB = constraint.instanceB { payload["instanceB"] = instanceB.uuidString }
        if let pointB = constraint.pointB { payload["pointB"] = Self.vectorPayload(pointB) }
        if let directionB = constraint.directionB {
            payload["directionB"] = Self.vectorPayload(directionB)
        }
        if let value = constraint.value {
            payload["value"] = value
            payload["valueUnit"] = constraint.kind == .angle ? "degrees" : "mm"
        }
        if let sourceRevisionA = constraint.sourceRevisionA {
            payload["sourceRevisionA"] = sourceRevisionA
        }
        if let sourceRevisionB = constraint.sourceRevisionB {
            payload["sourceRevisionB"] = sourceRevisionB
        }
        return payload
    }

    private func transformPayload(_ transform: CADTransform) -> [String: Any] {
        [
            "position": Self.vectorPayload(transform.position),
            "rotation": [transform.rotation.x, transform.rotation.y,
                         transform.rotation.z, transform.rotation.w],
            "scale": Self.vectorPayload(transform.scale),
        ]
    }

    private nonisolated static func vectorPayload(_ vector: SIMD3<Double>) -> [Double] {
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
        // Swift's numeric array bridges also accept CFBoolean. Every element
        // must pass the same number check as scalar dimensions.
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
        if let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
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
        /// True only when the system is grounded, exactly analyzed and the
        /// ACTUAL residual solve converges. A rank-zero but inconsistent or
        /// non-convergent system is never called fully constrained.
        var fullyConstrained: Bool
        var unconstrained: [UUID]
        var redundant: [UUID]
        var exact: Bool
        /// Constraints the solver could not resolve (missing instance/value).
        var invalidReferences: [UUID] = []
        /// Constraints whose residual stayed above tolerance, so the rank
        /// count is diagnostic only and MUST NOT be presented as live freedom.
        var conflicting: [UUID] = []
        var solved: Bool = true
        /// A rank/DOF read is trustworthy only when the same assembly actually
        /// solves, every reference resolves, and the rank is in the exact
        /// 64-instance / 128-constraint window. Beyond it the rank is still
        /// returned but `fullyConstrained` is never claimed.
        var credible: Bool { solved && invalidReferences.isEmpty && exact }
    }

    static func degreesOfFreedom(_ assembly: CADAssembly,
                                 modelScale: Double = 1) -> DOFResult {
        let index = resolvableIndex(assembly)
        // The true residual solver is the honesty check: rank alone cannot
        // tell whether two different targets are inconsistent. This is pure
        // value math and is never persisted.
        let dryRun = solve(assembly, modelScale: modelScale)
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
            && dryRun.solved && dryRun.invalidReferences.isEmpty

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
        // constraints are never flagged. The incremental orthonormal basis
        // stays exact at the 64-instance / 128-constraint boundary instead of
        // silently returning an empty list beyond a small window.
        let redundant = exact
            ? incrementalRedundancy(active, columns: columns) { rows(for: $0) }
            : []

        return DOFResult(perInstance: perInstance,
                         total: total,
                         relative: relative,
                         globalRigid: globalRigid,
                         fullyConstrained: fullyConstrained,
                         unconstrained: unconstrained,
                         redundant: redundant,
                         exact: exact,
                         invalidReferences: dryRun.invalidReferences,
                         conflicting: dryRun.conflicting,
                         solved: dryRun.solved)
    }

    /// Order-stable redundancy by modified Gram-Schmidt over the normalized
    /// constraint rows. Unlike re-running Gauss-Jordan per prefix, this is
    /// O(rows × basis × columns), so the supported 128-row exact boundary is
    /// still bounded. A constraint is redundant when none of its rows adds an
    /// independent direction; duplicate/loop rows therefore flag the LATER
    /// copy, while a genuinely new loop closure still increases the rank.
    private static func incrementalRedundancy(
        _ constraints: [CADAssemblyConstraint],
        columns: Int,
        rows: (CADAssemblyConstraint) -> [[Double]]
    ) -> [UUID] {
        var basis: [[Double]] = []
        basis.reserveCapacity(min(columns, constraints.count * 6))
        var redundant: [UUID] = []
        let threshold = 1e-8

        for constraint in constraints {
            var contributed = false
            for raw in rows(constraint) {
                guard raw.count == columns else { continue }
                let norm = sqrt(raw.reduce(0) { $0 + $1 * $1 })
                guard norm.isFinite, norm > 1e-15 else { continue }
                var vector = raw.map { $0 / norm }
                // Two passes keep the basis stable for near-duplicate rows.
                for _ in 0..<2 {
                    for unit in basis {
                        var dot = 0.0
                        for index in 0..<columns { dot += vector[index] * unit[index] }
                        guard dot != 0 else { continue }
                        for index in 0..<columns { vector[index] -= dot * unit[index] }
                    }
                }
                var residualSquared = 0.0
                for value in vector { residualSquared += value * value }
                let residual = sqrt(residualSquared)
                guard residual.isFinite, residual > threshold,
                      basis.count < columns else { continue }
                for index in 0..<columns { vector[index] /= residual }
                basis.append(vector)
                contributed = true
            }
            if !contributed { redundant.append(constraint.id) }
        }
        return redundant
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
