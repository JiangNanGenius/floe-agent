//
//  CADExchangeExport.swift
//  FloeCADKit
//
//  Placed-assembly exchange export (E24/E25).
//
//  The existing `EditorViewModel`/`nativeExportData` exporters consume
//  `document.bodies` and therefore write one copy of each PART DEFINITION.
//  They never see assembly placements. This file adds the missing product
//  loop on top of the SAME resolved occurrence tree the viewport and drawing
//  services already use:
//
//    * `scope=part` is the historical behaviour: selected/all document
//      bodies, each body's own transform.
//    * `scope=assembly` walks `CADAssembly.occurrences(includeHidden:false)`,
//      resolves every visible placed part through its source body, composes
//      the ancestor placement with the source body transform exactly once,
//      and keeps occurrence IDs/paths on the receipt (and, for GLB, on real
//      nodes/extras). A hidden definition with visible instances is still
//      exported through those visible instances; a hidden INSTANCE is not.
//
//  Coverage is computed BEFORE any file is promoted. STEP can only carry
//  analytic B-rep occurrences, so mesh-only objects are listed and require
//  an explicit `acceptPartial` choice. GLB can carry every valid mesh, but
//  invalid meshes/material images are never silently treated as a complete
//  success: they are reported in the same coverage receipt.
//
//  `nativePartExport` is the legacy whole-document entry (no explicit scope):
//  it returns the SAME truthfully computed part receipt and refuses an
//  incomplete receipt unless the caller explicitly accepted the actual loss,
//  so the historical "always complete" shortcut cannot come back.
//
//  No new export manager, permission flow or selection store is introduced.
//  Callers hand in the exact body/instance IDs they selected; the plan is
//  built from the live document and the existing assembly resolver.
//
//  Units: model space is millimetres. STEP is written in mm. GLB keeps
//  body-local mm geometry and applies ONE root 0.001 scale. USDZ keeps mm
//  buffers under its existing 0.001 metre parent. World transforms are
//  composed once and never pre-multiplied into another unit's coordinates.
//

import Foundation
import simd

// MARK: - Public request values

public nonisolated enum CADExchangeScope: String, Codable, Sendable, Hashable {
    case part
    case assembly
}

/// Explicit export request. Empty `bodyIDs`/`instanceIDs` mean "all" for that
/// scope, preserving the historical UI default. `acceptPartial` is the user's
/// explicit acknowledgement that the coverage receipt is not complete; it is
/// never inferred from a successful write.
public nonisolated struct CADExchangeSelection: Sendable, Equatable {
    public var scope: CADExchangeScope
    public var bodyIDs: [UUID]
    public var instanceIDs: [UUID]
    public var acceptPartial: Bool
    public var expectedRevision: Int?
    public var expectedChangeCount: Int?
    public var expectedContentSHA256: String?

    public init(scope: CADExchangeScope = .part,
                bodyIDs: [UUID] = [],
                instanceIDs: [UUID] = [],
                acceptPartial: Bool = false,
                expectedRevision: Int? = nil,
                expectedChangeCount: Int? = nil,
                expectedContentSHA256: String? = nil) {
        self.scope = scope
        self.bodyIDs = bodyIDs
        self.instanceIDs = instanceIDs
        self.acceptPartial = acceptPartial
        self.expectedRevision = expectedRevision
        self.expectedChangeCount = expectedChangeCount
        self.expectedContentSHA256 = expectedContentSHA256
    }
}

public nonisolated struct CADExchangeCoverageItem: Sendable, Equatable {
    /// Placed occurrence identity. Nil for a part-scope document body.
    public var instanceID: UUID?
    public var parentInstanceID: UUID?
    /// Definition body identity. For an independent assembly copy this is the
    /// copied body, not the original definition.
    public var bodyID: UUID
    public var name: String
    public var path: [UUID]
    public var pathNames: [String]
    public var depth: Int
    /// Column-major 4x4 world matrix in millimetres.
    public var worldMatrix: [Double]
    public var worldPositionMM: [Double]
    public var analyticBRep: Bool
    public var independentCopy: Bool
    public var sourceReferenceID: UUID?
    public var included: Bool
    /// Stable machine-readable reason when excluded.
    public var reason: String?
    /// Material/texture fidelity gaps on an otherwise included mesh.
    public var materialWarnings: [String]
    public var meshVertexCount: Int
    public var meshTriangleCount: Int

    public init(instanceID: UUID? = nil,
                parentInstanceID: UUID? = nil,
                bodyID: UUID,
                name: String,
                path: [UUID] = [],
                pathNames: [String] = [],
                depth: Int = 0,
                worldMatrix: [Double],
                worldPositionMM: [Double],
                analyticBRep: Bool,
                independentCopy: Bool = false,
                sourceReferenceID: UUID? = nil,
                included: Bool,
                reason: String? = nil,
                materialWarnings: [String] = [],
                meshVertexCount: Int = 0,
                meshTriangleCount: Int = 0) {
        self.instanceID = instanceID
        self.parentInstanceID = parentInstanceID
        self.bodyID = bodyID
        self.name = name
        self.path = path
        self.pathNames = pathNames
        self.depth = depth
        self.worldMatrix = worldMatrix
        self.worldPositionMM = worldPositionMM
        self.analyticBRep = analyticBRep
        self.independentCopy = independentCopy
        self.sourceReferenceID = sourceReferenceID
        self.included = included
        self.reason = reason
        self.materialWarnings = materialWarnings
        self.meshVertexCount = meshVertexCount
        self.meshTriangleCount = meshTriangleCount
    }

    public var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "body_id": bodyID.uuidString,
            "name": name,
            "path": path.map(\.uuidString),
            "path_names": pathNames,
            "depth": depth,
            "world_matrix_mm": worldMatrix,
            "world_position_mm": worldPositionMM,
            "analytic_brep": analyticBRep,
            "independent_copy": independentCopy,
            "included": included,
            "material_warnings": materialWarnings,
            "mesh_vertex_count": meshVertexCount,
            "mesh_triangle_count": meshTriangleCount,
        ]
        if let instanceID { object["instance_id"] = instanceID.uuidString }
        if let parentInstanceID { object["parent_instance_id"] = parentInstanceID.uuidString }
        if let sourceReferenceID { object["source_reference_id"] = sourceReferenceID.uuidString }
        if let reason { object["reason"] = reason }
        return object
    }
}

