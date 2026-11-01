//
//  CADExactImportService.swift
//  FloeCADKit
//
//  E31-R2 import scheduling: STEP/IGES read + tessellation is a value-producing
//  step that runs OFF the MainActor, and only the exact-body commit runs on the
//  document's actor.
//
//  Ownership model (do not weaken):
//    * The worker creates FRESH OCCT reader/import handles from the caller's
//      bytes. Those handles have never been exposed to the document, undo,
//      identity or presentation layers, so they cannot alias a live/undo/
//      serialized handle. `BRepHandle` stays `@unchecked Sendable` with its
//      documented caveat: live handles never cross the actor boundary.
//    * Each fresh handle is serialized with `OCCTKernel.serialize` inside the
//      worker. The plan carries immutable `Data` (plus the render/value plan),
//      never a handle.
//    * The MainActor commit restores a NEW handle per body with
//      `OCCTKernel.deserialize`, builds every body before the first command,
//      checks cancellation once and then commits the prepared bodies in one
//      `CompositeCommand` (one undo step, one document mutation) or, for the
//      legacy synchronous `nativeImportData` path, in its historical per-body
//      undo granularity.
//
//  Concurrency: OCCT's STEP/IGES readers and `IGESControl_Controller::Init`
//  are process-global resources with no reader queue in the bridge (verified in
//  OCCTBridge.mm `readSTEPFromPath:` / `OS3DReadIGES`). The service serializes
//  all exact parses with one cancellation-aware gate held only INSIDE the
//  synchronous worker: never across an await and never acquired by the
//  MainActor commit. A queued waiter observes its token while it waits and
//  refuses BEFORE the reader; the acquisition path re-checks cancellation
//  immediately before each OCCT read. Cancelling cannot kill an in-flight OCCT
//  call; the token stops further solids and the late commit, and the owned
//  worker is joined before the import returns.
//
//  SPDX-License-Identifier: MPL-2.0
//

import Foundation

/// One exact import parsed (or ready to parse) off the document actor. Opaque:
/// callers receive counts and an apply function, never a live kernel handle.
public nonisolated struct CADExactImportPlan: Sendable {
    public let format: String
    public let fileName: String
    public let solidCount: Int
    public let surfaceCount: Int
    public let skippedSurfaceCount: Int
    public let triangleCount: Int
    /// Bytes retained by the immutable plan (render/edge arrays + serialized
    /// exact blobs). Reported for measurement; unlike the mesh budget this is
    /// not a policy ceiling, because a STEP/IGES payload is not a
    /// file-declared *expansion* of a compressed asset.
    public let retainedBytes: Int
    public let chargedBytes: Int
    public let rootCount: Int
    /// True when the parse ran on a non-main thread (measurement witness).
    public let parsedOffMain: Bool
    /// Serialized exact bodies + their immutable render/edge plan. Internal so
    /// no caller can extract/reuse a live handle or mutate the plan.
    let bodies: [BodyPlan]

    nonisolated struct BodyPlan: Sendable {
        let isSurface: Bool
        let baseName: String
        let uniqueName: Bool
        let faceCount: Int?
        /// Serialized exact OCCT shape; restored to a NEW handle at commit.
        let exactData: Data
        let render: RenderMesh
        let edges: FeatureEdgeSet
        let retainedBytes: Int
        var triangleCount: Int { render.indices.count / 3 }
    }
}

/// One applied exact import: the stable `CADCommandOutcome` the import callers
/// already understand plus the real body ids/counts for the interactive
/// selection step.
public nonisolated struct CADExactImportApplication: Sendable {
    public let outcome: CADCommandOutcome
    public let importedBodyIDs: [UUID]
    public let solidCount: Int
    public let surfaceCount: Int
    public let skippedSurfaceCount: Int
    public let bodyCount: Int
}

/// How the prepared bodies reach the document. `.singleStep` is the App/tool
/// path (one undoable transaction, one document mutation). `.perBody` keeps
/// the historical synchronous `nativeImportData` undo granularity so existing
/// document contracts/tests are preserved; both check cancellation exactly once
/// BEFORE the first command, so a late cancel can never split a commit.
public nonisolated enum CADExactImportUndoMode: Sendable {
    case singleStep
    case perBody
}

