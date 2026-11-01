//
//  CADMeshService.swift
//  FloeCADKit
//
//  Mesh-level editing for one FloeCAD document: combine, Euclid CSG booleans,
//  transforms, normal recomputation, boundary/loose-edge reporting, welding
//  repair, cluster simplification and materials.
//
//  Exactness rules (AGENTS.md / kernel invariants):
//   * combine / boolean / repair / simplify rebuild the render mesh from
//     triangles. A body with an analytic B-rep is REFUSED unless the caller
//     passes `forceMesh:true`; the refused op changes nothing. A forced
//     result is marked `"exactness":"mesh"` and drops the B-rep. boolean also
//     reports `inputExactness` ("precise" | "mesh" | "mixed") and how many
//     analytic inputs the forced mesh result dropped — a precise or mixed
//     input is never silently reported as preserved.
//   * transform / recomputeNormals / boundary / material / image keep any
//     B-rep untouched and report `"exactness":"preserved"`.
//   * Every successful geometry edit goes through the document's undoable
//     command path in ONE step and returns `"mutated":true`.
//
//  Bounds: at most 16 input bodies and 500k input triangles per operation, a
//  10-second wall-clock deadline, and cancellation checks inside every loop
//  (Euclid CSG receives the same `isCancelled` closure). Frozen heavy inputs
//  are validated on the compute thread before Euclid conversion/CSG: finite
//  positions/normals/UVs, matching buffer counts, whole triangles, in-range
//  indices and a finite positive transform. A malformed snapshot is refused
//  with `invalid_mesh` and changes nothing. Caller cancellation
//  is a separate signal from the deadline: a lock-guarded token is flipped by
//  the caller Task's cancellation handler and read by Euclid's CSG from its
//  Dispatch worker threads, where `Task.isCancelled` is not meaningful. Every
//  pre-commit boundary refuses a cancelled operation, so a partial Euclid
//  result is never published as success. No file paths are accepted anywhere;
//  image bytes arrive base64-encoded or via an existing document image.
//
//  X08 execution boundary: combine / boolean / repair / simplify snapshot the
//  exact input VALUES on the MainActor, run the heavy render/Euclid work in a
//  service-owned detached task, re-check the document identity + input
//  ownership on the MainActor, and only then make the one undoable commit.
//  `Task.detached` is joined before the caller returns; a cancelled or stale
//  operation discards its worker result instead of publishing partial geometry.
//
//  Actions / args (all share `bodyID` or `bodyIDs`):
//   * combine          bodyIDs, name? -> new body (world transforms baked).
//   * boolean          op (union|subtract|intersect), target, tools, name?
//                      -> new body; empty result is refused.
//   * transform        bodyID, translate [x,y,z]?, rotate
//                      {axis:[x,y,z], angleDegrees}?, scale? — rotation and
//                      scale pivot on the body's current placement
//                      (translation); never drops a B-rep.
//   * recomputeNormals bodyID(s) — area-weighted normals from triangles.
//   * boundary         bodyID(s) — boundary/non-manifold edge counts+bounds.
//   * repair           bodyID(s), tolerance (mm, default 1e-3) — weld +
//                      drop degenerate triangles.
//   * simplify         bodyID(s), ratio (0…1) or tolerance (mm) — cluster
//                      decimation, never below 4 triangles.
//   * material         bodyID(s), color [r,g,b(,a)], metallic?, roughness?,
//                      opacity? (0…1) — non-destructive.
//   * image            bodyID(s), imageBase64 (PNG/JPEG) or imageID of an
//                      inserted document image — sets the material texture.
//   * text             always refused with `text_mesh_unavailable`.
//  Destructive actions accept `forceMesh:true` to acknowledge dropping an
//  analytic B-rep; without it they return `brep_body_refused`.
//

import Foundation
import CoreFoundation
import simd
import Euclid

/// One mesh operation's caller-cancellation state.
///
/// Euclid runs its CSG halves through `DispatchQueue.concurrentPerform`; on
/// those worker threads `Task.isCancelled` is not the caller task's flag, so a
/// plain `Task.isCancelled` check in the `isCancelled` closure cannot stop a
/// long BSP. The service wraps the operation in the caller's
/// `withTaskCancellationHandler`; `cancel()` runs immediately on whatever
/// thread requests cancellation and this lock-guarded flag is the one signal
/// every CSG worker can read. Service phase guards and the single document
/// commit read the same flag, but through the side-effect-free getter.
///
/// `nonisolated` because CSG worker threads call `kernelIsCancelled` outside
/// the MainActor. The internal `checkpoint` initializer lets the focused source
/// tests cancel at a deterministic Euclid checkpoint (no wall-clock sleep);
/// only the kernel callback runs it, so preparation/pre-commit guards can never
/// be mistaken for real CSG progress. It has no effect in production, where
/// cancellation comes from the caller's task cancellation handler or the
/// service-owned `cancelActiveOperation`.
nonisolated final class CADMeshCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private let checkpoint: (@Sendable () -> Void)?
    private var cancelled = false

    init() {
        checkpoint = nil
    }

    init(checkpoint: (@Sendable () -> Void)?) {
        self.checkpoint = checkpoint
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    /// Side-effect-free token read for service phase guards and the commit
    /// fence. Never invokes the test checkpoint.
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// The ONE callback handed to Euclid's `isCancelled` closure. The focused
    /// checkpoint runs before the lock so a checkpoint may call `cancel()`
    /// without a self-deadlock; production has no checkpoint.
    func kernelIsCancelled() -> Bool {
        checkpoint?()
        return isCancelled
    }
}

/// The detached computational values for one body. A `Body` with a live B-rep
/// handle, undo closure, document/session reference or UIKit state never enters
/// this boundary. `render` and `transform` are value copies; `euclid` is the
/// body's `Euclid.Mesh` value (declared Sendable by pinned Euclid 0.9.6, whose
/// Storage caches are lock-guarded), or nil so the worker rebuilds it from the
/// frozen render buffers with the existing `EuclidBridge.euclidMesh` path.
nonisolated struct CADMeshInputSnapshot: Sendable {
    let id: BodyID
    let name: String
    let meshRevision: UInt64
    let transform: Transform3D
    let render: RenderMesh
    let euclid: Euclid.Mesh?

    var triangleCount: Int { render.triangleCount }

    func euclidMesh() -> Euclid.Mesh {
        euclid ?? EuclidBridge.euclidMesh(from: render)
    }
}

nonisolated enum CADMeshBooleanKind: String, Sendable {
    case union, subtract, intersect
}

/// The exact in-memory geometry identity a commit is allowed to touch.
/// `changeCount` covers every command/undo/redo/preview epoch, and each input
/// body's `meshRevision` covers a direct geometry swap. Persistence revisions
/// are deliberately NOT part of this fence: an autosave of an unchanged model
/// must not discard a valid in-flight result. The commit re-reads both on the
/// MainActor and refuses a stale result.
nonisolated struct CADMeshSourceToken: Equatable, Sendable {
    struct BodyState: Equatable, Sendable {
        let id: BodyID
        let meshRevision: UInt64
    }

    let changeCount: Int
    let bodies: [BodyState]
}

nonisolated enum CADMeshPlan: Sendable {
    case combine(inputs: [CADMeshInputSnapshot], name: String)
    case boolean(kind: CADMeshBooleanKind,
                 inputs: [CADMeshInputSnapshot],
                 inputExactness: String,
                 brepBodyCount: Int)
    case repair(inputs: [CADMeshInputSnapshot], tolerance: Double)
    case simplify(inputs: [CADMeshInputSnapshot], ratio: Double?, tolerance: Double?)

    var action: String {
        switch self {
        case .combine: return "combine"
        case .boolean: return "boolean"
        case .repair: return "repair"
        case .simplify: return "simplify"
        }
    }

    var inputs: [CADMeshInputSnapshot] {
        switch self {
        case .combine(let inputs, _): return inputs
        case .boolean(_, let inputs, _, _): return inputs
        case .repair(let inputs, _): return inputs
        case .simplify(let inputs, _, _): return inputs
        }
    }

    var inputTriangleCount: Int {
        inputs.reduce(0) { $0 + $1.triangleCount }
    }
}

nonisolated struct CADMeshRepairEntry: Sendable {
    let bodyID: BodyID
    let beforeTriangles: Int
    let afterTriangles: Int
    let weldedVertices: Int
    let removedTriangles: Int

    var payload: [String: Any] {
        ["bodyID": bodyID.raw.uuidString,
         "beforeTriangles": beforeTriangles,
         "afterTriangles": afterTriangles,
         "weldedVertices": weldedVertices,
         "removedTriangles": removedTriangles]
    }
}

nonisolated struct CADMeshSimplifyEntry: Sendable {
    let bodyID: BodyID
    let beforeTriangles: Int
    let afterTriangles: Int
    let targetTriangles: Int?
    let cellSize: Double?
    let tolerance: Double?

    var payload: [String: Any] {
        var entry: [String: Any] = ["bodyID": bodyID.raw.uuidString,
                                    "beforeTriangles": beforeTriangles,
                                    "afterTriangles": afterTriangles]
        if let tolerance { entry["tolerance"] = tolerance }
        if let targetTriangles { entry["targetTriangles"] = targetTriangles }
        if let cellSize { entry["cellSize"] = cellSize }
        return entry
    }
}

nonisolated struct CADMeshReplacement: Sendable {
    let id: BodyID
    let render: RenderMesh
    let edges: FeatureEdgeSet
}

/// Worker result. Only Sendable values cross the boundary; every JSON reply is
/// built after the MainActor re-check, never on the compute thread.
nonisolated enum CADMeshComputation: Sendable {
    case cancelled
    case timedOut
    case refused(code: String, message: String)
    case combine(mesh: Euclid.Mesh,
                 render: RenderMesh,
                 edges: FeatureEdgeSet,
                 previewHash: String,
                 previewSnapshot: CADTransientMeshPreview.Snapshot?)
    case boolean(mesh: Euclid.Mesh,
                 render: RenderMesh,
                 edges: FeatureEdgeSet,
                 previewHash: String,
                 previewSnapshot: CADTransientMeshPreview.Snapshot?)
    case replacements(_ replacements: [CADMeshReplacement],
                      repairEntries: [CADMeshRepairEntry],
                      simplifyEntries: [CADMeshSimplifyEntry],
                      previewHash: String,
                      previewSnapshot: CADTransientMeshPreview.Snapshot?,
                      previewTriangleCount: Int)
}