public nonisolated struct CADExchangeCoverage: Sendable, Equatable {
    public var format: String
    public var scope: CADExchangeScope
    public var unit: String
    public var documentRevision: Int
    public var changeCount: Int
    public var contentSHA256: String
    public var selectedCount: Int
    public var includedCount: Int
    public var excludedCount: Int
    /// True only when every selected object is included with no material
    /// fidelity warning. A written file may still be useful when false, but it
    /// is never reported as complete.
    public var complete: Bool
    public var requiresConfirmation: Bool
    public var acceptedPartial: Bool
    public var items: [CADExchangeCoverageItem]
    /// Format-level losses that no receipt can repair (history, PMI, exact
    /// B-rep, assembly names/hierarchy). Values are stable machine keys.
    public var formatLoss: [String]
    public var notes: [String]

    public init(format: String,
                scope: CADExchangeScope,
                unit: String = "mm",
                documentRevision: Int,
                changeCount: Int,
                contentSHA256: String,
                selectedCount: Int,
                includedCount: Int,
                excludedCount: Int,
                complete: Bool,
                requiresConfirmation: Bool,
                acceptedPartial: Bool,
                items: [CADExchangeCoverageItem],
                formatLoss: [String],
                notes: [String]) {
        self.format = format
        self.scope = scope
        self.unit = unit
        self.documentRevision = documentRevision
        self.changeCount = changeCount
        self.contentSHA256 = contentSHA256
        self.selectedCount = selectedCount
        self.includedCount = includedCount
        self.excludedCount = excludedCount
        self.complete = complete
        self.requiresConfirmation = requiresConfirmation
        self.acceptedPartial = acceptedPartial
        self.items = items
        self.formatLoss = formatLoss
        self.notes = notes
    }

    public var excludedItems: [CADExchangeCoverageItem] {
        items.filter { !$0.included }
    }

    public func jsonObject() -> [String: Any] {
        [
            "format": format,
            "scope": scope.rawValue,
            "unit": unit,
            "document_revision": documentRevision,
            "change_count": changeCount,
            "content_sha256": contentSHA256,
            "selected_count": selectedCount,
            "included_count": includedCount,
            "excluded_count": excludedCount,
            "complete": complete,
            "requires_confirmation": requiresConfirmation,
            "accepted_partial": acceptedPartial,
            "format_loss": formatLoss,
            "notes": notes,
            "items": items.map(\.jsonObject),
            "excluded": excludedItems.map(\.jsonObject),
        ]
    }

    public func jsonString() -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: jsonObject(),
            options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

public nonisolated enum CADExchangeOutcome: Sendable {
    /// Bytes are complete or explicitly accepted as partial; `coverage`
    /// carries the exact receipt, including `complete:false` for a partial
    /// write.
    case success(data: Data, note: String, coverage: CADExchangeCoverage)
    /// Nothing was written. The caller must show the receipt and obtain an
    /// explicit partial-export choice before retrying with `acceptPartial`.
    case coverageRequired(CADExchangeCoverage)
    /// Dry-run receipt only. No bytes and no file promotion.
    case coverage(CADExchangeCoverage)
    case failure(CADDocumentError)
}

// MARK: - Internal plan

/// A fully resolved, revision-bound export plan. It owns immutable Body
/// VALUES (meshes are copy-on-write) and no live kernel handle of its own.
@MainActor
struct CADExchangePlan {
    var format: String
    var selection: CADExchangeSelection
    var coverage: CADExchangeCoverage
    /// World-space placed bodies for STEP/USDZ (body transform = world).
    var placedBodies: [Body]
    /// Body-local geometry for GLB; the scene graph carries placements.
    var glbBodies: [Body]
    var sceneGraph: [GLBSceneNode]?
    var faceTables: [BodyID: FaceTable]
    var faceTableRevisions: [BodyID: UInt64]
    var rootExtras: [String: Any]
}

// MARK: - Public entry points

@MainActor
public extension FloeCADDocument {
    /// Live change count used by the export fence. `revision` is the committed
    /// identity; `changeCount` also moves for unsaved edits.
    var exchangeChangeCount: Int { session.changeCount }

    /// True when the saved assembly resolves at least one visible placed part.
    /// The export sheet uses this only to explain an empty assembly; the core
    /// plan still validates every id itself.
    var hasDrawableAssemblyInstances: Bool {
        guard let data = session.document.assemblyData,
              let assembly = try? CADAssembly.decode(from: data) else { return false }
        return assembly.occurrences(includeHidden: false).contains(where: { $0.isDrawablePart })
    }

    /// Receipt-only preflight. No bytes, no workspace write, no format file.
    func exchangeCoverage(format: String,
                          selection: CADExchangeSelection) -> Result<CADExchangeCoverage, CADDocumentError> {
        do {
            let plan = try makeExchangePlan(format: format, selection: selection)
            return .success(plan.coverage)
        } catch let error as CADDocumentError {
            return .failure(error)
        } catch {
            return .failure(CADDocumentError(code: "export_coverage_failed",
                                             message: error.localizedDescription))
        }
    }

    /// The product export path shared by the UI and `cad.document`.
    ///
    /// It never writes a file itself: the host writes the returned bytes
    /// through its existing verified-staging/atomic workspace commit. When
    /// the receipt is incomplete and `acceptPartial` is false, no bytes are
    /// returned, so a stale/partial export can never overwrite the target.
    func nativeExchangeExport(format: String,
                              pageID: UUID?,
                              selection: CADExchangeSelection,
                              dryRun: Bool) -> CADExchangeOutcome {
        _ = pageID  // Drawing pages use the existing drawing export path.
        do {
            let plan = try makeExchangePlan(format: format, selection: selection)
            if dryRun {
                return .coverage(plan.coverage)
            }
            guard plan.coverage.includedCount > 0 else {
                return .failure(CADDocumentError(
                    code: "nothing_exportable",
                    message: "No selected object can be written as \(format.uppercased()); "
                        + "see the coverage receipt for the exact reasons."))
            }
            if plan.coverage.requiresConfirmation {
                return .coverageRequired(plan.coverage)
            }

            switch plan.format {
            case "step":
                switch STEPKit.export(bodies: plan.placedBodies) {
                case let .success(data, skipped):
                    guard skipped.isEmpty else {
                        return .failure(CADDocumentError(
                            code: "step_geometry_refused",
                            message: "The STEP writer rejected \(skipped.count) placed B-rep "
                                + "object(s) (\(skipped.prefix(3).joined(separator: ", "))); "
                                + "nothing was written."))
                    }
                    let note = "exact OCCT B-rep STEP AP214, \(plan.coverage.includedCount) "
                        + "placed object(s), millimetres; no history/PMI or assembly names/hierarchy"
                    return .success(data: data, note: note, coverage: plan.coverage)
                case let .nothingAnalytic(skipped):
                    return .failure(CADDocumentError(
                        code: "no_analytic_geometry",
                        message: "No analytic B-rep body to export; mesh-only: "
                            + skipped.prefix(4).joined(separator: ", ")))
                case .failed:
                    return .failure(CADDocumentError(
                        code: "step_export_failed",
                        message: "The STEP writer refused the export; nothing was written."))
                }

            case "glb":
                if plan.coverage.scope == .assembly,
                   (plan.sceneGraph?.isEmpty ?? true) {
                    return .failure(CADDocumentError(
                        code: "assembly_scene_empty",
                        message: "No placed occurrence resolved into the GLB hierarchy; nothing was written."))
                }
                let data = GLBExporter.glb(bodies: plan.glbBodies,
                                           faceTables: plan.faceTables,
                                           faceTableRevisions: plan.faceTableRevisions,
                                           sceneGraph: plan.sceneGraph,
                                           rootExtras: plan.rootExtras)
                let note = plan.coverage.scope == .assembly
                    ? "binary glTF assembly: \(plan.coverage.includedCount) placed object(s), "
                        + "occurrence hierarchy/IDs in nodes/extras, one mm→m root scale"
                    : "binary glTF tessellation with applied PBR/UV/textures (mesh representation)"
                return .success(data: data, note: note, coverage: plan.coverage)

            case "usdz":
                let report = USDZExporter.export(bodies: plan.placedBodies)
                if let data = report.data, report.diagnostics.isEmpty {
                    let note = plan.coverage.scope == .assembly
                        ? "USDZ assembly: \(plan.coverage.includedCount) placed object(s), "
                            + "millimetre buffers under one metre parent"
                        : "USDZ tessellation (presentation mesh)"
                    return .success(data: data, note: note, coverage: plan.coverage)
                }
                let details = report.diagnostics.prefix(4).map { diagnostic -> String in
                    var text = "\(diagnostic.code): \(diagnostic.message)"
                    if let bodyID = diagnostic.bodyID { text += " (body \(bodyID.uuidString))" }
                    if let slot = diagnostic.textureSlot { text += " [texture \(slot.rawValue)]" }
                    return text
                }.joined(separator: "; ")
                let code = report.diagnostics.first?.code ?? "usdz_export_failed"
                return .failure(CADDocumentError(
                    code: code,
                    message: details.isEmpty
                        ? "The USDZ writer produced no bytes; nothing was written."
                        : details))

            case "obj_bundle":
                let report = OBJBundleExporter.export(
                    bodies: plan.placedBodies,
                    faceTables: plan.faceTables,
                    faceTableRevisions: plan.faceTableRevisions)
                if let data = report.data, report.diagnostics.isEmpty {
                    let note = report.receipt?.noteText
                        ?? "OBJ bundle (ZIP) with materials and relative textures"
                    return .success(data: data, note: note, coverage: plan.coverage)
                }
                let details = report.diagnostics.prefix(4).map { diagnostic -> String in
                    var text = "\(diagnostic.code): \(diagnostic.message)"
                    if let bodyID = diagnostic.bodyID {
                        text += " (body \(bodyID.uuidString))"
                    }
                    if let slot = diagnostic.textureSlot {
                        text += " [texture \(slot.rawValue)]"
                    }
                    return text
                }.joined(separator: "; ")
                let code = report.diagnostics.first?.code ?? "obj_bundle_export_failed"
                return .failure(CADDocumentError(
                    code: code,
                    message: details.isEmpty
                        ? "The OBJ bundle writer produced no bytes; nothing was written."
                        : details))

            case "stl", "obj", "3mf":
                switch nativeExportData(format: plan.format, pageID: pageID,
                                        bodies: plan.placedBodies) {
                case let .success(data, note):
                    return .success(data: data, note: note, coverage: plan.coverage)
                case let .failure(error):
                    return .failure(error)
                }

            default:
                return .failure(CADDocumentError(
                    code: "unsupported_format",
                    message: "Exchange supports step, glb and usdz for parts or assemblies, "
                        + "and part-scope obj_bundle, stl, obj and 3mf; got '\(format)'."))
            }
        } catch let error as CADDocumentError {
            return .failure(error)
        } catch {
            return .failure(CADDocumentError(code: "export_failed",
                                             message: error.localizedDescription))
        }
    }

    /// Truthful part-scope export for the legacy whole-document callers
    /// (`CadDocumentCenter`/`FloeCAD3DBridge` and the editor's GLB actions).
    ///
    /// `step`/`glb`/`usdz` are the SAME exchange plan/writer used by
    /// `nativeExchangeExport`; `stl`/`obj`/`3mf` reuse that plan's per-body
    /// mesh validation and then the existing mesh writers restricted to the
    /// bodies the receipt includes. Bytes are returned only when every selected
    /// body can actually be written, or when the caller explicitly accepted
    /// the receipt's actual loss. An incomplete unscoped export therefore
    /// writes nothing instead of claiming completeness.
    func nativePartExport(format rawFormat: String,
                          pageID: UUID?,
                          acceptPartial: Bool = false,
                          expectedChangeCount: Int? = nil) -> CADExchangeOutcome {
        let format = rawFormat.lowercased()
        let selection = CADExchangeSelection(scope: .part, acceptPartial: acceptPartial,
                                             expectedChangeCount: expectedChangeCount)
        switch format {
        case "step", "glb", "usdz", "obj_bundle":
            return nativeExchangeExport(format: format, pageID: pageID,
                                        selection: selection, dryRun: false)

        case "stl", "obj", "3mf":
            do {
                // These writers share the part plan but do not enter the
                // exchange writer below. A reviewed partial export must keep
                // the same revision fence as GLB/STEP and the coverage query.
                try validateExchangeSelection(selection)
                try checkExchangeFence(selection)
                let plan = try makePartExchangePlan(format: format, selection: selection)
                guard plan.coverage.includedCount > 0 else {
                    return .failure(CADDocumentError(
                        code: "nothing_exportable",
                        message: "No document body can be written as \(format.uppercased()); "
                            + "see the coverage receipt for the exact reasons."))
                }
                guard !plan.coverage.requiresConfirmation else {
                    return .coverageRequired(plan.coverage)
                }
                switch nativeExportData(format: format, pageID: pageID,
                                        bodies: plan.placedBodies) {
                case let .success(data, note):
                    return .success(data: data, note: note, coverage: plan.coverage)
                case let .failure(error):
                    return .failure(error)
                }
            } catch let error as CADDocumentError {
                return .failure(error)
            } catch {
                return .failure(CADDocumentError(code: "export_failed",
                                                 message: error.localizedDescription))
            }

        default:
            return .failure(CADDocumentError(
                code: "unsupported_format",
                message: "Part export supports step, stl, obj, 3mf, glb, usdz and "
                    + "obj_bundle; got '\(rawFormat)'."))
        }
    }
}

// MARK: - Plan construction

@MainActor
private extension FloeCADDocument {
    func makeExchangePlan(format rawFormat: String,
                          selection: CADExchangeSelection) throws -> CADExchangePlan {
        let format = rawFormat.lowercased()
        guard ["step", "glb", "usdz", "obj_bundle", "stl", "obj", "3mf"].contains(format) else {
            throw CADDocumentError(
                code: "unsupported_format",
                message: "Exchange supports step, glb and usdz for parts or assemblies, "
                    + "and part-scope obj_bundle, stl, obj and 3mf; got '\(rawFormat)'.")
        }
        if !["step", "glb", "usdz"].contains(format), selection.scope == .assembly {
            throw CADDocumentError(
                code: "unsupported_format",
                message: "\(format) supports part export only; assembly placement "
                    + "export is available as step, glb or usdz.")
        }
        try validateExchangeSelection(selection)
        try checkExchangeFence(selection)

        switch selection.scope {
        case .part:
            return try makePartExchangePlan(format: format, selection: selection)
        case .assembly:
            return try makeAssemblyExchangePlan(format: format, selection: selection)
        }
    }

    func validateExchangeSelection(_ selection: CADExchangeSelection) throws {
        let maximum = 512
        guard selection.bodyIDs.count <= maximum,
              selection.instanceIDs.count <= maximum else {
            throw CADDocumentError(code: "invalid_selection",
                                   message: "An export selection is limited to \(maximum) ids.")
        }
        switch selection.scope {
        case .part where !selection.instanceIDs.isEmpty:
            throw CADDocumentError(code: "invalid_selection",
                                   message: "scope=part selects document bodies; use body_ids, not instance_ids.")
        case .assembly where !selection.bodyIDs.isEmpty:
            throw CADDocumentError(code: "invalid_selection",
                                   message: "scope=assembly selects occurrences; use instance_ids, not body_ids.")
        default:
            break
        }
        if let sha = selection.expectedContentSHA256,
           (sha.count != 64 || !sha.allSatisfy { $0.isHexDigit }) {
            throw CADDocumentError(code: "invalid_selection",
                                   message: "expected_content_sha256 must be a 64-character SHA-256 hex string.")
        }
    }

    func checkExchangeFence(_ selection: CADExchangeSelection) throws {
        if let expected = selection.expectedRevision, expected != revision {
            throw CADDocumentError(code: "stale_export",
                                   message: "The document revision changed before export; nothing was written.")
        }
        if let expected = selection.expectedChangeCount, expected != session.changeCount {
            throw CADDocumentError(code: "stale_export",
                                   message: "The document changed before export; nothing was written.")
        }
        if let expected = selection.expectedContentSHA256,
           expected.lowercased() != contentSHA256.lowercased() {
            throw CADDocumentError(code: "stale_export",
                                   message: "The saved document identity changed before export; nothing was written.")
        }
    }

    func makePartExchangePlan(format: String,
                              selection: CADExchangeSelection) throws -> CADExchangePlan {
        let allBodies = session.document.bodies
        var chosen: [Body] = []
        if selection.bodyIDs.isEmpty {
            chosen = allBodies
        } else {
            var seen = Set<UUID>()
            for id in selection.bodyIDs where seen.insert(id).inserted {
                guard let body = allBodies.first(where: { $0.id.raw == id }) else {
                    throw CADDocumentError(code: "unknown_body",
                                           message: "No document body has id \(id.uuidString).")
                }
                chosen.append(body)
            }
        }
        guard !chosen.isEmpty else {
            throw CADDocumentError(code: "empty_selection",
                                   message: "There is no document body to export.")
        }

        var items: [CADExchangeCoverageItem] = []
        var includedBodies: [Body] = []
        var warnings: [String] = []
        var informationalNotes: [String] = []
        for body in chosen {
            let matrix = body.transform.matrix
            let mesh = body.render
            let fidelityWarnings = materialWarnings(for: body, format: format)
            let meshIssue = CADExchangeMeshValidator.issue(for: body)
            let analytic = body.brep != nil
            var included = true
            var reason: String?
            switch format {
            case "step":
                if !analytic {
                    included = false
                    reason = "mesh_only_no_analytic_brep"
                }
            default:
                if let meshIssue {
                    included = false
                    reason = meshIssue
                }
            }
            if format == "usdz", !body.materialFaceBindings.isEmpty {
                included = false
                reason = "unsupported_face_materials"
            }
            if included {
                includedBodies.append(body)
                if usesGeneratedBoxProjection(for: body, format: format) {
                    informationalNotes.append("texture_uv_generated")
                }
            }
            warnings.append(contentsOf: fidelityWarnings)
            items.append(CADExchangeCoverageItem(
                bodyID: body.id.raw,
                name: body.name,
                worldMatrix: matrixArray(matrix),
                worldPositionMM: [matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z],
                analyticBRep: analytic,
                included: included,
                reason: reason,
                materialWarnings: fidelityWarnings,
                meshVertexCount: mesh.positions.count,
                meshTriangleCount: mesh.indices.count / 3))
        }

        let coverage = makeCoverage(format: format,
                                    scope: .part,
                                    selection: selection,
                                    items: items,
                                    extraWarnings: warnings,
                                    informationalNotes: informationalNotes)
        let faceRanges = session.faceRangeTables(for: includedBodies)
        return CADExchangePlan(format: format, selection: selection, coverage: coverage,
                               placedBodies: includedBodies,
                               glbBodies: includedBodies,
                               sceneGraph: nil,
                               faceTables: faceRanges.tables,
                               faceTableRevisions: faceRanges.revisions,
                               rootExtras: [:])
    }

    func makeAssemblyExchangePlan(format: String,
                                  selection: CADExchangeSelection) throws -> CADExchangePlan {
        guard let data = session.document.assemblyData, !data.isEmpty else {
            throw CADDocumentError(code: "no_assembly_instances",
                                   message: "scope=assembly needs a saved assembly with placed instances.")
        }
        let assembly: CADAssembly
        do {
            assembly = try CADAssembly.decode(from: data)
        } catch {
            throw CADDocumentError(code: "invalid_assembly",
                                   message: "The stored assembly hierarchy could not be decoded; nothing was written.")
        }

        let every = assembly.occurrences(includeHidden: true)
        let visible = assembly.occurrences(includeHidden: false)
        let drawable = visible.filter(\.isDrawablePart)
        guard !drawable.isEmpty else {
            throw CADDocumentError(code: "no_assembly_instances",
                                   message: "The assembly has no visible placed part to export.")
        }

        let selected: [CADAssemblyOccurrence]
        if selection.instanceIDs.isEmpty {
            selected = drawable
        } else {
            var selectedIDs = Set<UUID>()
            var seen = Set<UUID>()
            for id in selection.instanceIDs where seen.insert(id).inserted {
                guard let occurrence = every.first(where: { $0.instance.id == id }) else {
                    throw CADDocumentError(code: "unknown_instance",
                                           message: "No assembly instance has id \(id.uuidString).")
                }
                guard occurrence.isVisible else {
                    throw CADDocumentError(code: "instance_not_visible",
                                           message: "Instance \(occurrence.instance.name) is hidden; "
                                               + "show it before exporting.")
                }
                if occurrence.isDrawablePart {
                    selectedIDs.insert(id)
                } else {
                    let descendants = drawable.filter { $0.path.contains(id) }
                    guard !descendants.isEmpty else {
                        throw CADDocumentError(code: "empty_selection",
                                               message: "The selected subassembly has no visible placed part.")
                    }
                    selectedIDs.formUnion(descendants.map(\.instance.id))
                }
            }
            selected = drawable.filter { selectedIDs.contains($0.instance.id) }
        }
        guard !selected.isEmpty else {
            throw CADDocumentError(code: "empty_selection",
                                   message: "There is no visible placed part to export.")
        }

        var items: [CADExchangeCoverageItem] = []
        var placedBodies: [Body] = []
        var glbBodies: [Body] = []
        var glbIndexByInstance: [UUID: Int] = [:]
        var sourceByInstance: [UUID: Body] = [:]
        var occurrenceByInstance: [UUID: CADAssemblyOccurrence] = [:]
        var warnings: [String] = []
        var informationalNotes: [String] = []

        for occurrence in selected {
            occurrenceByInstance[occurrence.instance.id] = occurrence
            guard let sourceID = occurrence.effectiveBodyID,
                  let source = session.document.bodies.first(where: { $0.id.raw == sourceID }) else {
                items.append(CADExchangeCoverageItem(
                    instanceID: occurrence.instance.id,
                    parentInstanceID: occurrence.parentInstanceID,
                    bodyID: occurrence.effectiveBodyID ?? occurrence.instance.bodyID,
                    name: occurrence.instance.name,
                    path: occurrence.path,
                    pathNames: occurrence.pathNames,
                    depth: occurrence.depth,
                    worldMatrix: matrixArray(occurrence.worldTransform.placement3D().matrix),
                    worldPositionMM: vectorArray(occurrence.worldTransform.position),
                    analyticBRep: false,
                    independentCopy: occurrence.instance.isIndependentCopy,
                    sourceReferenceID: occurrence.sourceReferenceID,
                    included: false,
                    reason: "source_body_missing"))
                continue
            }
            sourceByInstance[occurrence.instance.id] = source
            let placement = occurrence.worldTransform
            guard placement.isPlaceable else {
                items.append(CADExchangeCoverageItem(
                    instanceID: occurrence.instance.id,
                    parentInstanceID: occurrence.parentInstanceID,
                    bodyID: sourceID,
                    name: occurrence.instance.name,
                    path: occurrence.path,
                    pathNames: occurrence.pathNames,
                    depth: occurrence.depth,
                    worldMatrix: matrixArray(source.transform.matrix),
                    worldPositionMM: vectorArray(placement.position),
                    analyticBRep: source.brep != nil,
                    independentCopy: occurrence.instance.isIndependentCopy,
                    sourceReferenceID: occurrence.sourceReferenceID,
                    included: false,
                    reason: "invalid_placement",
                    meshVertexCount: source.render.positions.count,
                    meshTriangleCount: source.render.indices.count / 3))
                continue
            }

            let world = placement.placement3D().composed(onto: source.transform)
            let meshIssue = CADExchangeMeshValidator.issue(for: source)
            let fidelityWarnings = materialWarnings(for: source, format: format)
            let analytic = source.brep != nil
            var included = true
            var reason: String?
            switch format {
            case "step":
                if !analytic {
                    included = false
                    reason = "mesh_only_no_analytic_brep"
                }
            default:
                if let meshIssue {
                    included = false
                    reason = meshIssue
                }
            }
            if format == "usdz", !source.materialFaceBindings.isEmpty {
                included = false
                reason = "unsupported_face_materials"
            }

            if included {
                var placed = source
                placed.name = occurrence.instance.name
                placed.transform = world
                placed.isHidden = false
                placedBodies.append(placed)

                var glb = source
                glb.name = occurrence.instance.name
                glb.transform = .identity
                glb.isHidden = false
                glbIndexByInstance[occurrence.instance.id] = glbBodies.count
                glbBodies.append(glb)
                if usesGeneratedBoxProjection(for: source, format: format) {
                    informationalNotes.append("texture_uv_generated")
                }
            }
            warnings.append(contentsOf: fidelityWarnings)
            items.append(CADExchangeCoverageItem(
                instanceID: occurrence.instance.id,
                parentInstanceID: occurrence.parentInstanceID,
                bodyID: sourceID,
                name: occurrence.instance.name,
                path: occurrence.path,
                pathNames: occurrence.pathNames,
                depth: occurrence.depth,
                worldMatrix: matrixArray(world.matrix),
                worldPositionMM: [world.matrix.columns.3.x,
                                  world.matrix.columns.3.y,
                                  world.matrix.columns.3.z],
                analyticBRep: analytic,
                independentCopy: occurrence.instance.isIndependentCopy,
                sourceReferenceID: occurrence.sourceReferenceID,
                included: included,
                reason: reason,
                materialWarnings: fidelityWarnings,
                meshVertexCount: source.render.positions.count,
                meshTriangleCount: source.render.indices.count / 3))
        }

        let coverage = makeCoverage(format: format,
                                    scope: .assembly,
                                    selection: selection,
                                    items: items,
                                    extraWarnings: warnings,
                                    informationalNotes: informationalNotes)
        guard coverage.includedCount > 0 else {
            return CADExchangePlan(format: format, selection: selection, coverage: coverage,
                                   placedBodies: [], glbBodies: [], sceneGraph: nil,
                                   faceTables: [:], faceTableRevisions: [:],
                                   rootExtras: [:])
        }

        // The GLB graph keeps the persisted occurrence hierarchy. A leaf's
        // local matrix is (instance placement ∘ source body transform); its
        // ancestors contribute their own local placements. Geometry stays
        // body-local, so no placement is applied twice.
        var includedPaths = Set<[UUID]>()
        for item in coverage.items where item.included {
            if let instanceID = item.instanceID,
               let occurrence = occurrenceByInstance[instanceID] {
                includedPaths.insert(occurrence.path)
            }
        }
        var prefixPaths = Set<[UUID]>()
        for path in includedPaths {
            for length in 1...path.count {
                prefixPaths.insert(Array(path.prefix(length)))
            }
        }

        func buildNodes(_ list: [CADAssemblyInstance],
                        parentPath: [UUID]) -> [GLBSceneNode] {
            var nodes: [GLBSceneNode] = []
            for instance in list {
                let path = parentPath + [instance.id]
                guard prefixPaths.contains(path) else { continue }
                if instance.subassemblyID != nil {
                    let children = buildNodes(instance.children, parentPath: path)
                    guard !children.isEmpty else { continue }
                    var extras: [String: Any] = [
                        "floe_kind": "subassembly",
                        "floe_occurrence_id": instance.id.uuidString,
                        "floe_occurrence_path": path.map(\.uuidString),
                        "floe_depth": path.count - 1,
                        "floe_subassembly_id": (instance.subassemblyID ?? instance.bodyID).uuidString,
                    ]
                    if path.count > 1 {
                        extras["floe_parent_instance_id"] = path[path.count - 2].uuidString
                    }
                    nodes.append(GLBSceneNode(
                        name: instance.name,
                        bodyIndex: nil,
                        matrix: matrixArray(instance.transform.placement3D().matrix),
                        children: children,
                        extras: extras))
                } else if let bodyIndex = glbIndexByInstance[instance.id],
                          let source = sourceByInstance[instance.id],
                          let occurrence = occurrenceByInstance[instance.id] {
                    let world = occurrence.worldTransform
                    let worldMatrix = world.placement3D().composed(onto: source.transform).matrix
                    let local = instance.transform.placement3D().composed(onto: source.transform).matrix
                    var extras: [String: Any] = [
                        "floe_kind": "part",
                        "floe_occurrence_id": instance.id.uuidString,
                        "floe_occurrence_path": path.map(\.uuidString),
                        "floe_occurrence_names": occurrence.pathNames,
                        "floe_source_body_id": source.id.raw.uuidString,
                        "floe_depth": path.count - 1,
                        "floe_independent_copy": instance.isIndependentCopy,
                        "floe_analytic_brep": source.brep != nil,
                        "floe_world_position_mm": vectorArray(world.position),
                        "floe_world_matrix_mm": matrixArray(worldMatrix),
                    ]
                    if path.count > 1 {
                        extras["floe_parent_instance_id"] = path[path.count - 2].uuidString
                    }
                    if let referenceID = instance.sourceReferenceID {
                        extras["floe_source_reference_id"] = referenceID.uuidString
                    }
                    nodes.append(GLBSceneNode(
                        name: instance.name,
                        bodyIndex: bodyIndex,
                        matrix: matrixArray(local),
                        children: [],
                        extras: extras))
                }
            }
            return nodes
        }

        let sceneGraph = buildNodes(assembly.instances, parentPath: [])
        let faceRanges = session.faceRangeTables(for: glbBodies)
        let rootExtras: [String: Any] = [
            "floe_assembly_scope": "assembly",
            "floe_occurrence_count": coverage.includedCount,
            "floe_hierarchy": "preserved",
            "floe_format_loss": coverage.formatLoss,
            "floe_export_unit": "millimetres",
            "floe_coverage_complete": coverage.complete,
        ]
        return CADExchangePlan(format: format, selection: selection, coverage: coverage,
                               placedBodies: placedBodies, glbBodies: glbBodies,
                               sceneGraph: sceneGraph,
                               faceTables: faceRanges.tables,
                               faceTableRevisions: faceRanges.revisions,
                               rootExtras: rootExtras)
    }

    func makeCoverage(format: String,
                      scope: CADExchangeScope,
                      selection: CADExchangeSelection,
                      items: [CADExchangeCoverageItem],
                      extraWarnings: [String],
                      informationalNotes: [String] = []) -> CADExchangeCoverage {
        let included = items.filter(\.included).count
        let excluded = items.count - included
        let fidelityWarnings = items.flatMap(\.materialWarnings)
        let complete = excluded == 0 && fidelityWarnings.isEmpty
        let acceptedPartial = selection.acceptPartial
        var notes: [String] = []
        if format == "step" {
            notes.append("STEP writes exact B-rep geometry in millimetres; it does not carry "
                + "model history, PMI, part names or the assembly hierarchy.")
        } else if format == "glb" {
            notes.append("GLB keeps body-local millimetre geometry and applies one 0.001 "
                + "root scale; scope=assembly nodes/extras carry occurrence identity and hierarchy.")
        } else if format == "usdz" {
            notes.append("USDZ keeps millimetre buffers under one metre parent; per-face "
                + "materials are not supported.")
        }
        if !complete {
            notes.append("This receipt is not complete: \(excluded) object(s) or material "
                + "channel(s) are excluded. Nothing is promoted without an explicit partial choice.")
        }
        if !extraWarnings.isEmpty {
            notes.append("Warnings: " + Array(Set(extraWarnings)).sorted().prefix(6).joined(separator: ", "))
        }
        if !informationalNotes.isEmpty {
            // Supported export-only behaviour, not a fidelity loss: the
            // deterministic box projection is recorded instead of pretending
            // the body authored UVs.
            notes.append("Informational: "
                + Array(Set(informationalNotes)).sorted().joined(separator: ", "))
        }
        return CADExchangeCoverage(
            format: format,
            scope: scope,
            unit: "mm",
            documentRevision: revision,
            changeCount: session.changeCount,
            contentSHA256: contentSHA256,
            selectedCount: items.count,
            includedCount: included,
            excludedCount: excluded,
            complete: complete,
            requiresConfirmation: !complete && !acceptedPartial,
            acceptedPartial: acceptedPartial,
            items: items,
            formatLoss: formatLoss(for: format),
            notes: notes)
    }

    func formatLoss(for format: String) -> [String] {
        switch format {
        case "step":
            return ["history", "pmi", "assembly_names", "assembly_hierarchy"]
        case "glb":
            return ["history", "pmi", "brep"]
        case "usdz":
            return ["history", "pmi", "brep", "assembly_hierarchy"]
        case "obj_bundle":
            return ["history", "pmi", "brep"]
        default:
            return ["history", "pmi"]
        }
    }

    /// Material/texture gaps are fidelity warnings, not a silent success. The
    /// exporter may still write the mesh with the scalar factors/UV fallback;
    /// the receipt says exactly what was not carried.
    ///
    /// The texture predicate is the real writer's, not one shared byte cap:
    /// GLB can embed any PNG/JPEG inside the decoded-dimension bounds even when
    /// the encoded image is larger than the 8 MiB material-library limit, while
    /// USDZ and the OBJ bundle still enforce that authored-material cap.
    func materialWarnings(for body: Body, format: String) -> [String] {
        guard format == "glb" || format == "usdz" || format == "obj_bundle" else { return [] }
        var warnings = Set<String>()
        func textureIsEmbeddable(_ data: Data) -> Bool {
            GLBExporter.textureCanBeEmbedded(data)
        }
        func inspect(_ spec: BodyMaterialSpec?) {
            guard let spec else { return }
            if let metadata = spec.textureMetadata {
                let slots = metadata.map(\.slot)
                if Set(slots).count != slots.count {
                    warnings.insert("ambiguous_texture_metadata")
                }
                for item in metadata {
                    guard let data = spec.textureData(for: item.slot), !data.isEmpty else {
                        warnings.insert("texture_\(item.slot.rawValue)_missing")
                        continue
                    }
                    if !textureIsEmbeddable(data) {
                        warnings.insert("texture_\(item.slot.rawValue)_invalid")
                    }
                    if item.verifiedDigest(for: data) == nil {
                        warnings.insert("texture_\(item.slot.rawValue)_identity_mismatch")
                    }
                    if format != "glb", data.count > CADMaterialLimits.maximumTextureBytes {
                        warnings.insert("texture_\(item.slot.rawValue)_too_large")
                    }
                }
            }
            for slot in MaterialTextureSlot.allCases {
                guard let data = spec.textureData(for: slot) else { continue }
                if data.isEmpty {
                    warnings.insert("texture_\(slot.rawValue)_missing")
                } else {
                    if !textureIsEmbeddable(data) {
                        warnings.insert("texture_\(slot.rawValue)_invalid")
                    }
                    if format != "glb", data.count > CADMaterialLimits.maximumTextureBytes {
                        warnings.insert("texture_\(slot.rawValue)_too_large")
                    }
                }
            }
            if spec.hasAnyTexture,
               MaterialUVProjector.effectiveUVs(
                   meshTexcoords: body.render.texcoords,
                   positions: body.render.positions,
                   normals: body.render.normals,
                   indices: body.render.indices,
                   mapping: spec.uvMapping) == nil {
                // GLB and the OBJ bundle generate the same deterministic box
                // projection for a mesh-sourced textured material with no UVs;
                // that is supported export behaviour, not a fidelity loss. USDZ
                // has no such fallback, and an explicit projection that still
                // yields nil is unmapped for every writer.
                let meshSource = (spec.uvMapping?.source ?? .mesh) == .mesh
                if format == "usdz" || !meshSource {
                    warnings.insert("texture_uv_unmapped")
                }
            }
            if (format == "usdz" || format == "obj_bundle"),
               let strength = spec.emissiveStrength, strength > 1,
               spec.emissive != nil {
                warnings.insert("unsupported_hdr_emission")
            }
            if format == "obj_bundle" {
                if spec.normalTexture != nil,
                   spec.textureColorSpace(for: .normal) == .srgb {
                    warnings.insert("unsupported_normal_color_space")
                }
                if let mapping = spec.uvMapping,
                   mapping.source == .mesh,
                   mapping.rotationDegrees != 0 || mapping.offset != .zero
                       || mapping.flipU || mapping.flipV {
                    warnings.insert("unsupported_mesh_uv_transform")
                }
            }
        }
        inspect(body.material)
        for binding in body.materialFaceBindings {
            inspect(binding.material)
        }
        if (format == "glb" || format == "obj_bundle"), !body.materialFaceBindings.isEmpty {
            // The same prepared table the viewport/scene use: the applied
            // rebuild's table when current, otherwise one derived from the
            // exact restored render. Nil means no trustworthy range exists.
            let table = session.faceRangeTable(for: body)
            if table == nil { warnings.insert("face_material_ranges_unavailable") }
            // One shared assessment with both writers: signature matching alone
            // is not enough — a table can still miss, ambiguously match or
            // overlap the exact triangle range and fall back to the body
            // material.
            let assessment = CADFaceMaterialResolver.assessGroups(
                in: body,
                table: table,
                tableRevision: table.map { _ in body.meshRevision })
            for issue in assessment.issues {
                switch issue.kind {
                case .tableUnavailable:
                    warnings.insert("face_material_ranges_unavailable")
                case .missing:
                    warnings.insert("face_material_missing")
                case .ambiguous, .ambiguousSignature:
                    warnings.insert("face_material_ambiguous")
                case .overlapOrInvalid:
                    warnings.insert("face_material_overlap")
                case .unresolvedSignature:
                    warnings.insert("face_material_unresolved")
                }
            }
        }
        return warnings.sorted()
    }

    /// True when a supported writer will synthesize the deterministic box
    /// projection for this body. The receipt records the informational fact;
    /// it does not pretend authored UVs exist and it does not gate the export.
    func usesGeneratedBoxProjection(for body: Body, format: String) -> Bool {
        guard format == "glb" || format == "obj_bundle" else { return false }
        func generated(_ spec: BodyMaterialSpec?) -> Bool {
            guard let spec, spec.hasAnyTexture,
                  (spec.uvMapping?.source ?? .mesh) == .mesh else { return false }
            return MaterialUVProjector.effectiveUVs(
                meshTexcoords: body.render.texcoords,
                positions: body.render.positions,
                normals: body.render.normals,
                indices: body.render.indices,
                mapping: spec.uvMapping) == nil
        }
        if generated(body.material) { return true }
        return body.materialFaceBindings.contains { generated($0.material) }
    }

}

// MARK: - Small value helpers

nonisolated enum CADExchangeMeshValidator {
    static func issue(for body: Body) -> String? {
        let mesh = body.render
        guard !mesh.positions.isEmpty, !mesh.indices.isEmpty else { return "empty_mesh" }
        guard mesh.indices.count % 3 == 0 else { return "index_count_not_triangles" }
        guard mesh.positions.count == mesh.normals.count else { return "normal_count_mismatch" }
        guard mesh.indices.allSatisfy({ Int($0) < mesh.positions.count }) else {
            return "index_out_of_range"
        }
        guard mesh.positions.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }),
              mesh.normals.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else {
            return "non_finite_mesh"
        }
        let transform = body.transform
        guard transform.scale.isFinite, transform.scale > 0,
              transform.translation.x.isFinite, transform.translation.y.isFinite,
              transform.translation.z.isFinite,
              transform.rotation.vector.x.isFinite, transform.rotation.vector.y.isFinite,
              transform.rotation.vector.z.isFinite, transform.rotation.vector.w.isFinite,
              simd_length(transform.rotation.vector) > 1e-12 else {
            return "invalid_transform"
        }
        return nil
    }
}

nonisolated private func matrixArray(_ matrix: simd_double4x4) -> [Double] {
    [
        matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z, matrix.columns.0.w,
        matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z, matrix.columns.1.w,
        matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z, matrix.columns.2.w,
        matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z, matrix.columns.3.w,
    ]
}

nonisolated private func vectorArray(_ vector: SIMD3<Double>) -> [Double] {
    [vector.x, vector.y, vector.z]
}