public nonisolated enum CADExactImportService {
    // MARK: - Parse (worker-safe, MainActor-free)

    /// Parse exact STEP/IGES bytes under one budget + cooperative token. Safe
    /// to call from a worker: it only creates/consumes its own fresh handles.
    ///
    /// `waitForParser` is for WORKER callers only: the wait is cancellation
    /// aware, so a cancelled import leaves the queue without reading. The
    /// legacy synchronous entry passes `false` and converts a busy gate into
    /// `import_busy` instead of blocking its caller (the MainActor).
    public static func parse(data: Data,
                             format rawFormat: String,
                             fileName: String,
                             bodyNameBase: String? = nil,
                             uniqueBodyNames: Bool = false,
                             limits: MeshImportLimits = .standard,
                             cancellation: (any MeshImportCancellationChecking)? = nil,
                             waitForParser: Bool = true)
        throws -> CADExactImportPlan {
        let format = normalizedFormat(rawFormat)
        let displayName = trimmedName(fileName) ?? "Imported"
        let baseName = trimmedName(bodyNameBase) ?? displayName
        let budget = MeshImportBudget(limits: limits, cancellation: cancellation,
                                      fileName: displayName)
        do {
            try budget.checkCancellation()
        } catch let error as MeshImportError {
            throw mapped(error)
        }
        guard format == "step" || format == "stp" || format == "iges" || format == "igs" else {
            throw CADDocumentError(
                code: "unsupported_format",
                message: "Exact import supports STEP (.step/.stp) and IGES (.igs/.iges); "
                    + "got '\(format)'.")
        }
        let checkpoint = {
            #if DEBUG
            testCheckpoint?(CADExactImportCheckpoint(
                phase: "begin", format: format, bodyIndex: 0, bodyCount: 0,
                ranOnMainThread: Thread.isMainThread,
                chargedBytes: budget.chargedBytes))
            #endif
        }
        checkpoint()
        // One exact parse at a time: OCCT's readers/IGES controller are global
        // and the bridge installs no reader queue. The gate is held only while
        // this synchronous function runs; it is never held across an await.
        // A legacy synchronous entry must NOT block the MainActor waiting for
        // an in-flight worker; it asks for a non-blocking acquire and refuses
        // with `import_busy` instead. Workers wait (serialized) in short
        // cancellation-aware slices, so a cancelled waiter leaves this queue
        // WITHOUT waiting for the current owner's OCCT call to finish and
        // without ever starting its own reader.
        if waitForParser {
            guard parseSerialization.wait(whileCancelled: { budget.isCancelled }) else {
                throw cancelled()
            }
        } else if !parseSerialization.tryAcquire() {
            throw CADDocumentError(
                code: "import_busy",
                message: "Another exact import is already running; nothing was imported.")
        }
        defer { parseSerialization.release() }
        // Cancelled AFTER acquisition (queued while the owner ran, or while
        // another waiter held the slot): refuse before the reader starts.
        do {
            try budget.checkCancellation()
        } catch let error as MeshImportError {
            throw mapped(error)
        }
        #if DEBUG
        testParseEntered()
        defer { testParseExited() }
        testCheckpoint?(CADExactImportCheckpoint(
            phase: "locked", format: format, bodyIndex: 0, bodyCount: 0,
            ranOnMainThread: Thread.isMainThread,
            chargedBytes: budget.chargedBytes))
        #endif
        do {
            switch format {
            case "step", "stp":
                return try parseSTEP(data: data, format: format, displayName: displayName,
                                     baseName: baseName, uniqueBodyNames: uniqueBodyNames,
                                     budget: budget)
            default:
                return try parseIGES(data: data, format: format, displayName: displayName,
                                     baseName: baseName, budget: budget)
            }
        } catch let error as MeshImportError {
            throw mapped(error)
        } catch let error as CADDocumentError {
            throw error
        } catch {
            throw CADDocumentError(
                code: "import_failed",
                message: "The \(format.uppercased()) file could not be imported: "
                    + "\(error.localizedDescription). Nothing was imported.")
        }
    }

    /// Parse on a detached worker and JOIN it. A caller Task cancellation
    /// cancels the same cooperative token, so a closed panel/switch stops the
    /// import while an in-flight OCCT call is allowed to finish (it is never
    /// reported as complete; the late commit is fenced).
    public static func parseOffMain(data: Data,
                                    format: String,
                                    fileName: String,
                                    bodyNameBase: String? = nil,
                                    uniqueBodyNames: Bool = false,
                                    limits: MeshImportLimits = .standard,
                                    cancellation: MeshImportCancellation)
        async throws -> CADExactImportPlan {
        let worker = Task.detached(priority: .userInitiated) {
            try parse(data: data, format: format, fileName: fileName,
                      bodyNameBase: bodyNameBase, uniqueBodyNames: uniqueBodyNames,
                      limits: limits, cancellation: cancellation,
                      waitForParser: true)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func parseSTEP(data: Data, format: String, displayName: String,
                                  baseName: String, uniqueBodyNames: Bool,
                                  budget: MeshImportBudget)
        throws -> CADExactImportPlan {
        // Immediately before the reader: a cancel that arrived while this
        // parse was queued, or between entry and here, must not start OCCT.
        try budget.checkCancellation()
        let solids = STEPKit.solids(from: data)
        try budget.checkCancellation()
        #if DEBUG
        testCheckpoint?(CADExactImportCheckpoint(
            phase: "read", format: format, bodyIndex: 0, bodyCount: solids.count,
            ranOnMainThread: Thread.isMainThread,
            chargedBytes: budget.chargedBytes))
        #endif
        guard !solids.isEmpty else {
            throw CADDocumentError(
                code: "no_solids",
                message: "The STEP file carries no readable solid; nothing was imported.")
        }
        var bodies: [CADExactImportPlan.BodyPlan] = []
        for (index, solid) in solids.enumerated() {
            try budget.checkCancellation()
            let name = uniqueBodyNames
                ? baseName
                : (solids.count > 1 ? "\(baseName) \(index + 1)" : baseName)
            let plan: CADExactImportPlan.BodyPlan
            do {
                plan = try preparedBody(from: solid, isSurface: false, baseName: name,
                                        uniqueName: uniqueBodyNames, faceCount: nil,
                                        budget: budget)
            } catch let error as CADDocumentError where error.code == "import_over_budget" {
                throw error
            } catch let error as MeshImportError {
                throw mapped(error)
            } catch {
                throw CADDocumentError(
                    code: "step_body_failed",
                    message: "Solid \(index + 1) could not be meshed; nothing was imported.")
            }
            bodies.append(plan)
            MeshImportKit.testImportBodyCheckpoint?(bodies.count)
            #if DEBUG
            testCheckpoint?(CADExactImportCheckpoint(
                phase: "body", format: format, bodyIndex: bodies.count,
                bodyCount: solids.count, ranOnMainThread: Thread.isMainThread,
                chargedBytes: budget.chargedBytes))
            #endif
        }
        try budget.checkCancellation()
        return CADExactImportPlan(
            format: format, fileName: displayName,
            solidCount: bodies.count, surfaceCount: 0, skippedSurfaceCount: 0,
            triangleCount: budget.triangles,
            retainedBytes: bodies.reduce(0) { $0 + $1.retainedBytes },
            chargedBytes: budget.chargedBytes,
            rootCount: solids.count, parsedOffMain: !Thread.isMainThread,
            bodies: bodies)
    }

    private static func parseIGES(data: Data, format: String, displayName: String,
                                  baseName: String, budget: MeshImportBudget)
        throws -> CADExactImportPlan {
        // Immediately before the reader (see parseSTEP).
        try budget.checkCancellation()
        let iges = OCCTKernel.readIGES(data)
        try budget.checkCancellation()
        #if DEBUG
        testCheckpoint?(CADExactImportCheckpoint(
            phase: "read", format: format,
            bodyIndex: 0, bodyCount: iges.solids.count + iges.surfaces.count,
            ranOnMainThread: Thread.isMainThread,
            chargedBytes: budget.chargedBytes))
        #endif
        guard iges.readSucceeded else {
            throw CADDocumentError(
                code: "iges_read_failed",
                message: "The IGES file could not be read (its records did not parse); "
                    + "nothing was imported.")
        }
        guard iges.rootCount > 0 else {
            throw CADDocumentError(
                code: "iges_empty",
                message: "The IGES file parsed but carries no transferable shape; "
                    + "nothing was imported.")
        }
        let total = iges.solids.count + iges.surfaces.count
        var bodies: [CADExactImportPlan.BodyPlan] = []
        for (index, solid) in iges.solids.enumerated() {
            try budget.checkCancellation()
            let name = total > 1 ? "\(baseName) Solid \(index + 1)" : baseName
            let faceCount = index < iges.solidFaceCounts.count
                ? iges.solidFaceCounts[index] : nil
            do {
                bodies.append(try preparedBody(
                    from: solid, isSurface: false, baseName: name,
                    uniqueName: true, faceCount: faceCount, budget: budget))
            } catch let error as CADDocumentError where error.code == "import_over_budget" {
                throw error
            } catch let error as MeshImportError {
                throw mapped(error)
            } catch {
                throw CADDocumentError(
                    code: "iges_import_failed",
                    message: "The IGES file's solid \(index + 1) could not be tessellated; "
                        + "nothing was imported.")
            }
            MeshImportKit.testImportBodyCheckpoint?(bodies.count)
            #if DEBUG
            testCheckpoint?(CADExactImportCheckpoint(
                phase: "body", format: format, bodyIndex: bodies.count,
                bodyCount: total, ranOnMainThread: Thread.isMainThread,
                chargedBytes: budget.chargedBytes))
            #endif
        }
        var skippedSurfaces = 0
        for (index, surface) in iges.surfaces.enumerated() {
            try budget.checkCancellation()
            let name = total > 1 ? "\(baseName) Surface \(index + 1)"
                                 : "\(baseName) Surface"
            let faceCount = index < iges.surfaceFaceCounts.count
                ? iges.surfaceFaceCounts[index] : nil
            do {
                bodies.append(try preparedBody(
                    from: surface, isSurface: true, baseName: name,
                    uniqueName: true, faceCount: faceCount, budget: budget))
            } catch let error as CADDocumentError where error.code == "import_over_budget" {
                throw error
            } catch let error as MeshImportError {
                throw mapped(error)
            } catch {
                // A surface that will not tessellate is skipped, exactly like
                // the legacy IGES import; the remaining exact roots still land.
                skippedSurfaces += 1
                continue
            }
            MeshImportKit.testImportBodyCheckpoint?(bodies.count)
            #if DEBUG
            testCheckpoint?(CADExactImportCheckpoint(
                phase: "body", format: format, bodyIndex: bodies.count,
                bodyCount: total, ranOnMainThread: Thread.isMainThread,
                chargedBytes: budget.chargedBytes))
            #endif
        }
        try budget.checkCancellation()
        guard !bodies.isEmpty else {
            throw CADDocumentError(
                code: "iges_import_failed",
                message: "The IGES file's \(iges.rootCount) shape(s) did not survive "
                    + "validation and tessellation; nothing was imported.")
        }
        let surfaces = bodies.filter(\.isSurface).count
        return CADExactImportPlan(
            format: format, fileName: displayName,
            solidCount: bodies.count - surfaces, surfaceCount: surfaces,
            skippedSurfaceCount: skippedSurfaces,
            triangleCount: budget.triangles,
            retainedBytes: bodies.reduce(0) { $0 + $1.retainedBytes },
            chargedBytes: budget.chargedBytes,
            rootCount: iges.rootCount, parsedOffMain: !Thread.isMainThread,
            bodies: bodies)
    }

    /// Tessellate one FRESH import handle into the immutable plan and charge
    /// every retained allocation to the same import budget. The handle is
    /// discarded when this returns; the plan holds only `Data`/value arrays.
    private static func preparedBody(from handle: BRepHandle, isSurface: Bool,
                                     baseName: String, uniqueName: Bool,
                                     faceCount: Int?, budget: MeshImportBudget)
        throws -> CADExactImportPlan.BodyPlan {
        try budget.checkCancellation()
        guard !isSurface || !handle.containsSolid else {
            throw CADDocumentError(
                code: "iges_import_failed",
                message: "An IGES surface root unexpectedly contained a solid; "
                    + "nothing was imported.")
        }
        let mesh = OCCTKernel.renderMesh(from: handle)
        guard !mesh.positions.isEmpty, !mesh.indices.isEmpty else {
            throw CADDocumentError(code: "empty_mesh",
                                   message: "The imported shape produced no render mesh.")
        }
        let render = RenderMesh(positions: mesh.positions, normals: mesh.normals,
                                indices: mesh.indices)
        let edgeSet = FeatureEdgeExtractor.edges(from: render)
        try budget.addTriangles(render.triangleCount)
        try budget.addPart(baseName)
        let renderBytes = render.positions.count * MemoryLayout<SIMD3<Float>>.stride
            + render.normals.count * MemoryLayout<SIMD3<Float>>.stride
            + render.indices.count * MemoryLayout<UInt32>.stride
            + edgeSet.segments.count * MemoryLayout<SIMD3<Float>>.stride
        guard let exact = OCCTKernel.serialize(handle) else {
            throw CADDocumentError(
                code: "import_failed",
                message: "The exact shape could not be serialized; nothing was imported.")
        }
        try budget.checkCancellation()
        // No byte-budget charge here: exact STEP/IGES is not a compressed
        // asset's declared expansion, and R1's exact path only accounted
        // triangles. The retained bytes are reported for the real footprint
        // measurement instead of being turned into a new refusal cap.
        return CADExactImportPlan.BodyPlan(
            isSurface: isSurface, baseName: baseName, uniqueName: uniqueName,
            faceCount: faceCount, exactData: exact, render: render, edges: edgeSet,
            retainedBytes: renderBytes + exact.count)
    }

    // MARK: - Apply (document MainActor)

    /// Apply a prepared exact plan to a live document. Cancellation is checked
    /// before body construction and once more before the first command; a cancel
    /// that arrives after the commit starts cannot split it.
    @MainActor
    public static func apply(_ plan: CADExactImportPlan,
                             to document: FloeCADDocument,
                             cancellation: (any MeshImportCancellationChecking)? = nil,
                             undoMode: CADExactImportUndoMode = .singleStep,
                             title: String? = nil)
        throws -> CADExactImportApplication {
        try apply(plan, to: document.session, closed: document.isClosed,
                  cancellation: cancellation, undoMode: undoMode, title: title)
    }

    /// Session-level apply used by the workbench view model (which owns the
    /// shared session but not the facade). `closed` is supplied by the facade
    /// when one exists; a closed document must never be mutated.
    @MainActor
    static func apply(_ plan: CADExactImportPlan,
                      to session: DocumentSession,
                      closed: Bool,
                      cancellation: (any MeshImportCancellationChecking)? = nil,
                      undoMode: CADExactImportUndoMode = .singleStep,
                      title: String? = nil)
        throws -> CADExactImportApplication {
        if let block = session.writeBlock {
            let outcome = FloeCADDocument.jsonOutcome(
                status: 409,
                object: ["ok": false, "error": block.code, "message": block.message,
                         "mutated": false])
            return CADExactImportApplication(
                outcome: outcome, importedBodyIDs: [], solidCount: 0,
                surfaceCount: 0, skippedSurfaceCount: plan.skippedSurfaceCount,
                bodyCount: 0)
        }
        guard !closed else {
            let outcome = FloeCADDocument.jsonOutcome(
                status: 409,
                object: ["ok": false, "error": "read_only",
                         "message": "The CAD document is closed.", "mutated": false])
            return CADExactImportApplication(
                outcome: outcome, importedBodyIDs: [], solidCount: 0,
                surfaceCount: 0, skippedSurfaceCount: plan.skippedSurfaceCount,
                bodyCount: 0)
        }
        if cancellation?.isCancelled == true { throw cancelled() }
        guard !plan.bodies.isEmpty else { throw emptyImport() }
        #if DEBUG
        testCheckpoint?(CADExactImportCheckpoint(
            phase: "commit", format: plan.format, bodyIndex: 0,
            bodyCount: plan.bodies.count, ranOnMainThread: Thread.isMainThread,
            chargedBytes: plan.chargedBytes))
        #endif

        var localDocument = session.document
        var pending: [(body: Body, isSurface: Bool, faceCount: Int?)] = []
        pending.reserveCapacity(plan.bodies.count)
        for bodyPlan in plan.bodies {
            if cancellation?.isCancelled == true { throw cancelled() }
            guard let handle = OCCTKernel.deserialize(bodyPlan.exactData) else {
                throw CADDocumentError(
                    code: "import_failed",
                    message: "The exact shape blob could not be restored; nothing was imported.")
            }
            if bodyPlan.isSurface, handle.containsSolid {
                throw CADDocumentError(
                    code: "import_failed",
                    message: "An exact open-surface body could not be restored; nothing was imported.")
            }
            let name = bodyPlan.uniqueName
                ? localDocument.uniqueBodyName(base: bodyPlan.baseName)
                : bodyPlan.baseName
            var body = Body(id: BodyID(), name: name, transform: .identity,
                            render: bodyPlan.render, edges: bodyPlan.edges,
                            revision: localDocument.nextRevision())
            if bodyPlan.isSurface {
                body.surfaceBRep = handle
                body.brep = nil
            } else {
                body.brep = handle
                body.surfaceBRep = nil
            }
            body.euclid = EuclidBridge.euclidMesh(from: bodyPlan.render)
            localDocument.bodies.append(body)
            pending.append((body, bodyPlan.isSurface, bodyPlan.faceCount))
        }
        if cancellation?.isCancelled == true { throw cancelled() }

        let undoTitle = title ?? "Import \(plan.fileName)"
        let commands = pending.map {
            AddBodyCommand(body: $0.body, title: "Import \($0.body.name)")
        }
        switch undoMode {
        case .singleStep:
            session.perform(CompositeCommand(title: undoTitle, commands: commands))
        case .perBody:
            // Historical `nativeImportData` granularity (one undo step per
            // body). No cancellation check between commands: the atomic unit
            // is "every prepared body", never a half model.
            for command in commands {
                session.perform(command)
            }
        }
        #if DEBUG
        testCheckpoint?(CADExactImportCheckpoint(
            phase: "committed", format: plan.format, bodyIndex: pending.count,
            bodyCount: pending.count, ranOnMainThread: Thread.isMainThread,
            chargedBytes: plan.chargedBytes))
        #endif

        let solids = pending.filter { !$0.isSurface }.count
        let surfaces = pending.count - solids
        var importedRows: [[String: Any]] = []
        importedRows.reserveCapacity(pending.count)
        for entry in pending {
            var row: [String: Any] = [
                "bodyID": entry.body.id.raw.uuidString,
                "name": entry.body.name,
                "analyticBRep": !entry.isSurface,
            ]
            if plan.format == "iges" || plan.format == "igs" {
                row["openSurfaceBRep"] = entry.isSurface
                row["kind"] = entry.isSurface ? "surface" : "solid"
                if let faceCount = entry.faceCount { row["faceCount"] = faceCount }
            }
            importedRows.append(row)
        }
        var object: [String: Any] = [
            "ok": true,
            "imported": importedRows,
            "count": pending.count,
            "mutated": true,
        ]
        if plan.format == "iges" || plan.format == "igs" {
            object["solidsImported"] = solids
            object["surfacesImported"] = surfaces
            object["openSurfaceBodies"] = surfaces
            var notes: [String] = []
            if surfaces > 0 {
                notes.append("IGES surfaces are not solids: \(surfaces) shell/face "
                    + "body(ies) were imported as exact open-surface bodies (analyticBRep: false) "
                    + "and cannot take boolean, fillet or shell operations. They can be moved, "
                    + "rotated, scaled, material-painted and exported back to IGES.")
            }
            if plan.skippedSurfaceCount > 0 {
                notes.append("\(plan.skippedSurfaceCount) surface(s) failed to tessellate "
                    + "and were skipped.")
            }
            if !notes.isEmpty { object["note"] = notes.joined(separator: " ") }
        }
        return CADExactImportApplication(
            outcome: FloeCADDocument.jsonOutcome(status: 200, object: object),
            importedBodyIDs: pending.map { $0.body.id.raw },
            solidCount: solids, surfaceCount: surfaces,
            skippedSurfaceCount: plan.skippedSurfaceCount,
            bodyCount: pending.count)
    }

    /// The synchronous legacy entry used by `FloeCADDocument.nativeImportData`:
    /// same parse + historical per-body undo mode, same structured outcome.
    @MainActor
    static func importSync(_ data: Data, format: String, fileName: String?,
                           unitScale: Double?, limits: MeshImportLimits,
                           cancellation: (any MeshImportCancellationChecking)?,
                           to document: FloeCADDocument) -> CADCommandOutcome {
        if let block = document.session.writeBlock {
            return FloeCADDocument.jsonOutcome(
                status: 409, object: ["ok": false, "error": block.code,
                    "message": block.message, "mutated": false])
        }
        guard !document.isClosed else {
            return FloeCADDocument.jsonOutcome(
                status: 409, object: ["ok": false, "error": "read_only",
                    "message": "The CAD document is closed.", "mutated": false])
        }
        do {
            let plan = try parse(data: data, format: format,
                                 fileName: fileName ?? "Imported",
                                 limits: limits, cancellation: cancellation,
                                 waitForParser: false)
            let application = try apply(plan, to: document,
                                        cancellation: cancellation,
                                        undoMode: .perBody)
            return application.outcome
        } catch let error as CADDocumentError {
            let status = error.code == "cancelled" ? 422
                : (error.code == "import_over_budget" ? 422 : 422)
            return FloeCADDocument.jsonOutcome(
                status: status,
                object: ["ok": false, "error": error.code, "message": error.message])
        } catch let error as MeshImportError {
            let mapped = mapped(error)
            return FloeCADDocument.jsonOutcome(
                status: 422,
                object: ["ok": false, "error": mapped.code, "message": mapped.message])
        } catch {
            return FloeCADDocument.jsonOutcome(
                status: 422,
                object: ["ok": false, "error": "import_failed",
                         "message": "The import failed: \(error.localizedDescription)"])
        }
    }

    // MARK: - Errors / helpers

    private static func mapped(_ error: MeshImportError) -> CADDocumentError {
        switch error {
        case .cancelled:
            return cancelled()
        case .overBudget(let detail):
            return CADDocumentError(
                code: "import_over_budget",
                message: "The import exceeds the import budget: \(detail). Nothing was imported; "
                    + "the source and document are unchanged.")
        case .unsupportedFormat(let what):
            return CADDocumentError(
                code: "unsupported_format",
                message: "The \(what.isEmpty ? "unknown" : what) format is not supported by this import.")
        case .empty:
            return emptyImport()
        case .malformed(let what):
            return CADDocumentError(
                code: "mesh_parse_failed",
                message: "The file could not be parsed: \(what)")
        }
    }

    private static func cancelled() -> CADDocumentError {
        CADDocumentError(code: "cancelled",
                         message: "Import cancelled; nothing was imported.")
    }

    private static func emptyImport() -> CADDocumentError {
        CADDocumentError(code: "empty_import",
                         message: "The file produced no importable bodies; nothing was changed.")
    }

    private static func normalizedFormat(_ raw: String) -> String {
        var format = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if format == "igs" { format = "iges" }
        if format == "stp" { format = "step" }
        return format
    }

    private static func trimmedName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Serializes every exact parse. Held only inside the synchronous worker;
    /// never across an await and never by the MainActor commit.
    private static let parseSerialization = ExactParseSerialization()

    #if DEBUG
    /// Deterministic test seam for the REAL exact parse. Fires on the worker
    /// (begin/locked/read/body) and on the document actor (commit/committed).
    /// Production leaves it nil and pays no branch.
    nonisolated(unsafe) static var testCheckpoint: (@Sendable (CADExactImportCheckpoint) -> Void)?

    private static let testCounterLock = NSLock()
    nonisolated(unsafe) private static var testActiveParsers = 0
    nonisolated(unsafe) private static var testMaxActiveParsers = 0

    private static func testParseEntered() {
        testCounterLock.lock()
        testActiveParsers += 1
        if testActiveParsers > testMaxActiveParsers {
            testMaxActiveParsers = testActiveParsers
        }
        testCounterLock.unlock()
    }

    static func testParseExited() {
        testCounterLock.lock()
        testActiveParsers = max(0, testActiveParsers - 1)
        testCounterLock.unlock()
    }

    /// Highest number of exact parses that entered the serialized section at
    /// the same time. A correct run is 1.
    static var testPeakConcurrentParsers: Int {
        testCounterLock.lock()
        defer { testCounterLock.unlock() }
        return testMaxActiveParsers
    }

    static func testResetPeakConcurrentParsers() {
        testCounterLock.lock()
        testMaxActiveParsers = testActiveParsers
        testCounterLock.unlock()
    }
    #endif
}

/// E31-R3 process-wide serialization for the OCCT STEP/IGES readers.
///
/// Why not `NSLock`: a cancelled import that is queued behind a long OCCT read
/// must LEAVE the queue promptly instead of waiting for the owner to finish,
/// and must never start its own reader afterwards. A plain lock gives no
/// cancellation point, and once acquired its holder reads unconditionally.
/// This gate polls the caller's cooperative token in short slices while it
/// waits and answers `false` (no acquisition) when the token was cancelled;
/// release broadcasts so a live waiter wakes immediately instead of waiting
/// out the slice. The gate is never held across an `await`; the legacy
/// synchronous entry only uses the non-blocking `tryAcquire` so the MainActor
/// can never be stalled behind a worker.
nonisolated private final class ExactParseSerialization: @unchecked Sendable {
    private let condition = NSCondition()
    private var occupied = false
    /// Cancellation poll granularity for a queued waiter. Bounded because the
    /// owner's OCCT call itself cannot be interrupted.
    private static let waitSlice: TimeInterval = 0.02

    /// Wait until the slot is free. Returns false, WITHOUT acquiring, when the
    /// token is cancelled first; the caller must then refuse the import.
    func wait(whileCancelled isCancelled: () -> Bool) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while occupied {
            if isCancelled() { return false }
            _ = condition.wait(until: Date(timeIntervalSinceNow: Self.waitSlice))
        }
        // A cancel that lands exactly between the last check and acquisition
        // still refuses before the caller's next pre-reader check.
        if isCancelled() { return false }
        occupied = true
        return true
    }

    /// Non-blocking acquire for the legacy synchronous entry.
    func tryAcquire() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard !occupied else { return false }
        occupied = true
        return true
    }

    func release() {
        condition.lock()
        occupied = false
        condition.broadcast()
        condition.unlock()
    }
}

#if DEBUG
/// One real exact-import checkpoint. `bodyCount` is the number of bodies the
/// file declared (STEP solids or IGES roots); `bodyIndex` is how many have
/// been prepared/committed when the phase fires. Public only in DEBUG test
/// builds; Release has no checkpoint type at all.
public nonisolated struct CADExactImportCheckpoint: Sendable {
    public let phase: String
    public let format: String
    public let bodyIndex: Int
    public let bodyCount: Int
    public let ranOnMainThread: Bool
    public let chargedBytes: Int

    public init(phase: String, format: String, bodyIndex: Int, bodyCount: Int,
                ranOnMainThread: Bool, chargedBytes: Int) {
        self.phase = phase
        self.format = format
        self.bodyIndex = bodyIndex
        self.bodyCount = bodyCount
        self.ranOnMainThread = ranOnMainThread
        self.chargedBytes = chargedBytes
    }
}
#endif
