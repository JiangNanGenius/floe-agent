//
//  CADMeshImportService.swift
//  FloeCADKit
//
//  E31 import scheduling: the heavy mesh parse is a value-producing step that
//  runs OFF the MainActor under one `MeshImportBudget` + cooperative token,
//  while the body commit stays on the document's MainActor. This is the same
//  split the X08 mesh operations use; it does not add another parser or
//  another document owner.
//
//  Why this exists: `FloeCADDocument.nativeImportData` and the kernel command
//  importer both parse synchronously inside a MainActor method. A 10 MiB GLB
//  or STL can block the UI for the whole parse and, before this round, a
//  file-declared expansion was allocated before any budget was consulted.
//  The plan types below keep `ImportedPart`/`MeshImportProbe` internal: the
//  App passes an opaque plan and calls one MainActor apply.
//
//  A cancelled or over-budget parse throws before the document is touched;
//  the caller owns the throwaway proposal copy, so no body, proposal record or
//  package byte exists for a refused import.
//
//  SPDX-License-Identifier: MPL-2.0
//

import Foundation

/// One mesh import parsed off the main actor. The parts are already scaled to
/// the chosen unit so the MainActor apply only builds bodies and commits.
public nonisolated struct CADMeshImportPlan: Sendable {
    let probe: MeshImportProbe
    let parts: [ImportedPart]
    public let format: String
    public let fileName: String
    public let triangleCount: Int
    public let partCount: Int
    public let detectedScale: Double
    public let chargedBytes: Int
    /// True when the parse observed itself on a non-main thread (measurement
    /// witness; false for a direct synchronous call from the main actor).
    public let parsedOffMain: Bool
}

/// One single-mesh STL/OBJ import prepared off the main actor. It preserves
/// the exact `nativeImportData` semantics (one welded body, no selection or
/// camera side effects) while moving the parse off the UI thread.
public nonisolated struct CADSingleMeshImportPlan: Sendable {
    public let format: String
    public let fileName: String
    let render: RenderMesh
    public let triangleCount: Int
    public let chargedBytes: Int
    public let parsedOffMain: Bool
}