/// Test-only observation of one REAL detached compute. It is emitted only
/// when `CADMeshService.testComputeObservation` is installed by a test, so the
/// production path pays no clock read. `computeSeconds` covers off-main input
/// validation plus the actual Euclid/render/weld work and deliberately excludes
/// the scheduling probe, which runs before this measurement starts.
nonisolated struct CADMeshComputeObservation: Sendable {
    let action: String
    let inputBodies: Int
    let inputTriangles: Int
    let computeSeconds: Double
    let ranOnMainThread: Bool
    let outcome: String
}

/// Result of the off-main frozen-input validation. A refusal carries the same
/// error code/message shape the service returns to callers.
private nonisolated enum CADMeshInputValidation: Sendable {
    case valid
    case interrupted
    case refused(code: String, message: String)
}

@MainActor
final class CADMeshOperationRun {
    let id = UUID()
    let documentKey: ObjectIdentifier
    let action: String
    let cancellation: CADMeshCancellation
    private var worker: Task<CADMeshComputation, Never>?

    init(documentKey: ObjectIdentifier,
         action: String,
         cancellation: CADMeshCancellation) {
        self.documentKey = documentKey
        self.action = action
        self.cancellation = cancellation
    }

    func attach(_ task: Task<CADMeshComputation, Never>) {
        worker = task
        if cancellation.isCancelled { task.cancel() }
    }

    func cancel() {
        cancellation.cancel()
        worker?.cancel()
    }
}

@MainActor
public final class CADMeshService {
    public nonisolated static let maxInputBodies = 16
    public nonisolated static let maxInputTriangles = 500_000
    public static let wallClockLimitSeconds: Double = 10
    public static let maxImageBytes = 8 * 1024 * 1024

    private let document: FloeCADDocument
    /// Per-service deadline used by every operation. The public initializer
    /// keeps the shared 10-second limit; the internal one exists only so the
    /// deadline refusal path can be exercised deterministically.
    private let wallClockLimit: Double

    public convenience init(document: FloeCADDocument) {
        self.init(document: document, wallClockLimitSeconds: Self.wallClockLimitSeconds)
    }

    init(document: FloeCADDocument, wallClockLimitSeconds: Double) {
        self.document = document
        self.wallClockLimit = max(wallClockLimitSeconds, 0)
    }

    // MARK: Action router

    /// Test-only seam called at the START of the real detached heavy worker,
    /// before any vector/Euclid work. A suite can prove the compute thread and
    /// hold it at a deterministic scheduling gate; result geometry is still the
    /// real kernel output. Never set in production.
    nonisolated(unsafe) static var testHeavyComputeProbe: (@Sendable (String, Int) -> Void)?

    /// Test-only seam called inside the detached worker after the real result
    /// is computed but before it returns to the MainActor. Used to edit/close
    /// the source while a stale result is in flight. Never set in production.
    nonisolated(unsafe) static var testBeforeCommitProbe: (@Sendable () -> Void)?

    /// Test-only measurement sink fed by the real compute wrapper. It records
    /// only measured values (no synthesized peak or timer); production leaves
    /// it nil and then takes no clock or observation sample.
    nonisolated(unsafe) static var testComputeObservation:
        (@Sendable (CADMeshComputeObservation) -> Void)?

    private static var activeRuns: [ObjectIdentifier: CADMeshOperationRun] = [:]

    /// Synchronous entry point kept for direct unit tests and existing callers.
    /// Production UI/tool/proposal paths use `handleAsync`; heavy actions here
    /// run through the same prepare/compute/commit boundary, with compute on
    /// the caller's actor. A caller cancellation is still observed at every
    /// service boundary and before the one commit.
    public func handle(action: String, args: [String: Any]) -> [String: Any] {
        let cancellation = CADMeshCancellation()
        if Task.isCancelled { cancellation.cancel() }
        return handle(action: action, args: args, cancellation: cancellation)
    }

    /// Async entry point for the visible panel, agent tools and proposal
    /// apply. Heavy mesh actions snapshot their inputs on the MainActor and
    /// run the actual Euclid/render work in a service-owned detached worker.
    /// The caller's task cancellation flips the thread-safe token immediately
    /// and cancels the joined worker; a late result is discarded before commit.
    public func handleAsync(action: String, args: [String: Any]) async -> [String: Any] {
        await handleAsync(action: action, args: args, cancellation: CADMeshCancellation())
    }

    func handleAsync(action: String, args: [String: Any],
                     cancellation: CADMeshCancellation) async -> [String: Any] {
        if Task.isCancelled { cancellation.cancel() }
        guard !document.isClosed else { return Self.closedReply() }
        if let refusal = CADServiceOperations.readOnlyRefusal(document: document, kind: "mesh", action: action) { return refusal }
        switch action {
        case "combine", "boolean", "repair", "simplify":
            switch prepare(action: action, args: args) {
            case .refusal(let reply):
                return reply
            case .heavy(let plan):
                return await runHeavyOffMain(plan, args: args, cancellation: cancellation)
            case .light:
                break
            }
        default:
            break
        }
        return handle(action: action, args: args, cancellation: cancellation)
    }

    func handle(action: String, args: [String: Any],
                cancellation: CADMeshCancellation) -> [String: Any] {
        if cancellation.isCancelled || Task.isCancelled { return Self.cancelledReply() }
        guard !document.isClosed else { return Self.closedReply() }
        if let refusal = CADServiceOperations.readOnlyRefusal(document: document, kind: "mesh", action: action) { return refusal }
        switch action {
        case "combine", "boolean", "repair", "simplify":
            switch prepare(action: action, args: args) {
            case .refusal(let reply):
                return reply
            case .heavy(let plan):
                return runHeavySynchronously(plan, args: args, cancellation: cancellation)
            case .light:
                break
            }
        default:
            break
        }
        switch action {
        case "transform": return transform(args)
        case "recomputeNormals": return recomputeNormals(args)
        case "boundary": return boundary(args)
        case "material": return material(args)
        case "text": return text(args)
        case "image": return image(args)
        default:
            return Self.fail("unknown_action",
                             "Unknown mesh action '\(action)'. Use combine, boolean, transform, "
                             + "recomputeNormals, boundary, repair, simplify, material, text or image.")
        }
    }

    /// Request cancellation of the one active heavy mesh operation for this
    /// document. The awaiting caller is released only after the detached
    /// worker observes the flag and returns; no partial result is accepted.
    /// The visible panel and document close use this owner-level path.
    @discardableResult
    static func cancelActiveOperation(for document: FloeCADDocument) -> Bool {
        guard let run = activeRuns[ObjectIdentifier(document)] else { return false }
        run.cancel()
        return true
    }

    /// Current progress identity for the one active operation, or nil. The
    /// service (not a view) owns this state.
    func activeOperationStatus() -> [String: Any]? {
        guard let run = Self.activeRuns[ObjectIdentifier(document)] else { return nil }
        return ["ok": true,
                "active": true,
                "action": run.action,
                "cancelRequested": run.cancellation.isCancelled,
                "mutated": false]
    }

    private func beginRun(action: String,
                          cancellation: CADMeshCancellation) -> CADMeshOperationRun {
        let key = ObjectIdentifier(document)
        Self.activeRuns[key]?.cancel()
        let run = CADMeshOperationRun(documentKey: key,
                                      action: action,
                                      cancellation: cancellation)
        Self.activeRuns[key] = run
        return run
    }

    private static func finishRun(_ run: CADMeshOperationRun) {
        if activeRuns[run.documentKey]?.id == run.id {
            activeRuns[run.documentKey] = nil
        }
    }

    private enum CADMeshPreparation {
        case heavy(CADMeshPlan)
        case light
        case refusal([String: Any])
    }

    private func prepare(action: String, args: [String: Any]) -> CADMeshPreparation {
        switch action {
        case "combine": return prepareCombine(args)
        case "boolean": return prepareBoolean(args)
        case "repair": return prepareRepair(args)
        case "simplify": return prepareSimplify(args)
        default: return .light
        }
    }

    private func snapshot(_ bodies: [Body]) -> [CADMeshInputSnapshot] {
        bodies.map {
            CADMeshInputSnapshot(id: $0.id,
                                 name: $0.name,
                                 meshRevision: $0.meshRevision,
                                 transform: $0.transform,
                                 render: $0.render,
                                 euclid: $0.euclid)
        }
    }

    private func sourceToken(for inputs: [CADMeshInputSnapshot]) -> CADMeshSourceToken {
        CADMeshSourceToken(changeCount: document.session.changeCount,
                           bodies: inputs.map {
                               CADMeshSourceToken.BodyState(id: $0.id,
                                                            meshRevision: $0.meshRevision)
                           })
    }

    /// Re-reads the live source identity. Used after the worker returns and
    /// again immediately before the commit.
    private func currentSourceToken(for inputs: [CADMeshInputSnapshot]) -> CADMeshSourceToken {
        let live = document.session.document
        return CADMeshSourceToken(
            changeCount: document.session.changeCount,
            bodies: inputs.map { input in
                CADMeshSourceToken.BodyState(
                    id: input.id,
                    meshRevision: live.bodies.first(where: { $0.id == input.id })?.meshRevision
                        ?? UInt64.max)
            })
    }

    private func commitFence(_ plan: CADMeshPlan,
                             source: CADMeshSourceToken,
                             cancellation: CADMeshCancellation) -> [String: Any]? {
        if cancellation.isCancelled || Task.isCancelled { return Self.cancelledReply() }
        guard !document.isClosed else { return Self.closedReply() }
        if let refusal = CADServiceOperations.readOnlyRefusal(document: document,
                                                              kind: "mesh",
                                                              action: plan.action) {
            return refusal
        }
        guard currentSourceToken(for: plan.inputs) == source else {
            return Self.sourceChangedReply()
        }
        return nil
    }

    /// Compatibility/test-only synchronous path. It runs the same prepare and
    /// compute (including frozen-input validation) on the caller's actor;
    /// production UI, Bridge and proposal routes use `handleAsync`, whose
    /// compute and validation run in the detached worker.
    private func runHeavySynchronously(_ plan: CADMeshPlan,
                                       args: [String: Any],
                                       cancellation: CADMeshCancellation) -> [String: Any] {
        let source = sourceToken(for: plan.inputs)
        let computation = Self.compute(plan: plan,
                                       wallClockLimit: wallClockLimit,
                                       cancellation: cancellation,
                                       previewRequested: Self.boolean(args["preview"]))
        return finishHeavy(plan, computation: computation, args: args,
                           cancellation: cancellation, source: source)
    }

    private func runHeavyOffMain(_ plan: CADMeshPlan,
                                 args: [String: Any],
                                 cancellation: CADMeshCancellation) async -> [String: Any] {
        if cancellation.isCancelled || Task.isCancelled { return Self.cancelledReply() }
        let source = sourceToken(for: plan.inputs)
        let limit = wallClockLimit
        let previewRequested = Self.boolean(args["preview"])
        let run = beginRun(action: plan.action, cancellation: cancellation)
        let probe = Self.testHeavyComputeProbe
        let beforeCommitProbe = Self.testBeforeCommitProbe
        let worker = Task.detached(priority: .userInitiated) {
            probe?(plan.action, plan.inputTriangleCount)
            let computation = CADMeshService.compute(plan: plan,
                                                     wallClockLimit: limit,
                                                     cancellation: cancellation,
                                                     previewRequested: previewRequested)
            beforeCommitProbe?()
            return computation
        }
        run.attach(worker)
        let computation = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            cancellation.cancel()
            worker.cancel()
        }
        Self.finishRun(run)