public nonisolated enum CADMeshImportService {
    /// Parse a mesh exchange (STL/OBJ/GLB/glTF/zip/Blender/USD) with the real
    /// kernel parsers under one budget and cancellation token.
    public static func parse(data: Data, fileName: String,
                             siblings: [String: Data] = [:],
                             unitScale: Double? = nil,
                             limits: MeshImportLimits = .standard,
                             cancellation: (any MeshImportCancellationChecking)? = nil)
        throws -> CADMeshImportPlan {
        let budget = MeshImportBudget(limits: limits, cancellation: cancellation,
                                      fileName: (fileName as NSString).lastPathComponent)
        do {
            let probe = try MeshImportKit.probe(data: data, fileName: fileName,
                                                siblings: siblings, budget: budget)
            // Scaling copies every position. Charge it on the parse side so the
            // MainActor apply holds no unbudgeted second mesh copy.
            let positionCount = probe.parts.reduce(0) { $0 + $1.mesh.positions.count }
            try budget.charge(positionCount * MemoryLayout<SIMD3<Float>>.stride,
                              "unit-scaled positions")
            let scale = unitScale ?? probe.detectedScale
            let parts = MeshImportKit.scaled(probe.parts, by: scale)
            try budget.checkCancellation()
            return CADMeshImportPlan(probe: probe,
                                     parts: parts,
                                     format: probe.format,
                                     fileName: (fileName as NSString).lastPathComponent,
                                     triangleCount: probe.triangleCount,
                                     partCount: parts.count,
                                     detectedScale: probe.detectedScale,
                                     chargedBytes: budget.chargedBytes,
                                     parsedOffMain: !Thread.isMainThread)
        } catch let error as MeshImportError {
            throw importError(error)
        }
    }

    /// Parse on a detached worker and join it. `cancellation` observes the
    /// tool token and is also cancelled by the caller Task's cancellation
    /// handler, so a closed panel or a cancelled run stops the same parse.
    public static func parseOffMain(data: Data, fileName: String,
                                    siblings: [String: Data] = [:],
                                    unitScale: Double? = nil,
                                    limits: MeshImportLimits = .standard,
                                    cancellation: MeshImportCancellation)
        async throws -> CADMeshImportPlan {
        let worker = Task.detached(priority: .userInitiated) {
            try parse(data: data, fileName: fileName, siblings: siblings,
                      unitScale: unitScale, limits: limits, cancellation: cancellation)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// The single-mesh path used by STEP/IGES' STL/OBJ sibling: exactly
    /// `STLImporter.importSTL` / `OBJImporter.importSingleMesh` under budget.
    public static func parseSingleMesh(data: Data, fileName: String,
                                       format: String,
                                       unitScale: Double? = nil,
                                       limits: MeshImportLimits = .standard,
                                       cancellation: (any MeshImportCancellationChecking)? = nil)
        throws -> CADSingleMeshImportPlan {
        let budget = MeshImportBudget(limits: limits, cancellation: cancellation,
                                      fileName: (fileName as NSString).lastPathComponent)
        do {
            let normalized = format.lowercased()
            let render: RenderMesh
            if normalized == "stl" {
                render = try STLImporter.importSTL(data, unitScale: unitScale ?? 1, budget: budget)
            } else {
                render = try OBJImporter.importSingleMesh(data, unitScale: unitScale ?? 1,
                                                          budget: budget)
            }
            try budget.checkCancellation()
            guard !render.indices.isEmpty else { throw MeshImportError.empty }
            return CADSingleMeshImportPlan(format: normalized,
                                           fileName: (fileName as NSString).lastPathComponent,
                                           render: render,
                                           triangleCount: render.indices.count / 3,
                                           chargedBytes: budget.chargedBytes,
                                           parsedOffMain: !Thread.isMainThread)
        } catch let error as MeshImportError {
            throw importError(error)
        }
    }

    public static func parseSingleMeshOffMain(data: Data, fileName: String,
                                              format: String,
                                              unitScale: Double? = nil,
                                              limits: MeshImportLimits = .standard,
                                              cancellation: MeshImportCancellation)
        async throws -> CADSingleMeshImportPlan {
        let worker = Task.detached(priority: .userInitiated) {
            try parseSingleMesh(data: data, fileName: fileName, format: format,
                                unitScale: unitScale, limits: limits,
                                cancellation: cancellation)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// Parse a mesh file for the interactive units prompt, OFF the MainActor.
    /// No unit scaling happens here: the prompt applies the user's choice to
    /// the same parsed parts, so the source is never parsed twice and no
    /// security-scoped file is reopened after its lease ends.
    static func parseProbe(data: Data, fileName: String,
                                  siblings: [String: Data] = [:],
                                  limits: MeshImportLimits = .standard,
                                  cancellation: (any MeshImportCancellationChecking)? = nil)
        throws -> MeshImportProbe {
        do {
            let probe = try MeshImportKit.probe(
                data: data, fileName: fileName, siblings: siblings,
                limits: limits, cancellation: cancellation)
            return probe
        } catch let error as MeshImportError {
            throw importError(error)
        }
    }

    static func parseProbeOffMain(data: Data, fileName: String,
                                         siblings: [String: Data] = [:],
                                         limits: MeshImportLimits = .standard,
                                         cancellation: MeshImportCancellation)
        async throws -> MeshImportProbe {
        let worker = Task.detached(priority: .userInitiated) {
            try parseProbe(data: data, fileName: fileName, siblings: siblings,
                           limits: limits, cancellation: cancellation)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// The units prompt's scale copy, still off the MainActor. The copy is
    /// charged to the same budget class as the AI mesh path, so a huge prompt
    /// selection cannot double the import's footprint unaccounted.
    static func scalePartsOffMain(_ parts: [ImportedPart], by factor: Double,
                                         limits: MeshImportLimits = .standard,
                                         fileName: String = "import")
        async throws -> [ImportedPart] {
        let worker = Task.detached(priority: .userInitiated) { () throws -> [ImportedPart] in
            guard factor.isFinite, factor > 0 else {
                throw CADDocumentError(code: "mesh_parse_failed",
                                       message: "The selected import unit is not a positive finite scale.")
            }
            let budget = MeshImportBudget(limits: limits, cancellation: nil,
                                          fileName: (fileName as NSString).lastPathComponent)
            let positions = parts.reduce(0) { $0 + $1.mesh.positions.count }
            do {
                try budget.charge(positions * MemoryLayout<SIMD3<Float>>.stride,
                                  "unit-scaled positions")
            } catch let error as MeshImportError {
                throw importError(error)
            }
            return MeshImportKit.scaled(parts, by: factor)
        }
        return try await worker.value
    }

    /// Apply a parsed mesh plan on the document's MainActor. `importParts`
    /// is the SAME production body-building path the kernel command importer
    /// already uses for GLB/glTF (one body per part, one undo step, pivot at
    /// the part's AABB centre, material carried through).
    @MainActor
    public static func apply(_ plan: CADMeshImportPlan,
                             to document: FloeCADDocument,
                             cancellation: (any MeshImportCancellationChecking)? = nil)
        throws -> CADCommandOutcome {
        if let block = document.session.writeBlock {
            return FloeCADDocument.jsonOutcome(
                status: 409,
                object: ["ok": false, "error": block.code, "message": block.message,
                         "mutated": false])
        }
        guard !document.isClosed else {
            return FloeCADDocument.jsonOutcome(
                status: 409,
                object: ["ok": false, "error": "read_only",
                         "message": "The CAD document is closed.", "mutated": false])
        }
        if cancellation?.isCancelled == true {
            throw CADDocumentError(code: "cancelled",
                                   message: "The import was cancelled; nothing was imported and the source was not changed.")
        }
        guard !plan.parts.isEmpty else {
            throw CADDocumentError(code: "empty_import",
                                   message: "The file produced no importable bodies; nothing was changed.")
        }
        let before = Set(document.session.document.bodies.map(\.id))
        let model = document.viewModel()
        model.errorMessage = nil
        model.importParts(plan.parts, fileName: plan.fileName)
        if let error = model.errorMessage {
            return FloeCADDocument.jsonOutcome(
                status: 422,
                object: ["ok": false, "error": "empty_mesh", "message": error])
        }
        // Once `importParts` has run, the add is one atomic undo step on the
        // MainActor. A cancellation observed after this point cannot split it;
        // the caller commits or discards the whole step, never a half body.
        let added = document.session.document.bodies.filter { !before.contains($0.id) }
        guard !added.isEmpty else {
            return FloeCADDocument.jsonOutcome(
                status: 422,
                object: ["ok": false, "error": "empty_mesh",
                         "message": "The file produced no importable bodies; nothing was changed."])
        }
        return FloeCADDocument.jsonOutcome(status: 200, object: [
            "ok": true,
            "imported": added.map { body -> [String: Any] in
                ["bodyID": body.id.raw.uuidString, "name": body.name, "analyticBRep": false]
            },
            "count": added.count,
            "mutated": true,
        ])
    }

    /// Apply the single-mesh plan with the exact `nativeImportData` STL/OBJ
    /// body construction (one body, identity transform, no selection change).
    @MainActor
    public static func applySingleMesh(_ plan: CADSingleMeshImportPlan,
                                       to document: FloeCADDocument,
                                       cancellation: (any MeshImportCancellationChecking)? = nil)
        throws -> CADCommandOutcome {
        if let block = document.session.writeBlock {
            return FloeCADDocument.jsonOutcome(
                status: 409,
                object: ["ok": false, "error": block.code, "message": block.message,
                         "mutated": false])
        }
        guard !document.isClosed else {
            return FloeCADDocument.jsonOutcome(
                status: 409,
                object: ["ok": false, "error": "read_only",
                         "message": "The CAD document is closed.", "mutated": false])
        }
        if cancellation?.isCancelled == true {
            throw CADDocumentError(code: "cancelled",
                                   message: "The import was cancelled; nothing was imported and the source was not changed.")
        }
        let baseName = plan.fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = baseName.isEmpty ? "Imported" : baseName
        var localDocument = document.session.document
        var body = Body(id: BodyID(),
                        name: localDocument.uniqueBodyName(base: fallback),
                        transform: .identity,
                        primitive: nil,
                        render: plan.render,
                        revision: localDocument.nextRevision())
        body.euclid = EuclidBridge.euclidMesh(from: plan.render)
        if cancellation?.isCancelled == true {
            throw CADDocumentError(code: "cancelled",
                                   message: "The import was cancelled; nothing was imported and the source was not changed.")
        }
        document.session.perform(AddBodyCommand(body: body, title: "Import \(body.name)"))
        return FloeCADDocument.jsonOutcome(status: 200, object: [
            "ok": true,
            "imported": [["bodyID": body.id.raw.uuidString, "name": body.name,
                          "analyticBRep": false]],
            "count": 1,
            "mutated": true,
        ])
    }

    /// The kernel error taxonomy the host/tool already understands. The App
    /// never catches the kernel-internal `MeshImportError`; it receives these
    /// stable codes and messages.
    nonisolated static func importError(_ error: MeshImportError) -> CADDocumentError {
        switch error {
        case .cancelled:
            return CADDocumentError(
                code: "cancelled",
                message: "The import was cancelled; nothing was imported and the source was not changed.")
        case .overBudget(let detail):
            return CADDocumentError(
                code: "import_over_budget",
                message: "The file exceeds the import budget: \(detail). "
                    + "Nothing was imported; the source and document are unchanged.")
        case .unsupportedFormat(let what):
            return CADDocumentError(
                code: "unsupported_format",
                message: "The \(what.isEmpty ? "unknown" : what) format is not supported by this import.")
        case .empty:
            return CADDocumentError(
                code: "empty_import",
                message: "The file produced no importable bodies; nothing was changed.")
        case .malformed(let what):
            return CADDocumentError(
                code: "mesh_parse_failed",
                message: "The file could not be parsed: \(what)")
        }
    }
}