        guard !document.isClosed else { return Self.closedReply() }
        if let refusal = CADServiceOperations.readOnlyRefusal(document: document,
                                                              kind: "mesh",
                                                              action: plan.action) {
            return refusal
        }
        if cancellation.isCancelled || Task.isCancelled || run.cancellation.isCancelled {
            return Self.cancelledReply()
        }
        guard currentSourceToken(for: plan.inputs) == source else {
            return Self.sourceChangedReply()
        }
        return finishHeavy(plan, computation: computation, args: args,
                           cancellation: cancellation, source: source)
    }

    private func finishHeavy(_ plan: CADMeshPlan,
                             computation: CADMeshComputation,
                             args: [String: Any],
                             cancellation: CADMeshCancellation,
                             source: CADMeshSourceToken) -> [String: Any] {
        if cancellation.isCancelled || Task.isCancelled { return Self.cancelledReply() }
        guard !document.isClosed else { return Self.closedReply() }
        if let refusal = CADServiceOperations.readOnlyRefusal(document: document,
                                                              kind: "mesh",
                                                              action: plan.action) {
            return refusal
        }
        guard currentSourceToken(for: plan.inputs) == source else {
            return Self.sourceChangedReply()
        }
        switch computation {
        case .cancelled:
            return Self.cancelledReply()
        case .timedOut:
            return limitTime()
        case .refused(let code, let message):
            return Self.fail(code, message)
        case .combine(let mesh, let render, let edges, let hash, let snapshot):
            return commitResult(plan: plan, args: args, source: source,
                                cancellation: cancellation,
                                mesh: mesh, render: render, edges: edges,
                                hash: hash, snapshot: snapshot,
                                repairEntries: [], simplifyEntries: [])
        case .boolean(let mesh, let render, let edges, let hash, let snapshot):
            return commitResult(plan: plan, args: args, source: source,
                                cancellation: cancellation,
                                mesh: mesh, render: render, edges: edges,
                                hash: hash, snapshot: snapshot,
                                repairEntries: [], simplifyEntries: [])
        case .replacements(let replacements, let repairEntries,
                           let simplifyEntries, let hash, let snapshot,
                           let previewTriangleCount):
            return commitReplacements(plan: plan, args: args, source: source,
                                      cancellation: cancellation,
                                      replacements: replacements,
                                      repairEntries: repairEntries,
                                      simplifyEntries: simplifyEntries,
                                      hash: hash, snapshot: snapshot,
                                      previewTriangleCount: previewTriangleCount)
        }
    }

    // MARK: Preparation (MainActor, value-only)

    private func prepareCombine(_ args: [String: Any]) -> CADMeshPreparation {
        guard case let .ok(bodies) = resolveBodies(args) else {
            return .refusal(resolutionFailure(args))
        }
        if let refusal = verifyMeshOnly(bodies, args: args, action: "combine") {
            return .refusal(refusal)
        }
        let name = sanitizeName(args["name"]) ?? "Combined"
        return .heavy(.combine(inputs: snapshot(bodies), name: name))
    }

    private func prepareBoolean(_ args: [String: Any]) -> CADMeshPreparation {
        guard let opString = args["op"] as? String,
              let op = CADMeshBooleanKind(rawValue: opString) else {
            return .refusal(Self.fail("bad_request", "'op' must be union, subtract or intersect."))
        }
        guard let targetID = args["target"] as? String else {
            return .refusal(Self.fail("bad_request", "'target' is required."))
        }
        let toolIDs = stringList(args["tools"])
        guard !toolIDs.isEmpty else {
            return .refusal(Self.fail("bad_request", "'tools' must list at least one body."))
        }
        guard case let .ok(target) = resolveBodies(ids: [targetID]) else {
            return .refusal(resolutionFailure(ids: [targetID]))
        }
        guard case let .ok(tools) = resolveBodies(ids: toolIDs) else {
            return .refusal(resolutionFailure(ids: toolIDs))
        }
        let inputs = target + tools
        guard Set([targetID] + toolIDs).count == inputs.count else {
            return .refusal(Self.fail("bad_request",
                                      "'tools' must not repeat the target or each other."))
        }
        guard inputs.count <= Self.maxInputBodies else {
            return .refusal(Self.fail("too_many_bodies",
                                      "At most \(Self.maxInputBodies) bodies per operation; got \(inputs.count)."))
        }
        let totalTriangles = inputs.reduce(0) { $0 + $1.render.triangleCount }
        guard totalTriangles <= Self.maxInputTriangles else {
            return .refusal(Self.fail("too_many_triangles",
                                      "Input exceeds \(Self.maxInputTriangles) triangles."))
        }
        if let refusal = verifyMeshOnly(inputs, args: args, action: "boolean") {
            return .refusal(refusal)
        }
        let exactness = Self.inputExactness(inputs)
        return .heavy(.boolean(kind: op,
                               inputs: snapshot(inputs),
                               inputExactness: exactness.label,
                               brepBodyCount: exactness.brepBodyCount))
    }

    // MARK: transform (non-destructive)

    private func transform(_ args: [String: Any]) -> [String: Any] {
        guard let bodyID = args["bodyID"] as? String else {
            return Self.fail("bad_request", "'bodyID' is required.")
        }
        guard case let .ok(bodies) = resolveBodies(ids: [bodyID]) else {
            return resolutionFailure(ids: [bodyID])
        }
        let body = bodies[0]
        var next = body.transform
        var changed = false

        if let rawTranslate = args["translate"] {
            guard let vector = Self.doubles(rawTranslate), vector.count == 3 else {
                return Self.fail("bad_request", "'translate' must be [x, y, z] in mm.")
            }
            next.translation += SIMD3(vector[0], vector[1], vector[2])
            changed = true
        }
        if let rawRotate = args["rotate"] as? [String: Any] {
            guard let axisValues = Self.doubles(rawRotate["axis"]), axisValues.count == 3,
                  let angle = Self.number(rawRotate["angleDegrees"]) else {
                return Self.fail("bad_request",
                                 "'rotate' must be {\"axis\":[x,y,z],\"angleDegrees\":degrees}.")
            }
            let axis = SIMD3(axisValues[0], axisValues[1], axisValues[2])
            let length = simd_length(axis)
            guard length > 1e-12 else {
                return Self.fail("bad_request", "'rotate.axis' must be non-zero.")
            }
            let delta = simd_quatd(angle: angle * .pi / 180, axis: axis / length)
            // About the body's current placement: translation stays the pivot,
            // the delta pre-multiplies the existing orientation.
            next.rotation = simd_normalize(delta * next.rotation)
            changed = true
        }
        if let rawScale = args["scale"] {
            guard let scale = Self.number(rawScale), scale > 0 else {
                return Self.fail("bad_request", "'scale' must be a positive number.")
            }
            next.scale *= scale
            changed = true
        }
        guard changed else {
            return Self.fail("bad_request", "Provide 'translate', 'rotate' and/or 'scale'.")
        }
        guard next.translation.x.isFinite, next.translation.y.isFinite, next.translation.z.isFinite,
              next.scale.isFinite, next.scale > 0 else {
            return Self.fail("bad_request", "The resulting transform is not finite.")
        }

        document.session.perform(TransformBodiesCommand(title: "Transform",
                                                        before: [body.id: body.transform],
                                                        after: [body.id: next]))
        return ["ok": true,
                "action": "transform",
                "mutated": true,
                "exactness": "preserved",
                "bodyID": body.id.raw.uuidString,
                "translate": [next.translation.x, next.translation.y, next.translation.z],
                "scale": next.scale]
    }

    // MARK: recomputeNormals (non-destructive)

    private func recomputeNormals(_ args: [String: Any]) -> [String: Any] {
        guard case let .ok(bodies) = resolveBodies(args) else {
            return resolutionFailure(args)
        }
        let clock = EvaluationDeadlineClock(seconds: wallClockLimit)
        var replacements: [(before: Body, after: Body)] = []
        var entries: [[String: Any]] = []
        for body in bodies {
            guard !clock.expired else { return limitTime() }
            var after = body
            after.render = RenderMesh(
                positions: body.render.positions,
                normals: MeshImportKit.computedNormals(positions: body.render.positions,
                                                       indices: body.render.indices),
                indices: body.render.indices,
                texcoords: body.render.texcoords)
            after.edges = FeatureEdgeExtractor.edges(from: after.render)
            // The render normals were rewritten; force the CSG cache to be
            // rebuilt from the new render rather than keeping stale normals.
            after.euclid = nil
            replacements.append((before: body, after: after))
            entries.append(["bodyID": body.id.raw.uuidString,
                            "triangleCount": after.render.triangleCount])
        }
        performReplacements(replacements, title: "Recompute Normals")
        return ["ok": true,
                "action": "recomputeNormals",
                "mutated": true,
                "exactness": "preserved",
                "bodies": entries]
    }

    // MARK: boundary (read-only)

    private func boundary(_ args: [String: Any]) -> [String: Any] {
        guard case let .ok(bodies) = resolveBodies(args) else {
            return resolutionFailure(args)
        }
        let clock = EvaluationDeadlineClock(seconds: wallClockLimit)
        var entries: [[String: Any]] = []
        var totalBoundary = 0
        var totalNonManifold = 0
        for body in bodies {
            guard !clock.expired else { return limitTime() }
            guard let stats = Self.edgeStats(body.render, clock: clock) else {
                return limitTime()
            }
            totalBoundary += stats.boundary
            totalNonManifold += stats.nonManifold
            var entry: [String: Any] = ["bodyID": body.id.raw.uuidString,
                                        "triangleCount": stats.triangleCount,
                                        "edgeCount": stats.edgeCount,
                                        "boundaryEdgeCount": stats.boundary,
                                        "nonManifoldEdgeCount": stats.nonManifold]
            if let bounds = Self.worldBounds(of: stats.boundarySegments, transform: body.transform) {
                entry["bounds"] = bounds
            }
            entries.append(entry)
        }
        return ["ok": true,
                "action": "boundary",
                "mutated": false,
                "exactness": "preserved",
                "boundaryEdgeCount": totalBoundary,
                "nonManifoldEdgeCount": totalNonManifold,
                "bodies": entries]
    }

    private func prepareRepair(_ args: [String: Any]) -> CADMeshPreparation {
        guard case let .ok(bodies) = resolveBodies(args) else {
            return .refusal(resolutionFailure(args))
        }
        if let refusal = verifyMeshOnly(bodies, args: args, action: "repair") {
            return .refusal(refusal)
        }
        let tolerance: Double
        if let raw = args["tolerance"] {
            guard let value = Self.number(raw), value > 0 else {
                return .refusal(Self.fail("bad_request",
                                          "'tolerance' must be a positive distance in mm."))
            }
            tolerance = value
        } else {
            tolerance = 1e-3
        }
        return .heavy(.repair(inputs: snapshot(bodies), tolerance: tolerance))
    }

    private func prepareSimplify(_ args: [String: Any]) -> CADMeshPreparation {
        guard case let .ok(bodies) = resolveBodies(args) else {
            return .refusal(resolutionFailure(args))
        }
        if let refusal = verifyMeshOnly(bodies, args: args, action: "simplify") {
            return .refusal(refusal)
        }
        let ratio = args["ratio"].flatMap { Self.number($0) }
        let tolerance = args["tolerance"].flatMap { Self.number($0) }
        if tolerance == nil {
            guard let ratio, ratio > 0, ratio < 1 else {
                return .refusal(Self.fail("bad_request",
                                          "Provide 'ratio' in (0, 1) or a positive 'tolerance' in mm."))
            }
        } else if let tolerance, tolerance <= 0 {
            return .refusal(Self.fail("bad_request",
                                      "'tolerance' must be a positive distance in mm."))
        }
        return .heavy(.simplify(inputs: snapshot(bodies),
                                ratio: ratio,
                                tolerance: tolerance))
    }

    // MARK: material (non-destructive)

    private func material(_ args: [String: Any]) -> [String: Any] {
        guard case let .ok(bodies) = resolveBodies(args) else {
            return resolutionFailure(args)
        }
        var color: SIMD4<Double>?
        if let rawColor = args["color"] {
            if let values = Self.doubles(rawColor), values.count == 3 || values.count == 4,
               values.allSatisfy({ $0 >= 0 && $0 <= 1 }) {
                color = SIMD4(values[0], values[1], values[2], values.count == 4 ? values[3] : 1)
            } else if let text = rawColor as? String {
                var hex = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if hex.hasPrefix("#") { hex.removeFirst() }
                guard hex.count == 6 || hex.count == 8, let raw = UInt64(hex, radix: 16) else {
                    return Self.fail("bad_request",
                                     "'color' must be [r, g, b] or [r, g, b, a] in 0…1 (or #RRGGBB[AA]).")
                }
                let hasAlpha = hex.count == 8
                color = SIMD4(
                    Double((raw >> (hasAlpha ? 24 : 16)) & 0xFF) / 255,
                    Double((raw >> (hasAlpha ? 16 : 8)) & 0xFF) / 255,
                    Double((raw >> (hasAlpha ? 8 : 0)) & 0xFF) / 255,
                    hasAlpha ? Double(raw & 0xFF) / 255 : 1)
            } else {
                return Self.fail("bad_request",
                                 "'color' must be [r, g, b] or [r, g, b, a] in 0…1 (or #RRGGBB[AA]).")
            }
        }
        var opacity: Double?
        if let raw = args["opacity"] {
            guard let value = Self.number(raw), value >= 0, value <= 1 else {
                return Self.fail("bad_request", "'opacity' must be in 0…1.")
            }
            opacity = value
        }
        var metallic: Double?
        if let raw = args["metallic"] {
            guard let value = Self.number(raw), value >= 0, value <= 1 else {
                return Self.fail("bad_request", "'metallic' must be in 0…1.")
            }
            metallic = value
        }
        var roughness: Double?
        if let raw = args["roughness"] {
            guard let value = Self.number(raw), value >= 0, value <= 1 else {
                return Self.fail("bad_request", "'roughness' must be in 0…1.")
            }
            roughness = value
        }
        guard color != nil || opacity != nil || metallic != nil || roughness != nil else {
            return Self.fail("bad_request",
                             "Provide at least one of 'color', 'opacity', 'metallic' or 'roughness'.")
        }

        var commands: [DocumentCommand] = []
        for body in bodies {
            var spec = body.material ?? BodyMaterialSpec.default
            if let color { spec.baseColor = color }
            if let opacity { spec.baseColor.w = opacity }
            if let metallic { spec.metallic = metallic }
            if let roughness { spec.roughness = roughness }
            commands.append(SetMaterialCommand(bodyIDs: [body.id],
                                               material: spec.clamped,
                                               document: document.session.document))
        }
        performCommands(commands, title: "Material")
        return ["ok": true,
                "action": "material",
                "mutated": true,
                "exactness": "preserved",
                "bodyCount": bodies.count]
    }

    // MARK: text

    private func text(_ args: [String: Any]) -> [String: Any] {
        _ = args
        return Self.fail("text_mesh_unavailable",
                         "This service creates text through the native sketch route: propose sketch.addText (text outlines as "
                         + "ordinary sketch entities), apply, then feature.extrude the closed profiles. "
                         + "This mesh service has no standalone text-to-mesh path.")
    }

    // MARK: image

    private func image(_ args: [String: Any]) -> [String: Any] {
        guard case let .ok(bodies) = resolveBodies(args) else {
            return resolutionFailure(args)
        }
        let data: Data
        if let base64 = args["imageBase64"] as? String {
            guard base64.utf8.count <= (Self.maxImageBytes + 2) / 3 * 4 else {
                return Self.fail("too_large_image",
                                 "Encoded image exceeds \(Self.maxImageBytes) bytes.")
            }
            guard let decoded = Data(base64Encoded: base64), !decoded.isEmpty,
                  decoded.count <= Self.maxImageBytes else {
                return Self.fail("bad_request", "'imageBase64' is not valid base64 image data.")
            }
            data = decoded
        } else if let imageID = args["imageID"] as? String,
                  let uuid = UUID(uuidString: imageID),
                  let inserted = document.session.document.images.first(where: { $0.id.raw == uuid }) {
            guard !inserted.imageData.isEmpty, inserted.imageData.count <= Self.maxImageBytes else {
                return Self.fail("bad_request",
                                 "The document image '\(inserted.name)' carries no usable bytes.")
            }
            data = inserted.imageData
        } else {
            return Self.fail("bad_request",
                             "Provide 'imageBase64' (PNG/JPEG bytes) or an existing 'imageID'.")
        }
        guard Self.isPNG(data) || Self.isJPEG(data) else {
            return Self.fail("unsupported_image", "Image bytes must be PNG or JPEG.")
        }

        var commands: [DocumentCommand] = []
        var textured: [[String: Any]] = []
        for body in bodies {
            var spec = body.material ?? BodyMaterialSpec.default
            spec.baseColorTexture = data
            commands.append(SetMaterialCommand(bodyIDs: [body.id],
                                               material: spec.clamped,
                                               document: document.session.document))
            textured.append(["bodyID": body.id.raw.uuidString,
                             "uvs": body.render.texcoords != nil])
        }
        performCommands(commands, title: "Image Material")
        return ["ok": true,
                "action": "image",
                "mutated": true,
                "exactness": "preserved",
                "textureBytes": data.count,
                "bodies": textured]
    }

    // MARK: Body resolution / limits

    private enum BodyResolution {
        case ok([Body])
        case failed([String: Any])
    }

    private func resolveBodies(_ args: [String: Any]) -> BodyResolution {
        var ids = stringList(args["bodyIDs"])
        if ids.isEmpty, let single = args["bodyID"] as? String { ids = [single] }
        guard !ids.isEmpty else {
            return .failed(Self.fail("bad_request", "Provide 'bodyID' or 'bodyIDs'."))
        }
        return resolveBodies(ids: ids)
    }

    private func resolveBodies(ids: [String]) -> BodyResolution {
        guard ids.count <= Self.maxInputBodies else {
            return .failed(Self.fail("too_many_bodies",
                                     "At most \(Self.maxInputBodies) bodies per operation; got \(ids.count)."))
        }
        guard Set(ids).count == ids.count else {
            return .failed(Self.fail("bad_request", "'bodyIDs' must not repeat a body."))
        }
        let live = document.session.document
        var bodies: [Body] = []
        var triangles = 0
        for idString in ids {
            guard let uuid = UUID(uuidString: idString),
                  let body = live.bodies.first(where: { $0.id.raw == uuid }) else {
                return .failed(Self.fail("unknown_body", "No body with id \(idString)."))
            }
            triangles += body.render.triangleCount
            guard triangles <= Self.maxInputTriangles else {
                return .failed(Self.fail("too_many_triangles",
                                         "Input exceeds \(Self.maxInputTriangles) triangles."))
            }
            bodies.append(body)
        }
        return .ok(bodies)
    }

    private func resolutionFailure(_ args: [String: Any]) -> [String: Any] {
        var ids = stringList(args["bodyIDs"])
        if ids.isEmpty, let single = args["bodyID"] as? String { ids = [single] }
        return resolutionFailure(ids: ids)
    }

    private func resolutionFailure(ids: [String]) -> [String: Any] {
        if case let .failed(response) = resolveBodies(ids: ids) { return response }
        return Self.fail("bad_request", "Bodies could not be resolved.")
    }

    /// Refuses destructive mesh ops on exact B-rep bodies unless the caller
    /// acknowledged the downgrade with `forceMesh:true`. The refusal names the
    /// real input exactness, so a precise or mixed call can never be read as a
    /// silently preserved analytic result. Both a closed solid and an exact
    /// open IGES surface count: either handle is lost by a mesh rebuild.
    private func verifyMeshOnly(_ bodies: [Body], args: [String: Any], action: String) -> [String: Any]? {
        guard !Self.boolean(args["forceMesh"]) else { return nil }
        let exactness = Self.inputExactness(bodies)
        guard exactness.brepBodyCount == 0 else {
            var reply = Self.fail("brep_body_refused",
                                  "'\(action)' rebuilds meshes and would drop the exact B-rep of "
                                  + "\(exactness.brepBodyCount) body(ies): "
                                  + bodies.filter { $0.brep != nil || $0.surfaceBRep != nil }
                                      .map(\.name).joined(separator: ", ")
                                  + ". Pass forceMesh:true to acknowledge the downgrade.")
            reply["inputExactness"] = exactness.label
            reply["brepBodyCount"] = exactness.brepBodyCount
            return reply
        }
        return nil
    }

    /// Input representation the boolean consumes before it rebuilds triangles.
    /// "precise" means every input carries an exact B-rep (closed solid OR
    /// open IGES surface); "mesh" means none does; "mixed" is both in one
    /// operation. The forced result is always "mesh", so `brepBodyCount` is
    /// what that result dropped — including an open surface handle.
    private struct InputExactness {
        let label: String
        let brepBodyCount: Int
    }

    private static func inputExactness(_ bodies: [Body]) -> InputExactness {
        let analytic = bodies.filter { $0.brep != nil || $0.surfaceBRep != nil }.count
        let label: String
        if analytic == 0 {
            label = "mesh"
        } else if analytic == bodies.count {
            label = "precise"
        } else {
            label = "mixed"
        }
        return InputExactness(label: label, brepBodyCount: analytic)
    }

    private static func exactnessFields(_ exactness: InputExactness) -> [String: Any] {
        ["inputExactness": exactness.label,
         "brepDropped": exactness.brepBodyCount > 0,
         "droppedBRepBodyCount": exactness.brepBodyCount]
    }

    /// Preview/apply gate for destructive mesh operations.
    ///
    /// `preview:true` returns the transient result geometry (a bounded mesh
    /// snapshot a UI can draw) plus an order-independent content hash and the
    /// source revision/change-count the worker was dispatched against — WITHOUT
    /// touching the document. A subsequent apply may pass those values as
    /// `expectedPreviewHash` / `expectedRevision` / `expectedChangeCount`; a
    /// mismatch refuses with `preview_stale` instead of committing geometry
    /// the user never saw. The hash/snapshot were computed in the worker.
    private func previewGate(action: String, args: [String: Any],
                             hash: String,
                             snapshot: CADTransientMeshPreview.Snapshot?,
                             triangleCount: Int,
                             revision: Int,
                             changeCount: Int,
                             extra: [String: Any]) -> (reply: [String: Any]?,
                                                       refusal: [String: Any]?) {
        if let expected = args["expectedPreviewHash"] as? String, !expected.isEmpty {
            guard expected == hash else {
                return (nil, Self.fail("preview_stale",
                                       "The geometry changed since the preview; preview again before applying."))
            }
            if let expectedRevision = Self.integer(args["expectedRevision"]),
               expectedRevision != revision {
                return (nil, Self.fail("preview_stale",
                                       "The document changed since the preview; preview again before applying."))
            }
            if let expectedChangeCount = Self.integer(args["expectedChangeCount"]),
               expectedChangeCount != changeCount {
                return (nil, Self.fail("preview_stale",
                                       "The document changed since the preview; preview again before applying."))
            }
        }
        if Self.boolean(args["preview"]) {
            guard let snapshot else {
                return (nil, Self.fail("invalid_mesh", "The '\(action)' preview is empty."))
            }
            var reply: [String: Any] = ["ok": true,
                                        "action": action,
                                        "mutated": false,
                                        "preview": true,
                                        "exactness": "mesh",
                                        "previewHash": hash,
                                        "previewRevision": revision,
                                        "previewChangeCount": changeCount,
                                        "triangleCount": triangleCount,
                                        "mesh": CADTransientMeshPreview.payload(snapshot)]
            for (key, value) in extra { reply[key] = value }
            return (reply, nil)
        }
        return (nil, nil)
    }

    private static func integer(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let number = raw as? NSNumber { return number.intValue }
        return nil
    }

    // MARK: Session commit helpers

    private func makeResultBody(name: String,
                                mesh: Euclid.Mesh,
                                render: RenderMesh,
                                edges: FeatureEdgeSet) -> Body {
        var localDocument = document.session.document
        var body = Body(id: BodyID(),
                        name: localDocument.uniqueBodyName(base: name),
                        transform: .identity,
                        render: render,
                        edges: edges,
                        revision: localDocument.nextRevision())
        body.euclid = mesh
        return body
    }

    /// Adds the result body and consumes the inputs in ONE undo step.
    private func commit(_ body: Body, consumingIDs: [BodyID], title: String) {
        var commands: [DocumentCommand] = [AddBodyCommand(body: body, title: title)]
        if !consumingIDs.isEmpty {
            commands.append(DeleteBodiesCommand(ids: Set(consumingIDs),
                                                document: document.session.document))
        }
        performCommands(commands, title: title)
    }

    private func performReplacements(_ replacements: [(before: Body, after: Body)], title: String) {
        guard !replacements.isEmpty else { return }
        let commands = replacements.map {
            ReplaceBodyCommand(title: title, before: $0.before, after: $0.after)
        }
        performCommands(commands, title: title)
    }

    private func performCommands(_ commands: [DocumentCommand], title: String) {
        guard !commands.isEmpty else { return }
        if commands.count == 1 {
            document.session.perform(commands[0])
        } else {
            document.session.perform(CompositeCommand(title: title, commands: commands))
        }
    }

    private static func mutationResult(action: String,
                                       body: Body,
                                       extra: [String: Any]) -> [String: Any] {
        var response: [String: Any] = ["ok": true,
                                       "action": action,
                                       "mutated": true,
                                       "exactness": "mesh",
                                       "outputBodyID": body.id.raw.uuidString,
                                       "bodyName": body.name,
                                       "triangleCount": body.render.triangleCount]
        for (key, value) in extra { response[key] = value }
        return response
    }

    private func commitResult(plan: CADMeshPlan,
                              args: [String: Any],
                              source: CADMeshSourceToken,
                              cancellation: CADMeshCancellation,
                              mesh: Euclid.Mesh,
                              render: RenderMesh,
                              edges: FeatureEdgeSet,
                              hash: String,
                              snapshot: CADTransientMeshPreview.Snapshot?,
                              repairEntries: [CADMeshRepairEntry],
                              simplifyEntries: [CADMeshSimplifyEntry]) -> [String: Any] {
        _ = repairEntries
        _ = simplifyEntries
        let gateExtra: [String: Any]
        var mutationExtra: [String: Any]
        let name: String
        let title: String
        switch plan {
        case .combine(let inputs, let baseName):
            gateExtra = [:]
            mutationExtra = ["sourceBodyCount": inputs.count]
            name = baseName
            title = "Combine"
        case .boolean(let kind, let inputs, let inputExactness, let brepBodyCount):
            let exactness: [String: Any] = ["inputExactness": inputExactness,
                                            "brepDropped": brepBodyCount > 0,
                                            "droppedBRepBodyCount": brepBodyCount]
            gateExtra = exactness
            mutationExtra = exactness
            mutationExtra["op"] = kind.rawValue
            mutationExtra["sourceBodyCount"] = inputs.count
            name = sanitizeName(args["name"]) ?? "Boolean"
            title = kind.rawValue.capitalized
        case .repair, .simplify:
            return Self.fail("bad_request", "Unexpected mesh result.")
        }
        let gate = previewGate(action: plan.action, args: args, hash: hash,
                               snapshot: snapshot,
                               triangleCount: render.triangleCount,
                               revision: document.store.revision,
                               changeCount: document.session.changeCount,
                               extra: gateExtra)
        if let refusal = gate.refusal { return refusal }
        if let reply = gate.reply { return reply }
        if let fence = commitFence(plan, source: source, cancellation: cancellation) {
            return fence
        }
        let body = makeResultBody(name: name, mesh: mesh, render: render, edges: edges)
        commit(body, consumingIDs: plan.inputs.map(\.id), title: title)
        return Self.mutationResult(action: plan.action, body: body, extra: mutationExtra)
    }

    private func commitReplacements(plan: CADMeshPlan,
                                    args: [String: Any],
                                    source: CADMeshSourceToken,
                                    cancellation: CADMeshCancellation,
                                    replacements: [CADMeshReplacement],
                                    repairEntries: [CADMeshRepairEntry],
                                    simplifyEntries: [CADMeshSimplifyEntry],
                                    hash: String,
                                    snapshot: CADTransientMeshPreview.Snapshot?,
                                    previewTriangleCount: Int) -> [String: Any] {
        let gate = previewGate(action: plan.action, args: args, hash: hash,
                               snapshot: snapshot,
                               triangleCount: previewTriangleCount,
                               revision: document.store.revision,
                               changeCount: document.session.changeCount,
                               extra: [:])
        if let refusal = gate.refusal { return refusal }
        if let reply = gate.reply { return reply }
        if let fence = commitFence(plan, source: source, cancellation: cancellation) {
            return fence
        }

        var pairs: [(before: Body, after: Body)] = []
        for replacement in replacements {
            guard let before = document.session.document.body(with: replacement.id) else {
                return Self.sourceChangedReply()
            }
            var after = before
            after.render = replacement.render
            after.edges = replacement.edges
            after.euclid = nil
            after.brep = nil
            // Repair/simplify REPLACED the geometry: the old exact IGES
            // surface handle would otherwise describe the pre-repair shape and
            // IGES export would silently write stale geometry.
            after.surfaceBRep = nil
            after.primitive = nil
            pairs.append((before: before, after: after))
        }
        let title: String
        let mutated: Bool
        let entries: [[String: Any]]
        switch plan {
        case .repair(_, let tolerance):
            title = "Repair Mesh"
            mutated = !pairs.isEmpty
            entries = repairEntries.map(\.payload)
            performReplacements(pairs, title: title)
            return ["ok": true,
                    "action": "repair",
                    "mutated": mutated,
                    "exactness": "mesh",
                    "tolerance": tolerance,
                    "bodies": entries]
        case .simplify:
            title = "Simplify Mesh"
            mutated = true
            entries = simplifyEntries.map(\.payload)
            performReplacements(pairs, title: title)
            return ["ok": true,
                    "action": "simplify",
                    "mutated": mutated,
                    "exactness": "mesh",
                    "bodies": entries]
        case .combine, .boolean:
            return Self.fail("bad_request", "Unexpected mesh result.")
        }
    }

    // MARK: Off-main compute

    /// Validates the frozen heavy inputs before any Euclid conversion/CSG or
    /// welding. The scan is chunk-bounded by cancellation/deadline checks so a
    /// huge or corrupt buffer cannot monopolize the worker past the operation
    /// limit; it introduces no smaller size cap. Every refusal names the body
    /// and leaves geometry, history and files untouched.
    private nonisolated static func validateInputs(
        _ inputs: [CADMeshInputSnapshot],
        clock: EvaluationDeadlineClock,
        isCancelled: @Sendable () -> Bool
    ) -> CADMeshInputValidation {
        guard inputs.count <= maxInputBodies else {
            return .refused(
                code: "too_many_bodies",
                message: "At most \(maxInputBodies) bodies per operation; got \(inputs.count).")
        }
        var totalTriangles = 0
        for input in inputs {
            if isCancelled() || clock.isExpired() { return .interrupted }

            let transform = input.transform
            guard transform.translation.x.isFinite,
                  transform.translation.y.isFinite,
                  transform.translation.z.isFinite,
                  transform.scale.isFinite,
                  transform.scale > 0,
                  transform.rotation.imag.x.isFinite,
                  transform.rotation.imag.y.isFinite,
                  transform.rotation.imag.z.isFinite,
                  transform.rotation.real.isFinite else {
                return invalid(input, "has a non-finite or non-positive transform")
            }
            let rotation = transform.rotation
            let rotationLength = (rotation.imag.x * rotation.imag.x
                + rotation.imag.y * rotation.imag.y
                + rotation.imag.z * rotation.imag.z
                + rotation.real * rotation.real).squareRoot()
            guard rotationLength.isFinite, rotationLength > 1e-12 else {
                return invalid(input, "has a zero or non-finite rotation")
            }

            let render = input.render
            guard !render.indices.isEmpty, !render.positions.isEmpty else {
                return invalid(input, "has no triangles to operate on")
            }
            guard render.indices.count % 3 == 0 else {
                return invalid(input, "has a truncated triangle index buffer")
            }
            guard render.normals.count == render.positions.count else {
                return invalid(input, "has a normals buffer that does not match its vertices")
            }
            if let texcoords = render.texcoords,
               texcoords.count != render.positions.count {
                return invalid(input, "has a texture-coordinate buffer that does not match its vertices")
            }

            totalTriangles += render.triangleCount
            guard totalTriangles <= maxInputTriangles else {
                return .refused(
                    code: "too_many_triangles",
                    message: "Input exceeds \(maxInputTriangles) triangles.")
            }

            let vertexCount = render.positions.count
            for (offset, position) in render.positions.enumerated() {
                if offset % 4096 == 0, isCancelled() || clock.isExpired() {
                    return .interrupted
                }
                guard position.x.isFinite, position.y.isFinite, position.z.isFinite else {
                    return invalid(input, "has a non-finite position")
                }
            }
            for (offset, normal) in render.normals.enumerated() {
                if offset % 4096 == 0, isCancelled() || clock.isExpired() {
                    return .interrupted
                }
                guard normal.x.isFinite, normal.y.isFinite, normal.z.isFinite else {
                    return invalid(input, "has a non-finite normal")
                }
            }
            if let texcoords = render.texcoords {
                for (offset, uv) in texcoords.enumerated() {
                    if offset % 4096 == 0, isCancelled() || clock.isExpired() {
                        return .interrupted
                    }
                    guard uv.x.isFinite, uv.y.isFinite else {
                        return invalid(input, "has a non-finite texture coordinate")
                    }
                }
            }
            for (offset, index) in render.indices.enumerated() {
                if offset % 4096 == 0, isCancelled() || clock.isExpired() {
                    return .interrupted
                }
                guard Int(index) < vertexCount else {
                    return invalid(input, "has an out-of-range triangle index")
                }
            }
        }
        return .valid
    }

    private nonisolated static func invalid(_ input: CADMeshInputSnapshot,
                                            _ detail: String) -> CADMeshInputValidation {
        .refused(code: "invalid_mesh",
                 message: "Body '\(input.name)' \(detail); nothing changed.")
    }

    /// Test-visible timing wrapper around the real compute. Production has no
    /// observation installed and calls straight through without a clock read.
    private nonisolated static func compute(plan: CADMeshPlan,
                                            wallClockLimit: Double,
                                            cancellation: CADMeshCancellation,
                                            previewRequested: Bool) -> CADMeshComputation {
        guard let observation = testComputeObservation else {
            return computeBody(plan: plan,
                               wallClockLimit: wallClockLimit,
                               cancellation: cancellation,
                               previewRequested: previewRequested)
        }
        let started = ContinuousClock.now
        let computation = computeBody(plan: plan,
                                      wallClockLimit: wallClockLimit,
                                      cancellation: cancellation,
                                      previewRequested: previewRequested)
        let duration = started.duration(to: .now)
        let parts = duration.components
        observation(CADMeshComputeObservation(
            action: plan.action,
            inputBodies: plan.inputs.count,
            inputTriangles: plan.inputTriangleCount,
            computeSeconds: Double(parts.seconds)
                + Double(parts.attoseconds) / 1_000_000_000_000_000_000,
            ranOnMainThread: Thread.isMainThread,
            outcome: computeOutcomeLabel(computation)))
        return computation
    }

    private nonisolated static func computeOutcomeLabel(_ computation: CADMeshComputation) -> String {
        switch computation {
        case .cancelled: return "cancelled"
        case .timedOut: return "limit_time"
        case .refused(let code, _): return "refused:\(code)"
        case .combine: return "combine"
        case .boolean: return "boolean"
        case .replacements: return "replacements"
        }
    }

    private nonisolated static func computeBody(plan: CADMeshPlan,
                                                wallClockLimit: Double,
                                                cancellation: CADMeshCancellation,
                                                previewRequested: Bool) -> CADMeshComputation {
        let clock = EvaluationDeadlineClock(seconds: wallClockLimit)
        let kernelCancel: @Sendable () -> Bool = {
            cancellation.kernelIsCancelled() || Task.isCancelled || clock.isExpired()
        }
        let serviceCancel: @Sendable () -> Bool = {
            cancellation.isCancelled || Task.isCancelled || clock.isExpired()
        }
        func interrupted() -> CADMeshComputation {
            if cancellation.isCancelled || Task.isCancelled { return .cancelled }
            return .timedOut
        }

        // Frozen value inputs are persistence-adjacent bytes: a reopened
        // MeshBlob guards index bounds but deliberately accepts non-finite
        // floats. Validate the whole snapshot HERE, on the compute thread,
        // before Euclid conversion/CSG or welding can subscript a bad index,
        // convert a NaN into a trap, or commit a malformed body. This mirrors
        // the existing `DocumentSession.faceRangeTable` render checks and adds
        // the UV/transform invariants this service consumes; it is a scanned
        // pass, not an artificial size limit.
        switch validateInputs(plan.inputs, clock: clock, isCancelled: serviceCancel) {
        case .valid:
            break
        case .interrupted:
            return interrupted()
        case .refused(let code, let message):
            return .refused(code: code, message: message)
        }

        switch plan {
        case .combine(let inputs, _):
            guard !serviceCancel() else { return interrupted() }
            var result = Euclid.Mesh.empty
            for input in inputs {
                guard !serviceCancel() else { return interrupted() }
                result = result.merge(worldMesh(input))
            }
            guard !serviceCancel() else { return interrupted() }
            guard !result.polygons.isEmpty else {
                return .refused(code: "empty_geometry",
                                message: "The combined mesh is empty; nothing changed.")
            }
            let render = EuclidBridge.renderMesh(from: result)
            guard !serviceCancel() else { return interrupted() }
            guard let hash = CADTransientMeshPreview.hash(of: [render]) else {
                return .refused(code: "invalid_mesh",
                                message: "The 'combine' result has non-finite geometry; nothing changed.")
            }
            let snapshot = previewRequested
                ? CADTransientMeshPreview.snapshot(of: [render]) : nil
            return .combine(mesh: result, render: render,
                            edges: FeatureEdgeExtractor.edges(from: render),
                            previewHash: hash, previewSnapshot: snapshot)

        case .boolean(let kind, let inputs, _, _):
            guard !serviceCancel() else { return interrupted() }
            var result = worldMesh(inputs[0])
            for input in inputs.dropFirst() {
                guard !serviceCancel() else { return interrupted() }
                let toolMesh = worldMesh(input)
                switch kind {
                case .union:
                    result = result.union(toolMesh, isCancelled: kernelCancel)
                case .subtract:
                    result = result.subtracting(toolMesh, isCancelled: kernelCancel)
                case .intersect:
                    result = result.intersection(toolMesh, isCancelled: kernelCancel)
                }
                // Euclid may return its partially clipped mesh when the
                // closure reports cancellation. Never treat that as a
                // result: drop it before the watertight pass, preview, body
                // construction or commit.
                guard !serviceCancel() else { return interrupted() }
            }
            result = result.makeWatertight(isCancelled: kernelCancel)
            guard !serviceCancel() else { return interrupted() }
            guard !result.polygons.isEmpty else {
                return .refused(code: "empty_geometry",
                                message: "The \(kind.rawValue) result is empty; nothing changed.")
            }
            let render = EuclidBridge.renderMesh(from: result)
            guard !serviceCancel() else { return interrupted() }
            guard let hash = CADTransientMeshPreview.hash(of: [render]) else {
                return .refused(code: "invalid_mesh",
                                message: "The 'boolean' result has non-finite geometry; nothing changed.")
            }
            let snapshot = previewRequested
                ? CADTransientMeshPreview.snapshot(of: [render]) : nil
            return .boolean(mesh: result, render: render,
                            edges: FeatureEdgeExtractor.edges(from: render),
                            previewHash: hash, previewSnapshot: snapshot)

        case .repair(let inputs, let tolerance):
            guard !serviceCancel() else { return interrupted() }
            var replacements: [CADMeshReplacement] = []
            var entries: [CADMeshRepairEntry] = []
            var previewMeshes: [RenderMesh] = []
            for input in inputs {
                guard !serviceCancel() else { return interrupted() }
                guard let welded = weldAndClean(input.render,
                                                tolerance: tolerance,
                                                clock: clock,
                                                isCancelled: serviceCancel) else {
                    if serviceCancel() { return interrupted() }
                    return .refused(code: "invalid_mesh",
                                    message: "Body '\(input.name)' has non-finite coordinates; nothing changed.")
                }
                guard !welded.mesh.indices.isEmpty else {
                    return .refused(code: "empty_geometry",
                                    message: "Repairing '\(input.name)' would remove every triangle; nothing changed.")
                }
                previewMeshes.append(welded.mesh)
                entries.append(CADMeshRepairEntry(bodyID: input.id,
                                                  beforeTriangles: input.render.triangleCount,
                                                  afterTriangles: welded.mesh.triangleCount,
                                                  weldedVertices: welded.weldedVertices,
                                                  removedTriangles: welded.removedTriangles))
                guard welded.weldedVertices > 0 || welded.removedTriangles > 0 else {
                    continue
                }
                replacements.append(CADMeshReplacement(
                    id: input.id,
                    render: welded.mesh,
                    edges: FeatureEdgeExtractor.edges(from: welded.mesh)))
                guard !serviceCancel() else { return interrupted() }
            }
            guard !serviceCancel() else { return interrupted() }
            guard let hash = CADTransientMeshPreview.hash(of: previewMeshes) else {
                return .refused(code: "invalid_mesh",
                                message: "The 'repair' result has non-finite geometry; nothing changed.")
            }
            let snapshot = previewRequested
                ? CADTransientMeshPreview.snapshot(of: previewMeshes) : nil
            return .replacements(replacements,
                                 repairEntries: entries,
                                 simplifyEntries: [],
                                 previewHash: hash,
                                 previewSnapshot: snapshot,
                                 previewTriangleCount: previewMeshes.reduce(0) {
                                     $0 + $1.triangleCount
                                 })

        case .simplify(let inputs, let ratio, let tolerance):
            guard !serviceCancel() else { return interrupted() }
            var replacements: [CADMeshReplacement] = []
            var entries: [CADMeshSimplifyEntry] = []
            var previewMeshes: [RenderMesh] = []
            for input in inputs {
                guard !serviceCancel() else { return interrupted() }
                let before = input.render.triangleCount
                guard before >= 4 else {
                    return .refused(code: "too_few_triangles",
                                    message: "Body '\(input.name)' has \(before) triangles; simplification "
                                           + "never goes below 4.")
                }
                let simplified: RenderMesh
                if let tolerance {
                    // Tolerance takes precedence when both are given.
                    guard let welded = weldAndClean(input.render,
                                                    tolerance: tolerance,
                                                    clock: clock,
                                                    isCancelled: serviceCancel) else {
                        if serviceCancel() { return interrupted() }
                        return .refused(code: "invalid_mesh",
                                        message: "Body '\(input.name)' has non-finite coordinates; nothing changed.")
                    }
                    guard welded.mesh.triangleCount >= 4 else {
                        return .refused(code: "simplify_too_aggressive",
                                        message: "That tolerance would leave fewer than 4 triangles; "
                                               + "nothing changed.")
                    }
                    simplified = welded.mesh
                    entries.append(CADMeshSimplifyEntry(bodyID: input.id,
                                                        beforeTriangles: before,
                                                        afterTriangles: welded.mesh.triangleCount,
                                                        targetTriangles: nil,
                                                        cellSize: nil,
                                                        tolerance: tolerance))
                } else {
                    guard let ratio else {
                        return .refused(code: "bad_request",
                                        message: "Provide 'ratio' in (0, 1) or 'tolerance'.")
                    }
                    let target = max(4, Int((Double(before) * ratio).rounded()))
                    var cell = max(diagonal(input.render) * 0.01, 1e-9)
                    var best: RenderMesh?
                    var bestCell = cell
                    for _ in 0..<28 {
                        guard !serviceCancel() else { return interrupted() }
                        guard let welded = weldAndClean(input.render,
                                                        tolerance: cell,
                                                        clock: clock,
                                                        isCancelled: serviceCancel) else {
                            if serviceCancel() { return interrupted() }
                            return .refused(code: "invalid_mesh",
                                            message: "Body '\(input.name)' has non-finite coordinates; nothing changed.")
                        }
                        let candidate = welded.mesh
                        guard candidate.triangleCount >= 4 else { break }
                        best = candidate
                        bestCell = cell
                        if candidate.triangleCount <= target { break }
                        cell *= 1.6
                    }
                    guard let simplifiedMesh = best else {
                        return .refused(code: "simplify_too_aggressive",
                                        message: "No cluster size kept at least 4 triangles; nothing changed.")
                    }
                    simplified = simplifiedMesh
                    entries.append(CADMeshSimplifyEntry(bodyID: input.id,
                                                        beforeTriangles: before,
                                                        afterTriangles: simplifiedMesh.triangleCount,
                                                        targetTriangles: target,
                                                        cellSize: bestCell,
                                                        tolerance: nil))
                }
                previewMeshes.append(simplified)
                replacements.append(CADMeshReplacement(
                    id: input.id,
                    render: simplified,
                    edges: FeatureEdgeExtractor.edges(from: simplified)))
                guard !serviceCancel() else { return interrupted() }
            }
            guard !serviceCancel() else { return interrupted() }
            guard let hash = CADTransientMeshPreview.hash(of: previewMeshes) else {
                return .refused(code: "invalid_mesh",
                                message: "The 'simplify' result has non-finite geometry; nothing changed.")
            }
            let snapshot = previewRequested
                ? CADTransientMeshPreview.snapshot(of: previewMeshes) : nil
            return .replacements(replacements,
                                 repairEntries: [],
                                 simplifyEntries: entries,
                                 previewHash: hash,
                                 previewSnapshot: snapshot,
                                 previewTriangleCount: previewMeshes.reduce(0) {
                                     $0 + $1.triangleCount
                                 })
        }
    }

    // MARK: Geometry helpers

    private nonisolated static func worldMesh(_ input: CADMeshInputSnapshot) -> Euclid.Mesh {
        input.euclidMesh().transformed(by: input.transform.euclid)
    }

    private nonisolated static func diagonal(_ mesh: RenderMesh) -> Double {
        let aabb = mesh.localAABB
        return simd_length(SIMD3(Double(aabb.max.x - aabb.min.x),
                                 Double(aabb.max.y - aabb.min.y),
                                 Double(aabb.max.z - aabb.min.z)))
    }

    /// Grid-quantized vertex welding; triangles that collapse to a repeated
    /// index or zero area are dropped. Returns nil for non-finite input,
    /// cancellation or deadline expiry (the caller distinguishes the latter two
    /// with the shared cancellation closure and `clock.isExpired()`).
    private nonisolated static func weldAndClean(
        _ mesh: RenderMesh,
        tolerance: Double,
        clock: EvaluationDeadlineClock,
        isCancelled: @escaping @Sendable () -> Bool
    ) -> (mesh: RenderMesh, weldedVertices: Int, removedTriangles: Int)? {
        for position in mesh.positions
        where !position.x.isFinite || !position.y.isFinite || !position.z.isFinite {
            return nil
        }
        guard mesh.normals.count == mesh.positions.count, tolerance > 0 else { return nil }

        var lookup = [ClusterKey: Int]()
        var sums = [SIMD3<Double>]()
        var normalSums = [SIMD3<Double>]()
        var counts = [Int]()
        var remap = [UInt32](repeating: 0, count: mesh.positions.count)
        for (index, position) in mesh.positions.enumerated() {
            if clock.isExpired() || isCancelled() { return nil }
            let key = ClusterKey(position, cell: tolerance)
            let cluster: Int
            if let existing = lookup[key] {
                cluster = existing
            } else {
                cluster = sums.count
                lookup[key] = cluster
                sums.append(.zero)
                normalSums.append(.zero)
                counts.append(0)
            }
            sums[cluster] += SIMD3(Double(position.x), Double(position.y), Double(position.z))
            let normal = mesh.normals[index]
            normalSums[cluster] += SIMD3(Double(normal.x), Double(normal.y), Double(normal.z))
            counts[cluster] += 1
            remap[index] = UInt32(cluster)
        }

        var positions = [SIMD3<Float>]()
        var normals = [SIMD3<Float>]()
        positions.reserveCapacity(sums.count)
        normals.reserveCapacity(sums.count)
        for cluster in sums.indices {
            let count = Double(counts[cluster])
            positions.append(SIMD3(Float(sums[cluster].x / count),
                                   Float(sums[cluster].y / count),
                                   Float(sums[cluster].z / count)))
            let normal = normalSums[cluster]
            if simd_length(normal) > 1e-12 {
                let unit = simd_normalize(normal)
                normals.append(SIMD3(Float(unit.x), Float(unit.y), Float(unit.z)))
            } else {
                normals.append(SIMD3(0, 1, 0))
            }
        }

        var indices = [UInt32]()
        var removed = 0
        var triangle = 0
        while triangle < mesh.triangleCount {
            if clock.isExpired() || isCancelled() { return nil }
            let base = triangle * 3
            triangle += 1
            let a = remap[Int(mesh.indices[base])]
            let b = remap[Int(mesh.indices[base + 1])]
            let c = remap[Int(mesh.indices[base + 2])]
            guard a != b, b != c, c != a else { removed += 1; continue }
            let pa = positions[Int(a)], pb = positions[Int(b)], pc = positions[Int(c)]
            guard simd_length(simd_cross(pb - pa, pc - pa)) > 1e-12 else {
                removed += 1
                continue
            }
            indices.append(contentsOf: [a, b, c])
        }
        let cleaned = RenderMesh(positions: positions, normals: normals, indices: indices)
        return (cleaned,
                mesh.positions.count - sums.count,
                removed)
    }

    private nonisolated struct ClusterKey: Hashable {
        let x, y, z: Int64
        init(_ position: SIMD3<Float>, cell: Double) {
            x = MeshQuantize.key64(Double(position.x), quantum: cell)
            y = MeshQuantize.key64(Double(position.y), quantum: cell)
            z = MeshQuantize.key64(Double(position.z), quantum: cell)
        }
    }

    private struct PositionKey: Hashable {
        let x, y, z: Int64
        init(_ position: SIMD3<Float>) {
            let inverse: Float = 1 / 1e-5
            x = MeshQuantize.key64(position.x, inverseQuantum: inverse)
            y = MeshQuantize.key64(position.y, inverseQuantum: inverse)
            z = MeshQuantize.key64(position.z, inverseQuantum: inverse)
        }
    }

    private struct EdgeKey: Hashable {
        let a, b: Int
        init(_ i: Int, _ j: Int) {
            if i < j { a = i; b = j } else { a = j; b = i }
        }
    }

    private struct EdgeStats {
        var triangleCount: Int
        var edgeCount: Int
        var boundary: Int
        var nonManifold: Int
        var boundarySegments: [(SIMD3<Float>, SIMD3<Float>)]
    }

    /// Boundary edges are used by exactly one triangle; non-manifold edges by
    /// more than two. Positions are topologically welded first, because the
    /// render mesh splits vertices along hard edges (position + normal).
    private static func edgeStats(_ mesh: RenderMesh,
                                  clock: EvaluationDeadlineClock) -> EdgeStats? {
        guard mesh.triangleCount > 0 else {
            return EdgeStats(triangleCount: 0, edgeCount: 0, boundary: 0,
                             nonManifold: 0, boundarySegments: [])
        }
        var lookup = [PositionKey: Int]()
        var topo = [Int](repeating: 0, count: mesh.positions.count)
        var unique = [SIMD3<Float>]()
        for (index, position) in mesh.positions.enumerated() {
            if clock.isExpired() { return nil }
            let key = PositionKey(position)
            if let existing = lookup[key] {
                topo[index] = existing
            } else {
                lookup[key] = unique.count
                topo[index] = unique.count
                unique.append(position)
            }
        }
        var edgeUses = [EdgeKey: Int]()
        var triangle = 0
        while triangle < mesh.triangleCount {
            if clock.isExpired() { return nil }
            let base = triangle * 3
            triangle += 1
            let i0 = Int(mesh.indices[base])
            let i1 = Int(mesh.indices[base + 1])
            let i2 = Int(mesh.indices[base + 2])
            let p0 = mesh.positions[i0], p1 = mesh.positions[i1], p2 = mesh.positions[i2]
            guard simd_length(simd_cross(p1 - p0, p2 - p0)) > 1e-12 else { continue }
            let t0 = topo[i0], t1 = topo[i1], t2 = topo[i2]
            guard t0 != t1, t1 != t2, t2 != t0 else { continue }
            edgeUses[EdgeKey(t0, t1), default: 0] += 1
            edgeUses[EdgeKey(t1, t2), default: 0] += 1
            edgeUses[EdgeKey(t2, t0), default: 0] += 1
        }
        var boundary = 0
        var nonManifold = 0
        var segments: [(SIMD3<Float>, SIMD3<Float>)] = []
        for (edge, uses) in edgeUses {
            if uses == 1 {
                boundary += 1
                segments.append((unique[edge.a], unique[edge.b]))
            } else if uses > 2 {
                nonManifold += 1
            }
        }
        return EdgeStats(triangleCount: mesh.triangleCount,
                         edgeCount: edgeUses.count,
                         boundary: boundary,
                         nonManifold: nonManifold,
                         boundarySegments: segments)
    }

    private static func worldBounds(of segments: [(SIMD3<Float>, SIMD3<Float>)],
                                    transform: Transform3D) -> [[Double]]? {
        guard !segments.isEmpty else { return nil }
        var minimum = SIMD3<Double>(repeating: .infinity)
        var maximum = SIMD3<Double>(repeating: -.infinity)
        for (a, b) in segments {
            for point in [a, b] {
                let world = transform.applying(to: SIMD3(Double(point.x),
                                                         Double(point.y),
                                                         Double(point.z)))
                minimum = simd_min(minimum, world)
                maximum = simd_max(maximum, world)
            }
        }
        guard minimum.x.isFinite, maximum.x.isFinite else { return nil }
        return [[minimum.x, minimum.y, minimum.z], [maximum.x, maximum.y, maximum.z]]
    }

    // MARK: Argument helpers

    private func stringList(_ raw: Any?) -> [String] {
        if let list = raw as? [String] { return list }
        if let list = raw as? [Any] { return list.compactMap { $0 as? String } }
        return []
    }

    private static func number(_ raw: Any?) -> Double? {
        guard let raw else { return nil }
        // `NSNumber(1) is Bool` is true under Swift bridging, so booleans are
        // distinguished from JSON numbers by their CoreFoundation type.
        if let nsNumber = raw as? NSNumber {
            guard CFGetTypeID(nsNumber) != CFBooleanGetTypeID() else { return nil }
            let value = nsNumber.doubleValue
            return value.isFinite ? value : nil
        }
        if raw is Bool { return nil }
        if let value = raw as? Double { return value.isFinite ? value : nil }
        if let value = raw as? Int { return Double(value) }
        return nil
    }

    private static func boolean(_ raw: Any?) -> Bool {
        guard let raw, let nsNumber = raw as? NSNumber else { return false }
        return CFGetTypeID(nsNumber) == CFBooleanGetTypeID()
    }

    private static func doubles(_ raw: Any?) -> [Double]? {
        guard let list = raw as? [Any] else {
            if let list = raw as? [Double] { return list }
            return nil
        }
        var values: [Double] = []
        values.reserveCapacity(list.count)
        for element in list {
            guard let value = number(element) else { return nil }
            values.append(value)
        }
        return values
    }

    private func sanitizeName(_ raw: Any?) -> String? {
        guard let text = raw as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(120))
    }

    private static func isPNG(_ data: Data) -> Bool {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.count >= signature.count else { return false }
        return Array(data.prefix(signature.count)) == signature
    }

    private static func isJPEG(_ data: Data) -> Bool {
        guard data.count >= 3 else { return false }
        return data[data.startIndex] == 0xFF
            && data[data.startIndex + 1] == 0xD8
            && data[data.startIndex + 2] == 0xFF
    }

    // MARK: Response helpers

    private func limitTime() -> [String: Any] {
        Self.fail("limit_time",
                  "The mesh operation exceeded the \(String(format: "%g", wallClockLimit))-second "
                  + "wall-clock limit; nothing changed.")
    }

    /// Caller cancellation is reported separately from the wall-clock deadline
    /// and never as a successful (possibly partial) mesh result.
    private func interrupted(_ cancellation: CADMeshCancellation) -> [String: Any] {
        if cancellation.isCancelled || Task.isCancelled { return Self.cancelledReply() }
        return limitTime()
    }

    private static func cancelledReply() -> [String: Any] {
        ["ok": false,
         "error": "cancelled",
         "mutated": false,
         "message": "The mesh operation was cancelled; nothing changed."]
    }

    private static func closedReply() -> [String: Any] {
        ["ok": false,
         "error": "closed",
         "mutated": false,
         "message": FloeCADStrings.text(
            "cad.mesh.error.closed",
            "The document closed while the mesh operation ran; nothing was applied.")]
    }

    private static func sourceChangedReply() -> [String: Any] {
        ["ok": false,
         "error": "source_changed",
         "mutated": false,
         "message": FloeCADStrings.text(
            "cad.mesh.error.sourceChanged",
            "The document changed while the mesh operation ran; nothing was applied. Run it again on the current bodies.")]
    }

    static func fail(_ code: String, _ message: String) -> [String: Any] {
        ["ok": false, "error": code, "message": message]
    }
}
